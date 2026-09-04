# sync-translate 实时翻译字幕

捕获系统播放的声音（或麦克风）→ 语音识别 → 实时翻译 → 屏幕悬浮双语字幕。

- **平台**：Windows（✅ MVP 可用）/ Android、macOS（工程骨架与采集接口已预留）
- **框架**：Flutter 3.47 + 少量平台原生代码
- **架构**：STT 与翻译引擎可插拔（云端优先，本地引擎接口预留）

## 功能

- 系统声音采集：Windows WASAPI 回环（loopback），**无需任何权限**
- 麦克风采集：Windows WASAPI eCapture（首次使用触发系统麦克风授权）
- 实时分段：短时能量 VAD，静音自动切句
- 语音识别：OpenAI 兼容 `/audio/transcriptions`（OpenAI / Groq / SiliconFlow / whisper.cpp server…）
- 翻译：OpenAI 兼容 `/chat/completions`（DeepSeek / OpenAI / Ollama 本地模型…）
- 悬浮字幕：置顶、半透明、可拖动、原文+译文双行、保留最近 N 条
- 配置持久化：应用数据目录 `config.json`

## 快速开始（Windows）

### 1. 环境

- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows)（本项目用 3.47.x）
- Visual Studio 2022（含"使用 C++ 的桌面开发"工作负载）
- 国内网络建议配置镜像：
  ```powershell
  $env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
  $env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
  ```

### 2. 构建运行

```powershell
flutter pub get
flutter build windows --release
# 产物：build\windows\x64\runner\Release\sync_translate.exe
# 开发调试：flutter run -d windows
```

> ⚠️ 构建带原生插件的 Windows 工程时，Flutter 工具默认要求系统开启
> **开发者模式**（符号链接支持）。如果无法开启（如无管理员权限），
> 可用 junction 绕过（无需任何权限）：
> ```powershell
> # 依据 .flutter-plugins-dependencies 为每个 windows 插件建 junction
> New-Item -ItemType Directory -Force -Path windows\flutter\ephemeral\.plugin_symlinks
> cmd /c mklink /J windows\flutter\ephemeral\.plugin_symlinks\window_manager "C:\Users\<你>\AppData\Local\Pub\Cache\hosted\pub.flutter-io.cn\window_manager-0.5.2"
> # （path_provider_windows、screen_retriever_windows、jni 同理）
> ```

### 3. 配置引擎

首次启动在设置页填写：

| 引擎 | 服务商示例 | Base URL | 模型示例 |
|---|---|---|---|
| STT | Groq（免费额度，速度快） | `https://api.groq.com/openai/v1` | `whisper-large-v3-turbo` |
| STT | OpenAI | `https://api.openai.com/v1` | `whisper-1` / `gpt-4o-transcribe` |
| STT | SiliconFlow（国内） | `https://api.siliconflow.cn/v1` | `FunAudioLLM/SenseVoiceSmall` |
| STT | whisper.cpp server（本地） | `http://localhost:8080/v1` | `whisper-1` |
| 翻译 | DeepSeek（国内） | `https://api.deepseek.com/v1` | `deepseek-chat` |
| 翻译 | OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| 翻译 | Ollama（本地） | `http://localhost:11434/v1` | `qwen2.5:7b` 等 |

点击 **开始监听**，窗口自动切换为悬浮字幕形态（置顶半透明，Esc 返回设置）。

## 目录结构

```
lib/
├── main.dart / app.dart         入口、窗口双形态切换（设置 ↔ 悬浮字幕）
├── ffi/wasapi_bindings.dart     dart:ffi 绑定（wasapi_capture.dll）
├── core/
│   ├── audio/                   采集抽象 + WASAPI 实现 + Android/macOS 占位 + 重采样
│   ├── stt/                     SttEngine 接口 + OpenAI 兼容实现 + 本地占位
│   ├── translate/               Translator 接口 + LLM 实现 + 本地占位
│   ├── pipeline/                VAD 分段器 + 翻译流水线 + 字幕状态
│   ├── config/                  配置模型 + JSON 持久化
│   └── overlay/                 悬浮窗窗口控制
└── ui/                          settings_view / overlay_view
windows/runner/native/           WASAPI 采集 C++（ring_buffer.h / wasapi_capture.*）
docs/                            架构文档 / 三平台音频采集方案
test/                            重采样器与 VAD 单元测试
```

## 平台状态

| 平台 | 音频采集 | 悬浮窗 |
|---|---|---|
| Windows | ✅ WASAPI 回环 / 麦克风 | ✅ 置顶半透明窗口 |
| Android | 🧱 预留接口（AudioPlaybackCapture + MediaProjection，Android 10+） | 🧱 预留（SYSTEM_ALERT_WINDOW 已声明） |
| macOS | 🧱 预留接口（ScreenCaptureKit，macOS 13+，需屏幕录制权限） | 🧱 预留（window_manager 支持 macOS） |

详见 [docs/platform-audio.md](docs/platform-audio.md) 与 [docs/architecture.md](docs/architecture.md)。

## 常见问题

- **没有字幕出现？** 先确认扬声器正在播放声音；VAD 阈值默认 0.008，可把音量调大验证。
- **STT 报 401？** API Key 或 Base URL 不对（Base URL 需包含 `/v1` 或由服务商文档确定）。
- **识别延迟 2~5 秒属正常**：分段（≥0.5s）+ 云端往返。流式 STT 在路线图中。
- **Groq/OpenAI 无法访问（国内）？** 换 SiliconFlow 等国内服务，或本地 whisper.cpp server。

## 路线图

1. Android：MediaProjection + AudioPlaybackCapture、悬浮窗、前台服务
2. macOS：ScreenCaptureKit 采集 + TCC 权限引导
3. 流式 STT（WebSocket 部分结果）+ 逐句增量翻译，上屏延迟压到 1s 内
4. 本地引擎落地（whisper.cpp / NLLB）
5. 独立悬浮子窗口（脱离主窗口）、字幕历史导出

## 许可

仅供学习与个人使用。使用系统音频采集与云端服务时请遵守当地法律法规及服务商条款。
