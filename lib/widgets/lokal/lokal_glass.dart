import 'package:flick/features/appearance/lokal_performance_advisor.dart';

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/core/theme/lokal_interaction.dart';
import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/theme/lokal_tokens.dart';

/// The lens and rim shaders, loaded once at start-up.
///
/// The lens needs Impeller's shader image filters; where they are missing
/// (or still loading) glass falls back to blur and tint.
abstract final class LokalGlassShaders {
  static final lens = ValueNotifier<ui.FragmentProgram?>(null);
  static final rim = ValueNotifier<ui.FragmentProgram?>(null);

  static Future<void> load() async {
    try {
      rim.value ??= await ui.FragmentProgram.fromAsset(
        'shaders/lokal_glass_rim.frag',
      );
      if (ui.ImageFilter.isShaderFilterSupported) {
        lens.value ??= await ui.FragmentProgram.fromAsset(
          'shaders/lokal_glass_lens.frag',
        );
      }
    } catch (error, stack) {
      // Glass still works without them; it just isn't liquid.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'lokal glass',
          context: ErrorDescription('loading the glass shaders'),
        ),
      );
    }
  }
}

/// How a glass shape bends what is behind it (Kyant0/backdrop's lens).
@immutable
class LokalLens {
  const LokalLens({
    required this.height,
    required this.amount,
    this.depth = 0,
    this.dispersion = 0,
    this.fraction = 1,
  });

  /// How far in from the edge the bending reaches, in logical pixels.
  final double height;

  /// How far the edge pulls the backdrop in, in logical pixels.
  final double amount;

  /// 1 bulges the whole face like a magnifier; 0 bends only the edge.
  final double depth;

  /// Rainbow fringe at the rim, 0 to 1.
  final double dispersion;

  /// Caps [height] and [amount] at this share of the shape's shorter side,
  /// so a lens scales with the shape (BitChord's bars use half).
  final double fraction;

  static const none = LokalLens(height: 0, amount: 0);

  LokalLens scale(double t) => LokalLens(
    height: height * t,
    amount: amount * t,
    depth: depth,
    dispersion: dispersion,
    fraction: fraction,
  );

  @override
  bool operator ==(Object other) =>
      other is LokalLens &&
      other.height == height &&
      other.amount == amount &&
      other.depth == depth &&
      other.dispersion == dispersion &&
      other.fraction == fraction;

  @override
  int get hashCode => Object.hash(height, amount, depth, dispersion, fraction);
}

/// How much a [LokalGlass] hides what is behind it.
///
/// Real glass (with the lens) stays clear, as on iOS 26: a light blur and a
/// 40 % tint, the lens doing the work. Without the lens it falls back to a
/// heavier frost so text on it keeps its contrast.
enum LokalGlassThickness {
  /// Controls floating over artwork or content: top-bar circles, chips,
  /// segmented controls, Now Playing transport.
  thin(
    blur: 2,
    tint: .22,
    lens: LokalLens(height: 12, amount: 24),
    frostSigma: 14,
    frostDark: .14,
    frostLight: .45,
  ),

  /// Floating chrome: tab capsule, search circle, mini player, toasts.
  regular(
    blur: 8,
    tint: .40,
    lens: LokalLens(height: 48, amount: 48, fraction: .5),
    frostSigma: 18,
    frostDark: .50,
    frostLight: .62,
  ),

  /// Sheets and menus.
  sheet(
    blur: 12,
    tint: .70,
    lens: LokalLens(height: 24, amount: 16),
    frostSigma: 24,
    frostDark: .72,
    frostLight: .78,
  );

  const LokalGlassThickness({
    required this.blur,
    required this.tint,
    required this.lens,
    required this.frostSigma,
    required this.frostDark,
    required this.frostLight,
  });

  /// Blur radius under real glass, in logical pixels (Android's and
  /// Kyant0/backdrop's radius, not a sigma).
  final double blur;

  /// [blur] as a Gaussian sigma (Skia's conversion).
  double get blurSigma => blur * 0.57735 + 0.5;

  /// Tint opacity of real glass.
  final double tint;
  final LokalLens lens;

  /// The fallback frost: blur sigma and tint opacity on dark and light
  /// themes.
  final double frostSigma;
  final double frostDark;
  final double frostLight;
}

