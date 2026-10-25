import 'package:flick/core/utils/artist_credits.dart';
import 'package:flick/core/utils/album_match.dart';

import 'dart:collection';

import 'package:flick/services/queue_pre_resolver.dart';
import 'package:flick/features/discovery/discovery_artwork.dart';
import 'package:flick/features/discovery/discovery_http.dart';

import 'package:http/http.dart' as http;
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/recommendation_match.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/apple_music/apple_music_metadata_service.dart';
import 'package:flick/services/apple_music/apple_music_models.dart';

class LokalCatalogueTrack {
  const LokalCatalogueTrack(
    this.metadata, {
    this.number,
    this.disc,
    this.sourceId,
    this.exact,
  });
  final LokalDiscoveryTrack metadata;
  final int? number, disc;
  final String? sourceId;
  final DiscoveryTrack? exact;

  Song pending({String? playbackSource}) {
    if (playbackSource == null) return discoveryPendingSong(metadata);
    final resolver = QueuePreResolver.shared;
    return resolver.pending(
      key: 'catalogue:$playbackSource:${metadata.key}',
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      duration: metadata.duration,
      artwork: metadata.artworkUrl,
      resolve: ({onStatus, cancel}) => prepareCatalogueTrack(
        this,
        playbackSource: playbackSource,
        onStatus: onStatus,
        cancel: cancel,
      ),
    );
  }
}

enum LokalReleaseKind { album, ep, single, compilation, live, feature, unknown }

/// Match complete artist credit tokens, rather than substring names (e.g.
/// "Ann" must not claim "Joanne" releases as Features).
bool catalogueArtistCredit(String credit, String artist) {
  if (recommendationKey(credit) == recommendationKey(artist)) return true;
  return splitArtistCredits(credit)
      .any((name) => recommendationKey(name) == recommendationKey(artist));
}

bool cataloguePrimaryArtist(String credit, String artist) =>
    recommendationKey(credit) == recommendationKey(artist) ||
    recommendationKey(splitArtistCredits(credit).firstOrNull) ==
        recommendationKey(artist);

class LokalCatalogueAlbum {
  const LokalCatalogueAlbum({
    required this.title,
    required this.artist,
    this.id,
    this.artwork = '',
    this.date,
    this.trackCount,
    this.url = '',
    this.releaseKind,
  });
  final String title, artist, artwork, url;
  final String? id, date;
  final int? trackCount;
  final LokalReleaseKind? releaseKind;
  LokalReleaseKind get kind {
    if (releaseKind != null) return releaseKind!;
    final name = title.toLowerCase();
    if (RegExp(r'(?:\bep\b|extended play)').hasMatch(name))
      return LokalReleaseKind.ep;
    if (RegExp(r'\bsingle\b').hasMatch(name)) return LokalReleaseKind.single;
    if (RegExp(r'compilation|greatest hits|best of').hasMatch(name))
      return LokalReleaseKind.compilation;
    if (RegExp(r'(?:\(|-\s*)live\b|\blive at\b|\blive in\b').hasMatch(name))
      return LokalReleaseKind.live;
    if (trackCount == 1) return LokalReleaseKind.single;
    if (trackCount != null && trackCount! >= 2 && trackCount! <= 6)
      return LokalReleaseKind.ep;
    if (title.trim().isEmpty || recommendationKey(title) == 'unknown album')
      return LokalReleaseKind.unknown;
    return LokalReleaseKind.album;
  }

  int? get year => date == null ? null : DateTime.tryParse(date!)?.year;
  factory LokalCatalogueAlbum.fromApple(AppleMusicAlbumMatch match) =>
      LokalCatalogueAlbum(
        id: match.collectionId,
        title: match.name,
        artist: match.artistName,
        artwork: match.artworkUrl ?? '',
        date: match.releaseDate,
        trackCount: match.trackCount,
        url: match.url,
      );
}

