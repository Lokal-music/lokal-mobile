import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/settings/lokal/groups/online_sources_group.dart';
import 'package:flick/features/settings/widgets/eco_data_mode_toggle.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    for (final (family, asset) in [
      (LokalTheme.sans, 'assets/fonts/DMSans-Regular.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });

  testWidgets('iPhone source controls fit all locales at 200% on 320px', (
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
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
            home: MediaQuery(
              data: const MediaQueryData(
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final soundCloud = onlineSourcesSettings(context, ref)
                          .first
                          .children
                          .whereType<LokalSettingRow>()
                          .singleWhere(
                            (row) =>
                                row.key ==
                                const ValueKey('soundcloud-source-toggle'),
                          );
                      return Column(
                        children: [const EcoDataModeToggle(), soundCloud],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final phrase in [
        EcoDataModeToggle.label,
        EcoDataModeToggle.description,
        'Search and stream audio from SoundCloud.',
      ]) {
        final text = lokalText(phrase);
        if (locale.languageCode != 'en') {
          expect(text, isNot(phrase), reason: '$locale translation');
        }
        final label = find.text(text);
        expect(label, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: label, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, false, reason: '$locale $phrase');
      }
      expect(find.text('SoundCloud'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$locale layout');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
