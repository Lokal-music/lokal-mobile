import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Desktop's src/coverMix.js paints overlapping soft radial gradients, never
/// clip ovals. This shader performs the same alpha union in one GPU mask pass.
abstract final class CloudCoverShaders {
  static final program = ValueNotifier<ui.FragmentProgram?>(null);
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      program.value ??= await ui.FragmentProgram.fromAsset(
        'shaders/cover_cloud_dissolve.frag',
      );
    } catch (error) {
      // A missing GPU effect must not break playback or widget tests.
      // Release builds precompile shader assets; debug tools can inspect this.
      assert(() {
        debugPrint('Desktop cloud dissolve shader unavailable: $error');
        return true;
      }());
    }
  }
}

@immutable
class CloudCoverBlob {
  const CloudCoverBlob(this.x, this.y, this.delay, this.size);

  final double x;
  final double y;
  final double delay;
  final double size;
}

/// The same 14 positions, stagger delays and radius ranges as desktop.
List<CloudCoverBlob> createCloudCoverBlobs(int seed) {
  final rng = math.Random(seed);
  return List<CloudCoverBlob>.unmodifiable(
    List.generate(
      14,
      (i) => CloudCoverBlob(
        .08 + rng.nextDouble() * .84,
        .08 + rng.nextDouble() * .84,
        i < 3 ? rng.nextDouble() * .06 : .06 + rng.nextDouble() * .66,
        .30 + rng.nextDouble() * .34,
      ),
    ),
  );
}

double _clamp(double value) => value.clamp(0.0, 1.0).toDouble();
double _easeOut(double t) => 1 - math.pow(1 - t, 3).toDouble();
double _easeInOut(double t) =>
    t < .5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3).toDouble() / 2;

/// CSS filter blur(16px) at the start, sharpening by 88% of the 2400ms reveal.
double cloudCoverBlur(double progress) =>
    16 * (1 - _easeOut(_clamp(progress / .88)));

/// CPU reference for the fragment shader's circular, feathered gradients,
/// used only for geometry/feathering regression tests (UI runs on the GPU).
@visibleForTesting
double cloudCoverAlphaAt(
  List<CloudCoverBlob> blobs,
  double progress,
  double x,
  double y, {
  Size size = const Size(1, 1),
  bool inverted = false,
}) {
  final p = _clamp(progress);
  // Both axes are measured in physical pixel space. In particular, a
  // portrait fullscreen cover cannot stretch the mask into tall ovals.
  final width = math.max(1.0, size.width);
  final height = math.max(1.0, size.height);
  final shortestSide = math.min(width, height);
  var alpha = 0.0;
  for (final blob in blobs) {
    final t = _clamp((p - blob.delay) / (1 - blob.delay));
    final grown = .65 * _easeOut(t) + .35 * _easeInOut(t);
    final radius = blob.size * grown;
    if (radius <= 0) continue;
    final dx = (x - blob.x) * width;
    final dy = (y - blob.y) * height;
    final dist = math.sqrt(dx * dx + dy * dy) / (radius * shortestSide);
    final double layer;
    if (dist <= .45) {
      layer = 1;
    } else if (dist <= .70) {
      layer = 1 - .4 * (dist - .45) / .25;
    } else if (dist <= 1) {
      layer = .6 * (1 - (dist - .70) / .30);
    } else {
      layer = 0;
    }
    alpha = 1 - (1 - alpha) * (1 - layer);
  }
  // Exactly desktop's translucent full-frame final 18%; not a growing oval.
  final fill = _clamp((p - .82) / .18);
  final composed = 1 - (1 - alpha) * (1 - fill);
  return inverted ? 1 - composed : composed;
}

/// GPU cloud handover for transport-button transitions. The outgoing stage is
/// kept underneath; the incoming artwork retains its own repaint boundary.
/// Finger swipes never instantiate this widget.
class CloudCoverReveal extends StatefulWidget {
  const CloudCoverReveal({
    super.key,
    required this.progress,
    required this.seed,
    required this.child,
    this.inverted = false,
    this.blur = true,
  });

  final Animation<double> progress;
  final int seed;
  final Widget child;

  /// The outgoing fullscreen sleeve uses the inverse cloud mask. Otherwise
  /// its intentionally translucent lower edge retains an old rectangular
  /// banner until the old stage is unmounted on the final animation frame.
  final bool inverted;

  /// Only the incoming artwork needs the desktop's soft-to-sharp blur.
  final bool blur;

  @override
  State<CloudCoverReveal> createState() => _CloudCoverRevealState();
}

class _CloudCoverRevealState extends State<CloudCoverReveal> {
  static const _steps = 72; // Desktop's 2400 ms / 30 FPS.
  late List<CloudCoverBlob> _blobs;
  late int _step;
  ui.FragmentProgram? _program;

  static int _frame(double progress) => (_clamp(progress) * _steps).floor();

  @override
  void initState() {
    super.initState();
    _blobs = createCloudCoverBlobs(widget.seed);
    _step = _frame(widget.progress.value);
    _program = CloudCoverShaders.program.value;
    widget.progress.addListener(_tick);
    unawaited(CloudCoverShaders.load());
  }

  void _tick() {
    final step = _frame(widget.progress.value);
    if (mounted && step != _step) setState(() => _step = step);
  }

  @override
  void didUpdateWidget(covariant CloudCoverReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_tick);
      widget.progress.addListener(_tick);
      _step = _frame(widget.progress.value);
    }
    if (oldWidget.seed != widget.seed) {
      _blobs = createCloudCoverBlobs(widget.seed);
      // A new track can adopt a shader that loaded during the last transition.
      _program = CloudCoverShaders.program.value;
    }
  }

  @override
  void dispose() {
    widget.progress.removeListener(_tick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _step / _steps;
    final artwork = RepaintBoundary(child: widget.child);
    final program = _program;
    if (program == null) {
      // Do not show hard-edged vector shapes if the shader is unavailable.
      // Keep this transition a stable crossfade, then retry on the next song.
      return Opacity(opacity: widget.inverted ? 1 - p : p, child: artwork);
    }

    Widget incoming = ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final shader = program.fragmentShader()
          ..setFloat(0, rect.width)
          ..setFloat(1, rect.height)
          ..setFloat(2, p);
        for (var i = 0; i < _blobs.length; i++) {
          final blob = _blobs[i];
          final at = 3 + i * 4;
          shader
            ..setFloat(at, blob.x)
            ..setFloat(at + 1, blob.y)
            ..setFloat(at + 2, blob.delay)
            ..setFloat(at + 3, blob.size);
        }
        shader.setFloat(59, widget.inverted ? 1.0 : 0.0);
        return shader;
      },
      child: artwork,
    );

    // On desktop the CSS blur is applied to the *masked incoming layer*.
    // Blur after ShaderMask so both the new picture and cloud edges soften
    // together, then sharpen progressively to the full-resolution cover.
    final blur = cloudCoverBlur(p);
    if (widget.blur && blur > .05) {
      incoming = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blur,
          sigmaY: blur,
          tileMode: TileMode.decal,
        ),
        child: incoming,
      );
    }
    return incoming;
  }
}
