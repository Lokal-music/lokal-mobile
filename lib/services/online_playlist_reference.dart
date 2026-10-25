import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../features/discovery/lastfm_discovery.dart';
import '../features/konnekted/konnekted_discovery.dart' show findDiscoverySong;
import '../models/playlist.dart';
import '../models/song.dart';
import 'queue_pre_resolver.dart';

/// A local playlist saves a stable, portable *catalogue reference*, never
/// an expiring audio URL, a cache file, or a resolver closure.
const onlinePlaylistPrefix = 'pending:playlist:';

String? _catalogueVideoId(String? id) {
  if (id == null) return null;
  final match = RegExp(r'^(?:yt:)?([A-Za-z0-9_-]{11})$').firstMatch(id);
  return match?.group(1);
}

/// Convert streamed or pending Flow items into a rehydratable playlist entry.
/// The hash is a cross-platform stable recording identity, independent of
/// ephemeral discovery cache IDs or the chosen playback extension.
Song stableOnlinePlaylistSong(Song song) {
  final normalized = [
    song.artist.trim().toLowerCase(),
    song.title.trim().toLowerCase(),
    song.album?.trim().toLowerCase() ?? '',
  ].join('\u001f');
  final stable = sha256.convert(utf8.encode(normalized)).toString().substring(0, 24);
  final id = '$onlinePlaylistPrefix$stable';
  return _onlinePending(
    id: id,
    title: song.title,
    artist: song.artist,
    album: song.album,
    artwork: song.albumArt,
    duration: song.duration,
    videoId: _catalogueVideoId(song.remoteId),
  );
}

/// Re-register a resolver whenever a stored playlist is opened. A snapshot
/// alone would be a visible but permanently unplayable pending Song.
Song restoreOnlinePlaylistSong(String id, PlaylistSongSnapshot snapshot) =>
    _onlinePending(
      id: id,
      title: snapshot.title,
      artist: snapshot.artist,
      album: snapshot.album,
      artwork: snapshot.albumArt,
      duration: Duration(milliseconds: snapshot.durationMs),
      videoId: _catalogueVideoId(snapshot.remoteId),
    );

Song _onlinePending({
  required String id,
  required String title,
  required String artist,
  String? album,
  String? artwork,
  required Duration duration,
  String? videoId,
}) {
  if (!id.startsWith('pending:')) {
    throw ArgumentError.value(id, 'id', 'Expected pending track identity');
  }
  final record = LokalDiscoveryTrack(
    title: title,
    artist: artist,
    album: album ?? '',
    artworkUrl: artwork ?? '',
    videoId: videoId,
    duration: duration,
  );
  final resolver = QueuePreResolver.shared;
  final song = resolver.pending(
    key: id.substring('pending:'.length),
    title: title,
    artist: artist,
    album: album,
    artwork: artwork,
    duration: duration,
    resolve: ({onStatus, cancel}) => findDiscoverySong(
      record,
      onStatus: onStatus,
      cancel: cancel,
      additionalProtectedPaths: () => resolver.resolvedPaths,
    ),
  );
  return song.copyWith(remoteId: videoId == null ? null : 'yt:$videoId');
}
