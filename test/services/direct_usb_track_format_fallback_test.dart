import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/uac2_service.dart';

void main() {
  group('manual direct USB restart verification', () {
    test('rejects route selection without actual streaming', () {
      expect(
        isVerifiedUsbRestartPlayback(
          directRouteSelected: true,
          streamActive: false,
          streamStable: false,
          bitPerfectVerified: false,
          consumerFrames: 0,
          previousConsumerFrames: 0,
          transportError: false,
        ),
        isFalse,
      );
    });

    test('rejects a stream that stopped consuming frames', () {
      expect(
        isVerifiedUsbRestartPlayback(
          directRouteSelected: true,
          streamActive: true,
          streamStable: true,
          bitPerfectVerified: true,
          consumerFrames: 700,
          previousConsumerFrames: 700,
          transportError: false,
        ),
        isFalse,
      );
    });

    test('rejects a transport failure even after bit-perfect verified', () {
      expect(
        isVerifiedUsbRestartPlayback(
          directRouteSelected: true,
          streamActive: true,
          streamStable: true,
          bitPerfectVerified: true,
          consumerFrames: 900,
          previousConsumerFrames: 700,
          transportError: true,
        ),
        isFalse,
      );
    });

    test('accepts only live, verified USB consumption', () {
      expect(
        isVerifiedUsbRestartPlayback(
          directRouteSelected: true,
          streamActive: true,
          streamStable: true,
          bitPerfectVerified: true,
          consumerFrames: 900,
          previousConsumerFrames: 700,
          transportError: false,
        ),
        isTrue,
      );
    });
  });

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
        shouldRearmUsbAfterTrackScopedFallback(
          fallbackTrackKey: 'track24|qobuz|48000|24',
          requestedTrackKey: 'track16|qobuz|44100|16',
        ),
        isTrue,
      );
    });

    test('online songs can be re-resolved at a new supported quality', () {
      expect(
        shouldRearmUsbAfterTrackScopedFallback(
          fallbackTrackKey: 'same-id|24-bit-path|48000|24',
          requestedTrackKey: 'same-id|16-bit-path|44100|16',
        ),
        isTrue,
      );
    });

    test('a signed HTTP-only online source does not permanently disable USB', () {
      expect(
        shouldRearmUsbAfterTrackScopedFallback(
          fallbackTrackKey: 'http-addon|signed-url|lossless',
          requestedTrackKey: 'next-local|flac|44100|16',
        ),
        isTrue,
      );
    });

    test('retrying the same incompatible source does not loop', () {
      expect(
        shouldRearmUsbAfterTrackScopedFallback(
          fallbackTrackKey: 'song|online-url|48000|24',
          requestedTrackKey: 'song|online-url|48000|24',
        ),
        isFalse,
      );
    });

    test('ordinary playback does not trigger route re-evaluation', () {
      expect(
        shouldRearmUsbAfterTrackScopedFallback(
          fallbackTrackKey: null,
          requestedTrackKey: 'track16|qobuz|44100|16',
        ),
        isFalse,
      );
    });
  });
}
