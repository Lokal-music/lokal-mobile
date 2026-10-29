import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'lokal_player_artwork.dart';

/// The motion shared by Now Playing and the mini player, like Apple Music:
/// one 0..1 value (0 = sunk into the mini player, 1 = open) that a finger
/// moves directly and a spring settles, so a release carries on in one
/// movement from wherever the finger let go.
abstract final class LokalPlayerMotion {
  /// Close to critically damped, so it lands without wobbling.
  static final spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 210,
    ratio: 1,
  );

  // The opening sheet used the same slow critical-damping tail as dismissal.
  // On a high-refresh display it appeared to stall just before reaching the
  // top. Keep dismissal's familiar resistance but settle opening sooner,
  // without an underdamped bounce or a separate final snap.
  static final openingSpring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 390,
    ratio: 1,
  );

  /// A release past this share of the way carries on to that end.
  static const double carryFraction = .25;

  /// A release faster than this (logical px/s) decides on its own.
  static const double flickVelocity = 700;

  /// Whether a release at [progress] and [velocityDown] (logical px/s,
  /// positive down) ends open; [fromOpen] when the drag began open.
  static bool opens(
    double progress,
    double velocityDown, {
    required bool fromOpen,
  }) {
    if (velocityDown >= flickVelocity) return false;
    if (velocityDown <= -flickVelocity) return true;
    return fromOpen ? progress > 1 - carryFraction : progress >= carryFraction;
  }

  static SpringSimulation simulation(double from, double to, double velocity) =>
      SpringSimulation(
        to > from ? openingSpring : spring,
        from,
        to,
        velocity,
        snapToEnd: true,
      );

  /// How far the sheet travels for the whole movement: from [startTop]
  /// (the mini player's top) to the top of the screen.
  static double travel(double startTop) => math.max(startTop, 200);

  /// A continuous corner radius through the settling frame and its endpoint.
  /// Clipping remains active at zero to avoid a one-frame repaint of the sheet.
  static double sheetCornerRadius(double progress) =>
      36 * (1 - progress.clamp(0.0, 1.0));

  /// The sheet at [progress]: its top edge between [startTop] and the top
  /// of the screen, rounded while it travels, fading in out of the mini
  /// player, over what's behind dimmed to match.
  static Widget sheet({
    required double progress,
    required double startTop,
    required Widget child,
  }) {
    final p = progress.clamp(0.0, 1.0);
    // Ease the four corners all the way down to zero, rather than
    // retaining a large clip until the last few frames and then dropping
    // ClipRRect entirely at the spring's completion.
    final radius = sheetCornerRadius(p);
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: ColoredBox(color: Colors.black.withValues(alpha: .6 * p)),
        ),
        Transform.translate(
          offset: Offset(0, (1 - p) * startTop),
          child: Opacity(
            opacity: (p / .12).clamp(0.0, 1.0),
            child: ClipRRect(
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(radius),
              child: RepaintBoundary(child: child),
            ),
          ),
        ),
      ],
    );
  }
}

/// Now Playing as a sheet that rises out of the mini player and sinks back
/// into it ([LokalPlayerMotion]), the route's own animation being the shared
/// value: a tap, Back and a drag down on Now Playing ([startDrag], [dragBy],
/// [endDrag]) all move it, and any of them can take over mid-flight. A pull
/// up on the mini player is shown by [LokalPlayerPull] and handed over with
/// [initialProgress]. With reduced motion the sheet still follows the
/// finger, but jumps instead of springing.
class LokalPlayerRoute<T> extends PageRoute<T> {
  LokalPlayerRoute({
    required this.builder,
    this.startTop,
    this.reduceMotion,
    this.initialProgress,
    this.sourceArtwork,
    super.settings,
  }) : _heroes = ValueNotifier(sourceArtwork == null);

  final WidgetBuilder builder;
  final Rect? Function()? sourceArtwork;

