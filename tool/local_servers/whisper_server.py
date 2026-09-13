"""faster-whisper 本地语音识别服务（sync-translate 专用，OpenAI 兼容）。

- faster-whisper（CTranslate2 内核），优先 CUDA，自动回退 CPU
- HTTP 接口：
    实时字幕：
    GET  /health                    -> {"ok": true, "device": "cuda"}
    POST /v1/audio/transcriptions   multipart: file=audio.wav, model, language, response_format
                                     -> {"text": "..."}
    批量离线字幕（音视频文件 -> SRT，异步任务队列）：
    POST /batch/transcribe          {"path": "...", "target_lang": "zh"} -> {"job_id": "..."}
    GET  /batch/status?job_id=...   -> {status, progress, srt_path, ...}
    GET  /batch/jobs                -> 全部任务列表

运行：venv\\Scripts\\python.exe whisper_server.py [--model deepdml/faster-whisper-large-v3-turbo-ct2]
                                [--port 8000] [--device cuda|cpu|auto]
国内网络自动使用 hf-mirror.com 下载模型。
"""

import argparse
import logging
import os
import sys
import threading
from pathlib import Path
from uuid import uuid4

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

# 注册 NVIDIA cuDNN/cuBLAS 运行库路径（ctranslate2 GPU 推理依赖）
_NVIDIA_BASE = Path(__file__).resolve().parent / "venv" / "Lib" / "site-packages" / "nvidia"
for _dll_dir in (_NVIDIA_BASE / "cudnn" / "bin", _NVIDIA_BASE / "cublas" / "bin"):
    if _dll_dir.is_dir():
        os.add_dll_directory(str(_dll_dir))

import numpy as np  # noqa: E402
import uvicorn  # noqa: E402
from fastapi import FastAPI, File, Form, HTTPException, UploadFile  # noqa: E402
from faster_whisper import WhisperModel  # noqa: E402
from pydantic import BaseModel  # noqa: E402

MODELS_ROOT = Path(__file__).resolve().parent / "models"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("whisper-server")

app = FastAPI(title="faster-whisper local STT service")
_model = None
_model_id = ""
_device_name = "not-loaded"
_compute_type = ""


def load_model(model_name: str, device: str, compute_type: str) -> None:
    global _model, _device_name, _model_id, _compute_type
    _model_id = model_name
    _compute_type = compute_type
    # 优先用本地模型目录（download_models.ps1 下载），否则走 HF 仓库（hf-mirror）
    local_dir = MODELS_ROOT / Path(model_name).name
    src = str(local_dir) if local_dir.is_dir() else model_name
    log.info("加载 whisper 模型: %s", src)
    if device == "auto":
        try:
            import ctranslate2  # noqa: F401
            device = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
        except Exception:
            device = "cpu"
    try:
        _model = WhisperModel(src, device=device, compute_type=compute_type)
        _device_name = device
        log.info("whisper 模型已加载: %s，设备=%s，compute_type=%s",
                 src, device, compute_type)
    except Exception as exc:
        log.warning("GPU 初始化失败（%s），回退 CPU", exc)
        _model = WhisperModel(src, device="cpu", compute_type="int8")
        _device_name = "cpu"
        log.info("whisper 模型已加载（CPU 回退）: %s", src)


@app.get("/health")
def health() -> dict:
    return {"ok": _model is not None, "device": _device_name,
            "model": _model_id, "compute_type": _compute_type}


@app.post("/v1/audio/transcriptions")
def transcribe(
    file: UploadFile = File(...),
    model: str = Form(""),
    language: str = Form(""),
    response_format: str = Form("json"),
) -> dict:
    # 注意：同步端点（FastAPI 放入线程池执行），
    # 让"边听边出"的部分识别与最终识别可以并发处理。
    if _model is None:
        return {"error": "model not loaded"}
    raw = file.file.read()
    # 应用端固定上传 16kHz 单声道 PCM16 WAV
    try:
        audio = np.frombuffer(raw[44:], dtype=np.int16).astype(np.float32) / 32768.0
    except ValueError:
        return {"error": "unsupported audio format (expect PCM16 WAV)"}
    if audio.size == 0:
        return {"text": ""}

    lang = language if language not in ("", "auto") else None
    segments, info = _model.transcribe(
        audio,
        language=lang,
        beam_size=5,
        vad_filter=False,
        condition_on_previous_text=False,
    )
    text = "".join(seg.text for seg in segments).strip()
    return {"text": text}


# ---------------------------------------------------------------------------
# 批量离线字幕：音视频文件 -> SRT（异步队列）
# ---------------------------------------------------------------------------

BATCH_JOBS: dict[str, dict] = {}
_BATCH_LOCK = threading.Lock()
_batch_worker_thread: threading.Thread | None = None
_nllb_ready = False
_nllb_lock = threading.Lock()


class BatchRequest(BaseModel):
    path: str
    target_lang: str = "zh"
    source_lang: str | None = None


