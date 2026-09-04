import 'package:flutter/material.dart';

import 'core/config/app_config.dart';
import 'core/overlay/overlay_window_controller.dart';
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

class _SyncTranslateAppState extends State<SyncTranslateApp> {
  late final AppConfig _config = widget.initialConfig;
  final _window = OverlayWindowController();
  AppMode _mode = AppMode.settings;
  TranslationPipeline? _pipeline;

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
    final pipeline = _pipeline;
    if (pipeline != null) {
      await pipeline.stop();
      await pipeline.dispose();
    }
    await _window.close();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
              onQuit: _quit,
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
