import 'dart:convert';
import 'dart:io';

import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/spotify_discovery.dart';
import 'package:flick/features/konnekted/discovery_snapshot_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late DiscoverySnapshotCache cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lokal-discovery-test-');
    cache = DiscoverySnapshotCache(directory: root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('Last.fm shelves and order survive a fresh cache instance', () async {
    const data = LokalDiscovery(
      account: 'Listener',
      page: 2,
      mixes: [LokalDiscoveryMix(id: 'radio', title: 'My Mix')],
      categories: [
        LokalDiscoveryCategory(
          id: 'fresh',
          tracks: [
            LokalDiscoveryTrack(
              title: 'First', artist: 'Singer', videoId: 'video1',
              duration: Duration(seconds: 193), reason: 'Because you listened',
            ),
            LokalDiscoveryTrack(title: 'Second', artist: 'Singer'),
          ],
        ),
      ],
      quickPicks: [
        LokalDiscoveryTrack(title: 'Song', artist: 'Artist',
            scrobbleCount: 5),
      ],
      albums: [
        LokalDiscoveryAlbum(title: 'Album', artist: 'Artist'),
      ],
    );
    await cache.writeLokal('lastfm', 'lastfm:user', data);
    final restored = await DiscoverySnapshotCache(directory: root)
        .readLokal('lastfm', 'lastfm:user');
    expect(restored, isNotNull);
    expect(restored!.isFresh(DiscoverySnapshotCache.lastfmTtl), isTrue);
    expect(restored.data.page, 2);
    expect(restored.data.categories!.single.tracks.map((t) => t.title),
        ['First', 'Second']);
    expect(restored.data.categories!.single.tracks.first.videoId, 'video1');
    expect(restored.data.categories!.single.tracks.first.duration,
        const Duration(seconds: 193));
    expect(restored.data.mixes!.single.id, 'radio');
    expect(restored.data.quickPicks!.single.scrobbleCount, 5);
    expect(restored.data.albums!.single.title, 'Album');
    expect(await cache.readLokal('lastfm', 'lastfm:other'), isNull);
    expect(await cache.readLokal('youtube', 'lastfm:user'), isNull);
  });

  test('Spotify shelves restore without persisting session cookies', () async {
    const data = SpotifyDiscoveryData(
      account: 'Spotify', quickPicks: [
        LokalDiscoveryTrack(title: 'Track', artist: 'Singer',
            artworkUrl: 'https://example.org/cover.jpg'),
      ],
      recentlyPlayed: [], likedSongs: [], artists: [], albums: [],
      freshFinds: [],
      mixes: [LokalDiscoveryMix(id: 'abc', title: 'Mix')],
    );
    const identity = 'a-hash-of-the-spotify-session';
    await cache.writeSpotify(identity, data);
    final saved = await cache.readSpotify(identity);
    expect(saved?.data.mixes.single.title, 'Mix');
    expect(saved?.data.quickPicks.single.artworkUrl,
        'https://example.org/cover.jpg');
    expect(await cache.readSpotify('different-session'), isNull);
    final file = (await root.list().first) as File;
    final raw = await file.readAsString();
    expect(raw, isNot(contains(identity)));
    expect(raw, isNot(contains('accessToken')));
    expect(raw, isNot(contains('sessionCookie')));
  });

  test('invalid JSON, expired snapshots and schema mismatches are safe',
      () async {
    await cache.writeLokal('youtube', 'youtube:user', const LokalDiscovery(
      account: 'YouTube', page: 0, quickPicks: [
        LokalDiscoveryTrack(title: 'Pick', artist: 'Artist'),
      ],
    ));
    final file = (await root.list().first) as File;
    final original = jsonDecode(await file.readAsString())
        as Map<String, dynamic>;
    final stale = Map<String, dynamic>.from(original);
    stale['savedAt'] = DateTime.now().toUtc()
        .subtract(const Duration(hours: 26)).toIso8601String();
    await file.writeAsString(jsonEncode(stale));
    final old = await cache.readLokal('youtube', 'youtube:user');
    expect(old, isNotNull);
    expect(old!.isFresh(DiscoverySnapshotCache.youtubeTtl), isFalse);
    await file.writeAsString('not json');
    expect(await cache.readLokal('youtube', 'youtube:user'), isNull);
    await file.writeAsString(jsonEncode({...original, 'version': 9}));
    expect(await cache.readLokal('youtube', 'youtube:user'), isNull);
    await cache.invalidate('youtube', 'youtube:user');
    expect(await file.exists(), isFalse);
  });

  test('empty loads never replace an existing successful snapshot', () async {
    await cache.writeLokal('lastfm', 'lastfm:user', const LokalDiscovery(
      account: 'Listener', page: 0,
      albums: [LokalDiscoveryAlbum(title: 'Saved', artist: 'Artist')],
    ));
    await cache.writeLokal('lastfm', 'lastfm:user',
        const LokalDiscovery(account: 'Listener', page: 1));
    expect((await cache.readLokal('lastfm', 'lastfm:user'))
        ?.data.albums?.single.title, 'Saved');
  });
}
