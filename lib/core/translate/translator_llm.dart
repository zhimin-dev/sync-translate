import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'translator.dart';

/// LLM 翻译引擎：POST {baseUrl}/chat/completions（OpenAI 兼容）。
/// 兼容 OpenAI / DeepSeek / SiliconFlow / Ollama（http://localhost:11434/v1）等。
///
/// 质量设计：
/// - 字幕翻译专用 system 提示词（中文目标含"反翻译腔"禁令与少样本风格示例）；
/// - 把前几句对白的「原文 → 译文」成对上下文一起发送（消歧义 + 术语一致）；
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
    final isZh = target.toLowerCase().replaceAll('-', '').startsWith('zh');
    final sourceHint = sourceLang == null || sourceLang.isEmpty
        ? '（自动检测源语言）'
        : '从 "$sourceLang"';

    // 目标语言为中文时用中文准则（对"翻译腔"给出明确禁令与例句），
    // 其他语言用通用英文准则。
    final systemPrompt = isZh
        ? '你是一名资深影视字幕翻译，负责把对白$sourceHint翻译成 "$target"。'
            '目标：观众看电影时读起来像原生中文字幕，而不是"翻译出来的中文"。\n'
            '\n'
            '翻译准则：\n'
            '1. 意译优先：翻译意思和语气，绝不逐字直译；可重组语序、调整断句，'
            '译文要像中文母语者写的电影字幕。\n'
            '2. 坚决避免翻译腔：不用"被…所…""进行了…""对于…而言""关于…的事情"'
            '"有着…的…""不得不说的是"等生硬结构；被动句尽量转成主动句；'
            '能用中文现成说法就不用西式长句。\n'
            '3. 口语化：对白要像人嘴里说出来的话；语气词（啊、吧、嘛、呢、呀）'
            '用在自然的地方，不滥用；短句优先。\n'
            '4. 成语、俚语、双关、网络梗：按含义意译，不硬译字面。\n'
            '5. 保留语气与情绪：惊讶、讽刺、愤怒、撒娇、敬语（您/尊称）、'
            '礼貌程度都要体现出来。\n'
            '6. 专有名词不译：人名、地名、品牌名保留原文。\n'
            '7. 上下文一致：称呼、名字、术语与上文保持一致；原文省略主语时'
            '按上下文补全，保证每句单独看也读得通。\n'
            '8. 简洁但不丢信息：字幕要短，意思必须完整，不擅自增删情节信息。\n'
            '9. 只输出译文本身：不要解释、不要引号、不要多余文字。\n'
            '10. 原文已经是 "$target" 则原样输出。\n'
            '\n'
            '参考风格示例：\n'
            '- "You can say that again." → 可不是嘛。\n'
            '- "I\'ve got your back." → 有我在呢。\n'
            '- "That\'s the last straw." → 我受够了。\n'
            '- "You\'re kidding, right?" → 你开玩笑的吧？\n'
            '- "仕方ないな。" → 真拿你没办法。'
        : 'You are a professional subtitle translator for movies, TV shows '
            'and videos. Translate the user\'s message $sourceHint into '
            '"$target".\n'
            'Rules:\n'
            '1. Translate the MEANING, not the words. Reorder clauses freely '
            'so the result reads like natural, fluent movie subtitles in '
            '"$target".\n'
            '2. Prefer 意译 over literal translation: idioms, slang and '
            'colloquial expressions should be rendered by their meaning.\n'
            '3. Preserve the speaker\'s tone and emotion.\n'
            '4. Keep proper nouns in their original language.\n'
            '5. Be concise: subtitles are short, but keep the meaning complete.\n'
            '6. Stay consistent with the context lines provided by the user.\n'
            '7. Output ONLY the translation itself: no explanations, no '
            'quotes, no extra text.\n'
            '8. If the text is already in "$target", output it unchanged.';

    // 带上文：前几句对白的「原文 → 译文」成对上下文
    //（原文帮助消解源语言歧义，译文帮助保持术语/称呼一致）
    final userContent = (context == null || context.trim().isEmpty)
        ? text
        : '前文对白（原文 → 译文，仅供理解上下文）：\n'
            '$context\n'
            '\n'
            '当前对白：\n'
            '$text';

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
