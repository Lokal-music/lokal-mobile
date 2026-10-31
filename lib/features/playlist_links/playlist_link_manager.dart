import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/playlist.dart';
import 'package:flick/models/song.dart';

import 'playlist_link_backend.dart';
import 'playlist_link_http.dart';
import 'playlist_link_importers.dart';
import 'playlist_link_matcher.dart';
import 'playlist_link_models.dart';
import 'playlist_link_parser.dart';
import 'playlist_link_store.dart';

abstract interface class PlaylistLinkLibrary {
  Future<List<Song>> getSongs();
}

class SongRepositoryPlaylistLinkLibrary implements PlaylistLinkLibrary {
  final SongRepository repository;

  SongRepositoryPlaylistLinkLibrary({SongRepository? repository})
    : repository = repository ?? SongRepository();

  @override
  Future<List<Song>> getSongs() => repository.getAllSongs();
}

class PlaylistLinkBusyException implements Exception {
  const PlaylistLinkBusyException();

  @override
  String toString() => 'Another playlist link operation is already running.';
}

class PlaylistLinkOperationException implements Exception {
  final String message;

  const PlaylistLinkOperationException(this.message);

  @override
  String toString() => message;
}

class PlaylistLinkManager {
  final PlaylistLinkImporter importer;
  final PlaylistLinkMetadataStore metadataStore;
  final LinkedPlaylistBackend playlists;
  final PlaylistLinkLibrary library;
  final PlaylistLinkMatcher matcher;
  final bool _ownsImporter;

  PlaylistLinkCancellationToken? _activeCancellation;
  bool _disposed = false;

  PlaylistLinkManager({
    PlaylistLinkImporter? importer,
    PlaylistLinkMetadataStore? metadataStore,
    LinkedPlaylistBackend? playlists,
    PlaylistLinkLibrary? library,
    PlaylistLinkMatcher? matcher,
  }) : importer = importer ?? PublicPlaylistImporter(),
       metadataStore = metadataStore ?? SharedPreferencesPlaylistLinkStore(),
       playlists = playlists ?? PlaylistServiceBackend(),
       library = library ?? SongRepositoryPlaylistLinkLibrary(),
       matcher = matcher ?? const PlaylistLinkMatcher(),
       _ownsImporter = importer == null;

  bool get isBusy => _activeCancellation != null;

  Future<List<PlaylistLinkRecord>> getLinks() async {
    _ensureUsable();
    return metadataStore.load();
  }

  Future<PlaylistLinkPreview> preview(String input) =>
      _run((cancellation) async {
        final link = PlaylistLinkParser.parse(input);
        return _fetchPreview(link, cancellation);
      });

  Future<PlaylistLinkPreview> previewLink(String linkId) => _run((
    cancellation,
  ) async {
    final records = await metadataStore.load();
    final record = _findRecord(records, linkId);
    if (record == null) {
      throw const PlaylistLinkOperationException('Linked playlist not found.');
    }
    final link = ParsedPlaylistLink(
      source: record.source,
      remoteId: record.remoteId,
      canonicalUrl: record.canonicalUrl,
    );
    return _fetchPreview(link, cancellation);
  });

  Future<PlaylistLinkRecord> createFromPreview(
    PlaylistLinkPreview preview, {
    String? name,
  }) => _run((cancellation) async {
    cancellation.throwIfCancelled();
    final records = await metadataStore.load();
    if (_findRecord(records, preview.link.linkId) != null) {
      throw const PlaylistLinkOperationException(
        'This playlist is already linked. Preview it to refresh instead.',
      );
    }
    if (preview.remote.entries.isEmpty) {
      throw const PlaylistLinkOperationException(
        'The remote playlist has no importable entries.',
      );
    }

    final playlistName = (name ?? preview.remote.title).trim();
    if (playlistName.isEmpty) {
      throw const PlaylistLinkOperationException(
        'A playlist name is required.',
      );
    }
    final created = await playlists.createPlaylist(playlistName);
    if (created == null) {
      throw const PlaylistLinkOperationException(
        'A local playlist with that name already exists.',
      );
    }

    final targetOrder = _uniqueSongIds(
      preview.matches.matches.map((match) => match.song.id),
    );
    try {
      await _applyOrder(created.id, const [], targetOrder, cancellation);
      final record = _recordFor(
        link: preview.link,
        playlist: created,
        remote: preview.remote,
        report: preview.matches,
        managedSongIds: targetOrder,
      );
      await metadataStore.save([...records, record]);
      return record;
    } catch (error) {
      await _restorePlaylist(created.id, const []);
      await playlists.deletePlaylist(created.id);
      rethrow;
    }
  });

