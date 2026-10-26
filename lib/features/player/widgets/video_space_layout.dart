import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flick/l10n/l10n.dart';

import 'full_player_visuals.dart';

/// Keep captions and Lokal gestures outside the official embedded player.
/// The caller reparents its existing keyed video surface into [player].
class VideoSpaceLayout extends StatelessWidget {
  const VideoSpaceLayout({
    super.key,
    required this.player,
    required this.subtitles,
    required this.onExit,
    required this.onOptions,
  });
  final Widget player;
  final Widget subtitles;
  final VoidCallback onExit, onOptions;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final captionHeight = math.min(
          180.0,
          math.max(72.0, constraints.maxHeight * .25),
        );
        final playerHeight = math.max(
          200.0,
          constraints.maxHeight - captionHeight - 60,
        );
        final content = Column(
          children: [
            SizedBox(
              height: playerHeight,
              width: double.infinity,
              child: player,
            ),
            SizedBox(
              height: captionHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Center(child: SingleChildScrollView(child: subtitles)),
              ),
            ),
            SizedBox(
              height: 60,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextButton.icon(
                      key: const ValueKey('embedded-space-exit'),
                      onPressed: onExit,
                      icon: const Icon(
                        Icons.close_fullscreen,
                        color: FullPlayerVisuals.primaryText,
                      ),
                      label: Text(
                        lokalText('Exit Space'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: FullPlayerVisuals.primaryText,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onOptions,
                    tooltip: l10n.lyrics,
                    icon: const Icon(
                      Icons.more_horiz,
                      color: FullPlayerVisuals.primaryText,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
        // Keep the embedded player at least 200px high on short/rotated windows.
        return playerHeight + captionHeight + 60 > constraints.maxHeight
            ? SingleChildScrollView(child: content)
            : content;
      },
    ),
  );
}