class LokalCataloguePage {
  const LokalCataloguePage({
    this.tracks = const [],
    this.albums = const [],
    this.portrait = '',
    this.biography,
    this.url = '',
    this.label = 'Apple Music',
    this.completeAlbum = false,
  });
  final List<LokalCatalogueTrack> tracks;
  final List<LokalCatalogueAlbum> albums;
  final String portrait, url, label;
  final String? biography;
  final bool completeAlbum;
}

/// Construction performs no requests. Called only by the page's online switch
/// or an explicit navigation from an already-online recommendation.
class LokalOnlineCatalogue {
  LokalOnlineCatalogue({
    AppleMusicMetadataService? apple,
    Future<List<OnlineSource>> Function(http.Client)? sources,
    Future<String> Function(String title, String artist)? albumArtwork,
  }) : _apple = apple ?? AppleMusicMetadataService.instance,
       _sources = sources ?? onlineSources,
       _albumArtwork = albumArtwork;
  static final instance = LokalOnlineCatalogue();
  void invalidateArtist(String name) =>
      _cache.remove('artist:${recommendationKey(name)}');

  final AppleMusicMetadataService _apple;
  final Future<List<OnlineSource>> Function(http.Client) _sources;
  final Future<String> Function(String, String)? _albumArtwork;
  final _cache = LinkedHashMap<String, (DateTime, LokalCataloguePage)>();
  final _pending = <String, Future<LokalCataloguePage>>{};

  Future<LokalCataloguePage> _load(
    String key,
    bool refresh,
    Future<LokalCataloguePage> Function() fetch,
  ) async {
    final hit = _cache[key];
    if (!refresh &&
        hit != null &&
        DateTime.now().difference(hit.$1) < const Duration(minutes: 15))
      return hit.$2;
    if (_pending[key] case final work?) return work;
    final work = fetch();
    _pending[key] = work;
    try {
      final page = await work;
      if (page.tracks.isNotEmpty ||
          page.albums.isNotEmpty ||
          page.portrait.isNotEmpty) {
        _cache.remove(key);
        _cache[key] = (DateTime.now(), page);
        while (_cache.length > 60) {
          _cache.remove(_cache.keys.first);
        }
      }
      return page;
    } finally {
      _pending.remove(key);
    }
  }

  Future<LokalCataloguePage> artist(
    String name, {
    bool refresh = false,
  }) => _load('artist:${recommendationKey(name)}', refresh, () async {
    AppleMusicArtistData? data;
    List<AppleMusicAlbumMatch> releases = const [];
    // Independent metadata sections can still be shown when one endpoint fails.
    await Future.wait([
      _apple
          .getArtistData(name, topSongLimit: 25, refresh: refresh)
          .then((value) {
            data = value;
          })
          .catchError((Object _) {}),
      _apple
          .searchAlbums(name, limit: 100, refresh: refresh)
          .then((value) {
            releases = value;
          })
          .catchError((Object _) {}),
    ]);
    if (data != null &&
        recommendationKey(data!.artist.name) != recommendationKey(name))
      data = null;
    final creditedAlbums = {
      for (final song in data?.topSongs ?? <AppleMusicTopSong>[])
        if (catalogueArtistCredit(song.artistName, name) &&
            song.collectionName != null)
          recommendationKey(song.collectionName),
    };
    final albums =
        releases
            .where(
              (album) =>
                  recommendationKey(album.artistName) ==
                      recommendationKey(name) ||
                  catalogueArtistCredit(album.artistName, name) ||
                  creditedAlbums.contains(recommendationKey(album.name)),
            )
            .map(
              (match) => LokalCatalogueAlbum(
                id: match.collectionId,
                title: match.name,
                artist: match.artistName,
                artwork: match.artworkUrl ?? '',
                date: match.releaseDate,
                trackCount: match.trackCount,
                url: match.url,
                releaseKind: !cataloguePrimaryArtist(match.artistName, name)
                    ? LokalReleaseKind.feature
                    : null,
              ),
            )
            .toList()
          ..sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
    var tracks = [
      for (final song in data?.topSongs ?? <AppleMusicTopSong>[])
        LokalCatalogueTrack(
          LokalDiscoveryTrack(
            title: song.trackName,
            artist: song.artistName,
            album: song.collectionName ?? '',
            artworkUrl:
                albums
                    .where(
                      (a) =>
                          recommendationKey(a.title) ==
                          recommendationKey(song.collectionName),
                    )
                    .firstOrNull
                    ?.artwork ??
                '',
            duration: song.durationMs == null
                ? null
                : Duration(milliseconds: song.durationMs!),
          ),
        ),
    ];
    String label = 'Apple Music';
    if (tracks.isEmpty) {
      final found = await _search(name, artist: name);
      if (found.$1.isNotEmpty) {
        tracks = found.$1;
        label = found.$2;
      }
    }
    if (albums.isEmpty) {
      final seen = <String>{};
      for (final track in tracks) {
        final album = track.metadata.album;
        if (album.isNotEmpty && seen.add(recommendationKey(album)))
          albums.add(
            LokalCatalogueAlbum(
              title: album,
              artist: name,
              artwork: track.metadata.artworkUrl,
            ),
          );
      }
    }
    var portrait = data?.info?.imageUrl ?? '';
    if (portrait.isEmpty) {
      final client = http.Client();
      try {
        portrait = await DiscoveryArtworkResolver(DiscoveryHttp(client))
            .resolve(
              DiscoveryArtworkRequest(
                kind: DiscoveryArtworkKind.artist,
                artist: name,
              ),
            )
            .timeout(const Duration(seconds: 8));
      } catch (_) {
      } finally {
        client.close();
      }
    }
    return LokalCataloguePage(
      tracks: tracks,
      albums: albums,
      portrait: portrait,
      biography: data?.info?.biography,
      url: data?.artist.url ?? '',
      label: label,
    );
  });

