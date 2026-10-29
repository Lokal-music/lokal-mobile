import 'dart:io';

import 'package:flick/data/entities/ios_transfer_receipt_entity.dart';
import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';

/// Exercise actual iOS repository entry points and the locked native Isar core
/// in a disposable private database. No product songs, files or pairing change.
Future<Map<String, Object>> probeIosImportScanGuard() async {
  final root = await Directory.systemTemp.createTemp('lokal-import-scan-');
  Isar? opened;
  try {
    final db = await Isar.open(
      [SongEntitySchema, IosTransferReceiptEntitySchema],
      directory: root.path,
      name: 'ios_import_scan_probe',
      relaxedDurability: false,
    );
    opened = db;
    final repository = SongRepository(isar: db);
    const jobId = '62dcde21-562f-4417-b660-cd1385ea44ca';
    const relative = 'Desktop Copies/Probe - $jobId-r1.wav';
    final target = '${root.path}/Music/$relative';
    final receipt = IosTransferReceiptEntity()
      ..operationKey = '$jobId:1'
      ..jobId = jobId
      ..revision = 1
      ..localSongId = 42
      ..serverId = 3
      ..desktopId = 'isolated-probe'
      ..pairingId = '72dcde21-562f-4417-b660-cd1385ea44ca'
      ..origin = 'http://127.0.0.1:5443'
      ..sourceId = 'fixture'
      ..relativePath = relative
      ..bytes = 12
      ..sha256 = 'a' * 64
      ..preparedAt = DateTime.utc(2026, 10, 29);
    SongEntity scan(String path, {int id = Isar.autoIncrement}) => SongEntity()
      ..id = id
      ..filePath = path
      ..title = 'Stale scan'
      ..dateAdded = DateTime.utc(2026, 10, 29)
      ..artist = 'Probe';
    await db.writeTxn(() async {
      await db.songEntitys.put(scan('lokal://3/fixture', id: 42));
      await db.iosTransferReceiptEntitys.put(receipt);
    });
    final stale = scan(target);
    final ordinary = scan('${root.path}/Ordinary.wav');
    await repository.upsertScannedSongs([stale, ordinary]);
    expect(await db.songEntitys.count(), 2);
    expect(stale.id, Isar.autoIncrement);
    expect(ordinary.id, greaterThan(0));
    await repository.deleteScannedSongsByIds([42]);
    await repository.deleteScannedSongsByPath(['lokal://3/fixture']);
    expect(await db.songEntitys.get(42), isNotNull);

    // Ordinary user entry points must retain their explicit mutation semantics.
    await repository.upsertSong(
      scan('lokal://3/fixture', id: 42)..title = 'User edit',
    );
    expect((await db.songEntitys.get(42))!.title, 'User edit');
    await db.writeTxn(() async {
      final row = (await db.songEntitys.get(42))!..filePath = target;
      receipt
        ..state = 'committed'
        ..committedAt = DateTime.utc(2026, 10, 29);
      await db.songEntitys.put(row);
      await db.iosTransferReceiptEntitys.put(receipt);
    });
    await repository.upsertScannedSong(stale);
    await repository.upsertScannedSong(scan(target.toUpperCase(), id: 42));
    expect((await db.songEntitys.get(42))!.title, 'User edit');
    expect((await db.songEntitys.get(42))!.filePath, target);
    final current = (await db.songEntitys.get(42))!..title = 'Fresh scan';
    await repository.upsertScannedSong(current);
    expect((await db.songEntitys.get(42))!.title, 'Fresh scan');
    await repository.deleteScannedSongsByIds([42]);
    expect(await db.songEntitys.get(42), isNotNull);
    await repository.deleteSong(42);
    await repository.upsertScannedSong(stale);
    expect(await db.songEntitys.get(42), isNull);
    expect(await db.songEntitys.count(), 1);
    return {
      'scope': 'Actual iOS scanner repository and private native Isar fixture; no file publication, media import or CUE conversion acceptance',
      'prepared_copy_and_source_id_protected': true,
      'stale_scan_and_alias_do_not_replace_commit': true,
      'fresh_canonical_scan_allowed': true,
      'explicit_user_mutations_retained': true,
      'completed_deletion_not_resurrected': true,
      'real_user_library_touched': false,
    };
  } finally {
    if (opened != null) await opened.close(deleteFromDisk: true);
    if (await root.exists()) await root.delete(recursive: true);
  }
}
