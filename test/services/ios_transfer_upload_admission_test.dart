import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/models/ios_transfer_upload.dart';
import 'package:flick/services/ios_library_scan_epoch.dart';
import 'package:flick/services/ios_transfer_upload_admission.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';

class _Port implements IosTransferUploadPort {
  _Port(this.root);
  final String root;
  final requests = <String>[];
  final released = <String>[];
  IosTransferIntent? submitted;
  Future<void> Function()? authorizing;
  @override
  Future<IosTransferUploadContext> uploadSourceContext() async =>
      IosTransferUploadContext(
        id: '11111111-1111-4111-8111-111111111111',
        rootPath: root,
        canonicalRootPath: root,
        pairing: const IosTransferPairing(
          scope: IosTransferScope(
            desktopId: 'desktop',
            origin: 'https://desktop.example',
            pairingId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          ),
          desktopUserId: 'account',
        ),
      );
  @override
  Future<IosTransferUploadGrant> authorizeUploadSource({
    required String contextId,
    required String relativePath,
    required String songId,
  }) async {
    requests.add(relativePath);
    await authorizing?.call();
    return IosTransferUploadGrant(
      id: '22222222-2222-4222-8222-222222222222',
      songId: songId,
      bytes: 4,
      sha256: List.filled(64, 'a').join(),
    );
  }

  @override
  Future<void> releaseUploadSource(String id) async {
    released.add(id);
  }

  @override
  Future<IosTransferSummary> enqueueUpload(
    IosTransferIntent intent, {
    String? grantId,
  }) async {
    submitted = intent;
    throw StateError('Lost native acknowledgement');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final config = File('.dart_tool/package_config.json').absolute.uri;
    final packages =
        (jsonDecode(await File.fromUri(config).readAsString())
                as Map)['packages']
            as List;
    final package = packages.cast<Map>().singleWhere(
      (row) => row['name'] == 'isar_community_flutter_libs',
    );
    final path = config
        .resolve('${package['rootUri']}/')
        .resolve(Platform.isMacOS ? 'macos/libisar.dylib' : 'linux/libisar.so')
        .toFilePath();
    expect(
      await File(path).exists(),
      true,
      reason: 'Actual native Isar core required',
    );
    Isar.initializeIsarCore(libraries: {Abi.current(): path});
  });
  late Directory root;
  late Isar isar;
  late _Port port;
  late IosTransferUploadAdmission admission;
  setUp(() async {
    root = (await Directory.systemTemp.createTemp('ios-upload-admission-'))
        .resolveSymbolicLinksSyncDirectory();
    isar = await Isar.open(
      [SongEntitySchema],
      directory: root.path,
      name: 'sources',
      relaxedDurability: false,
    );
    final album = await Directory('${root.path}/Café').create();
    final source = await File('${album.path}/track.wav')
        .writeAsBytes([1, 2, 3, 4]);
    await isar.writeTxn(
      () => isar.songEntitys.put(
        SongEntity()
          ..id = 42
          ..filePath = source.path
          ..title = 'Original'
          ..artist = 'Artist'
          ..dateAdded = DateTime.utc(2026)
          ..durationMs = 2000,
      ),
    );
    port = _Port(root.path);
    admission = IosTransferUploadAdmission(isar: isar, port: port);
  });
  tearDown(() async {
    await isar.close();
    await root.delete(recursive: true);
  });

  test('actual Isar metadata and native hash freeze before an ambiguous reply; all grants release', () async {
    IosTransferIntent? frozen;
    await expectLater(
      admission.enqueueSong(
        songId: 42,
        expectedPairing: (await port.uploadSourceContext()).pairing,
        prepared: (intent) => frozen = intent,
      ),
      throwsStateError,
    );
    expect(port.requests, ['Café/track.wav']);
    expect(identical(frozen, port.submitted), true);
    expect(frozen!.metadata.title, 'Original');
    expect(frozen!.identity.localSongId, '42');
    expect(frozen!.identity.desktopUserId, 'account');
    expect(frozen!.expectedBytes, 4);
    expect(frozen!.expectedSha256, List.filled(64, 'a').join());
    expect(port.released.length, 2);
  });

  for (final change in ['delete', 'metadata', 'path', 'clear']) {
    test(
      'actual Isar $change during native hashing prevents submission',
      () async {
        port.authorizing = () async {
          if (change == 'clear') {
            await IosLibraryScanEpoch.withMutation(() async {});
          } else {
            await isar.writeTxn(() async {
              if (change == 'delete') {
                await isar.songEntitys.delete(42);
              } else {
                final song = (await isar.songEntitys.get(42))!;
                if (change == 'metadata') {
                  song.title = 'Changed';
                } else {
                  song.filePath = '${root.path}/different.wav';
                }
                await isar.songEntitys.put(song);
              }
            });
          }
        };
        await expectLater(
          admission.enqueueSong(
            songId: 42,
            expectedPairing: (await port.uploadSourceContext()).pairing,
            prepared: (_) => fail('stale intent escaped'),
          ),
          throwsStateError,
        );
        expect(port.submitted, isNull);
        expect(port.released.length, 2);
      },
    );
  }

  test('reviewed desktop consent cannot upload to a newer pairing', () async {
    await expectLater(
      admission.enqueueSong(
        songId: 42,
        expectedPairing: const IosTransferPairing(
          scope: IosTransferScope(
            desktopId: 'other-desktop',
            origin: 'https://desktop.example',
            pairingId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          ),
          desktopUserId: 'account',
        ),
        prepared: (_) => fail('wrong desktop intent'),
      ),
      throwsStateError,
    );
    expect(port.requests, isEmpty);
    expect(port.submitted, isNull);
    expect(port.released.length, 1);
  });

  for (final kind in ['cue', 'network', 'outside']) {
    test('$kind source does not reach native authorization', () async {
      await isar.writeTxn(() async {
        final song = (await isar.songEntitys.get(42))!;
        if (kind == 'cue') song.startOffsetMs = 0;
        if (kind == 'network') song.sourceType = 'smb';
        if (kind == 'outside') song.filePath = Platform.resolvedExecutable;
        await isar.songEntitys.put(song);
      });
      await expectLater(
        admission.enqueueSong(
          songId: 42,
          expectedPairing: (await port.uploadSourceContext()).pairing,
          prepared: (_) => fail('invalid intent'),
        ),
        throwsStateError,
      );
      expect(port.requests, isEmpty);
      expect(port.submitted, isNull);
    });
  }
}

extension on Directory {
  Directory resolveSymbolicLinksSyncDirectory() =>
      Directory(resolveSymbolicLinksSync());
}
