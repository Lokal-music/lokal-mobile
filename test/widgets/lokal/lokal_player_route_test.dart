import 'package:flick/widgets/lokal/lokal_player_route.dart';
import 'package:flick/widgets/lokal/lokal_pull_to_dismiss.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A screen with a "mini player" bar at [_miniTop] that a finger can pull up
/// into a [LokalPlayerRoute], as the dock's mini player does.
const _miniTop = 700.0;

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  LokalPlayerRoute<void>? route;
  LokalPlayerPull? pull;
  int closes = 0;
  bool? pulling;

  Widget _player(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: LokalPullToDismiss(
      onDismiss: () => Navigator.of(context).pop(),
      child: const Center(child: Text('now playing')),
    ),
  );

  void open({double? from}) {
    final pushed = LokalPlayerRoute<void>(
      builder: _player,
      startTop: () => _miniTop,
      initialProgress: from,
    );
    route = pushed;
    Navigator.of(context).push(pushed).then((_) => closes++);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: _miniTop,
          height: 60,
          child: GestureDetector(
            key: const ValueKey('mini'),
            behavior: HitTestBehavior.opaque,
            onTap: open,
            onVerticalDragUpdate: (d) {
              if (pulling == null) {
                pulling = d.delta.dy < 0;
                if (pulling!) {
                  pull = LokalPlayerPull.start(
                    Navigator.of(context),
                    builder: _player,
                    startTop: () => _miniTop,
                    onOpen: (progress) => open(from: progress),
                  );
                }
              }
              if (pulling!) pull?.dragBy(d.delta.dy);
            },
            onVerticalDragEnd: (d) {
              if (pulling ?? false) pull?.end(d.primaryVelocity ?? 0);
              pulling = null;
            },
            child: const ColoredBox(color: Colors.teal),
          ),
        ),
      ],
    ),
  );
}

void main() {
  test('all sheet corners shrink smoothly without a terminal snap', () {
    expect(LokalPlayerMotion.sheetCornerRadius(0), 36);
    expect(LokalPlayerMotion.sheetCornerRadius(.5), 18);
    expect(LokalPlayerMotion.sheetCornerRadius(.98), closeTo(.72, 1e-8));
    expect(LokalPlayerMotion.sheetCornerRadius(1), 0);
    expect(LokalPlayerMotion.sheetCornerRadius(1.01), 0);
  });

  testWidgets('the final frame keeps a four-corner clip', (tester) async {
    Future<ClipRRect> clipAt(double progress) async {
      await tester.pumpWidget(MaterialApp(
        home: LokalPlayerMotion.sheet(
          progress: progress,
          startTop: 500,
          child: const ColoredBox(color: Colors.black),
        ),
      ));
      return tester.widget<ClipRRect>(find.byType(ClipRRect).last);
    }

    final nearEnd = await clipAt(.99);
    expect(nearEnd.borderRadius,
        BorderRadius.circular(LokalPlayerMotion.sheetCornerRadius(.99)));
    expect(nearEnd.clipBehavior, Clip.antiAlias);

    final finished = await clipAt(1);
    expect(finished.borderRadius, BorderRadius.zero);
    expect(finished.clipBehavior, Clip.antiAlias,
        reason: 'Never drop clipping at the instant the sheet settles');
  });

  test('opening spring reaches the top without a slow final stall', () {
    final open = LokalPlayerMotion.simulation(0, 1, 0);
    final close = LokalPlayerMotion.simulation(1, 0, 0);
    expect(open.x(0), closeTo(0, .00001));
    expect(open.x(.20), greaterThan(0.87));
    expect(open.x(.40), greaterThan(0.99),
        reason: 'The old opening spring hovered below the top for too long');
    expect(open.isDone(.65), isTrue);
    expect(close.x(.20), greaterThan(0),
        reason: 'The closing spring remains independently tuned');
  });

  Future<_HomeState> pump(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(400, 800),
          disableAnimations: disableAnimations,
        ),
        child: const MaterialApp(home: _Home()),
      ),
    );
    return tester.state<_HomeState>(find.byType(_Home));
  }

  double sheetTop(WidgetTester tester) => tester
      .getTopLeft(
        find.ancestor(
          of: find.byType(LokalPullToDismiss),
          matching: find.byType(Scaffold),
        ),
      )
      .dy;

  testWidgets('pulling the mini player up opens Now Playing under the finger', (
    tester,
  ) async {
    final home = await pump(tester);
    final gesture = await tester.startGesture(const Offset(200, 720));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump();
    // The sheet's top edge rides with the finger, from the mini player up
    // (the drag slop aside); nothing is pushed while the finger is down.
    expect(home.route, isNull);
    final top = sheetTop(tester);
    expect(top, inInclusiveRange(_miniTop - 230, _miniTop - 190));
    await gesture.up();
    await tester.pump();
    // The overlay finishes its spring before handing over the same player
    // state. It must keep moving upwards throughout, without a handoff jump.
    var lastTop = top;
    for (var frame = 0; frame < 120 && home.route == null; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final nextTop = sheetTop(tester);
      expect(nextTop, lessThanOrEqualTo(lastTop + .1));
      lastTop = nextTop;
    }
    await tester.pumpAndSettle();
    expect(home.route!.progress, 1);
    expect(sheetTop(tester), 0);
  });

  testWidgets('a short pull up falls back into the mini player', (
    tester,
  ) async {
    final home = await pump(tester);
    await tester.timedDrag(
      find.byKey(const ValueKey('mini')),
      const Offset(0, -80),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(home.route, isNull);
    expect(find.text('now playing'), findsNothing);
  });

  testWidgets(
    'pulling Now Playing down sinks it into the mini player in one movement',
    (tester) async {
      final home = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('mini')));
      await tester.pumpAndSettle();
      final route = home.route!;
      expect(route.progress, 1);

      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 220));
      await tester.pump();
      // The finger moves the route itself: no separate sheet offset.
      expect(sheetTop(tester), closeTo(250, 25));
      expect(route.progress, closeTo(1 - 250 / _miniTop, .05));

      await gesture.up();
      // From there it carries on down without ever coming back up: one
      // movement, not a drop followed by a second slide.
      var last = route.progress;
      for (var frame = 0; frame < 120 && route.isActive; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (!route.isActive) break;
        expect(route.progress, lessThanOrEqualTo(last + 1e-9));
        last = route.progress;
      }
      await tester.pumpAndSettle();
      expect(home.closes, 1);
      expect(find.text('now playing'), findsNothing);
    },
  );

  testWidgets('a short pull down springs back open', (tester) async {
    final home = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('mini')));
    await tester.pumpAndSettle();
    await tester.timedDrag(
      find.text('now playing'),
      const Offset(0, 90),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(home.closes, 0);
    expect(home.route!.progress, 1);
    expect(sheetTop(tester), 0);
  });

  testWidgets('with reduced motion it follows the finger, then jumps', (
    tester,
  ) async {
    final home = await pump(tester, disableAnimations: true);
    final gesture = await tester.startGesture(const Offset(200, 720));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -250));
    await tester.pump();
    expect(sheetTop(tester), inInclusiveRange(_miniTop - 280, _miniTop - 240));
    await gesture.up();
    await tester.pump();
    expect(home.route!.progress, 1);
    await tester.pump();
    expect(sheetTop(tester), 0);

    await tester.timedDrag(
      find.text('now playing'),
      const Offset(0, 400),
      const Duration(seconds: 1),
    );
    await tester.pump();
    await tester.pump();
    expect(home.closes, 1);
  });
}
