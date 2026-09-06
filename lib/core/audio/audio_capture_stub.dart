import 'dart:async';

import 'audio_capture.dart';
import 'audio_chunk.dart';

/// Android / macOS 采集占位实现（见 docs/platform-audio.md）：
/// - Android: AudioPlaybackCapture（MediaProjection 授权）或 AudioRecord（麦克风）
/// - macOS:   ScreenCaptureKit（屏幕录制权限）或 AVAudioEngine（麦克风）
class StubAudioCapture implements AudioCapture {
  final _chunks = StreamController<AudioChunk>.broadcast();
  final _errors = StreamController<String>.broadcast();

  static const String _message =
      '当前平台（Android/macOS）的音频采集尚未实现。\n'
      'Android 计划：MediaProjection + AudioPlaybackCapture（Android 10+）\n'
      'macOS 计划：ScreenCaptureKit（macOS 13+，需屏幕录制权限）\n'
      '详见 docs/platform-audio.md。';

  @override
  Stream<AudioChunk> get chunks => _chunks.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> start(CaptureSource source, {String? device}) async {
    _errors.add(_message);
    throw UnimplementedError(_message);
  }

  @override
  Future<List<String>> listDevices(CaptureSource source) async => const [];

  @override
  Future<void> stop() async {}
}