/// Lokal's glass material (design spec §4), modelled on Apple's Liquid Glass.
///
/// What is behind it is made more vibrant, lightly blurred and bent toward
/// the centre near the edge by a lens shader, so the glass reads as a solid
/// lens; then a 40 % tint and a specular rim lit from the top-left. Where
/// shader filters are unavailable it is frosted glass instead, and in
/// performance mode a solid tint, like desktop's Performance Mode removing
/// every backdrop-filter.
///
/// Inside a [BackdropGroup], pass [grouped] so neighbouring frosted glass
/// shares one backdrop capture (the lens needs its own).
class LokalGlass extends ConsumerWidget {
  const LokalGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.thickness = LokalGlassThickness.regular,
    this.tint,
    this.padding,
    this.shadow = true,
    this.grouped = false,
    this.lens,
  });

  /// A fully rounded capsule or circle (`StadiumBorder`-like radius).
  const LokalGlass.capsule({
    super.key,
    required this.child,
    this.thickness = LokalGlassThickness.regular,
    this.tint,
    this.padding,
    this.shadow = true,
    this.grouped = false,
    this.lens,
  }) : borderRadius = const BorderRadius.all(Radius.circular(999));

  final Widget child;
  final BorderRadius borderRadius;
  final LokalGlassThickness thickness;

  /// Replaces the theme tint, e.g. the accent for a selected lens.
  final Color? tint;
  final EdgeInsetsGeometry? padding;
  final bool shadow;
  final bool grouped;

  /// Overrides the thickness's lens.
  final LokalLens? lens;

  static const _vibrancy = 1.5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.lokal;
    final solid = ref.watch(
      lokalAppearanceProvider.select((a) => a.performanceMode),
    );
    return _GlassPresence(
      child: ValueListenableBuilder<ui.FragmentProgram?>(
        valueListenable: LokalGlassShaders.lens,
        builder: (context, program, _) {
          final liquid = !solid && program != null;
          final light = t.isLight;
          final double alpha;
          if (liquid) {
            alpha = thickness.tint;
          } else {
            final frost = light ? thickness.frostLight : thickness.frostDark;
            // Solid glass gets 20 % more opacity so text keeps its contrast
            // without the blur behind it.
            alpha = solid ? (frost + .2).clamp(0.0, .96) : frost;
          }
          final base =
              tint ??
              (liquid
                  ? (light ? const Color(0xFFFAFAFA) : const Color(0xFF121212))
                  : (light ? Colors.white : t.surface));

          Widget surface = DecoratedBox(
            decoration: BoxDecoration(
              color: base.withValues(alpha: alpha),
              borderRadius: borderRadius,
            ),
            position: DecorationPosition.background,
            child: CustomPaint(
              foregroundPainter: LokalGlassRimPainter(
                borderRadius: borderRadius,
                light: light,
                strength: solid ? .6 : 1,
                program: LokalGlassShaders.rim.value,
              ),
              child: padding == null
                  ? child
                  : Padding(padding: padding!, child: child),
            ),
          );

          if (liquid) {
            surface = LokalLensBackdrop(
              program: program,
              radius: _radius(borderRadius),
              lens: lens ?? thickness.lens,
              inner: ui.ImageFilter.compose(
                outer: ui.ImageFilter.blur(
                  sigmaX: thickness.blurSigma,
                  sigmaY: thickness.blurSigma,
                  tileMode: TileMode.mirror,
                ),
                inner: const ColorFilter.matrix(_vibrancyMatrix),
              ),
              child: surface,
            );
          } else if (!solid) {
            final filter = ui.ImageFilter.compose(
              outer: const ColorFilter.matrix(_vibrancyMatrix),
              inner: ui.ImageFilter.blur(
                sigmaX: thickness.frostSigma,
                sigmaY: thickness.frostSigma,
                tileMode: TileMode.mirror,
              ),
            );
            surface = grouped
                ? BackdropFilter.grouped(filter: filter, child: surface)
                : BackdropFilter(filter: filter, child: surface);
          }

          surface = ClipRRect(borderRadius: borderRadius, child: surface);
          if (!shadow) return surface;
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: light ? .10 : .30),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: surface,
          );
        },
      ),
    );
  }

  static double _radius(BorderRadius r) => [
    r.topLeft.x,
    r.topRight.x,
    r.bottomLeft.x,
    r.bottomRight.x,
  ].reduce(math.max);

  // Kyant0/backdrop's vibrancy: saturation 1.5 on what the glass samples,
  // so colours behind it glow instead of going muddy.
  static const List<double> _vibrancyMatrix = <double>[
    0.213 * (1 - _vibrancy) + _vibrancy,
    0.715 * (1 - _vibrancy),
    0.072 * (1 - _vibrancy),
    0,
    0,
    0.213 * (1 - _vibrancy),
    0.715 * (1 - _vibrancy) + _vibrancy,
    0.072 * (1 - _vibrancy),
    0,
    0,
    0.213 * (1 - _vibrancy),
    0.715 * (1 - _vibrancy),
    0.072 * (1 - _vibrancy) + _vibrancy,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];
}

