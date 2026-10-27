import 'dart:math' as math;

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flutter/material.dart';

import 'domain/flow_models.dart';

/// Desktop's FlowPanel hero, using the currently selected Lokal theme.
class FlowHero extends StatelessWidget {
  const FlowHero({
    super.key,
    required this.mood,
    required this.count,
    required this.playing,
    required this.busy,
    required this.enabled,
    required this.onPlay,
    required this.onShuffle,
    required this.onSave,
    this.onTune,
  });
  final FlowMood mood;
  final int count;
  final bool playing;
  final bool busy;
  final bool enabled;
  final VoidCallback onPlay, onShuffle, onSave;
  final VoidCallback? onTune;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surface2,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _FlowGlow(t.accent, t.purple),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'FLOW',
                        style: LokalTheme.label(t, color: t.accent)
                            .copyWith(letterSpacing: 2.5),
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const Key('flow-tune-button'),
                      onPressed: onTune,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        foregroundColor: t.text,
                        backgroundColor: t.surface3,
                        side: BorderSide(color: t.border2),
                      ),
                      icon: const Icon(Icons.tune_rounded, size: 18),
                      label: const Text('Tune'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FlowInfinityOrb(
                      playing: playing,
                      onPressed: enabled ? onPlay : null,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  mood == FlowMood.flow
                                      ? 'Flow'
                                      : 'Flow · ' + mood.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: LokalTheme.sans,
                                    fontSize: 27,
                                    fontWeight: FontWeight.w800,
                                    height: 1.12,
                                    letterSpacing: -.8,
                                    color: t.text,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                Icons.all_inclusive_rounded,
                                color: t.muted,
                                size: 22,
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Your personal soundtrack',
                            style: TextStyle(
                              color: t.muted,
                              fontSize: 14,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$count tracks · Local library',
                            style: TextStyle(color: t.muted2, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const Key('flow-play-button'),
                      onPressed: enabled ? onPlay : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: t.text,
                        foregroundColor: t.bg,
                        disabledBackgroundColor: t.surface3,
                        disabledForegroundColor: t.muted2,
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow, size: 20),
                      label: Text(playing ? 'Pause' : 'Play'),
                    ),
                    _outline(t, 'Shuffle', Icons.shuffle, enabled ? onShuffle : null),
                    _outline(t, 'Save', Icons.playlist_add, enabled ? onSave : null),
                  ],
                ),
                if (busy)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: LinearProgressIndicator(
                      color: t.accent,
                      backgroundColor: t.border,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _outline(
    LokalTokens t,
    String name,
    IconData icon,
    VoidCallback? callback,
  ) => OutlinedButton.icon(
    onPressed: callback,
    style: OutlinedButton.styleFrom(
      foregroundColor: t.text,
      disabledForegroundColor: t.muted2,
      minimumSize: const Size(0, 44),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      side: BorderSide(color: t.border2),
    ),
    icon: Icon(icon, size: 18),
    label: Text(name),
  );
}

/// Desktop CSS has two soft radial washes on top of --surface2.
class _FlowGlow extends CustomPainter {
  const _FlowGlow(this.accent, this.secondary);
  final Color accent, secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    for (final (center, color, opacity) in [
      (const Alignment(-1, -1), accent, .16),
      (const Alignment(1, 1), secondary, .18),
    ]) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: center,
            radius: 1.25,
            colors: [
              color.withValues(alpha: opacity),
              Colors.transparent,
            ],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FlowGlow old) =>
      old.accent != accent || old.secondary != secondary;
}

/// A compact, tappable version of desktop's three breathing infinity rings.
/// Reduced-motion users see the still orb; frames repaint only this boundary.
class FlowInfinityOrb extends StatefulWidget {
  const FlowInfinityOrb({
    super.key,
    required this.playing,
    required this.onPressed,
  });
  final bool playing;
  final VoidCallback? onPressed;
  @override
  State<FlowInfinityOrb> createState() => _FlowInfinityOrbState();
}

class _FlowInfinityOrbState extends State<FlowInfinityOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant FlowInfinityOrb old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) _sync();
  }

  void _sync() {
    if (MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context)) {
      _pulse.stop();
      _pulse.value = 0;
      return;
    }
    final duration = Duration(milliseconds: widget.playing ? 2200 : 3900);
    if (_pulse.isAnimating && _pulse.duration == duration) return;
    _pulse.duration = duration;
    _pulse.repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final still = MediaQuery.disableAnimationsOf(context);
    final label = widget.playing ? 'Pause Flow' : 'Play Flow';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: widget.onPressed != null,
        label: label,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: RepaintBoundary(
            child: SizedBox.square(
              dimension: 88,
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) => Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            t.accent.withValues(alpha: .28),
                            t.accent.withValues(alpha: .07),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                    if (!still)
                      for (final delay in [0.0, 1 / 3, 2 / 3])
                        _ring(t, (_pulse.value + delay) % 1),
                    Transform.rotate(
                      angle: still ? 0 : _pulse.value * math.pi * 2 / 3,
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(
                            colors: [t.accent, t.purple, t.accentDim, t.accent],
                          ),
                          border: Border.all(
                            color: t.text.withValues(alpha: .18),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: t.accent.withValues(alpha: .23),
                              blurRadius: 14,
                            ),
                          ],
                        ),
                        child: Transform.rotate(
                          angle: still ? 0 : -_pulse.value * math.pi * 2 / 3,
                          child: const Icon(
                            Icons.all_inclusive_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
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
  }

  Widget _ring(LokalTokens t, double phase) => Transform.scale(
    scale: .9 + .85 * phase,
    child: Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: t.accent.withValues(alpha: .6 * (1 - phase)),
          width: 1.5,
        ),
      ),
    ),
  );
}