def _ensure_nllb() -> None:
    """懒加载 NLLB 翻译模型（与实时字幕共用官方模型）。"""
    global _nllb_ready
    if _nllb_ready:
        return
    with _nllb_lock:
        if _nllb_ready:
            return
        import nllb_server  # 同目录模块

        nllb_server.load_model(Path(nllb_server.DEFAULT_MODEL_DIR), "auto")
        _nllb_ready = True
        log.info("NLLB 模型已加载（批量翻译）")


def _assemble_audio(frames: list[tuple[float, np.ndarray]],
                    sample_rate: int) -> np.ndarray:
    """按 PTS 起始时间拼装音频帧：起始偏移与帧间空隙补静音，
    保证音频时间轴严格对应视频时间轴（避免后半段字幕漂移）。"""
    chunks: list[np.ndarray] = []
    expected_next: float | None = None

    def push_silence(seconds: float) -> None:
        n = int(round(seconds * sample_rate))
        if n > 0:
            chunks.append(np.zeros(n, dtype=np.float32))

    for start, pcm in frames:
        dur = pcm.size / sample_rate
        if expected_next is None:
            if start > 0.05:
                push_silence(start)
        elif start > expected_next + 0.05:
            push_silence(start - expected_next)
        expected_next = start + dur
        chunks.append(np.asarray(pcm, dtype=np.float32))
    if not chunks:
        return np.zeros(0, dtype=np.float32)
    audio = np.concatenate(chunks)
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak > 1.0:
        audio = audio / peak
    return audio


def _decode_audio(path: str) -> np.ndarray:
    """任意音视频 -> 16kHz 单声道 float32（PyAV 内置 FFmpeg）。"""
    import av

    container = av.open(path)
    stream = container.streams.audio[0] if container.streams.audio else None
    if stream is None:
        raise RuntimeError("文件中没有音频轨")
    resampler = av.AudioResampler(format="flt", layout="mono", rate=16000)
    frames: list[tuple[float, np.ndarray]] = []
    for frame in container.decode(stream):
        # 帧在视频时间轴上的起始时间（秒）
        start = (float(frame.pts * frame.time_base)
                 if frame.pts is not None and frame.time_base is not None
                 else 0.0)
        parts: list[np.ndarray] = []
        for out in resampler.resample(frame):
            parts.append(out.to_ndarray())
        if not parts:
            continue
        pcm = np.concatenate(parts, axis=1)
        if pcm.ndim == 2:
            pcm = pcm[0]
        frames.append((start, np.asarray(pcm, dtype=np.float32)))
    if not frames:
        raise RuntimeError("解码后无音频数据")
    return _assemble_audio(frames, 16000)


