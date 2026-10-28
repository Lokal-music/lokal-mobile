import 'dart:io';
import 'dart:convert';

import 'youtube_music_account.dart' show youtubeMusicPageObject;

import 'package:flutter/foundation.dart';

import 'discovery_http.dart';
import 'discovery_models.dart';

class YoutubeMusicCatalog {
  YoutubeMusicCatalog(this.http, {this.refreshClientContext = false});
  final bool refreshClientContext;
  Future<Map<String, dynamic>>? _pageContext;
  final DiscoveryHttp http;

  Future<Map<String, dynamic>> _loadPageContext() async {
    try {
      final response = await http.client
          .get(
            Uri.https('music.youtube.com', '/'),
            headers: {
              'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
              'Accept-Language': 'en-US,en;q=0.9',
            },
          )
          .timeout(http.timeout);
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 8 * 1024 * 1024)
        return {};
      return youtubeMusicPageObject(utf8.decode(response.bodyBytes), 'ytcfg') ??
          {};
    } catch (_) {
      return {};
    }
  }

  Future<List<DiscoveryTrack>> search(String query) async {
    if (query.trim().isEmpty) return [];
    return parse(await rawSearch(query));
  }

  /// YouTube Music's videos filter (desktop's VIDEOS_PARAMS).
  static const videosFilter = 'EgWKAQIQAWoMEA4QChADEAQQCRAF';
  static const _songsFilter = 'EgWKAQIIAWoKEAkQChAFEAMQBA==';

  /// The search response itself, songs filter unless [params] names another.
  Future<Map<String, dynamic>> rawSearch(
    String query, {
    String params = _songsFilter,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length > 200) {
      throw const DiscoveryException('Search is limited to 200 characters.');
    }
    // Guest WEB_REMIX, using the songs filter from Konnekted's shared
    // Innertube client. No cookies, account impersonation or stream extraction.
    final config = refreshClientContext
        ? await (_pageContext ??= _loadPageContext())
        : <String, dynamic>{};
    final context = config['INNERTUBE_CONTEXT'];
    final client = context is Map && context['client'] is Map
        ? (context['client'] as Map).cast<String, Object?>()
        : <String, Object?>{};
    final version =
        config['INNERTUBE_CLIENT_VERSION']?.toString() ?? '1.20250101.01.00';
    final response = await http.json(
      Uri.https('music.youtube.com', '/youtubei/v1/search', {
        'prettyPrint': 'false',
      }),
      headers: {
        'Origin': 'https://music.youtube.com',
        'X-YouTube-Client-Name': '67',
        'X-YouTube-Client-Version': version,
      },
      body: {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            ...client,
            'clientVersion': version,
            if (config['VISITOR_DATA'] != null)
              'visitorData': config['VISITOR_DATA'],
            'hl': 'en',
            'gl': 'US',
          },
        },
        'query': trimmed,
        'params': params,
      },
    );
    return response;
  }

  static List<DiscoveryTrack> parse(Map<String, dynamic> response) {
    if (response['error'] != null || response['contents'] is! Map) {
      throw const DiscoveryException(
        'YouTube Music returned an unsupported catalog response.',
      );
    }
    final results = <String, DiscoveryTrack>{};
    var nodes = 0;
    void walk(Object? value, int depth) {
      if (++nodes > 30000 || depth > 40) {
        throw const DiscoveryException('The catalog response is too complex.');
      }
      if (value is Map) {
        final row = value['musicResponsiveListItemRenderer'];
        if (row is Map) {
          final columns = row['flexColumns'];
          final titleRuns = columns is List && columns.isNotEmpty
              ? _runs(
                  _path(columns.first, [
                    'musicResponsiveListItemFlexColumnRenderer',
                    'text',
                  ]),
                )
              : <Map>[];
          final title = discoveryText(
            titleRuns.map((r) => r['text'] is String ? r['text'] : '').join(),
          );
          Object? rawId =
              _path(row, ['playlistItemData', 'videoId']) ??
              _path(row, ['navigationEndpoint', 'watchEndpoint', 'videoId']);
          for (final run in titleRuns) {
            rawId ??= _path(run, [
              'navigationEndpoint',
              'watchEndpoint',
              'videoId',
            ]);
          }
          final id = discoveryText(rawId, maxLength: 11);
          if (id != null &&
              RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) &&
              title != null) {
            final artists = <String>[];
            String? album;
            Duration? duration;
            if (columns is List) {
              for (final column in columns.skip(1)) {
                for (final run in _runs(
                  _path(column, [
                    'musicResponsiveListItemFlexColumnRenderer',
                    'text',
                  ]),
                )) {
                  final text = discoveryText(run['text']);
                  if (text == null) continue;
                  final browse = _path(run, [
                    'navigationEndpoint',
                    'browseEndpoint',
                    'browseId',
                  ]);
                  if (browse is String && browse.startsWith('UC')) {
                    artists.add(text);
                  }
                  if (browse is String && browse.startsWith('MPRE')) {
                    album = text;
                  }
                  duration ??= _clock(text);
                }
              }
              // Guest responses sometimes provide plain text without artist
              // endpoints. Only the first metadata run is the artist fallback.
              if (artists.isEmpty && columns.length > 1) {
                final runs = _runs(
                  _path(columns[1], [
                    'musicResponsiveListItemFlexColumnRenderer',
                    'text',
                  ]),
                );
                if (runs.isNotEmpty) {
                  final first = discoveryText(runs.first['text']);
                  if (first != null &&
                      _clock(first) == null &&
                      first != 'Song') {
                    artists.add(first);
                  }
                }
              }
            }
            final fixed = row['fixedColumns'];
            if (fixed is List) {
              for (final column in fixed) {
                for (final run in _runs(
                  _path(column, [
                    'musicResponsiveListItemFixedColumnRenderer',
                    'text',
                  ]),
                )) {
                  duration ??= _clock(run['text']);
                }
              }
            }
            if (results.length < 50) {
              results.putIfAbsent(
                id,
                () => DiscoveryTrack(
                  id: id,
                  title: title,
                  artist: artists.isEmpty
                      ? 'Artist not supplied'
                      : artists.toSet().join(', '),
                  source: DiscoverySource.youtubeMusic,
                  sourceUrl: Uri.https('music.youtube.com', '/watch', {
                    'v': id,
                  }),
                  album: album,
                  duration: duration,
                  artwork: thumbnail(row),
                ),
              );
            }
          }
        }
        for (final child in value.values) {
          walk(child, depth + 1);
        }
      } else if (value is List) {
        for (final child in value) {
          walk(child, depth + 1);
        }
      }
    }

    walk(response['contents'], 0);
    return results.values.toList(growable: false);
  }

  /// The row's cover: the largest https thumbnail, requested at 1200 px
  /// on Google's resizable artwork CDN (YouTube Music often sends 60/120 px).
  @visibleForTesting
  static String? thumbnail(Map row) {
    final list = _path(row, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails',
    ]);
    if (list is! List) return null;
    String? best;
    var width = -1;
    for (final item in list.whereType<Map>()) {
      final url = discoveryText(item['url'], maxLength: 2000);
      final uri = url == null ? null : Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) continue;
      final w = item['width'] is num ? (item['width'] as num).toInt() : 0;
      if (w > width) {
        width = w;
        best = url;
      }
    }
    if (best == null) return null;
    final host = Uri.parse(best).host;
    // Retain the provider's original thumbnail. Shared artwork widgets and
    // download caches request the higher-resolution variant first, but must
    // still be able to fall back if it is missing or exceeds the size limit.
    return best;
  }

  static Object? _path(Object? value, List<String> keys) {
    for (final key in keys) {
      if (value is! Map) return null;
      value = value[key];
    }
    return value;
  }

  static List<Map> _runs(Object? value) => value is Map && value['runs'] is List
      ? (value['runs'] as List).whereType<Map>().toList()
      : [];

  static Duration? _clock(Object? value) {
    if (value is! String ||
        !RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(value)) {
      return null;
    }
    final parts = value.split(':').map(int.parse).toList();
    if (parts.skip(1).any((p) => p >= 60)) return null;
    return discoveryDuration(parts.fold<int>(0, (a, b) => a * 60 + b));
  }
}

