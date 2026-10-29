import 'package:flick/features/player/widgets/motion_art_widget.dart';
import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/services/motion_art/moving_cover_settings.dart';
import 'package:flick/l10n/l10n.dart';

import '../link/lokal_devices_card.dart';

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/models/song.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/overflow_marquee_title.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/widgets/lokal/lokal_glass.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'konnekted_home.dart';

enum KonnektedTab {
  listen('Home', Icons.home_rounded),
  explore('Search', Icons.search_rounded),
  library('Library', Icons.library_music_rounded),
  settings('You', Icons.person_rounded);

  const KonnektedTab(this.label, this.icon);

  final String label;
  final IconData icon;

  /// The tabs inside the capsule; [explore] is the separate search circle,
  /// as in Apple Music on iOS 26.
  static const capsule = [listen, library, settings];
}

/// Apple Music's iOS 26 tab bar in Lokal glass.
///
/// A mini-player capsule floats above a tab capsule with a sliding lens and
/// a separate search circle. Scrolling down ([collapsed]) shrinks the tabs
/// to the current one and tucks the mini player between it and search.
class KonnektedDock extends StatefulWidget {
  const KonnektedDock({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.miniPlayer,
    this.hasMiniPlayer = true,
    this.collapsed = false,
    this.onExpand,
  });

  final KonnektedTab selected;
  final ValueChanged<KonnektedTab> onSelect;
  final Widget miniPlayer;

  /// Whether [miniPlayer] has a song to show; without one the dock is a
  /// single row and never collapses.
  final bool hasMiniPlayer;
  final bool collapsed;

  /// Tapping the shrunken tab capsule asks for the full dock back.
  final VoidCallback? onExpand;

  static const barHeight = 58.0;
  static const miniHeight = 58.0;
  static const gap = 8.0;
  static const _margin = EdgeInsets.fromLTRB(14, 6, 14, 8);

  /// The dock's full height over a screen whose bottom inset is
  /// [systemInset], for content padding.
  static double reservedHeight({
    required bool hasMiniPlayer,
    double systemInset = 0,
  }) =>
      math.max(systemInset, _margin.bottom) +
      _margin.top +
      barHeight +
      (hasMiniPlayer ? miniHeight + gap : 0);

  @override
  State<KonnektedDock> createState() => _KonnektedDockState();
}

