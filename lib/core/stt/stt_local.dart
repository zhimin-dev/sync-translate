import 'dart:typed_data';

import '../config/app_config.dart';
import 'stt_engine.dart';

/// 本地 STT 引擎占位（计划：whisper.cpp / faster-whisper + FFI）。
/// 提示：whisper.cpp 的 server 模式同样提供 OpenAI 兼容的
/// /audio/transcriptions 接口，可先用 'openai_compat' 引擎指向
/// http://localhost:8080/v1 实现本地识别。
class LocalSttEngine implements SttEngine {
  @override
  String get id => 'whisper_local';

  @override
  Future<void> init(SttConfig config) async {}

  @override
  Future<String> transcribe(Float32List pcm16k, {String? language}) {
    throw UnimplementedError(
      '本地 STT 引擎尚未实现。\n'
      '当前可用替代方案：whisper.cpp server 模式（OpenAI 兼容接口），'
      '在 STT 引擎选择 "OpenAI 兼容" 并把 Base URL 指向 http://localhost:8080/v1。',
    );
  }

  @override
  Future<void> dispose() async {}
}
