import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';

void main() {
  group('direct USB PCM format negotiation', () {
    test('96 kHz / 24-bit source never silently becomes 96 kHz / 16-bit', () {
      final format = PlayerService.derivePcmDirectUsbFormat(
        sampleRate: 96000,
        resolution: '24-bit / 96 kHz FLAC',
      );
      expect(format?.sampleRate, 96000);
      expect(format?.bitDepth, 24);
      expect(format?.channels, 2);
    });

    test('missing bit depth triggers probe instead of invented 16-bit', () {
      expect(
        PlayerService.derivePcmDirectUsbFormat(sampleRate: 96000),
        isNull,
      );
      expect(
        PlayerService.derivePcmDirectUsbFormat(
          bitDepth: 24,
          resolution: '24-bit FLAC',
        ),
        isNull,
      );
    });

    test('exact 44.1/16 and 96/24 metadata are preserved', () {
      final cd = PlayerService.derivePcmDirectUsbFormat(
        sampleRate: 44100, bitDepth: 16,
      );
      final hiRes = PlayerService.derivePcmDirectUsbFormat(
        sampleRate: 96000, bitDepth: 24,
      );
      expect(cd?.sampleRate, 44100);
      expect(cd?.bitDepth, 16);
      expect(hiRes?.sampleRate, 96000);
      expect(hiRes?.bitDepth, 24);
    });

    test('conflicting PCM metadata triggers real decoder probe', () {
      expect(
        PlayerService.derivePcmDirectUsbFormat(
          sampleRate: 96000, bitDepth: 16,
          resolution: '96kHz 24-bit',
        ),
        isNull,
      );
      expect(
        PlayerService.derivePcmDirectUsbFormat(
          sampleRate: 48000, bitDepth: 24,
          resolution: '96kHz 24-bit',
        ),
        isNull,
      );
    });
  });

  group('direct USB transfer recovery classification', () {
    test('libusb I/O -1, busy -6 and URB failure permit bounded reset', () {
      expect(
        isRecoverableDirectUsbTransportError(
          'Android USB direct transfer failed: '
          'libusb_submit_transfer failed with code -1',
        ),
        isTrue,
      );
      expect(
        isRecoverableDirectUsbTransportError(
          'libusb_submit_transfer failed with code -6',
        ),
        isTrue,
      );
      expect(
        isRecoverableDirectUsbTransportError(
          'Android USB direct transfer failed: isochronous transfer failed',
        ),
        isTrue,
      );
    });

    test('unsupported PCM endpoint and unplug are not treated as I/O reset', () {
      expect(
        isRecoverableDirectUsbTransportError(
          'No isochronous OUT endpoint can carry 96000 Hz / 16-bit / 2 ch',
        ),
        isFalse,
      );
      expect(
        isRecoverableDirectUsbTransportError('USB direct host handle lost'),
        isFalse,
      );
    });
  });
}
