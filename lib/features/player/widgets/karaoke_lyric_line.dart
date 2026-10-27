import 'lyric_motion_line.dart';
import 'lyrics_subline_timing.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/player_service.dart';

/// Renders a single lyric line as karaoke-style text: a soft highlight
/// sweeps through the words in reading order based on playback position.
/// Real enhanced-LRC word timings drive the sweep; plain synced lines fall
/// back to a single whole-line window.
///
/// The widget subscribes to [PlayerService.positionNotifier] and
/// extrapolates between engine ticks with a frame ticker, so the sweep stays
/// smooth even when position updates arrive infrequently.
class KaraokeLyricLine extends StatefulWidget {
  final PlayerService playerService;
  final LyricsService lyricsService;
  final LyricsData lyrics;
  final int lineIndex;
  final TextAlign textAlign;
  final TextStyle style;
  final Color sungColor;
  final Color unsungColor;

  /// Optional translated or romanized text to animate to the source vocal.
  final String? sublineText;

  /// Position source to sweep against. Defaults to the player's own position;
  /// carousel peek stages pass a static source so their sweep stays put.
  final ValueNotifier<Duration>? positionNotifier;

  /// False for peek stages: no ticker, no sweep.
  final bool active;

  const KaraokeLyricLine({
    super.key,
    required this.playerService,
    required this.lyricsService,
    required this.lyrics,
    required this.lineIndex,
    required this.textAlign,
    required this.style,
    required this.sungColor,
    required this.unsungColor,
    this.sublineText,
    this.positionNotifier,
    this.active = true,
  });

  @override
  State<KaraokeLyricLine> createState() => _KaraokeLyricLineState();
}

class _KaraokeLyricLineState extends State<KaraokeLyricLine>
    with SingleTickerProviderStateMixin {
  static const double _fillEpsilon = 0.0004;

  late List<LyricsWord> _segments;
  late LyricsLine _displayLine;
  Duration _basePosition = Duration.zero;
  Duration _tickerElapsed = Duration.zero;
  Duration _baseTickerElapsed = Duration.zero;
  bool _isPlaying = false;
  Ticker? _ticker;
  List<double> _lastFills = const [];
  int _builtForLineIndex = -1;
  LyricsData? _builtForLyrics;

  ValueNotifier<Duration> get _positionNotifier =>
      widget.positionNotifier ?? widget.playerService.positionNotifier;

  @override
  void initState() {
    super.initState();
    _basePosition = _positionNotifier.value;
    _isPlaying = widget.playerService.isPlayingNotifier.value;
    _positionNotifier.addListener(_onPositionTick);
    widget.playerService.isPlayingNotifier.addListener(_onPlayingChanged);
    _resolveWords();
    _updateTicker();
  }

  @override
  void didUpdateWidget(covariant KaraokeLyricLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldNotifier =
        oldWidget.positionNotifier ?? oldWidget.playerService.positionNotifier;
    if (!identical(oldNotifier, _positionNotifier)) {
      oldNotifier.removeListener(_onPositionTick);
      _basePosition = _positionNotifier.value;
      _baseTickerElapsed = _tickerElapsed;
      _positionNotifier.addListener(_onPositionTick);
    }
    if (!identical(oldWidget.lyrics, widget.lyrics) ||
        oldWidget.lineIndex != widget.lineIndex ||
        oldWidget.sublineText != widget.sublineText) {
      _resolveWords();
      _onPositionTick();
      return;
    }
    if (oldWidget.active != widget.active) {
      _onPositionTick();
      return;
    }
    _updateTicker();
  }

  void _resolveWords() {
    final sourceLine = widget.lyrics.lines[widget.lineIndex];
    _displayLine = widget.sublineText == null
        ? sourceLine
        : projectLyricsSubline(sourceLine, widget.sublineText!);
    _segments = _displayLine.words ?? const [];
    _builtForLineIndex = widget.lineIndex;
    _builtForLyrics = widget.lyrics;
    _lastFills = const [];
  }

  void _onPositionTick() {
    _basePosition = _positionNotifier.value;
    _baseTickerElapsed = _tickerElapsed;
    _updateTicker();
  }

  void _onPlayingChanged() {
    // Freeze extrapolation at the exact current predicted position so
    // pausing does not jump the fill forward.
    _basePosition = _predictedPosition();
    _baseTickerElapsed = _tickerElapsed;
    _isPlaying = widget.playerService.isPlayingNotifier.value;
    _updateTicker();
  }

  void _updateTicker() {
    final shouldRun =
        widget.active && _isPlaying && _segments.isNotEmpty && mounted;
    if (shouldRun && _ticker == null) {
      _tickerElapsed = Duration.zero;
      _baseTickerElapsed = Duration.zero;
      _ticker = createTicker(_onFrame);
      _ticker!.start();
    } else if (!shouldRun && _ticker != null) {
      _ticker!.dispose();
      _ticker = null;
      _rebuildIfFillsChanged();
    }
  }

  Duration _predictedPosition() {
    if (!_isPlaying) return _basePosition;
    final ahead = _tickerElapsed - _baseTickerElapsed;
    if (ahead < Duration.zero) return _basePosition;
    return _basePosition +
        Duration(
          microseconds:
              (ahead.inMicroseconds.clamp(0, 600000) *
                      widget.playerService.playbackSpeedNotifier.value)
                  .round(),
        );
  }

  void _onFrame(Duration elapsed) {
    _tickerElapsed = elapsed;
    _rebuildIfFillsChanged();
  }

  void _rebuildIfFillsChanged() {
    if (_segments.isEmpty || !mounted) return;

    final position = _predictedPosition();
    final nextFills = <double>[
      for (final segment in _segments)
        LyricsService.fillForWord(segment, position),
    ];

    final previous = _lastFills;
    var changed = previous.length != nextFills.length;
    if (!changed) {
      for (var i = 0; i < nextFills.length; i++) {
        if ((previous[i] - nextFills[i]).abs() > _fillEpsilon) {
          changed = true;
          break;
        }
      }
    }
    if (!changed &&
        !_segments.any(
          (w) =>
              position >= w.start &&
              position < w.end + const Duration(milliseconds: 700),
        ))
      return;

    setState(() => _lastFills = nextFills);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _positionNotifier.removeListener(_onPositionTick);
    widget.playerService.isPlayingNotifier.removeListener(_onPlayingChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_builtForLineIndex != widget.lineIndex ||
        !identical(_builtForLyrics, widget.lyrics)) {
      _resolveWords();
    }

    if (_segments.isEmpty) {
      return Text(
        _displayLine.text,
        textAlign: widget.textAlign,
        style: widget.style,
      );
    }

    return LyricMotionLine(
      line: _displayLine,
      position: _predictedPosition(),
      style: widget.style,
      sung: widget.sungColor,
      unsung: widget.unsungColor,
      textAlign: widget.textAlign,
    );
  }
}
