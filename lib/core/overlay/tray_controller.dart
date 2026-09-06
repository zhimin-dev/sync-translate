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
    await trayManager.setIcon('assets/tray_icon.ico');
    await trayManager.setToolTip('实时翻译字幕（右键退出）');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '显示主界面'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: '退出'),
    ]));
    trayManager.addListener(_AppTrayListener(onShow: onShow, onExit: onExit));
  }

  Future<void> dispose() async {
    try {
      await trayManager.destroy();
    } catch (_) {}
  }
}
