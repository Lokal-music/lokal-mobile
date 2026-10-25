import 'dart:async';
import 'dart:convert';

import 'package:flick/features/playlist_links/playlist_link_http.dart';
import 'package:flick/features/playlist_links/playlist_link_importers.dart';
import 'package:flick/features/playlist_links/playlist_link_models.dart';
import 'package:flick/features/playlist_links/playlist_link_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import 'playlist_link_importers_test.dart' show FakeTransport;

PlaylistLinkHttpResponse jsonResponse(Object value) =>
    PlaylistLinkHttpResponse(statusCode: 200, body: jsonEncode(value));
const providerUrls = {
  PlaylistLinkSource.tidal:
      'https://listen.tidal.com/playlist/12345678-abcd-1234-abcd-123456789abc',
  PlaylistLinkSource.apple:
      'https://music.apple.com/fr/playlist/my-mix/pl.u-abc123',
  PlaylistLinkSource.qobuz: 'https://www.qobuz.com/fr-fr/playlist/my-mix/12345',
  PlaylistLinkSource.deezer: 'https://www.deezer.com/fr/playlist/12345?utm=x',
};

void main() {
  test(
    'new providers parse full links, stable identities and source labels',
    () {
      for (final entry in providerUrls.entries) {
        final parsed = PlaylistLinkParser.parse(entry.value);
        expect(parsed.source, entry.key);
        expect(parsed.source.label, isNotEmpty);
        expect(
          PlaylistLinkParser.parse(parsed.canonicalUrl).linkId,
          parsed.linkId,
        );
        expect(parsed.canonicalUrl, isNot(contains('utm=')));
      }
    },
  );

  test(
    'reject host spoofing, credentials, album links and extra path segments',
    () {
      for (final url in [
        'https://deezer.com.evil.test/playlist/12345',
        'https://user@deezer.com/playlist/12345',
        'https://www.qobuz.com/album/mix/12345',
        'https://music.apple.com.evil.test/fr/playlist/mix/pl.u-abc123',
        'https://www.deezer.com/playlist/12345/track/1',
        'https://tidal.com/playlist/not-an-id',
      ]) {
        expect(
          () => PlaylistLinkParser.parse(url),
          throwsA(isA<PlaylistLinkFormatException>()),
          reason: url,
        );
      }
    },
  );

  for (final provider in [
    PlaylistLinkSource.tidal,
    PlaylistLinkSource.apple,
    PlaylistLinkSource.qobuz,
  ]) {
    test(
      '${provider.label} dispatches link handler and normalizes add-on metadata conservatively',
      () async {
        final link = PlaylistLinkParser.parse(providerUrls[provider]!);
        final importer = PublicPlaylistImporter(
          transport: FakeTransport({}),
          addonReader: (parsed) async {
            expect(parsed.linkId, link.linkId);
            final payload = {
              'name': 'Mix',
              'tracks': [
                {
                  'id': 123,
                  'name': 'Song',
                  'artists': [
                    {'name': 'Artist'},
                    'Guest',
                  ],
                  'album': {'name': 'Album'},
                  'duration_ms': 123000,
                },
              ],
            };
            return provider == PlaylistLinkSource.tidal
                ? payload
                : {'playlist': payload};
          },
        );
        final result = await importer.fetch(link);
        expect(result.title, 'Mix');
        expect(result.entries.single.artist, 'Artist, Guest');
        expect(result.entries.single.album, 'Album');
        expect(result.entries.single.remoteId, '123');
        expect(result.entries.single.duration, const Duration(seconds: 123));
        expect(result.complete, false);
        importer.close();
      },
    );
  }

  test(
    'add-on verification errors are actionable and cancellation stops waiting',
    () async {
      final link = PlaylistLinkParser.parse(
        providerUrls[PlaylistLinkSource.tidal]!,
      );
      final importer = PublicPlaylistImporter(
        transport: FakeTransport({}),
        addonReader: (_) async => {'error': 'VERIFY_REQUIRED'},
      );
      await expectLater(
        importer.fetch(link),
        throwsA(
          isA<PlaylistLinkHttpException>().having(
            (e) => e.message,
            'message',
            contains('Settings → Add-ons'),
          ),
        ),
      );
      final pending = Completer<Object?>();
      final waiting = PublicPlaylistImporter(
        transport: FakeTransport({}),
        addonReader: (_) => pending.future,
      );
      final token = PlaylistLinkCancellationToken();
      final request = waiting.fetch(link, cancellation: token);
      token.cancel();
      await expectLater(
        request,
        throwsA(isA<PlaylistLinkCancelledException>()),
      );
      pending.complete({'tracks': []});
      importer.close();
      waiting.close();
    },
  );

  FakeTransport deezerTransport({bool failure = false, bool empty = false}) =>
      FakeTransport({
        'https://api.deezer.com/playlist/12345': [
          jsonResponse({'title': 'Deezer Mix', 'nb_tracks': empty ? 0 : 2}),
        ],
        'https://api.deezer.com/playlist/12345/tracks?index=0&limit=100': [
          jsonResponse({
            'data': empty
                ? []
                : [
                    {
                      'id': 1,
                      'title': 'Song',
                      'artist': {'name': 'Artist'},
                      'album': {'title': 'Album'},
                      'duration': 120,
                    },
                  ],
            'total': empty ? 0 : 2,
            if (!empty) 'next': 'https://evil.test/should-not-be-followed',
          }),
        ],
        'https://api.deezer.com/playlist/12345/tracks?index=100&limit=100': [
          jsonResponse(
            failure
                ? {
                    'error': {'message': 'failed'},
                  }
                : {
                    'data': [
                      {
                        'id': 1,
                        'title': 'Song',
                        'artist': {'name': 'Artist'},
                      },
                    ],
                    'total': 2,
                  },
          ),
        ],
      });

  test(
    'Deezer paginates, preserves duplicate entries and does not invoke add-ons',
    () async {
      final transport = deezerTransport();
      final importer = PublicPlaylistImporter(
        transport: transport,
        addonReader: (_) => throw StateError('must not run'),
      );
      final result = await importer.fetch(
        PlaylistLinkParser.parse(providerUrls[PlaylistLinkSource.deezer]!),
      );
      expect(result.entries.length, 2);
      expect(result.complete, true);
      expect(result.entries.first.duration, const Duration(seconds: 120));
      expect(result.entries.first.album, 'Album');
      expect(transport.requests.every((u) => u.host == 'api.deezer.com'), true);
      importer.close();
    },
  );

  test('Deezer failed continuation remains partial; empty public playlist is complete', () async {
    final link = PlaylistLinkParser.parse(
      providerUrls[PlaylistLinkSource.deezer]!,
    );
    final partial = PublicPlaylistImporter(
      transport: deezerTransport(failure: true),
    );
    final result = await partial.fetch(link);
    expect(result.complete, false);
    expect(result.entries.length, 1);
    final empty = PublicPlaylistImporter(
      transport: deezerTransport(empty: true),
    );
    expect((await empty.fetch(link)).complete, true);
    partial.close();
    empty.close();
  });
}
