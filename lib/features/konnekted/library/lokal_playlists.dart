import 'package:flick/l10n/l10n.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:flick/services/sources/subsonic_service.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_home.dart';
import 'package:flick/models/playlist.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/online_playlist_reference.dart';
import 'package:flick/providers/playlist_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/widgets/lokal/lokal_choice_sheet.dart';

import 'lokal_library_kit.dart';
import 'lokal_playlist_order.dart';
import 'lokal_song_browser.dart';


/// A server playlist's cover is independent of its constituent tracks.
/// Fetch through authenticated getCoverArt rather than exposing auth in URLs.
final _subsonicPlaylistCoverProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({int serverId, String coverId})>((ref, key) async {
  final cacheKey = key.serverId.toString() + '|' + key.coverId;
  final cached = _playlistCoverCache.remove(cacheKey);
  if (cached != null) {
    _playlistCoverCache[cacheKey] = cached;
    return cached;
  }
  final servers = await ref.watch(networkServersProvider.future);
  final server = servers.where((item) => item.id == key.serverId).firstOrNull;
  if (server == null || server.protocol != 'subsonic') return null;
  final bytes = await SubsonicService.instance.getCoverArt(server, key.coverId);
  if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) return null;
  final image = Uint8List.fromList(bytes);
  _playlistCoverCache[cacheKey] = image;
  while (_playlistCoverCache.length > 16) {
    _playlistCoverCache.remove(_playlistCoverCache.keys.first);
  }
  return image;
});

final Map<String, Uint8List> _playlistCoverCache = {};

/// Prefer a Navidrome playlist's own artwork, using a song collage when the
/// server has no cover, is offline, or the request fails.
class LokalPlaylistArtwork extends ConsumerWidget {
  const LokalPlaylistArtwork({
    super.key,
    required this.playlist,
    required this.songs,
  });

  final Playlist playlist;
  final List<Song> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverId = playlist.coverArt?.trim();
    final serverId = playlist.networkServerId;
    final fallback = LokalCollage(songs: songs);
    if (serverId == null || coverId == null || coverId.isEmpty) {
      return fallback;
    }
    final cover = ref.watch(_subsonicPlaylistCoverProvider(
      (serverId: serverId, coverId: coverId),
    )).value;
    if (cover == null) return fallback;
    return Image.memory(
      cover,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }
}

/// Preserve stored playlist order. The shared library index aliases hidden
/// desktop tracks to their preferred phone copies. Online entries added before
/// a library scan use their saved metadata instead of disappearing.
Song? lokalPlaylistSong(Playlist playlist, String id, Map<String, Song> libraryById) {
  final local = libraryById[id];
  if (local != null) return local;
  final snapshot = playlist.songSnapshots[id];
  if (snapshot == null) return null;
  if (id.startsWith(onlinePlaylistPrefix)) {
    return restoreOnlinePlaylistSong(id, snapshot);
  }
  return snapshot.toSong(id);
}

List<Song> lokalPlaylistSongs(
  Playlist playlist,
  Map<String, Song> libraryById,
) => playlist.songIds
    .map((id) => lokalPlaylistSong(playlist, id, libraryById))
    .whereType<Song>()
    .toList(growable: false);

/// Playlist tiles need at most four covers, not a 10,000-track queue.
/// Bound each tile's scan so scrolling through huge collections remains cheap.
List<Song> lokalPlaylistCoverSongs(
  Playlist playlist,
  Map<String, Song> libraryById,
) {
  final covers = <String>{};
  final result = <Song>[];
  for (final id in playlist.songIds.take(64)) {
    final song = lokalPlaylistSong(playlist, id, libraryById);
    if (song == null) continue;
    final key = song.albumArt ??
        '${song.album ?? song.title}|${song.albumArtist ?? song.artist}';
    if (!covers.add(key)) continue;
    result.add(song);
    if (result.length == 4) break;
  }
  return result;
}

/// Keep the fully resolved playlist stable across rebuilds so searching and
/// changing menus do not repeat large metadata lookups.
final lokalResolvedPlaylistSongsProvider =
    Provider.autoDispose.family<List<Song>, String>((ref, playlistId) {
  final playlist = ref.watch(playlistProvider(playlistId));
  if (playlist == null) return const <Song>[];
  final byId =
      ref.watch(konnektedLibraryIndexProvider).value?.byId ??
      const <String, Song>{};
  return lokalPlaylistSongs(playlist, byId);
});

