import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/lyricsplus_normalizer.dart';
import 'package:flick/services/lyrics_service.dart';

void main() {
  final service = LyricsService();

  test('LyricsPlus v2 millisecond lines in reverse order play chronologically', () {
    final result = normalizeLyricsPlusV2({
      'lyrics': [
        {'time': 165000, 'text': 'Final verse'},
        {'time': 18000, 'text': 'Imagination'},
        {'time': 55000, 'text': 'A strange dimension'},
      ],
    }, duration: const Duration(minutes: 3));
    expect(result, isNotNull);
    final parsed = service.parseLyricsText(result!, source: 'LyricsPlus');
    expect(parsed.lines.map((line) => line.text).toList(), [
      'Imagination', 'A strange dimension', 'Final verse',
    ]);
    expect(parsed.lines.first.timestamp, const Duration(seconds: 18));
    expect(parsed.lines.last.timestamp, const Duration(seconds: 165));
    expect(parsed.isSynchronized, isTrue);
  });

  test('reject timeline where first lyric begins at end of track', () {
    final result = normalizeLyricsPlusV2({
      'lyrics': [
        {'time': 170000, 'text': 'Outro'},
        {'time': 174000, 'text': 'Outro two'},
      ],
    }, duration: const Duration(minutes: 3));
    expect(result, isNull);
  });

  test('reject grossly out-of-range or negative timestamps instead of flashing lyrics at wrong time', () {
    expect(normalizeLyricsPlusV2({
      'lyrics': [
        {'time': -200000, 'text': 'Wrong recording'},
        {'time': 360000, 'text': 'Wrong recording end'},
        {'time': 13000, 'text': 'Valid but mostly corrupted'},
      ],
    }, duration: const Duration(minutes: 3)), isNull);
  });

  test('preserve genuine syllabus timings, ignoring background vocals and sorting words', () {
    final result = normalizeLyricsPlusV2({
      'lyrics': [
        {
          'time': 10000,
          'text': 'Hello world',
          'syllabus': [
            {'time': 11000, 'text': 'world'},
            {'time': 10000, 'text': 'Hello '},
            {'time': 10500, 'text': 'ad lib', 'isBackground': true},
          ],
        },
      ],
    }, duration: const Duration(minutes: 2));
    expect(result, isNotNull);
    final parsed = service.parseLyricsText(result!, source: 'LyricsPlus');
    expect(parsed.lines.single.words, hasLength(2));
    expect(parsed.lines.single.words![0].text.trim(), 'Hello');
    expect(parsed.lines.single.words![1].text, 'world');
    expect(parsed.lines.single.words![0].start, const Duration(seconds: 10));
  });

  test('when no usable foreground syllabus exists, keep the line text', () {
    final result = normalizeLyricsPlusV2({
      'lyrics': [
        {
          'time': 10000,
          'text': 'Keep this line',
          'syllabus': [
            {'time': 10000, 'text': 'backing', 'isBackground': true},
          ],
        },
      ],
    }, duration: const Duration(minutes: 2));
    expect(service.parseLyricsText(result!).lines.single.text, 'Keep this line');
  });

  test('reject a non-lyric payload, but accept songs with no known duration', () {
    expect(normalizeLyricsPlusV2({'lyrics': []}, duration: Duration.zero), isNull);
    expect(normalizeLyricsPlusV2({
      'lyrics': [{'time': 125000, 'text': 'A verse'}],
    }, duration: Duration.zero), isNotNull);
  });
}
