import 'package:flick/l10n/l10n.dart';

import 'dart:async';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/discovery/discovery_artwork.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/spotify_discovery.dart';
import 'package:flick/features/spotify/spotify_oauth.dart';
import 'package:flick/features/spotify/spotify_storage.dart';
import 'package:flick/features/discovery/youtube_music_account.dart';
import 'package:flick/features/discovery/youtube_music_sign_in.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/search/widgets/online_result_actions.dart';
import 'package:flick/features/search/online_song_save.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/widgets/lokal/lokal_swipe_to_queue.dart';
import 'package:flick/widgets/lokal/lokal_glass.dart';
import 'package:flick/widgets/lokal/lokal_status_snack.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'discovery_shelf_layout.dart';
import 'konnekted_data.dart';
import 'konnekted_destination.dart';
import 'konnekted_discovery.dart';
import 'konnekted_style.dart';
import 'library/lokal_music_detail_page.dart';
import 'library/lokal_library_kit.dart' show pushLokal;
import 'library/lokal_online_catalogue.dart';

/// Home's Discovery tab: personalized recommendations from Last.fm,
/// YouTube Music and Spotify, with source-specific shelves.
class KonnektedDiscoveryView extends ConsumerStatefulWidget {
  const KonnektedDiscoveryView({
    super.key,
    required this.onNavigate,
    required this.onPlay,
    this.findSong = findDiscoverySong,
    this.pendingSong = discoveryPendingSong,
  });

  final ValueChanged<KonnektedDestination> onNavigate;
  final void Function(Song song, List<Song> shelf) onPlay;

  /// Looks for a song you don't have on YouTube Music and your add-ons;
  /// replaced in tests.
  final Future<Song?> Function(
    LokalDiscoveryTrack track, {
    void Function(String status)? onStatus,
    Set<String> Function()? additionalProtectedPaths,
  })
  findSong;

  /// A queue placeholder for a song you don't have, looked up once it's
  /// coming up; replaced in tests.
  final Song Function(LokalDiscoveryTrack track) pendingSong;

  @override
  ConsumerState<KonnektedDiscoveryView> createState() =>
      _KonnektedDiscoveryViewState();
}

enum _Shelf { fresh, quick, history }

