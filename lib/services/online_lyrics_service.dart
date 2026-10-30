import 'lyrics_matching.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flick/core/constants/app_constants.dart';
import 'package:http/http.dart' as http;

class OnlineLyricsResult {
  final int id;
  final String? trackName;
  final String? artistName;
  final String? albumName;
  final double? duration;
  final bool instrumental;
  final String? plainLyrics;
  final String? syncedLyrics;

  const OnlineLyricsResult({
    required this.id,
    this.trackName,
    this.artistName,
    this.albumName,
    this.duration,
    required this.instrumental,
    this.plainLyrics,
    this.syncedLyrics,
  });

  factory OnlineLyricsResult.fromJson(Map<String, dynamic> json) {
    return OnlineLyricsResult(
      id: json['id'] as int,
      trackName: json['trackName'] as String?,
      artistName: json['artistName'] as String?,
      albumName: json['albumName'] as String?,
      duration: (json['duration'] as num?)?.toDouble(),
      instrumental: json['instrumental'] as bool? ?? false,
      plainLyrics: json['plainLyrics'] as String?,
      syncedLyrics: json['syncedLyrics'] as String?,
    );
  }

  bool get hasSyncedLyrics =>
      syncedLyrics != null && syncedLyrics!.trim().isNotEmpty;
  bool get hasPlainLyrics =>
      plainLyrics != null && plainLyrics!.trim().isNotEmpty;

  String get bestLyrics => hasSyncedLyrics ? syncedLyrics! : plainLyrics ?? '';

  int get lineCount {
    final text = bestLyrics;
    if (text.isEmpty) return 0;
    return text.split('\n').where((l) => l.trim().isNotEmpty).length;
  }

  String? get snippet {
    final text = bestLyrics;
    if (text.isEmpty) return null;
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return null;
    // Strip LRC tags for snippet
    final clean = lines
        .map(
          (l) => l.replaceAll(RegExp(r'\[\d{2}:\d{2}\.\d{2,3}\]'), '').trim(),
        )
        .where((l) => l.isNotEmpty)
        .toList();
    if (clean.isEmpty) return null;
    if (clean.length <= 2) return clean.join('\n');
    return clean.take(3).join('\n');
  }

  bool get isSyncedOnly => hasSyncedLyrics && !hasPlainLyrics;
  bool get isPlainOnly => hasPlainLyrics && !hasSyncedLyrics;

  String get formatLabel {
    if (instrumental) return 'Instrumental';
    if (hasSyncedLyrics) return 'Synced LRC';
    if (hasPlainLyrics) return 'Plain Text';
    return 'Unknown';
  }

  String get shortFormatLabel {
    if (instrumental) return 'Inst';
    if (hasSyncedLyrics) return 'LRC';
    if (hasPlainLyrics) return 'TXT';
    return '?';
  }
}

/// A response from LRCLIB that was not a successful lyrics lookup.
class OnlineLyricsHttpException implements Exception {
  const OnlineLyricsHttpException(this.statusCode, {this.retryAfter});

  final int statusCode;
  final Duration? retryAfter;

  @override
  String toString() => 'LRCLIB HTTP $statusCode';
}

class OnlineLyricsService {
  static const String _baseUrl = 'https://lrclib.net/api';
  static const Duration _requestTimeout = Duration(seconds: 8);
  static const int _maxCacheEntries = 50;
  static const Duration _maxRetryDelay = Duration(seconds: 5);
  // LRCLIB requires an identifiable app/version/project User-Agent.
  static const Map<String, String> _headers = {
    'Accept': 'application/json',
    'User-Agent': 'Lokal-Mobile/$kAppVersion (https://github.com/lokal-music/lokal-mobile)',
  };

  // Static so state survives per-sheet instance recreation — same singleton
  // idiom as album_art_import_service.
  static final http.Client _client = http.Client();
  static final Map<String, OnlineLyricsResult?> _exactCache = {};
  static final Map<String, List<OnlineLyricsResult>> _searchCache = {};

