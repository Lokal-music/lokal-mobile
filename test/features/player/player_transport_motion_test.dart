import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/player/widgets/player_transport_controls.dart';

void main() {
  testWidgets(
    'play morph reverses and transport resizes with the lyrics pose',
    (tester) async {
      var playing = false, l = 0.0;
      late StateSetter change;
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            lokalInitialAppearanceProvider.overrideWithValue(
              const LokalAppearance()),
          ],
          child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    change = setState;
                    return PlayerTransportControls(
                      playing: playing,
                      compact: false,
                      lyricsProgress: l,
                      accent: Colors.lime,
                      onAccent: Colors.black,
                      onPrevious: () {},
                      onNext: () {},
                      onPlayPause: () => setState(() => playing = !playing),
                    );
                  },
                ),
              ),
            ),
          ),
          ),
        ),
      );
      final controls = find.byType(PlayerTransportControls);
      expect(tester.getSize(controls).height, 82);
      final icon = () =>
          tester.widget<AnimatedIcon>(find.byType(AnimatedIcon)).progress.value;
      await tester.tap(find.byKey(const ValueKey('player-play-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(icon(), greaterThan(0));
      expect(icon(), lessThan(1));
      change(() {
        playing = false;
        l = .5;
      });
      await tester.pump();
      expect(tester.getSize(controls).height, 67);
      change(() => l = 1);
      await tester.pumpAndSettle();
      expect(tester.getSize(controls).height, 52);
      expect(icon(), 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('unboxed play/pause animates both ways without restoring a box',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var playing = false;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        lokalInitialAppearanceProvider.overrideWithValue(
          const LokalAppearance(unboxedPlayerControls: true)),
      ],
      child: MaterialApp(home: Scaffold(body: Center(child: SizedBox(
        width: 360,
        child: StatefulBuilder(builder: (context, setState) =>
            PlayerTransportControls(
          playing: playing, compact: false, lyricsProgress: 0,
          accent: Colors.white, onAccent: Colors.black,
          onPrevious: () {}, onNext: () {},
          onPlayPause: () => setState(() => playing = !playing),
        )),
      )))),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('apple-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('apple-pause')), findsNothing);
    expect(find.byType(AnimatedIcon), findsNothing);
    expect(find.byType(AnimatedSwitcher), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-play-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('apple-play')), findsOneWidget,
        reason: 'old play glyph remains visible during transition');
    expect(find.byKey(const ValueKey('apple-pause')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('apple-play')), findsNothing);
    expect(find.byKey(const ValueKey('apple-pause')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-play-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('apple-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('apple-pause')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('apple-pause')), findsNothing);
    expect(find.byKey(const ValueKey('apple-play')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Apple glyph centers follow the screenshot quarter-width layout',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(ProviderScope(
        overrides: [
          lokalInitialAppearanceProvider.overrideWithValue(
            const LokalAppearance(unboxedPlayerControls: true)),
        ],
        child: MaterialApp(home: Scaffold(body: Center(child: SizedBox(
          width: 360,
          child: PlayerTransportControls(
            playing: false, compact: false, lyricsProgress: 0,
            accent: Colors.white, onAccent: Colors.black,
            onPrevious: () {}, onNext: () {}, onPlayPause: () {},
          ),
        )))),
      ));
      await tester.pump();
      final bounds = tester.getRect(find.byType(PlayerTransportControls));
      final prev = tester.getCenter(find.byKey(const ValueKey('apple-skip-previous'))).dx;
      final play = tester.getCenter(find.byKey(const ValueKey('apple-play-pause'))).dx;
      final next = tester.getCenter(find.byKey(const ValueKey('apple-skip-next'))).dx;
      expect(prev, closeTo(bounds.left + bounds.width * .25, .1));
      expect(play, closeTo(bounds.left + bounds.width * .50, .1));
      expect(next, closeTo(bounds.left + bounds.width * .75, .1));
      expect(find.byType(AnimatedIcon), findsNothing);
    },
  );

}