  Future<PlaylistLinkRefreshResult> refreshFromPreview(
    PlaylistLinkPreview preview, {
    bool removeMissing = false,
  }) => _run((cancellation) async {
    cancellation.throwIfCancelled();
    final oldRecord = preview.existingLink;
    if (oldRecord == null) {
      throw const PlaylistLinkOperationException(
        'This preview does not belong to an existing link.',
      );
    }
    final current = await playlists.getPlaylist(oldRecord.playlistId);
    if (current == null) {
      throw const PlaylistLinkOperationException(
        'The saved local playlist no longer exists.',
      );
    }
    final records = await metadataStore.load();
    final stored = _findRecord(records, oldRecord.linkId);
    if (stored == null) {
      throw const PlaylistLinkOperationException(
        'Linked playlist metadata changed.',
      );
    }

    final oldManaged = stored.managedSongIds.toSet();
    final matchedIds = _uniqueSongIds(
      preview.matches.matches.map((match) => match.song.id),
    );
    final target = <String>[];
    if (preview.remote.complete) {
      target.addAll(matchedIds);
      for (final id in current.songIds) {
        if (target.contains(id)) continue;
        if (!removeMissing || !oldManaged.contains(id)) target.add(id);
      }
    } else {
      // A partial listing can only append newly resolved songs. It must not
      // reorder or remove anything because absent rows may simply be on a
      // continuation page that the source did not return.
      target.addAll(current.songIds);
      for (final id in matchedIds) {
        if (!target.contains(id)) target.add(id);
      }
      removeMissing = false;
    }

    // Explicit downloads remain local additions even when a refresh resolves
    // them, so remote omissions cannot remove them.
    final downloadedIds = stored.downloadedSongIds.values.toSet();
    final managedMatches = matchedIds.where(
      (id) => !downloadedIds.contains(id) || oldManaged.contains(id),
    );
    final nextManaged = preview.remote.complete && removeMissing
        ? managedMatches.toList()
        : _uniqueSongIds([...stored.managedSongIds, ...managedMatches]);
    final beforeOrder = List<String>.from(current.songIds);
    final changed = !_sameOrder(beforeOrder, target);
    try {
      if (changed) {
        await _applyOrder(current.id, beforeOrder, target, cancellation);
      }
      final nextRecord = _recordFor(
        link: preview.link,
        playlist: current,
        remote: preview.remote,
        report: preview.matches,
        managedSongIds: nextManaged,
        downloadedSongIds: stored.downloadedSongIds,
      );
      await metadataStore.save(
        records
            .map((item) => item.linkId == nextRecord.linkId ? nextRecord : item)
            .toList(),
      );
      final updated = await playlists.getPlaylist(current.id);
      if (updated == null) {
        throw const PlaylistLinkOperationException(
          'The local playlist disappeared during refresh.',
        );
      }
      return PlaylistLinkRefreshResult(
        record: nextRecord,
        playlist: updated,
        report: preview.matches,
        changed: changed,
        removedMissing: preview.remote.complete && removeMissing,
      );
    } catch (error) {
      await _restorePlaylist(current.id, beforeOrder);
      rethrow;
    }
  });

