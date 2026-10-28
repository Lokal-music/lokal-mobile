import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_destination.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/features/settings/lokal/lokal_settings_page.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home) => ProviderScope(
  child: Consumer(
    builder: (context, ref, _) => MaterialApp(
      theme: LokalTheme.build(ref.watch(lokalAppearanceProvider).tokens),
      home: home,
    ),
  ),
);

Widget _page(List<Widget> children) => Scaffold(
  body: ListView(
    children: [LokalSettingsSection(title: 'Test', children: children)],
  ),
);

/// Two small groups standing in for the real ones, which read the player.
List<LokalSettingsSection> _fakeSections(
  LokalSettingsGroup group,
  BuildContext context,
  WidgetRef ref,
) => switch (group) {
  LokalSettingsGroup.playback => [
    LokalSettingsSection(
      title: 'Song transitions',
      children: [
        LokalSettingRow.toggle(
          label: 'Crossfade',
          description: 'Start the next song before the current one ends.',
          value: false,
          onChanged: (_) {},
        ),
        LokalSettingRow.toggle(
          label: 'Gapless playback',
          description: 'No silence between songs.',
          value: true,
          onChanged: (_) {},
        ),
      ],
    ),
    for (final title in ['Queue', 'Play from', 'Equalizer'])
      LokalSettingsSection(
        title: title,
        children: [
          LokalSettingRow(label: '$title row', description: 'Filler'),
          LokalSettingRow(label: '$title second', description: 'Filler'),
          LokalSettingRow(label: '$title third', description: 'Filler'),
        ],
      ),
    LokalSettingsSection(
      title: 'Lyrics',
      children: [
        LokalSettingRow.toggle(
          label: 'Fetch lyrics automatically',
          description: 'Look for lyrics online.',
          value: true,
          onChanged: (_) {},
        ),
      ],
    ),
  ],
  LokalSettingsGroup.appearance => [
    LokalSettingsSection(
      title: 'Interface',
      children: [
        LokalSettingRow.toggle(
          label: 'Haptics',
          description: 'A light tap under your finger.',
          value: true,
          onChanged: (_) {},
        ),
      ],
    ),
  ],
  _ => const [],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a toggle row flips its DM Mono pill and reads as a switch', (
    tester,
  ) async {
    var value = false;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => _page([
            LokalSettingRow.toggle(
              label: 'Gapless playback',
              description: 'No silence between songs.',
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ]),
        ),
      ),
    );
    expect(find.text('OFF'), findsOneWidget);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('Gapless playback')),
      isSemantics(hasToggledState: true, isToggled: false),
    );
    await tester.tap(find.text('Gapless playback'));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(find.text('ON'), findsOneWidget);
    final on = tester.widget<Text>(find.text('ON'));
    expect(on.style?.fontFamily, LokalTheme.mono);
    handle.dispose();
  });

  testWidgets('settings pages are solid theme surfaces, never a blur', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const LokalSettingsPage(sectionsBuilder: _fakeSections)),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(LokalSettingsPage));
    final t = Theme.of(context).extension<LokalTokens>()!;
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester
          .widget<Scaffold>(
            find.descendant(
              of: find.byType(LokalSettingsPage),
              matching: find.byType(Scaffold),
            ),
          )
          .backgroundColor,
      t.bg,
    );
    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(LokalSettingsCard),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((card.decoration! as BoxDecoration).color, t.surface);

    await tester.pumpWidget(
      _app(
        LokalSettingsScaffold(
          title: 'Sub-page',
          children: [
            LokalSettingsSection(
              title: 'Rows',
              children: [LokalSettingRow(label: 'A row')],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('Sub-page'), findsOneWidget);
    expect(find.text('A row'), findsOneWidget);
  });

  testWidgets('a disabled row ignores taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        _page([
          LokalSettingRow.toggle(
            label: 'Crossfade',
            value: false,
            enabled: false,
            onChanged: (_) => taps++,
          ),
        ]),
      ),
    );
    await tester.tap(find.text('Crossfade'));
    expect(taps, 0);
  });

  testWidgets('segmented control picks a value', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _app(
        _page([
          LokalSettingRow(
            label: 'ReplayGain',
            trailing: LokalSegmented<String>(
              segments: const [
                LokalSegment('off', 'Off'),
                LokalSegment('track', 'Track'),
                LokalSegment('album', 'Album'),
              ],
              value: 'off',
              onChanged: (v) => picked = v,
            ),
          ),
        ]),
      ),
    );
    await tester.tap(find.text('Album'));
    expect(picked, 'album');
    picked = null;
    await tester.tap(find.text('Off'));
    expect(picked, isNull, reason: 'the selected segment does nothing');
  });

  testWidgets('slider saves once the finger lets go', (tester) async {
    final saved = <double>[];
    await tester.pumpWidget(
      _app(
        _page([
          LokalSettingSlider(
            label: 'Crossfade length',
            value: 2,
            min: 0,
            max: 10,
            divisions: 10,
            valueLabel: (v) => '${v.round()} s',
            onChanged: saved.add,
          ),
        ]),
      ),
    );
    expect(find.text('2 s'), findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Slider)),
    );
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(saved, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(saved, hasLength(1));
  });

  testWidgets('choice row opens a sheet and picks', (tester) async {
    int? picked;
    await tester.pumpWidget(
      _app(
        _page([
          LokalSettingChoice<int>(
            label: 'Fade curve',
            options: const [
              LokalSegment(0, 'Equal power'),
              LokalSegment(1, 'Linear'),
              LokalSegment(2, 'Square root'),
              LokalSegment(3, 'S-curve'),
            ],
            value: 0,
            onChanged: (v) => picked = v,
          ),
        ]),
      ),
    );
    expect(find.text('EQUAL POWER'), findsOneWidget);
    await tester.tap(find.text('Fade curve'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('S-curve'));
    await tester.pumpAndSettle();
    expect(picked, 3);
  });

  test('sections filter by title, label and description', () {
    final section = LokalSettingsSection(
      title: 'Lyrics',
      children: [
        LokalSettingRow(label: 'Word-by-word sync', description: 'Karaoke'),
        const LokalSettingCustom(
          label: 'Last.fm',
          description: 'Scrobble what you play',
          child: SizedBox(),
        ),
        const SizedBox(),
      ],
    );
    expect(section.filtered('LYRICS'), same(section));
    expect(section.filtered('karaoke')!.children, hasLength(1));
    expect(
      section.filtered('scrobble')!.children.single,
      isA<LokalSettingCustom>(),
    );
    expect(section.filtered('nothing like this'), isNull);
    expect(section.filtered('')!.children, hasLength(3));
  });

  testWidgets('settings search filters rows across groups', (tester) async {
    await tester.pumpWidget(
      _app(const LokalSettingsPage(sectionsBuilder: _fakeSections)),
    );
    expect(find.text('Settings'), findsOneWidget);
    for (final group in LokalSettingsGroup.listed) {
      expect(find.text(group.label), findsOneWidget);
    }
    expect(find.text('Gapless playback'), findsNothing);

    await tester.enterText(find.byType(TextField), 'crossfade');
    await tester.pumpAndSettle();
    expect(find.text('Crossfade'), findsOneWidget);
    expect(find.text('Gapless playback'), findsNothing);
    expect(find.text('PLAYBACK · SONG TRANSITIONS'), findsOneWidget);
    expect(find.text('Online sources'), findsNothing);

    await tester.enterText(find.byType(TextField), 'finger');
    await tester.pumpAndSettle();
    expect(find.text('Haptics'), findsOneWidget);
    expect(find.text('APPEARANCE · INTERFACE'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'qwertyuiop');
    await tester.pumpAndSettle();
    expect(find.text('No settings match your search.'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Online sources'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a group opens scrolled to its section', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        const LokalSettingsGroupPage(
          group: LokalSettingsGroup.playback,
          section: 'Lyrics',
          sectionsBuilder: _fakeSections,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Playback'), findsOneWidget);
    final row = tester.getRect(find.text('Fetch lyrics automatically'));
    expect(row.bottom, lessThanOrEqualTo(700));
    expect(row.top, greaterThanOrEqualTo(0));
  });

  test('settings is one destination, with an optional group and section', () {
    const lyrics = KonnektedDestination.settingsAt(
      LokalSettingsGroup.playback,
      section: 'Lyrics',
    );
    expect(lyrics.isSettings, isTrue);
    expect(lyrics.name, KonnektedDestination.settings.name);
    expect(
      lyrics,
      const KonnektedDestination.settingsAt(
        LokalSettingsGroup.playback,
        section: 'Lyrics',
      ),
    );
    expect(lyrics, isNot(KonnektedDestination.settings));
    expect(LokalSettingsGroup.listed.map((g) => g.label), [
      'Online sources',
      'Playback',
      'Advanced output',
      'Library',
      'Appearance',
      'Data',
    ]);
    expect(LokalSettingsGroup.output.parent, isNull);
  });
}
