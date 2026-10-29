import 'dart:math' as math;

import 'cloud_cover_reveal.dart';

import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter/scheduler.dart' show TickerCanceled;
import 'package:flutter/services.dart';
import 'package:flick/models/song.dart';

/// Cover stages follow the finger, then keep the incoming neighbour in place
/// while playback commits. Controls and the artwork backdrop stay stationary.
class SongStageCarousel extends StatefulWidget {
  const SongStageCarousel({
    super.key,
    required this.currentSong,
    required this.nextSong,
    required this.prevSong,
    required this.stageBuilder,
    required this.onNext,
    required this.onPrevious,
    this.enabled = true,
    this.buttonDissolve = false,
    this.onDragStateChanged,
  });
  final Song currentSong;
  final Song? nextSong, prevSong;
  final Widget Function(Song song) stageBuilder;
  final Future<void> Function() onNext, onPrevious;
  final bool enabled;
  /// Transport buttons dissolve; horizontal drags keep the original slide.
  final bool buttonDissolve;
  final ValueChanged<bool>? onDragStateChanged;

  @override
  State<SongStageCarousel> createState() => SongStageCarouselState();
}

class SongStageCarouselState extends State<SongStageCarousel>
    with TickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);
  late final _dissolve = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
    value: 1,
  )..addStatusListener((status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _dissolveFrom = null);
    }
  });
  Song? _dissolveFrom;
  bool _buttonChangePending = false;
  late Animation<double> _animation;
  double _offset = 0;
  bool _dragging = false, _animating = false, _committing = false;
  late Song _current;
  Song? _next, _previous;

  @override
  void initState() {
    super.initState();
    _syncSongs();
    _controller.addListener(() {
      if (_animating) setState(() => _offset = _animation.value);
    });
  }

  void _syncSongs() {
    _current = widget.currentSong;
    _next = widget.nextSong;
    _previous = widget.prevSong;
  }

  @override
  void didUpdateWidget(SongStageCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentSong.id != widget.currentSong.id) {
      final reveal = _buttonChangePending && widget.buttonDissolve;
      _buttonChangePending = false;
      _controller.stop();
      _animating = false;
      _offset = 0;
      _dragging = false;
      widget.onDragStateChanged?.call(false);
      _dissolve.stop();
      _dissolveFrom = reveal ? _current : null;
      _syncSongs();
      if (reveal) {
        // Start only once the real playback target is known. Shuffle and
        // source-dependent next songs may differ from the queue preview.
        _dissolve.forward(from: 0);
      } else {
        _dissolve.value = 1;
      }
    } else if (!_dragging && !_animating && !_committing && _offset == 0) {
      // Queue notifications can arrive before the current-song notification.
      // Never swap the visible incoming neighbour during a pending commit.
      _syncSongs();
    }
  }

  double get _width => context.size?.width ?? MediaQuery.sizeOf(context).width;

  Future<bool> _moveTo(double target) async {
    if (!mounted) return false;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _offset = target);
      return true;
    }
    _animating = true;
    _animation = Tween(
      begin: _offset,
      end: target,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    // A short remainder settles quickly; it does not restart a full slide.
    final distance = ((_offset - target).abs() / math.max(_width, 1)).clamp(
      0.0,
      1.0,
    );
    _controller.duration = Duration(
      milliseconds: (180 + 160 * distance).round(),
    );
    try {
      await _controller.forward(from: 0).orCancel;
      return mounted;
    } on TickerCanceled {
      return false;
    } finally {
      _animating = false;
    }
  }

  Future<void> animateToNext() =>
      _buttonChange(true);

  Future<void> animateToPrevious() =>
      _buttonChange(false);

  Future<void> _buttonChange(bool next) async {
    if (_committing || _animating || _dragging || _buttonChangePending) return;
    final change = next ? widget.onNext : widget.onPrevious;
    if (!widget.buttonDissolve) {
      // Classic player and cover swipes retain their existing slide motion.
      if (!widget.enabled || (next ? _next : _previous) == null) {
        await change();
      } else {
        await _commit(next);
      }
      return;
    }

    final animate = widget.enabled && !MediaQuery.disableAnimationsOf(context);
    if (animate) {
      _buttonChangePending = true;
      // Rapid consecutive skips settle to the last incoming cover, like
      // desktop. Audio is never held back for the visual transition.
      _dissolve.stop();
      if (_dissolveFrom != null) {
        setState(() {
          _dissolveFrom = null;
          _dissolve.value = 1;
        });
      }
    }
    try {
      await change();
    } catch (error) {
      if (mounted) {
        LokalToast.fromSnackBar(
          context,
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      // A no-op (end of queue / failed skip) must not leave the next
      // unrelated song change armed for a dissolve.
      _buttonChangePending = false;
    }
  }

  Future<void> _commit(bool next) async {
    if (_committing) return;
    _committing = true;
    final before = _current.id;
    try {
      if (!await _moveTo(next ? -_width : _width)) return;
      HapticFeedback.selectionClick();
      if (next) {
        await widget.onNext();
      } else {
        await widget.onPrevious();
      }
      // Notifier callbacks schedule the parent's rebuild; the playback future
      // can finish before didUpdateWidget receives the newly selected song.
      // Keep the incoming stage centred until that rebuild has run.
      if (mounted) await WidgetsBinding.instance.endOfFrame;
      // didUpdateWidget replaces the centred incoming stage. If playback did
      // not advance, return to the real current song rather than snapping it.
      if (mounted && _current.id == before) await _moveTo(0);
    } catch (error) {
      if (mounted) {
        await _moveTo(0);
        if (mounted)
          LokalToast.fromSnackBar(context, SnackBar(content: Text(error.toString())));
      }
    } finally {
      _committing = false;
      if (mounted && _offset == 0) setState(_syncSongs);
    }
  }

  void _start(DragStartDetails details) {
    if (!widget.enabled || _committing || _buttonChangePending) return;
    if (_dissolveFrom != null) {
      // The finger always owns the stage: cancel only the visual overlay.
      _dissolve.stop();
      setState(() {
        _dissolveFrom = null;
        _dissolve.value = 1;
      });
    }
    _controller.stop();
    _animating = false;
    _dragging = true;
    widget.onDragStateChanged?.call(true);
  }

  void _update(DragUpdateDetails details) {
    if (!_dragging || !widget.enabled) return;
    var delta = details.delta.dx;
    if ((delta < 0 && _next == null) || (delta > 0 && _previous == null)) {
      delta *= .32 * math.exp(-_offset.abs() / math.max(_width * .6, 1));
    }
    setState(() => _offset = (_offset + delta).clamp(-_width, _width));
  }

  Future<void> _end(DragEndDetails details) async {
    if (!_dragging) return;
    _dragging = false;
    widget.onDragStateChanged?.call(false);
    final velocity = details.primaryVelocity ?? 0;
    final goNext =
        velocity <= -700 || (velocity.abs() < 700 && _offset < -_width * .25);
    final goPrevious =
        velocity >= 700 || (velocity.abs() < 700 && _offset > _width * .25);
    if (goNext && _next != null) {
      await _commit(true);
    } else if (goPrevious && _previous != null) {
      await _commit(false);
    } else {
      await _moveTo(0);
    }
  }

  void _cancel() {
    if (!_dragging) return;
    _dragging = false;
    widget.onDragStateChanged?.call(false);
    _moveTo(0);
  }

  @override
  void dispose() {
    _dissolve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      if (width <= 0) return const SizedBox.shrink();
      Widget stage(Song song, double offset, String slot) {
        final repeated =
            [
              _previous,
              _next,
              _current,
            ].where((item) => item?.id == song.id).length >
            1;
        return Transform.translate(
          // A neighbour keeps its decoded image when it becomes the centre.
          // Slot suffixes also allow queues containing the same song twice.
          key: ValueKey((song.id, repeated ? slot : null)),
          offset: Offset(offset, 0),
          child: RepaintBoundary(child: widget.stageBuilder(song)),
        );
      }

      return ClipRect(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _start,
          onHorizontalDragUpdate: _update,
          onHorizontalDragEnd: _end,
          onHorizontalDragCancel: _cancel,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_dissolveFrom case final oldSong?)
                // Only two stationary stages during button navigation. The
                // old art stays painted behind a single clipped incoming art;
                // no repeated full-player builds or slide transforms.
                stage(oldSong, 0, 'outgoing')
              else ...[
                if (_previous != null)
                  stage(_previous!, -width + _offset, 'previous'),
                if (_next != null) stage(_next!, width + _offset, 'next'),
              ],
              if (_dissolveFrom != null)
                CloudCoverReveal(
                  progress: _dissolve,
                  seed: _current.id.hashCode,
                  child: stage(_current, 0, 'incoming'),
                )
              else
                stage(_current, _offset, 'current'),
            ],
          ),
        ),
      );
    },
  );
}
