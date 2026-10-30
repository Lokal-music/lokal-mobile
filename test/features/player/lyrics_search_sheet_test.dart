import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/online_lyrics_service.dart';
import 'package:flick/features/player/widgets/online_lyrics_search_sheet.dart';

final _song = Song(
  id: 'song',
  title: '駅',
  artist: 'Mariya Takeuchi',
  fileType: 'FLAC',
  duration: const Duration(seconds: 290),
);
const _result = OnlineLyricsResult(
  id: 1,
  trackName: 'Chosen song',
  artistName: 'Chosen artist',
  duration: 290,
  instrumental: false,
  syncedLyrics: '',
  plainLyrics: 'Plain words',
);

class _Online extends OnlineLyricsService {
  final requests = <Completer<List<OnlineLyricsResult>>>[];
  final queries = <String>[];
  @override
  Future<List<OnlineLyricsResult>> search({
    String? query,
    String? artist,
    String? title,
    String? album,
    bool refresh = false,
    bool reportErrors = false,
  }) {
    queries.add('$title|$artist');
    final request = Completer<List<OnlineLyricsResult>>();
    requests.add(request);
    return request.future;
  }
}

class _Lyrics extends LyricsService {
  final saved = <String>[];
  @override
  Future<LyricsSaveResult> importLyricsForSong({
    required Song song,
    required String fileName,
    required String content,
  }) async {
    saved.add(content);
    return LyricsSaveResult(
      data: parseLyricsText(content),
      path: 'test',
      savedBesideSong: false,
    );
  }
}

void main() {
  testWidgets(
    'manual search ignores stale answers and a result applies directly',
    (tester) async {
      final online = _Online(),
          lyrics = _Lyrics(),
          session = LyricsSearchSession(_song);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<bool>(
                context: context,
                isScrollControlled: true,
                builder: (_) => SizedBox(
                  height: 580,
                  child: OnlineLyricsSearchSheet(
                    song: _song,
                    lyricsService: lyrics,
                    onlineService: online,
                    session: session,
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(online.requests, isEmpty); // Desktop does not search on opening.
      await tester.tap(find.text('Search'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('lyrics-search-title')),
        'New title',
      );
      online.requests.first.complete([_result]);
      await tester.pump();
      expect(find.text('Chosen song'), findsNothing);
      await tester.tap(find.text('Search'));
      await tester.pump();
      expect(online.queries.last, 'New title|Mariya Takeuchi');
      online.requests.last.complete([_result]);
      await tester.pumpAndSettle();
      expect(find.text('Chosen song'), findsOneWidget);
      await tester.ensureVisible(find.text('Chosen song'));
      await tester.tap(find.text('Chosen song'));
      await tester.pumpAndSettle();
      expect(lyrics.saved.single, 'Plain words');
      expect(find.text('Open'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Chosen song'), findsOneWidget);
      expect(
        find.text('New title'),
        findsOneWidget,
      ); // Session survives closing.
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rate limit reports the provider error instead of a connection failure',
      (tester) async {
    final online = _Online();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<bool>(
              context: context,
              isScrollControlled: true,
              builder: (_) => SizedBox(
                height: 580,
                child: OnlineLyricsSearchSheet(
                  song: _song,
                  lyricsService: _Lyrics(),
                  onlineService: online,
                  session: LyricsSearchSession(_song),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search'));
    await tester.pump();
    online.requests.single.completeError(
      const OnlineLyricsHttpException(
        429,
        retryAfter: Duration(seconds: 45),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('rate limit'), findsOneWidget);
    expect(find.textContaining('45 seconds'), findsOneWidget);
    expect(find.textContaining('Check your connection'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
