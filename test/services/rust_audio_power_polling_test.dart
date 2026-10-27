import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/rust_audio_service.dart';

void main() {
  group('Rust audio power-aware event polling', () {
    test('active foreground audio retains quick crossfade handoff', () {
      for (final state in [
        RustPlaybackState.playing,
        RustPlaybackState.buffering,
        RustPlaybackState.crossfading,
      ]) {
        expect(
          RustAudioService.eventPollIntervalFor(
            state: state,
            foreground: true,
          ),
          const Duration(milliseconds: 50),
        );
        expect(
          RustAudioService.eventPollIntervalFor(
            state: state,
            foreground: false,
          ),
          const Duration(milliseconds: 250),
        );
      }
    });

    test('paused playback no longer polls at active playback rates', () {
      expect(
        RustAudioService.eventPollIntervalFor(
          state: RustPlaybackState.paused,
          foreground: true,
        ),
        const Duration(milliseconds: 500),
      );
      expect(
        RustAudioService.eventPollIntervalFor(
          state: RustPlaybackState.paused,
          foreground: false,
        ),
        const Duration(seconds: 1),
      );
    });

    test('idle and stopped engines use a low-frequency check', () {
      for (final state in [
        RustPlaybackState.idle,
        RustPlaybackState.stopped,
      ]) {
        expect(
          RustAudioService.eventPollIntervalFor(
            state: state,
            foreground: true,
          ),
          const Duration(seconds: 1),
        );
        expect(
          RustAudioService.eventPollIntervalFor(
            state: state,
            foreground: false,
          ),
          const Duration(seconds: 2),
        );
      }
    });
  });
}
