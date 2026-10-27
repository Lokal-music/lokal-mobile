import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/player/widgets/flowing_lyric_subline.dart';
import 'package:flick/features/player/widgets/lyric_motion_line.dart';
import 'package:flick/features/player/widgets/lyrics_subline_timing.dart';
import 'package:flick/services/lyrics_service.dart';

const sourceLine = LyricsLine(
  timestamp: Duration(seconds: 1),
  text: 'こ ん に ち は',
  translation: 'Good morning',
  words: [
    LyricsWord(
      text: 'こ', start: Duration(seconds: 1),
      end: Duration(milliseconds: 1300),
    ),
    LyricsWord(
      text: 'ん', start: Duration(milliseconds: 1400),
      end: Duration(milliseconds: 1600),
    ),
    LyricsWord(
      text: 'に', start: Duration(milliseconds: 1800),
      end: Duration(milliseconds: 2100),
    ),
    LyricsWord(
      text: 'ち', start: Duration(milliseconds: 2400),
      end: Duration(milliseconds: 2900),
    ),
    LyricsWord(
      text: 'は', start: Duration(milliseconds: 3000),
      end: Duration(milliseconds: 3500),
    ),
  ],
);

Widget preview({
  required String text,
  LyricsLine? timed,
  Duration position = const Duration(milliseconds: 1800),
  bool singing = true,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 350,
        child: FlowingLyricSubline(
          text: text,
          timedLine: timed,
          singing: singing,
          position: position,
          style: const TextStyle(
            fontSize: 18,
            color: Color.fromRGBO(255, 255, 255, .82),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('main player translated line uses the timed vocal painter',
      (tester) async {
    final timed = projectLyricsSubline(sourceLine, 'Good morning');
    expect(timed.words, isNotEmpty);
    await tester.pumpWidget(preview(text: 'Good morning', timed: timed));

    final painter = tester.widget<LyricMotionLine>(find.byType(LyricMotionLine));
    expect(painter.line.text, 'Good morning');
    expect(painter.line.words, isNotEmpty);
    expect(painter.position, const Duration(milliseconds: 1800));
    expect(painter.unsung.a, lessThan(painter.sung.a));
    expect(tester.takeException(), isNull);

    final priorState = tester.state(find.byType(LyricMotionLine));
    await tester.pumpWidget(preview(
      text: 'Good morning',
      timed: timed,
      position: const Duration(milliseconds: 2700),
    ));
    expect(tester.widget<LyricMotionLine>(
      find.byType(LyricMotionLine)).position,
      const Duration(milliseconds: 2700));
    expect(identical(tester.state(find.byType(LyricMotionLine)), priorState),
        isTrue, reason: 'Playback ticks must preserve shaped glyph layouts');
  });

  testWidgets('main player romanized line inherits original syllables',
      (tester) async {
    final romaji = projectLyricsSubline(sourceLine, 'kon ni chi wa');
    await tester.pumpWidget(preview(text: 'kon ni chi wa', timed: romaji));
    expect(find.byType(LyricMotionLine), findsOneWidget);
    expect(tester.widget<LyricMotionLine>(find.byType(LyricMotionLine))
        .line.words!.first.start, const Duration(seconds: 1));
  });

  testWidgets('inactive lines stay plain text instead of animating',
      (tester) async {
    final timed = projectLyricsSubline(sourceLine, 'Good morning');
    await tester.pumpWidget(preview(
      text: 'Good morning', timed: timed, singing: false,
    ));
    expect(find.byType(LyricMotionLine), findsNothing);
    expect(find.text('Good morning'), findsOneWidget);
  });

  testWidgets('line-timed or missing source units do not fake karaoke',
      (tester) async {
    final untimed = projectLyricsSubline(
      const LyricsLine(timestamp: Duration(seconds: 1), text: 'hello'),
      'Bonjour',
    );
    await tester.pumpWidget(preview(text: 'Bonjour', timed: untimed));
    expect(find.byType(LyricMotionLine), findsNothing);
    expect(find.text('Bonjour'), findsOneWidget);
  });

  testWidgets('stale projection from another line never animates',
      (tester) async {
    final timed = projectLyricsSubline(sourceLine, 'Good morning');
    await tester.pumpWidget(preview(text: 'Not this song', timed: timed));
    expect(find.byType(LyricMotionLine), findsNothing);
    expect(find.text('Not this song'), findsOneWidget);
  });
}
