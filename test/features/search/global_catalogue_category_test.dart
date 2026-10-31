import 'dart:async';

import 'package:flick/features/search/providers/global_search_provider.dart';
import 'package:flick/features/search/models/global_search_results.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/discovery/discovery_artwork.dart';
import 'package:flick/features/discovery/discovery_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/features/search/providers/search_filter_provider.dart';
import 'package:flick/features/search/screens/search_screen.dart';
import 'package:flick/features/search/widgets/global_catalogue_search_section.dart';
import 'package:flick/features/search/widgets/online_catalogue_search_section.dart';
import 'package:flick/features/search/widgets/artist_search_portrait.dart';
import 'package:flick/services/global_catalogue_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Catalogue extends GlobalCatalogueSearchService {
  _Catalogue(this.catalogue, {this.emptySongs = false});
  final String catalogue;
  final bool emptySongs;
  final calls = <bool>[];

  @override
  Future<GlobalCatalogueMatches> search(
    String rawQuery, {
    String? selected,
    bool refresh = false,
    bool songsOnly = false,
  }) async {
    calls.add(songsOnly);
    // Return mixed entities even for Songs to verify the view also respects
    // its category when a cached/provider response includes other types.
    return GlobalCatalogueMatches(
      catalogue: catalogue,
      songs: emptySongs
          ? []
          : const [
              GlobalCatalogueSong(
                catalogueId: 'song',
                title: 'Wanted song',
                artist: 'Singer',
              ),
            ],
      albums: const [
        GlobalCatalogueAlbum(name: 'Unrelated album', artist: 'Other'),
      ],
      artists: const [GlobalCatalogueArtist(
        name: 'Unrelated artist', artworkUrl: 'https://example.test/portrait.jpg',
      )],
    );
  }
}

// Keep artwork fallbacks deterministic: tests must not depend on public CDNs.
final _quietArtwork = [
  discoveryLocalArtworkProvider.overrideWithValue(DiscoveryLocalArtwork.empty),
  discoveryArtworkResolverProvider.overrideWithValue(
    DiscoveryArtworkResolver(
      DiscoveryHttp(MockClient((_) async => http.Response(
        '{"data":[],"results":[]}', 200,
        headers: {'content-type': 'application/json'},
      ))),
    ),
  ),
];

