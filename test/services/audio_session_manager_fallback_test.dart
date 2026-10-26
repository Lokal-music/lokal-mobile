import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/services/audio_session_manager.dart';

void main() {
  test('iPhone reports a system route before the first playback request', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final manager = AudioSessionManager(
      onSwitchEngine: ({
        required from,
        required to,
        required initializeNewEngine,
        required reason,
      }) async {},
      isPlaybackActive: () => false,
    );
    addTearDown(manager.dispose);
    expect(manager.selectedMode, AudioEngineType.iosSystem);
    expect(manager.initializedMode, isNull);
  });

  test(
    'Rust fallback remains identifiable while Standard is initialized',
    () async {
      final manager = AudioSessionManager(
        onSwitchEngine: ({
          required from,
          required to,
          required initializeNewEngine,
          required reason,
        }) async {},
        isPlaybackActive: () => true,
      );
      addTearDown(manager.dispose);

      await manager.switchMode(
        AudioEngineType.rustOboe,
        initializeNewEngine: true,
      );
      await manager.recordFallback(
        requestedMode: AudioEngineType.rustOboe,
        fallbackMode: AudioEngineType.normalAndroid,
        reason: 'Rust output lost during crossfade',
      );
      await manager.switchMode(
        AudioEngineType.normalAndroid,
        initializeNewEngine: true,
      );
      expect(manager.selectedMode, AudioEngineType.normalAndroid);
      expect(manager.initializedMode, AudioEngineType.normalAndroid);
      expect(manager.fallbackRequestedMode, AudioEngineType.rustOboe);
      expect(manager.fallbackReason, contains('Rust output lost'));

      await manager.switchMode(
        AudioEngineType.rustOboe,
        initializeNewEngine: true,
      );
      expect(manager.initializedMode, AudioEngineType.rustOboe);
      expect(manager.fallbackRequestedMode, isNull);
      expect(manager.fallbackReason, isNull);
    },
  );

  test(
    'failed Rust switch does not report disposed Standard engine as ready',
    () async {
      final manager = AudioSessionManager(
        onSwitchEngine:
            ({
              required from,
              required to,
              required initializeNewEngine,
              required reason,
            }) async {
              if (to == AudioEngineType.rustOboe) {
                throw StateError('Oboe could not open');
              }
            },
        isPlaybackActive: () => true,
      );
      addTearDown(manager.dispose);

      await manager.switchMode(
        AudioEngineType.normalAndroid,
        initializeNewEngine: true,
      );
      await expectLater(
        manager.switchMode(AudioEngineType.rustOboe, initializeNewEngine: true),
        throwsStateError,
      );
      expect(manager.initializedMode, isNull);
      await manager.switchMode(
        AudioEngineType.normalAndroid,
        initializeNewEngine: true,
      );
      expect(manager.initializedMode, AudioEngineType.normalAndroid);
    },
  );
}
