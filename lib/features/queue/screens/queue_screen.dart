import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/blurred_song_background.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';

/// A song's identity must not change when its position changes. Duplicates
/// are separate queue occurrences; IDs and indices alone are insufficient.
List<String> queueRowIdentities(List<Song> songs, String section) {
  final seen = <String, int>{};
  return [
    for (final song in songs)
      '$section:${song.id}:${seen.update(song.id, (n) => n + 1, ifAbsent: () => 0)}',
  ];
}

/// One post-removal target index for both queue screens and player backends.
/// SliverReorderableList sends the destination BEFORE the old row is removed.
int queueDropIndex(int oldIndex, int newIndex, int length) =>
    (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(0, length - 1).toInt();

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Colors.transparent,
    body: BlurredSongBackground(
      child: SafeArea(bottom: false, child: QueueList()),
    ),
  );
}

/// Shared queue experience for full player, mini-player sheet and standalone
/// screen. Up Next is the real playback order and ALREADY includes manually
/// queued tracks; never render the manual queue a second time.
class QueueList extends ConsumerStatefulWidget {
  const QueueList({
    super.key,
    this.embedded = false,
    this.sheet = false,
    this.scrollController,
    this.onOpenPlayer,
  });

  final bool embedded;
  final bool sheet;
  final ScrollController? scrollController;
  final VoidCallback? onOpenPlayer;

  @override
  ConsumerState<QueueList> createState() => _QueueListState();
}

class _QueueListState extends ConsumerState<QueueList> {
  bool _selectionMode = false;
  final _selected = <String>{};
  List<Song>? _optimisticSongs;
  bool _reordering = false;
  bool _openingPlayer = false;

  void _openPlayer() {
    if (!mounted || _openingPlayer || widget.onOpenPlayer == null) return;
    _openingPlayer = true;
    widget.onOpenPlayer!();
  }

  Future<void> _move(int from, int to, List<Song> songs, bool manualOnly) async {
    if (from == to || _reordering) return;
    final reordered = List<Song>.of(songs);
    reordered.insert(to, reordered.removeAt(from));
    setState(() {
      _reordering = true;
      _optimisticSongs = reordered;
    });
    try {
      final player = ref.read(playerProvider.notifier);
      if (manualOnly) {
        await player.moveQueueItem(from, to);
      } else {
        await player.moveUpNextItem(from, to);
      }
    } finally {
      if (mounted) {
        setState(() {
          _optimisticSongs = null;
          _reordering = false;
        });
      }
    }
  }

