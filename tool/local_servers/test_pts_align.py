"""验证批量解码的 PTS 时间轴对齐（纯逻辑单测，无需编码器）：
模拟音频帧：0-2s 无帧（起始偏移）、2-4s 有声、4-5s 空隙、5-7s 有声、7-8s 无帧。
拼装后应保持 8 秒总长，能量段位置与 PTS 一致（后半段字幕漂移的修复验证）。
用法：venv\\Scripts\\python.exe test_pts_align.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import whisper_server  # noqa: E402

SR = 16000


def sine(seconds: float) -> np.ndarray:
    n = int(seconds * SR)
    return (0.5 * np.sin(2 * np.pi * 440 * np.arange(n) / SR)).astype(np.float32)


def main() -> None:
    frames = [
        (2.0, sine(2.0)),  # 2-4s 有声段 1
        (5.0, sine(2.0)),  # 5-7s 有声段 2（中间 4-5s 为 PTS 空隙）
    ]
    audio = whisper_server._assemble_audio(frames, SR)
    total = audio.size / SR
    # 音频结束于最后一帧的末尾（7.0s）：尾部不会凭空延长
    print(f"拼装总长: {total:.2f}s（预期 ~7.0s：2s 前导静音 + 2s 有声 + 1s 空隙 + 2s 有声）")

    def rms(start: float, end: float) -> float:
        seg = audio[int(start * SR):int(end * SR)]
        return float(np.sqrt(np.mean(seg ** 2))) if seg.size else 0.0

    segs = [("0-2s 前导静音（起始偏移补齐）", 0.0, 2.0),
            ("2-4s 有声段1", 2.0, 4.0),
            ("4-5s 空隙（帧间补齐）", 4.0, 5.0),
            ("5-7s 有声段2", 5.0, 7.0)]
    ok = True
    for name, s, e in segs:
        v = rms(s, e)
        print(f"  {name}: RMS={v:.4f}")
        if "有声段" in name:
            if v < 0.1:
                ok = False
        else:
            if v > 0.02:
                ok = False
    if abs(total - 7.0) > 0.3:
        ok = False
    print("PTS 对齐验证:", "通过" if ok else "失败")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