/// Supported manifest option for an HTTP add-on select setting.
class AddonSettingOption {
  const AddonSettingOption(this.value, this.label);
  final String value;
  final String label;
}

class AddonSetting {
  const AddonSetting(this.key, this.label, this.defaultValue, this.options);
  final String key;
  final String label;
  final String defaultValue;
  final List<AddonSettingOption> options;

  static List<AddonSetting> parse(Object? raw) {
    if (raw is! List) return const [];
    final result = <AddonSetting>[];
    final used = <String>{};
    for (final entry in raw.take(16)) {
      if (entry is! Map) continue;
      final key = discoveryText(entry['key'], maxLength: 40);
      if (key == null ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(key) ||
          key == 'q' ||
          !used.add(key)) continue;
      // Select controls declare an explicit finite set of values.
      final rawOptions = entry['options'];
      if (rawOptions is! List) continue;
      final options = <AddonSettingOption>[];
      final values = <String>{};
      for (final item in rawOptions.take(32)) {
        if (item is! Map) continue;
        final value = discoveryText(item['value'], maxLength: 120);
        if (value == null ||
            RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value) ||
            !values.add(value)) continue;
        options.add(AddonSettingOption(
          value,
          discoveryText(item['label'], maxLength: 80) ?? value,
        ));
      }
      if (options.isEmpty) continue;
      final requestedDefault = discoveryText(entry['default'], maxLength: 120);
      final defaultValue = values.contains(requestedDefault)
          ? requestedDefault!
          : options.first.value;
      result.add(AddonSetting(
        key,
        discoveryText(entry['label'], maxLength: 80) ?? key,
        defaultValue,
        List.unmodifiable(options),
      ));
    }
    return List.unmodifiable(result);
  }
}

