import 'package:flick/features/music_videos/music_video_controller.dart';
import 'package:flick/features/music_videos/music_video_surface.dart';
import 'package:flick/features/player/widgets/video_space_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Opt-in network evidence, separate from the deterministic playback corpus.
/// The real WKWebView, production HTML/API bridge and native media suspension
/// are used. A remote restriction is recorded as inconclusive, never a pass.
Future<void> probeLiveIosVideo(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final video = Media3MusicVideoController();
  final space = ValueNotifier(false);
  final playerKey = GlobalKey();
  final evidence = <String, Object?>{'outcome': 'inconclusive'};
  binding.reportData!['live_youtube_webkit_probe'] = evidence;

  Future<bool> until(bool Function() ready, int attempts) async {
    for (var i = 0; i < attempts; i++) {
      if (ready()) return true;
      await tester.pump(const Duration(milliseconds: 250));
    }
    return ready();
  }

  Widget surface() => MusicVideoSurface(
    key: playerKey,
    videoId: 'jNQXAC9IVRw', // Public, short "Me at the zoo" fixture.
    controller: video,
  );

  try {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: space,
            builder: (_, active, __) => active
                ? VideoSpaceLayout(
                    player: surface(),
                    subtitles: const Text('Live WebKit playback probe'),
                    onExit: () => space.value = false,
                    onOptions: () {},
                  )
                : Center(
                    child: SizedBox(width: 320, height: 320, child: surface()),
                  ),
          ),
        ),
      ),
    );
    final ready = await until(
      () =>
          video.timingAvailableNotifier.value ||
          video.embedErrorNotifier.value != null,
      180,
    );
    evidence['api_ready'] = video.timingAvailableNotifier.value;
    evidence['provider_error'] = video.embedErrorNotifier.value;
    if (!ready || !video.timingAvailableNotifier.value) {
      evidence['reason'] = 'Official player readiness was not observed; inspect the provider error and screenshot.';
      await binding.takeScreenshot('ios-live-video-unavailable');
      return;
    }
    await video.command('play');
    final initial = video.positionNotifier.value;
    final advancing = await until(
      () =>
          video.positionNotifier.value - initial >
          const Duration(milliseconds: 300),
      40,
    );
    evidence['observed_position_advance_ms'] =
        (video.positionNotifier.value - initial).inMilliseconds;
    if (!advancing) {
      evidence['reason'] =
          'API ready, but playback advancement was not observed.';
      await binding.takeScreenshot('ios-live-video-not-advancing');
      return;
    }
    await video.command('pause');
    expect(
      await until(() => !video.playingNotifier.value, 20),
      isTrue,
      reason: 'Real WebKit pause did not reach the production video clock',
    );
    await video.seek(const Duration(seconds: 2));
    expect(
      await until(
        () => (video.positionNotifier.value.inMilliseconds - 2000).abs() < 1000,
        20,
      ),
      isTrue,
      reason: 'The official iframe did not acknowledge seek',
    );
    final original = playerKey.currentState;
    space.value = true;
    await tester.pump();
    expect(playerKey.currentState, same(original));
    await binding.takeScreenshot('ios-live-video-space');
    await tester.tap(find.byKey(const ValueKey('embedded-space-exit')));
    await tester.pump();
    expect(playerKey.currentState, same(original));
    evidence['pause_seek_and_space_identity'] = 'passed';
    evidence['outcome'] = 'passed';
  } finally {
    // This acknowledgement is checked even when the public player is blocked.
    // It proves the real native WebKit method, not successful video playback.
    try {
      await video.releaseAudio().timeout(const Duration(seconds: 5));
      evidence['native_webkit_release_acknowledged'] = true;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      video.dispose();
      space.dispose();
    }
  }
}
