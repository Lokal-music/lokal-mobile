import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/features/library_jobs/artist_metadata.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/theme/lokal_interaction.dart';
import 'package:flick/data/database.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/features/albums/widgets/identify_album_sheet.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/recommendation_match.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/player/widgets/add_to_playlist_sheet.dart';
import 'package:flick/features/player/widgets/artist_credit_links.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/favorites_provider.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/providers/songs_provider.dart';
import 'package:flick/services/color_extraction_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/lokal/lokal_glass.dart';
import 'package:flick/widgets/lokal/lokal_choice_sheet.dart';
import 'package:flick/widgets/lokal/lokal_status_snack.dart';
import 'package:flick/features/link/lokal_ghost_availability.dart';

import 'artist_follow_store.dart';
import 'lokal_detail_header.dart';
import 'lokal_library_groups.dart';
import 'lokal_library_kit.dart';
import 'lokal_online_catalogue.dart';
import 'package:flick/core/utils/album_match.dart';
import 'package:flick/features/discovery/discovery_artwork.dart';
import 'lokal_radio.dart';
import 'package:flick/widgets/lokal/lokal_swipe_to_queue.dart';

class LokalMusicDetailPage extends ConsumerStatefulWidget {
  const LokalMusicDetailPage.artist({
    super.key,
    required String name,
    required this.localSongs,
    this.initialOnline = false,
  }) : title = name,
       artist = name,
       isArtist = true,
       release = null;
  const LokalMusicDetailPage.album({
    super.key,
    required this.title,
    required this.artist,
    required this.localSongs,
    this.initialOnline = false,
    this.release,
  }) : isArtist = false;

  final String title, artist;
  final List<Song> localSongs;
  final bool isArtist, initialOnline;
  final LokalCatalogueAlbum? release;

  @override
  ConsumerState<LokalMusicDetailPage> createState() =>
      _LokalMusicDetailPageState();
}

class _Entry {
  const _Entry(this.track, this.owned);
  final LokalCatalogueTrack track;
  final Song? owned;
}

