import 'dart:typed_data';

/// 线性插值重采样器（流式，任意采样率 → 目标采样率）。
/// MVP 使用线性插值，语音字幕场景足够；后续可替换为 sinc 滤波实现。
class LinearResampler {
  LinearResampler(this.srcRate, this.dstRate)
      : assert(srcRate > 0),
        assert(dstRate > 0),
        _ratio = srcRate / dstRate;

  /// 源采样率（Hz）。
  final double srcRate;

  /// 目标采样率（Hz）。
  final double dstRate;

  final double _ratio;
  final List<double> _buf = [];
  double _pos = 0;

  /// 输入源采样率样本，返回目标采样率样本（可能为空）。
  Float32List process(Float32List input) {
    if (input.isEmpty) return Float32List(0);
    _buf.addAll(input);
    final out = <double>[];
    // 需要 i0+1 有效，即 _pos < len - 1
    while (_pos + _ratio <= _buf.length - 1) {
      final i0 = _pos.floor();
      final frac = _pos - i0;
      out.add(_buf[i0] * (1 - frac) + _buf[i0 + 1] * frac);
      _pos += _ratio;
    }
    // 丢弃已消费前缀，仅保留插值所需的尾部样本
    final consumed = _pos.floor();
    if (consumed > 0) {
      _buf.removeRange(0, consumed);
      _pos -= consumed;
    }
    final result = Float32List(out.length);
    for (var i = 0; i < out.length; i++) {
      result[i] = out[i];
    }
    return result;
  }

  void reset() {
    _buf.clear();
    _pos = 0;
  }
}
