import 'dart:io';

import 'package:flick/features/discovery/discovery_progressive_streams.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/morneye/morneye_live_playback.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/queue_pre_resolver.dart';

/// Liked rows are persisted independently of the queue. Some of their Song
/// snapshots contain short-lived live-stream handles or temporary cache paths
/// that stop being playable after a process restart or playback handoff.
/// Keep the favorite's identity/metadata, but resolve a fresh source on tap.
bool likedSongNeedsFreshSource(Song song) {
  // Real local downloads and configured network-library songs retain their
  // own durable playback paths and resolver routes.
  if (song.sourceType != null) return false;
  if (song.isPending) return true;
  if (song.sourcePackage == 'konnekted.progressive') {
    return !DiscoveryProgressiveStreams.instance.contains(song.filePath);
  }
  if (song.sourcePackage == 'konnekted.morneye-live') {
    return MorneyeLiveRegistry.instance.resolve(song.filePath)?.isPlayable !=
        true;
  }
  if (!song.isExternal) return false;
  final path = song.filePath;
  if (path == null || path.isEmpty) return true;
  // Never treat signed URLs or dead temporary files as durable downloads.
  final uri = Uri.tryParse(path);
  if (uri != null && uri.hasScheme) {
    if (uri.scheme != 'file') return true;
    return !File.fromUri(uri).existsSync();
  }
  return !File(path).existsSync();
}

/// Called only on Play, Shuffle or track selection in Liked. Every expired
/// entry in the resulting queue receives a real new resolver rather than the
/// historical transient path; the original visible rows and IDs stay intact.
List<Song> playableLikedQueue(List<Song> liked) => [
  for (final song in liked)
    if (!likedSongNeedsFreshSource(song))
      song
    else
      QueuePreResolver.shared.pending(
        key: 'liked:${song.id}',
        title: song.title,
        artist: song.artist,
        album: song.album,
        duration: song.duration,
        artwork: song.albumArt,
        resolve: ({onStatus, cancel}) => findDiscoverySong(
          LokalDiscoveryTrack(
            title: song.title,
            artist: song.artist,
            album: song.album ?? '',
            artworkUrl: song.albumArt ?? '',
            duration: song.duration,
            videoId: song.sourceDisplayName?.toLowerCase() == 'youtube music' &&
                    RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(song.remoteId ?? '')
                ? song.remoteId
                : null,
          ),
          onStatus: onStatus,
          cancel: cancel,
        ),
      ),
];
