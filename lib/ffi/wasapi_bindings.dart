import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _StartNative = Int32 Function(
    Int32 mode, Pointer<Pointer<Void>> outHandle);
typedef _StartDart = int Function(int mode, Pointer<Pointer<Void>> outHandle);

typedef _ReadNative = Int32 Function(Pointer<Void> handle, Pointer<Float> out,
    Int32 maxFrames, Pointer<Int32> framesRead, Pointer<Int32> sampleRate);
typedef _ReadDart = int Function(Pointer<Void> handle, Pointer<Float> out,
    int maxFrames, Pointer<Int32> framesRead, Pointer<Int32> sampleRate);

typedef _StopNative = Void Function(Pointer<Void> handle);
typedef _StopDart = void Function(Pointer<Void> handle);

typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

/// dart:ffi 绑定到 windows/runner/native/wasapi_capture.cpp 导出的 C API。
/// 仅 Windows 可用；其他平台加载即抛异常，由上层用占位实现代替。
class WasapiBindings {
  WasapiBindings._(this._lib) {
    _start = _lib.lookupFunction<_StartNative, _StartDart>('wasapi_start');
    _read = _lib.lookupFunction<_ReadNative, _ReadDart>('wasapi_read');
    _stop = _lib.lookupFunction<_StopNative, _StopDart>('wasapi_stop');
    _lastError = _lib
        .lookupFunction<_LastErrorNative, _LastErrorDart>('wasapi_last_error');
  }

  static WasapiBindings? _instance;
  static WasapiBindings get instance =>
      _instance ??= WasapiBindings._(DynamicLibrary.open('wasapi_capture.dll'));

  final DynamicLibrary _lib;
  late final _StartDart _start;
  late final _ReadDart _read;
  late final _StopDart _stop;
  late final _LastErrorDart _lastError;

  int start(int mode, Pointer<Pointer<Void>> outHandle) =>
      _start(mode, outHandle);

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
