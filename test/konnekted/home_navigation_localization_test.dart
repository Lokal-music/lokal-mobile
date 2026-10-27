import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_home.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    for (final (family, asset) in [
      (LokalTheme.sans, 'assets/fonts/DMSans-Regular.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });

  testWidgets('all Home modes remain readable and reachable in every locale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final previous = l10n;
    addTearDown(() => LocaleController.instance.bind(previous));
    for (final locale in kSupportedLocales) {
      LocaleController.instance.bindLocale(locale);
      KonnektedHomeTab? selected;
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(locale),
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.light)),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: KonnektedHomeTopBar(
                  now: DateTime(2026, 10, 27, 9),
                  onSettings: () {},
                  onAppearance: () {},
                  onTabChanged: (value) => selected = value,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final tab in KonnektedHomeTab.values) {
        final label = find.text(lokalText(tab.label).toUpperCase());
        await tester.ensureVisible(label);
        await tester.pumpAndSettle();
        expect(tester.getSize(label).height, greaterThanOrEqualTo(20));
        await tester.tap(label);
        expect(selected, tab, reason: '$locale ${tab.name}');
      }
      expect(tester.takeException(), isNull, reason: '$locale layout');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
