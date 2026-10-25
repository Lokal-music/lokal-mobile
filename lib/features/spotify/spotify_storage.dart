import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flick/services/playback_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'spotify_models.dart';

class SpotifyTokens {
  const SpotifyTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.sessionCookie,
    this.clientToken,
    this.queryHashes = const {},
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;
  final String? sessionCookie;
  final String? clientToken;
  final Map<String, String> queryHashes;

  bool get isExpired => DateTime.now()
      .toUtc()
      .add(const Duration(seconds: 30))
      .isAfter(expiresAt);

  SpotifyTokens copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? sessionCookie,
    String? clientToken,
    Map<String, String>? queryHashes,
  }) {
    return SpotifyTokens(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      sessionCookie: sessionCookie ?? this.sessionCookie,
      clientToken: clientToken ?? this.clientToken,
      queryHashes: queryHashes ?? this.queryHashes,
    );
  }
}

abstract interface class SpotifyTokenStore {
  Future<SpotifyTokens?> readTokens();
  Future<void> writeTokens(SpotifyTokens tokens);
  Future<void> clearTokens();
}

/// Only OAuth tokens are written here. Client IDs and sync metadata stay in
/// ordinary preferences because they are not credentials.
class SecureSpotifyTokenStore implements SpotifyTokenStore {
  SecureSpotifyTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const PlaybackSecureStorage();

  static const _key = 'konnekted.spotify.tokens.v1';
  static final sessionRevision = ValueNotifier<int>(0);
  final FlutterSecureStorage _storage;

  @override
  Future<SpotifyTokens?> readTokens() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || ![1, 2].contains(json['version'])) return null;
      final accessToken = json['accessToken'];
      final expiresAt = json['expiresAt'];
      if (accessToken is! String ||
          accessToken.isEmpty ||
          expiresAt is! String) {
        return null;
      }
      return SpotifyTokens(
        accessToken: accessToken,
        refreshToken: json['refreshToken'] as String?,
        // Version 1 used a fabricated client token. Remint once after upgrade.
        expiresAt: json['version'] == 1
            ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
            : DateTime.parse(expiresAt).toUtc(),
        sessionCookie: json['sessionCookie'] as String?,
        clientToken: json['version'] == 1
            ? null
            : json['clientToken'] as String?,
        queryHashes: {
          for (final entry
              in (json['queryHashes'] is Map ? json['queryHashes'] as Map : {})
                  .entries)
            if (entry.key is String &&
                entry.value is String &&
                RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value as String))
              entry.key as String: entry.value as String,
        },
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeTokens(SpotifyTokens tokens) async {
    final previous = await readTokens();
    await _storage.write(
      key: _key,
      value: jsonEncode({
        'version': 2,
        'queryHashes': tokens.queryHashes,
        'accessToken': tokens.accessToken,
        'refreshToken': tokens.refreshToken,
        'expiresAt': tokens.expiresAt.toUtc().toIso8601String(),
        'sessionCookie': tokens.sessionCookie,
        'clientToken': tokens.clientToken,
      }),
    );
    if (previous?.sessionCookie != tokens.sessionCookie)
      sessionRevision.value++;
  }

  @override
  Future<void> clearTokens() async {
    await _storage.delete(key: _key);
    sessionRevision.value++;
  }
}

abstract interface class SpotifyPreferenceStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class SharedPreferencesSpotifyPreferenceStore
    implements SpotifyPreferenceStore {
  SharedPreferencesSpotifyPreferenceStore({this._preferences});

  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<String?> read(String key) async => (await _prefs).getString(key);

  @override
  Future<void> write(String key, String value) async {
    await (await _prefs).setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await (await _prefs).remove(key);
  }
}

class SpotifySettingsStore {
  SpotifySettingsStore({
    SpotifyPreferenceStore? preferences,
    SpotifyTokenStore? tokenStore,
  }) : preferences = preferences ?? SharedPreferencesSpotifyPreferenceStore(),
       tokenStore = tokenStore ?? SecureSpotifyTokenStore();

  static const clientIdKey = 'konnekted.spotify.client_id.v1';
  static const metadataKey = 'konnekted.spotify.metadata.v1';
  static const discoveryEnabledKey = 'konnekted.spotify.discovery_enabled.v1';

  final SpotifyPreferenceStore preferences;
  final SpotifyTokenStore tokenStore;

  Future<String> loadClientId() async =>
      (await preferences.read(clientIdKey))?.trim() ?? '';

  Future<void> saveClientId(String clientId) async {
    final value = clientId.trim();
    if (value.isEmpty) {
      await preferences.remove(clientIdKey);
    } else {
      await preferences.write(clientIdKey, value);
    }
  }

  Future<bool> loadDiscoveryEnabled() async =>
      (await preferences.read(discoveryEnabledKey)) == 'true';

  Future<void> saveDiscoveryEnabled(bool enabled) async {
    if (enabled) {
      await preferences.write(discoveryEnabledKey, 'true');
    } else {
      await preferences.remove(discoveryEnabledKey);
    }
  }
}

class SpotifyMetadataStore {
  SpotifyMetadataStore(this._preferences);

  final SpotifyPreferenceStore _preferences;

  Future<SpotifySyncMetadata> load() async {
    final raw = await _preferences.read(SpotifySettingsStore.metadataKey);
    if (raw == null || raw.isEmpty) return const SpotifySyncMetadata();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException();
      return SpotifySyncMetadata.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      throw const FormatException('Saved Spotify sync metadata is invalid.');
    }
  }

  Future<void> save(SpotifySyncMetadata metadata) => _preferences.write(
    SpotifySettingsStore.metadataKey,
    jsonEncode(metadata.toJson()),
  );

  Future<void> savePlaylist(SpotifyPlaylistMetadata playlist) async {
    final current = await load();
    final playlists = Map<String, SpotifyPlaylistMetadata>.from(
      current.playlists,
    )..[playlist.playlistId] = playlist;
    await save(current.copyWith(playlists: playlists));
  }

  Future<void> saveLikedSync(DateTime timestamp) async {
    final current = await load();
    await save(current.copyWith(lastLikedSync: timestamp));
  }
}
