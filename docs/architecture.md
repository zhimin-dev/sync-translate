# sync-translate 架构文档

> 系统音频/麦克风 → 实时语音识别 → 实时翻译 → 屏幕悬浮双语字幕

## 1. 目标与范围

| 平台 | 状态 | 音频采集方案 |
|---|---|---|
| Windows | ✅ MVP 目标（本次会话） | WASAPI 回环采集（loopback），麦克风走 WASAPI eCapture，均无需特殊权限 |
| Android | 🧱 工程骨架 + 接口预留 | Android 10+ `AudioPlaybackCapture`（需 MediaProjection 用户授权）；麦克风 `AudioRecord` |
| macOS | 🧱 工程骨架 + 接口预留 | ScreenCaptureKit（需"屏幕录制"权限；音频流随屏幕内容采集，macOS 14.2+ 支持音频专用流） |

## 2. 总体架构

```
┌─────────────────────────── 设备 / 系统 ───────────────────────────┐
│  系统音频输出 (Windows: WASAPI loopback) / 麦克风                    │
└───────────────────────────────┬───────────────────────────────────┘
                                │ 原始 PCM (设备采样率, 如 48kHz 浮点)
┌───────────────────────────────▼───────────────────────────────────┐
│  原生采集层 (windows/runner/native/wasapi_capture.cpp)              │
│  ・WASAPI IAudioClient → 下混为单声道 float32 → SPSC 环形缓冲        │
│  ・导出 C API: wasapi_start/read/stop/last_error                   │
└───────────────────────────────┬───────────────────────────────────┘
                                │ dart:ffi 轮询 (100ms)
┌───────────────────────────────▼───────────────────────────────────┐
│  AudioCapture 抽象 (lib/core/audio/)                               │
│  ・Windows: FFI 实现；Android/macOS: 占位实现（见 platform-audio）   │
│  ・重采样 48kHz→16kHz 单声道（线性插值，STT 标准输入）                │
└───────────────────────────────┬───────────────────────────────────┘
                                │ PCM16k 流
┌───────────────────────────────▼───────────────────────────────────┐
│  分段器 VadSegmenter (lib/core/pipeline/)                          │
│  ・能量 VAD：RMS 短时窗 → 静音 450ms 切段，最短 300ms（提速调优）    │
└───────────────────────────────┬───────────────────────────────────┘
                                │ 语音片段
┌───────────────────────────────▼───────────────────────────────────┐
│  STT 引擎 SttEngine (lib/core/stt/)        可插拔                  │
│  ・OpenAI 兼容 /audio/transcriptions（Groq/OpenAI/SiliconFlow…）    │
│  ・本地引擎接口预留（whisper.cpp）                                   │
└───────────────────────────────┬───────────────────────────────────┘
                                │ 原文文本
┌───────────────────────────────▼───────────────────────────────────┐
│  翻译引擎 Translator (lib/core/translate/)     可插拔              │
│  ・LLM /chat/completions（OpenAI/DeepSeek/…/Ollama 本地）           │
│  ・本地引擎接口预留（NLLB / OPUS-MT）                                │
└───────────────────────────────┬───────────────────────────────────┘
                                │ 译文
┌───────────────────────────────▼───────────────────────────────────┐
│  字幕状态 SubtitleController → Overlay UI                          │
│  ・置顶、半透明、可拖动；原文+译文双行；保留最近 N 条                 │
└───────────────────────────────────────────────────────────────────┘
```

## 3. 模块划分（lib/）

```
lib/
├── main.dart / app.dart
├── core/
│   ├── audio/           采集抽象 + 各平台实现 + 重采样
│   ├── stt/             SttEngine 接口 + OpenAI 兼容实现 + 本地占位
│   ├── translate/       Translator 接口 + LLM 实现 + 本地占位
│   ├── pipeline/        分段器 + 翻译流水线 + 字幕状态
│   ├── config/          配置模型 + JSON 持久化（应用数据目录）
│   └── overlay/         悬浮窗窗口控制
├── ffi/                 dart:ffi 绑定（wasapi_bindings.dart）
└── ui/                  悬浮字幕视图 / 设置面板
```