  Future<LokalCataloguePage> album(
    String title,
    String artist, {
    LokalCatalogueAlbum? release,
    bool refresh = false,
  }) => _load(
    'album:${release?.id ?? '${recommendationKey(artist)}:${recommendationKey(title)}'}',
    refresh,
    () async {
      AppleMusicAlbumData? data;
      List<AppleMusicTrack> tracks = const [];
      try {
        if (release?.id != null) {
          tracks = await _apple.getAlbumTracks(
            release!.id!,
            refresh: refresh,
            storefront: Uri.tryParse(release.url)?.pathSegments.firstOrNull,
          );
        } else {
          data = await _apple.getAlbumData(
            album: title,
            artist: artist,
            refresh: refresh,
          );
          // A different release is not a substitute for the requested album.
          if (data != null &&
              (!albumTitlesMatch(data.match.name, title) ||
                  !albumArtistsMatch(artist, data.match.artistName)))
            data = null;
          tracks = data?.tracks ?? const [];
        }
      } catch (_) {}
      var album = data == null
          ? release
          : LokalCatalogueAlbum.fromApple(data.match);
      if (discoveryImageUrl(album?.artwork).isEmpty) {
        String cover = '';
        final client = http.Client();
        try {
          cover =
              await (_albumArtwork?.call(title, artist) ??
                      DiscoveryArtworkResolver(DiscoveryHttp(client)).resolve(
                        DiscoveryArtworkRequest(
                          kind: DiscoveryArtworkKind.album,
                          title: title,
                          artist: artist,
                        ),
                      ))
                  .timeout(const Duration(seconds: 8));
        } catch (_) {
        } finally {
          client.close();
        }
        if (album != null || cover.isNotEmpty) {
          album = LokalCatalogueAlbum(
            title: album?.title ?? title,
            artist: album?.artist ?? artist,
            id: album?.id,
            artwork: cover,
            date: album?.date,
            trackCount: album?.trackCount,
            url: album?.url ?? '',
            releaseKind: album?.releaseKind,
          );
        }
      }
      if (tracks.isNotEmpty) {
        final ordered = List<AppleMusicTrack>.of(tracks)
          ..sort((a, b) {
            final disc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
            return disc != 0
                ? disc
                : (a.trackNumber ?? 999).compareTo(b.trackNumber ?? 999);
          });
        return LokalCataloguePage(
          completeAlbum: true,
          url: album?.url ?? '',
          albums: [if (album != null) album],
          tracks: [
            for (final song in ordered)
              LokalCatalogueTrack(
                LokalDiscoveryTrack(
                  title: song.trackName,
                  artist: song.artistName ?? artist,
                  album: title,
                  artworkUrl: album?.artwork ?? '',
                  duration: song.durationMs == null
                      ? null
                      : Duration(milliseconds: song.durationMs!),
                ),
                number: song.trackNumber,
                disc: song.discNumber,
              ),
          ],
        );
      }
      final found = await _search(
        '$title ${splitArtistCredits(artist).firstOrNull ?? artist}',
        artist: artist,
        album: title,
      );
      return LokalCataloguePage(
        tracks: found.$1,
        label: found.$2,
        albums: [if (album != null) album],
        url: album?.url ?? '',
      );
    },
  );

