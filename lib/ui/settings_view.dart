import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/audio/audio_capture.dart';
import '../core/batch/batch_subtitle_service.dart';
import '../core/config/app_config.dart';
import '../core/pipeline/local_server_manager.dart';

const _kLanguageOptions = <String, String>{
  'auto': '自动检测',
  'zh': '中文',
  'en': '英语',
  'ja': '日语',
  'ko': '韩语',
  'fr': '法语',
  'de': '德语',
  'es': '西班牙语',
  'ru': '俄语',
  'pt': '葡萄牙语',
};

const _kDefaultDevice = '(默认设备)';

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.config,
    required this.onStart,
    required this.onHideToTray,
  });

  final AppConfig config;
  final Future<void> Function() onStart;
  final Future<void> Function() onHideToTray;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _sttBaseUrl =
      TextEditingController(text: widget.config.stt.baseUrl);
  late final TextEditingController _sttApiKey =
      TextEditingController(text: widget.config.stt.apiKey);
  late final TextEditingController _sttModel =
      TextEditingController(text: widget.config.stt.model);
  late final TextEditingController _trBaseUrl =
      TextEditingController(text: widget.config.translate.baseUrl);
  late final TextEditingController _trApiKey =
      TextEditingController(text: widget.config.translate.apiKey);
  late final TextEditingController _trModel =
      TextEditingController(text: widget.config.translate.model);

  late String _sttEngine = widget.config.stt.engine;
  late String _sttLanguage = widget.config.stt.language;
  late String _trEngine = widget.config.translate.engine;
  late String _trSourceLang = widget.config.translate.sourceLang;
  late String _trTargetLang = widget.config.translate.targetLang;
  late String _captureMode = widget.config.capture.mode;
  late String _selectedDevice = widget.config.capture.device.isEmpty
      ? _kDefaultDevice
      : widget.config.capture.device;
  List<String> _devices = const [];
  bool _devicesLoading = false;
  late double _overlayOpacity = widget.config.overlay.opacity;
  late double _fontSize = widget.config.overlay.fontSize;
  late double _maxLines = widget.config.overlay.maxLines.toDouble();
  bool _obscureSttKey = true;
  bool _obscureTrKey = true;
  bool _saving = false;

  // 批量离线字幕
  final List<BatchItem> _batchItems = [];
  Timer? _batchTimer;
  bool _batchSubmitting = false;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() => _devicesLoading = true);
    try {
      final capture = createPlatformAudioCapture();
      final list = await capture.listDevices(
          _captureMode == 'mic' ? CaptureSource.microphone : CaptureSource.system);
      if (mounted) setState(() => _devices = list);
    } catch (_) {
      if (mounted) setState(() => _devices = const []);
    } finally {
      if (mounted) setState(() => _devicesLoading = false);
    }
  }

  // ---- 批量离线字幕 ----

  Future<void> _addBatchFiles() async {
    // file_picker 12.x：pickFiles 默认多选，返回列表
    final result = await FilePicker.pickFiles(
      type: FileType.any,
    );
    if (result.isEmpty) return;
    final existing = _batchItems.map((e) => e.path).toSet();
    final added = <BatchItem>[];
    for (final f in result) {
      if (f.path == null || existing.contains(f.path)) continue;
      added.add(BatchItem(f.path!));
    }
    if (added.isNotEmpty) setState(() => _batchItems.addAll(added));
  }

  Future<void> _startBatch() async {
    final pending = _batchItems.where((e) => e.jobId == null).toList();
    if (pending.isEmpty) return;
    setState(() => _batchSubmitting = true);
    try {
      // 确保本地服务在线（应用自动拉起）
      final sttBase = widget.config.stt.baseUrl;
      await LocalServerManager.instance.ensureServerRunning(
        script: 'whisper_server.py',
        args: [
          '--model', widget.config.stt.model,
          '--port', '${Uri.tryParse(sttBase)?.port ?? 8000}',
          '--device', 'auto',
        ],
        healthBase: sttBase,
      );
      final service = BatchSubtitleService(baseUrl: sttBase);
      final targetLang = widget.config.translate.targetLang;
      for (final item in pending) {
        if (item.jobId != null) continue;
        item.status = '排队中';
        try {
          item.jobId = await service.submit(
            path: item.path,
            targetLang: targetLang,
          );
        } catch (e) {
          item.status = '失败';
          item.error = '提交失败: $e';
        }
      }
      _ensureBatchPolling();
    } catch (e) {
      _showSnack('启动批量任务失败: $e');
    } finally {
      if (mounted) setState(() => _batchSubmitting = false);
    }
  }

  void _ensureBatchPolling() {
    if (_batchTimer != null) return;
    _batchTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollBatch());
  }

  Future<void> _pollBatch() async {
    final running = _batchItems.where((e) => e.jobId != null && e.running).toList();
    if (running.isEmpty) {
      _batchTimer?.cancel();
      _batchTimer = null;
      return;
    }
    final sttBase = widget.config.stt.baseUrl;
    final service = BatchSubtitleService(baseUrl: sttBase);
    var anyUpdate = false;
    for (final item in running) {
      try {
        final s = await service.status(item.jobId!);
        item.status = s['status'] as String? ?? item.status;
        item.progress = (s['progress'] as num?)?.toDouble() ?? item.progress;
        item.srtPath = s['srt_path'] as String?;
        item.origSrtPath = s['orig_srt_path'] as String?;
        item.error = s['error'] as String?;
        item.duration = (s['duration'] as num?)?.toDouble();
        anyUpdate = true;
      } catch (_) {
        // 服务暂时不可达，下一轮再试
      }
    }
    if (anyUpdate && mounted) setState(() {});
  }

  void _openBatchFolder(BatchItem item) {
    final p = item.srtPath ?? item.path;
    final dir = File(p).parent.path;
    Process.start('explorer', ['/select,', p]).catchError((_) =>
        Process.start('explorer', [dir]));
  }

  void _removeBatchItem(BatchItem item) {
    if (item.running) return;
    setState(() => _batchItems.remove(item));
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _batchTimer?.cancel();
    _sttBaseUrl.dispose();
    _sttApiKey.dispose();
    _sttModel.dispose();
    _trBaseUrl.dispose();
    _trApiKey.dispose();
    _trModel.dispose();
    super.dispose();
  }

  void _writeBack() {
    final c = widget.config;
    c.stt
      ..engine = _sttEngine
      ..baseUrl = _sttBaseUrl.text.trim()
      ..apiKey = _sttApiKey.text.trim()
      ..model = _sttModel.text.trim()
      ..language = _sttLanguage;
    c.translate
      ..engine = _trEngine
      ..baseUrl = _trBaseUrl.text.trim()
      ..apiKey = _trApiKey.text.trim()
      ..model = _trModel.text.trim()
      ..sourceLang = _trSourceLang
      ..targetLang = _trTargetLang;
    c.capture.mode = _captureMode;
    c.capture.device = _selectedDevice == _kDefaultDevice
        ? ''
        : _selectedDevice;
    c.overlay
      ..opacity = _overlayOpacity
      ..fontSize = _fontSize
      ..maxLines = _maxLines.round();
  }

  Future<void> _save() async {
    _writeBack();
    await widget.config.save();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('设置已保存')));
    }
  }

  Future<void> _start() async {
    _writeBack();
    setState(() => _saving = true);
    try {
      await widget.config.save();
      await widget.onStart();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _onSttEngineChanged(String? v) {
    if (v == null) return;
    setState(() {
      _sttEngine = v;
      if (v == 'whisper_local' &&
          !_sttBaseUrl.text.contains('localhost') &&
          !_sttBaseUrl.text.contains('127.0.0.1')) {
        // 切到本地引擎时自动填默认服务地址（免 Key）
        _sttBaseUrl.text = 'http://127.0.0.1:8000/v1';
        _sttModel.text = 'deepdml/faster-whisper-large-v3-turbo-ct2';
        _sttApiKey.text = '';
      }
    });
  }

  void _onTrEngineChanged(String? v) {
    if (v == null) return;
    setState(() {
      _trEngine = v;
      if (v == 'nllb_local' &&
          !_trBaseUrl.text.contains('localhost') &&
          !_trBaseUrl.text.contains('127.0.0.1')) {
        _trBaseUrl.text = 'http://127.0.0.1:8765';
        _trModel.text = 'facebook/nllb-200-distilled-600M';
        _trApiKey.text = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _TitleBar(onHideToTray: widget.onHideToTray),
          Expanded(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [
                  _sectionTitle('采集源'),
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
                      setState(() => _captureMode = s.first);
                      _selectedDevice = _kDefaultDevice;
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
                                value: _kDefaultDevice,
                                child: Text('默认设备')),
                            ..._devices.map((d) => DropdownMenuItem(
                                value: d, child: Text(d, overflow: TextOverflow.ellipsis))),
                          ],
                          onChanged: (v) =>
                              setState(() => _selectedDevice = v ?? _kDefaultDevice),
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
                    'Windows：系统声音走 WASAPI 回环采集，无需权限；'
                    '若 PotPlayer 等播放器没声音进字幕，请在此选择其实际输出设备。\n'
                    '注意：播放器若使用 WASAPI 独占模式输出，回环采集将无法捕获，'
                    '请把播放器音频渲染器改为共享模式（如 DirectSound / 内置 WASAPI 共享）。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  _sectionTitle('语音识别（STT）'),
                  _engineDropdown(
                    value: _sttEngine,
                    items: const {
                      'openai_compat': 'OpenAI 兼容接口（云端）',
                      'whisper_local': '本地 Whisper（faster-whisper，免 Key）',
                    },
                    onChanged: _onSttEngineChanged,
                  ),
                  const SizedBox(height: 8),
                  _buildTextFormField(
                    controller: _sttBaseUrl,
                    label: 'Base URL',
                    hint: 'https://api.groq.com/openai/v1',
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _buildTextFormField(
                          controller: _sttApiKey,
                          label: 'API Key',
                          obscure: _obscureSttKey,
                        ),
                      ),
                      IconButton(
                        tooltip: _obscureSttKey ? '显示' : '隐藏',
                        icon: Icon(_obscureSttKey
                            ? Icons.visibility
                            : Icons.visibility_off),
                        onPressed: () =>
                            setState(() => _obscureSttKey = !_obscureSttKey),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildTextFormField(
                    controller: _sttModel,
                    label: '模型',
                    hint: '云端：whisper-large-v3-turbo；本地：deepdml/faster-whisper-large-v3-turbo-ct2',
                  ),
                  const SizedBox(height: 8),
                  _languageDropdown(
                    label: '识别语言',
                    value: _sttLanguage,
                    onChanged: (v) => setState(() => _sttLanguage = v!),
                  ),
                  const SizedBox(height: 20),
                  _sectionTitle('翻译'),
                  _engineDropdown(
                    value: _trEngine,
                    items: const {
                      'llm': 'LLM（OpenAI 兼容接口）',
                      'nllb_local': '本地 NLLB-200（免 Key）',
                    },
                    onChanged: _onTrEngineChanged,
                  ),
                  const SizedBox(height: 8),
                  _buildTextFormField(
                    controller: _trBaseUrl,
                    label: 'Base URL',
                    hint: 'https://api.deepseek.com/v1',
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _buildTextFormField(
                          controller: _trApiKey,
                          label: 'API Key',
                          obscure: _obscureTrKey,
                        ),
                      ),
                      IconButton(
                        tooltip: _obscureTrKey ? '显示' : '隐藏',
                        icon: Icon(_obscureTrKey
                            ? Icons.visibility
                            : Icons.visibility_off),
                        onPressed: () =>
                            setState(() => _obscureTrKey = !_obscureTrKey),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildTextFormField(
                    controller: _trModel,
                    label: '模型',
                    hint: 'deepseek-chat / gpt-4o-mini / qwen2.5…',
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _languageDropdown(
                          label: '源语言',
                          value: _trSourceLang,
                          onChanged: (v) =>
                              setState(() => _trSourceLang = v!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _languageDropdown(
                          label: '目标语言',
                          value: _trTargetLang,
                          onChanged: (v) =>
                              setState(() => _trTargetLang = v!),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _sectionTitle('悬浮字幕'),
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
                          onChanged: (v) =>
                              setState(() => _overlayOpacity = v),
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
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _start,
                          icon: const Icon(Icons.graphic_eq),
                          label: const Text('开始监听'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: _saving ? null : _save,
                        child: const Text('保存设置'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '提示：本地引擎（faster-whisper / NLLB-200）需先启动服务，'
                    '脚本位于 tool\\local_servers\\（start_whisper.ps1 / start_nllb.ps1），'
                    '免 API Key、数据不出本机。云端引擎可用 Groq/SiliconFlow/DeepSeek 等。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Divider(height: 32),
                  _sectionTitle('离线字幕（音视频 → SRT 批量翻译）'),
                  Text(
                    '导入音视频文件，本地模型离线转写+翻译，生成同名 .srt 字幕'
                    '（译文，播放器自动加载）与 .orig.srt（原文）。'
                    '多文件排队异步处理，关闭窗口不影响。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _batchSubmitting ? null : _addBatchFiles,
                        icon: const Icon(Icons.add),
                        label: const Text('添加音视频文件（可多选）'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.tonalIcon(
                        onPressed: _batchSubmitting ? null : _startBatch,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(_batchSubmitting ? '提交中…' : '开始批量翻译'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_batchItems.isEmpty)
                    Text(
                      '尚未添加文件。支持 mp4/mkv/avi/mov/wav/mp3/flac 等常见格式。',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    ..._batchItems.map((item) => _buildBatchTile(item)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchTile(BatchItem item) {
    final progress = (item.progress * 100).clamp(0.0, 100.0);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.fileName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                _batchStatusBadge(item),
                IconButton(
                  tooltip: item.running ? '处理中不可移除' : '移除',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: item.running ? null : () => _removeBatchItem(item),
                ),
              ],
            ),
            if (item.running) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: item.progress),
              ),
              const SizedBox(height: 4),
              Text(
                '${item.statusText} ${progress.toStringAsFixed(0)}%'
                '${item.duration != null ? '（音频 ${item.duration!.toStringAsFixed(0)} 秒）' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (item.done && item.srtPath != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '字幕: ${item.srtPath}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _openBatchFolder(item),
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('打开目录'),
                  ),
                ],
              ),
            ],
            if (item.error != null && item.error!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                item.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _batchStatusBadge(BatchItem item) {
    final (color, text) = switch (item.status) {
      '完成' => (Colors.greenAccent, '完成'),
      '失败' => (Colors.redAccent, '失败'),
      '排队中' => (Colors.orangeAccent, '排队中'),
      '解码音频' => (Colors.lightBlueAccent, '解码'),
      '识别中' => (Colors.lightBlueAccent, '识别中'),
      '翻译中' => (Colors.amberAccent, '翻译中'),
      _ => (Colors.grey, item.statusText),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, color: Colors.blueGrey),
        ),
      );

  Widget _buildTextFormField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _engineDropdown({
    required String value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: const InputDecoration(
        labelText: '引擎',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: items.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: onChanged,
    );
  }

  Widget _languageDropdown({
    required String label,
    required String value,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: _kLanguageOptions.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: onChanged,
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.onHideToTray});

  final Future<void> Function() onHideToTray;

  @override
  Widget build(BuildContext context) {
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
            const Text('实时翻译字幕', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
              tooltip: '最小化',
              icon: const Icon(Icons.remove, size: 18),
              onPressed: () => windowManager.minimize(),
            ),
            IconButton(
              tooltip: '隐藏到托盘（右键托盘图标退出）',
              icon: const Icon(Icons.close, size: 18),
              onPressed: onHideToTray,
            ),
          ],
        ),
      ),
    );
  }
}