Widget _app(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
        home: Scaffold(body: child),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('All keeps online catalogue mounted when local results load', (tester) async {
    final api = _Catalogue('apple');
    final local = Completer<GlobalSearchResults>();
    final c = ProviderContainer(overrides: [
      ..._quietArtwork,
      globalCatalogueSearchServiceProvider.overrideWithValue(api),
      globalSearchResultsProvider.overrideWith((ref, query) => local.future),
    ]);
    addTearDown(c.dispose);
    c.read(searchFilterProvider.notifier).select(SearchCategory.artists);
    c.read(searchScopeProvider.notifier).select(SearchScope.all);
    await tester.pumpWidget(_app(c, const SearchScreen()));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Dude');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    final finder = find.byType(OnlineCatalogueSearchSection);
    expect(finder, findsOneWidget);
    final element = tester.element(finder);
    const song = Song(id: '1', title: 'Track', artist: 'Composer',
        duration: Duration(minutes: 3), fileType: 'FLAC');
    local.complete(GlobalSearchResults(query: 'Dude', artists: [MapEntry('Composer', [song])]));
    await tester.pump();
    await tester.pump();
    expect(tester.element(finder), same(element));
    expect(api.calls, [false]);
    expect(tester.takeException(), isNull);
  });

  for (final catalogue in ['apple', 'spotify']) {
    testWidgets(
      '$catalogue Songs hides albums/artists; All restores them for the same query',
      (tester) async {
        final api = _Catalogue(catalogue);
        final c = ProviderContainer(
          overrides: [
            ..._quietArtwork,
            globalCatalogueSearchServiceProvider.overrideWithValue(api),
          ],
        );
        addTearDown(c.dispose);
        Widget section(bool songsOnly) => _app(
          c,
          SingleChildScrollView(
            child: GlobalCatalogueSearchSection(
              query: 'Wanted',
              songsOnly: songsOnly,
            ),
          ),
        );
        await tester.pumpWidget(section(true));
        await tester.pumpAndSettle();
        expect(find.text('Wanted song'), findsOneWidget);
        final songArtwork = tester.widget<DiscoveryArtwork>(
          find.byType(DiscoveryArtwork).first,
        );
        expect(songArtwork.kind, DiscoveryArtworkKind.track);
        expect(songArtwork.title, 'Wanted song');
        expect(songArtwork.artist, 'Singer');
        expect(songArtwork.url, isEmpty);

        expect(find.text('Online songs'), findsNothing);
        expect(find.text('$catalogue'), findsNothing);
        expect(find.text('${catalogue == 'spotify' ? 'Spotify' : 'Apple Music'} catalogue · plays through your configured sources'), findsNothing);
        expect(find.text('Global'), findsNothing);
        expect(find.text('Songs'), findsNothing); // Category tabs are the header.
        expect(find.text('Unrelated album'), findsNothing);
        expect(find.text('Unrelated artist'), findsNothing);
        expect(find.text('Albums'), findsNothing);
        expect(find.text('Artists'), findsNothing);
        await tester.pumpWidget(section(false));
        await tester.pumpAndSettle();
        expect(find.text('Global'), findsNothing);
        expect(find.text('Online songs'), findsNothing);
        expect(find.text('Unrelated album'), findsOneWidget);
        final albumArtwork = tester.widgetList<DiscoveryArtwork>(
          find.byType(DiscoveryArtwork),
        ).where((artwork) => artwork.kind == DiscoveryArtworkKind.album);
        expect(albumArtwork, hasLength(1));
        expect(albumArtwork.single.title, 'Unrelated album');
        expect(albumArtwork.single.artist, 'Other');

        expect(find.text('Unrelated artist'), findsOneWidget);
        await tester.pumpWidget(section(true));
        await tester.pumpAndSettle();
        expect(find.text('Unrelated album'), findsNothing);
        expect(api.calls, [true, false, true]);
      },
    );
  }
  testWidgets('Global song long press exposes the same queue and download menu', (
    tester,
  ) async {
    final c = ProviderContainer(overrides: [
      ..._quietArtwork,
      globalCatalogueSearchServiceProvider.overrideWithValue(
        _Catalogue('apple'),
      ),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(
      c,
      const SingleChildScrollView(
        child: GlobalCatalogueSearchSection(query: 'Wanted', songsOnly: true),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Wanted song'));
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Download to library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Songs empty state ignores album/artist-only matches', (
    tester,
  ) async {
    final c = ProviderContainer(
      overrides: [
        ..._quietArtwork,
        globalCatalogueSearchServiceProvider.overrideWithValue(
          _Catalogue('apple', emptySongs: true),
        ),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      _app(
        c,
        const GlobalCatalogueSearchSection(query: 'Wanted', songsOnly: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No global results found.'), findsOneWidget);
    expect(find.text('Unrelated album'), findsNothing);
    expect(find.text('Unrelated artist'), findsNothing);
  });
  testWidgets(
    'Search screen passes the Songs category to Global online results',
    (tester) async {
      final api = _Catalogue('apple');
      final c = ProviderContainer(
        overrides: [
          ..._quietArtwork,
          globalCatalogueSearchServiceProvider.overrideWithValue(api),
        ],
      );
      addTearDown(c.dispose);
      c.read(searchScopeProvider.notifier).select(SearchScope.online);
      c.read(searchFilterProvider.notifier).select(SearchCategory.songs);
      await tester.pumpWidget(_app(c, const SearchScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Search your library'), findsNothing);
    expect(find.text('Search online'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Wanted');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<GlobalCatalogueSearchSection>(
              find.byType(GlobalCatalogueSearchSection),
            )
            .songsOnly,
        true,
      );
      expect(find.text('Wanted song'), findsOneWidget);
      expect(find.text('Unrelated album'), findsNothing);
      expect(find.text('Unrelated artist'), findsNothing);
      expect(api.calls, everyElement(true));
      expect(tester.takeException(), isNull);
    },
  );
testWidgets('Online artists and albums omit redundant titles but keep artist portraits', (tester) async {
  final c = ProviderContainer(overrides: [
    ..._quietArtwork,
    globalCatalogueSearchServiceProvider.overrideWithValue(_Catalogue('spotify')),
  ]);
  addTearDown(c.dispose);
  await tester.pumpWidget(_app(c, const SingleChildScrollView(
    child: OnlineCatalogueSearchSection(query: 'Wanted', category: SearchCategory.artists),
  )));
  await tester.pumpAndSettle();
  expect(find.text('Online artists'), findsNothing);
  expect(find.text('Spotify catalogue · plays through your configured sources'), findsNothing);
  expect(find.byType(ArtistSearchPortrait), findsOneWidget);

  await tester.pumpWidget(_app(c, const SingleChildScrollView(
    child: OnlineCatalogueSearchSection(query: 'Wanted', category: SearchCategory.albums),
  )));
  await tester.pumpAndSettle();
  expect(find.text('Online albums'), findsNothing);
  expect(find.text('Spotify catalogue · plays through your configured sources'), findsNothing);
  expect(find.text('Unrelated album'), findsOneWidget);
});

}


