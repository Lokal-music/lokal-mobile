import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/bini_lyrics_matcher.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/lyrics_playback_prefetch.dart';
import 'package:flick/services/lyrics_translation_service.dart';

import '../../integration_test/fixtures/ios_concurrent_lyrics.dart';

import 'package:flick/features/player/widgets/lyrics_file_export.dart';

void main() {
  test(
    'enhanced translated native fixture reimports with both singers intact',
    () {
      final original = LyricsService().parseLyricsText(iosConcurrentLyrics);
      final translated = LyricsData(
        isSynchronized: true,
        rawContent: original.rawContent,
        lines: [
          for (var i = 0; i < original.lines.length; i++)
            original.lines[i].withTranslation('Translation $i'),
        ],
      );
      final song = Song(
        id: 'native-fixture',
        title: 'Generated tone',
        artist: 'Fixture',
        duration: const Duration(seconds: 10),
        fileType: 'wav',
      );
      final exported = prepareLyricsFileExport(
        song,
        translated,
        includeDisplayedSubline: true,
      );
      final restored = LyricsService().parseLyricsText(exported.content);
      expect(exported.extension, 'elrc');
      expect(restored.lines, hasLength(4));
      expect(
        restored.lines.map((line) => line.text),
        original.lines.map((line) => line.text),
      );
      expect(restored.lines.map((line) => line.translation), [
        for (var i = 0; i < 4; i++) 'Translation $i',
      ]);
      expect(restored.lines[1].timestamp, const Duration(seconds: 3));
      expect(restored.lines[2].timestamp, const Duration(seconds: 3));
      final libraryCopy = LyricsService().parseLyricsText(
        LyricsService().buildLrcContent(lines: translated.lines),
      );
      expect(
        libraryCopy.lines.map((line) => line.text),
        original.lines.map((line) => line.text),
      );
      expect(libraryCopy.lines.map((line) => line.translation), [
        for (var i = 0; i < 4; i++) 'Translation $i',
      ]);
    },
  );
  test(
    'actual native fixture retains both singers through bilingual parsing',
    () {
      final lyrics = LyricsService().parseLyricsText(iosConcurrentLyrics);
      expect(lyrics.lines, hasLength(4));
      expect(lyrics.lines[1].timestamp, const Duration(seconds: 3));
      expect(lyrics.lines[2].timestamp, const Duration(seconds: 3));
      expect(lyrics.lines[1].text, 'Second generated lyric');
      expect(lyrics.lines[2].text, 'Concurrent generated voice');
      expect(lyrics.lines[1].words, isNotEmpty);
      expect(lyrics.lines[2].words, isNotEmpty);
      expect(lyrics.lines.every((line) => line.translation == null), isTrue);
    },
  );

  test(
    'local synchronized lyrics remain visible while an online upgrade loads',
    () {
      const local = LyricsData(
        lines: [LyricsLine(timestamp: Duration.zero, text: 'Local lyrics')],
        isSynchronized: true,
        rawContent: '[00:00.00]Local lyrics',
        source: 'song.lrc',
      );
      const plain = LyricsData(
        lines: [
          LyricsLine(timestamp: Duration.zero, text: 'Unverified web text'),
        ],
        isSynchronized: false,
        rawContent: 'Unverified web text',
      );
      expect(lyricQualityRank(local), 2);
      expect(lyricQualityRank(plain), 1);
      expect(lyricQualityRank(null), 0);
      expect(lyricQualityRank(plain) > lyricQualityRank(local), isFalse);
    },
  );

  test(
    'localized Bini names can match the recording by duration and timing',
    () {
      final song = Song(
        id: 'eki',
        title: '駅',
        artist: 'Mariya Takeuchi',
        duration: const Duration(seconds: 290),
        fileType: 'FLAC',
      );
      final match = pickBiniLyrics([
        {
          'track_name': '駅',
          'artist_name': 'Cover Artist',
          'duration': 321,
          'timing_type': 'line',
        },
        {
          'track_name': 'Eki',
          'artist_name': '竹内まりや',
          'duration': 290,
          'timing_type': 'word',
        },
      ], song);
      expect(match?['artist_name'], '竹内まりや');
      expect(
        pickBiniLyrics([
          {
            'track_name': 'Other',
            'artist_name': 'Other',
            'duration': 450,
            'timing_type': 'line',
          },
        ], song),
        isNull,
      );
    },
  );
  test('bare TTML seconds retain Japanese syllable times and language', () {
    final lyrics = LyricsService().parseLyricsText(
      '<tt xml:lang="ja"><body><div><p begin="10.25" end="13"><span begin="10.25" end="11">見覚え</span><span begin="11" end="13">のある</span></p></div></body></tt>',
    );
    expect(lyrics.language, 'ja');
    expect(lyrics.lines.single.timestamp, const Duration(milliseconds: 10250));
    expect(lyrics.lines.single.words!.map((w) => w.start), [
      const Duration(milliseconds: 10250),
      const Duration(seconds: 11),
    ]);
    expect(lyrics.lines.single.text, '見覚えのある');
  });
  test('untimed TTML is plain text rather than raw XML', () {
    final lyrics = LyricsService().parseLyricsText(
      '<tt><body><div><p>Plain words</p></div></body></tt>',
    );
    expect(lyrics.isSynchronized, isFalse);
    expect(lyrics.lines.single.text, 'Plain words');
  });
  test(
    'paired desktop lyrics retain word windows and do not turn gaps into lines',
    () {
      final lyrics = LyricsService.fromDesktop({
        'type': 'syllable',
        'sync': 'syllable',
        'language': 'ja',
        'source': 'binilyrics',
        'lines': [
          {'time': 0, 'end': 10, 'gap': true, 'text': ''},
          {
            'time': 10.25,
            'text': '見覚えのある',
            'words': [
              {'time': 10.25, 'end': 11, 'word': '見覚え'},
              {'time': 11, 'end': 13, 'word': 'のある'},
            ],
          },
        ],
      })!;
      expect(lyrics.isSynchronized, isTrue);
      expect(lyrics.lines, hasLength(1));
      expect(lyrics.lines.single.words!.first.start.inMilliseconds, 10250);
      expect(lyrics.lines.single.words!.last.end.inSeconds, 13);
      expect(lyrics.language, 'ja');
    },
  );
  test(
    'same system language is rejected before a translation request',
    () async {
      const lyrics = LyricsData(
        lines: [LyricsLine(timestamp: Duration.zero, text: 'Hello')],
        isSynchronized: true,
        rawContent: '',
        language: 'en',
      );
      await expectLater(
        LyricsTranslationService.convert(
          lyrics,
          romanize: false,
          target: 'en-US',
          current: () => true,
        ),
        throwsA(isA<SameLyricsLanguage>()),
      );
      expect(LyricsTranslationService.sameLanguage('ja', 'en'), isFalse);
    },
  );
}
