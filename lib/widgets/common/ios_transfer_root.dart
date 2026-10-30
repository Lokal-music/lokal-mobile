import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/ios_transfer_provider.dart';
import '../../providers/lokal_remote_provider.dart';
import '../../services/ios_transfer_session.dart';
import '../../services/ios_library_scan_epoch.dart';
import '../../services/link/lokal_desktop_source.dart';

import '../../models/lokal_remote_state.dart';
import '../../services/ios_pairing_retirement.dart';
import '../../services/ios_transfer_import_coordinator.dart';
import '../../services/ios_transfer_mutation_barrier.dart';
import '../../services/ios_transfer_transport.dart';

/// App lifetime, rather than a tab/screen, owns import observation. Native
/// libraryImport=false keeps product imports disabled while cleanup/upload
/// gates remain unfinished. An explicit pairing mutation may temporarily
/// attach a native owner to revoke URLSession authority before Keychain changes.
/// Android retains its existing behavior; iPhone foreground writers are drained.
class IosTransferRoot extends ConsumerStatefulWidget {
  const IosTransferRoot({super.key, required this.child});
  final Widget child;

  /// Clear Library keeps public files and the desktop pairing, but old plans
  /// must not insert new Songs after the user's metadata transaction.
  static Future<T> withLibraryClearBarrier<T>(
    BuildContext context,
    Future<T> Function() mutation,
  ) {
    if (kIsWeb || !Platform.isIOS) return mutation();
    final root = context.findAncestorStateOfType<_IosTransferRootState>();
    if (root == null) throw StateError('iPhone transfer owner is unavailable.');
    return root._withLibraryClear(mutation);
  }

  /// Guard a destructive library or pairing operation at its UI entry point.
  /// Ordinary Android operations remain unchanged. Native iOS transfers are
  /// still release-disabled; this fence does not replace OS-task cancellation.
  static Future<T> withMutationBarrier<T>(
    BuildContext context,
    Future<T> Function() mutation,
  ) {
    if (kIsWeb || !Platform.isIOS) return mutation();
    final root = context.findAncestorStateOfType<_IosTransferRootState>();
    if (root == null) {
      throw StateError('iPhone transfer owner is unavailable.');
    }
    return root._withMutation(mutation);
  }

  /// The stronger Forget boundary always checks native journal truth, even
  /// while product background import is disabled. Generic library mutations
  /// do not imply that credentials may be revoked.
  static Future<T> withPairingRetirement<T>(
    BuildContext context, {
    required LokalRemoteCredentials? expected,
    required Future<T> Function() mutation,
  }) {
    if (kIsWeb || !Platform.isIOS) return mutation();
    final root = context.findAncestorStateOfType<_IosTransferRootState>();
    if (root == null) {
      throw StateError('iPhone transfer owner is unavailable.');
    }
    return root._withPairingRetirement(expected, mutation);
  }

  @override
  ConsumerState<IosTransferRoot> createState() => _IosTransferRootState();
}

