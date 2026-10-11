import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// STT 引擎配置。
class SttConfig {
  SttConfig({
    this.engine = 'openai_compat',
    this.baseUrl = 'https://api.groq.com/openai/v1',
    this.apiKey = '',
    this.model = 'whisper-large-v3-turbo',
    this.language = 'auto',
    this.fastInference = false,
  });

  /// 'openai_compat' | 'whisper_local'（本地预留）
  String engine;
  String baseUrl;
  String apiKey;
  String model;

  /// 识别语言提示，'auto' = 自动检测
  String language;

  /// 本地识别速度优先：int8_float16 量化推理（约快 1.5~2 倍，准度略降）
  bool fastInference;

  Map<String, dynamic> toJson() => {
        'engine': engine,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'language': language,
        'fastInference': fastInference,
      };

  factory SttConfig.fromJson(Map<String, dynamic> json) => SttConfig(
        engine: json['engine'] as String? ?? 'openai_compat',
        baseUrl: json['baseUrl'] as String? ??
            'https://api.groq.com/openai/v1',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? 'whisper-large-v3-turbo',
        language: json['language'] as String? ?? 'auto',
        fastInference: json['fastInference'] as bool? ?? false,
      );
}

/// 翻译引擎配置。
class TranslatorConfig {
  TranslatorConfig({
    this.engine = 'llm',
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.apiKey = '',
    this.model = 'deepseek-v4-pro',
    this.fastModel = 'deepseek-flash',
    this.sourceLang = 'auto',
    this.targetLang = 'zh',
    this.thinking = false,
    this.thinkingEffort = 'high',
    this.translationGuide = '',
    this.batchReview = true,
  });

  /// 'llm'（OpenAI 兼容 chat/completions，含 Ollama 本地）| 'nllb_local'（预留）
  String engine;
  String baseUrl;
  String apiKey;
  String model;

  /// 快速模型（可选）：临时字幕（边听边出）的翻译用它，
  /// 最终字幕用 [model]。留空 = 与主模型相同。
  String fastModel;
  String sourceLang;
  String targetLang;

  /// 思考模式（仅 DeepSeek 官方 API 且仅最终字幕生效）：
  /// 先推理再输出，译文更通顺、更贴合语境，但更慢、推理 token 也计费。
  bool thinking;

  /// 思考强度：'low' | 'high' | 'max'（DeepSeek reasoning_effort）
  String thinkingEffort;

  /// 可选的视频背景、人物称呼、术语约定；用于 LLM 实时和批量翻译。
  String translationGuide;

  /// 批量 AI 翻译后再对照原文校对一次；增加请求耗时和费用。
  bool batchReview;

  Map<String, dynamic> toJson() => {
        'engine': engine,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'fastModel': fastModel,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'thinking': thinking,
        'thinkingEffort': thinkingEffort,
        'translationGuide': translationGuide,
        'batchReview': batchReview,
      };

  factory TranslatorConfig.fromJson(Map<String, dynamic> json) =>
      TranslatorConfig(
        engine: json['engine'] as String? ?? 'llm',
        baseUrl: json['baseUrl'] as String? ?? 'https://api.deepseek.com/v1',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? 'deepseek-v4-pro',
        fastModel: json['fastModel'] as String? ?? '',
        sourceLang: json['sourceLang'] as String? ?? 'auto',
        targetLang: json['targetLang'] as String? ?? 'zh',
        thinking: json['thinking'] as bool? ?? false,
        thinkingEffort: json['thinkingEffort'] as String? ?? 'high',
        translationGuide: json['translationGuide'] as String? ?? '',
        batchReview: json['batchReview'] as bool? ?? true,
      );
}

/// 采集配置。
class CaptureConfig {
  CaptureConfig({this.mode = 'system', this.device = ''});

  /// 'system'（系统声音）| 'mic'（麦克风）
  String mode;

  /// 端点友好名称（空 = 默认设备）；可选项见设置界面设备列表
  String device;

  Map<String, dynamic> toJson() => {'mode': mode, 'device': device};

  factory CaptureConfig.fromJson(Map<String, dynamic> json) => CaptureConfig(
        mode: json['mode'] as String? ?? 'system',
        device: json['device'] as String? ?? '',
      );
}

/// 悬浮窗配置。
class OverlayConfig {
  OverlayConfig({
    this.opacity = 0.88,
    this.fontSize = 18,
    this.maxLines = 4,
    this.autoHideSeconds = 8,
  });

  double opacity;
  double fontSize;
  int maxLines;

  /// 无新字幕多少秒后自动淡出（0 = 一直显示）
  int autoHideSeconds;

  Map<String, dynamic> toJson() => {
        'opacity': opacity,
        'fontSize': fontSize,
        'maxLines': maxLines,
        'autoHideSeconds': autoHideSeconds,
      };

  factory OverlayConfig.fromJson(Map<String, dynamic> json) => OverlayConfig(
        opacity: (json['opacity'] as num?)?.toDouble() ?? 0.88,
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18,
        maxLines: json['maxLines'] as int? ?? 4,
        autoHideSeconds: json['autoHideSeconds'] as int? ?? 8,
      );
}

/// 应用配置，JSON 持久化到应用支持目录。
class AppConfig {
  AppConfig({
    SttConfig? stt,
    TranslatorConfig? translate,
    CaptureConfig? capture,
    OverlayConfig? overlay,
  })  : stt = stt ?? SttConfig(),
        translate = translate ?? TranslatorConfig(),
        capture = capture ?? CaptureConfig(),
        overlay = overlay ?? OverlayConfig();

  SttConfig stt;
  TranslatorConfig translate;
  CaptureConfig capture;
  OverlayConfig overlay;

  Map<String, dynamic> toJson() => {
        'stt': stt.toJson(),
        'translate': translate.toJson(),
        'capture': capture.toJson(),
        'overlay': overlay.toJson(),
      };

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        stt: json['stt'] is Map<String, dynamic>
            ? SttConfig.fromJson(json['stt'] as Map<String, dynamic>)
            : null,
        translate: json['translate'] is Map<String, dynamic>
            ? TranslatorConfig.fromJson(json['translate'] as Map<String, dynamic>)
            : null,
        capture: json['capture'] is Map<String, dynamic>
            ? CaptureConfig.fromJson(json['capture'] as Map<String, dynamic>)
            : null,
        overlay: json['overlay'] is Map<String, dynamic>
            ? OverlayConfig.fromJson(json['overlay'] as Map<String, dynamic>)
            : null,
      );

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}config.json');
  }

  static Future<AppConfig> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          return AppConfig.fromJson(decoded);
        }
      }
    } catch (_) {
      // 配置损坏时回退默认值
    }
    return AppConfig();
  }

  Future<void> save() async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  /// 启动监听前的基本校验，返回错误文案；null 表示通过。
  String? validate() {
    if (stt.engine != 'whisper_local' && stt.apiKey.trim().isEmpty) {
      return '请填写 STT 引擎的 API Key';
    }
    if (stt.baseUrl.trim().isEmpty) return 'STT Base URL 不能为空';
    if (stt.model.trim().isEmpty) return 'STT 模型名不能为空';
    if (translate.engine != 'nllb_local' && translate.apiKey.trim().isEmpty) {
      return '请填写翻译引擎的 API Key';
    }
    if (translate.baseUrl.trim().isEmpty) return '翻译 Base URL 不能为空';
    if (translate.model.trim().isEmpty) return '翻译模型名不能为空';
    return null;
  }
}
