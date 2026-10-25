import 'dart:convert';
import 'dart:io';

import 'package:flick/services/apple_music/apple_music_cache.dart';
import 'package:flick/services/apple_music/apple_music_metadata_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Global catalogue songs contain metadata but no streaming URLs', () {
    final item = AppleMusicSearchSong.fromItunes({
      'wrapperType': 'track', 'kind': 'song',
      'trackId': 123, 'trackName': 'Test song', 'artistName': 'Test artist',
      'collectionName': 'Album', 'trackTimeMillis': 210000,
      'artworkUrl100': 'https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg',
      'previewUrl': 'https://audio-ssl.itunes.apple.com/signed-preview.m4a',
    });
    expect(item, isNotNull);
    expect(item!.catalogueId, '123');
    expect(item.duration, const Duration(seconds: 210));
    expect(item.artworkUrl, contains('100x100bb'));
    expect(item.toJson().toString(), isNot(contains('preview')));
    expect(item.toJson().toString(), isNot(contains('m4a')));
    expect(AppleMusicSearchSong.fromJson(item.toJson()).title, item.title);
  });

  test('Global search deduplicates iTunes results and uses device storefront', () async {
    final dir = await Directory.systemTemp.createTemp('global_song_search_test_');
    final cache = AppleMusicCache.forDirectory(dir);
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.host, 'itunes.apple.com');
      expect(request.url.queryParameters['entity'], 'song');
      expect(request.url.queryParameters['country'], 'fr');
      return http.Response(jsonEncode({
        'resultCount': 3,
        'results': [
          {
            'wrapperType': 'track', 'kind': 'song',
            'trackId': 123, 'trackName': 'Song', 'artistName': 'Artist',
            'collectionName': 'Album', 'trackTimeMillis': 180000,
          },
          {
            'wrapperType': 'track', 'kind': 'song',
            'trackId': 123, 'trackName': 'Song', 'artistName': 'Artist',
          },
          {'wrapperType': 'track', 'kind': 'music-video', 'trackId': 345,
           'trackName': 'Video', 'artistName': 'Artist'},
        ],
      }), 200);
    });
    try {
      final service = AppleMusicMetadataService.create(
        client: client, cache: cache,
      );
      final results = await service.searchSongs('Song', storefront: 'fr');
      expect(results.map((e) => e.catalogueId), ['123']);
      final cached = await service.searchSongs('Song', storefront: 'fr');
      expect(cached.length, 1);
      expect(calls, 1);
    } finally {
      await cache.flushPendingWrites();
      await dir.delete(recursive: true);
      client.close();
    }
  });
}