Future<String?> _askName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: context.lokal.surface2,
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: lokalText('Playlist name')),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(lokalText('Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(action),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

void _say(BuildContext context, String message) {
  if (!context.mounted) return;
  LokalToast.show(context, message);
}

/// Asks for a name and creates a playlist.
Future<void> lokalCreatePlaylist(BuildContext context, WidgetRef ref) async {
  final name = await _askName(
    context,
    title: lokalText('New playlist'),
    action: 'Create',
  );
  if (name == null || name.trim().isEmpty || !context.mounted) return;
  final playlist = await ref
      .read(playlistsProvider.notifier)
      .createPlaylist(name);
  if (!context.mounted) return;
  _say(
    context,
    playlist == null
        ? 'A playlist with this name already exists.'
        : 'Created “${playlist.name}”.',
  );
}

/// Imports an M3U or M3U8 file as a playlist.
Future<void> lokalImportM3u(BuildContext context, WidgetRef ref) async {
  try {
    final result = await ref
        .read(playlistsProvider.notifier)
        .importM3uPlaylist();
    if (result == null || !context.mounted) return;
    _say(
      context,
      'Imported “${result.playlist.name}” with ${lokalSongCount(result.importedSongs)}'
      '${result.unmatchedEntries > 0 ? ', ${result.unmatchedEntries} not found' : ''}.',
    );
  } catch (e) {
    if (context.mounted) _say(context, 'Couldn’t import this file: $e');
  }
}

/// Library › Playlists.
class LokalPlaylistsPage extends ConsumerWidget {
  const LokalPlaylistsPage({super.key});

  Future<void> _syncServers(BuildContext context, WidgetRef ref) async {
    try {
      final synced = await ref
          .read(playlistsProvider.notifier)
          .syncServerPlaylists();
      if (context.mounted) {
        _say(
          context,
          synced == 0
              ? 'No server playlists found.'
              : 'Synced $synced playlists.',
        );
      }
    } catch (e) {
      if (context.mounted) _say(context, 'Couldn’t sync server playlists: $e');
    }
  }

  Future<void> _showPlaylistActions(
    BuildContext context,
    WidgetRef ref,
    bool hasServers,
  ) async {
    final selected = await showLokalChoiceSheet<String>(
      context: context,
      title: 'Playlists',
      choices: [
        LokalChoice(value: 'new', label: lokalText('New playlist'), icon: Icons.add_rounded),
        LokalChoice(value: 'import', label: lokalText('Import M3U'), icon: Icons.file_upload_outlined),
        if (hasServers)
          LokalChoice(value: 'sync', label: lokalText('Sync server playlists'), icon: Icons.sync_rounded),
      ],
    );
    if (!context.mounted) return;
    switch (selected) {
      case 'new':
        await lokalCreatePlaylist(context, ref);
      case 'import':
        await lokalImportM3u(context, ref);
      case 'sync':
        await _syncServers(context, ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.lokal;
    final state = ref.watch(playlistsProvider);
    final libraryIndex = ref.watch(konnektedLibraryIndexProvider).value;
    final libraryById = libraryIndex?.byId ?? const <String, Song>{};
    final hasServers =
        ref.watch(networkServersProvider).value?.isNotEmpty ?? false;
    final playlists = state.value?.playlists;
    return LokalLibraryPage(
      title: lokalText('Playlists'),
      subtitle: playlists == null
          ? null
          : lokalText("{arg0} playlists", args: {'arg0': playlists.length}),
      actions: [
        LokalRoundAction(
          icon: Icons.add_rounded,
          label: lokalText('Add'),
          onPressed: () => unawaited(_showPlaylistActions(context, ref, hasServers)),
        ),
      ],
      slivers: [
        if (playlists == null)
          SliverToBoxAdapter(
            child: state.hasError
                ? LokalEmptyState(
                    icon: Icons.error_outline_rounded,
                    title: lokalText('Couldn’t load your playlists'),
                    message: lokalText('Try again in a moment.'),
                    actionLabel: 'Try again',
                    onAction: () => ref.invalidate(playlistsProvider),
                  )
                : const Padding(
                    padding: EdgeInsets.all(48),
                    child: Center(child: CircularProgressIndicator()),
                  ),
          )
        else ...[
          SliverToBoxAdapter(
            child: InkWell(
              onTap: () => lokalCreatePlaylist(context, ref),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: t.surface2,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.add_rounded, color: t.accent, size: 30),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      lokalText('New playlist…'),
                      style: TextStyle(fontSize: 16, color: t.accent),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverList.builder(
            itemCount: playlists.length,
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              final songs = lokalPlaylistCoverSongs(playlist, libraryById);
              return InkWell(
                onTap: () => pushLokal(
                  context,
                  LokalPlaylistPage(playlistId: playlist.id),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 64,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LokalPlaylistArtwork(
                            playlist: playlist,
                            songs: songs,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              playlist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              playlist.isNetworkSource
                                  ? lokalText(
                                      "{arg0} · server",
                                      args: {
                                        'arg0': lokalSongCount(
                                          playlist.songIds.length,
                                        ),
                                      },
                                    )
                                  : lokalSongCount(playlist.songIds.length),
                              style: TextStyle(fontSize: 13, color: t.muted),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: t.muted2),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// One playlist: collage, name, Play and Shuffle, the songs.
class LokalPlaylistPage extends ConsumerWidget {
  const LokalPlaylistPage({super.key, required this.playlistId});

  final String playlistId;

  Future<void> _rename(BuildContext context, WidgetRef ref, Playlist p) async {
    final name = await _askName(
      context,
      title: lokalText('Rename playlist'),
      action: 'Rename',
      initial: p.name,
    );
    if (name == null || name.trim().isEmpty) return;
    final ok = await ref
        .read(playlistsProvider.notifier)
        .renamePlaylist(p.id, name.trim());
    if (!ok && context.mounted) _say(context, 'Couldn’t rename this playlist.');
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Playlist p) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.lokal.surface2,
        title: Text(lokalText("Delete “{arg0}”?", args: {'arg0': p.name})),
        content: Text(lokalText('The songs stay in your library.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(lokalText('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              lokalText('Delete'),
              style: TextStyle(color: context.lokal.red),
            ),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    await ref.read(playlistsProvider.notifier).deletePlaylist(p.id);
    if (context.mounted) Navigator.of(context).maybePop();
  }

  Future<void> _export(BuildContext context, WidgetRef ref, Playlist p) async {
    try {
      final result = await ref
          .read(playlistsProvider.notifier)
          .exportPlaylistAsM3u(p.id, utf8: true);
      if (result != null && context.mounted) {
        _say(
          context,
          'Exported ${lokalSongCount(result.exportedSongs)} to ${result.fileName}.',
        );
      }
    } catch (e) {
      if (context.mounted) _say(context, 'Couldn’t export: $e');
    }
  }

  Future<void> _showActions(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    List<Song> songs,
  ) async {
    final selected = await showLokalChoiceSheet<String>(
      context: context,
      title: playlist.name,
      choices: [
        LokalChoice(value: 'queue', label: lokalText('Add to queue'), icon: Icons.queue_music_rounded),
        if (!playlist.isNetworkSource && playlist.songIds.length > 1)
          LokalChoice(value: 'reorder', label: lokalText('Reorder songs'), icon: Icons.sort_rounded),
        if (!playlist.isNetworkSource)
          LokalChoice(value: 'rename', label: lokalText('Rename'), icon: Icons.edit_rounded),
        LokalChoice(value: 'export', label: lokalText('Export as M3U8'), icon: Icons.file_download_outlined),
        LokalChoice(value: 'delete', label: lokalText('Delete playlist'),
          icon: Icons.delete_outline_rounded, destructive: true),
      ],
    );
    if (!context.mounted) return;
    switch (selected) {
      case 'queue':
        await lokalQueueAll(context, ref, songs);
      case 'reorder':
        await pushLokal(context, _ReorderPage(playlistId: playlistId));
      case 'rename':
        await _rename(context, ref, playlist);
      case 'export':
        await _export(context, ref, playlist);
      case 'delete':
        await _delete(context, ref, playlist);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.lokal;
    final playlist = ref.watch(playlistProvider(playlistId));
    final libraryIndex = ref.watch(konnektedLibraryIndexProvider).value;
    final libraryById = libraryIndex?.byId ?? const <String, Song>{};
    if (playlist == null) {
      return LokalLibraryPage(
        title: lokalText('Playlist'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        ],
      );
    }
    final songs = ref.watch(lokalResolvedPlaylistSongsProvider(playlistId));
    final width = MediaQuery.sizeOf(context).width;
    return LokalLibraryPage(
      title: playlist.name,
      actions: [
        LokalRoundAction(
          icon: Icons.more_horiz_rounded,
          label: lokalText('More'),
          onPressed: () => unawaited(_showActions(context, ref, playlist, songs)),
        ),
      ],
      header: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
        child: Column(
          children: [
            SizedBox.square(
              dimension: (width * .62).clamp(150.0, 300.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: LokalPlaylistArtwork(playlist: playlist, songs: songs),
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              header: true,
              child: Text(
                playlist.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              lokalText(
                "{arg0}, {arg1}",
                args: {
                  'arg0': lokalSongCount(songs.length),
                  'arg1': lokalRunningTime(songs),
                },
              ),
              style: TextStyle(color: t.muted),
            ),
          ],
        ),
      ),
      slivers: [
        if (songs.isEmpty)
          SliverToBoxAdapter(
            child: LokalEmptyState(
              icon: Icons.queue_music_rounded,
              title: lokalText('No songs yet'),
              message: lokalText(
                'Add songs from any song’s menu: More › Add to a playlist.',
              ),
            ),
          )
        else
          LokalSongBrowser(
            songs: songs,
            initialSort: LokalSongSort.original,
            originalLabel: 'Playlist order',
            preferencesKey: 'lokal.playlist.$playlistId.song_browser_view.v1',
            searchHint: 'Search in playlist',
            onRemove: playlist.isNetworkSource
                ? null
                : (song) {
                    // Aliased desktop entries display their phone copy, but
                    // removing must target the ID stored in this playlist.
                    final originalId = playlist.songIds.firstWhere(
                      (id) => lokalPlaylistSong(playlist, id, libraryById)?.id == song.id,
                      orElse: () => song.id,
                    );
                    unawaited(ref
                        .read(playlistsProvider.notifier)
                        .removeSongFromPlaylist(playlist.id, originalId));
                  },
          ),
      ],
    );
  }
}

class _ReorderPage extends ConsumerWidget {
  const _ReorderPage({required this.playlistId});

  final String playlistId;

  Future<void> _sortSavedOrder(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    Map<String, Song> byId,
  ) async {
    final choice = await showLokalChoiceSheet<LokalPlaylistOrder>(
      context: context,
      title: 'Sort playlist',
      choices: const [
        LokalChoice(value: LokalPlaylistOrder.titleAscending,
          label: 'Title · A–Z', icon: Icons.sort_by_alpha_rounded),
        LokalChoice(value: LokalPlaylistOrder.titleDescending,
          label: 'Title · Z–A', icon: Icons.sort_by_alpha_rounded),
        LokalChoice(value: LokalPlaylistOrder.artistAscending,
          label: 'Artist · A–Z', icon: Icons.person_outline_rounded),
        LokalChoice(value: LokalPlaylistOrder.artistDescending,
          label: 'Artist · Z–A', icon: Icons.person_outline_rounded),
        LokalChoice(value: LokalPlaylistOrder.dateAscending,
          label: 'Date added · Oldest first', icon: Icons.event_rounded),
        LokalChoice(value: LokalPlaylistOrder.dateDescending,
          label: 'Date added · Newest first', icon: Icons.event_rounded),
        LokalChoice(value: LokalPlaylistOrder.reverse,
          label: 'Reverse current order', icon: Icons.swap_vert_rounded),
      ],
    );
    if (choice == null || !context.mounted) return;
    final ordered = lokalOrderedPlaylistIds(playlist, byId, choice);
    final ok = await ref.read(playlistsProvider.notifier)
        .setSongOrder(playlistId, ordered);
    if (context.mounted) {
      _say(
        context,
        ok ? lokalText('Playlist order saved')
           : lokalText('Couldn’t reorder this playlist.'),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.lokal;
    final playlist = ref.watch(playlistProvider(playlistId));
    final byId =
        ref.watch(konnektedLibraryIndexProvider).value?.byId ??
        const <String, Song>{};
    final ids = playlist?.songIds ?? const <String>[];
    // Stable keys keep art and row state attached to tracks while dragging.
    // A per-id occurrence suffix also supports legacy lists with duplicates.
    final occurrence = <String, int>{};
    final rowKeys = [
      for (final id in ids)
        ValueKey(
          '$id#${occurrence.update(id, (n) => n + 1, ifAbsent: () => 0)}',
        ),
    ];
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            LokalPageBar(
              actions: [
                if (playlist != null && !playlist.isNetworkSource && ids.length > 1)
                  LokalRoundAction(
                    icon: Icons.sort_by_alpha_rounded,
                    label: lokalText('Sort playlist'),
                    onPressed: () => unawaited(
                      _sortSavedOrder(context, ref, playlist, byId),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(lokalText('Done')),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: LokalLargeTitle(
                title: lokalText('Reorder'),
                subtitle: lokalText('Drag to move'),
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                padding: EdgeInsets.only(
                  bottom: 150 + MediaQuery.paddingOf(context).bottom,
                ),
                itemCount: ids.length,
                // The service takes the drop index before removal, as onReorder had.
                onReorderItem: (from, to) => ref
                    .read(playlistsProvider.notifier)
                    .reorderSongs(playlistId, from, from < to ? to + 1 : to),
                itemBuilder: (context, index) {
                  final song = playlist == null
                       ? null
                       : lokalPlaylistSong(playlist, ids[index], byId);
                  return ListTile(
                    key: rowKeys[index],
                    leading: song == null
                        ? Icon(Icons.music_off_rounded, color: t.muted)
                        : KonnektedArtwork(song: song, size: 44, radius: 6),
                    title: Text(
                      song?.title ?? lokalText('Missing song'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      song?.artist ?? '',
                      maxLines: 1,
                      style: TextStyle(color: t.muted),
                    ),
                    trailing: Icon(Icons.drag_handle_rounded, color: t.muted),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
