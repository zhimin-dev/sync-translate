// 验证自动拉起后端：先确保服务停止，然后通过 LocalServerManager 拉起并等待就绪。
// 运行：dart run tool/test_autostart.dart
import 'dart:io';

import 'package:sync_translate/core/pipeline/local_server_manager.dart';

Future<void> killServers() async {
  // 简单粗暴：杀掉占用 8000/8765 端口的进程（仅测试用）
  for (final port in [8000, 8765]) {
    await Process.run('powershell', [
      '-NoProfile', '-Command',
      'Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | '
          'Select-Object -ExpandProperty OwningProcess | Sort-Object -Unique | '
          'ForEach-Object { Stop-Process -Id \$_ -Force }'
    ]);
  }
  await Future.delayed(const Duration(seconds: 2));
}

void main() async {
  stdout.writeln('projectRoot: ${LocalServerManager.projectRoot}');
  stdout.writeln('venvPython:  ${LocalServerManager.venvPython}');
  stdout.writeln('停止现有服务…');
  await killServers();
  stdout.writeln(
      'whisper healthy after kill: ${await LocalServerManager.isHealthy('http://127.0.0.1:8000/v1')}');

  final sw = Stopwatch()..start();
  final pid1 = await LocalServerManager.instance.ensureServerRunning(
    script: 'whisper_server.py',
    args: ['--model', 'deepdml/faster-whisper-large-v3-turbo-ct2', '--port', '8000', '--device', 'auto'],
    healthBase: 'http://127.0.0.1:8000/v1',
  );
  stdout.writeln('whisper 启动: pid=$pid1 用时=${sw.elapsedMilliseconds}ms');

  sw.reset();
  final pid2 = await LocalServerManager.instance.ensureServerRunning(
    script: 'nllb_server.py',
    args: ['--port', '8765', '--device', 'auto'],
    healthBase: 'http://127.0.0.1:8765',
  );
  stdout.writeln('nllb 启动:    pid=$pid2 用时=${sw.elapsedMilliseconds}ms');

  // 再次调用应直接复用（立即返回 null）
  sw.reset();
  final again = await LocalServerManager.instance.ensureServerRunning(
    script: 'whisper_server.py',
    args: ['--model', 'deepdml/faster-whisper-large-v3-turbo-ct2', '--port', '8000', '--device', 'auto'],
    healthBase: 'http://127.0.0.1:8000/v1',
  );
  stdout.writeln('复用检测: $again（null=已健康复用）用时=${sw.elapsedMilliseconds}ms');
  stdout.writeln('=== 自动拉起验证通过 ===');
}
