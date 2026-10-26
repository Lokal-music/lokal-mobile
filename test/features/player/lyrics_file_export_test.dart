import 'dart:convert';

import 'package:flick/features/player/widgets/lyrics_file_export.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _song = Song(
  id: 'track-id',
  title: 'My Song / Part 2?',
  artist: 'A: Band',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
);

void main() {
  test('keeps original timed LRC bytes and sanitizes the filename', () {
    const raw = '[ar:Artist]\n[00:01.00]First line\n[00:02.20]Second line';
    const lyrics = LyricsData(
      lines: [
        LyricsLine(timestamp: Duration(seconds: 1), text: 'First line'),
        LyricsLine(timestamp: Duration(milliseconds: 2200), text: 'Second line'),
      ],
      isSynchronized: true,
      rawContent: raw,
    );
    final file = prepareLyricsFileExport(_song, lyrics);
    expect(file.extension, 'lrc');
    expect(file.fileName, 'A Band - My Song Part 2.lrc');
    expect(utf8.decode(file.bytes), raw);
  });

  test('preserves original TTML syllable timing without flattening', () {
    const raw = '<tt xml:lang="ja"><body><p begin="1s">'
        '<span begin="1s" end="2s">春</span></p></body></tt>';
    const lyrics = LyricsData(
      lines: [LyricsLine(timestamp: Duration(seconds: 1), text: '春')],
      isSynchronized: true,
      rawContent: raw,
    );
    final file = prepareLyricsFileExport(_song, lyrics);
    expect(file.extension, 'ttml');
    expect(file.mimeType, 'application/xml');
    expect(file.content, raw);
  });

  test('preserves original enhanced LRC word markers', () {
    const lyrics = LyricsData(
      lines: [LyricsLine(timestamp: Duration(seconds: 1), text: 'word')],
      isSynchronized: true,
      rawContent: '[00:01.00]<00:01.10>word',
    );
    final file = prepareLyricsFileExport(_song, lyrics);
    expect(file.extension, 'elrc');
    expect(file.content, lyrics.rawContent);
  });

  test('converts desktop JSON to timed enhanced LRC', () {
    const lyrics = LyricsData(
      lines: [
        LyricsLine(
          timestamp: Duration(milliseconds: 1050),
          text: 'Hello world',
          words: [
            LyricsWord(start: Duration(milliseconds: 1050),
                end: Duration(milliseconds: 1400), text: 'Hello '),
            LyricsWord(start: Duration(milliseconds: 1400),
                end: Duration(milliseconds: 2200), text: 'world'),
          ],
          translation: 'Bonjour monde',
        ),
      ],
      isSynchronized: true,
      rawContent: '{"type":"syllable","lines":[{"text":"Hello world"}]}',
    );
    final file = prepareLyricsFileExport(_song, lyrics);
    expect(file.extension, 'elrc');
    expect(file.content,
        '[00:01.05]<00:01.05>Hello <00:01.40>world\nBonjour monde\n');
  });

  test('saves plain text and supports cancellation', () async {
    const lyrics = LyricsData(
      lines: [
        LyricsLine(timestamp: Duration.zero, text: 'One'),
        LyricsLine(timestamp: Duration.zero, text: 'Two'),
      ],
      isSynchronized: false,
      rawContent: 'One\nTwo',
    );
    final file = prepareLyricsFileExport(_song, lyrics);
    expect(file.extension, 'txt');
    expect(file.content, 'One\nTwo');
    expect(await saveCurrentLyricsFile(
      song: _song, lyrics: lyrics, picker: (_) async => null,
    ), isFalse);
  });

  test('passes UTF-8 bytes to the Android document picker', () async {
    const lyrics = LyricsData(
      lines: [LyricsLine(timestamp: Duration.zero, text: '夜曲')],
      isSynchronized: false,
      rawContent: '夜曲',
    );
    expect(await saveCurrentLyricsFile(
      song: _song,
      lyrics: lyrics,
      picker: (file) async {
        expect(file.fileName, endsWith('.txt'));
        expect(utf8.decode(file.bytes), '夜曲');
        return Uri.parse('content://downloads/documents/42');
      },
    ), isTrue);
  });

  test('rejects empty lyrics before asking for a destination', () async {
    const empty = LyricsData(
        lines: [], isSynchronized: false, rawContent: '');
    var opened = false;
    await expectLater(() => saveCurrentLyricsFile(
      song: _song, lyrics: empty,
      picker: (_) async {
        opened = true;
        return null;
      },
    ), throwsArgumentError);
    expect(opened, isFalse);
  });
}
