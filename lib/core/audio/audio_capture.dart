import 'dart:io';

import 'audio_capture_stub.dart';
import 'audio_capture_wasapi.dart';
import 'audio_chunk.dart';

/// 采集源。
enum CaptureSource { system, microphone }

/// 平台音频采集抽象。所有实现统一输出 16kHz 单声道 float32 PCM。
abstract class AudioCapture {
  Future<void> start(CaptureSource source);

  Future<void> stop();

  /// 16kHz 单声道 float32 音频块流。
  Stream<AudioChunk> get chunks;

  /// 运行时错误（如默认音频设备被拔出）。
  Stream<String> get errors;
}

/// 按平台创建采集实现。
AudioCapture createPlatformAudioCapture() {
  if (Platform.isWindows) return WasapiAudioCapture();
  // Android / macOS 的采集层尚未实现（见 docs/platform-audio.md）。
  return StubAudioCapture();
}
