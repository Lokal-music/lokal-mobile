import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'spotify_models.dart';
import 'spotify_oauth.dart';
import 'spotify_storage.dart';
import 'spotify_http.dart';

class SpotifyApiException implements Exception {
  const SpotifyApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

typedef SpotifyDelay = Future<void> Function(Duration duration);

abstract interface class SpotifyLibraryApi {
  Future<List<SpotifyPlaylist>> getPlaylists({
    void Function(int loaded)? onProgress,
    SpotifyCancellation? cancellation,
  });
  Future<List<SpotifyTrack>> getPlaylistTracks(
    String playlistId, {
    void Function(int loaded)? onProgress,
    SpotifyCancellation? cancellation,
  });
  Future<List<SpotifyTrack>> getLikedSongs({
    void Function(int loaded)? onProgress,
    SpotifyCancellation? cancellation,
  });
}

class SpotifyApi implements SpotifyLibraryApi {
  SpotifyApi({
    required this._tokenStore,
    required this._oauth,
    http.Client? client,
    SpotifyDelay? delay,
  }) : _delay = delay ?? ((duration) => Future<void>.delayed(duration)),
       _http = SpotifyHttp(client ?? http.Client());

  static final apiOrigin = Uri.parse('https://api.spotify.com');
  static const _pageSize = 50;
  static const _trackPageSize = 50;
  static const _max429Retries = 2;

  /// Construct a read-only catalogue client using the existing encrypted
  /// Spotify cookie-backed session and the same refresh implementation.
  static SpotifyApi withCredentials(
    SpotifyTokenStore store, SpotifyOAuthService oauth,
  ) => SpotifyApi(_tokenStore: store, _oauth: oauth);

  void close() => _http.client.close();

  final SpotifyTokenStore _tokenStore;
  final SpotifyOAuthService _oauth;
  final SpotifyHttp _http;
  final SpotifyDelay _delay;

  /// Reads an authenticated Spotify Web API JSON resource while retaining the
  /// same-origin, refresh, cancellation and rate-limit guards as library
  /// pagination.
  Future<Map<String, dynamic>> getJson(
    Uri url, {
    SpotifyCancellation? cancellation,
  }) =>
      _getJson(url, cancellation: cancellation);

  @override
  Future<List<SpotifyPlaylist>> getPlaylists({
    void Function(int loaded)? onProgress,
    SpotifyCancellation? cancellation,
  }) async {
    final pages = await _collectPages<SpotifyPlaylist>(
      initial: Uri.parse(
        'https://api.spotify.com/v1/me/playlists?limit=$_pageSize&offset=0',
      ),
      parse: _parsePlaylistPage,
      onProgress: onProgress,
      cancellation: cancellation,
    );
    return pages;
  }

