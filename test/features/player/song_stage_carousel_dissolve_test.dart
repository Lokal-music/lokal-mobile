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
  test('cloud reveal geometry is seeded, bounded, and completes seamlessly', () {
    final a = createCloudCoverBlobs(42);
    final b = createCloudCoverBlobs(42);
    expect(a, hasLength(14));
    expect(a.map((v) => v.x), b.map((v) => v.x));
    final bounds = const Size(360, 720);
    expect(CloudCoverClipper(0, a).revealPath(bounds)
        .contains(const Offset(180, 360)), isFalse);
    expect(CloudCoverClipper(.5, a).revealPath(bounds).getBounds().isEmpty,
        isFalse);
    final nearEnd = CloudCoverClipper(.995, a).revealPath(bounds);
    expect(nearEnd.contains(const Offset(0, 0)), isTrue);
    expect(nearEnd.contains(const Offset(359, 719)), isTrue);
    final end = CloudCoverClipper(1, a).revealPath(bounds);
    expect(end.contains(const Offset(359, 719)), isTrue);
    expect(end.getBounds(), Offset.zero & bounds);
  });

  Future<GlobalKey<SongStageCarouselState>> mount(
    WidgetTester tester, {
    required void Function(int) changed,
    bool buttonDissolve = true,
    bool animate = true,
    int initial = 0,
  }) async {
    final key = GlobalKey<SongStageCarouselState>();
    var index = initial;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(
          width: 320,
          height: 320,
          child: StatefulBuilder(
            builder: (context, update) => SongStageCarousel(
              key: key,
              currentSong: tracks[index],
              prevSong: index == 0 ? null : tracks[index - 1],
              nextSong: index == tracks.length - 1 ? null : tracks[index + 1],
              buttonDissolve: buttonDissolve,
              animateButtonDissolve: animate,
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
    var current = 0;
    final key = await mount(
      tester, changed: (i) => current = i, initial: 2,
    );
    await key.currentState!.animateToNext();
    await tester.pump();
    expect(current, 0); // No track-change callback was issued.
    expect(find.byType(CloudCoverReveal), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
