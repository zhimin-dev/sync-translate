import '../config/app_config.dart';
import 'translator.dart';

/// 本地翻译引擎占位（计划：CTranslate2 + NLLB / OPUS-MT + FFI）。
/// 提示：本地大模型可先用 Ollama（OpenAI 兼容接口），把翻译引擎设为
/// "LLM（OpenAI 兼容）" 并将 Base URL 指向 http://localhost:11434/v1。
class LocalTranslator implements Translator {
  @override
  String get id => 'nllb_local';

  @override
  Future<void> init(TranslatorConfig config) async {}

  @override
  Future<String> translate(String text,
      {String? sourceLang, String? targetLang}) {
    throw UnimplementedError(
      '本地翻译引擎尚未实现。\n'
      '当前可用替代方案：Ollama 本地模型（OpenAI 兼容接口），'
      '在翻译引擎选择 "LLM（OpenAI 兼容）" 并把 Base URL 指向 '
      'http://localhost:11434/v1。',
    );
  }

  @override
  Future<void> dispose() async {}
}
