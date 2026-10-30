import 'dart:math' as math;

import 'package:isar_community/isar.dart';

import '../data/entities/ios_transfer_receipt_entity.dart';
import '../data/entities/ios_song_identity_entity.dart';
import '../data/entities/song_entity.dart';

/// The private durable floor and receipt IDs outlive the Songs collection,
/// whose auto-increment resets on clear and on reopening an empty collection.
/// Call inside the same
/// Isar writer as put/putAll. Ordinary new rows must never take a historical
/// import's ID, and stale explicit IDs cannot recreate a deleted recording.
/// An empty batch advances the durable floor before receipt/history pruning.
Future<void> retainIosImportSongIdentitiesInTransaction(
  Isar isar,
  List<SongEntity> rows,
) async {
  final state = await isar.iosSongIdentityEntitys.get(1);
  final stateCount = await isar.iosSongIdentityEntitys.count();
  if (stateCount > 1 ||
      (state == null && stateCount != 0) ||
      (state != null &&
          (state.schemaVersion != 1 ||
              state.lastAllocated < 0 ||
              state.lastAllocated >= 9223372036854775807))) {
    throw StateError(
      'The iPhone recording identity counter needs a compatible app.',
    );
  }
  final history = await isar.iosTransferReceiptEntitys
      .where(sort: Sort.desc)
      .anyLocalSongId()
      .findFirst();
  final historical = history?.localSongId;
  if (historical != null &&
      (historical < 1 || historical >= 9223372036854775807)) {
    throw StateError('The iPhone import identity history cannot be allocated.');
  }
  // IDs are primary keys rather than stored scalar properties. Read the
  // descending primary-key index; scalar max(idProperty) is not reliable.
  final latest = await isar.songEntitys
      .where(sort: Sort.desc)
      .anyId()
      .findFirst();
  final known = math.max(
    state?.lastAllocated ?? 0,
    math.max(historical ?? 0, latest?.id ?? 0),
  );
  var next = known;
  final explicit = <int>{};
  for (final row in rows) {
    if (row.id == Isar.autoIncrement) continue;
    if (row.id < 1 || row.id >= 9223372036854775807 || !explicit.add(row.id)) {
      throw StateError('Invalid or repeated iPhone recording identity.');
    }
    next = math.max(next, row.id);
    final current = await isar.songEntitys.get(row.id);
    if (current == null && row.id <= known) {
      throw StateError('A retired recording identity cannot be recreated.');
    }
  }
  final fresh = rows.where((row) => row.id == Isar.autoIncrement).toList();
  if (next > 9223372036854775806 - fresh.length) {
    throw StateError('The iPhone recording identity space is exhausted.');
  }
  for (final row in fresh) {
    next++;
    if (await isar.songEntitys.get(next) != null) {
      throw StateError(
        'The new iPhone recording identity is already occupied.',
      );
    }
    row.id = next;
  }
  if (state == null || state.lastAllocated != next) {
    await isar.iosSongIdentityEntitys.put(
      (state ?? IosSongIdentityEntity())..lastAllocated = next,
    );
  }
}
