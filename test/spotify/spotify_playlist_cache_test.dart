import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flick/features/spotify/spotify_playlist_cache.dart';
import 'package:flick/features/spotify/spotify_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Prefs implements SpotifyPreferenceStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<void> remove(String key) async { values.remove(key); }
}

class _Tokens implements SpotifyTokenStore {
  SpotifyTokens? current;
  @override
  Future<SpotifyTokens?> readTokens() async => current;
  @override
  Future<void> writeTokens(SpotifyTokens tokens) async { current = tokens; }
  @override
  Future<void> clearTokens() async { current = null; }
}

SpotifyTokens _token(String cookie) => SpotifyTokens(
  accessToken: 'test',
  refreshToken: null,
  expiresAt: DateTime.utc(2030),
  sessionCookie: cookie,
);

void main() {
  test('a cached library restores across screen instances and restarts', () async {
    const cookie = 'this-is-a-private-cookie';
    final prefs = _Prefs();
    final tokens = _Tokens()..current = _token(cookie);
    final account = sha256.convert(utf8.encode(cookie)).toString();
    final timestamp = DateTime.utc(2026, 10, 30).millisecondsSinceEpoch;
    await prefs.write(SpotifyPlaylistCache.cacheKey, jsonEncode({
      'version': 1, 'account': account,
      'playlists': {
        'updated': timestamp, 'retryAfter': 0,
        'items': [
          {'id': 'playlistA', 'name': 'Playlist', 'owner': 'Listener', 'tracksTotal': 1},
        ],
      },
      'tracks': {
        'playlistA': {
          'updated': timestamp, 'retryAfter': 0,
          'items': [
            {'id': 'songA', 'title': 'Song', 'artist': 'Singer', 'album': 'Album', 'durationMs': 30000},
          ],
        },
      },
    }));
    final settings = SpotifySettingsStore(preferences: prefs, tokenStore: tokens);
    final cache = SpotifyPlaylistCache(
      settings: settings, now: () => DateTime.utc(2026, 10, 31, 12),
    );
    expect((await cache.playlists())!.single.name, 'Playlist');
    expect((await cache.tracks('playlistA'))!.single.title, 'Song');
    expect(await cache.shouldAutoUpdateList(), false); // default off

    await settings.savePlaylistAutoUpdate(true);
    expect(await cache.shouldAutoUpdateList(), true);
    expect(await cache.shouldAutoUpdateTracks('playlistA'), true);
    final reopened = SpotifyPlaylistCache(
      settings: settings, now: () => DateTime.utc(2026, 10, 31, 12),
    );
    expect((await reopened.playlists())!.single.owner, 'Listener');

    tokens.current = _token('different-account-cookie');
    expect(await cache.playlists(), isNull);
    expect(await cache.tracks('playlistA'), isNull);
  });

  test('only successfully cached lists are eligible for auto-update', () async {
    final prefs = _Prefs();
    final tokens = _Tokens()..current = _token('cookie');
    final settings = SpotifySettingsStore(preferences: prefs, tokenStore: tokens);
    await settings.savePlaylistAutoUpdate(true);
    final cache = SpotifyPlaylistCache(
      settings: settings, now: () => DateTime.utc(2026, 10, 31),
    );
    expect(await cache.playlists(), isNull);
    expect(await cache.shouldAutoUpdateList(), false);
    tokens.current = null;
    expect(await cache.playlists(), isNull);
  });
}
