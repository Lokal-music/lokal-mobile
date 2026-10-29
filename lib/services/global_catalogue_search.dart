import 'dart:async';

import 'package:flick/features/spotify/spotify_api.dart';
import 'package:flick/features/spotify/spotify_oauth.dart';
import 'package:flick/features/spotify/spotify_storage.dart';
import 'package:flick/features/spotify/spotify_web_api.dart';
import 'package:flick/services/apple_music/apple_music_metadata_service.dart';
import 'package:flick/services/apple_music/apple_music_models.dart';
import 'package:flick/services/global_catalogue_source.dart';

/// Playback sources and streaming URLs are NEVER part of this model.
class GlobalCatalogueSong {
  const GlobalCatalogueSong({
    required this.catalogueId, required this.title, required this.artist,
    this.album = '', this.artworkUrl = '', this.duration = Duration.zero,
  });

  final String catalogueId;
  final String title;
  final String artist;
  final String album;
  final String artworkUrl;
  final Duration duration;
}

class GlobalCatalogueAlbum {
  const GlobalCatalogueAlbum({required this.name, required this.artist,
    this.artworkUrl = ''});
  final String name;
  final String artist;
  final String artworkUrl;
}

class GlobalCatalogueArtist {
  const GlobalCatalogueArtist({required this.name, this.artworkUrl = ''});
  final String name;
  final String artworkUrl;
}

class GlobalCatalogueMatches {
  const GlobalCatalogueMatches({
    required this.catalogue,
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.notice,
  });
  final String catalogue;
  final List<GlobalCatalogueSong> songs;
  final List<GlobalCatalogueAlbum> albums;
  final List<GlobalCatalogueArtist> artists;
  final String? notice;
}

String _image(dynamic raw) {
  if (raw is! String || !raw.startsWith('https://')) return '';
  return raw;
}

List<Map> _items(dynamic raw) => raw is List ? raw.whereType<Map>().toList() : const [];

/// Both Spotify REST and Pathfinder provide multiple image sizes, sometimes
/// with an empty/invalid first URL. Prefer the largest valid HTTPS image.
String _bestArtwork(dynamic images) {
  String best = '';
  int bestPixels = -1;
  for (final image in _items(images)) {
    final url = _image(image['url']);
    if (url.isEmpty) continue;
    final width = (image['width'] as num?)?.toInt() ?? 0;
    final height = (image['height'] as num?)?.toInt() ?? 0;
    final pixels = width > 0 && height > 0 ? width * height : 0;
    if (best.isEmpty || pixels > bestPixels) {
      best = url;
      bestPixels = pixels;
    }
  }
  return best;
}

String _artistNames(dynamic raw) => _items(raw)
    .map((item) => (item['name'] ?? '').toString().trim())
    .where((name) => name.isNotEmpty).join(', ');

/// Parse Spotify Web API catalogue results without treating its identifiers
/// or 30-second preview links as usable playback audio.
GlobalCatalogueMatches parseSpotifyGlobal(Map<String, dynamic> json) {
  final tracks = (json['tracks'] is Map ? json['tracks']['items'] : null);
  final albums = (json['albums'] is Map ? json['albums']['items'] : null);
  final artists = (json['artists'] is Map ? json['artists']['items'] : null);

  final seen = <String>{};
  return GlobalCatalogueMatches(
    catalogue: GlobalCatalogueSource.spotify,
    songs: [
      for (final item in _items(tracks))
        if (item['id'] != null && item['name'] is String &&
            _artistNames(item['artists']).isNotEmpty &&
            seen.add(item['id'].toString()))
          GlobalCatalogueSong(
            catalogueId: item['id'].toString(),
            title: item['name'] as String,
            artist: _artistNames(item['artists']),
            album: item['album'] is Map ? (item['album']['name'] ?? '').toString() : '',
            artworkUrl: item['album'] is Map ? _bestArtwork(item['album']['images']) : '',
            duration: Duration(milliseconds: (item['duration_ms'] as num?)?.toInt() ?? 0),
          ),
    ],
    albums: [
      for (final item in _items(albums))
        if (item['name'] is String && _artistNames(item['artists']).isNotEmpty)
          GlobalCatalogueAlbum(
            name: item['name'] as String,
            artist: _artistNames(item['artists']),
            artworkUrl: _bestArtwork(item['images']),
          ),
    ],
    artists: [
      for (final item in _items(artists))
        if (item['name'] is String)
          GlobalCatalogueArtist(name: item['name'] as String,
            artworkUrl: _bestArtwork(item['images'])),
    ],
  );
}

