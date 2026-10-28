import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/models/song.dart';
import 'package:flick/data/repositories/song_repository.dart';

typedef _SavedPlayback = ({
  String? songId,
  int positionMs,
  bool wasPlaying,
  String? playlistJson,
  int? index,
});

/// Service for persisting and restoring the last played song.
class LastPlayedService {
  // All instances share these preference keys. Preserve invocation order even
  // when a periodic save, acknowledged Pause and lifecycle save overlap.
  static Future<void> _pending = Future<void>.value();

  static Future<T> _ordered<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static const String _lastSongIdKey = 'last_played_song_id';
  static const String _lastPositionKey = 'last_played_position_ms';
  static const String _lastPlaylistSongIdsKey = 'last_played_playlist_song_ids';
  static const String _lastPlaylistIndexKey = 'last_played_playlist_index';
  static const String _lastWasPlayingKey = 'last_played_was_playing';
  static const String _snapshotKey = 'last_played_snapshot_v1';

  static Future<void> _writeSnapshot(
    SharedPreferences prefs,
    String json,
  ) async {
    try {
      if (!await prefs.setString(_snapshotKey, json)) {
        throw StateError('Could not save playback state.');
      }
    } catch (error, stack) {
      // The preference facade updates its cache before the platform write.
      // Recover the last committed value without replacing the primary error.
      try {
        await prefs.reload();
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
  }

  static _SavedPlayback? _readSnapshot(SharedPreferences prefs) {
    try {
      if (prefs.containsKey(_snapshotKey)) {
        final raw = prefs.getString(_snapshotKey);
        final data = raw == null ? null : jsonDecode(raw);
        // A cleared, damaged or future record must not resurrect legacy data.
        if (data is! Map ||
            data['schemaVersion'] != 1 ||
            data['cleared'] == true) {
          return null;
        }
        final id = data['songId'];
        final position = data['positionMs'];
        final playing = data['wasPlaying'];
        final ids = data['playlistSongIds'];
        final index = data['playlistIndex'];
        if (id is! String ||
            id.isEmpty ||
            position is! int ||
            position < 0 ||
            playing is! bool ||
            (ids != null &&
                (ids is! List ||
                    ids.any((id) => id is! String || id.isEmpty))) ||
            (index != null &&
                (index is! int ||
                    ids is! List ||
                    index < 0 ||
                    index >= ids.length))) {
          return null;
        }
        return (
          songId: id,
          positionMs: position,
          wasPlaying: playing,
          playlistJson: ids == null ? null : jsonEncode(ids),
          index: index as int?,
        );
      }
      return (
        songId: prefs.getString(_lastSongIdKey),
        positionMs: prefs.getInt(_lastPositionKey) ?? 0,
        wasPlaying: prefs.getBool(_lastWasPlayingKey) ?? false,
        playlistJson: prefs.getString(_lastPlaylistSongIdsKey),
        index: prefs.getInt(_lastPlaylistIndexKey),
      );
    } catch (_) {
      return null;
    }
  }

  final SongRepository _songRepository;

  LastPlayedService({SongRepository? songRepository})
    : _songRepository = songRepository ?? SongRepository();

  /// Save the currently playing song ID and position.
  ///
  /// Optionally stores the active playlist context so next/previous work
  /// correctly after app relaunch.
  Future<void> saveLastPlayed(
    String songId,
    Duration position, {
    List<String>? playlistSongIds,
    int? currentIndex,
    bool wasPlaying = false,
  }) {
    // Freeze caller-owned queue state before waiting for any previous write.
    final ids = playlistSongIds == null || playlistSongIds.isEmpty
        ? null
        : playlistSongIds;
    final snapshot = jsonEncode({
      'schemaVersion': 1,
      'songId': songId,
      'positionMs': position.isNegative ? 0 : position.inMilliseconds,
      'wasPlaying': wasPlaying,
      'playlistSongIds': ids,
      'playlistIndex':
          ids != null &&
              currentIndex != null &&
              currentIndex >= 0 &&
              currentIndex < ids.length
          ? currentIndex
          : null,
    });
    return _ordered(() async {
      final prefs = await SharedPreferences.getInstance();
      await _writeSnapshot(prefs, snapshot);
    });
  }

  /// Get the last played song and position.
  /// Returns null if no song was previously played.
  Future<
    ({
      Song song,
      Duration position,
      List<Song>? playlist,
      int? playlistIndex,
      bool wasPlaying,
    })?
  >
  getLastPlayed() async {
    // Read one coherent set before the asynchronous library lookup. A later
    // save must not attach another recording's cursor/queue to this song ID.
    final saved = await _ordered(() async {
      final prefs = await SharedPreferences.getInstance();
      return _readSnapshot(prefs);
    });
    if (saved == null) return null;
    final songId = saved.songId;

    if (songId == null) return null;

    // Find the song in the database
    final allSongs = await _songRepository.getAllSongs();
    final song = allSongs.where((s) => s.id == songId).firstOrNull;

    if (song == null) return null;

    List<Song>? restoredPlaylist;
    int? restoredPlaylistIndex;
    final playlistSongIdsRaw = saved.playlistJson;
    if (playlistSongIdsRaw != null) {
      try {
        final dynamic decoded = jsonDecode(playlistSongIdsRaw);
        if (decoded is List) {
          final playlistSongIds = decoded.whereType<String>().toList();
          if (playlistSongIds.isNotEmpty) {
            final songsById = {for (final s in allSongs) s.id: s};
            final mapped = <Song>[];
            for (final id in playlistSongIds) {
              final found = songsById[id];
              if (found != null) {
                mapped.add(found);
              }
            }
            if (mapped.isNotEmpty) {
              restoredPlaylist = mapped;
              final storedIndex = saved.index;
              if (storedIndex != null &&
                  storedIndex >= 0 &&
                  storedIndex < mapped.length &&
                  mapped[storedIndex].id == song.id) {
                restoredPlaylistIndex = storedIndex;
              } else {
                final songIndex = mapped.indexWhere((s) => s.id == song.id);
                restoredPlaylistIndex = songIndex >= 0 ? songIndex : 0;
              }
            }
          }
        }
      } catch (_) {
        // Ignore invalid or stale persisted playlist JSON.
      }
    }

    return (
      song: song,
      position: Duration(
        milliseconds: saved.positionMs < 0 ? 0 : saved.positionMs,
      ),
      playlist: restoredPlaylist,
      playlistIndex: restoredPlaylistIndex,
      wasPlaying: saved.wasPlaying,
    );
  }

  /// Clear the last played state.
  Future<void> clearLastPlayed() => _ordered(() async {
    final prefs = await SharedPreferences.getInstance();
    // Commit a tombstone first, so interrupted legacy cleanup cannot revive
    // an old recording on the next launch.
    await _writeSnapshot(
      prefs,
      jsonEncode({'schemaVersion': 1, 'cleared': true}),
    );
    await prefs.remove(_lastSongIdKey);
    await prefs.remove(_lastPositionKey);
    await prefs.remove(_lastPlaylistSongIdsKey);
    await prefs.remove(_lastPlaylistIndexKey);
    await prefs.remove(_lastWasPlayingKey);
  });
}
