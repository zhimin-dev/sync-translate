import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/audio_capture.dart';
import '../config/app_config.dart';
import '../stt/stt_engine.dart';
import '../translate/translator.dart';
import 'vad_segmenter.dart';

/// 一条字幕：原文 + 译文。
/// - [isFinal] 为 false 表示"边听边出"的临时字幕（原文随说话持续更新）；
/// - [translated] 为空串表示译文尚未返回；
/// - 最终字幕以递增 [seq] 发出并替换临时字幕；临时字幕固定使用 seq = -1。
class SubtitleEntry {
  SubtitleEntry(this.seq, this.original, this.translated, this.time,
      {this.isFinal = true});

  final int seq;
  final String original;
  final String translated;
  final DateTime time;
  final bool isFinal;

  static const int provisionalSeq = -1;
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
/// 实时性设计：
/// - 说话过程中每 ~0.8s 把当前语音窗口送 STT，结果以"临时字幕"上屏（原文先行）；
/// - 临时字幕的翻译做节流（文本变化且间隔 ≥ 700ms 才翻一次）；
/// - 句子结束（静音切段）后做最终识别+翻译，覆盖临时字幕。
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
  StreamSubscription<dynamic>? _partialSub;
  StreamSubscription<dynamic>? _errSub;
  int _seq = 0;

  // 部分结果（临时字幕）状态
  int _partialSeq = 0; // 单调递增的部分请求号
  int _latestAppliedPartial = -1; // 已上屏的最新部分号；更小的过期丢弃
  bool _partialInFlight = false; // 同时只跑一个部分识别（自然节流）
  String _lastTranslatedPartialText = '';
  int _lastPartialTranslateMs = 0;

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
      _partialSub = segmenter.partials.listen(_onPartial);
      _chunkSub = capture.chunks.listen(segmenter.add);

      await capture.start(_config.capture.mode == 'mic'
              ? CaptureSource.microphone
              : CaptureSource.system,
          device: _config.capture.device.trim().isEmpty
              ? null
              : _config.capture.device);
      state.value = const PipelineState(PipelinePhase.listening);
    } catch (e) {
      state.value = PipelineState(PipelinePhase.error, '启动失败: $e');
      await stop();
    }
  }

  String? get _sttLanguage {
    return _config.stt.language == 'auto' ? null : _config.stt.language;
  }

  String? get _mtSourceLanguage {
    return _config.translate.sourceLang == 'auto'
        ? null
        : _config.translate.sourceLang;
  }

  String get _mtTargetLanguage => _config.translate.targetLang;

  /// 边听边出：说话过程中的滚动窗口识别。
  Future<void> _onPartial(SpeechPartial partial) async {
    if (_partialInFlight) return; // 上一个还没回来，跳过本次（自然节流）
    _partialInFlight = true;
    final reqSeq = _partialSeq++;
    try {
      final text =
          (await _stt.transcribe(partial.pcm16k, language: _sttLanguage))
              .trim();
      if (text.isEmpty) return;
      if (reqSeq <= _latestAppliedPartial) return; // 已过期
      _latestAppliedPartial = reqSeq;
      _subtitles.add(SubtitleEntry(
        SubtitleEntry.provisionalSeq,
        text,
        '',
        DateTime.now(),
        isFinal: false,
      ));
      // 翻译节流：文本有变化且距上次 ≥ 700ms 才翻一次
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (text != _lastTranslatedPartialText &&
          nowMs - _lastPartialTranslateMs >= 700) {
        _lastPartialTranslateMs = nowMs;
        try {
          final translated = (await _translator.translate(
            text,
            sourceLang: _mtSourceLanguage,
            targetLang: _mtTargetLanguage,
          ))
              .trim();
          if (reqSeq < _latestAppliedPartial) return; // 期间已有更新结果
          _lastTranslatedPartialText = text;
          _subtitles.add(SubtitleEntry(
            SubtitleEntry.provisionalSeq,
            text,
            translated,
            DateTime.now(),
            isFinal: false,
          ));
        } catch (_) {
          // 部分翻译失败忽略（最终翻译会兜底）
        }
      }
    } catch (_) {
      // 部分识别失败忽略
    } finally {
      _partialInFlight = false;
    }
  }

  /// 句子结束：最终识别 + 翻译，覆盖临时字幕。
  Future<void> _onSegment(SpeechSegment segment) async {
    // 使所有在途的部分结果过期
    _latestAppliedPartial = _partialSeq++;
    _lastTranslatedPartialText = '';
    state.value = const PipelineState(PipelinePhase.transcribing);
    try {
      final text =
          (await _stt.transcribe(segment.pcm16k, language: _sttLanguage))
              .trim();
      if (text.isEmpty) {
        state.value = const PipelineState(PipelinePhase.listening);
        return;
      }
      final seq = _seq++;
      // 原文先行：识别完成立即上屏，译文随后以同 seq 事件补上（感知延迟大幅下降）
      _subtitles.add(SubtitleEntry(seq, text, '', DateTime.now()));
      final translated = (await _translator.translate(
        text,
        sourceLang: _mtSourceLanguage,
        targetLang: _mtTargetLanguage,
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
    await _partialSub?.cancel();
    await _errSub?.cancel();
    _chunkSub = null;
    _segSub = null;
    _partialSub = null;
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