  /// Where the sheet's top edge starts from and lands back at (the mini
  /// player's top, in global coordinates), read every frame; null or a null
  /// answer means the bottom of the screen.
  final double? Function()? startTop;

  /// Whether motion is reduced (besides the platform's own setting).
  final bool Function()? reduceMotion;

  /// Opens from here rather than from the mini player: where a finger let
  /// go of [LokalPlayerPull]. Keep the matching Hero active at handoff so the
  /// cover can settle into the full-player artwork and reverse into the footer
  /// when Now Playing is dismissed.
  final double? initialProgress;

  final ValueNotifier<bool> _heroes;

  /// A finger holds the sheet.
  bool _tracking = false;

  /// The navigator told of a user gesture (the artwork follows the finger).
  NavigatorState? _gestureNavigator;

  /// A downward release velocity, logical px/s, for the closing spring.
  double _popVelocity = 0;

  /// The player route [context] sits in, if it is one.
  static LokalPlayerRoute<dynamic>? maybeOf(BuildContext context) {
    final route = ModalRoute.of(context);
    return route is LokalPlayerRoute ? route : null;
  }

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  bool get _reduced {
    if (reduceMotion?.call() ?? false) return true;
    final context = navigator?.context;
    return context != null &&
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
  }

  @override
  Duration get transitionDuration =>
      _reduced ? Duration.zero : const Duration(milliseconds: 360);

  double _height() {
    final context = navigator?.context;
    return context == null
        ? 800.0
        : MediaQuery.maybeSizeOf(context)?.height ?? 800.0;
  }

  double _startTop(double height) =>
      (startTop?.call() ?? height).clamp(0.0, height);

  /// How far the sheet travels, in logical pixels.
  double get travel => LokalPlayerMotion.travel(_startTop(_height()));

  /// The sheet's progress, 0 (at the mini player) to 1 (open).
  double get progress => controller?.value ?? 0;

  @override
  AnimationController createAnimationController() {
    final controller = super.createAnimationController();
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && sourceArtwork == null) {
        _heroes.value = true;
      }
    });
    return controller;
  }

  @override
  Simulation? createSimulation({required bool forward}) {
    final controller = this.controller;
    if (_reduced || controller == null) return null; // A zero duration.
    // From wherever it is, carrying a release's speed, in one movement.
    return forward
        ? LokalPlayerMotion.simulation(controller.value, 1, 0)
        : LokalPlayerMotion.simulation(
            controller.value,
            0,
            -_popVelocity / travel,
          );
  }

  @override
  TickerFuture didPush() {
    if (initialProgress case final from?) {
      controller!.value = from.clamp(0.0, 1.0);
    }
    return super.didPush();
  }

  @override
  bool didPop(T? result) {
    final popped = super.didPop(result);
    _popVelocity = 0;
    _tracking = false;
    _stopGesture();
    return popped;
  }

  @override
  void dispose() {
    _heroes.dispose();
    super.dispose();
  }

  // ───────────────────────────── finger ─────────────────────────────

  /// A finger takes hold of the sheet (stopping any spring).
  void startDrag() {
    final controller = this.controller;
    if (controller == null || !isCurrent) return;
    controller.stop();
    _tracking = true;
    if (_gestureNavigator == null && _heroes.value) {
      final navigator = this.navigator!;
      navigator.didStartUserGesture();
      _gestureNavigator = navigator;
    }
  }

  /// Moves the sheet with the finger; [dyDown] in logical px, positive down.
  void dragBy(double dyDown) {
    final controller = this.controller;
    if (controller == null || !_tracking || !isCurrent) return;
    // Kept off 0: there the route reads as dismissed, ending the flight.
    controller.value = (controller.value - dyDown / travel).clamp(.001, 1.0);
  }

  /// The finger lets go, at [velocityDown] logical px/s (positive down):
  /// the sheet closes or springs back open from where it is.
  void endDrag(double velocityDown) {
    final controller = this.controller;
    if (controller == null || !_tracking || !isCurrent) return;
    _tracking = false;
    if (!LokalPlayerMotion.opens(
      controller.value,
      velocityDown,
      fromOpen: true,
    )) {
      HapticFeedback.lightImpact();
      _popVelocity = math.max(0, velocityDown);
      navigator?.pop();
      return;
    }
    if (_reduced) {
      controller.value = 1;
    } else {
      controller.animateWith(
        LokalPlayerMotion.simulation(
          controller.value,
          1,
          -velocityDown / travel,
        ),
      );
    }
    _stopGesture();
  }

  /// Tells the navigator the gesture is over once the sheet has settled.
  void _stopGesture() {
    final navigator = _gestureNavigator;
    if (navigator == null) return;
    _gestureNavigator = null;
    final controller = this.controller;
    void stop() {
      if (navigator.mounted) navigator.didStopUserGesture();
    }

    if (controller == null || !controller.isAnimating) {
      stop();
      return;
    }
    late final AnimationStatusListener listener;
    listener = (status) {
      if (controller.isAnimating) return;
      controller.removeStatusListener(listener);
      stop();
    };
    controller.addStatusListener(listener);
  }

  // ───────────────────────────── look ─────────────────────────────

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => ValueListenableBuilder<bool>(
    valueListenable: _heroes,
    builder: (context, heroes, child) =>
        HeroMode(enabled: heroes, child: child!),
    child: Builder(builder: builder),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final top = _startTop(MediaQuery.sizeOf(context).height);
      final sheet = LokalPlayerMotion.sheet(
        progress: animation.value,
        startTop: top,
        child: child!,
      );
      return sourceArtwork == null
          ? sheet
          : LokalPlayerMorph(
              progress: animation.value,
              sheetOffset: (1 - animation.value) * top,
              sourceArtwork: sourceArtwork!,
              child: sheet,
            );
    },
  );
}

