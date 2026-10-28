import 'dart:convert';

import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/discovery_settings.dart';
import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

const _manifest = {
  'id': 'dev.bitperfect.qobuz.de.personal',
  'name': 'Qobuz [Heisenbergg]',
  'version': '1.0.0-de',
  'resources': ['search', 'stream'],
  'allowDownloads': 1,
  'settings': [
    {
      'key': 'quality',
      'default': 'LOSSLESS',
      'options': [
        {'value': 'LOSSLESS'},
        {'value': 'HI_RES'},
        {'value': 'HIGH'},
        {'value': 'LOW'},
      ],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manifest installation probes exactly the pasted private URL', () async {
    final pasted = Uri.parse(
      'https://addons.example/private/a/Qobuz-Token/manifest.json',
    );
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return _json(_manifest);
    });
    addTearDown(client.close);
    final addon = DiscoveryAddon(
      DiscoveryHttp(client),
      endpoint: pasted.toString(),
    );
    final health = await addon.health(exactManifestUrl: pasted);
    expect(health.name, 'Qobuz [Heisenbergg]');
    expect(requests, [pasted]);
    expect(addon.base.toString(),
        'https://addons.example/private/a/Qobuz-Token');
  });

  test('encoded manifest path survives secure settings and later checks', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = DiscoverySettingsStore();
    const exact = 'https://addons.example/private/a%40b/manifest.json';
    final endpoint = normalizeAddonEndpoint(exact).toString();
    await store.save(DiscoverySettings(addons: [
      DiscoveryAddonConfig(
        id: 'encoded',
        endpoint: endpoint,
        manifestUrl: exact,
        label: 'Private source',
        enabled: true,
      ),
    ]));
    final saved = (await store.load()).addons.single;
    expect(saved.manifestUrl, exact);
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.toString() == exact) return _json(_manifest);
      if (request.url.path.endsWith('/stream/track')) {
        return _json({'url': 'https://media.example/song.flac'});
      }
      return http.Response('Not found', 404);
    });
    addTearDown(client.close);
    final addon = DiscoveryAddon(
      DiscoveryHttp(client),
      endpoint: saved.endpoint,
      exactManifestUrl: Uri.parse(saved.manifestUrl!),
      configId: saved.id,
    );
    expect((await addon.health()).cacheAllowed, isTrue);
    expect(requests.single.toString(), exact);
    final song = DiscoveryTrack(
      id: 'track', title: 'Song', artist: 'Artist',
      source: DiscoverySource.addon,
      addonId: saved.id,
      addonBase: addon.base,
    );
    await addon.resolve(song, forDownload: true);
    expect(requests[1].toString(), exact);
  });

  test('rejects foreign and malformed persisted manifest URLs', () {
    for (final manifestUrl in [
      'https://other.example/private/manifest.json',
      'https://addon.example/path/manifest.json?token=secret',
      'http://addon.example/path/manifest.json',
      'https://addon.example/path/other.json',
    ]) {
      expect(
        () => DiscoveryAddonConfig(
          id: 'bad', endpoint: 'https://addon.example/path',
          manifestUrl: manifestUrl,
        ).validated(),
        throwsA(isA<DiscoveryException>()),
      );
    }
  });

  test('manifest probes cannot send credentials to a foreign origin', () async {
    final client = MockClient((_) async => fail('No network expected'));
    addTearDown(client.close);
    final addon = DiscoveryAddon(
      DiscoveryHttp(client),
      endpoint: 'https://addons.example/private/manifest.json',
      token: 'secret',
    );
    expect(
      () => addon.health(
        exactManifestUrl: Uri.parse('https://attacker.example/manifest.json'),
      ),
      throwsA(isA<DiscoveryException>()),
    );
  });

  test('parses real-world manifest name and untyped quality select', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/private/manifest.json');
      return _json(_manifest);
    });
    addTearDown(client.close);
    final addon = DiscoveryAddon(
      DiscoveryHttp(client),
      endpoint: 'https://addon.example/private/manifest.json',
    );
    final health = await addon.health();
    expect(health.name, 'Qobuz [Heisenbergg]');
    expect(health.cacheAllowed, isTrue);
    expect(health.settings, hasLength(1));
    final quality = health.settings.single;
    expect(quality.label, 'quality');
    expect(quality.defaultValue, 'LOSSLESS');
    expect(
      quality.options.map((o) => o.value),
      ['LOSSLESS', 'HI_RES', 'HIGH', 'LOW'],
    );
  });

  test('cover metadata reaches player track; quality goes to search/stream', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.path.endsWith('/manifest.json')) return _json(_manifest);
      if (request.url.path.endsWith('/search')) {
        return _json({
          'tracks': [
            {
              'id': 'track/1',
              'title': 'Song with artwork',
              'artist': 'Artist',
              'artworkURL': 'https://images.example/track.jpg',
            },
            {
              'id': 'track/2',
              'title': 'Album artwork',
              'albumArtworkURL': 'https://images.example/album.jpg',
            },
            {
              'id': 'track/3',
              'title': 'Unsafe artwork',
              'artworkURL': 'http://insecure.example/pic.jpg',
            },
          ],
        });
      }
      return _json({'url': 'https://media.example/song.flac'});
    });
    addTearDown(client.close);
    final addon = DiscoveryAddon(
      DiscoveryHttp(client),
      endpoint: 'https://addon.example/private',
      settings: const {'quality': 'HI_RES'},
    );
    final tracks = await addon.search('song');
    expect(tracks, hasLength(3));
    expect(tracks[0].artwork, 'https://images.example/track.jpg');
    expect(tracks[1].artwork, 'https://images.example/album.jpg');
    expect(tracks[2].artwork, isNull);
    expect(requests[0].queryParameters, {'quality': 'HI_RES', 'q': 'song'});
    await addon.resolve(tracks[0]);
    expect(requests, hasLength(2));
    expect(requests[1].pathSegments.last, 'track/1');
    expect(requests[1].queryParameters['quality'], 'HI_RES');
    // Explicit saving must still enforce the current manifest policy.
    await addon.resolve(tracks[0], forDownload: true);
    expect(requests[2].path, '/private/manifest.json');
    expect(requests[3].pathSegments.last, 'track/1');
    expect(requests[3].queryParameters['quality'], 'HI_RES');
  });

  test('secure settings survive reload and older version 2 records', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = DiscoverySettingsStore();
    final withSettings = DiscoverySettings(addons: [
      const DiscoveryAddonConfig(
        id: 'qobuz',
        endpoint: 'https://addon.example/private',
        label: 'Qobuz [Heisenbergg]',
        settings: {'quality': 'HI_RES'},
        enabled: true,
      ),
    ]);
    await store.save(withSettings);
    final reloaded = await store.load();
    expect(reloaded.addons.single.displayName, 'Qobuz [Heisenbergg]');
    expect(reloaded.addons.single.settings['quality'], 'HI_RES');
    final raw = const FlutterSecureStorage();
    await raw.write(
      key: 'konnekted.discovery.sources.v1',
      value: jsonEncode({
        'version': 2,
        'youtubeEnabled': false,
        'addons': [
          {
            'id': 'legacy',
            'endpoint': 'https://addon.example',
            'label': 'Old source',
            'token': '',
            'enabled': true,
          },
        ],
      }),
    );
    final old = await store.load();
    expect(old.addons.single.settings, isEmpty);
  });
}
