import 'dart:convert';

import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/youtube_music_account.dart';
import 'package:flick/features/discovery/youtube_music_playlist_cache.dart';
import 'package:flick/features/spotify/provider_playlist_visibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> savedCard(String id, String title) => {
  'musicTwoRowItemRenderer': {
    'title': {'runs': [{'text': title}]},
    'navigationEndpoint': {
      'browseEndpoint': {
        'browseId': 'VL$id',
        'browseEndpointContextSupportedConfigs': {
          'browseEndpointContextMusicConfig': {
            'pageType': 'MUSIC_PAGE_TYPE_PLAYLIST',
          },
        },
      },
    },
  },
};

Map<String, dynamic> answer(Map<String, Object?> data) => {
  'responseContext': {
    'mainAppWebResponseContext': {'loggedOut': false},
  },
  ...data,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('YouTube Music saved playlist library pages, not the Home mixes', () async {
    final requests = <Map>[];
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      requests.add(body);
      final continuation = body['continuation'] != null;
      return http.Response(jsonEncode(answer({
        'gridRenderer': {
          'items': continuation
              ? [savedCard('PLsecond', 'Second playlist')]
              : [savedCard('PLfirst', 'First playlist'),
                  savedCard('RDpersonal', 'Radio mix')],
          if (!continuation) 'continuations': [
            {'nextContinuationData': {'continuation': 'page-two'}},
          ],
        },
      })), 200);
    });
    addTearDown(client.close);
    final account = YoutubeMusicAccount(
      client, const YoutubeMusicSession(cookies: {
        'SAPISID': 'fake-test-cookie',
      }),
    );
    final playlists = await account.libraryPlaylists();
    expect(playlists.map((p) => p.id), ['PLfirst', 'PLsecond']);
    expect(requests.map((r) => r['browseId']).toSet(),
        {'FEmusic_liked_playlists'});
    expect(requests.where((r) => r['continuation'] != null).length, 1);
  });

  test('persisted lists remain available with auto-update disabled; hidden choices are account scoped', () async {
    final now = DateTime.utc(2026, 10, 31);
    final cache = YoutubeMusicPlaylistCache(now: () => now);
    expect(await cache.autoUpdate, false);
    expect(await cache.playlists(List.filled(24, 'a').join()), null);
    await cache.setAutoUpdate(true);
    expect(await cache.autoUpdate, true);
    expect(await cache.due(List.filled(24, 'a').join(), 'library'), false);
    const visibility = ProviderPlaylistVisibility();
    const a = 'aaaaaaaaaaaaaaaaaaaaaaaa';
    const b = 'bbbbbbbbbbbbbbbbbbbbbbbb';
    expect(await visibility.hidden('youtube', a), isEmpty);
    expect(await visibility.setHidden('youtube', a, 'PLfirst', true), {'PLfirst'});
    expect(await visibility.hidden('youtube', b), isEmpty);
    expect(await visibility.hidden('spotify', a), isEmpty);
    expect(await visibility.setHidden('youtube', a, 'PLfirst', false), isEmpty);
  });

  test('library tracks reject invalid IDs and paginate valid playlists', () async {
    final requests = <Map>[];
    Map<String, Object?> track(String videoId, String title) => {
      'musicResponsiveListItemRenderer': {
        'playlistItemData': {'videoId': videoId},
        'flexColumns': [
          {'musicResponsiveListItemFlexColumnRenderer': {'text': {'runs': [
            {'text': title, 'navigationEndpoint': {'watchEndpoint': {'videoId': videoId}}},
          ]}}},
          {'musicResponsiveListItemFlexColumnRenderer': {'text': {'runs': [
            {'text': 'Artist'},
          ]}}},
        ],
      },
    };
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      requests.add(body);
      final next = body['continuation'] != null;
      return http.Response(jsonEncode(answer({
        'musicPlaylistShelfRenderer': {
          'contents': next
              ? [track('abcdefghijk', 'First'), track('lmnopqrstuv', 'Second')]
              : [track('abcdefghijk', 'First')],
          if (!next) 'continuations': [
            {'nextContinuationData': {'continuation': 'next-page'}},
          ],
        },
      })), 200);
    });
    addTearDown(client.close);
    final account = YoutubeMusicAccount(client,
        const YoutubeMusicSession(cookies: {'SAPISID': 'fake-test-cookie'}));
    for (final id in ['RDpersonal', '', 'PL/invalid', List.filled(121, 'x').join()]) {
      await expectLater(account.libraryPlaylistTracks(id), throwsA(isA<LokalDiscoveryFailure>()));
    }
    expect(requests, isEmpty);
    final tracks = await account.libraryPlaylistTracks('PLvalid');
    expect(tracks.map((track) => track.videoId), ['abcdefghijk', 'lmnopqrstuv']);
    expect(requests.map((request) => request['browseId']), ['VLPLvalid', 'VLPLvalid']);
    expect(requests.last['continuation'], 'next-page');
  });

  test('clearAll removes cached data from memory and disk only', () async {
    const account = 'aaaaaaaaaaaaaaaaaaaaaaaa';
    const prefix = 'lokal.youtube.playlists.cache.v1.';
    final data = jsonEncode({'version': 1, 'items': [
      {'id': 'PLfirst', 'title': 'First'},
    ]});
    SharedPreferences.setMockInitialValues({
      '${prefix}aaaaaaaaaaaaaaaaaaaaaaaa.library': data,
      '${prefix}bbbbbbbbbbbbbbbbbbbbbbbb.tracks.PLfirst': data,
      YoutubeMusicPlaylistCache.autoUpdateKey: true,
      'unrelated': 'keep',
    });
    final cache = YoutubeMusicPlaylistCache();
    expect((await cache.playlists(account))!.single.id, 'PLfirst');
    await cache.clearAll();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((key) => key.startsWith(prefix)), isEmpty);
    expect(await cache.playlists(account), isNull);
    expect(await YoutubeMusicPlaylistCache().playlists(account), isNull);
    expect(await cache.autoUpdate, isTrue);
    expect(prefs.getString('unrelated'), 'keep');
  });

}
