import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/batch/batch_subtitle_service.dart';
import '../core/config/app_config.dart';
import '../core/model/model_manager.dart';
import '../core/pipeline/local_server_manager.dart';

/// 离线转换页：音视频批量转写+翻译，生成 SRT 字幕（异步队列）。
/// 入口在托盘右键菜单。
class BatchView extends StatefulWidget {
  const BatchView({
    super.key,
    required this.config,
    required this.onBack,
    required this.onHideToTray,
  });

  final AppConfig config;
  final VoidCallback onBack;
  final Future<void> Function() onHideToTray;

  @override
  State<BatchView> createState() => _BatchViewState();
}

class _BatchViewState extends State<BatchView> {
  final List<BatchItem> _batchItems = [];
  Timer? _batchTimer;
  bool _batchSubmitting = false;
  String _batchMode = 'video'; // 'video'（视频转写）| 'srt'（纯字幕翻译）

  @override
  void initState() {
    super.initState();
    // 若有过在途任务，恢复轮询
    _ensureBatchPolling();
  }

  @override
  void dispose() {
    _batchTimer?.cancel();
    super.dispose();
  }

  Future<void> _addBatchFiles() async {
    final isSrt = _batchMode == 'srt';
    final result = isSrt
        ? await FilePicker.pickFiles(
            type: FileType.custom, allowedExtensions: ['srt'])
        : await FilePicker.pickFiles(type: FileType.any);
    if (result.isEmpty) return;
    final existing = _batchItems.map((e) => e.path).toSet();
    final added = <BatchItem>[];
    for (final f in result) {
      if (f.path == null || existing.contains(f.path)) continue;
      added.add(BatchItem(f.path!, kind: isSrt ? 'srt' : 'video'));
    }
    if (added.isNotEmpty) setState(() => _batchItems.addAll(added));
  }

  Future<void> _startBatch() async {
    final pending = _batchItems
        .where((e) => e.jobId == null && e.kind == _batchMode)
        .toList();
    if (pending.isEmpty) return;
    setState(() => _batchSubmitting = true);
    try {
      // Batch endpoints always run locally, even when live STT uses a cloud API.
      final sttBase = _batchBaseUrl;
      await LocalServerManager.instance.ensureServerRunning(
        script: 'whisper_server.py',
        args: [
          '--model', widget.config.stt.engine == 'whisper_local'
              ? widget.config.stt.model
              : 'Systran/faster-whisper-large-v3',
          '--port', '${Uri.tryParse(sttBase)?.port ?? 8000}',
          '--device', 'auto',
        ],
        healthBase: sttBase,
      );
      final service = BatchSubtitleService(baseUrl: sttBase);
      final targetLang = widget.config.translate.targetLang;
      final translator = widget.config.translate;
      final modelDir = translator.engine == 'nllb_local'
          ? ModelManager.modelDir('mt', translator.model)
          : null;
      for (final item in pending) {
        if (item.jobId != null) continue;
        item.status = '排队中';
        try {
          if (item.kind == 'srt') {
            item.jobId = await service.submitSrt(
              path: item.path,
              targetLang: targetLang,
              modelDir: modelDir,
              sourceLang: translator.sourceLang,
              translator: translator,
            );
          } else {
            item.jobId = await service.submit(
              path: item.path,
              targetLang: targetLang,
              modelDir: modelDir,
              sourceLang: translator.sourceLang,
              translator: translator,
            );
          }
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

  String get _batchBaseUrl => widget.config.stt.engine == 'whisper_local'
      ? widget.config.stt.baseUrl
      : 'http://127.0.0.1:8000/v1';

  void _ensureBatchPolling() {
    if (_batchTimer != null) return;
    _batchTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollBatch());
  }

  Future<void> _pollBatch() async {
    final running =
        _batchItems.where((e) => e.jobId != null && e.running).toList();
    if (running.isEmpty) {
      _batchTimer?.cancel();
      _batchTimer = null;
      return;
    }
    final service =
        BatchSubtitleService(baseUrl: _batchBaseUrl);
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
    final p = item.srtPath ?? item.origSrtPath ?? item.path;
    final dir = File(p).parent.path;
    Process.start('explorer', ['/select,', p])
        .catchError((_) => Process.start('explorer', [dir]));
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
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildTitleBar(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              children: [
                const Text('批量字幕翻译',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.blueGrey)),
                const SizedBox(height: 6),
                Text(
                  _batchMode == 'srt'
                      ? '导入现成的 .srt 字幕文件，使用设置中的翻译模型并保留时间轴，'
                          '生成 <同名>.<目标语言>.srt 新字幕。'
                          '多文件排队异步处理，关闭窗口不影响（托盘常驻）。'
                      : '导入音视频文件，本地识别后使用所选翻译模型，生成同名 .srt 字幕'
                          '（译文，播放器自动加载）与 .orig.srt（原文）。'
                          '多文件排队异步处理，关闭窗口不影响（托盘常驻）。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'video',
                      label: Text('视频转写'),
                      icon: Icon(Icons.movie_outlined),
                    ),
                    ButtonSegment(
                      value: 'srt',
                      label: Text('SRT 翻译'),
                      icon: Icon(Icons.translate),
                    ),
                  ],
                  selected: {_batchMode},
                  onSelectionChanged: (sel) =>
                      setState(() => _batchMode = sel.first),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _batchSubmitting ? null : _addBatchFiles,
                      icon: const Icon(Icons.add),
                      label: Text(_batchMode == 'srt'
                          ? '添加 SRT 字幕文件（可多选）'
                          : '添加音视频文件（可多选）'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      onPressed: _batchSubmitting ? null : _startBatch,
                      icon: const Icon(Icons.play_arrow),
                      label:
                          Text(_batchSubmitting ? '提交中…' : '开始批量翻译'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '目标语言：${widget.config.translate.targetLang}'
                  ' · 模型：${widget.config.translate.model}\n'
                  '${widget.config.translate.engine == 'llm' ? 'AI 按段翻译并参考前后文；字幕文本将发送至所配置的 API。' : '本地 NLLB 逐条翻译；有上下文需求时可在设置中切换 AI 模型。'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                if (_batchItems.where((e) => e.kind == _batchMode).isEmpty)
                  Text(
                    _batchMode == 'srt'
                        ? '尚未添加 SRT 文件。选择已有的字幕文件直接翻译，时间轴保持不变。'
                        : '尚未添加文件。支持 mp4/mkv/avi/mov/wav/mp3/flac 等常见格式。',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  ..._batchItems
                      .where((e) => e.kind == _batchMode)
                      .map((item) => _buildBatchTile(item)),
              ],
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
                  onPressed:
                      item.running ? null : () => _removeBatchItem(item),
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
              if (item.origSrtPath != null)
                TextButton.icon(
                  onPressed: () => _openBatchFolder(item),
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('原字幕已保存，打开目录后可导入 SRT 重新翻译'),
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
      '解析字幕' => (Colors.lightBlueAccent, '解析字幕'),
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
            const Text('离线转换',
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
}
