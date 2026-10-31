import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'spotify_api.dart';
import 'spotify_models.dart';
import 'spotify_storage.dart';
import 'spotify_web_api.dart';

/// Spotify playlist metadata is cached by account, never by access token.
/// Access/refresh tokens and the sp_dc cookie never enter SharedPreferences.
/// The single instance keeps decoded lists in memory across screen visits.
class SpotifyPlaylistCache {
  SpotifyPlaylistCache({SpotifySettingsStore? settings, DateTime Function()? now})
      : _settings = settings ?? SpotifySettingsStore(),
        _now = now ?? DateTime.now;

  static final instance = SpotifyPlaylistCache();
  static const cacheKey = 'konnekted.spotify.playlist_library_cache.v1';
  static const updateInterval = Duration(hours: 24);
  static const retryInterval = Duration(hours: 1);

  final SpotifySettingsStore _settings;
  final DateTime Function() _now;
  String? _account;
  Map<String, dynamic>? _state;

  int get _timestamp => _now().millisecondsSinceEpoch;

  Future<String> _fingerprint() async {
    final cookie = (await _settings.tokenStore.readTokens())?.sessionCookie;
    if (cookie == null || cookie.isEmpty) return '';
    return sha256.convert(utf8.encode(cookie)).toString();
  }

  /// SHA-256 account identity for view preferences (never the raw cookie).
  Future<String> accountId() => _fingerprint();

  Future<void> _ensure() async {
    final account = await _fingerprint();
    if (account == _account && _state != null) return;
    final raw = await _settings.preferences.read(cacheKey);
    Map<String, dynamic>? saved;
    try {
      final decoded = jsonDecode(raw ?? '');
      if (decoded is Map<String, dynamic> &&
          decoded['version'] == 1 && decoded['account'] == account) {
        saved = decoded;
      }
    } catch (_) {}
    // If another async initialization or an account change completed while
    // we were reading preferences, only the current account may win.
    if (account != await _fingerprint()) return _ensure();
    _account = account;
    _state = saved ?? {
      'version': 1, 'account': account, 'playlists': null,
      'tracks': <String, dynamic>{},
    };
    if (account.isEmpty) {
      _state = {'version': 1, 'account': '', 'playlists': null,
        'tracks': <String, dynamic>{}};
      await _settings.preferences.remove(cacheKey);
    }
  }

  Future<void> _save() async {
    if (_state != null && _account == await _fingerprint() &&
        _account?.isNotEmpty == true) {
      await _settings.preferences.write(cacheKey, jsonEncode(_state));
    }
  }

  Map<String, dynamic>? _entry(Object? object) =>
      object is Map ? Map<String, dynamic>.from(object) : null;

  Future<List<SpotifyPlaylist>?> playlists() async {
    await _ensure();
    final entry = _entry(_state?['playlists']);
    final items = entry?['items'];
    if (items is! List) return null;
    return [
      for (final raw in items)
        if (raw is Map && raw['id'] is String && raw['name'] is String)
          SpotifyPlaylist(
            id: raw['id'] as String, name: raw['name'] as String,
            owner: raw['owner'] as String?,
            imageUrl: raw['imageUrl'] as String?,
            tracksTotal: (raw['tracksTotal'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  Future<List<SpotifyTrack>?> tracks(String playlistId) async {
    await _ensure();
    final entry = _entry((_state?['tracks'] as Map?)?[playlistId]);
    final items = entry?['items'];
    if (items is! List) return null;
    return [
      for (final raw in items)
        if (raw is Map && raw['id'] is String && raw['title'] is String)
          SpotifyTrack(
            id: raw['id'] as String, title: raw['title'] as String,
            artist: raw['artist'] as String? ?? '',
            album: raw['album'] as String?,
            durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
            imageUrl: raw['imageUrl'] as String?,
          ),
    ];
  }

  bool _due(Object? raw) {
    final entry = _entry(raw);
    if (entry == null) return false;
    final updated = (entry['updated'] as num?)?.toInt() ?? 0;
    final retryAfter = (entry['retryAfter'] as num?)?.toInt() ?? 0;
    return _timestamp - updated >= updateInterval.inMilliseconds &&
        _timestamp >= retryAfter;
  }

  Future<bool> shouldAutoUpdateList() async {
    await _ensure();
    return await _settings.loadPlaylistAutoUpdate() &&
        _due(_state?['playlists']);
  }

  Future<bool> shouldAutoUpdateTracks(String id) async {
    await _ensure();
    return await _settings.loadPlaylistAutoUpdate() &&
        _due((_state?['tracks'] as Map?)?[id]);
  }

  Future<void> _failed(String? id) async {
    await _ensure();
    // Use explicit branching: Dart can interpret the null-aware [] access
    // next to a ternary '?' as a second conditional expression.
    Object? raw;
    if (id == null) {
      raw = _state?['playlists'];
    } else {
      final trackEntries = _state?['tracks'];
      raw = trackEntries is Map ? trackEntries[id] : null;
    }
    final entry = _entry(raw);
    if (entry == null) return;
    entry['retryAfter'] = _timestamp + retryInterval.inMilliseconds;
    if (id == null) {
      _state!['playlists'] = entry;
    } else {
      (_state!['tracks'] as Map)[id] = entry;
    }
    await _save();
  }

  Future<List<SpotifyPlaylist>> refreshList(SpotifyWebApi api) async {
    await _ensure();
    final account = _account;
    if (account == null || account.isEmpty) {
      throw const SpotifyApiException('Connect Spotify in Data → Accounts.');
    }
    try {
      final list = await api.getLibraryPlaylists();
      if (account != await _fingerprint()) {
        throw const SpotifyApiException('Spotify account changed. Retry the update.');
      }
      await _ensure();
      _state!['playlists'] = {
        'updated': _timestamp, 'retryAfter': 0,
        'items': [
          for (final p in list)
            {'id': p.id, 'name': p.name, 'owner': p.owner,
              'imageUrl': p.imageUrl, 'tracksTotal': p.tracksTotal},
        ],
      };
      // Track caches remain until each playlist is explicitly visited
      // or its own auto-update interval expires.
      await _save();
      return list;
    } catch (_) {
      if (account == await _fingerprint()) await _failed(null);
      rethrow;
    }
  }

  Future<List<SpotifyTrack>> refreshTracks(
      SpotifyWebApi api, String playlistId) async {
    await _ensure();
    final account = _account;
    if (account == null || account.isEmpty) {
      throw const SpotifyApiException('Connect Spotify in Data → Accounts.');
    }
    try {
      final list = await api.getPlaylistTracks(playlistId, max: 1000);
      if (account != await _fingerprint()) {
        throw const SpotifyApiException('Spotify account changed. Retry the update.');
      }
      await _ensure();
      (_state!['tracks'] as Map)[playlistId] = {
        'updated': _timestamp, 'retryAfter': 0,
        'items': [
          for (final t in list)
            {'id': t.id, 'title': t.title, 'artist': t.artist,
              'album': t.album, 'durationMs': t.durationMs,
              'imageUrl': t.imageUrl},
        ],
      };
      await _save();
      return list;
    } catch (_) {
      if (account == await _fingerprint()) await _failed(playlistId);
      rethrow;
    }
  }
}