  /// Attach a user-requested download without guessing a library match from
  /// remote metadata. The download has already been saved and indexed, so
  /// compare its exact on-device path to the new library row.
  Future<String> attachDownloadedEntry(
    String linkId,
    RemotePlaylistEntry entry, {
    required String savedPath,
  }) => _run((cancellation) async {
    cancellation.throwIfCancelled();
    final records = await metadataStore.load();
    final index = records.indexWhere((record) => record.linkId == linkId);
    if (index < 0) {
      throw const PlaylistLinkOperationException('Linked playlist no longer exists.');
    }
    final record = records[index];
    final matchingIndex = record.unmatchedEntries.indexWhere(
      (candidate) => _sameRemoteEntry(candidate, entry),
    );
    if (matchingIndex < 0) {
      throw const PlaylistLinkOperationException(
        'That entry is no longer unmatched. Refresh the linked playlist.',
      );
    }
    final songs = (await library.getSongs())
        .where((song) => song.filePath == savedPath).toList();
    if (songs.length != 1) {
      throw const PlaylistLinkOperationException(
        'The song was saved but its library entry is not indexed yet. '
        'Refresh the library, then retry the link.',
      );
    }
    final playlist = await playlists.getPlaylist(record.playlistId);
    if (playlist == null) {
      throw const PlaylistLinkOperationException('The local playlist is missing.');
    }
    final songId = songs.single.id;
    final beforeOrder = List<String>.from(playlist.songIds);
    final resolved = {...record.resolvedSongIds, entry.identityKey: songId};
    final target = List<String>.from(beforeOrder);
    final position = record.remoteEntries.indexWhere(
      (candidate) => _sameRemoteEntry(candidate, entry),
    );
    if (!target.contains(songId)) {
      var insertAt = target.length;
      if (!record.isPartial && position >= 0) {
        // Keep existing songs in their current order, including local additions.
        for (final next in record.remoteEntries.skip(position + 1)) {
          final id = resolved[next.identityKey] ?? resolved[next.legacyIdentityKey];
          final index = target.indexOf(id ?? '');
          if (index >= 0) {
            insertAt = index;
            break;
          }
        }
        if (insertAt == target.length) {
          for (final previous in record.remoteEntries.take(position).toList().reversed) {
            final id = resolved[previous.identityKey] ?? resolved[previous.legacyIdentityKey];
            final index = target.indexOf(id ?? '');
            if (index >= 0) {
              insertAt = index + 1;
              break;
            }
          }
        }
      }
      target.insert(insertAt, songId);
    }
    try {
      await _applyOrder(playlist.id, beforeOrder, target, cancellation);
      cancellation.throwIfCancelled();
      final unresolved = record.unmatchedEntries
          .where((candidate) => !_sameRemoteEntry(candidate, entry)).toList();
      final revised = record.copyWith(
        unmatchedEntries: unresolved,
        resolvedSongIds: resolved,
        downloadedSongIds: {...record.downloadedSongIds, entry.identityKey: songId},
      );
      final updated = [...records];
      updated[index] = revised;
      await metadataStore.save(updated);
      return songId;
    } catch (_) {
      await _restorePlaylist(playlist.id, beforeOrder);
      rethrow;
    }
  });

  static bool _sameRemoteEntry(
    RemotePlaylistEntry a, RemotePlaylistEntry b,
  ) => a.identityKey == b.identityKey;

  Future<void> unlink(String linkId) => _run((_) async {
    final records = await metadataStore.load();
    if (_findRecord(records, linkId) == null) return;
    // Only metadata is removed. The user's saved local playlist is kept.
    await metadataStore.save(
      records.where((record) => record.linkId != linkId).toList(),
    );
  });

  void cancelCurrent() {
    _activeCancellation?.cancel();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activeCancellation?.cancel();
    if (_ownsImporter && importer is PublicPlaylistImporter) {
      (importer as PublicPlaylistImporter).close();
    }
  }

  Future<PlaylistLinkPreview> _fetchPreview(
    ParsedPlaylistLink link,
    PlaylistLinkCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final remote = await importer.fetch(link, cancellation: cancellation);
    cancellation.throwIfCancelled();
    final songs = await library.getSongs();
    cancellation.throwIfCancelled();
    final records = await metadataStore.load();
    final existingLink = _findRecord(records, link.linkId);
    final report = matcher.match(remote.entries, songs,
        resolvedSongIds: existingLink?.downloadedSongIds ?? const {});
    final existingPlaylist = existingLink == null
        ? null
        : await playlists.getPlaylist(existingLink.playlistId);
    return PlaylistLinkPreview(
      link: link,
      remote: remote,
      matches: report,
      existingLink: existingLink,
      existingPlaylist: existingPlaylist,
    );
  }

