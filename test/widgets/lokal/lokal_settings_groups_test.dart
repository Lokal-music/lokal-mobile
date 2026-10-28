import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/features/settings/lokal/lokal_settings_page.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The player switches the Playback pages show, without the real engine.
class _FakePlayer extends Fake implements PlayerService {
  @override
  final gaplessPlaybackEnabledNotifier = ValueNotifier(true);
  @override
  final bitPerfectProcessingLockedNotifier = ValueNotifier(false);
  @override
  final wrapAroundQueueNotifier = ValueNotifier(true);
  @override
  final autoplayOnQueueEndNotifier = ValueNotifier(false);
  @override
  final duckOnInterruptionNotifier = ValueNotifier(true);
  @override
  final extendedVolumeEnabledNotifier = ValueNotifier(false);
  @override
  bool get isBitPerfectModeEnabled => false;

  @override
  Future<void> setWrapAroundQueue(bool value) async =>
      wrapAroundQueueNotifier.value = value;

  @override
  Future<void> setAutoplayOnQueueEnd(bool value) async =>
      autoplayOnQueueEndNotifier.value = value;
}

Widget _app(Widget home, {PlayerService? player}) => ProviderScope(
  overrides: [playerServiceProvider.overrideWithValue(player ?? _FakePlayer())],
  child: Consumer(
    builder: (context, ref, _) => MaterialApp(
      theme: LokalTheme.build(ref.watch(lokalAppearanceProvider).tokens),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) {
        LocaleController.instance.bind(AppLocalizations.of(context));
        return child!;
      },
      home: home,
    ),
  ),
);

void main() {
  test(
    'root output descriptions are translated in all supported languages',
    () {
      final previous = l10n;
      addTearDown(() => LocaleController.instance.bind(previous));
      for (final locale in kSupportedLocales.where(
        (value) => value.languageCode != 'en',
      )) {
        LocaleController.instance.bindLocale(locale);
        for (final phrase in [
          'Audio output',
          'AirPlay, Bluetooth, volume and crossfeed',
          'Advanced output',
          'ReplayGain, crossfade, queue, equalizer and lyrics',
        ]) {
          expect(
            lokalText(phrase),
            isNot(phrase),
            reason: locale.toLanguageTag(),
          );
        }
      }
    },
  );
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final group in [
    LokalSettingsGroup.playback,
    LokalSettingsGroup.output,
    LokalSettingsGroup.library,
    LokalSettingsGroup.appearance,
    LokalSettingsGroup.about,
    LokalSettingsGroup.data,
    LokalSettingsGroup.integrations,
  ]) {
    testWidgets('${group.label} builds its sections with the kit', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(412, 915)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(LokalSettingsGroupPage(group: group)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.byType(LokalSettingsSection), findsWidgets);
    });
  }

  testWidgets('Library puts Add folder first', (tester) async {
    tester.view
      ..physicalSize = const Size(412, 915)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(const LokalSettingsGroupPage(group: LokalSettingsGroup.library)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final add = find.byKey(const ValueKey('library-add-folder'));
    expect(add, findsOneWidget);
    expect(find.text('Add folder'), findsOneWidget);
    expect(
      tester.getTopLeft(add).dy,
      lessThan(tester.getTopLeft(find.text('Manage folders')).dy),
    );
    // The duplicated filters live only here now, not on the Folders page.
    expect(find.text('Skip non-music files'), findsOneWidget);
  });

  testWidgets('Advanced output opens directly from Settings root', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(412, 915)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const LokalSettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('Advanced output'), findsOneWidget);
    await tester.tap(find.text('Advanced output'));
    await tester.pumpAndSettle();

    expect(find.byType(LokalSettingsGroupPage), findsOneWidget);
    expect(find.text('USB DAC'), findsWidgets);
    expect(find.text('Bluetooth'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Playback no longer nests Advanced output', (tester) async {
    await tester.pumpWidget(
      _app(const LokalSettingsGroupPage(group: LokalSettingsGroup.playback)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Advanced output'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Playback rows drive the player and rebuild with it', (
    tester,
  ) async {
    final player = _FakePlayer();
    await tester.pumpWidget(
      _app(
        const LokalSettingsGroupPage(
          group: LokalSettingsGroup.playback,
          section: 'Queue',
        ),
        player: player,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Autoplay'));
    await tester.pumpAndSettle();
    expect(player.autoplayOnQueueEndNotifier.value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search reaches rows in every real group', (tester) async {
    tester.view
      ..physicalSize = const Size(412, 915)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const LokalSettingsPage()));
    await tester.enterText(find.byType(TextField), 'lyrics automatically');
    await tester.pumpAndSettle();
    expect(find.text('Fetch lyrics automatically'), findsOneWidget);
    expect(find.text('PLAYBACK · LYRICS'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'scrobbl');
    await tester.pumpAndSettle();
    expect(find.text('DATA · ACCOUNTS'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'licences');
    await tester.pumpAndSettle();
    expect(find.text('Licences'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('canonical Online sources exposes HTTP add-ons', (tester) async {
    await tester.pumpWidget(
      _app(
        const LokalSettingsGroupPage(group: LokalSettingsGroup.integrations),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('HTTP music add-ons'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('http-addon-manifest-url')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('http-addon-add')), findsOneWidget);
    expect(find.text('Add music addon'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