/// A pull up on the mini player: Now Playing rises under the finger, then
/// on release either springs fully open before handing its existing player
/// state to [LokalPlayerRoute], or sinks back. Shown in the
/// navigator's overlay, because pushing a route mid-drag would cancel the
/// finger.
class LokalPlayerPull {
  LokalPlayerPull._(this._key, this._onClosed);
  final VoidCallback? _onClosed;

  final GlobalKey<_PullSheetState> _key;
  OverlayEntry? _entry;

  /// Starts a pull in [navigator]'s overlay. [builder] builds Now Playing.
  static LokalPlayerPull start(
    NavigatorState navigator, {
    required WidgetBuilder builder,
    required double? Function() startTop,
    required void Function(double progress) onOpen,
    bool Function()? reduceMotion,
    Rect? Function()? sourceArtwork,
    VoidCallback? onClosed,
  }) {
    final pull = LokalPlayerPull._(GlobalKey<_PullSheetState>(), onClosed);
    final entry = OverlayEntry(
      builder: (context) => _PullSheet(
        key: pull._key,
        builder: builder,
        startTop: startTop,
        reduceMotion: reduceMotion,
        takePending: pull._takePending,
        sourceArtwork: sourceArtwork,
        onOpen: (progress) {
          // Remove and push in the same frame. The caller shares the player's
          // GlobalKey with the route, preserving decoded artwork, backdrop
          // phase, listeners and layout instead of mounting a second player.
          pull._remove();
          onOpen(progress);
        },
        onClosed: () {
          pull._remove();
          onClosed?.call();
        },
      ),
    );
    pull._entry = entry;
    navigator.overlay!.insert(entry);
    return pull;
  }

  /// Moves the sheet with the finger; [dyDown] in logical px, positive down.
  void dragBy(double dyDown) {
    final state = _key.currentState;
    if (state == null) {
      _pending += dyDown; // Not built yet: it starts from here.
    } else {
      state.dragBy(dyDown);
    }
  }

  double _pending = 0;

