import 'dart:typed_data';

import 'package:flick/services/artwork_pixel_validation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test(
    'valid JPEG bytes return original dimensions and original bytes',
    () async {
      final bytes = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 480, height: 320)),
      );
      final result = await validateArtworkBytes(bytes, ensureJpeg: true);
      expect(result, isNotNull);
      expect(result!.shortSide, 320);
      expect(result.bytes, bytes);
    },
  );

  test('truncated JPEG scan is never accepted or embedded', () async {
    final bytes = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 480, height: 320)),
    );
    final truncated = Uint8List.fromList(bytes.sublist(0, bytes.length - 2));
    expect(await validateArtworkBytes(truncated), isNull);
  });

  test(
    'malicious declared dimensions are rejected before pixel allocation',
    () async {
      final source = img.encodeJpg(img.Image(width: 128, height: 128));
      final bytes = Uint8List.fromList(source);
      var patched = false;
      for (var i = 0; i < bytes.length - 9; i++) {
        if (bytes[i] == 0xff &&
            (bytes[i + 1] == 0xc0 || bytes[i + 1] == 0xc2)) {
          bytes[i + 5] = 0x7f;
          bytes[i + 6] = 0xff;
          bytes[i + 7] = 0x7f;
          bytes[i + 8] = 0xff;
          patched = true;
          break;
        }
      }
      expect(patched, isTrue);
      expect(await validateArtworkBytes(bytes), isNull);
    },
  );

  test(
    'fake JPEG header and images smaller than 32 pixels are rejected',
    () async {
      expect(
        await validateArtworkBytes(
          Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
        ),
        isNull,
      );
      final tiny = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 16, height: 16)),
      );
      expect(await validateArtworkBytes(tiny), isNull);
    },
  );
}
