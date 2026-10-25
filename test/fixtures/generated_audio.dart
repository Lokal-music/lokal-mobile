import 'dart:math' as math;
import 'dart:typed_data';

// Generated PCM tone for native tests; no recorded music is redistributed.
Uint8List generatedPcmTone() {
  const rate = 44100, frames = rate * 8;
  final bytes = ByteData(44 + frames * 2);
  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bytes.setUint32(40, frames * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    bytes.setInt16(
      44 + i * 2,
      (math.sin(i * 2 * math.pi * 440 / rate) * 1000).round(),
      Endian.little,
    );
  }
  return bytes.buffer.asUint8List();
}