def _fmt_ts(seconds: float) -> str:
    ms = int(round(seconds * 1000))
    h, rem = divmod(ms, 3600000)
    m, rem = divmod(rem, 60000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


# 字幕行内允许的最大静音间隔（秒）：超过即切分成新字幕，
# 保证长停顿期间不显示任何字幕，下一句开始时才出现。
_SUB_MAX_GAP_SECONDS = 1.2
# 单条字幕最长时长（秒），防止句子过长挂屏
_SUB_MAX_LINE_SECONDS = 8.0


def _segments_to_lines(segments) -> list[dict]:
    """把 whisper 片段按词级时间戳切分为"只在该句说话时段显示"的字幕行。"""
    words: list[tuple[float, float, str]] = []
    for seg in segments:
        if seg.words:
            for w in seg.words:
                words.append((float(w.start), float(w.end), w.word))
        else:
            # 无词级时间戳时退化为整段
            words.append((float(seg.start), float(seg.end), seg.text.strip()))
    lines: list[dict] = []
    cur_start = cur_end = 0.0
    cur_words: list[str] = []
    for start, end, word in words:
        if not cur_words:
            cur_start, cur_end = start, end
            cur_words.append(word)
            continue
        gap = start - cur_end
        line_len = start - cur_start
        if gap > _SUB_MAX_GAP_SECONDS or line_len > _SUB_MAX_LINE_SECONDS:
            lines.append(_make_line(cur_start, cur_end, cur_words))
            cur_start, cur_end = start, end
            cur_words = [word]
        else:
            cur_end = end
            cur_words.append(word)
    if cur_words:
        lines.append(_make_line(cur_start, cur_end, cur_words))
    return lines


def _make_line(start: float, end: float, words: list[str]) -> dict:
    text = "".join(words).strip()
    if not text:
        # 空格开头的单词拼接后首字符可能是空格，strip 处理
        text = " ".join(w.strip() for w in words if w.strip())
    return {"start": round(start, 3), "end": round(end, 3), "text": text,
            "translation": ""}


def _to_srt(items: list[dict], key: str) -> str:
    lines: list[str] = []
    for i, it in enumerate(items, start=1):
        lines.append(str(i))
        lines.append(f"{_fmt_ts(it['start'])} --> {_fmt_ts(it['end'])}")
        lines.append(it.get(key) or "")
        lines.append("")
    return "\n".join(lines)


def _media_duration(path: str) -> float | None:
    """容器总时长（秒）；无法获取时返回 None。"""
    try:
        import av
        container = av.open(path)
        if container.duration is not None:
            return float(container.duration / av.time_base)
    except Exception:  # noqa: BLE001
        pass
    return None


def _process_batch_job(job: dict) -> None:
    try:
        src_path = Path(job["path"])
        job["status"] = "解码音频"
        video_duration = _media_duration(str(src_path))
        audio = _decode_audio(str(src_path))
        if audio.size < 16000:  # 不足 1 秒
            raise RuntimeError("音频过短（<1 秒）")
        duration = audio.size / 16000
        job["duration"] = round(duration, 1)
        if video_duration is not None:
            job["video_duration"] = round(video_duration, 1)
            log.info("[batch:%s] 视频 %.1fs / 音频 %.1fs",
                     job["id"], video_duration, duration)
        else:
            log.info("[batch:%s] 音频时长 %.1fs，开始识别", job["id"], duration)

        _ensure_nllb()
        job["status"] = "识别中"
        segments, info = _model.transcribe(
            audio,
            beam_size=5,
            vad_filter=True,
            # 离线批量启用跨句上下文（整段连贯转写，准确率更高；
            # 实时字幕路径禁用是为了避免短段间重复幻觉）
            condition_on_previous_text=True,
            word_timestamps=True,
        )
        # 按词级时间戳切分：停顿超过阈值即断句，长停顿期间不显示字幕
        items = _segments_to_lines(segments)
        if not items:
            raise RuntimeError("未识别到任何语音（文件可能无人声）")
        job["subtitle_count"] = len(items)
        for it in items:
            if it["end"] > duration:
                it["end"] = round(duration, 3)
            job["progress"] = round(min(0.5, it["end"] / duration), 3)

        job["status"] = "翻译中"
        from nllb_server import translate_text as nllb_translate

        total = len(items)
        for i, it in enumerate(items):
            try:
                it["translation"] = nllb_translate(
                    it["text"], job.get("source_lang"), job["target_lang"])
            except Exception:
                it["translation"] = it["text"]
            job["progress"] = round(0.5 + 0.5 * (i + 1) / total, 3)

        # 写出字幕：同名 .srt（播放器自动加载，内容为译文）与 .orig.srt（原文）
        base = src_path.with_suffix("")
        trans_path = Path(str(base) + ".srt")
        orig_path = Path(str(base) + ".orig.srt")
        trans_path.write_text(_to_srt(items, "translation"), encoding="utf-8")
        orig_path.write_text(_to_srt(items, "text"), encoding="utf-8")
        job["srt_path"] = str(trans_path)
        job["orig_srt_path"] = str(orig_path)
        job["status"] = "完成"
        job["progress"] = 1.0
        log.info("[batch:%s] 完成: %s（%d 条字幕）", job["id"], trans_path, len(items))
    except Exception as exc:  # noqa: BLE001
        job["status"] = "失败"
        job["error"] = str(exc)
        log.exception("[batch:%s] 失败", job.get("id", "?"))


def _batch_worker() -> None:
    while True:
        with _BATCH_LOCK:
            pending = [j for j in BATCH_JOBS.values() if j["status"] == "排队中"]
            job = pending[0] if pending else None
        if job is None:
            break
        _process_batch_job(job)


def _kick_worker() -> None:
    global _batch_worker_thread
    if _batch_worker_thread is None or not _batch_worker_thread.is_alive():
        _batch_worker_thread = threading.Thread(target=_batch_worker, daemon=True)
        _batch_worker_thread.start()


@app.post("/batch/transcribe")
def batch_transcribe(req: BatchRequest) -> dict:
    src_path = Path(req.path)
    if not src_path.exists():
        raise HTTPException(status_code=404, detail="文件不存在: " + req.path)
    job_id = uuid4().hex[:12]
    with _BATCH_LOCK:
        BATCH_JOBS[job_id] = {
            "id": job_id,
            "path": str(src_path),
            "file_name": src_path.name,
            "status": "排队中",
            "progress": 0.0,
            "target_lang": req.target_lang,
            "source_lang": req.source_lang,
        }
    _kick_worker()
    return {"job_id": job_id}


@app.get("/batch/status")
def batch_status(job_id: str) -> dict:
    with _BATCH_LOCK:
        job = BATCH_JOBS.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="任务不存在: " + job_id)
        return dict(job)


@app.get("/batch/jobs")
def batch_jobs() -> dict:
    with _BATCH_LOCK:
        return {"jobs": [dict(j) for j in BATCH_JOBS.values()]}


def main() -> None:
    parser = argparse.ArgumentParser(description="faster-whisper local STT server")
    parser.add_argument("--model", default="Systran/faster-whisper-large-v3",
                        help="HF 模型名")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--device", default="auto", choices=["auto", "cuda", "cpu"])
    parser.add_argument("--compute-type", default="float16",
                        help="CUDA: float16 / int8_float16；CPU: int8")
    args = parser.parse_args()

    load_model(args.model, args.device, args.compute_type)
    log.info("监听 http://127.0.0.1:%d（/health /v1/audio/transcriptions /batch/*）", args.port)
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="info")


if __name__ == "__main__":
    sys.exit(main())
