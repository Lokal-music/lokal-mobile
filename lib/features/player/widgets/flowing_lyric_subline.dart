import 'package:flutter/material.dart';

import 'package:flick/features/player/widgets/lyric_motion_line.dart';
import 'package:flick/services/lyrics_service.dart';

/// Subline in the main flowing lyrics player. The source vocal's timing is
/// projected and cached by the owning player, never recalculated per frame.
///
/// Only the currently singing rows animate. Neighboring rows stay as cheap,
/// readable static text; untimed lyrics and absent translations do not acquire
/// artificial word timing.
class FlowingLyricSubline extends StatelessWidget {
  const FlowingLyricSubline({
    super.key,
    required this.text,
    required this.position,
    required this.singing,
    required this.style,
    this.timedLine,
    this.lightweight = false,
  });

  final String text;
  final LyricsLine? timedLine;
  final Duration position;
  final bool singing;
  final TextStyle style;
  final bool lightweight;

  @override
  Widget build(BuildContext context) {
    final projected = timedLine;
    if (!singing ||
        projected == null ||
        projected.text != text ||
        projected.words?.isNotEmpty != true) {
      return Text(text, style: style);
    }

    final opacity = (style.color ?? Colors.white).a;
    return LyricMotionLine(
      line: projected,
      position: position,
      style: style,
      sung: Colors.white.withValues(alpha: opacity),
      unsung: Colors.white.withValues(alpha: opacity * .40),
      lightweight: lightweight,
    );
  }
}
