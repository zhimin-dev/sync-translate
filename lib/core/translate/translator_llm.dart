import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'translator.dart';

/// LLM 翻译引擎：POST {baseUrl}/chat/completions（OpenAI 兼容）。
/// 兼容 OpenAI / DeepSeek / SiliconFlow / Ollama（http://localhost:11434/v1）等。
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
  Future<String> translate(String text,
      {String? sourceLang, String? targetLang}) async {
    final cfg = _config;
    if (cfg == null) throw StateError('翻译引擎未初始化');
    final base = cfg.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');
    final target = targetLang ?? cfg.targetLang;
    final systemPrompt = sourceLang == null || sourceLang.isEmpty
        ? 'You are a professional subtitle translator. Translate the user\'s '
            'message into "$target". Output only the translation itself: no '
            'explanations, no quotes, no extra text. If the text is already in '
            '"$target", output it unchanged.'
        : 'You are a professional subtitle translator. Translate the user\'s '
            'message from "$sourceLang" into "$target". Output only the '
            'translation itself: no explanations, no quotes, no extra text. '
            'If the text is already in "$target", output it unchanged.';

    final body = jsonEncode({
      'model': cfg.model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': text},
      ],
      'temperature': 0.2,
      'stream': false,
    });

    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${cfg.apiKey}',
            },
            body: body,
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
