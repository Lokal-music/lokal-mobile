import 'ios_transfer_import_coordinator.dart';
import 'ios_transfer_transport.dart';
import 'ios_transfer_mutation_barrier.dart';

import 'dart:convert';

import '../models/ios_transfer_models.dart';

/// One app lifetime owns both the Dart coordinator and its native client.
/// Lifecycle widgets borrow this owner; screen replacement never disposes it.
class IosTransferSession {
  IosTransferSession({required this.native, required this.coordinator}) {
    if (!identical(native, coordinator.native)) {
      throw ArgumentError(
        'An iPhone transfer session requires one shared transport.',
      );
    }
  }

  final IosTransferTransport native;
  final IosTransferImportCoordinator coordinator;
  final mutations = IosTransferMutationBarrier();
  Future<void>? _disposing;
  bool _disposed = false;
  bool get active => !_disposed;

  Future<void> start() => _disposed ? Future.value() : coordinator.start();
  Future<void> foreground() =>
      _disposed ? Future.value() : coordinator.foreground();

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
        if (job.direction == 'download') {
          final scope = job.intent.identity.scope;
          scopes[jsonEncode(scope.toJson())] = scope;
        }
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
