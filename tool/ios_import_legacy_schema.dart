// Frozen pre-media schema creates an actual older native Isar file in a child
// process. The current reader must add the nullable field without losing data.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:isar_community/isar.dart';

import '../test/fixtures/ios_receipt_v1/ios_transfer_receipt_entity.dart';

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var index = 0; index < args.length; index += 2) {
    options[args[index]] = args[index + 1];
  }
  Isar.initializeIsarCore(
    libraries: {Abi.current(): options['--isar-library']!},
  );
  final directory = options['--directory']!;
  final job =
      jsonDecode(await File('$directory/job.json').readAsString()) as Map;
  final identity = job['identity'] as Map;
  final db = await Isar.open(
    [IosTransferReceiptEntitySchema],
    directory: directory,
    name: 'ios_import_contracts',
    relaxedDurability: false,
  );
  try {
    await db.writeTxn(
      () => db.iosTransferReceiptEntitys.put(
        IosTransferReceiptEntity()
          ..id = 7
          ..operationKey = '${job['id']}:1'
          ..jobId = job['id'] as String
          ..revision = 1
          ..localSongId = 42
          ..serverId = 3
          ..desktopId = identity['desktopID'] as String
          ..desktopUserId = identity['desktopUserID'] as String?
          ..pairingId = identity['pairingID'] as String
          ..origin = identity['origin'] as String
          ..sourceId = identity['sourceID'] as String
          ..relativePath =
              'Desktop Copies/Verified fixture - ${job['id']}-r1.wav'
          ..bytes = job['receivedBytes'] as int
          ..sha256 = job['receivedSHA256'] as String
          ..preparedAt = DateTime.utc(2020),
      ),
    );
  } finally {
    await db.close();
  }
}