  @override
  Future<List<SpotifyTrack>> getPlaylistTracks(
    String playlistId, {
    void Function(int loaded)? onProgress,
    SpotifyCancellation? cancellation,
  }) async {
    _validateId(playlistId, 'playlist');
    return _collectPages<SpotifyTrack>(
      initial: Uri.parse(
        'https://api.spotify.com/v1/playlists/${Uri.encodeComponent(playlistId)}/tracks?limit=$_trackPageSize&offset=0',
      ),
      parse: _parseTrackPage,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  @override
  Future<List<SpotifyTrack>> getLikedSongs({
    void Function(int loaded)? onProgress,
    SpotifyCancellation? cancellation,
  }) {
    return _collectPages<SpotifyTrack>(
      initial: Uri.parse(
        'https://api.spotify.com/v1/me/tracks?limit=$_trackPageSize&offset=0',
      ),
      parse: _parseTrackPage,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  Future<List<T>> _collectPages<T>({
    required Uri initial,
    required List<T> Function(Map<String, dynamic>) parse,
    void Function(int loaded)? onProgress,
    SpotifyCancellation? cancellation,
  }) async {
    final collected = <T>[];
    var next = initial;
    var pageCount = 0;
    while (true) {
      if (++pageCount > 10000) {
        throw const SpotifyApiException(
          'Spotify pagination exceeded its safety limit.',
        );
      }
      final payload = await _getJson(next, cancellation: cancellation);
      cancellation?.check();
      final items = parse(payload);
      collected.addAll(items);
      onProgress?.call(collected.length);
      final rawNext = payload['next'];
      if (rawNext is! String || rawNext.isEmpty) break;
      next = _safeNext(rawNext);
    }
    return collected;
  }

  Future<Map<String, dynamic>> _getJson(
    Uri url, {
    SpotifyCancellation? cancellation,
  }) async {
    final safeUrl = _safeApiUrl(url);
    var didRefresh = false;
    var rateLimitRetries = 0;
    while (true) {
      var tokens = await _tokenStore.readTokens();
      cancellation?.check();
      if (tokens == null) {
        throw const SpotifyApiException(
          'Connect Spotify before loading your library.',
        );
      }
      if (tokens.isExpired) {
        tokens = await _oauth.refresh();
        if (tokens == null) {
          throw const SpotifyApiException(
            'Spotify sign-in expired. Connect again.',
          );
        }
      }

      final response = await _http.send(
        safeUrl,
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer ${tokens.accessToken}',
          'App-platform': 'WebPlayer',
          'Origin': 'https://open.spotify.com',
          'Referer': 'https://open.spotify.com/',
          'User-Agent': _webPlayerUserAgent,
          if (tokens.clientToken case final clientToken?)
            'Client-Token': clientToken,
        },
        cancellation: cancellation,
      );
      if (response.statusCode == 401 && !didRefresh) {
        didRefresh = true;
        final refreshed = await _oauth.refresh();
        if (refreshed == null) {
          throw const SpotifyApiException(
            'Spotify sign-in expired. Connect again.',
            statusCode: 401,
          );
        }
        continue;
      }
      if (response.statusCode == 429) {
        if (rateLimitRetries >= _max429Retries) {
          throw const SpotifyApiException(
            'Spotify is rate limiting requests. Try again later.',
            statusCode: 429,
          );
        }
        rateLimitRetries++;
        final retryAfter =
            int.tryParse(response.headers['retry-after'] ?? '1') ?? 1;
        await _delay(Duration(seconds: retryAfter.clamp(0, 30).toInt()));
        cancellation?.check();
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SpotifyApiException(
          'Spotify returned HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      }
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // Do not include response content, tokens, or URLs in the exception.
      }
      throw const SpotifyApiException('Spotify returned invalid JSON.');
    }
  }

  Uri _safeNext(String raw) {
    final next = Uri.tryParse(raw);
    if (next == null || !_sameOrigin(next, apiOrigin)) {
      throw const SpotifyApiException(
        'Spotify returned an unsafe pagination URL.',
      );
    }
    // Pagination URLs may be returned by Spotify, but authorization always
    // comes from the header. Any query token is deliberately discarded.
    final query = Map<String, String>.from(next.queryParameters)
      ..removeWhere((key, _) => key.toLowerCase().contains('token'));
    return next.replace(queryParameters: query);
  }

  Uri _safeApiUrl(Uri url) {
    if (!_sameOrigin(url, apiOrigin) || url.scheme != 'https') {
      throw const SpotifyApiException('Spotify returned an unsafe API URL.');
    }
    return url;
  }

  bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  List<SpotifyPlaylist> _parsePlaylistPage(Map<String, dynamic> json) {
    final rawItems = json['items'];
    if (rawItems is! List) return const [];
    return [
      for (final raw in rawItems)
        if (raw is Map && raw['id'] is String && raw['name'] is String)
          SpotifyPlaylist(
            id: raw['id'] as String,
            name: raw['name'] as String,
            owner: (raw['owner'] as Map?)?['display_name'] as String?,
            imageUrl: _imageUrl(raw['images']),
            tracksTotal:
                ((raw['tracks'] as Map?)?['total'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  List<SpotifyTrack> _parseTrackPage(Map<String, dynamic> json) {
    final rawItems = json['items'];
    if (rawItems is! List) return const [];
    final tracks = <SpotifyTrack>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final track = raw['track'];
      final data = track is Map ? track : raw;
      final id = data['id'];
      final title = data['name'];
      if (id is! String || title is! String || id.isEmpty || title.isEmpty) {
        continue;
      }
      final artists = data['artists'];
      final artist = artists is List
          ? artists
                .whereType<Map>()
                .map((item) => item['name'])
                .whereType<String>()
                .where((name) => name.isNotEmpty)
                .join(', ')
          : '';
      final albumData = data['album'];
      tracks.add(
        SpotifyTrack(
          id: id,
          title: title,
          artist: artist,
          album: albumData is Map ? albumData['name'] as String? : null,
          durationMs: (data['duration_ms'] as num?)?.toInt() ?? 0,
          imageUrl: albumData is Map ? _imageUrl(albumData['images']) : null,
        ),
      );
    }
    return tracks;
  }

  static const _webPlayerUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/122.0.0.0 Safari/537.36';

  String? _imageUrl(Object? images) {
    if (images is! List) return null;
    for (final image in images) {
      if (image is Map && image['url'] is String) return image['url'] as String;
    }
    return null;
  }

  void _validateId(String value, String label) {
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(value)) {
      throw SpotifyApiException('Invalid Spotify $label ID.');
    }
  }
}
