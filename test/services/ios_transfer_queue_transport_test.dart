import 'dart:async';

import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_transport_test.dart'
    show encoded, request, intentDocument, summary;

Map<String, Object?> document({
  String direction = 'download',
  String phase = 'interrupted',
  int revision = 1,
}) => {
  ...intentDocument(),
  'direction': direction,
  'phase': phase,
  'revision': revision,
  'updatedMs': 2000,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test('queue controls carry the observed client, verify revision and never retry an upload as a download', () async {
    const channel = MethodChannel('test/queue-owned-controls');
    final observed = Completer<String>();
    final calls = <String>[];
    bool forged = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        observed.complete((request(call) as Map)['clientID'] as String);
        return null;
      }
      if (call.method == 'stopObserving') return null;
      calls.add(call.method);
      expect((request(call) as Map)['clientID'], await observed.future);
      if (call.method == 'queueResumeScope') return encoded(summary());
      final row = document(
        phase: call.method == 'queueCancel' ? 'cancelled' : 'queued',
        revision: 2,
      );
      if (forged) row['revision'] = 7;
      return encoded(row);
    });
    final native = IosTransferTransport(channel: channel, supported: true);
    final listener = native.changes.listen((_) {});
    try {
      await observed.future;
      final job = IosTransferJob.fromJson(document());
      expect(
        (await native.cancelFromQueue(job)).phase,
        IosTransferPhase.cancelled,
      );
      expect((await native.retryDownloadFromQueue(job)).revision, 2);
      await native.resumeFromQueue(job.intent.identity.scope);
      final before = calls.length;
      await expectLater(
        native.retryDownloadFromQueue(
          IosTransferJob.fromJson(document(direction: 'upload')),
        ),
        throwsFormatException,
      );
      expect(calls.length, before);
      forged = true;
      await expectLater(native.cancelFromQueue(job), throwsFormatException);
    } finally {
      await listener.cancel();
      await native.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  for (final operation in ['cancel', 'retry', 'resume']) {
    test(
      'mutation during observation wait prevents stale queue $operation dispatch',
      () async {
        final channel = MethodChannel('test/queue-retired-$operation');
        final observed = Completer<void>(), ready = Completer<void>();
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'observe') {
            observed.complete();
            await ready.future;
            return null;
          }
          return encoded(true);
        });
        final native = IosTransferTransport(channel: channel, supported: true);
        final listener = native.changes.listen((_) {});
        try {
          await observed.future;
          final job = IosTransferJob.fromJson(document());
          final Future<Object?> pending = switch (operation) {
            'cancel' => native.cancelFromQueue(job),
            'retry' => native.retryDownloadFromQueue(job),
            _ => native.resumeFromQueue(job.intent.identity.scope),
          };
          final rejected = expectLater(pending, throwsStateError);
          final fence = native.pauseSubmissions();
          ready.complete();
          await rejected;
          await fence;
          expect(calls.where((name) => name.startsWith('queue')), isEmpty);
        } finally {
          if (!ready.isCompleted) ready.complete();
          await listener.cancel();
          await native.dispose();
          messenger.setMockMethodCallHandler(channel, null);
        }
      },
    );
  }
}
