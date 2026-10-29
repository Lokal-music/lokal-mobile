import 'dart:async';
import 'dart:convert';

import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Actual registered Swift channel in the isolated CI app. No paired desktop,
/// user files or credentials are required for protocol/observation acceptance.
Future<void> probeIosTransferTransport(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final old = IosTransferTransport();
  final current = IosTransferTransport();
  StreamSubscription<void>? oldListener, currentListener;
  var oldEvents = 0, currentEvents = 0;
  try {
    final capability = await current.capability().timeout(
      const Duration(seconds: 10),
    );
    expect(capability.available, true);
    expect(capability.download, true);
    final before = await current.summary().timeout(const Duration(seconds: 10));
    await expectLater(
      const MethodChannel('lokal/transfers').invokeMethod<Object?>(
        'enqueue',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode([
              {
                'phase': 'complete',
                'headers': {'authorization': 'synthetic-forbidden-token'},
              },
            ]),
          ),
        ),
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'INVALID_TRANSFER_REQUEST',
        ),
      ),
    );
    final after = await current.summary().timeout(const Duration(seconds: 10));
    expect(after.generation, before.generation);
    expect(after.total, before.total);
    expect(
      (await current.page().timeout(const Duration(seconds: 10))).length,
      lessThanOrEqualTo(100),
    );

    oldListener = old.changes.listen((_) => oldEvents++);
    await tester.pump(const Duration(milliseconds: 100));
    currentListener = current.changes.listen((_) => currentEvents++);
    await tester.pump(const Duration(milliseconds: 100));
    final beforeImportGuards = await current.recover().timeout(
      const Duration(seconds: 10),
    );
    const missingJobId = '62dcde21-562f-4417-b660-cd1385ea44ca';
    const missingLeaseId = '72dcde21-562f-4417-b660-cd1385ea44ca';
    Future<void> rejectedControl(
      String method,
      Map<String, Object> payload,
      String code,
    ) async {
      await expectLater(
        const MethodChannel('lokal/transfers')
            .invokeMethod<Object?>(
              method,
              Uint8List.fromList(utf8.encode(jsonEncode(payload))),
            )
            .timeout(const Duration(seconds: 10)),
        throwsA(
          isA<PlatformException>().having((error) => error.code, 'code', code),
        ),
      );
    }

    await rejectedControl('claimImport', {
      'id': missingJobId,
      'revision': 1,
      'reconcileOnly': false,
      'sourcePath': '/caller/injected.wav',
    }, 'INVALID_TRANSFER_REQUEST');
    await rejectedControl('claimImport', {
      'id': missingJobId,
      'revision': 1,
      'reconcileOnly': false,
    }, 'TRANSFER_MISSING');
    for (final method in [
      'validateImport',
      'validateImportReconciliation',
      'releaseImport',
    ]) {
      await rejectedControl(method, {
        'id': missingJobId,
        'revision': 1,
        'leaseID': missingLeaseId,
      }, 'TRANSFER_CHANGED');
    }
    final afterImportGuards = await current.summary().timeout(
      const Duration(seconds: 10),
    );
    expect(afterImportGuards.generation, beforeImportGuards.generation);
    expect(afterImportGuards.total, beforeImportGuards.total);
    await oldListener.cancel();
    oldListener = null;
    await old.dispose();
    final retiredEvents = oldEvents, currentBaseline = currentEvents;
    await current.recover().timeout(const Duration(seconds: 10));
    for (var i = 0; i < 40 && currentEvents == currentBaseline; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(oldEvents, retiredEvents);
    expect(currentEvents, greaterThan(currentBaseline));
    binding.reportData!['native_transfer_protocol'] = {
      'scope': 'Actual Swift/Flutter byte protocol and foreground observation',
      'available': capability.available,
      'download_api': capability.download,
      'library_import_api': capability.libraryImport,
      'upload_api': capability.upload,
      'invalid_intent_rejected_without_commit': true,
      'replacement_observer_survives_old_disposal': true,
      'private_import_control_rejects_injection': true,
      'unclaimed_import_guard_rejected_without_commit': true,
      'background_daemon_or_library_import_acceptance': false,
    };
  } finally {
    await oldListener?.cancel();
    await currentListener?.cancel();
    await old.dispose();
    await current.dispose();
  }
}
