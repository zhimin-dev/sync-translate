import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// 批量离线字幕服务客户端（后端 = whisper_server.py 的 /batch/* 接口）。
class BatchSubtitleService {
  BatchSubtitleService({required this.baseUrl});

  /// whisper 服务 base（如 http://127.0.0.1:8000/v1）
  final String baseUrl;

  String get _base {
    final uri = Uri.parse(baseUrl);
    return '${uri.scheme}://${uri.authority}';
  }

  Future<void> _checkTranslatorSupport(TranslatorConfig? translator) async {
    if (translator == null || translator.engine != 'llm') return;
    final response = await http
        .get(Uri.parse('$_base/health'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final capabilities = data is Map ? data['capabilities'] : null;
      if (capabilities is List &&
          capabilities.contains('context_translation_v1') &&
          (!translator.batchReview ||
              capabilities.contains('translation_review_v1'))) return;
    }
    throw Exception('本地字幕服务版本过旧，请重启 whisper_server.py 后再翻译，'
        '以确保使用所选 AI 模型。');
  }

  /// 提交一个音视频文件到批量队列，返回任务 ID。
  Future<String> submit({
    required String path,
    required String targetLang,
    String? sourceLang,
    String? modelDir,
    TranslatorConfig? translator,
  }) async {
    await _checkTranslatorSupport(translator);
    final resp = await http
        .post(
          Uri.parse('$_base/batch/transcribe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'path': path,
            'target_lang': targetLang,
            if (translator != null) 'translator': translator.toJson(),
            if (sourceLang != null && sourceLang.isNotEmpty)
              'source_lang': sourceLang,
            if (modelDir != null && modelDir.isNotEmpty) 'model_dir': modelDir,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception(
          '提交失败 HTTP ${resp.statusCode}: ${_truncate(resp.body)}');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    final id = (decoded as Map<String, dynamic>)['job_id'];
    if (id is! String || id.isEmpty) {
      throw Exception('提交失败：响应缺少 job_id');
    }
    return id;
  }

  /// 提交一个 SRT 文件到翻译队列（保留时间轴，仅翻译文本），返回任务 ID。
  Future<String> submitSrt({
    required String path,
    required String targetLang,
    String? sourceLang,
    String? modelDir,
    TranslatorConfig? translator,
  }) async {
    await _checkTranslatorSupport(translator);
    final resp = await http
        .post(
          Uri.parse('$_base/batch/translate-srt'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'path': path,
            'target_lang': targetLang,
            if (translator != null) 'translator': translator.toJson(),
            if (sourceLang != null && sourceLang.isNotEmpty)
              'source_lang': sourceLang,
            if (modelDir != null && modelDir.isNotEmpty) 'model_dir': modelDir,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception(
          '提交失败 HTTP ${resp.statusCode}: ${_truncate(resp.body)}');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    final id = (decoded as Map<String, dynamic>)['job_id'];
    if (id is! String || id.isEmpty) {
      throw Exception('提交失败：响应缺少 job_id');
    }
    return id;
  }

  /// 查询任务状态。
  Future<Map<String, dynamic>> status(String jobId) async {
    final resp = await http
        .get(Uri.parse('$_base/batch/status?job_id=$jobId'))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('查询失败 HTTP ${resp.statusCode}');
    }
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  static String _truncate(String s, [int max = 300]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}

/// 批量任务在应用侧的状态。
class BatchItem {
  BatchItem(this.path, {this.kind = 'video'});

  final String path;

  /// 'video'（视频转写）| 'srt'（纯字幕翻译）
  final String kind;
  String? jobId;
  String status = '待提交';
  double progress = 0;
  String? srtPath;
  String? origSrtPath;
  String? error;
  String? warning;
  String? translationEngine;
  String? translationModel;
  double? duration;

  String get fileName => path.split(RegExp(r'[\\/]')).last;

  bool get running => status == '排队中' || status == '解码音频' ||
      status == '识别中' || status == '翻译中' ||
      status == '解析字幕' || status == '待提交';

  bool get done => status == '完成';

  String get statusText {
    switch (status) {
      case '待提交':
        return '待提交';
      case '排队中':
        return '排队中';
      case '解码音频':
        return '解码音频中…';
      case '识别中':
        return '语音识别中…';
      case '解析字幕':
        return '解析字幕中…';
      case '翻译中':
        return '翻译中…';
      case '完成':
        return '完成';
      case '失败':
        return '失败';
      default:
        return status;
    }
  }
}