## 4. 可插拔引擎设计

两个核心接口均以"引擎 ID + 配置"方式通过工厂创建：

```dart
abstract class SttEngine {
  String get id;
  Future<void> init(SttConfig config);
  /// 输入 16kHz 单声道 PCM（float），返回识别文本
  Future<String> transcribe(Float32List pcm16k);
  Future<void> dispose();
}

abstract class Translator {
  String get id;
  Future<void> init(TranslatorConfig config);
  Future<String> translate(String text, {String? sourceLang, String? targetLang});
  Future<void> dispose();
}
```

| 引擎 | 类型 | 说明 |
|---|---|---|
| `openai_compat` STT | 云端 | `POST {baseUrl}/audio/transcriptions`，兼容 OpenAI/Groq/SiliconFlow/DeepInfra 等 |
| `llm` 翻译 | 云端/本地 | `POST {baseUrl}/chat/completions`；baseUrl 指向 `http://localhost:11434/v1` 即 Ollama 本地模型 |
| `whisper_local` STT | 本地 | 接口已预留，计划 whisper.cpp + FFI |
| `nllb_local` 翻译 | 本地 | 接口已预留，计划 CT2/NLLB + FFI |

选择"混合"策略的原因：云端实时性最好；本地引擎可通过同一套 OpenAI 兼容协议（Ollama/LM Studio/whisper.cpp server）先行接入，无需另写原生绑定。

## 5. 延迟预算（Windows MVP）

| 环节 | 典型延迟 |
|---|---|
| WASAPI 缓冲 + FFI 轮询 | ~200ms |
| 分段（最短语音段） | 500ms |
| 云端 STT（Groq whisper-large-v3-turbo 等） | 0.5–2s |
| 云端翻译（LLM） | 0.3–1.5s |
| **合计（首字→译文上屏）** | **~1.5–4s** |

后续优化方向：流式 STT（WebSocket 部分结果）+ 逐句增量翻译，可把上屏延迟压到 1s 内。

## 6. 配置持久化

`AppConfig` JSON 保存于 `path_provider` 应用支持目录：

```json
{
  "stt": { "engine": "openai_compat", "baseUrl": "https://api.groq.com/openai/v1",
           "apiKey": "…", "model": "whisper-large-v3-turbo", "language": "auto" },
  "translate": { "engine": "llm", "baseUrl": "https://api.deepseek.com/v1",
                 "apiKey": "…", "model": "deepseek-chat",
                 "sourceLang": "auto", "targetLang": "zh" },
  "capture": { "mode": "system" },
  "overlay": { "opacity": 0.85, "fontSize": 18, "maxLines": 4, "alwaysOnTop": true }
}
```

## 7. 路线图

1. ✅ Windows MVP：WASAPI 采集 → 分段 → 云端 STT → LLM 翻译 → 悬浮窗
2. Android：MediaProjection + AudioPlaybackCapture（API 29+）、`SYSTEM_ALERT_WINDOW` 悬浮窗、前台服务
3. macOS：ScreenCaptureKit 采集（14.2+ 音频流），TCC 权限引导
4. 流式 STT（Groq/Deepgram WebSocket）+ 增量翻译
5. 本地引擎落地（whisper.cpp / NLLB）
6. 独立悬浮子窗口（脱离主窗口）、字幕历史导出

## 8. 关键参考

- macOS 系统音频采集：Apple Developer Forums — [ScreenCaptureKit audio-only 讨论](https://developer.apple.com/forums/thread/718279)
- Chromium macOS 回环采集实现参考：[audio_loopback_input_mac_impl.h](https://chromium.googlesource.com/chromium/src/media/+/c5a022ab4160b8c358a52ed49c263525587a1eb8/audio/mac/audio_loopback_input_mac_impl.h)
- Android 采集参考：[AudioPlaybackCaptureConfiguration（官方文档）](https://developer.android.com/guide/topics/media/playback-capture)
