import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/konnekted/library/lokal_library_kit.dart';
import 'package:flick/features/spotify/provider_playlist_track_tile.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';

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

/// Shared read-only playlist controls for Spotify and YouTube Music.
/// Playback is delegated to the parent so source resolution, queues, and
/// providers are exactly the same as when a track is tapped.
class ProviderPlaylistTrackBrowser extends StatefulWidget {
  const ProviderPlaylistTrackBrowser({
    super.key,
    required this.tracks,
    required this.artworkBuilder,
    required this.onPlay,
    required this.onSongActions,
  });

  final List<LokalDiscoveryTrack> tracks;
  final Widget Function(LokalDiscoveryTrack track) artworkBuilder;

  /// [orderedIndices] are original playlist indices in playback queue order.
  /// [startIndex] addresses that queue, not the unfiltered source playlist.
  final void Function(List<int> orderedIndices, int startIndex) onPlay;
  final void Function(int sourceIndex) onSongActions;

  @override
  State<ProviderPlaylistTrackBrowser> createState() =>
      _ProviderPlaylistTrackBrowserState();
}

class _ProviderPlaylistTrackBrowserState
    extends State<ProviderPlaylistTrackBrowser> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _play(List<int> visible, {int start = 0, bool shuffle = false}) {
    if (visible.isEmpty) return;
    final queueIndices = List<int>.of(visible);
    if (shuffle) queueIndices.shuffle();
    widget.onPlay(queueIndices, shuffle ? 0 : start);
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
