import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:flick/features/player/widgets/lyric_motion_line.dart';
import 'package:flick/services/lyrics_service.dart';

/// Space is available only for genuinely timestamped lyrics.
bool hasImmersiveLyrics(LyricsData? lyrics) =>
    lyrics != null && lyrics.isSynchronized && lyrics.lines.isNotEmpty;

/// Identical line selection and resolved syllable timing to Lyrics mode.
int immersiveLyricsLineIndex(LyricsData lyrics, Duration position) {
  if (!lyrics.isSynchronized) return -1;
  return LyricsService().findCurrentLineIndex(lyrics, position);
}

/// All lines sharing a timestamp are concurrent; individually timed word
/// windows may also overlap a newer line. Never collapse these lyrics to the
/// single last line returned by the binary search.
List<int> immersiveActiveLineIndices(
  LyricsData lyrics,
  Duration position, {
  List<LyricsLine>? playbackLines,
}) {
  final latest = immersiveLyricsLineIndex(lyrics, position);
  if (latest < 0) return const [];
  final lines = playbackLines ?? lyrics.lines;
  final latestTimestamp = lyrics.lines[latest].timestamp;
  final active = <int>[];
  for (var i = 0; i <= latest && i < lines.length; i++) {
    final line = lines[i];
    final overlappingWords = line.words?.any(
      (word) => word.start <= position && word.end > position,
    ) ?? false;
    if (line.timestamp == latestTimestamp || overlappingWords) {
      active.add(i);
    }
  }
  return active;
}

/// Space is a transparent subtitle layer above the currently selected visual
/// (still art, fullscreen cover, Canvas or native Media3 video), not a player.
///
/// The normal audio position notifier and Media3 snapshots arrive less often
/// than display frames. Lyrics mode already interpolates its playback clock;
/// use that same frame-driven clock here so syllables do not advance in jumps.
/// The glyph renderer is EXACTLY LyricMotionLine from normal Lyrics mode.
class ImmersiveLyricsSubtitle extends StatefulWidget {
  const ImmersiveLyricsSubtitle({
    super.key,
    required this.lyrics,
    required this.position,
    this.playing,
    this.playbackSpeed,
    this.loading = false,
  });

  final LyricsData? lyrics;
  final ValueListenable<Duration> position;
  final ValueListenable<bool>? playing;
  final ValueListenable<double>? playbackSpeed;
  final bool loading;

  @override
  State<ImmersiveLyricsSubtitle> createState() => _ImmersiveLyricsSubtitleState();
}

