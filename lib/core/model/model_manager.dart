import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../pipeline/local_server_manager.dart';
import '../../ffi/wasapi_bindings.dart';

/// 模型规格（本地或云端）。
class ModelSpec {
  const ModelSpec(
    this.name,
    this.label,
    this.type, {
    this.remote = false,
    this.baseUrl = '',
    this.dirName,
    required this.files,
  });

  /// HF 仓库名（如 Systran/faster-whisper-large-v3）或云端模型名
  final String name;

  /// 界面显示名
  final String label;

  /// 'stt'（识别）| 'mt'（翻译）
  final String type;

  /// 是否云端模型（远程 API）
  final bool remote;

  /// 云端模型的默认 Base URL
  final String baseUrl;

  /// 本地模型目录名（默认取 name 的 basename；NLLB 用 -- 替换 /）
  final String? dirName;

  /// 本地模型需要的仓库文件
  final List<String> files;

  String get dir => dirName ?? name.split('/').last;
}

/// 识别（STT）模型目录。
const List<ModelSpec> kSttModels = [
  // 本地
  ModelSpec('Systran/faster-whisper-large-v3', 'large-v3 完整版（最准确）', 'stt',
      files: ['config.json', 'model.bin', 'preprocessor_config.json', 'tokenizer.json', 'vocabulary.json']),
  ModelSpec('deepdml/faster-whisper-large-v3-turbo-ct2', 'large-v3-turbo（速度优先）', 'stt',
      files: ['config.json', 'model.bin', 'preprocessor_config.json', 'tokenizer.json', 'vocabulary.json']),
  ModelSpec('Systran/faster-whisper-small', 'small（CPU 低配友好）', 'stt',
      files: ['config.json', 'model.bin', 'preprocessor_config.json', 'tokenizer.json', 'vocabulary.json']),
  // 云端
  ModelSpec('whisper-large-v3-turbo', 'whisper-large-v3-turbo（Groq）', 'stt',
      remote: true, baseUrl: 'https://api.groq.com/openai/v1', files: []),
  ModelSpec('whisper-1', 'whisper-1（OpenAI）', 'stt',
      remote: true, baseUrl: 'https://api.openai.com/v1', files: []),
  ModelSpec('FunAudioLLM/SenseVoiceSmall', 'SenseVoiceSmall（SiliconFlow 国内）', 'stt',
      remote: true, baseUrl: 'https://api.siliconflow.cn/v1', files: []),
];

/// 翻译（MT）模型目录。
const List<ModelSpec> kMtModels = [
  // 本地
  ModelSpec('facebook/nllb-200-distilled-600M', 'NLLB-200 600M（本地·快）', 'mt',
      dirName: 'facebook--nllb-200-distilled-600M',
      files: ['config.json', 'generation_config.json', 'pytorch_model.bin',
          'sentencepiece.bpe.model', 'special_tokens_map.json',
          'tokenizer.json', 'tokenizer_config.json']),
  ModelSpec('facebook/nllb-200-distilled-1.3B', 'NLLB-200 1.3B（本地·质量更好）', 'mt',
      dirName: 'facebook--nllb-200-distilled-1.3B',
      files: ['config.json', 'generation_config.json', 'pytorch_model.bin',
          'sentencepiece.bpe.model', 'special_tokens_map.json',
          'tokenizer.json', 'tokenizer_config.json']),
  // 云端
  ModelSpec('deepseek-v4-pro', 'deepseek-v4-pro（DeepSeek 高质量）', 'mt',
      remote: true, baseUrl: 'https://api.deepseek.com/v1', files: []),
  ModelSpec('deepseek-flash', 'deepseek-flash（DeepSeek 快速便宜）', 'mt',
      remote: true, baseUrl: 'https://api.deepseek.com/v1', files: []),
  ModelSpec('gpt-4o-mini', 'gpt-4o-mini（OpenAI）', 'mt',
      remote: true, baseUrl: 'https://api.openai.com/v1', files: []),
  ModelSpec('deepseek-ai/DeepSeek-V3', 'DeepSeek-V3（SiliconFlow 国内）', 'mt',
      remote: true, baseUrl: 'https://api.siliconflow.cn/v1', files: []),
];