/// A clear lens with no tint or blur of its own, like the travelling
/// selection in an iOS 26 tab bar: it refracts whatever glass is under it.
class LokalClearLens extends StatelessWidget {
  const LokalClearLens({
    super.key,
    required this.lens,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(999)),
  });

  final LokalLens lens;
  final BorderRadius borderRadius;

  /// Painted on top of the lens: its fill and rim.
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ui.FragmentProgram?>(
        valueListenable: LokalGlassShaders.lens,
        builder: (context, program, _) {
          if (program == null || lens.amount <= 0 || lens.height <= 0) {
            return child;
          }
          return ClipRRect(
            borderRadius: borderRadius,
            child: LokalLensBackdrop(
              program: program,
              radius: LokalGlass._radius(borderRadius),
              lens: lens,
              child: child,
            ),
          );
        },
      );
}

/// Runs the lens shader over the backdrop of its child's box.
///
/// The shader needs the box's size and on-screen position each frame, so
/// this paints its own [BackdropFilterLayer] instead of using
/// [BackdropFilter]. Wrap it in a clip of the same shape.
class LokalLensBackdrop extends SingleChildRenderObjectWidget {
  const LokalLensBackdrop({
    super.key,
    required this.program,
    required this.radius,
    required this.lens,
    this.inner,
    super.child,
  });

  final ui.FragmentProgram program;
  final double radius;
  final LokalLens lens;

  /// Applied to the backdrop before the lens (vibrancy, blur).
  final ui.ImageFilter? inner;

