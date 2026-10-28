import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/uac2_service.dart';

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

  group('USB alternate-setting transport tuples', () {
    const alternatives = <Map<String, dynamic>>[
      {
        'format_tag': 'PCM',
        'bit_resolution': 16,
        'channels': 2,
        'subslot_size': 2,
        'service_interval_us': 1000,
        'max_packet_bytes': 192,
        'sample_rates': [44100, 48000],
      },
      {
        'format_tag': 'PCM',
        'bit_resolution': 24,
        'channels': 2,
        'subslot_size': 3,
        'service_interval_us': 1000,
        'max_packet_bytes': 600,
        'sample_rates': [96000],
      },
    ];

    test('96/16 is rejected despite both values appearing in capability lists', () {
      final requested = const Uac2AudioFormat(
        sampleRate: 96000, bitDepth: 16, channels: 2,
      );
      expect(
        Uac2Service.choosePcmUsbAltFormat(
          requested, alternatives, bitPerfect: true,
        ),
        isNull,
      );
    });

    test('96/24 and 44.1/16 use their actual matching endpoint', () {
      for (final requested in [
        const Uac2AudioFormat(sampleRate: 96000, bitDepth: 24, channels: 2),
        const Uac2AudioFormat(sampleRate: 44100, bitDepth: 16, channels: 2),
      ]) {
        final result = Uac2Service.choosePcmUsbAltFormat(
          requested, alternatives, bitPerfect: true,
        );
        expect(result?.sampleRate, requested.sampleRate);
        expect(result?.bitDepth, requested.bitDepth);
      }
    });

    test('only non-bit-perfect playback may choose a different tuple', () {
      const requested = Uac2AudioFormat(
        sampleRate: 96000, bitDepth: 16, channels: 2,
      );
      final result = Uac2Service.choosePcmUsbAltFormat(
        requested, alternatives, bitPerfect: false,
      );
      expect(result?.sampleRate, 48000);
      expect(result?.bitDepth, 16);
    });

    test('endpoint without enough bytes per USB service interval is rejected', () {
      const requested = Uac2AudioFormat(
        sampleRate: 96000, bitDepth: 24, channels: 2,
      );
      final impossible = <Map<String, dynamic>>[
        {...alternatives[1], 'max_packet_bytes': 64},
      ];
      expect(
        Uac2Service.choosePcmUsbAltFormat(
          requested, impossible, bitPerfect: true,
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
