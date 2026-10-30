import 'dart:io';

import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/discovery_playback.dart';
import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only explicitly selected HTTP Atmos tiers route to native audio', () {
    expect(httpAddonRequestedSpatialCodec({'quality': 'ATMOS'}), 'eac3-joc');
    expect(httpAddonRequestedSpatialCodec({'audio_quality': 'DOLBY_ATMOS'}),
        'eac3-joc');
    expect(httpAddonRequestedSpatialCodec({'format': 'AC4_ATMOS'}), 'ac4');
    expect(httpAddonRequestedSpatialCodec({'quality': 'EAC3_JOC'}), 'eac3-joc');
    for (final settings in [
      <String, String>{},
      {'quality': 'LOSSLESS'},
      {'quality': 'HI_RES'},
      {'quality': 'EAC3'}, // Plain E-AC-3 does not establish Atmos.
      {'codec': 'ac4'}, // AC-4 alone is not a verified Atmos presentation.
      {'visualization': 'ATMOS'},
    ]) {
      expect(httpAddonRequestedSpatialCodec(settings), isNull);
    }
  });

  test('selected quality bypasses a search-inline stream and uses /stream', () async {
    final requests = <Uri>[];
    final addon = DiscoveryAddon(
      DiscoveryHttp(MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          '{"url":"https://audio.example/verified.m4a?signature=private","codec":"eac3"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      })),
      endpoint: 'https://addon.example/private',
      configId: 'tidal-fixture',
      settings: const {'quality': 'DOLBY_ATMOS'},
    );
    final track = DiscoveryTrack(
      id: 'song', title: 'Song', artist: 'Artist',
      source: DiscoverySource.addon, addonId: 'tidal-fixture',
      addonBase: addon.base,
      inlineStream: const {'url': 'https://audio.example/search-preview.flac'},
    );
    final audio = await addon.resolve(track);
    expect(requests, hasLength(1));
    expect(requests.single.path, '/private/stream/song');
    expect(requests.single.queryParameters['quality'], 'DOLBY_ATMOS');
    expect(audio.url.path, '/verified.m4a');
  });

  test('HTTP quality option labels can identify a custom Atmos value', () async {
    final addon = DiscoveryAddon(
      DiscoveryHttp(MockClient((request) async => http.Response(
        '{"id":"tidal-fixture","name":"Tidal HTTP","resources":["search","stream"],'
        '"settings":[{"key":"quality","options":['
        '{"value":"LOSSLESS","label":"FLAC"},'
        '{"value":"MAX","label":"Dolby Atmos (E-AC-3 JOC)"}]}]}',
        200,
        headers: {'content-type': 'application/json'},
      ))),
      endpoint: 'https://addon.example/a/opaque',
      settings: const {'quality': 'MAX'},
    );
    expect(await addon.requestedSpatialCodec(), 'eac3-joc');
  });

  const channel = MethodChannel('lokal/atmos');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('http-spatial-fixture-');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'capabilities') return {'available': true};
      return false;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  final mediaUrl = Uri.parse('https://media.example/track.m4a?signature=private');
  final track = DiscoveryTrack(
    id: 'track', title: 'Song', artist: 'Artist',
    source: DiscoverySource.addon,
  );
  final audio = ResolvedDiscoveryAudio(mediaUrl);
  final sampleBytes = List<int>.generate(512, (i) => i % 256);

  test('HTTP E-AC-3 JOC keeps the original compressed file for Media3', () async {
    final client = MockClient((request) async {
      expect(request.url, mediaUrl);
      return http.Response.bytes(sampleBytes, 200);
    });
    var nativeChecks = 0;
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(client),
      directory: () async => directory,
      spatialProbe: (path, codec) async {
        nativeChecks++;
        expect(codec, 'eac3-joc');
        expect(path, endsWith('.m4a'));
        expect(await File(path).readAsBytes(), sampleBytes);
        return true;
      },
      probe: (_) async => fail('PCM probe must not process a spatial stream'),
    );
    final song = await cache.prepare(track, audio,
        requestedSpatialCodec: 'eac3-joc');
    expect(nativeChecks, 1);
    expect(song.atmosEncoded, isTrue);
    expect(song.fileType, 'E-AC-3 JOC');
    expect(song.filePath, isNot(contains('signature')));
    expect(await File(song.filePath!).readAsBytes(), sampleBytes);
  });

  test('HTTP addon returning stereo for Atmos preference is rejected', () async {
    final client = MockClient((_) async => http.Response.bytes(sampleBytes, 200));
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(client),
      directory: () async => directory,
      spatialProbe: (path, codec) async {
        expect(codec, 'eac3-joc');
        return false;
      },
      probe: (_) async => fail('Never fall back to stereo without consent'),
    );
    await expectLater(
      cache.prepare(track, audio, requestedSpatialCodec: 'eac3-joc'),
      throwsA(isA<DiscoveryException>()),
    );
    expect(directory.listSync().whereType<File>(), isEmpty);
  });
}
