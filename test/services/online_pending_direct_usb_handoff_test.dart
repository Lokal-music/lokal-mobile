import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/services/player_service.dart';

void main() {
  group('unavailable online track and direct USB handoff', () {
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
