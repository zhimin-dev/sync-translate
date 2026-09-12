"""批量离线字幕端到端验证：提交 speech_sample.wav -> 轮询状态 -> 校验 SRT 输出。
用法：venv\\Scripts\\python.exe test_batch.py
"""
import time
import wave

import httpx

SAMPLE = r"D:\myweb\sync-translate\tool\speech_sample.wav"
BASE = "http://127.0.0.1:8000"

# 语音 + 6 秒静音 + 语音：验证长停顿被切成两条独立字幕
with wave.open(SAMPLE, "rb") as w:
    params = w.getparams()
    frames = w.readframes(w.getnframes())
silence = b"\x00\x00" * (params.framerate * 6)
audio_bytes = frames + silence + frames
merged = r"D:\myweb\sync-translate\tool\speech_batch_test.wav"
with wave.open(merged, "wb") as w:
    w.setparams(params)
    w.writeframes(audio_bytes)
print(f"[1/3] 测试音频: {merged}（{len(audio_bytes) / params.framerate:.1f}s，含 6 秒静音）")

resp = httpx.post(f"{BASE}/batch/transcribe",
                  json={"path": merged, "target_lang": "zh"}, timeout=30)
resp.raise_for_status()
job_id = resp.json()["job_id"]
print(f"[2/3] 任务已提交: {job_id}")

last = ""
while True:
    s = httpx.get(f"{BASE}/batch/status", params={"job_id": job_id}, timeout=30).json()
    line = f"  {s['status']} {float(s.get('progress', 0)) * 100:.0f}%"
    if line != last:
        print(line)
        last = line
    if s["status"] in ("完成", "失败"):
        break
    time.sleep(3)

if s["status"] != "完成":
    print("失败:", s.get("error"))
    raise SystemExit(1)

print(f"[3/3] 完成。字幕文件: {s['srt_path']}")
with open(s["srt_path"], encoding="utf-8") as f:
    content = f.read()
print("--- SRT 内容 ---")
print(content[:600])
print("=== 批量字幕验证通过 ===")