  PlaylistLinkRecord _recordFor({
    required ParsedPlaylistLink link,
    required Playlist playlist,
    required RemotePlaylistSnapshot remote,
    required PlaylistLinkMatchReport report,
    required List<String> managedSongIds,
    Map<String, String> downloadedSongIds = const {},
  }) {
    return PlaylistLinkRecord(
      linkId: link.linkId,
      source: link.source,
      remoteId: link.remoteId,
      canonicalUrl: link.canonicalUrl,
      playlistId: playlist.id,
      remoteTitle: remote.title,
      description: remote.description,
      thumbnailUrl: remote.thumbnailUrl,
      managedSongIds: managedSongIds,
      unmatchedEntries: List.of(report.unmatchedEntries),
      remoteEntries: List.of(remote.entries),
      resolvedSongIds: {
        for (final match in report.matches) match.remoteEntry.identityKey: match.song.id,
      },
      downloadedSongIds: downloadedSongIds,
      remoteEntryCount: remote.totalEntries ?? remote.entries.length,
      fetchedEntryCount: remote.entries.length,
      duplicateMatches: report.duplicateMatches,
      syncStatus: remote.complete
          ? PlaylistLinkSyncStatus.complete
          : PlaylistLinkSyncStatus.partial,
      lastSyncedAt: DateTime.now(),
      lastSyncMessage: remote.truncationReason,
    );
  }

  Future<void> _applyOrder(
    String playlistId,
    List<String> beforeOrder,
    List<String> targetOrder,
    PlaylistLinkCancellationToken cancellation,
  ) async {
    final target = _uniqueSongIds(targetOrder);
    final current = List<String>.from(beforeOrder);
    for (final id in target) {
      cancellation.throwIfCancelled();
      if (current.contains(id)) continue;
      if (!await playlists.addSong(playlistId, id)) {
        throw PlaylistLinkOperationException(
          'Could not add a matched song to the playlist.',
        );
      }
      current.add(id);
    }
    for (final id in List<String>.from(current)) {
      cancellation.throwIfCancelled();
      if (target.contains(id)) continue;
      if (!await playlists.removeSong(playlistId, id)) {
        throw PlaylistLinkOperationException(
          'Could not remove a song from the playlist.',
        );
      }
      current.remove(id);
    }
    if (!_sameOrder(current, target) &&
        !await playlists.replaceOrder(playlistId, target)) {
      throw PlaylistLinkOperationException(
        'Could not preserve playlist order.',
      );
    }
  }

  Future<void> _restorePlaylist(String playlistId, List<String> order) async {
    try {
      final currentPlaylist = await playlists.getPlaylist(playlistId);
      if (currentPlaylist == null) return;
      final current = List<String>.from(currentPlaylist.songIds);
      for (final id in order) {
        if (!current.contains(id)) {
          if (await playlists.addSong(playlistId, id)) current.add(id);
        }
      }
      for (final id in List<String>.from(current)) {
        if (!order.contains(id)) {
          if (await playlists.removeSong(playlistId, id)) current.remove(id);
        }
      }
      if (!_sameOrder(current, order)) {
        await playlists.replaceOrder(playlistId, order);
      }
    } catch (_) {
      // Preserve the original operation error. The saved link metadata is not
      // written until the playlist operation has succeeded.
    }
  }

  Future<T> _run<T>(
    Future<T> Function(PlaylistLinkCancellationToken) action,
  ) async {
    _ensureUsable();
    if (_activeCancellation != null) throw const PlaylistLinkBusyException();
    final cancellation = PlaylistLinkCancellationToken();
    _activeCancellation = cancellation;
    try {
      return await action(cancellation);
    } finally {
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
      }
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw const PlaylistLinkOperationException(
        'Playlist link screen is disposed.',
      );
    }
  }

  static PlaylistLinkRecord? _findRecord(
    List<PlaylistLinkRecord> records,
    String linkId,
  ) {
    for (final record in records) {
      if (record.linkId == linkId) return record;
    }
    return null;
  }

  static List<String> _uniqueSongIds(Iterable<String> ids) {
    final seen = <String>{};
    return [
      for (final id in ids)
        if (seen.add(id)) id,
    ];
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}
