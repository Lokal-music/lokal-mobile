import '../milestone_service.dart';
import '../local_metadata_repair.dart';
import '../../models/song.dart';

import 'dart:convert';

import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/database.dart';
import '../../data/repositories/recently_played_repository.dart';
import '../../data/repositories/song_repository.dart';
import '../../models/lokal_remote_state.dart';
import '../../models/playlist.dart';
import '../favorites_service.dart';
import '../playlist_service.dart';
import '../online_playlist_reference.dart';
import 'link_journal.dart';
import 'link_playlist_order.dart';
import 'link_profile_service.dart';
import 'lokal_desktop_source.dart';
import 'lokal_link_service.dart';

/// Symmetric, cursor-based merge. Only explicit operations remove playlist items;
/// a missing desktop row can never delete a phone file, like, or playlist.
class LinkSyncCoordinator {
  LinkSyncCoordinator({
    required this.socket,
    required this.credentials,
    required this.favorites,
    this.onChanged,
    this.onProfileChanged,
    this.onProgress,
    this.initialProgress = const LinkSyncProgress(),
  });
  final LokalLinkService socket;
  final LokalRemoteCredentials credentials;
  final FavoritesService favorites;
  final void Function()? onChanged;
  final void Function()? onProfileChanged;
  final void Function(LinkSyncProgress)? onProgress;
  final LinkSyncProgress initialProgress;
  late LinkSyncProgress _progress = initialProgress;
  Future<void>? _active;
  bool _background = false;
  List<Song>? _matchCandidates;
  final _matchCache = <String, Song?>{};
  bool get busy => _active != null;

  Future<Song?> _match(Map<String, dynamic> track) async {
    final key = track['track_key']?.toString();
    if (key != null && _matchCache.containsKey(key)) return _matchCache[key];
    final song = await LinkJournal.instance.match(
      track,
      candidates: _matchCandidates,
    );
    if (key != null) _matchCache[key] = song;
    return song;
  }

