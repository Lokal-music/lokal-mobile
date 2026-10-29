import 'dart:convert';

import 'ios_transfer_models.dart';

Never _invalidImport() =>
    throw const FormatException('Invalid iPhone import receipt.');

/// Ephemeral native authority. Never save this document to Isar/preferences or
/// send its current sandbox path to peers. Job + receipt remain durable truth.
class IosTransferImportLease {
  const IosTransferImportLease._({
    required this.job,
    required this.leaseId,
    required this.clientId,
    required this.reconcileOnly,
    required this.target,
    this.sourcePath,
  });
  final IosTransferJob job;
  final String leaseId;
  final String clientId;
  final bool reconcileOnly;
  final IosTransferLibraryTarget target;
  final String? sourcePath;

  factory IosTransferImportLease.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) => !{
            'job',
            'leaseID',
            'clientID',
            'reconcileOnly',
            'targetRelativePath',
            'sourcePath',
          }.contains(key),
        ) ||
        value['leaseID'] is! String ||
        value['clientID'] is! String ||
        value['reconcileOnly'] is! bool ||
        value['targetRelativePath'] is! String ||
        (value['sourcePath'] != null && value['sourcePath'] is! String)) {
      _invalidImport();
    }
    final job = IosTransferJob.fromJson(value['job']);
    final leaseId = value['leaseID'] as String;
    final clientId = value['clientID'] as String;
    final reconcileOnly = value['reconcileOnly'] as bool;
    final source = value['sourcePath'] as String?;
    final target = IosTransferLibraryTarget(
      value['targetRelativePath'] as String,
    );
    if (!RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(leaseId) ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(clientId) ||
        job.direction != 'download' ||
        !{
          IosTransferPhase.validating,
          IosTransferPhase.importing,
          IosTransferPhase.complete,
        }.contains(job.phase) ||
        (job.phase == IosTransferPhase.complete && !reconcileOnly) ||
        (reconcileOnly && source != null) ||
        (source != null &&
            (!source.startsWith('/') ||
                source.contains('\u0000') ||
                utf8.encode(source).length > 4096 ||
                source
                    .split('/')
                    .any((part) => part == '.' || part == '..')))) {
      _invalidImport();
    }
    target.validateFor(job);
    return IosTransferImportLease._(
      job: job,
      leaseId: leaseId,
      clientId: clientId,
      reconcileOnly: reconcileOnly,
      target: target,
      sourcePath: source,
    );
  }

  Map<String, Object> get control => {
    'id': job.id,
    'revision': job.revision,
    'leaseID': leaseId,
    'clientID': clientId,
  };
}

/// A verified physical copy at the native importing boundary. This document is
/// not acknowledgement that a Song or a completed Isar receipt exists.
class IosTransferPublishedImport {
  const IosTransferPublishedImport._(this.job, this.songId, this.receipt);
  final IosTransferJob job;
  final int songId;
  final IosTransferLibraryReceipt receipt;

  factory IosTransferPublishedImport.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any((key) => !{'job', 'songID', 'receipt'}.contains(key)) ||
        value['songID'] is! int ||
        (value['songID'] as int) < 1) {
      _invalidImport();
    }
    final job = IosTransferJob.fromJson(value['job']);
    final songId = value['songID'] as int;
    final receipt = IosTransferLibraryReceipt.fromJson(value['receipt']);
    if (job.direction != 'download' ||
        job.phase != IosTransferPhase.importing ||
        (job.intent.identity.localSongId != null &&
            job.intent.identity.localSongId != songId.toString())) {
      _invalidImport();
    }
    receipt.validateFor(job);
    return IosTransferPublishedImport._(job, songId, receipt);
  }

  void validateFor(IosTransferImportLease lease, {required int songId}) {
    if (lease.reconcileOnly ||
        this.songId != songId ||
        job.id != lease.job.id ||
        job.revision != lease.job.revision ||
        job.receivedBytes != lease.job.receivedBytes ||
        job.receivedSha256 != lease.job.receivedSha256 ||
        receipt.relativePath != lease.target.relativePath ||
        jsonEncode(job.intent.toJson()) !=
            jsonEncode(lease.job.intent.toJson())) {
      _invalidImport();
    }
  }
}

/// A native-derived target is relative to the current app's Music directory.
/// Preparing this target does not claim that a file has been published.
class IosTransferLibraryTarget {
  const IosTransferLibraryTarget(this.relativePath);
  final String relativePath;

