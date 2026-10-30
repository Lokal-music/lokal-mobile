import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import '../../data/database.dart';
import '../../services/ios_transfer_import_coordinator.dart';
import '../../services/ios_transfer_mutation_barrier.dart';
import '../../services/ios_transfer_import_store.dart';
import '../../services/ios_transfer_media_probe.dart';
import '../../services/ios_transfer_transport.dart';

/// App lifetime, rather than a tab/screen, owns import observation. Native
/// libraryImport=false keeps this inert while cleanup/upload/lifecycle gates
/// remain unfinished; Android and the existing foreground copy flows continue.
class IosTransferRoot extends StatefulWidget {
  const IosTransferRoot({super.key, required this.child});
  final Widget child;

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

  @override
  State<IosTransferRoot> createState() => _IosTransferRootState();
}

class _IosTransferRootState extends State<IosTransferRoot>
    with WidgetsBindingObserver {
  IosTransferTransport? _native;
  IosTransferImportCoordinator? _coordinator;
  final IosTransferMutationBarrier _mutations = IosTransferMutationBarrier();

  Future<T> _withMutation<T>(Future<T> Function() mutation) {
    final coordinator = _coordinator;
    if (coordinator == null) {
      throw StateError('iPhone transfer owner is unavailable.');
    }
    var paused = false;
    return _mutations.run<T>(
      pause: () async {
        if (!mounted) throw StateError('iPhone transfer owner was disposed.');
        await coordinator.start();
        if (!mounted) throw StateError('iPhone transfer owner was disposed.');
        if (!coordinator.enabled) {
          // The disabled release adapter has never acquired a transfer lease.
          // If an eligible adapter failed startup, refuse the mutation rather
          // than writing across an owner whose retirement is unconfirmed.
          if (coordinator.eligible) {
            throw StateError('iPhone transfer recovery must succeed first.');
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
    );
  }

  @override
  void initState() {
    super.initState();
    if (kIsWeb || !Platform.isIOS) return;
    WidgetsBinding.instance.addObserver(this);
    final native = IosTransferTransport();
    _native = native;
    _coordinator = IosTransferImportCoordinator(
      native: native,
      store: () async {
        if (!Database.isInitialized) {
          throw StateError('Library is not available.');
        }
        final documents = await getApplicationDocumentsDirectory();
        return IosTransferImportStore(
          Database.instance,
          musicRoot: '${documents.path}/Music',
        );
      },
      readMedia: const IosTransferMediaProbe().inspect,
    );
    unawaited(_coordinator!.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_coordinator?.foreground());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final coordinator = _coordinator, native = _native;
    unawaited(() async {
      await coordinator?.dispose();
      await native?.dispose();
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
