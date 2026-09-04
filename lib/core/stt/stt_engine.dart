import 'dart:typed_data';

import '../config/app_config.dart';
import 'stt_local.dart';
import 'stt_openai_compat.dart';

/// 语音识别引擎抽象。输入统一为 16kHz 单声道 float32 PCM。
abstract class SttEngine {
  String get id;

  Future<void> init(SttConfig config);

  /// 转写一段语音，返回文本（可能为空串）。
  /// [language] 为识别语言提示（ISO 639-1），null 表示自动检测。
  Future<String> transcribe(Float32List pcm16k, {String? language});

  Future<void> dispose();
}

/// 按引擎 ID 创建实现。
SttEngine createSttEngine(String id) {
  switch (id) {
    case 'openai_compat':
      return OpenAiCompatSttEngine();
    case 'whisper_local':
      return LocalSttEngine();
    default:
      throw ArgumentError.value(id, 'id', '未知 STT 引擎');
  }
}

class SttException implements Exception {
  SttException(this.message);
  final String message;

  @override
  String toString() => 'SttException: $message';
}