GlobalCatalogueMatches parseSpotifyPathfinder(Map<String, dynamic> data) {
  final container = data['searchV2'];
  final rows = container is Map && container['tracksV2'] is Map
      ? container['tracksV2']['items']
      : null;
  final seen = <String>{};
  return GlobalCatalogueMatches(
    catalogue: GlobalCatalogueSource.spotify,
    notice: 'Spotify currently supplies songs only through this session.',
    songs: [
      for (final wrap in _items(rows))
        if (wrap['item'] is Map && wrap['item']['data'] is Map)
          for (final item in [wrap['item']['data'] as Map])
            if (item['uri'] is String &&
                item['name'] is String &&
                seen.add(item['uri'] as String))
              GlobalCatalogueSong(
                catalogueId: (item['uri'] as String).split(':').last,
                title: item['name'] as String,
                artist: item['artists'] is Map
                    ? _items(item['artists']['items'])
                        .map((artist) => artist['profile'] is Map
                            ? (artist['profile']['name'] ?? '').toString() : '')
                        .where((artist) => artist.isNotEmpty).join(', ')
                    : '',
                album: item['albumOfTrack'] is Map
                    ? (item['albumOfTrack']['name'] ?? '').toString() : '',
                artworkUrl: item['albumOfTrack'] is Map &&
                        item['albumOfTrack']['coverArt'] is Map
                    ? _bestArtwork(item['albumOfTrack']['coverArt']['sources'])
                    : '',
                duration: Duration(milliseconds: item['duration'] is Map
                    ? (item['duration']['totalMilliseconds'] as num?)?.toInt() ?? 0
                    : 0),
              ),
    ],
  );
}

/// One metadata-only Global lookup; Spotify reuses the encrypted existing
/// cookie/session. Web API search may refuse cookie-backed tokens; retry its
/// own Pathfinder search before falling back to Apple's public catalogue.
class GlobalCatalogueSearchService {
  const GlobalCatalogueSearchService({this.appleMusic});

  final AppleMusicMetadataService? appleMusic;

  static final _cache = <String, ({DateTime until, GlobalCatalogueMatches value})>{};

  Future<GlobalCatalogueMatches> search(
    String rawQuery, {
    String? selected,
    bool refresh = false,
    bool songsOnly = false,
  }) async {
    final query = rawQuery.trim();
    if (query.length < 2) return const GlobalCatalogueMatches(catalogue: 'apple');
    final source = selected ?? await GlobalCatalogueSource.load();
    final key = (songsOnly ? 'songs:' : 'all:') + source + ':' +
        SecureSpotifyTokenStore.sessionRevision.value.toString() +
        ':' + query.toLowerCase();
    final hit = _cache[key];
    if (!refresh && hit != null && DateTime.now().isBefore(hit.until)) {
      return hit.value;
    }
    if (source == GlobalCatalogueSource.spotify) {
      try {
        final result = await _spotify(query, songsOnly: songsOnly);
        // An empty Spotify search is a valid result, not a signal to
        // silently mix in another catalogue.
        _cache[key] = (until: DateTime.now().add(const Duration(minutes: 2)), value: result);
        if (_cache.length > 75) _cache.remove(_cache.keys.first);
        return result;
      } catch (_) {
        // Never log bearer tokens, cookie values or returned auth bodies.
      }
      final apple = await _apple(query, refresh: refresh, songsOnly: songsOnly);
      return GlobalCatalogueMatches(
        catalogue: GlobalCatalogueSource.apple,
        songs: apple.songs, albums: apple.albums, artists: apple.artists,
        notice: 'Spotify search unavailable. Showing Apple Music results.',
      );
    }
    return _apple(query, refresh: refresh, songsOnly: songsOnly);
  }

  Future<GlobalCatalogueMatches> _spotify(String query, {required bool songsOnly}) async {
    final store = SecureSpotifyTokenStore();
    final oauth = SpotifyOAuthService(tokenStore: store);
    final api = SpotifyApi.withCredentials(store, oauth);
    try {
      final payload = await api.getJson(Uri.https('api.spotify.com', '/v1/search', {
        'q': query, 'type': songsOnly ? 'track' : 'track,album,artist', 'limit': '40',
      })).timeout(const Duration(seconds: 13));
      return parseSpotifyGlobal(payload);
    } catch (_) {
      // Cookie-backed Web Player accounts may reject the public REST API.
      final web = SpotifyWebApi(store: store, oauth: oauth);
      try {
        final data = await web.query('searchTracks', {
          'searchTerm': query, 'offset': 0, 'limit': 40,
          'numberOfTopResults': 5, 'includeAudiobooks': false,
          'includePreReleases': false,
        }).timeout(const Duration(seconds: 13));
        return parseSpotifyPathfinder(data);
      } finally {
        web.close();
      }
    } finally {
      api.close();
    }
  }

  Future<GlobalCatalogueMatches> _apple(String query, {bool refresh = false, required bool songsOnly}) async {
    final service = appleMusic ?? AppleMusicMetadataService.instance;
    final results = await (
      service.searchSongs(query, limit: 40, refresh: refresh),
      songsOnly ? Future.value(<AppleMusicAlbumMatch>[]) :
          service.searchAlbums(query, limit: 12, refresh: refresh),
      songsOnly ? Future.value(<AppleMusicArtist>[]) :
          service.searchArtists(query, limit: 12, refresh: refresh),
    ).wait;
    final (songs, albums, artists) = results;
    return GlobalCatalogueMatches(
      catalogue: GlobalCatalogueSource.apple,
      songs: [
        for (final song in songs)
          GlobalCatalogueSong(
            catalogueId: song.catalogueId, title: song.title,
            artist: song.artist, album: song.album, artworkUrl: song.artworkUrl,
            duration: song.duration,
          ),
      ],
      albums: [
        for (final album in albums)
          GlobalCatalogueAlbum(name: album.name, artist: album.artistName,
            artworkUrl: album.artworkUrl ?? ''),
      ],
      artists: [
        for (final artist in artists)
          GlobalCatalogueArtist(name: artist.name),
      ],
    );
  }
}
