import 'dart:async';
import 'dart:convert';

import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Observe outbound client identity while forwarding every call to real Swift.
/// This does not replace the messenger, native handler or its response.
class _ObservedTransferChannel extends MethodChannel {
  _ObservedTransferChannel() : super('lokal/transfers');
  String? observedClient;
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    if (method == 'observe' && arguments is Uint8List) {
      observedClient =
          (jsonDecode(utf8.decode(arguments)) as Map)['clientID'] as String;
    }
    return super.invokeMethod<T>(method, arguments);
  }
}

/// Actual registered Swift channel in the isolated CI app. No paired desktop,
/// user files or credentials are required for protocol/observation acceptance.
Future<void> probeIosTransferTransport(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final channel = _ObservedTransferChannel();
  final old = IosTransferTransport(channel: channel);
  final current = IosTransferTransport(channel: channel);
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
    final retiredClient = channel.observedClient;
    currentListener = current.changes.listen((_) => currentEvents++);
    await tester.pump(const Duration(milliseconds: 100));
    final activeClient = channel.observedClient!;
    expect(retiredClient, isNot(activeClient));
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
      payload = {'clientID': activeClient, ...payload};
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
    await rejectedControl('claimImport', {
      'id': missingJobId,
      'revision': 1,
      'reconcileOnly': false,
      'clientID': retiredClient!,
    }, 'TRANSFER_CHANGED');
    await rejectedControl('claimImportCleanup', {
      'id': missingJobId,
      'revision': 1,
      'sourcePath': '/caller/injected.wav',
    }, 'INVALID_TRANSFER_REQUEST');
    // Three fields must reach the real runtime, rather than fail decoding a
    // missing writer-only flag. No real transfer/library data is created.
    await rejectedControl('claimImportCleanup', {
      'id': missingJobId,
      'revision': 1,
    }, 'TRANSFER_CHANGED');
    await rejectedControl('claimImport', {
      'id': missingJobId,
      'revision': 1,
      'reconcileOnly': false,
    }, 'TRANSFER_MISSING');
    for (final method in [
      'validateImport',
      'validateImportReconciliation',
      'validateImportCleanup',
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
      'retired_client_cannot_inherit_replacement_import_owner': true,
      'cleanup_claim_three_field_codec_reaches_runtime': true,
      'cleanup_claim_injection_rejected': true,
      'ordinary_claim_reaches_missing_job_after_cleanup_refusal': true,
      'background_daemon_or_library_import_acceptance': false,
    };
  } finally {
    await oldListener?.cancel();
    await currentListener?.cancel();
    await old.dispose();
    await current.dispose();
  }
}
