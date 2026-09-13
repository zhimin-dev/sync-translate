import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'translator.dart';

/// LLM 翻译引擎：POST {baseUrl}/chat/completions（OpenAI 兼容）。
/// 兼容 OpenAI / DeepSeek / SiliconFlow / Ollama（http://localhost:11434/v1）等。
///
/// 质量设计：
/// - 字幕翻译专用 system 提示词（口语自然、保留语气、专名不译、术语一致）；
/// - 支持把前几句已翻译字幕作为上下文一起发送（避免碎片句误译）；
/// - 临时字幕（provisional）可用快速模型 [TranslatorConfig.fastModel]，最终字幕用主模型；
/// - DeepSeek 官方 API 默认开启思考模式（慢且计费），这里显式关闭。
class LlmTranslator implements Translator {
  @override
  String get id => 'llm';

  TranslatorConfig? _config;
  final _client = http.Client();

  @override
  Future<void> init(TranslatorConfig config) async {
    _config = config;
    if (config.apiKey.trim().isEmpty) {
      throw StateError('翻译 API Key 未配置');
    }
    if (config.baseUrl.trim().isEmpty) {
      throw StateError('翻译 Base URL 未配置');
    }
  }

  @override
  Future<String> translate(
    String text, {
    String? sourceLang,
    String? targetLang,
    String? context,
    bool provisional = false,
  }) async {
    final cfg = _config;
    if (cfg == null) throw StateError('翻译引擎未初始化');
    final base = cfg.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');
    final target = targetLang ?? cfg.targetLang;
    final sourceHint = sourceLang == null || sourceLang.isEmpty
        ? '（自动检测源语言）'
        : '从 "$sourceLang"';

    final systemPrompt = 'You are a professional subtitle translator for '
        'movies, TV shows and videos. Translate the user\'s message '
        '$sourceHint into "$target".\n'
        'Rules:\n'
        '1. Sound natural and colloquial — like subtitles a native "$target" '
        'speaker would read, not literal word-for-word translation.\n'
        '2. Preserve the speaker\'s tone and emotion (surprise, sarcasm, '
        'politeness, honorifics, slang).\n'
        '3. Keep proper nouns (person names, place names, brands) in their '
        'original language.\n'
        '4. Be concise: subtitles are short. Merge redundant words and drop '
        'filler when it sounds natural.\n'
        '5. Terminology, names and tone must stay consistent with the context '
        'lines provided by the user.\n'
        '6. Output ONLY the translation itself: no explanations, no quotes, '
        'no extra text, no markdown.\n'
        '7. If the text is already in "$target", output it unchanged.';

    // 带上文：前几句已翻译字幕（仅作上下文参考，不翻译它们）
    final userContent = (context == null || context.trim().isEmpty)
        ? text
        : '前文字幕（已翻译，仅供理解上下文）：\n$context\n\n当前字幕：\n$text';

    // 临时字幕用快速模型（若配置），最终字幕用主模型
    final model = (provisional && cfg.fastModel.trim().isNotEmpty)
        ? cfg.fastModel.trim()
        : cfg.model;

    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userContent},
      ],
      'temperature': 0.2,
      'stream': false,
      // DeepSeek 官方 API：默认思考模式（慢、计费 reasoning token），翻译场景关闭。
      if (base.contains('deepseek.com'))
        'thinking': {'type': 'disabled'},
    };

    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${cfg.apiKey}',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw TranslateException('翻译请求超时（60s）');
    } catch (e) {
      throw TranslateException('翻译网络错误: $e');
    }
    if (response.statusCode != 200) {
      throw TranslateException(
          '翻译 HTTP ${response.statusCode}: ${_truncate(response.body)}');
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final content = (decoded as Map<String, dynamic>)['choices']
          ?[0]?['message']?['content'];
      if (content is! String) {
        throw const FormatException('missing choices[0].message.content');
      }
      return _stripQuotes(content.trim());
    } catch (e) {
      throw TranslateException(
          '翻译响应解析失败: ${_truncate(response.body)}');
    }
  }

  @override
  Future<void> dispose() async {
    _client.close();
  }

  static String _stripQuotes(String s) {
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith('「') && s.endsWith('」')) ||
            (s.startsWith('“') && s.endsWith('”')))) {
      return s.substring(1, s.length - 1).trim();
    }
    return s;
  }

  static String _truncate(String s, [int max = 300]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
