import 'dart:convert';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/library/lokal_song_browser.dart';
import 'package:flick/features/konnekted/library/lokal_song_filter.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, String title, DateTime added) => Song(
  id: id,
  title: title,
  artist: 'Artist',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
  dateAdded: added,
);

void main() {
  final oldLibrarySong = _song('new-like', 'Zebra', DateTime(2020));
  final newLibrarySong = _song('old-like', 'Alpha', DateTime(2026));

  test('Likes newest-first follows heart dates, not file-import dates', () {
    final likedRanks = {'old-like': 100, 'new-like': 200};
    final tracks = [newLibrarySong, oldLibrarySong];

    tracks.sort((a, b) => compareSongAddedOrder(
      a, b, descending: true, likedRanks: likedRanks,
    ));
    expect(tracks.first.id, 'new-like');

    tracks.sort((a, b) => compareSongAddedOrder(
      a, b, descending: false, likedRanks: likedRanks,
    ));
    expect(tracks.first.id, 'old-like');

    // Every other library page must continue sorting by actual dateAdded.
    tracks.sort((a, b) => compareSongAddedOrder(
      a, b, descending: true,
    ));
    expect(tracks.first.id, 'old-like');
  });

  test('Likes view roundtrips direction, sort, location, format and search', () {
    const settings = LokalSongBrowserViewSettings(
      sort: LokalSongSort.artist,
      descending: true,
      location: LokalSongLocation.phone,
      audioFilter: 'format:16:44100',
      query: 'Soundtrack',
    );
    final decoded = LokalSongBrowserViewSettings.decode(
      jsonEncode(settings.toJson()),
    );
    expect(decoded, isNotNull);
    expect(decoded!.sort, LokalSongSort.artist);
    expect(decoded.descending, isTrue);
    expect(decoded.location, LokalSongLocation.phone);
    expect(decoded.audioFilter, 'format:16:44100');
    expect(decoded.query, 'Soundtrack');
  });

  testWidgets('Likes restores direction and quality/location filters across visits',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'lokal.likes.test_view': jsonEncode(const LokalSongBrowserViewSettings(
        sort: LokalSongSort.recentlyAdded,
        descending: false,
        location: LokalSongLocation.phone,
        audioFilter: 'quality:lossless',
        query: '',
      ).toJson()),
    });
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Widget page() => ProviderScope(
      child: MaterialApp(
        theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              LokalSongBrowser(
                songs: [_song('local', 'Local track', DateTime(2026))],
                preferencesKey: 'lokal.likes.test_view',
                recentlyAddedRanks: const {'local': 1},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ascending · switch to descending'), findsOneWidget);
    expect(find.text('Mobile'), findsOneWidget);
    expect(find.text('Lossless'), findsOneWidget);

    await tester.tap(find.byTooltip('Ascending · switch to descending'));
    await tester.pumpAndSettle();
    final preferences = await SharedPreferences.getInstance();
    // SharedPreferences writes are queued, so flush the widget's microtasks.
    await tester.pump(const Duration(milliseconds: 50));
    final saved = LokalSongBrowserViewSettings.decode(
      preferences.getString('lokal.likes.test_view'),
    );
    expect(saved!.descending, isTrue);
    expect(saved.location, LokalSongLocation.phone);
    expect(saved.audioFilter, 'quality:lossless');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Descending · switch to ascending'), findsOneWidget);
    expect(find.text('Mobile'), findsOneWidget);
  });

  test('malformed settings and removed format/quality names are safe', () {
    expect(LokalSongBrowserViewSettings.decode('{broken'), isNull);
    final restored = LokalSongBrowserViewSettings.decode(jsonEncode({
      'sort': 'original',
      'descending': false,
      'location': 'invalid-location',
      'audioFilter': 'quality:gone',
      'query': 'ok',
    }));
    expect(restored!.sort, LokalSongSort.recentlyAdded);
    expect(restored.descending, isFalse);
    expect(restored.location, LokalSongLocation.all);
    expect(restored.audioFilter, 'all');
  });
}
