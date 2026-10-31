import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/services/ios_transfer_import_coordinator.dart';
import 'package:flick/services/ios_transfer_session.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_transport_test.dart' show intentDocument, summary;

class _Native extends IosTransferTransport {
  _Native() : super(supported: false);
  final cancelled = <IosTransferScope>[];
  @override
  Future<IosTransferCapability> capability() async =>
      const IosTransferCapability(available: true, download: true);
  @override
  Future<IosTransferSummary> recover() async =>
      IosTransferSummary.fromJson(summary());
  @override
  Future<List<IosTransferJob>> page({int offset = 0, int limit = 100}) async =>
      [
        IosTransferJob.fromJson({
          ...intentDocument(),
          'direction': 'upload',
          'phase': 'queued',
          'revision': 1,
          'updatedMs': 2000,
        }),
      ];
  @override
  Future<IosTransferSummary> cancelNetworkScopePreservingFiles(
    IosTransferScope scope,
  ) async {
    cancelled.add(scope);
    return IosTransferSummary.fromJson(summary());
  }
}

class _Coordinator extends IosTransferImportCoordinator {
  _Coordinator(IosTransferTransport native)
    : super(
        native: native,
        store: () =>
            throw StateError('No storage access in this boundary test'),
        readMedia: (
          lease, {
          required isCurrent,
          required validateOwnership,
          cancelled,
        }) => throw StateError('No media access'),
      );
  @override
  Future<void> reconcileImportsForMutation(
    IosTransferScope? scope, {
    bool afterNetworkRetirement = false,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'disabled product upload never opens source access or captures new consent',
    () async {
      final native = _Native();
      var opened = false;
      final session = IosTransferSession(
        native: native,
        coordinator: _Coordinator(native),
        uploadAdmission: () async {
          opened = true;
          throw StateError('Must not open');
        },
      );
      await expectLater(
        session.enqueueUploadSong(
          songId: 42,
          expectedPairing: const IosTransferPairing(
            scope: IosTransferScope(
              desktopId: 'desktop',
              origin: 'https://desktop.example',
            ),
          ),
          prepared: (_) => fail('Unqualified product intent'),
        ),
        throwsStateError,
      );
      expect(opened, false);
      await session.dispose();
    },
  );
  test('library clear drains a pairing containing only uploads', () async {
    final native = _Native();
    final session = IosTransferSession(
      native: native,
      coordinator: _Coordinator(native),
    );
    await session.reconcileBeforeLibraryClear();
    expect(
      native.cancelled.single.desktopId,
      (intentDocument()['identity'] as Map)['desktopID'],
    );
    await session.dispose();
  });
}
