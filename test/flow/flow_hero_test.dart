import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/flow/domain/flow_models.dart';
import 'package:flick/features/flow/flow_hero.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget heroApp({
  required LokalTokens tokens,
  required VoidCallback onPlay,
  required VoidCallback onSave,
  required VoidCallback onTune,
  bool playing = false,
}) => MaterialApp(
  theme: LokalTheme.build(tokens),
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(320, 650),
      disableAnimations: true,
    ),
    child: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FlowHero(
            mood: FlowMood.workout,
            count: 24,
            playing: playing,
            busy: false,
            enabled: true,
            onPlay: onPlay,
            onShuffle: () {},
            onSave: onSave,
            onTune: onTune,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('Flow hero uses every active Lokal theme surface', (tester) async {
    for (final id in LokalThemeId.values) {
      final tokens = LokalTokens.resolve(id);
      await tester.pumpWidget(
        heroApp(
          tokens: tokens,
          onPlay: () {},
          onSave: () {},
          onTune: () {},
        ),
      );
      await tester.pumpAndSettle();

      final root = tester.widget<Container>(
        find.descendant(
          of: find.byType(FlowHero),
          matching: find.byType(Container),
        ).first,
      );
      final decoration = root.decoration! as BoxDecoration;
      expect(decoration.color, tokens.surface2, reason: id.name);
      expect(decoration.border!.top.color, tokens.border, reason: id.name);
      final label = tester.widget<Text>(find.text('Flow · Workout'));
      expect(label.style!.color, tokens.text, reason: id.name);
      expect(find.byType(FlowInfinityOrb), findsOneWidget);
      expect(find.text('MADE FROM YOUR MUSIC'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Tune is at the top-right, not in the playback button row', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 650)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var tuneCalls = 0;
    var playCalls = 0;
    var saveCalls = 0;
    await tester.pumpWidget(
      heroApp(
        tokens: LokalTokens.resolve(LokalThemeId.dark),
        onPlay: () => playCalls++,
        onSave: () => saveCalls++,
        onTune: () => tuneCalls++,
      ),
    );
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(FlowHero));
    final tune = tester.getRect(find.byKey(const Key('flow-tune-button')));
    final play = tester.getRect(find.byKey(const Key('flow-play-button')));
    expect(tune.center.dx, greaterThan(card.center.dx));
    expect(tune.top, lessThan(play.top));
    expect(tune.right, lessThanOrEqualTo(card.right));
    expect(find.widgetWithText(OutlinedButton, 'Tune'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Save'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Shuffle'), findsOneWidget);

    await tester.tap(find.text('Tune'));
    await tester.pump();
    expect(tuneCalls, 1);
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(saveCalls, 1);
    await tester.tap(find.byType(FlowInfinityOrb));
    await tester.pump();
    expect(playCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion leaves the small infinity orb static', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 650)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      heroApp(
        tokens: LokalTokens.resolve(LokalThemeId.light),
        playing: true,
        onPlay: () {},
        onSave: () {},
        onTune: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FlowInfinityOrb), findsOneWidget);
    expect(find.bySemanticsLabel('Pause Flow'), findsOneWidget);
    expect(tester.getSize(find.byType(FlowInfinityOrb)).width, 88);
    expect(tester.takeException(), isNull);
  });
}
