import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/recommendation_match.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/models/song.dart';
import 'package:http/http.dart' as http;

import 'playlist_link_models.dart';

typedef PlaylistDownloadChoice = ({String sourceId, DiscoveryTrack track});

/// A remote playlist row that cannot be resolved is skipped, not treated as a
/// failed download. Later entries should still be attempted.
class PlaylistDownloadSourceUnavailable implements Exception {
  const PlaylistDownloadSourceUnavailable();

  @override
  String toString() => 'No verified downloadable source matched this entry. '
      'Check enabled add-ons or search for it manually.';
}

/// Reuses Online Search's checked sources and the library download pipeline.
class PlaylistUnmatchedDownloader {
  const PlaylistUnmatchedDownloader();
  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  static PlaylistDownloadChoice? directYouTube(
    ParsedPlaylistLink link, RemotePlaylistEntry entry,
  ) {
    final id = entry.remoteId;
    if (link.source != PlaylistLinkSource.youtube ||
        id == null || !_videoId.hasMatch(id)) return null;
    return (
      sourceId: 'yt',
      track: DiscoveryTrack(
        id: id,
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        duration: entry.duration,
        source: DiscoverySource.youtubeMusic,
        sourceUrl: Uri.https('www.youtube.com', '/watch', {'v': id}),
      ),
    );
  }

  /// Spotify (and YouTube entries lacking a usable video ID) must resolve
  /// against a verified title/artist/recording, not a first-search-hit guess.
  Future<PlaylistDownloadChoice?> findSource(
    RemotePlaylistEntry entry,
    List<OnlineSource> sources, {
    Future<bool> Function(OnlineSource source)? verifySource,
    void Function(String message)? onStatus,
    bool Function()? cancelled,
  }) async {
    if (entry.artist.trim().isEmpty || entry.title.trim().isEmpty) return null;
    final wanted = RecommendationCandidate(
      title: entry.title, artist: entry.artist,
      album: entry.album, duration: entry.duration,
    );
    for (final source in sources) {
      if (cancelled?.call() == true) {
        throw const DiscoveryException('Download cancelled.');
      }
      if (source.needsVerification?.call() == true) {
        if (verifySource == null || !await verifySource(source)) continue;
        if (source.needsVerification?.call() == true) continue;
      }
      for (final query in recommendationQueries(wanted).take(3)) {
        if (cancelled?.call() == true) {
          throw const DiscoveryException('Download cancelled.');
        }
        onStatus?.call('Searching ${source.name} for ${entry.title}…');
        try {
          final results = await source.search(query);
          final found = recommendationMatch(
            wanted, results,
            (track) => RecommendationCandidate(
              title: track.title, artist: track.artist,
              album: track.album, duration: track.duration,
            ),
          );
          if (found != null) return (sourceId: source.id, track: found);
        } catch (_) {
          // Another source can still provide the verified recording.
        }
      }
    }
    return null;
  }

  Future<LibraryDownloadResult> download(
    ParsedPlaylistLink link, RemotePlaylistEntry entry, {
    void Function(String message)? onStatus,
    Future<void>? cancel,
    bool Function()? cancelled,
    Future<bool> Function(OnlineSource source)? verifySource,
    Future<List<OnlineSource>> Function(http.Client client)? sources,
    Future<Song> Function(String sourceId, DiscoveryTrack track)? prepare,
    Future<LibraryDownloadResult> Function(Song ready)? save,
  }) async {
    var chosen = directYouTube(link, entry);
    if (chosen == null) {
      final client = http.Client();
      try {
        chosen = await findSource(
          entry,
          await (sources?.call(client) ?? onlineSources(client)),
          verifySource: verifySource,
          onStatus: onStatus,
          cancelled: cancelled,
        );
      } finally {
        client.close();
      }
    }
    if (chosen == null) throw const PlaylistDownloadSourceUnavailable();
    if (cancelled?.call() == true) {
      throw const DiscoveryException('Download cancelled.');
    }
    onStatus?.call('Downloading ${entry.title} to library…');
    final ready = await (prepare?.call(chosen.sourceId, chosen.track) ??
        playOnlineTrack(chosen.sourceId, chosen.track,
          forDownload: true, onStatus: onStatus, cancel: cancel));
    if (cancelled?.call() == true) {
      throw const DiscoveryException('Download cancelled.');
    }
    onStatus?.call('Saving ${entry.title} to your library…');
    return save?.call(ready) ??
        LibraryDownloader().save(ready, artwork: chosen.track.artwork);
  }
}