  double _takePending() {
    final pending = _pending;
    _pending = 0;
    return pending;
  }

  /// The finger lets go at [velocityDown] logical px/s (positive down).
  void end(double velocityDown) {
    final state = _key.currentState;
    if (state == null) {
      _remove(); // Let go before the sheet was even built.
      _onClosed?.call();
    } else {
      state.end(velocityDown);
    }
  }

  /// A new gesture can take over an in-flight settling spring.
  void resume() => _key.currentState?.resume();
  void open() => _key.currentState?.open();
  void cancel() => _remove();

  void _remove() {
    final entry = _entry;
    _entry = null;
    if (entry == null) return;
    entry.remove();
    entry.dispose();
  }
}

class _PullSheet extends StatefulWidget {
  const _PullSheet({
    super.key,
    required this.builder,
    required this.startTop,
    required this.onOpen,
    required this.onClosed,
    required this.takePending,
    this.reduceMotion,
    this.sourceArtwork,
  });

  final WidgetBuilder builder;
  final double Function() takePending;
  final double? Function() startTop;
  final void Function(double progress) onOpen;
  final VoidCallback onClosed;
  final bool Function()? reduceMotion;
  final Rect? Function()? sourceArtwork;

  @override
  State<_PullSheet> createState() => _PullSheetState();
}

class _PullSheetState extends State<_PullSheet>
    with SingleTickerProviderStateMixin {
  late final _progress = AnimationController(vsync: this);
  bool _released = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    dragBy(widget.takePending());
  }

  double _startTop() {
    final height = MediaQuery.sizeOf(context).height;
    return (widget.startTop() ?? height).clamp(0.0, height);
  }

  bool get _reduced =>
      (widget.reduceMotion?.call() ?? false) ||
      MediaQuery.disableAnimationsOf(context);

  void dragBy(double dyDown) {
    if (_released) return;
    _progress.value =
        _progress.value - dyDown / LokalPlayerMotion.travel(_startTop());
  }

  void end(double velocityDown) {
    if (_released) return;
    dragBy(widget.takePending());
    _released = true;
    if (LokalPlayerMotion.opens(
      _progress.value,
      velocityDown,
      fromOpen: false,
    )) {
      HapticFeedback.selectionClick();
      _settleOpen(velocityDown);
      return;
    }
    if (_reduced || _progress.value == 0) {
      widget.onClosed();
      return;
    }
    _progress
        .animateBackWith(
          LokalPlayerMotion.simulation(
            _progress.value,
            0,
            -velocityDown / LokalPlayerMotion.travel(_startTop()),
          ),
        )
        .then((_) {
          if (mounted && _released) widget.onClosed();
        });
  }

  void resume() {
    _progress.stop();
    _released = false;
  }

  void open() {
    _released = true;
    _settleOpen(0);
  }

  void _settleOpen(double velocityDown) {
    if (_reduced || _progress.value == 1) {
      widget.onOpen(1);
      return;
    }
    _progress
        .animateWith(
          LokalPlayerMotion.simulation(
            _progress.value,
            1,
            -velocityDown / LokalPlayerMotion.travel(_startTop()),
          ),
        )
        .then((_) {
          if (mounted && _released) widget.onOpen(1);
        });
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    // The finger that pulls it belongs to the mini player underneath.
    child: AnimatedBuilder(
      animation: _progress,
      child: HeroMode(
        enabled: false,
        child: TickerMode(
          enabled: false,
          child: Builder(builder: widget.builder),
        ),
      ),
      builder: (context, child) {
        final sheet = LokalPlayerMotion.sheet(
          progress: _progress.value,
          startTop: _startTop(),
          child: child!,
        );
        return widget.sourceArtwork == null
            ? sheet
            : LokalPlayerMorph(
                progress: _progress.value,
                sheetOffset: (1 - _progress.value) * _startTop(),
                sourceArtwork: widget.sourceArtwork!,
                child: sheet,
              );
      },
    ),
  );
}
