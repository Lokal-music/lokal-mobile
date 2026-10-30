import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

import '../data/entities/ios_transfer_receipt_entity.dart';
import '../data/entities/song_entity.dart';
import 'ios_library_scan_epoch.dart';
import 'ios_transfer_scan_guard.dart';
import 'ios_transfer_song_identity.dart';

/// Metadata-only range replacement. Caller owns Isar's writer; no native file
/// authority is granted and the original import receipt stays immutable.
class IosTransferCueMapping {
  IosTransferCueMapping(this.isar);
  final Isar isar;

  Future<bool> replaceInTransaction(
    String path,
    List<SongEntity> tracks, {
    required List<SongEntity> expected,
  }) async {
    IosLibraryScanEpoch.requireCurrent();
    final key = iosTransferOperationKeyForPath(path);
    if (key == null) return false;
    final receipt = await isar.iosTransferReceiptEntitys.getByOperationKey(key);
    if (receipt == null) return false;
    if (receipt.schemaVersion != 1 ||
        receipt.localSongId < 1 ||
        receipt.operationKey != '${receipt.jobId}:${receipt.revision}' ||
        !{'committed', 'retired'}.contains(receipt.state) ||
        !path.endsWith('/${receipt.relativePath}') ||
        p.posix.normalize(path) != path ||
        tracks.isEmpty ||
        tracks.length > 1000 ||
        expected.length > 1001) {
      throw StateError(
        'This import must finish before its CUE tracks can change.',
      );
    }
    final current = await isar.songEntitys
        .where()
        .filePathEqualToAnyStartOffsetMs(path)
        .findAll();
    final snapshot = {for (final row in expected) row.id: row};
    if (snapshot.length != expected.length ||
        current.length != expected.length ||
        current.any((row) => !_sameRecording(row, snapshot[row.id]))) {
      throw StateError('The recording changed. Start a new scan.');
    }
    final ordered = List<SongEntity>.of(tracks);
    for (final row in ordered) {
      final start = row.startOffsetMs, end = row.endOffsetMs;
      if (row.filePath != path ||
          start == null ||
          start < 0 ||
          start > 31536000000 ||
          (end != null && (end <= start || end > 31536000000)) ||
          (row.id != Isar.autoIncrement && !snapshot.containsKey(row.id))) {
        throw StateError('Invalid CUE recording identity or range.');
      }
    }
    ordered.sort((a, b) => a.startOffsetMs!.compareTo(b.startOffsetMs!));
    for (var i = 1; i < ordered.length; i++) {
      if (ordered[i - 1].startOffsetMs == ordered[i].startOffsetMs ||
          ordered[i - 1].endOffsetMs == null ||
          ordered[i - 1].endOffsetMs! > ordered[i].startOffsetMs!) {
        throw StateError('CUE recording ranges overlap.');
      }
    }
    final ranges = {
      for (final row in current)
        if (row.startOffsetMs != null) row.startOffsetMs!: row,
    };
    final raw = current.where((row) => row.startOffsetMs == null).firstOrNull;
    final retained = <int>{};
    for (var i = 0; i < ordered.length; i++) {
      final row = ordered[i];
      final previous = ranges[row.startOffsetMs] ?? (i == 0 ? raw : null);
      if (previous == null) {
        row.id = Isar.autoIncrement;
      } else {
        if (!retained.add(previous.id)) {
          throw StateError('A CUE recording identity was selected twice.');
        }
        row
          ..id = previous.id
          ..dateAdded = previous.dateAdded
          ..remoteId = previous.remoteId
          ..remoteServerId = previous.remoteServerId
          ..sourceType = previous.sourceType
          ..hasLocalEdits = previous.hasLocalEdits;
        if (previous.hasLocalEdits) {
          row
            ..title = previous.title
            ..artist = previous.artist
            ..album = previous.album
            ..albumArtist = previous.albumArtist
            ..genre = previous.genre
            ..year = previous.year
            ..trackNumber = previous.trackNumber
            ..discNumber = previous.discNumber;
        }
      }
    }
    await retainIosImportSongIdentitiesInTransaction(isar, ordered);
    IosLibraryScanEpoch.requireCurrent();
    await isar.songEntitys.putAll(ordered);
    final selected = ordered.map((row) => row.id).toSet();
    final removed = current
        .where((row) => !selected.contains(row.id))
        .map((row) => row.id)
        .toList();
    if (removed.isNotEmpty) await isar.songEntitys.deleteAll(removed);
    return true;
  }

  bool _sameRecording(SongEntity row, SongEntity? expected) =>
      expected != null &&
      row.filePath == expected.filePath &&
      row.startOffsetMs == expected.startOffsetMs &&
      row.endOffsetMs == expected.endOffsetMs &&
      row.dateAdded.isAtSameMomentAs(expected.dateAdded) &&
      row.fileSize == expected.fileSize &&
      row.lastModified?.microsecondsSinceEpoch ==
          expected.lastModified?.microsecondsSinceEpoch &&
      row.sourceType == expected.sourceType &&
      row.remoteId == expected.remoteId &&
      row.remoteServerId == expected.remoteServerId;
}
