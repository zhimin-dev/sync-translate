import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'translator.dart';

/// 本地 NLLB-200 翻译引擎：连接本地翻译服务（tool/local_servers/nllb_server.py），
/// 无需 API Key。默认地址 http://127.0.0.1:8765。
class LocalTranslator implements Translator {
  @override
  String get id => 'nllb_local';

  TranslatorConfig? _config;
  final _client = http.Client();

  @override
  Future<void> init(TranslatorConfig config) async {
    _config = config;
    if (config.baseUrl.trim().isEmpty) {
      throw StateError('NLLB 服务地址未配置');
    }
  }

  @override
  Future<String> translate(String text,
      {String? sourceLang,
      String? targetLang,
      String? context,
      bool provisional = false}) async {
    final cfg = _config;
    if (cfg == null) throw StateError('翻译引擎未初始化');
    final base = cfg.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/translate');
    final body = jsonEncode({
      'text': text,
      if (sourceLang != null && sourceLang.isNotEmpty)
        'source_lang': sourceLang,
      'target_lang': targetLang ?? cfg.targetLang,
    });

    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw TranslateException('本地翻译超时（30s）');
    } catch (e) {
      throw TranslateException(
          '无法连接 NLLB 服务（${cfg.baseUrl}）: $e\n'
          '请先运行 tool\\local_servers\\start_nllb.ps1');
    }
    if (response.statusCode != 200) {
      throw TranslateException(
          '本地翻译 HTTP ${response.statusCode}: ${_truncate(response.body)}');
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not a JSON object');
      }
      final translation = decoded['translation'];
      if (translation is! String) {
        throw FormatException('missing translation field');
      }
      return translation.trim();
    } catch (e) {
      throw TranslateException('本地翻译响应解析失败: ${_truncate(response.body)}');
    }
  }

  @override
  Future<void> dispose() async {
    _client.close();
  }

  static String _truncate(String s, [int max = 300]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
