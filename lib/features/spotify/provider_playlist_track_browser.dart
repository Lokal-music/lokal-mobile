import 'dart:async';
import 'dart:io';

import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/playlist_links/playlist_link_models.dart';
import 'package:flick/features/playlist_links/playlist_unmatched_downloader.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/songs_provider.dart';
import 'package:flick/features/konnekted/library/lokal_library_kit.dart';
import 'package:flick/features/spotify/provider_playlist_track_tile.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Return original playlist indices, retaining duplicates and track order.
/// Provider playlists have track metadata, not a known playback quality.
List<int> providerPlaylistMatchingIndices(
  List<LokalDiscoveryTrack> tracks,
  String query,
) {
  final needle = query.trim().toLowerCase();
  return [
    for (var i = 0; i < tracks.length; i++)
      if (needle.isEmpty ||
          '${tracks[i].title}\n${tracks[i].artist}\n${tracks[i].album}'
              .toLowerCase()
              .contains(needle))
        i,
  ];
}

RemotePlaylistEntry providerPlaylistDownloadEntry(
    LokalDiscoveryTrack track, PlaylistLinkSource source) {
  return RemotePlaylistEntry(
    title: track.title,
    artist: track.artist,
    album: track.album.isEmpty ? null : track.album,
    duration: track.duration,
    remoteId: source == PlaylistLinkSource.youtube ? track.videoId : null,
  );
}

/// Shared read-only playlist controls for Spotify and YouTube Music.
/// Playback is delegated to the parent so source resolution, queues, and
/// providers are exactly the same as when a track is tapped.
class ProviderPlaylistTrackBrowser extends ConsumerStatefulWidget {
  const ProviderPlaylistTrackBrowser({
    super.key,
    required this.tracks,
    required this.artworkBuilder,
    required this.source,
    required this.playlistId,
    required this.onPlay,
    required this.onSongActions,
  });

  final List<LokalDiscoveryTrack> tracks;
  final Widget Function(LokalDiscoveryTrack track) artworkBuilder;
  final PlaylistLinkSource source;
  final String playlistId;

  /// [orderedIndices] are original playlist indices in playback queue order.
  /// [startIndex] addresses that queue, not the unfiltered source playlist.
  final void Function(List<int> orderedIndices, int startIndex) onPlay;
  final void Function(int sourceIndex) onSongActions;

  @override
  ConsumerState<ProviderPlaylistTrackBrowser> createState() =>
      _ProviderPlaylistTrackBrowserState();
}

class _ProviderPlaylistTrackBrowserState
    extends ConsumerState<ProviderPlaylistTrackBrowser> {
  final _search = TextEditingController();
  String _query = '';
  Completer<void>? _cancellation;
  String? _downloadStatus;
  bool _downloading = false;

  @override
  void dispose() {
    final cancel = _cancellation;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    _search.dispose();
    super.dispose();
  }

  void _play(List<int> visible, {int start = 0, bool shuffle = false}) {
    if (visible.isEmpty) return;
    final queueIndices = List<int>.of(visible);
    if (shuffle) queueIndices.shuffle();
    widget.onPlay(queueIndices, shuffle ? 0 : start);
  }

  void _cancelDownload() {
    final cancel = _cancellation;
    if (cancel != null && !cancel.isCompleted) {
      cancel.complete();
      if (mounted) setState(() => _downloadStatus = 'Cancelling download…');
    }
  }

  Future<void> _downloadPlaylist() async {
    if (_downloading || widget.tracks.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Download playlist?'),
        content: Text(
          'Download ${widget.tracks.length} playlist entries to your '
          'local library using enabled playback sources? '
          'Songs already saved on this device will be skipped. '
          'Unavailable recordings may fail. This can use substantial data '
          'and storage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _downloading) return;

    final cancel = Completer<void>();
    final downloader = const PlaylistUnmatchedDownloader();
    final link = ParsedPlaylistLink(
      source: widget.source,
      remoteId: widget.playlistId,
      canonicalUrl: widget.source == PlaylistLinkSource.spotify
          ? 'https://open.spotify.com/playlist/${widget.playlistId}'
          : 'https://music.youtube.com/playlist?list=${widget.playlistId}',
    );
    final library = KonnektedLibraryIndex.of(
      ref.read(konnektedLibraryProvider).value ?? const <Song>[],
    );
    _cancellation = cancel;
    setState(() {
      _downloading = true;
      _downloadStatus = 'Preparing downloads…';
    });
    var saved = 0;
    var skipped = 0;
    var failed = 0;
    String? lastError;
    final downloaded = <String>{};
    try {
      for (var i = 0; i < widget.tracks.length; i++) {
        if (cancel.isCompleted || !mounted) break;
        final track = widget.tracks[i];
        final key = '${track.key}:${track.videoId ?? ''}:${track.duration?.inMilliseconds ?? 0}';
        final existing = library.match(track);
        final path = existing?.filePath;
        if (downloaded.contains(key) ||
            (existing != null &&
                !existing.isNetworkSource &&
                !existing.isPending &&
                path != null &&
                path.isNotEmpty &&
                await File(path).exists())) {
          skipped++;
          continue;
        }
        if (mounted) {
          setState(() => _downloadStatus =
              'Downloading ${i + 1}/${widget.tracks.length}: ${track.title}');
        }
        try {
          await downloader.download(
            link,
            providerPlaylistDownloadEntry(track, widget.source),
            cancel: cancel.future,
            cancelled: () => cancel.isCompleted,
            onStatus: (message) {
              if (mounted && !cancel.isCompleted) {
                setState(() => _downloadStatus =
                    '${i + 1}/${widget.tracks.length}: $message');
              }
            },
            verifySource: (source) async {
              if (!mounted || cancel.isCompleted || source.verify == null) {
                return false;
              }
              return source.verify!(context);
            },
          );
          downloaded.add(key);
          saved++;
          if (mounted) ref.invalidate(songsProvider);
        } catch (error) {
          if (cancel.isCompleted) break;
          failed++;
          lastError = error.toString();
        }
      }
    } finally {
      if (identical(_cancellation, cancel)) _cancellation = null;
      if (mounted) {
        final cancelled = cancel.isCompleted;
        setState(() {
          _downloading = false;
          _downloadStatus = 'Downloaded $saved · Skipped $skipped'
              ' · Failed $failed${cancelled ? ' · Cancelled' : ''}'
              '${lastError == null ? '' : '\nLast error: $lastError'}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = providerPlaylistMatchingIndices(widget.tracks, _query);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
          child: LokalSearchField(
            controller: _search,
            hint: lokalText('Search songs'),
            onChanged: (query) => setState(() => _query = query),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: LokalPill(
                  icon: Icons.play_arrow_rounded,
                  label: lokalText('Play'),
                  onTap: visible.isEmpty ? null : () => _play(visible),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: LokalPill(
                  icon: Icons.shuffle_rounded,
                  label: lokalText('Shuffle'),
                  onTap: visible.isEmpty
                      ? null
                      : () => _play(visible, shuffle: true),
                ),
              ),
            ],
          ),
        ),
        if (_query.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('${visible.length} of ${widget.tracks.length} songs'),
            ),
          ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    _query.trim().isNotEmpty
                        ? lokalText('No matching songs')
                        : 'No tracks in this playlist.',
                  ),
                )
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, position) {
                    final sourceIndex = visible[position];
                    final track = widget.tracks[sourceIndex];
                    return ProviderPlaylistTrackTile(
                      track: track,
                      leading: widget.artworkBuilder(track),
                      onPlay: () => _play(visible, start: position),
                      onSongActions: () => widget.onSongActions(sourceIndex),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