class _KonnektedDiscoveryViewState
    extends ConsumerState<KonnektedDiscoveryView> {
  _Shelf? _open;
  String? _busy;
  String? _expandedCategory;
  final _shelfStore = const DiscoveryShelfLayoutStore();
  final _shelfLayouts = <String, DiscoveryShelfLayout>{};

  @override
  void initState() {
    super.initState();
    unawaited(_restoreShelfLayouts());
    Future.microtask(() {
      if (mounted) ref.read(konnektedDiscoveryProvider.notifier).load();
    });
  }

  Future<void> _restoreShelfLayouts() async {
    for (final provider in discoveryShelfDefaults.keys) {
      final layout = await _shelfStore.read(provider);
      if (!mounted) return;
      setState(() => _shelfLayouts.putIfAbsent(provider, () => layout));
    }
  }

  DiscoveryShelfLayout _layout(KonnektedDiscoverySource source) =>
      _shelfLayouts[source.name] ?? DiscoveryShelfLayout.defaults(source.name);

  List<Widget> _arranged(
    KonnektedDiscoverySource source,
    Map<String, List<Widget>> shelves,
  ) => [for (final id in _layout(source).visible) ...?shelves[id]];

  Future<void> _customize(KonnektedDiscoverySource source) async {
    final provider = source.name;
    var layout = _layout(source);
    var saving = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, update) => SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * .85,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    lokalText(
                      'Customize {arg0}',
                      args: {
                        'arg0': switch (source) {
                          KonnektedDiscoverySource.youtube => 'YouTube',
                          KonnektedDiscoverySource.lastfm => 'Last.fm',
                          KonnektedDiscoverySource.spotify => 'Spotify',
                        },
                      },
                    ),
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    lokalText('Choose sections to show and drag to reorder.'),
                    style: TextStyle(color: sheetContext.lokal.muted),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ReorderableListView(
                      shrinkWrap: true,
                      buildDefaultDragHandles: true,
                      onReorderItem: (from, to) => update(() {
                        if (!saving) layout = layout.moved(from, to);
                      }),
                      children: [
                        for (final id in layout.order)
                          SwitchListTile(
                            key: ValueKey(id),
                            title: Text(
                              lokalText(discoveryShelfTitles[id] ?? id),
                            ),
                            secondary: const Icon(Icons.drag_handle_rounded),
                            value: !layout.hidden.contains(id),
                            onChanged: saving
                                ? null
                                : (show) => update(
                                    () => layout = layout.showing(id, show),
                                  ),
                          ),
                      ],
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: saving
                          ? null
                          : () async {
                              update(() => saving = true);
                              try {
                                await _shelfStore.write(provider, layout);
                                if (mounted) {
                                  setState(
                                    () => _shelfLayouts[provider] = layout,
                                  );
                                }
                                if (sheetContext.mounted) {
                                  Navigator.of(sheetContext).pop();
                                }
                              } catch (_) {
                                if (sheetContext.mounted) {
                                  update(() => saving = false);
                                }
                                if (mounted) {
                                  _say(
                                    lokalText(
                                      'Could not save Discovery layout. Try again.',
                                    ),
                                  );
                                }
                              }
                            },
                      child: Text(lokalText('Done')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _youtubeCategory(
    LokalDiscoveryCategory category,
    KonnektedLibraryIndex library,
  ) {
    final entries = category.tracks;
    final expanded = _expandedCategory == category.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KonnektedSectionHeading(
          title: lokalText(discoveryShelfTitles[category.id] ?? category.id),
          onSeeAll: entries.length > 6
              ? () => setState(
                  () => _expandedCategory = expanded ? null : category.id,
                )
              : null,
          seeAllLabel: expanded ? 'Show less' : 'See all',
        ),
        for (final track in expanded ? entries : entries.take(6))
          KonnektedDiscoveryRow(
            track: track,
            inLibrary: library.match(track) != null,
            busy: _busy == track.key,
            onTap: () => _play(track, entries),
            onMore: () => unawaited(_actions(track, entries)),
            onQueue: () => _enqueue(track),
          ),
        if (category.mixes.isNotEmpty)
          _MixShelf(
            storageKey: 'youtube-${category.id}',
            mixes: category.mixes,
            busyId: _busy?.startsWith('mix:') == true
                ? _busy!.substring(4)
                : null,
            onTap: _playMix,
          ),
        if (category.albums.isNotEmpty)
          _AlbumShelf(
            albums: category.albums,
            onTap: (album) => pushLokal(
              context,
              LokalMusicDetailPage.album(
                title: album.title,
                artist: album.artist,
                localSongs: _library().album(album.title, album.artist),
                initialOnline: true,
                release: LokalCatalogueAlbum(
                  title: album.title,
                  artist: album.artist,
                  artwork: album.artworkUrl,
                  url: album.url,
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _toggle(_Shelf shelf) =>
      setState(() => _open = _open == shelf ? null : shelf);

  /// What's being got ready, on one line updated in place.
  late final _progress = LokalStatusSnack(() => mounted ? context : null);

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  /// A message that replaces the progress line and goes after a while.
  void _say(String message) => _progress.fail(message);

  Future<void> _selectDiscoverySource(KonnektedDiscoverySource source) async {
    if (ref.read(konnektedDiscoveryProvider).source == source) return;
    if (source == KonnektedDiscoverySource.spotify) {
      final settings = SpotifySettingsStore();
      final oauth = SpotifyOAuthService(tokenStore: settings.tokenStore);
      var connected = false;
      try {
        connected = await oauth.isConnected;
      } catch (_) {
        connected = false;
      }

      if (!mounted) return;
      if (!connected) {
        widget.onNavigate(
          const KonnektedDestination.settingsAt(
            LokalSettingsGroup.data,
            section: LokalDataSections.accounts,
          ),
        );
        return;
      }

      try {
        await settings.saveDiscoveryEnabled(true);
      } catch (_) {
        if (mounted)
          _say(
            lokalText(
              'Spotify connected, but Discovery settings could not be saved.',
            ),
          );
      }
    }

    if (!mounted) return;
    HapticFeedback.selectionClick();
    await ref.read(konnektedDiscoveryProvider.notifier).setSource(source);
  }

  Future<void> _connectYoutubeMusic() async {
    try {
      final session = await YoutubeMusicSignInSheet.show(context);
      if (!mounted || session == null) return;
      await ref
          .read(konnektedYoutubeMusicSessionProvider.notifier)
          .save(session);
      final discovery = ref.read(konnektedDiscoveryProvider.notifier);
      if (ref.read(konnektedDiscoveryProvider).source ==
          KonnektedDiscoverySource.youtube) {
        await discovery.load(refresh: true);
      } else {
        await discovery.setSource(KonnektedDiscoverySource.youtube);
      }
    } catch (_) {
      if (mounted)
        _say(lokalText('Could not sign in to YouTube Music. Try again.'));
    }
  }

  Future<void> _playMix(LokalDiscoveryMix mix, {bool spotify = false}) async {
    final account = spotify
        ? null
        : ref.read(konnektedYoutubeMusicAccountProvider);
    if (!spotify && account == null) {
      await _connectYoutubeMusic();
      return;
    }
    if (_busy != null) return;
    setState(() => _busy = 'mix:' + mix.id);
    _progress.update('Loading ' + mix.title + '…');
    try {
      final tracks = spotify
          ? await ref.read(konnektedSpotifyMixLoaderProvider)(mix.id)
          : await youtubeMusicMix(account!, mix.id);
      if (!mounted) return;
      if (tracks.isEmpty) {
        _say(lokalText('This mix did not return any playable tracks.'));
        return;
      }
      final library = _library();
      final songs = <Song>[];
      final seen = <String>{};
      for (final track in tracks) {
        final song = library.match(track) ?? widget.pendingSong(track);
        if (seen.add(song.id)) songs.add(song);
      }
      if (songs.isEmpty) {
        _say(lokalText('No tracks from this mix could be prepared.'));
      } else {
        _progress.clear();
        widget.onPlay(songs.first, songs);
      }
    } on YoutubeMusicSignedOut catch (error) {
      await ref.read(konnektedYoutubeMusicSessionProvider.notifier).signOut();
      if (mounted) _say(error.message);
    } catch (error) {
      if (mounted) {
        _say(
          spotify
              ? spotifyDiscoveryError(error)
              : lokalText(
                  'Could not load this YouTube Music mix. Refresh and try again.',
                ),
        );
      }
    } finally {
      _progress.clear();
      if (mounted) setState(() => _busy = null);
    }
  }

  KonnektedLibraryIndex _library() => KonnektedLibraryIndex.of(
    ref.read(konnektedLibraryProvider).value ?? const [],
  );

  /// Plays your copy when you have it, with the shelf's other songs you
  /// have after it; otherwise finds it on YouTube Music or your add-ons.
  Future<void> _play(
    LokalDiscoveryTrack track,
    List<LokalDiscoveryTrack> shelf,
  ) async {
    final library = _library();
    final own = library.match(track);
    if (own != null) {
      final queue = library.matchAll(shelf);
      widget.onPlay(own, queue.contains(own) ? queue : [own, ...queue]);
      return;
    }
    final pending = widget.pendingSong(track);
    widget.onPlay(pending, _shelfQueue(track, pending, shelf, library));
  }

  /// Online Search and Discovery use exactly the same menu/sheet actions.
  /// Discovery placeholders preserve the original recommendation so queue
  /// pre-resolution can verify and download the chosen recording later.
  Future<void> _enqueue(LokalDiscoveryTrack track, {bool next = false}) async {
    final song = _library().match(track) ?? widget.pendingSong(track);
    final player = ref.read(playerProvider.notifier);
    try {
      if (ref.read(playerProvider).currentSong == null) {
        widget.onPlay(song, [song]);
        return;
      }
      final index = await player.addToQueue(song);
      if (next && index > 0) await player.moveQueueItemToNext(index);
      _say(
        next
            ? '${track.title} plays next'
            : 'Added ${track.title} to the queue',
      );
    } catch (_) {
      if (mounted) _say('Could not add ${track.title} to the queue.');
    }
  }

  Future<void> _downloadDiscovery(LokalDiscoveryTrack track) async {
    final key = 'save:${track.key}';
    if (_busy != null) return;
    setState(() => _busy = key);
    _progress.update('Downloading ${track.title} to library…');
    try {
      final found = await widget.findSong(
        track,
        onStatus: (text) {
          if (mounted) _progress.update(text);
        },
      );
      if (found == null)
        throw const DiscoveryException(
          'No playable source was found for this track.',
        );
      if (OnlineSongSaveRegistry.instance.canSave(found)) {
        await OnlineSongSaveRegistry.instance.save(found);
      } else {
        await LibraryDownloader().save(found, artwork: track.artworkUrl);
      }
      if (mounted) _say('Saved ${track.title} to your library');
    } catch (error) {
      if (mounted)
        _say(
          'Could not save ${track.title}. Check your connection or source and retry.',
        );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _actions(
    LokalDiscoveryTrack track,
    List<LokalDiscoveryTrack> shelf,
  ) async {
    HapticFeedback.mediumImpact();
    final result = OnlineResult(
      DiscoveryTrack(
        id: track.videoId ?? track.key,
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        artwork: track.artworkUrl,
        source: DiscoverySource.youtubeMusic,
      ),
    );
    final action = await showOnlineResultActions(
      context,
      result: result,
      sourceName: 'Discovery',
      saving: _busy == 'save:${track.key}',
    );
    if (!mounted || action == null) return;
    switch (action) {
      case OnlineResultAction.play:
        await _play(track, shelf);
      case OnlineResultAction.playNext:
        await _enqueue(track, next: true);
      case OnlineResultAction.addToQueue:
        await _enqueue(track);
      case OnlineResultAction.download:
        await _downloadDiscovery(track);
      case OnlineResultAction.playAtmos:
      case OnlineResultAction.downloadAtmos:
        break; // Discovery has not verified an Atmos edition for this pick.
    }
  }

  /// The shelf in order with [found] in [track]'s place: your copies of the
  /// others, else placeholders looked up once they're coming up.
  List<Song> _shelfQueue(
    LokalDiscoveryTrack track,
    Song found,
    List<LokalDiscoveryTrack> shelf,
    KonnektedLibraryIndex library,
  ) {
    final seen = <String>{found.id};
    final queue = <Song>[];
    var placed = false;
    for (final other in shelf) {
      if (!placed && other.key == track.key) {
        queue.add(found);
        placed = true;
        continue;
      }
      final song = library.match(other) ?? widget.pendingSong(other);
      if (seen.add(song.id)) queue.add(song);
    }
    if (!placed) queue.insert(0, found);
    return queue;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final discovery = ref.watch(konnektedDiscoveryProvider);
    final data = discovery.data;
    final source = discovery.source;
    // Rebuild when the library changes, so "in your library" stays right.
    final library = KonnektedLibraryIndex.of(
      ref.watch(konnektedLibraryProvider).value ?? const [],
    );
    if (source == KonnektedDiscoverySource.spotify) {
      return _buildSpotify(
        context,
        ref.watch(konnektedSpotifyDiscoveryProvider),
        library,
      );
    }
    final fresh = data?.freshFinds ?? const <LokalDiscoveryTrack>[];
    final quick = data?.quickPicks ?? const <LokalDiscoveryTrack>[];
    final mixes = data?.mixes ?? const <LokalDiscoveryMix>[];
    final albums = data?.albums ?? const <LokalDiscoveryAlbum>[];
    final artists = data?.artists ?? const <LokalDiscoveryArtist>[];
    // Hidden account/history shelves must not count as visible recommendations.
    final hasRecommendations = source == KonnektedDiscoverySource.lastfm
        ? albums.isNotEmpty || artists.isNotEmpty || fresh.isNotEmpty
        : mixes.isNotEmpty ||
              artists.isNotEmpty ||
              fresh.isNotEmpty ||
              quick.isNotEmpty ||
              (data?.categories ?? const <LokalDiscoveryCategory>[]).any(
                (category) => !category.isEmpty,
              );

    Widget tracks(_Shelf shelf, List<LokalDiscoveryTrack> items) => Column(
      children: [
        for (final track in _open == shelf ? items : items.take(6))
          KonnektedDiscoveryRow(
            track: track,
            inLibrary: library.match(track) != null,
            busy: _busy == track.key,
            trailing: shelf == _Shelf.quick && (track.scrobbleCount ?? 0) > 1
                ? '×${track.scrobbleCount}'
                : null,
            onTap: () => _play(track, items),
            onMore: () => unawaited(_actions(track, items)),
            onQueue: () => _enqueue(track),
          ),
      ],
    );

    KonnektedSectionHeading heading(
      _Shelf shelf,
      String title,
      IconData icon,
      int count, {
      String? subtitle,
      int shown = 6,
    }) => KonnektedSectionHeading(
      title: title,
      icon: icon,
      subtitle: subtitle,
      onSeeAll: count > shown ? () => _toggle(shelf) : null,
      seeAllLabel: _open == shelf ? 'Show less' : 'See all',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          loading: discovery.loading,
          source: source,
          onSourceChanged: (next) {
            unawaited(_selectDiscoverySource(next));
          },
          onCustomize: (provider) => unawaited(_customize(provider)),
          onRefresh: () {
            HapticFeedback.selectionClick();
            ref.read(konnektedDiscoveryProvider.notifier).load(refresh: true);
          },
        ),
        if (discovery.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF87171).withValues(alpha: .1),
                  border: Border.all(
                    color: const Color(0xFFF87171).withValues(alpha: .25),
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  discovery.error!,
                  style: TextStyle(
                    fontSize: 13,
                    color: t.isLight
                        ? const Color(0xFFB91C1C)
                        : const Color(0xFFFECACA),
                  ),
                ),
              ),
            ),
          ),
        if (!discovery.connected && source == KonnektedDiscoverySource.youtube)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: KonnektedMessage(
              title: lokalText('Sign in to YouTube Music'),
              message: lokalText(
                'Connect your account to see your mixes and personalized picks.',
              ),
              icon: Icons.music_note_rounded,
              actionLabel: 'Sign in',
              onAction: _connectYoutubeMusic,
            ),
          )
        else if (!discovery.connected &&
            source == KonnektedDiscoverySource.lastfm)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: KonnektedMessage(
              title: lokalText('Connect Last.fm for Discovery'),
              message: lokalText(
                'Discovery recommends music from your Last.fm scrobbles. Sign in to Last.fm in Data → Accounts to see your shelves.',
              ),
              icon: Icons.auto_awesome_rounded,
              actionLabel: 'Open Accounts',
              onAction: () => widget.onNavigate(
                const KonnektedDestination.settingsAt(
                  LokalSettingsGroup.data,
                  section: LokalDataSections.accounts,
                ),
              ),
            ),
          )
        else if (data == null && discovery.loading)
          KonnektedLoading(
            label: source == KonnektedDiscoverySource.youtube
                ? lokalText('Loading your YouTube Music shelves…')
                : lokalText('Building your Last.fm recommendations…'),
          )
        else if (data != null && !hasRecommendations)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: KonnektedMessage(
              title: lokalText('Nothing to recommend yet'),
              message: source == KonnektedDiscoverySource.youtube
                  ? lokalText(
                      'No YouTube Music recommendations were returned. Refresh to retry.',
                    )
                  : lokalText(
                      'No Last.fm recommendations are available yet. Scrobble a few songs, then refresh.',
                    ),
              icon: Icons.auto_awesome_rounded,
            ),
          ),
        ..._arranged(source, <String, List<Widget>>{
          if (source == KonnektedDiscoverySource.lastfm && albums.isNotEmpty)
            'albums': [
              KonnektedSectionHeading(
                title: lokalText('Albums For You'),
                icon: Icons.album_rounded,
              ),
              _AlbumShelf(
                albums: albums,
                onTap: (album) => pushLokal(
                  context,
                  LokalMusicDetailPage.album(
                    title: album.title,
                    artist: album.artist,
                    localSongs: _library().album(album.title, album.artist),
                    initialOnline: true,
                    release: LokalCatalogueAlbum(
                      title: album.title,
                      artist: album.artist,
                      artwork: album.artworkUrl,
                      url: album.url,
                    ),
                  ),
                ),
              ),
            ],
          if (source == KonnektedDiscoverySource.youtube && mixes.isNotEmpty)
            'mixes': [
              KonnektedSectionHeading(
                title: lokalText('Mixed for you'),
                icon: Icons.queue_music_rounded,
              ),
              _MixShelf(
                mixes: mixes,
                busyId: _busy?.startsWith('mix:') == true
                    ? _busy!.substring(4)
                    : null,
                onTap: _playMix,
              ),
            ],
          if (fresh.isNotEmpty &&
              (source != KonnektedDiscoverySource.youtube ||
                  (data?.categories ?? const <LokalDiscoveryCategory>[])
                      .isEmpty))
            'fresh': [
              heading(
                _Shelf.fresh,
                'Fresh Finds',
                Icons.music_note_rounded,
                fresh.length,
              ),
              tracks(_Shelf.fresh, fresh),
            ],
          if (source == KonnektedDiscoverySource.youtube && quick.isNotEmpty)
            'quick': [
              heading(
                _Shelf.quick,
                'Quick Picks',
                Icons.auto_awesome_rounded,
                quick.length,
              ),
              tracks(_Shelf.quick, quick),
            ],
          if (artists.isNotEmpty)
            'artists': [
              KonnektedSectionHeading(
                title: lokalText('Artists For You'),
                icon: Icons.person_rounded,
              ),
              _ArtistShelf(
                artists: artists,
                onTap: (artist) => pushLokal(
                  context,
                  LokalMusicDetailPage.artist(
                    name: artist.name,
                    localSongs: _library().artist(artist.name),
                    initialOnline: true,
                  ),
                ),
              ),
            ],
          if (source == KonnektedDiscoverySource.youtube)
            for (final category
                in data?.categories ?? const <LokalDiscoveryCategory>[])
              if (!category.isEmpty)
                category.id: [_youtubeCategory(category, library)],
        }),
        if (source == KonnektedDiscoverySource.youtube &&
            data?.mixError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              data!.mixError!,
              style: TextStyle(fontSize: 12, color: t.muted),
            ),
          ),
      ],
    );
  }

  Widget _buildSpotify(
    BuildContext context,
    AsyncValue<SpotifyDiscoverySnapshot> snapshot,
    KonnektedLibraryIndex library,
  ) {
    final t = context.lokal;
    final value = snapshot.value;
    final data = value?.data;
    final fresh = data?.freshFinds ?? const <LokalDiscoveryTrack>[];
    final quick = data?.quickPicks ?? const <LokalDiscoveryTrack>[];
    final history = data?.recentlyPlayed ?? const <LokalDiscoveryTrack>[];
    final hasRecommendations =
        data != null &&
        (data.mixes.isNotEmpty ||
            data.freshFinds.isNotEmpty ||
            data.quickPicks.isNotEmpty ||
            data.recentlyPlayed.isNotEmpty ||
            data.albums.isNotEmpty ||
            data.artists.isNotEmpty);

    Widget tracks(_Shelf shelf, List<LokalDiscoveryTrack> items) => Column(
      children: [
        for (final track in _open == shelf ? items : items.take(6))
          KonnektedDiscoveryRow(
            track: track,
            inLibrary: library.match(track) != null,
            busy: _busy == track.key,
            onTap: () => _play(track, items),
            onMore: () => unawaited(_actions(track, items)),
            onQueue: () => _enqueue(track),
          ),
      ],
    );

    KonnektedSectionHeading heading(
      _Shelf shelf,
      String title,
      IconData icon,
      int count, {
      String? subtitle,
    }) => KonnektedSectionHeading(
      title: title,
      icon: icon,
      subtitle: subtitle,
      onSeeAll: count > 6 ? () => _toggle(shelf) : null,
      seeAllLabel: _open == shelf ? 'Show less' : 'See all',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          loading: snapshot.isLoading,
          source: KonnektedDiscoverySource.spotify,
          onSourceChanged: (next) {
            unawaited(_selectDiscoverySource(next));
          },
          onCustomize: (provider) => unawaited(_customize(provider)),
          onRefresh: () {
            HapticFeedback.selectionClick();
            unawaited(ref.read(konnektedSpotifyDiscoveryProvider.notifier).refresh());
          },
        ),
        if (snapshot.hasError)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              spotifyDiscoveryError(snapshot.error!),
              style: TextStyle(
                color: t.isLight
                    ? const Color(0xFFB91C1C)
                    : const Color(0xFFFECACA),
              ),
            ),
          )
        else if (snapshot.isLoading && value == null)
          KonnektedLoading(label: lokalText('Building your Spotify shelves…'))
        else if (value?.error case final error? when data == null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              error,
              style: TextStyle(
                color: t.isLight
                    ? const Color(0xFFB91C1C)
                    : const Color(0xFFFECACA),
              ),
            ),
          )
        else if (value == null || !value.enabled)
          KonnektedMessage(
            title: lokalText('Spotify Discovery is off'),
            message: lokalText(
              'Connect your Spotify session to enable personal shelves.',
            ),
            icon: Icons.auto_awesome_rounded,
            actionLabel: 'Connect Spotify',
            onAction: () => unawaited(
              _selectDiscoverySource(KonnektedDiscoverySource.spotify),
            ),
          )
        else if (!value.connected)
          KonnektedMessage(
            title: lokalText('Connect Spotify for Discovery'),
            message: lokalText(
              'Paste your Spotify session cookie to load your personal shelves.',
            ),
            icon: Icons.auto_awesome_rounded,
            actionLabel: 'Enter cookie',
            onAction: () => unawaited(
              _selectDiscoverySource(KonnektedDiscoverySource.spotify),
            ),
          )
        else if (!hasRecommendations)
          KonnektedMessage(
            title: lokalText('Nothing to recommend yet'),
            message: lokalText(
              'Spotify did not return any personal shelves yet. Refresh and try again.',
            ),
            icon: Icons.auto_awesome_rounded,
          ),
        ..._arranged(KonnektedDiscoverySource.spotify, <String, List<Widget>>{
          if (data != null && data.mixes.isNotEmpty)
            'mixes': [
              KonnektedSectionHeading(
                title: lokalText('Mixed for you'),
                icon: Icons.queue_music_rounded,
              ),
              _MixShelf(
                storageKey: 'spotify-mixes',
                mixes: data.mixes,
                busyId: _busy?.startsWith('mix:') == true
                    ? _busy!.substring(4)
                    : null,
                onTap: (mix) => unawaited(_playMix(mix, spotify: true)),
              ),
            ],
          if (fresh.isNotEmpty)
            'fresh': [
              heading(
                _Shelf.fresh,
                'Fresh Finds',
                Icons.music_note_rounded,
                fresh.length,
              ),
              tracks(_Shelf.fresh, fresh),
            ],
          if (quick.isNotEmpty)
            'quick': [
              heading(
                _Shelf.quick,
                'Quick Picks',
                Icons.auto_awesome_rounded,
                quick.length,
              ),
              tracks(_Shelf.quick, quick),
            ],
          if (history.isNotEmpty)
            'history': [
              heading(
                _Shelf.history,
                'Recently Played',
                Icons.history_rounded,
                history.length,
              ),
              _History(
                entries: _open == _Shelf.history
                    ? history
                    : history.take(6).toList(),
                row: (track) => KonnektedDiscoveryRow(
                  track: track,
                  inLibrary: library.match(track) != null,
                  busy: _busy == track.key,
                  trailing: track.scrobbledAt == null
                      ? null
                      : DateFormat.Hm().format(
                          DateTime.fromMillisecondsSinceEpoch(
                            track.scrobbledAt! * 1000,
                          ),
                        ),
                  onTap: () => _play(track, history),
                  onMore: () => unawaited(_actions(track, history)),
                  onQueue: () => _enqueue(track),
                ),
              ),
            ],
          if (data?.albums case final albums? when albums.isNotEmpty)
            'albums': [
              KonnektedSectionHeading(
                title: lokalText('Albums For You'),
                icon: Icons.album_rounded,
              ),
              _AlbumShelf(
                albums: albums,
                onTap: (album) => pushLokal(
                  context,
                  LokalMusicDetailPage.album(
                    title: album.title,
                    artist: album.artist,
                    localSongs: library.album(album.title, album.artist),
                    initialOnline: true,
                    release: LokalCatalogueAlbum(
                      title: album.title,
                      artist: album.artist,
                      artwork: album.artworkUrl,
                      url: album.url,
                    ),
                  ),
                ),
              ),
            ],
          if (data?.artists case final artists? when artists.isNotEmpty)
            'artists': [
              KonnektedSectionHeading(
                title: lokalText('Artists For You'),
                icon: Icons.person_rounded,
              ),
              _ArtistShelf(
                artists: artists,
                onTap: (artist) => pushLokal(
                  context,
                  LokalMusicDetailPage.artist(
                    name: artist.name,
                    localSongs: library.artist(artist.name),
                    initialOnline: true,
                  ),
                ),
              ),
            ],
        }),
      ],
    );
  }
}

