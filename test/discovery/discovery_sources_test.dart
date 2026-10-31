import 'dart:async';
import 'dart:convert';

import 'package:flick/features/discovery/discovery_controller.dart';
import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/discovery_settings.dart';
import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> catalogRow({
  String id = 'abcdefghijk',
  String title = 'Fixture recording',
}) => {
  'musicResponsiveListItemRenderer': {
    'playlistItemData': {'videoId': id},
    'flexColumns': [
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {'text': title},
            ],
          },
        },
      },
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {
                'text': 'Fixture artist',
                'navigationEndpoint': {
                  'browseEndpoint': {'browseId': 'UC_artist'},
                },
              },
              {'text': ' • '},
              {
                'text': 'Fixture album',
                'navigationEndpoint': {
                  'browseEndpoint': {'browseId': 'MPRE_album'},
                },
              },
              {'text': ' • '},
              {'text': '3:42'},
            ],
          },
        },
      },
    ],
  },
};

Map<String, Object?> catalogResponse(List<Object?> rows) => {
  'contents': {
    'tabbedSearchResultsRenderer': {
      'tabs': [
        {
          'tabRenderer': {
            'content': {
              'sectionListRenderer': {
                'contents': [
                  {
                    'musicShelfRenderer': {'contents': rows},
                  },
                ],
              },
            },
          },
        },
      ],
    },
  },
};

const manifest = {
  'id': 'fixture',
  'name': 'Test addon',
  'resources': ['search', 'stream'],
};
http.Response jsonResponse(Object data, {int status = 200}) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);
Matcher get discoveryFailure => isA<DiscoveryException>();

