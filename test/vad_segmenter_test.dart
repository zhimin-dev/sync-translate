import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_translate/core/audio/audio_chunk.dart';
import 'package:sync_translate/core/pipeline/vad_segmenter.dart';

/// 生成 16kHz 单声道 float32：正弦（语音）或静音。
Float32List makeAudio({required int ms, required bool voiced}) {
  final len = ms * 16;
  final pcm = Float32List(len);
  if (voiced) {
    for (var i = 0; i < len; i++) {
      pcm[i] = 0.3 * math.sin(2 * math.pi * 220 * i / 16000);
    }
  }
  return pcm;
}

void main() {
  List<SpeechSegment> collect(VadSegmenter seg) {
    final out = <SpeechSegment>[];
    seg.segments.listen(out.add);
    return out;
  }

  test('语音-静音-语音切出两段', () async {
    final seg = VadSegmenter(
      silenceThreshold: 0.05,
      silenceToCutMs: 600,
      minSpeechMs: 300,
      maxSegmentMs: 8000,
    );
    final segments = collect(seg);
    var t = 0;
    void add(int ms, bool voiced) {
      seg.add(AudioChunk(makeAudio(ms: ms, voiced: voiced), t));
      t += ms;
    }

    add(800, true); // 语音 800ms
    add(900, false); // 静音 900ms → 切段
    add(600, true); // 语音 600ms
    add(1200, false); // 静音 → 切段
    await seg.dispose();

    expect(segments.length, 2);
    // 第一段：语音 800ms + 部分静音，尾部静音被裁掉
    expect(segments[0].startMs, 0);
    expect(segments[0].endMs, greaterThanOrEqualTo(800));
    expect(segments[0].endMs, lessThan(800 + 600 + 60));
    expect(segments[0].pcm16k.length, greaterThan(800 * 16 ~/ 2));
    // 第二段起点在语音段起点
    expect(segments[1].startMs, 1700);
  });

  test('纯静音不产生分段', () async {
    final seg = VadSegmenter();
    final segments = collect(seg);
    seg.add(AudioChunk(makeAudio(ms: 3000, voiced: false), 0));
    await seg.dispose();
    expect(segments, isEmpty);
  });

  test('超长语音按 maxSegmentMs 强制切段', () async {
    final seg = VadSegmenter(
      silenceThreshold: 0.05,
      maxSegmentMs: 1000,
      minSpeechMs: 300,
    );
    final segments = collect(seg);
    seg.add(AudioChunk(makeAudio(ms: 2500, voiced: true), 0));
    await seg.dispose();
    expect(segments.length, 2);
    expect(segments[0].endMs - segments[0].startMs, lessThanOrEqualTo(1030));
  });

  test('过短语音段被丢弃', () async {
    final seg = VadSegmenter(
      silenceThreshold: 0.05,
      silenceToCutMs: 600,
      minSpeechMs: 450,
    );
    final segments = collect(seg);
    var t = 0;
    seg.add(AudioChunk(makeAudio(ms: 200, voiced: true), t));
    t += 200;
    seg.add(AudioChunk(makeAudio(ms: 900, voiced: false), t));
    await seg.dispose();
    expect(segments, isEmpty);
  });

  test('说话过程中周期性发出部分结果（边听边出）', () async {
    final seg = VadSegmenter(
      silenceThreshold: 0.05,
      silenceToCutMs: 600,
      partialMinSpeechMs: 500,
      partialIntervalMs: 300,
    );
    final partials = <SpeechPartial>[];
    seg.partials.listen(partials.add);
    var t = 0;
    // 连续 3000ms 语音（分块喂入模拟实时流）
    for (var i = 0; i < 10; i++) {
      seg.add(AudioChunk(makeAudio(ms: 300, voiced: true), t));
      t += 300;
    }
    seg.add(AudioChunk(makeAudio(ms: 900, voiced: false), t));
    await seg.dispose();

    expect(partials, isNotEmpty);
    // 第一个部分结果在语音满 500ms 后
    expect(partials.first.startMs, 0);
    expect(partials.first.endMs - partials.first.startMs,
        greaterThanOrEqualTo(500));
    // 部分结果时间递增、音频逐步变长
    for (var i = 1; i < partials.length; i++) {
      expect(partials[i].endMs, greaterThanOrEqualTo(partials[i - 1].endMs));
      expect(partials[i].pcm16k.length, greaterThan(partials[i - 1].pcm16k.length));
    }
  });

  test('纯静音不产生部分结果', () async {
    final seg = VadSegmenter(
      silenceThreshold: 0.05,
      partialMinSpeechMs: 500,
      partialIntervalMs: 300,
    );
    final partials = <SpeechPartial>[];
    seg.partials.listen(partials.add);
    seg.add(AudioChunk(makeAudio(ms: 3000, voiced: false), 0));
    await seg.dispose();
    expect(partials, isEmpty);
  });
}
