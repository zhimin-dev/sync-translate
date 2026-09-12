import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/audio/audio_capture.dart';
import '../core/config/app_config.dart';

const _kDefaultDevice = '(默认设备)';

String engineLabel(String id, {required bool isStt}) {
  switch (id) {
    case 'whisper_local':
      return '本地 Whisper（faster-whisper）';
    case 'openai_compat':
      return 'OpenAI 兼容接口（云端）';
    case 'nllb_local':
      return '本地 NLLB-200';
    case 'llm':
      return 'LLM（OpenAI 兼容）';
    default:
      return isStt ? '未配置识别引擎' : '未配置翻译引擎';
  }
}

/// 主页面：日常只需配置采集源与悬浮字幕信息，即可开始监听。
/// 引擎配置在「设置」页（右上角齿轮进入）。
class MainView extends StatefulWidget {
  const MainView({
    super.key,
    required this.config,
    required this.onStart,
    required this.onOpenSettings,
    required this.onHideToTray,
  });

  final AppConfig config;
  final Future<void> Function() onStart;
  final VoidCallback onOpenSettings;
  final Future<void> Function() onHideToTray;

  @override
  State<MainView> createState() => _MainViewState();
}

class _MainViewState extends State<MainView> {
  late String _captureMode = widget.config.capture.mode;
  late String _selectedDevice = widget.config.capture.device.isEmpty
      ? _kDefaultDevice
      : widget.config.capture.device;
  List<String> _devices = const [];
  bool _devicesLoading = false;
  late double _overlayOpacity = widget.config.overlay.opacity;
  late double _fontSize = widget.config.overlay.fontSize;
  late double _maxLines = widget.config.overlay.maxLines.toDouble();
  late int _autoHide = widget.config.overlay.autoHideSeconds;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() => _devicesLoading = true);
    try {
      final capture = createPlatformAudioCapture();
      final list = await capture.listDevices(_captureMode == 'mic'
          ? CaptureSource.microphone
          : CaptureSource.system);
      if (mounted) setState(() => _devices = list);
    } catch (_) {
      if (mounted) setState(() => _devices = const []);
    } finally {
      if (mounted) setState(() => _devicesLoading = false);
    }
  }

  void _writeBack() {
    final c = widget.config;
    c.capture.mode = _captureMode;
    c.capture.device =
        _selectedDevice == _kDefaultDevice ? '' : _selectedDevice;
    c.overlay
      ..opacity = _overlayOpacity
      ..fontSize = _fontSize
      ..maxLines = _maxLines.round()
      ..autoHideSeconds = _autoHide;
  }

  Future<void> _start() async {
    _writeBack();
    final error = widget.config.validate();
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('无法启动：$error（请到右上角「设置」完善引擎配置）'),
      ));
      return;
    }
    setState(() => _starting = true);
    try {
      await widget.config.save();
      await widget.onStart();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    return Scaffold(
      body: Column(
        children: [
          _buildTitleBar(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              children: [
                // 引擎状态卡片
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.settings_suggest_outlined),
                    title: Text(
                      '识别：${engineLabel(c.stt.engine, isStt: true)}',
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      '翻译：${engineLabel(c.translate.engine, isStt: false)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: TextButton(
                      onPressed: widget.onOpenSettings,
                      child: const Text('修改引擎配置'),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('采集源',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.blueGrey)),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'system',
                        label: Text('系统声音'),
                        icon: Icon(Icons.volume_up)),
                    ButtonSegment(
                        value: 'mic',
                        label: Text('麦克风'),
                        icon: Icon(Icons.mic)),
                  ],
                  selected: {_captureMode},
                  onSelectionChanged: (s) {
                    setState(() {
                      _captureMode = s.first;
                      _selectedDevice = _kDefaultDevice;
                    });
                    _loadDevices();
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _devices.contains(_selectedDevice)
                            ? _selectedDevice
                            : _kDefaultDevice,
                        decoration: const InputDecoration(
                          labelText: '采集设备',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem(
                              value: _kDefaultDevice, child: Text('默认设备')),
                          ..._devices.map((d) => DropdownMenuItem(
                              value: d,
                              child:
                                  Text(d, overflow: TextOverflow.ellipsis))),
                        ],
                        onChanged: (v) => setState(
                            () => _selectedDevice = v ?? _kDefaultDevice),
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新设备列表',
                      icon: const Icon(Icons.refresh),
                      onPressed: _devicesLoading ? null : _loadDevices,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Windows：系统声音走 WASAPI 回环采集，无需权限。'
                  'PotPlayer 等播放器若没字幕，请在此选择其实际输出设备。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                const Text('悬浮字幕',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.blueGrey)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(width: 90, child: Text('窗口透明度')),
                    Expanded(
                      child: Slider(
                        value: _overlayOpacity,
                        min: 0.3,
                        max: 1.0,
                        divisions: 14,
                        label: _overlayOpacity.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _overlayOpacity = v),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 90, child: Text('字幕字号')),
                    Expanded(
                      child: Slider(
                        value: _fontSize,
                        min: 12,
                        max: 32,
                        divisions: 20,
                        label: _fontSize.round().toString(),
                        onChanged: (v) => setState(() => _fontSize = v),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 90, child: Text('保留条数')),
                    Expanded(
                      child: Slider(
                        value: _maxLines,
                        min: 2,
                        max: 8,
                        divisions: 6,
                        label: _maxLines.round().toString(),
                        onChanged: (v) => setState(() => _maxLines = v),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 90, child: Text('空闲自动隐藏')),
                    Expanded(
                      child: Slider(
                        value: _autoHide.toDouble(),
                        min: 0,
                        max: 30,
                        divisions: 30,
                        label: _autoHide == 0 ? '不隐藏' : '$_autoHide 秒后淡出',
                        onChanged: (v) =>
                            setState(() => _autoHide = v.round()),
                      ),
                    ),
                    SizedBox(
                      width: 76,
                      child: Text(
                        _autoHide == 0 ? '不隐藏' : '$_autoHide 秒',
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '句子之间停顿超过设定时间时字幕自动淡出，下一句开始说话时再显示。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _starting ? null : _start,
                  icon: const Icon(Icons.graphic_eq),
                  label: Text(_starting ? '启动中…' : '开始监听'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    textStyle: const TextStyle(fontSize: 17),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleBar() {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 40,
        color: const Color(0xFF1E2128),
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(Icons.subtitles, size: 18),
            const SizedBox(width: 8),
            const Text('实时翻译字幕',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
              tooltip: '设置（识别/翻译引擎配置）',
              icon: const Icon(Icons.settings, size: 18),
              onPressed: widget.onOpenSettings,
            ),
            IconButton(
              tooltip: '最小化',
              icon: const Icon(Icons.remove, size: 18),
              onPressed: () => windowManager.minimize(),
            ),
            IconButton(
              tooltip: '隐藏到托盘（右键托盘图标退出）',
              icon: const Icon(Icons.close, size: 18),
              onPressed: widget.onHideToTray,
            ),
          ],
        ),
      ),
    );
  }
}
