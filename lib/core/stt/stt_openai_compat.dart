import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../config/app_config.dart';
import 'stt_engine.dart';
import 'wav_encoder.dart';

/// OpenAI 兼容 STT 引擎：POST {baseUrl}/audio/transcriptions。
/// 兼容 OpenAI / Groq / SiliconFlow / DeepInfra 等提供该接口的服务。
class OpenAiCompatSttEngine implements SttEngine {
  @override
  String get id => 'openai_compat';

  SttConfig? _config;
  final _client = http.Client();

  @override
  Future<void> init(SttConfig config) async {
    _config = config;
    if (config.apiKey.trim().isEmpty) {
      throw StateError('STT API Key 未配置');
    }
    if (config.baseUrl.trim().isEmpty) {
      throw StateError('STT Base URL 未配置');
    }
  }

  @override
  Future<String> transcribe(Float32List pcm16k, {String? language}) async {
    final cfg = _config;
    if (cfg == null) throw StateError('STT 引擎未初始化');
    final base = cfg.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/audio/transcriptions');
    final wav = encodeWavPcm16(pcm16k);

    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Bearer ${cfg.apiKey}';
    request.fields['model'] = cfg.model;
    request.fields['response_format'] = 'json';
    final lang = language ?? (cfg.language == 'auto' ? null : cfg.language);
    if (lang != null && lang.isNotEmpty) request.fields['language'] = lang;
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      wav,
      filename: 'audio.wav',
      contentType: MediaType('audio', 'wav'),
    ));

    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw SttException('STT 请求超时（30s）');
    } catch (e) {
      throw SttException('STT 网络错误: $e');
    }
    final body = await response.stream.bytesToString()
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw SttException(
          'STT HTTP ${response.statusCode}: ${_truncate(body)}');
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not a JSON object');
      }
      final text = decoded['text'];
      if (text is! String) {
        throw FormatException('missing text field');
      }
      return text;
    } catch (e) {
      throw SttException('STT 响应解析失败: ${_truncate(body)}');
    }
  }

  @override
  Future<void> dispose() async {
    _client.close();
  }

  static String _truncate(String s, [int max = 300]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
