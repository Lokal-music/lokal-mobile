import 'package:flick/features/player/widgets/motion_art_widget.dart';
import 'package:flick/features/spotify/spotify_storage.dart';
import 'package:flick/services/motion_art/animated_artwork_service.dart';
import 'package:flick/services/motion_art/moving_cover_settings.dart';
import 'package:flick/services/motion_art/shared_motion_playback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
// The platform interface is supplied by the production video_player dependency.
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}
  @override
  Widget buildView(int playerId) =>
      const ColoredBox(key: ValueKey('decoded-frame'), color: Colors.red);
}

class _WarmController extends VideoPlayerController {
  _WarmController()
    : super.networkUrl(Uri.parse('https://video.test/clip.mp4'));
  @override
  int get playerId => 7;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('ticker-disabled pull preview shows the warm Canvas immediately', (
    tester,
  ) async {
    final previousPlatform = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = _VideoPlatform();
    addTearDown(() => VideoPlayerPlatform.instance = previousPlatform);
    final controller = _WarmController();
    controller.value = const VideoPlayerValue(
      duration: Duration(seconds: 8),
      size: Size(200, 200),
      isInitialized: true,
      position: Duration(seconds: 3),
    );
    var created = 0;
    final pool = SharedMotionPlayback<VideoPlayerController>(
      create: (_) async {
        created++;
        return controller;
      },
      activate: (_, active) async {},
      dispose: (resource) async => resource.dispose(),
    );
    final key =
        'player:42|${movingCoverRevision.value}|${SecureSpotifyTokenStore.sessionRevision.value}|${AnimatedArtworkService.instance.revision.value}';
    final mini = await pool.acquire(key, 'https://video.test/clip.mp4');
    await mini.setActive(true);
    final suppression = ValueNotifier(false);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 200,
          child: TickerMode(
            enabled: false,
            child: MotionArtView(
              title: 'Song',
              artist: 'Artist',
              sharedPlaybackKey: 'player:42',
              sharedPlaybackOverride: pool,
              suppressionOverride: suppression,
              fallback: const Text('static cover'),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('decoded-frame')), findsOneWidget);
    expect(created, 1);
    expect(controller.value.position, const Duration(seconds: 3));
    expect(tester.takeException(), isNull);

    // A backgrounded app releases its motion-art view lease instead of
    // retaining an invisible Android video surface. On resume, a still-live
    // mini-player lease can supply its already decoded frame.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.byType(VideoPlayer), findsNothing);
    expect(find.text('static cover'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byKey(const ValueKey('decoded-frame')), findsOneWidget);
    expect(created, 1);

    // Memory pressure prioritizes the audio player and releases optional
    // video immediately; a new decoder must not be started on this frame.
    tester.binding.handleMemoryPressure();
    await tester.pump();
    expect(find.byType(VideoPlayer), findsNothing);
    expect(find.text('static cover'), findsOneWidget);
    suppression.value = true;
    await tester.pump();
    expect(find.byType(VideoPlayer), findsNothing);
    expect(find.text('static cover'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await mini.release(immediate: true);
    suppression.dispose();
  });
}
