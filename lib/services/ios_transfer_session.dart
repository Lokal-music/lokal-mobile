import 'ios_transfer_import_coordinator.dart';
import 'ios_transfer_transport.dart';
import 'ios_transfer_mutation_barrier.dart';

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

  Future<void> start() => _disposed ? Future.value() : coordinator.start();
  Future<void> foreground() =>
      _disposed ? Future.value() : coordinator.foreground();

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
