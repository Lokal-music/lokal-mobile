import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_destination.dart';
import 'package:flick/features/konnekted/konnekted_library.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'Library localizes shortcuts and import without changing destinations',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final previous = l10n;
      addTearDown(() => LocaleController.instance.bind(previous));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      final destinations = <KonnektedDestination>[];
      var imports = 0;
      Future<void> show(String locale) async {
        LocaleController.instance.bindLocale(Locale(locale));
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(locale),
            overrides: [
              konnektedLibraryProvider.overrideWithValue(const AsyncData([])),
            ],
            child: MaterialApp(
              theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 568),
                  textScaler: TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: KonnektedLibrary(
                    onNavigate: destinations.add,
                    onAddFolder: (_) => imports++,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show('tr');
      await tester.scrollUntilVisible(find.text('Müzik klasörü ekle'), 160);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Müzik klasörü ekle'));
      expect(imports, 1);
      for (final (label, destination) in [
        ('Beğenildi', KonnektedDestination.favorites),
        ('Çalma listeleri', KonnektedDestination.playlists),
        ('Albümler', KonnektedDestination.albums),
        ('Sanatçılar', KonnektedDestination.artists),
        ('Türler', KonnektedDestination.genres),
        ('İndirilenler', KonnektedDestination.downloads),
      ]) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        expect(destinations.last, destination);
      }
      expect(find.text('Liked'), findsNothing);
      expect(tester.takeException(), isNull);
      await show('en');
      await tester.scrollUntilVisible(find.text('Add a music folder'), 160);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add a music folder'));
      expect(imports, 2);
      await tester.ensureVisible(find.text('Albums'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Albums'));
      expect(destinations.last, KonnektedDestination.albums);
      expect(find.text('Albümler'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
