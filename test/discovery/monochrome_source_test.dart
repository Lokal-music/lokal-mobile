import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/monochrome_source.dart';

void main() {
  test('Monochrome is a selectable native catalogue with its own track IDs', () async {
    final client = MockClient((request) async {
      expect(request.url.host, MonochromeSource.host);
      expect(request.url.path, '/search/tracks');
      expect(request.url.queryParameters['q'], 'Daft Punk');
      return http.Response(jsonEncode({
        'tracks': [
          {
            'trackId': '155142501534011392',
            'title': 'Get Lucky',
            'artistNames': ['Daft Punk', 'Pharrell Williams'],
            'albumTitle': 'Random Access Memories',
            'duration': 369626,
            'artwork': 'https://tracks.monochrome.st/proxy/mi/155142458219433984-1A01.jpg',
            'playable': true,
          },
          {
            'trackId': '../invalid',
            'title': 'Bad ID',
            'playable': true,
          },
          {
            'trackId': '155142501534011392',
            'title': 'Duplicate',
          }
        ]
      }), 200, headers: {'content-type': 'application/json'});
    });
    addTearDown(client.close);
    final songs = await MonochromeSource.search(DiscoveryHttp(client), 'Daft Punk');
    expect(songs, hasLength(1));
    final track = songs.single;
    expect(track.source, DiscoverySource.monochrome);
    expect(track.artist, 'Daft Punk, Pharrell Williams');
    expect(track.duration, const Duration(milliseconds: 369626));
    expect(track.artwork, contains('monochrome.st/proxy/'));
    final audio = MonochromeSource.resolve(track);
    expect(audio.url.toString(), 'https://tracks.monochrome.st/track/155142501534011392');
    expect(audio.codec, 'FLAC');
    expect(audio.bitDepth, isNull);
    expect(audio.sampleRate, isNull);
  });


  test('Monochrome retries a transient server failure', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      if (calls == 1) return http.Response('Unavailable', 503);
      return http.Response(jsonEncode({'tracks': []}), 200);
    });
    addTearDown(client.close);
    final result = await MonochromeSource.search(DiscoveryHttp(client), 'query');
    expect(result, isEmpty);
    expect(calls, 2);
  });

  test('Monochrome cannot resolve another provider or an invalid ID', () {
    expect(() => MonochromeSource.streamUri('../hello'), throwsA(isA<DiscoveryException>()));
    expect(() => MonochromeSource.resolve(const DiscoveryTrack(
      id: '155142501534011392', title: 'Song', artist: 'Artist',
      source: DiscoverySource.youtubeMusic,
    )), throwsA(isA<DiscoveryException>()));
  });

  test('Monochrome retains artist object credits and album in downloaded metadata', () async {
    final client = MockClient((_) async => http.Response(jsonEncode({
      'tracks': [{
        'trackId': '155142501534011393',
        'title': 'Get Lucky',
        'artists': [{'name': 'Daft Punk'}, {'name': 'Pharrell Williams'}],
        'releaseTitle': 'Random Access Memories',
        'playable': true,
      }],
    }), 200));
    addTearDown(client.close);
    final found = (await MonochromeSource.search(DiscoveryHttp(client), 'Get Lucky')).single;
    expect(found.artist, 'Daft Punk, Pharrell Williams');
    expect(found.album, 'Random Access Memories');
    expect(found.sourceName, 'Monochrome');
  });
}
