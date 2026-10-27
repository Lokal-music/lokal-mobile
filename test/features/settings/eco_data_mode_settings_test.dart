import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/features/settings/lokal/groups/data_group.dart';
import 'package:flick/features/settings/lokal/groups/online_sources_group.dart';
import 'package:flick/features/settings/widgets/eco_data_mode_toggle.dart';
import 'package:flick/services/playback_source_priority.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Eco Data Mode is under Data → Mobile data, not Online sources',
      (tester) async {
    late List<LokalSettingsSection> data;
    late List<LokalSettingsSection> online;

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          data = dataSettings(context, ref);
          online = onlineSourcesSettings(context, ref);
          return const SizedBox.shrink();
        }),
      ),
    ));

    final section = data.singleWhere((section) => section.title == 'Mobile data');
    expect(section.children, hasLength(1));
    expect(section.children.single, isA<EcoDataModeToggle>());
    expect(online.expand((section) => section.children)
        .whereType<EcoDataModeToggle>(), isEmpty);
    expect(online.expand((section) => section.children)
        .whereType<LokalSettingCustom>()
        .where((entry) => entry.label == 'Eco Data Mode'), isEmpty);
    expect(section.filtered('Eco Data Mode'), isNotNull,
        reason: 'The relocated control must remain searchable');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Eco Data Mode shows label, help text and a normal on/off pill',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: Consumer(
        builder: (context, ref, _) => MaterialApp(
          theme: LokalTheme.build(ref.watch(lokalAppearanceProvider).tokens),
          home: const Scaffold(body: EcoDataModeToggle()),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Eco Data Mode'), findsOneWidget);
    expect(find.textContaining('YouTube Music and SoundCloud'), findsOneWidget);
    expect(find.byType(Switch), findsNothing,
        reason: 'Use the standard Lokal settings style, not a lone OS switch');
    final row = tester.widget<LokalSettingRow>(
        find.byKey(const ValueKey('eco-data-mode-row')));
    expect(row.toggled, false);
    expect(find.byType(LokalOnOffPill), findsOneWidget);

    await tester.tap(find.text('Eco Data Mode'));
    await tester.pumpAndSettle();
    expect(await EcoDataMode.enabled(), isTrue);
    expect(tester.widget<LokalSettingRow>(
        find.byKey(const ValueKey('eco-data-mode-row'))).toggled, isTrue);

    await tester.tap(find.text('Eco Data Mode'));
    await tester.pumpAndSettle();
    expect(await EcoDataMode.enabled(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Eco Data Mode restores the enabled preference on screen load',
      (tester) async {
    SharedPreferences.setMockInitialValues({EcoDataMode.key: true});
    await tester.pumpWidget(ProviderScope(
      child: Consumer(
        builder: (context, ref, _) => MaterialApp(
          theme: LokalTheme.build(ref.watch(lokalAppearanceProvider).tokens),
          home: const Scaffold(body: EcoDataModeToggle()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<LokalSettingRow>(
        find.byKey(const ValueKey('eco-data-mode-row'))).toggled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
