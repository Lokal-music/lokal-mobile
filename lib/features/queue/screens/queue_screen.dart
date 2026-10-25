import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/blurred_song_background.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';
import 'package:flick/widgets/common/surface_icon_button.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/theme/lokal_theme.dart';

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: BlurredSongBackground(
        child: SafeArea(bottom: false, child: QueueList()),
      ),
    );
  }
}

/// The queue: now playing, up next and the manual queue, with reorder, swipe
/// to remove, play from here and multi-select. [QueueScreen] shows it as a
/// page; Now Playing embeds it ([embedded]) in its in-place queue reveal, where
/// the player's own header already shows the current song and the rows sit on
/// the player's dark backdrop as glass.
class QueueList extends ConsumerStatefulWidget {
  const QueueList({
    super.key,
    this.embedded = false,
    this.sheet = false,
    this.scrollController,
    this.onOpenPlayer,
  });

  final bool sheet;
  final ScrollController? scrollController;
  final VoidCallback? onOpenPlayer;

  final bool embedded;

  @override
  ConsumerState<QueueList> createState() => _QueueListState();
}

class _QueueListState extends ConsumerState<QueueList> {
  bool _selectionMode = false;
  bool _openingPlayer = false;

  void _openPlayer() {
    if (!mounted || _openingPlayer || widget.onOpenPlayer == null) return;
    _openingPlayer = true;
    widget.onOpenPlayer!();
  }

  final Set<String> _selectedKeys = {};

  String _upNextKey(int i) => 'upnext-$i';
  String _queueKey(int i) => 'queue-$i';

  void _enterSelectionMode(String? key) {
    setState(() {
      _selectionMode = true;
      if (key != null) _selectedKeys.add(key);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
    });
  }

  void _toggleSelection(String key) {
    setState(() {
      if (_selectedKeys.contains(key)) {
        _selectedKeys.remove(key);
        if (_selectedKeys.isEmpty) _selectionMode = false;
      } else {
        _selectedKeys.add(key);
      }
    });
  }

  void _selectAll() {
    final upNext = ref.read(upNextProvider);
    final queue = ref.read(queueProvider);
    setState(() {
      for (int i = 0; i < upNext.length; i++) {
        _selectedKeys.add(_upNextKey(i));
      }
      for (int i = 0; i < queue.length; i++) {
        _selectedKeys.add(_queueKey(i));
      }
    });
  }

