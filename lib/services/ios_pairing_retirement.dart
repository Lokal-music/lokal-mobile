import '../models/ios_transfer_models.dart';
import '../models/lokal_remote_state.dart';

/// Product-side ownership decision for Forget. Never use an origin preference
/// or a bearer token as a native job identity. The native side authorizes
/// current credentials independently from its atomic Keychain record.
///
/// This is deliberately stricter than a normal connection reset: if a native
/// journal is present but its pairing cannot be proven, preserve the desktop
/// credentials and ask for transfer recovery instead of orphaning OS tasks.
class IosPairingRetirement {
  static bool sameScope(IosTransferScope left, IosTransferScope right) {
    final a = Uri.tryParse(left.origin), b = Uri.tryParse(right.origin);
    return left.desktopId == right.desktopId &&
        left.pairingId != null &&
        left.pairingId == right.pairingId &&
        a != null &&
        b != null &&
        a.scheme == b.scheme &&
        a.host == b.host &&
        a.port == b.port &&
        (a.path.isEmpty || a.path == '/') &&
        (b.path.isEmpty || b.path == '/');
  }

  static Future<void> retireBeforeForget({
    required LokalRemoteCredentials? expected,
    required Future<IosTransferSummary> Function() recover,
    required Future<IosTransferPairing?> Function() currentPairing,
    required Future<IosTransferSummary> Function(IosTransferScope scope) retire,
    required Future<void> Function(IosTransferScope scope) reconcileImports,
    required Future<void> Function(IosTransferScope scope)
    reconcileReservations,
  }) async {
    // Recover URLSession identities before inspecting any journal count.
    // Native cancellation/cleanup still owns its own serial queue.
    final recovered = await recover();
    if (recovered.persistenceFailed) {
      throw StateError('iPhone transfer recovery must succeed first.');
    }

    final native = await currentPairing();
    final hasNativeAuthority =
        expected?.desktopId != null &&
        expected!.remoteToken.isNotEmpty &&
        expected.pairingID != null;
    if (!hasNativeAuthority) {
      // Legacy credentials have no public pairing identity. The native
      // adapter never authorized jobs with them; any persisted job is
      // nevertheless ambiguous and must block destructive credential removal.
      if (native != null || recovered.total != 0) {
        throw StateError('iPhone transfer pairing cannot be verified.');
      }
      return;
    }

    final requested = IosTransferScope(
      desktopId: expected.desktopId!,
      origin: expected.origin.toString(),
      pairingId: expected.pairingID,
    );
    requested.validate();
    if (native == null || !sameScope(requested, native.scope)) {
      throw StateError('iPhone transfer pairing changed. Reconnect and retry.');
    }
    await reconcileImports(native.scope);
    final retired = await retire(native.scope);
    if (retired.persistenceFailed ||
        !retired.pauses.any(
          (pause) =>
              pause.reason == 'pairingChanged' &&
              sameScope(pause.scope, native.scope),
        )) {
      throw StateError('iPhone transfer retirement was not acknowledged.');
    }
    await reconcileReservations(native.scope);
  }
}
