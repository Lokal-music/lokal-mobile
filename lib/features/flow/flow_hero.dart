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

/// Static, tappable Flow mark. No ticker or continuous animations: the Flow
/// screen stays idle when playback state and the selected mood do not change.
class FlowInfinityOrb extends StatelessWidget {
  const FlowInfinityOrb({
    super.key,
    required this.playing,
    required this.onPressed,
  });

  final bool playing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final label = playing ? 'Pause Flow' : 'Play Flow';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: label,
        onTap: onPressed,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: RepaintBoundary(
            child: SizedBox.square(
              dimension: 88,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: t.accent.withValues(alpha: .07),
                      border: Border.all(
                        color: t.accent.withValues(alpha: .20),
                        width: 1.2,
                      ),
                    ),
                  ),
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: t.accent.withValues(alpha: playing ? .42 : .30),
                        width: 1.5,
                      ),
                    ),
                  ),
                  Container(
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
                    ),
                    child: const Icon(
                      Icons.all_inclusive_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