  Future<void> _removeSelected() async {
    final upNextIndices = <int>[];
    final queueIndices = <int>[];
    for (final key in _selectedKeys) {
      if (key.startsWith('upnext-')) {
        upNextIndices.add(int.parse(key.substring(7)));
      } else if (key.startsWith('queue-')) {
        queueIndices.add(int.parse(key.substring(6)));
      }
    }
    setState(() {
      _selectedKeys.clear();
      _selectionMode = false;
    });
    // Remove in reverse order to keep indices stable
    upNextIndices.sort((a, b) => b.compareTo(a));
    queueIndices.sort((a, b) => b.compareTo(a));
    for (final i in queueIndices) {
      await ref.read(playerProvider.notifier).removeFromQueue(i);
    }
    for (final i in upNextIndices) {
      await ref.read(playerProvider.notifier).removeFromUpNext(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(queueProvider);
    final upNext = ref.watch(upNextProvider);
    final autoplay = ref.watch(autoplayUpNextProvider);
    final currentSong = ref.watch(currentSongProvider);
    final embedded = widget.embedded;
    final hPad = embedded ? 0.0 : AppConstants.spacingLg;

    final content = Column(
      children: [
        if (_selectionMode)
          _buildSelectionHeader(upNext.length + queue.length)
        else
          _Header(
            queueCount: upNext.length + queue.length + autoplay.length,
            canClear: upNext.isNotEmpty || queue.isNotEmpty,
            onClear: () async {
              await ref.read(playerProvider.notifier).clearAllUpcoming();
            },
            onSelectMode: () => _enterSelectionMode(null),
            showBack: !embedded && !widget.sheet,
            sheet: widget.sheet,
          ),
        Expanded(
          child: upNext.isEmpty && queue.isEmpty && currentSong == null
              ? const _EmptyQueue()
              : _fadeTop(
                  embedded,
                  CustomScrollView(
                    controller: widget.scrollController,
                    slivers: [
                      if (currentSong != null && !embedded)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              hPad,
                              0,
                              hPad,
                              AppConstants.spacingMd,
                            ),
                            child: _NowPlayingCard(
                              song: currentSong,
                              onOpen: widget.onOpenPlayer == null
                                  ? null
                                  : _openPlayer,
                            ),
                          ),
                        ),
                      if (upNext.isNotEmpty || autoplay.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            hPad,
                            0,
                            hPad,
                            AppConstants.spacingSm,
                          ),
                          child: Text(
                            l10n.upNext,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: context.adaptiveTextSecondary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                      ),
                      if (upNext.isEmpty && autoplay.isEmpty)
                        const SliverToBoxAdapter(child: _EmptyUpcomingState())
                      else
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            hPad,
                            0,
                            hPad,
                            AppConstants.spacingLg,
                          ),
                          sliver: _selectionMode
                              ? SliverList.builder(
                                  itemCount: upNext.length,
                                  itemBuilder: (context, index) {
                                    final song = upNext[index];
                                    final key = _upNextKey(index);
                                    final isSelected = _selectedKeys.contains(
                                      key,
                                    );
                                    return _UpcomingTile(
                                      song: song,
                                      index: index,
                                      isSelectionMode: true,
                                      isSelected: isSelected,
                                      glass: embedded,
                                      onTap: () => _toggleSelection(key),
                                      onLongPress: () {},
                                    );
                                  },
                                )
                              : SliverReorderableList(
                                  itemCount: upNext.length,
                                  onReorder: (oldIndex, newIndex) async {
                                    final targetIndex = newIndex > oldIndex
                                        ? newIndex - 1
                                        : newIndex;
                                    await ref
                                        .read(playerProvider.notifier)
                                        .moveUpNextItem(oldIndex, targetIndex);
                                  },
                                  itemBuilder: (context, index) {
                                    final song = upNext[index];
                                    return _UpcomingTile(
                                      key: ValueKey('upnext-${song.id}-$index'),
                                      song: song,
                                      index: index,
                                      glass: embedded,
                                      onTap: () async {
                                        await ref
                                            .read(playerProvider.notifier)
                                            .playFromUpNextIndex(index);
                                        if (mounted) {
                                          _openPlayer();
                                        }
                                      },
                                      onLongPress: () => _enterSelectionMode(
                                        _upNextKey(index),
                                      ),
                                      onRemove: () async {
                                        await ref
                                            .read(playerProvider.notifier)
                                            .removeFromUpNext(index);
                                      },
                                    );
                                  },
                                ),
                        ),
                      if (queue.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              hPad,
                              0,
                              hPad,
                              AppConstants.spacingSm,
                            ),
                            child: Text(
                              l10n.manualQueue,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: context.adaptiveTextSecondary,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                        ),
                      if (queue.isNotEmpty)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            hPad,
                            0,
                            hPad,
                            embedded || widget.sheet
                                ? AppConstants.spacingLg
                                : AppConstants.navBarHeight + 120,
                          ),
                          sliver: _selectionMode
                              ? SliverList.builder(
                                  itemCount: queue.length,
                                  itemBuilder: (context, index) {
                                    final song = queue[index];
                                    final key = _queueKey(index);
                                    final isSelected = _selectedKeys.contains(
                                      key,
                                    );
                                    return _QueueTile(
                                      key: ValueKey(
                                        'queue-sel-${song.id}-$index',
                                      ),
                                      song: song,
                                      index: index,
                                      isSelectionMode: true,
                                      isSelected: isSelected,
                                      glass: embedded,
                                      onTap: () => _toggleSelection(key),
                                      onLongPress: () {},
                                      onRemove: () async {
                                        await ref
                                            .read(playerProvider.notifier)
                                            .removeFromQueue(index);
                                      },
                                      onMoveToNext: null,
                                    );
                                  },
                                )
                              : SliverReorderableList(
                                  itemCount: queue.length,
                                  onReorder: (oldIndex, newIndex) async {
                                    final targetIndex = newIndex > oldIndex
                                        ? newIndex - 1
                                        : newIndex;
                                    await ref
                                        .read(playerProvider.notifier)
                                        .moveQueueItem(oldIndex, targetIndex);
                                  },
                                  itemBuilder: (context, index) {
                                    final song = queue[index];
                                    return _QueueTile(
                                      key: ValueKey('${song.id}-$index'),
                                      song: song,
                                      index: index,
                                      glass: embedded,
                                      onTap: () async {
                                        await ref
                                            .read(playerProvider.notifier)
                                            .playFromQueueIndex(index);
                                        if (mounted) {
                                          _openPlayer();
                                        }
                                      },
                                      onLongPress: () =>
                                          _enterSelectionMode(_queueKey(index)),
                                      onRemove: () async {
                                        await ref
                                            .read(playerProvider.notifier)
                                            .removeFromQueue(index);
                                      },
                                      onMoveToNext: index == 0
                                          ? null
                                          : () async {
                                              await ref
                                                  .read(playerProvider.notifier)
                                                  .moveQueueItemToNext(index);
                                            },
                                    );
                                  },
                                ),
                        ),
                      // Autoplay is a preview, not part of the user's manual
                      // queue. Its first item is the exact track selected at
                      // queue end; tapping a suggestion plays from that point.
                      if (autoplay.isNotEmpty && !_selectionMode)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              hPad,
                              AppConstants.spacingSm,
                              hPad,
                              AppConstants.spacingSm,
                            ),
                            child: Text(
                              'Autoplay',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: context.adaptiveTextSecondary,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                        ),
                      if (autoplay.isNotEmpty && !_selectionMode)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            hPad, 0, hPad, AppConstants.spacingLg,
                          ),
                          sliver: SliverList.builder(
                            itemCount: autoplay.length,
                            itemBuilder: (context, index) => _UpcomingTile(
                              key: ValueKey('autoplay-${autoplay[index].id}-$index'),
                              song: autoplay[index],
                              index: index,
                              glass: embedded,
                              reorderable: false,
                              onTap: () async {
                                await ref.read(playerProvider.notifier)
                                    .playFromAutoplayIndex(index);
                                if (mounted) _openPlayer();
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
    if (!embedded) return content;
    // The player's backdrop is always dark, whatever the app theme.
    return AdaptiveColorProvider(backgroundColor: Colors.black, child: content);
  }

  /// Embedded, rows fade out under the player's header rather than being cut.
  static Widget _fadeTop(bool embedded, Widget list) {
    if (!embedded) return list;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
        stops: [0, .05],
      ).createShader(r),
      child: list,
    );
  }

