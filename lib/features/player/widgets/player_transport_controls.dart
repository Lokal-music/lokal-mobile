import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/l10n/l10n.dart';
import 'full_player_visuals.dart';

/// Both transport styles share playback callbacks, hit regions and animations.
/// The boxed layout remains identical; Apple Music changes only the unboxed UI.
class PlayerTransportControls extends ConsumerStatefulWidget {
  const PlayerTransportControls({
    super.key,
    required this.playing,
    required this.compact,
    this.tallerButtons = false,
    required this.lyricsProgress,
    required this.accent,
    required this.onAccent,
    required this.onPrevious,
    required this.onNext,
    required this.onPlayPause,
  });

  final bool playing, compact;
  final bool tallerButtons;
  final double lyricsProgress;
  final Color accent, onAccent;
  final VoidCallback onPrevious, onNext, onPlayPause;

  @override
  ConsumerState<PlayerTransportControls> createState() =>
      _PlayerTransportControlsState();
}

class _PlayerTransportControlsState extends ConsumerState<PlayerTransportControls>
    with SingleTickerProviderStateMixin {
  late final AnimationController _icon = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: widget.playing ? 1 : 0,
  );

  @override
  void didUpdateWidget(PlayerTransportControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _icon.value = widget.playing ? 1 : 0;
      } else {
        _icon.animateTo(widget.playing ? 1 : 0, curve: Curves.easeInOutCubic);
      }
    }
  }

  @override
  void dispose() {
    _icon.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _icon,
    builder: (context, _) {
      final unboxed = ref.watch(lokalAppearanceProvider.select(
        (appearance) => appearance.unboxedPlayerControls,
      ));
      final l = widget.lyricsProgress.clamp(0.0, 1.0);
      final height = lerpDouble(
        widget.tallerButtons
            ? (widget.compact ? 74.0 : 94.0)
            : (widget.compact ? 66.0 : 82.0),
        widget.compact ? 48 : 52,
        l,
      )!;
      final radius = lerpDouble(26, 23, l)!;

      Widget skip(bool previous) => _TransportButton(
        color: unboxed ? Colors.transparent : FullPlayerVisuals.surface,
        radius: radius,
        unboxed: unboxed,
        pulseCount: unboxed ? 3 : 1,
        onTap: previous ? widget.onPrevious : widget.onNext,
        label: previous ? l10n.previousSong : l10n.nextSong,
        child: unboxed
            ? _AppleTransportGlyph(
                key: ValueKey(previous ? 'apple-skip-previous' : 'apple-skip-next'),
                glyph: previous ? _AppleGlyph.previous : _AppleGlyph.next,
                size: lerpDouble(44, 34, l)!,
                color: FullPlayerVisuals.primaryText,
              )
            : Icon(
                previous ? Icons.skip_previous_rounded : Icons.skip_next_rounded,
                size: lerpDouble(29, 26, l),
                color: FullPlayerVisuals.primaryText,
              ),
      );

      final play = _TransportButton(
        key: const ValueKey('player-play-button'),
        unboxed: unboxed,
        pulseCount: unboxed ? 2 : 1,
        color: unboxed ? Colors.transparent : widget.accent,
        radius: radius,
        onTap: widget.onPlayPause,
        label: widget.playing ? l10n.pause : l10n.play,
        child: unboxed
            ? SizedBox.square(
                key: const ValueKey('apple-play-pause'),
                dimension: lerpDouble(62, 44, l)!,
                child: AnimatedSwitcher(
                  // Only animate the glyph, never introduce a button box.
                  // A short fade/scale reads as a play/pause morph without
                  // running a continuous animation between interactions.
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 240),
                  reverseDuration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: .88, end: 1).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _AppleTransportGlyph(
                    key: ValueKey(widget.playing ? 'apple-pause' : 'apple-play'),
                    glyph: widget.playing ? _AppleGlyph.pause : _AppleGlyph.play,
                    size: lerpDouble(62, 44, l)!,
                    color: FullPlayerVisuals.primaryText,
                  ),
                ),
              )
            : AnimatedIcon(
                icon: AnimatedIcons.play_pause,
                progress: _icon,
                size: lerpDouble(33, 29, l),
                color: widget.onAccent,
              ),
      );

      return SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, c) {
            if (unboxed) {
              // Screenshot reference: on the 706px-wide Apple Music player
              // the three glyph centers are x=176, 354, 530, i.e. 25/50/75%.
              // Keeping the hit regions distinct from the glyphs preserves
              // that precise spacing at every width and avoids visible boxes.
              final quarter = c.maxWidth / 4;
              final sideWidth = quarter.clamp(48.0, 76.0).toDouble();
              final playWidth = (quarter * 1.05).clamp(52.0, 96.0).toDouble();
              return Stack(children: [
                Positioned(
                  top: 0, bottom: 0,
                  left: quarter - sideWidth / 2, width: sideWidth,
                  child: skip(true),
                ),
                Positioned(
                  top: 0, bottom: 0,
                  left: c.maxWidth / 2 - playWidth / 2, width: playWidth,
                  child: play,
                ),
                Positioned(
                  top: 0, bottom: 0,
                  left: quarter * 3 - sideWidth / 2, width: sideWidth,
                  child: skip(false),
                ),
              ]);
            }
            // Retain the original boxed button widths and gap.
            final primary = (c.maxWidth - 16) * .36;
            return Row(children: [
              Expanded(child: skip(true)),
              const SizedBox(width: 8),
              SizedBox(width: primary, child: play),
              const SizedBox(width: 8),
              Expanded(child: skip(false)),
            ]);
          },
        ),
      );
    },
  );
}

