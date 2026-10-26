import 'package:flick/features/music_videos/media3_music_video_surface.dart';
import 'package:flick/features/player/widgets/immersive_lyrics_stage.dart';
import 'package:flick/features/player/widgets/lyric_motion_line.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _lyrics = LyricsData(
  isSynchronized: true,
  rawContent: '',
  lines: [
    LyricsLine(
      timestamp: Duration.zero,
      text: 'Hold this syllable',
      words: [
        LyricsWord(
          text: 'Hold',
          start: Duration.zero,
          end: Duration(milliseconds: 1800),
        ),
        LyricsWord(
          text: 'this',
          start: Duration(milliseconds: 1800),
          end: Duration(milliseconds: 1900),
        ),
        LyricsWord(
          text: 'syllable',
          start: Duration(milliseconds: 1900),
          end: Duration(seconds: 2),
        ),
      ],
    ),
    LyricsLine(
      timestamp: Duration(seconds: 2),
      text: 'Next subtitle',
    ),
  ],
);

class _ArtworkMarker extends StatefulWidget {
  const _ArtworkMarker({required this.onMount});
  final VoidCallback onMount;

  @override
  State<_ArtworkMarker> createState() => _ArtworkMarkerState();
}

class _ArtworkMarkerState extends State<_ArtworkMarker> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.blue, child: SizedBox.expand());
}

void main() {
  testWidgets('Space changes syllables/lines without remounting album artwork',
      (tester) async {
    final audioClock = ValueNotifier<Duration>(Duration.zero);
    addTearDown(audioClock.dispose);
    var artworkMounts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(child: _ArtworkMarker(
                onMount: () => artworkMounts++,
              )),
              Positioned(
                left: 0,
                right: 0,
                bottom: 70,
                child: ImmersiveLyricsSubtitle(
                  lyrics: _lyrics,
                  position: audioClock,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('space-line:0')), findsOneWidget);
    expect(find.byType(LyricMotionLine), findsOneWidget);
    final sameLineState = tester.state(find.byType(LyricMotionLine));

    for (final ms in [100, 250, 500, 900, 1250, 1800]) {
      audioClock.value = Duration(milliseconds: ms);
      await tester.pump();
      expect(identical(tester.state(find.byType(LyricMotionLine)), sameLineState),
          isTrue, reason: 'Word highlighting must reuse the glyph layout');
    }
    expect(artworkMounts, 1);
    audioClock.value = const Duration(milliseconds: 2100);
    await tester.pump();
    expect(find.byKey(const ValueKey('space-line:2000')), findsOneWidget);
    expect(artworkMounts, 1);

    // Rewind into the first line, as with a user seeking backwards.
    audioClock.value = const Duration(milliseconds: 400);
    await tester.pump();
    expect(find.byKey(const ValueKey('space-line:0')), findsOneWidget);
    expect(artworkMounts, 1);
  });

  test('native video controller owns an independent clock for Space subtitles',
      () {
    final video = Media3MusicVideoController();
    addTearDown(video.dispose);
    video.update(
      positionMs: 1720,
      durationMs: 130000,
      playing: false,
      buffering: false,
    );
    expect(video.positionNotifier.value,
        const Duration(milliseconds: 1720));
    expect(video.durationNotifier.value,
        const Duration(seconds: 130));
    expect(video.playingNotifier.value, isFalse);

    video.fallback();
    expect(video.nativeNotifier.value, isFalse);
    video.reset();
    expect(video.positionNotifier.value, Duration.zero);
    expect(video.nativeNotifier.value, isTrue);
  });
}
