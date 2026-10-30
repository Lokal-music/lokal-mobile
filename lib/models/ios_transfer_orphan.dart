import 'ios_transfer_models.dart';
import 'ios_transfer_recovery.dart';

/// A drained, older native revision without custody. This grants bookkeeping
/// retirement only; it is never accepted by publication or file cleanup APIs.
class IosTransferOrphanLease {
  const IosTransferOrphanLease._({
    required this.key,
    required this.songId,
    required this.leaseId,
    required this.clientId,
    required this.currentJob,
  });
  final IosTransferWorkCursor key;
  final int songId;
  final String leaseId, clientId;
  final IosTransferJob currentJob;

  factory IosTransferOrphanLease.fromJson(Object? value) {
    Never invalid() =>
        throw const FormatException('Invalid orphan recovery authority.');
    if (value is! Map ||
        value.keys.any(
          (key) => !{
            'permission',
            'id',
            'revision',
            'songID',
            'leaseID',
            'clientID',
            'currentJob',
          }.contains(key),
        ) ||
        value['permission'] != 'orphanCleanup' ||
        value['id'] is! String ||
        value['revision'] is! int ||
        value['songID'] is! int ||
        (value['songID'] as int) < 1 ||
        (value['songID'] as int) >= 9223372036854775807 ||
        value['leaseID'] is! String ||
        value['clientID'] is! String) {
      invalid();
    }
    final key = IosTransferWorkCursor.parse(
      '${value['id']}:${value['revision']}',
    );
    final job = IosTransferJob.fromJson(value['currentJob']);
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    );
    if (job.id != key.jobId ||
        job.revision <= key.revision ||
        job.direction != 'download' ||
        !uuid.hasMatch(value['leaseID'] as String) ||
        !uuid.hasMatch(value['clientID'] as String) ||
        (job.intent.identity.localSongId != null &&
            job.intent.identity.localSongId != '${value['songID']}')) {
      invalid();
    }
    return IosTransferOrphanLease._(
      key: key,
      songId: value['songID'] as int,
      leaseId: value['leaseID'] as String,
      clientId: value['clientID'] as String,
      currentJob: job,
    );
  }

  Map<String, Object> get control => {
    'id': key.jobId,
    'revision': key.revision,
    'leaseID': leaseId,
    'clientID': clientId,
  };
}
