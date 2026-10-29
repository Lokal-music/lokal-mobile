import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

import '../data/entities/ios_transfer_receipt_entity.dart';
import '../data/entities/network_server_entity.dart';
import '../data/entities/song_entity.dart';
import '../models/ios_transfer_import.dart';
import '../models/ios_transfer_models.dart';

enum IosTransferImportConflict {
  pairingChanged,
  recordingRemoved,
  destinationConflict,
  receiptMismatch,
  retired,
}

class IosTransferImportException implements Exception {
  const IosTransferImportException(this.reason);
  final IosTransferImportConflict reason;
  @override
  String toString() => 'iPhone import ${reason.name}.';
}

class IosTransferImportResult {
  const IosTransferImportResult(this.receipt, this.song);
  final IosTransferReceiptEntity receipt;
  final SongEntity? song;
  bool get committed => receipt.state == 'committed';
  // A previously committed receipt remains historical proof after deletion.
  bool get removedAfterCommit => committed && song == null;
}

/// One app-isolate library writer. Native callbacks never open this database.
/// Preparation reserves identity before publication; song and completed receipt
/// commit in one actual Isar transaction. The app adapter/schema are not enabled
/// by constructing this isolated store.
class IosTransferImportStore {
  IosTransferImportStore(
    this.isar, {
    required String musicRoot,
    DateTime Function()? now,
    this.testingBoundary,
  }) : musicRoot = p.normalize(musicRoot),
       _now = now ?? DateTime.now {
    if (!p.isAbsolute(musicRoot) || musicRoot.contains('\u0000')) {
      throw const FormatException('Invalid iPhone library root.');
    }
  }

  final Isar isar;
  final String musicRoot;
  final DateTime Function() _now;
  final Future<void> Function(String stage)? testingBoundary;

  String keyFor(IosTransferJob job) => '${job.id}:${job.revision}';
  Never _fail(IosTransferImportConflict reason) =>
      throw IosTransferImportException(reason);
  void _current(bool Function() check) {
    if (!check()) _fail(IosTransferImportConflict.retired);
  }

  Future<void> _boundary(String stage) async {
    await testingBoundary?.call(stage);
  }

  void _validateJob(IosTransferJob job, IosTransferLibraryTarget target) {
    job.intent.validate(submission: true);
    final localId = job.intent.identity.localSongId;
    if (localId != null) {
      final parsed = int.tryParse(localId);
      if (parsed == null || parsed < 1 || parsed.toString() != localId) {
        _fail(IosTransferImportConflict.receiptMismatch);
      }
    }
    if (job.direction != 'download' ||
        job.receivedBytes == null ||
        job.receivedSha256 == null ||
        !{
          IosTransferPhase.staged,
          IosTransferPhase.validating,
          IosTransferPhase.importing,
          IosTransferPhase.complete,
        }.contains(job.phase)) {
      _fail(IosTransferImportConflict.receiptMismatch);
    }
    target.validateFor(job);
  }

  void _matches(
    IosTransferReceiptEntity receipt,
    IosTransferJob job,
    IosTransferLibraryTarget target,
  ) {
    final identity = job.intent.identity;
    if (receipt.schemaVersion != 1 ||
        !{'prepared', 'committed', 'retired'}.contains(receipt.state) ||
        receipt.operationKey != keyFor(job) ||
        receipt.jobId != job.id ||
        receipt.revision != job.revision ||
        receipt.localSongId < 1 ||
        (identity.localSongId != null &&
            receipt.localSongId.toString() != identity.localSongId) ||
        receipt.serverId != identity.localServerId ||
        receipt.desktopId != identity.scope.desktopId ||
        receipt.desktopUserId != identity.desktopUserId ||
        receipt.pairingId != identity.scope.pairingId ||
        receipt.origin != identity.scope.origin ||
        receipt.sourceId != identity.sourceId ||
        receipt.relativePath != target.relativePath ||
        receipt.bytes != job.receivedBytes ||
        receipt.sha256 != job.receivedSha256 ||
        (receipt.state == 'committed') != (receipt.committedAt != null)) {
      _fail(IosTransferImportConflict.receiptMismatch);
    }
  }

  Future<void> _server(IosTransferJob job) async {
    final identity = job.intent.identity;
    final server = await isar.networkServerEntitys.get(identity.localServerId!);
    final origin = server == null ? null : Uri.tryParse(server.baseUrl);
    if (server == null ||
        server.protocol != 'lokal' ||
        origin == null ||
        !{'http', 'https'}.contains(origin.scheme) ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/') ||
        origin.origin != Uri.parse(identity.scope.origin).origin ||
        server.username !=
            '${identity.scope.desktopId}:${identity.desktopUserId ?? 'guest'}') {
      _fail(IosTransferImportConflict.pairingChanged);
    }
  }

