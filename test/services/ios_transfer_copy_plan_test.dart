import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/models/ios_transfer_upload.dart';
import 'package:flick/models/lokal_remote_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/ios_library_scan_epoch.dart';
import 'package:flick/services/ios_transfer_copy_plan.dart';
import 'package:flick/services/ios_transfer_import_coordinator.dart';
import 'package:flick/services/ios_transfer_session.dart';
import 'package:flick/services/link/link_file_copy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';

import 'ios_transfer_queue_test.dart' show QueueNative;

const pairing = IosTransferPairing(
  scope: IosTransferScope(
    desktopId: 'desktop',
    origin: 'https://desktop.example',
    pairingId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  ),
  desktopUserId: 'account',
);

class _Native extends QueueNative {
  _Native(this.root);
  final String root;
  final batches = <List<IosTransferIntent>>[];
  final released = <String>[];
  bool loseReply = false;
  @override
  Future<IosTransferUploadContext> uploadSourceContext() async =>
      IosTransferUploadContext(
        id: '11111111-1111-4111-8111-111111111111',
        rootPath: root,
        canonicalRootPath: root,
        pairing: pairing,
      );
  @override
  Future<void> releaseUploadSource(String id) async {
    released.add(id);
  }

  @override
  Future<IosTransferSummary> enqueue(List<IosTransferIntent> intents) async {
    batches.add(List.unmodifiable(intents));
    if (loseReply) {
      loseReply = false;
      throw StateError('Lost acknowledgement');
    }
    return summary();
  }
}

class _Session extends IosTransferSession {
  _Session(_Native native)
    : super(
        native: native,
        coordinator: IosTransferImportCoordinator(
          native: native,
          store: () => throw StateError('Import store tested separately'),
          readMedia: (
            lease, {
            required isCurrent,
            required validateOwnership,
            cancelled,
          }) => throw StateError('Reader tested separately'),
        ),
      );
  int uploadCalls = 0;
  bool loseReply = false;
  final uploadIntents = <IosTransferIntent>[];
  final sourcePaths = <String?>[];
  @override
  Future<void> start() async {}
  @override
  Future<IosTransferSummary> enqueueUploadSong({
    required int songId,
    required IosTransferPairing expectedPairing,
    required void Function(IosTransferIntent intent) prepared,
    IosTransferIntent? frozenIntent,
    String? reviewedSourcePath,
  }) async {
    sourcePaths.add(reviewedSourcePath);
    final intent =
        frozenIntent ??
        IosTransferIntent(
          id: '22222222-2222-4222-8222-222222222222',
          identity: IosTransferIdentity(
            scope: expectedPairing.scope,
            sourceId: 'phone-song-$songId',
            localSongId: '$songId',
            desktopUserId: expectedPairing.desktopUserId,
          ),
          metadata: const IosTransferMetadata(
            title: 'Local',
            artist: 'Artist',
            fileExtension: 'wav',
          ),
          createdMs: 1000,
          expectedBytes: 4,
          expectedSha256: 'a' * 64,
        );
    prepared(intent);
    uploadCalls++;
    uploadIntents.add(intent);
    if (loseReply) {
      loseReply = false;
      throw StateError('Lost upload acknowledgement');
    }
    return native.summary();
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
  late Isar isar;
  late Directory root;
  late _Native native;
  late _Session session;
  late NetworkServerEntity server;
  late IosTransferCopyAdapter adapter;
  late LokalRemoteCredentials credentials;
  late Map<String, dynamic> track;
  Song local({String? path, int? offset}) => Song(
    id: '42',
    title: 'Local',
    artist: 'Artist',
    duration: const Duration(seconds: 2),
    fileType: 'WAV',
    filePath: path ?? '${root.path}/Music/local.wav',
    startOffsetMs: offset,
  );
  LinkCopyPlan plan({
    bool uploads = true,
    bool downloads = true,
    Song? existing,
    Song? upload,
  }) => LinkCopyPlan(
    server: server,
    toDesktop: uploads ? [upload ?? local()] : [],
    toPhone: downloads ? [(track: track, existing: existing)] : [],
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ios-copy-plan-');
    isar = await Isar.open(
      [SongEntitySchema, NetworkServerEntitySchema],
      directory: root.path,
      name: 'copy',
      relaxedDurability: false,
    );
    server = NetworkServerEntity()
      ..id = 3
      ..protocol = 'lokal'
      ..baseUrl = 'https://desktop.example'
      ..label = 'Desktop'
      ..username = 'desktop:account';
    await isar.writeTxn(() async {
      await isar.networkServerEntitys.put(server);
      await isar.songEntitys.put(
        SongEntity()
          ..id = 42
          ..filePath = '${root.path}/Music/local.wav'
          ..title = 'Local'
          ..artist = 'Artist'
          ..dateAdded = DateTime.utc(2026),
      );
    });
    native = _Native('${root.path}/Music');
    session = _Session(native);
    adapter = IosTransferCopyAdapter(isar: isar, session: session);
    credentials = LokalRemoteCredentials(
      origin: Uri.parse('https://desktop.example'),
      desktopId: 'desktop',
      desktopUserId: 'account',
      pairingID: pairing.scope.pairingId,
    );
    track = {
      'id': 'original-7',
      'title': 'Desktop song',
      'artist': 'Artist',
      'duration': 1.5,
      'fileType': 'wav',
    };
  });
  tearDown(() async {
    await session.dispose();
    await native.events.close();
    await isar.close();
    await root.delete(recursive: true);
  });

