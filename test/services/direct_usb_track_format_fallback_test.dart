import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/uac2_service.dart';

void main() {
  group('direct USB exact PCM compatibility', () {
    const pcm44116 = Uac2AudioFormat(
      sampleRate: 44100,
      bitDepth: 16,
      channels: 2,
    );
    const pcm44124 = Uac2AudioFormat(
      sampleRate: 44100,
      bitDepth: 24,
      channels: 2,
    );
    const pcm48024 = Uac2AudioFormat(
      sampleRate: 48000,
      bitDepth: 24,
      channels: 2,
    );

    test('accepts only an exact format, not a rate/depth substitute', () {
      expect(exactDirectUsbFormatSupported(pcm44116, pcm44116), isTrue);
      expect(exactDirectUsbFormatSupported(pcm44124, pcm44116), isFalse);
      expect(exactDirectUsbFormatSupported(pcm48024, pcm44116), isFalse);
      expect(exactDirectUsbFormatSupported(pcm44116, null), isFalse);
    });

    test('rejects a different DSD transport mode', () {
      const dop = Uac2AudioFormat(
        sampleRate: 176400,
        bitDepth: 24,
        channels: 2,
        isDop: true,
      );
      const nativeDsd = Uac2AudioFormat(
        sampleRate: 176400,
        bitDepth: 24,
        channels: 2,
        isNativeDsd: true,
      );
      expect(exactDirectUsbFormatSupported(dop, nativeDsd), isFalse);
    });
  });

  group('track-scoped USB fallback recovery', () {
    test('after an incompatible song, a different track retries direct USB', () {
      expect(
        shouldRearmUsbAfterIncompatibleTrack(
          incompatibleTrackKey: 'track24|qobuz|48000|24',
          requestedTrackKey: 'track16|qobuz|44100|16',
        ),
        isTrue,
      );
    });

    test('online songs can be re-resolved at a new supported quality', () {
      expect(
        shouldRearmUsbAfterIncompatibleTrack(
          incompatibleTrackKey: 'same-id|24-bit-path|48000|24',
          requestedTrackKey: 'same-id|16-bit-path|44100|16',
        ),
        isTrue,
      );
    });

    test('retrying the same incompatible source does not loop', () {
      expect(
        shouldRearmUsbAfterIncompatibleTrack(
          incompatibleTrackKey: 'song|online-url|48000|24',
          requestedTrackKey: 'song|online-url|48000|24',
        ),
        isFalse,
      );
    });

    test('ordinary playback does not trigger route re-evaluation', () {
      expect(
        shouldRearmUsbAfterIncompatibleTrack(
          incompatibleTrackKey: null,
          requestedTrackKey: 'track16|qobuz|44100|16',
        ),
        isFalse,
      );
    });
  });
}
