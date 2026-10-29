import 'dart:math' as math;
import 'dart:ui' as ui;

/// Rasterize the compiled production shader. This deliberately does not call
/// the CPU geometry reference: assertions inspect the actual returned pixels.
Future<Map<String, int>> renderCloudCoverPixelContract({
  required ui.FragmentProgram program,
  required int width,
  required int height,
  required double progress,
  int activeBlobs = 1,
  bool inverted = false,
}) async {
  final shader = program.fragmentShader()
    ..setFloat(0, width.toDouble())
    ..setFloat(1, height.toDouble())
    ..setFloat(2, progress);
  for (var index = 0; index < 14; index++) {
    final offset = 3 + index * 4;
    shader
      ..setFloat(offset, .5)
      ..setFloat(offset + 1, .5)
      ..setFloat(offset + 2, index < activeBlobs ? 0 : .9)
      ..setFloat(offset + 3, .35);
  }
  shader.setFloat(59, inverted ? 1 : 0);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..shader = shader,
  );
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (pixels == null) throw StateError('Cloud mask did not produce pixels.');
    int alpha(double x, double y) => pixels.getUint8(
      ((y.floor().clamp(0, height - 1) * width +
                  x.floor().clamp(0, width - 1)) *
              4) +
          3,
    );
    // Closed-form fixture geometry, independent of the production evaluator.
    final t = progress.clamp(0.0, 1.0);
    final cubicOut = 1 - math.pow(1 - t, 3);
    final cubicInOut = t < .5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;
    final radius =
        .35 * (.65 * cubicOut + .35 * cubicInOut) * math.min(width, height);
    final centerX = width / 2, centerY = height / 2;
    return {
      'center': alpha(centerX, centerY),
      'horizontal_feather': alpha(centerX + radius * .7, centerY),
      'vertical_feather': alpha(centerX, centerY + radius * .7),
      'corner': alpha(0, 0),
    };
  } finally {
    image?.dispose();
    picture.dispose();
    shader.dispose();
  }
}
