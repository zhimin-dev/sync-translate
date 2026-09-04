// 原生层冒烟测试：直接加载 wasapi_capture.dll，采集 3 秒系统声音。
// 运行：dart run tool/native_smoke.dart [--tone]   （--tone 先循环播放 440Hz 测试音）
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _StartNative = Int32 Function(Int32, Pointer<Pointer<Void>>);
typedef _StartDart = int Function(int, Pointer<Pointer<Void>>);
typedef _ReadNative = Int32 Function(
    Pointer<Void>, Pointer<Float>, Int32, Pointer<Int32>, Pointer<Int32>);
typedef _ReadDart = int Function(
    Pointer<Void>, Pointer<Float>, int, Pointer<Int32>, Pointer<Int32>);
typedef _StopNative = Void Function(Pointer<Void>);
typedef _StopDart = void Function(Pointer<Void>);
typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

typedef _PlaySoundNative = Int32 Function(Pointer<Utf16>, Pointer<Void>, Uint32);
typedef _PlaySoundDart = int Function(Pointer<Utf16>, Pointer<Void>, int);

void main(List<String> args) {
  final playTone = args.contains('--tone');
  final winmm = DynamicLibrary.open('winmm.dll');
  final playSound = winmm
      .lookupFunction<_PlaySoundNative, _PlaySoundDart>('PlaySoundW');
  Pointer<Utf16>? tonePathPtr;

  if (playTone) {
    final wav = _makeWav(440, 3);
    final tonePath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}sync_translate_tone.wav';
    File(tonePath).writeAsBytesSync(wav);
    tonePathPtr = tonePath.toNativeUtf16();
    final rc = playSound(tonePathPtr, nullptr, 0x0001 | 0x0008 | 0x20000);
    stdout.writeln('PlaySound rc=$rc');
    if (rc == 0) exit(2);
  }

  final dllPath =
      r'D:\myweb\sync-translate\build\windows\x64\runner\Release\wasapi_capture.dll';
  final lib = DynamicLibrary.open(dllPath);
  final start = lib.lookupFunction<_StartNative, _StartDart>('wasapi_start');
  final read = lib.lookupFunction<_ReadNative, _ReadDart>('wasapi_read');
  final stop = lib.lookupFunction<_StopNative, _StopDart>('wasapi_stop');
  final lastError =
      lib.lookupFunction<_LastErrorNative, _LastErrorDart>('wasapi_last_error');

  final outHandle = calloc<Pointer<Void>>();
  var rc = start(0, outHandle);
  stdout.writeln('start rc=$rc err=${lastError()}');
  if (rc != 0) {
    exit(1);
  }
  final handle = outHandle.value;
  calloc.free(outHandle);

  final buf = calloc<Float>(48000);
  final framesRead = calloc<Int32>();
  final sampleRate = calloc<Int32>();
  var total = 0;
  var peak = 0.0;
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < 3000) {
    rc = read(handle, buf, 48000, framesRead, sampleRate);
    if (rc == -2) {
      stdout.writeln('capture thread died: ${lastError()}');
      break;
    }
    if (rc != 0) {
      stdout.writeln('read rc=$rc err=${lastError()}');
      break;
    }
    final n = framesRead.value;
    if (n > 0) {
      total += n;
      final view = buf.asTypedList(n);
      for (final s in view) {
        final a = s.abs();
        if (a > peak) peak = a;
      }
    }
  }
  stdout.writeln(
      'rate=${sampleRate.value} frames=$total (${(total / sampleRate.value * 1000).round()}ms) peak=$peak');
  stop(handle);
  playSound(nullptr, nullptr, 0);
  if (tonePathPtr != null) calloc.free(tonePathPtr);
  calloc.free(buf);
  calloc.free(framesRead);
  calloc.free(sampleRate);
}

Uint8List _makeWav(int freq, int seconds) {
  const rate = 48000;
  final n = rate * seconds;
  final bytes = Uint8List(44 + n * 2);
  final bd = ByteData.view(bytes.buffer);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  bd.setUint32(4, 36 + n * 2, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, rate, Endian.little);
  bd.setUint32(28, rate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  bd.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (0.3 * 32767 * math.sin(2 * math.pi * freq * i / rate)).round();
    bd.setInt16(44 + i * 2, v, Endian.little);
  }
  return bytes;
}
