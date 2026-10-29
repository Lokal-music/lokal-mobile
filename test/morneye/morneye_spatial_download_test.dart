import 'dart:io';

import 'package:flick/core/utils/app_log.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/morneye/morneye_packages.dart';
import 'package:flick/features/morneye/morneye_service.dart';
import 'package:flick/features/morneye/morneye_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'morneye_fakes.dart';

class _Service implements MorneyeService {
  _Service(this.manager);
  final MorneyePackages manager;

  @override
  Future<MorneyePackages> get packages async => manager;

  @override
  Future<List<MorneyeAddon>> playable() async => manager.addons.toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lokal/atmos');
  const ffmpeg = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
  const ffmpegEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late MorneyePackages packages;
  late FakeEngine engine;
  final requested = <String>[];
  final probes = <String>[];
  const decryptedBytes = [1, 2, 3, 4];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppLog.instance.clear();
    root = await Directory.systemTemp.createTemp('morneye-spatial-');
    final native = FakeNative();
    final storage = MorneyeStorage(root, sealer: native, vault: MemoryVault());
    await storage.open();
    engine = FakeEngine();
    requested.clear();
    probes.clear();
    packages = MorneyePackages(
      root,
      storage: storage,
      native: native,
      starter: engine.start,
      audioDecryptor: (input, output, key) async {
        expect(File(input).readAsStringSync(), 'encrypted');
        await File(output).writeAsBytes(decryptedBytes);
      },
      audioConverter: (_, _, _) async =>
          fail('Encoded audio must not be transcoded'),
    );
    await packages.load();
    messenger.setMockMethodCallHandler(channel, (call) async {
      probes.add(call.method);
      final path = (call.arguments as Map)['path'] as String;
      expect(
        File(path).readAsBytesSync(),
        decryptedBytes,
        reason: 'Verify the decrypted bytes, not the encrypted download',
      );
      return true;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(ffmpeg, null);
    messenger.setMockMethodCallHandler(ffmpegEvents, null);
    packages.shutdown();
    await root.delete(recursive: true);
  });

  Future<MorneyeAddon> install({
    String provider = 'amazon',
    String? error,
    bool conversion = false,
  }) async {
    engine.scripts['spatial'] = {
      'initialize': (_, _) async => true,
      'searchTracks': (_, _) async => [],
      'download': (args, host) async {
        requested.add('${args[1]}');
        if (error != null) return {'success': false, 'error': error};
        await host('file.write', [args[2], 'encrypted']);
        return {
          'success': true,
          'file_path': args[2],
          'decryption': {
            'strategy': 'ffmpeg.mov_key',
            'key': '00112233445566778899aabbccddeeff',
            'output_extension': '.mp4',
          },
          'requires_container_conversion': conversion,
        };
      },
    };
    final addon = await packages.install(
      bytes: packageBytes(
        manifestFor(
          provider,
          extra: {
            'qualityOptions': [
              {'id': 'ac4', 'kind': 'spatial'},
              {'id': 'eac3'},
              {'id': 'best', 'kind': 'lossless'},
            ],
          },
        ),
        'spatial',
      ),
    );
    packages.setSettings(addon.key, {'downloadQuality': 'ac4'});
    return addon;
  }

  for (final forPlayback in [false, true]) {
    test(
      'explicit AC-4 request preserves verified bytes (playback=$forPlayback)',
      () async {
        final addon = await install(conversion: true);
        final result = await packages.download(
          addon.key,
          'track',
          quality: 'ac4',
          forPlayback: forPlayback,
        );
        expect(requested, ['ac4']);
        expect(probes, ['inspectAc4']);
        expect(result.atmosEncoded, isTrue);
        expect(result.atmosCodec, 'ac4');
        expect(result.info['codec'], 'ac4');
        expect(result.file.readAsBytesSync(), decryptedBytes);
        await result.cleanup();
      },
    );
  }

