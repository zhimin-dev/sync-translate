import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'translator.dart';

/// LLM 翻译引擎：POST {baseUrl}/chat/completions（OpenAI 兼容）。
/// 兼容 OpenAI / DeepSeek / SiliconFlow / Ollama（http://localhost:11434/v1）等。
///
/// 质量设计：
/// - 字幕翻译专用 system 提示词（意译优先、通顺自然、保留语气、专名不译、术语一致）；
/// - 支持把前几句已翻译字幕作为上下文一起发送（避免碎片句误译）；
/// - 临时字幕（provisional）可用快速模型 [TranslatorConfig.fastModel]，最终字幕用主模型；
/// - 可选思考模式（[TranslatorConfig.thinking]，仅 DeepSeek 官方 API、仅最终字幕）：
///   先推理再输出，译文更通顺贴合语境，代价是更慢、推理 token 计费；默认关闭思考。
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
        '1. Translate the MEANING, not the words. Reorder clauses freely so '
        'the result reads like natural, fluent movie subtitles in "$target" — '
        'a native speaker should not be able to tell it was translated.\n'
        '2. Prefer 意译 over literal translation: idioms, slang and '
        'colloquial expressions should be rendered by their meaning.\n'
        '3. Preserve the speaker\'s tone and emotion (surprise, sarcasm, '
        'politeness, honorifics, slang).\n'
        '4. Keep proper nouns (person names, place names, brands) in their '
        'original language.\n'
        '5. Be concise: subtitles are short. Merge redundant words and drop '
        'filler when it sounds natural.\n'
        '6. Terminology, names and tone must stay consistent with the context '
        'lines provided by the user.\n'
        '7. Output ONLY the translation itself: no explanations, no quotes, '
        'no extra text, no markdown.\n'
        '8. If the text is already in "$target", output it unchanged.';

    // 带上文：前几句已翻译字幕（仅作上下文参考，不翻译它们）
    final userContent = (context == null || context.trim().isEmpty)
        ? text
        : '前文字幕（已翻译，仅供理解上下文）：\n$context\n\n当前字幕：\n$text';

    // 临时字幕用快速模型（若配置），最终字幕用主模型
    final model = (provisional && cfg.fastModel.trim().isNotEmpty)
        ? cfg.fastModel.trim()
        : cfg.model;

    final isDeepSeek = base.contains('deepseek.com');
    // 思考模式：仅 DeepSeek 官方 API、且仅最终字幕生效（临时字幕要快，不开）。
    final useThinking = isDeepSeek && cfg.thinking && !provisional;

    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userContent},
      ],
      'stream': false,
      if (useThinking) ...{
        // 思考模式：先推理再输出（更通顺/更贴语境），temperature 不生效。
        'thinking': {'type': 'enabled'},
        'reasoning_effort': cfg.thinkingEffort == 'low'
            ? 'low'
            : (cfg.thinkingEffort == 'max' ? 'max' : 'high'),
      } else ...{
        'temperature': 0.2,
        // DeepSeek 官方 API 默认开启思考模式（慢、计费 reasoning token），
        // 非思考场景显式关闭。
        if (isDeepSeek) 'thinking': {'type': 'disabled'},
      },
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
          .timeout(Duration(seconds: useThinking ? 180 : 60));
    } on TimeoutException {
      throw TranslateException(
          '翻译请求超时（${useThinking ? 180 : 60}s）');
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
