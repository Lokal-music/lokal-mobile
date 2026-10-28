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

const libraryKey = 'lokal.library.songs.song_browser_view.v1';
const playlistKey = 'lokal.playlist.test.song_browser_view.v1';

Song song(String id) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  fileType: 'FLAC',
  duration: const Duration(minutes: 3),
  sampleRate: 44100,
  bitDepth: 16,
);

Widget browserPage(String key) => ProviderScope(
  child: MaterialApp(
    theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
    home: Scaffold(
      body: CustomScrollView(
        slivers: [
          LokalSongBrowser(
            songs: [song('a'), song('b')],
            initialSort: key == playlistKey
                ? LokalSongSort.original
                : LokalSongSort.recentlyAdded,
            originalLabel: key == playlistKey ? 'Playlist order' : null,
            preferencesKey: key,
          ),
        ],
      ),
    ),
  ),
);

void main() {
  test('all saved song views include the entire sort and filter state', () {
    const view = LokalSongBrowserViewSettings(
      sort: LokalSongSort.artist,
      descending: false,
      location: LokalSongLocation.pc,
      audioFilter: 'format:16:44100',
      query: 'music',
    );
    final restored = LokalSongBrowserViewSettings.decode(
      jsonEncode(view.toJson()),
    );
    expect(restored, isNotNull);
    expect(restored!.sort, LokalSongSort.artist);
    expect(restored.descending, isFalse);
    expect(restored.location, LokalSongLocation.pc);
    expect(restored.audioFilter, 'format:16:44100');
    expect(restored.query, 'music');
  });

  testWidgets('Library and playlist views restore distinct saved directions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      libraryKey: jsonEncode(
        const LokalSongBrowserViewSettings(
          sort: LokalSongSort.title,
          descending: true,
          location: LokalSongLocation.all,
          audioFilter: 'all',
          query: '',
        ).toJson(),
      ),
      playlistKey: jsonEncode(
        const LokalSongBrowserViewSettings(
          sort: LokalSongSort.original,
          descending: false,
          location: LokalSongLocation.all,
          audioFilter: 'all',
          query: '',
        ).toJson(),
      ),
    });
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(browserPage(libraryKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Descending · switch to ascending'), findsOneWidget);
    expect(find.byTooltip('Sort: Title'), findsOneWidget);

    // Switching the criterion must preserve the descending selection.
    await tester.tap(find.byTooltip('Sort: Title'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Artist'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Descending · switch to ascending'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    await tester.pump(const Duration(milliseconds: 50));
    final savedLibrary = LokalSongBrowserViewSettings.decode(
      prefs.getString(libraryKey),
    );
    expect(savedLibrary!.sort, LokalSongSort.artist);
    expect(savedLibrary.descending, isTrue);

    await tester.pumpWidget(browserPage(playlistKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ascending · switch to descending'), findsOneWidget);
    expect(find.byTooltip('Sort: Playlist order'), findsOneWidget);
    expect(
      LokalSongBrowserViewSettings.decode(prefs.getString(libraryKey))!
          .descending,
      isTrue,
    );
  });

  testWidgets('reopening the same list restores newly saved direction', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(browserPage(libraryKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Descending · switch to ascending'), findsOneWidget);
    await tester.tap(find.byTooltip('Descending · switch to ascending'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ascending · switch to descending'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(browserPage(libraryKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ascending · switch to descending'), findsOneWidget);
  });
}
