# sync-translate 实时翻译字幕

捕获系统播放的声音（或麦克风）→ 语音识别 → 实时翻译 → 屏幕悬浮双语字幕。

- **平台**：Windows（✅ MVP 可用）/ Android、macOS（工程骨架与采集接口已预留）
- **框架**：Flutter 3.47 + 少量平台原生代码
- **架构**：STT 与翻译引擎可插拔（云端 / 本地均可，本地免 API Key）

## 功能

- 系统声音采集：Windows WASAPI 回环（loopback），**无需任何权限**
- 麦克风采集：Windows WASAPI eCapture（首次使用触发系统麦克风授权）
- 实时分段：短时能量 VAD，静音自动切句（提速调优：静音 450ms 切句 / 最短 300ms）
- 语音识别（可插拔）：**本地 faster-whisper（GPU 加速，免 Key）** / OpenAI 兼容接口（OpenAI / Groq / SiliconFlow…）
- 翻译（可插拔）：**本地 NLLB-200（免 Key）** / LLM（DeepSeek / OpenAI / Ollama…）
- 悬浮字幕：置顶、半透明、可拖动、**原文先行上屏**、译文随后补上、保留最近 N 条
- **边听边出**：说话过程中每 ~0.8s 滚动更新草稿字幕，说完后最终结果覆盖
- **批量字幕**：导入音视频或现成 SRT → 使用设置中的翻译模型 → 生成 SRT，异步排队处理；AI 翻译参考前后文，本地 NLLB 可离线使用
- 系统托盘常驻：关闭窗口隐藏到托盘，右键托盘图标退出
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

### 3. 配置引擎与使用

#### 方案 A：本地模型（推荐，免 Key、数据不出本机、GPU 加速、后端自动拉起）

**一次性准备**（第一次使用这台电脑时执行，约 10~30 分钟，含模型下载）：

```powershell
# 1. 安装后端依赖（自动选择标准版 Python 3.11，创建 venv）
powershell -ExecutionPolicy Bypass -File tool\local_servers\setup.ps1

# 2. 下载两个模型（faster-whisper-large-v3-turbo ~1.5GB + NLLB-200 600M ~2.4GB，支持断点续传）
powershell -ExecutionPolicy Bypass -File tool\local_servers\download_models.ps1
```

**日常使用（零后端操作）**：

1. 双击 `sync_translate.exe`
2. 设置页选择 STT 引擎「本地 Whisper（faster-whisper，免 Key）」、翻译引擎「本地 NLLB-200（免 Key）」（切换时自动填好默认地址）
3. 点 **开始监听** —— 应用会**自动检测并在后台拉起两个本地服务**（首次启动服务要等模型加载约 10~30 秒，之后秒开），无需开任何终端

> 后端是应用自动管理的：服务已在运行就直接复用；没运行就隐藏窗口启动并等它就绪。
> 服务日志在 `tool\local_servers\logs\*.log`；服务进程为后台 python，随系统重启需应用再次点"开始监听"自动拉起。

**手动管理后端（可选）**：

```powershell
# 一键启动两个服务（各开一个日志窗口，关窗口即停服务）
tool\local_servers\start_servers.bat

# 或分别启动
powershell -ExecutionPolicy Bypass -File tool\local_servers\start_whisper.ps1   # STT  http://127.0.0.1:8000/v1
powershell -ExecutionPolicy Bypass -File tool\local_servers\start_nllb.ps1     # 翻译 http://127.0.0.1:8765
```

- STT：faster-whisper（CTranslate2，RTX 4060 Ti 实测 6 秒音频约 1 秒识别）
- 翻译：官方 facebook/nllb-200-distilled-600M（PyTorch + transformers，CUDA，亚秒级）
- 链路自检：`venv\Scripts\python.exe tool\local_servers\test_chain.py`
- 纯 CPU 也能跑（略慢）。识别模型可编辑 `start_whisper.ps1` 换成 small/medium

#### 方案 B：云端引擎（无需本地后端）

首次启动在设置页填写：

