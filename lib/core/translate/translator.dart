import '../config/app_config.dart';
import 'translator_llm.dart';
import 'translator_local.dart';

/// 翻译引擎抽象。
abstract class Translator {
  String get id;

  Future<void> init(TranslatorConfig config);

  /// 翻译一段文本。[sourceLang]/[targetLang] 为 ISO 639-1 提示，null 表示用配置值。
  Future<String> translate(String text, {String? sourceLang, String? targetLang});

  Future<void> dispose();
}

/// 按引擎 ID 创建实现。
Translator createTranslator(String id) {
  switch (id) {
    case 'llm':
      return LlmTranslator();
    case 'nllb_local':
      return LocalTranslator();
    default:
      throw ArgumentError.value(id, 'id', '未知翻译引擎');
  }
}

class TranslateException implements Exception {
  TranslateException(this.message);
  final String message;

  @override
  String toString() => 'TranslateException: $message';
}