  void _binding(SongEntity song, IosTransferJob job) {
    if (song.remoteServerId != job.intent.identity.localServerId ||
        song.remoteId != job.intent.identity.sourceId) {
      _fail(IosTransferImportConflict.pairingChanged);
    }
  }

  String absolutePath(IosTransferLibraryTarget target) =>
      p.joinAll([musicRoot, ...target.relativePath.split('/')]);

  /// Read-only recovery never creates a replacement for a deleted recording.
  Future<IosTransferImportResult?> peek(
    IosTransferJob job,
    IosTransferLibraryTarget target,
  ) async {
    _validateJob(job, target);
    return isar.txn(() async {
      final receipt = await isar.iosTransferReceiptEntitys.getByOperationKey(
        keyFor(job),
      );
      if (receipt == null) return null;
      _matches(receipt, job, target);
      return IosTransferImportResult(
        receipt,
        await isar.songEntitys.get(receipt.localSongId),
      );
    });
  }

  Future<IosTransferImportResult> prepare(
    IosTransferJob job,
    IosTransferLibraryTarget target, {
    required bool Function() isCurrent,
    required Future<void> Function() validateOwnership,
  }) async {
    _validateJob(job, target);
    if (!{
      IosTransferPhase.validating,
      IosTransferPhase.importing,
    }.contains(job.phase)) {
      _fail(IosTransferImportConflict.retired);
    }
    final result = await isar.writeTxn(() async {
      _current(isCurrent);
      final previous = await isar.iosTransferReceiptEntitys.getByOperationKey(
        keyFor(job),
      );
      if (previous != null) {
        _matches(previous, job, target);
        if (previous.state == 'retired') {
          _fail(IosTransferImportConflict.retired);
        }
        final song = await isar.songEntitys.get(previous.localSongId);
        _current(isCurrent);
        if (song == null && previous.state != 'committed') {
          _fail(IosTransferImportConflict.recordingRemoved);
        }
        return IosTransferImportResult(previous, song);
      }
      await _server(job);
      _current(isCurrent);
      final identity = job.intent.identity;
      SongEntity? song;
      if (identity.localSongId != null) {
        final id = int.tryParse(identity.localSongId!);
        if (id == null || id < 1 || id.toString() != identity.localSongId) {
          _fail(IosTransferImportConflict.receiptMismatch);
        }
        song = await isar.songEntitys.get(id);
        if (song == null) _fail(IosTransferImportConflict.recordingRemoved);
      } else {
        final matching = await isar.songEntitys
            .where()
            .remoteIdEqualTo(identity.sourceId)
            .filter()
            .remoteServerIdEqualTo(identity.localServerId)
            .limit(2)
            .findAll();
        if (matching.length > 1) {
          _fail(IosTransferImportConflict.destinationConflict);
        }
        if (matching.isNotEmpty) song = matching.single;
      }
      _current(isCurrent);
      if (song != null) {
        _binding(song, job);
        if (song.sourceType != 'lokal') {
          _fail(IosTransferImportConflict.destinationConflict);
        }
      }
      final slot = await isar.songEntitys.getByFilePathStartOffsetMs(
        absolutePath(target),
        song?.startOffsetMs,
      );
      if (slot != null && slot.id != song?.id) {
        _fail(IosTransferImportConflict.destinationConflict);
      }
      // This native lease check runs while holding Isar's writer. A clear or
      // unpair barrier revokes old leases before taking that same writer, so a
      // delayed old engine cannot reserve a new row after the barrier commits.
      await validateOwnership();
      _current(isCurrent);
      if (song == null) {
        final metadata = job.intent.metadata;
        song = SongEntity()
          ..filePath =
              'lokal://${identity.localServerId}/${Uri.encodeComponent(identity.sourceId)}'
          ..sourceType = 'lokal'
          ..remoteId = identity.sourceId
          ..remoteServerId = identity.localServerId
          ..title = metadata.title
          ..artist = metadata.artist
          ..album = metadata.album
          ..albumArtist = metadata.albumArtist
          ..genre = metadata.genre
          ..durationMs = metadata.durationMs
          ..trackNumber = metadata.trackNumber
          ..discNumber = metadata.discNumber
          ..year = metadata.year
          ..fileType = metadata.fileExtension
          ..dateAdded = _now();
        await isar.songEntitys.put(song);
      }
      await _boundary('prepare:afterSong');
      _current(isCurrent);
      final receipt = IosTransferReceiptEntity()
        ..operationKey = keyFor(job)
        ..jobId = job.id
        ..revision = job.revision
        ..localSongId = song.id
        ..serverId = identity.localServerId!
        ..desktopId = identity.scope.desktopId
        ..desktopUserId = identity.desktopUserId
        ..pairingId = identity.scope.pairingId!
        ..origin = identity.scope.origin
        ..sourceId = identity.sourceId
        ..relativePath = target.relativePath
        ..bytes = job.receivedBytes!
        ..sha256 = job.receivedSha256!
        ..preparedAt = _now();
      await isar.iosTransferReceiptEntitys.put(receipt);
      await _boundary('prepare:beforeCommit');
      _current(isCurrent);
      return IosTransferImportResult(receipt, song);
    });
    await _boundary('prepare:afterCommit');
    return result;
  }

