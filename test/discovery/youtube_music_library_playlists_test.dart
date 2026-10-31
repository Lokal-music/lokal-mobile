import 'dart:convert';

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
}
