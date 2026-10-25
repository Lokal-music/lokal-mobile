import 'dart:ui' as ui;

import 'package:flick/widgets/lokal/lokal_player_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('repaint boundary does not retain stale Canvas chrome after settling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final capture = GlobalKey();
    var progress = .5;
    late StateSetter update;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          final slide = (1 - progress) * 700;
          return RepaintBoundary(
            key: capture,
            child: ColoredBox(
              color: Colors.black,
              child: LokalPlayerMorph(
                progress: progress,
                sheetOffset: slide,
                sourceArtwork: () => const Rect.fromLTWH(10, 700, 52, 52),
                child: Transform.translate(
                  offset: Offset(0, slide),
                  child: Stack(children: [
                    const Positioned.fill(child: LokalPlayerArtwork(
                      expandedRadius: 0,
                      child: ColoredBox(color: Colors.red),
                    )),
                    Positioned(
                      left: 20,
                      top: 200,
                      child: RepaintBoundary(
                        child: LokalPlayerChrome(
                          child: const SizedBox(
                            width: 120,
                            height: 90,
                            child: ColoredBox(color: Colors.green),
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    ));

    Future<Color> sample(int px, int py) async {
      await tester.pump();
      final image = await (capture.currentContext!.findRenderObject()
          as RenderRepaintBoundary).toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final index = (py * image.width + px) * 4;
      final color = Color.fromARGB(
        bytes.getUint8(index + 3),
        bytes.getUint8(index),
        bytes.getUint8(index + 1),
        bytes.getUint8(index + 2),
      );
      image.dispose();
      return color;
    }

    final halfway = await sample(65, 565);
    expect(halfway.g, greaterThan(halfway.r));
    update(() => progress = 1);
    final settled = await sample(65, 240);
    expect(settled.g, greaterThan(settled.r),
        reason: 'Chrome must repaint at its normal position after the flight');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fullscreen canvas chrome stays above flying artwork during slide-up',
    (tester) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final boundary = GlobalKey();
      const source = Rect.fromLTWH(10, 700, 52, 52);

      Future<Color> pixelAt(double progress, {required bool liftChrome}) async {
        final shift = (1 - progress) * 700;
        await tester.pumpWidget(MaterialApp(
          home: RepaintBoundary(
            key: boundary,
            child: ColoredBox(
              color: Colors.black,
              child: LokalPlayerMorph(
                progress: progress,
                sheetOffset: shift,
                sourceArtwork: () => source,
                child: Transform.translate(
                  offset: Offset(0, shift),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: LokalPlayerArtwork(
                          expandedRadius: 0,
                          child: const ColoredBox(color: Colors.red),
                        ),
                      ),
                      Positioned(
                        left: 20,
                        top: 200,
                        child: LokalPlayerChrome(
                          enabled: liftChrome,
                          child: const SizedBox(
                            width: 120,
                            height: 90,
                            child: ColoredBox(color: Colors.green),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pump();
        final rb = boundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await rb.toImage(pixelRatio: 1);
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        // With the sheet halfway open, the flying Canvas covers this point
        // unless the chrome has its own foreground paint pass.
        const x = 65, y = 565;
        final index = (y * image.width + x) * 4;
        final color = Color.fromARGB(
          data.getUint8(index + 3),
          data.getUint8(index),
          data.getUint8(index + 1),
          data.getUint8(index + 2),
        );
        image.dispose();
        return color;
      }

      final behindCanvas = await pixelAt(.5, liftChrome: false);
      expect(behindCanvas.r, greaterThan(behindCanvas.g),
          reason: 'The fullscreen flying artwork covers normal sheet chrome');

      final foreground = await pixelAt(.5, liftChrome: true);
      expect(foreground.g, greaterThan(foreground.r),
          reason: 'Title and controls remain visible over the moving Canvas');

      final settled = await pixelAt(1, liftChrome: true);
      expect(settled.g, greaterThan(settled.r),
          reason: 'At rest, chrome returns to its normal render position');
      expect(tester.takeException(), isNull);
    },
  );
}
