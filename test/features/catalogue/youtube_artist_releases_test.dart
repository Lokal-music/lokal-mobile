import 'dart:convert';

import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flick/features/konnekted/library/lokal_online_catalogue.dart';
import 'package:flick/features/konnekted/library/youtube_artist_releases.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> artistRow(String name, String id) => {
  'musicTwoRowItemRenderer': {
    'title': {'runs': [{'text': name}]},
    'navigationEndpoint': {'browseEndpoint': {'browseId': id}},
  },
};

Map<String, Object?> releaseRow(String title, String artist, String id) => {
  'musicTwoRowItemRenderer': {
    'title': {'runs': [{'text': title}]},
    'subtitle': {'runs': [
      {'text': 'Album'}, {'text': ' • '}, {'text': artist},
    ]},
    'navigationEndpoint': {'browseEndpoint': {'browseId': id}},
  },
};

Map<String, Object?> releaseShelf(
  String kind, List<Map<String, Object?>> items, {String? more},
) => {
  'musicCarouselShelfRenderer': {
    'header': {
      'musicCarouselShelfBasicHeaderRenderer': {
        'title': {'runs': [{'text': kind}]},
        if (more != null)
          'moreContentButton': {'buttonRenderer': {
            'navigationEndpoint': {'browseEndpoint': {'browseId': more}},
          }},
      },
    },
    'contents': items,
  },
};

void main() {
  test('artist search accepts only exact names and real artist-channel IDs', () {
    expect(youtubeArtistChannelCandidates({
      'contents': [
        artistRow('Asake Fan', 'UCabcdefghijklmnop'),
        artistRow('Asake', 'MPREnotAChannel'),
        artistRow('Asake', 'UC9876543210abcdef'),
      ],
    }, 'Asake'), ['UC9876543210abcdef']);
  });

  test('release sections keep albums, singles, EPs and the correct artist', () {
    final albums = parseYoutubeArtistChannelReleases({
      'contents': [
        releaseShelf('Albums', [
          releaseRow('Mr. Money With The Vibe', 'Asake', 'MPREfirst'),
          releaseRow('Wrong Artist', 'Asake Fan', 'MPREother'),
        ]),
        releaseShelf('Singles & EPs', [
          releaseRow('New Single', 'Asake', 'MPREsingle'),
        ]),
        releaseShelf('EPs', [
          releaseRow('Ololade Asake', 'Asake', 'MPREep'),
        ]),
      ],
    }, 'Asake');
    expect(albums.map((a) => a.title), [
      'Mr. Money With The Vibe', 'New Single', 'Ololade Asake',
    ]);
    expect(albums.map((a) => a.kind), [
      LokalReleaseKind.album, LokalReleaseKind.single, LokalReleaseKind.ep,
    ]);
    expect(albums.first.url, contains('MPREfirst'));
  });

  test('guest artist channel follows its releases shelf without login', () async {
    final seen = <String>[];
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path.endsWith('/search')) {
        expect(body['params'], youtubeArtistFilter);
        expect(body['query'], 'Davido');
        return http.Response(jsonEncode({
          'contents': [artistRow('Davido', 'UCabcdefghijklmnop')],
        }), 200);
      }
      expect(request.url.path, endsWith('/browse'));
      final id = body['browseId'].toString();
      seen.add(id);
      if (id == 'UCabcdefghijklmnop') {
        return http.Response(jsonEncode({
          'contents': [
            releaseShelf('Albums', [
              releaseRow('A Good Time', 'Davido', 'MPREalbumOne'),
              releaseRow('Timeless', 'Davido', 'MPREalbumTwo'),
            ], more: 'MPLYmoreReleases'),
          ],
        }), 200);
      }
      if (id == 'MPLYmoreReleases') {
        return http.Response(jsonEncode({
          'contents': [
            releaseRow('5ive', 'Davido', 'MPREalbumThree'),
            releaseRow('Not by Davido', 'Random Artist', 'MPREbad'),
          ],
        }), 200);
      }
      return http.Response('{}', 404);
    });
    final catalogue = YoutubeMusicCatalog(DiscoveryHttp(client),
      refreshClientContext: false);
    final results = await loadYoutubeArtistReleases(
      'Davido', catalogue: catalogue,
    );
    expect(results.map((a) => a.title), ['A Good Time', 'Timeless', '5ive']);
    expect(seen, ['UCabcdefghijklmnop', 'MPLYmoreReleases']);
    client.close();
  });
}
