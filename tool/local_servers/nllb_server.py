"""NLLB-200 本地翻译服务（sync-translate 专用）。

- transformers + PyTorch 加载官方 facebook/nllb-200-distilled-600M，优先 CUDA，回退 CPU
- HTTP 接口：
    GET  /health                    -> {"ok": true, "device": "cuda"}
    POST /translate                 -> {"translation": "..."}
        {"text": "...", "source_lang": "en", "target_lang": "zh"}

运行：venv\\Scripts\\python.exe nllb_server.py [--model-dir 模型目录] [--port 8765] [--device cuda|cpu|auto]
"""

import argparse
import logging
import os
import sys
from pathlib import Path

MODELS_ROOT = Path(__file__).resolve().parent / "models"
DEFAULT_MODEL_DIR = MODELS_ROOT / "facebook--nllb-200-distilled-600M"

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
AUTO = "eng_Latn"  # 源语言未知时默认按英语处理

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nllb-server")

_tokenizer = None
_model = None
_device_name = "not-loaded"
_model_name = ""


def load_model(model_dir: Path, device: str) -> None:
    global _tokenizer, _model, _device_name, _model_name
    _model_name = str(model_dir)
    import torch  # noqa: F401  (延迟导入，加快 --help 等路径)
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

    if device == "auto":
        device = "cuda" if torch.cuda.is_available() else "cpu"
    log.info("加载 NLLB 模型: %s，设备=%s", model_dir, device)
    _tokenizer = AutoTokenizer.from_pretrained(str(model_dir))
    _model = AutoModelForSeq2SeqLM.from_pretrained(str(model_dir))
    if device == "cuda":
        _model = _model.half().to("cuda")
    else:
        _model = _model.to("cpu")
    _model.eval()
    _device_name = device
    log.info("NLLB 模型已加载（%s）", device)


def translate_text(text: str, source_lang: str | None, target_lang: str) -> str:
    import torch

    src_code = LANG_MAP.get(source_lang, AUTO) if source_lang and source_lang not in ("auto", "") else AUTO
    tgt_code = LANG_MAP.get(target_lang, target_lang)
    # NLLB tokenizer 需要显式设置语言，自动加上语言前缀 token
    _tokenizer.src_lang = src_code
    _tokenizer.tgt_lang = tgt_code
    inputs = _tokenizer(text, return_tensors="pt", truncation=True, max_length=256)
    if _device_name == "cuda":
        inputs = {k: v.to("cuda") for k, v in inputs.items()}
    with torch.no_grad():
        outputs = _model.generate(
            **inputs,
            max_new_tokens=160,
            num_beams=1,
            forced_bos_token_id=_tokenizer.convert_tokens_to_ids(tgt_code),
        )
    return _tokenizer.batch_decode(outputs, skip_special_tokens=True)[0].strip()


# ---- FastAPI ----
import uvicorn  # noqa: E402
from fastapi import FastAPI, HTTPException  # noqa: E402
from pydantic import BaseModel  # noqa: E402

app = FastAPI(title="NLLB-200 local translation service")


class TranslateRequest(BaseModel):
    text: str
    source_lang: str | None = None
    target_lang: str = "zh"


class TranslateResponse(BaseModel):
    translation: str


@app.get("/health")
def health() -> dict:
    return {"ok": _model is not None, "device": _device_name,
            "model": _model_name}


@app.post("/translate", response_model=TranslateResponse)
def translate(req: TranslateRequest) -> TranslateResponse:
    if _model is None:
        raise HTTPException(status_code=503, detail="model not loaded")
    text = req.text.strip()
    if not text:
        return TranslateResponse(translation="")
    return TranslateResponse(
        translation=translate_text(text, req.source_lang, req.target_lang))


def main() -> None:
    parser = argparse.ArgumentParser(description="NLLB-200 local translation server")
    parser.add_argument("--model-dir", default=str(DEFAULT_MODEL_DIR))
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--device", default="auto", choices=["auto", "cuda", "cpu"])
    args = parser.parse_args()

    model_dir = Path(args.model_dir)
    if not (model_dir / "pytorch_model.bin").exists():
        log.error("模型文件缺失: %s（请先运行 download_models.ps1）",
                  model_dir / "pytorch_model.bin")
        sys.exit(1)

    load_model(model_dir, args.device)
    log.info("监听 http://127.0.0.1:%d（/health /translate）", args.port)
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="info")


if __name__ == "__main__":
    sys.exit(main())
