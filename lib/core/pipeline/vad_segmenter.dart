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

/// 基于短时能量的 VAD 分段器（MVP）。
/// 输入 16kHz 单声道 float32 块流，按静音切分为语音段。
class VadSegmenter {
  VadSegmenter({
    this.frameMs = 30,
    this.silenceThreshold = 0.008,
    this.silenceToCutMs = 650,
    this.minSpeechMs = 450,
    this.maxSegmentMs = 8000,
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

  static const int _sampleRate = 16000;

  final _segments = StreamController<SpeechSegment>.broadcast();
  Stream<SpeechSegment> get segments => _segments.stream;

  final List<double> _buffer = [];
  int _speechStartMs = -1;
  int _silenceMs = 0;

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
    final voiced = rms >= silenceThreshold;
    if (_speechStartMs < 0) {
      if (voiced) {
        _speechStartMs = tMs;
        _silenceMs = 0;
        _buffer.clear();
        _buffer.addAll(pcm.sublist(start, end));
      }
      return;
    }
    _buffer.addAll(pcm.sublist(start, end));
    if (voiced) {
      _silenceMs = 0;
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
  }

  /// 停止采集前调用，把未切段的语音作为最后一段发出。
  void flush() {
    if (_speechStartMs >= 0) {
      _emit(_speechStartMs + _buffer.length * 1000 ~/ _sampleRate);
    }
  }

  Future<void> dispose() => _segments.close();

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