  Widget _buildSelectionHeader(int queueCount) {
    final upNext = ref.read(upNextProvider);
    final queue = ref.read(queueProvider);
    final count = _selectedKeys.length;
    final totalItems = upNext.length + queue.length;
    final allSelected = totalItems > 0 && count == totalItems;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Row(
        children: [
          SurfaceIconButton.icon(
            icon: LucideIcons.x,
            onPressed: _exitSelectionMode,
            iconColor: context.adaptiveTextPrimary,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.sheet ? l10n.queue.toUpperCase() : l10n.queue,
                  style: widget.sheet
                      ? LokalTheme.label(context.lokal)
                      : Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: context.adaptiveTextPrimary,
                        ),
                ),
                Text(
                  l10n.selectedOfSong(count, queueCount),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: context.adaptiveTextTertiary),
                ),
              ],
            ),
          ),
          if (!allSelected)
            TextButton(
              onPressed: _selectAll,
              child: Text(
                l10n.selectAll,
                style: TextStyle(color: context.adaptiveTextSecondary),
              ),
            ),
          IconButton(
            icon: Icon(
              LucideIcons.trash2,
              color: Colors.redAccent.withValues(alpha: 0.8),
            ),
            onPressed: count > 0 ? _removeSelected : null,
            tooltip: l10n.removeSelected,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final int queueCount;
  final bool canClear;
  final Future<void> Function() onClear;
  final VoidCallback onSelectMode;

  const _Header({
    required this.queueCount,
    required this.canClear,
    required this.onClear,
    required this.onSelectMode,
    this.showBack = true,
    this.sheet = false,
  });

  final bool showBack;
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: showBack ? AppConstants.spacingLg : AppConstants.spacingXs,
        vertical: showBack ? AppConstants.spacingMd : AppConstants.spacingXs,
      ),
      child: Row(
        children: [
          if (showBack) ...[
            SurfaceIconButton.icon(
              icon: LucideIcons.chevronLeft,
              onPressed: () => Navigator.of(context).pop(),
              iconColor: context.adaptiveTextPrimary,
            ),
            const SizedBox(width: AppConstants.spacingMd),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sheet ? l10n.queue.toUpperCase() : l10n.queue,
                  style: sheet
                      ? LokalTheme.label(context.lokal)
                      : Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: context.adaptiveTextPrimary,
                        ),
                ),
                Text(
                  l10n.upcomingSong(queueCount),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: context.adaptiveTextTertiary),
                ),
              ],
            ),
          ),
          SurfaceIconButton.icon(
            icon: LucideIcons.checkCheck,
            onPressed: onSelectMode,
            iconColor: context.adaptiveTextPrimary,
          ),
          const SizedBox(width: AppConstants.spacingSm),
          if (canClear)
            TextButton(onPressed: onClear, child: Text(l10n.clearAll)),
        ],
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.spacingXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.listMusic,
              size: 52,
              color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: AppConstants.spacingLg),
            Text(
              l10n.queueIsEmpty,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: context.adaptiveTextSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            Text(
              l10n.addSongsFromThePlayerOr,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: context.adaptiveTextTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyUpcomingState extends StatelessWidget {
  const _EmptyUpcomingState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppConstants.spacingLg),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Row(
          children: [
            Icon(
              LucideIcons.sparkles,
              color: context.adaptiveTextTertiary,
              size: 20,
            ),
            const SizedBox(width: AppConstants.spacingSm),
            Expanded(
              child: Text(
                l10n.noUpcomingQueueItemsYet,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: context.adaptiveTextSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  final Song song;

  const _NowPlayingCard({required this.song, this.onOpen});
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onOpen != null,
      label: onOpen == null ? null : 'Open player: ${song.title}',
      child: Material(
        color: context.lokal.surface2,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: const ValueKey('queue-now-playing'),
          onTap: onOpen,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              border: Border.all(color: context.lokal.border),
            ),
            child: Row(
              children: [
                _Artwork(song: song),
                const SizedBox(width: AppConstants.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.nowPlaying2,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: context.lokal.accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: context.adaptiveTextPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: context.adaptiveTextSecondary),
                      ),
                    ],
                  ),
                ),
                if (onOpen != null)
                  Icon(Icons.chevron_right_rounded, color: context.lokal.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UpcomingTile extends StatelessWidget {
  final Song song;
  final int index;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onRemove;
  final bool isSelectionMode;
  final bool isSelected;
  final bool reorderable;

  const _UpcomingTile({
    super.key,
    required this.song,
    required this.index,
    required this.onTap,
    this.onLongPress,
    this.onRemove,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.reorderable = true,
    this.glass = false,
  });

  /// On the player's backdrop: frosted white instead of the theme surface.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final tile = Padding(
      padding: const EdgeInsets.only(bottom: AppConstants.spacingSm),
      child: Material(
        color: isSelected
            ? AppColors.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppConstants.spacingMd,
              vertical: AppConstants.spacingSm,
            ),
            decoration: _tileDecoration(glass),
            child: Row(
              children: [
                if (isSelectionMode) ...[
                  Icon(
                    isSelected ? LucideIcons.check : LucideIcons.circle,
                    color: isSelected
                        ? AppColors.accent
                        : context.adaptiveTextTertiary,
                    size: 22,
                  ),
                  const SizedBox(width: AppConstants.spacingSm),
                ] else if (reorderable)
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        right: AppConstants.spacingSm,
                      ),
                      child: Icon(
                        LucideIcons.gripVertical,
                        color: context.adaptiveTextTertiary,
                        size: 18,
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(
                      right: AppConstants.spacingSm,
                    ),
                    child: Icon(
                      LucideIcons.sparkles,
                      color: context.adaptiveTextTertiary,
                      size: 18,
                    ),
                  ),
                _Artwork(song: song),
                const SizedBox(width: AppConstants.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: context.adaptiveTextPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: context.adaptiveTextSecondary),
                      ),
                    ],
                  ),
                ),
                if (!isSelectionMode) ...[
                  Text(
                    song.formattedDuration,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: context.adaptiveTextTertiary),
                  ),
                  IconButton(
                    tooltip: 'More',
                    onPressed: () => SongActionsBottomSheet.show(
                      context,
                      song,
                      extras: [
                        if (onRemove != null)
                          LokalSongMenuAction(
                            icon: Icons.playlist_remove_rounded,
                            label: 'Remove from up next',
                            destructive: true,
                            onTap: onRemove!,
                          ),
                      ],
                    ),
                    icon: Icon(
                      LucideIcons.ellipsis,
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    if (isSelectionMode || onRemove == null) return tile;

    return Dismissible(
      key: ValueKey('upnext-dismiss-$index-${song.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          color: Colors.redAccent.withValues(alpha: 0.18),
          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.35)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.spacingLg),
        alignment: Alignment.centerRight,
        child: const Icon(LucideIcons.trash2, color: Colors.redAccent),
      ),
      onDismissed: (_) => onRemove!(),
      child: tile,
    );
  }
}

class _QueueTile extends StatelessWidget {
  final Song song;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;
  final VoidCallback? onMoveToNext;
  final bool isSelectionMode;
  final bool isSelected;

  const _QueueTile({
    required super.key,
    required this.song,
    required this.index,
    required this.onTap,
    this.onLongPress = _noop,
    required this.onRemove,
    required this.onMoveToNext,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.glass = false,
  });

  /// On the player's backdrop: frosted white instead of the theme surface.
  final bool glass;

  static void _noop() {}

  @override
  Widget build(BuildContext context) {
    final tile = Padding(
      padding: const EdgeInsets.only(bottom: AppConstants.spacingSm),
      child: Material(
        color: isSelected
            ? AppColors.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppConstants.spacingMd,
              vertical: AppConstants.spacingSm,
            ),
            decoration: _tileDecoration(glass),
            child: Row(
              children: [
                if (isSelectionMode) ...[
                  Icon(
                    isSelected ? LucideIcons.check : LucideIcons.circle,
                    color: isSelected
                        ? AppColors.accent
                        : context.adaptiveTextTertiary,
                    size: 22,
                  ),
                  const SizedBox(width: AppConstants.spacingSm),
                ] else
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        right: AppConstants.spacingSm,
                      ),
                      child: Icon(
                        LucideIcons.gripVertical,
                        color: context.adaptiveTextTertiary,
                        size: 18,
                      ),
                    ),
                  ),
                _Artwork(song: song),
                const SizedBox(width: AppConstants.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: context.adaptiveTextPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: context.adaptiveTextSecondary),
                      ),
                    ],
                  ),
                ),
                if (!isSelectionMode)
                  IconButton(
                    tooltip: 'More',
                    onPressed: () => SongActionsBottomSheet.show(
                      context,
                      song,
                      queueActions: false,
                      extras: [
                        if (onMoveToNext != null)
                          LokalSongMenuAction(
                            icon: Icons.playlist_play_rounded,
                            label: l10n.playNext,
                            onTap: onMoveToNext!,
                          ),
                        LokalSongMenuAction(
                          icon: Icons.playlist_remove_rounded,
                          label: 'Remove from queue',
                          destructive: true,
                          onTap: onRemove,
                        ),
                      ],
                    ),
                    icon: Icon(
                      LucideIcons.ellipsis,
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    if (isSelectionMode) return tile;

    return Dismissible(
      key: ValueKey('queue-dismiss-$index-${song.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          color: Colors.redAccent.withValues(alpha: 0.18),
          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.35)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.spacingLg),
        alignment: Alignment.centerRight,
        child: const Icon(LucideIcons.trash2, color: Colors.redAccent),
      ),
      onDismissed: (_) => onRemove(),
      child: tile,
    );
  }
}

