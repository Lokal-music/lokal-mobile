import 'package:flick/features/search/screens/search_screen.dart';
import 'package:flick/features/search/providers/global_search_provider.dart';
import 'package:flick/features/search/models/global_search_results.dart';
import 'package:flick/models/song.dart';

import 'dart:async';

import 'package:flick/features/search/widgets/online_catalogue_search_section.dart';
import 'package:flick/features/search/providers/search_filter_provider.dart';
import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/services/global_catalogue_search.dart';
import 'package:flick/services/global_catalogue_source.dart';
import 'package:flick/features/search/widgets/global_catalogue_search_section.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Stub the current catalogue boundary. The catalogue's Apple/Spotify HTTP
// requests have separate service tests; these checks exercise UI filtering,
// scope changes and stale-result handling without live requests.
class _Catalogue extends GlobalCatalogueSearchService {
  final calls = <String>[];
  Completer<GlobalCatalogueMatches>? old;

  @override
  Future<GlobalCatalogueMatches> search(
    String query, {String? selected, bool refresh = false, bool songsOnly = false}
  ) async {
    calls.add(query);
    if (query == 'old') return old!.future;
    return GlobalCatalogueMatches(
      catalogue: GlobalCatalogueSource.apple,
      albums: [
        for (var i = 0; i < 6; i++)
          GlobalCatalogueAlbum(name: '$query album $i', artist: 'Composer'),
      ],
      artists: [GlobalCatalogueArtist(name: '$query performer')],
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalCatalogueSource.selected.value = GlobalCatalogueSource.apple;
  });
  testWidgets(
    'whole search screen isolates a category and switches to online without library work',
    (tester) async {
      final api = _Catalogue();
      var libraryReads = 0;
      const song = Song(
        id: '1',
        title: 'Track',
        artist: 'Composer',
        duration: Duration(minutes: 3),
        fileType: 'FLAC',
      );
      final c = ProviderContainer(
        overrides: [
          globalCatalogueSearchServiceProvider.overrideWithValue(
            api,
          ),
          globalSearchResultsProvider.overrideWith((ref, query) async {
            libraryReads++;
            return GlobalSearchResults(
              query: query,
              artists: [
                for (var i = 0; i < 7; i++)
                  MapEntry('Library Composer $i', [song]),
              ],
            );
          }),
        ],
      );
      addTearDown(c.dispose);
      c.read(searchScopeProvider.notifier).select(SearchScope.library);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
            home: const SearchScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Artists'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Dude');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Library Composer 6'), 250,
        scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).last);
      expect(
        find.text('Library Composer 6'),
        findsOneWidget,
      ); // No four-item preview limit for an isolated category.
      final reads = libraryReads;
      await tester.tap(find.text('Online'));
      await tester.pumpAndSettle();
      expect(find.text('Library Composer 0'), findsNothing);
      expect(find.text('Dude performer'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'New');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('New performer'), findsOneWidget);
      expect(libraryReads, reads);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('artist and album filters show only their catalogue entity type', (
    tester,
  ) async {
    final api = _Catalogue();
    final c = ProviderContainer(
      overrides: [globalCatalogueSearchServiceProvider.overrideWithValue(
            api,
          )],
    );
    addTearDown(c.dispose);
    Widget app(SearchCategory type, String query, {int? preview}) =>
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
            home: Scaffold(
              body: SingleChildScrollView(
                child: OnlineCatalogueSearchSection(
                  category: type,
                  query: query,
                  previewLimit: preview,
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(app(SearchCategory.artists, 'Dude'));
    await tester.pumpAndSettle();
    expect(find.text('Dude performer'), findsOneWidget);
    expect(find.text('Dude album 0'), findsNothing);
    await tester.pumpWidget(app(SearchCategory.albums, 'Dude', preview: 2));
    await tester.pumpAndSettle();
    expect(find.text('Dude performer'), findsNothing);
    expect(find.text('Dude album 0'), findsOneWidget);
    expect(find.text('Dude album 2'), findsNothing);
    await tester.tap(find.text('See all albums'));
    await tester.pumpAndSettle();
    expect(c.read(searchFilterProvider), {SearchCategory.albums});
    expect(api.calls, ['Dude', 'Dude']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('late results from the old query never replace a newer query', (
    tester,
  ) async {
    final api = _Catalogue()..old = Completer<GlobalCatalogueMatches>();
    final c = ProviderContainer(
      overrides: [globalCatalogueSearchServiceProvider.overrideWithValue(
            api,
          )],
    );
    addTearDown(c.dispose);
    Widget app(String query) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
        home: Scaffold(
          body: SingleChildScrollView(
            child: OnlineCatalogueSearchSection(
              category: SearchCategory.albums,
              query: query,
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app('old'));
    await tester.pump();
    await tester.pumpWidget(app('new'));
    await tester.pumpAndSettle();
    api.old!.complete(const GlobalCatalogueMatches(
      catalogue: GlobalCatalogueSource.apple,
      albums: [GlobalCatalogueAlbum(name: 'Obsolete album', artist: 'Wrong')],
    ));
    await tester.pumpAndSettle();
    expect(find.text('new album 0'), findsOneWidget);
    expect(find.text('Obsolete album'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
