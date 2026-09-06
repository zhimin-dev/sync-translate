import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

class _AppTrayListener with TrayListener {
  _AppTrayListener({required this.onShow, required this.onExit});

  final Future<void> Function() onShow;
  final Future<void> Function() onExit;

  @override
  void onTrayIconMouseDown() => onShow();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        onShow();
        break;
      case 'exit':
        onExit();
        break;
    }
  }
}

/// 系统托盘常驻控制器（Windows 右下角 / macOS 右上角菜单栏）。
/// 关闭主窗口只是隐藏到托盘，右键托盘图标 → 退出 才真正结束进程。
class TrayController {
  Future<void> init({
    required Future<void> Function() onShow,
    required Future<void> Function() onExit,
  }) async {
    final log = <String>[];
    Future<void> step(String name, Future<void> Function() fn) async {
      try {
        await fn();
        log.add('OK   $name');
      } catch (e) {
        log.add('ERR  $name: $e');
        rethrow;
      }
    }

    try {
      await step(
          'setIcon', () => trayManager.setIcon('assets/tray_icon.ico'));
      await step('setToolTip',
          () => trayManager.setToolTip('实时翻译字幕（右键退出）'));
      await step(
          'setContextMenu',
          () => trayManager.setContextMenu(Menu(items: [
                MenuItem(key: 'show', label: '显示主界面'),
                MenuItem.separator(),
                MenuItem(key: 'exit', label: '退出'),
              ])));
      trayManager
          .addListener(_AppTrayListener(onShow: onShow, onExit: onExit));
      log.add('OK   addListener');
    } catch (e) {
      log.add('FATAL: $e');
    } finally {
      _writeLog(log);
    }
  }

  Future<void> dispose() async {
    try {
      await trayManager.destroy();
    } catch (_) {}
  }

  void _writeLog(List<String> lines) {
    try {
      final dir = '${Platform.environment['APPDATA']}'
          '${Platform.pathSeparator}com.synctranslate'
          '${Platform.pathSeparator}sync_translate';
      File('$dir${Platform.pathSeparator}tray.log')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
            '[${DateTime.now().toIso8601String()}]\n${lines.join('\n')}\n',
            mode: FileMode.append);
    } catch (_) {}
  }
}