  Future<void> _removeSelection(bool manualOnly, List<Song> songs) async {
    final keys = queueRowIdentities(songs, 'next');
    final indices = [
      for (var i = 0; i < keys.length; i++)
        if (_selected.contains(keys[i])) i,
    ]..sort((a, b) => b.compareTo(a));
    setState(() {
      _selected.clear();
      _selectionMode = false;
    });
    final player = ref.read(playerProvider.notifier);
    for (final index in indices) {
      if (manualOnly) {
        await player.removeFromQueue(index);
      } else {
        await player.removeFromUpNext(index);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final upcoming = ref.watch(upNextProvider);
    final manualQueue = ref.watch(queueProvider);
    final autoplay = ref.watch(autoplayUpNextProvider);
    final current = ref.watch(currentSongProvider);
    // A paused/no-context manual queue is still editable. With active
    // playback, Up Next already contains every manual queue entry.
    final manualOnly = upcoming.isEmpty && manualQueue.isNotEmpty;
    final songs = _optimisticSongs ??
        (manualOnly ? manualQueue : upcoming);
    final ids = queueRowIdentities(songs, 'next');
    final t = context.lokal;
    final textColor = widget.embedded ? Colors.white : t.text;
    final mutedColor = widget.embedded ? Colors.white60 : t.muted;
    final h = widget.embedded ? 14.0 : 20.0;
    final count = songs.length + autoplay.length;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(h, widget.sheet ? 4 : 16, h, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(lokalText('Queue'),
                    style: TextStyle(
                      fontSize: 23, fontWeight: FontWeight.w700,
                      color: textColor, letterSpacing: -0.45,
                    )),
                const SizedBox(height: 3),
                Text(
                  _selectionMode
                      ? lokalText('{arg0} selected',
                          args: {'arg0': _selected.length})
                      : l10n.upcomingSong(count),
                  style: TextStyle(fontSize: 12.5, color: mutedColor),
                ),
              ],
            ),
          ),
          if (_selectionMode) ...[
            TextButton(
              onPressed: () => setState(() => _selected
                ..clear()
                ..addAll(ids)),
              child: Text(l10n.selectAll),
            ),
            IconButton(
              key: const ValueKey('queue-remove-selected'),
              tooltip: l10n.removeSelected,
              onPressed: _selected.isEmpty
                  ? null
                  : () => unawaited(_removeSelection(manualOnly, songs)),
              icon: const Icon(LucideIcons.trash2, size: 20),
            ),
          ] else if (songs.isNotEmpty) ...[
            IconButton(
              key: const ValueKey('queue-select'),
              tooltip: l10n.selectAll,
              onPressed: () => setState(() => _selectionMode = true),
              icon: const Icon(LucideIcons.checkCheck, size: 20),
            ),
            TextButton(
              onPressed: () async {
                final player = ref.read(playerProvider.notifier);
                if (manualOnly) {
                  await player.clearQueue();
                } else {
                  await player.clearAllUpcoming();
                }
              },
              child: Text(l10n.clearAll, style: TextStyle(color: mutedColor)),
            ),
          ],
          if (_selectionMode)
            IconButton(
              tooltip: lokalText('Cancel'),
              onPressed: () => setState(() {
                _selectionMode = false;
                _selected.clear();
              }),
              icon: const Icon(LucideIcons.x, size: 20),
            ),
        ],
      ),
    );

    final body = Column(
      children: [
        header,
        Expanded(
          child: CustomScrollView(
            controller: widget.scrollController,
            slivers: [
              if (current != null && !widget.embedded)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(h, 0, h, 14),
                  sliver: SliverToBoxAdapter(
                    child: _NowPlayingRow(song: current, onTap: _openPlayer,
                        canOpen: widget.onOpenPlayer != null),
                  ),
                ),
              if (songs.isNotEmpty) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(h, 5, h, 5),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Text(l10n.upNext,
                            style: TextStyle(
                              color: mutedColor, fontWeight: FontWeight.w700,
                              fontSize: 12, letterSpacing: 1.2,
                            )),
                        const SizedBox(width: 8),
                        Text('${songs.length}',
                            style: TextStyle(fontSize: 12, color: mutedColor)),
                        const Spacer(),
                        if (!_selectionMode)
                          Text(lokalText('Drag to reorder'),
                              style: TextStyle(fontSize: 11, color: mutedColor)),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(h, 0, h,
                      autoplay.isEmpty ? (widget.embedded || widget.sheet ? 24 : 140) : 14),
                  sliver: _selectionMode
                      ? SliverList.builder(
                          itemCount: songs.length,
                          itemBuilder: (context, i) => _QueueRow(
                            key: ValueKey(ids[i]),
                            song: songs[i],
                            index: i,
                            darkBackdrop: widget.embedded,
                            selected: _selected.contains(ids[i]),
                            selecting: true,
                            onTap: () => setState(() {
                              if (!_selected.add(ids[i])) _selected.remove(ids[i]);
                            }),
                          ),
                        )
                      : SliverReorderableList(
                          itemCount: songs.length,
                          // The platform and sheet scroll gestures no longer
                          // compete with nested Dismissible/second reorder lists.
                          onReorder: (from, destination) {
                            final to = queueDropIndex(from, destination, songs.length);
                            unawaited(_move(from, to, songs, manualOnly));
                          },
                          proxyDecorator: (child, index, animation) => Material(
                            elevation: 10,
                            color: widget.embedded ? Colors.white.withValues(alpha: .1) : t.surface2,
                            borderRadius: BorderRadius.circular(14),
                            child: child,
                          ),
                          itemBuilder: (context, i) => _QueueRow(
                            key: ValueKey(ids[i]),
                            song: songs[i],
                            index: i,
                            darkBackdrop: widget.embedded,
                            onTap: () async {
                              final player = ref.read(playerProvider.notifier);
                              if (manualOnly) {
                                await player.playFromQueueIndex(i);
                              } else {
                                await player.playFromUpNextIndex(i);
                              }
                              _openPlayer();
                            },
                            onRemove: () async {
                              final player = ref.read(playerProvider.notifier);
                              if (manualOnly) {
                                await player.removeFromQueue(i);
                              } else {
                                await player.removeFromUpNext(i);
                              }
                            },
                          ),
                        ),
                ),
              ] else
                SliverPadding(
                  padding: EdgeInsets.all(h),
                  sliver: SliverToBoxAdapter(
                    child: _QueueEmpty(
                      darkBackdrop: widget.embedded,
                      text: current == null
                          ? l10n.queueIsEmpty
                          : l10n.noUpcomingQueueItemsYet,
                    ),
                  ),
                ),
              if (autoplay.isNotEmpty && !_selectionMode) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(h, 5, h, 5),
                  sliver: SliverToBoxAdapter(
                    child: Text('Autoplay',
                        style: TextStyle(
                          color: mutedColor, fontWeight: FontWeight.w700,
                          fontSize: 12, letterSpacing: 1.2,
                        )),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(h, 0, h,
                    widget.sheet || widget.embedded ? 30 : 140),
                  sliver: SliverList.builder(
                    itemCount: autoplay.length,
                    itemBuilder: (context, i) => _QueueRow(
                      key: ValueKey('autoplay-${autoplay[i].id}-$i'),
                      song: autoplay[i],
                      index: i,
                      darkBackdrop: widget.embedded,
                      autoplay: true,
                      onTap: () async {
                        await ref.read(playerProvider.notifier)
                            .playFromAutoplayIndex(i);
                        _openPlayer();
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    if (!widget.embedded) return body;
    return AdaptiveColorProvider(
        backgroundColor: Colors.black, child: body);
  }
}

/// A minimal queue row: artwork, title, secondary artist, duration, actions,
/// and a dedicated immediate drag handle. No nested Dismissible/GestureDetector
/// competes for the vertical drag arena.
class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.song,
    required this.index,
    required this.onTap,
    this.onRemove,
    this.selecting = false,
    this.selected = false,
    this.autoplay = false,
    this.darkBackdrop = false,
  });

  final Song song;
  final int index;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final bool selecting;
  final bool selected;
  final bool autoplay;
  final bool darkBackdrop;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final textColor = darkBackdrop ? Colors.white : t.text;
    final mutedColor = darkBackdrop ? Colors.white60 : t.muted;
    final surface = darkBackdrop ? Colors.white.withValues(alpha: .085) : t.surface2;
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: selected ? t.accent.withValues(alpha: .14) : surface,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
                  child: Row(
                    children: [
                      if (selecting) ...[
                        Icon(selected ? LucideIcons.check
                                      : LucideIcons.circle,
                            color: selected ? t.accent : mutedColor, size: 20),
                        const SizedBox(width: 10),
                      ],
                      _QueueArt(song: song, size: 46),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(song.title, maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: textColor, fontSize: 14,
                                fontWeight: FontWeight.w600)),
                            const SizedBox(height: 3),
                            Text(song.artist, maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: mutedColor, fontSize: 12)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(song.duration > Duration.zero
                          ? song.formattedDuration : (song.isPending ? '…' : '—'),
                          style: TextStyle(color: mutedColor, fontSize: 11)),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              ),
            ),
            if (!selecting && !autoplay) ...[
              IconButton(
                tooltip: 'More',
                icon: Icon(LucideIcons.ellipsis, color: mutedColor, size: 19),
                onPressed: () => SongActionsBottomSheet.show(
                  context,
                  song,
                  queueActions: false,
                  extras: [
                    if (onRemove != null)
                      LokalSongMenuAction(
                        icon: Icons.playlist_remove_rounded,
                        label: 'Remove from queue',
                        destructive: true,
                        onTap: onRemove!,
                      ),
                  ],
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Semantics(
                  button: true,
                  label: 'Reorder ${song.title}',
                  child: SizedBox(
                    key: ValueKey('queue-grip-$index'),
                    width: 44,
                    height: 62,
                    child: Icon(LucideIcons.gripVertical, color: mutedColor,
                        size: 22),
                  ),
                ),
              ),
            ] else if (autoplay)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Icon(LucideIcons.sparkles, color: mutedColor, size: 18),
              )
            else
              const SizedBox(width: 16),
          ],
        ),
      ),
    );
    return content;
  }
}

