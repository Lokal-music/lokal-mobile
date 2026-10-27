import 'dart:convert';

import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/discovery/discovery_progressive_streams.dart';
import 'package:flick/providers/opt_in_source_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/soundcloud_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const key = 'abcdefghijklmnopqrstuvwxyz123456';

  test(
    'SoundCloud is a distinct native source with artist, artwork and stream',
    () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.url.path);
        expect(request.url.host, 'api-v2.soundcloud.com');
        expect(request.url.queryParameters['client_id'], key);
        if (request.url.path == '/search/tracks') {
          expect(request.url.queryParameters['q'], 'Daft Punk');
          return http.Response(
            jsonEncode({
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
            }),
            200,
          );
        }
        if (request.url.path == '/tracks/123') {
          return http.Response(
            jsonEncode({
              'id': 123,
              'access': 'playable',
              'media': {
                'transcodings': [
                  {
                    'url': 'https://api-v2.soundcloud.com/media/123/mp3',
                    'format': {
                      'protocol': 'progressive',
                      'mime_type': 'audio/mpeg',
                    },
                  },
                ],
              },
            }),
            200,
          );
        }
        if (request.url.path == '/media/123/mp3') {
          return http.Response(
            jsonEncode({
              'url': 'https://cf-media.sndcdn.com/stream.mp3?sig=private',
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      addTearDown(client.close);
      final source = SoundCloudSource(
        DiscoveryHttp(client),
        clientId: () async => key,
      );
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
    },
  );

  test(
    'iPhone HLS selects AAC without resolving an unsupported Ogg playlist',
    () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.url.path);
        if (request.url.path == '/tracks/123') {
          return http.Response(
            jsonEncode({
              'id': 123,
              'access': 'playable',
              'media': {
                'transcodings': [
                  {
                    'url': 'https://api-v2.soundcloud.com/media/123/opus',
                    'format': {
                      'protocol': 'hls',
                      'mime_type': 'audio/ogg; codecs=opus',
                    },
                  },
                  {
                    'url': 'https://api-v2.soundcloud.com/media/123/aac',
                    'format': {
                      'protocol': 'hls',
                      'mime_type': 'audio/mp4; codecs=mp4a.40.2',
                    },
                  },
                ],
              },
            }),
            200,
          );
        }
        expect(request.url.path, '/media/123/aac');
        return http.Response(
          jsonEncode({'url': 'https://cf-media.sndcdn.com/audio.m3u8'}),
          200,
        );
      });
      addTearDown(client.close);
      final source = SoundCloudSource(
        DiscoveryHttp(client),
        clientId: () async => key,
        supportsOggHls: false,
      );
      final stream = await source.resolve(
        const DiscoveryTrack(
          id: '123',
          title: 'Track',
          artist: 'Artist',
          source: DiscoverySource.soundCloud,
        ),
      );
      expect(stream.codec, 'AAC');
      expect(calls, ['/tracks/123', '/media/123/aac']);
    },
  );

  test('SoundCloud preview is playable but not downloadable', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/tracks/123') {
        return http.Response(
          jsonEncode({
            'id': 123,
            'access': 'preview',
            'media': {
              'transcodings': [
                {
                  'url': 'https://api-v2.soundcloud.com/media/123/hls',
                  'format': {'protocol': 'hls', 'mime_type': 'audio/mp4'},
                },
              ],
            },
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({'url': 'https://cf-media.sndcdn.com/audio.m3u8'}),
        200,
      );
    });
    addTearDown(client.close);
    final source = SoundCloudSource(
      DiscoveryHttp(client),
      clientId: () async => key,
    );
    final track = DiscoveryTrack(
      id: '123',
      title: 'Preview',
      artist: 'Artist',
      source: DiscoverySource.soundCloud,
      inlineStream: const {'preview': true},
    );
    final preview = await source.resolve(track);
    expect(preview.url.path, '/audio.m3u8');
    expect(preview.isPreview, true);
    await expectLater(
      source.resolve(track, forDownload: true),
      throwsA(isA<DiscoveryException>()),
    );
  });

  test(
    'playback labels a preview confirmed only during stream resolution',
    () async {
      SharedPreferences.setMockInitialValues({
        soundCloudEnabledPreferenceKey: true,
      });
      addTearDown(DiscoveryProgressiveStreams.instance.clear);
      final client = MockClient((request) async {
        if (request.url.host == 'soundcloud.com') {
          return http.Response('client_id:"$key"', 200);
        }
        if (request.url.path == '/tracks/123') {
          return http.Response(
            jsonEncode({
              'id': 123,
              'access': 'preview',
              'media': {
                'transcodings': [
                  {
                    'url': 'https://api-v2.soundcloud.com/media/123/aac',
                    'format': {'protocol': 'hls', 'mime_type': 'audio/mp4'},
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'url': 'https://cf-media.sndcdn.com/preview.m3u8?sig=fixture',
          }),
          200,
        );
      });
      addTearDown(client.close);
      final song = await playOnlineTrack(
        'sc',
        const DiscoveryTrack(
          id: '123',
          title: 'Track',
          artist: 'Artist',
          source: DiscoverySource.soundCloud,
        ),
        client: client,
      );
      expect(song.sourceDisplayName, 'SoundCloud (preview)');
      expect(song.filePath, startsWith('lokal-progressive://'));
      expect(song.filePath, isNot(contains('sig=')));
    },
  );

  test(
    'SoundCloud disallows arbitrary CDN URLs and invalid source identities',
    () async {
      final client = MockClient((request) async {
        if (request.url.path == '/tracks/123') {
          return http.Response(
            jsonEncode({
              'id': 123,
              'access': 'playable',
              'media': {
                'transcodings': [
                  {
                    'url': 'https://api-v2.soundcloud.com/media/123/mp3',
                    'format': {
                      'protocol': 'progressive',
                      'mime_type': 'audio/mpeg',
                    },
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'url': 'https://evil.example/private.mp3'}),
          200,
        );
      });
      addTearDown(client.close);
      final source = SoundCloudSource(
        DiscoveryHttp(client),
        clientId: () async => key,
      );
      await expectLater(
        source.resolve(
          const DiscoveryTrack(
            id: '123',
            title: 'Track',
            artist: 'Artist',
            source: DiscoverySource.soundCloud,
          ),
        ),
        throwsA(isA<DiscoveryException>()),
      );
      await expectLater(
        source.resolve(
          const DiscoveryTrack(
            id: '../bad',
            title: 'Track',
            artist: 'Artist',
            source: DiscoverySource.soundCloud,
          ),
        ),
        throwsA(isA<DiscoveryException>()),
      );
      await expectLater(
        source.resolve(
          const DiscoveryTrack(
            id: '123',
            title: 'Track',
            artist: 'Artist',
            source: DiscoverySource.monochrome,
          ),
        ),
        throwsA(isA<DiscoveryException>()),
      );
    },
  );

  test('SoundCloud key finder accepts current web hydration', () {
    expect(
      SoundCloudSource.clientIdIn(
        '{"apiClient":{"data":{"id":"abcdefghijklmnopqrstuvwxyz123456"}}}',
      ),
      key,
    );
  });

  test(
    'SoundCloud CDN audio redirects are followed only inside sndcdn.com',
    () async {
      final visited = <String>[];
      final client = MockClient((request) async {
        visited.add(request.url.host);
        if (request.url.host == 'cf-media.sndcdn.com') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://cf2-media.sndcdn.com/song.mp3'},
          );
        }
        return http.Response('audio', 200);
      });
      addTearDown(client.close);
      final bytes = <int>[];
      await DiscoveryHttp(client).transfer(
        Uri.parse('https://cf-media.sndcdn.com/redirect'),
        maxBytes: 100,
        deadline: const Duration(seconds: 3),
        followMediaRedirects: true,
        onChunk: bytes.addAll,
      );
      expect(visited, ['cf-media.sndcdn.com', 'cf2-media.sndcdn.com']);
      expect(utf8.decode(bytes), 'audio');
    },
  );

  test('SoundCloud CDN redirects to other domains remain blocked', () async {
    final client = MockClient(
      (_) async => http.Response(
        '',
        302,
        headers: {'location': 'https://example.com/private-audio'},
      ),
    );
    addTearDown(client.close);
    await expectLater(
      DiscoveryHttp(client).transfer(
        Uri.parse('https://cf-media.sndcdn.com/audio'),
        maxBytes: 100,
        deadline: const Duration(seconds: 3),
        followMediaRedirects: true,
        onChunk: (_) {},
      ),
      throwsA(isA<DiscoveryException>()),
    );
  });
}
