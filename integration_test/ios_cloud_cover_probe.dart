import 'package:flick/features/player/widgets/cloud_cover_reveal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/cloud_cover_pixel_contract.dart';

/// Actual app runtime fragment program and returned pixels, separate from
/// CPU-reference tests. This is not a physical 60/120 Hz performance claim.
Future<void> probeIosCloudCoverPixels(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  await tester.runAsync(() async {
    await CloudCoverShaders.load();
    final program = CloudCoverShaders.program.value;
    expect(program, isNotNull, reason: 'A fallback cannot qualify the shader.');
    final rows = <Map<String, Object>>[];
    binding.reportData!['native_cloud_cover_pixels'] = {
      'scope': 'Actual production fragment program rasterized in the iOS app; no display-rate/performance acceptance',
      'cases': rows,
      'outgoing_inverse_pixel_complement_checked': true,
    };
    for (final (width, height) in [(350, 350), (350, 740), (740, 350)]) {
      final pixels = await renderCloudCoverPixelContract(
        program: program!,
        width: width,
        height: height,
        progress: .65,
      );
      rows.add({'width': width, 'height': height, 'progress': .65, ...pixels});
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
      rows.add({'width': 350, 'height': 740, 'progress': progress, ...pixels});
      expect(pixels.values, everyElement(expected));
    }
    final overlap = await renderCloudCoverPixelContract(
      program: program!,
      width: 350,
      height: 350,
      progress: .65,
      activeBlobs: 2,
    );
    rows.add({
      'width': 350,
      'height': 350,
      'progress': .65,
      'active_blobs': 2,
      ...overlap,
    });
    expect(overlap['horizontal_feather'], closeTo(214, 8));
    final finalFill = await renderCloudCoverPixelContract(
      program: program,
      width: 350,
      height: 740,
      progress: .91,
    );
    rows.add({'width': 350, 'height': 740, 'progress': .91, ...finalFill});
    expect(finalFill['corner'], closeTo(128, 2));
  });
}
