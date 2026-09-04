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
  });

  /// 'openai_compat' | 'whisper_local'（本地预留）
  String engine;
  String baseUrl;
  String apiKey;
  String model;

  /// 识别语言提示，'auto' = 自动检测
  String language;

  Map<String, dynamic> toJson() => {
        'engine': engine,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'language': language,
      };

  factory SttConfig.fromJson(Map<String, dynamic> json) => SttConfig(
        engine: json['engine'] as String? ?? 'openai_compat',
        baseUrl: json['baseUrl'] as String? ??
            'https://api.groq.com/openai/v1',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? 'whisper-large-v3-turbo',
        language: json['language'] as String? ?? 'auto',
      );
}

/// 翻译引擎配置。
class TranslatorConfig {
  TranslatorConfig({
    this.engine = 'llm',
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.apiKey = '',
    this.model = 'deepseek-chat',
    this.sourceLang = 'auto',
    this.targetLang = 'zh',
  });

  /// 'llm'（OpenAI 兼容 chat/completions，含 Ollama 本地）| 'nllb_local'（预留）
  String engine;
  String baseUrl;
  String apiKey;
  String model;
  String sourceLang;
  String targetLang;

  Map<String, dynamic> toJson() => {
        'engine': engine,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
      };

  factory TranslatorConfig.fromJson(Map<String, dynamic> json) =>
      TranslatorConfig(
        engine: json['engine'] as String? ?? 'llm',
        baseUrl: json['baseUrl'] as String? ?? 'https://api.deepseek.com/v1',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? 'deepseek-chat',
        sourceLang: json['sourceLang'] as String? ?? 'auto',
        targetLang: json['targetLang'] as String? ?? 'zh',
      );
}

/// 采集配置。
class CaptureConfig {
  CaptureConfig({this.mode = 'system'});

  /// 'system'（系统声音）| 'mic'（麦克风）
  String mode;

  Map<String, dynamic> toJson() => {'mode': mode};

  factory CaptureConfig.fromJson(Map<String, dynamic> json) =>
      CaptureConfig(mode: json['mode'] as String? ?? 'system');
}

/// 悬浮窗配置。
class OverlayConfig {
  OverlayConfig({
    this.opacity = 0.88,
    this.fontSize = 18,
    this.maxLines = 4,
  });

  double opacity;
  double fontSize;
  int maxLines;

  Map<String, dynamic> toJson() => {
        'opacity': opacity,
        'fontSize': fontSize,
        'maxLines': maxLines,
      };

  factory OverlayConfig.fromJson(Map<String, dynamic> json) => OverlayConfig(
        opacity: (json['opacity'] as num?)?.toDouble() ?? 0.88,
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18,
        maxLines: json['maxLines'] as int? ?? 4,
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
