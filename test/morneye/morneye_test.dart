import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flick/features/morneye/morneye_host.dart';
import 'package:flick/features/morneye/morneye_network.dart';
import 'package:flick/features/morneye/morneye_packages.dart';
import 'package:flick/features/morneye/morneye_runtime.dart';
import 'package:flick/features/morneye/morneye_storage.dart';
import 'package:flick/services/playback_source_priority.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import 'morneye_fakes.dart';

void main() {
  late Directory dir;
  late FakeNative native;
  late MemoryVault vault;
  late MorneyeStorage storage;
  final namespace = morneyeKeyOf('deezer');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('morneye');
    native = FakeNative();
    vault = MemoryVault();
    storage = MorneyeStorage(dir, sealer: native, vault: vault);
    await storage.open();
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('storage', () {
    test('keeps add-on storage plain and everything else sealed', () {
      storage.write(namespace, 'storage', {'a': 1});
      storage.write(namespace, 'credentials', {'token': 'secret'});

      final plain = File(p.join(dir.path, 'data', namespace, 'storage.json'));
      final sealed = File(
        p.join(dir.path, 'data', namespace, 'credentials.enc'),
      );
      expect(jsonDecode(plain.readAsStringSync()), {'a': 1});
      expect(
        utf8.decode(sealed.readAsBytesSync(), allowMalformed: true),
        isNot(contains('secret')),
      );
      expect(storage.read(namespace, 'credentials'), {'token': 'secret'});
    });

    test(
      'a lost key discards sealed records but keeps plain storage',
      () async {
        storage.write(namespace, 'storage', {'a': 1});
        storage.write(namespace, 'credentials', {'token': 'secret'});

        vault.key = null;
        final reopened = MorneyeStorage(dir, sealer: native, vault: vault);
        await reopened.open();

        expect(reopened.read(namespace, 'credentials'), isEmpty);
        expect(reopened.read(namespace, 'storage'), {'a': 1});
        expect(vault.key, hasLength(32));
      },
    );

    test('rejects namespaces that could escape its folder', () {
      expect(() => storage.read('../x', 'storage'), throwsArgumentError);
      expect(() => storage.read(namespace, 'Settings'), throwsArgumentError);
    });

    test('update and forget', () {
      storage.update(namespace, 'storage', 'k', 'v');
      expect(storage.read(namespace, 'storage'), {'k': 'v'});
      storage.update(namespace, 'storage', 'k', null, remove: true);
      expect(storage.read(namespace, 'storage'), isEmpty);
      storage.update(namespace, 'storage', 'k', 'v');
      storage.forget(namespace);
      expect(
        Directory(p.join(dir.path, 'data', namespace)).existsSync(),
        isFalse,
      );
    });
  });

  group('network rules', () {
    test('private addresses', () {
      for (final address in [
        '127.0.0.1',
        '10.1.2.3',
        '192.168.0.4',
        '172.20.0.1',
        '169.254.1.1',
        '::1',
        'fe80::1',
        'fc00::2',
      ]) {
        expect(morneyePrivateAddress(address), isTrue, reason: address);
      }
      expect(morneyePrivateAddress('8.8.8.8'), isFalse);
      expect(morneyePrivateAddress('172.32.0.1'), isFalse);
    });

    test('domain permissions and wildcards', () {
      expect(morneyeDomainAllowed('api.deezer.com', ['*.deezer.com']), isTrue);
      expect(morneyeDomainAllowed('deezer.com', ['deezer.com']), isTrue);
      expect(morneyeDomainAllowed('evildeezer.com', ['*.deezer.com']), isFalse);
      const permissions = MorneyePermissions(network: ['api.example.com']);
      expect(
        morneyeValidateUrl('https://api.example.com/x', permissions).path,
        '/x',
      );
      expect(
        () => morneyeValidateUrl('https://other.com/', permissions),
        throwsA(isA<MorneyeNetworkException>()),
      );
      expect(
        () => morneyeValidateUrl('http://api.example.com/', permissions),
        throwsA(isA<MorneyeNetworkException>()),
      );
      expect(
        () => morneyeValidateUrl('https://u:p@api.example.com/', permissions),
        throwsA(isA<MorneyeNetworkException>()),
      );
    });

    test('cookie jar scopes cookies by domain, path and expiry', () {
      final jar = MorneyeCookieJar();
      final url = Uri.parse('https://www.example.com/app/page');
      final now = DateTime.now();
      jar.store('sid=1; Domain=example.com; Path=/', url, now: now);
      jar.store('app=2; Path=/app', url, now: now);
      jar.store('old=3; Max-Age=10', url, now: now);

      expect(
        jar.header(Uri.parse('https://api.example.com/'), now: now),
        'sid=1',
      );
      expect(jar.header(url, now: now).split('; ')..sort(), [
        'app=2',
        'old=3',
        'sid=1',
      ]);
      expect(
        jar.header(url, now: now.add(const Duration(seconds: 11))),
        isNot(contains('old=3')),
      );
      expect(jar.header(Uri.parse('https://other.com/'), now: now), isEmpty);

      final copy = MorneyeCookieJar.fromJson(jar.toJson());
      expect(copy.header(url, now: now), jar.header(url, now: now));
    });
  });

  group('network requests', () {
    late HttpServer server;
    late String base;
    var stallRequests = 0;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/login':
            response.headers.add('set-cookie', 'sid=abc; Path=/');
            response.write('ok');
          case '/echo':
            response.headers.contentType = ContentType.json;
            response.write(
              jsonEncode({
                'cookie': request.headers.value('cookie'),
                'auth': request.headers.value('authorization'),
              }),
            );
          case '/away':
            response.statusCode = 302;
            response.headers.set('location', 'https://elsewhere.test/');
          case '/hop':
            response.statusCode = 302;
            response.headers.set('location', '/echo');
          case '/stall':
            // The first answer goes quiet halfway; the second is whole.
            response.contentLength = 8;
            if (++stallRequests == 1) {
              response.add([1, 2, 3, 4]);
              await response.flush();
              return; // Never finished.
            }
            response.add([1, 2, 3, 4, 5, 6, 7, 8]);
          default:
            response.statusCode = 404;
        }
        await response.close();
      });
    });

    tearDown(() => server.close(force: true));

    MorneyeNetwork network([List<String> domains = const ['127.0.0.1']]) =>
        MorneyeNetwork(MorneyePermissions(network: domains, allowHttp: true));

    test(
      'keeps cookies between requests and follows local redirects',
      () async {
        final net = network();
        await net.jsonResponse('$base/login');
        final reply = await net.jsonResponse(
          '$base/hop',
          headers: {'Authorization': 'Bearer t'},
        );
        expect(reply['status'], 200);
        final body = jsonDecode('${reply['body']}') as Map;
        expect(body['cookie'], 'sid=abc');
        expect(body['auth'], 'Bearer t');
        net.close();
      },
    );

    test('a download that goes quiet is dropped and tried again', () async {
      stallRequests = 0;
      final host = MorneyeHost(
        addon: MorneyeAddonInfo(
          key: namespace,
          name: 'deezer',
          manifest: const {
            'permissions': {
              'network': ['127.0.0.1'],
              'file': true,
            },
          },
        ),
        storage: storage,
        network: network(),
        native: native,
        root: p.join(dir.path, 'files'),
        stallTimeout: const Duration(milliseconds: 300),
      );
      final result = await host.call('file.download', [
        '$base/stall',
        'song.flac',
        const {'maxAttempts': 3},
      ], (descriptor, args, {strict = false}) async {});
      expect(result, containsPair('success', true));
      expect(result, containsPair('attempts', 2));
      expect(File(p.join(dir.path, 'files', 'song.flac')).readAsBytesSync(), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);
      host.network.close();
    });

    test('refuses redirects to hosts outside its permissions', () async {
      final net = network();
      await expectLater(
        net.jsonResponse('$base/away'),
        throwsA(isA<MorneyeNetworkException>()),
      );
      net.close();
    });

    test(
      'Qobuz addon DNS stalls are bounded and never hang playback',
      () async {
        final pendingDns = Completer<List<InternetAddress>>();
        final net = MorneyeNetwork(
          const MorneyePermissions(network: ['qobuz.example']),
          lookup: (_) => pendingDns.future,
          requestTimeout: const Duration(milliseconds: 80),
        );
        addTearDown(net.close);
        await expectLater(
          net.request('https://qobuz.example/stream'),
          throwsA(isA<TimeoutException>()),
        );
      },
    );
    test('refuses private addresses that were not asked for', () async {
      final net = MorneyeNetwork(
        const MorneyePermissions(network: ['local.test'], allowHttp: true),
        lookup: (_) async => [InternetAddress.loopbackIPv4],
      );
      await expectLater(
        net.jsonResponse('http://local.test:${server.port}/echo'),
        throwsA(isA<MorneyeNetworkException>()),
      );
      net.close();
    });
  });

  group('host', () {
    MorneyeHost host({bool storagePermission = true}) => MorneyeHost(
      addon: MorneyeAddonInfo(
        key: namespace,
        name: 'deezer',
        manifest: {
          'permissions': {
            'network': ['api.example.com'],
            'storage': storagePermission,
            'file': true,
          },
        },
      ),
      storage: storage,
      network: MorneyeNetwork(
        const MorneyePermissions(network: ['api.example.com']),
      ),
      native: native,
      root: p.join(dir.path, 'files'),
    );

    Future<void> noCallback(
      Object? descriptor,
      List<Object?> args, {
      bool strict = false,
    }) async {}

    test('storage and credentials need the storage permission', () async {
      final allowed = host();
      await allowed.call('storage.set', ['k', 1], noCallback);
      expect(await allowed.call('storage.get', ['k'], noCallback), {
        'found': true,
        'value': 1,
      });
      await allowed.call('credentials.set', ['t', 'x'], noCallback);
      expect(storage.read(namespace, 'credentials'), {'t': 'x'});

      expect(
        host(storagePermission: false).call('storage.get', ['k'], noCallback),
        throwsStateError,
      );
    });

    test('files stay inside the add-on folder', () async {
      final h = host();
      final written = await h.call('file.write', [
        'a/b.txt',
        'hello',
      ], noCallback);
      expect(written, isA<Map>());
      expect(await h.call('file.exists', ['a/b.txt'], noCallback), isTrue);
      expect(() => h.file('../outside.txt'), throwsArgumentError);
      expect(() => h.file(p.join(dir.path, 'x.txt')), throwsStateError);
    });

    test('helpers match desktop', () async {
      final h = host();
      expect(
        await h.call('utils.md5', ['abc'], noCallback),
        md5.convert(utf8.encode('abc')).toString(),
      );
      expect(
        await h.call('gobackend.buildFilename', [
          '{artist} - {title}',
          {'artist': 'AC/DC', 'title': 'T.N.T.'},
        ], noCallback),
        isNot(contains('/')),
      );
      expect(
        (await h.call('url.parse', ['https://a.com/p?q=1#f', null], noCallback)
            as Map)['hostname'],
        'a.com',
      );
      expect(
        await h.call('ffmpeg.execute', ['-i x'], noCallback),
        containsPair('success', false),
      );
      expect(h.call('nope.method', const [], noCallback), throwsStateError);
    });

    test('abort cancels sleeps', () async {
      final h = host();
      final sleeping = h.call('utils.sleep', [60000], noCallback);
      h.abort();
      await expectLater(sleeping, throwsA(isA<MorneyeCancelled>()));
    });
  });

  group('runtime', () {
    late FakeEngine engine;
    late MorneyeHost host;

    setUp(() {
      engine = FakeEngine();
      host = MorneyeHost(
        addon: MorneyeAddonInfo(
          key: namespace,
          name: 'deezer',
          manifest: const {
            'permissions': {'network': <String>[], 'storage': true},
          },
        ),
        storage: storage,
        network: MorneyeNetwork(const MorneyePermissions()),
        native: native,
        root: p.join(dir.path, 'files'),
      );
    });

    test('calls run one at a time and reach the host', () async {
      final order = <String>[];
      engine.scripts['code'] = {
        'slow': (args, call) async {
          order.add('slow start');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          order.add('slow end');
          return 1;
        },
        'fast': (args, call) async {
          order.add('fast');
          return call('utils.sha256', ['x']);
        },
        'broken': (args, call) => call('storage.nope', const []),
      };
      final runtime = await MorneyeRuntime.start(
        'code',
        const {},
        host,
        starter: engine.start,
      );
      final results = await Future.wait([
        runtime.invoke('slow'),
        runtime.invoke('fast'),
      ]);
      expect(order, ['slow start', 'slow end', 'fast']);
      expect(results.last, sha256.convert(utf8.encode('x')).toString());
      expect(runtime.methods, containsAll(['slow', 'fast']));
      expect(runtime.closed, isFalse);
    });

    test('a call that times out stops the add-on', () async {
      engine.scripts['code'] = {
        'hang': (args, call) => Completer<Object?>().future,
      };
      final runtime = await MorneyeRuntime.start(
        'code',
        const {},
        host,
        starter: engine.start,
      );
      await expectLater(
        runtime.invoke('hang', const [], const Duration(milliseconds: 20)),
        throwsA(
          isA<MorneyeRuntimeError>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
      expect(runtime.closed, isTrue);
      expect(host.aborted, isTrue);
      await expectLater(
        runtime.invoke('hang'),
        throwsA(isA<MorneyeRuntimeError>()),
      );
    });
  });

  group('Mornye package file names', () {
    test('accepts official .spotiflac-ext packages and registry formats', () {
      for (final name in [
        'extension.spotiflac-ext',
        'EXTENSION.SPOTIFLAC-EXT',
        'extension.sflx',
        'extension.morneye-ext',
      ]) {
        expect(morneyeIsPackageFileName(name), isTrue, reason: name);
      }
      for (final name in [
        'extension.zip',
        'extension.json',
        'extension.spotiflac-ext.zip',
        'extension.spotiflac-ext/index.js',
        'extension.spotiflac-ext.exe',
      ]) {
        expect(morneyeIsPackageFileName(name), isFalse, reason: name);
      }
    });
  });

  group('manifests', () {
    test('accepts a download provider', () {
      expect(morneyeValidateManifest(manifestFor('qobuz'))['name'], 'qobuz');
    });

    test('rejects what desktop rejects', () {
      Matcher fails(String text) => throwsA(
        isA<MorneyePackageError>().having(
          (e) => e.message,
          'message',
          contains(text),
        ),
      );
      expect(
        () => morneyeValidateManifest({...manifestFor('x'), 'name': 'Bad!'}),
        fails('manifest'),
      );
      expect(
        () => morneyeValidateManifest({
          ...manifestFor('x'),
          'type': ['lyrics_provider'],
        }),
        fails('download-capable'),
      );
      expect(
        () => morneyeValidateManifest({
          ...manifestFor('x'),
          'minAppVersion': '99.0.0',
        }),
        fails('compatibility'),
      );
      expect(
        () => morneyeValidateManifest({
          ...manifestFor('x'),
          'requiredRuntimeFeatures': ['teleport@1'],
        }),
        fails('teleport'),
      );
      expect(
        () => morneyeValidateManifest(manifestFor('x', network: ['bad host/'])),
        fails('network'),
      );
    });

    test('version comparison', () {
      expect(morneyeCompareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(morneyeCompareVersions('1.0.0', '1.0.0'), 0);
      expect(morneyeCompareVersions(null, '0.0.1'), lessThan(0));
    });

    test('archives need manifest.json and index.js and safe paths', () {
      expect(
        () => morneyeReadArchive(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<MorneyePackageError>()),
      );
      final ok = morneyeReadArchive(packageBytes(manifestFor('qobuz'), 'code'));
      expect(ok.code, 'code');
    });
  });

  group('fast provider resolution without skipping verification', () {
    test('selected metadata requires an exact id, title and artist', () {
      expect(
        morneyeSelectedTrackHint(
          id: '',
          title: 'Song',
          artist: 'Artist',
          durationMs: 200000,
        ),
        isNull,
      );
      expect(
        morneyeSelectedTrackHint(
          id: '123',
          title: '',
          artist: 'Artist',
          durationMs: null,
        ),
        isNull,
      );
      expect(
        morneyeSelectedTrackHint(
          id: '123',
          title: 'Song',
          artist: 'Artist',
          durationMs: 200000,
        ),
        {
          'id': '123',
          'name': 'Song',
          'artists': 'Artist',
          'duration_ms': 200000,
        },
      );
    });

    test('all failed provider lookups can retry enrichment once', () {
      for (final provider in ['tidal-web', 'qobuz-web', 'deezer', 'amazon']) {
        expect(
          morneyeShouldRetryEnrichment(
            available: {'available': false, 'reason': '$provider unavailable'},
            hasEnrichment: true,
          ),
          isTrue,
          reason: provider,
        );
      }
      expect(
        morneyeShouldRetryEnrichment(
          available: {'available': true, 'track_id': 't1'},
          hasEnrichment: true,
        ),
        isFalse,
      );
      expect(
        morneyeShouldRetryEnrichment(
          available: {'available': false},
          hasEnrichment: false,
        ),
        isFalse,
      );
    });
  });

  group('package manager', () {
    late FakeEngine engine;
    late MorneyePackages packages;
    final served = <String, Uint8List>{};

    Map<String, GuestMethod> downloader({
      String? payload,
      bool requiresContainerConversion = false,
      Map<String, Object?>? decryption,
      String? outputExtension,
      String? decryptionKey,
    }) => {
      'initialize': (args, call) async => true,
      'searchTracks': (args, call) async => [
        {
          'id': 't1',
          'name': 'Song',
          'artists': 'Artist',
          'album_name': 'Album',
          'duration_ms': 180000,
        },
        {'id': 'a1', 'name': 'An album', 'item_type': 'album'},
      ],
      'download': (args, call) async {
        final path = '${args[2]}';
        await call('file.write', [path, payload ?? 'audio']);
        return {
          'success': true,
          'file_path': path,
          if (decryption != null) 'decryption': decryption,
          if (outputExtension != null) 'output_extension': outputExtension,
          if (decryptionKey != null) 'decryption_key': decryptionKey,
          if (requiresContainerConversion)
            'requires_container_conversion': true,
        };
      },
    };

    setUp(() async {
      engine = FakeEngine();
      served.clear();
      packages = MorneyePackages(
        dir,
        storage: storage,
        native: native,
        starter: engine.start,
        fetch: (url, max) async {
          final body = served[url];
          if (body == null) throw const MorneyePackageError('HTTP 404');
          return body;
        },
      );
      await packages.load();
    });

    tearDown(() => packages.shutdown());

    test('starts with the official repository', () {
      expect(packages.repositories.single.url, morneyeRegistry);
      expect(packages.repositories.single.official, isTrue);
    });

    test('replaces the old default registry with Morneye', () async {
      const oldRegistry =
          'https://raw.githubusercontent.com/spotiflacapp/SpotiFLAC-Extension/main/registry.json';
      await File(p.join(dir.path, 'index.json')).writeAsString(
        jsonEncode({
          'repositories': [
            {'id': 'old-default', 'url': oldRegistry, 'name': 'Old registry'},
          ],
          'packages': [
            {
              'key': morneyeKeyOf('qobuz'),
              'name': 'qobuz',
              'manifest': manifestFor('qobuz'),
              'digest': 'test-digest',
              'installed_at': 1,
              'methods': ['initialize', 'searchTracks', 'download'],
              'repository_id': 'old-default',
              'enabled': true,
            },
          ],
        }),
      );
      final migrated = MorneyePackages(
        dir,
        storage: storage,
        native: native,
        starter: engine.start,
      );
      await migrated.load();

      expect(migrated.repositories, hasLength(1));
      expect(migrated.repositories.single.url, morneyeRegistry);
      expect(migrated.repositories.single.name, 'Morneye official');
      expect(
        migrated.find(morneyeKeyOf('qobuz'))?.repositoryId,
        migrated.repositories.single.id,
      );
      migrated.shutdown();
    });

    test(
      'installs from a file, survives a reload, and removes cleanly',
      () async {
        engine.scripts['v1'] = downloader();
        final addon = await packages.install(
          bytes: packageBytes(manifestFor('qobuz'), 'v1'),
        );
        expect(addon.displayName, 'QOBUZ');
        expect(addon.methods, contains('download'));
        expect(engine.configurations.last['heapMb'], 64);

        final again = MorneyePackages(
          dir,
          storage: storage,
          native: native,
          starter: engine.start,
        );
        await again.load();
        expect(again.find(addon.key)?.version, '1.0.0');

        await packages.remove(addon.key);
        expect(packages.find(addon.key), isNull);
        expect(
          Directory(p.join(dir.path, 'packages', addon.key)).existsSync(),
          isFalse,
        );
      },
    );

    test('refuses packages without the methods they promise', () async {
      engine.scripts['empty'] = {'initialize': (args, call) async => true};
      await expectLater(
        packages.install(bytes: packageBytes(manifestFor('qobuz'), 'empty')),
        throwsA(isA<MorneyePackageError>()),
      );
      expect(packages.addons, isEmpty);
    });

    test('new package is prioritized but updating it keeps user order', () async {
      SharedPreferences.setMockInitialValues({
        PlaybackSourcePriority.key: ['mono', 'yt'],
      });
      engine.scripts['v1'] = downloader();
      engine.scripts['v2'] = downloader();
      final addon = await packages.install(
        bytes: packageBytes(manifestFor('qobuz', version: '1.0.0'), 'v1'),
      );
      expect(await PlaybackSourcePriority.load(),
          ['a-${addon.key}', 'mono', 'yt']);
      await PlaybackSourcePriority.reorder(
          ['a-${addon.key}', 'mono', 'yt'], 0, 3);
      expect(await PlaybackSourcePriority.load(),
          ['mono', 'yt', 'a-${addon.key}']);

      await packages.install(
        bytes: packageBytes(manifestFor('qobuz', version: '2.0.0'), 'v2'),
      );
      expect(await PlaybackSourcePriority.load(),
          ['mono', 'yt', 'a-${addon.key}'],
          reason: 'An upgrade must not promote an existing package');
    });

    test('updates but never downgrades', () async {
      engine.scripts['v1'] = downloader();
      engine.scripts['v2'] = downloader();
      await packages.install(
        bytes: packageBytes(manifestFor('qobuz', version: '1.2.0'), 'v1'),
      );
      await expectLater(
        packages.install(
          bytes: packageBytes(manifestFor('qobuz', version: '1.1.0'), 'v2'),
        ),
        throwsA(isA<MorneyePackageError>()),
      );
      final updated = await packages.install(
        bytes: packageBytes(manifestFor('qobuz', version: '2.0.0'), 'v2'),
      );
      expect(updated.version, '2.0.0');
    });

    test('imports a documented .spotiflac-ext URL and can search it', () async {
      engine.scripts['v1'] = downloader();
      const url = 'https://repo.example.com/qobuz.spotiflac-ext';
      served[url] = packageBytes(manifestFor('qobuz'), 'v1');

      final addon = await packages.install(url: url);
      expect(addon.name, 'qobuz');
      expect(addon.methods, containsAll(['searchTracks', 'download']));
      final songs = await packages.search(addon.key, 'Song');
      expect(songs.single.title, 'Song');
    });

    test('installs from a repository and checks its SHA-256', () async {
      engine.scripts['v1'] = downloader();
      final bytes = packageBytes(manifestFor('tidal'), 'v1');
      const repo = 'https://repo.example.com/registry.json';
      const download = 'https://repo.example.com/tidal.sflx';
      Map<String, Object?> entry(String digest) => {
        'id': 'tidal',
        'name': 'Tidal',
        'version': '1.0.0',
        'category': 'download',
        'sha256': digest,
        'download_url': download,
      };
      served[download] = bytes;
      served[repo] = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'name': 'Friends',
            'extensions': [entry('0' * 64)],
          }),
        ),
      );
      final added = await packages.addRepo('https://repo.example.com/');
      expect(added.url, repo);
      expect(added.name, 'Friends');
      expect(packages.catalogue(added.id).single.name, 'Tidal');

      await expectLater(
        packages.install(repositoryId: added.id, id: 'tidal'),
        throwsA(
          isA<MorneyePackageError>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );

      served[repo] = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'extensions': [entry(sha256.convert(bytes).toString())],
          }),
        ),
      );
      await packages.refreshRepo(added.id);
      final addon = await packages.install(repositoryId: added.id, id: 'tidal');
      expect(addon.repositoryId, added.id);
      expect(packages.catalogue(added.id).single.installed, isNotNull);
      expect(
        () => packages.addRepo('http://repo.example.com/'),
        throwsA(isA<MorneyePackageError>()),
      );
    });

    test('settings start from the schema defaults', () async {
      engine.scripts['v1'] = downloader();
      final addon = await packages.install(
        bytes: packageBytes(
          manifestFor(
            'qobuz',
            extra: {
              'settings': [
                {'key': 'region', 'type': 'string', 'default': 'us'},
              ],
            },
          ),
          'v1',
        ),
      );
      expect(packages.settings(addon)['region'], 'us');
    });

    test(
      'searches keep only songs; a turned-off add-on is unavailable',
      () async {
        engine.scripts['v1'] = downloader();
        final addon = await packages.install(
          bytes: packageBytes(manifestFor('qobuz'), 'v1'),
        );
        final songs = await packages.search(addon.key, 'song');
        expect(songs.map((s) => s.id), ['t1']);
        expect(songs.single.duration, const Duration(minutes: 3));

        packages.setEnabled(addon.key, false);
        await expectLater(
          packages.search(addon.key, 'song'),
          throwsA(isA<MorneyePackageError>()),
        );
      },
    );

    test(
      'first click verifies availability without redundant enrichment',
      () async {
        var enriched = 0;
        var checked = 0;
        engine.scripts['fast-preflight'] = {
          ...downloader(),
          'enrichTrack': (args, call) async {
            enriched++;
            return {'name': 'Song'};
          },
          'checkAvailability': (args, call) async {
            checked++;
            expect(args[3], isA<Map>());
            return {'available': true, 'track_id': 't1'};
          },
        };
        final addon = await packages.install(
          bytes: packageBytes(manifestFor('qobuz'), 'fast-preflight'),
        );
        // A source-owned catalogue entry can be checked directly even if its
        // optional provider_id field is absent. The download still authorizes.
        await packages.search(addon.key, 'Song');
        final stages = <String>[];
        final download = await packages.download(
          addon.key,
          't1',
          forPlayback: true,
          onResolutionStage: stages.add,
        );
        expect(checked, 1);
        expect(
          enriched,
          0,
          reason: 'Availability should be attempted before enrichment',
        );
        expect(
          stages,
          containsAllInOrder([
            'worker_start',
            'initializing',
            'metadata',
            'availability',
            'preparing_media',
          ]),
        );
        await download.cleanup();
      },
    );

    test(
      'owned Search result uses the same availability-first path for Play',
      () async {
        var enriched = 0, checked = 0;
        engine.scripts['owned-fast-path'] = {
          ...downloader(),
          'searchTracks': (args, call) async => [
            {
              'id': 't1',
              'name': 'Song',
              'artists': 'Artist',
              'provider_id': 'tidal',
              'duration_ms': 180000,
            },
          ],
          'enrichTrack': (args, call) async {
            enriched++;
            return {'name': 'Song'};
          },
          'checkAvailability': (args, call) async {
            checked++;
            final options = args[3] as Map;
            expect((options['track'] as Map)['provider_id'], 'tidal');
            return {'available': true, 'track_id': 't1'};
          },
        };
        final addon = await packages.install(
          bytes: packageBytes(manifestFor('tidal-web'), 'owned-fast-path'),
        );
        await packages.search(addon.key, 'Song');
        final file = await packages.download(
          addon.key,
          't1',
          forPlayback: true,
        );
        expect(enriched, 0);
        expect(
          checked,
          1,
          reason: 'metadata and authorization are separate stages',
        );
        await file.cleanup();
      },
    );

    test(
      'native Tidal lookup also retries after failed availability',
      () async {
        final steps = <String>[];
        engine.scripts['tidal-retry'] = {
          ...downloader(),
          'searchTracks': (args, call) async => [
            {
              'id': 't1',
              'name': 'Song',
              'artists': 'Artist',
              'provider_id': 'tidal',
              'duration_ms': 180000,
            },
          ],
          'checkAvailability': (args, call) async {
            steps.add('availability');
            return steps.length >= 3
                ? {'available': true, 'track_id': 't1'}
                : {'available': false, 'reason': 'Refresh metadata'};
          },
          'enrichTrack': (args, call) async {
            steps.add('enrichment');
            return {'name': 'Song', 'tidal_id': 't1'};
          },
        };
        final addon = await packages.install(
          bytes: packageBytes(manifestFor('tidal-web'), 'tidal-retry'),
        );
        await packages.search(addon.key, 'Song');
        final downloaded = await packages.download(
          addon.key,
          't1',
          forPlayback: true,
        );
        expect(steps, ['availability', 'enrichment', 'availability']);
        await downloaded.cleanup();
      },
    );

    test(
      'failed cross-catalogue availability enriches and retries once',
      () async {
        final steps = <String>[];
        engine.scripts['cross-catalogue-retry'] = {
          ...downloader(),
          'searchTracks': (args, call) async => [
            {
              'id': 'spotify-track',
              'name': 'Song',
              'artists': 'Artist',
              'provider_id': 'spotify',
            },
          ],
          'checkAvailability': (args, call) async {
            steps.add('availability');
            final track = (args[3] as Map)['track'] as Map;
            return track['provider_id'] == 'tidal'
                ? {'available': true, 'track_id': 't1'}
                : {'available': false, 'reason': 'Needs provider match'};
          },
          'enrichTrack': (args, call) async {
            steps.add('enrichment');
            return {'id': 't1', 'provider_id': 'tidal'};
          },
        };
        final addon = await packages.install(
          bytes: packageBytes(
            manifestFor('tidal-web'),
            'cross-catalogue-retry',
          ),
        );
        await packages.search(addon.key, 'Song');
        final saved = await packages.download(
          addon.key,
          'spotify-track',
          forPlayback: false,
        );
        expect(steps, ['availability', 'enrichment', 'availability']);
        await saved.cleanup();
      },
    );

    test(
      'evicted Search track uses exact selected metadata, not extra getTrack',
      () async {
        var byId = 0;
        var available = 0;
        engine.scripts['hint-preflight'] = {
          ...downloader(),
          'getTrack': (args, call) async {
            byId++;
            return {'id': 't1', 'name': 'Song', 'artists': 'Artist'};
          },
          'checkAvailability': (args, call) async {
            available++;
            final options = args[3] as Map;
            expect(options['track']['name'], 'Song');
            return {'available': true, 'track_id': 't1'};
          },
        };
        final addon = await packages.install(
          bytes: packageBytes(manifestFor('qobuz'), 'hint-preflight'),
        );
        final file = await packages.download(
          addon.key,
          't1',
          forPlayback: true,
          trackHint: morneyeSelectedTrackHint(
            id: 't1',
            title: 'Song',
            artist: 'Artist',
            durationMs: 180000,
          ),
        );
        expect(byId, 0);
        expect(available, 1);
        await file.cleanup();
      },
    );

    test('downloads into a staging folder with a playable name', () async {
      engine.scripts['v1'] = downloader();
      final addon = await packages.install(
        bytes: packageBytes(manifestFor('qobuz'), 'v1'),
      );
      await packages.search(addon.key, 'song');
      native.info = {'codec': 'aac', 'format': 'isomp4', 'duration_ms': 181000};

      final download = await packages.download(addon.key, 't1');
      expect(engine.configurations.last['heapMb'], 256);
      expect(p.extension(download.file.path), '.m4a');
      expect(download.file.readAsStringSync(), 'audio');
      expect(download.metadata['name'], 'Song');
      await download.cleanup();
      expect(download.file.existsSync(), isFalse);
    });

    test(
      'converts a lossless stream container before validating playback',
      () async {
        engine.scripts['container'] = downloader(
          requiresContainerConversion: true,
        );
        native.info = {
          'codec': 'flac',
          'format': 'isomp4',
          'duration_ms': 181000,
        };
        final conversionPackages = MorneyePackages(
          dir,
          storage: storage,
          native: native,
          starter: engine.start,
          audioConverter: (inputPath, outputPath, codec) async {
            expect(codec, 'copy');
            expect(File(inputPath).existsSync(), isTrue);
            native.info = {
              'codec': 'flac',
              'format': 'flac',
              'duration_ms': 181000,
            };
            await File(outputPath).writeAsBytes([1, 2, 3, 4]);
          },
        );
        await conversionPackages.load();
        final addon = await conversionPackages.install(
          bytes: packageBytes(manifestFor('qobuz'), 'container'),
        );
        await conversionPackages.search(addon.key, 'song');

        final download = await conversionPackages.download(addon.key, 't1');
        expect(p.extension(download.file.path), '.flac');
        expect(download.info['codec'], 'flac');
        expect(download.file.readAsBytesSync(), [1, 2, 3, 4]);
        await download.cleanup();
        conversionPackages.shutdown();
      },
    );

    test(
      'decrypts the desktop Amazon descriptor before probing audio',
      () async {
        const key = '00112233445566778899aabbccddeeff';
        engine.scripts['encrypted'] = downloader(
          decryption: {'strategy': 'ffmpeg.mov_key', 'key': key},
        );
        var decrypted = false;
        final decryptPackages = MorneyePackages(
          dir,
          storage: storage,
          native: native,
          starter: engine.start,
          audioDecryptor: (input, output, suppliedKey) async {
            expect(suppliedKey, key);
            expect(File(input).readAsStringSync(), 'audio');
            decrypted = true;
            await File(output).writeAsBytes([1, 2, 3, 4]);
          },
        );
        await decryptPackages.load();
        addTearDown(decryptPackages.shutdown);
        final addon = await decryptPackages.install(
          bytes: packageBytes(manifestFor('qobuz'), 'encrypted'),
        );
        await decryptPackages.search(addon.key, 'song');
        final result = await decryptPackages.download(addon.key, 't1');
        expect(decrypted, isTrue);
        expect(p.extension(result.file.path), '.flac');
        expect(result.file.readAsBytesSync(), [1, 2, 3, 4]);
        await result.cleanup();
      },
    );

    for (final fixture in [
      (
        name: 'Amazon FLAC empty output extension',
        outer: '',
        inner: '',
        expected: '.flac',
      ),
      (
        name: 'empty outer extension uses descriptor',
        outer: '',
        inner: '.m4a',
        expected: '.m4a',
      ),
      (
        name: 'normalized extension remains an allowed container',
        outer: ' FLAC ',
        inner: '',
        expected: '.flac',
      ),
    ]) {
      test(fixture.name, () async {
        const key = '00112233445566778899aabbccddeeff';
        engine.scripts['amazon-container'] = downloader(
          outputExtension: fixture.outer,
          decryptionKey: key,
          decryption: {
            'strategy': 'ffmpeg.mov_key',
            'key': key,
            'input_format': 'mov',
            'output_extension': fixture.inner,
          },
        );
        var calls = 0;
        final instance = MorneyePackages(
          dir,
          storage: storage,
          native: native,
          starter: engine.start,
          audioDecryptor: (input, output, suppliedKey) async {
            expect(p.extension(output), fixture.expected);
            expect(suppliedKey, key);
            calls++;
            await File(output).writeAsBytes([1, 2, 3, 4]);
          },
        );
        await instance.load();
        addTearDown(instance.shutdown);
        final addon = await instance.install(
          bytes: packageBytes(manifestFor('amazon'), 'amazon-container'),
        );
        await instance.search(addon.key, 'song');
        final result = await instance.download(addon.key, 't1');
        expect(calls, 1);
        expect(result.file.readAsBytesSync(), [1, 2, 3, 4]);
        await result.cleanup();
      });
    }
    test('clear Amazon audio with an empty decryption key does not request decryption', () async {
      engine.scripts['clear-amazon'] = downloader(
        decryptionKey: '',
        outputExtension: '',
      );
      final addon = await packages.install(
        bytes: packageBytes(manifestFor('amazon'), 'clear-amazon'),
      );
      await packages.search(addon.key, 'song');
      final result = await packages.download(addon.key, 't1');
      expect(result.file.readAsStringSync(), 'audio');
      await result.cleanup();
    });
    test(
      'rejects a path or command in the decrypted output extension',
      () async {
        engine.scripts['bad-container'] = downloader(
          outputExtension: '../../escape.flac',
          decryption: {
            'strategy': 'ffmpeg.mov_key',
            'key': '00112233445566778899aabbccddeeff',
          },
        );
        final addon = await packages.install(
          bytes: packageBytes(manifestFor('amazon'), 'bad-container'),
        );
        await packages.search(addon.key, 'song');
        await expectLater(
          packages.download(addon.key, 't1'),
          throwsA(
            isA<MorneyePackageError>().having(
              (e) => e.message,
              'container',
              contains('Invalid decrypted audio container'),
            ),
          ),
        );
      },
    );

    test('rejects unknown decryption instead of forwarding arbitrary ffmpeg options', () async {
      engine.scripts['bad-key'] = downloader(
        decryption: {'strategy': 'arbitrary', 'key': 'bad'},
      );
      final addon = await packages.install(
        bytes: packageBytes(manifestFor('qobuz'), 'bad-key'),
      );
      await packages.search(addon.key, 'song');
      await expectLater(
        packages.download(addon.key, 't1'),
        throwsA(
          isA<MorneyePackageError>().having(
            (e) => e.message,
            'message',
            contains('descriptor'),
          ),
        ),
      );
    });

    test('refuses audio the phone can’t play or that doesn’t match', () async {
      engine.scripts['v1'] = downloader();
      final addon = await packages.install(
        bytes: packageBytes(manifestFor('qobuz'), 'v1'),
      );
      await packages.search(addon.key, 'song');

      native.info = {'codec': 'eac3', 'format': 'isomp4', 'duration_ms': 0};
      await expectLater(
        packages.download(addon.key, 't1'),
        throwsA(isA<MorneyePackageError>()),
      );

      native.info = {'codec': 'flac', 'format': 'flac', 'duration_ms': 30000};
      await expectLater(
        packages.download(addon.key, 't1'),
        throwsA(
          isA<MorneyePackageError>().having(
            (e) => e.message,
            'message',
            contains('duration'),
          ),
        ),
      );
      expect(
        Directory(p.join(dir.path, 'work')).listSync(),
        isEmpty,
        reason: 'failed downloads clean up after themselves',
      );
    });
  });
}
