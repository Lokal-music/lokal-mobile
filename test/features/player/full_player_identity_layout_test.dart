import 'package:flick/features/player/widgets/full_player_identity_layout.dart';
import 'package:flick/widgets/common/overflow_marquee_title.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('quality badge stays at the same height for different titles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var longTitle = false;
    var credit = 'Black Eyed Peas';
    var quality = 'LOSSLESS';
    late StateSetter change;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                return FullPlayerIdentityLayout(
                  titleFontSize: 29,
                  titleToArtistGap: 3,
                  title: OverflowMarqueeTitle(
                    title: longTitle
                        ? 'Let\'s Get It Started - Spike Mix - Extra Long Extended Edit'
                        : 'ATTENTION',
                    style: const TextStyle(fontSize: 29, fontWeight: FontWeight.w700),
                  ),
                  artist: Text(
                    credit,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: [
                    const SizedBox(width: 12),
                    DecoratedBox(
                      key: const ValueKey('quality-tag'),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3,
                        ),
                        child: Text(quality, style: const TextStyle(fontSize: 9)),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(find.byKey(const ValueKey('quality-tag'))).dy;
    final initialInfoHeight = tester.getSize(find.byType(FullPlayerIdentityLayout)).height;

    change(() {
      longTitle = true;
      credit = 'veggi, Lowgo, Chloe Florence';
      quality = 'HI-RES LOSSLESS';
    });
    await tester.pumpAndSettle();
    final second = tester.getTopLeft(find.byKey(const ValueKey('quality-tag'))).dy;
    expect(second, closeTo(first, .01));
    expect(
      tester.getSize(find.byType(FullPlayerIdentityLayout)).height,
      closeTo(initialInfoHeight, .01),
      reason: 'The whole info panel must not reflow during a swipe',
    );

    change(() {
      longTitle = false;
      credit = 'Denzel Curry';
      quality = 'HIGH';
    });
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('quality-tag'))).dy,
      closeTo(first, .01),
    );
    expect(tester.takeException(), isNull);
    // Retire the overflow marquee and drain its already scheduled pause.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('metadata slot also scales with accessibility text', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: FullPlayerIdentityLayout(
                titleFontSize: 29,
                titleToArtistGap: 3,
                title: Text('A title'),
                artist: Text('Artist'),
                trailing: [Text('LOSSLESS')],
              ),
            ),
          ),
        ),
      ),
    ));
    expect(
      tester.getSize(find.byType(FullPlayerIdentityLayout)).height,
      greaterThan(80),
    );
    expect(tester.takeException(), isNull);
  });
}
