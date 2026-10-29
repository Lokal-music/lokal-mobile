import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Matches the desktop player's staggered, expanding-blob artwork handover.
///
/// The old cover is painted below this clipped incoming cover. Unlike a
/// fullscreen blur or a per-frame bitmap mask, this uses one anti-aliased
/// vector clip of 14 ovals, keeping the decoded artwork in its own layer.
/// The clip is the only thing that changes on animation ticks.
class CloudCoverReveal extends StatefulWidget {
  const CloudCoverReveal({
    super.key,
    required this.progress,
    required this.seed,
    required this.child,
  });

  final Animation<double> progress;
  final int seed;
  final Widget child;

  @override
  State<CloudCoverReveal> createState() => _CloudCoverRevealState();
}

class _CloudCoverRevealState extends State<CloudCoverReveal> {
  late List<CloudCoverBlob> _blobs = createCloudCoverBlobs(widget.seed);

  @override
  void didUpdateWidget(covariant CloudCoverReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seed != widget.seed) {
      _blobs = createCloudCoverBlobs(widget.seed);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.progress,
    child: RepaintBoundary(child: widget.child),
    builder: (context, child) => ClipPath(
      clipBehavior: Clip.antiAlias,
      clipper: CloudCoverClipper(widget.progress.value, _blobs),
      child: child,
    ),
  );
}

@immutable
class CloudCoverBlob {
  const CloudCoverBlob(this.x, this.y, this.delay, this.size);
  final double x, y, delay, size;
}

List<CloudCoverBlob> createCloudCoverBlobs(int seed) {
  final rng = math.Random(seed);
  return List<CloudCoverBlob>.unmodifiable(
    List.generate(14, (i) => CloudCoverBlob(
      .08 + rng.nextDouble() * .84,
      .08 + rng.nextDouble() * .84,
      i < 3 ? rng.nextDouble() * .06 : .06 + rng.nextDouble() * .66,
      .30 + rng.nextDouble() * .34,
    )),
  );
}

double _clamp(double value) => value.clamp(0.0, 1.0).toDouble();
double _easeOut(double t) => 1 - math.pow(1 - t, 3).toDouble();
double _easeInOut(double t) => t < .5
    ? 4 * t * t * t
    : 1 - math.pow(-2 * t + 2, 3).toDouble() / 2;

/// Pure geometry: no artwork decoding, gradient allocation, or raster reads.
class CloudCoverClipper extends CustomClipper<Path> {
  const CloudCoverClipper(this.progress, this.blobs);

  final double progress;
  final List<CloudCoverBlob> blobs;

  @visibleForTesting
  Path revealPath(Size size) {
    final p = _clamp(progress);
    final path = Path();
    if (p >= 1) return path..addRect(Offset.zero & size);
    if (size.isEmpty) return path;

    for (final blob in blobs) {
      final t = _clamp((p - blob.delay) / (1 - blob.delay));
      if (t <= 0) continue;
      final growth = .65 * _easeOut(t) + .35 * _easeInOut(t);
      final radius = blob.size * growth;
      path.addOval(Rect.fromCenter(
        center: Offset(size.width * blob.x, size.height * blob.y),
        width: size.width * radius * 2,
        height: size.height * radius * 2,
      ));
    }

    // Desktop fades an unmasked layer in over the final 18%. Grow an
    // oversized ellipse instead, to avoid a full-screen saveLayer and to
    // guarantee a continuous reveal without a final one-frame pop.
    final fill = _clamp((p - .82) / .18);
    if (fill > 0) {
      final radius = 2 * _easeOut(fill);
      path.addOval(Rect.fromCenter(
        center: size.center(Offset.zero),
        width: size.width * radius * 2,
        height: size.height * radius * 2,
      ));
    }
    return path;
  }

  @override
  Path getClip(Size size) => revealPath(size);

  @override
  bool shouldReclip(CloudCoverClipper oldClipper) =>
      progress != oldClipper.progress || !identical(blobs, oldClipper.blobs);
}
