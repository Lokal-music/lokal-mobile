import 'package:flick/features/player/widgets/cloud_cover_reveal.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/cloud_cover_pixel_contract.dart';

void main() {
  testWidgets(
    'compiled cloud shader produces circular feathered pixels in every aspect ratio',
    (tester) async {
      await tester.runAsync(() async {
        await CloudCoverShaders.load();
        final program = CloudCoverShaders.program.value;
        expect(
          program,
          isNotNull,
          reason: 'A crossfade cannot qualify the compiled shader.',
        );
        for (final (width, height) in [(350, 350), (350, 740), (740, 350)]) {
          final pixels = await renderCloudCoverPixelContract(
            program: program!,
            width: width,
            height: height,
            progress: .65,
          );
          final inverse = await renderCloudCoverPixelContract(
            program: program,
            width: width,
            height: height,
            progress: .65,
            inverted: true,
          );
          for (final key in pixels.keys) {
            expect(pixels[key]! + inverse[key]!, closeTo(255, 1));
          }

          expect(pixels['center'], 255);
          expect(pixels['corner'], 0);
          expect(pixels['horizontal_feather'], closeTo(153, 8));
          expect(
            pixels['vertical_feather'],
            closeTo(pixels['horizontal_feather']!, 8),
          );
        }
        for (final (progress, expected) in [(0.0, 0), (1.0, 255)]) {
          final pixels = await renderCloudCoverPixelContract(
            program: program!,
            width: 350,
            height: 740,
            progress: progress,
          );
          expect(pixels.values, everyElement(expected));
        }
        final overlap = await renderCloudCoverPixelContract(
          program: program!,
          width: 350,
          height: 350,
          progress: .65,
          activeBlobs: 2,
        );
        expect(overlap['horizontal_feather'], closeTo(214, 8));
        final finalFill = await renderCloudCoverPixelContract(
          program: program,
          width: 350,
          height: 740,
          progress: .91,
        );
        expect(finalFill['corner'], closeTo(128, 2));
      });
    },
  );
}