  void validateFor(IosTransferJob job) {
    final parts = relativePath.split('/');
    final extension = job.intent.metadata.fileExtension;
    if (utf8.encode(relativePath).length > 512 ||
        parts.length != 2 ||
        parts.first != 'Desktop Copies' ||
        parts.last.isEmpty ||
        parts.last.startsWith('.') ||
        parts.last.contains('\\') ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(relativePath) ||
        !parts.last.endsWith(' - ${job.id}-r${job.revision}.$extension')) {
      _invalidImport();
    }
  }
}

/// Produced after native owned-copy publication and full-file verification.
class IosTransferLibraryReceipt extends IosTransferLibraryTarget {
  const IosTransferLibraryReceipt({
    required String relativePath,
    required this.bytes,
    required this.sha256,
  }) : super(relativePath);
  final int bytes;
  final String sha256;

  factory IosTransferLibraryReceipt.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) => !{'relativePath', 'bytes', 'sha256'}.contains(key),
        ) ||
        value['relativePath'] is! String ||
        value['bytes'] is! int ||
        value['sha256'] is! String) {
      _invalidImport();
    }
    final receipt = IosTransferLibraryReceipt(
      relativePath: value['relativePath'] as String,
      bytes: value['bytes'] as int,
      sha256: value['sha256'] as String,
    );
    receipt._validate();
    return receipt;
  }

  void _validate() {
    if (bytes < 1 ||
        bytes > 8 * 1024 * 1024 * 1024 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      _invalidImport();
    }
  }

  @override
  void validateFor(IosTransferJob job) {
    super.validateFor(job);
    _validate();
    if (bytes != job.receivedBytes || sha256 != job.receivedSha256) {
      _invalidImport();
    }
  }
}

/// Header/probe results supplied by the existing media reader. This object
/// does not perform or substitute for actual media validation.
class IosTransferMediaInfo {
  const IosTransferMediaInfo({
    required this.recognized,
    this.codec,
    this.format,
    this.durationMs,
    this.sampleRate,
    this.bitDepth,
    this.bitrate,
    this.channels,
  });
  final bool recognized;
  final String? codec;

  /// Actual container/playback label (WAV, M4A, FLAC...), separate from codec.
  final String? format;
  final int? durationMs, sampleRate, bitDepth, bitrate, channels;

  Map<String, Object> toJson() {
    validate();
    return {
      'recognized': recognized,
      'codec': ?codec,
      'format': ?format,
      'durationMs': ?durationMs,
      'sampleRate': ?sampleRate,
      'bitDepth': ?bitDepth,
      'bitrate': ?bitrate,
      'channels': ?channels,
    };
  }

  factory IosTransferMediaInfo.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) => !{
            'recognized',
            'codec',
            'format',
            'durationMs',
            'sampleRate',
            'bitDepth',
            'bitrate',
            'channels',
          }.contains(key),
        ) ||
        value['recognized'] is! bool ||
        (value['codec'] != null && value['codec'] is! String) ||
        (value['format'] != null && value['format'] is! String)) {
      _invalidImport();
    }
    for (final key in [
      'durationMs',
      'sampleRate',
      'bitDepth',
      'bitrate',
      'channels',
    ]) {
      if (value[key] != null && value[key] is! int) _invalidImport();
    }
    final media = IosTransferMediaInfo(
      recognized: value['recognized'] as bool,
      codec: value['codec'] as String?,
      format: value['format'] as String?,
      durationMs: value['durationMs'] as int?,
      sampleRate: value['sampleRate'] as int?,
      bitDepth: value['bitDepth'] as int?,
      bitrate: value['bitrate'] as int?,
      channels: value['channels'] as int?,
    );
    media.validate();
    return media;
  }

  void validate() {
    bool outside(int? value, int minimum, int maximum) =>
        value != null && (value < minimum || value > maximum);
    if (!recognized ||
        (codec != null && !RegExp(r'^[A-Z0-9_]{1,16}$').hasMatch(codec!)) ||
        (format != null && !RegExp(r'^[A-Z0-9_]{1,16}$').hasMatch(format!)) ||
        outside(durationMs, 0, 365 * 24 * 60 * 60 * 1000) ||
        outside(sampleRate, 1, 1536000) ||
        outside(bitDepth, 1, 64) ||
        outside(bitrate, 1, 1000000) ||
        outside(channels, 1, 64)) {
      _invalidImport();
    }
  }
}