class _QueueArt extends StatelessWidget {
  const _QueueArt({required this.song, this.size = 46});
  final Song song;
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: SizedBox.square(
      dimension: size,
      child: CachedImageWidget(
        imagePath: song.albumArt,
        audioSourcePath: song.filePath,
        fit: BoxFit.cover,
        useThumbnail: true,
        thumbnailWidth: 112,
        thumbnailHeight: 112,
        placeholder: const FlickArtworkPlaceholder(size: 22, opacity: .8),
        errorWidget: const FlickArtworkPlaceholder(size: 22, opacity: .8),
      ),
    ),
  );
}

class _NowPlayingRow extends StatelessWidget {
  const _NowPlayingRow({required this.song, required this.onTap,
    required this.canOpen});
  final Song song;
  final VoidCallback onTap;
  final bool canOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Material(
      color: t.surface2,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const ValueKey('queue-now-playing'),
        borderRadius: BorderRadius.circular(14),
        onTap: canOpen ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _QueueArt(song: song, size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.nowPlaying2,
                      style: TextStyle(color: t.accent, fontSize: 11,
                        fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(song.title, maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.text, fontSize: 15,
                        fontWeight: FontWeight.w700)),
                    Text(song.artist, maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.muted, fontSize: 12)),
                  ],
                ),
              ),
              if (canOpen)
                Icon(LucideIcons.chevronRight, color: t.muted, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueEmpty extends StatelessWidget {
  const _QueueEmpty({required this.text, this.darkBackdrop = false});
  final String text;
  final bool darkBackdrop;
  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final muted = darkBackdrop ? Colors.white60 : t.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 15),
      child: Column(
        children: [
          Icon(LucideIcons.listMusic, color: muted, size: 36),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: muted)),
        ],
      ),
    );
  }
}
