import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/audio_chunk.dart';

/// 一段被判定为语音的音频及其时间范围。
class SpeechSegment {
  SpeechSegment(this.pcm16k, this.startMs, this.endMs);

  final Float32List pcm16k;
  final int startMs;
  final int endMs;
}

/// 说话过程中的滚动窗口部分结果（边听边出，用于临时字幕）。
class SpeechPartial {
  SpeechPartial(this.pcm16k, this.startMs, this.endMs);

  final Float32List pcm16k;
  final int startMs;
  final int endMs;
}

/// 基于短时能量的 VAD 分段器。
/// 输入 16kHz 单声道 float32 块流：
/// - [segments]：按静音切分的完整语音段（最终字幕用）
/// - [partials]：说话过程中周期性发出的当前语音窗口快照（实时字幕用）
class VadSegmenter {
  VadSegmenter({
    this.frameMs = 30,
    // 静音阈值：低于视为静音。0.004 适配较低的系统音量（如 PotPlayer 默认音量）；
    // 若背景噪声大导致误触发，可适当调高。
    this.silenceThreshold = 0.004,
    // 提速调优：静音 450ms 即切句（原 650ms），最短语音 300ms（原 450ms），
    // 让每句更早上屏；句子切得稍碎可换来约 0.5~1s 的实时性提升。
    this.silenceToCutMs = 450,
    this.minSpeechMs = 300,
    this.maxSegmentMs = 8000,
    // 部分结果（实时字幕）：语音满 1200ms 后每 800ms 发一次窗口快照
    this.partialMinSpeechMs = 1200,
    this.partialIntervalMs = 800,
  });

  /// 帧长（毫秒）。
  final int frameMs;

  /// RMS 能量阈值，低于视为静音。
  final double silenceThreshold;

  /// 连续静音超过该时长即切段。
  final int silenceToCutMs;

  /// 最短语音段时长，过短的段丢弃。
  final int minSpeechMs;

  /// 最长语音段时长，强制切段（避免超长请求）。
  final int maxSegmentMs;

  /// 语音持续至少该时长后才开始发部分结果。
  final int partialMinSpeechMs;

  /// 部分结果的最小间隔。
  final int partialIntervalMs;

  static const int _sampleRate = 16000;

  final _segments = StreamController<SpeechSegment>.broadcast();
  Stream<SpeechSegment> get segments => _segments.stream;

  final _partials = StreamController<SpeechPartial>.broadcast();
  Stream<SpeechPartial> get partials => _partials.stream;

  final List<double> _buffer = [];
  int _speechStartMs = -1;
  int _silenceMs = 0;
  int _lastPartialEndMs = -1;

  // 自适应阈值：跟踪背景噪声底，动态阈值 = max(阈值下限, 噪声底×3 + 0.0003)
  double _noiseFloor = 0.0;

  /// 计算当前有效判定阈值（自适应背景噪声）。
  double _effectiveThreshold() {
    final floor = silenceThreshold * 0.35;
    final adaptive = _noiseFloor * 3 + 0.0003;
    return math.max(floor, adaptive);
  }

  /// 更新噪声底（仅用"当前被判为静音"的帧，缓慢下移）。
  void _updateNoiseFloor(double rms) {
    if (_noiseFloor <= 0) {
      _noiseFloor = rms;
    } else if (rms < _noiseFloor) {
      _noiseFloor = _noiseFloor * 0.9 + rms * 0.1;
    } else {
      _noiseFloor = _noiseFloor * 0.995 + rms * 0.005;
    }
  }

  void add(AudioChunk chunk) {
    final pcm = chunk.pcm16k;
    final frameLen = _sampleRate * frameMs ~/ 1000;
    var i = 0;
    var frameStartMs = chunk.timestampMs;
    while (i < pcm.length) {
      final end = math.min(i + frameLen, pcm.length);
      final rms = _rms(pcm, i, end);
      _processFrame(rms, pcm, i, end, frameStartMs);
      frameStartMs += frameMs;
      i = end;
    }
  }

  void _processFrame(
      double rms, Float32List pcm, int start, int end, int tMs) {
    final voiced = rms >= _effectiveThreshold();
    if (_speechStartMs < 0) {
      if (voiced) {
        _speechStartMs = tMs;
        _silenceMs = 0;
        _lastPartialEndMs = -1;
        _buffer.clear();
        _buffer.addAll(pcm.sublist(start, end));
      } else {
        // 仅用非语音帧估计背景噪声底
        _updateNoiseFloor(rms);
      }
      return;
    }
    _buffer.addAll(pcm.sublist(start, end));
    if (voiced) {
      _silenceMs = 0;
      // 边听边出：当前语音窗口快照
      final nowMs = tMs + frameMs;
      final speechLenMs = nowMs - _speechStartMs;
      if (speechLenMs >= partialMinSpeechMs &&
          nowMs - _lastPartialEndMs >= partialIntervalMs) {
        _lastPartialEndMs = nowMs;
        final snapshot = Float32List(_buffer.length);
        for (var i = 0; i < _buffer.length; i++) {
          snapshot[i] = _buffer[i];
        }
        _partials.add(SpeechPartial(snapshot, _speechStartMs, nowMs));
      }
    } else {
      _silenceMs += frameMs;
    }
    final speechLenMs = tMs + frameMs - _speechStartMs;
    final cutBySilence =
        _silenceMs >= silenceToCutMs && speechLenMs >= minSpeechMs;
    final cutByMax = speechLenMs >= maxSegmentMs;
    if (cutBySilence || cutByMax) {
      _emit(tMs + frameMs);
    }
  }

  void _emit(int endMs) {
    var keep = _buffer.length;
    if (_silenceMs > 0) {
      // 裁掉尾部静音
      final trim = math.min(keep, _silenceMs * _sampleRate ~/ 1000);
      keep -= trim;
    }
    if (keep > 0 && endMs - _silenceMs - _speechStartMs >= minSpeechMs) {
      final pcm = Float32List(keep);
      for (var i = 0; i < keep; i++) {
        pcm[i] = _buffer[i];
      }
      _segments.add(SpeechSegment(pcm, _speechStartMs, endMs - _silenceMs));
    }
    _buffer.clear();
    _speechStartMs = -1;
    _silenceMs = 0;
    _lastPartialEndMs = -1;
  }

  /// 停止采集前调用，把未切段的语音作为最后一段发出。
  void flush() {
    if (_speechStartMs >= 0) {
      _emit(_speechStartMs + _buffer.length * 1000 ~/ _sampleRate);
    }
  }

  Future<void> dispose() async {
    await _segments.close();
    await _partials.close();
  }

  static double _rms(Float32List pcm, int start, int end) {
    if (end <= start) return 0;
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      final v = pcm[i];
      sum += v * v;
    }
    return math.sqrt(sum / (end - start));
  }
}
