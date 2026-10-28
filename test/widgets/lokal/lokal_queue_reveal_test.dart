import 'package:flick/features/queue/screens/queue_screen.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/widgets/lokal/lokal_pull_to_dismiss.dart';
import 'package:flick/widgets/lokal/lokal_queue_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _EmbeddedPlayer extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final AnimationController progress = AnimationController(vsync: this);
  late final LokalQueueRevealMotion motion = LokalQueueRevealMotion(progress)
    ..travel = 300
    ..addListener(() => setState(() {}));
  final pulls = <double>[];

  bool get animate => !MediaQuery.disableAnimationsOf(context);

  @override
  void dispose() {
    motion.dispose();
    progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () => motion.toggle(animate: animate),
            child: const Text('queue'),
          ),
          Expanded(
            child: LokalPullToDismiss(
              onDismiss: () {},
              onPullUpUpdate: motion.dragBy,
              onPullUpEnd: (v) => motion.release(v, animate: animate),
              isBlocked: () => motion.engaged,
              child: LokalQueueReveal(
                progress: progress,
                open: motion.isOpen,
                onHeaderTap: () => motion.setOpen(false, animate: animate),
                onHeaderDragUpdate: motion.dragBy,
                onHeaderDragEnd: (v) => motion.release(v, animate: animate),
                artwork: (context, size, p) => Align(
                  alignment: LokalQueueReveal.coverAlignment(p),
                  child: SizedBox(
                    key: const ValueKey('cover'),
                    width: size,
                    height: size,
                    child: const ColoredBox(color: Colors.purple),
                  ),
                ),
                info: (context, p) => const Text('Title'),
                badge: const Text('Hi-Res'),
                queue: ListView(
                  children: [
                    for (var i = 0; i < 20; i++)
                      ListTile(title: Text('Track $i')),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void main() {
  Future<_HarnessState> pump(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(400, 800),
          disableAnimations: disableAnimations,
        ),
        child: const MaterialApp(home: _Harness()),
      ),
    );
    return tester.state<_HarnessState>(find.byType(_Harness));
  }

  Size cover(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey('cover')));

  testWidgets('tapping the queue button shrinks the cover into the header', (
    tester,
  ) async {
    final h = await pump(tester);
    expect(cover(tester).width, 400);
    expect(find.text('Track 0'), findsNothing);

    await tester.tap(find.text('queue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // Mid-flight: one continuous value, not a page swap.
    expect(h.progress.value, inExclusiveRange(0, 1));
    expect(cover(tester).width, inExclusiveRange(56, 400));

    await tester.pumpAndSettle();
    expect(h.progress.value, 1);
    expect(cover(tester).width, 56);
    expect(tester.getTopLeft(find.byKey(const ValueKey('cover'))).dx, 0);
    expect(find.text('Track 0').hitTestable(), findsOneWidget);

    // The same button reverses it.
    await tester.tap(find.text('queue'));
    await tester.pumpAndSettle();
    expect(h.progress.value, 0);
    expect(cover(tester).width, 400);
    expect(find.text('Track 0'), findsNothing);
  });

  testWidgets('a pull up follows the finger and carries past 30%', (
    tester,
  ) async {
    final h = await pump(tester);
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(h.progress.value, closeTo(80 / 300, .07));
    expect(h.motion.isOpen, isFalse);
    // Not interactive while only being dragged in.
    expect(find.text('Track 0').hitTestable(), findsNothing);

    await gesture.moveBy(const Offset(0, -40));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.motion.isOpen, isTrue);
    expect(h.progress.value, 1);
  });

  testWidgets('a short slow pull falls back to the player', (tester) async {
    final h = await pump(tester);
    await tester.timedDrag(
      find.byKey(const ValueKey('cover')),
      const Offset(0, -60),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(h.motion.isOpen, isFalse);
    expect(h.progress.value, 0);
  });

  testWidgets('dragging the header down or tapping it puts the queue away', (
    tester,
  ) async {
    final h = await pump(tester);
    await tester.tap(find.text('queue'));
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('lokal-queue-reveal-header'));

    final gesture = await tester.startGesture(tester.getCenter(header));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    expect(h.progress.value, lessThan(1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.motion.isOpen, isFalse);
    expect(h.progress.value, 0);

    await tester.tap(find.text('queue'));
    await tester.pumpAndSettle();
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(h.progress.value, 0);
  });

  testWidgets('after a drag puts the queue away, a pull up opens it again', (
    tester,
  ) async {
    final h = await pump(tester);
    Future<void> pullUp() async {
      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(0, -20));
      await gesture.moveBy(const Offset(0, -150));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    final header = find.byKey(const ValueKey('lokal-queue-reveal-header'));
    for (var round = 0; round < 3; round++) {
      await pullUp();
      expect(h.motion.isOpen, isTrue, reason: 'round $round');
      expect(h.progress.value, 1);

      // A quick swipe down, as a thumb puts it away.
      await tester.fling(header, const Offset(0, 160), 1400);
      await tester.pumpAndSettle();
      expect(h.motion.isOpen, isFalse, reason: 'round $round');
      expect(h.progress.value, 0);
    }
  });

  testWidgets('the queue list still scrolls while it is open', (tester) async {
    final h = await pump(tester);
    await tester.tap(find.text('queue'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Track 3'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(h.progress.value, 1);
    expect(find.text('Track 0').hitTestable(), findsNothing);
  });

  testWidgets('with animations disabled it jumps straight to either end', (
    tester,
  ) async {
    final h = await pump(tester, disableAnimations: true);
    await tester.tap(find.text('queue'));
    await tester.pump();
    expect(h.progress.value, 1);
    expect(h.progress.isAnimating, isFalse);
    await tester.tap(find.text('queue'));
    await tester.pump();
    expect(h.progress.value, 0);
  });

  testWidgets('a spring always lands exactly at either end', (tester) async {
    // A settled spring stops within a tolerance of its target; anything
    // left over (0.0004 open) kept the sheet's pull-up blocked for good.
    final c = AnimationController(vsync: tester);
    final m = LokalQueueRevealMotion(c)..travel = 287;
    final misses = <String>[];
    for (final start in [.12, .31, .5, .77, .93]) {
      for (final velocity in [-1400.0, -600.0, -120.0, 0.0, 300.0, 900.0]) {
        for (final open in [false, true]) {
          m.setOpen(!open, animate: false);
          c.value = start;
          m.setOpen(open, velocity: velocity / m.travel);
          for (var frame = 0; frame < 300 && c.isAnimating; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          if (c.value != (open ? 1.0 : 0.0)) {
            misses.add('$start $velocity $open → ${c.value}');
          }
        }
      }
    }
    expect(misses, isEmpty);
    m.dispose();
    c.dispose();
  });

  test('a flick decides on its own, either way', () {
    final c = AnimationController(vsync: const TestVSync());
    final m = LokalQueueRevealMotion(c)..travel = 300;
    m.dragBy(10);
    expect(m.release(900, animate: false), isTrue);
    expect(c.value, 1);
    m.dragBy(-10);
    expect(m.release(-900, animate: false), isFalse);
    expect(c.value, 0);
    // Open, a small pull down stays open.
    m.setOpen(true, animate: false);
    m.dragBy(-60);
    expect(m.release(0, animate: false), isTrue);
    m.dispose();
    c.dispose();
  });

  testWidgets(
    'embedded, the queue drops its back button and now playing card',
    (tester) async {
      Song song(String id) => Song(
        id: id,
        title: 'Song $id',
        artist: 'Artist',
        duration: const Duration(minutes: 3),
        fileType: 'FLAC',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerProvider.overrideWith(_EmbeddedPlayer.new),
            currentSongProvider.overrideWithValue(song('now')),
            upNextProvider.overrideWithValue([song('a'), song('b'), song('q')]),
            queueProvider.overrideWithValue([song('q')]),
            autoplayUpNextProvider.overrideWithValue(const []),
          ],
          child: const MaterialApp(
            home: Scaffold(body: QueueList(embedded: true)),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Song a'), findsOneWidget);
      expect(find.text('Song b'), findsOneWidget);
      expect(find.text('Song q'), findsOneWidget);
      expect(find.text('Song now'), findsNothing);
      expect(
        find.byType(ReorderableDelayedDragStartListener),
        findsNWidgets(3),
      );
    },
  );
}
