import 'package:flutter/material.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/discovery/discovery_artwork.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';

/// What can be done with a song Search found online.
enum OnlineResultAction {
  play,
  playAtmos,
  playNext,
  addToQueue,
  download,
  downloadAtmos,
}

/// A Search result's cover: the source's, else Discovery's lookup (your
/// library, Deezer, iTunes), else a note.
class OnlineResultCover extends StatelessWidget {
  const OnlineResultCover({super.key, required this.result, this.size = 48});

  final OnlineResult result;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final placeholder = ColoredBox(
      color: t.surface2,
      child: Center(
        child: Icon(Icons.music_note_rounded, color: t.muted, size: size * .42),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 6),
      child: SizedBox.square(
        dimension: size,
        child: DiscoveryArtwork(
          kind: DiscoveryArtworkKind.track,
          title: result.track.title,
          artist: result.track.artist,
          url: result.artwork ?? '',
          width: size,
          height: size,
          placeholder: placeholder,
        ),
      ),
    );
  }
}

/// The long-press sheet for a Search result: Play, Play next, Add to queue,
/// Download to library. A solid theme surface, like Lokal's other sheets.
Future<OnlineResultAction?> showOnlineResultActions(
  BuildContext context, {
  required OnlineResult result,
  required String sourceName,
  bool saving = false,
}) {
  final t = context.lokal;
  return showModalBottomSheet<OnlineResultAction>(
    context: context,
    backgroundColor: t.surface,
    showDragHandle: true,
    useRootNavigator: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (context) => SingleChildScrollView(
      child: _OnlineResultSheet(
        result: result,
        source: sourceName,
        saving: saving,
      ),
    ),
  );
}

class _OnlineResultSheet extends StatelessWidget {
  const _OnlineResultSheet({
    required this.result,
    required this.source,
    required this.saving,
  });

  final OnlineResult result;
  final String source;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final track = result.track;
    void pick(OnlineResultAction action) => Navigator.of(context).pop(action);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                OnlineResultCover(result: result, size: 56),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${track.artist} · $source',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.muted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DecoratedBox(
              decoration: BoxDecoration(
                color: t.surface2,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: t.border),
              ),
              child: Column(
                children: [
                  _ActionRow(
                    icon: Icons.play_arrow_rounded,
                    label: 'Play',
                    onTap: () => pick(OnlineResultAction.play),
                  ),
                  if (track.atmosAvailable || track.atmosRequestable)
                    _ActionRow(
                      icon: Icons.surround_sound_rounded,
                      label: track.atmosRequestable && !track.atmosAvailable ? 'Try AC-4 (availability unverified)' : 'Play Dolby Atmos',
                      onTap: () => pick(OnlineResultAction.playAtmos),
                    ),
                  _ActionRow(
                    icon: Icons.queue_play_next_rounded,
                    label: 'Play next',
                    onTap: () => pick(OnlineResultAction.playNext),
                  ),
                  _ActionRow(
                    icon: Icons.playlist_add_rounded,
                    label: 'Add to queue',
                    onTap: () => pick(OnlineResultAction.addToQueue),
                  ),
                  _ActionRow(
                    icon: Icons.download_rounded,
                    label: saving ? 'Downloading…' : 'Download to library',
                    onTap: saving
                        ? null
                        : () => pick(OnlineResultAction.download),
                    last: !(track.atmosAvailable || track.atmosRequestable),
                  ),
                  if (track.atmosAvailable || track.atmosRequestable)
                    _ActionRow(
                      icon: Icons.surround_sound_rounded,
                      label: saving ? 'Downloading…' : (track.atmosRequestable && !track.atmosAvailable ? 'Download Amazon AC-4' : 'Download Dolby Atmos'),
                      onTap: saving
                          ? null
                          : () => pick(OnlineResultAction.downloadAtmos),
                      last: true,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.last = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final color = onTap == null ? t.muted2 : t.text;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(bottom: BorderSide(color: t.border, width: .5)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(icon, color: onTap == null ? t.muted2 : t.accent, size: 22),
          ],
        ),
      ),
    );
  }
}
