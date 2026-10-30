import 'dart:convert';

import 'ios_transfer_import.dart';
import 'ios_transfer_models.dart';
import 'ios_transfer_recovery.dart';

Never _invalidCleanup() =>
    throw const FormatException('Invalid native import cleanup claim.');

enum IosTransferCleanupMode { abandoned, committed }

enum IosTransferAbandonment { removedOwnedFile, missingFile, preservedUserFile }

/// Native file handling finished; this never substitutes for an Isar receipt.
class IosTransferCleanupResolution {
  const IosTransferCleanupResolution._(this.mode, this.abandonment);
  final IosTransferCleanupMode mode;
  final IosTransferAbandonment? abandonment;
  factory IosTransferCleanupResolution.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any((key) => !{'mode', 'abandonment'}.contains(key))) {
      _invalidCleanup();
    }
    final mode = IosTransferCleanupMode.values.where(
      (e) => e.name == value['mode'],
    );
    final outcome = IosTransferAbandonment.values.where(
      (e) => e.name == value['abandonment'],
    );
    if (mode.length != 1 ||
        (value['abandonment'] != null && outcome.length != 1) ||
        (mode.single == IosTransferCleanupMode.abandoned) !=
            outcome.isNotEmpty) {
      _invalidCleanup();
    }
    return IosTransferCleanupResolution._(mode.single, outcome.firstOrNull);
  }
}

class IosTransferResolvedCleanup {
  const IosTransferResolvedCleanup._(
    this.id,
    this.revision,
    this.songId,
    this.resolution,
  );
  final String id;
  final int revision, songId;
  final IosTransferCleanupResolution resolution;
  factory IosTransferResolvedCleanup.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) => !{'id', 'revision', 'songID', 'resolution'}.contains(key),
        ) ||
        value['id'] is! String ||
        value['revision'] is! int ||
        value['songID'] is! int ||
        (value['songID'] as int) < 1) {
      _invalidCleanup();
    }
    final key = IosTransferWorkCursor.parse(
      '${value['id']}:${value['revision']}',
    );
    return IosTransferResolvedCleanup._(
      key.jobId,
      key.revision,
      value['songID'] as int,
      IosTransferCleanupResolution.fromJson(value['resolution']),
    );
  }
  void validateFor(IosTransferCleanupLease lease, IosTransferCleanupMode mode) {
    if (id != lease.job.id ||
        revision != lease.job.revision ||
        songId != lease.songId ||
        resolution.mode != mode) {
      _invalidCleanup();
    }
  }
}

/// Distinct from a publication/reconciliation lease: no source path and no
/// conversion to writer authority. Never persist this ephemeral document.
class IosTransferCleanupLease {
  const IosTransferCleanupLease._({
    required this.job,
    required this.songId,
    required this.leaseId,
    required this.clientId,
    required this.target,
    required this.currentRevision,
    required this.currentPhase,
    required this.publicationRecorded,
    required this.resolution,
  });
  final IosTransferJob job;
  final int songId;
  final String leaseId, clientId;
  final IosTransferLibraryTarget target;
  final int currentRevision;
  final IosTransferPhase currentPhase;
  final bool publicationRecorded;
  final IosTransferCleanupResolution? resolution;

  factory IosTransferCleanupLease.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) => !{
            'permission',
            'job',
            'songID',
            'leaseID',
            'clientID',
            'targetRelativePath',
            'currentRevision',
            'currentPhase',
            'publicationRecorded',
            'resolution',
          }.contains(key),
        ) ||
        value['permission'] != 'cleanup' ||
        value['songID'] is! int ||
        (value['songID'] as int) < 1 ||
        value['leaseID'] is! String ||
        value['clientID'] is! String ||
        value['targetRelativePath'] is! String ||
        value['currentRevision'] is! int ||
        value['publicationRecorded'] is! bool) {
      _invalidCleanup();
    }
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    );
    final job = IosTransferJob.fromJson(value['job']);
    final revision = value['currentRevision'] as int;
    final phases = IosTransferPhase.values.where(
      (e) => e.name == value['currentPhase'],
    );
    if (!uuid.hasMatch(value['leaseID'] as String) ||
        !uuid.hasMatch(value['clientID'] as String) ||
        job.direction != 'download' ||
        !{
          IosTransferPhase.validating,
          IosTransferPhase.importing,
        }.contains(job.phase) ||
        job.receivedBytes == null ||
        job.receivedSha256 == null ||
        (job.intent.identity.localSongId != null &&
            job.intent.identity.localSongId != '${value['songID']}') ||
        revision < job.revision ||
        revision >= 9223372036854775807 ||
        phases.length != 1) {
      _invalidCleanup();
    }
    final phase = phases.single;
    final published = value['publicationRecorded'] as bool;
    final resolution = value['resolution'] == null
        ? null
        : IosTransferCleanupResolution.fromJson(value['resolution']);
    if ((revision == job.revision &&
            !{
              IosTransferPhase.validating,
              IosTransferPhase.importing,
              IosTransferPhase.complete,
            }.contains(phase)) ||
        (revision == job.revision &&
            phase == IosTransferPhase.complete &&
            !published) ||
        (resolution != null && revision == job.revision) ||
        (resolution?.mode == IosTransferCleanupMode.committed && !published)) {
      _invalidCleanup();
    }
    final target = IosTransferLibraryTarget(
      value['targetRelativePath'] as String,
    );
    target.validateFor(job);
    return IosTransferCleanupLease._(
      job: job,
      songId: value['songID'] as int,
      leaseId: value['leaseID'] as String,
      clientId: value['clientID'] as String,
      target: target,
      currentRevision: revision,
      currentPhase: phase,
      publicationRecorded: published,
      resolution: resolution,
    );
  }

  Map<String, Object> get control => {
    'id': job.id,
    'revision': job.revision,
    'leaseID': leaseId,
    'clientID': clientId,
  };

  void validateFor(IosTransferImportWork work) {
    if (job.id != work.job.id ||
        job.revision != work.job.revision ||
        job.phase != work.job.phase ||
        job.updatedMs != work.job.updatedMs ||
        songId != work.songId ||
        target.relativePath != work.target.relativePath ||
        job.receivedBytes != work.job.receivedBytes ||
        job.receivedSha256 != work.job.receivedSha256 ||
        jsonEncode(job.intent.toJson()) !=
            jsonEncode(work.job.intent.toJson()) ||
        (work.publicationRecorded && !publicationRecorded) ||
        (work.currentRevision != null &&
            currentRevision < work.currentRevision!)) {
      _invalidCleanup();
    }
  }
}
