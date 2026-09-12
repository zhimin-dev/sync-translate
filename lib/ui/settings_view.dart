import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/config/app_config.dart';
import '../core/model/model_manager.dart';

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

/// 设置页：语音识别（STT）与翻译引擎的集中配置。
class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.config,
    required this.onBack,
    required this.onHideToTray,
  });

  final AppConfig config;
  final VoidCallback onBack;
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
  bool _obscureSttKey = true;
  bool _obscureTrKey = true;

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

  void _onSttEngineChanged(String? v) {
    if (v == null) return;
    setState(() {
      _sttEngine = v;
      if (v == 'whisper_local' &&
          !_sttBaseUrl.text.contains('localhost') &&
          !_sttBaseUrl.text.contains('127.0.0.1')) {
        // 切到本地引擎时自动填默认服务地址（免 Key）
        _sttBaseUrl.text = 'http://127.0.0.1:8000/v1';
        _sttModel.text = 'Systran/faster-whisper-large-v3';
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
  }

  Future<void> _save() async {
    _writeBack();
    await widget.config.save();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('设置已保存')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildTitleBar(),
          Expanded(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [
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
                  if (_sttEngine == 'whisper_local')
                    _buildLocalModelPicker()
                  else
                    _buildTextFormField(
                      controller: _sttModel,
                      label: '模型',
                      hint: 'whisper-large-v3-turbo（Groq）/ whisper-1（OpenAI）',
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
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.save),
                          label: const Text('保存设置'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: widget.onBack,
                        child: const Text('返回主界面'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '提示：本地引擎（faster-whisper / NLLB-200）由应用自动拉起服务，'
                    '免 API Key、数据不出本机；云端引擎可用 Groq/SiliconFlow/DeepSeek 等。'
                    '配置保存后，主界面即可开始监听。',
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

  static const _kCustomModel = '__custom__';

  Future<void> _onLocalModelChanged(String? v) async {
    if (v == null) return;
    if (v == _kCustomModel) {
      setState(() {});
      return;
    }
    setState(() => _sttModel.text = v);
    if (!ModelManager.isDownloaded(v)) {
      final result = await ModelManager.instance.ensureDownloaded(v);
      if (result == 0) {
        _showSnack('开始后台下载模型（断点续传），完成后即可使用');
      } else if (result == -1) {
        _showSnack('无法自动下载该模型，请手动运行 download_models.ps1');
      }
    }
  }

  Widget _buildLocalModelPicker() {
    final current = _sttModel.text.trim();
    final isCustom = ModelManager.specOf(current) == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: isCustom ? _kCustomModel : current,
          decoration: const InputDecoration(
            labelText: '识别模型',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            ...kLocalWhisperModels.map((m) => DropdownMenuItem(
                  value: m.name,
                  child: Text(
                    '${m.label} · ${m.name}',
                    overflow: TextOverflow.ellipsis,
                  ),
                )),
            const DropdownMenuItem(
                value: _kCustomModel, child: Text('自定义（手动填写）')),
          ],
          onChanged: _onLocalModelChanged,
        ),
        ValueListenableBuilder<Map<String, int>>(
          valueListenable: ModelManager.instance.progress,
          builder: (context, p, _) {
            final name = _sttModel.text.trim();
            if (ModelManager.specOf(name) == null) {
              return const SizedBox.shrink();
            }
            final downloaded = ModelManager.isDownloaded(name);
            final bytes = p[name] ?? 0;
            if (downloaded) {
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle,
                        size: 14, color: Colors.greenAccent),
                    const SizedBox(width: 6),
                    Text('模型已下载，开始监听时自动加载',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              );
            }
            if (bytes > 0) {
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LinearProgressIndicator(minHeight: 4),
                    const SizedBox(height: 4),
                    Text(
                      '后台下载中… 已下载 ${(bytes / 1048576).toStringAsFixed(0)} MB'
                      '（断点续传，可关闭窗口）',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Text('模型未下载',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final result =
                          await ModelManager.instance.ensureDownloaded(name);
                      if (result == 0) {
                        _showSnack('开始后台下载模型（断点续传）');
                      } else if (result == -1) {
                        _showSnack('无法自动下载，请手动运行 download_models.ps1');
                      }
                      setState(() {});
                    },
                    icon: const Icon(Icons.download, size: 14),
                    label: const Text('下载'),
                  ),
                ],
              ),
            );
          },
        ),
        if (isCustom)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _buildTextFormField(
              controller: _sttModel,
              label: '模型名（HuggingFace 仓库）',
              hint: 'org/model-name',
            ),
          ),
      ],
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildTitleBar() {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 40,
        color: const Color(0xFF1E2128),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回主界面',
              icon: const Icon(Icons.arrow_back, size: 18),
              onPressed: widget.onBack,
            ),
            const Icon(Icons.subtitles, size: 18),
            const SizedBox(width: 8),
            const Text('设置（引擎配置）',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
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
