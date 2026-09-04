# 三平台音频采集方案详解

统一目标：每平台产出 **16kHz 单声道 float32 PCM** 流，交给上层分段器。

## Windows（本次 MVP）

**技术**：WASAPI `IAudioClient` + `IAudioCaptureClient`。

- 系统声音：`GetDefaultAudioEndpoint(eRender, eConsole)` + `Initialize(..., AUDCLNT_STREAMFLAGS_LOOPBACK, ...)`，**无需任何权限**，Windows 8+ 均可。
- 麦克风：`GetDefaultAudioEndpoint(eCapture, eConsole)`，首次使用时系统自动触发麦克风隐私授权；设置里被禁用时 `GetBuffer` 会返回静音。
- 实现要点（`windows/runner/native/wasapi_capture.cpp`）：
  1. `GetMixFormat` 取设备混合格式（通常 48kHz/float32/立体声，也可能是 44.1k/int16），**共享模式必须用该格式初始化**；
  2. 捕获线程用 `GetNextPacketSize` 轮询（loopback 不支持事件驱动），`Pro Audio` MMCSS 优先级；
  3. 多声道下混为单声道（float 或 int16 → float32）；
  4. 写入 SPSC 环形缓冲（8 秒容量，溢出丢最旧数据），Dart 侧每 100ms `wasapi_read` 轮询；
  5. 设备拔插：捕获线程报错退出，Dart 侧收到 `-2` 后提示用户重新启动采集。
- 构建：`wasapi_capture.dll` 由 CMake 编译进 runner 工程，链接 `avrt.lib`、`ole32.lib`。

## Android（骨架已建，接口预留）

**系统声音**：Android 10 (API 29)+ 的 [AudioPlaybackCapture API](https://developer.android.com/guide/topics/media/playback-capture)：

- 需要用户每次启动时同意 **MediaProjection**（`MediaProjectionManager.createScreenCaptureIntent()`，弹系统授权框——这是唯一能合法采集系统音频的途径）；
- `AudioPlaybackCaptureConfiguration.Builder(mediaProjection).addMatchingUsage(USAGE_MEDIA | USAGE_GAME | USAGE_UNKNOWN).build()` 交给 `AudioRecord`；
- 需要 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PROJECTION` 权限和前台服务（否则几秒后被系统杀掉）；
- 输出格式直接请求 16kHz/单声道（系统会重采样）；部分应用（DRM、通话类）会拒绝被采集，属平台限制。

**麦克风**：普通 `AudioRecord` + `RECORD_AUDIO` 运行时权限。

**悬浮窗**：`SYSTEM_ALERT_WINDOW`（`Settings.canDrawOverlays` 引导授权）；Android 8+ 用 `TYPE_APPLICATION_OVERLAY`。

**接入点**：实现 `AudioCapture` 接口（`lib/core/audio/audio_capture.dart`），通过 MethodChannel 调 Kotlin 原生代码；当前占位实现会抛出带指引的错误。

## macOS（骨架已建，接口预留）

**技术**：ScreenCaptureKit（macOS 13+）。

- 权限：需要在"系统设置 → 隐私与安全性 → 屏幕录制"中授予 App 权限（TCC），可监听 `SCShareableContent` 触发系统弹窗；
- 音频与屏幕内容绑定采集：`SCContentFilter` 选择内容 + `SCStreamConfiguration.capturesAudio = true`；
- **macOS 14.2 (Sonoma) 起**支持音频专用流（audio-only，无需真实视频帧），旧版 13.x 需要附带一个最小视频流（如 1×1）——参见 [Apple Developer Forums 讨论](https://developer.apple.com/forums/thread/718279)；
- 输出 PCM 为设备原生格式，需在 Swift 侧重采样为 16kHz 单声道；
- macOS 13 以下无官方回环接口，需虚拟声卡（BlackHole/Soundflower，用户手动安装）——建议声明支持 macOS 13+。

**接入点**：`AudioCapture` 接口 + MethodChannel/FFI 调 Swift；当前占位实现抛出带指引的错误。可参考 Chromium 的 [audio_loopback_input_mac_impl.h](https://chromium.googlesource.com/chromium/src/media/+/c5a022ab4160b8c358a52ed49c263525587a1eb8/audio/mac/audio_loopback_input_mac_impl.h)。

## 重采样

所有平台输出统一进 `Resampler`（`lib/core/audio/resampler.dart`）：任意采样率 → 16kHz 单声道，MVP 用线性插值（语音场景足够），预留 sinc 滤波实现位置。

## 权限与合规注意

- 系统音频采集属于敏感能力：三平台均需在首次使用时向用户**明示用途**（翻译字幕），并在设置里提供采集源切换；
- Google Play 上架使用 MediaProjection 需声明用途并避免被判定为"屏幕录制工具"；
- macOS 上架（如走 App Store）需说明 ScreenCaptureKit 用途。