/// 模型下载管理器：选择未下载的本地模型后自动后台下载（断点续传），
/// 下载完成后写 download.ok 标记；开始监听前校验模型已就绪。
class ModelManager {
  ModelManager._();
  static final ModelManager instance = ModelManager._();

  /// 各模型的下载字节数（进度展示用）
  final ValueNotifier<Map<String, int>> progress =
      ValueNotifier<Map<String, int>>({});

  final Map<String, Timer> _pollers = {};

  static List<ModelSpec> modelsOf(String type) =>
      type == 'stt' ? kSttModels : kMtModels;

  /// 按类型+模型名查找规格。
  static ModelSpec? specOf(String type, String modelName) {
    for (final m in modelsOf(type)) {
      if (m.name.toLowerCase() == modelName.toLowerCase()) return m;
    }
    return null;
  }

  /// 模型目录（项目根 `tool/local_servers/models/<dir>`）。
  static String? modelDir(String type, String modelName) {
    final spec = specOf(type, modelName);
    if (spec == null) return null;
    final root = LocalServerManager.projectRoot;
    if (root == null) return null;
    return '$root${Platform.pathSeparator}tool'
        '${Platform.pathSeparator}local_servers'
        '${Platform.pathSeparator}models'
        '${Platform.pathSeparator}${spec.dir}';
  }

  /// 本地模型是否已下载完成。
  static bool isDownloaded(String type, String modelName) {
    final dir = modelDir(type, modelName);
    if (dir == null) return false;
    return File('$dir${Platform.pathSeparator}download.ok').existsSync();
  }

  /// 模型文件已下载的字节数（进度展示）。
  static int downloadedBytes(String type, String modelName) {
    final dir = modelDir(type, modelName);
    if (dir == null) return 0;
    final d = Directory(dir);
    if (!d.existsSync()) return 0;
    var total = 0;
    for (final f in d.listSync().whereType<File>()) {
      total += f.lengthSync();
    }
    return total;
  }

  /// 开始下载本地模型（若未下载）。
  /// 返回：1=已就绪；0=已启动后台下载（进度见 [progress]）；-1=无法下载。
  Future<int> ensureDownloaded(String type, String modelName) async {
    if (isDownloaded(type, modelName)) return 1;
    final spec = specOf(type, modelName);
    if (spec == null || spec.remote) return -1;
    final dir = modelDir(type, modelName);
    if (dir == null) return -1;
    final root = LocalServerManager.projectRoot;
    if (root == null) return -1;

    if (_pollers.containsKey(modelName)) return 0; // 已在下载

    final script = '$root${Platform.pathSeparator}tool'
        '${Platform.pathSeparator}local_servers'
        '${Platform.pathSeparator}download_model.ps1';
    String quoted(String s) => '"$s"';
    final cmdline = [
      quoted('powershell'),
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', quoted(script),
      '-Repo', quoted(spec.name),
      '-Dir', quoted(dir),
      '-Files', quoted(spec.files.join(',')),
    ].join(' ');
    final pid = WasapiBindings.instance.spawnHidden(cmdline);
    if (pid <= 0) return -1;

    _updateProgress(modelName);
    _pollers[modelName] =
        Timer.periodic(const Duration(seconds: 2), (_) async {
      _updateProgress(modelName);
      if (isDownloaded(type, modelName)) {
        _pollers.remove(modelName)?.cancel();
        _updateProgress(modelName);
      }
    });
    return 0;
  }

  void _updateProgress(String modelName) {
    final map = Map<String, int>.from(progress.value);
    map[modelName] = 0;
    for (final m in [...kSttModels, ...kMtModels]) {
      if (m.name == modelName) {
        map[modelName] = downloadedBytes(m.type, m.name);
      }
    }
    progress.value = map;
  }
}

