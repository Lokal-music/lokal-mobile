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

  testWidgets('Space reuses the full Lyrics-mode syllable painter without shading',
      (tester) async {
    final clock = ValueNotifier<Duration>(const Duration(milliseconds: 200));
    addTearDown(clock.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(width: 340, child: ImmersiveLyricsSubtitle(
          lyrics: _lyrics, position: clock,
        )),
      ),
    ));
    final lyric = tester.widget<LyricMotionLine>(find.byType(LyricMotionLine));
    expect(lyric.lightweight, isFalse,
        reason: 'Space must use the exact full painter from regular Lyrics mode');
    expect(lyric.line.words, isNotEmpty);
    expect(lyric.style.shadows, isNull);
    expect(lyric.style.fontSize, 31);
    final translation = find.text('Next subtitle');
    expect(translation, findsNothing);
    var darkSubtitlePill = false;
    tester.element(find.byType(LyricMotionLine)).visitAncestorElements((e) {
      if (e.widget is DecoratedBox) {
        final decoration = (e.widget as DecoratedBox).decoration;
        if (decoration is BoxDecoration &&
            decoration.color == const Color(0x44000000)) {
          darkSubtitlePill = true;
        }
      }
      return true;
    });
    expect(darkSubtitlePill, isFalse,
        reason: 'The previous dark subtitle-pill decoration must be absent');
  });

  testWidgets('Space advances syllables between coarse playback position samples',
      (tester) async {
    final clock = ValueNotifier<Duration>(const Duration(milliseconds: 100));
    final playing = ValueNotifier<bool>(true);
    addTearDown(clock.dispose);
    addTearDown(playing.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Center(child: SizedBox(width: 320,
        child: ImmersiveLyricsSubtitle(
          lyrics: _lyrics,
          position: clock,
          playing: playing,
        ),
      )),
    ));
    final initial = tester.widget<LyricMotionLine>(
      find.byType(LyricMotionLine)).position;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final frame1 = tester.widget<LyricMotionLine>(
      find.byType(LyricMotionLine)).position;
    await tester.pump(const Duration(milliseconds: 32));
    final frame2 = tester.widget<LyricMotionLine>(
      find.byType(LyricMotionLine)).position;
    expect(frame1, greaterThan(initial));
    expect(frame2, greaterThan(frame1),
        reason: 'No 400 ms syllable stepping while the song position is unchanged');
    // A slightly stale source sample must never jump backwards.
    clock.value = const Duration(milliseconds: 130);
    await tester.pump(const Duration(milliseconds: 16));
    final afterSample = tester.widget<LyricMotionLine>(
      find.byType(LyricMotionLine)).position;
    expect(afterSample, greaterThanOrEqualTo(frame2));
    // An actual seek corrects immediately.
    clock.value = const Duration(milliseconds: 1700);
    await tester.pump();
    expect(tester.widget<LyricMotionLine>(find.byType(LyricMotionLine))
        .position, const Duration(milliseconds: 1700));
    playing.value = false;
    await tester.pump();
    final paused = tester.widget<LyricMotionLine>(
      find.byType(LyricMotionLine)).position;
    await tester.pump(const Duration(milliseconds: 48));
    expect(tester.widget<LyricMotionLine>(
      find.byType(LyricMotionLine)).position, paused);
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
