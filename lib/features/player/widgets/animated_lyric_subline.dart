import 'package:flutter/material.dart';

class AnimatedLyricSubline extends StatelessWidget {
  const AnimatedLyricSubline({
    super.key,
    required this.text,
    required this.style,
    this.motionChild,
    this.textAlign = TextAlign.start,
  });
  final String? text;
  final TextStyle style;
  /// Uses the existing karaoke clock when the original lyrics have timings.
  final Widget? motionChild;
  final TextAlign textAlign;
  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280),
    curve: Curves.easeInOutCubic,
    alignment: Alignment.topCenter,
    child: AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [
          for (final old in previous) Positioned.fill(child: old),
          if (current != null) current,
        ],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, .08),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: text?.isNotEmpty == true
          ? Padding(
              key: ValueKey(text),
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: SizedBox(
                width: double.infinity,
                child: motionChild ?? Text(text!, textAlign: textAlign, style: style),
              ),
            )
          : const SizedBox(width: double.infinity, key: ValueKey('empty')),
    ),
  );
}
