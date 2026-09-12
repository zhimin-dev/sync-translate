import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../pipeline/local_server_manager.dart';
import '../../ffi/wasapi_bindings.dart';

/// 本地识别模型规格。
class ModelSpec {
  const ModelSpec(this.name, this.label, this.files);

  /// HF 仓库名（如 Systran/faster-whisper-large-v3）
  final String name;

  /// 界面显示名
  final String label;

  /// 需要的仓库文件
  final List<String> files;

  String get dirName => name.split('/').last;
}

/// 内置可选模型目录（本地 Whisper 引擎）。
const List<ModelSpec> kLocalWhisperModels = [
  ModelSpec('Systran/faster-whisper-large-v3', 'large-v3 完整版（最准确）', [
    'config.json', 'model.bin', 'preprocessor_config.json',
    'tokenizer.json', 'vocabulary.json',
  ]),
  ModelSpec('deepdml/faster-whisper-large-v3-turbo-ct2',
      'large-v3-turbo（速度优先）', [
    'config.json', 'model.bin', 'preprocessor_config.json',
    'tokenizer.json', 'vocabulary.json',
  ]),
  ModelSpec('Systran/faster-whisper-small', 'small（CPU 低配友好）', [
    'config.json', 'model.bin', 'preprocessor_config.json',
    'tokenizer.json', 'vocabulary.json',
  ]),
];

/// 模型下载管理器：选择未下载的模型后自动后台下载（断点续传），
/// 下载完成后写 .ok 标记；开始监听前校验模型已就绪。
class ModelManager {
  ModelManager._();
  static final ModelManager instance = ModelManager._();

  /// 各模型的下载字节数（进度展示用）
  final ValueNotifier<Map<String, int>> progress =
      ValueNotifier<Map<String, int>>({});

  final Map<String, Timer> _pollers = {};

  /// 模型目录（项目根 `tool/local_servers/models/<basename>`）。
  static String? modelDir(String modelName) {
    final root = LocalServerManager.projectRoot;
    if (root == null) return null;
    return '$root${Platform.pathSeparator}tool'
        '${Platform.pathSeparator}local_servers'
        '${Platform.pathSeparator}models'
        '${Platform.pathSeparator}${modelName.split('/').last}';
  }

  /// 模型是否已下载完成。
  static bool isDownloaded(String modelName) {
    final dir = modelDir(modelName);
    if (dir == null) return false;
    return File('$dir${Platform.pathSeparator}download.ok').existsSync();
  }

  /// 模型文件已下载的字节数（进度展示）。
  static int downloadedBytes(String modelName) {
    final dir = modelDir(modelName);
    if (dir == null) return 0;
    final d = Directory(dir);
    if (!d.existsSync()) return 0;
    var total = 0;
    for (final f in d.listSync().whereType<File>()) {
      total += f.lengthSync();
    }
    return total;
  }

  /// 查找模型规格。
  static ModelSpec? specOf(String modelName) {
    for (final m in kLocalWhisperModels) {
      if (m.name.toLowerCase() == modelName.toLowerCase()) return m;
    }
    return null;
  }

  /// 开始下载模型（若未下载）。
  /// 返回：1=已就绪；0=已启动后台下载（进度见 [progress]）；-1=无法下载
  /// （自定义模型不在内置目录 / 环境不完整 / 启动失败）。
  /// 下载完成后轮询器会自动更新 [progress]。
  Future<int> ensureDownloaded(String modelName) async {
    if (isDownloaded(modelName)) return 1;
    final spec = specOf(modelName);
    if (spec == null) return -1; // 自定义模型：需用户手动准备
    final dir = modelDir(modelName);
    if (dir == null) return -1;
    final root = LocalServerManager.projectRoot;
    if (root == null) return -1;

    if (_pollers.containsKey(modelName)) return 0; // 已在下载

    // 启动隐藏下载进程（PowerShell + curl 断点续传）
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
      if (isDownloaded(modelName)) {
        _pollers.remove(modelName)?.cancel();
        _updateProgress(modelName);
      }
    });
    return 0;
  }

  void _updateProgress(String modelName) {
    final map = Map<String, int>.from(progress.value);
    map[modelName] = downloadedBytes(modelName);
    progress.value = map;
  }
}
