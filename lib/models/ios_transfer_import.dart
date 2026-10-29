import 'dart:convert';

import 'ios_transfer_models.dart';

Never _invalidImport() =>
    throw const FormatException('Invalid iPhone import receipt.');

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
    this.durationMs,
    this.sampleRate,
    this.bitDepth,
    this.bitrate,
    this.channels,
  });
  final bool recognized;
  final String? codec;
  final int? durationMs, sampleRate, bitDepth, bitrate, channels;

  void validate() {
    bool outside(int? value, int minimum, int maximum) =>
        value != null && (value < minimum || value > maximum);
    if (!recognized ||
        (codec != null && !RegExp(r'^[A-Z0-9_]{1,16}$').hasMatch(codec!)) ||
        outside(durationMs, 0, 365 * 24 * 60 * 60 * 1000) ||
        outside(sampleRate, 1, 1536000) ||
        outside(bitDepth, 1, 64) ||
        outside(bitrate, 1, 1000000) ||
        outside(channels, 1, 64)) {
      _invalidImport();
    }
  }
}
