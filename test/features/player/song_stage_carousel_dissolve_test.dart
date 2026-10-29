import 'package:flick/features/player/widgets/cloud_cover_reveal.dart';
import 'package:flick/features/player/widgets/song_stage_carousel.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const tracks = [
  Song(id: 'a', title: 'First', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC'),
  Song(id: 'b', title: 'Second', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC'),
  Song(id: 'c', title: 'Third', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC'),
];

void main() {
  test('cloud mask mirrors desktop stagger and soft radial alpha gradients', () {
    final a = createCloudCoverBlobs(42);
    final b = createCloudCoverBlobs(42);
    expect(a, hasLength(14));
    expect(a.map((v) => v.x), b.map((v) => v.x));
    expect(a.map((v) => v.delay), b.map((v) => v.delay));
    expect(a.every((v) => v.size >= .30 && v.size <= .64), isTrue);
    expect(cloudCoverBlur(0), closeTo(16, .001));
    expect(cloudCoverBlur(.88), closeTo(0, .001));

    final one = [const CloudCoverBlob(.5, .5, 0, .4)];
    // The first appearance is transparent. The blob core is fully opaque,
    // with a gradual, non-binary falloff at its edge.
    expect(cloudCoverAlphaAt(one, 0, .5, .5), 0);
    expect(cloudCoverAlphaAt(one, .5, .5, .5), 1);
    final p = .5;
    final radius = .4 * (
      .65 * (1 - (1 - p) * (1 - p) * (1 - p)) +
      .35 * (4 * p * p * p)
    );
    expect(cloudCoverAlphaAt(one, p, .5 + radius * .575, .5),
        closeTo(.8, .001)); // Between desktop 45% and 70% stops
    expect(cloudCoverAlphaAt(one, p, .5 + radius * .85, .5),
        closeTo(.3, .001)); // Feathered outer 30% (not a clipped oval)
    expect(cloudCoverAlphaAt(one, p, 0, 0), 0);

    // The last 18% uses uniform translucency over *every pixel*, not a
    // rapidly expanding central ellipse that leaves cut-off corners.
    expect(cloudCoverAlphaAt(one, .82, 0, 0), 0);
    expect(cloudCoverAlphaAt(one, .91, 0, 0), closeTo(.5, .001));
    expect(cloudCoverAlphaAt(one, 1, 0, 0), 1);
    expect(cloudCoverAlphaAt(a, 1, 1, 1), 1);
  });

  test('cloud blobs are circles in portrait, landscape and square covers', () {
    const single = [CloudCoverBlob(.5, .5, 0, .4)];
    const progress = .5;
    const distancePx = 80.0;
    final sizes = [
      const Size(350, 350), // Regular cover
      const Size(350, 740), // Fullscreen portrait cover
      const Size(740, 350), // Landscape artwork
    ];
    double? squareAlpha;
    for (final size in sizes) {
      final horizontal = cloudCoverAlphaAt(
        single, progress, .5 + distancePx / size.width, .5, size: size,
      );
      final vertical = cloudCoverAlphaAt(
        single, progress, .5, .5 + distancePx / size.height, size: size,
      );
      expect(horizontal, greaterThan(0));
      expect(horizontal, lessThan(1));
      expect(vertical, closeTo(horizontal, 0.000001),
          reason: 'A physical circle has the same alpha at equal pixel distances, '
              'regardless of artwork aspect ratio: $size');
      squareAlpha ??= horizontal;
      expect(horizontal, closeTo(squareAlpha, 0.000001),
          reason: 'The radius is based on the shortest side, not stretched');
    }

    // A normalized Y offset represents more pixels than the same normalized
    // X offset on a tall canvas. This would be equal for the old oval mask.
    const portrait = Size(350, 740);
    final sameUvX = cloudCoverAlphaAt(
      single, progress, .6, .5, size: portrait,
    );
    final sameUvY = cloudCoverAlphaAt(
      single, progress, .5, .6, size: portrait,
    );
    expect(sameUvY, lessThan(sameUvX));
  });

  Future<GlobalKey<SongStageCarouselState>> mount(
    WidgetTester tester, {
    required void Function(int) changed,
    bool buttonDissolve = true,
    bool animate = true,
    bool maskOutgoingOnDissolve = false,
    double height = 320,
    int initial = 0,
  }) async {
    final key = GlobalKey<SongStageCarouselState>();
    var index = initial;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(
          width: 320,
          height: height,
          child: StatefulBuilder(
            builder: (context, update) => SongStageCarousel(
              key: key,
              currentSong: tracks[index],
              prevSong: index == 0 ? null : tracks[index - 1],
              nextSong: index == tracks.length - 1 ? null : tracks[index + 1],
              buttonDissolve: buttonDissolve,
              animateButtonDissolve: animate,
              maskOutgoingOnDissolve: maskOutgoingOnDissolve,
              onNext: () async {
                if (index == tracks.length - 1) return;
                update(() => index++);
                changed(index);
              },
              onPrevious: () async {
                if (index == 0) return;
                update(() => index--);
                changed(index);
              },
              stageBuilder: (song) => ColoredBox(
                key: ValueKey('art-${song.id}'),
                color: switch (song.id) {
                  'a' => Colors.red,
                  'b' => Colors.green,
                  _ => Colors.blue,
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        )),
      ),
    ));
    return key;
  }

  testWidgets('next and previous buttons reveal without sliding', (tester) async {
    var current = 0;
    final key = await mount(tester, changed: (i) => current = i);
    await key.currentState!.animateToNext();
    await tester.pump();
    expect(current, 1);
    expect(find.byType(CloudCoverReveal), findsOneWidget);
    expect(find.byKey(const ValueKey('art-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('art-b')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.byType(CloudCoverReveal), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump();
    expect(find.byType(CloudCoverReveal), findsNothing);

    await key.currentState!.animateToPrevious();
    await tester.pump();
    expect(current, 0);
    expect(find.byType(CloudCoverReveal), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2400));
    await tester.pump();
    expect(find.byType(CloudCoverReveal), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('outgoing mask is the complement of the incoming fullscreen reveal', () {
    final blobs = createCloudCoverBlobs(812);
    const portrait = Size(350, 740);
    // Verify the lower banner/centre and all edges, not only the cloud cores.
    // The old cover must no longer become invisible in one abrupt final frame.
    for (final p in [0.0, .25, .5, .82, .9, .99, 1.0]) {
      for (final x in [0.0, .25, .5, .75, 1.0]) {
        for (final y in [0.0, .4, .7, 1.0]) {
          final incoming = cloudCoverAlphaAt(
            blobs, p, x, y, size: portrait,
          );
          final outgoing = cloudCoverAlphaAt(
            blobs, p, x, y, size: portrait, inverted: true,
          );
          expect(incoming + outgoing, closeTo(1, .000001));
          if (p == 1) expect(outgoing, 0);
          if (p == .99) {
            expect(outgoing, lessThan(.057),
                reason: 'No previous-cover rectangle may survive the last frame');
          }
        }
      }
    }
  });

  testWidgets('fullscreen cover dissolves outgoing art before its final unmount',
      (tester) async {
    var current = 0;
    final key = await mount(
      tester,
      changed: (i) => current = i,
      maskOutgoingOnDissolve: true,
      height: 700, // Tall full-bleed banner, not a square sleeve
    );
    await key.currentState!.animateToNext();
    await tester.pump();
    expect(current, 1);
    final outgoing = find.ancestor(
      of: find.byKey(const ValueKey('art-a')),
      matching: find.byType(CloudCoverReveal),
    );
    final incoming = find.ancestor(
      of: find.byKey(const ValueKey('art-b')),
      matching: find.byType(CloudCoverReveal),
    );
    expect(outgoing, findsOneWidget);
    expect(incoming, findsOneWidget);
    expect(tester.widget<CloudCoverReveal>(outgoing).inverted, isTrue);
    expect(tester.widget<CloudCoverReveal>(outgoing).blur, isFalse);
    expect(tester.widget<CloudCoverReveal>(incoming).inverted, isFalse);

    await tester.pump(const Duration(milliseconds: 2300));
    // The outgoing widget is still mounted, but its *mask* is almost fully
    // transparent rather than showing a solid rectangle until teardown.
    expect(outgoing, findsOneWidget);
    final outgoingMask = tester.widget<CloudCoverReveal>(outgoing);
    expect(outgoingMask.inverted, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.byKey(const ValueKey('art-a')), findsNothing);
    expect(find.byType(CloudCoverReveal), findsNothing);
    expect(find.byKey(const ValueKey('art-b')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid button skips retire the old outgoing cover', (tester) async {
    var current = 0;
    final key = await mount(tester, changed: (i) => current = i);
    await key.currentState!.animateToNext();
    await tester.pump(const Duration(milliseconds: 250));
    await key.currentState!.animateToNext();
    await tester.pump();
    expect(current, 2);
    expect(find.byKey(const ValueKey('art-a')), findsNothing);
    expect(find.byKey(const ValueKey('art-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('art-c')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2400));
    await tester.pump();
    expect(find.byType(CloudCoverReveal), findsNothing);
  });

  testWidgets('drag still slides, never invokes cloud reveal', (tester) async {
    var current = 0;
    await mount(tester, changed: (i) => current = i);
    await tester.drag(
      find.byType(SongStageCarousel),
      const Offset(-270, 0),
    );
    await tester.pumpAndSettle();
    expect(current, 1);
    expect(find.byType(CloudCoverReveal), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled animation switches immediately without button slide',
      (tester) async {
    var current = 0;
    final key = await mount(
      tester,
      changed: (i) => current = i,
      animate: false,
    );
    await key.currentState!.animateToNext();
    await tester.pump();
    expect(current, 1);
    expect(find.byType(CloudCoverReveal), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('end-of-queue next does not arm a later unrelated transition',
      (tester) async {
    var current = 2;
    final key = await mount(
      tester, changed: (i) => current = i, initial: 2,
    );
    await key.currentState!.animateToNext();
    await tester.pump();
    expect(current, 2); // No track-change callback was issued.
    expect(find.byType(CloudCoverReveal), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
