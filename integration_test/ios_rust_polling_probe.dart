import 'package:flick/services/player_service.dart';
import 'package:flick/services/rust_audio_service.dart';
import 'package:flick/src/rust/api/audio_api.dart' as native;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Real engine and lifecycle budget hooks in a foreground simulator app.
/// This does not claim actual suspension or a physical-device battery profile.
Future<void> probeIosRustPolling(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  PlayerService player, {
  required Future<int> Function() expectProgress,
}) async {
  final service = RustAudioService();
  await player.pause();
  expect(native.audioGetState(), 'paused');
  try {
    await player.onAppPaused();
    final before = service.debugPollingCounts;
    final window = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final paused = service.debugPollingCounts;
    window.stop();
    expect(paused.progress - before.progress, 0);
    expect(
      paused.events - before.events,
      inInclusiveRange(1, window.elapsedMilliseconds ~/ 1000 + 2),
    );
    expect(native.audioGetState(), 'paused');

    Future<void> seekAndObserve(Duration target) async {
      await player.seek(target);
      for (var i = 0; i < 40; i++) {
        final delta = (service.positionNotifier.value - target).abs();
        final labelDelta = (service.positionLabelNotifier.value - target).abs();
        if (delta < const Duration(milliseconds: 350) &&
            labelDelta < const Duration(milliseconds: 350)) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        (service.positionNotifier.value - target).abs(),
        lessThan(const Duration(milliseconds: 350)),
      );
      expect(
        (service.positionLabelNotifier.value - target).abs(),
        lessThan(const Duration(milliseconds: 350)),
      );
      expect(native.audioGetState(), 'paused');
      expect(player.isPlayingNotifier.value, isFalse);
    }

    await seekAndObserve(const Duration(seconds: 2));
    await seekAndObserve(const Duration(milliseconds: 500));
    final settled = service.debugPollingCounts;
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.debugPollingCounts.progress, settled.progress);
    await player.onAppResumed();
    expect(native.audioGetState(), 'paused');
    expect(player.isPlayingNotifier.value, isFalse);
    await player.resume();
    final resumedProgress = await expectProgress();
    binding.reportData!['rust_polling_pause_seek_budget'] = {
      'scope': 'Real Rust engine with observation-budget hooks; not actual app suspension or measured battery savings',
      'background_paused_periodic_progress_callbacks':
          paused.progress - before.progress,
      'background_paused_event_batches': paused.events - before.events,
      'observation_window_ms': window.elapsedMilliseconds,
      'forward_and_backward_paused_seek_observed': true,
      'foreground_did_not_resume_audio': true,
      'explicit_resume_progress_ms': resumedProgress,
    };
  } finally {
    await player.onAppResumed();
  }
}
