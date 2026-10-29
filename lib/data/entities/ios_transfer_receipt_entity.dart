import 'package:isar_community/isar.dart';

part 'ios_transfer_receipt_entity.g.dart';

/// Private import receipts never enter the peer-synchronized library journal.
/// A reservation precedes file publication; completion shares the song txn.
@collection
class IosTransferReceiptEntity {
  Id id = Isar.autoIncrement;
  int schemaVersion = 1;

  @Index(unique: true)
  late String operationKey;
  late String jobId;
  late int revision;

  @Index()
  String state = 'prepared';
  @Index()
  late int localSongId;

  late int serverId;
  late String desktopId;
  String? desktopUserId;
  late String pairingId;
  late String origin;
  late String sourceId;

  /// Relative to the current app-owned Music directory, never a sandbox path.
  @Index()
  late String relativePath;
  late int bytes;
  late String sha256;
  late DateTime preparedAt;
  DateTime? committedAt;

  /// Bounded actual-reader result for these exact frozen bytes/hash. No tags,
  /// source URL, credentials or absolute sandbox path enters this document.
  String? validatedMediaJson;
}
