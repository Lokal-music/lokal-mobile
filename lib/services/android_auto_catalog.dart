import 'dart:convert';

import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/playback_context.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/online_playlist_reference.dart';
import 'package:flick/services/playlist_service.dart';

/// MediaBrowser catalog for Android Auto. No second player or MediaStore-only
/// index: these entries come from the same library, likes and playlists as UI.
class AndroidAutoCatalog {
  AndroidAutoCatalog({
    SongRepository? songs,
    FavoritesService? favorites,
    PlaylistService? playlists,
    PlayerService? player,
  }) : _songs = songs ?? SongRepository(),
       _favorites = favorites ?? FavoritesService(),
       _playlists = playlists ?? PlaylistService.instance,
       _player = player ?? PlayerService();

  final SongRepository _songs;
  final FavoritesService _favorites;
  final PlaylistService _playlists;
  final PlayerService _player;

  static const root = 'lokal/root';
  static const songs = 'lokal/songs';
  static const likes = 'lokal/likes';
  static const playlists = 'lokal/playlists';
  static const albums = 'lokal/albums';
  static const _playlistPrefix = 'lokal/playlist/';
  static const _albumPrefix = 'lokal/album/';
  static const _bucketPrefix = 'lokal/songs/';
  static const _trackPrefix = 'lokal/track/';

  static String _encode(String value) => base64Url.encode(utf8.encode(value));
  static String? _decode(String value) {
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(value)));
    } on FormatException {
      return null;
    }
  }

  static Map<String, Object?> _folder(String id, String title, [String? subtitle]) =>
      {'id': id, 'title': title, 'subtitle': subtitle, 'playable': false};

  static Map<String, Object?> _track(Song song, String parent) => {
    'id': '$_trackPrefix${_encode(parent)}/${_encode(song.id)}',
    'title': song.title,
    'subtitle': song.artist,
    'artUri': song.albumArt,
    'playable': true,
  };

  static String _initial(Song song) {
    final name = song.title.trim().toUpperCase();
    if (name.isEmpty) return '#';
    final first = name.substring(0, 1);
    return RegExp(r'^[A-Z]$').hasMatch(first) ? first : '#';
  }

  /// Media browser clients generally don't page results. Group large
  /// collections under stable alphabet buckets instead of truncating them.
  Future<List<Map<String, Object?>>> browse(String parentId) async {
    if (parentId == root) {
      return [
        _folder(songs, 'Songs'),
        _folder(likes, 'Liked Songs'),
        _folder(playlists, 'Playlists'),
        _folder(albums, 'Albums'),
      ];
    }
    if (parentId == songs) {
      final library = await _songs.getAllSongs();
      final initials = library.map(_initial).toSet().toList()..sort();
      return initials.map((letter) =>
          _folder('$_bucketPrefix$letter', letter == '#' ? '0–9 & Other' : letter)).toList();
    }
    if (parentId.startsWith(_bucketPrefix)) {
      final letter = parentId.substring(_bucketPrefix.length);
      if (letter.length != 1 || !RegExp(r'^[A-Z#]$').hasMatch(letter)) return [];
      final library = await _songs.getAllSongs();
      final items = library.where((song) => _initial(song) == letter).toList()
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      return items.map((song) => _track(song, parentId)).toList();
    }
    if (parentId == likes) {
      return (await _favorites.getFavorites())
          .map((song) => _track(song, likes)).toList();
    }
    if (parentId == playlists) {
      return (await _playlists.getPlaylists())
          .map((p) => _folder('$_playlistPrefix${_encode(p.id)}', p.name,
              '${p.songIds.length} songs')).toList();
    }
    if (parentId.startsWith(_playlistPrefix)) {
      final id = _decode(parentId.substring(_playlistPrefix.length));
      if (id == null) return [];
      final playlist = await _playlists.getPlaylist(id);
      if (playlist == null) return [];
      return (await _playlistSongs(id)).map((song) => _track(song, parentId)).toList();
    }
    if (parentId == albums) {
      final groups = await _songs.getSongsByAlbum();
      final names = groups.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return names.map((name) => _folder('$_albumPrefix${_encode(name)}',
          name, groups[name]?.firstOrNull?.artist)).toList();
    }
    if (parentId.startsWith(_albumPrefix)) {
      final album = _decode(parentId.substring(_albumPrefix.length));
      if (album == null) return [];
      final grouped = await _songs.getSongsByAlbum();
      return (grouped[album] ?? []).map((song) => _track(song, parentId)).toList();
    }
    return [];
  }

  Future<List<Song>> _playlistSongs(String playlistId) async {
    final playlist = await _playlists.getPlaylist(playlistId);
    if (playlist == null) return [];
    final byId = {for (final song in await _songs.getAllSongs()) song.id: song};
    return [
      for (final id in playlist.songIds)
        if (byId[id] != null) byId[id]!
        else if (playlist.songSnapshots[id] != null)
          id.startsWith(onlinePlaylistPrefix)
              ? restoreOnlinePlaylistSong(id, playlist.songSnapshots[id]!)
              : playlist.songSnapshots[id]!.toSong(id),
    ];
  }

  /// A car selection uses the existing player queue and source context.
  Future<bool> playMediaId(String mediaId) async {
    if (!mediaId.startsWith(_trackPrefix)) return false;
    final parts = mediaId.substring(_trackPrefix.length).split('/');
    if (parts.length != 2) return false;
    final parentId = _decode(parts[0]);
    final songId = _decode(parts[1]);
    if (parentId == null || songId == null) return false;

    List<Song> queue;
    PlaybackContext context = const PlaybackContext(source: PlaybackSource.allSongs);
    if (parentId == likes) {
      queue = await _favorites.getFavorites();
    } else if (parentId.startsWith(_playlistPrefix)) {
      final id = _decode(parentId.substring(_playlistPrefix.length));
      if (id == null) return false;
      queue = await _playlistSongs(id);
      context = PlaybackContext(source: PlaybackSource.playlist, sourceId: id);
    } else if (parentId.startsWith(_albumPrefix)) {
      final album = _decode(parentId.substring(_albumPrefix.length));
      if (album == null) return false;
      queue = (await _songs.getSongsByAlbum())[album] ?? [];
      context = PlaybackContext(source: PlaybackSource.album, sourceId: album);
    } else if (parentId.startsWith(_bucketPrefix)) {
      queue = await _songs.getAllSongs();
    } else {
      return false;
    }
    for (final song in queue) {
      if (song.id == songId) {
        await _player.play(song, playlist: queue, context: context);
        return true;
      }
    }
    return false;
  }

  /// Browse results for Android Auto's built-in search UI.
  Future<List<Map<String, Object?>>> search(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return [];
    final library = await _songs.getAllSongs();
    final matches = library.where((song) =>
        song.title.toLowerCase().contains(needle) ||
        song.artist.toLowerCase().contains(needle)).take(100);
    return matches.map((song) =>
        _track(song, '$_bucketPrefix${_initial(song)}')).toList();
  }

  /// Enables voice requests such as "play [song] on Lokal" for library tracks.
  Future<bool> playSearch(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return false;
    final library = await _songs.getAllSongs();
    final matches = library.where((s) =>
        s.title.toLowerCase().contains(needle) ||
        s.artist.toLowerCase().contains(needle)).toList();
    if (matches.isEmpty) return false;
    await _player.play(
      matches.first,
      playlist: matches,
      context: const PlaybackContext(source: PlaybackSource.allSongs),
    );
    return true;
  }
}
