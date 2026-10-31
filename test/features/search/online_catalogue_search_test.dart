import 'package:flick/features/search/screens/search_screen.dart';
import 'package:flick/features/search/providers/global_search_provider.dart';
import 'package:flick/features/search/models/global_search_results.dart';
import 'package:flick/models/song.dart';

import 'dart:async';

import 'package:flick/features/search/widgets/online_catalogue_search_section.dart';
import 'package:flick/features/search/widgets/global_catalogue_search_section.dart';
import 'package:flick/services/global_catalogue_search.dart';
import 'package:flick/features/search/providers/search_filter_provider.dart';
import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/providers/apple_music_provider.dart';
import 'package:flick/services/apple_music/apple_music_metadata_service.dart';
import 'package:flick/services/apple_music/apple_music_models.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api implements AppleMusicMetadataService {
  final calls = <String>[];
  Completer<List<AppleMusicAlbumMatch>>? old;
  @override
  Future<List<AppleMusicAlbumMatch>> searchAlbums(
    String term, {
    int limit = 25,
    String? storefront,
    bool refresh = false,
  }) async {
    calls.add('albums:$term');
    if (term == 'old') return old!.future;
    return [
      for (var i = 0; i < 6; i++)
        AppleMusicAlbumMatch(
          collectionId: '$i',
          name: '$term album $i',
          artistName: 'Composer',
          url: '',
        ),
    ];
  }

  @override
  Future<List<AppleMusicArtist>> searchArtists(
    String term, {
    int limit = 25,
    String? storefront,
    bool refresh = false,
  }) async {
    calls.add('artists:$term');
    return [AppleMusicArtist(artistId: 'a', name: '$term performer')];
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Catalogue extends GlobalCatalogueSearchService {
  final calls = <String>[];
  @override
  Future<GlobalCatalogueMatches> search(String query, {
    String? selected, bool refresh = false, bool songsOnly = false,
  }) async {
    calls.add(query);
    return GlobalCatalogueMatches(catalogue: 'apple',
      artists: [GlobalCatalogueArtist(name: '$query performer')]);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'whole search screen isolates a category and switches to online without library work',
    (tester) async {
      final api = _Api();
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
          appleMusicMetadataServiceProvider.overrideWithValue(api),
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
      await tester.enterText(find.byType(TextField), 'Dude');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Artists'));
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

  testWidgets('All search keeps online results mounted when local results arrive', (tester) async {
    final api = _Catalogue();
    final local = Completer<GlobalSearchResults>();
    final c = ProviderContainer(overrides: [
      globalCatalogueSearchServiceProvider.overrideWithValue(api),
      globalSearchResultsProvider.overrideWith((ref, query) => local.future),
    ]);
    addTearDown(c.dispose);
    c.read(searchFilterProvider.notifier).select(SearchCategory.artists);
    c.read(searchScopeProvider.notifier).select(SearchScope.all);
    await tester.pumpWidget(UncontrolledProviderScope(container: c,
      child: MaterialApp(theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
        home: const SearchScreen())));
    await tester.enterText(find.byType(TextField), 'Dude');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final finder = find.byType(OnlineCatalogueSearchSection);
    expect(finder, findsOneWidget);
    final element = tester.element(finder);
    const song = Song(id: '1', title: 'Track', artist: 'Composer',
      duration: Duration(minutes: 3), fileType: 'FLAC');
    local.complete(const GlobalSearchResults(query: 'Dude', artists: [MapEntry('Composer', [song])]));
    await tester.pump();
    await tester.pump();
    expect(tester.element(finder), same(element));
    expect(api.calls.where((call) => call == 'Dude'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist and album filters use their own catalogue endpoints', (
    tester,
  ) async {
    final api = _Api();
    final c = ProviderContainer(
      overrides: [appleMusicMetadataServiceProvider.overrideWithValue(api)],
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
    expect(api.calls, ['artists:Dude', 'albums:Dude']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('late results from the old query never replace a newer query', (
    tester,
  ) async {
    final api = _Api()..old = Completer<List<AppleMusicAlbumMatch>>();
    final c = ProviderContainer(
      overrides: [appleMusicMetadataServiceProvider.overrideWithValue(api)],
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
    api.old!.complete([
      const AppleMusicAlbumMatch(
        collectionId: 'old',
        name: 'Obsolete album',
        artistName: 'Wrong',
        url: '',
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('new album 0'), findsOneWidget);
    expect(find.text('Obsolete album'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