| 引擎 | 服务商示例 | Base URL | 模型示例 |
|---|---|---|---|
| STT | Groq（免费额度，速度快） | `https://api.groq.com/openai/v1` | `whisper-large-v3-turbo` |
| STT | SiliconFlow（国内） | `https://api.siliconflow.cn/v1` | `FunAudioLLM/SenseVoiceSmall` |
| 翻译 | DeepSeek（国内） | `https://api.deepseek.com/v1` | `deepseek-chat` |
| 翻译 | SiliconFlow（国内） | `https://api.siliconflow.cn/v1` | `deepseek-ai/DeepSeek-V3` |

点击 **开始监听**，窗口自动切换为悬浮字幕形态（置顶半透明，Esc 返回设置）。

### 4. 批量字幕（音视频 / 原文 SRT → 译文 SRT）

通过托盘菜单进入批量字幕页：

1. 点 **添加音视频文件**（可多选，支持 mp4/mkv/avi/mov/wav/mp3/flac 等）
2. 点 **开始批量翻译** → 本地服务自动拉起，任务排队异步处理（可关闭窗口，托盘常驻继续跑）
3. 完成后在视频同目录生成：
   - `<视频名>.srt` —— 译文字幕（PotPlayer 等播放器**自动加载**同名 srt）
   - `<视频名>.orig.srt` —— 原文字幕（可手动加载对照）
4. 每个任务显示进度（解码 → 识别 → 翻译），完成后可一键「打开目录」

已有原文字幕时，切换 **SRT 翻译**，导入 `.srt` 即可，无需重新识别视频。
结果保存为 `<原字幕名>.<目标语言>.srt`，保留每条字幕的起止时间，不修改原文件。

翻译使用设置页中选定的引擎、主模型和源/目标语言：

- **AI 翻译**：按段处理（通常每段最多 12 条），带最近 6 条原文/译文和后续 3 条原文；长文本会缩小窗口。可在「视频背景与术语约定」填写题材、人物译名或专业词汇。字幕文本会发送至配置的 API，并产生相应服务费用。
- **译后校对**：批量 AI 翻译默认开启，初译后再对照原文核对跨行否定、漏译和表达，每段额外调用一次所选主模型。可在设置关闭以减少耗时和费用。校对失败时保留初译并提示复核；日文残留和长串重复仅作为疑点，不机械删除原文内容。该流程仍不能保证语义完全正确。
- **本地 NLLB**：保留完全离线的逐条翻译方式，不支持背景提示和上下文翻译。SRT 源语言建议明确指定；自动模式下 NLLB 按英语处理。视频则使用 Whisper 检测的源语言。
- AI 输出会校验字幕编号、数量及空译文，格式异常会重试一次。网络暂时失败也有有限重试；最终失败时显示错误。结构校验不能保证每句语义正确，重要内容仍需对照原文。
- 本地 NLLB 单条返回空译文时重试一次；仍为空则保留该条原文，继续翻译后续字幕并正常导出 SRT。任务显示「完成（需复核）」及条目提示，状态接口的 `untranslated_indices` 返回全部待补译序号，`translation_warnings` 返回具体复核原因。模型加载或推理异常仍会报告失败。
- 视频识别后立即保存 `.orig.srt`，即使翻译失败也可用这份字幕重新翻译。

批量任务仍需要本地 Python 字幕服务；选择云端翻译时无需加载 NLLB。
更新代码后请重启已运行的 `whisper_server.py`；旧服务不支持按设置选择 AI 模型，应用会提示重启。

每个任务会显示实际运行的翻译引擎与模型请求值（`translation_engine`、`translation_model`），避免把设置页当前选项误认为历史任务所用引擎。批量翻译使用主「翻译模型」；「快速模型」只用于实时临时字幕。模型请求值不能独立验证服务商实际部署的底层模型。

翻译回归测试（模拟 API，无需模型权重或真实 API Key）：

```sh
python -m unittest discover -s tool/local_servers -p 'test_*translation.py'
flutter test test/translator_llm_test.dart
```

Python 集成测试依赖 `fastapi`、`uvicorn`、`python-multipart`、`httpx`、`numpy`；纯翻译测试 `test_subtitle_translation.py` 只需 Python 标准库。

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
