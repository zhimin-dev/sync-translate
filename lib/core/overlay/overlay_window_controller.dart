import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 单窗口双形态控制器（Windows MVP）：
/// - 设置形态：常规大小、可缩放、任务栏可见
/// - 悬浮字幕形态：置顶、跳过任务栏、半透明、固定底部居中
class OverlayWindowController {
  static const Size overlaySize = Size(780, 260);
  static const Size settingsSize = Size(920, 640);
  static const Size settingsMinSize = Size(760, 560);

  Future<void> enterOverlay({required double opacity}) async {
    await windowManager.setMinimumSize(Size.zero);
    await windowManager.setResizable(false);
    await windowManager.setSize(overlaySize);
    await windowManager.setAlignment(Alignment.bottomCenter);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setOpacity(opacity.clamp(0.3, 1.0));
  }

  Future<void> enterSettings() async {
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.setOpacity(1.0);
    await windowManager.setResizable(true);
    await windowManager.setMinimumSize(settingsMinSize);
    await windowManager.setSize(settingsSize);
    await windowManager.center();
  }

  Future<void> close() => windowManager.destroy();

  Future<void> minimize() => windowManager.minimize();

  Future<void> startDragging() => windowManager.startDragging();
}
