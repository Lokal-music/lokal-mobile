import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flick/features/discovery/discovery_models.dart';

import 'dart:convert';

import 'package:flick/features/discovery/discovery_artwork.dart';
import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('album artwork matches soundtrack credits but rejects a different language', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'api.deezer.com') return _json({'data': []});
      return _json({'results': [
        {'collectionName': 'Dude (Telugu) [Original Motion Picture Soundtrack]',
          'artistName': 'Sai Abhyankkar', 'artworkUrl100': 'https://art.example/telugu-100x100bb.jpg'},
        {'collectionName': 'Dude', 'artistName': 'Someone Else',
          'artworkUrl100': 'https://art.example/wrong-100x100bb.jpg'},
        {'collectionName': 'Dude', 'artistName': 'Sai Abhyankkar',
          'artworkUrl100': 'https://art.example/tamil-100x100bb.jpg'},
      ]});
    });
    addTearDown(client.close);
    expect(await DiscoveryArtworkResolver(DiscoveryHttp(client)).resolve(
      const DiscoveryArtworkRequest(kind: DiscoveryArtworkKind.album,
        artist: 'Sai Abhyankar, Paal Dabba, Bhumi, Deepthi Suresh',
        title: 'Dude (Original Motion Picture Soundtrack)')),
      'https://art.example/tamil-1500x1500bb.jpg');
  });

  test('Discord/Discovery resolves Knuckle G local title variant from a broad lookup', () async {
    final terms = <String>[];
    final client = MockClient((request) async {
      if (request.url.host == 'itunes.apple.com') {
        final term = request.url.queryParameters['term'] ?? '';
        terms.add(term);
        if (term == 'Knuckle G biggest city') {
          return _json({
            'results': [
              {
                'trackName': 'Biggest of the City',
                'artistName': 'Other Artist',
                'artworkUrl100': 'https://is7-ssl.mzstatic.com/other-100x100bb.jpg',
              },
              {
                'trackName': 'Biggest of the City (Remix)',
                'artistName': 'Knuckle G',
                'artworkUrl100': 'https://is7-ssl.mzstatic.com/remix-100x100bb.jpg',
              },
              {
                'trackName': 'Biggest of the City',
                'artistName': 'Knuckle G',
                'artworkUrl100': 'https://is7-ssl.mzstatic.com/original-100x100bb.jpg',
              },
            ],
          });
        }
        return _json({'results': []});
      }
      return _json({'data': []});
    });
    addTearDown(client.close);
    final actual = await DiscoveryArtworkResolver(DiscoveryHttp(client)).resolve(
      const DiscoveryArtworkRequest(
        kind: DiscoveryArtworkKind.track,
        artist: 'Knuckle G',
        title: 'Biggest in the City',
      ),
    );
    expect(terms, contains('Knuckle G biggest city'));
    expect(actual, 'https://is7-ssl.mzstatic.com/original-600x600bb.jpg');
  });


  test('mobile Discord resolves Big Data - Dangerous with Joywave credited separately', () async {
    final terms = <String>[];
    final client = MockClient((request) async {
      if (request.url.host != 'itunes.apple.com') {
        return _json({'data': []});
      }
      terms.add(request.url.queryParameters['term'] ?? '');
      return _json({
        'results': [
          {
            'trackName': 'Dangerous',
            'artistName': 'David Guetta',
            'artworkUrl100': 'https://is7-ssl.mzstatic.com/wrong-100x100bb.jpg',
          },
          {
            'trackName': 'Dangerous (Oliver Remix)',
            'artistName': 'Big Data & Joywave',
            'artworkUrl100': 'https://is7-ssl.mzstatic.com/remix-100x100bb.jpg',
          },
          {
            'trackName': 'Dangerous',
            'artistName': 'Big Data & Joywave',
            'collectionName': '2.0',
            'trackTimeMillis': 280000,
            'artworkUrl100': 'https://is7-ssl.mzstatic.com/original-100x100bb.jpg',
          },
        ],
      });
    });
    addTearDown(client.close);
    const request = DiscoveryArtworkRequest(
      kind: DiscoveryArtworkKind.track,
      artist: 'Big Data',
      title: 'Dangerous',
    );
    // Strict Discovery matching must not be loosened.
    expect(await DiscoveryArtworkResolver(DiscoveryHttp(client)).resolve(request), '');
    // Discord's opt-in path accepts the exact title with a verified lead
    // artist and returns only the original, not the unrelated/remix hits.
    final discord = DiscoveryArtworkResolver(
      DiscoveryHttp(client),
      allowCollaborations: true,
    );
    expect(await discord.resolve(request),
        'https://is7-ssl.mzstatic.com/original-600x600bb.jpg');
    expect(terms, contains('Big Data Dangerous'));
  });

  test('Discord retries a one-word title broadly with the same-artist scorer', () async {
    final terms = <String>[];
    final client = MockClient((request) async {
      if (request.url.host != 'itunes.apple.com') {
        return _json({'data': []});
      }
      final term = request.url.queryParameters['term'] ?? '';
      terms.add(term);
      if (term != 'Big Data dangerous') return _json({'results': []});
      return _json({
        'results': [
          {
            'trackName': 'Dangerous',
            'artistName': 'Wrong Artist & Joywave',
            'artworkUrl100': 'https://is7-ssl.mzstatic.com/wrong-100x100bb.jpg',
          },
          {
            'trackName': 'Dangerous (Oliver Remix)',
            'artistName': 'Big Data & Joywave',
            'artworkUrl100': 'https://is7-ssl.mzstatic.com/remix-100x100bb.jpg',
          },
          {
            'trackName': 'Dangerous',
            'artistName': 'Big Data & Joywave',
            'artworkUrl100': 'https://is7-ssl.mzstatic.com/original-100x100bb.jpg',
          },
        ],
      });
    });
    addTearDown(client.close);
    final discord = DiscoveryArtworkResolver(
      DiscoveryHttp(client),
      allowCollaborations: true,
    );
    expect(await discord.resolve(const DiscoveryArtworkRequest(
      kind: DiscoveryArtworkKind.track,
      artist: 'Big Data',
      title: 'Dangerous',
    )), 'https://is7-ssl.mzstatic.com/original-600x600bb.jpg');
    expect(terms, contains('Big Data dangerous'));
  });

  late List<Uri> requests;
  late Map<String, Object> responses;
  late DateTime now;

  DiscoveryArtworkResolver resolver({
    Future<String?> Function(String)? artistPortrait,
    Future<List<DiscoveryTrack>> Function(String)? searchSongs,
  }) {
    final client = MockClient((request) async {
      requests.add(request.url);
      final key = '${request.url.host}${request.url.path}';
      final body = responses[key];
      return body == null ? http.Response('', 404) : _json(body);
    });
    return DiscoveryArtworkResolver(
      DiscoveryHttp(client),
      now: () => now,
      artistPortrait: artistPortrait,
      searchSongs: searchSongs,
    );
  }

  setUp(() {
    requests = [];
    responses = {};
    now = DateTime(2026, 10, 20, 12);
  });

  test('explicit Discord retry really re-queries a cached miss', () async {
    final subject = resolver();
    const request = DiscoveryArtworkRequest(
      kind: DiscoveryArtworkKind.track,
      artist: 'Knuckle G',
      title: 'Biggest of the City',
    );
    expect(await subject.resolve(request), '');
    final firstRequestCount = requests.length;
    expect(firstRequestCount, greaterThan(0));

    responses['api.deezer.com/search'] = {
      'data': [
        {
          'title': 'Biggest of the City',
          'artist': {'name': 'Knuckle G'},
          'album': {'cover_xl': 'https://e-cdns-images.dzcdn.net/images/cover/knuckle/500x500.jpg'},
        },
      ],
    };

    // A normal cached miss never contacts the service again.
    expect(await subject.resolve(request), '');
    expect(requests, hasLength(firstRequestCount));

    // Discord's later retry must clear only the negative result.
    subject.invalidateMiss(request);
    expect(await subject.resolve(request),
        'https://e-cdns-images.dzcdn.net/images/cover/knuckle/500x500.jpg');
    expect(requests.length, greaterThan(firstRequestCount));
  });

  test('Plastic Love uses an exact original match in another storefront, never a cover artist', () async {
    final countries = <String>[];
    final subject = DiscoveryArtworkResolver(
      DiscoveryHttp(
        MockClient((request) async {
          if (request.url.host != 'itunes.apple.com')
            return _json({'data': []});
          final country = request.url.queryParameters['country']!;
          countries.add(country);
          return _json({
            'results': [
              {
                'trackName': 'Plastic Love',
                'artistName': 'Friday Night Plans',
                'artworkUrl100': 'https://cdn.test/cover.jpg',
              },
              if (country == 'gb')
                {
                  'trackName': 'Plastic Love',
                  'artistName': 'Mariya Takeuchi',
                  'artworkUrl100': 'https://cdn.test/original-100x100bb.jpg',
                },
            ],
          });
        }),
      ),
    );
    expect(
      await subject.resolve(
        const DiscoveryArtworkRequest(
          kind: DiscoveryArtworkKind.track,
          artist: 'Mariya Takeuchi',
          title: 'Plastic Love',
        ),
      ),
      'https://cdn.test/original-600x600bb.jpg',
    );
    expect(countries, ['us', 'gb']);
  });

  test(
    'uses a real portrait fallback when Deezer has no artist picture',
    () async {
      final image =
          await resolver(
            artistPortrait: (name) async {
              expect(name, 'Artist');
              return 'https://cdn.test/portrait.jpg';
            },
          ).resolve(
            const DiscoveryArtworkRequest(
              kind: DiscoveryArtworkKind.artist,
              artist: 'Artist',
            ),
          );
      expect(image, 'https://cdn.test/portrait.jpg');
    },
  );

  test('matches remaster and guest-credit differences without selecting a remix cover', () async {
    responses['api.deezer.com/search'] = {
      'data': [
        {
          'title': 'Song (Remix)',
          'artist': {'name': 'Artist'},
          'album': {'cover_xl': 'https://cdn.test/remix.jpg'},
        },
        {
          'title': 'Song (2020 Remaster)',
          'artist': {'name': 'Artist'},
          'album': {'cover_xl': 'https://cdn.test/original.jpg'},
        },
      ],
    };
    final image = await resolver().resolve(
      const DiscoveryArtworkRequest(
        kind: DiscoveryArtworkKind.track,
        title: 'Song',
        artist: 'Artist feat. Guest',
      ),
    );
    expect(image, 'https://cdn.test/original.jpg');
  });

  test('desktop YouTube fallback supplies non-library covers after Deezer and iTunes miss', () async {
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.host == 'music.youtube.com') {
        return http.Response(
          'ytcfg.set({"INNERTUBE_CLIENT_VERSION":"fixture-current","VISITOR_DATA":"visitor"});',
          200,
        );
      }
      if (request.url.path == '/youtubei/v1/search') {
        final body = jsonDecode(request.body) as Map;
        expect(body['query'], 'Artist Song');
        expect(body['context']['client']['clientVersion'], 'fixture-current');
        expect(body['context']['client']['visitorData'], 'visitor');
        return _json({
          'contents': {
            'musicShelfRenderer': {
              'contents': [
                {
                  'musicResponsiveListItemRenderer': {
                    'playlistItemData': {'videoId': 'abcdefghijk'},
                    'flexColumns': [
                      {
                        'musicResponsiveListItemFlexColumnRenderer': {
                          'text': {
                            'runs': [
                              {'text': 'Song'},
                            ],
                          },
                        },
                      },
                      {
                        'musicResponsiveListItemFlexColumnRenderer': {
                          'text': {
                            'runs': [
                              {
                                'text': 'Artist',
                                'navigationEndpoint': {
                                  'browseEndpoint': {'browseId': 'UCartist'},
                                },
                              },
                            ],
                          },
                        },
                      },
                    ],
                    'thumbnail': {
                      'musicThumbnailRenderer': {
                        'thumbnail': {
                          'thumbnails': [
                            {
                              'url': 'https://cdn.test/song.jpg',
                              'width': 226,
                              'height': 226,
                            },
                          ],
                        },
                      },
                    },
                  },
                },
              ],
            },
          },
        });
      }
      return _json({'data': [], 'results': []});
    });
    addTearDown(client.close);
    final web = DiscoveryHttp(client);
    final subject = DiscoveryArtworkResolver(
      web,
      searchSongs: YoutubeMusicCatalog(web, refreshClientContext: true).search,
    );
    final image = await subject.resolve(
      const DiscoveryArtworkRequest(
        kind: DiscoveryArtworkKind.track,
        artist: 'Artist',
        title: 'Song',
      ),
    );
    expect(image, 'https://cdn.test/song.jpg');
  });

  test(
    'YouTube artwork fallback rejects a different recording and failed image',
    () async {
      final subject = resolver(
        searchSongs: (_) async => [
          const DiscoveryTrack(
            id: 'remix',
            title: 'Song (Remix)',
            artist: 'Artist',
            source: DiscoverySource.youtubeMusic,
            artwork: 'https://cdn.test/remix.jpg',
          ),
          const DiscoveryTrack(
            id: 'other',
            title: 'Song',
            artist: 'Someone else',
            source: DiscoverySource.youtubeMusic,
            artwork: 'https://cdn.test/other.jpg',
          ),
        ],
      );
      expect(
        await subject.resolve(
          const DiscoveryArtworkRequest(
            kind: DiscoveryArtworkKind.track,
            title: 'Song',
            artist: 'Artist',
          ),
        ),
        '',
      );
    },
  );

  group('discoveryImageUrl', () {
    test('rejects Last.fm placeholders and non-https images', () {
      expect(
        discoveryImageUrl(
          'https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png',
        ),
        '',
      );
      expect(discoveryImageUrl('https://x.test/default_album.png'), '');
      expect(discoveryImageUrl('https://x.test/noimage/a.png'), '');
      expect(discoveryImageUrl('https://api.deezer.com/artist//image'), '');
      expect(discoveryImageUrl('ftp://x.test/a.png'), '');
      expect(discoveryImageUrl(''), '');
      expect(
        discoveryImageUrl('http://x.test/cover.jpg'),
        'https://x.test/cover.jpg',
      );
    });
  });

  group('DiscoveryArtworkResolver', () {
    test('takes a Deezer track cover only on an exact match', () async {
      responses['api.deezer.com/search'] = {
        'data': [
          {
            'title': 'Halo (Remix)',
            'artist': {'name': 'Beyoncé'},
            'album': {'cover_xl': 'https://cdn.test/remix.jpg'},
          },
          {
            'title': 'Halo',
            'artist': {'name': 'Beyonce'},
            'album': {
              'cover_xl': 'https://cdn.test/2a96cbd8.jpg',
              'cover_big': 'https://cdn.test/halo.jpg',
            },
          },
        ],
      };
      final image = await resolver().resolve(
        const DiscoveryArtworkRequest(
          kind: DiscoveryArtworkKind.track,
          title: 'Halo',
          artist: 'Beyoncé',
        ),
      );
      expect(image, 'https://cdn.test/halo.jpg');
      expect(
        requests.single.queryParameters['q'],
        'artist:"Beyoncé" track:"Halo"',
      );
    });

    test('falls back to iTunes albums with a 1500px cover', () async {
      responses['api.deezer.com/search/album'] = {
        'data': [
          {
            'title': 'Other',
            'artist': {'name': 'Air'},
            'cover_xl': 'https://cdn.test/other.jpg',
          },
        ],
      };
      responses['itunes.apple.com/search'] = {
        'results': [
          {
            'collectionName': 'Moon Safari',
            'artistName': 'Air',
            'artworkUrl100': 'https://is1.test/a/100x100bb.jpg',
          },
        ],
      };
      final image = await resolver().resolve(
        const DiscoveryArtworkRequest(
          kind: DiscoveryArtworkKind.album,
          title: 'Moon Safari',
          artist: 'Air',
        ),
      );
      expect(image, 'https://is1.test/a/1500x1500bb.jpg');
      expect(requests.last.queryParameters['entity'], 'album');
    });

    test('finds artists on Deezer and skips the failed URL', () async {
      responses['api.deezer.com/search/artist'] = {
        'data': [
          {'name': 'Daft Punk', 'picture_xl': 'https://cdn.test/broken.jpg'},
          {'name': 'Daft Punk', 'picture_big': 'https://cdn.test/dp.jpg'},
        ],
      };
      final image = await resolver().resolve(
        const DiscoveryArtworkRequest(
          kind: DiscoveryArtworkKind.artist,
          artist: 'Daft Punk',
          exclude: 'https://cdn.test/broken.jpg',
        ),
      );
      expect(image, 'https://cdn.test/dp.jpg');
    });

    test('caches hits for a day and misses for five minutes', () async {
      final subject = resolver();
      const hit = DiscoveryArtworkRequest(
        kind: DiscoveryArtworkKind.artist,
        artist: 'Air',
      );
      responses['api.deezer.com/search/artist'] = {
        'data': [
          {'name': 'Air', 'picture_xl': 'https://cdn.test/air.jpg'},
        ],
      };
      expect(await subject.resolve(hit), 'https://cdn.test/air.jpg');
      now = now.add(const Duration(hours: 23));
      expect(await subject.resolve(hit), 'https://cdn.test/air.jpg');
      expect(requests, hasLength(1));
      now = now.add(const Duration(hours: 2));
      await subject.resolve(hit);
      expect(requests, hasLength(2));

      requests.clear();
      const miss = DiscoveryArtworkRequest(
        kind: DiscoveryArtworkKind.track,
        title: 'Nothing',
        artist: 'Nobody',
      );
      expect(await subject.resolve(miss), '');
      final missRequests = requests.length;
      now = now.add(const Duration(minutes: 4));
      expect(await subject.resolve(miss), '');
      expect(requests, hasLength(missRequests));
      now = now.add(const Duration(minutes: 2));
      await subject.resolve(miss);
      expect(requests.length, greaterThan(missRequests));
    });

    test(
      'dedupes concurrent lookups and ignores incomplete requests',
      () async {
        final subject = resolver();
        const request = DiscoveryArtworkRequest(
          kind: DiscoveryArtworkKind.track,
          title: 'Song',
          artist: 'Band',
        );
        await Future.wait([subject.resolve(request), subject.resolve(request)]);
        // One lookup: Deezer and two storefronts, shared by both callers.
        expect(requests, hasLength(3));
        expect(
          await subject.resolve(
            const DiscoveryArtworkRequest(
              kind: DiscoveryArtworkKind.track,
              artist: 'Band',
            ),
          ),
          '',
        );
        expect(requests, hasLength(3));
      },
    );
  });

  group('DiscoveryLocalArtwork', () {
    final library = DiscoveryLocalArtwork([
      const Song(
        id: '1',
        title: 'Café',
        artist: 'Feat Artist',
        albumArtist: 'Sigur Rós',
        album: 'Ágætis byrjun',
        albumArt: '/art/agaetis.jpg',
        duration: Duration(minutes: 3),
        filePath: '/music/cafe.flac',
        fileType: 'flac',
      ),
    ]);

    test('matches tracks and albums by normalised title and artist', () {
      expect(
        library.lookup(
          const DiscoveryArtworkRequest(
            kind: DiscoveryArtworkKind.track,
            title: 'cafe',
            artist: 'Sigur Ros',
          ),
        ),
        '/art/agaetis.jpg',
      );
      expect(
        library.lookup(
          const DiscoveryArtworkRequest(
            kind: DiscoveryArtworkKind.album,
            title: 'ÁGÆTIS byrjun',
            artist: 'sigur rós',
          ),
        ),
        '/art/agaetis.jpg',
      );
      expect(
        library.lookup(
          const DiscoveryArtworkRequest(
            kind: DiscoveryArtworkKind.track,
            title: 'Café',
            artist: 'Someone Else',
          ),
        ),
        isNull,
      );
      expect(
        library.lookup(
          const DiscoveryArtworkRequest(
            kind: DiscoveryArtworkKind.artist,
            artist: 'Sigur Rós',
          ),
        ),
        isNull,
      );
    });
  });
}