  test(
    'configured Amazon AC-4 save verifies bytes and bypasses conversion',
    () async {
      final addon = await install(conversion: true);
      final result = await packages.download(addon.key, 'track');
      expect(requested, ['ac4']);
      expect(probes, ['inspectAc4']);
      expect(result.atmosEncoded, isTrue);
      expect(result.atmosCodec, 'ac4');
      expect(result.file.readAsBytesSync(), decryptedBytes);
      await result.cleanup();
    },
  );

  for (final configured in ['ac4', 'eac3']) {
    test('ordinary playback excludes configured Amazon $configured', () async {
      final addon = await install();
      packages.setSettings(addon.key, {'downloadQuality': configured});
      final result = await packages.download(
        addon.key,
        'track',
        forPlayback: true,
      );
      expect(requested, ['best']);
      expect(probes, isEmpty);
      expect(result.atmosEncoded, isFalse);
      await result.cleanup();
    });
  }

  test('explicit Tidal Atmos retains JOC verification', () async {
    final addon = await install(provider: 'tidal', conversion: true);
    final result = await packages.download(
      addon.key,
      'track',
      quality: 'DOLBY_ATMOS',
      forPlayback: true,
    );
    expect(requested, ['DOLBY_ATMOS']);
    expect(probes, ['inspect']);
    expect(result.atmosEncoded, isTrue);
    expect(result.atmosCodec, 'eac3-joc');
    await result.cleanup();
  });

  void rejectCodecProbe() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      probes.add(call.method);
      return false;
    });
    messenger.setMockMethodCallHandler(ffmpeg, (_) async {
      throw PlatformException(code: 'probe_unavailable');
    });
    messenger.setMockMethodCallHandler(ffmpegEvents, (_) async => null);
  }

  test(
    'configured AC-4 save rejects an unverified file without conversion',
    () async {
      final addon = await install(conversion: true);
      rejectCodecProbe();
      await expectLater(
        packages.download(addon.key, 'track'),
        throwsA(isA<MorneyeSourceVerificationError>()),
      );
      expect(requested, ['ac4']);
      expect(probes, ['inspectAc4']);
      expect(
        Directory('${root.path}/work').listSync(),
        isEmpty,
        reason: 'Rejected downloads must release their staged files',
      );
    },
  );

  test(
    'unavailable requested quality is not reported as a codec probe failure',
    () async {
      final addon = await install(
        error: 'The requested quality is unavailable',
      );
      final client = MockClient(
        (_) async => fail('No network request expected'),
      );
      addTearDown(client.close);
      await expectLater(
        playOnlineTrack(
          'a-${addon.key}',
          const DiscoveryTrack(
            id: 'track',
            title: 'Title',
            artist: 'Artist',
            source: DiscoverySource.morneye,
            atmosRequestable: true,
            atmosRequested: true,
            atmosDownload: true,
          ),
          morneye: _Service(packages),
          client: client,
          forDownload: true,
        ),
        throwsA(
          isA<DiscoveryException>().having(
            (error) => error.message,
            'message',
            'Atmos download failed. No stereo track was substituted.',
          ),
        ),
      );
      expect(probes, isEmpty);
      expect(requested, ['ac4']);
      final start = AppLog.instance.entries.singleWhere(
        (entry) => entry.message.contains('"event":"download_start"'),
      );
      expect(start.message, contains('"quality":"ac4"'));
    },
  );

  test(
    'AC-4 verification failure reaches the caller as probe guidance',
    () async {
      final addon = await install();
      rejectCodecProbe();
      final client = MockClient(
        (_) async => fail('No network request expected'),
      );
      addTearDown(client.close);
      await expectLater(
        playOnlineTrack(
          'a-${addon.key}',
          const DiscoveryTrack(
            id: 'track',
            title: 'Title',
            artist: 'Artist',
            source: DiscoverySource.morneye,
            atmosRequestable: true,
            atmosRequested: true,
            atmosDownload: true,
          ),
          morneye: _Service(packages),
          client: client,
          forDownload: true,
        ),
        throwsA(
          isA<DiscoveryException>().having(
            (error) => error.message,
            'message',
            contains('not verified'),
          ),
        ),
      );
      expect(requested, ['ac4']);
      expect(probes, ['inspectAc4']);
    },
  );
}