class _LokalMusicDetailPageState extends ConsumerState<LokalMusicDetailPage> {
  final _client = http.Client();
  final _cancel = Completer<void>();
  late final _progress = LokalStatusSnack(
    () => mounted ? context : null,
  );
  LokalCataloguePage? _page;
  bool _online = false,
      _loading = false,
      _busy = false,
      _followed = false,
      _allSongs = false;
  String? _portrait, _error;
  Color? _dominant;
  int _request = 0;
  String get _identity =>
      '${widget.isArtist ? 'artist' : 'album'}:${recommendationKey(widget.artist)}:${recommendationKey(widget.title)}';
  String get _consentKey => 'lokal.catalogue.online.$_identity';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    await ArtistFollowStore.instance.load();
    if (!mounted) return;
    setState(() {
      _followed = ArtistFollowStore.instance.isFollowed(widget.artist);
    });
    if (widget.isArtist && Database.isInitialized) {
      try {
        final row = await Database.artists
            .filter()
            .nameEqualTo(widget.artist, caseSensitive: false)
            .findFirst();
        if (mounted) setState(() => _portrait = row?.artPath);
        if (row?.artPath?.isNotEmpty == true) unawaited(_tint(row!.artPath!));
      } catch (_) {
        /* A missing portrait never blocks opening the page. */
      }
    }
    if (!mounted) return;
    if (widget.initialOnline || prefs.getBool(_consentKey) == true) {
      setState(() => _online = true);
      _load();
    } else if (!widget.isArtist) {
      final path = widget.localSongs
          .where((s) => s.albumArt?.isNotEmpty == true)
          .firstOrNull
          ?.albumArt;
      if (path != null && !path.startsWith('http')) _tint(path);
    }
  }

  Future<void> _tint(String path) async {
    try {
      if (path.startsWith('http')) {
        if (!_online) return;
        path = (await DefaultCacheManager().getSingleFile(path)).path;
      }
      final color = await ColorExtractionService().extractDominantColor(path);
      if (widget.isArtist && Database.isInitialized && _online) {
        final previous = await Database.artists
            .filter()
            .nameEqualTo(widget.artist, caseSensitive: false)
            .findFirst();
        if (previous?.artPath?.isNotEmpty != true) {
          final artist = previous ?? (ArtistEntity()..name = widget.artist);
          artist.artPath = path;
          await Database.instance.writeTxn(() => Database.artists.put(artist));
          if (mounted) setState(() => _portrait = path);
        }
      }
      if (mounted && color != null) setState(() => _dominant = color);
    } catch (_) {}
  }

  Future<void> _setOnline(bool value) async {
    setState(() => _online = value);
    ++_request;
    await (await SharedPreferences.getInstance()).setBool(_consentKey, value);
    if (!mounted) return;
    if (value) {
      await _load();
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (!_online) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await (widget.isArtist
          ? LokalOnlineCatalogue.instance.artist(
              widget.artist,
              refresh: refresh,
            )
          : LokalOnlineCatalogue.instance.album(
              widget.title,
              widget.artist,
              release: widget.release,
              refresh: refresh,
            ));
      if (!mounted || !_online || request != _request) return;
      setState(() => _page = page);
      final image = widget.isArtist
          ? page.portrait
          : page.albums.firstOrNull?.artwork;
      if (image?.isNotEmpty == true) unawaited(_tint(image!));
    } catch (error) {
      if (mounted && request == _request)
        setState(() => _error = discoveryError(error));
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  List<Song> _local(List<Song> library) {
    final artist = recommendationKey(widget.artist);
    final wantedTitle = albumTitleKey(widget.title);
    final found = library
        .where(
          (song) => widget.isArtist
              ? (recommendationKey(song.albumArtist ?? song.artist) == artist ||
                  recommendationKey(song.artist) == artist ||
                  catalogueArtistCredit(song.artist, widget.artist))
              : wantedTitle.isNotEmpty &&
                  albumTitleKey(song.album ?? '') == wantedTitle &&
                  albumArtistsMatch(widget.artist, song.albumArtist ?? song.artist),
        )
        .toList();
    return found;
  }

  List<_Entry> _entries(List<Song> library, List<Song> local) {
    final index = KonnektedLibraryIndex.of(library);
    final seen = <String>{};
    final rows = <_Entry>[];
    if (_online)
      for (final track in _page?.tracks ?? <LokalCatalogueTrack>[]) {
        if (!seen.add(track.metadata.key)) continue;
        rows.add(_Entry(track, index.match(track.metadata)));
      }
    final counts = ref.watch(lokalPlayCountsProvider).value ?? const {};
    final ordered = List<Song>.of(local)
      ..sort((a, b) {
        if (widget.isArtist)
          return (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0);
        final disc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
        return disc != 0
            ? disc
            : (a.trackNumber ?? 999).compareTo(b.trackNumber ?? 999);
      });
    for (final song in ordered) {
      final metadata = LokalDiscoveryTrack(
        title: song.title,
        artist: song.artist,
        album: song.album ?? '',
        artworkUrl: song.albumArt ?? '',
        duration: song.duration,
      );
      if (seen.add(metadata.key) &&
          !rows.any((row) => row.owned?.id == song.id))
        rows.add(
          _Entry(
            LokalCatalogueTrack(
              metadata,
              number: song.trackNumber,
              disc: song.discNumber,
            ),
            song,
          ),
        );
    }
    return rows;
  }

  Future<Song> _prepare(_Entry entry) async {
    if (entry.owned != null) {
      if (entry.owned!.sourceType != 'lokal' ||
          await ref.read(lokalSongAvailableProvider(entry.owned!).future))
        return entry.owned!;
      if (!_online)
        throw const DiscoveryException(
          'This desktop song is offline and has not been downloaded.',
        );
    }
    final song = await prepareCatalogueTrack(
      entry.track,
      cancel: _cancel.future,
      onStatus: (text) {
        if (mounted) _progress.update(text);
      },
    );
    if (song == null)
      throw const DiscoveryException(
        'This recording could not be found on your playback sources.',
      );
    return song;
  }

  Future<void> _play(
    List<_Entry> rows, {
    int start = 0,
    bool shuffle = false,
  }) async {
    if (rows.isEmpty || _busy) return;
    final ordered = List<_Entry>.of(rows);
    if (shuffle) {
      ordered.shuffle();
      start = 0;
    }
    setState(() => _busy = true);
    try {
      final queue = [
        for (final entry in ordered) entry.owned ?? entry.track.pending(),
      ];
      await ref
          .read(playerProvider.notifier)
          .play(queue[start], playlist: queue);
      _progress.clear();
    } catch (error) {
      if (mounted) _progress.fail(discoveryError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(List<_Entry> rows) async {
    if (_busy) return;
    final missing = rows.where((row) => row.owned == null).toList();
    if (missing.isEmpty) return;
    setState(() => _busy = true);
    var saved = 0;
    try {
      for (final row in missing) {
        if (!mounted || _cancel.isCompleted) break;
        _progress.update(
          lokalText(
            'Downloading {title}…',
            args: {'title': row.track.metadata.title},
          ),
        );
        final song = await _prepare(row);
        if (!mounted) break;
        await LibraryDownloader().save(
          song,
          artwork: row.track.metadata.artworkUrl.isEmpty
              ? null
              : row.track.metadata.artworkUrl,
        );
        saved++;
        ref.invalidate(songsProvider);
      }
      if (mounted)
        _progress.fail(
          lokalText(
            'Saved {count} songs to your library.',
            args: {'count': saved},
          ),
        );
    } catch (error) {
      if (mounted)
        _progress.fail(
          lokalText(
            'Saved {count} songs. {error}',
            args: {'count': saved, 'error': discoveryError(error)},
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    try {
      final box = context.findRenderObject();
      await SharePlus.instance.share(
        ShareParams(
          text:
              '${widget.title}${widget.isArtist ? '' : ' — ${widget.artist}'}\n${_online && _page?.url.isNotEmpty == true ? _page!.url : 'Konnekted'}',
          sharePositionOrigin: box is RenderBox && box.hasSize
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (error) {
      if (mounted) _progress.fail(lokalText('Could not share this page.'));
    }
  }

  @override
  void dispose() {
    ++_request;
    _cancel.complete();
    _client.close();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final library =
        ref.watch(konnektedLibraryProvider).value ?? widget.localSongs;
    final local = _local(library);
    final rows = _entries(library, local);
    final groups =
        lokalAlbums(widget.isArtist ? local : library)
            .where(
              (album) =>
                  widget.isArtist ||
                  recommendationKey(album.albumArtist) ==
                      recommendationKey(widget.artist),
            )
            .toList()
          ..sort(
            (a, b) =>
                (b.songs.first.year ?? 0).compareTo(a.songs.first.year ?? 0),
          );
    final albums = <LokalCatalogueAlbum>[];
    final albumIds = <String>{};
    final onlineTitles = <String>{};
    if (_online) {
      for (final album in _page?.albums ?? <LokalCatalogueAlbum>[]) {
        final title = recommendationKey(album.title);
        // Do not collapse distinct official editions solely because they
        // share a title. Artist lookup can return several release IDs.
        if (album.id?.isNotEmpty == true && !albumIds.add(album.id!)) continue;
        if (album.id?.isNotEmpty != true && !onlineTitles.add(title)) continue;
        onlineTitles.add(title);
        albums.add(album);
      }
    }
    for (final group in groups) {
      if (onlineTitles.add(recommendationKey(group.albumName)))
        albums.add(
          LokalCatalogueAlbum(
            title: group.albumName,
            artist: group.albumArtist,
            artwork:
                group.songs
                    .where((s) => s.albumArt?.isNotEmpty == true)
                    .firstOrNull
                    ?.albumArt ??
                '',
            date: group.songs.first.year == null
                ? null
                : '${group.songs.first.year}-01-01',
            releaseKind:
                widget.isArtist &&
                    !cataloguePrimaryArtist(group.albumArtist, widget.artist)
                ? LokalReleaseKind.feature
                : null,
          ),
        );
    }
    final localArtworkSong = local
        .where((song) => song.albumArt?.isNotEmpty == true)
        .firstOrNull ?? local.firstOrNull;
    final localCover = localArtworkSong?.albumArt;
    final cachedPortrait = widget.isArtist
        ? ref.watch(
            artistMetadataProvider.select(
              (paths) => paths[ArtistMetadata.key(widget.artist)],
            ),
          )
        : null;
    final heroImage = widget.isArtist
        ? (cachedPortrait ??
              (_portrait?.isNotEmpty == true
                  ? _portrait
                  : _online
                  ? _page?.portrait
                  : null))
        : ((_online && _page?.albums.firstOrNull?.artwork.isNotEmpty == true
                  ? _page!.albums.first.artwork : null) ??
              localCover ?? widget.release?.artwork);
    final moreAlbums = albums
        .where(
          (album) =>
              recommendationKey(album.title) != recommendationKey(widget.title),
        )
        .toList();
    final pageColor = Color.lerp(t.bg, _dominant ?? t.bg, .2)!;
    final show = widget.isArtist && !_allSongs ? rows.take(5).toList() : rows;
    final liked = ref.watch(favoritesProvider).value;
    final allLiked = local.isNotEmpty &&
        local.every((song) => liked?.isFavorite(song.id) == true);

    // The existing image-resolution chain is retained for online albums,
    // network/NAS artwork, cached artist portraits and local fallback art.
    final Widget heroArtwork;
    if (_online && !widget.isArtist && _page != null) {
      heroArtwork = DiscoveryArtwork(
        kind: DiscoveryArtworkKind.album,
        title: widget.title,
        artist: widget.artist,
        url: discoveryImageUrl(heroImage),
        placeholder: localCover?.isNotEmpty == true
            ? CachedImageWidget(
                imagePath: localCover,
                audioSourcePath: localArtworkSong?.filePath,
                fit: BoxFit.cover,
                errorWidget: ColoredBox(color: pageColor),
              )
            : ColoredBox(color: pageColor),
      );
    } else if (heroImage?.isNotEmpty == true) {
      heroArtwork = CachedImageWidget(
        imagePath: heroImage,
        audioSourcePath: widget.isArtist ? null : localArtworkSong?.filePath,
        fit: BoxFit.cover,
        placeholder: ColoredBox(color: pageColor),
        errorWidget: ColoredBox(color: pageColor),
      );
    } else if (!widget.isArtist && local.isNotEmpty) {
      heroArtwork = CachedImageWidget(
        audioSourcePath: local.first.filePath,
        fit: BoxFit.cover,
        placeholder: ColoredBox(color: pageColor),
        errorWidget: ColoredBox(color: pageColor),
      );
    } else {
      heroArtwork = ColoredBox(
        color: pageColor,
        child: Center(
          child: Icon(
            widget.isArtist ? Icons.person_rounded : Icons.album_rounded,
            size: 110,
            color: t.muted2.withValues(alpha: .4),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: pageColor,
      body: CustomScrollView(
        key: PageStorageKey('detail:$_identity'),
        slivers: [
          SliverToBoxAdapter(
            child: LokalDetailHeader(
              title: widget.title,
              artwork: heroArtwork,
              isArtist: widget.isArtist,
              background: pageColor,
              metadata: widget.isArtist
                  ? (local.isEmpty ? null : lokalSongCount(local.length))
                  : [
                      if (local.firstOrNull?.year != null)
                        '${local.first.year}',
                      lokalSongCount(rows.length),
                      if (local.isNotEmpty) lokalRunningTime(local),
                    ].join('  ·  '),
              onBack: () => Navigator.of(context).maybePop(),
              onShare: _share,
              onMore: () => unawaited(_showMenu(rows, local, allLiked)),
              artistCredit: widget.isArtist ? null : ArtistCreditLinks(
                credit: widget.artist,
                style: TextStyle(fontSize: 17, color: t.accent),
                onArtistTap: (artist) => pushLokal(
                  context,
                  LokalMusicDetailPage.artist(
                    name: artist,
                    localSongs: KonnektedLibraryIndex.of(library).artist(artist),
                    initialOnline: _online,
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: rows.isEmpty || _busy ? null : () => _play(rows),
                          icon: _busy
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.play_arrow_rounded, size: 27),
                          label: Text(
                            l10n.play,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: t.accent,
                            foregroundColor: t.onAccent,
                            minimumSize: const Size(0, 56),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(19),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _control(
                        Icons.shuffle_rounded,
                        l10n.shuffle,
                        rows.isEmpty || _busy ? null : () => _play(rows, shuffle: true),
                      ),
                      const SizedBox(width: 12),
                      _control(
                        widget.isArtist
                            ? (_followed ? Icons.star_rounded : Icons.star_border_rounded)
                            : (allLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                        widget.isArtist
                            ? (_followed ? lokalText('Unfollow artist') : lokalText('Follow artist'))
                            : lokalText('Like all'),
                        !widget.isArtist && local.isEmpty
                            ? null : () => widget.isArtist
                                ? _follow() : _like(local, !allLiked),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: t.surface.withValues(alpha: .8),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: t.border2.withValues(alpha: .65)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  lokalText('Online catalogue'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: t.text,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              if (_online)
                                IconButton(
                                  tooltip: lokalText('Refresh'),
                                  onPressed: _loading ? null : () => _load(refresh: true),
                                  icon: Icon(Icons.refresh_rounded, color: t.muted),
                                ),
                              Switch.adaptive(
                                value: _online,
                                onChanged: _busy ? null : _setOnline,
                                activeTrackColor: t.accent,
                              ),
                            ],
                          ),
                          if (_online) ...[
                            if (_loading)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 10),
                                child: LinearProgressIndicator(),
                              ),
                            if (!_loading && (_page?.tracks.isEmpty ?? true))
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: Text(
                                  _error ?? lokalText(
                                    'No online tracks found. Your library is still available.'),
                                  style: TextStyle(color: t.muted, fontSize: 13),
                                ),
                              ),
                            if (_page?.tracks.isNotEmpty == true)
                              Padding(
                                padding: const EdgeInsets.only(top: 8, bottom: 6),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    widget.isArtist || _page!.completeAlbum
                                        ? lokalText('Catalogue: {source}',
                                            args: {'source': _page!.label})
                                        : lokalText(
                                            'Search results from {source}; the full album could not be verified.',
                                            args: {'source': _page!.label}),
                                    style: TextStyle(color: t.muted, fontSize: 12),
                                  ),
                                ),
                              ),
                            if (rows.any((row) => row.owned == null))
                              TextButton.icon(
                                onPressed: _busy ? null : () => _download(rows),
                                icon: const Icon(Icons.download_rounded, size: 18),
                                label: Text(lokalText('Download missing songs')),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.isArtist && albums.isNotEmpty)
            SliverToBoxAdapter(
              child: _recentRelease(albums.first, groups, library),
            ),
          SliverToBoxAdapter(
            child: LokalSectionTitle(
              title: widget.isArtist
                  ? lokalText('Top songs')
                  : lokalText('Songs'),
              onSeeAll: widget.isArtist && rows.length > 5
                  ? () => setState(() => _allSongs = !_allSongs)
                  : null,
            ),
          ),
          if (show.isEmpty && !_loading)
            SliverToBoxAdapter(
              child: LokalEmptyState(
                icon: Icons.music_note_rounded,
                title: lokalText('Nothing here yet'),
                message: lokalText(
                  _online
                      ? 'No matching tracks found. Try refreshing the catalogue.'
                      : 'Enable online mode to discover songs and releases.',
                ),
              ),
            ),
          SliverList.builder(
            itemCount: show.length,
            itemBuilder: (context, index) =>
                _trackRow(show[index], rows, index),
          ),
          for (final kind in LokalReleaseKind.values)
            if (widget.isArtist &&
                albums.any((album) => album.kind == kind)) ...[
              SliverToBoxAdapter(
                child: LokalSectionTitle(
                  title: switch (kind) {
                    LokalReleaseKind.album => l10n.albums,
                    LokalReleaseKind.ep => lokalText('EPs'),
                    LokalReleaseKind.single => lokalText('Singles'),
                    LokalReleaseKind.compilation => lokalText('Compilations'),
                    LokalReleaseKind.live => lokalText('Live'),
                    LokalReleaseKind.feature => lokalText('Features'),
                    LokalReleaseKind.unknown => lokalText('Unknown albums'),
                  },
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 238,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: albums
                        .where((album) => album.kind == kind)
                        .length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (context, index) => SizedBox(
                      width: 156,
                      child: _albumCard(
                        albums
                            .where((album) => album.kind == kind)
                            .elementAt(index),
                        groups,
                        library,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          if (!widget.isArtist && rows.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Text(
                  lokalSongCount(rows.length),
                  style: TextStyle(color: t.muted, fontSize: 13),
                ),
              ),
            ),
          if (!widget.isArtist && moreAlbums.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: LokalSectionTitle(
                title: lokalText(
                  'More by {artist}',
                  args: {'artist': widget.artist},
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 238,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: moreAlbums.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, index) => SizedBox(
                    width: 156,
                    child: _albumCard(moreAlbums[index], groups, library),
                  ),
                ),
              ),
            ),
          ],
          if (widget.isArtist &&
              _online &&
              _page?.biography?.isNotEmpty == true)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _page!.biography!,
                  style: TextStyle(color: t.muted, height: 1.5),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom),
          ),
        ],
      ),
    );
  }

  Widget _control(IconData icon, String label, VoidCallback? onTap) => Tooltip(
    message: label,
    child: LokalGlassButton(
      size: 56,
      semanticLabel: label,
      onPressed: onTap,
      child: Icon(
        icon,
        color: onTap == null ? context.lokal.muted2 : context.lokal.text,
        size: 26,
      ),
    ),
  );

  Future<void> _follow() async {
    final next = !_followed;
    await ArtistFollowStore.instance.setFollowed(widget.artist, next);
    if (mounted) setState(() => _followed = next);
  }

  Future<void> _like(List<Song> songs, bool value) async {
    final notifier = ref.read(favoritesProvider.notifier);
    for (final song in songs) {
      if (value) {
        await notifier.addFavorite(song.id, song: song);
      } else {
        await notifier.removeFavorite(song.id);
      }
    }
  }

  Future<void> _showMenu(
    List<_Entry> rows,
    List<Song> local,
    bool allLiked,
  ) async {
    final value = await showLokalChoiceSheet<String>(
      context: context,
      title: widget.title,
      choices: [
        if (local.isNotEmpty)
          LokalChoice(value: 'playlist',
            label: lokalText('Add to a playlist'), icon: Icons.playlist_add_rounded),
        if (local.isNotEmpty)
          LokalChoice(value: 'like',
            label: allLiked ? lokalText('Unlike all') : lokalText('Like all'),
            icon: allLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded),
        if (rows.isNotEmpty)
          LokalChoice(value: 'queue', label: lokalText('Add to queue'),
            icon: Icons.queue_music_rounded),
        if (!widget.isArtist && local.isNotEmpty)
          LokalChoice(value: 'identify', label: lokalText('Identify album'),
            icon: Icons.album_rounded),
        LokalChoice(value: 'radio', label: lokalText('Start artist radio'),
          icon: Icons.radio_rounded),
      ],
    );
    if (value != null && mounted) await _menu(value, rows, local, allLiked);
  }

  Future<void> _menu(
    String value,
    List<_Entry> rows,
    List<Song> local,
    bool allLiked,
  ) async {
    if (_busy) return;
    try {
      switch (value) {
        case 'playlist':
          await AddToPlaylistSheet.showSongs(context, local);
        case 'like':
          await _like(local, !allLiked);
        case 'queue':
          final player = ref.read(playerProvider.notifier);
          for (final row in rows) {
            await player.addToQueue(row.owned ?? row.track.pending());
          }
        case 'identify':
          await IdentifyAlbumSheet.show(
            context,
            songs: local,
            initialArtist: widget.artist,
            initialAlbum: widget.title,
          );
        case 'radio':
          await startLokalRadio(context, artist: widget.artist);
      }
    } catch (error) {
      if (mounted) _progress.fail(discoveryError(error));
    }
  }

  List<Song> _albumSongs(LokalCatalogueAlbum album, List<AlbumGroup> groups) =>
      groups
          .where(
            (group) =>
                recommendationKey(group.albumName) ==
                    recommendationKey(album.title) &&
                recommendationKey(group.albumArtist) ==
                    recommendationKey(album.artist),
          )
          .firstOrNull
          ?.songs ??
      const [];

  void _openAlbum(LokalCatalogueAlbum album, List<AlbumGroup> groups) {
    pushLokal(
      context,
      LokalMusicDetailPage.album(
        title: album.title,
        artist: album.artist,
        localSongs: _albumSongs(album, groups),
        initialOnline: _online,
        release: album,
      ),
    );
  }

  Widget _releaseArt(
    LokalCatalogueAlbum album,
    List<Song> songs,
    double size,
  ) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SizedBox.square(
      dimension: size,
      child: CachedImageWidget(
        imagePath: album.artwork.isEmpty
            ? songs.firstOrNull?.albumArt
            : album.artwork,
        audioSourcePath: songs.firstOrNull?.filePath,
        fit: BoxFit.cover,
        placeholder: ColoredBox(
          color: context.lokal.surface2,
          child: Icon(Icons.album_rounded, color: context.lokal.muted),
        ),
        errorWidget: ColoredBox(
          color: context.lokal.surface2,
          child: Icon(Icons.album_rounded, color: context.lokal.muted),
        ),
      ),
    ),
  );

  String _ownership(LokalCatalogueAlbum album, List<Song> songs) {
    if (songs.isEmpty) return '';
    if (album.trackCount != null && songs.length >= album.trackCount!)
      return lokalText('In library');
    return album.trackCount == null
        ? lokalSongCount(songs.length)
        : lokalText(
            '{owned}/{total} in library',
            args: {'owned': songs.length, 'total': album.trackCount},
          );
  }

  Widget _recentRelease(
    LokalCatalogueAlbum album,
    List<AlbumGroup> groups,
    List<Song> library,
  ) {
    final t = context.lokal, songs = _albumSongs(album, groups);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Material(
        color: t.surface.withValues(alpha: .65),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: t.muted2.withValues(alpha: .2)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openAlbum(album, groups),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _releaseArt(album, songs, 80),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.year?.toString() ??
                            (album.date == null
                                ? lokalText('Featured album')
                                : lokalText('Recent release')),
                        style: TextStyle(color: t.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        album.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _ownership(album, songs).isEmpty
                            ? (album.date == null
                                  ? lokalText('Featured album')
                                  : lokalText('Recent release'))
                            : _ownership(album, songs),
                        style: TextStyle(color: t.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip:
                      !_online ||
                          (album.trackCount != null &&
                              songs.length >= album.trackCount!)
                      ? lokalText('Add to a playlist')
                      : lokalText('Add to library'),
                  onPressed: _busy
                      ? null
                      : () async {
                          if (!_online ||
                              (album.trackCount != null &&
                                  songs.length >= album.trackCount!)) {
                            if (songs.isNotEmpty)
                              await AddToPlaylistSheet.showSongs(
                                context,
                                songs,
                              );
                          } else {
                            await _downloadRelease(album, library);
                          }
                        },
                  icon: Icon(Icons.add_rounded, color: t.text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _downloadRelease(
    LokalCatalogueAlbum album,
    List<Song> library,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _progress.update(lokalText('Loading album…'));
      final page = await LokalOnlineCatalogue.instance.album(
        album.title,
        album.artist,
        release: album,
      );
      if (!mounted) return;
      final index = KonnektedLibraryIndex.of(library);
      final rows = [
        for (final track in page.tracks)
          _Entry(track, index.match(track.metadata)),
      ];
      setState(() => _busy = false);
      if (rows.isEmpty) {
        _progress.fail(lokalText('No online tracks found.'));
        return;
      }
      if (rows.every((row) => row.owned != null)) {
        _progress.clear();
        await AddToPlaylistSheet.showSongs(context, [
          for (final row in rows) row.owned!,
        ]);
      } else {
        await _download(rows);
      }
    } catch (error) {
      if (mounted) _progress.fail(discoveryError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _albumCard(
    LokalCatalogueAlbum album,
    List<AlbumGroup> groups,
    List<Song> library,
  ) {
    final songs = _albumSongs(album, groups), t = context.lokal;
    return LokalPressable(
      radius: 16,
      semanticLabel: album.title,
      onTap: () => _openAlbum(album, groups),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _releaseArt(album, songs, 156),
          const SizedBox(height: 8),
          Text(
            album.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: t.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _ownership(album, songs).isEmpty
                ? album.year?.toString() ?? album.artist
                : _ownership(album, songs),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _songActions(_Entry row) => unawaited(
    SongActionsBottomSheet.show(
      context,
      row.owned ?? row.track.pending(),
      extras: [
        if (row.owned == null)
          LokalSongMenuAction(
            icon: Icons.download_rounded,
            label: lokalText('Download to library'),
            onTap: () {
              if (mounted) unawaited(_download([row]));
            },
          ),
      ],
    ),
  );

  Widget _trackRow(_Entry row, List<_Entry> queue, int index) {
    final t = context.lokal, track = row.track.metadata;
    return LokalSwipeToQueue(
      song: row.owned ?? row.track.pending(),
      enabled: !_busy,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
        onTap: _busy ? null : () => _play(queue, start: index),
        onLongPress: _busy ? null : () => _songActions(row),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox.square(
            dimension: 48,
            child: row.owned == null
                ? DiscoveryArtwork(
                    kind: DiscoveryArtworkKind.track,
                    title: track.title,
                    artist: track.artist,
                    url: track.artworkUrl,
                    width: 48,
                    height: 48,
                    placeholder: ColoredBox(
                      color: t.surface2,
                      child: Icon(Icons.music_note_rounded, color: t.muted),
                    ),
                  )
                : CachedImageWidget(
                    imagePath: row.owned?.albumArt,
                    audioSourcePath: row.owned?.filePath,
                    fit: BoxFit.cover,
                    placeholder: ColoredBox(
                      color: t.surface2,
                      child: Icon(Icons.music_note_rounded, color: t.muted),
                    ),
                    errorWidget: ColoredBox(
                      color: t.surface2,
                      child: Icon(Icons.music_note_rounded, color: t.muted),
                    ),
                  ),
          ),
        ),
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: t.text,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
        subtitle: Text(
          widget.isArtist
              ? track.artist
              : '${row.track.disc != null && row.track.disc! > 1 ? '${row.track.disc} · ' : ''}${row.track.number ?? index + 1} · ${track.artist}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.muted, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (row.owned != null)
              Tooltip(
                message: lokalText('In library'),
                child: Icon(
                  Icons.check_circle_outline_rounded,
                  color: t.accent,
                  size: 18,
                ),
              ),
            IconButton(
              tooltip: lokalText('More'),
              icon: Icon(Icons.more_vert_rounded, color: t.muted, size: 20),
              onPressed: _busy ? null : () => _songActions(row),
            ),
          ],
        ),
      ),
    );
  }
}
