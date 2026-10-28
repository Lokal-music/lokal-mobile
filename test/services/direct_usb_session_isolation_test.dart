import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/services/android_audio_device_service.dart';
import 'package:flick/services/audio_session_manager.dart';
import 'package:flick/services/uac2_service.dart';

void main() {
  group('USB playback-active serialization', () {
    test('skips obsolete activity changes before they reach Android', () async {
      final writes = <bool>[];
      final writer = LatestUsbPlaybackActivityWriter((active) async {
        writes.add(active);
      });

      final obsolete = writer.set(false);
      final current = writer.set(true);
      await Future.wait([obsolete, current]);

      expect(writes, [true]);
      expect(writer.applied, isTrue);
    });

    test('a pending deactivate cannot override a newer active session', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final writes = <bool>[];
      final writer = LatestUsbPlaybackActivityWriter((active) async {
        writes.add(active);
        if (active && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      });

      final first = writer.set(true);
      await entered.future;
      final obsoleteDeactivation = writer.set(false);
      final continuedPlayback = writer.set(true);
      release.complete();
      await Future.wait([first, obsoleteDeactivation, continuedPlayback]);

      expect(writes, [true]);
      expect(writer.applied, isTrue);
    });

    test('explicit final deactivation still reaches the native host', () async {
      final writes = <bool>[];
      final writer = LatestUsbPlaybackActivityWriter((active) async {
        writes.add(active);
      });

      await writer.set(true);
      await writer.set(false);
      expect(writes, [true, false]);
      expect(writer.applied, isFalse);
    });

    test('a rejected native operation does not block a later retry', () async {
      var attempts = 0;
      final writer = LatestUsbPlaybackActivityWriter((active) async {
        attempts++;
        if (attempts == 1) throw StateError('native USB focus unavailable');
      });
      await expectLater(writer.set(true), throwsStateError);
      expect(writer.applied, isNull);
      await writer.set(true);
      expect(writer.applied, isTrue);
      expect(attempts, 2);
    });
  });

  group('route-change isolation', () {
    test('retains active direct USB on an incidental Android route event', () {
      expect(
        shouldDeferDirectUsbRouteProbe(
          reason: 'audio route change',
          selectedMode: AudioEngineType.usbDacExperimental,
          initializedMode: AudioEngineType.usbDacExperimental,
          playbackActive: true,
          directUsbSessionActive: true,
        ),
        isTrue,
      );
    });

    test('allows shutdown, manual preference changes and fallback', () {
      for (final entry in <({
        String reason,
        AudioEngineType selected,
        bool playing,
        bool active,
      })>[
        (
          reason: 'bit-perfect preference changed',
          selected: AudioEngineType.usbDacExperimental,
          playing: true,
          active: true,
        ),
        (
          reason: 'audio route change',
          selected: AudioEngineType.usbDacExperimental,
          playing: false,
          active: true,
        ),
        (
          reason: 'audio route change',
          selected: AudioEngineType.usbDacExperimental,
          playing: true,
          active: false,
        ),
        (
          reason: 'audio route change',
          selected: AudioEngineType.normalAndroid,
          playing: true,
          active: true,
        ),
      ]) {
        expect(
          shouldDeferDirectUsbRouteProbe(
            reason: entry.reason,
            selectedMode: entry.selected,
            initializedMode: AudioEngineType.usbDacExperimental,
            playbackActive: entry.playing,
            directUsbSessionActive: entry.active,
          ),
          isFalse,
        );
      }
    });

    test('rejects route result when USB ownership activates mid-probe', () {
      expect(
        shouldDiscardStaleDirectUsbRouteProbe(
          reason: 'audio route change',
          directUsbSessionWasActive: false,
          selectedMode: AudioEngineType.usbDacExperimental,
          initializedMode: AudioEngineType.usbDacExperimental,
          playbackActive: true,
          directUsbSessionActive: true,
        ),
        isTrue,
      );
    });

    test('does not discard intentional changes or non-live USB results', () {
      for (final reason in [
        'bit-perfect preference changed',
        'manual direct USB retry',
        'engine preference changed',
      ]) {
        expect(
          shouldDiscardStaleDirectUsbRouteProbe(
            reason: reason,
            directUsbSessionWasActive: false,
            selectedMode: AudioEngineType.usbDacExperimental,
            initializedMode: AudioEngineType.usbDacExperimental,
            playbackActive: true,
            directUsbSessionActive: true,
          ),
          isFalse,
        );
      }

      expect(
        shouldDiscardStaleDirectUsbRouteProbe(
          reason: 'audio route change',
          directUsbSessionWasActive: false,
          selectedMode: AudioEngineType.usbDacExperimental,
          initializedMode: AudioEngineType.usbDacExperimental,
          playbackActive: true,
          directUsbSessionActive: false,
        ),
        isFalse,
      );
      expect(
        shouldDiscardStaleDirectUsbRouteProbe(
          reason: 'audio route change',
          directUsbSessionWasActive: true,
          selectedMode: AudioEngineType.usbDacExperimental,
          initializedMode: AudioEngineType.usbDacExperimental,
          playbackActive: true,
          directUsbSessionActive: true,
        ),
        isFalse,
      );
    });

    test('failed route query retains the exact live USB status', () {
      final usbStatus = Uac2DeviceStatus(
        device: Uac2DeviceInfo(
          vendorId: 0x1234,
          productId: 0x5678,
          serial: null,
          productName: 'Audiocular D07',
          manufacturer: 'Audiocular',
          deviceName: '/dev/bus/usb/001/002',
        ),
        state: Uac2State.streaming,
        routeType: Uac2RouteType.externalUsb,
        routeLabel: 'Audiocular D07',
        isExternalRoute: true,
        currentFormat: const Uac2AudioFormat(
          sampleRate: 96000,
          bitDepth: 24,
          channels: 2,
        ),
      );
      final preserved = directUsbStatusToPreserveOnFailedRouteProbe(
        currentStatus: usbStatus,
        directUsbPlaybackActive: true,
      );
      expect(identical(preserved, usbStatus), isTrue);
      expect(preserved?.routeType, Uac2RouteType.externalUsb);
      expect(preserved?.currentFormat?.sampleRate, 96000);
      expect(preserved?.state, Uac2State.streaming);

      // Explicit release must NOT keep stale USB device state.
      expect(
        directUsbStatusToPreserveOnFailedRouteProbe(
          currentStatus: usbStatus,
          directUsbPlaybackActive: false,
        ),
        isNull,
      );
      expect(
        directUsbStatusToPreserveOnFailedRouteProbe(
          currentStatus: null,
          directUsbPlaybackActive: true,
        ),
        isNull,
      );
      expect(
        directUsbStatusToPreserveOnFailedRouteProbe(
          currentStatus: usbStatus.copyWith(
            routeType: Uac2RouteType.unknown,
            isExternalRoute: false,
          ),
          directUsbPlaybackActive: true,
        ),
        isNull,
      );
    });

    test('equivalent route snapshots do not notify the session again', () {
      const before = AndroidPlaybackDeviceInfo(
        hasUsbDac: true,
        hasAttachedUac2Device: true,
        manufacturer: 'Nothing',
        model: 'A059P',
        routeType: 'usb',
        routeLabel: 'Audiocular D07',
      );
      const unchanged = AndroidPlaybackDeviceInfo(
        hasUsbDac: true,
        hasAttachedUac2Device: true,
        manufacturer: 'Nothing',
        model: 'A059P',
        routeType: 'usb',
        routeLabel: 'Audiocular D07',
      );
      const detached = AndroidPlaybackDeviceInfo(
        hasUsbDac: false,
        hasAttachedUac2Device: false,
        manufacturer: 'Nothing',
        model: 'A059P',
        routeType: 'internal',
      );
      expect(sameAndroidPlaybackDeviceSnapshot(before, unchanged), isTrue);
      expect(sameAndroidPlaybackDeviceSnapshot(before, detached), isFalse);
    });
  });
}
