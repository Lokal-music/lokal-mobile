import 'package:flick/services/ios_transfer_cue_mapping.dart';
import 'package:flick/services/ios_transfer_song_identity.dart';
import 'package:flick/services/ios_library_scan_epoch.dart';
// Actual Isar/libmdbx contracts. The native lease callback and media description
// are fixture boundaries; this is not installed-app/import/media acceptance.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:isar_community/isar.dart';
import 'package:flick/data/entities/artist_entity.dart';
import 'package:flick/data/entities/folder_entity.dart';
import 'package:flick/data/entities/ios_transfer_receipt_entity.dart';
import 'package:flick/data/entities/link_event_entities.dart';
import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/data/entities/recently_played_entity.dart';
import 'package:flick/data/entities/song_audio_cache_entity.dart';
import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/models/ios_transfer_import.dart';
import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/models/ios_transfer_orphan.dart';
import 'package:flick/services/ios_transfer_import_store.dart';
import 'package:flick/services/ios_transfer_scan_guard.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> rejects(
  Future<Object?> Function() action, [
  IosTransferImportConflict? reason,
]) async {
  try {
    await action();
  } on IosTransferImportException catch (error) {
    if (reason != null) {
      require(error.reason == reason, 'Unexpected import conflict');
    }
    return;
  } on FormatException {
    if (reason == null) return;
    rethrow;
  }
  throw StateError('Expected operation to be refused');
}

