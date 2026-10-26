import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_dock.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'dock labels and tooltips follow the active locale without changing navigation IDs',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final previous = l10n;
      addTearDown(() => LocaleController.instance.bind(previous));
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <KonnektedTab>[];

      Future<void> show(String language) async {
        LocaleController.instance.bindLocale(Locale(language));
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: KonnektedDock(
                    selected: KonnektedTab.listen,
                    onSelect: selected.add,
                    miniPlayer: const SizedBox.shrink(),
                    hasMiniPlayer: false,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show('tr');
      expect(find.text('Ana sayfa'), findsOneWidget);
      expect(find.text('Kitaplık'), findsOneWidget);
      expect(find.text('Sen'), findsOneWidget);
      expect(find.byTooltip('Ara'), findsOneWidget);
      await tester.tap(find.byTooltip('Kitaplık'));
      await tester.tap(find.byTooltip('Ara'));
      expect(selected, [KonnektedTab.library, KonnektedTab.explore]);

      await show('en');
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(find.byTooltip('Search'), findsOneWidget);
      expect(find.text('Kitaplık'), findsNothing);
      expect(KonnektedTab.library.label, 'Library');
      expect(tester.takeException(), isNull);
    },
  );
}
