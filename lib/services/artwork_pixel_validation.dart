import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

const artworkMaxBytes = 5 * 1024 * 1024;
const artworkMaxPixels = 16 * 1024 * 1024;

/// Actual decoded image dimensions and validated bytes. This is intentionally
/// a separate isolate: add-on responses must never decode on the Flutter UI.
/// The fixed image >=4.10.2 JPEG decoder also rejects hostile SOF dimensions.
class ValidatedArtwork {
  const ValidatedArtwork({
    required this.bytes,
    required this.shortSide,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int shortSide;
  final int width;
  final int height;
}

Future<ValidatedArtwork?> validateArtworkBytes(
  Uint8List bytes, {
  bool ensureJpeg = false,
}) async {
  if (bytes.isEmpty || bytes.length > artworkMaxBytes) return null;
  return Isolate.run(() {
    try {
      final jpeg = bytes.length >= 3 &&
          bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;
      final png = bytes.length >= 8 &&
          bytes[0] == 0x89 && bytes[1] == 0x50 &&
          bytes[2] == 0x4e && bytes[3] == 0x47;
      final webp = bytes.length >= 12 &&
          String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
          String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP';
      if (!jpeg && !png && !webp) return null;

      // The older image decoder tolerates truncated JPEG scans. Even when
      // decoding appears successful, do not embed bytes without JPEG EOI.
      if (jpeg && (bytes[bytes.length - 2] != 0xff ||
          bytes[bytes.length - 1] != 0xd9)) return null;

      final decoder = image.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      final width = info?.width ?? 0;
      final height = info?.height ?? 0;
      if (width <= 0 || height <= 0 ||
          width > artworkMaxPixels ~/ height ||
          math.min(width, height) < 32) return null;

      // Header-only checks are insufficient: verify complete decodability.
      // Decode exactly one frame, even if a provider returns animated WebP.
      final decoded = image.decodeImage(bytes, frame: 0);
      if (decoded == null || decoded.width != width ||
          decoded.height != height) return null;
      final result = ensureJpeg && !jpeg
          ? Uint8List.fromList(image.encodeJpg(decoded, quality: 92))
          : bytes;
      if (result.length > artworkMaxBytes) return null;
      return ValidatedArtwork(
        bytes: result,
        shortSide: math.min(width, height),
        width: width,
        height: height,
      );
    } catch (_) {
      return null;
    }
  });
}
