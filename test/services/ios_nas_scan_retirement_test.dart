import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flick/data/entities/ios_song_identity_entity.dart';
import 'package:flick/data/entities/ios_transfer_receipt_entity.dart';
import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/services/ios_library_scan_epoch.dart';
import 'package:flick/services/sources/native_smb_transport.dart';
import 'package:flick/services/sources/smb_service.dart';
import 'package:flick/services/sources/webdav_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:isar_community/isar.dart';

class _SmbSession implements NativeSmbSession {
  _SmbSession(this.listing);
  final Future<List<NativeSmbEntry>> Function() listing;
  bool closed = false;
  @override
  Future<List<NativeSmbEntry>> list(String directory) => listing();
  @override
  Future<void> close() async => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _body =
    '<D:multistatus xmlns:D="DAV:">'
    '<D:response><D:href>/music/Track.wav</D:href><D:propstat><D:prop>'
    '<D:getcontentlength>12</D:getcontentlength>'
    '</D:prop></D:propstat></D:response></D:multistatus>';

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
    final root = config.resolve('${package['rootUri']}/');
    final path = root
        .resolve(Platform.isMacOS ? 'macos/libisar.dylib' : 'linux/libisar.so')
        .toFilePath();
    expect(
      await File(path).exists(),
      true,
      reason: 'Actual native Isar core is required',
    );
    Isar.initializeIsarCore(libraries: {Abi.current(): path});
  });

  for (final protocol in ['smb', 'webdav']) {
    for (final removeServer in [false, true]) {
      test(
        '$protocol late scan cannot undo ${removeServer ? 'server removal' : 'library clear'}',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'lokal-nas-writer-',
          );
          final database = await Isar.open(
            [
              SongEntitySchema,
              NetworkServerEntitySchema,
              IosTransferReceiptEntitySchema,
              IosSongIdentityEntitySchema,
            ],
            directory: directory.path,
            name: 'nas',
            relaxedDurability: false,
          );
          addTearDown(() async {
            await database.close();
            await directory.delete(recursive: true);
          });
          final repository = SongRepository(
            isar: database,
            iosImportSafety: true,
          );
          final server = NetworkServerEntity()
            ..id = 3
            ..protocol = protocol
            ..label = 'Synthetic NAS'
            ..baseUrl = protocol == 'smb'
                ? 'smb://nas/Music'
                : 'http://nas/music';
          await database.writeTxn(
            () => database.networkServerEntitys.put(server),
          );
          final original = SongEntity()
            ..filePath = 'fixture://existing'
            ..title = 'Before clear'
            ..artist = 'Fixture'
            ..dateAdded = DateTime.utc(2026, 1, 1);
          await repository.upsertSong(original);
          final entered = Completer<void>(), release = Completer<void>();
          final smb = _SmbSession(() async {
            entered.complete();
            await release.future;
            return [
              (name: 'Track.wav', path: 'Track.wav', size: 12, isDir: false),
            ];
          });
          final client = MockClient((request) async {
            entered.complete();
            await release.future;
            return http.Response(_body, 207);
          });
          final scan = protocol == 'smb'
              ? SmbService.create(
                  songRepository: repository,
                  iosScanSafety: true,
                  connector: ({
                    required host,
                    required port,
                    required share,
                    required username,
                    required password,
                  }) async => smb,
                ).syncLibrary(server)
              : WebdavService.create(
                  client: client,
                  songRepository: repository,
                  iosScanSafety: true,
                ).syncLibrary(server);
          try {
            final refused = expectLater(scan.toList(), throwsStateError);
            await entered.future;
            await IosLibraryScanEpoch.withMutation(() async {
              await repository.deleteAllSongs();
              if (removeServer) {
                await database.writeTxn(
                  () => database.networkServerEntitys.delete(3),
                );
              }
            });
            release.complete();
            await refused;
            expect(await database.songEntitys.count(), 0);
            expect(
              (await database.networkServerEntitys.get(3))?.lastSyncedAt,
              isNull,
            );
            if (protocol == 'smb') expect(smb.closed, true);
            if (!removeServer) {
              final freshSmb = _SmbSession(
                () async => [
                  (
                    name: 'Track.wav',
                    path: 'Track.wav',
                    size: 12,
                    isDir: false,
                  ),
                ],
              );
              final freshClient = MockClient(
                (_) async => http.Response(_body, 207),
              );
              try {
                final fresh = protocol == 'smb'
                    ? SmbService.create(
                        songRepository: repository,
                        iosScanSafety: true,
                        connector: ({
                          required host,
                          required port,
                          required share,
                          required username,
                          required password,
                        }) async => freshSmb,
                      ).syncLibrary(server)
                    : WebdavService.create(
                        client: freshClient,
                        songRepository: repository,
                        iosScanSafety: true,
                      ).syncLibrary(server);
                expect((await fresh.toList()).last.isComplete, true);
                final songs = await repository.getSongsByRemoteServer(3);
                expect(songs.single.id, greaterThan(original.id));
                expect(
                  (await database.networkServerEntitys.get(3))?.lastSyncedAt,
                  isNotNull,
                );
              } finally {
                freshClient.close();
              }
            }
          } finally {
            if (!release.isCompleted) release.complete();
            client.close();
          }
        },
      );
    }
  }
}
