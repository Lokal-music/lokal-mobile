import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/apple_music_provider.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/apple_music/apple_music_metadata_service.dart';
import 'package:flick/services/online_playlist_reference.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';

/// A catalogue-wide search independent of playback providers. The metadata
/// gets re-resolved through Playback Source Priority, never an iTunes preview.
class GlobalCatalogueSearchSection extends ConsumerStatefulWidget {
  const GlobalCatalogueSearchSection({super.key, required this.query});
  final String query;

  @override
  ConsumerState<GlobalCatalogueSearchSection> createState() =>
      _GlobalCatalogueSearchSectionState();
}

class _GlobalCatalogueSearchSectionState
    extends ConsumerState<GlobalCatalogueSearchSection> {
  late Future<List<AppleMusicSearchSong>> _results;
  bool _expanded = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load({bool refresh = false}) {
    _results = ref.read(appleMusicMetadataServiceProvider).searchSongs(
      widget.query, refresh: refresh, limit: 40,
    );
  }

  @override
  void didUpdateWidget(covariant GlobalCatalogueSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      _expanded = false;
      _load();
    }
  }

  Song _pending(AppleMusicSearchSong match) => stableOnlinePlaylistSong(Song(
    id: 'itunes:' + match.catalogueId,
    title: match.title,
    artist: match.artist,
    album: match.album,
    albumArt: match.artworkUrl,
    duration: match.duration,
    fileType: 'ONLINE',
    sourcePackage: Song.pendingSourcePackage,
  ));

  Future<void> _play(
    AppleMusicSearchSong selected,
    List<AppleMusicSearchSong> matches,
  ) async {
    if (_starting) return;
    setState(() => _starting = true);
    // The metadata IDs belong to Apple; the pending resolver deliberately
    // contains no Apple audio URL and does not bypass configured sources.
    final queue = [for (final match in matches) _pending(match)];
    final selectedId = _pending(selected).id;
    final song = queue.firstWhere((item) => item.id == selectedId);
    try {
      LokalToast.show(
        context, 'Finding ' + selected.title + ' through your playback sources…',
      );
      await ref.read(playerProvider.notifier).play(song, playlist: queue);
    } catch (_) {
      if (mounted) LokalToast.show(context, 'Could not start this song.');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Global', style: TextStyle(
            color: t.text, fontSize: 17, fontWeight: FontWeight.w600,
          )),
          Text(
            lokalText('Apple Music catalogue · plays through your source priority'),
            style: TextStyle(color: t.muted, fontSize: 11),
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<AppleMusicSearchSong>>(
            future: _results,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator(color: t.muted)),
                );
              }
              if (snapshot.hasError) {
                return TextButton.icon(
                  onPressed: () => setState(() => _load(refresh: true)),
                  icon: const Icon(Icons.refresh),
                  label: Text(lokalText('Could not search. Retry')),
                );
              }
              final songs = snapshot.data ?? const <AppleMusicSearchSong>[];
              if (songs.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('No global songs found.', style: TextStyle(color: t.muted)),
                );
              }
              final shown = _expanded ? songs : songs.take(8).toList();
              return Column(
                children: [
                  for (final song in shown)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      enabled: !_starting,
                      leading: SizedBox.square(
                        dimension: 48,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CachedImageWidget(imagePath: song.artworkUrl),
                        ),
                      ),
                      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        song.artist + (song.album.isEmpty ? '' : ' · ' + song.album),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.play_arrow_rounded),
                      onTap: () => unawaited(_play(song, songs)),
                    ),
                  if (songs.length > 8)
                    TextButton(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      child: Text(_expanded ? 'Show fewer' : 'Show all ' + songs.length.toString() + ' global songs'),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