class _ImmersiveLyricsSubtitleState extends State<ImmersiveLyricsSubtitle>
    with SingleTickerProviderStateMixin {
  static const _font = 'GoogleSansFlex';
  static const _lyricStyle = TextStyle(
    fontFamily: _font,
    color: Colors.white,
    fontSize: 31,
    fontWeight: FontWeight.w800,
    height: 1.2,
  );

  LyricsData? _preparedSource;
  List<LyricsLine> _preparedLines = const [];
  late final Ticker _ticker;
  final ValueNotifier<Duration> _framePosition =
      ValueNotifier<Duration>(Duration.zero);
  Duration _frameElapsed = Duration.zero;
  Duration _anchorElapsed = Duration.zero;
  Duration _anchorPosition = Duration.zero;
  bool _playing = false;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _prepare();
    _anchorPosition = widget.position.value;
    _framePosition.value = _anchorPosition;
    _playing = widget.playing?.value ?? false;
    _speed = widget.playbackSpeed?.value ?? 1.0;
    _listen();
    _ticker = createTicker(_onFrame);
    if (_playing) _ticker.start();
  }

  void _listen() {
    widget.position.addListener(_onPosition);
    widget.playing?.addListener(_onPlaybackState);
    widget.playbackSpeed?.addListener(_onPlaybackState);
  }

  void _unlisten() {
    widget.position.removeListener(_onPosition);
    widget.playing?.removeListener(_onPlaybackState);
    widget.playbackSpeed?.removeListener(_onPlaybackState);
  }

  @override
  void didUpdateWidget(covariant ImmersiveLyricsSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lyrics, widget.lyrics)) _prepare();
    if (oldWidget.position != widget.position ||
        oldWidget.playing != widget.playing ||
        oldWidget.playbackSpeed != widget.playbackSpeed) {
      oldWidget.position.removeListener(_onPosition);
      oldWidget.playing?.removeListener(_onPlaybackState);
      oldWidget.playbackSpeed?.removeListener(_onPlaybackState);
      _anchorElapsed = _frameElapsed;
      _anchorPosition = widget.position.value;
      _framePosition.value = _anchorPosition;
      _playing = widget.playing?.value ?? false;
      _speed = widget.playbackSpeed?.value ?? 1.0;
      if (_ticker.isActive != _playing) {
        if (_playing) {
          _anchorElapsed = Duration.zero;
          _frameElapsed = Duration.zero;
          _ticker.start();
        } else {
          _ticker.stop();
        }
      }
      _listen();
    }
  }

  void _prepare() {
    _preparedSource = widget.lyrics;
    // Resolve enhanced-LRC word end windows once per lyrics change only.
    _preparedLines = _preparedSource == null
        ? const []
        : LyricsService().playbackLines(_preparedSource!);
  }

  Duration _interpolated(Duration frame) {
    if (!_playing) return _anchorPosition;
    final milliseconds = (frame - _anchorElapsed).inMicroseconds /
        1000.0 * _speed;
    return _anchorPosition + Duration(microseconds:
        (milliseconds * 1000).round());
  }

  void _onPosition() {
    final actual = widget.position.value;
    final expected = _interpolated(_frameElapsed);
    final delta = (actual - expected).inMilliseconds;
    // Seek, source replacement, buffering resumption: jump immediately.
    // Otherwise correct small polling jitter gradually, rather than
    // snapping every 400 ms (the previous choppy Space behavior).
    _anchorPosition = !_playing || delta.abs() > 350
        ? actual
        : expected + Duration(milliseconds: (delta * .12).round());
    _anchorElapsed = _frameElapsed;
    if (!_playing || delta.abs() > 350) {
      _framePosition.value = _anchorPosition;
    }
  }

  void _onPlaybackState() {
    final nowPlaying = widget.playing?.value ?? false;
    final speed = widget.playbackSpeed?.value ?? 1.0;
    if (_playing == nowPlaying && _speed == speed) return;

    if (_playing && !nowPlaying) {
      // Freeze the extrapolated position, not a stale Media3 sample.
      _anchorPosition = _interpolated(_frameElapsed);
      _anchorElapsed = Duration.zero;
      _frameElapsed = Duration.zero;
      _playing = false;
      _speed = speed;
      _ticker.stop();
      _framePosition.value = _anchorPosition;
    } else if (!_playing && nowPlaying) {
      _anchorPosition = widget.position.value;
      _anchorElapsed = Duration.zero;
      _frameElapsed = Duration.zero;
      _playing = true;
      _speed = speed;
      _ticker.start();
    } else {
      // Keep a continuous playhead through speed changes.
      _anchorPosition = _interpolated(_frameElapsed);
      _anchorElapsed = _frameElapsed;
      _speed = speed;
    }
  }

  void _onFrame(Duration elapsed) {
    _frameElapsed = elapsed;
    if (!_playing) return;
    final next = _interpolated(elapsed);
    if (_framePosition.value != next) _framePosition.value = next;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _unlisten();
    _framePosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ValueListenableBuilder<Duration>(
      valueListenable: _framePosition,
      builder: (context, position, _) {
        final lyrics = _preparedSource;
        if (lyrics == null || !hasImmersiveLyrics(lyrics)) {
          return widget.loading
              ? const Center(
                  child: Text('Finding lyrics…',
                      style: TextStyle(color: Colors.white70, fontSize: 16)),
                )
              : const SizedBox.shrink();
        }
        final indices = immersiveActiveLineIndices(
          lyrics, position, playbackLines: _preparedLines,
        );
        if (indices.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final index in indices) ...[
                if (index != indices.first)
                  const SizedBox(height: 5),
                _subtitleLine(_preparedLines[index], index, position),
              ],
            ],
          ),
        );
      },
    ),
  );

  Widget _subtitleLine(LyricsLine line, int index, Duration position) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          child: LyricMotionLine(
            // Timestamp alone is not unique: two concurrent lyrics can have
            // the exact same millisecond timestamp.
            key: ValueKey('space-line:${line.timestamp.inMilliseconds}:$index'),
            line: line,
            position: position,
            textAlign: TextAlign.center,
            style: _lyricStyle,
          ),
        ),
        if (line.translation?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 5),
          Text(
            line.translation!.trim(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: _font,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.25,
              color: Colors.white,
            ),
          ),
        ],
      ],
    );
  }
}
