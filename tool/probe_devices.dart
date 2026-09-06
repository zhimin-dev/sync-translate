// 设备探测：播放测试音，逐个活动渲染设备采集 2 秒，报告每个设备的音量峰值。
// 运行：dart run tool/probe_devices.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _StartOnDeviceNative = Int32 Function(
    Int32 mode, Pointer<Utf8> name, Pointer<Pointer<Void>> outHandle);
typedef _StartOnDeviceDart = int Function(
    int mode, Pointer<Utf8> name, Pointer<Pointer<Void>> outHandle);
typedef _ListDevicesNative = Pointer<Utf8> Function(Int32 mode);
typedef _ListDevicesDart = Pointer<Utf8> Function(int mode);
typedef _ReadNative = Int32 Function(
    Pointer<Void>, Pointer<Float>, Int32, Pointer<Int32>, Pointer<Int32>);
typedef _ReadDart = int Function(
    Pointer<Void>, Pointer<Float>, int, Pointer<Int32>, Pointer<Int32>);
typedef _StopNative = Void Function(Pointer<Void>);
typedef _StopDart = void Function(Pointer<Void>);
typedef _PlaySoundNative = Int32 Function(Pointer<Utf16>, Pointer<Void>, Uint32);
typedef _PlaySoundDart = int Function(Pointer<Utf16>, Pointer<Void>, int);

void main(List<String> args) {
  final listenMode = args.contains('listen'); // 不放测试音，直接监听当前播放内容
  final dllPath =
      r'D:\myweb\sync-translate\build\windows\x64\runner\Release\wasapi_capture.dll';
  final lib = DynamicLibrary.open(dllPath);
  final listDevices =
      lib.lookupFunction<_ListDevicesNative, _ListDevicesDart>('wasapi_list_devices');
  final startOnDevice = lib
      .lookupFunction<_StartOnDeviceNative, _StartOnDeviceDart>('wasapi_start_on_device');
  final read = lib.lookupFunction<_ReadNative, _ReadDart>('wasapi_read');
  final stop = lib.lookupFunction<_StopNative, _StopDart>('wasapi_stop');
  final winmm = DynamicLibrary.open('winmm.dll');
  final playSound =
      winmm.lookupFunction<_PlaySoundNative, _PlaySoundDart>('PlaySoundW');

  // 生成 440Hz 正弦测试音
  final wav = _makeWav(440, 3);
  final path =
      '${Directory.systemTemp.path}${Platform.pathSeparator}sync_translate_tone.wav';
  File(path).writeAsBytesSync(wav);
  final p = path.toNativeUtf16();

  final devicesPtr = listDevices(0);
  final devices = devicesPtr == nullptr
      ? <String>[]
      : devicesPtr.toDartString().split('\n').where((e) => e.trim().isNotEmpty).toList();
  stdout.writeln('活动渲染设备: ${devices.isEmpty ? "(无)" : devices.join(" | ")}');

  double probe(String? deviceName, int ms) {
    final outHandle = calloc<Pointer<Void>>();
    final namePtr = (deviceName ?? '').toNativeUtf8();
    final rc = startOnDevice(0, namePtr, outHandle);
    calloc.free(namePtr);
    if (rc != 0) {
      stdout.writeln('  [${deviceName ?? "默认"}] 启动失败 rc=$rc');
      calloc.free(outHandle);
      return -1;
    }
    final handle = outHandle.value;
    calloc.free(outHandle);
    final buf = calloc<Float>(48000);
    final framesRead = calloc<Int32>();
    final sampleRate = calloc<Int32>();
    var peak = 0.0;
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < ms) {
      final rr = read(handle, buf, 48000, framesRead, sampleRate);
      if (rr != 0) break;
      final n = framesRead.value;
      if (n > 0) {
        final view = buf.asTypedList(n);
        for (final s in view) {
          final a = s.abs();
          if (a > peak) peak = a;
        }
      }
    }
    stop(handle);
    calloc.free(buf);
    calloc.free(framesRead);
    calloc.free(sampleRate);
    return peak;
  }

  if (listenMode) {
    stdout.writeln('监听模式：请在 15 秒内开始播放 PotPlayer 视频/音频…');
    stdout.writeln('  默认设备  峰值: ${probe(null, 8000).toStringAsFixed(6)}');
    for (final d in devices) {
      stdout.writeln('  [$d] 峰值: ${probe(d, 8000).toStringAsFixed(6)}');
    }
  } else {
    playSound(p, nullptr, 0x0001 | 0x0008 | 0x20000); // 循环播放测试音
    stdout.writeln('测试音播放中（loop）…');
    stdout.writeln('  默认设备  峰值: ${probe(null, 2000).toStringAsFixed(6)}');
    for (final d in devices) {
      stdout.writeln('  [$d] 峰值: ${probe(d, 2000).toStringAsFixed(6)}');
    }
    playSound(nullptr, nullptr, 0);
  }
  calloc.free(p);
  stdout.writeln('完成。峰值 > 0.01 的设备就是声音实际经过的设备；全为 0 说明声音走了独占模式或未在本会话渲染。');
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
