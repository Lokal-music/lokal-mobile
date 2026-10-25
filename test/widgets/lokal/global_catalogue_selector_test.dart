import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/settings/widgets/global_catalogue_selector.dart';
import 'package:flick/services/global_catalogue_source.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app({double scale = 1}) => ProviderScope(
  child: MaterialApp(
    theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: ListView(
        children: const [
          LokalSettingsSection(
            title: 'Streaming & Search',
            children: [
              LokalSettingCustom(
                label: 'Global search catalogue',
                child: GlobalCatalogueSelector(),
              ),
              LokalSettingRow(label: 'Playback search priority'),
            ],
          ),
        ],
      ),
    ),
  ),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await GlobalCatalogueSource.set(GlobalCatalogueSource.spotify);
  });

  for (final size in [320.0, 390.0]) {
    testWidgets('catalogue setting is labelled and inset at $size px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(size, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.text('Global search catalogue'), findsOneWidget);
      expect(find.text('SPOTIFY'), findsOneWidget);
      expect(find.byType(SegmentedButton<String>), findsNothing);
      expect(
        find.textContaining('Spotify uses your existing account cookie.'),
        findsNothing,
      );
      final card = tester.getRect(find.byType(LokalSettingsCard));
      final title = tester.getRect(find.text('Global search catalogue'));
      final value = tester.getRect(find.text('SPOTIFY'));
      expect(title.left - card.left, greaterThanOrEqualTo(16));
      expect(card.right - value.right, greaterThanOrEqualTo(16));
      expect(title.right, lessThanOrEqualTo(value.left));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('choice sheet explains Spotify and persists either provider', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Global search catalogue'));
    await tester.pumpAndSettle();
    expect(find.text('Apple Music'), findsOneWidget);
    expect(find.text('Spotify'), findsOneWidget);
    expect(
      find.textContaining('Spotify uses your existing account cookie.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Apple Music'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('APPLE MUSIC'), findsOneWidget);
    expect(GlobalCatalogueSource.selected.value, GlobalCatalogueSource.apple);
    expect(
      (await SharedPreferences.getInstance()).getString(
        GlobalCatalogueSource.key,
      ),
      'apple',
    );
    await tester.tap(find.text('Global search catalogue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spotify'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('SPOTIFY'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString(
        GlobalCatalogueSource.key,
      ),
      'spotify',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow layout and sheet remain usable with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(scale: 1.6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Global search catalogue'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Apple Music'));
    await tester.tap(find.text('Apple Music'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(GlobalCatalogueSource.selected.value, 'apple');
    expect(tester.takeException(), isNull);
  });
}