class _KonnektedDockState extends State<KonnektedDock>
    with SingleTickerProviderStateMixin {
  late final _collapse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: _wantsCollapse ? 1 : 0,
  );

  bool get _wantsCollapse => widget.collapsed && widget.hasMiniPlayer;

  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 400,
    ratio: 1,
  );

  @override
  void didUpdateWidget(KonnektedDock old) {
    super.didUpdateWidget(old);
    final target = _wantsCollapse ? 1.0 : 0.0;
    if (old.collapsed == widget.collapsed &&
        old.hasMiniPlayer == widget.hasMiniPlayer)
      return;
    if (target == _collapse.value && !_collapse.isAnimating) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _collapse.value = target;
    } else {
      // Start the reverse on this frame rather than carrying momentum away
      // from the user's new direction. Continuing folds keep their velocity.
      _collapse.animateWith(
        SpringSimulation(
          _spring,
          _collapse.value,
          target,
          _collapse.velocity * (target - _collapse.value) > 0
              ? _collapse.velocity
              : 0,
          // Without this the spring rests a hair short of 0 and the folded
          // layer stays on top of the tabs, swallowing their taps.
          snapToEnd: true,
        ),
      );
    }
  }

  @override
  void dispose() {
    _collapse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: KonnektedDock._margin,
    // Fixed-height chrome, like iOS: text grows up to a point, and the full
    // player carries large text beyond it.
    child: MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: LayoutBuilder(
            builder: (context, constraints) => AnimatedBuilder(
              animation: _collapse,
              builder: (context, _) => _layout(constraints.maxWidth),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _layout(double width) {
    const bar = KonnektedDock.barHeight;
    const mini = KonnektedDock.miniHeight;
    const gap = KonnektedDock.gap;
    final t = _collapse.value;
    final hasMini = widget.hasMiniPlayer;
    final top = hasMini ? mini + gap : 0.0;

    final tabsOpen = Rect.fromLTWH(0, top, width - bar - gap, bar);
    final tabsShut = const Rect.fromLTWH(0, 0, bar, bar);
    final searchOpen = Rect.fromLTWH(width - bar, top, bar, bar);
    final searchShut = Rect.fromLTWH(width - bar, 0, bar, bar);
    final miniOpen = Rect.fromLTWH(0, 0, width, mini);
    final miniShut = Rect.fromLTWH(bar + gap, 0, width - 2 * (bar + gap), bar);

    return SizedBox(
      height: lerpDouble(top + bar, bar, t),
      // Its own ink layer, so tap ripples draw on the glass rather than on
      // the page underneath, where the glass would blur them.
      child: Material(
        type: MaterialType.transparency,
        // One backdrop capture for all three pieces of frosted glass.
        child: BackdropGroup(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (hasMini)
                Positioned.fromRect(
                  rect: Rect.lerp(miniOpen, miniShut, t)!,
                  child: LokalGlass.capsule(
                    grouped: true,
                    child: KonnektedMiniPlayerScope(
                      collapsed: t > .5,
                      child: widget.miniPlayer,
                    ),
                  ),
                ),
              Positioned.fromRect(
                rect: Rect.lerp(tabsOpen, tabsShut, t)!,
                child: _TabCapsule(
                  width: tabsOpen.width,
                  collapse: t,
                  selected: widget.selected,
                  onSelect: widget.onSelect,
                  onExpand: widget.onExpand,
                ),
              ),
              Positioned.fromRect(
                rect: Rect.lerp(searchOpen, searchShut, t)!,
                child: _SearchCircle(
                  selected: widget.selected == KonnektedTab.explore,
                  onTap: () => widget.onSelect(KonnektedTab.explore),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tells the mini player whether it sits tucked between the circles.
class KonnektedMiniPlayerScope extends InheritedWidget {
  const KonnektedMiniPlayerScope({
    super.key,
    required this.collapsed,
    required super.child,
  });

  final bool collapsed;

  static bool collapsedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<KonnektedMiniPlayerScope>()
          ?.collapsed ??
      false;

  @override
  bool updateShouldNotify(KonnektedMiniPlayerScope old) =>
      collapsed != old.collapsed;
}

class _TabCapsule extends StatefulWidget {
  const _TabCapsule({
    required this.width,
    required this.collapse,
    required this.selected,
    required this.onSelect,
    required this.onExpand,
  });

  /// The open capsule's width; the tabs keep it while the capsule shrinks.
  final double width;
  final double collapse;
  final KonnektedTab selected;
  final ValueChanged<KonnektedTab> onSelect;
  final VoidCallback? onExpand;

  @override
  State<_TabCapsule> createState() => _TabCapsuleState();
}

class _TabCapsuleState extends State<_TabCapsule> {
  static const _tabs = KonnektedTab.capsule;
  static const _inset = 4.0;

  /// The lens follows a dragging finger, like iOS 26's tab bar.
  double? _dragX;
  int? _dragIndex;

  double get _slot => (widget.width - 2 * _inset) / _tabs.length;

  int _indexAt(double x) =>
      ((x - _inset) / _slot).floor().clamp(0, _tabs.length - 1);

  void _drag(double x) {
    final index = _indexAt(x);
    if (index != _dragIndex) {
      HapticFeedback.selectionClick();
      _dragIndex = index;
    }
    setState(() => _dragX = x);
  }

  void _endDrag() {
    final index = _dragIndex;
    setState(() {
      _dragX = null;
      _dragIndex = null;
    });
    if (index != null && _tabs[index] != widget.selected) {
      widget.onSelect(_tabs[index]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final selectedIndex = _tabs.indexOf(widget.selected);
    final shown = selectedIndex < 0 ? KonnektedTab.listen : widget.selected;
    final lensLeft = _dragX != null
        ? (_dragX! - _slot / 2).clamp(_inset, widget.width - _inset - _slot)
        : _inset + _slot * (selectedIndex < 0 ? 0 : selectedIndex);
    final open = 1 - widget.collapse;

    // The bar swells by 16 px while the lens is dragged: glass you can
    // push on.
    return AnimatedScale(
      scale: _dragX != null && !reduceMotion ? 1 + 16 / widget.width : 1,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: LokalGlass.capsule(
        grouped: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (open > 0)
              IgnorePointer(
                ignoring: widget.collapse > .5,
                child: Opacity(
                  opacity: Curves.easeIn.transform(open),
                  child: ExcludeSemantics(
                    excluding: widget.collapse > .5,
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: widget.width,
                      maxWidth: widget.width,
                      child: GestureDetector(
                        onHorizontalDragStart: (d) => _drag(d.localPosition.dx),
                        onHorizontalDragUpdate: (d) =>
                            _drag(d.localPosition.dx),
                        onHorizontalDragEnd: (_) => _endDrag(),
                        onHorizontalDragCancel: _endDrag,
                        child: Stack(
                          children: [
                            AnimatedPositioned(
                              duration: reduceMotion || _dragX != null
                                  ? Duration.zero
                                  : const Duration(milliseconds: 380),
                              curve: Curves.easeOutBack,
                              left: lensLeft,
                              top: _inset,
                              bottom: _inset,
                              width: _slot,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 200),
                                opacity: selectedIndex < 0 && _dragX == null
                                    ? 0
                                    : 1,
                                child: AnimatedScale(
                                  duration: const Duration(milliseconds: 200),
                                  scale: _dragX != null && !reduceMotion
                                      ? 1.08
                                      : 1,
                                  child: _Lens(
                                    color: t.accent,
                                    active: _dragX != null && !reduceMotion,
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(_inset),
                              child: Row(
                                children: [
                                  for (final (i, tab) in _tabs.indexed)
                                    Expanded(
                                      child: _TabButton(
                                        tab: tab,
                                        selected: _dragIndex != null
                                            ? i == _dragIndex
                                            : tab == widget.selected,
                                        onTap: () => widget.onSelect(tab),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.collapse > 0)
              IgnorePointer(
                ignoring: widget.collapse <= .5,
                child: Opacity(
                  opacity: Curves.easeOut.transform(widget.collapse),
                  child: ExcludeSemantics(
                    excluding: widget.collapse <= .5,
                    child: Semantics(
                      button: true,
                      label: lokalText(
                        "Show tabs. {arg0}",
                        args: {'arg0': shown.label},
                      ),
                      onTap: widget.onExpand,
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: widget.onExpand,
                        customBorder: const CircleBorder(),
                        child: Icon(shown.icon, color: t.accent, size: 24),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The selection lens: a brighter pane of glass under the current tab.
class _Lens extends StatelessWidget {
  const _Lens({required this.color, this.active = false});

  final Color color;

  /// While a finger drags it, the lens turns clear and refracts the tabs
  /// under it with a rainbow fringe, as in iOS 26.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final light = context.lokal.isLight;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: active ? 1 : 0),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => LokalClearLens(
        lens: const LokalLens(height: 10, amount: 14, dispersion: 1).scale(t),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: StadiumBorder(
              side: BorderSide(
                color: Colors.white.withValues(alpha: light ? .7 : .12),
              ),
            ),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(
                  color,
                  Colors.white,
                  .25,
                )!.withValues(alpha: .20 * (1 - t)),
                color.withValues(alpha: .12 * (1 - t)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final KonnektedTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? context.lokal.accent : context.lokal.text;
    return Semantics(
      selected: selected,
      button: true,
      label: tab.label,
      onTap: onTap,
      child: Tooltip(
        message: tab.label,
        excludeFromSemantics: true,
        child: InkWell(
          onTap: onTap,
          excludeFromSemantics: true,
          customBorder: const StadiumBorder(),
          child: ExcludeSemantics(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(tab.icon, size: 22, color: color),
                const SizedBox(height: 2),
                Text(
                  tab.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchCircle extends StatelessWidget {
  const _SearchCircle({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    const tab = KonnektedTab.explore;
    return Semantics(
      selected: selected,
      button: true,
      label: tab.label,
      onTap: onTap,
      child: Tooltip(
        message: tab.label,
        excludeFromSemantics: true,
        child: LokalGlass.capsule(
          grouped: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: selected ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: _Lens(color: t.accent),
                ),
              ),
              InkWell(
                onTap: onTap,
                excludeFromSemantics: true,
                customBorder: const CircleBorder(),
                child: Icon(
                  tab.icon,
                  size: 26,
                  color: selected ? t.accent : t.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Only the transport adapter subscribes to playback. Position ticks rebuild a
/// three-pixel progress strip, not the home shelves or the navigator.
class KonnektedMiniPlayer extends ConsumerWidget {
  const KonnektedMiniPlayer({
    super.key,
    required this.onOpen,
    required this.onQueue,
    this.onPullUpStart,
    this.onPullUpUpdate,
    this.onPullUpEnd,
    this.artworkKey,
  });

  final Key? artworkKey;
  final VoidCallback onOpen;
  final VoidCallback onQueue;

  /// A finger pulls the mini player up into Now Playing: see
  /// [KonnektedMiniPlayerContent.onPullUpStart].
  final VoidCallback? onPullUpStart;
  final ValueChanged<double>? onPullUpUpdate;
  final ValueChanged<double>? onPullUpEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(currentSongProvider);
    if (song == null) return const SizedBox.shrink();
    return KonnektedMiniPlayerContent(
      song: song,
      artworkKey: artworkKey,
      isPlaying: ref.watch(isPlayingProvider),
      onOpen: onOpen,
      onQueue: onQueue,
      onPullUpStart: onPullUpStart,
      onPullUpUpdate: onPullUpUpdate,
      onPullUpEnd: onPullUpEnd,
      onPlayPause: () {
        AppHaptics.doublePulse();
        _transport(context, () => ref.read(playerProvider.notifier).togglePlayPause());
      },
      onNext: () {
        AppHaptics.triplePulse();
        _transport(context, () => ref.read(playerProvider.notifier).next());
      },
      onPrevious: () {
        AppHaptics.triplePulse();
        _transport(context, () => ref.read(playerProvider.notifier).previous());
      },
      progress: Consumer(
        builder: (context, ref, _) {
          final value = ref.watch(progressProvider);
          return LinearProgressIndicator(
            value: value.isFinite ? value.clamp(0.0, 1.0) : 0,
            minHeight: 2,
            backgroundColor: Colors.white.withValues(alpha: .06),
            color: context.lokal.accent,
            semanticsLabel: 'Track progress',
          );
        },
      ),
    );
  }

  Future<void> _transport(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted) {
        LokalToast.show(
          context,
          lokalText('Playback couldn’t be changed. Please try again.'),
        );
      }
    }
  }
}

class KonnektedMiniPlayerContent extends StatelessWidget {
  const KonnektedMiniPlayerContent({
    super.key,
    required this.song,
    required this.isPlaying,
    required this.onOpen,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrevious,
    required this.onQueue,
    required this.progress,
    this.onPullUpStart,
    this.onPullUpUpdate,
    this.onPullUpEnd,
    this.artworkKey,
  });

  final Song song;
  final bool isPlaying;
  final Key? artworkKey;
  final VoidCallback onOpen;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onQueue;
  final Widget progress;

  /// A drag that starts upward on the mini player opens Now Playing under
  /// the finger: this starts it, [onPullUpUpdate] follows each movement
  /// (logical px, positive down, as the sheet moves) and [onPullUpEnd] gets
  /// the release velocity (logical px/s, positive down).
  final VoidCallback? onPullUpStart;
  final ValueChanged<double>? onPullUpUpdate;
  final ValueChanged<double>? onPullUpEnd;

  /// Shared with the full player's artwork, so it grows into Now Playing.
  static const heroTag = 'konnekted-player-art';

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (onPullUpStart == null) return body;
    return _PullUp(
      onStart: onPullUpStart!,
      onUpdate: onPullUpUpdate,
      onEnd: onPullUpEnd,
      onPrevious: onPrevious,
      onNext: onNext,
      child: body,
    );
  }

  Widget _body(BuildContext context) {
    final tucked = KonnektedMiniPlayerScope.collapsedOf(context);
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                tucked ||
                constraints.maxWidth < 360 ||
                MediaQuery.textScalerOf(context).scale(14) > 23;
            return Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      button: true,
                      label: lokalText(
                        "Open player for {arg0} by {arg1}. Lyrics and playback controls.",
                        args: {'arg0': song.title, 'arg1': song.artist},
                      ),
                      onTap: onOpen,
                      child: InkWell(
                        onTap: onOpen,
                        excludeFromSemantics: true,
                        customBorder: const StadiumBorder(),
                        child: ExcludeSemantics(
                          child: Row(
                            children: [
                              Hero(
                                tag: heroTag,
                                // The artwork travels directly between the
                                // two real layouts, like BitChord's docked art.
                                createRectTween: (begin, end) =>
                                    RectTween(begin: begin, end: end),
                                flightShuttleBuilder: _flight,
                                child: SizedBox(
                                  key: artworkKey,
                                  width: 42,
                                  height: 42,
                                  child: _MiniMotionArtwork(
                                    song: song,
                                    playing: isPlaying,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Match the other mini-player layouts:
                                    // only pan if the title exceeds the space
                                    // left by artwork and playback controls.
                                    // A song ID key restarts at the beginning
                                    // instead of inheriting the old scroll.
                                    OverflowMarqueeTitle(
                                      key: ValueKey('dock-mini-title:${song.id}'),
                                      title: song.title,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (!tucked) ...[
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              song.artist,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: context.lokal.muted,
                                              ),
                                            ),
                                          ),
                                          const Flexible(
                                            child: LokalOutputPill(),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: isPlaying ? lokalText('Pause') : lokalText('Play'),
                    onPressed: onPlayPause,
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 28,
                    ),
                  ),
                  if (!compact)
                    IconButton(
                      tooltip: lokalText('Next track'),
                      onPressed: onNext,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                  if (!tucked)
                    IconButton(
                      tooltip: lokalText('Open queue'),
                      onPressed: onQueue,
                      icon: const Icon(Icons.queue_music_rounded, size: 22),
                    ),
                ],
              ),
            );
          },
        ),
        Positioned(left: 24, right: 24, bottom: 0, child: progress),
      ],
    );
  }

  /// Rounds the artwork from the mini player's circle to the normal
  /// full player's actual 20 px corner radius, in both directions.
  Widget _flight(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromContext,
    BuildContext toContext,
  ) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) => ClipRRect(
      borderRadius: BorderRadius.circular(
        lerpDouble(21, 20, Curves.easeInOutCubic.transform(animation.value))!,
      ),
      child: child,
    ),
    child: _MiniMotionArtwork(song: song, playing: isPlaying, flight: true),
  );
}

/// Hands a drag that starts upward over to Now Playing; one that starts
/// downward is left alone.
class _PullUp extends StatefulWidget {
  const _PullUp({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onPrevious,
    required this.onNext,
    required this.child,
  });

  final VoidCallback onStart;
  final ValueChanged<double>? onUpdate;
  final ValueChanged<double>? onEnd;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Widget child;

  @override
  State<_PullUp> createState() => _PullUpState();
}

class _PullUpState extends State<_PullUp> {
  /// Whether this drag opened Now Playing (null: no direction yet).
  bool? _pulling;
  double _horizontalDelta = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onVerticalDragStart: (_) => _pulling = null,
    onVerticalDragUpdate: (d) {
      if (_pulling == null) {
        _pulling = d.delta.dy < 0;
        if (_pulling!) widget.onStart();
      }
      if (_pulling!) widget.onUpdate?.call(d.delta.dy);
    },
    onVerticalDragEnd: (d) {
      if (_pulling ?? false) widget.onEnd?.call(d.primaryVelocity ?? 0);
      _pulling = null;
    },
    onVerticalDragCancel: () {
      if (_pulling ?? false) widget.onEnd?.call(0);
      _pulling = null;
    },
    onHorizontalDragStart: (_) => _horizontalDelta = 0,
    onHorizontalDragUpdate: (d) => _horizontalDelta += d.delta.dx,
    onHorizontalDragEnd: (d) {
      final velocity = d.primaryVelocity ?? 0;
      final direction = velocity.abs() >= 500 ? velocity : _horizontalDelta;
      _horizontalDelta = 0;
      if (direction <= -48) {
        widget.onNext();
      } else if (direction >= 48) {
        widget.onPrevious();
      }
    },
    onHorizontalDragCancel: () => _horizontalDelta = 0,
    child: widget.child,
  );
}

class _MiniMotionArtwork extends ConsumerWidget {
  const _MiniMotionArtwork({
    required this.song,
    required this.playing,
    this.flight = false,
  });
  final bool flight;
  final Song song;
  final bool playing;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPreferencesProvider);
    final enabled =
        prefs.animatedAlbumArt &&
        prefs.animationsEnabled &&
        song.filePath != null &&
        !song.isPending &&
        !ref
            .watch(movingCoverSettingsProvider)
            .disabledSongs
            .contains(movingCoverSongKey(song));
    final still = flight
        ? CachedImageWidget(
            imagePath: song.albumArt,
            audioSourcePath: song.filePath,
            fit: BoxFit.cover,
            placeholder: ColoredBox(color: context.lokal.surface3),
            errorWidget: ColoredBox(color: context.lokal.surface3),
          )
        : KonnektedArtwork(song: song, size: 42, radius: 21);
    if (!enabled) return still;
    final art = MotionArtView(
      sharedPlaybackKey: 'player:${song.id}',
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration,
      playbackActive: playing,
      borderRadius: flight ? null : BorderRadius.circular(21),
      fallback: still,
    );
    return flight ? art : ClipOval(child: art);
  }
}
