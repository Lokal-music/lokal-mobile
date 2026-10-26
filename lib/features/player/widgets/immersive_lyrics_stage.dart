import 'package:flutter/material.dart';

import 'package:flick/features/player/widgets/lyric_motion_line.dart';
import 'package:flick/services/lyrics_service.dart';

/// Space is available only for genuinely timestamped lyrics.
bool hasImmersiveLyrics(LyricsData? lyrics) =>
    lyrics != null && lyrics.isSynchronized && lyrics.lines.isNotEmpty;

/// Uses the same binary search and timeline as regular synchronized lyrics.
int immersiveLyricsLineIndex(LyricsData lyrics, Duration position) {
  if (!lyrics.isSynchronized) return -1;
  return LyricsService().findCurrentLineIndex(lyrics, position);
}

/// A subtitle layer, NOT another player or artwork surface. Its [position]
/// notifier repaints independently of the artwork/Canvas/Media3 platform view.
/// A native video can pass its own clock instead of the paused song's clock.
class ImmersiveLyricsSubtitle extends StatefulWidget {
  const ImmersiveLyricsSubtitle({
    super.key,
    required this.lyrics,
    required this.position,
    this.loading = false,
  });

  final LyricsData? lyrics;
  final ValueListenable<Duration> position;
  final bool loading;

  @override
  State<ImmersiveLyricsSubtitle> createState() => _ImmersiveLyricsSubtitleState();
}

class _ImmersiveLyricsSubtitleState extends State<ImmersiveLyricsSubtitle> {
  static const _font = 'GoogleSansFlex';
  LyricsData? _preparedSource;
  List<LyricsLine> _preparedLines = const [];

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant ImmersiveLyricsSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lyrics, widget.lyrics)) _prepare();
  }

  void _prepare() {
    _preparedSource = widget.lyrics;
    // Resolve enhanced-LRC word ends once per data change, never per tick.
    _preparedLines = _preparedSource == null
        ? const []
        : LyricsService().playbackLines(_preparedSource!);
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ValueListenableBuilder<Duration>(
      valueListenable: widget.position,
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
        final index = immersiveLyricsLineIndex(lyrics, position);
        if (index < 0 || index >= _preparedLines.length) {
          // No fabricated lyric during an instrumental intro.
          return const SizedBox.shrink();
        }
        final current = _preparedLines[index];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Fixed line identity retains TextPainter glyph boxes while
              // per-syllable progress repaints, eliminating repeated layouts.
              RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0x44000000),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 7,
                    ),
                    child: LyricMotionLine(
                      key: ValueKey('space-line:${current.timestamp.inMilliseconds}'),
                      line: current,
                      position: position,
                      textAlign: TextAlign.center,
                      lightweight: true,
                      // No per-glyph blur shadows on syllable repaints.
                      style: const TextStyle(
                        fontFamily: _font,
                        color: Colors.white,
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        height: 1.20,
                      ),
                    ),
                  ),
                ),
              ),
              if (current.translation?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 5),
                Text(
                  current.translation!.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: _font,
                    fontSize: 16,
                    height: 1.25,
                    color: Colors.white,
                    shadows: [
                      Shadow(color: Color(0xEE000000), blurRadius: 9),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}
