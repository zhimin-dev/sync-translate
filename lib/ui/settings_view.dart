import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/config/app_config.dart';

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

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.config,
    required this.onStart,
    required this.onQuit,
  });

  final AppConfig config;
  final Future<void> Function() onStart;
  final Future<void> Function() onQuit;

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
  late double _overlayOpacity = widget.config.overlay.opacity;
  late double _fontSize = widget.config.overlay.fontSize;
  late double _maxLines = widget.config.overlay.maxLines.toDouble();
  bool _obscureSttKey = true;
  bool _obscureTrKey = true;
  bool _saving = false;

  @override
  void dispose() {
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
        _trModel.text = 'JustFrederik/nllb-200-distilled-600M-ct2-int8';
        _trApiKey.text = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _TitleBar(onQuit: widget.onQuit),
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
                    onSelectionChanged: (s) =>
                        setState(() => _captureMode = s.first),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Windows：系统声音走 WASAPI 回环采集，无需权限；'
                    '麦克风首次使用会触发系统授权。',
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
                ],
              ),
            ),
          ),
        ],
      ),
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
  const _TitleBar({required this.onQuit});

  final Future<void> Function() onQuit;

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
              tooltip: '退出',
              icon: const Icon(Icons.close, size: 18),
              onPressed: onQuit,
            ),
          ],
        ),
      ),
    );
  }
}
