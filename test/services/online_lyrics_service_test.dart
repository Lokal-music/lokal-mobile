import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/online_lyrics_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _record = {
  'id': 42,
  'trackName': 'Chan Chan',
  'artistName': 'Kiko',
  'albumName': 'Album',
  'duration': 213,
  'instrumental': false,
  'plainLyrics': 'Lyrics',
  'syncedLyrics': null,
};

void main() {
  setUp(OnlineLyricsService.clearLookupCache);

  test('manual search identifies Lokal to LRCLIB and sends structured parameters', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/search');
      expect(request.url.queryParameters['track_name'], 'Chan Chan');
      expect(request.url.queryParameters['artist_name'], 'Kiko');
      expect(
        request.headers['User-Agent'],
        contains('https://github.com/lokal-music/lokal-mobile'),
      );
      expect(request.headers['Accept'], 'application/json');
      return http.Response(jsonEncode([_record]), 200);
    });

    final result = await OnlineLyricsService(client: client).search(
      title: 'Chan Chan',
      artist: 'Kiko',
      refresh: true,
      reportErrors: true,
    );
    expect(result.single.trackName, 'Chan Chan');
    expect(result.single.bestLyrics, 'Lyrics');
    client.close();
  });

  test('exact lookup also identifies the application', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/get');
      expect(request.headers['User-Agent'], contains('Lokal-Mobile/'));
      return http.Response(jsonEncode(_record), 200);
    });

    final result = await OnlineLyricsService(client: client).fetchExact(
      title: 'Chan Chan',
      artist: 'Kiko',
    );
    expect(result?.id, 42);
    client.close();
  });

  test('short server Retry-After is honored before one successful retry', () async {
    var requests = 0;
    final delays = <Duration>[];
    final client = MockClient((request) async {
      requests++;
      if (requests == 1) {
        return http.Response('', 503, headers: {'retry-after': '2'});
      }
      return http.Response(jsonEncode([_record]), 200);
    });

    final results = await OnlineLyricsService(
      client: client,
      delay: (duration) async { delays.add(duration); },
    ).search(title: 'Chan Chan', artist: 'Kiko', refresh: true, reportErrors: true);

    expect(requests, 2);
    expect(delays, [const Duration(seconds: 2)]);
    expect(results.single.id, 42);
    client.close();
  });

  test('long rate limit is surfaced, not retried early or cached as no lyrics', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('', 429, headers: {'retry-after': '60'});
    });
    final service = OnlineLyricsService(
      client: client,
      delay: (_) async { fail('Must not ignore a 60-second Retry-After'); },
    );

    await expectLater(
      service.search(
        title: 'Chan Chan',
        artist: 'Kiko',
        refresh: true,
        reportErrors: true,
      ),
      throwsA(
        isA<OnlineLyricsHttpException>()
            .having((e) => e.statusCode, 'status code', 429)
            .having((e) => e.retryAfter, 'retry-after', const Duration(seconds: 60)),
      ),
    );

    expect(await service.search(title: 'Chan Chan', artist: 'Kiko'), isEmpty);
    expect(await service.search(title: 'Chan Chan', artist: 'Kiko'), isEmpty);
    expect(requests, 3); // 429 must never enter the empty-results cache.
    client.close();
  });

  test('temporary exact lookup failure does not poison the cache', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return requests == 1
          ? http.Response('', 429, headers: {'retry-after': '60'})
          : http.Response(jsonEncode(_record), 200);
    });
    final service = OnlineLyricsService(client: client);
    expect(await service.fetchExact(title: 'Chan Chan', artist: 'Kiko'), isNull);
    expect(
      (await service.fetchExact(title: 'Chan Chan', artist: 'Kiko'))?.id,
      42,
    );
    expect(requests, 2);
    client.close();
  });
}
