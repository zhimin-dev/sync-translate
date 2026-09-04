import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/audio_capture.dart';
import '../config/app_config.dart';
import '../stt/stt_engine.dart';
import '../translate/translator.dart';
import 'vad_segmenter.dart';

/// 一条字幕：原文 + 译文。
/// [translated] 为空串表示译文尚未返回（原文先行阶段）；
/// 译文就绪后流水线会以相同 [seq] 再次发出本条。
class SubtitleEntry {
  SubtitleEntry(this.seq, this.original, this.translated, this.time);

  final int seq;
  final String original;
  final String translated;
  final DateTime time;
}

enum PipelinePhase { idle, starting, listening, transcribing, error, stopped }

class PipelineState {
  const PipelineState(this.phase, [this.message = '']);

  final PipelinePhase phase;
  final String message;

  @override
  String toString() => message.isEmpty ? phase.name : '${phase.name}: $message';
}

/// 翻译流水线：采集 → VAD 分段 → STT → 翻译 → 字幕流。
class TranslationPipeline {
  TranslationPipeline({required AppConfig config})
      : _config = config,
        _stt = createSttEngine(config.stt.engine),
        _translator = createTranslator(config.translate.engine);

  final AppConfig _config;
  final SttEngine _stt;
  final Translator _translator;

  final _subtitles = StreamController<SubtitleEntry>.broadcast();
  Stream<SubtitleEntry> get subtitles => _subtitles.stream;

  final state =
      ValueNotifier<PipelineState>(const PipelineState(PipelinePhase.idle));

  AudioCapture? _capture;
  VadSegmenter? _segmenter;
  StreamSubscription<dynamic>? _chunkSub;
  StreamSubscription<dynamic>? _segSub;
  StreamSubscription<dynamic>? _errSub;
  int _seq = 0;

  Future<void> start() async {
    if (state.value.phase == PipelinePhase.listening ||
        state.value.phase == PipelinePhase.starting) {
      return;
    }
    state.value = const PipelineState(PipelinePhase.starting);
    try {
      await _stt.init(_config.stt);
      await _translator.init(_config.translate);

      final capture = createPlatformAudioCapture();
      _capture = capture;
      final segmenter = VadSegmenter();
      _segmenter = segmenter;

      _errSub = capture.errors
          .listen((e) => state.value = PipelineState(PipelinePhase.error, e));
      _segSub = segmenter.segments.listen(_onSegment);
      _chunkSub = capture.chunks.listen(segmenter.add);

      await capture.start(_config.capture.mode == 'mic'
          ? CaptureSource.microphone
          : CaptureSource.system);
      state.value = const PipelineState(PipelinePhase.listening);
    } catch (e) {
      state.value = PipelineState(PipelinePhase.error, '启动失败: $e');
      await stop();
    }
  }

  Future<void> _onSegment(SpeechSegment segment) async {
    state.value = const PipelineState(PipelinePhase.transcribing);
    try {
      final lang =
          _config.stt.language == 'auto' ? null : _config.stt.language;
      final text = (await _stt.transcribe(segment.pcm16k, language: lang))
          .trim();
      if (text.isEmpty) {
        state.value = const PipelineState(PipelinePhase.listening);
        return;
      }
      final seq = _seq++;
      // 原文先行：识别完成立即上屏，译文随后以同 seq 事件补上（感知延迟大幅下降）
      _subtitles.add(SubtitleEntry(seq, text, '', DateTime.now()));
      final sourceLang = _config.translate.sourceLang == 'auto'
          ? null
          : _config.translate.sourceLang;
      final translated = (await _translator.translate(
        text,
        sourceLang: sourceLang,
        targetLang: _config.translate.targetLang,
      ))
          .trim();
      _subtitles.add(SubtitleEntry(seq, text, translated, DateTime.now()));
      state.value = const PipelineState(PipelinePhase.listening);
    } catch (e) {
      // 单段失败不中断采集，继续听；错误展示在状态栏。
      state.value = PipelineState(PipelinePhase.error, '识别/翻译失败: $e');
    }
  }

  Future<void> stop() async {
    await _chunkSub?.cancel();
    await _segSub?.cancel();
    await _errSub?.cancel();
    _chunkSub = null;
    _segSub = null;
    _errSub = null;
    await _capture?.stop();
    _capture = null;
    final segmenter = _segmenter;
    _segmenter = null;
    // 停止时直接丢弃尾部未完成的语音段（订阅已取消，flush 无处可去）。
    if (segmenter != null) {
      await segmenter.dispose();
    }
    try {
      await _stt.dispose();
    } catch (_) {}
    try {
      await _translator.dispose();
    } catch (_) {}
    if (state.value.phase != PipelinePhase.error) {
      state.value = const PipelineState(PipelinePhase.stopped);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _subtitles.close();
    state.dispose();
  }
}
