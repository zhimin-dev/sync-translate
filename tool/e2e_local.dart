// 端到端验证：播放英文语音 → WASAPI 采集 → faster-whisper 识别 → NLLB-200 翻译。
// 前置：两个本地服务已启动；tool/speech_sample.wav 存在。
// 运行：dart run tool/e2e_local.dart
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:sync_translate/core/audio/resampler.dart';
import 'package:sync_translate/core/stt/wav_encoder.dart';

typedef _StartNative = Int32 Function(Int32, Pointer<Pointer<Void>>);
typedef _StartDart = int Function(int, Pointer<Pointer<Void>>);
typedef _ReadNative = Int32 Function(
    Pointer<Void>, Pointer<Float>, Int32, Pointer<Int32>, Pointer<Int32>);
typedef _ReadDart = int Function(
    Pointer<Void>, Pointer<Float>, int, Pointer<Int32>, Pointer<Int32>);
typedef _StopNative = Void Function(Pointer<Void>);
typedef _StopDart = void Function(Pointer<Void>);
typedef _PlaySoundNative = Int32 Function(Pointer<Utf16>, Pointer<Void>, Uint32);
typedef _PlaySoundDart = int Function(Pointer<Utf16>, Pointer<Void>, int);

const whisperBase = 'http://127.0.0.1:8000/v1';
const nllbBase = 'http://127.0.0.1:8765';

Future<void> main() async {
  final speechPath = 'tool${Platform.pathSeparator}speech_sample.wav';
  if (!File(speechPath).existsSync()) {
    stderr.writeln('缺少 $speechPath（先用 SAPI 生成：见下方说明）');
    exit(2);
  }

  final dllPath =
      r'D:\myweb\sync-translate\build\windows\x64\runner\Release\wasapi_capture.dll';
  final lib = DynamicLibrary.open(dllPath);
  final start = lib.lookupFunction<_StartNative, _StartDart>('wasapi_start');
  final read = lib.lookupFunction<_ReadNative, _ReadDart>('wasapi_read');
  final stop = lib.lookupFunction<_StopNative, _StopDart>('wasapi_stop');
  final winmm = DynamicLibrary.open('winmm.dll');
  final playSound =
      winmm.lookupFunction<_PlaySoundNative, _PlaySoundDart>('PlaySoundW');

  // 1. 播放语音样本（循环，采 6 秒）
  final p = speechPath.toNativeUtf16();
  final rc = playSound(p, nullptr, 0x0001 | 0x0008 | 0x20000);
  if (rc == 0) {
    stderr.writeln('PlaySound 失败');
    exit(2);
  }
  stdout.writeln('[1/4] 播放语音样本并采集 6 秒…');

  // 2. WASAPI 采集
  final outHandle = calloc<Pointer<Void>>();
  var rcStart = start(0, outHandle);
  if (rcStart != 0) {
    stderr.writeln('采集启动失败 rc=$rcStart');
    exit(1);
  }
  final handle = outHandle.value;
  calloc.free(outHandle);

  final buf = calloc<Float>(48000);
  final framesRead = calloc<Int32>();
  final sampleRate = calloc<Int32>();
  final captured = <double>[];
  var srcRate = 0;
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < 6000) {
    final r = read(handle, buf, 48000, framesRead, sampleRate);
    if (r != 0) {
      stderr.writeln('读取失败 rc=$r');
      break;
    }
    if (srcRate == 0) srcRate = sampleRate.value;
    final n = framesRead.value;
    if (n > 0) captured.addAll(buf.asTypedList(n));
  }
  stop(handle);
  playSound(nullptr, nullptr, 0);
  calloc.free(p);
  calloc.free(buf);
  calloc.free(framesRead);
  calloc.free(sampleRate);
  stdout.writeln('[2/4] 采集完成：${captured.length} 帧 @$srcRate Hz（${(captured.length / srcRate).toStringAsFixed(1)}s）');

  // 3. 重采样到 16k 并识别
  final resampler = LinearResampler(srcRate.toDouble(), 16000);
  final pcm16k = resampler.process(Float32List.fromList(captured));
  final wav = encodeWavPcm16(pcm16k);
  stdout.writeln('[3/4] 调用 faster-whisper 识别（${pcm16k.length} 样本 = ${(pcm16k.length / 16000).toStringAsFixed(1)}s）…');

  final sttSw = Stopwatch()..start();
  final request = http.MultipartRequest(
      'POST', Uri.parse('$whisperBase/audio/transcriptions'));
  request.fields['model'] = 'deepdml/faster-whisper-large-v3-turbo-ct2';
  request.fields['response_format'] = 'json';
  request.files.add(http.MultipartFile.fromBytes(
    'file',
    wav,
    filename: 'audio.wav',
    contentType: MediaType('audio', 'wav'),
  ));
  final resp = await http.Response.fromStream(
      await http.Client().send(request).timeout(const Duration(seconds: 60)));
  sttSw.stop();
  if (resp.statusCode != 200) {
    stderr.writeln('STT HTTP ${resp.statusCode}: ${resp.body}');
    exit(1);
  }
  final text = (jsonDecode(utf8.decode(resp.bodyBytes))
      as Map<String, dynamic>)['text'] as String;
  stdout.writeln('识别结果: "$text" （耗时 ${sttSw.elapsedMilliseconds}ms）');

  // 4. NLLB 翻译
  stdout.writeln('[4/4] 调用 NLLB-200 翻译（en → zh）…');
  final trSw = Stopwatch()..start();
  final trResp = await http
      .post(Uri.parse('$nllbBase/translate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(
              {'text': text, 'source_lang': 'en', 'target_lang': 'zh'}))
      .timeout(const Duration(seconds: 60));
  trSw.stop();
  if (trResp.statusCode != 200) {
    stderr.writeln('翻译 HTTP ${trResp.statusCode}: ${trResp.body}');
    exit(1);
  }
  final translation = (jsonDecode(utf8.decode(trResp.bodyBytes))
      as Map<String, dynamic>)['translation'] as String;
  stdout.writeln('翻译结果: "$translation" （耗时 ${trSw.elapsedMilliseconds}ms）');

  stdout.writeln('');
  stdout.writeln('=== 端到端验证通过 ===');
}
