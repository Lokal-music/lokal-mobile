import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/search/widgets/lyrics_search_result_card.dart';
import 'package:flick/features/search/widgets/lyrics_search_section.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/songs_provider.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/online_lyrics_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const song = Song(
  id: 'layout-test',
  title: 'Song title',
  artist: 'Singer',
  album: 'Album',
  filePath: '/music/layout.flac',
  duration: Duration.zero,
  fileType: 'FLAC',
);

class _Songs extends SongsNotifier {
  @override
  Future<SongsState> build() async => SongsState(songs: [song]);
}

class _Local extends Fake implements LyricsService {
  @override
  Future<LyricsData?> loadLyricsForSong(
    Song song, {
    bool forceRefresh = false,
    bool fetchOnline = false,
    bool refreshOnline = false,
    String source = 'auto',
    bool Function()? stillCurrent,
  }) async => const LyricsData(
    lines: [LyricsLine(timestamp: Duration.zero, text: 'The lyric phrase')],
    isSynchronized: false,
    rawContent: 'The lyric phrase',
  );
}

class _Online extends Fake implements OnlineLyricsService {
  @override
  Future<List<OnlineLyricsResult>> search({
    String? query,
    String? artist,
    String? title,
    String? album,
    bool refresh = false,
    bool reportErrors = false,
  }) async => const [
    OnlineLyricsResult(
      id: 1,
      trackName: 'Song title',
      artistName: 'Singer',
      albumName: 'Album',
      instrumental: false,
      syncedLyrics: '[ar:Singer]\n[00:02.00]The lyric phrase',
    ),
  ];
}

Widget app(ProviderContainer c, Widget child, {double scale = 1}) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: child,
          ),
        ),
      ),
    );

void main() {
  test(
    'lyric snippets strip timestamps and metadata, preferring the query line',
    () {
      expect(
        lyricsResultSnippet(
          '[ar:Singer]\n[00:02.00]First line\n[00:03.00]The lyric phrase',
          'lyric phrase',
        ),
        'The lyric phrase',
      );
      expect(
        lyricsResultSnippet('First line\nSecond line\nThird', 'Song title'),
        'First line · Second line',
      );
      expect(lyricsResultSnippet('[ar:Singer]\n[00:00.00]', 'anything'), '');
    },
  );
  for (final online in [false, true]) {
    testWidgets(
      '${online ? 'Online' : 'Library'} uses the shared library lyric card',
      (tester) async {
        final c = ProviderContainer(
          overrides: [
            songsProvider.overrideWith(_Songs.new),
            lyricsSearchLocalServiceProvider.overrideWithValue(_Local()),
            lyricsSearchOnlineServiceProvider.overrideWithValue(_Online()),
          ],
        );
        addTearDown(c.dispose);
        await c.read(songsProvider.future);
        Song? played;
        final section = LyricsSearchSection(
          query: 'lyric phrase',
          online: online,
          onPlayLocal: (selected, queue) async {
            played = selected;
            expect(queue, [song]);
          },
        );
        await tester.pumpWidget(
          app(c, online ? SingleChildScrollView(child: section) : section),
        );
        await tester.pumpAndSettle();
        expect(find.byType(LyricsSearchResultCard), findsOneWidget);
        expect(find.text('Song title'), findsOneWidget);
        expect(find.text('Singer · Album'), findsOneWidget);
        expect(find.text('The lyric phrase'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('The lyric phrase')).dy,
          greaterThan(tester.getBottomLeft(find.text('Singer · Album')).dy),
        );
        expect(find.byType(ListTile), findsNothing);
        if (!online) {
          await tester.tap(find.text('Song title'));
          await tester.pumpAndSettle();
          expect(played, song);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'shared lyric card fits narrow enlarged text and supports disabled play',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        app(
          c,
          const LyricsSearchResultCard(
            title: 'A long song title',
            artist: 'Artist',
            album: 'Album',
            snippet: 'The lyric phrase',
            onPlay: null,
          ),
          scale: 1.8,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('A long song title'));
      expect(tester.takeException(), isNull);
    },
  );
}
