import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/spotify_discovery.dart';
import 'package:flick/features/konnekted/discovery_snapshot_cache.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/spotify/spotify_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Tokens implements SpotifyTokenStore {
  SpotifyTokens? value;
  @override
  Future<SpotifyTokens?> readTokens() async => value;
  @override
  Future<void> writeTokens(SpotifyTokens tokens) async {
    value = tokens;
    SecureSpotifyTokenStore.sessionRevision.value++;
  }

  @override
  Future<void> clearTokens() async {
    value = null;
    SecureSpotifyTokenStore.sessionRevision.value++;
  }
}

class _Settings extends SpotifySettingsStore {
  _Settings(_Tokens store) : super(tokenStore: store);
  @override
  Future<bool> loadDiscoveryEnabled() async => true;
}

SpotifyTokens _session(String id) => SpotifyTokens(
  accessToken: 'fixture-access',
  refreshToken: null,
  expiresAt: DateTime.utc(2099),
  sessionCookie: id,
);
String _key(String id) => sha256.convert(utf8.encode(id)).toString();
SpotifyDiscoverySnapshot _snapshot(String account) => SpotifyDiscoverySnapshot(
  enabled: true,
  connected: true,
  data: SpotifyDiscoveryData(
    account: account,
    quickPicks: [LokalDiscoveryTrack(title: account, artist: 'Fixture')],
    recentlyPlayed: [],
    likedSongs: [],
    artists: [],
    albums: [],
    freshFinds: [],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DiscoverySnapshotCache cache;
  late _Tokens tokens;
  late _Settings settings;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('lokal-spotify-cache-owner-');
    cache = DiscoverySnapshotCache(directory: root);
    tokens = _Tokens()..value = _session('fixture-a');
    settings = _Settings(tokens);
  });
  tearDown(() async => root.delete(recursive: true));

  test('old startup response cannot populate the new account or recreate its purged cache', () async {
    final started = Completer<void>(),
        oldResponse = Completer<SpotifyDiscoverySnapshot>();
    final container = ProviderContainer(
      overrides: [
        konnektedSpotifySettingsProvider.overrideWithValue(settings),
        konnektedDiscoverySnapshotCacheProvider.overrideWithValue(cache),
        konnektedSpotifySnapshotFetchProvider.overrideWithValue((_) {
          if (tokens.value!.sessionCookie == 'fixture-a') {
            started.complete();
            return oldResponse.future;
          }
          return Future.value(_snapshot('Account B'));
        }),
      ],
    );
    addTearDown(container.dispose);
    final first = container.read(konnektedSpotifyDiscoveryProvider.future);
    await started.future;
    await tokens.writeTokens(_session('fixture-b'));
    final latest = await container.read(
      konnektedSpotifyDiscoveryProvider.future,
    );
    expect(latest.data!.account, 'Account B');
    oldResponse.complete(_snapshot('Account A'));
    await first;
    await pumpEventQueue();
    expect(
      container.read(konnektedSpotifyDiscoveryProvider).value!.data!.account,
      'Account B',
    );
    expect(await cache.readSpotify(_key('fixture-a')), isNull);
    expect(
      (await cache.readSpotify(_key('fixture-b')))!.data.account,
      'Account B',
    );
  });

  test('sign-out during a manual refresh leaves no old snapshot or displayed account', () async {
    await cache.writeSpotify(_key('fixture-a'), _snapshot('Account A').data!);
    final started = Completer<void>(),
        response = Completer<SpotifyDiscoverySnapshot>();
    final container = ProviderContainer(
      overrides: [
        konnektedSpotifySettingsProvider.overrideWithValue(settings),
        konnektedDiscoverySnapshotCacheProvider.overrideWithValue(cache),
        konnektedSpotifySnapshotFetchProvider.overrideWithValue((_) {
          started.complete();
          return response.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    expect(
      (await container.read(konnektedSpotifyDiscoveryProvider.future))
          .data!
          .account,
      'Account A',
    );
    final refreshing = container
        .read(konnektedSpotifyDiscoveryProvider.notifier)
        .refresh();
    await started.future;
    await tokens.clearTokens();
    expect(
      (await container.read(konnektedSpotifyDiscoveryProvider.future))
          .connected,
      isFalse,
    );
    response.complete(_snapshot('Stale Account A'));
    await refreshing;
    await pumpEventQueue();
    expect(
      container.read(konnektedSpotifyDiscoveryProvider).value!.connected,
      isFalse,
    );
    expect(await cache.readSpotify(_key('fixture-a')), isNull);
  });
}