  OnlineLyricsService({
    http.Client? client,
    Future<void> Function(Duration)? delay,
  }) : _http = client ?? _client,
       _delay = delay ?? ((duration) => Future<void>.delayed(duration));

  final http.Client _http;
  final Future<void> Function(Duration) _delay;

  static Duration? _retryAfter(http.Response response) {
    final header = response.headers['retry-after']?.trim();
    if (header == null || header.isEmpty) return null;
    final seconds = int.tryParse(header);
    if (seconds != null) {
      return Duration(seconds: seconds < 0 ? 0 : seconds);
    }
    try {
      final remaining = HttpDate.parse(header).difference(DateTime.now().toUtc());
      return remaining.isNegative ? Duration.zero : remaining;
    } catch (_) {
      // An invalid Retry-After header must not become a parsing failure.
      return null;
    }
  }

  /// Retry a busy/rate-limited search once, only when Retry-After is short.
  /// Longer server-requested waits must not be silently ignored.
  Future<http.Response> _searchRequest(Uri uri) async {
    for (var attempt = 0; ; attempt++) {
      final response = await _http
          .get(uri, headers: _headers)
          .timeout(_requestTimeout);
      if (attempt > 0 ||
          (response.statusCode != 429 && response.statusCode != 503)) {
        return response;
      }
      final wait = _retryAfter(response) ?? const Duration(seconds: 1);
      if (wait > _maxRetryDelay) return response;
      await _delay(wait);
    }
  }

  /// Explicit playback search refresh also retries previously cached misses.
  static void clearLookupCache() {
    _exactCache.clear();
    _searchCache.clear();
  }

