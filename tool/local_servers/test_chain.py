"""验证本地链路（不含采集层）：语音样本 -> faster-whisper -> NLLB-200。
用法：venv\\Scripts\\python.exe test_chain.py
"""
import io
import struct
import wave

import av
import httpx

SAMPLE = r"D:\myweb\sync-translate\tool\speech_sample.wav"

# 1) 把任意采样率的语音样本转成 16kHz 单声道 PCM16
container = av.open(SAMPLE)
resampler = av.AudioResampler(format="s16", layout="mono", rate=16000)
chunks = []
for frame in container.decode(audio=0):
    for out in resampler.resample(frame):
        chunks.append(bytes(out.planes[0]))
pcm = b"".join(chunks)

buf = io.BytesIO()
with wave.open(buf, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(16000)
    w.writeframes(pcm)
wav_bytes = buf.getvalue()
print(f"[1/3] 语音样本: {len(pcm) / 16000:.1f}s @16kHz")

# 2) faster-whisper 识别
resp = httpx.post(
    "http://127.0.0.1:8000/v1/audio/transcriptions",
    files={"file": ("audio.wav", wav_bytes, "audio/wav")},
    data={"model": "turbo", "response_format": "json"},
    timeout=120,
)
resp.raise_for_status()
text = resp.json()["text"].strip()
print(f"[2/3] 识别结果: {text!r}")

# 3) NLLB 翻译
resp2 = httpx.post(
    "http://127.0.0.1:8765/translate",
    json={"text": text, "source_lang": "en", "target_lang": "zh"},
    timeout=120,
)
resp2.raise_for_status()
print(f"[3/3] 翻译结果: {resp2.json()['translation']!r}")
print("=== 本地链路验证通过 ===")
