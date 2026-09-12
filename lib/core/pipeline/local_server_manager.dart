import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../ffi/wasapi_bindings.dart';

/// 本地模型服务异常（带用户可操作的指引）。
class LocalServerException implements Exception {
  LocalServerException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 本地模型服务管理器：自动拉起/等待 faster-whisper 与 NLLB 服务。
/// 应用内使用本地引擎时无需手动开终端；服务已运行则直接复用。
class LocalServerManager {
  LocalServerManager._();
  static final LocalServerManager instance = LocalServerManager._();

  final List<int> _spawnedPids = [];

  /// 已由本应用拉起的服务 PID（用于日志/诊断）。
  List<int> get spawnedPids => List.unmodifiable(_spawnedPids);

  /// 定位项目根目录：优先用环境变量覆盖（测试用），否则从 exe 路径向上找标记。
  static String? get projectRoot {
    final env = Platform.environment['SYNC_TRANSLATE_ROOT'];
    if (env != null && env.trim().isNotEmpty) {
      return Directory(env.trim()).existsSync() ? env.trim() : null;
    }
    try {
      var dir = File(Platform.resolvedExecutable).parent;
      for (var i = 0; i < 6; i++) {
        final marker = File('${dir.path}${Platform.pathSeparator}tool'
            '${Platform.pathSeparator}local_servers'
            '${Platform.pathSeparator}whisper_server.py');
        if (marker.existsSync()) return dir.path;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    } catch (_) {}
    return null;
  }

  /// venv 里的 python 解释器路径；不存在返回 null。
  static String? get venvPython {
    final root = projectRoot;
    if (root == null) return null;
    final p = '$root${Platform.pathSeparator}tool'
        '${Platform.pathSeparator}local_servers'
        '${Platform.pathSeparator}venv'
        '${Platform.pathSeparator}Scripts'
        '${Platform.pathSeparator}python.exe';
    return File(p).existsSync() ? p : null;
  }

  static String _healthUrl(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    return uri.replace(path: '/health', query: '', fragment: '').toString();
  }

  /// 服务是否已就绪。
  static Future<bool> isHealthy(String baseUrl) async {
    try {
      final resp = await http
          .get(Uri.parse(_healthUrl(baseUrl)))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200 && resp.body.contains('"ok":true');
    } catch (_) {
      return false;
    }
  }

  /// 运行中服务当前加载的模型名（无则返回 null）。
  static Future<String?> serverModel(String baseUrl) async {
    try {
      final resp = await http
          .get(Uri.parse(_healthUrl(baseUrl)))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) {
          return decoded['model'] as String?;
        }
      }
    } catch (_) {}
    return null;
  }

  static String _basename(String s) =>
      s.split(RegExp(r'[\\/]')).last.toLowerCase();

  /// 停止占用指定端口的进程（Windows；用于模型切换时重启服务）。
  static Future<void> killPortListener(int port) async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('powershell', [
        '-NoProfile', '-Command',
        'Get-NetTCPConnection -LocalPort $port -State Listen '
            '-ErrorAction SilentlyContinue | '
            'Select-Object -ExpandProperty OwningProcess | '
            'Sort-Object -Unique | ForEach-Object { Stop-Process -Id \$_ -Force }',
      ]);
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 2));
  }

  /// 确保某个本地服务在运行：健康且模型匹配则直接返回 null；
  /// 模型不匹配则重启服务；未运行则从项目 venv 后台拉起并等待就绪，返回新进程 PID。
  /// 环境不完整（缺 venv/项目目录）时抛出带指引的 [LocalServerException]。
  Future<int?> ensureServerRunning({
    required String script,
    required List<String> args,
    required String healthBase,
    String? requiredModel,
  }) async {
    if (await isHealthy(healthBase)) {
      if (requiredModel == null) return null;
      final current = await serverModel(healthBase);
      final match = current != null &&
          (_basename(current) == _basename(requiredModel));
      if (match) return null;
      // 配置的模型与运行中不一致：重启服务
      final port = Uri.tryParse(healthBase)?.port;
      if (port != null) await killPortListener(port);
      if (await isHealthy(healthBase)) return null; // 未杀成则继续复用
    }

    if (!Platform.isWindows) {
      throw LocalServerException(
          '当前平台不支持自动启动本地服务，请手动运行: $script');
    }
    final py = venvPython;
    final root = projectRoot;
    if (py == null || root == null) {
      throw LocalServerException(
          '未找到本地模型环境。请在项目目录执行：\n'
          'powershell -ExecutionPolicy Bypass -File tool\\local_servers\\setup.ps1\n'
          '然后运行 tool\\local_servers\\download_models.ps1 下载模型。');
    }

    final serversDir = '$root${Platform.pathSeparator}tool'
        '${Platform.pathSeparator}local_servers';
    final logDir = '$serversDir${Platform.pathSeparator}logs';
    Directory(logDir).createSync(recursive: true);
    final logFile = '$logDir${Platform.pathSeparator}$script.log';

    String quoted(String s) => '"$s"';
    final cmdline = [
      quoted(py),
      quoted('$serversDir${Platform.pathSeparator}$script'),
      ...args.map(quoted),
    ].join(' ');

    final pid = WasapiBindings.instance.spawnHidden(cmdline);
    if (pid <= 0) {
      throw LocalServerException(
          '启动本地服务失败（$script）: ${WasapiBindings.instance.lastError()}\n'
          '日志: $logFile');
    }
    _spawnedPids.add(pid);

    // 等待就绪（首次加载模型可能需要数十秒）
    final deadline = DateTime.now().add(const Duration(seconds: 150));
    while (DateTime.now().isBefore(deadline)) {
      if (await isHealthy(healthBase)) return pid;
      await Future.delayed(const Duration(seconds: 2));
    }
    throw LocalServerException(
        '本地服务启动超时: $script\n（模型首次加载较慢，查看日志: $logFile）');
  }
}
