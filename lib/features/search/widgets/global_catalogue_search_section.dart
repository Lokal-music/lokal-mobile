import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/global_catalogue_source.dart';
import 'package:flick/services/global_catalogue_search.dart';
import 'package:flick/services/online_playlist_reference.dart';
import 'package:flick/features/konnekted/library/lokal_music_detail_page.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/features/discovery/discovery_artwork.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/search/widgets/online_result_actions.dart';
import 'package:flick/features/search/online_song_save.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/widgets/lokal/lokal_swipe_to_queue.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';

import 'artist_search_portrait.dart';

final globalCatalogueSearchServiceProvider =
    Provider<GlobalCatalogueSearchService>(
      (ref) => const GlobalCatalogueSearchService(),
    );

/// An online catalogue supplies only metadata. The pending recorder resolves
/// audio later using the user's unchanged Playback Source Priority settings.
class GlobalCatalogueSearchSection extends ConsumerStatefulWidget {
  const GlobalCatalogueSearchSection({
    super.key,
    required this.query,
    this.songsOnly = false,
  });
  final String query;
  final bool songsOnly;

  @override
  ConsumerState<GlobalCatalogueSearchSection> createState() =>
      _GlobalCatalogueSearchSectionState();
}

class _GlobalCatalogueSearchSectionState
    extends ConsumerState<GlobalCatalogueSearchSection> {
  late Future<GlobalCatalogueMatches> _results;
  bool _expanded = false;
  bool _starting = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    GlobalCatalogueSource.selected.addListener(_changedSource);
    _load();
  }

  void _changedSource() {
    if (mounted)
      setState(() {
        _expanded = false;
        _load();
      });
  }

  void _load({bool refresh = false}) {
    _results = ref
        .read(globalCatalogueSearchServiceProvider)
        .search(widget.query, refresh: refresh, songsOnly: widget.songsOnly);
  }

  @override
  void didUpdateWidget(covariant GlobalCatalogueSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.songsOnly != widget.songsOnly) {
      _expanded = false;
      _load();
    }
  }

  @override
  void dispose() {
    GlobalCatalogueSource.selected.removeListener(_changedSource);
    super.dispose();
  }

  Song _pending(GlobalCatalogueSong match) => stableOnlinePlaylistSong(
    Song(
      id: 'catalogue:' + match.catalogueId,
      title: match.title,
      artist: match.artist,
      album: match.album,
      albumArt: match.artworkUrl,
      duration: match.duration,
      fileType: 'ONLINE',
      sourcePackage: Song.pendingSourcePackage,
    ),
  );

  Future<void> _play(
    GlobalCatalogueSong selected,
    List<GlobalCatalogueSong> matches,
  ) async {
    if (_starting) return;
    setState(() => _starting = true);
    final seen = <String>{};
    final queue = [
      for (final match in matches)
        if (seen.add(_pending(match).id)) _pending(match),
    ];
    final selectedId = _pending(selected).id;
    final song = queue.where((item) => item.id == selectedId).firstOrNull;
    if (song == null) {
      if (mounted) setState(() => _starting = false);
      return;
    }
    try {
      LokalToast.show(
        context,
        'Finding ' + selected.title + ' through your playback sources…',
      );
      await ref.read(playerProvider.notifier).play(song, playlist: queue);
    } catch (_) {
      if (mounted) LokalToast.show(context, 'Could not start this song.');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Global catalogue entries carry metadata only. Enqueue the same pending
  /// song used for direct playback; source priority resolves it when needed.
  Future<void> _enqueue(GlobalCatalogueSong match, {required bool next}) async {
    if (ref.read(playerProvider).currentSong == null) {
      await _play(match, [match]);
      return;
    }
    try {
      final player = ref.read(playerProvider.notifier);
      final index = await player.addToQueue(_pending(match));
      if (next && index > 0) await player.moveQueueItemToNext(index);
      if (mounted) {
        LokalToast.show(
          context,
          next
              ? '${match.title} plays next'
              : 'Added ${match.title} to the queue',
        );
      }
    } catch (_) {
      if (mounted) LokalToast.show(context, 'Could not queue ${match.title}.');
    }
  }

  /// Download metadata-only global results through the configured playable
  /// sources, never by treating an Apple/Spotify catalogue URL as audio.
  Future<void> _download(GlobalCatalogueSong match) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final info = LokalDiscoveryTrack(
        title: match.title,
        artist: match.artist,
        album: match.album,
        artworkUrl: match.artworkUrl,
        duration: match.duration,
      );
      final found = await findDiscoverySong(info);
      if (found == null) throw StateError('No playable source');
      if (OnlineSongSaveRegistry.instance.canSave(found)) {
        await OnlineSongSaveRegistry.instance.save(found);
      } else {
        await LibraryDownloader().save(found, artwork: match.artworkUrl);
      }
      if (mounted)
        LokalToast.show(context, 'Saved ${match.title} to your library.');
    } catch (_) {
      if (mounted) {
        LokalToast.show(
          context,
          'Could not download ${match.title} from the configured sources.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _actions(
    GlobalCatalogueSong match,
    List<GlobalCatalogueSong> songs,
    String catalogue,
  ) async {
    HapticFeedback.mediumImpact();
    // The shared sheet only uses this model for artwork/text and actions.
    // Playback always uses _pending() and the global source-priority resolver.
    final display = OnlineResult(
      DiscoveryTrack(
        id: match.catalogueId,
        title: match.title,
        artist: match.artist,
        album: match.album,
        duration: match.duration,
        artwork: match.artworkUrl,
        source: DiscoverySource.youtubeMusic,
      ),
    );
    final action = await showOnlineResultActions(
      context,
      result: display,
      sourceName: catalogue == 'spotify' ? 'Spotify' : 'Apple Music',
      saving: _saving,
    );
    if (!mounted || action == null) return;
    switch (action) {
      case OnlineResultAction.play:
        await _play(match, songs);
      case OnlineResultAction.playNext:
        await _enqueue(match, next: true);
      case OnlineResultAction.addToQueue:
        await _enqueue(match, next: false);
      case OnlineResultAction.download:
        await _download(match);
      case OnlineResultAction.playAtmos:
      case OnlineResultAction.downloadAtmos:
        break; // A global catalogue match has no verified Atmos source.
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FutureBuilder<GlobalCatalogueMatches>(
            future: _results,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: CircularProgressIndicator(color: t.muted),
                  ),
                );
              }
              if (snapshot.hasError) {
                return TextButton.icon(
                  onPressed: () => setState(() => _load(refresh: true)),
                  icon: const Icon(Icons.refresh),
                  label: Text(lokalText('Could not search. Retry')),
                );
              }
              final data =
                  snapshot.data ??
                  const GlobalCatalogueMatches(catalogue: 'apple');
              final songs = data.songs;
              final albums = widget.songsOnly
                  ? const <GlobalCatalogueAlbum>[]
                  : data.albums;
              final artists = widget.songsOnly
                  ? const <GlobalCatalogueArtist>[]
                  : data.artists;
              final shown = _expanded ? songs : songs.take(8).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (data.notice != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      data.notice!,
                      style: TextStyle(color: t.muted, fontSize: 11),
                    ),
                  ],
                  if (songs.isEmpty && albums.isEmpty && artists.isEmpty)
                    Text(
                      'No global results found.',
                      style: TextStyle(color: t.muted),
                    ),
                  if (songs.isNotEmpty) ...[
                    for (final song in shown)
                      LokalSwipeToQueue(
                        onQueue: () => _enqueue(song, next: false),
                        onNext: () => _enqueue(song, next: true),
                        enabled: !_starting,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          enabled: !_starting,
                          leading: SizedBox.square(
                            dimension: 48,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: DiscoveryArtwork(
                                kind: DiscoveryArtworkKind.track,
                                title: song.title,
                                artist: song.artist,
                                url: song.artworkUrl,
                                width: 48,
                                height: 48,
                                placeholder:
                                    CachedImageWidget.defaultPlaceholder(),
                              ),
                            ),
                          ),
                          title: Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            song.artist +
                                (song.album.isEmpty ? '' : ' · ' + song.album),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.play_arrow_rounded),
                          onTap: () => unawaited(_play(song, songs)),
                          onLongPress: () =>
                              unawaited(_actions(song, songs, data.catalogue)),
                        ),
                      ),
                    if (songs.length > 8)
                      TextButton(
                        onPressed: () => setState(() => _expanded = !_expanded),
                        child: Text(
                          _expanded
                              ? 'Show fewer'
                              : 'Show all ' +
                                    songs.length.toString() +
                                    ' songs',
                        ),
                      ),
                  ],
                  if (albums.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Albums',
                      style: TextStyle(color: t.muted, fontSize: 12),
                    ),
                    for (final album in albums.take(_expanded ? 12 : 4))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: SizedBox.square(
                          dimension: 48,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: DiscoveryArtwork(
                              kind: DiscoveryArtworkKind.album,
                              title: album.name,
                              artist: album.artist,
                              url: album.artworkUrl,
                              width: 48,
                              height: 48,
                              placeholder:
                                  CachedImageWidget.defaultPlaceholder(),
                            ),
                          ),
                        ),
                        title: Text(
                          album.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          album.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _open(
                          LokalMusicDetailPage.album(
                            title: album.name,
                            artist: album.artist,
                            localSongs: const [],
                            initialOnline: true,
                          ),
                        ),
                      ),
                  ],
                  if (artists.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Artists',
                      style: TextStyle(color: t.muted, fontSize: 12),
                    ),
                    for (final artist in artists.take(_expanded ? 12 : 4))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: ArtistSearchPortrait(
                          name: artist.name,
                          artworkUrl: artist.artworkUrl,
                        ),
                        title: Text(artist.name),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(
                          LokalMusicDetailPage.artist(
                            name: artist.name,
                            localSongs: const [],
                            initialOnline: true,
                          ),
                        ),
                      ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
