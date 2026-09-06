import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _StartNative = Int32 Function(
    Int32 mode, Pointer<Pointer<Void>> outHandle);
typedef _StartDart = int Function(int mode, Pointer<Pointer<Void>> outHandle);

typedef _StartOnDeviceNative = Int32 Function(
    Int32 mode, Pointer<Utf8> name, Pointer<Pointer<Void>> outHandle);
typedef _StartOnDeviceDart = int Function(
    int mode, Pointer<Utf8> name, Pointer<Pointer<Void>> outHandle);

typedef _ListDevicesNative = Pointer<Utf8> Function(Int32 mode);
typedef _ListDevicesDart = Pointer<Utf8> Function(int mode);

typedef _FreeStringNative = Void Function(Pointer<Utf8> s);
typedef _FreeStringDart = void Function(Pointer<Utf8> s);

typedef _ReadNative = Int32 Function(Pointer<Void> handle, Pointer<Float> out,
    Int32 maxFrames, Pointer<Int32> framesRead, Pointer<Int32> sampleRate);
typedef _ReadDart = int Function(Pointer<Void> handle, Pointer<Float> out,
    int maxFrames, Pointer<Int32> framesRead, Pointer<Int32> sampleRate);

typedef _StopNative = Void Function(Pointer<Void> handle);
typedef _StopDart = void Function(Pointer<Void> handle);

typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

typedef _SpawnHiddenNative = Int32 Function(Pointer<Utf8> cmdline);
typedef _SpawnHiddenDart = int Function(Pointer<Utf8> cmdline);

/// dart:ffi 绑定到 windows/runner/native/wasapi_capture.cpp 导出的 C API。
/// 仅 Windows 可用；其他平台加载即抛异常，由上层用占位实现代替。
class WasapiBindings {
  WasapiBindings._(this._lib) {
    _start = _lib.lookupFunction<_StartNative, _StartDart>('wasapi_start');
    _startOnDevice = _lib.lookupFunction<_StartOnDeviceNative,
        _StartOnDeviceDart>('wasapi_start_on_device');
    _listDevices = _lib.lookupFunction<_ListDevicesNative, _ListDevicesDart>(
        'wasapi_list_devices');
    _freeString = _lib
        .lookupFunction<_FreeStringNative, _FreeStringDart>('wasapi_free_string');
    _read = _lib.lookupFunction<_ReadNative, _ReadDart>('wasapi_read');
    _stop = _lib.lookupFunction<_StopNative, _StopDart>('wasapi_stop');
    _lastError = _lib
        .lookupFunction<_LastErrorNative, _LastErrorDart>('wasapi_last_error');
    _spawnHidden =
        _lib.lookupFunction<_SpawnHiddenNative, _SpawnHiddenDart>('st_spawn_hidden');
  }

  static WasapiBindings? _instance;
  static WasapiBindings get instance {
    if (_instance != null) return _instance!;
    try {
      _instance = WasapiBindings._(DynamicLibrary.open('wasapi_capture.dll'));
    } catch (_) {
      // 非应用运行环境（如 dart run 测试）：按项目根回退绝对路径
      final root = Platform.environment['SYNC_TRANSLATE_ROOT'];
      final fallback = root == null
          ? null
          : '$root${Platform.pathSeparator}build${Platform.pathSeparator}windows'
              '${Platform.pathSeparator}x64${Platform.pathSeparator}runner'
              '${Platform.pathSeparator}Release${Platform.pathSeparator}wasapi_capture.dll';
      if (fallback != null && File(fallback).existsSync()) {
        _instance = WasapiBindings._(DynamicLibrary.open(fallback));
      } else {
        rethrow;
      }
    }
    return _instance!;
  }

  final DynamicLibrary _lib;
  late final _StartDart _start;
  late final _StartOnDeviceDart _startOnDevice;
  late final _ListDevicesDart _listDevices;
  late final _FreeStringDart _freeString;
  late final _ReadDart _read;
  late final _StopDart _stop;
  late final _LastErrorDart _lastError;
  late final _SpawnHiddenDart _spawnHidden;

  /// 隐藏窗口启动后台进程（Windows 专用），返回 PID（<=0 表示失败）。
  int spawnHidden(String cmdline) {
    final c = cmdline.toNativeUtf8();
    try {
      return _spawnHidden(c);
    } finally {
      calloc.free(c);
    }
  }

  int start(int mode, Pointer<Pointer<Void>> outHandle) =>
      _start(mode, outHandle);

  /// 在指定友好名称的端点上开始采集（名称来自 [listDevices]）。
  int startOnDevice(int mode, String deviceName,
      Pointer<Pointer<Void>> outHandle) {
    final name = deviceName.toNativeUtf8();
    try {
      return _startOnDevice(mode, name, outHandle);
    } finally {
      calloc.free(name);
    }
  }

  /// 列出活动端点友好名称，每行一个；失败返回空串。
  String listDevices(int mode) {
    final ptr = _listDevices(mode);
    if (ptr == nullptr) return '';
    final s = ptr.toDartString();
    _freeString(ptr);
    return s;
  }

  int read(Pointer<Void> handle, Pointer<Float> out, int maxFrames,
          Pointer<Int32> framesRead, Pointer<Int32> sampleRate) =>
      _read(handle, out, maxFrames, framesRead, sampleRate);

  void stop(Pointer<Void> handle) => _stop(handle);

  /// 返回静态缓冲区的错误信息，需立即复制使用。
  String lastError() => _lastError().toDartString();
}

class WasapiException implements Exception {
  WasapiException(this.message);
  final String message;

  @override
  String toString() => 'WasapiException: $message';
}
