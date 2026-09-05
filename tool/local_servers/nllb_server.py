"""NLLB-200 本地翻译服务（sync-translate 专用）。

- CTranslate2 加载 facebook/nllb-200-distilled-* 模型，优先 CUDA，自动回退 CPU
- HTTP 接口：
    GET  /health                    -> {"ok": true, "device": "cuda"}
    POST /translate                 -> {"translation": "..."}
        {"text": "...", "source_lang": "en", "target_lang": "zh"}

运行：venv\\Scripts\\python.exe nllb_server.py [--model nllb-200-distilled-600M]
                                 [--port 8765] [--device cuda|cpu|auto]
国内网络自动使用 hf-mirror.com 下载模型。
"""

import argparse
import logging
import os
import sys

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

import ctranslate2  # noqa: E402
import sentencepiece as spm  # noqa: E402
import uvicorn  # noqa: E402
from fastapi import FastAPI, HTTPException  # noqa: E402
from huggingface_hub import hf_hub_download  # noqa: E402
from pydantic import BaseModel  # noqa: E402

# ISO 639-1 -> NLLB flores200 代码（应用层语言码）
LANG_MAP = {
    "zh": "zho_Hans", "zh-hans": "zho_Hans", "zh-hant": "zho_Hant",
    "en": "eng_Latn", "ja": "jpn_Jpan", "ko": "kor_Hang",
    "fr": "fra_Latn", "de": "deu_Latn", "es": "spa_Latn",
    "ru": "rus_Cyrl", "pt": "por_Latn", "it": "ita_Latn",
    "ar": "arb_Arab", "hi": "hin_Deva", "th": "tha_Thai",
    "vi": "vie_Latn", "id": "ind_Latn", "tr": "tur_Latn",
    "nl": "nld_Latn", "pl": "pol_Latn", "uk": "ukr_Cyrl",
    "cs": "ces_Latn", "fi": "fin_Latn", "sv": "swe_Latn",
    "da": "dan_Latn", "no": "nob_Latn", "el": "ell_Grek",
    "he": "heb_Hebr", "fa": "pes_Arab", "bn": "ben_Beng",
    "ms": "zsm_Latn", "ta": "tam_Taml", "te": "tel_Telu",
    "ur": "urd_Arab", "sw": "swh_Latn", "ro": "ron_Latn",
    "hu": "hun_Latn", "bg": "bul_Cyrl", "sr": "srp_Cyrl",
}

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nllb-server")

app = FastAPI(title="NLLB-200 local translation service")
_translator = None
_sp = None
_device_name = "not-loaded"


class TranslateRequest(BaseModel):
    text: str
    source_lang: str | None = None
    target_lang: str = "zh"


class TranslateResponse(BaseModel):
    translation: str


def load_model(model_name: str, device: str, compute_type: str) -> None:
    global _translator, _sp, _device_name
    repo = f"facebook/{model_name}"
    log.info("下载/加载 tokenizer: %s", repo)
    spm_path = hf_hub_download(repo_id=repo, filename="sentencepiece.bpe.model")
    _sp = spm.SentencePieceProcessor(model_file=spm_path)

    if device == "auto":
        device = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"

    try:
        _translator = ctranslate2.Translator(repo, device=device, compute_type=compute_type)
        _device_name = _translator.device
        log.info("NLLB 模型已加载: %s，设备=%s，compute_type=%s",
                 repo, _translator.device, _translator.compute_type)
    except Exception as exc:  # GPU 初始化失败时回退 CPU
        log.warning("GPU 初始化失败（%s），回退 CPU", exc)
        _translator = ctranslate2.Translator(repo, device="cpu", compute_type="int8")
        _device_name = _translator.device
        log.info("NLLB 模型已加载（CPU 回退）: %s", repo)


@app.get("/health")
def health() -> dict:
    return {"ok": _translator is not None, "device": _device_name}


@app.post("/translate", response_model=TranslateResponse)
def translate(req: TranslateRequest) -> TranslateResponse:
    if _translator is None:
        raise HTTPException(status_code=503, detail="model not loaded")
    text = req.text.strip()
    if not text:
        return TranslateResponse(translation="")

    target_code = LANG_MAP.get(req.target_lang, req.target_lang)
    source_code = (
        LANG_MAP.get(req.source_lang, req.source_lang)
        if req.source_lang and req.source_lang not in ("auto", "")
        else None
    )

    source_tokens = _sp.encode(text, out_type=str)
    # NLLB 只需目标语言前缀（flores200 代码）
    results = _translator.translate_batch(
        [source_tokens],
        target_prefix=[[target_code]],
        beam_size=1,
        max_batch_size=1,
    )
    out_tokens = results[0].hypotheses[0]
    translation = _sp.decode(out_tokens)
    return TranslateResponse(translation=translation)


def main() -> None:
    parser = argparse.ArgumentParser(description="NLLB-200 local translation server")
    parser.add_argument("--model", default="nllb-200-distilled-600M",
                        help="HF 模型名（facebook/ 前缀可省略）")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--device", default="auto", choices=["auto", "cuda", "cpu"])
    parser.add_argument("--compute-type", default="int8_float16",
                        help="CUDA: int8_float16 / float16；CPU: int8")
    args = parser.parse_args()

    load_model(args.model, args.device, args.compute_type)
    log.info("监听 http://127.0.0.1:%d（/health /translate）", args.port)
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="info")


if __name__ == "__main__":
    sys.exit(main())
