import 'dart:async';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared non-dismissive song-row gestures: right appends to queue, left
/// schedules Play next. A persistent setting reverses both directions.
/// The gesture preserves normal taps, long presses, and vertical scrolling.
class LokalSwipeToQueue extends ConsumerStatefulWidget {
  const LokalSwipeToQueue({
    super.key,
    required this.child,
    this.song,
    this.onQueue,
    this.onNext,
    this.enabled = true,
  }) : assert(song != null || onQueue != null || onNext != null);

  final Widget child;
  final Song? song;

  /// Online sources supply their own queue operations so pending tracks keep
  /// source verification and correct playback context.
  final FutureOr<void> Function()? onQueue;
  final FutureOr<void> Function()? onNext;
  final bool enabled;

  @override
  ConsumerState<LokalSwipeToQueue> createState() => _LokalSwipeToQueueState();
}

class _LokalSwipeToQueueState extends ConsumerState<LokalSwipeToQueue> {
  static const double _threshold = 72;
  static const double _maxTravel = 104;

  double _drag = 0;
  bool _dragging = false;
  bool _thresholdReached = false;
  bool _queueing = false;

  bool _canPerform(bool next) =>
      next ? widget.onNext != null || widget.song != null
           : widget.onQueue != null || widget.song != null;

  void _start(DragStartDetails details) {
    setState(() => _dragging = true);
  }

  void _update(DragUpdateDetails details) {
    final travel = (_drag + details.delta.dx).clamp(-_maxTravel, _maxTravel);
    if (travel == _drag) return;
    if (travel.abs() >= _threshold && !_thresholdReached) {
      AppHaptics.selection();
    }
    setState(() {
      _drag = travel;
      _thresholdReached = travel.abs() >= _threshold;
    });
  }

  void _reset() {
    if (!mounted) return;
    setState(() {
      _dragging = false;
      _thresholdReached = false;
      _drag = 0;
    });
  }

  void _end(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final right = _drag > 0;
    final commit = _drag.abs() >= _threshold ||
        (_drag.abs() >= 36 && velocity.abs() > 900 && velocity * _drag > 0);
    final reversed = ref.read(appPreferencesProvider).swipeQueueDirectionsReversed;
    _reset();
    if (commit) unawaited(_perform(next: right == reversed));
  }

  Future<void> _perform({required bool next}) async {
    if (!widget.enabled || _queueing || !_canPerform(next)) return;
    _queueing = true;
    try {
      final callback = next ? widget.onNext : widget.onQueue;
      if (callback != null) {
        await callback();
      } else if (widget.song case final song?) {
        final player = ref.read(playerProvider.notifier);
        final index = await player.addToQueue(song);
        if (next && index > 0) await player.moveQueueItemToNext(index);
        if (mounted) {
          LokalToast.show(context, next
              ? lokalText('“{arg0}” plays next', args: {'arg0': song.title})
              : lokalText('Added “{arg0}” to the queue', args: {'arg0': song.title}));
        }
      }
    } catch (_) {
      if (mounted) {
        LokalToast.show(context, next
            ? lokalText('Couldn’t play this song next.')
            : lokalText('Couldn’t add this song to the queue.'));
      }
    } finally {
      _queueing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.lokal.accent;
    final reversed = ref.watch(appPreferencesProvider.select(
        (prefs) => prefs.swipeQueueDirectionsReversed));
    final rightMeansNext = reversed;

    return Semantics(
      customSemanticsActions: widget.enabled
          ? {
              if (_canPerform(false))
                CustomSemanticsAction(label: l10n.addToQueue2):
                    () => unawaited(_perform(next: false)),
              if (_canPerform(true))
                CustomSemanticsAction(label: l10n.playNext):
                    () => unawaited(_perform(next: true)),
            }
          : const {},
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: widget.enabled ? _start : null,
        onHorizontalDragUpdate: widget.enabled ? _update : null,
        onHorizontalDragEnd: widget.enabled ? _end : null,
        onHorizontalDragCancel: widget.enabled ? _reset : null,
        child: ClipRect(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: _drag),
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            builder: (context, offset, child) {
              // Use the animated position, not the reset drag target, so the
              // action icon does not flip while the row springs back.
              final directionNext =
                  offset > 0 ? rightMeansNext : !rightMeansNext;
              return Stack(
                children: [
                  if (offset != 0)
                    Positioned(
                      left: offset > 0 ? 0 : null,
                      right: offset < 0 ? 0 : null,
                      top: 0,
                      bottom: 0,
                      width: offset.abs(),
                      child: ClipRect(
                        child: ColoredBox(
                          color: accent.withValues(alpha: 0.16),
                          child: Align(
                            alignment: offset > 0
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 23),
                              child: Icon(
                                directionNext
                                    ? Icons.queue_play_next_rounded
                                    : Icons.queue_music_rounded,
                                size: 27,
                                color: accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  ),
                ],
              );
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