class AddonHealth {
  const AddonHealth(this.name, {
    required this.cacheAllowed,
    this.settings = const [],
  });
  final String name;
  final bool cacheAllowed;
  final List<AddonSetting> settings;
}

class ResolvedDiscoveryAudio {
  const ResolvedDiscoveryAudio(
    this.url, {
    this.length,
    this.headers = const {},
    this.codec,
    this.bitrate,
    this.quality,
    this.bitDepth,
    this.sampleRate,
  });
  final Uri url;
  /// Resolved stream metadata, never inferred from a catalogue maximum.
  final String? codec;
  /// Bits per second for the exact selected rendition, when the resolver knows it.
  final int? bitrate;
  /// Resolver-advertised details of the selected rendition (not native-probed).
  final String? quality;
  final int? bitDepth;
  final int? sampleRate;

  /// The file's size when it must be fetched in parts (YouTube serves big
  /// single requests slowly): each part asks for a `range` of it.
  final int? length;

  /// Headers the media host expects, e.g. the client's own User-Agent.
  final Map<String, String> headers;
}

/// Return only numerical sample rates explicitly supplied by a provider.
int? providerAudioInteger(Map<String, dynamic> row, List<String> keys,
    {int min = 1, int max = 768000}) {
  for (final key in keys) {
    final raw = row[key];
    final n = raw is num ? raw.toInt()
        : raw is String ? int.tryParse(raw.trim()) : null;
    if (n != null && n >= min && n <= max) return n;
  }
  return null;
}

/// Sample-rate fields from HTTP providers may use Hz (44100) or kHz
/// (44.1 / "44.1 kHz"). Integer-only parsing drops CD-rate metadata.
int? providerAudioSampleRate(Map<String, dynamic> row) {
  const keys = [
    'sampleRate', 'sample_rate', 'samplingRate', 'sampling_rate',
    'audioSampleRate', 'audio_sample_rate',
  ];
  for (final key in keys) {
    final raw = row[key];
    if (raw == null) continue;
    final text = raw.toString().trim();
    final explicitKhz = RegExp(r'k\s*hz$', caseSensitive: false).hasMatch(text);
    final number = raw is num ? raw.toDouble() : double.tryParse(
      text.replaceFirst(RegExp(r'\s*(?:k\s*hz|hz)\s*$', caseSensitive: false), '').trim(),
    );
    if (number == null || !number.isFinite || number <= 0) continue;
    final hz = (explicitKhz || number < 1000 ? number * 1000 : number).round();
    if (hz >= 8000 && hz <= 768000) return hz;
  }
  return null;
}

String? providerAudioCodec(Map<String, dynamic> row) {
  final value = discoveryText(
      row['codec'] ?? row['audioCodec'] ?? row['audio_codec']
          ?? row['audioFormat'] ?? row['fileType'] ?? row['format']
          ?? row['mimeType'] ?? row['contentType'], maxLength: 80);
  if (value == null) return null;
  final v = value.toLowerCase();
  if (v.contains('flac')) return 'FLAC';
  if (v.contains('alac')) return 'ALAC';
  if (v.contains('opus')) return 'OPUS';
  if (v.contains('vorbis')) return 'VORBIS';
  if (v.contains('mp3') || v.contains('mpeg')) return 'MP3';
  if (v.contains('aac') || v.contains('mp4a')) return 'AAC';
  if (v.contains('eac3') || v.contains('ec-3')) return 'E-AC-3';
  return null;
}

