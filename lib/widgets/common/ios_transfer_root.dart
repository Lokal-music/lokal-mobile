import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/ios_transfer_provider.dart';
import '../../services/ios_transfer_session.dart';

/// App lifetime, rather than a tab/screen, owns import observation. Native
/// libraryImport=false keeps this inert while cleanup/upload/lifecycle gates
/// remain unfinished; Android and the existing foreground copy flows continue.
class IosTransferRoot extends ConsumerStatefulWidget {
  const IosTransferRoot({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<IosTransferRoot> createState() => _IosTransferRootState();
}

class _IosTransferRootState extends ConsumerState<IosTransferRoot>
    with WidgetsBindingObserver {
  IosTransferSession? _session;

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
