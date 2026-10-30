import 'dart:async';
import 'dart:convert';

import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/discovery_progressive_streams.dart';
import 'package:flick/features/discovery/discovery_settings.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/services/playback_source_priority.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _only = DiscoveryAddonConfig(
  id: 'only-http',
  label: 'HTTP source',
  endpoint: 'https://addon.example/library',
  token: 'test-token',
  enabled: true,
);
const _settings = DiscoverySettings(
  youtubeEnabled: false,
  addons: [_only],
);

class _MemorySettings extends DiscoverySettingsStore {
  _MemorySettings([this.value = _settings]);
  final DiscoverySettings value;
  @override
  Future<DiscoverySettings> load() async => value;
}

DiscoveryTrack _track({String label = 'HTTP source'}) => DiscoveryTrack(
  id: 'song-1',
  title: 'Night Drive',
  artist: 'Test Artist',
  source: DiscoverySource.addon,
  addonId: _only.id,
  addonBase: Uri.parse(_only.endpoint),
  sourceName: label,
);

MockClient _client(List<String> requests) => MockClient((request) async {
  requests.add(request.method + ' ' + request.url.path);
  expect(request.url.host, 'addon.example',
      reason: 'An HTTP-only source must never search native providers');
  expect(request.headers['authorization'], 'Bearer test-token');
  if (request.url.path == '/library/search') {
    return http.Response(jsonEncode({
      'tracks': [{
        'id': 'song-1',
        'title': 'Night Drive',
        'artist': 'Test Artist',
        'duration': 182,
      }],
    }), 200);
  }
  if (request.url.path == '/library/stream/song-1') {
    return http.Response(jsonEncode({
      'url': 'https://cdn.example/audio.flac?sig=secret',
      'format': 'audio/flac',
      'sampleRate': 44100,
      'bitDepth': 16,
    }), 200);
  }
  throw StateError('Unexpected HTTP request');
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      PlaybackSourcePriority.key: ['w-HTTP source', 'yt', 'mono'],
    });
    DiscoveryProgressiveStreams.instance.clear();
  });
  tearDown(DiscoveryProgressiveStreams.instance.clear);

  test('only enabled HTTP addon can search and resolve direct streaming', () async {
    final requests = <String>[];
    final client = _client(requests);
    addTearDown(client.close);
    final sources = await onlineSources(
      client, store: _MemorySettings(),
    );
    final httpSource = sources.singleWhere((source) => source.id == 'w-only-http');
    expect(httpSource.addon, true);
    expect(httpSource.name, 'HTTP source');

    final found = await httpSource.search('Night Drive');
    expect(found.single.addonId, _only.id);
    expect(requests, contains('GET /library/search'));
    final played = await playOnlineTrack(
      httpSource.id,
      found.single,
      store: _MemorySettings(),
      client: client,
    );
    expect(played.sourcePackage, 'konnekted.progressive');
    expect(played.filePath, startsWith('lokal-progressive://'));
    expect(played.filePath, isNot(contains('secret')));
    expect(DiscoveryProgressiveStreams.instance.resolve(played.filePath),
      Uri.parse('https://cdn.example/audio.flac?sig=secret'));
    expect(requests, ['GET /library/search', 'GET /library/stream/song-1'],
      reason: 'Streaming must not stage full media or request native providers');
  });

  test('automatic Discovery searches HTTP when it is the only enabled source', () async {
    final requests = <String>[];
    final client = _client(requests);
    addTearDown(client.close);
    final played = await findDiscoverySong(
      const LokalDiscoveryTrack(
        title: 'Night Drive',
        artist: 'Test Artist',
      ),
      client: client,
      store: _MemorySettings(),
    );
    expect(played, isNotNull);
    expect(played!.sourcePackage, 'konnekted.progressive');
    expect(played.sourceDisplayName, 'HTTP source');
    expect(DiscoveryProgressiveStreams.instance.resolve(played.filePath),
      Uri.parse('https://cdn.example/audio.flac?sig=secret'));
    expect(requests, ['GET /library/search', 'GET /library/stream/song-1'],
      reason: 'Disabled native sources must not intercept HTTP-only Discovery');
  });

  test('manifest failure does not start progressive playback', () async {
    final config = DiscoveryAddonConfig(
      id: _only.id, label: _only.label, endpoint: _only.endpoint,
      enabled: true, settings: const {'quality': 'CUSTOM'},
    );
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      if (request.url.path.endsWith('/manifest.json')) {
        return http.Response('unavailable', 503);
      }
      return http.Response('{"url":"https://cdn.example/audio.flac"}', 200);
    });
    addTearDown(client.close);
    await expectLater(
      playOnlineTrack('w-only-http', _track(), client: client,
          store: _MemorySettings(DiscoverySettings(addons: [config]))),
      throwsA(isA<DiscoveryException>()),
    );
    expect(requests, ['/library/stream/song-1', '/library/manifest.json']);
  });

  test('playback cancellation reaches the spatial manifest lookup', () async {
    final config = DiscoveryAddonConfig(
      id: _only.id, label: _only.label, endpoint: _only.endpoint,
      enabled: true, settings: const {'quality': 'CUSTOM'},
    );
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final cancelled = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/manifest.json')) {
        started.complete();
        return response.future;
      }
      return http.Response('{"url":"https://cdn.example/audio.flac"}', 200);
    });
    addTearDown(client.close);
    final result = playOnlineTrack('w-only-http', _track(), client: client,
        cancel: cancelled.future,
        store: _MemorySettings(DiscoverySettings(addons: [config])));
    await started.future;
    cancelled.complete();
    await expectLater(result, throwsA(isA<DiscoveryException>().having(
        (error) => error.message, 'message', 'Request cancelled.')));
    response.complete(http.Response('{}', 200));
  });

  for (final spatial in [true, false]) {
    test(spatial
        ? 'explicit spatial preparation failure does not try another source'
        : 'ordinary stream failure still tries another source', () async {
      SharedPreferences.setMockInitialValues({
        PlaybackSourcePriority.key: ['w-first', 'w-second'],
      });
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('lokal/atmos');
      messenger.setMockMethodCallHandler(channel, (_) async => {'available': false});
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final settings = DiscoverySettings(youtubeEnabled: false, addons: [
        DiscoveryAddonConfig(id: 'first', label: 'First',
          endpoint: 'https://first.example', enabled: true,
          settings: spatial ? const {'quality': 'ATMOS'} : const {}),
        const DiscoveryAddonConfig(id: 'second', label: 'Second',
          endpoint: 'https://second.example', enabled: true),
      ]);
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add('${request.url.host}${request.url.path}');
        if (request.url.path == '/search') {
          return http.Response(jsonEncode({'tracks': [{
            'id': 'song', 'title': 'Night Drive', 'artist': 'Test Artist',
          }]}), 200);
        }
        if (request.url.host == 'first.example' && !spatial) {
          return http.Response('unavailable', 503);
        }
        return http.Response('{"url":"https://cdn.example/audio.flac"}', 200);
      });
      addTearDown(client.close);
      final result = findDiscoverySong(
        const LokalDiscoveryTrack(title: 'Night Drive', artist: 'Test Artist'),
        client: client, store: _MemorySettings(settings),
      );
      if (spatial) {
        await expectLater(result, throwsA(isA<DiscoveryException>().having(
          (error) => error.message, 'message', contains('cannot decode'),
        )));
        expect(requests.where((request) => request.startsWith('second.example')),
            isEmpty);
      } else {
        final song = await result;
        expect(song?.sourceDisplayName, 'Second');
        expect(requests, contains('second.example/stream/song'));
      }
    });
  }

  test('old label-based queued source IDs still resolve after a rename', () async {
    final requests = <String>[];
    final client = _client(requests);
    addTearDown(client.close);
    final track = _track(label: 'Former name');
    final played = await playOnlineTrack(
      'w-Former name', track,
      store: _MemorySettings(),
      client: client,
    );
    expect(played.sourceDisplayName, 'HTTP source');
    expect(played.sourcePackage, 'konnekted.progressive');
    expect(requests, ['GET /library/stream/song-1']);
  });

  test('mismatched HTTP source selection never plays another add-on', () async {
    final requests = <String>[];
    final client = _client(requests);
    addTearDown(client.close);
    await expectLater(
      playOnlineTrack('w-other-source', _track(),
        store: _MemorySettings(), client: client),
      throwsA(isA<DiscoveryException>()),
    );
    expect(requests, isEmpty);
  });

  test('disabled HTTP addon is not silently replaced by another source', () async {
    final requests = <String>[];
    final client = _client(requests);
    addTearDown(client.close);
    final disabled = DiscoverySettings(addons: [
      const DiscoveryAddonConfig(
        id: 'only-http',
        label: 'HTTP source',
        endpoint: 'https://addon.example/library',
      ),
    ]);
    await expectLater(
      playOnlineTrack(
        'w-only-http', _track(),
        store: _MemorySettings(disabled),
        client: client,
      ),
      throwsA(isA<DiscoveryException>()),
    );
    expect(requests, isEmpty);
  });

  test('HTTP priority survives migration from display-name IDs', () async {
    final sources = <String>['yt', 'mono', 'w-only-http'];
    final ordered = await PlaybackSourcePriority.order(
      sources, (source) => source,
      aliases: {'w-HTTP source': 'w-only-http'},
    );
    expect(ordered.first, 'w-only-http');
    expect(await PlaybackSourcePriority.load(),
        ['w-only-http', 'yt', 'mono']);
  });
}
