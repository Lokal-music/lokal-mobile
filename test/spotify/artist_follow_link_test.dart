import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/features/konnekted/library/artist_follow_store.dart';
import 'package:flick/features/konnekted/library/lokal_albums_artists.dart';
import 'package:flick/features/konnekted/library/lokal_library_groups.dart';
import 'package:flick/features/spotify/spotify_api.dart';
import 'package:flick/features/spotify/spotify_oauth.dart';
import 'package:flick/features/spotify/spotify_storage.dart';
import 'package:flick/features/spotify/spotify_web_api.dart';

class _Tokens implements SpotifyTokenStore {
  SpotifyTokens? value = SpotifyTokens(
    accessToken: 'fake-access',
    refreshToken: null,
    expiresAt: DateTime.utc(2030),
    sessionCookie: 'fixture-cookie',
  );

  @override
  Future<SpotifyTokens?> readTokens() async => value;
  @override
  Future<void> writeTokens(SpotifyTokens tokens) async => value = tokens;
  @override
  Future<void> clearTokens() async => value = null;
}

void main() {
  test(
    'concurrent heart changes retain both artists before and after reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = ArtistFollowStore();
      await store.load();
      await Future.wait([
        store.setFollowed('Artist A', true),
        store.setFollowed('Artist B', true),
      ]);
      expect(store.followedNames.toSet(), {'Artist A', 'Artist B'});
      final restored = ArtistFollowStore();
      await restored.load();
      expect(restored.followedNames.toSet(), {'Artist A', 'Artist B'});
    },
  );
  test(
    'existing follows migrate, import is additive and survives reload',
    () async {
      SharedPreferences.setMockInitialValues({
        'lokal.artist.follow.daftpunk': true,
        'lokal.artist.follow.beyonce': false,
      });
      final store = ArtistFollowStore();
      await store.load();
      expect(store.isFollowed('Daftpunk'), true);
      expect(store.isFollowed('Beyoncé'), false);

      final report = await store.importNames([
        'Daftpunk',
        'Beyoncé',
        'Beyonce',
        'Massive Attack',
      ]);
      expect(report.added, 2);
      expect(store.isFollowed('Beyoncé'), true);
      expect(store.isFollowed('Massive Attack'), true);
      expect((await store.importNames(['Massive Attack'])).added, 0);

      await store.setFollowed('Beyonce', false);
      final restored = ArtistFollowStore();
      await restored.load();
      expect(restored.isFollowed('Beyoncé'), false);
      expect(restored.isFollowed('Daftpunk'), true);
      expect(restored.isFollowed('Massive Attack'), true);

      final local = [const LokalArtist('Daftpunk', [])];
      final all = selectArtistFavorites(
        local,
        restored,
        ArtistFavoritesFilter.all,
      );
      expect(all.map((artist) => artist.name), contains('Massive Attack'));
      final liked = selectArtistFavorites(
        local,
        restored,
        ArtistFavoritesFilter.favorites,
      );
      expect(liked.map((artist) => artist.name), contains('Massive Attack'));
      expect(
        selectArtistFavorites(
          local,
          restored,
          ArtistFavoritesFilter.nonFavorites,
        ).map((artist) => artist.name).toSet(),
        {'Beyoncé'},
      );
      await store.setFollowed('Daftpunk', false);
      expect(
        selectArtistFavorites(
          local,
          store,
          ArtistFavoritesFilter.nonFavorites,
        ).map((artist) => artist.name).toSet(),
        {'Daftpunk', 'Beyoncé'},
      );
      await store.setFollowed('Massive Attack', false);
      expect(
        selectArtistFavorites(
          local,
          store,
          ArtistFavoritesFilter.nonFavorites,
        ).map((artist) => artist.name),
        contains('Massive Attack'),
      );
      final again = ArtistFollowStore();
      await again.load();
      expect(
        selectArtistFavorites(
          local,
          again,
          ArtistFavoritesFilter.nonFavorites,
        ).map((artist) => artist.name),
        contains('Massive Attack'),
      );
      await again.setFollowed('Massive Attack', true);
      expect(again.isFollowed('Massive Attack'), true);
    },
  );

  test(
    'Spotify follows use desktop-compatible libraryV3 and paginate',
    () async {
      final tokens = _Tokens();
      final offsets = <int>[];
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.host, 'api-partner.spotify.com');
        expect(request.url.path, '/pathfinder/v1/query');
        expect(request.url.queryParameters['operationName'], 'libraryV3');
        expect(request.headers['authorization'], 'Bearer fake-access');
        final variables =
            jsonDecode(request.url.queryParameters['variables']!) as Map;
        final offset = variables['offset'] as int;
        expect(variables['filters'], ['Artists']);
        offsets.add(offset);
        final entries = offset == 0
            ? ['Beyoncé', 'Massive Attack']
            : ['Daft Punk'];
        return http.Response(
          jsonEncode({
            'data': {
              'me': {
                'libraryV3': {
                  'totalCount': 3,
                  'items': [
                    for (final artist in entries)
                      {
                        'item': {
                          'data': {
                            '__typename': 'Artist',
                            'profile': {'name': artist},
                          },
                        },
                      },
                  ],
                },
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final api = SpotifyWebApi(
        store: tokens,
        oauth: SpotifyOAuthService(tokenStore: tokens),
        client: client,
      );
      addTearDown(api.close);
      expect(await api.getFollowedArtists(pageSize: 2), [
        'Beyoncé',
        'Massive Attack',
        'Daft Punk',
      ]);
      expect(offsets, [0, 2]);
    },
  );

  test(
    'incomplete Spotify response is an error, not an empty import',
    () async {
      final tokens = _Tokens();
      final api = SpotifyWebApi(
        store: tokens,
        oauth: SpotifyOAuthService(tokenStore: tokens),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': {'me': null},
              'errors': [
                {'message': 'Failed to load library'},
              ],
            }),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.getFollowedArtists(),
        throwsA(isA<SpotifyApiException>()),
      );
    },
  );

  test('import never deletes unrelated follows', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ArtistFollowStore();
    await store.setFollowed('Local Artist', true);
    await store.importNames(['Spotify Artist']);
    await store.importNames([]);
    expect(store.isFollowed('Local Artist'), true);
    expect(store.isFollowed('Spotify Artist'), true);
  });

  for (final fixture in [
    (
      'short page with remaining artists',
      {
        'totalCount': 3,
        'items': [
          {
            'item': {
              'data': {
                '__typename': 'Artist',
                'profile': {'name': 'A'},
              },
            },
          },
        ],
      },
    ),
    ('missing count', {'items': []}),
    ('negative count', {'totalCount': -1, 'items': []}),
  ]) {
    test('refuses incomplete Spotify artist import: ${fixture.$1}', () async {
      final tokens = _Tokens();
      final api = SpotifyWebApi(
        store: tokens,
        oauth: SpotifyOAuthService(tokenStore: tokens),
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'data': {
                  'me': {'libraryV3': fixture.$2},
                },
              }),
            ),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.getFollowedArtists(pageSize: 2),
        throwsA(isA<SpotifyApiException>()),
      );
    });
  }

  test(
    'GraphQL errors cannot qualify a partial artist library as complete',
    () async {
      final tokens = _Tokens();
      final api = SpotifyWebApi(
        store: tokens,
        oauth: SpotifyOAuthService(tokenStore: tokens),
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'data': {
                  'me': {
                    'libraryV3': {'totalCount': 0, 'items': []},
                  },
                },
                'errors': [
                  {'message': 'Upstream library unavailable'},
                ],
              }),
            ),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.getFollowedArtists(),
        throwsA(isA<SpotifyApiException>()),
      );
    },
  );
}
