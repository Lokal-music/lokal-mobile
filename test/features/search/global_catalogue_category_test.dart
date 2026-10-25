import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/features/search/providers/search_filter_provider.dart';
import 'package:flick/features/search/screens/search_screen.dart';
import 'package:flick/features/search/widgets/global_catalogue_search_section.dart';
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
      artists: const [GlobalCatalogueArtist(name: 'Unrelated artist')],
    );
  }
}

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
  for (final catalogue in ['apple', 'spotify']) {
    testWidgets(
      '$catalogue Songs hides albums/artists; All restores them for the same query',
      (tester) async {
        final api = _Catalogue(catalogue);
        final c = ProviderContainer(
          overrides: [
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
        expect(find.text('Unrelated album'), findsNothing);
        expect(find.text('Unrelated artist'), findsNothing);
        expect(find.text('Albums'), findsNothing);
        expect(find.text('Artists'), findsNothing);
        await tester.pumpWidget(section(false));
        await tester.pumpAndSettle();
        expect(find.text('Unrelated album'), findsOneWidget);
        expect(find.text('Unrelated artist'), findsOneWidget);
        await tester.pumpWidget(section(true));
        await tester.pumpAndSettle();
        expect(find.text('Unrelated album'), findsNothing);
        expect(api.calls, [true, false, true]);
      },
    );
  }
  testWidgets('Songs empty state ignores album/artist-only matches', (
    tester,
  ) async {
    final c = ProviderContainer(
      overrides: [
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
          globalCatalogueSearchServiceProvider.overrideWithValue(api),
        ],
      );
      addTearDown(c.dispose);
      c.read(searchScopeProvider.notifier).select(SearchScope.online);
      c.read(searchFilterProvider.notifier).select(SearchCategory.songs);
      await tester.pumpWidget(_app(c, const SearchScreen()));
      await tester.pumpAndSettle();
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
}