/// Compact provider selection, placed immediately under the Home greeting.
class _Header extends StatelessWidget {
  const _Header({
    required this.loading,
    required this.source,
    required this.onSourceChanged,
    required this.onRefresh,
    required this.onCustomize,
  });

  final bool loading;
  final KonnektedDiscoverySource source;
  final ValueChanged<KonnektedDiscoverySource> onSourceChanged;
  final ValueChanged<KonnektedDiscoverySource> onCustomize;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
    child: Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: LokalGlass.capsule(
              thickness: LokalGlassThickness.thin,
              shadow: false,
              padding: const EdgeInsets.all(3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final provider in KonnektedDiscoverySource.values)
                    _ProviderChip(
                      label: lokalText(switch (provider) {
                        KonnektedDiscoverySource.lastfm => 'Last.fm',
                        KonnektedDiscoverySource.youtube => 'YouTube',
                        KonnektedDiscoverySource.spotify => 'Spotify',
                      }),
                      selected: source == provider,
                      onTap: () => onSourceChanged(provider),
                      onLongPress: () => onCustomize(provider),
                    ),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: lokalText('Refresh'),
          onPressed: loading ? null : onRefresh,
          icon: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
  );
}

class _ProviderChip extends StatelessWidget {
  const _ProviderChip({
    required this.label,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.comingSoon = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool comingSoon;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      onTap: onTap,
      onLongPress: onLongPress,
      label: comingSoon
          ? lokalText("{arg0}, coming soon", args: {'arg0': label})
          : label,
      excludeSemantics: true,
      child: Tooltip(
        message: comingSoon
            ? lokalText("{arg0} is coming soon", args: {'arg0': label})
            : label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              constraints: const BoxConstraints(minWidth: 60, minHeight: 44),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? t.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? t.onAccent
                      : t.muted.withValues(alpha: comingSoon ? .45 : .8),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal cards for provider-native radio mixes.
class _MixShelf extends StatelessWidget {
  const _MixShelf({
    required this.mixes,
    required this.onTap,
    this.busyId,
    this.storageKey = 'youtube-music-mixes',
  });

  final List<LokalDiscoveryMix> mixes;
  final ValueChanged<LokalDiscoveryMix> onTap;
  final String storageKey;
  final String? busyId;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return SizedBox(
      height: 205,
      child: ListView.separated(
        key: PageStorageKey(storageKey),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: mixes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final mix = mixes[index];
          final busy = busyId == mix.id;
          final placeholder = Container(
            color: t.surface3,
            alignment: Alignment.center,
            child: Icon(Icons.queue_music_rounded, color: t.accent, size: 32),
          );
          return SizedBox(
            width: 136,
            child: Semantics(
              button: true,
              label: lokalText('Play mix ') + mix.title,
              excludeSemantics: true,
              child: InkWell(
                onTap: busy ? null : () => onTap(mix),
                borderRadius: BorderRadius.circular(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox.square(
                        dimension: 136,
                        child: busy
                            ? Container(
                                color: t.surface3,
                                alignment: Alignment.center,
                                child: CircularProgressIndicator(
                                  color: t.accent,
                                ),
                              )
                            : DiscoveryArtwork(
                                kind: DiscoveryArtworkKind.album,
                                title: mix.title,
                                artist: mix.author,
                                url: mix.artworkUrl,
                                width: 136,
                                height: 136,
                                placeholder: placeholder,
                              ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      mix.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    if (mix.author.isNotEmpty)
                      Text(
                        mix.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: t.muted),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A recommended song: its cover, title, artist and why it's here. A check
/// marks songs you have, which play straight away.
class KonnektedDiscoveryRow extends StatelessWidget {
  const KonnektedDiscoveryRow({
    super.key,
    required this.track,
    required this.onTap,
    this.onMore,
    this.onQueue,
    this.inLibrary = false,
    this.busy = false,
    this.trailing,
  });

  final LokalDiscoveryTrack track;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final Future<void> Function()? onQueue;
  final bool inLibrary;
  final bool busy;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final placeholder = Container(
      color: t.surface3,
      alignment: Alignment.center,
      child: Icon(Icons.music_note_rounded, color: t.accent, size: 20),
    );
    final row = Semantics(
      button: true,
      label: lokalText(
        "Play {arg0} by {arg1}{arg2}",
        args: {
          'arg0': track.title,
          'arg1': track.artist,
          'arg2': inLibrary ? ', in your library' : '',
        },
      ),
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMore,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox.square(
                  dimension: 52,
                  child: DiscoveryArtwork(
                    kind: DiscoveryArtworkKind.track,
                    title: track.title,
                    artist: track.artist,
                    url: track.artworkUrl,
                    width: 52,
                    height: 52,
                    placeholder: placeholder,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: t.muted),
                    ),
                    if (track.reason != null)
                      Text(
                        track.reason!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: t.muted.withValues(alpha: .75),
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                Text(
                  trailing!,
                  style: LokalTheme.label(t, size: 11, color: t.muted),
                ),
              ],
              const SizedBox(width: 10),
              SizedBox(
                width: 18,
                child: busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: t.accent,
                        ),
                      )
                    : inLibrary
                    ? Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: t.accent,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
    return onQueue == null
        ? row
        : LokalSwipeToQueue(onQueue: onQueue, enabled: !busy, child: row);
  }
}

/// Scrobbles under a heading per day, as desktop's Scrobble History.
class _History extends StatelessWidget {
  const _History({required this.entries, required this.row});

  final List<LokalDiscoveryTrack> entries;
  final Widget Function(LokalDiscoveryTrack track) row;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final days = <String, List<LokalDiscoveryTrack>>{};
    for (final track in entries) {
      final day = track.scrobbledAt == null
          ? 'Earlier'
          : DateFormat.MMMMEEEEd().format(
              DateTime.fromMillisecondsSinceEpoch(track.scrobbledAt! * 1000),
            );
      days.putIfAbsent(day, () => []).add(track);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final MapEntry(key: day, value: tracks) in days.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Row(
              children: [
                Icon(Icons.calendar_today_rounded, size: 12, color: t.muted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    day.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LokalTheme.label(t, size: 10, color: t.muted),
                  ),
                ),
              ],
            ),
          ),
          for (final track in tracks) row(track),
        ],
      ],
    );
  }
}

class _AlbumShelf extends StatelessWidget {
  const _AlbumShelf({required this.albums, required this.onTap});

  final List<LokalDiscoveryAlbum> albums;
  final ValueChanged<LokalDiscoveryAlbum> onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    const size = 148.0;
    final scale = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: size + scale.scale(14) * 1.4 + scale.scale(12) * 1.5 + 18,
      child: ListView.separated(
        key: const PageStorageKey('discovery-albums'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final album = albums[index];
          final placeholder = Container(
            color: t.surface3,
            alignment: Alignment.center,
            child: Icon(Icons.album_rounded, color: t.muted, size: 48),
          );
          return Semantics(
            button: true,
            label: lokalText(
              "Play {arg0} by {arg1}",
              args: {'arg0': album.title, 'arg1': album.artist},
            ),
            excludeSemantics: true,
            onTap: () => onTap(album),
            child: GestureDetector(
              onTap: () => onTap(album),
              child: SizedBox(
                width: size,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox.square(
                        dimension: size,
                        child: DiscoveryArtwork(
                          kind: DiscoveryArtworkKind.album,
                          title: album.title,
                          artist: album.artist,
                          url: album.artworkUrl,
                          width: size,
                          height: size,
                          placeholder: placeholder,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      album.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      album.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: t.muted),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ArtistShelf extends StatelessWidget {
  const _ArtistShelf({required this.artists, required this.onTap});

  final List<LokalDiscoveryArtist> artists;
  final ValueChanged<LokalDiscoveryArtist> onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    const size = 96.0;
    final scale = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: size + scale.scale(13) * 1.4 + 14,
      child: ListView.separated(
        key: const PageStorageKey('discovery-artists'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: artists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, index) {
          final artist = artists[index];
          final initial = artist.name.characters.first.toUpperCase();
          final placeholder = Container(
            color: t.accent.withValues(alpha: .14),
            alignment: Alignment.center,
            child: Text(
              initial,
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w600,
                color: t.accent,
              ),
            ),
          );
          return Semantics(
            button: true,
            label: lokalText(
              "Play songs by {arg0}",
              args: {'arg0': artist.name},
            ),
            excludeSemantics: true,
            onTap: () => onTap(artist),
            child: GestureDetector(
              onTap: () => onTap(artist),
              child: SizedBox(
                width: size,
                child: Column(
                  children: [
                    ClipOval(
                      child: SizedBox.square(
                        dimension: size,
                        child: DiscoveryArtwork(
                          kind: DiscoveryArtworkKind.artist,
                          artist: artist.name,
                          url: artist.image,
                          width: size,
                          height: size,
                          placeholder: placeholder,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
