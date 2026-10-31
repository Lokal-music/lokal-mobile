import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flutter/material.dart';

/// Common track row for account playlists (Spotify and YouTube Music).
/// The supplied callbacks resolve and act on Lokal's Song rather than the
/// source's metadata, so remote tracks get the same menu as other lists.
class ProviderPlaylistTrackTile extends StatelessWidget {
  const ProviderPlaylistTrackTile({
    super.key,
    required this.track,
    required this.leading,
    required this.onPlay,
    required this.onSongActions,
  });

  final LokalDiscoveryTrack track;
  final Widget leading;
  final VoidCallback onPlay;
  final VoidCallback onSongActions;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: leading,
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          track.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: onPlay,
        onLongPress: onSongActions,
      );
}