class _Artwork extends StatelessWidget {
  final Song song;

  const _Artwork({required this.song});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppConstants.radiusMd),
      child: SizedBox(
        width: 48,
        height: 48,
        child: CachedImageWidget(
          imagePath: song.albumArt,
          audioSourcePath: song.filePath,
          fit: BoxFit.cover,
          useThumbnail: true,
          thumbnailWidth: 96,
          thumbnailHeight: 96,
          placeholder: ColoredBox(
            color: AppColors.surface,
            child: FlickArtworkPlaceholder(size: 22, opacity: 0.9),
          ),
          errorWidget: ColoredBox(
            color: AppColors.surface,
            child: FlickArtworkPlaceholder(size: 22, opacity: 0.9),
          ),
        ),
      ),
    );
  }
}

BoxDecoration _tileDecoration(bool glass) {
  if (glass) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(AppConstants.radiusLg),
      color: Colors.white.withValues(alpha: 0.08),
      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
    );
  }
  return BoxDecoration(
    borderRadius: BorderRadius.circular(AppConstants.radiusLg),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        AppColors.surfaceLight.withValues(alpha: 0.7),
        AppColors.surface.withValues(alpha: 0.82),
      ],
    ),
    border: Border.all(color: AppColors.glassBorder),
  );
}
