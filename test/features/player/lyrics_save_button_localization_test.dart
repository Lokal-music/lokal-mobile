import 'dart:io';
import 'dart:ui' as ui;

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/player/widgets/lyrics_save_button.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, asset) in [
      (LokalTheme.sans, 'assets/fonts/DMSans-Regular.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/lucide_icons_flutter/Lucide',
        'packages/lucide_icons_flutter/assets/lucide.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });

  testWidgets('save options retain both actions in every locale at 200 percent', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final previous = l10n;
    addTearDown(() => LocaleController.instance.bind(previous));
    for (final theme in [LokalThemeId.dark, LokalThemeId.light]) {
      for (final locale in kSupportedLocales) {
        LocaleController.instance.bindLocale(locale);
        if (locale.languageCode != 'en') {
          for (final text in [
            'Save original lyrics',
            'Save with selected translation',
            'Includes the active translation or romanization.',
            'Save lyrics to file (hold for options)',
          ]) {
            expect(lokalText(text), isNot(text), reason: '$locale: $text');
          }
        }
        final boundary = GlobalKey();
        var translated = 0;
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey('${locale.toLanguageTag()}-${theme.name}'),
            debugShowCheckedModeBanner: false,
            theme: LokalTheme.build(LokalTokens.resolve(theme)),
            builder: (context, child) => RepaintBoundary(
              key: boundary,
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
            ),
            home: Scaffold(
              body: Center(
                child: LyricsSaveButton(
                  saving: false,
                  onSaveOriginal: () {},
                  onSaveWithTranslation: () => translated++,
                ),
              ),
            ),
          ),
        );
        expect(
          tester.getSize(find.byType(IconButton)).height,
          greaterThanOrEqualTo(44),
        );
        await tester.longPress(find.byType(IconButton));
        await tester.pumpAndSettle();
        expect(find.text(lokalText('Save original lyrics')), findsOneWidget);
        final selected = find.text(lokalText('Save with selected translation'));
        expect(selected, findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: '$locale / ${theme.name}',
        );
        final output = Platform.environment['LOKAL_IOS290_UI_PREVIEW'];
        if (output != null) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            final directory = Directory(output)..createSync(recursive: true);
            await File(
              '${directory.path}/lyrics-save-${locale.toLanguageTag()}-${theme.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          });
        }
        await tester.ensureVisible(selected);
        await tester.tap(selected);
        await tester.pumpAndSettle();
        expect(translated, 1);
        expect(find.byType(BottomSheet), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