  @override
  RenderLokalLensBackdrop createRenderObject(BuildContext context) =>
      RenderLokalLensBackdrop(
        program: program,
        radius: radius,
        lens: lens,
        inner: inner,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLokalLensBackdrop renderObject,
  ) {
    renderObject
      ..program = program
      ..radius = radius
      ..lens = lens
      ..inner = inner
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

class RenderLokalLensBackdrop extends RenderProxyBox {
  RenderLokalLensBackdrop({
    required this._program,
    required this._radius,
    required this._lens,
    required this._inner,
    required this._devicePixelRatio,
  });

  ui.FragmentProgram _program;
  set program(ui.FragmentProgram value) {
    if (identical(value, _program)) return;
    _program = value;
    _invalidate();
  }

  double _radius;
  set radius(double value) {
    if (value == _radius) return;
    _radius = value;
    _invalidate();
  }

  LokalLens _lens;
  set lens(LokalLens value) {
    if (value == _lens) return;
    _lens = value;
    _invalidate();
  }

  ui.ImageFilter? _inner;
  set inner(ui.ImageFilter? value) {
    if (value == _inner) return;
    _inner = value;
    _invalidate();
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    _invalidate();
  }

  // The filter is rebuilt only when its uniforms change: a filter snapshots
  // its shader, so a shader is never changed after it is handed over.
  List<double>? _uniforms;
  ui.ImageFilter? _filter;

  void _invalidate() {
    _uniforms = null;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  BackdropFilterLayer? get layer => super.layer as BackdropFilterLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final dpr = _devicePixelRatio;
    final origin = localToGlobal(Offset.zero) * dpr;
    final cap = size.shortestSide * _lens.fraction;
    final height = math.min(math.min(_lens.height, cap), size.shortestSide / 2);
    final amount = math.min(_lens.amount, cap);
    final uniforms = <double>[
      size.width * dpr,
      size.height * dpr,
      origin.dx,
      origin.dy,
      _radius * dpr,
      height * dpr,
      amount * dpr,
      _lens.depth,
      _lens.dispersion,
    ];
    if (_filter == null || !listEquals(uniforms, _uniforms)) {
      final shader = _program.fragmentShader();
      // Index 0-1 is the input size, which the engine fills in.
      for (var i = 0; i < uniforms.length; i++) {
        shader.setFloat(i + 2, uniforms[i]);
      }
      _filter = ui.ImageFilter.shader(shader);
      _uniforms = uniforms;
    }
    final inner = _inner;
    if (inner == null) {
      _innerLayer.layer = null;
      layer ??= BackdropFilterLayer();
      layer!.filter = _filter!;
      context.pushLayer(layer!, super.paint, offset);
      return;
    }
    // Blur first, then the lens over the blurred backdrop, as two layers:
    // composed into one filter, the blur grows the lens's input past the
    // shape and its coordinates no longer line up.
    layer ??= BackdropFilterLayer();
    layer!.filter = inner;
    context.pushLayer(layer!, (context, offset) {
      final lensLayer = _innerLayer.layer ?? BackdropFilterLayer();
      lensLayer.filter = _filter!;
      _innerLayer.layer = lensLayer;
      context.pushLayer(lensLayer, super.paint, offset);
    }, offset);
  }

  final _innerLayer = LayerHandle<BackdropFilterLayer>();

  @override
  void dispose() {
    _innerLayer.layer = null;
    super.dispose();
  }
}

/// The specular rim that makes glass read as a solid object: light catching
/// the edge, brightest where the edge faces the top-left light and its
/// opposite corner (Kyant0/backdrop's default highlight).
class LokalGlassRimPainter extends CustomPainter {
  const LokalGlassRimPainter({
    required this.borderRadius,
    required this.light,
    required this.strength,
    this.program,
  });

  final BorderRadius borderRadius;
  final bool light;
  final double strength;
  final ui.FragmentProgram? program;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect).deflate(.5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..blendMode = light ? BlendMode.srcOver : BlendMode.plus;
    final program = this.program;
    if (program != null) {
      final shader = program.fragmentShader()
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, LokalGlass._radius(borderRadius))
        ..setFloat(3, 1)
        ..setFloat(4, 1)
        ..setFloat(5, 1)
        ..setFloat(6, (light ? .9 : .5) * strength)
        ..setFloat(7, math.pi / 4)
        ..setFloat(8, 1);
      paint.shader = shader;
    } else {
      paint.shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: (light ? .9 : .5) * strength),
          Colors.white.withValues(alpha: .08 * strength),
          Colors.white.withValues(alpha: (light ? .6 : .3) * strength),
        ],
      ).createShader(rect);
    }
    canvas.drawRRect(rrect, paint);
    // The 0.5 px hairline that gives glass an edge against a page the same
    // colour as its tint.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .5
        ..color = (light ? Colors.black : Colors.white).withValues(
          alpha: (light ? .06 : .10) * strength,
        ),
    );
  }

  @override
  bool shouldRepaint(LokalGlassRimPainter old) =>
      old.borderRadius != borderRadius ||
      old.light != light ||
      old.strength != strength ||
      old.program != program;
}

/// A glass control that swells under the finger, like iOS 26 glass buttons.
class LokalGlassButton extends StatefulWidget {
  const LokalGlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    required this.semanticLabel,
    this.size = 44,
    this.thickness = LokalGlassThickness.thin,
    this.tint,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final String semanticLabel;
  final double size;
  final LokalGlassThickness thickness;
  final Color? tint;

  @override
  State<LokalGlassButton> createState() => _LokalGlassButtonState();
}

class _LokalGlassButtonState extends State<LokalGlassButton> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        onTapDown: widget.onPressed == null ? null : (_) => _set(true),
        onTapUp: widget.onPressed == null ? null : (_) => _set(false),
        onTapCancel: widget.onPressed == null ? null : () => _set(false),
        onTap: widget.onPressed == null ? null : () {
          AppHaptics.tap();
          widget.onPressed!();
        },
        child: AnimatedScale(
          scale: _pressed && !reduceMotion ? LokalMotion.pressedScale : 1,
          duration: reduceMotion
              ? Duration.zero
              : (_pressed ? LokalMotion.press : LokalMotion.release),
          curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
          child: SizedBox.square(
            dimension: widget.size,
            child: LokalGlass.capsule(
              thickness: widget.thickness,
              tint: widget.tint,
              shadow: false,
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassPresence extends SingleChildRenderObjectWidget {
  const _GlassPresence({required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGlassPresence();
}

class _RenderGlassPresence extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    LokalPerformanceAdvisor.lastGlassPaintMicros =
        DateTime.now().microsecondsSinceEpoch;
    super.paint(context, offset);
  }
}