  test('review makes no submission; confirmation submits frozen downloads and reviewed upload sources once', () async {
    final prepared = (await adapter.prepare(plan(), credentials))!;
    expect(native.batches, isEmpty);
    expect(session.uploadCalls, 0);
    expect(native.released.length, 1);
    track['title'] = 'Changed after review';
    await prepared.submit();
    await prepared.submit();
    expect(native.batches.length, 1);
    expect(session.uploadCalls, 1);
    final download = native.batches.single.single;
    expect(download.metadata.title, 'Desktop song');
    expect(download.metadata.durationMs, 1500);
    expect(download.identity.localServerId, 3);
    expect(download.identity.sourceId, 'original-7');
    expect(session.sourcePaths.single, '${root.path}/Music/local.wav');
  });
  test(
    'desktop snake-case numeric metadata and genre lists survive plan freezing',
    () async {
      track.addAll({
        'sample_rate': 96000.0,
        'bit_depth': 24,
        'album_artist': 'Album artist',
        'track_number': 2,
        'genres': ['Jazz', 'Ambient'],
      });
      final prepared = (await adapter.prepare(
        plan(uploads: false),
        credentials,
      ))!;
      final metadata = prepared.downloads.single.metadata;
      expect(metadata.sampleRate, 96000);
      expect(metadata.bitDepth, 24);
      expect(metadata.trackNumber, 2);
      expect(metadata.albumArtist, 'Album artist');
      expect(metadata.genre, 'Jazz; Ambient');
      final counts = <int>[];
      await prepared.submit(
        onProgress: (queued, total) {
          counts.add(queued);
          expect(total, 1);
        },
      );
      expect(counts, [0, 1]);
    },
  );
  test('lost download acknowledgement retains exact job IDs and never falls back to foreground', () async {
    final prepared = (await adapter.prepare(
      plan(uploads: false),
      credentials,
    ))!;
    native.loseReply = true;
    await expectLater(prepared.submit(), throwsStateError);
    await prepared.submit();
    expect(native.batches.length, 2);
    expect(
      native.batches.first.single.toJson(),
      native.batches.last.single.toJson(),
    );
  });
  test('lost upload acknowledgement reuses its frozen intent without replaying admitted downloads', () async {
    final prepared = (await adapter.prepare(plan(), credentials))!;
    session.loseReply = true;
    await expectLater(prepared.submit(), throwsStateError);
    await prepared.submit();
    expect(native.batches.length, 1);
    expect(session.uploadIntents.length, 2);
    expect(
      identical(session.uploadIntents.first, session.uploadIntents.last),
      true,
    );
  });
  test('clear after preview retires consent even if the server and selected paths remain identical', () async {
    final prepared = (await adapter.prepare(plan(), credentials))!;
    await IosLibraryScanEpoch.withMutation(() async {});
    await expectLater(prepared.submit(), throwsStateError);
    expect(native.batches, isEmpty);
    expect(session.uploadCalls, 0);
  });
  test(
    'changed actual Isar server account prevents submission after review',
    () async {
      final prepared = (await adapter.prepare(plan(), credentials))!;
      await isar.writeTxn(() async {
        server.username = 'desktop:someone-else';
        await isar.networkServerEntitys.put(server);
      });
      await expectLater(prepared.submit(), throwsStateError);
      expect(native.batches, isEmpty);
      expect(session.uploadCalls, 0);
    },
  );
  test(
    'changed existing remote row cannot be overwritten by a reviewed download',
    () async {
      final song = Song(
        id: '43',
        title: 'Remote',
        artist: 'Artist',
        duration: Duration.zero,
        fileType: 'wav',
      );
      await isar.writeTxn(
        () => isar.songEntitys.put(
          SongEntity()
            ..id = 43
            ..filePath = 'lokal://3/original-7'
            ..title = 'Remote'
            ..artist = 'Artist'
            ..dateAdded = DateTime.utc(2026)
            ..remoteId = 'original-7'
            ..remoteServerId = 3
            ..sourceType = 'lokal',
        ),
      );
      final prepared = (await adapter.prepare(
        plan(uploads: false, existing: song),
        credentials,
      ))!;
      await isar.writeTxn(() async {
        final row = (await isar.songEntitys.get(43))!;
        row.filePath = '${root.path}/already-copied.wav';
        await isar.songEntitys.put(row);
      });
      await expectLater(prepared.submit(), throwsStateError);
      expect(native.batches, isEmpty);
    },
  );
  test('unqualified engine, external files and CUE segments retain whole-plan foreground behavior before admission', () async {
    native.qualified = false;
    expect(await adapter.prepare(plan(), credentials), isNull);
    native.qualified = true;
    expect(
      await adapter.prepare(
        plan(upload: local(path: '/outside/audio.wav')),
        credentials,
      ),
      isNull,
    );
    expect(
      await adapter.prepare(plan(upload: local(offset: 0)), credentials),
      isNull,
    );
    expect(native.batches, isEmpty);
    expect(session.uploadCalls, 0);
  });
}