void main() {
  group('guest YouTube Music catalog', () {
    test(
      'real request shape, metadata extraction, dedupe and source URL',
      () async {
        final client = MockClient((request) async {
          expect(request.url.host, 'music.youtube.com');
          expect(request.url.path, '/youtubei/v1/search');
          expect(request.method, 'POST');
          expect(request.followRedirects, isFalse);
          expect(
            request.headers.keys.map((k) => k.toLowerCase()),
            isNot(contains('authorization')),
          );
          expect(
            request.headers.keys.map((k) => k.toLowerCase()),
            isNot(contains('cookie')),
          );
          final body = jsonDecode(request.body) as Map;
          expect(body['query'], 'fixture artist');
          expect(body['params'], 'EgWKAQIIAWoKEAkQChAFEAMQBA==');
          expect(body['context']['client']['clientName'], 'WEB_REMIX');
          return jsonResponse(
            catalogResponse([
              catalogRow(),
              catalogRow(),
              catalogRow(id: '../not-an-id'),
              {
                'musicResponsiveListItemRenderer': {'flexColumns': 'bad'},
              },
              {
                'musicResponsiveListItemRenderer': {
                  'navigationEndpoint': {
                    'browseEndpoint': {'browseId': 'album'},
                  },
                },
              },
            ]),
          );
        });
        addTearDown(client.close);
        final tracks = await YoutubeMusicCatalog(DiscoveryHttp(client))
            .search(' fixture artist ');
        expect(tracks, hasLength(1));
        final track = tracks.single;
        expect(track.title, 'Fixture recording');
        expect(track.artist, 'Fixture artist');
        expect(track.album, 'Fixture album');
        expect(track.duration, const Duration(seconds: 222));
        expect(
          track.sourceUrl.toString(),
          'https://music.youtube.com/watch?v=abcdefghijk',
        );
        expect(track.inlineStream, isNull);
        expect(track.addonBase, isNull);
      },
    );

    test('search rows retain largest original https cover for fallback', () {
      final row = catalogRow();
      (row['musicResponsiveListItemRenderer'] as Map)['thumbnail'] = {
        'musicThumbnailRenderer': {
          'thumbnail': {
            'thumbnails': [
              {
                'url': 'https://lh3.googleusercontent.com/abc=w60-h60-l90-rj',
                'width': 60,
              },
              {
                'url': 'https://lh3.googleusercontent.com/abc=w120-h120-l90-rj',
                'width': 120,
              },
              {'url': 'http://insecure.example/big.jpg', 'width': 999},
            ],
          },
        },
      };
      final track = YoutubeMusicCatalog.parse(catalogResponse([row])).single;
      expect(
        track.artwork,
        'https://lh3.googleusercontent.com/abc=w120-h120-l90-rj',
      );

      // Video thumbnails aren't resized; rows without one have no cover.
      expect(
        YoutubeMusicCatalog.thumbnail({
          'thumbnail': {
            'musicThumbnailRenderer': {
              'thumbnail': {
                'thumbnails': [
                  {'url': 'https://i.ytimg.com/vi/x/sddefault.jpg'},
                ],
              },
            },
          },
        }),
        'https://i.ytimg.com/vi/x/sddefault.jpg',
      );
      expect(
        YoutubeMusicCatalog.parse(catalogResponse([catalogRow()]))
            .single
            .artwork,
        isNull,
      );
    });

    test('empty contents is empty; malformed response is an error', () {
      expect(YoutubeMusicCatalog.parse(catalogResponse([])), isEmpty);
      for (final bad in <Map<String, dynamic>>[
        {},
        {'error': {}},
        {'contents': []},
      ]) {
        expect(() => YoutubeMusicCatalog.parse(bad), throwsA(discoveryFailure));
      }
    });

    test('title navigation endpoint and fixed duration are accepted', () {
      final response = catalogResponse([
        {
          'musicResponsiveListItemRenderer': {
            'flexColumns': [
              {
                'musicResponsiveListItemFlexColumnRenderer': {
                  'text': {
                    'runs': [
                      {
                        'text': 'Title',
                        'navigationEndpoint': {
                          'watchEndpoint': {'videoId': '123456789_0'},
                        },
                      },
                    ],
                  },
                },
              },
            ],
            'fixedColumns': [
              {
                'musicResponsiveListItemFixedColumnRenderer': {
                  'text': {
                    'runs': [
                      {'text': '1:02:03'},
                    ],
                  },
                },
              },
            ],
          },
        },
      ]);
      expect(
        YoutubeMusicCatalog.parse(response).single.duration,
        const Duration(seconds: 3723),
      );
    });
  });

  group('opt-in and partial failure', () {
    test(
      'disabled sources make no requests, including with a saved endpoint',
      () async {
        final client = MockClient(
          (_) async => fail('Unexpected network request'),
        );
        addTearDown(client.close);
        final results = await searchDiscovery(
          DiscoveryHttp(client),
          const DiscoverySettings(
            addons: [
              DiscoveryAddonConfig(
                id: 'saved',
                endpoint: 'https://addon.example',
              ),
            ],
          ),
          'music',
        );
        expect(results.tracks, isEmpty);
        expect(results.errors, isEmpty);
      },
    );

    test(
      'addon results survive a catalog outage without substituting tracks',
      () async {
        final client = MockClient(
          (request) async => request.url.host == 'music.youtube.com'
              ? http.Response('down', 503)
              : jsonResponse({
                  'tracks': [
                    {'id': 'owned', 'title': 'Owned recording'},
                  ],
                }),
        );
        addTearDown(client.close);
        final results = await searchDiscovery(
          DiscoveryHttp(client),
          const DiscoverySettings(
            youtubeEnabled: true,
            addons: [
              DiscoveryAddonConfig(
                id: 'owned',
                endpoint: 'https://addon.example',
                enabled: true,
              ),
            ],
          ),
          'music',
        );
        expect(results.tracks.single.id, 'owned');
        expect(results.errors.single, contains('YouTube Music'));
      },
    );
  });

  group('addon protocol and trust boundary', () {
    test('Qobuz sample CDN and declared preview are never full audio', () {
      final client = MockClient((_) async => fail('No network expected'));
      addTearDown(client.close);
      final addon = DiscoveryAddon(
        DiscoveryHttp(client), endpoint: 'https://addon.example',
      );
      expect(
        () => addon.parseStream({'url': 'https://sample2.qobuz.com/file'}),
        throwsA(isA<DiscoveryException>()),
      );
      expect(
        () => addon.parseStream({
          'url': 'https://cdn.example/audio.flac', 'isPreview': true,
        }),
        throwsA(isA<DiscoveryException>()),
      );
      expect(
        () => addon.parseStream({
          'url': 'https://cdn.example/audio.mp3', 'duration': 30,
        }, expectedDuration: const Duration(seconds: 224)),
        throwsA(isA<DiscoveryException>()),
      );
      // A zero/invalid early alias must not mask a later 30-second preview.
      for (final firstClaim in [0, -1, 'invalid', null]) {
        expect(
          () => addon.parseStream({
            'url': 'https://cdn.example/audio.mp3',
            'streamDuration': firstClaim,
            'duration': 30,
          }, expectedDuration: const Duration(seconds: 220)),
          throwsA(isA<DiscoveryException>()),
        );
      }
      // A real short recording is not a preview just because it is short.
      expect(
        addon.parseStream({
          'url': 'https://cdn.example/short.mp3', 'duration': 35,
        }, expectedDuration: const Duration(seconds: 35)).url.path,
        '/short.mp3',
      );
    });

    test('a Qobuz inline sample retries the dedicated stream endpoint', () async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path == '/search') {
          return jsonResponse({
            'tracks': [{
              'id': 'song-1',
              'title': 'Full recording',
              'artist': 'Artist',
              'duration': 220,
              'streamURL': 'https://sample2.qobuz.com/file',
            }],
          });
        }
        if (request.url.path == '/stream/song-1') {
          return jsonResponse({
            'url': 'https://cdn.example/full.flac',
            'format': 'audio/flac',
          });
        }
        return http.Response('missing', 404);
      });
      addTearDown(client.close);
      final addon = DiscoveryAddon(
        DiscoveryHttp(client),
        endpoint: 'https://addon.example',
        configId: 'qobuz',
      );
      final track = (await addon.search('Full recording')).single;
      final resolved = await addon.resolve(track);
      expect(resolved.url.toString(), 'https://cdn.example/full.flac');
      expect(requests, ['/search', '/stream/song-1']);
    });

    test(
      'normalizes manifest URL, encodes ids and keeps credentials on API',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/manifest.json')) {
            return jsonResponse(manifest);
          }
          if (request.url.path.endsWith('/search')) {
            expect(request.url.queryParameters['q'], 'a & b');
            return jsonResponse({
              'tracks': [
                {
                  'id': 'folder/track?x=1',
                  'title': 'Authorized recording',
                  'artist': 'Artist',
                  'duration': 240.5,
                  'sourceURL': 'https://catalog.example/song?id=12',
                  'audioQuality': 'HI_RES_LOSSLESS',
                  'codec': 'flac',
                  'bitDepth': 24,
                  'sampleRate': 96000,
                },
              ],
            });
          }
          expect(request.url.pathSegments.last, 'folder/track?x=1');
          expect(request.url.query, isEmpty);
          return jsonResponse({
            'url': 'https://cdn.example/file?sig=private',
            'quality': '24-bit FLAC',
          });
        });
        addTearDown(client.close);
        final addon = DiscoveryAddon(
          DiscoveryHttp(client),
          endpoint: 'https://addon.example/base/manifest.json/',
          token: 'fixture-token',
        );
        expect(addon.base.toString(), 'https://addon.example/base');
        expect((await addon.health()).name, 'Test addon');
        final tracks = await addon.search('a & b');
        expect(tracks.single.duration, const Duration(milliseconds: 240500));
        expect(tracks.single.catalogueQuality, 'HI_RES_LOSSLESS');
        expect(tracks.single.catalogueCodec, 'FLAC');
        expect(tracks.single.catalogueBitDepth, 24);
        expect(tracks.single.catalogueSampleRate, 96000);
        expect(
          tracks.single.sourceUrl.toString(),
          'https://catalog.example/song?id=12',
        );
        expect(
          (await addon.resolve(tracks.single)).url.toString(),
          'https://cdn.example/file?sig=private',
        );
        expect(requests, hasLength(3), reason: 'Stream playback skips the redundant manifest fetch');
        for (final request in requests) {
          expect(request.headers['Authorization'], 'Bearer fixture-token');
          expect(request.url.host, 'addon.example');
          expect(request.followRedirects, isFalse);
        }
      },
    );

    test('HTTP provider quality fields are optional, invalid claims are ignored', () {
      expect(providerAudioCodec({'codec': 'audio/flac'}), 'FLAC');
      expect(providerAudioCodec({'codec': 'not-recognized'}), isNull);
      expect(providerAudioInteger({'bitDepth': '24'},
          const ['bitDepth'], min: 8, max: 64), 24);
      expect(providerAudioInteger({'sampleRate': 96000},
          const ['sampleRate'], min: 8000), 96000);
      expect(providerAudioInteger({'sampleRate': '999999999'},
          const ['sampleRate'], min: 8000), isNull);
    });

    test('inline stream keeps DRM flags and does not bypass policy', () async {
      final client = MockClient(
        (request) async => request.url.path.endsWith('manifest.json')
            ? jsonResponse(manifest)
            : jsonResponse({
                'tracks': [
                  {
                    'id': '1',
                    'title': 'Encrypted fixture',
                    'streamURL': 'https://cdn.example/audio',
                    'encrypted': true,
                  },
                ],
              }),
      );
      addTearDown(client.close);
      final addon = DiscoveryAddon(
        DiscoveryHttp(client),
        endpoint: 'https://addon.example',
      );
      final tracks = await addon.search('fixture');
      await expectLater(
        addon.resolve(tracks.single),
        throwsA(discoveryFailure),
      );
    });

    test('foreign-source results fail before contacting a server', () async {
      final client = MockClient((_) async => fail('Unexpected request'));
      addTearDown(client.close);
      final addon = DiscoveryAddon(
        DiscoveryHttp(client),
        endpoint: 'https://addon.example',
      );
      await expectLater(
        addon.resolve(
          DiscoveryTrack(
            id: '1',
            title: 't',
            artist: 'a',
            source: DiscoverySource.addon,
            addonBase: Uri.parse('https://other.example'),
          ),
        ),
        throwsA(discoveryFailure),
      );
    });

    test('download-prohibited addon permits streaming, not saving', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/manifest.json');
        return jsonResponse({...manifest, 'allowDownloads': false});
      });
      addTearDown(client.close);
      final addon = DiscoveryAddon(
        DiscoveryHttp(client),
        endpoint: 'https://addon.example',
      );
      final track = DiscoveryTrack(
        id: '1',
        title: 't',
        artist: 'a',
        source: DiscoverySource.addon,
        addonBase: addon.base,
        inlineStream: const {'url': 'https://cdn.example/song.flac'},
      );
      expect((await addon.health()).cacheAllowed, isFalse);
      final stream = await addon.resolve(track);
      expect(stream.url.toString(), 'https://cdn.example/song.flac');
      await expectLater(
        addon.resolve(track, forDownload: true),
        throwsA(discoveryFailure),
      );
    });

    test(
      'missing manifest resources and invalid track arrays are reported',
      () async {
        final client = MockClient(
          (request) async => jsonResponse(
            request.url.path.endsWith('manifest.json')
                ? {
                    'id': 'incomplete',
                    'resources': ['search'],
                  }
                : {'tracks': 'wrong'},
          ),
        );
        addTearDown(client.close);
        final addon = DiscoveryAddon(
          DiscoveryHttp(client),
          endpoint: 'https://addon.example',
        );
        await expectLater(addon.health(), throwsA(discoveryFailure));
        await expectLater(addon.search('x'), throwsA(discoveryFailure));
      },
    );

    test(
      'malformed rows are skipped, duplicates collapsed, empty is genuine',
      () async {
        var empty = false;
        final client = MockClient(
          (_) async => jsonResponse({
            'tracks': empty
                ? []
                : [
                    null,
                    'bad',
                    {'id': '..', 'title': 'unsafe'},
                    {'id': 'no-title'},
                    {
                      'id': 'ok',
                      'title': 'Title',
                      'artist': 123,
                      'duration': -4,
                      'sourceURL': 'file:///tmp/audio',
                    },
                    {'id': 'ok', 'title': 'Duplicate'},
                  ],
          }),
        );
        addTearDown(client.close);
        final addon = DiscoveryAddon(
          DiscoveryHttp(client),
          endpoint: 'https://addon.example',
        );
        final result = await addon.search('x');
        expect(result, hasLength(1));
        expect(result.single.duration, isNull);
        expect(result.single.sourceUrl, isNull);
        empty = true;
        expect(await addon.search('x'), isEmpty);
      },
    );

    test('unsafe configuration is rejected without a request', () {
      for (final value in [
        'http://addon.example',
        'https://user:pass@addon.example',
        'https://addon.example?token=secret',
        'https://addon.example#fragment',
        'file:///audio',
        'https://addon.example/../escape',
      ]) {
        expect(
          () => normalizeAddonEndpoint(value),
          throwsA(discoveryFailure),
          reason: value,
        );
      }
    });

    test(
      'resolve rejects insecure URLs, playlists, encryption and headers',
      () {
        final client = MockClient((_) async => fail('Unexpected request'));
        addTearDown(client.close);
        final addon = DiscoveryAddon(
          DiscoveryHttp(client),
          endpoint: 'https://addon.example',
        );
        final cases = <Map<String, dynamic>>[
          {},
          {'url': 'http://cdn.example/audio'},
          {'url': 'file:///music.flac'},
          {'url': 'https://user:password@cdn.example/audio'},
          {'url': 'https://cdn.example/audio#fragment'},
          {'url': 'https://127.0.0.1/audio'},
          {'url': 'https://[::1]/audio'},
          {'url': 'https://localhost/audio'},
          {'url': 'https://router.local/audio'},
          {'url': 'https://cdn.example/audio.mpd'},
          {'url': 'https://cdn.example/list.m3u8'},
          {'url': 'https://cdn.example/audio', 'manifest': 'dash'},
          {
            'url': 'https://cdn.example/audio',
            'mimeType': 'application/vnd.apple.mpegurl',
          },
          {'url': 'https://cdn.example/audio', 'manifest': {}},
          {'url': 'https://cdn.example/audio', 'encrypted': 'widevine'},
          {'url': 'https://cdn.example/audio', 'encrypted': {}},
          {'url': 'https://cdn.example/audio', 'drm': true},
          {
            'url': 'https://cdn.example/audio',
            'headers': {'Authorization': 'stolen'},
          },
        ];
        for (final json in cases) {
          expect(
            () => addon.parseStream(json),
            throwsA(discoveryFailure),
            reason: json.toString(),
          );
        }
        expect(
          addon
              .parseStream({
                'url': 'https://cdn.example/audio?signature=ok',
                'encrypted': false,
              })
              .url
              .scheme,
          'https',
        );
      },
    );

    test('only explicitly configured LAN origin can serve LAN media', () {
      final client = MockClient((_) async => fail('Unexpected request'));
      addTearDown(client.close);
      final addon = DiscoveryAddon(
        DiscoveryHttp(client),
        endpoint: 'https://192.168.1.10:8443',
      );
      expect(
        addon.parseStream({'url': 'https://192.168.1.10:8443/file'}).url.host,
        '192.168.1.10',
      );
      expect(
        () => addon.parseStream({'url': 'https://192.168.1.11/file'}),
        throwsA(discoveryFailure),
      );
    });
  });

  group('bounded transport', () {
    test('already cancelled requests do not contact the endpoint', () async {
      final client = MockClient(
        (_) async => fail('Cancelled request was sent'),
      );
      addTearDown(client.close);
      final cancel = Completer<void>()..complete();
      await expectLater(
        DiscoveryHttp(client)
            .json(Uri.parse('https://addon.example'), cancel: cancel.future),
        throwsA(discoveryFailure),
      );
    });

    test('automatic fallback cancellation interrupts addon search', () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final cancel = Completer<void>();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.url.path, '/search');
        started.complete();
        return response.future;
      });
      addTearDown(client.close);
      final addon = DiscoveryAddon(
        DiscoveryHttp(client), endpoint: 'https://addon.example',
      );
      final pending = addon.search('Artist song', cancel: cancel.future);
      final assertion = expectLater(
        pending,
        throwsA(isA<DiscoveryException>().having(
          (error) => error.message, 'message', 'Request cancelled.',
        )),
      );
      await started.future;
      cancel.complete();
      await assertion;
      response.complete(jsonResponse({'tracks': []}));
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
    });

    test('cancelling a Qobuz stream lookup aborts the one direct stream request', () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final cancel = Completer<void>();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.url.path, '/stream/1');
        started.complete();
        return response.future;
      });
      addTearDown(client.close);
      final addon = DiscoveryAddon(
        DiscoveryHttp(client),
        endpoint: 'https://addon.example',
      );
      final pending = addon.resolve(
        DiscoveryTrack(
          id: '1',
          title: 'Title',
          artist: 'Artist',
          source: DiscoverySource.addon,
          addonBase: addon.base,
        ),
        cancel: cancel.future,
      );
      final assertion = expectLater(pending, throwsA(discoveryFailure));
      await started.future;
      cancel.complete();
      await assertion;
      response.complete(jsonResponse({'url': 'https://cdn.example/song.flac'}));
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
    });

    test(
      'redirects are refused and remote error bodies never disclosed',
      () async {
        for (final status in [302, 401, 403, 429, 500]) {
          final client = MockClient((request) async {
            expect(request.followRedirects, isFalse);
            return http.Response(
              'private-token-and-url',
              status,
              headers: {'location': 'http://unsafe.example'},
            );
          });
          addTearDown(client.close);
          await expectLater(
            DiscoveryHttp(client).json(Uri.parse('https://addon.example')),
            throwsA(
              isA<DiscoveryException>().having(
                (e) => e.message,
                'safe message',
                isNot(contains('private-token')),
              ),
            ),
          );
        }
      },
    );

    test('bad JSON, non-object and oversized responses fail', () async {
      for (final body in [
        '<html>bad</html>',
        '[]',
        'x' * (DiscoveryHttp.jsonLimit + 1),
      ]) {
        final client = MockClient((_) async => http.Response(body, 200));
        addTearDown(client.close);
        await expectLater(
          DiscoveryHttp(client).json(Uri.parse('https://addon.example')),
          throwsA(discoveryFailure),
        );
      }
    });

    test(
      'header wait has an absolute timeout with an injected client',
      () async {
        final response = Completer<http.Response>();
        final client = MockClient((_) => response.future);
        addTearDown(client.close);
        await expectLater(
          DiscoveryHttp(
            client,
            timeout: const Duration(milliseconds: 10),
          ).json(Uri.parse('https://addon.example')),
          throwsA(
            isA<DiscoveryException>().having(
              (e) => e.message,
              'timeout',
              contains('timed out'),
            ),
          ),
        );
        response.complete(jsonResponse({}));
        await Future<void>.delayed(Duration.zero);
      },
    );

    test('slow trickle cannot extend the overall deadline', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(controller.stream, 200),
      );
      addTearDown(client.close);
      final transport = DiscoveryHttp(
        client,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        transport.json(Uri.parse('https://addon.example')),
        throwsA(discoveryFailure),
      );
      expect(cancelled, isTrue);
      await controller.close();
    });
  });
}
