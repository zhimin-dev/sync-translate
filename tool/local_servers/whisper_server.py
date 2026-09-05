"""faster-whisper 本地语音识别服务（sync-translate 专用，OpenAI 兼容）。

- faster-whisper（CTranslate2 内核），优先 CUDA，自动回退 CPU
- HTTP 接口（与 OpenAI /audio/transcriptions 对齐）：
    GET  /health                    -> {"ok": true, "device": "cuda"}
    POST /v1/audio/transcriptions   multipart: file=audio.wav, model, language, response_format
                                    -> {"text": "..."}

运行：venv\\Scripts\\python.exe whisper_server.py [--model deepdml/faster-whisper-large-v3-turbo-ct2]
                                [--port 8000] [--device cuda|cpu|auto]
国内网络自动使用 hf-mirror.com 下载模型。
"""

import argparse
import logging
import os
import sys
from pathlib import Path

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

# 注册 NVIDIA cuDNN/cuBLAS 运行库路径（ctranslate2 GPU 推理依赖）
_NVIDIA_BASE = Path(__file__).resolve().parent / "venv" / "Lib" / "site-packages" / "nvidia"
for _dll_dir in (_NVIDIA_BASE / "cudnn" / "bin", _NVIDIA_BASE / "cublas" / "bin"):
    if _dll_dir.is_dir():
        os.add_dll_directory(str(_dll_dir))

import numpy as np  # noqa: E402
import uvicorn  # noqa: E402
from fastapi import FastAPI, File, Form, UploadFile  # noqa: E402
from faster_whisper import WhisperModel  # noqa: E402

MODELS_ROOT = Path(__file__).resolve().parent / "models"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("whisper-server")

app = FastAPI(title="faster-whisper local STT service")
_model = None
_device_name = "not-loaded"


def load_model(model_name: str, device: str, compute_type: str) -> None:
    global _model, _device_name
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
    return {"ok": _model is not None, "device": _device_name}


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(""),
    language: str = Form(""),
    response_format: str = Form("json"),
) -> dict:
    if _model is None:
        return {"error": "model not loaded"}
    raw = await file.read()
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


def main() -> None:
    parser = argparse.ArgumentParser(description="faster-whisper local STT server")
    parser.add_argument("--model", default="deepdml/faster-whisper-large-v3-turbo-ct2",
                        help="HF 模型名")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--device", default="auto", choices=["auto", "cuda", "cpu"])
    parser.add_argument("--compute-type", default="float16",
                        help="CUDA: float16 / int8_float16；CPU: int8")
    args = parser.parse_args()

    load_model(args.model, args.device, args.compute_type)
    log.info("监听 http://127.0.0.1:%d（/health /v1/audio/transcriptions）", args.port)
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="info")


if __name__ == "__main__":
    sys.exit(main())
