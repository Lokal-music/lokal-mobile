import 'ios_transfer_import.dart';
import 'ios_transfer_models.dart';

Never _invalidRecovery() =>
    throw const FormatException('Invalid native import recovery page.');

/// Native SQLite key order: UUID bytes, then integer revision (not text order).
class IosTransferWorkCursor implements Comparable<IosTransferWorkCursor> {
  const IosTransferWorkCursor._(this.jobId, this.revision);
  final String jobId;
  final int revision;
  factory IosTransferWorkCursor.parse(String value) {
    final match = RegExp(
      r'^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([1-9][0-9]{0,18})$',
    ).firstMatch(value);
    final revision = match == null ? null : int.tryParse(match[2]!);
    if (match == null || revision == null || revision >= 9223372036854775807) {
      _invalidRecovery();
    }
    return IosTransferWorkCursor._(match[1]!, revision);
  }
  String get value => '$jobId:$revision';
  @override
  int compareTo(IosTransferWorkCursor other) {
    final id = jobId.compareTo(other.jobId);
    return id != 0 ? id : revision.compareTo(other.revision);
  }
}

/// Frozen old revisions survive cancellation/retry. This is bookkeeping, not
/// a lease or evidence that the recorded public file still exists unchanged.
class IosTransferImportWork {
  const IosTransferImportWork._(
    this.job,
    this.songId,
    this.target,
    this.publicationRecorded,
    this.currentRevision,
    this.currentPhase,
  );
  final IosTransferJob job;
  final int songId;
  final IosTransferLibraryTarget target;
  final bool publicationRecorded;
  final int? currentRevision;
  final IosTransferPhase? currentPhase;
  IosTransferWorkCursor get cursor =>
      IosTransferWorkCursor.parse('${job.id}:${job.revision}');
  bool get isCurrentRevision => currentRevision == job.revision;

  factory IosTransferImportWork.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) => !{
            'job',
            'songID',
            'targetRelativePath',
            'publicationRecorded',
            'currentRevision',
            'currentPhase',
          }.contains(key),
        ) ||
        value['songID'] is! int ||
        (value['songID'] as int) < 1 ||
        value['publicationRecorded'] is! bool ||
        value['targetRelativePath'] is! String) {
      _invalidRecovery();
    }
    final job = IosTransferJob.fromJson(value['job']);
    final songId = value['songID'] as int;
    if (job.direction != 'download' ||
        !{
          IosTransferPhase.validating,
          IosTransferPhase.importing,
        }.contains(job.phase) ||
        job.receivedBytes == null ||
        job.receivedSha256 == null ||
        (job.intent.identity.localSongId != null &&
            job.intent.identity.localSongId != '$songId')) {
      _invalidRecovery();
    }
    final revision = value['currentRevision'];
    final rawPhase = value['currentPhase'];
    IosTransferPhase? phase;
    if (rawPhase != null) {
      for (final candidate in IosTransferPhase.values) {
        if (candidate.name == rawPhase) phase = candidate;
      }
      if (phase == null) _invalidRecovery();
    }
    if ((revision == null) != (phase == null) ||
        (revision != null &&
            (revision is! int ||
                revision < job.revision ||
                revision >= 9223372036854775807))) {
      _invalidRecovery();
    }
    final target = IosTransferLibraryTarget(
      value['targetRelativePath'] as String,
    );
    target.validateFor(job);
    return IosTransferImportWork._(
      job,
      songId,
      target,
      value['publicationRecorded'] as bool,
      revision as int?,
      phase,
    );
  }
}

class IosTransferImportWorkPage {
  const IosTransferImportWorkPage._(
    this.generation,
    this.entries,
    this.nextCursor,
  );
  final int generation;
  final List<IosTransferImportWork> entries;
  final IosTransferWorkCursor? nextCursor;
  factory IosTransferImportWorkPage.fromJson(
    Object? value, {
    required int limit,
    IosTransferWorkCursor? after,
  }) {
    if (limit < 1 ||
        limit > 100 ||
        value is! Map ||
        value.keys.any(
          (key) => !{'generation', 'entries', 'nextCursor'}.contains(key),
        ) ||
        value['generation'] is! int ||
        (value['generation'] as int) < 0 ||
        value['entries'] is! List ||
        (value['entries'] as List).length > limit ||
        (value['nextCursor'] != null && value['nextCursor'] is! String)) {
      _invalidRecovery();
    }
    final entries = (value['entries'] as List)
        .map(IosTransferImportWork.fromJson)
        .toList();
    IosTransferWorkCursor? previous = after;
    for (final entry in entries) {
      if (previous != null && entry.cursor.compareTo(previous) <= 0) {
        _invalidRecovery();
      }
      previous = entry.cursor;
    }
    final next = value['nextCursor'] == null
        ? null
        : IosTransferWorkCursor.parse(value['nextCursor'] as String);
    if (next != null &&
        ((after != null && next.compareTo(after) <= 0) ||
            (entries.isNotEmpty && next.compareTo(entries.last.cursor) < 0))) {
      _invalidRecovery();
    }
    return IosTransferImportWorkPage._(
      value['generation'] as int,
      List.unmodifiable(entries),
      next,
    );
  }
}

class IosTransferImportCandidatePage {
  const IosTransferImportCandidatePage._(
    this.generation,
    this.entries,
    this.nextCursor,
  );
  final int generation;
  final List<IosTransferJob> entries;
  final IosTransferWorkCursor? nextCursor;
  factory IosTransferImportCandidatePage.fromJson(
    Object? value, {
    required int limit,
    IosTransferWorkCursor? after,
  }) {
    if (limit < 1 ||
        limit > 100 ||
        value is! Map ||
        value.keys.any(
          (key) => !{'generation', 'entries', 'nextCursor'}.contains(key),
        ) ||
        value['generation'] is! int ||
        (value['generation'] as int) < 0 ||
        value['entries'] is! List ||
        (value['entries'] as List).length > limit ||
        (value['nextCursor'] != null && value['nextCursor'] is! String)) {
      _invalidRecovery();
    }
    final entries = (value['entries'] as List)
        .map(IosTransferJob.fromJson)
        .toList();
    IosTransferWorkCursor? previous = after;
    for (final job in entries) {
      if (job.direction != 'download' ||
          !{
            IosTransferPhase.downloaded,
            IosTransferPhase.staged,
            IosTransferPhase.validating,
            IosTransferPhase.importing,
          }.contains(job.phase)) {
        _invalidRecovery();
      }
      final cursor = IosTransferWorkCursor.parse('${job.id}:${job.revision}');
      if (previous != null && cursor.compareTo(previous) <= 0) {
        _invalidRecovery();
      }
      previous = cursor;
    }
    final next = value['nextCursor'] == null
        ? null
        : IosTransferWorkCursor.parse(value['nextCursor'] as String);
    if (next != null &&
        (entries.length != limit ||
            previous == null ||
            next.compareTo(previous) != 0 ||
            (after != null && next.compareTo(after) <= 0))) {
      _invalidRecovery();
    }
    return IosTransferImportCandidatePage._(
      value['generation'] as int,
      List.unmodifiable(entries),
      next,
    );
  }
}