class _IosTransferRootState extends ConsumerState<IosTransferRoot>
    with WidgetsBindingObserver {
  IosTransferSession? _session;
  IosTransferTransport? get _native => _session?.native;
  IosTransferImportCoordinator? get _coordinator => _session?.coordinator;
  IosTransferMutationBarrier get _mutations => _session!.mutations;

  Future<T> _withLibraryClear<T>(Future<T> Function() mutation) {
    final session = _session;
    if (session == null) {
      throw StateError('iPhone transfer owner is unavailable.');
    }
    final coordinator = session.coordinator, native = session.native;
    StreamSubscription<void>? observation;
    var paused = false;
    return IosLibraryScanEpoch.withMutation(
      () => LokalDesktopSource.instance.withLibraryTransfersDrained(
        () => session.mutations.run<T>(
          pause: () async {
            try {
              if (!mounted || !session.active) {
                throw StateError('iPhone transfer owner was disposed.');
              }
              // Keep credentials, but retire old socket/journal callbacks so a
              // pending desktop sync cannot repopulate the cleared metadata.
              ref.read(lokalRemoteControllerProvider.notifier).disconnect();
              await coordinator.start();
              if (coordinator.eligible && !coordinator.enabled) {
                throw StateError(
                  'iPhone transfer recovery must succeed first.',
                );
              }
              observation = native.changes.listen(
                (_) {},
                onError: (Object _, StackTrace __) {},
              );
              await coordinator.pauseForMutation();
              paused = true;
              await session.reconcileBeforeLibraryClear();
              if (!mounted || !session.active) {
                throw StateError('iPhone transfer owner was disposed.');
              }
            } catch (_) {
              try {
                await observation?.cancel();
              } finally {
                if (paused) await coordinator.resumeAfterMutation();
              }
              rethrow;
            }
          },
          resume: () async {
            try {
              await observation?.cancel();
            } finally {
              if (paused) await coordinator.resumeAfterMutation();
            }
          },
          mutate: mutation,
        ),
      ),
    );
  }

  Future<T> _withMutation<T>(Future<T> Function() mutation) {
    final coordinator = _coordinator;
    if (coordinator == null) {
      throw StateError('iPhone transfer owner is unavailable.');
    }
    var paused = false;
    return IosLibraryScanEpoch.withMutation(
      () => LokalDesktopSource.instance.withLibraryTransfersDrained(
        () => _mutations.run<T>(
          pause: () async {
            if (!mounted) {
              throw StateError('iPhone transfer owner was disposed.');
            }
            await coordinator.start();
            if (!mounted) {
              throw StateError('iPhone transfer owner was disposed.');
            }
            if (!coordinator.enabled) {
              // The disabled release adapter has never acquired a transfer lease.
              // If an eligible adapter failed startup, refuse the mutation rather
              // than writing across an owner whose retirement is unconfirmed.
              if (coordinator.eligible) {
                throw StateError(
                  'iPhone transfer recovery must succeed first.',
                );
              }
              return;
            }
            await coordinator.pauseForMutation();
            paused = true;
          },
          resume: () async {
            if (paused) await coordinator.resumeAfterMutation();
          },
          mutate: mutation,
        ),
      ),
    );
  }

  Future<T> _withPairingRetirement<T>(
    LokalRemoteCredentials? expected,
    Future<T> Function() mutation,
  ) {
    final coordinator = _coordinator, native = _native;
    if (coordinator == null || native == null) {
      throw StateError('iPhone transfer owner is unavailable.');
    }
    StreamSubscription<void>? observation;
    var paused = false;
    return IosLibraryScanEpoch.withMutation(
      () => LokalDesktopSource.instance.withLibraryTransfersDrained(
        () => _mutations.run<T>(
          pause: () async {
            if (!mounted) {
              throw StateError('iPhone transfer owner was disposed.');
            }
            try {
              await coordinator.start();
              if (!mounted) {
                throw StateError('iPhone transfer owner was disposed.');
              }
              if (coordinator.eligible && !coordinator.enabled) {
                throw StateError(
                  'iPhone transfer recovery must succeed first.',
                );
              }
              // The product adapter currently never attaches a native client.
              // Observe explicitly for this one critical operation and keep its
              // client alive until the callback + file-work barrier has replied.
              observation = native.changes.listen(
                (_) {},
                onError: (Object _, StackTrace __) {},
              );
              await coordinator.pauseForMutation();
              paused = true;
              await IosPairingRetirement.retireBeforeForget(
                expected: expected,
                recover: native.recover,
                currentPairing: native.currentPairing,
                retire: native.retireNetworkScope,
                reconcileImports: coordinator.reconcileImportsForMutation,
                reconcileReservations: (scope) =>
                    coordinator.reconcileImportsForMutation(
                      scope,
                      afterNetworkRetirement: true,
                    ),
              );
              if (!mounted) {
                throw StateError('iPhone transfer owner was disposed.');
              }
            } catch (_) {
              try {
                await observation?.cancel();
              } finally {
                if (paused) await coordinator.resumeAfterMutation();
              }
              rethrow;
            }
          },
          resume: () async {
            try {
              await observation?.cancel();
            } finally {
              if (paused) await coordinator.resumeAfterMutation();
            }
          },
          mutate: mutation,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _session = ref.read(iosTransferSessionProvider);
    if (_session == null) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_session!.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_session?.foreground());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
