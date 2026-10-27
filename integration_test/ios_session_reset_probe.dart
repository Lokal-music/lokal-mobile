import 'package:flick/services/ios_local_audio_requests.dart';
import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/services/player_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Exercise the retained audio_session subscription after earlier reset tests.
/// These are real notification/plugin paths, not actual calls or daemon loss.
Future<void> probeIosSessionAfterReset(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  PlayerService player, {
  required Future<int> Function() expectProgress,
}) async {
  const ios = MethodChannel('lokal/ios');
  final lifecycle = IosLocalAudioRequests.lifecycle;
  Future<void> until(bool Function() ready, String reason) async {
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        lifecycle.phase.value,
        isNot(LocalAudioPhase.blocked),
        reason: '${lifecycle.cleanupError}',
      );
      if (ready()) return;
    }
    fail(reason);
  }

  await ios.invokeMethod<void>('postAudioInterruptionForIntegrationTest', {
    'begin': true,
  });
  await until(
    () => !player.isPlayingNotifier.value,
    'The persistent session observer could not pause after a prior reset',
  );
  await ios.invokeMethod<void>('postMediaServicesLostForIntegrationTest');
  await until(
    () => lifecycle.phase.value == LocalAudioPhase.lost,
    'Lost was not observed',
  );
  await player.resume(); // Unavailable output must not activate or resume.
  expect(player.isPlayingNotifier.value, isFalse);
  await ios.invokeMethod<void>('postMediaServicesResetForIntegrationTest');
  await until(
    () => lifecycle.phase.value == LocalAudioPhase.paused,
    'Reset did not restore paused state',
  );
  await ios.invokeMethod<void>('postAudioInterruptionForIntegrationTest', {
    'begin': false,
  });
  await tester.pump(const Duration(milliseconds: 750));
  expect(
    player.isPlayingNotifier.value,
    isFalse,
    reason: 'An old interruption-end must not resume after Lost/Reset',
  );

  await player.seek(const Duration(seconds: 1));
  await player.resume();
  await expectProgress();
  await ios.invokeMethod<void>('postAudioInterruptionForIntegrationTest', {
    'begin': true,
  });
  await until(
    () => !player.isPlayingNotifier.value,
    'A fresh interruption did not pause the recovered player',
  );
  await ios.invokeMethod<void>('postAudioInterruptionForIntegrationTest', {
    'begin': false,
  });
  final resumedProgress = await expectProgress();
  binding.reportData!['media_reset_persistent_session_observer'] = {
    'scope': 'Posted AVAudioSession Lost/Reset/interruption notifications through the actual plugin',
    'old_interruption_end_did_not_resume': true,
    'new_interruption_still_pauses_and_resumes': true,
    'resumed_progress_ms': resumedProgress,
  };
}
