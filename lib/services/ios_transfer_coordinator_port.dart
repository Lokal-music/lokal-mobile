import '../models/ios_transfer_import.dart';
import '../models/ios_transfer_cleanup.dart';
import '../data/entities/ios_transfer_receipt_entity.dart';
import '../models/ios_transfer_models.dart';
import '../models/ios_transfer_recovery.dart';

/// Pure app boundary so coordinator acceptance can use the actual Isar core
/// without replacing it with a Flutter storage mock. Native acceptance and
/// installed-app channel acceptance remain separate tests.
abstract interface class IosTransferCoordinatorPort {
  Stream<void> get changes;
  Future<IosTransferCapability> capability();
  Future<IosTransferSummary> recover();
  Future<void> drainImports();
  Future<IosTransferImportWorkPage> importWorkPage({
    IosTransferWorkCursor? after,
    int limit = 100,
  });
  Future<IosTransferImportCandidatePage> importCandidatesPage({
    IosTransferWorkCursor? after,
    int limit = 100,
  });
  Future<IosTransferJob> verify(IosTransferJob job);
  Future<IosTransferImportLease> claimImport(
    IosTransferJob job, {
    bool reconcileOnly = false,
  });
  Future<void> validateImport(
    IosTransferImportLease lease, {
    bool requiresWrite = true,
  });
  Future<IosTransferPublishedImport> publishImport(
    IosTransferImportLease lease, {
    required int songId,
  });
  Future<IosTransferJob> acknowledgeImport(
    IosTransferImportLease lease, {
    required int songId,
  });
  Future<void> releaseImport(IosTransferImportLease lease);
  Future<IosTransferCleanupLease> claimImportCleanup(
    IosTransferImportWork work,
  );
  Future<void> validateImportCleanup(IosTransferCleanupLease lease);
  Future<IosTransferResolvedCleanup> resolveImportCleanup(
    IosTransferCleanupLease lease, {
    required IosTransferReceiptEntity receipt,
  });
  Future<void> finalizeImportCleanup(
    IosTransferCleanupLease lease, {
    required IosTransferReceiptEntity receipt,
  });
  Future<void> releaseImportCleanup(IosTransferCleanupLease lease);
}

typedef IosTransferMediaReader = Future<IosTransferMediaInfo> Function(
  IosTransferImportLease lease, {
  required bool Function() isCurrent,
  required Future<void> Function() validateOwnership,
  Future<void>? cancelled,
});
