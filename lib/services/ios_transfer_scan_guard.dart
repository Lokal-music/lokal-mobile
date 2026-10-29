import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

import '../data/entities/ios_transfer_receipt_entity.dart';
import '../data/entities/song_entity.dart';

/// Match the native ASCII operation suffix rather than the display title.
/// This also handles APFS case/Unicode spelling and /var parent aliases without
/// filesystem calls inside the Isar writer. A matching UUID in any Desktop
/// Copies directory is conservatively protected until its reservation settles.
String? iosTransferOperationKeyForPath(String path) {
  if (!p.posix.isAbsolute(path) || path.contains('\u0000')) return null;
  final normalized = p.posix.normalize(path);
  if (p.posix.basename(p.posix.dirname(normalized)).toLowerCase() !=
      'desktop copies') {
    return null;
  }
  final match = RegExp(
    r' - ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})-r([1-9][0-9]*)\.[a-z0-9]{1,8}$',
    caseSensitive: false,
  ).firstMatch(p.posix.basename(normalized));
  if (match == null) return null;
  final revision = int.tryParse(match[2]!);
  if (revision == null || revision < 1) return null;
  return '${match[1]!.toLowerCase()}:$revision';
}

/// Scanner-only policy. Every call runs inside the caller's Isar write txn;
/// explicit user mutations and the import writer do not use this policy.
class IosTransferScanGuard {
  IosTransferScanGuard(this.isar);
  final Isar isar;

  Future<bool> allowsUpsertInTransaction(SongEntity incoming) async {
    final key = iosTransferOperationKeyForPath(incoming.filePath);
    if (key == null) return true;
    final receipt = await isar.iosTransferReceiptEntitys.getByOperationKey(key);
    if (receipt == null) return true;
    if (receipt.schemaVersion != 1 ||
        receipt.operationKey != '${receipt.jobId}:${receipt.revision}' ||
        receipt.localSongId < 1) {
      return false;
    }
    if (receipt.state == 'retired') return true;
    if (receipt.state != 'committed') return false;
    // A scan started before import completion has no current local ID. It must
    // not create a duplicate via an alias or overwrite the newly committed row.
    if (incoming.id != receipt.localSongId) return false;
    final current = await isar.songEntitys.get(receipt.localSongId);
    return current != null && current.filePath == incoming.filePath;
  }

  Future<bool> allowsRemovalInTransaction(int songId) async {
    final receipts = await isar.iosTransferReceiptEntitys
        .where()
        .localSongIdEqualTo(songId)
        .findAll();
    // Keep the import anchor until explicit removal has crossed the native
    // cancellation/writer barrier. In particular a CUE rewrite must not delete
    // it before its replacement rows have an accepted identity mapping.
    return receipts.every(
      (receipt) => receipt.schemaVersion == 1 && receipt.state == 'retired',
    );
  }
}
