import 'dart:ui' as ui;

import 'package:flick/features/player/widgets/full_bleed_artwork_frame.dart';
import 'package:flick/widgets/lokal/lokal_player_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Marker extends CustomPainter {
  const _Marker();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
    canvas.drawRect(
      Rect.fromCenter(center: size.center(Offset.zero), width: 80, height: 80),
      Paint()..color = Colors.red,
    );
  }

  @override
  bool shouldRepaint(_Marker old) => false;
}

void main() {
  testWidgets(
    'poster morph survives temporary lyrics/queue anchors returning twice',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      const source = Rect.fromLTWH(18, 710, 52, 52);
      Future<void> frame(double p, bool temporary) async {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                color: Colors.black,
                child: LokalPlayerMorph(
                  progress: p,
                  sheetOffset: (1 - p) * 700,
                  sourceArtwork: () => source,
                  child: Transform.translate(
                    offset: Offset(0, (1 - p) * 700),
                    child: Stack(
                      children: [
                        const FullBleedArtworkFrame(
                          canvas: false,
                          bannerBottom: 480,
                          child: CustomPaint(
                            key: ValueKey('poster'),
                            painter: _Marker(),
                          ),
                        ),
                        if (temporary)
                          const Positioned(
                            left: 10,
                            top: 500,
                            width: 52,
                            height: 52,
                            child: HeroMode(
                              enabled: false,
                              child: LokalPlayerArtwork(
                                child: ColoredBox(color: Colors.white),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      for (var visit = 0; visit < 2; visit++) {
        await frame(1, false);
        await frame(1, true); // Lyrics/queue compact cover.
        await frame(
          1,
          false,
        ); // Poster retained without reattaching/layout changes.
        await frame(.5, false);
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          // The original retained poster must be suppressed outside the traveling
          // cover, even after its temporary replacement was unregistered.
          final outside = (600 * image.width + 399) * 4;
          expect(
            data.getUint8(outside + 2) - data.getUint8(outside),
            lessThan(10),
          );
          final center = Rect.lerp(
            source,
            const Rect.fromLTWH(0, 0, 400, 480),
            .5,
          )!.center;
          final pixel =
              (center.dy.round() * image.width + center.dx.round()) * 4;
          expect(data.getUint8(pixel), greaterThan(150));
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'fullscreen cover reframes continuously without stretching or final square-crop snap',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      const source = Rect.fromLTWH(18, 710, 52, 52);
      for (final p in [1.0, .9, .5, .15, .001, 0.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                color: Colors.black,
                child: LokalPlayerMorph(
                  progress: p,
                  sheetOffset: (1 - p) * 700,
                  sourceArtwork: () => source,
                  child: Transform.translate(
                    offset: Offset(0, (1 - p) * 700),
                    child: const FullBleedArtworkFrame(
                      canvas: false,
                      bannerBottom: 480,
                      child: CustomPaint(
                        key: ValueKey('poster'),
                        painter: _Marker(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final viewport = Size.lerp(source.size, const Size(400, 480), p)!;
        expect(
          tester.getSize(find.byKey(const ValueKey('poster'))).height,
          closeTo(400 * viewport.height / viewport.width, .001),
        );
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var left = image.width, right = -1, top = image.height, bottom = -1;
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < image.width; x++) {
              final i = (y * image.width + x) * 4;
              if (data.getUint8(i) > 180 && data.getUint8(i + 2) < 80) {
                if (x < left) left = x;
                if (x > right) right = x;
                if (y < top) top = y;
                if (y > bottom) bottom = y;
              }
            }
          }
          expect(right, greaterThan(left));
          expect(
            (right - left - (bottom - top)).abs(),
            lessThanOrEqualTo(1),
            reason: 'Square marker remains square at p=$p',
          );
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }
    },
  );
}