/// A valid Qobuz sample CDN URL is not a full-length stream.
class _PreviewOnlyAddonStream extends DiscoveryException {
  const _PreviewOnlyAddonStream()
      : super('The HTTP addon returned a preview instead of full-length audio.');
}

bool _isAddonPreviewStream(
  Map<String, dynamic> response,
  Uri uri,
  Duration? expectedDuration,
) {
  for (final key in const [
    'preview', 'isPreview', 'is_preview',
    'previewOnly', 'preview_only', 'sample', 'isSample',
  ]) {
    if (response[key] == true || response[key] == 'true') return true;
  }
  if (response['fullTrack'] == false ||
      response['full_track'] == false ||
      response['isFullTrack'] == false) return true;

  // Qobuz may respond with HTTP 200 and a 30-second sample URL when
  // full-track access is unavailable.
  final host = uri.host.toLowerCase();
  if (host.endsWith('.qobuz.com') &&
      RegExp(r'^sample\d*$').hasMatch(host.split('.').first)) {
    return true;
  }

  // Only stream-specific length claims can reject a longer catalogue track.
  // Unknown and genuinely short recordings are never rejected on length.
  // Some sources send 0 or an invalid value in an earlier alias.
  // Parse before falling back, rather than allowing that value to hide a
  // later explicit 30-second sample duration.
  Duration? reported;
  for (final key in const [
    'streamDuration', 'stream_duration',
    'durationSeconds', 'duration_seconds', 'duration',
  ]) {
    reported = discoveryDuration(response[key]);
    if (reported != null) break;
  }
  return expectedDuration != null &&
      expectedDuration >= const Duration(seconds: 90) &&
      reported != null &&
      reported <= const Duration(seconds: 60) &&
      reported.inMilliseconds * 2 < expectedDuration.inMilliseconds;
}

/// Reference-compatible, deliberately limited progressive-audio addon client.
/// See README.md for the exact supported protocol and credential boundary.
class DiscoveryAddon {
  DiscoveryAddon(
    this.http, {
    required String endpoint,
    String token = '',
    this.exactManifestUrl,
    this.configId,
    this.displayName = 'Music addon',
    this.settings = const {},
  }) : base = normalizeAddonEndpoint(endpoint),
       _token = token.trim() {
    if (_token.length > 4096 || RegExp(r'[\x00-\x20\x7f]').hasMatch(_token)) {
      throw const DiscoveryException(
        'The bearer token contains invalid characters.',
      );
    }
  }

  final DiscoveryHttp http;
  final Uri base;
  final String _token;
  final Uri? exactManifestUrl;
  final String? configId;
  final String displayName;
  final Map<String, String> settings;

  Uri _endpoint(List<String> suffix, [Map<String, String>? query]) =>
      base.replace(
        pathSegments: [...base.pathSegments, ...suffix],
        queryParameters: query,
      );

  Future<Map<String, dynamic>> _get(
    List<String> suffix, {
    Map<String, String>? query,
    Future<void>? cancel,
  }) => http.json(
    _endpoint(suffix, query),
    headers: {if (_token.isNotEmpty) 'Authorization': 'Bearer $_token'},
    cancel: cancel,
  );

  Future<AddonHealth> health({
    Future<void>? cancel,
    Uri? exactManifestUrl,
  }) async {
    exactManifestUrl ??= this.exactManifestUrl;
    // An installation with an explicit manifest.json URL should verify
    // precisely that URI. The normalized base is retained for subsequent
    // /search and /stream calls, but must not rewrite the initial probe.
    // Never forward bearer credentials to a different origin.
    if (exactManifestUrl != null &&
        (exactManifestUrl.origin != base.origin ||
            exactManifestUrl.pathSegments.lastOrNull != 'manifest.json' ||
            exactManifestUrl.hasQuery ||
            exactManifestUrl.hasFragment ||
            normalizeAddonEndpoint(exactManifestUrl.toString()) != base)) {
      throw const DiscoveryException('Invalid add-on manifest URL.');
    }
    final json = exactManifestUrl == null
        ? await _get(['manifest.json'], cancel: cancel)
        : await http.json(
            exactManifestUrl,
            headers: {if (_token.isNotEmpty) 'Authorization': 'Bearer $_token'},
            cancel: cancel,
          );
    final id = discoveryText(json['id']);
    final resources = json['resources'];
    if (id == null ||
        resources is! List ||
        !resources.contains('search') ||
        !resources.contains('stream')) {
      throw const DiscoveryException(
        'The addon must declare an id and search + stream resources.',
      );
    }
    final flag = json['allowDownloads'];
    // An add-on may prohibit saving while allowing direct streaming.
    // Cache permission is checked only when an explicit download is requested.
    final allowed =
        flag == null ||
        flag == true ||
        flag == 1 ||
        flag == '1' ||
        flag == 'true';
    return AddonHealth(
      discoveryText(json['name']) ?? id,
      cacheAllowed: allowed,
      settings: AddonSetting.parse(json['settings']),
    );
  }

