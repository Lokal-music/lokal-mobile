import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/player/widgets/video_space_layout.dart';

class _PlayerMarker extends StatefulWidget {
  const _PlayerMarker({super.key, required this.onMount, required this.onTap});
  final VoidCallback onMount, onTap;
  @override
  State<_PlayerMarker> createState() => _PlayerMarkerState();
}

class _PlayerMarkerState extends State<_PlayerMarker> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    behavior: HitTestBehavior.opaque,
    child: const SizedBox.expand(),
  );
}

void main() {
  for (final size in [
    const Size(320, 280),
    const Size(393, 852),
    const Size(430, 932),
  ]) {
    testWidgets('Space leaves the embedded player unobstructed at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const player = ValueKey('player');
      const captions = ValueKey('captions');
      var playerTaps = 0, exits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(2),
              ),
              child: VideoSpaceLayout(
                player: _PlayerMarker(
                  key: player,
                  onMount: () {},
                  onTap: () => playerTaps++,
                ),
                subtitles: const Text('Current timed subtitle', key: captions),
                onExit: () => exits++,
                onOptions: () {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final videoBounds = tester.getRect(find.byKey(player));
      final subtitleBounds = tester.getRect(find.byKey(captions));
      expect(videoBounds.height, greaterThanOrEqualTo(200));
      expect(videoBounds.overlaps(subtitleBounds), false);
      await tester.tapAt(videoBounds.topLeft + const Offset(30, 30));
      expect(playerTaps, 1, reason: 'Video taps belong to the provider player');
      expect(exits, 0);
      final exit = find.byKey(const ValueKey('embedded-space-exit'));
      await tester.ensureVisible(exit);
      await tester.pump();
      await tester.tap(exit);
      expect(exits, 1);
    });
  }

  testWidgets(
    'Space reparents the same live player rather than restarting it',
    (tester) async {
      final key = GlobalKey();
      final space = ValueNotifier(false);
      addTearDown(space.dispose);
      var mounts = 0;
      Widget player() =>
          _PlayerMarker(key: key, onMount: () => mounts++, onTap: () {});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: space,
              builder: (_, active, __) => active
                  ? VideoSpaceLayout(
                      player: player(),
                      subtitles: const Text('Timed lyrics'),
                      onExit: () => space.value = false,
                      onOptions: () {},
                    )
                  : Center(
                      child: SizedBox(width: 300, height: 300, child: player()),
                    ),
            ),
          ),
        ),
      );
      final original = tester.state(find.byKey(key));
      space.value = true;
      await tester.pump();
      expect(tester.state(find.byKey(key)), same(original));
      space.value = false;
      await tester.pump();
      expect(tester.state(find.byKey(key)), same(original));
      expect(mounts, 1);
    },
  );
}