  Future<IosTransferImportResult> commit(
    IosTransferJob job,
    IosTransferLibraryReceipt copy,
    IosTransferMediaInfo media, {
    required bool Function() isCurrent,
    required Future<void> Function() validateOwnership,
  }) async {
    _validateJob(job, copy);
    if (job.phase != IosTransferPhase.importing) {
      _fail(IosTransferImportConflict.retired);
    }
    final result = await isar.writeTxn(() async {
      _current(isCurrent);
      final receipt = await isar.iosTransferReceiptEntitys.getByOperationKey(
        keyFor(job),
      );
      if (receipt == null) _fail(IosTransferImportConflict.receiptMismatch);
      _matches(receipt, job, copy);
      if (receipt.state == 'retired') _fail(IosTransferImportConflict.retired);
      final song = await isar.songEntitys.get(receipt.localSongId);
      if (receipt.state == 'committed') {
        return IosTransferImportResult(receipt, song);
      }
      if (song == null) _fail(IosTransferImportConflict.recordingRemoved);
      await _server(job);
      _binding(song, job);
      media.validate();
      _current(isCurrent);
      if (song.sourceType != 'lokal') {
        _fail(IosTransferImportConflict.destinationConflict);
      }
      final path = absolutePath(copy);
      final slot = await isar.songEntitys.getByFilePathStartOffsetMs(
        path,
        song.startOffsetMs,
      );
      if (slot != null && slot.id != song.id) {
        _fail(IosTransferImportConflict.destinationConflict);
      }
      await validateOwnership();
      _current(isCurrent);
      song
        ..filePath = path
        ..folderUri = musicRoot
        ..relativeFolderPath = 'Desktop Copies'
        ..mediaStoreUri = null
        ..sourceType = null
        ..fileSize = copy.bytes
        ..fileType =
            media.codec ?? job.intent.metadata.fileExtension.toUpperCase()
        ..sampleRate = media.sampleRate
        ..bitDepth = media.bitDepth
        ..bitrate = media.bitrate
        ..channels = media.channels
        ..metadataComplete = true
        ..lastModified = _now();
      // Existing CUE ranges and current descriptive/user metadata retain their identity.
      if (song.startOffsetMs == null) {
        song.durationMs = media.durationMs ?? song.durationMs;
      }
      await isar.songEntitys.put(song);
      await _boundary('commit:afterSong');
      _current(isCurrent);
      receipt
        ..state = 'committed'
        ..committedAt = _now();
      await isar.iosTransferReceiptEntitys.put(receipt);
      await _boundary('commit:beforeCommit');
      _current(isCurrent);
      return IosTransferImportResult(receipt, song);
    });
    await _boundary('commit:afterCommit');
    return result;
  }

  /// The scanner must call this inside its write transaction before indexing
  /// an owned target, rather than caching the answer before file enumeration.
  Future<bool> isReservedPathInTransaction(String path) async {
    if (!p.isWithin(musicRoot, path)) return false;
    final relative = p
        .relative(path, from: musicRoot)
        .split(p.separator)
        .join('/');
    if (!relative.startsWith('Desktop Copies/')) return false;
    return await isar.iosTransferReceiptEntitys
            .where()
            .relativePathEqualTo(relative)
            .filter()
            .stateEqualTo('prepared')
            .findFirst() !=
        null;
  }

  /// Call after native cancellation/owned-file cleanup has drained. A committed
  /// receipt remains historical proof; this never removes or recreates a song.
  Future<IosTransferImportResult?> retireReservation(
    IosTransferJob job,
    IosTransferLibraryTarget target, {
    required bool Function() isCurrent,
    required Future<void> Function() validateOwnership,
  }) async {
    _validateJob(job, target);
    return isar.writeTxn(() async {
      _current(isCurrent);
      final receipt = await isar.iosTransferReceiptEntitys.getByOperationKey(
        keyFor(job),
      );
      if (receipt == null) return null;
      _matches(receipt, job, target);
      final song = await isar.songEntitys.get(receipt.localSongId);
      if (receipt.state != 'committed') {
        await validateOwnership();
        _current(isCurrent);
        receipt.state = 'retired';
        await isar.iosTransferReceiptEntitys.put(receipt);
        _current(isCurrent);
      }
      return IosTransferImportResult(receipt, song);
    });
  }
}