  static String prefixFor(LokalRemoteCredentials value) =>
      'lokal.link.${value.desktopId}.user.${value.desktopUserId ?? 'guest'}';
  String get _prefix => prefixFor(credentials);
  Future<void> enableMerge() async {
    final active = _active;
    if (active != null) await active;
    await _run(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_prefix.merge', true);
      final ids = (prefs.getStringList('favorite_song_ids') ?? []).toSet();
      await LinkJournal.instance.captureFavorites(ids);
      await LinkJournal.instance.capturePlaylists(
        await PlaylistService.instance.getPlaylists(),
      );
      await _synchronize(importCatalog: true);
    });
  }

  void _report(
    LinkSyncPhase phase, {
    int processed = 0,
    int? total,
    int? catalogSongs,
    DateTime? completedAt,
  }) {
    if (_background) return;
    _progress = LinkSyncProgress(
      phase: phase,
      processed: processed,
      total: total,
      catalogSongs: catalogSongs ?? _progress.catalogSongs,
      completedAt: completedAt ?? _progress.completedAt,
    );
    onProgress?.call(_progress);
  }

  void _requireReady() {
    if (!socket.connected) throw StateError('Desktop link disconnected.');
    if (!Database.isInitialized)
      throw StateError('The music library is not ready.');
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool fullSync = true,
  }) {
    final active = _active;
    if (active != null) return active;
    final task = _execute(action, fullSync: fullSync);
    _active = task;
    return task.whenComplete(() {
      if (identical(_active, task)) _active = null;
    });
  }

  Future<void> _execute(
    Future<void> Function() action, {
    bool fullSync = true,
  }) async {
    if (fullSync) _report(LinkSyncPhase.preparing);
    try {
      _requireReady();
      await action();
      _requireReady();
      // Stats-only sync does not update the full-library sync timestamp.
      if (fullSync) {
        final completedAt = DateTime.now();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
          '$_prefix.last_sync',
          completedAt.millisecondsSinceEpoch,
        );
        if (_progress.catalogSongs case final count?) {
          await prefs.setInt('$_prefix.catalog_songs', count);
        }
        _report(LinkSyncPhase.complete, completedAt: completedAt);
      }
    } catch (_) {
      _report(
        LinkSyncPhase.paused,
        processed: _progress.processed,
        total: _progress.total,
      );
      rethrow;
    } finally {
      _matchCandidates = null;
      _matchCache.clear();
    }
  }

  Future<void> _backfillHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('lokal.link.history_backfilled') == true) return;
    final device = await LinkJournal.instance.deviceId();
    final rows = await Database.recentlyPlayed
        .filter()
        .eventIdIsNull()
        .findAll();
    final songs = {
      for (final song in await SongRepository().getAllSongs()) song.id: song,
    };
    for (final row in rows) {
      final song = songs[row.songId.toString()];
      if (song == null) continue;
      final id = 'mobile_${device}_${row.id}';
      // Legacy history retained song duration, not measured listen time. Keep
      // that existing estimate rather than inventing a new historic measurement.
      await LinkJournal.instance.recordPlay(
        eventId: id,
        songId: song.id,
        playedAt: row.playedAt.millisecondsSinceEpoch,
        msPlayed: row.listenedMs ?? song.duration.inMilliseconds,
      );
      row.eventId = id;
      await Database.instance.writeTxn(() => Database.recentlyPlayed.put(row));
    }
    await prefs.setBool('lokal.link.history_backfilled', true);
  }

  Future<void> synchronize({
    bool importCatalog = false,
    bool background = false,
  }) async {
    final active = _active;
    if (active != null) return active;
    if (!socket.connected || !Database.isInitialized) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('$_prefix.merge') != true) return;
    _background = background;
    try {
      await _run(() => _synchronize(importCatalog: importCatalog));
    } finally {
      _background = false;
    }
  }

  /// Automatic listening-statistics synchronization: one bounded journal page
  /// in each direction, no catalog, file, playlist, tag or lyrics operations.
  /// Older listening history is left for a later tick or manual full sync.
  Future<void> synchronizeStats() async {
    if (_active != null || !socket.connected || !Database.isInitialized) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('$_prefix.merge') != true) return;
    _background = true;
    try {
      await _run(_syncStatsBatch, fullSync: false);
    } finally {
      _background = false;
    }
  }

  Future<void> _syncStatsBatch() async {
    _requireReady();
    final prefs = await SharedPreferences.getInstance();
    final journal = LinkJournal.instance;
    const pageSize = 50;

    // One acknowledged outbound page per run, then checkpoint the cursor.
    final pushKey = '$_prefix.history.push';
    final outgoing = await journal.historyAfter(
      prefs.getInt(pushKey) ?? 0,
      limit: pageSize,
    );
    final pushed = outgoing['items'] as List;
    if (pushed.isNotEmpty) {
      await socket.request('history.push', {'items': pushed});
      _requireReady();
      await prefs.setInt(pushKey, outgoing['cursor'] as int);
    }

    // The desktop currently caps replies at 250 events. Consume only one
    // response per cycle to avoid monopolizing launch or playback resources.
    final pullKey = '$_prefix.history.pull';
    final reply = await socket.request('history.pull', {
      'cursor': prefs.getInt(pullKey) ?? 0,
    });
    _requireReady();
    final incoming = reply.body['items'];
    final nextCursor = reply.body['cursor'];
    if (incoming is! List ||
        incoming.length > 250 ||
        nextCursor is! int) {
      throw const FormatException('Invalid desktop listening-history page.');
    }
    if (incoming.isNotEmpty) {
      final accepted = await journal.mergeHistory(incoming);
      final songs = SongRepository();
      final candidatesByTitle = <String, List<Song>>{};
      for (final item in accepted) {
        // The journal always retains remote-only plays. Local recent history
        // is updated only for bounded, matching phone songs.
        final track = item['track'];
        if (track is! Map) continue;
        final wire = Map<String, dynamic>.from(track);
        final title = wire['title'] as String? ?? '';
        if (title.isEmpty) continue;
        final candidates = candidatesByTitle[title] ??=
            await songs.getHistoryMatchCandidates(title);
        if (candidates.isEmpty) continue;
        final song = await journal.match(wire, candidates: candidates);
        if (song == null) continue;
        await RecentlyPlayedRepository().recordPlay(
          song.id,
          eventId: item['event_id'] as String,
          playedAt: DateTime.fromMillisecondsSinceEpoch(
            item['played_at'] as int,
          ),
          listenedMs: item['ms_played'] as int,
        );
      }
      MilestoneService.changes.add(null);
    }
    // Only advance after journal and any matching local-history projections
    // were committed; interrupted runs can safely replay deduplicated events.
    await prefs.setInt(pullKey, nextCursor);
  }

  Future<void> _synchronize({required bool importCatalog}) async {
    final prefs = await SharedPreferences.getInstance();
    final source = LokalDesktopSource.instance,
        server = await LokalDesktopSource.instance.ensureServer(credentials);
    // A catalogue import is deliberately one-time. Subsequent explicit
    // syncs need a lightweight, genre-only repair because desktop lookup
    // results can predate the journal or fail to match when first received.
    final reconcileGenres = !importCatalog &&
        prefs.getBool('$_prefix.catalog') == true &&
        prefs.getBool('$_prefix.owned_catalog_v2') == true;
    if (importCatalog ||
        prefs.getBool('$_prefix.catalog') != true ||
        prefs.getBool('$_prefix.owned_catalog_v2') != true) {
      _report(LinkSyncPhase.catalog);
      await for (final progress in source.syncLibrary(server)) {
        _requireReady();
        _report(
          LinkSyncPhase.catalog,
          processed: progress.filesProcessed,
          total: progress.totalFiles,
          catalogSongs: progress.totalFiles,
        );
      }
      await prefs.setBool('$_prefix.catalog', true);
      await prefs.setBool('$_prefix.owned_catalog_v2', true);
      onChanged?.call();
    }
    if (!_background) {
      await LocalMetadataRepair.instance.repairDesktopCopies(
        onProgress: (done, total) {
          _report(LinkSyncPhase.metadata, processed: done, total: total);
        },
      );
      _report(LinkSyncPhase.lyrics);
      await source.syncCopiedLyrics(
        server,
        stillCurrent: () => socket.connected,
        onProgress: (done, total) =>
            _report(LinkSyncPhase.lyrics, processed: done, total: total),
      );
    }
    _requireReady();
    var changed = false;
    for (final kind in ['library', 'history']) {
      if (kind == 'history') await _backfillHistory();
      _requireReady();
      final phase = kind == 'history'
          ? LinkSyncPhase.history
          : LinkSyncPhase.library;
      var processed = 0;
      _report(phase);
      final pushKey = '$_prefix.$kind.push';
      while (socket.connected) {
        final cursor = prefs.getInt(pushKey) ?? 0;
        final batch = kind == 'history'
            ? await LinkJournal.instance.historyAfter(cursor)
            : await LinkJournal.instance.libraryAfter(cursor);
        final items = batch['items'] as List;
        if (items.isEmpty) break;
        await socket.request('$kind.push', {'items': items});
        processed += items.length;
        _report(phase, processed: processed);
        await prefs.setInt(pushKey, batch['cursor'] as int);
        if (batch['hasMore'] != true) break;
      }
      final pullKey = '$_prefix.$kind.pull';
      while (socket.connected) {
        final reply = await socket.request('$kind.pull', {
          'cursor': prefs.getInt(pullKey) ?? 0,
        });
        final items = reply.body['items'];
        if (items is! List || reply.body['cursor'] is! int)
          throw const FormatException('Invalid desktop sync page.');
        if (items.isNotEmpty) {
          changed = true;
          _matchCandidates ??= List<Song>.of(
            await SongRepository().getAllSongs(),
          );
        }
        if (kind == 'history') {
          final added = await LinkJournal.instance.mergeHistory(items);
          for (final item in added) {
            var song = await _match(item);
            // History is not ownership: retain the play event in the journal,
            // but never create a library song just because it was streamed.
            if (song != null)
              await RecentlyPlayedRepository().recordPlay(
                song.id,
                eventId: item['event_id'] as String,
                playedAt: DateTime.fromMillisecondsSinceEpoch(
                  item['played_at'] as int,
                ),
                listenedMs: item['ms_played'] as int,
              );
          }
        } else {
          final added = await LinkJournal.instance.mergeLibrary(items);
          if (added.isNotEmpty) {
            await _materializeLibraryPage(added);
            onChanged?.call();
          }
        }
        await prefs.setInt(pullKey, reply.body['cursor'] as int);
        processed += items.length;
        _report(phase, processed: processed);
        if (reply.body['hasMore'] != true) break;
      }
    }
    if (!_background && reconcileGenres) {
      _report(LinkSyncPhase.metadata);
      final repaired = await source.reconcileMissingGenres(server);
      if (repaired > 0) {
        changed = true;
        onChanged?.call();
      }
    }
    // A cursor only returns new events. Explicit Sync Now must also rebuild
    // playlists missing from the mobile store after a legacy or partial merge.
    // Replaying their durable operation history also repairs order and deletes.
    if (!_background) await _reconcileDesktopPlaylists();
    _requireReady();
    _report(LinkSyncPhase.finalizing);
    if (!_background) {
      await LinkProfileService.sync(credentials);
      onProfileChanged?.call();
    }
    if (changed || !_background) MilestoneService.changes.add(null);
  }

  /// Recover every playlist owned by the paired desktop on an explicit sync,
  /// even when the pull cursor has advanced or its local copy disappeared.
  /// The journal is authoritative for deletes, so this does not resurrect
  /// intentionally removed playlists. Mobile-origin and other desktop users'
  /// playlists are not reconstructed from unrelated operations.
  Future<void> _reconcileDesktopPlaylists() async {
    final desktopId = credentials.desktopId;
    if (desktopId == null || desktopId.isEmpty) return;

    final operations = await Database.instance.libraryOpEntitys
        .filter()
        .entityEqualTo('playlist')
        .findAll();
    final desktopPlaylistIds = <String>{};
    final desktopDeletions = <String>{};
    for (final operation in operations) {
      if (operation.deviceId != desktopId) continue;
      if (operation.op == 'playlist.create') {
        desktopPlaylistIds.add(operation.entityId);
      } else if (operation.op == 'playlist.delete') {
        desktopDeletions.add(operation.entityId);
      }
    }
    // A playlist originally created on the phone can later be deleted on
    // desktop. Include mapped deletions so an old consumed cursor cannot
    // silently leave the deleted mobile copy behind.
    final prefs = await SharedPreferences.getInstance();
    for (final id in desktopDeletions) {
      if (prefs.getString('lokal.link.playlist_local.$id') != null) {
        desktopPlaylistIds.add(id);
      }
    }
    var reconciled = false;
    for (final id in desktopPlaylistIds) {
      _requireReady();
      await _materialize({
        'entity': 'playlist',
        'entity_id': id,
        'op': 'playlist.create',
        'fields': <String, dynamic>{},
      });
      reconciled = true;
    }
    if (reconciled) onChanged?.call();
  }

  Future<void> _materializeLibraryPage(List<Map<String, dynamic>> items) async {
    final playlists = <String, Map<String, dynamic>>{};
    final likes = <String, bool>{};
    for (final item in items) {
      if (item['entity'] == 'playlist') {
        playlists[item['entity_id'] as String] = item;
      } else if (item['entity'] == 'like') {
        if (!await LinkJournal.instance.wins(item, 'liked')) continue;
        final song = await _match({
          ...Map<String, dynamic>.from(item['fields'] as Map),
          'track_key': item['entity_id'],
        });
        if (song != null) likes[song.id] = item['op'] == 'like';
      } else {
        await _materialize(item);
      }
    }
    if (likes.isNotEmpty) await favorites.setManyFromLink(likes);
    // mergeLibrary has already persisted every operation in this page. One
    // replay per playlist produces the same state as replaying it per member.
    for (final item in playlists.values) {
      await _materialize(item);
    }
  }

  Future<void> _materialize(Map<String, dynamic> item) async {
    final journal = LinkJournal.instance,
        fields = Map<String, dynamic>.from(item['fields'] as Map);
    switch (item['entity']) {
      case 'like':
        if (!await journal.wins(item, 'liked')) return;
        final song = await _match({...fields, 'track_key': item['entity_id']});
        if (song != null)
          await favorites.setFromLink(song.id, item['op'] == 'like');
        break;
      case 'playlist':
        final id = item['entity_id'] as String;
        final prefs = await SharedPreferences.getInstance();
        final localId = prefs.getString('lokal.link.playlist_local.$id') ?? id;
        await prefs.setString('lokal.link.playlist_uuid.$localId', id);
        await prefs.setString('lokal.link.playlist_local.$id', localId);
        final all = await Database.instance.libraryOpEntitys
            .filter()
            .entityIdEqualTo(id)
            .findAll();
        final state = LinkPlaylistOrder.replay([
          for (final op in all) journal.wireOp(op),
        ]);
        final name = state.name;
        if (name == null) return;
        // Retroactive replay can contain hundreds of members even when the
        // pull cursor returned no new rows. Share one library snapshot across
        // those matches; empty playlists should not read the library at all.
        if (state.members.isNotEmpty) {
          _matchCandidates ??= List<Song>.of(
            await SongRepository().getAllSongs(),
          );
        }
        final onlineSnapshots = <String, PlaylistSongSnapshot>{};
        final projection = await state.resolveMembers((member) async {
          final song = await _match({
            ...member.fields,
            'track_key': member.trackKey,
          });
          if (song != null) return song.id;

          // Desktop playlists must retain entries even when their original
          // audio has not been copied or the mobile catalogue cannot match it.
          // Keep a metadata-backed pending reference, rather than silently
          // shortening the list until the next explicit file copy.
          final fields = member.fields;
          final title = fields['title']?.toString().trim() ?? '';
          final artist = fields['artist']?.toString().trim() ?? '';
          if (title.isEmpty || artist.isEmpty) return null;
          final duration = (fields['duration'] as num?)?.toDouble() ?? 0;
          final rawArt = fields['artwork_url']?.toString() ?? '';
          final image = Uri.tryParse(rawArt);
          final publicArt = image != null &&
              image.scheme == 'https' &&
              !image.queryParameters.keys.any((name) =>
                  RegExp(r'token|signature|expires|auth', caseSensitive: false)
                      .hasMatch(name));
          final reference = stableOnlinePlaylistSong(Song(
            id: 'online-link:${member.trackKey}',
            title: title,
            artist: artist,
            album: fields['album']?.toString(),
            albumArt: publicArt ? rawArt : null,
            duration: Duration(
              milliseconds: (duration.clamp(0, 86400) * 1000).round(),
            ),
            fileType: 'ONLINE',
            sourcePackage: Song.pendingSourcePackage,
            remoteId: fields['source_ref']?.toString(),
          ));
          onlineSnapshots[reference.id] = PlaylistSongSnapshot.fromSong(reference);
          return reference.id;
        });
        final songIds = projection.songIds;
        final old = await PlaylistService.instance.getPlaylist(localId);
        final sameOrder = old != null &&
            old.songIds.length == songIds.length &&
            List.generate(songIds.length, (i) => i).every(
              (i) => old.songIds[i] == songIds[i],
            );
        final missingSnapshots = onlineSnapshots.keys.any(
          (id) => !(old?.songSnapshots.containsKey(id) ?? false),
        );
        if (state.deleted || old == null || old.name != name ||
            !sameOrder || missingSnapshots) {
          final snapshots = {...?old?.songSnapshots, ...onlineSnapshots}
            ..removeWhere((id, _) => !songIds.contains(id));
          final playlist =
              old?.copyWith(
                name: name,
                songIds: songIds,
                songSnapshots: snapshots,
                updatedAt: DateTime.now(),
              ) ??
              Playlist(
                id: localId,
                name: name,
                songIds: songIds,
                songSnapshots: snapshots,
                createdAt: DateTime.now(),
              );
          await PlaylistService.instance.putFromLink(
            playlist,
            deleted: state.deleted,
          );
        }
        // Store the merged baseline so a later local edit only journals its delta.
        final snapshot = Map<String, dynamic>.from(
          jsonDecode(prefs.getString('lokal.link.playlists_snapshot') ?? '{}')
              as Map,
        );
        if (state.deleted) {
          snapshot.remove(id);
        } else {
          snapshot[id] = {
            'name': name,
            // Snapshot is the *local projection*, not all remote entries:
            // unmatched desktop tracks must never look locally removed on
            // the next capture and be deleted remotely.
            'members': projection.matchedKeys,
          };
        }
        await prefs.setString(
          'lokal.link.playlists_snapshot',
          jsonEncode(snapshot),
        );
        break;
      case 'track':
        const editable = [
          'title',
          'artist',
          'album',
          'album_artist',
          'genre',
          'year',
          'track_num',
        ];
        // Desktop UPDATE triggers can emit hash-only operations even when
        // tag values did not change. They must not rewrite every phone row.
        if (!editable.any(fields.containsKey)) return;
        final song = await _match({...fields, 'track_key': item['entity_id']});
        if (song?.filePath == null) return;
        await journal.registerTrackAlias(song!.id, item['entity_id'] as String);
        final winning = <String, dynamic>{};
        for (final field in [
          'title',
          'artist',
          'album',
          'album_artist',
          'genre',
          'year',
          'track_num',
        ])
          if (fields.containsKey(field) && await journal.wins(item, field))
            winning[field] = fields[field];
        // The matching snapshot identifies rows; edits earlier in this sync
        // may already have changed their metadata, so compare the current row.
        final currentRow = await Database.songs
            .filter()
            .filePathEqualTo(song.filePath!)
            .findFirst();
        if (currentRow == null) return;
        final current = <String, dynamic>{
          'title': currentRow.title,
          'artist': currentRow.artist,
          'album': currentRow.album,
          'album_artist': currentRow.albumArtist,
          'genre': currentRow.genre,
          'year': currentRow.year,
          'track_num': currentRow.trackNumber,
        };
        winning.removeWhere(
          (field, value) => value == null || value == current[field],
        );
        if (winning.isEmpty) return;
        await SongRepository().updateSongMetadata(
          song.filePath!,
          title: winning['title'] as String?,
          artist: winning['artist'] as String?,
          album: winning['album'] as String?,
          albumArtist: winning['album_artist'] as String?,
          genre: winning['genre'] as String?,
          year: (winning['year'] as num?)?.toInt(),
          trackNumber: (winning['track_num'] as num?)?.toInt(),
          recordLink: false,
        );
        break;
    }
  }
}
