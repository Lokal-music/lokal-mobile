import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/services/player_service.dart';

void main() {
  group('unavailable online track and direct USB handoff', () {
    test('does not stop USB playback for an unavailable placeholder', () async {
      var stops = 0;
      for (var unavailable = 0; unavailable < 3; unavailable++) {
        await stopSourceBeforePendingLookup(
          preserveCurrentSource: true,
          stopSource: () async { stops++; },
        );
      }
      expect(stops, 0, reason: 'auto-skipping must not tear down the USB DAC');
    });

    test('regular Android playback still stops before pending resolution', () async {
      var stops = 0;
      await stopSourceBeforePendingLookup(
        preserveCurrentSource: false,
        stopSource: () async { stops++; },
      );
      expect(stops, 1);
    });

    test('keeps existing USB source when a pending song needs resolution', () {
      expect(
        shouldKeepDirectUsbAliveDuringPendingLookup(
          engine: AudioEngineType.usbDacExperimental,
          hasAttachedEngine: true,
          hasLoadedSource: true,
        ),
        isTrue,
      );
    });

    test('consecutive missing candidates can reuse the same direct USB source', () {
      // The UI loading flag can be false between skips. The policy must use
      // the real native source/engine, not the transient UI playing notifier.
      for (var missingCandidate = 0; missingCandidate < 4; missingCandidate++) {
        expect(
          shouldKeepDirectUsbAliveDuringPendingLookup(
            engine: AudioEngineType.usbDacExperimental,
            hasAttachedEngine: true,
            hasLoadedSource: true,
          ),
          isTrue,
        );
      }
    });

    test('without a live USB source, normal stop/prepare remains available', () {
      expect(
        shouldKeepDirectUsbAliveDuringPendingLookup(
          engine: AudioEngineType.usbDacExperimental,
          hasAttachedEngine: true,
          hasLoadedSource: false,
        ),
        isFalse,
      );
      expect(
        shouldKeepDirectUsbAliveDuringPendingLookup(
          engine: AudioEngineType.usbDacExperimental,
          hasAttachedEngine: false,
          hasLoadedSource: true,
        ),
        isFalse,
      );
    });

    test('non-USB routes keep the original stop-before-replace policy', () {
      for (final engine in [
        AudioEngineType.normalAndroid,
        AudioEngineType.rustOboe,
      ]) {
        expect(
          shouldKeepDirectUsbAliveDuringPendingLookup(
            engine: engine,
            hasAttachedEngine: true,
            hasLoadedSource: true,
          ),
          isFalse,
        );
      }
    });
  });
}