  /// A source search is a fallback, not an authoritative full-album tracklist.
  Future<(List<LokalCatalogueTrack>, String)> _search(
    String query, {
    required String artist,
    String? album,
  }) async {
    final client = http.Client();
    final clock = Stopwatch()..start();
    try {
      for (final source in await _sources(client)) {
        final remaining = const Duration(seconds: 20) - clock.elapsed;
        if (remaining <= Duration.zero) break;
        try {
          final results = await source
              .results(query)
              .timeout(
                remaining < const Duration(seconds: 10)
                    ? remaining
                    : const Duration(seconds: 10),
              );
          final unique = <String, LokalCatalogueTrack>{};
          for (final result in results) {
            final song = result.track;
            if (!albumArtistsMatch(artist, song.artist)) continue;
            if (album != null && !albumTitlesMatch(song.album ?? '', album))
              continue;
            final metadata = LokalDiscoveryTrack(
              title: song.title,
              artist: song.artist,
              album: song.album ?? '',
              duration: song.duration,
              artworkUrl: result.artwork ?? '',
            );
            unique.putIfAbsent(
              metadata.key,
              () => LokalCatalogueTrack(
                metadata,
                sourceId: source.id,
                exact: song,
              ),
            );
          }
          if (unique.isNotEmpty) return (unique.values.toList(), source.name);
        } catch (_) {}
      }
      return (const <LokalCatalogueTrack>[], 'Online');
    } finally {
      client.close();
    }
  }
}

/// Catalogue metadata is never a stream URL. Resolve through the current,
/// configured playback sources; an explicit source choice is not substituted.
Future<Song?> prepareCatalogueTrack(
  LokalCatalogueTrack track, {
  String? playbackSource,
  void Function(String)? onStatus,
  Future<void>? cancel,
}) async {
  final sourceId = playbackSource;
  if (sourceId == null)
    return findDiscoverySong(
      track.metadata,
      onStatus: onStatus,
      cancel: cancel,
    );
  if (track.exact != null && sourceId == track.sourceId)
    return playOnlineTrack(
      sourceId,
      track.exact!,
      onStatus: onStatus,
      cancel: cancel,
    );
  final client = http.Client();
  try {
    final sources = await onlineSources(client, onStatus: onStatus);
    final source = sources.where((s) => s.id == sourceId).firstOrNull;
    if (source == null)
      throw const DiscoveryException(
        'The selected playback source is unavailable.',
      );
    final rows = await source
        .search('${track.metadata.artist} ${track.metadata.title}')
        .timeout(const Duration(seconds: 15));
    final found = recommendationMatch(
      discoveryCandidate(track.metadata),
      rows,
      (row) => RecommendationCandidate(
        title: row.title,
        artist: row.artist,
        album: row.album,
        duration: row.duration,
      ),
    );
    if (found == null)
      throw const DiscoveryException(
        'This recording was not found on the selected source.',
      );
    return await playOnlineTrack(
      sourceId,
      found.withArtwork(track.metadata.artworkUrl),
      onStatus: onStatus,
      cancel: cancel,
    );
  } finally {
    client.close();
  }
}