class Fixture {
  Fixture(this.root, this.audio, this.document);
  final Directory root;
  final File audio;
  final Map<String, dynamic> document;
  Isar? _db;
  Isar get db => _db!;
  String get music => '${root.path}/Music';
  IosTransferJob job([String phase = 'validating']) =>
      IosTransferJob.fromJson({...document, 'phase': phase});
  IosTransferLibraryTarget get target => IosTransferLibraryTarget(
    'Desktop Copies/Verified fixture - ${job().id}-r1.wav',
  );
  IosTransferLibraryReceipt get copy => IosTransferLibraryReceipt(
    relativePath: target.relativePath,
    bytes: job().receivedBytes!,
    sha256: job().receivedSha256!,
  );
  IosTransferImportStore store({Future<void> Function(String)? boundary}) =>
      IosTransferImportStore(
        db,
        musicRoot: music,
        now: () => DateTime.utc(2026, 10, 28),
        testingBoundary: boundary,
      );
  static const media = IosTransferMediaInfo(
    recognized: true,
    codec: 'WAV',
    durationMs: 2000,
    sampleRate: 16000,
    bitDepth: 16,
    channels: 1,
    bitrate: 256,
  );
  Future<void> open({bool includeReceipts = true}) async {
    _db = await Isar.open(
      [
        SongEntitySchema,
        FolderEntitySchema,
        RecentlyPlayedEntitySchema,
        ArtistEntitySchema,
        SongAudioCacheEntitySchema,
        NetworkServerEntitySchema,
        PlayEventEntitySchema,
        LibraryOpEntitySchema,
        if (includeReceipts) IosTransferReceiptEntitySchema,
      ],
      directory: root.path,
      name: 'ios_import_contracts',
      relaxedDurability: false,
    );
  }

  Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }

  Future<void> seed({bool existing = true}) async {
    await Directory(music).create(recursive: true);
    final identity = job().intent.identity;
    final server = NetworkServerEntity()
      ..id = 3
      ..label = 'Synthetic desktop'
      ..protocol = 'lokal'
      ..baseUrl = '${identity.scope.origin}/'
      ..username = '${identity.scope.desktopId}:${identity.desktopUserId}';
    await db.writeTxn(() async {
      await db.networkServerEntitys.put(server);
      if (existing) {
        await db.songEntitys.put(
          SongEntity()
            ..id = 42
            ..filePath = 'lokal://3/original-7'
            ..sourceType = 'lokal'
            ..remoteServerId = 3
            ..remoteId = identity.sourceId
            ..title = 'Current library title'
            ..artist = 'Current artist'
            ..album = 'Current album'
            ..genre = 'Current genre'
            ..albumArtPath = '/owned/custom-cover.png'
            ..dateAdded = DateTime.utc(2020)
            ..hasLocalEdits = true
            ..sampleRate = 96000
            ..bitDepth = 24,
        );
        await db.recentlyPlayedEntitys.put(
          RecentlyPlayedEntity()
            ..songId = 42
            ..playedAt = DateTime.utc(2025),
        );
      }
    });
  }

  Future<IosTransferImportResult> prepare({
    bool Function()? current,
    Future<void> Function()? ownership,
    Future<void> Function(String)? boundary,
  }) => store(boundary: boundary).prepare(
    job(),
    target,
    isCurrent: current ?? () => true,
    validateOwnership: ownership ?? () async {},
  );
  Future<IosTransferImportResult> commit({
    bool Function()? current,
    Future<void> Function()? ownership,
    Future<void> Function(String)? boundary,
  }) async {
    await store().recordMediaValidation(
      job(),
      target,
      media,
      isCurrent: current ?? () => true,
      validateOwnership: ownership ?? () async {},
    );
    return store(boundary: boundary).commit(
      job('importing'),
      copy,
      media,
      isCurrent: current ?? () => true,
      validateOwnership: ownership ?? () async {},
    );
  }

  Future<void> publishFixture() async {
    final file = File(store().absolutePath(target));
    await file.parent.create(recursive: true);
    await audio.copy(file.path);
    require(
      (await sha256.bind(file.openRead()).first).toString() == copy.sha256,
      'Fixture file checksum',
    );
  }
}

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  require(arguments.length.isEven, 'Expected named fixture options');
  for (var i = 0; i < arguments.length; i += 2) {
    options[arguments[i]] = arguments[i + 1];
  }
  final library = options['--isar-library']!, audio = File(options['--audio']!);
  Isar.initializeIsarCore(libraries: {Abi.current(): library});
  final payload = await audio.readAsBytes();
  require(
    payload.length == 64044 &&
        (await sha256.bind(audio.openRead()).first).toString() ==
            '4a2dd160d62a6073256c461efe0e3ae9a9d34e64f346da5830a4b445e15a9b54',
    'Expected the generated native WAV fixture',
  );
  final original =
      (jsonDecode(
            File('test/fixtures/ios_transfer_intents_v1.json')
                .readAsStringSync(),
          ) as List).single
          as Map;
  Map<String, dynamic> document(bool existing) {
    final row = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(original)) as Map,
    );
    (row['metadata'] as Map)['fileExtension'] = 'wav';
    if (!existing) (row['identity'] as Map).remove('localSongID');
    return {
      ...row,
      'revision': 1,
      'direction': 'download',
      'updatedMs': 2000,
      'expectedBytes': payload.length,
      'expectedSHA256': sha256.convert(payload).toString(),
      'receivedBytes': payload.length,
      'receivedSHA256': sha256.convert(payload).toString(),
    };
  }

  if (options['--worker'] != null) {
    final root = Directory(options['--root']!);
    final data = Map<String, dynamic>.from(
      jsonDecode(File('${root.path}/job.json').readAsStringSync()) as Map,
    );
    final fixture = Fixture(root, audio, data);
    await fixture.open();
    Future<void> boundary(String stage) async {
      if (stage == options['--boundary']) exit(95);
    }

    if (options['--worker'] == 'prepare') {
      await fixture.prepare(boundary: boundary);
    } else if (options['--worker'] == 'retiring') {
      await fixture
          .store(boundary: boundary)
          .beginRetirement(
            fixture.job(),
            fixture.target,
            isCurrent: () => true,
            validateCleanupAuthority: () async {},
          );
    } else if (options['--worker'] == 'orphan') {
      final pending =
          (await fixture.store().pendingReservations()).entries.single;
      final lease = IosTransferOrphanLease.fromJson({
        'permission': 'orphanCleanup',
        'id': fixture.job().id,
        'revision': 1,
        'songID': 42,
        'leaseID': 'a7d96b93-6526-4f1f-a1af-688ffb5c799d',
        'clientID': 'b7d96b93-6526-4f1f-a1af-688ffb5c799d',
        'currentJob': {
          ...fixture.document,
          'phase': 'cancelled',
          'revision': 2,
        },
      });
      await fixture
          .store(boundary: boundary)
          .retireOrphanReservation(
            pending,
            lease,
            isCurrent: () => true,
            validateBookkeepingAuthority: () async {},
          );
    } else if (options['--worker'] == 'retired') {
      await fixture
          .store(boundary: boundary)
          .retireReservation(
            fixture.job(),
            fixture.target,
            isCurrent: () => true,
            validateOwnership: () async {},
          );
    } else if (options['--worker'] == 'media') {
      await fixture
          .store(boundary: boundary)
          .recordMediaValidation(
            fixture.job(),
            fixture.target,
            Fixture.media,
            isCurrent: () => true,
            validateOwnership: () async {},
          );
    } else {
      await fixture.commit(boundary: boundary);
    }
    await fixture.close();
    return;
  }

  final root = await Directory.systemTemp.createTemp(
    'lokal-isar-import-contracts-',
  );
  final packageConfig = (await Isolate.packageConfig)!.toFilePath();
  var stage = 'startup';
  Future<void> scenario(
    String name,
    Future<void> Function(Fixture) action, {
    bool existing = true,
  }) async {
    if (options['--scenario'] != null && options['--scenario'] != name) return;
    stage = name;
    final directory = await Directory('${root.path}/$name').create();
    final data = document(existing);
    await File('${directory.path}/job.json').writeAsString(jsonEncode(data));
    final fixture = Fixture(directory, audio, data);
    await fixture.open();
    try {
      await fixture.seed(existing: existing);
      await action(fixture);
    } finally {
      await fixture.close();
    }
  }

  Future<ProcessResult> child(
    Fixture fixture,
    String worker, [
    String boundary = 'none',
  ]) => Process.run(Platform.resolvedExecutable, [
    '--packages=$packageConfig',
    Platform.script.toFilePath(),
    '--isar-library',
    library,
    '--audio',
    audio.path,
    '--root',
    fixture.root.path,
    '--worker',
    worker,
    '--boundary',
    boundary,
  ]);
  try {
    if (options['--legacy-root'] case final String directory) {
      final data = Map<String, dynamic>.from(
        jsonDecode(await File('$directory/job.json').readAsString()) as Map,
      );
      final legacy = Fixture(Directory(directory), audio, data);
      await legacy.open();
      try {
        await legacy.seed();
        final old = (await legacy.store().peek(legacy.job(), legacy.target))!;
        require(
          old.receipt.id == 7 &&
              old.receipt.preparedAt.isAtSameMomentAs(DateTime.utc(2020)) &&
              old.validatedMedia == null,
          'Actual old private schema upgrades with identity/history intact and no invented media',
        );
        await legacy.store().recordMediaValidation(
          legacy.job(),
          legacy.target,
          Fixture.media,
          isCurrent: () => true,
          validateOwnership: () async {},
        );
        await legacy.close();
        await legacy.open();
        final upgraded = (await legacy.store().peek(
          legacy.job(),
          legacy.target,
        ))!;
        require(
          upgraded.receipt.id == 7 &&
              upgraded.receipt.preparedAt.isAtSameMomentAs(
                DateTime.utc(2020),
              ) &&
              upgraded.validatedMedia?.bitDepth == 16,
          'New validated media persists alongside the preserved old-schema reservation',
        );
      } finally {
        await legacy.close();
      }
    }
    for (final boundary in ['media:beforeCommit', 'media:afterCommit']) {
      await scenario('process-${boundary.replaceAll(':', '-')}', (
        fixture,
      ) async {
        await fixture.prepare();
        await fixture.close();
        final exited = await child(fixture, 'media', boundary);
        require(
          exited.exitCode == 95,
          'Media child exits at the exact writer boundary',
        );
        await fixture.open();
        final saved = (await fixture.store().peek(
          fixture.job(),
          fixture.target,
        ))!;
        require(
          (saved.validatedMedia != null) == boundary.endsWith('afterCommit'),
          'Process loss leaves either no reader result or the complete hash-bound validation',
        );
        require(
          saved.receipt.state == 'prepared' &&
              saved.song!.sourceType == 'lokal',
          'Saving media alone never claims file publication or a playable Song commit',
        );
      });
    }
    await scenario('add-private-schema', (fixture) async {
      // Reopen the same file with the eight existing product collections first.
      // Adding receipts must preserve every serialized field and reference.
      await fixture.close();
      await fixture.open(includeReceipts: false);
      await fixture.db.writeTxn(() async {
        await fixture.db.artistEntitys.put(
          ArtistEntity()
            ..name = 'Existing artist'
            ..artPath = '/owned/artist.png',
        );
        await fixture.db.folderEntitys.put(
          FolderEntity()
            ..uri = fixture.music
            ..displayName = 'Existing Music'
            ..dateAdded = DateTime.utc(2020)
            ..songCount = 1,
        );
        await fixture.db.songAudioCacheEntitys.put(
          SongAudioCacheEntity()
            ..songId = 42
            ..peaks = [0.1, 0.2]
            ..lufs = -14,
        );
        await fixture.db.playEventEntitys.put(
          PlayEventEntity()
            ..eventId = 'fixture-play'
            ..deviceId = 'fixture-phone'
            ..trackKey = 'fixture-track'
            ..playedAt = 1000
            ..msPlayed = 500
            ..source = 'local'
            ..trackJson = '{}',
        );
        await fixture.db.libraryOpEntitys.put(
          LibraryOpEntity()
            ..opId = 'fixture-op'
            ..deviceId = 'fixture-phone'
            ..hlc = 'fixture-clock'
            ..entity = 'track'
            ..entityId = 'fixture-track'
            ..op = 'update'
            ..fieldsJson = '{"liked":true}',
        );
      });
      Future<String> snapshot() async => jsonEncode(
        await Future.wait([
          fixture.db.songEntitys.where().exportJson(),
          fixture.db.folderEntitys.where().exportJson(),
          fixture.db.recentlyPlayedEntitys.where().exportJson(),
          fixture.db.artistEntitys.where().exportJson(),
          fixture.db.songAudioCacheEntitys.where().exportJson(),
          fixture.db.networkServerEntitys.where().exportJson(),
          fixture.db.playEventEntitys.where().exportJson(),
          fixture.db.libraryOpEntitys.where().exportJson(),
        ]),
      );
      final before = await snapshot();
      await fixture.close();
      await fixture.open();
      require(
        await snapshot() == before,
        'Adding the private collection preserves all eight existing collections',
      );
      require(
        await fixture.db.iosTransferReceiptEntitys.count() == 0,
        'Schema addition creates no transfer intent or receipt',
      );
      await fixture.prepare();
      require(
        jsonEncode(await fixture.db.libraryOpEntitys.where().exportJson()) ==
            jsonEncode([jsonDecode(before)[7][0]]),
        'Private preparation never enters the peer library journal',
      );
      await fixture.close();
      await fixture.open();
      require(
        await fixture.db.iosTransferReceiptEntitys.count() == 1,
        'The new private collection survives reopening',
      );
    });
    await scenario('identity', (fixture) async {
      final first = await fixture.prepare();
      require(
        first.receipt.localSongId == 42 && first.song!.sourceType == 'lokal',
        'Preparation preserves streaming row',
      );
      require(
        await fixture.db.writeTxn(
          () => fixture.store().isReservedPathInTransaction(
            fixture.store().absolutePath(fixture.target),
          ),
        ),
        'Prepared copy is reserved from indexing',
      );
      await fixture.publishFixture();
      final result = await fixture.commit();
      require(
        result.committed && result.song!.id == 42,
        'Same local identity commits',
      );
      require(
        result.song!.title == 'Current library title' &&
            result.song!.genre == 'Current genre' &&
            result.song!.hasLocalEdits &&
            result.song!.albumArtPath == '/owned/custom-cover.png' &&
            result.song!.dateAdded.isAtSameMomentAs(DateTime.utc(2020)),
        'Current/user metadata is preserved',
      );
      require(
        result.song!.sampleRate == 16000 &&
            result.song!.bitDepth == 16 &&
            result.song!.sourceType == null,
        'Verified media quality replaces remote guesses',
      );
      require(
        (await fixture.db.recentlyPlayedEntitys.where().findFirst())!.songId ==
            42,
        'History reference preserved',
      );
      require(
        !await fixture.db.writeTxn(
          () => fixture.store().isReservedPathInTransaction(
            fixture.store().absolutePath(fixture.target),
          ),
        ),
        'Committed copy can be indexed',
      );
      await fixture.close();
      await fixture.open();
      require(
        (await fixture.prepare()).committed &&
            (await fixture.commit()).committed,
        'Lost acknowledgement reopens idempotently',
      );
      require(
        await fixture.db.songEntitys.count() == 1 &&
            await fixture.db.iosTransferReceiptEntitys.count() == 1,
        'One row/receipt',
      );
      await fixture.db.writeTxn(() => fixture.db.songEntitys.delete(42));
      require(
        (await fixture.commit()).removedAfterCommit &&
            await fixture.db.songEntitys.count() == 0,
        'Committed deletion never resurrects its recording',
      );
    });
    await scenario('atomic-native-cue-mapping', (fixture) async {
      final path = fixture.store().absolutePath(fixture.target);
      final mapping = IosTransferCueMapping(fixture.db);
      SongEntity track(int start, int end) => SongEntity()
        ..filePath = path ..title = 'CUE $start' ..artist = 'CUE artist'
        ..startOffsetMs = start ..endOffsetMs = end ..durationMs = end - start
        ..fileSize = fixture.copy.bytes ..dateAdded = DateTime.utc(2026);
      Future<List<SongEntity>> rows() => fixture.db.songEntitys.where()
          .filePathEqualToAnyStartOffsetMs(path).findAll();
      Future<void> refuses(Future<Object?> Function() work) async {
        var refused = false;
        try { await work(); } on StateError { refused = true; }
        require(refused, 'Unsafe CUE replacement must refuse');
      }
      await fixture.prepare();
      await refuses(() => IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() =>
        mapping.replaceInTransaction(path, [track(0, 2000)], expected: []))));
      require((await fixture.store().peek(fixture.job(), fixture.target))!.receipt.state == 'prepared',
        'Preparing import refuses the entire CUE transaction');
      await fixture.publishFixture();
      await fixture.commit();
      final original = await rows();
      final cue = [track(0, 500), track(500, 2000)];
      await IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() async {
        require(await mapping.replaceInTransaction(path, cue, expected: original),
          'Native committed file is mapped atomically');
      }));
      require(cue[0].id == 42 && cue[1].id == 43 && await fixture.db.songEntitys.count() == 2,
        'First CUE range retains raw identity; new range gets distinct identity');
      require(!await fixture.db.writeTxn(() =>
          IosTransferScanGuard(fixture.db).allowsRemovalInTransaction(43)),
        'Ordinary scan cleanup cannot partially remove a protected derived range');
      require(cue[0].dateAdded.isAtSameMomentAs(DateTime.utc(2020)) && cue[0].hasLocalEdits &&
          cue[0].title == 'Current library title' && cue[0].remoteId == fixture.job().intent.identity.sourceId,
        'Manual metadata, original date and desktop binding survive conversion');
      final beforeExtension = await rows();
      final extended = [track(0, 500), track(500, 1000), track(1000, 2000)];
      await IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() =>
        mapping.replaceInTransaction(path, extended, expected: beforeExtension)));
      require(extended.map((row) => row.id).join(',') == '42,43,44',
        'Existing range IDs survive edits and an additional range');
      await refuses(() => IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() =>
        mapping.replaceInTransaction(path, [track(0, 2000)], expected: original))));
      final snapshot = await rows();
      await refuses(() => IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() =>
        mapping.replaceInTransaction(path, [track(0, 1500), track(1000, 2000)], expected: snapshot))));
      await refuses(() => IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() async {
        await mapping.replaceInTransaction(path, [track(500, 1000), track(1000, 2000)], expected: snapshot);
        throw StateError('Induced post-replacement rollback');
      })));
      await fixture.close();
      await fixture.open();
      require(await fixture.db.songEntitys.count() == 3 && await fixture.db.songEntitys.get(42) != null,
        'Actual rollback/reopen restores original anchor and all three ranges');
      final current = await rows();
      await IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() =>
        IosTransferCueMapping(fixture.db).replaceInTransaction(path,
          [track(500, 1000), track(1000, 2000)], expected: current)));
      final receipt = (await fixture.store().peek(fixture.job(), fixture.target))!;
      require(receipt.committed && receipt.removedAfterCommit && receipt.receipt.localSongId == 42 &&
          await fixture.db.songEntitys.get(43) != null && await fixture.db.songEntitys.get(44) != null,
        'Removing the anchored CUE range keeps history and other range IDs, never recreates it');
      require(sha256.convert(await File(path).readAsBytes()).toString() == fixture.copy.sha256,
        'Metadata mapping never changes public audio bytes');
    });
    await scenario('historical-song-id-allocation', (fixture) async {
      await fixture.prepare();
      await fixture.publishFixture();
      await fixture.commit();
      await fixture.db.writeTxn(() => fixture.db.songEntitys.clear());
      await fixture.close();
      await fixture.open();
      SongEntity fresh(String path) => SongEntity()
        ..filePath = path ..title = 'New recording' ..artist = 'Fixture'
        ..dateAdded = DateTime.utc(2026);
      final first = fresh('/new-first.wav'), second = fresh('/new-second.wav');
      await fixture.db.writeTxn(() async {
        await retainIosImportSongIdentitiesInTransaction(fixture.db, [first, second]);
        await fixture.db.songEntitys.putAll([first, second]);
      });
      require(first.id == 43 && second.id == 44 &&
          (await fixture.store().peek(fixture.job(), fixture.target))!.removedAfterCommit,
        'Fresh rows after empty database reopen cannot occupy historical import IDs');
      var refused = false;
      try {
        await fixture.db.writeTxn(() async {
          final stale = fresh('/stale-anchor.wav')..id = 42;
          await retainIosImportSongIdentitiesInTransaction(fixture.db, [stale]);
          await fixture.db.songEntitys.put(stale);
        });
      } on StateError { refused = true; }
      require(refused && await fixture.db.songEntitys.get(42) == null,
        'Stale explicit historical ID cannot recreate a removed recording');
      final current = (await fixture.db.songEntitys.get(first.id))!;
      current.title = 'Current edit';
      await fixture.db.writeTxn(() async {
        await retainIosImportSongIdentitiesInTransaction(fixture.db, [current]);
        await fixture.db.songEntitys.put(current);
      });
      require((await fixture.db.songEntitys.get(first.id))!.title == 'Current edit',
        'Existing current IDs retain normal metadata editing');
      try {
        await fixture.db.writeTxn(() async {
          final receipt = (await fixture.db.iosTransferReceiptEntitys.getByOperationKey(
            fixture.store().keyFor(fixture.job())))!;
          receipt.localSongId = 9223372036854775806;
          await fixture.db.iosTransferReceiptEntitys.put(receipt);
          await retainIosImportSongIdentitiesInTransaction(fixture.db,
            [fresh('/overflow-a.wav'), fresh('/overflow-b.wav')]);
        });
        throw Exception('Identity overflow was accepted');
      } on StateError { /* Actual Isar writer rolls the receipt back. */ }
      await fixture.close();
      await fixture.open();
      final receipt = (await fixture.db.iosTransferReceiptEntitys.getByOperationKey(
        fixture.store().keyFor(fixture.job())))!;
      require(receipt.localSongId == 42 && receipt.state == 'committed' &&
          await fixture.db.songEntitys.count() == 2,
        'Overflow refuses atomically and preserves historical proof across reopen');
      final rescanned = fresh(fixture.store().absolutePath(fixture.target));
      final guard = IosTransferScanGuard(fixture.db);
      require(!await fixture.db.writeTxn(() => guard.allowsUpsertInTransaction(rescanned)),
        'Unwitnessed scan cannot recreate deleted completed import metadata');
      await IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() async {
        require(await guard.allowsUpsertInTransaction(rescanned),
          'New scan may index retained canonical public bytes');
        await retainIosImportSongIdentitiesInTransaction(fixture.db, [rescanned]);
        await fixture.db.songEntitys.put(rescanned);
      }));
      require(rescanned.id == 45 &&
          (await fixture.db.songEntitys.get(43))!.title == 'Current edit' &&
          (await fixture.db.songEntitys.get(44))!.filePath == '/new-second.wav' &&
          (await fixture.store().peek(fixture.job(), fixture.target))!.removedAfterCommit,
        'Fresh rescan gets a separate ID without changing historical import deletion: id=${rescanned.id}, original=${(await fixture.store().peek(fixture.job(), fixture.target))!.song?.id}');
      await IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() async {
        require(await guard.allowsUpsertInTransaction(rescanned),
          'Later fresh scans can refresh the separately rescanned row');
      }));
      final entered = Completer<void>(), release = Completer<void>();
      final staleScan = IosLibraryScanEpoch.run(() async {
        entered.complete();
        await release.future;
        return fixture.db.writeTxn(() => guard.allowsUpsertInTransaction(rescanned));
      });
      await entered.future;
      await IosLibraryScanEpoch.withMutation(() async {});
      release.complete();
      require(!await staleScan,
        'Old scan witness remains invalid after a later mutation releases');
    });
    await scenario('scanner-mutation-generation', (fixture) async {
      final entered = Completer<void>(), release = Completer<void>();
      final blocking = fixture.db.writeTxn(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final stale = IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() async {
        IosLibraryScanEpoch.requireCurrent();
        await fixture.db.songEntitys.put(SongEntity()
          ..filePath = '/stale.wav' ..title = 'Stale scan' ..artist = 'Fixture' ..dateAdded = DateTime.utc(2026));
      }));
      final refused = stale.then((_) => false, onError: (_) => true);
      final clear = IosLibraryScanEpoch.withMutation(() => fixture.db.writeTxn(
        () => fixture.db.songEntitys.clear()));
      release.complete();
      await blocking;
      await clear;
      require(await refused && await fixture.db.songEntitys.count() == 0,
        'Actual queued scanner writer cannot repopulate after mutation retirement');
      await IosLibraryScanEpoch.run(() => fixture.db.writeTxn(() async {
        IosLibraryScanEpoch.requireCurrent();
        await fixture.db.songEntitys.put(SongEntity()
          ..filePath = '/fresh.wav' ..title = 'Fresh scan' ..artist = 'Fixture' ..dateAdded = DateTime.utc(2026));
      }));
      require(await fixture.db.songEntitys.count() == 1,
        'Fresh post-mutation scan is admitted in the actual writer');
    });
    await scenario('scanner-serialization', (fixture) async {
      final guard = IosTransferScanGuard(fixture.db);
      final path = fixture.store().absolutePath(fixture.target);
      SongEntity scanned(String path, {int? id}) => SongEntity()
        ..id = id ?? Isar.autoIncrement
        ..filePath = path
        ..title = 'Stale scanned title'
        ..artist = 'Scanned artist';
      final stale = scanned(path);
      require(
        await fixture.db.writeTxn(() => guard.allowsUpsertInTransaction(stale)),
        'Initial scan sees no reservation',
      );
      final entered = Completer<void>(), release = Completer<void>();
      final preparing = fixture.prepare(
        boundary: (stage) async {
          if (stage == 'prepare:beforeCommit') {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }
        },
      );
      await entered.future;
      var scanFinished = false;
      final scanning = fixture.db.writeTxn(() async {
        if (await guard.allowsUpsertInTransaction(stale)) {
          await fixture.db.songEntitys.put(stale);
        }
        scanFinished = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      require(!scanFinished, 'Scanner waits behind actual preparing writer');
      release.complete();
      await preparing;
      await scanning;
      require(
        await fixture.db.songEntitys.count() == 1 &&
            (await fixture.db.songEntitys.get(42))!.title ==
                'Current library title',
        'In-writer reservation check prevents duplicate row and stale overwrite',
      );
      for (final alias in [
        path.toUpperCase(),
        path.replaceFirst('Verified fixture', 'Cafe\u0301'),
        path.replaceFirst('Verified fixture', 'Café'),
        '/private/var/example/Music/Desktop Copies/Another title - ${fixture.job().id.toUpperCase()}-r1.WAV',
      ]) {
        require(
          !await fixture.db.writeTxn(
            () => guard.allowsUpsertInTransaction(scanned(alias)),
          ),
          'ASCII job suffix protects case/Unicode/root aliases without filesystem I/O',
        );
      }
      require(
        !await fixture.db.writeTxn(() => guard.allowsRemovalInTransaction(42)),
        'Scanner deletion cannot remove the prepared source identity',
      );
      require(
        await fixture.db.writeTxn(
          () => guard.allowsUpsertInTransaction(scanned('/other/music.wav')),
        ),
        'Unrelated recordings stay available to the scanner',
      );
      await fixture.publishFixture();
      await fixture.commit();
      require(
        !await fixture.db.writeTxn(
          () => guard.allowsUpsertInTransaction(stale),
        ),
        'Scan captured before commit cannot overwrite newly imported recording',
      );
      require(
        !await fixture.db.writeTxn(() => guard.allowsRemovalInTransaction(42)),
        'Automatic deletion/CUE replacement retains committed import anchor',
      );
      final current = (await fixture.db.songEntitys.get(42))!;
      require(
        await fixture.db.writeTxn(
          () => guard.allowsUpsertInTransaction(current),
        ),
        'Later scan of current canonical recording may refresh metadata',
      );
      require(
        !await fixture.db.writeTxn(
          () => guard.allowsUpsertInTransaction(
            scanned(path.toUpperCase(), id: 42),
          ),
        ),
        'Alias cannot change the canonical committed path',
      );
      await fixture.db.writeTxn(() => fixture.db.songEntitys.delete(42));
      require(
        !await fixture.db.writeTxn(
          () => guard.allowsUpsertInTransaction(current),
        ),
        'Scanner cannot resurrect a deleted completed recording',
      );
    });
    await scenario('retirement-barrier', (fixture) async {
      await fixture.prepare();
      await fixture.store().recordMediaValidation(
        fixture.job(),
        fixture.target,
        Fixture.media,
        isCurrent: () => true,
        validateOwnership: () async {},
      );
      await rejects(
        () => fixture.store().retireReservation(
          fixture.job(),
          fixture.target,
          isCurrent: () => true,
          validateOwnership: () async {},
        ),
        IosTransferImportConflict.retired,
      );
      var checks = 0;
      try {
        await fixture.store().beginRetirement(
          fixture.job(),
          fixture.target,
          isCurrent: () => true,
          validateCleanupAuthority: () async {
            if (++checks == 2) throw StateError('cleanup authority retired');
          },
        );
        throw StateError('Expected late cleanup revocation');
      } on StateError catch (error) {
        require(
          error.message == 'cleanup authority retired',
          'Late guard reached',
        );
      }
      require(
        (await fixture.store().peek(
              fixture.job(),
              fixture.target,
            ))!.receipt.state ==
            'prepared',
        'Late cleanup revocation rolls back retiring',
      );
      await fixture.store().beginRetirement(
        fixture.job(),
        fixture.target,
        isCurrent: () => true,
        validateCleanupAuthority: () async {},
      );
      await fixture.close();
      await fixture.open();
      require(
        (await fixture.store().pendingReservations()).entries.single.retiring,
        'Retiring survives process/database replacement',
      );
      await rejects(() => fixture.prepare(), IosTransferImportConflict.retired);
      await rejects(() => fixture.commit(), IosTransferImportConflict.retired);
      final guard = IosTransferScanGuard(fixture.db);
      require(
        await fixture.db.writeTxn(
              () => fixture.store().isReservedPathInTransaction(
                fixture.store().absolutePath(fixture.target),
              ),
            ) &&
            !await fixture.db.writeTxn(
              () => guard.allowsRemovalInTransaction(42),
            ),
        'Retiring protects both path and Song anchor from scanner writes',
      );
      await fixture.store().retireReservation(
        fixture.job(),
        fixture.target,
        isCurrent: () => true,
        validateOwnership: () async {},
      );
      require(
        (await fixture.store().pendingReservations()).entries.isEmpty &&
            (await fixture.db.songEntitys.get(42))!.sourceType == 'lokal',
        'Retirement finalizes bookkeeping without removing remote Song',
      );
    });
    await scenario('orphan-bookkeeping-barrier', (fixture) async {
      await fixture.prepare();
      final pending =
          (await fixture.store().pendingReservations()).entries.single;
      final document = {
        'permission': 'orphanCleanup',
        'id': fixture.job().id,
        'revision': 1,
        'songID': 42,
        'leaseID': 'a7d96b93-6526-4f1f-a1af-688ffb5c799d',
        'clientID': 'b7d96b93-6526-4f1f-a1af-688ffb5c799d',
        'currentJob': {
          ...fixture.document,
          'phase': 'cancelled',
          'revision': 2,
        },
      };
      final lease = IosTransferOrphanLease.fromJson(document);
      var checks = 0;
      try {
        await fixture.store().retireOrphanReservation(
          pending,
          lease,
          isCurrent: () => true,
          validateBookkeepingAuthority: () async {
            if (++checks == 2) throw StateError('orphan authority revoked');
          },
        );
        throw StateError('Expected late orphan revocation');
      } on StateError catch (error) {
        require(
          error.message == 'orphan authority revoked',
          'Late orphan guard reached',
        );
      }
      require(
        (await fixture.store().peek(
              fixture.job(),
              fixture.target,
            ))!.receipt.state ==
            'prepared',
        'Late orphan guard rolls back the actual Isar transaction',
      );
      final otherIdentity = Map<String, dynamic>.from(
        fixture.document['identity'] as Map,
      )..['sourceID'] = 'another-recording';
      final mismatched = IosTransferOrphanLease.fromJson({
        ...document,
        'currentJob': {
          ...fixture.document,
          'phase': 'cancelled',
          'revision': 2,
          'identity': otherIdentity,
        },
      });
      await rejects(
        () => fixture.store().retireOrphanReservation(
          pending,
          mismatched,
          isCurrent: () => true,
          validateBookkeepingAuthority: () async {},
        ),
        IosTransferImportConflict.receiptMismatch,
      );
      await fixture.commit();
      await rejects(
        () => fixture.store().retireOrphanReservation(
          pending,
          lease,
          isCurrent: () => true,
          validateBookkeepingAuthority: () async {},
        ),
        IosTransferImportConflict.receiptMismatch,
      );
      require(
        (await fixture.store().peek(fixture.job(), fixture.target))!.committed,
        'A stale prepared page cannot retire a subsequently committed receipt',
      );
    });
    await scenario('reservation-keyset-pages', (fixture) async {
      for (var index = 1; index <= 5; index++) {
        fixture.document['id'] =
            '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
        await fixture.prepare();
      }
      final store = fixture.store();
      final first = await store.pendingReservations(limit: 2);
      require(
        first.entries.length == 2 && first.nextId != null,
        'Private recovery returns bounded keyset page',
      );
      await fixture.db.writeTxn(
        () =>
            fixture.db.iosTransferReceiptEntitys.delete(first.entries.first.id),
      );
      fixture.document['id'] = '00000000-0000-4000-8000-000000000006';
      await fixture.prepare();
      final seen = first.entries.map((e) => e.operationKey).toSet();
      int? cursor = first.nextId;
      while (cursor != null) {
        final page = await store.pendingReservations(afterId: cursor, limit: 2);
        for (final entry in page.entries) {
          require(
            seen.add(entry.operationKey),
            'No duplicate reservation after deletion',
          );
        }
        cursor = page.nextId;
      }
      require(seen.length == 6, 'No offset skip after deletion and insertion');
      await rejects(() => store.pendingReservations(limit: 0));
      await rejects(() => store.pendingReservations(limit: 101));
      await rejects(() => store.pendingReservations(afterId: -1));
    });
    await scenario('prepared-deletion', (fixture) async {
      await fixture.prepare();
      await fixture.db.writeTxn(() => fixture.db.songEntitys.delete(42));
      await rejects(
        () => fixture.prepare(),
        IosTransferImportConflict.recordingRemoved,
      );
      await rejects(
        () => fixture.commit(),
        IosTransferImportConflict.recordingRemoved,
      );
      await fixture.store().beginRetirement(
        fixture.job(),
        fixture.target,
        isCurrent: () => true,
        validateCleanupAuthority: () async {},
      );
      await fixture.store().retireReservation(
        fixture.job(),
        fixture.target,
        isCurrent: () => true,
        validateOwnership: () async {},
      );
      require(
        await fixture.db.songEntitys.count() == 0,
        'Prepared deletion is retained',
      );
      require(
        !await fixture.db.writeTxn(
          () => fixture.store().isReservedPathInTransaction(
            fixture.store().absolutePath(fixture.target),
          ),
        ),
        'Retired reservation releases indexing',
      );
    });
    for (final boundary in ['commit:afterSong', 'commit:beforeCommit']) {
      await scenario('rollback-${boundary.split(':').last}', (fixture) async {
        await fixture.prepare();
        await fixture.publishFixture();
        try {
          await fixture.commit(
            boundary: (stage) async {
              if (stage == boundary) throw StateError('induced rollback');
            },
          );
          throw StateError('Expected rollback');
        } on StateError catch (error) {
          require(
            error.message == 'induced rollback',
            'Rollback boundary reached',
          );
        }
        await fixture.close();
        await fixture.open();
        require(
          (await fixture.db.songEntitys.get(42))!.sourceType == 'lokal',
          'Song write rolls back',
        );
        require(
          (await fixture.store().peek(
                fixture.job(),
                fixture.target,
              ))!.receipt.state ==
              'prepared',
          'Receipt write rolls back',
        );
      });
    }
    for (final phase in ['prepare', 'commit']) {
      await scenario('native-revoked-after-$phase-write', (fixture) async {
        var authorized = true;
        Future<void> guard() async {
          if (!authorized) {
            throw const IosTransferImportException(
              IosTransferImportConflict.retired,
            );
          }
        }

        Future<void> boundary(String stage) async {
          if (stage == '$phase:afterSong') authorized = false;
        }

        if (phase == 'commit') await fixture.prepare();
        await rejects(
          () => phase == 'prepare'
              ? fixture.prepare(ownership: guard, boundary: boundary)
              : fixture.commit(ownership: guard, boundary: boundary),
          IosTransferImportConflict.retired,
        );
        final song = await fixture.db.songEntitys.get(42);
        require(
          song?.sourceType == 'lokal',
          'Native revocation rolls back the actual Song writer despite a still-current local epoch',
        );
        final receipt = await fixture.store().peek(
          fixture.job(),
          fixture.target,
        );
        require(
          phase == 'prepare'
              ? receipt == null
              : receipt?.receipt.state == 'prepared',
          'Final native guard cannot leave an acknowledged reservation/completion after retirement',
        );
      });
    }
    await scenario('retired-after-write', (fixture) async {
      await fixture.prepare();
      var current = true;
      await rejects(
        () => fixture.commit(
          current: () => current,
          boundary: (stage) async {
            if (stage == 'commit:afterSong') current = false;
          },
        ),
        IosTransferImportConflict.retired,
      );
      require(
        (await fixture.db.songEntitys.get(42))!.sourceType == 'lokal',
        'Retired transaction is atomic',
      );
    });
    await scenario('writer-barrier', (fixture) async {
      final entered = Completer<void>(), release = Completer<void>();
      final preparing = fixture.prepare(
        ownership: () async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        },
      );
      await entered.future;
      var cleared = false;
      final clearing = fixture.db.writeTxn(() async {
        await fixture.db.songEntitys.clear();
        cleared = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      require(
        !cleared,
        'Clear waits behind the writer that owns the lease guard',
      );
      release.complete();
      await preparing;
      await clearing;
      require(
        await fixture.db.songEntitys.count() == 0,
        'Old preparation cannot reappear after clear',
      );
      await rejects(
        () => fixture.prepare(),
        IosTransferImportConflict.recordingRemoved,
      );
    }, existing: false);
    await scenario('revoked-native-guard', (fixture) async {
      await rejects(
        () => fixture.prepare(
          ownership: () async {
            throw const IosTransferImportException(
              IosTransferImportConflict.retired,
            );
          },
        ),
        IosTransferImportConflict.retired,
      );
      require(
        await fixture.db.songEntitys.count() == 0 &&
            await fixture.db.iosTransferReceiptEntitys.count() == 0,
        'Revoked guard creates no metadata/receipt',
      );
    }, existing: false);
    await scenario('cue', (fixture) async {
      await fixture.db.writeTxn(() async {
        final row = (await fixture.db.songEntitys.get(42))!
          ..startOffsetMs = 500
          ..endOffsetMs = 1500
          ..durationMs = 1000;
        await fixture.db.songEntitys.put(row);
      });
      await fixture.prepare();
      final result = await fixture.commit();
      require(
        result.song!.startOffsetMs == 500 &&
            result.song!.endOffsetMs == 1500 &&
            result.song!.durationMs == 1000,
        'A whole-file header does not replace an existing CUE range',
      );
    });
    await scenario('binding-and-corruption', (fixture) async {
      await fixture.prepare();
      await fixture.db.writeTxn(() async {
        final server = (await fixture.db.networkServerEntitys.get(3))!
          ..username = 'other:guest';
        await fixture.db.networkServerEntitys.put(server);
      });
      await rejects(
        () => fixture.commit(),
        IosTransferImportConflict.pairingChanged,
      );
      await fixture.db.writeTxn(() async {
        final receipt =
            (await fixture.db.iosTransferReceiptEntitys.where().findFirst())!
              ..schemaVersion = 2;
        await fixture.db.iosTransferReceiptEntitys.put(receipt);
      });
      await rejects(
        () => fixture.prepare(),
        IosTransferImportConflict.receiptMismatch,
      );
      require(
        (await fixture.db.iosTransferReceiptEntitys.where().findFirst())!
                .schemaVersion ==
            2,
        'Future receipt is preserved',
      );
    });
    await scenario('wrong-recording-receipt', (fixture) async {
      await fixture.prepare();
      await fixture.db.writeTxn(() async {
        final receipt =
            (await fixture.db.iosTransferReceiptEntitys.where().findFirst())!
              ..localSongId = 99;
        await fixture.db.iosTransferReceiptEntitys.put(receipt);
      });
      await rejects(
        () => fixture.prepare(),
        IosTransferImportConflict.receiptMismatch,
      );
      await rejects(
        () => fixture.commit(),
        IosTransferImportConflict.receiptMismatch,
      );
      require(
        (await fixture.db.songEntitys.get(42))!.sourceType == 'lokal',
        'A mismatched receipt never switches the selected recording',
      );
      require(
        (await fixture.db.iosTransferReceiptEntitys.where().findFirst())!
                .localSongId ==
            99,
        'Inconsistent receipt is retained for repair',
      );
    });
    await scenario('destination-conflict', (fixture) async {
      final target = File(fixture.store().absolutePath(fixture.target));
      await target.parent.create(recursive: true);
      await target.writeAsString('preserve user file');
      await fixture.db.writeTxn(
        () => fixture.db.songEntitys.put(
          SongEntity()
            ..id = 99
            ..filePath = target.path
            ..title = 'User recording'
            ..artist = 'User'
            ..dateAdded = DateTime.utc(2020),
        ),
      );
      await rejects(
        () => fixture.prepare(),
        IosTransferImportConflict.destinationConflict,
      );
      require(
        await target.readAsString() == 'preserve user file' &&
            await fixture.db.iosTransferReceiptEntitys.count() == 0,
        'Conflict does not overwrite a user recording',
      );
    });
    await scenario('traversal', (fixture) async {
      await rejects(
        () => fixture.store().prepare(
          fixture.job(),
          const IosTransferLibraryTarget('../outside.wav'),
          isCurrent: () => true,
          validateOwnership: () async {},
        ),
      );
      require(
        await fixture.db.iosTransferReceiptEntitys.count() == 0,
        'Unsafe target cannot persist intent',
      );
    });
    for (final operation in ['retiring', 'retired', 'orphan']) {
      for (final edge in ['beforeCommit', 'afterCommit']) {
        await scenario('process-$operation-$edge', (fixture) async {
          await fixture.prepare();
          if (operation == 'retired') {
            await fixture.store().beginRetirement(
              fixture.job(),
              fixture.target,
              isCurrent: () => true,
              validateCleanupAuthority: () async {},
            );
          }
          await fixture.close();
          final result = await child(fixture, operation, '$operation:$edge');
          require(
            result.exitCode == 95,
            'Retirement child exits at exact commit edge',
          );
          await fixture.open();
          final receipt = (await fixture.store().peek(
            fixture.job(),
            fixture.target,
          ))!.receipt;
          final expected = edge == 'afterCommit'
              ? (operation == 'orphan' ? 'retired' : operation)
              : (operation == 'retired' ? 'retiring' : 'prepared');
          require(
            receipt.state == expected &&
                (await fixture.db.songEntitys.get(42))!.sourceType == 'lokal',
            'Retirement process exit preserves exact transaction and Song',
          );
        });
      }
    }
    for (final boundary in [
      'prepare:afterSong',
      'prepare:beforeCommit',
      'prepare:afterCommit',
      'commit:afterSong',
      'commit:beforeCommit',
      'commit:afterCommit',
    ]) {
      await scenario('process-${boundary.replaceAll(':', '-')}', (
        fixture,
      ) async {
        final committing = boundary.startsWith('commit:');
        if (committing) {
          await fixture.prepare();
          await fixture.publishFixture();
        }
        await fixture.close();
        final result = await child(
          fixture,
          committing ? 'commit' : 'prepare',
          boundary,
        );
        require(
          result.exitCode == 95,
          'Child exited at exact transaction boundary',
        );
        await fixture.open();
        final afterCommit = boundary.endsWith('afterCommit');
        final count = await fixture.db.songEntitys.count();
        require(
          count == (committing || afterCommit ? 1 : 0),
          'Process exit leaves whole old/new identity',
        );
        final receipt = await fixture.store().peek(
          fixture.job(),
          fixture.target,
        );
        if (committing) {
          require(
            receipt!.committed == afterCommit &&
                (receipt.song!.sourceType == null) == afterCommit,
            'Song/receipt never split across process exit',
          );
        } else {
          require(
            (receipt != null) == afterCommit,
            'Reservation/row commit together',
          );
        }
      }, existing: false);
    }
    await scenario('six-process-reservation', (fixture) async {
      await fixture.close();
      final results = await Future.wait([
        for (var i = 0; i < 6; i++) child(fixture, 'prepare'),
      ]);
      require(
        results.every((result) => result.exitCode == 0),
        'Concurrent child writers succeed',
      );
      await fixture.open();
      require(
        await fixture.db.songEntitys.count() == 1 &&
            await fixture.db.iosTransferReceiptEntitys.count() == 1,
        'Six processes share one reserved identity and receipt',
      );
    }, existing: false);
    stdout.writeln(
      options['--scenario'] != null ? 'Actual Isar scenario passed: ${options['--scenario']}' :
      'Actual Isar import contracts passed: eight-collection schema preservation, private sync isolation, identity/metadata/history, deletion, scanner writer/alias/history guards, writer barrier, atomic rollback, old private-schema/media upgrade, bounded reservation keyset pages, retiring/retired/orphan guards, fourteen receipt/media/retirement commit-exit boundaries and six process reservations. Native RPC/media/app integration remain separate.',
    );
  } catch (error, stack) {
    stderr.writeln('Isar import contracts failed at $stage: $error\n$stack');
    rethrow;
  } finally {
    await root.delete(recursive: true);
  }
}
