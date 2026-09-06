import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/pipeline/translation_pipeline.dart';

/// 悬浮字幕视图：置顶半透明窗口，显示最近 N 条原文/译文。
class OverlayView extends StatefulWidget {
  const OverlayView({
    super.key,
    required this.pipeline,
    required this.maxLines,
    required this.fontSize,
    required this.onBackToSettings,
  });

  final TranslationPipeline pipeline;
  final int maxLines;
  final double fontSize;
  final VoidCallback onBackToSettings;

  @override
  State<OverlayView> createState() => _OverlayViewState();
}

class _OverlayViewState extends State<OverlayView> {
  final _focusNode = FocusNode();
  final List<SubtitleEntry> _entries = [];
  StreamSubscription<SubtitleEntry>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.pipeline.subtitles.listen(_onEntry);
  }

  void _onEntry(SubtitleEntry entry) {
    setState(() {
      if (entry.seq == SubtitleEntry.provisionalSeq) {
        // 临时字幕（边听边出）：替换上一条临时字幕
        _entries.removeWhere((e) => e.seq == SubtitleEntry.provisionalSeq);
        _entries.add(entry);
        return;
      }
      // 最终字幕：同 seq 事件 = 译文补上，原位替换；同时清掉临时字幕
      final index = _entries.indexWhere(
          (e) => e.seq == entry.seq && e.seq != SubtitleEntry.provisionalSeq);
      if (index >= 0) {
        _entries[index] = entry;
      } else {
        _entries.removeWhere((e) => e.seq == SubtitleEntry.provisionalSeq);
        _entries.add(entry);
      }
      final max = widget.maxLines;
      if (_entries.length > max) {
        _entries.removeRange(0, _entries.length - max);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onBackToSettings();
        }
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xE6121418),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Column(
            children: [
              _buildHeader(),
              Expanded(child: _buildSubtitleList()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            const SizedBox(width: 12),
            ValueListenableBuilder<PipelineState>(
              valueListenable: widget.pipeline.state,
              builder: (context, state, _) {
                final (color, text) = switch (state.phase) {
                  PipelinePhase.idle => (Colors.grey, '空闲'),
                  PipelinePhase.starting => (Colors.orange, '启动中…'),
                  PipelinePhase.listening => (Colors.greenAccent, '聆听中'),
                  PipelinePhase.transcribing => (Colors.lightBlueAccent, '识别/翻译中…'),
                  PipelinePhase.error => (Colors.redAccent, '出错'),
                  PipelinePhase.stopped => (Colors.grey, '已停止'),
                };
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(text, style: const TextStyle(fontSize: 12)),
                  ],
                );
              },
            ),
            const Spacer(),
            IconButton(
              tooltip: '清空字幕',
              icon: const Icon(Icons.clear_all, size: 16),
              onPressed: () => setState(_entries.clear),
            ),
            IconButton(
              tooltip: '返回设置 (Esc)',
              icon: const Icon(Icons.settings, size: 16),
              onPressed: widget.onBackToSettings,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtitleList() {
    if (_entries.isEmpty) {
      return Center(
        child: ValueListenableBuilder<PipelineState>(
          valueListenable: widget.pipeline.state,
          builder: (context, state, _) {
            if (state.phase == PipelinePhase.error) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  state.message.isEmpty ? '发生错误' : state.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                ),
              );
            }
            return Text(
              '等待语音…',
              style: TextStyle(
                  color: Colors.white38, fontSize: widget.fontSize),
            );
          },
        ),
      );
    }
    final reversed = _entries.reversed.toList();
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      itemCount: reversed.length,
      itemBuilder: (context, index) {
        final entry = reversed[index];
        final finalStyle = entry.isFinal;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.original,
                style: TextStyle(
                  color: finalStyle ? Colors.white : Colors.white70,
                  fontSize: widget.fontSize,
                  height: 1.25,
                  fontStyle: finalStyle ? FontStyle.normal : FontStyle.italic,
                ),
              ),
              if (entry.translated.isNotEmpty)
                Text(
                  entry.translated,
                  style: TextStyle(
                    color: finalStyle
                        ? Colors.amberAccent
                        : const Color(0xCCFFD54F),
                    fontSize: widget.fontSize,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                  ),
                )
              else
                Text(
                  finalStyle ? '翻译中…' : '…',
                  style: TextStyle(
                    color: Colors.white30,
                    fontSize: widget.fontSize - 2,
                    height: 1.3,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
