import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/library/lokal_albums_artists.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, asset) in [
      (LokalTheme.sans, 'assets/fonts/DMSans-Regular.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });

  testWidgets('artist favorites and import controls fit all locales at 200%', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final previous = l10n;
    addTearDown(() => LocaleController.instance.bind(previous));
    for (final locale in kSupportedLocales) {
      LocaleController.instance.bindLocale(locale);
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(locale),
          overrides: [
            konnektedLibraryProvider.overrideWithValue(const AsyncData([])),
            lokalArtistsProvider.overrideWithValue(const AsyncData([])),
          ],
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
            home: const MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: LokalArtistsPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final import = find.text(lokalText('Import favorites from Spotify'));
      expect(import, findsOneWidget, reason: '$locale');
      await tester.ensureVisible(import);
      await tester.pumpAndSettle();
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: import, matching: find.byType(RichText)),
      );
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '$locale import label',
      );
      expect(find.text(lokalText('Favorites')), findsOneWidget);
      expect(find.text(lokalText('Non-favorites')), findsOneWidget);
      if (locale.languageCode != 'en') {
        expect(find.text('Import favorites from Spotify'), findsNothing);
      }
      expect(tester.takeException(), isNull, reason: '$locale');
    }
  });
}
