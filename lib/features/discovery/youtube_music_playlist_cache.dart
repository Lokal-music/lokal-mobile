import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'lastfm_discovery.dart';
import 'youtube_music_account.dart';

/// Stores read-only YouTube Music playlist metadata and tracks on this device.
/// Namespaced by the cookie session's non-reversible account key.
class YoutubeMusicPlaylistCache {
  YoutubeMusicPlaylistCache({Future<SharedPreferences> Function()? preferences,
      DateTime Function()? now})
      : _prefs = preferences ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now;

  static final instance = YoutubeMusicPlaylistCache();
  static const updateInterval = Duration(hours: 24);
  static const failureRetry = Duration(hours: 1);
  static const autoUpdateKey = 'lokal.youtube.playlists.auto_update.v1';
  static const _cachePrefix = 'lokal.youtube.playlists.cache.v1.';
  final Future<SharedPreferences> Function() _prefs;
  final DateTime Function() _now;
  final Map<String, Map<String, dynamic>> _memory = {};

  String _key(String accountId, String resource) =>
      '$_cachePrefix$accountId.$resource';

  Future<void> clearAll() async {
    _memory.clear();
    final prefs = await _prefs();
    for (final key in prefs.getKeys().where((key) => key.startsWith(_cachePrefix))) {
      await prefs.remove(key);
    }
  }

  Future<Map<String, dynamic>?> _read(String accountId, String resource) async {
    final key = _key(accountId, resource);
    if (_memory.containsKey(key)) return _memory[key];
    try {
      final raw = (await _prefs()).getString(key);
      if (raw == null) return null;
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic> || parsed['version'] != 1 ||
          parsed['items'] is! List) return null;
      _memory[key] = parsed;
      return parsed;
    } catch (_) { return null; }
  }

  Future<void> _write(String accountId, String resource, List<Map<String, dynamic>> items) async {
    final key = _key(accountId, resource);
    final data = <String, dynamic>{
      'version': 1, 'updated': _now().millisecondsSinceEpoch,
      'retryAfter': 0, 'items': items,
    };
    await (await _prefs()).setString(key, jsonEncode(data));
    _memory[key] = data;
  }

  Future<bool> get autoUpdate async =>
      (await _prefs()).getBool(autoUpdateKey) ?? false;

  Future<void> setAutoUpdate(bool value) async {
    await (await _prefs()).setBool(autoUpdateKey, value);
  }

  Future<bool> due(String account, String resource) async {
    if (!await autoUpdate) return false;
    final data = await _read(account, resource);
    if (data == null) return false;
    final at = (data['updated'] as num?)?.toInt() ?? 0;
    final retry = (data['retryAfter'] as num?)?.toInt() ?? 0;
    final now = _now().millisecondsSinceEpoch;
    return now - at >= updateInterval.inMilliseconds && now >= retry;
  }

  Future<void> failed(String account, String resource) async {
    final saved = await _read(account, resource);
    if (saved == null) return;
    final data = Map<String, dynamic>.from(saved)
      ..['retryAfter'] = _now().millisecondsSinceEpoch + failureRetry.inMilliseconds;
    await (await _prefs()).setString(_key(account, resource), jsonEncode(data));
    _memory[_key(account, resource)] = data;
  }

  Future<List<LokalDiscoveryMix>?> playlists(String account) async {
    final data = await _read(account, 'library');
    if (data == null) return null;
    return [
      for (final raw in data['items'] as List)
        if (raw is Map && raw['id'] is String && raw['title'] is String)
          LokalDiscoveryMix(
            id: raw['id'] as String, title: raw['title'] as String,
            author: raw['author'] as String? ?? '',
            artworkUrl: raw['artworkUrl'] as String? ?? '',
          ),
    ];
  }

  Future<List<LokalDiscoveryTrack>?> tracks(String account, String id) async {
    final data = await _read(account, 'tracks.$id');
    if (data == null) return null;
    return [
      for (final raw in data['items'] as List)
        if (raw is Map && raw['title'] is String && raw['artist'] is String)
          LokalDiscoveryTrack(
            title: raw['title'] as String, artist: raw['artist'] as String,
            album: raw['album'] as String? ?? '',
            artworkUrl: raw['artworkUrl'] as String? ?? '',
            url: raw['url'] as String? ?? '',
            videoId: raw['videoId'] as String?,
            duration: raw['durationMs'] is num
                ? Duration(milliseconds: (raw['durationMs'] as num).toInt())
                : null,
          ),
    ];
  }

  Future<List<LokalDiscoveryMix>> refreshLibrary(YoutubeMusicAccount api) async {
    final account = api.session.accountKey;
    try {
      final list = await api.libraryPlaylists();
      if (api.session.accountKey != account) throw const YoutubeMusicSignedOut();
      await _write(account, 'library', [
        for (final p in list) {'id': p.id, 'title': p.title,
          'author': p.author, 'artworkUrl': p.artworkUrl},
      ]);
      return list;
    } catch (_) { await failed(account, 'library'); rethrow; }
  }

  Future<List<LokalDiscoveryTrack>> refreshTracks(YoutubeMusicAccount api, String id) async {
    final account = api.session.accountKey;
    try {
      final tracks = await api.libraryPlaylistTracks(id);
      if (api.session.accountKey != account) throw const YoutubeMusicSignedOut();
      await _write(account, 'tracks.$id', [
        for (final t in tracks) {
          'title': t.title, 'artist': t.artist, 'album': t.album,
          'artworkUrl': t.artworkUrl, 'url': t.url,
          'videoId': t.videoId, 'durationMs': t.duration?.inMilliseconds,
        },
      ]);
      return tracks;
    } catch (_) { await failed(account, 'tracks.$id'); rethrow; }
  }
}
