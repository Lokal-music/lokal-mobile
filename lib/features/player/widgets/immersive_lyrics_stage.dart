import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flick/features/player/widgets/lyric_motion_line.dart';
import 'package:flick/features/player/widgets/lyrics_subline_buttons.dart';
import 'package:flick/features/player/widgets/player_artwork_image.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/player_service.dart';

/// Independently renders the song's current timed lyric as a subtitle while
/// keeping the album sleeve front and centre. Like Prism's immersive mode,
/// but built entirely on Lokal's existing audio clock and lyric services.
class ImmersiveLyricsStage extends StatefulWidget {
  const ImmersiveLyricsStage({
    super.key,
    required this.song,
    required this.player,
    required this.lyrics,
    required this.baseLyrics,
    required this.loading,
    required this.onExit,
    required this.onSublineChanged,
    required this.onLyricsSource,
  });

  final Song song;
  final PlayerService player;
  /// May contain translated or romanized lines at identical timestamps.
  final LyricsData? lyrics;
  final LyricsData? baseLyrics;
  final bool loading;
  final VoidCallback onExit;
  final ValueChanged<LyricsData?> onSublineChanged;
  final VoidCallback onLyricsSource;

  @override
  State<ImmersiveLyricsStage> createState() => _ImmersiveLyricsStageState();
}

/// A pure, testable subtitle selector. Never guess timing for unsynchronized
/// lyrics: those use a separate readable, scrolling text fallback.
int immersiveLyricsLineIndex(LyricsData lyrics, Duration position) {
  if (!lyrics.isSynchronized) return -1;
  return LyricsService().findCurrentLineIndex(lyrics, position);
}

class _ImmersiveLyricsStageState extends State<ImmersiveLyricsStage> {
  static const _font = 'GoogleSansFlex';
  bool _controlsVisible = true;
  Timer? _hideControls;
  LyricsData? _timedSource;
  List<LyricsLine> _timedLines = const [];

  @override
  void initState() {
    super.initState();
    _updateTimedLines();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant ImmersiveLyricsStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lyrics, widget.lyrics)) _updateTimedLines();
  }

  void _updateTimedLines() {
    _timedSource = widget.lyrics;
    _timedLines = widget.lyrics == null
        ? const []
        : LyricsService().playbackLines(widget.lyrics!);
  }

  void _scheduleHide() {
    _hideControls?.cancel();
    _hideControls = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _reveal() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
    else _hideControls?.cancel();
  }

  @override
  void dispose() {
    _hideControls?.cancel();
    super.dispose();
  }

  Widget _subtitle(Duration position) {
    final lyrics = _timedSource;
    if (lyrics == null || lyrics.lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Text(
          widget.loading ? 'Finding lyrics…' : 'No lyrics available',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: _font, color: Colors.white70, fontSize: 18,
          ),
        ),
      );
    }

    if (!lyrics.isSynchronized) {
      return SizedBox(
        height: 160,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 25),
            child: Text(
              lyrics.lines.map((line) => [
                line.text,
                if (line.translation?.trim().isNotEmpty == true)
                  line.translation!.trim(),
              ].join('\n')).join('\n\n'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: _font, color: Colors.white,
                height: 1.35, fontSize: 22, fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }

    final index = immersiveLyricsLineIndex(lyrics, position);
    final line = index >= 0 && index < _timedLines.length
        ? _timedLines[index] : null;
    final next = index + 1 < lyrics.lines.length
        ? lyrics.lines[index + 1] : null;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: SizedBox(
        key: ValueKey('${widget.song.id}:$index'),
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 25),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (line == null)
                const Text(
                  '♪',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 28),
                )
              else
                LyricMotionLine(
                  line: line,
                  position: position,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: _font, color: Colors.white,
                    fontWeight: FontWeight.w800, fontSize: 29, height: 1.2,
                    shadows: [
                      Shadow(color: Color(0xCC000000), blurRadius: 17),
                    ],
                  ),
                ),
              if (line?.translation?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 7),
                Text(
                  line!.translation!.trim(),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _font, color: Color(0xE6FFFFFF),
                    fontSize: 17, height: 1.22,
                    shadows: [Shadow(color: Colors.black, blurRadius: 10)],
                  ),
                ),
              ],
              if (next != null && next.text.trim().isNotEmpty) ...[
                const SizedBox(height: 15),
                Text(
                  next.text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: _font, color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 16, height: 1.18, fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final coverSide = math.min(size.width * 0.86, size.height * 0.48);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _reveal,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Keep the original album art (never a generic placeholder or
            // black video rectangle) as the entire immersive background.
            PlayerArtworkImage(
              key: ValueKey('immersive-cover:${widget.song.id}'),
              song: widget.song,
              radius: 0,
              crossfade: true,
            ),
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, .42, .64, 1],
                    colors: [
                      Color(0x48000000),
                      Color(0x30000000),
                      Color(0xAB000000),
                      Color(0xED000000),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 7, 12, 0),
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: 'Return to full player',
                              icon: const Icon(Icons.close_fullscreen_rounded,
                                  color: Colors.white),
                              onPressed: widget.onExit,
                            ),
                            const Expanded(
                              child: Text(
                                'IMMERSIVE LYRICS',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: _font, color: Colors.white,
                                  fontSize: 12, fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Choose lyrics source',
                              icon: const Icon(Icons.library_music_outlined,
                                  color: Colors.white),
                              onPressed: widget.onLyricsSource,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  // The sleeve itself remains visible in the upper area;
                  // lyrics replace regular buttons/title at the bottom.
                  SizedBox.square(
                    dimension: coverSide * 0.72,
                    child: IgnorePointer(
                      child: PlayerArtworkImage(
                        song: widget.song, radius: 18,
                        decodeWidth: 720, crossfade: false,
                      ),
                    ),
                  ),
                  const Spacer(),
                  ValueListenableBuilder<Duration>(
                    valueListenable: widget.player.positionNotifier,
                    builder: (_, position, __) => _subtitle(position),
                  ),
                  const SizedBox(height: 18),
                  if (widget.baseLyrics != null)
                    IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: Semantics(
                          label: 'Subtitle language controls',
                          child: LyricsSublineButtons(
                            lyrics: widget.baseLyrics!,
                            onChanged: widget.onSublineChanged,
                          ),
                        ),
                      ),
                    ),
                  IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: ValueListenableBuilder<bool>(
                        valueListenable: widget.player.isPlayingNotifier,
                        builder: (_, playing, __) => Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              tooltip: 'Previous',
                              onPressed: widget.player.previousBySwipe,
                              icon: const Icon(Icons.skip_previous_rounded,
                                  color: Colors.white, size: 30),
                            ),
                            const SizedBox(width: 18),
                            IconButton(
                              tooltip: playing ? 'Pause' : 'Play',
                              onPressed: widget.player.togglePlayPause,
                              icon: Icon(
                                playing ? Icons.pause_circle_filled_rounded
                                    : Icons.play_circle_filled_rounded,
                                color: Colors.white, size: 52,
                              ),
                            ),
                            const SizedBox(width: 18),
                            IconButton(
                              tooltip: 'Next',
                              onPressed: widget.player.next,
                              icon: const Icon(Icons.skip_next_rounded,
                                  color: Colors.white, size: 30),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
