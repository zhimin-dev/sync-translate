import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../ffi/wasapi_bindings.dart';
import 'audio_capture.dart';
import 'audio_chunk.dart';
import 'resampler.dart';

/// Windows 音频采集：WASAPI 回环（系统声音）或默认麦克风。
/// 原生层输出设备采样率单声道 float32，本类轮询读取并重采样到 16kHz。
class WasapiAudioCapture implements AudioCapture {
  final _chunks = StreamController<AudioChunk>.broadcast();
  final _errors = StreamController<String>.broadcast();

  static const int _targetRate = 16000;
  static const int _pollMs = 100;

  Pointer<Void>? _handle;
  Timer? _timer;
  LinearResampler? _resampler;
  int _srcRate = 0;
  int _totalFrames = 0;
  bool _running = false;

  @override
  Stream<AudioChunk> get chunks => _chunks.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> start(CaptureSource source) async {
    if (_running) return;
    final bindings = WasapiBindings.instance;
    final outHandle = calloc<Pointer<Void>>();
    try {
      final mode = source == CaptureSource.system ? 0 : 1;
      final rc = bindings.start(mode, outHandle);
      if (rc != 0) {
        throw WasapiException('采集启动失败 (rc=$rc): ${bindings.lastError()}');
      }
      _handle = outHandle.value;
    } finally {
      calloc.free(outHandle);
    }
    _running = true;
    _srcRate = 0;
    _totalFrames = 0;
    _timer = Timer.periodic(const Duration(milliseconds: _pollMs), _poll);
  }

  void _poll(Timer timer) {
    if (!_running || _handle == null) return;
    try {
      _readOnce();
    } catch (e) {
      _errors.add('音频读取异常: $e');
    }
  }

  void _readOnce() {
    final handle = _handle;
    if (handle == null) return;
    final bindings = WasapiBindings.instance;

    // 首次读取时按设备采样率分配缓冲（1 秒容量）。
    if (_srcRate == 0) {
      // 空指针探测采样率（原生层约定：out 为 NULL 时不消费数据）。
      final probe = calloc<Int32>();
      final probeRate = calloc<Int32>();
      try {
        final rc = bindings.read(handle, nullptr, 0, probe, probeRate);
        if (rc != 0) {
          _errors.add('采集探测失败 (rc=$rc): ${bindings.lastError()}');
          return;
        }
        _srcRate = probeRate.value;
        _resampler = LinearResampler(_srcRate.toDouble(), _targetRate.toDouble());
      } finally {
        calloc.free(probe);
        calloc.free(probeRate);
      }
      if (_srcRate <= 0) {
        _errors.add('无效的设备采样率: $_srcRate');
        return;
      }
    }

    final maxFrames = _srcRate ~/ 10; // 100ms 的数据量
    final buf = calloc<Float>(maxFrames);
    final framesRead = calloc<Int32>();
    final sampleRate = calloc<Int32>();
    try {
      final rc = bindings.read(handle, buf, maxFrames, framesRead, sampleRate);
      if (rc == -2) {
        // 采集线程已退出（如默认设备被拔出）
        _running = false;
        _timer?.cancel();
        _errors.add('采集已中断（默认音频设备可能被拔出或禁用）：${bindings.lastError()}');
        return;
      }
      if (rc != 0) {
        _errors.add('读取失败 (rc=$rc): ${bindings.lastError()}');
        return;
      }
      final n = framesRead.value;
      if (n <= 0) return;
      final native = buf.asTypedList(n);
      final samples = Float32List.fromList(native);
      final resampled = _resampler?.process(samples) ?? Float32List(0);
      if (resampled.isNotEmpty) {
        final timestampMs = (_totalFrames * 1000 / _srcRate).round();
        _chunks.add(AudioChunk(resampled, timestampMs));
      }
      _totalFrames += n;
    } finally {
      calloc.free(buf);
      calloc.free(framesRead);
      calloc.free(sampleRate);
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      try {
        WasapiBindings.instance.stop(handle);
      } catch (_) {
        // 忽略重复释放
      }
    }
    _resampler = null;
    _srcRate = 0;
    _totalFrames = 0;
  }
}