  Future<List<DiscoveryTrack>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];
    if (trimmed.length > 200) {
      throw const DiscoveryException('Search is limited to 200 characters.');
    }
    final json = await _get(['search'], query: {...settings, 'q': trimmed});
    final rows = json['tracks'];
    if (rows is! List) {
      throw const DiscoveryException(
        'The addon search response must contain a tracks array.',
      );
    }
    final tracks = <String, DiscoveryTrack>{};
    for (final row in rows.take(500)) {
      if (row is! Map<String, dynamic>) continue;
      final id = discoveryText(row['id'], maxLength: 1024);
      final title = discoveryText(row['title']);
      if (id == null || title == null || id == '.' || id == '..') continue;
      Uri? sourceUrl;
      final source = discoveryText(row['sourceURL'], maxLength: 8192);
      if (source != null) {
        try {
          sourceUrl = requireHttps(source);
        } on DiscoveryException {
          /* optional metadata */
        }
      }
      // BitChord's wire format uses artworkURL and albumArtworkURL.
      // Invalid/unsafe URLs must not be fetched by the player.
      String? artwork;
      for (final key in [
        'artworkURL', 'albumArtworkURL', 'artworkUrl',
        'albumArtworkUrl', 'coverUrl', 'thumbnailUrl',
      ]) {
        final candidate = discoveryText(row[key], maxLength: 8192);
        if (candidate == null) continue;
        try {
          final imageUrl = requireHttps(candidate);
          // The configured add-on itself may be on a private network, but an
          // arbitrary search result must not point the image fetch at a
          // different local/private host.
          if (imageUrl.origin != base.origin) {
            final host = imageUrl.host.toLowerCase();
            if (InternetAddress.tryParse(host) != null ||
                !host.contains('.') ||
                host.endsWith('.') ||
                const [
                  '.localhost', '.local', '.internal', '.lan', '.home',
                ].any(host.endsWith)) continue;
          }
          artwork = imageUrl.toString();
          break;
        } on DiscoveryException {
          // Artwork is optional; an invalid URL never fails the search.
        }
      }
      tracks.putIfAbsent(
        id,
        () => DiscoveryTrack(
          id: id,
          title: title,
          artist: discoveryText(row['artist']) ?? 'Artist not supplied',
          album: discoveryText(row['album']),
          duration: discoveryDuration(row['duration']),
          source: DiscoverySource.addon,
          addonBase: base,
          addonId: configId,
          sourceName: displayName,
          sourceUrl: sourceUrl,
          artwork: artwork,
          catalogueQuality: discoveryText(row['audioQuality'] ??
              row['audio_quality'] ?? row['quality'], maxLength: 40),
          catalogueCodec: providerAudioCodec(row),
          catalogueBitDepth: providerAudioInteger(
              row, const ['bitDepth', 'bit_depth', 'bitsPerSample', 'bits_per_sample'],
              min: 8, max: 64),
          catalogueSampleRate: providerAudioSampleRate(row),
          // Retain security-relevant fields with inline URLs, not just the URL.
          inlineStream: row['streamURL'] == null
              ? null
              : {...row, 'url': row['streamURL']},
        ),
      );
      if (tracks.length == 50) break;
    }
    if (rows.isNotEmpty && tracks.isEmpty) {
      throw const DiscoveryException(
        'The addon returned tracks without usable ids and titles.',
      );
    }
    return tracks.values.toList(growable: false);
  }

  Future<ResolvedDiscoveryAudio> resolve(
    DiscoveryTrack track, {
    Future<void>? cancel,
    bool forDownload = false,
  }) async {
    if (track.source != DiscoverySource.addon ||
        track.addonId != configId ||
        track.addonBase != base ||
        track.id.isEmpty ||
        track.id.length > 1024 ||
        track.id == '.' ||
        track.id == '..') {
      throw const DiscoveryException(
        'This result belongs to a different source. Search again.',
      );
    }
    // Search has already selected a configured, identity-checked add-on.
    // Fetching its manifest *again* before every streaming playback adds an
    // unrelated network round-trip to first audio (especially Qobuz HTTP).
    // Saving still reads the current manifest to enforce allowDownloads.
    if (forDownload) {
      final manifest = await health(cancel: cancel);
      if (!manifest.cacheAllowed) {
        throw const DiscoveryException(
          'This addon disallows saving or downloading audio.',
        );
      }
    }
    // A search result can embed a Qobuz sample URL. Discard only recognized
    // previews and request a fresh full stream from the add-on endpoint.
    // Unsafe, encrypted or DRM inline responses still fail closed.
    if (track.inlineStream case final inline?) {
      try {
        return parseStream(inline, expectedDuration: track.duration);
      } on _PreviewOnlyAddonStream {
        // Give the full stream endpoint one opportunity to replace a preview.
      }
    }
    return parseStream(
      await _get(['stream', track.id], query: settings, cancel: cancel),
      expectedDuration: track.duration,
    );
  }

  ResolvedDiscoveryAudio parseStream(
    Map<String, dynamic> json, {
    Duration? expectedDuration,
  }) {
    if (json['error'] != null) {
      throw const DiscoveryException(
        'The addon could not resolve this recording.',
      );
    }
    if (json['encrypted'] != null && json['encrypted'] != false) {
      throw const DiscoveryException(
        'Encrypted audio is not supported by this adapter.',
      );
    }
    if (json['drm'] != null && json['drm'] != false) {
      throw const DiscoveryException(
        'DRM audio is not supported by this adapter.',
      );
    }
    if (json['headers'] != null &&
        !(json['headers'] is Map && (json['headers'] as Map).isEmpty)) {
      throw const DiscoveryException(
        'Use a signed media URL; custom media headers are not supported.',
      );
    }
    final url = discoveryText(json['url'], maxLength: 8192);
    if (url == null) {
      throw const DiscoveryException('The addon returned no playable URL.');
    }
    final uri = requireHttps(url);
    if (_isAddonPreviewStream(json, uri, expectedDuration)) {
      throw const _PreviewOnlyAddonStream();
    }
    for (final key in [
      'manifest',
      'mediaType',
      'format',
      'container',
      'containerFormat',
      'mimeType',
    ]) {
      final value = json[key];
      if (value != null && value is! String) {
        throw const DiscoveryException(
          'The addon returned invalid transport metadata.',
        );
      }
      if (value is String &&
          RegExp(
            r'hls|dash|mpegurl|m3u8|mpd',
            caseSensitive: false,
          ).hasMatch(value)) {
        throw const DiscoveryException(
          'This source uses HLS/DASH. A progressive audio file is required.',
        );
      }
    }
    if (RegExp(r'\.(m3u8|mpd)$', caseSensitive: false).hasMatch(uri.path)) {
      throw const DiscoveryException(
        'A playlist URL cannot be played as an audio file.',
      );
    }
    // An explicitly configured LAN addon may serve its own media. An addon
    // cannot redirect the downloader to a different literal/private host.
    if (uri.origin != base.origin) {
      final host = uri.host.toLowerCase();
      if (InternetAddress.tryParse(host) != null ||
          !host.contains('.') ||
          host.endsWith('.') ||
          [
            '.localhost',
            '.local',
            '.internal',
            '.lan',
            '.home',
          ].any(host.endsWith)) {
        throw const DiscoveryException(
          'The addon returned a disallowed media host.',
        );
      }
    }
    return ResolvedDiscoveryAudio(
      uri,
      codec: providerAudioCodec(json),
      quality: discoveryText(
        json['audioQuality'] ?? json['audio_quality'] ?? json['quality'],
        maxLength: 80,
      ),
      bitDepth: providerAudioInteger(
        json, const ['bitDepth', 'bit_depth', 'bitsPerSample', 'bits_per_sample'],
        min: 8, max: 64,
      ),
      sampleRate: providerAudioSampleRate(json),
    );
  }
}
