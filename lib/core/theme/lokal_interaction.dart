import 'package:flutter/material.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/core/constants/app_constants.dart';

/// Motion tokens shared by catalogue surfaces and ordinary navigation.
abstract final class LokalMotion {
  static const press = Duration(milliseconds: 170);
  static const release = Duration(milliseconds: 360);
  static const enter = Duration(milliseconds: 340);
  static const exit = Duration(milliseconds: 250);
  static const pressedScale = .968;
  static const enterScale = .982;
}

/// A restrained spring on release. Gesture arbitration stays with InkWell, so
/// list scrolling, horizontal swipes and long-press menus are not stolen.
class LokalPressable extends StatefulWidget {
  const LokalPressable({
    super.key,
    required this.child,
    required this.onTap,
    this.radius = 20,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  final String? semanticLabel;

  @override
  State<LokalPressable> createState() => _LokalPressableState();
}

class _LokalPressableState extends State<LokalPressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final t = context.lokal;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: AnimatedScale(
        scale: reduced || !_pressed ? 1 : LokalMotion.pressedScale,
        alignment: Alignment.center,
        duration: reduced
            ? Duration.zero
            : (_pressed ? LokalMotion.press : LokalMotion.release),
        curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(widget.radius),
          child: InkWell(
            borderRadius: BorderRadius.circular(widget.radius),
            onHighlightChanged: (value) {
              if (mounted && _pressed != value) {
                setState(() => _pressed = value);
              }
            },
            onTap: widget.onTap == null
                ? null
                : () {
                    AppHaptics.tap();
                    widget.onTap!();
                  },
            splashColor: t.accent.withValues(alpha: .12),
            highlightColor: t.accent.withValues(alpha: .06),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// On touch devices, scrollable surfaces settle with a bounded elastic
/// response. Desktop pointer scrolling retains its platform physics.
/// DisableAnimations removes the extra elasticity for accessibility.
class LokalScrollBehavior extends MaterialScrollBehavior {
  const LokalScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context) ||
        AppConstants.animationNormal == Duration.zero) {
      return const ClampingScrollPhysics();
    }
    final platform = getPlatform(context);
    if (platform == TargetPlatform.android || platform == TargetPlatform.iOS) {
      return const BouncingScrollPhysics(
        decelerationRate: ScrollDecelerationRate.normal,
      );
    }
    return super.getScrollPhysics(context);
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
