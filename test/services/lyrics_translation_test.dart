import 'package:flick/features/player/lokal_lyrics_subline.dart';
import 'package:flick/features/player/widgets/lyrics_editor_model.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/online_lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Lrclib implements OnlineLyricsService {
  _Lrclib(this.result);

  final OnlineLyricsResult? result;
  final asked = <String>[];

  @override
  Future<OnlineLyricsResult?> fetchExact({
    required String artist,
    required String title,
    String? album,
    Duration? duration,
  }) async {
    asked.add('$artist - $title');
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final service = LyricsService();
  List<String?> translations(String raw) => [
    for (final line in service.parseLyricsText(raw).lines) line.translation,
  ];

  group('LRC translation lines (desktop v9.2)', () {
    test('an unstamped line under a stamped one is its translation', () {
      const raw =
          '﻿[ti:Kiss]\r\n'
          '[00:21.65] Saigo no Kisu wa\r\n'
          '    The last kiss\r\n'
          '[00:25.00]Tabako no flavor ga shita\r\n'
          'Tasted of tobacco\r\n';
      final lyrics = service.parseLyricsText(raw);
      expect(lyrics.isSynchronized, isTrue);
      expect(lyrics.lines.map((l) => l.text), [
        'Saigo no Kisu wa',
        'Tabako no flavor ga shita',
      ]);
      expect(translations(raw), ['The last kiss', 'Tasted of tobacco']);
    });

    test('paired timestamps import as translations, not extra sung rows', () {
      const raw = '[00:19.51]Original first\n'
          '[00:19.51]Translation first\n'
          '[00:21.99]Original second\n'
          '[00:24.73]Original third\n'
          '[00:24.73]Translation third';
      final lyrics = service.parseLyricsText(raw);
      expect(lyrics.lines.map((line) => line.text), [
        'Original first', 'Original second', 'Original third',
      ]);
      expect(lyrics.lines.map((line) => line.translation), [
        'Translation first', null, 'Translation third',
      ]);
      expect(lyrics.lines.map((line) => line.timestamp.inMilliseconds),
        [19510, 21990, 24730]);
    });

    test('same-time word-timed vocals and multi-vocal groups remain distinct', () {
      final lyrics = service.parseLyricsText(
        '[00:01.00]<00:01.00>Main\n'
        '[00:01.00]<00:01.00>Backing\n'
        '[00:02.00]Voice one\n'
        '[00:02.00]Voice two\n'
        '[00:02.00]Voice three',
      );
      expect(lyrics.lines.map((line) => line.text), [
        'Main', 'Backing', 'Voice one', 'Voice two', 'Voice three',
      ]);
      expect(lyrics.lines.every((line) => line.translation == null), isTrue);
    });

    test('identical simultaneous lyric text is not mistaken for translation', () {
      final lyrics = service.parseLyricsText(
        '[00:01.00]Repeat\n[00:01.00]Repeat',
      );
      expect(lyrics.lines, hasLength(2));
      expect(lyrics.lines.every((line) => line.translation == null), isTrue);
    });

    test('old Mac line endings work too', () {
      expect(translations('[00:01.00]Uno\rOne\r[00:02.00]Dos\rTwo'), [
        'One',
        'Two',
      ]);
    });

    test('a line stamped twice gets its translation at both times', () {
      final lyrics = service.parseLyricsText(
        '[00:01.00][00:09.00]Chorus\nRefrain\n[00:05.00]Verse\nCouplet',
      );
      expect(lyrics.lines.map((l) => (l.text, l.translation)), [
        ('Chorus', 'Refrain'),
        ('Verse', 'Couplet'),
        ('Chorus', 'Refrain'),
      ]);
    });

    test('a stray note in an ordinary LRC is dropped, not a translation', () {
      const raw =
          '[00:01.00]One\n[00:02.00]Two\nLyrics by someone\n'
          '[00:03.00]Three\n[00:04.00]Four\n[00:05.00]Five';
      final lyrics = service.parseLyricsText(raw);
      expect(lyrics.lines.map((l) => l.text), [
        'One',
        'Two',
        'Three',
        'Four',
        'Five',
      ]);
      expect(lyrics.lines.every((l) => l.translation == null), isTrue);
    });

    test(
      'a blank line or an empty stamp breaks the link to the line above',
      () {
        expect(
          translations(
            '[00:01.00]One\nUn\n[00:02.00]Two\nDeux\n[00:03.00]Three\n\n'
            'not this\n[00:04.00]\nnor this',
          ),
          ['Un', 'Deux', null],
        );
      },
    );

    test('plain lyrics stay plain', () {
      final lyrics = service.parseLyricsText('First line\nSecond line');
      expect(lyrics.isSynchronized, isFalse);
      expect(lyrics.lines.map((l) => l.text), ['First line', 'Second line']);
    });

    test('saving keeps translations, through the editor too', () {
      final lyrics = service.parseLyricsText(
        '[00:01.00]Uno\nOne\n[00:02.00]Dos\nTwo',
      );
      final saved = LyricsEditorModel.fromLyrics(lyrics).normalizeForSave();
      final lrc = service.buildLrcContent(lines: saved);
      expect(lrc, '[00:01.00]Uno\n[00:01.00]One\n'
          '[00:02.00]Dos\n[00:02.00]Two');
      expect(translations(lrc), ['One', 'Two']);
    });
  });

  group('fetch lyrics automatically', () {
    const song = Song(
      id: '1',
      title: 'Teardrop',
      artist: 'Massive Attack',
      duration: Duration(minutes: 5),
      fileType: 'FLAC',
    );

    test('off: only the lyrics the song carries', () async {
      final lrclib = _Lrclib(null);
      final service = LyricsService(online: lrclib);
      expect(await service.loadLyricsForSong(song), isNull);
      expect(lrclib.asked, isEmpty);
    });

    test('on: a song without lyrics is looked up, timed preferred', () async {
      final lrclib = _Lrclib(
        OnlineLyricsResult.fromJson({
          'id': 7,
          'trackName': 'Teardrop',
          'artistName': 'Massive Attack',
          'instrumental': false,
          'plainLyrics': 'Love, love is a verb',
          'syncedLyrics': '[00:57.00]Love, love is a verb',
        }),
      );
      final service = LyricsService(online: lrclib);
      final lyrics = await service.loadLyricsForSong(song, fetchOnline: true);
      expect(lrclib.asked, ['Massive Attack - Teardrop']);
      expect(lyrics!.isSynchronized, isTrue);
      expect(lyrics.source, 'LRCLIB');
      expect(lyrics.lines.single.timestamp, const Duration(seconds: 57));
    });

    test('an instrumental answer is no lyrics', () async {
      final service = LyricsService(
        online: _Lrclib(
          OnlineLyricsResult.fromJson({'id': 1, 'instrumental': true}),
        ),
      );
      expect(await service.loadLyricsForSong(song, fetchOnline: true), isNull);
    });
  });

  group('translation toggle', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      LokalLyricsSubline.reset();
    });

    test('is remembered', () async {
      await LokalLyricsSubline.load();
      expect(LokalLyricsSubline.showTranslation.value, isFalse);
      await LokalLyricsSubline.toggle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LokalLyricsSubline.prefsKey), 'translation');

      LokalLyricsSubline.reset();
      await LokalLyricsSubline.load();
      expect(LokalLyricsSubline.showTranslation.value, isTrue);
    });

    test('only offered when the lyrics have a translation', () {
      expect(
        LokalLyricsSubline.hasTranslation(
          service.parseLyricsText('[00:01.00]Uno\nOne'),
        ),
        isTrue,
      );
      expect(
        LokalLyricsSubline.hasTranslation(
          service.parseLyricsText('[00:01.00]Uno'),
        ),
        isFalse,
      );
      expect(LokalLyricsSubline.hasTranslation(null), isFalse);
    });
  });
}
