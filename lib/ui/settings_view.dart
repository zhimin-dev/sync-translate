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

const _kCustom = '__custom__';

/// 设置页：语音识别与翻译的集中配置。
/// 交互逻辑：先选模型（本地/云端分组）→ 自动判定运行方式 →
/// 云端需 API Key + Base URL；本地只需 Base URL（展示下载状态/进度）。
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

  late String _sttLanguage = widget.config.stt.language;
  late bool _sttFast = widget.config.stt.fastInference;
  late String _trSourceLang = widget.config.translate.sourceLang;
  late String _trTargetLang = widget.config.translate.targetLang;

  // 模型选择状态（模型优先，运行方式随模型自动判定；自定义时手动选）
  late String _sttChoice;
  late String _sttRunMode;
  late String _trChoice;
  late String _trRunMode;
  bool _obscureSttKey = true;
  bool _obscureTrKey = true;

  @override
  void initState() {
    super.initState();
    final sttSpec = ModelManager.specOf('stt', _sttModel.text.trim());
    _sttChoice = sttSpec != null ? sttSpec.name : _kCustom;
    _sttRunMode = widget.config.stt.engine == 'whisper_local'
        ? 'local'
        : 'remote';
    final trSpec = ModelManager.specOf('mt', _trModel.text.trim());
    _trChoice = trSpec != null ? trSpec.name : _kCustom;
    _trRunMode = widget.config.translate.engine == 'nllb_local'
        ? 'local'
        : 'remote';
  }

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

  // ---- 模型选择逻辑 ----

  Future<void> _onSttModelChanged(String? v) async {
    if (v == null) return;
    setState(() => _sttChoice = v);
    if (v == _kCustom) return; // 手动模式，保持现有字段
    final spec = ModelManager.specOf('stt', v)!;
    _sttModel.text = spec.name;
    if (spec.remote) {
      _sttBaseUrl.text = spec.baseUrl;
      // 云端：保留用户已填 Key
    } else {
      _sttBaseUrl.text = 'http://127.0.0.1:8000/v1';
      _sttApiKey.text = '';
      if (!ModelManager.isDownloaded('stt', spec.name)) {
        final r = await ModelManager.instance.ensureDownloaded('stt', spec.name);
        if (r == 0) _showSnack('开始后台下载模型（断点续传），完成后即可使用');
        if (r == -1) _showSnack('无法自动下载，请手动运行 download_models.ps1');
      }
    }
  }

  Future<void> _onTrModelChanged(String? v) async {
    if (v == null) return;
    setState(() => _trChoice = v);
    if (v == _kCustom) return;
    final spec = ModelManager.specOf('mt', v)!;
    _trModel.text = spec.name;
    if (spec.remote) {
      _trBaseUrl.text = spec.baseUrl;
    } else {
      _trBaseUrl.text = 'http://127.0.0.1:8765';
      _trApiKey.text = '';
      if (!ModelManager.isDownloaded('mt', spec.name)) {
        final r = await ModelManager.instance.ensureDownloaded('mt', spec.name);
        if (r == 0) _showSnack('开始后台下载模型（断点续传），完成后即可使用');
        if (r == -1) _showSnack('无法自动下载，请手动运行 download_models.ps1');
      }
    }
  }

  void _writeBack() {
    final c = widget.config;
    final sttSpec = ModelManager.specOf('stt', _sttChoice);
    final trSpec = ModelManager.specOf('mt', _trChoice);
    c.stt
      ..engine = (sttSpec != null)
          ? (sttSpec.remote ? 'openai_compat' : 'whisper_local')
          : (_sttRunMode == 'local' ? 'whisper_local' : 'openai_compat')
      ..baseUrl = _sttBaseUrl.text.trim()
      ..apiKey = _sttApiKey.text.trim()
      ..model = _sttModel.text.trim()
      ..language = _sttLanguage
      ..fastInference = _sttFast;
    c.translate
      ..engine = (trSpec != null)
          ? (trSpec.remote ? 'llm' : 'nllb_local')
          : (_trRunMode == 'local' ? 'nllb_local' : 'llm')
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

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final sttSpec = ModelManager.specOf('stt', _sttChoice);
    final sttIsLocal = sttSpec != null
        ? !sttSpec.remote
        : _sttRunMode == 'local';
    final trSpec = ModelManager.specOf('mt', _trChoice);
    final trIsLocal = trSpec != null ? !trSpec.remote : _trRunMode == 'local';

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
                  _modelDropdown(
                    label: '识别模型',
                    type: 'stt',
                    value: _sttChoice,
                    onChanged: _onSttModelChanged,
                  ),
                  const SizedBox(height: 8),
                  if (sttSpec == null)
                    Row(
                      children: [
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                                value: 'local',
                                label: Text('本地（本机模型）'),
                                icon: Icon(Icons.computer)),
                            ButtonSegment(
                                value: 'remote',
                                label: Text('远程（云端 API）'),
                                icon: Icon(Icons.cloud)),
                          ],
                          selected: {_sttRunMode},
                          onSelectionChanged: (s) =>
                              setState(() => _sttRunMode = s.first),
                        ),
                      ],
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Icon(
                            sttIsLocal ? Icons.computer : Icons.cloud,
                            size: 15,
                            color: Colors.blueGrey,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            sttIsLocal ? '运行方式：本地（本机模型）' : '运行方式：远程（云端 API）',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  if (sttSpec != null && !sttSpec.remote)
                    _buildDownloadStatus('stt', sttSpec.name),
                  if (sttSpec != null && !sttSpec.remote)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('速度优先（int8 量化）',
                          style: TextStyle(fontSize: 14)),
                      subtitle: Text(
                        '推理约快 1.5~2 倍，识别准度略降（切换后下次开始监听自动重启服务生效）',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      value: _sttFast,
                      onChanged: (v) => setState(() => _sttFast = v),
                    ),
                  if (sttSpec == null)
                    _buildTextFormField(
                      controller: _sttModel,
                      label: '模型名',
                      hint: sttIsLocal
                          ? '本地：HuggingFace 仓库（如 Systran/faster-whisper-large-v3）'
                          : '云端：whisper-large-v3-turbo',
                    ),
                  const SizedBox(height: 8),
                  _buildTextFormField(
                    controller: _sttBaseUrl,
                    label: 'Base URL',
                    hint: sttIsLocal
                        ? 'http://127.0.0.1:8000/v1'
                        : 'https://api.groq.com/openai/v1',
                  ),
                  if (!sttIsLocal) ...[
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
                  ],
                  const SizedBox(height: 8),
                  _languageDropdown(
                    label: '识别语言',
                    value: _sttLanguage,
                    onChanged: (v) => setState(() => _sttLanguage = v!),
                  ),
                  const SizedBox(height: 20),
                  _sectionTitle('翻译'),
                  _modelDropdown(
                    label: '翻译模型',
                    type: 'mt',
                    value: _trChoice,
                    onChanged: _onTrModelChanged,
                  ),
                  const SizedBox(height: 8),
                  if (trSpec == null)
                    Row(
                      children: [
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                                value: 'local',
                                label: Text('本地（本机模型）'),
                                icon: Icon(Icons.computer)),
                            ButtonSegment(
                                value: 'remote',
                                label: Text('远程（云端 API）'),
                                icon: Icon(Icons.cloud)),
                          ],
                          selected: {_trRunMode},
                          onSelectionChanged: (s) =>
                              setState(() => _trRunMode = s.first),
                        ),
                      ],
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Icon(
                            trIsLocal ? Icons.computer : Icons.cloud,
                            size: 15,
                            color: Colors.blueGrey,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            trIsLocal ? '运行方式：本地（本机模型）' : '运行方式：远程（云端 API）',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  if (trSpec != null && !trSpec.remote)
                    _buildDownloadStatus('mt', trSpec.name),
                  if (trSpec == null)
                    _buildTextFormField(
                      controller: _trModel,
                      label: '模型名',
                      hint: trIsLocal
                          ? '本地：facebook/nllb-200-distilled-600M'
                          : '云端：deepseek-chat / gpt-4o-mini',
                    ),
                  const SizedBox(height: 8),
                  _buildTextFormField(
                    controller: _trBaseUrl,
                    label: 'Base URL',
                    hint: trIsLocal
                        ? 'http://127.0.0.1:8765'
                        : 'https://api.deepseek.com/v1',
                  ),
                  if (!trIsLocal) ...[
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
                  ],
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
                    '提示：本地模型（识别/翻译）由应用自动拉起服务并自动下载，'
                    '免 API Key、数据不出本机；云端引擎需填写服务商的 API Key。'
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

  /// 模型下拉框：本地组 + 云端组 + 自定义。
  Widget _modelDropdown({
    required String label,
    required String type,
    required String value,
    required ValueChanged<String?> onChanged,
  }) {
    final locals = ModelManager.modelsOf(type).where((m) => !m.remote);
    final remotes = ModelManager.modelsOf(type).where((m) => m.remote);
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem(
          value: '__group_local__',
          enabled: false,
          child: Text('— 本地模型（免 Key） —',
              style: TextStyle(color: Colors.blueGrey, fontSize: 12)),
        ),
        ...locals.map((m) => DropdownMenuItem(
              value: m.name,
              child: Text(m.label, overflow: TextOverflow.ellipsis),
            )),
        const DropdownMenuItem(
          value: '__group_remote__',
          enabled: false,
          child: Text('— 云端模型（需 API Key） —',
              style: TextStyle(color: Colors.blueGrey, fontSize: 12)),
        ),
        ...remotes.map((m) => DropdownMenuItem(
              value: m.name,
              child: Text(m.label, overflow: TextOverflow.ellipsis),
            )),
        const DropdownMenuItem(value: _kCustom, child: Text('自定义…')),
      ],
      onChanged: onChanged,
    );
  }

  /// 本地模型下载状态：已下载 ✓ / 下载中进度 / 未下载（下载按钮）。
  Widget _buildDownloadStatus(String type, String modelName) {
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: ModelManager.instance.progress,
      builder: (context, p, _) {
        final downloaded = ModelManager.isDownloaded(type, modelName);
        final bytes = p[modelName] ?? 0;
        if (downloaded) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
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
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(minHeight: 4),
                const SizedBox(height: 4),
                Text(
                  '模型下载中… 已下载 ${(bytes / 1048576).toStringAsFixed(0)} MB'
                  '（断点续传，可关闭窗口）',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Text('模型未下载',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final r = await ModelManager.instance
                      .ensureDownloaded(type, modelName);
                  if (r == 0) {
                    _showSnack('开始后台下载模型（断点续传）');
                  } else if (r == -1) {
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