  static String _norm(String? s) =>
      (s ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  String _exactCacheKey({
    required String artist,
    required String title,
    String? album,
    Duration? duration,
  }) {
    return 'exact|${_norm(artist)}|${_norm(title)}|${_norm(album)}|'
        '${duration?.inSeconds ?? 0}';
  }

  String _searchCacheKey({
    String? query,
    String? artist,
    String? title,
    String? album,
  }) {
    final parts = <String>['search'];
    if (query != null && query.isNotEmpty) parts.add('q=${_norm(query)}');
    if (artist != null && artist.isNotEmpty) parts.add('a=${_norm(artist)}');
    if (title != null && title.isNotEmpty) parts.add('t=${_norm(title)}');
    if (album != null && album.isNotEmpty) parts.add('al=${_norm(album)}');
    return parts.join('|');
  }

  void _put<T>(Map<String, T> cache, String key, T value) {
    cache[key] = value;
    // ponytail: FIFO eviction, not true LRU — fine at this volume.
    while (cache.length > _maxCacheEntries) {
      cache.remove(cache.keys.first);
    }
  }

  /// Exact request then a duration-constrained search, as desktop does.
  Future<OnlineLyricsResult?> fetchBest({
    required String artist,
    required String title,
    String? album,
    Duration? duration,
  }) async {
    final cleanTitle = lyricsSearchTitle(title),
        cleanArtist = lyricsSearchArtist(artist);
    final exact = await fetchExact(
      artist: artist,
      title: title,
      album: album,
      duration: duration,
    );
    bool near(OnlineLyricsResult row) =>
        duration == null ||
        duration.inSeconds == 0 ||
        row.duration == null ||
        (row.duration! - duration.inMilliseconds / 1000).abs() <= 5;
    if (exact != null &&
        near(exact) &&
        (exact.hasSyncedLyrics || exact.instrumental))
      return exact;
    final cleanExact = cleanTitle != title || cleanArtist != artist
        ? await fetchExact(
            artist: cleanArtist,
            title: cleanTitle,
            duration: duration,
          )
        : null;
    if (cleanExact != null && near(cleanExact) && cleanExact.hasSyncedLyrics)
      return cleanExact;
    final candidates =
        (await search(artist: cleanArtist, title: cleanTitle))
            .where(
              (row) =>
                  near(row) &&
                  lyricsMatchName(lyricsSearchTitle(row.trackName ?? '')) ==
                      lyricsMatchName(cleanTitle) &&
                  lyricsMatchName(lyricsSearchArtist(row.artistName ?? '')) ==
                      lyricsMatchName(cleanArtist),
            )
            .toList()
          ..sort(
            (a, b) => ((a.duration ?? 0) - (duration?.inSeconds ?? 0))
                .abs()
                .compareTo(
                  ((b.duration ?? 0) - (duration?.inSeconds ?? 0)).abs(),
                ),
          );
    return candidates.where((row) => row.hasSyncedLyrics).firstOrNull ??
        (exact != null && near(exact) ? exact : null) ??
        (cleanExact != null && near(cleanExact) ? cleanExact : null) ??
        candidates.where((row) => row.hasPlainLyrics).firstOrNull;
  }

  Future<OnlineLyricsResult?> fetchExact({
    required String artist,
    required String title,
    String? album,
    Duration? duration,
  }) async {
    final cacheKey = _exactCacheKey(
      artist: artist,
      title: title,
      album: album,
      duration: duration,
    );
    if (_exactCache.containsKey(cacheKey)) return _exactCache[cacheKey];

    final queryParams = <String, String>{
      'track_name': title,
      'artist_name': artist,
    };
    if (album != null && album.isNotEmpty) {
      queryParams['album_name'] = album;
    }
    if (duration != null && duration.inSeconds > 0) {
      queryParams['duration'] = duration.inSeconds.toString();
    }

    final uri = Uri.parse('$_baseUrl/get')
        .replace(queryParameters: queryParams);
    try {
      final response = await _http.get(uri, headers: _headers).timeout(_requestTimeout);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final result = OnlineLyricsResult.fromJson(json);
        _put(_exactCache, cacheKey, result);
        return result;
      }
      // Definitive miss (e.g. 404) — cache it. 5xx is transient, skip caching.
      if (response.statusCode == 404) {
        _put(_exactCache, cacheKey, null);
      }
    } catch (_) {
      // Network/timeout error — do not cache.
    }
    return null;
  }

  Future<List<OnlineLyricsResult>> search({
    String? query,
    String? artist,
    String? title,
    String? album,
    bool refresh = false,
    bool reportErrors = false,
  }) async {
    final cacheKey = _searchCacheKey(
      query: query,
      artist: artist,
      title: title,
      album: album,
    );
    if (!refresh && _searchCache.containsKey(cacheKey))
      return _searchCache[cacheKey]!;

    final queryParams = <String, String>{};
    if (query != null && query.isNotEmpty) {
      queryParams['q'] = query;
    }
    if (artist != null && artist.isNotEmpty) {
      queryParams['artist_name'] = artist;
    }
    if (title != null && title.isNotEmpty) {
      queryParams['track_name'] = title;
    }
    if (album != null && album.isNotEmpty) {
      queryParams['album_name'] = album;
    }

    final uri = Uri.parse('$_baseUrl/search')
        .replace(queryParameters: queryParams);
    try {
      final response = await _searchRequest(uri);
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List<dynamic>;
        final results = list
            .map((e) => OnlineLyricsResult.fromJson(e as Map<String, dynamic>))
            .toList();
        _put(_searchCache, cacheKey, results);
        return results;
      }
      if (reportErrors) {
        throw OnlineLyricsHttpException(
          response.statusCode,
          retryAfter: _retryAfter(response),
        );
      }
      // Never cache a transient HTTP failure (notably 429/503) as a miss.
      if (response.statusCode == 404) {
        _put(_searchCache, cacheKey, const []);
      }
    } catch (_) {
      if (reportErrors) rethrow;
      // Network/timeout error — do not cache.
    }
    return [];
  }
}
