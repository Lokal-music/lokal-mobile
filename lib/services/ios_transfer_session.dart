import 'ios_transfer_import_coordinator.dart';
import 'ios_transfer_transport.dart';
import 'ios_transfer_mutation_barrier.dart';
import 'ios_transfer_upload_admission.dart';

import 'dart:convert';

import '../models/ios_transfer_models.dart';

/// One app lifetime owns both the Dart coordinator and its native client.
/// Lifecycle widgets borrow this owner; screen replacement never disposes it.
class IosTransferSession {
  IosTransferSession({
    required this.native,
    required this.coordinator,
    this.uploadAdmission,
  }) {
    if (!identical(native, coordinator.native)) {
      throw ArgumentError(
        'An iPhone transfer session requires one shared transport.',
      );
    }
  }

  final IosTransferTransport native;
  final IosTransferImportCoordinator coordinator;
  final Future<IosTransferUploadAdmission> Function()? uploadAdmission;
  final mutations = IosTransferMutationBarrier();
  Future<void>? _disposing;
  bool _disposed = false;
  bool get active => !_disposed;

  Future<void> start() => _disposed ? Future.value() : coordinator.start();
  Future<void> foreground() =>
      _disposed ? Future.value() : coordinator.foreground();

  /// The product entry point keeps source access behind the qualified engine
  /// capability and the existing app-root observation/mutation owner.
  Future<IosTransferSummary> enqueueUploadSong({
    required int songId,
    required IosTransferPairing expectedPairing,
    required void Function(IosTransferIntent intent) prepared,
    IosTransferIntent? frozenIntent,
    String? reviewedSourcePath,
  }) async {
    final capability = await native.capability();
    if (_disposed ||
        !capability.canCopyToLibrary ||
        !capability.upload ||
        uploadAdmission == null) {
      throw StateError(
        'Background uploads are not available. Use foreground copying.',
      );
    }
    await start();
    if (_disposed || !coordinator.enabled) {
      throw StateError('iPhone transfer owner is unavailable.');
    }
    final admission = await uploadAdmission!();
    if (_disposed) throw StateError('iPhone transfer owner was disposed.');
    return admission.enqueueSong(
      songId: songId,
      expectedPairing: expectedPairing,
      prepared: prepared,
      frozenIntent: frozenIntent,
      reviewedSourcePath: reviewedSourcePath,
    );
  }

  /// Caller holds the shared mutation pause and a native observation lease.
  /// Cancel old plans durably without revoking the paired desktop itself.
  Future<void> reconcileBeforeLibraryClear() async {
    final recovered = await native.recover();
    if (recovered.persistenceFailed) {
      throw StateError('iPhone transfer recovery must succeed first.');
    }
    await coordinator.reconcileImportsForMutation(null);
    final scopes = <String, IosTransferScope>{};
    var offset = 0;
    while (true) {
      if (_disposed) throw StateError('iPhone transfer owner was disposed.');
      final jobs = await native.page(offset: offset);
      for (final job in jobs) {
        final scope = job.intent.identity.scope;
        scopes[jsonEncode(scope.toJson())] = scope;
      }
      offset += jobs.length;
      if (offset > iosTransferMaximumJobs) {
        throw const FormatException('Library mutation budget exceeded.');
      }
      if (jobs.length < 100) break;
      if (offset == iosTransferMaximumJobs) break;
    }
    for (final scope in scopes.values) {
      if (_disposed) throw StateError('iPhone transfer owner was disposed.');
      final cancelled = await native.cancelNetworkScopePreservingFiles(scope);
      if (cancelled.persistenceFailed) {
        throw StateError('iPhone transfer cancellation must finish first.');
      }
    }
    await coordinator.reconcileImportsForMutation(
      null,
      afterNetworkRetirement: true,
    );
  }

  Future<void> dispose() {
    _disposed = true;
    return _disposing ??= () async {
      try {
        await coordinator.dispose();
      } finally {
        await native.dispose();
      }
    }();
  }
}
