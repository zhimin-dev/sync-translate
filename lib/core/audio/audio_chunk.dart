import 'dart:typed_data';

/// 一段 16kHz 单声道 float32 PCM 音频，范围 [-1, 1]。
class AudioChunk {
  AudioChunk(this.pcm16k, this.timestampMs);

  final Float32List pcm16k;

  /// 该块起始时间（相对采集开始，毫秒）。
  final int timestampMs;
}
