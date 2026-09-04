import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/config/app_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(920, 640),
    minimumSize: Size(760, 560),
    center: true,
    title: '实时翻译字幕',
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );

  // 单窗口双形态：设置形态 / 悬浮字幕形态，均使用无边框 + 自定义标题栏。
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    await windowManager.show();
    await windowManager.focus();
  });

  final config = await AppConfig.load();
  runApp(SyncTranslateApp(initialConfig: config));
}
