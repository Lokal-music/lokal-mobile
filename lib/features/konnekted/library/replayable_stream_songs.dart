import 'dart:io';

import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/queue_pre_resolver.dart';

/// Metadata lookup, never a saved signed URL or an in-memory stream handle.
typedef StreamTrackLookup = Future<Song?> Function(
  LokalDiscoveryTrack track, {
  void Function(String)? onStatus,
  Future<void>? cancel,
});

/// Likes and playlists retain song metadata between rebuilds and restarts,
/// but live Mornye sessions and HTTP add-on tokens do not survive that long.
/// Previously the restored Song was handed directly to ExoPlayer and failed
/// with "Morneye stream expired" / "HTTP add-on stream expired".
bool needsStreamReResolution(Song song) {
  final source = song.sourcePackage;
  if (source == 'konnekted.morneye-live' ||
      source == 'konnekted.progressive') {
    // Reuse an active stream while the handle is still genuinely registered;
    // re-resolve as soon as its session expires.
    return !QueuePreResolver.isPlayableResolvedSource(song);
  }
  if (source == Song.pendingSourcePackage) return true;
  if (source == null || !source.startsWith('konnekted.')) return false;
  final path = song.filePath;
  // Keep actually downloaded/cache-backed files that are still present.
  return path == null || path.isEmpty || !File(path).existsSync();
}

/// Turn an expired streamed song into a registered on-demand queue placeholder,
/// retaining its durable favorite ID (unlike ordinary discovery placeholders).
///
/// This deliberately happens at playback time, not on each favorite-provider
/// refresh. It avoids stale handles even if a Likes page has stayed open for
/// hours, and doesn't interfere with downloaded files or Subsonic/WebDAV.
/// The normal QueuePreResolver still preloads the next four tracks.
Song replayableStreamSong(
  Song song, {
  QueuePreResolver? queueResolver,
  StreamTrackLookup? lookup,
}) {
  if (!needsStreamReResolution(song)) return song;
  final resolver = queueResolver ?? QueuePreResolver.shared;
  // A freshly created Search/Discovery placeholder already has a resolver
  // tied to the user's chosen add-on. Never overwrite that with a generic
  // artist/title search; only repair persisted placeholders with no resolver.
  if (song.isPending && resolver.hasResolver(song.id)) return song;
  final resolve = lookup ?? findDiscoverySong;
  final videoId = song.sourceDisplayName == 'YouTube Music' &&
          song.remoteId != null &&
          RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(song.remoteId!)
      ? song.remoteId
      : null;
  final track = LokalDiscoveryTrack(
    title: song.title,
    artist: song.artist,
    album: song.album ?? '',
    artworkUrl: song.albumArt ?? '',
    duration: song.duration > Duration.zero ? song.duration : null,
    videoId: videoId,
  );

  return resolver.pending(
    key: 'liked-stream:${song.id}',
    stableId: song.id,
    title: song.title,
    artist: song.artist,
    album: song.album,
    artwork: song.albumArt,
    duration: song.duration,
    resolve: ({onStatus, cancel}) async {
      final resolved = await resolve(
        track,
        onStatus: onStatus,
        cancel: cancel,
      );
      if (resolved == null) return null;
      // Do not silently substitute stereo when a liked source was verified
      // to contain Dolby Atmos (E-AC-3 JOC).
      if (song.atmosEncoded && !resolved.atmosEncoded) {
        throw StateError(
          'A verified Dolby Atmos stream was requested but not found.',
        );
      }
      // The stream's source identity can change after lookup, but the liked
      // track's ID must stay fixed for hearts, queue transitions and sorting.
      return resolved.copyWith(id: song.id);
    },
  );
}

List<Song> replayableStreamQueue(
  List<Song> songs, {
  QueuePreResolver? resolver,
  StreamTrackLookup? lookup,
}) => [
  for (final song in songs)
    replayableStreamSong(song, queueResolver: resolver, lookup: lookup),
];

/// Refresh every expired HTTP/Morneye handle before an existing playback
/// queue is submitted to Media3. A queue can remain open for hours, longer
/// than its registered HTTP URL or live-transfer session. Keeping a stale
/// resolved Song in a future slot bypasses the existing Likes-page repair.
///
/// [selected] remains authoritative when the user explicitly picks another
/// recording/source for the same logical song ID.
({Song selected, List<Song> queue}) replayableStreamSelection(
  Song selected,
  List<Song> queue, {
  QueuePreResolver? resolver,
  StreamTrackLookup? lookup,
}) {
  final prepared = replayableStreamSong(
    selected, queueResolver: resolver, lookup: lookup,
  );
  final refreshed = <Song>[
    for (final item in queue)
      if (item.id == selected.id) prepared
      else
        replayableStreamSong(item, queueResolver: resolver, lookup: lookup),
  ];
  return (selected: prepared, queue: refreshed);
}

