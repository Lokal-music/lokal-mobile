import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/player/widgets/lyric_motion_line.dart';
import 'package:flick/features/player/widgets/lyrics_subline_timing.dart';
import 'package:flick/services/lyrics_service.dart';

const original = LyricsLine(
  timestamp: Duration(seconds: 1),
  text: 'お は よ',
  words: [
    LyricsWord(
      start: Duration(seconds: 1),
      end: Duration(milliseconds: 1500),
      text: 'お',
    ),
    LyricsWord(
      start: Duration(seconds: 2),
      end: Duration(milliseconds: 2300),
      text: 'は',
    ),
    LyricsWord(
      start: Duration(seconds: 3),
      end: Duration(seconds: 4),
      text: 'よ',
    ),
  ],
);

void main() {
  test('translated words inherit nonuniform original syllable timing', () {
    final translated = projectLyricsSubline(original, 'Good morning friend');
    expect(translated.text, 'Good morning friend');
    expect(translated.timestamp, original.timestamp);
    expect(translated.words!.map((w) => w.text).join(),
        'Goodmorningfriend');
    expect(translated.words!.length, greaterThan(3),
        reason: 'a translated word crossing source syllables is split');
    expect(translated.words!.first.start, const Duration(seconds: 1));
    expect(translated.words!.last.end, const Duration(seconds: 4));
    expect(
      translated.words![0].end - translated.words![0].start,
      isNot(translated.words![2].end - translated.words![2].start),
    );
    expect(original.words!.length, 3,
        reason: 'visual projection must not rewrite source timing');
    for (final segment in translated.words!) {
      expect(
        original.words!.any((original) =>
            segment.start >= original.start && segment.end <= original.end),
        isTrue,
        reason: 'projected fragments cannot run through silent gaps',
      );
    }
    expect(original.translation, isNull);
  });

  test('romaji without spaces still progresses character by character', () {
    final romaji = projectLyricsSubline(original, 'ohayo');
    expect(romaji.words!.map((w) => w.text), ['o', 'h', 'a', 'y', 'o']);
    expect(romaji.words!.first.start, const Duration(seconds: 1));
    expect(romaji.words!.last.end, const Duration(seconds: 4));
    final middle = romaji.words![2];
    expect(middle.start, greaterThan(romaji.words!.first.start));
    expect(middle.end, lessThan(romaji.words!.last.end));
  });

  test('silent source gaps never advance a projected translation', () {
    final projected = projectLyricsSubline(original, 'abc');
    expect(projected.words!.map((word) => word.text), ['a', 'b', 'c']);
    expect(projected.words!.map((word) => [word.start, word.end]), [
      [const Duration(seconds: 1), const Duration(milliseconds: 1500)],
      [const Duration(seconds: 2), const Duration(milliseconds: 2300)],
      [const Duration(seconds: 3), const Duration(seconds: 4)],
    ]);
    expect(projected.words![0].end, lessThan(projected.words![1].start));
    expect(projected.words![1].end, lessThan(projected.words![2].start));
  });

  test('zero-duration enhanced-LRC words normalize before subline mapping', () {
    const unresolved = LyricsData(
      isSynchronized: true, rawContent: '', lines: [
        LyricsLine(
          timestamp: Duration(seconds: 1),
          text: 'a b',
          words: [
            LyricsWord(
              start: Duration(seconds: 1),
              end: Duration(seconds: 1),
              text: 'a',
            ),
            LyricsWord(
              start: Duration(seconds: 2),
              end: Duration(seconds: 2),
              text: 'b',
            ),
          ],
        ),
        LyricsLine(timestamp: Duration(seconds: 4), text: 'next'),
      ],
    );
    final normalized = LyricsService().playbackLines(unresolved).first;
    expect(normalized.words!.first.end,
        greaterThan(normalized.words!.first.start));
    final projected = projectLyricsSubline(normalized, 'hello');
    expect(projected.words!.first.end,
        greaterThan(projected.words!.first.start));
  });

  test('unavailable syllable timings never produce fabricated timestamps', () {
    const line = LyricsLine(
      timestamp: Duration(seconds: 12),
      text: 'Untimed lyrics',
    );
    final subline = projectLyricsSubline(line, 'Translated lyric');
    expect(subline.words, isNull);
    expect(subline.timestamp, line.timestamp);
    expect(projectLyricsSubline(line, '').words, isNull);
  });

  testWidgets('timed translated text uses the original LyricMotionLine painter',
      (tester) async {
    final translation = projectLyricsSubline(original, 'Good morning friend');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: LyricMotionLine(
              line: translation,
              position: const Duration(milliseconds: 2500),
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    ));
    expect(find.byType(LyricMotionLine), findsOneWidget);
    expect(find.text('Good morning friend'), findsNothing,
        reason: 'the timed subline is painted using glyph geometry');
    expect(tester.takeException(), isNull);
  });
}
