import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_translate/core/audio/resampler.dart';

void main() {
  test('48kHz -> 16kHz 输出长度为输入的 1/3', () {
    final resampler = LinearResampler(48000, 16000);
    // 300ms @48kHz = 14400 样本；分块喂入模拟流式
    const srcLen = 14400;
    final input = Float32List(srcLen);
    for (var i = 0; i < srcLen; i++) {
      input[i] = math.sin(2 * math.pi * 440 * i / 48000);
    }
    final outputs = <Float32List>[];
    const chunk = 2400;
    for (var i = 0; i < srcLen; i += chunk) {
      final end = math.min(i + chunk, srcLen);
      final part = input.sublist(i, end);
      outputs.add(resampler.process(part));
    }
    final total = outputs.fold<int>(0, (sum, o) => sum + o.length);
    // 4800 输出 ±2 样本容差（流式边界）
    expect(total, closeTo(4800, 2));

    // 无 NaN，幅度在 [-1, 1]
    for (final o in outputs) {
      for (final v in o) {
        expect(v.isNaN, isFalse);
        expect(v.abs(), lessThanOrEqualTo(1.0));
      }
    }
  });

  test('44.1kHz -> 16kHz 输出长度符合比例', () {
    final resampler = LinearResampler(44100, 16000);
    final input = Float32List(4410); // 100ms
    final out = resampler.process(input);
    expect(out.length, closeTo(1600, 2));
  });

  test('静音输入输出全零且无 NaN', () {
    final resampler = LinearResampler(48000, 16000);
    final out = resampler.process(Float32List(4800));
    expect(out, isNotEmpty);
    for (final v in out) {
      expect(v, 0);
    }
  });

  test('reset 后行为与新建一致', () {
    final resampler = LinearResampler(48000, 16000);
    final sine = Float32List(4800);
    for (var i = 0; i < sine.length; i++) {
      sine[i] = math.sin(2 * math.pi * 440 * i / 48000);
    }
    final before = resampler.process(sine);
    resampler.reset();
    final after = resampler.process(sine);
    expect(after.length, before.length);
    for (var i = 0; i < before.length; i++) {
      expect(after[i], closeTo(before[i], 1e-6));
    }
  });
}
