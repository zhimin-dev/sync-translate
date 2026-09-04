import 'dart:typed_data';

/// 将 16kHz 单声道 float32 PCM 编码为 WAV (PCM16)。
/// 用于 OpenAI 兼容 /audio/transcriptions 接口的 multipart 上传。
Uint8List encodeWavPcm16(Float32List pcm, {int sampleRate = 16000}) {
  const channels = 1;
  const bitsPerSample = 16;
  final bytesPerSample = bitsPerSample ~/ 8;
  final dataLen = pcm.length * bytesPerSample;
  final bytes = Uint8List(44 + dataLen);
  final bd = ByteData.view(bytes.buffer);

  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  bd.setUint32(4, 36 + dataLen, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  bd.setUint32(16, 16, Endian.little); // fmt 块长度
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * channels * bytesPerSample, Endian.little);
  bd.setUint16(32, channels * bytesPerSample, Endian.little);
  bd.setUint16(34, bitsPerSample, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  bd.setUint32(40, dataLen, Endian.little);

  for (var i = 0; i < pcm.length; i++) {
    final v = (pcm[i].clamp(-1.0, 1.0) * 32767.0).round();
    bd.setInt16(44 + i * bytesPerSample, v, Endian.little);
  }
  return bytes;
}
