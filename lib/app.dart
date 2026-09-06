import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'core/config/app_config.dart';
import 'core/overlay/overlay_window_controller.dart';
import 'core/overlay/tray_controller.dart';
import 'core/pipeline/translation_pipeline.dart';
import 'ui/overlay_view.dart';
import 'ui/settings_view.dart';

enum AppMode { settings, overlay }

class SyncTranslateApp extends StatefulWidget {
  const SyncTranslateApp({super.key, required this.initialConfig});

  final AppConfig initialConfig;

  @override
  State<SyncTranslateApp> createState() => _SyncTranslateAppState();
}

class _SyncTranslateAppState extends State<SyncTranslateApp>
    with WindowListener {
  late final AppConfig _config = widget.initialConfig;
  final _window = OverlayWindowController();
  final _tray = TrayController();
  AppMode _mode = AppMode.settings;
  TranslationPipeline? _pipeline;
  bool _quitting = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // 关闭窗口 = 隐藏到托盘，不退出（托盘右键菜单里才真正退出）
    windowManager.setPreventClose(true);
    _initTray();
  }

  Future<void> _initTray() async {
    try {
      await _tray.init(
        onShow: _showFromTray,
        onExit: _quit,
      );
    } catch (e) {
      // 平台不支持托盘（如无桌面环境）时忽略，应用仍可正常使用
    }
  }

  Future<void> _showFromTray() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _hideToTray() async {
    try {
      await windowManager.hide();
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    // 用户点击关闭按钮：隐藏到托盘（除非正在退出流程）
    if (_quitting) return;
    await _hideToTray();
  }

  Future<void> _startListening() async {
    final error = _config.validate();
    if (error != null) {
      _showMessage('无法启动：$error');
      return;
    }
    await _config.save();

    final pipeline = TranslationPipeline(config: _config);
    _pipeline = pipeline;
    setState(() => _mode = AppMode.overlay);
    try {
      await _window.enterOverlay(opacity: _config.overlay.opacity);
    } catch (e) {
      _showMessage('悬浮窗切换失败（当前平台可能未实现）: $e');
    }
    await pipeline.start();
  }

  Future<void> _backToSettings() async {
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) {
      await pipeline.stop();
      await pipeline.dispose();
    }
    setState(() => _mode = AppMode.settings);
    try {
      await _window.enterSettings();
    } catch (_) {
      // 平台不支持窗口控制时忽略
    }
  }

  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    final pipeline = _pipeline;
    if (pipeline != null) {
      await pipeline.stop();
      await pipeline.dispose();
    }
    await _tray.dispose();
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '实时翻译字幕',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF15171C),
      ),
      home: _mode == AppMode.settings
          ? SettingsView(
              config: _config,
              onStart: _startListening,
              onHideToTray: _hideToTray,
            )
          : OverlayView(
              pipeline: _pipeline!,
              maxLines: _config.overlay.maxLines,
              fontSize: _config.overlay.fontSize,
              onBackToSettings: _backToSettings,
            ),
    );
  }
}