class _TransportButton extends StatefulWidget {
  const _TransportButton({
    super.key,
    required this.color,
    required this.radius,
    required this.unboxed,
    required this.onTap,
    required this.label,
    required this.child,
    this.pulseCount = 1,
  });

  final Color color;
  final double radius;
  final bool unboxed;
  final VoidCallback onTap;
  final String label;
  final Widget child;
  final int pulseCount;

  @override
  State<_TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<_TransportButton> {
  bool _pressed = false;

  void _activate() {
    if (widget.pulseCount == 3) {
      AppHaptics.triplePulse();
    } else if (widget.pulseCount == 2) {
      AppHaptics.doublePulse();
    } else {
      AppHaptics.tap();
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    child: Tooltip(
      message: widget.label,
      child: AnimatedScale(
        scale: _pressed ? .94 : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Duration(milliseconds: _pressed ? 90 : 220),
        curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
        child: Material(
          color: widget.color,
          borderRadius: BorderRadius.circular(widget.radius),
          clipBehavior: Clip.antiAlias,
          child: widget.unboxed
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => setState(() => _pressed = true),
                  onTapCancel: () => setState(() => _pressed = false),
                  onTapUp: (_) => setState(() => _pressed = false),
                  onTap: _activate,
                  child: Center(child: widget.child),
                )
              : InkWell(
                  onHighlightChanged: (value) => setState(() => _pressed = value),
                  onTap: _activate,
                  child: Center(child: widget.child),
                ),
        ),
      ),
    ),
  );
}

enum _AppleGlyph { previous, play, pause, next }

/// Screenshot-derived silhouettes: overlapping double triangles with NO
/// terminal bar, unlike backward.end.fill and Material's rounded fast rewind.
class _AppleTransportGlyph extends StatelessWidget {
  const _AppleTransportGlyph({
    super.key, required this.glyph, required this.size, required this.color,
  });
  final _AppleGlyph glyph;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _AppleTransportPainter(glyph: glyph, color: color),
    ),
  );
}

class _AppleTransportPainter extends CustomPainter {
  const _AppleTransportPainter({required this.glyph, required this.color});
  final _AppleGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..isAntiAlias = true;
    final w = size.width, h = size.height;
    if (glyph == _AppleGlyph.pause) {
      final barWidth = w * .105, barHeight = h * .60;
      final top = (h - barHeight) / 2;
      for (final x in [w * .32, w * .57]) {
        canvas.drawRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barWidth, barHeight),
          Radius.circular(w * .018),
        ), paint);
      }
      return;
    }
    void triangle(double tipX, double baseX, double top, double bottom) {
      final path = Path()
        ..moveTo(tipX, (top + bottom) / 2)
        ..lineTo(baseX, top)
        ..lineTo(baseX, bottom)
        ..close();
      canvas.drawPath(path, paint);
      canvas.drawPath(path, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * .018
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true);
    }
    if (glyph == _AppleGlyph.play) {
      triangle(w * .77, w * .23, h * .17, h * .83);
      return;
    }
    final left = w * .13, step = w * .365;
    final top = h * .25, bottom = h * .75;
    if (glyph == _AppleGlyph.next) {
      triangle(left + step, left, top, bottom);
      triangle(left + step * 2, left + step, top, bottom);
    } else {
      triangle(left + step, left + step * 2, top, bottom);
      triangle(left, left + step, top, bottom);
    }
  }

  @override
  bool shouldRepaint(_AppleTransportPainter old) =>
      old.glyph != glyph || old.color != color;
}
