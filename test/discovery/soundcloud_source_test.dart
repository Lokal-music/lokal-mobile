import 'dart:convert';

import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/soundcloud_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const key = 'abcdefghijklmnopqrstuvwxyz123456';

  test('SoundCloud is a distinct native source with artist, artwork and stream', () async {
    final calls = <String>[];
    final client = MockClient((request) async {
      calls.add(request.url.path);
      expect(request.url.host, 'api-v2.soundcloud.com');
      expect(request.url.queryParameters['client_id'], key);
      if (request.url.path == '/search/tracks') {
        expect(request.url.queryParameters['q'], 'Daft Punk');
        return http.Response(jsonEncode({
          'collection': [
            {
              'id': 123,
              'title': 'Night Drive',
              'duration': 200000,
              'access': 'playable',
              'publisher_metadata': {
                'artist': 'Daft Punk',
                'album_title': 'Album',
              },
              'artwork_url': 'https://i1.sndcdn.com/artworks-example.jpg',
            },
            {'id': 'not-an-id', 'title': 'Invalid'},
            {'id': 123, 'title': 'Duplicate'},
          ],
        }), 200);
      }
      if (request.url.path == '/tracks/123') {
        return http.Response(jsonEncode({
          'id': 123,
          'access': 'playable',
          'media': {
            'transcodings': [
              {'url': 'https://api-v2.soundcloud.com/media/123/mp3',
                'format': {'protocol': 'progressive', 'mime_type': 'audio/mpeg'}},
            ],
          },
        }), 200);
      }
      if (request.url.path == '/media/123/mp3') {
        return http.Response(jsonEncode({
          'url': 'https://cf-media.sndcdn.com/stream.mp3?sig=private',
        }), 200);
      }
      return http.Response('{}', 404);
    });
    addTearDown(client.close);
    final source = SoundCloudSource(DiscoveryHttp(client), clientId: () async => key);
    final tracks = await source.search('Daft Punk');
    expect(tracks, hasLength(1));
    final found = tracks.single;
    expect(found.source, DiscoverySource.soundCloud);
    expect(found.title, 'Night Drive');
    expect(found.artist, 'Daft Punk');
    expect(found.album, 'Album');
    expect(found.duration, const Duration(seconds: 200));
    expect(found.artwork, 'https://i1.sndcdn.com/artworks-example.jpg');

    final stream = await source.resolve(found, forDownload: true);
    expect(stream.codec, 'MP3');
    expect(stream.url.host, 'cf-media.sndcdn.com');
    expect(calls, ['/search/tracks', '/tracks/123', '/media/123/mp3']);
  });

  test('SoundCloud preview is playable but not downloadable', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/tracks/123') {
        return http.Response(jsonEncode({
          'id': 123, 'access': 'preview',
          'media': {'transcodings': [
            {'url': 'https://api-v2.soundcloud.com/media/123/hls',
              'format': {'protocol': 'hls', 'mime_type': 'audio/mp4'}},
          ]},
        }), 200);
      }
      return http.Response(jsonEncode({
        'url': 'https://cf-media.sndcdn.com/audio.m3u8',
      }), 200);
    });
    addTearDown(client.close);
    final source = SoundCloudSource(DiscoveryHttp(client), clientId: () async => key);
    final track = DiscoveryTrack(
      id: '123', title: 'Preview', artist: 'Artist',
      source: DiscoverySource.soundCloud,
      inlineStream: const {'preview': true},
    );
    expect((await source.resolve(track)).url.path, '/audio.m3u8');
    await expectLater(source.resolve(track, forDownload: true),
        throwsA(isA<DiscoveryException>()));
  });

  test('SoundCloud disallows arbitrary CDN URLs and invalid source identities', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/tracks/123') {
        return http.Response(jsonEncode({
          'id': 123, 'access': 'playable',
          'media': {'transcodings': [
            {'url': 'https://api-v2.soundcloud.com/media/123/mp3',
              'format': {'protocol': 'progressive', 'mime_type': 'audio/mpeg'}},
          ]},
        }), 200);
      }
      return http.Response(jsonEncode({'url': 'https://evil.example/private.mp3'}), 200);
    });
    addTearDown(client.close);
    final source = SoundCloudSource(DiscoveryHttp(client), clientId: () async => key);
    await expectLater(source.resolve(const DiscoveryTrack(
      id: '123', title: 'Track', artist: 'Artist',
      source: DiscoverySource.soundCloud,
    )), throwsA(isA<DiscoveryException>()));
    await expectLater(source.resolve(const DiscoveryTrack(
      id: '../bad', title: 'Track', artist: 'Artist',
      source: DiscoverySource.soundCloud,
    )), throwsA(isA<DiscoveryException>()));
    await expectLater(source.resolve(const DiscoveryTrack(
      id: '123', title: 'Track', artist: 'Artist',
      source: DiscoverySource.monochrome,
    )), throwsA(isA<DiscoveryException>()));
  });

  test('SoundCloud key finder accepts current web hydration', () {
    expect(SoundCloudSource.clientIdIn(
      '{"apiClient":{"data":{"id":"abcdefghijklmnopqrstuvwxyz123456"}}}'),
      key);
  });
}
