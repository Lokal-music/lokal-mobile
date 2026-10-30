import 'package:flick/data/database.dart';
import 'package:flick/data/entities/ios_transfer_receipt_entity.dart';
import 'package:flick/data/entities/ios_song_identity_entity.dart';
import 'package:flutter_test/flutter_test.dart';

/// Query the actual product database, not an isolated substitute. The native
/// importer remains disabled; opening its private schema must not create songs.
Future<Map<String, Object>> probeIosImportSchema() async {
  expect(Database.isInitialized, true);
  final receipts = await Database.instance.iosTransferReceiptEntitys.count();
  expect(receipts, 0);
  final counter = await Database.instance.iosSongIdentityEntitys.get(1);
  expect(await Database.instance.iosSongIdentityEntitys.count(), 1);
  expect(counter?.schemaVersion, 1);
  expect(counter?.lastAllocated, greaterThanOrEqualTo(0));
  return {
    'scope': 'Actual iPhone application Isar private collection open; no power-loss or completed-import acceptance',
    'private_receipts': receipts,
    'recording_identity_floor': counter!.lastAllocated,
    'durability_requested': 'full',
    'product_import_enabled': false,
  };
}
