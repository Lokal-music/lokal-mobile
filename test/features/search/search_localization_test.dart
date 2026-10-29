import 'package:flick/l10n/l10n.dart';
import 'package:flick/l10n/lokal_ui_translations.dart';
import 'package:flick/features/search/widgets/search_filter_chips.dart';
import 'package:flick/features/search/widgets/online_catalogue_search_section.dart';
import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/features/search/providers/search_filter_provider.dart';
import 'package:flick/features/search/widgets/global_catalogue_search_section.dart';
import 'package:flick/services/global_catalogue_search.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends GlobalCatalogueSearchService {
  final refreshes = <bool>[];

  @override
  Future<GlobalCatalogueMatches> search(
    String query, {String? selected, bool refresh = false,
    bool songsOnly = false,
  }) async {
    refreshes.add(refresh);
    if (!refresh) throw StateError('offline');
    return const GlobalCatalogueMatches(catalogue: 'apple');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(
    () => LocaleController.instance.bind(
      lookupAppLocalizations(const Locale('en')),
    ),
  );
  test('all shipped non-English locales have the new fixed search phrases', () {
    const phrases = [
      'Library',
      'Online',
      'Artist',
      'Search online catalogues and playback sources',
      'This category searches your library',
      'Online albums',
      'Online artists',
      'Apple Music catalogue · plays through your configured sources',
      'Could not search. Retry',
      'No albums found online.',
      'No artists found online.',
      'See all albums',
      'See all artists',
      'No matching tracks found. Try refreshing the catalogue.',
    ];
    for (final locale in kSupportedLocales.where(
      (locale) => locale.languageCode != 'en',
    )) {
      final map =
          lokalUiTranslations[locale.toString()] ??
          lokalUiTranslations[locale.languageCode]!;
      for (final phrase in phrases)
        expect(map[phrase], isNotEmpty, reason: '$locale: $phrase');
    }
  });
  testWidgets(
    'French scope, catalogue, retry and empty-state labels follow the active locale',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _Api();
      final c = ProviderContainer(
        overrides: [globalCatalogueSearchServiceProvider.overrideWithValue(api)],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            locale: const Locale('fr'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: kSupportedLocales,
            theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
            builder: (context, child) {
              LocaleController.instance.bind(AppLocalizations.of(context));
              return child!;
            },
            home: Scaffold(
              body: Column(
                children: [
                  SearchFilterChips(
                    enabled: const {SearchCategory.albums},
                    scope: SearchScope.online,
                    onToggle: (_) {},
                    onScopeChanged: (_) {},
                  ),
                  const Expanded(
                    child: SingleChildScrollView(
                      child: OnlineCatalogueSearchSection(
                        query: 'Dude',
                        category: SearchCategory.albums,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Toutes les sources'), findsNothing);
      expect(find.text('En ligne'), findsOneWidget);
      expect(find.text('Albums en ligne'), findsNothing);
      expect(find.text('Search online catalogues and playback sources'), findsNothing);
      await tester.tap(find.text('Recherche impossible. Réessayer'));
      await tester.pumpAndSettle();
      expect(api.refreshes, [false, true]);
      expect(find.text('Aucun album trouvé en ligne.'), findsOneWidget);
      expect(find.text('No albums found online.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
