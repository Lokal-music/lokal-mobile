import 'dart:async';

import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_transport_test.dart' show encoded, request, intentDocument;

Map<String, Object?> upload({String phase = 'interrupted'}) => {
  ...intentDocument(),
  'direction': 'upload',
  'revision': 1,
  'updatedMs': 2000,
  'phase': phase,
  if (phase == 'interrupted') 'lastFailure': 'network',
  if (phase == 'complete') 'resultOriginalID': 'matched-original',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'upload controls wait for root observation and bind the current client',
    () async {
      const channel = MethodChannel('test/upload-recovery-owned');
      final observed = Completer<String>(), ready = Completer<void>();
      final calls = <String>[];
      Object? response = upload(phase: 'complete');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'observe') {
          observed.complete((request(call) as Map)['clientID'] as String);
          await ready.future;
          return null;
        }
        if (call.method == 'matchUploadedOriginal' ||
            call.method == 'cleanupUploadBody') {
          expect(request(call), {
            'id': upload()['id'],
            'revision': 1,
            'clientID': await observed.future,
          });
          return encoded(call.method == 'cleanupUploadBody' ? true : response);
        }
        return null;
      });
      final transport = IosTransferTransport(channel: channel, supported: true);
      final subscription = transport.changes.listen((_) {});
      try {
        await observed.future;
        final pending = transport.matchUploadedOriginal(
          IosTransferJob.fromJson(upload()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(calls, ['observe']);
        ready.complete();
        final result = await pending;
        expect(result?.resultOriginalId, 'matched-original');
        response = null;
        expect(
          await transport.matchUploadedOriginal(
            IosTransferJob.fromJson(upload()),
          ),
          isNull,
        );
        await transport.cleanupUploadBody(result!);
        final before = calls.length;
        await expectLater(
          transport.cleanupUploadBody(IosTransferJob.fromJson(upload())),
          throwsFormatException,
        );
        expect(calls.length, before);
      } finally {
        if (!ready.isCompleted) ready.complete();
        await subscription.cancel();
        await transport.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  test(
    'reconciliation refuses changed identity, revision, intent and receipt',
    () async {
      const channel = MethodChannel('test/upload-recovery-frozen');
      final observed = Completer<void>();
      Object? response;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'observe') observed.complete();
        return call.method == 'matchUploadedOriginal' ||
                call.method == 'cleanupUploadBody'
            ? encoded(response)
            : null;
      });
      final transport = IosTransferTransport(channel: channel, supported: true);
      final subscription = transport.changes.listen((_) {});
      try {
        await observed.future;
        final original = IosTransferJob.fromJson(upload());
        for (final patch in [
          {'revision': 2},
          {'expectedBytes': 13},
          {'expectedSHA256': 'b' * 64},
          {'phase': 'interrupted', 'resultOriginalID': null},
          {
            'metadata': {
              ...intentDocument()['metadata'] as Map,
              'title': 'Changed recording',
            },
          },
        ]) {
          response = {...upload(phase: 'complete'), ...patch};
          await expectLater(
            transport.matchUploadedOriginal(original),
            throwsFormatException,
          );
        }
        response = {
          ...upload(phase: 'complete'),
          'resultOriginalID': 'different-original',
        };
        await expectLater(
          transport.matchUploadedOriginal(
            IosTransferJob.fromJson(upload(phase: 'complete')),
          ),
          throwsFormatException,
        );
        response = 1;
        await expectLater(
          transport.cleanupUploadBody(
            IosTransferJob.fromJson(upload(phase: 'complete')),
          ),
          throwsFormatException,
        );
      } finally {
        await subscription.cancel();
        await transport.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  test(
    'mutation retires delayed matches and blocks subsequent upload controls',
    () async {
      const channel = MethodChannel('test/upload-recovery-mutation');
      final observed = Completer<void>(), entered = Completer<void>();
      final delayed = Completer<void>();
      var matches = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'observe') observed.complete();
        if (call.method == 'retireSubmissions') return encoded(true);
        if (call.method == 'matchUploadedOriginal') {
          matches++;
          entered.complete();
          await delayed.future;
          return encoded(upload(phase: 'complete'));
        }
        return null;
      });
      final transport = IosTransferTransport(channel: channel, supported: true);
      final subscription = transport.changes.listen((_) {});
      try {
        await observed.future;
        final pending = transport.matchUploadedOriginal(
          IosTransferJob.fromJson(upload()),
        );
        final refused = expectLater(pending, throwsStateError);
        await entered.future;
        await transport.pauseSubmissions();
        delayed.complete();
        await refused;
        await expectLater(
          transport.matchUploadedOriginal(IosTransferJob.fromJson(upload())),
          throwsStateError,
        );
        expect(matches, 1);
      } finally {
        if (!delayed.isCompleted) delayed.complete();
        await subscription.cancel();
        await transport.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
  test('mutation while observation waits prevents the upload RPC', () async {
    const channel = MethodChannel('test/upload-recovery-observation-mutation');
    final observed = Completer<void>(), ready = Completer<void>();
    var matches = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        observed.complete();
        await ready.future;
      }
      if (call.method == 'retireSubmissions') return encoded(true);
      if (call.method == 'matchUploadedOriginal') matches++;
      return null;
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    final subscription = transport.changes.listen((_) {});
    try {
      await observed.future;
      final pending = expectLater(
        transport.matchUploadedOriginal(IosTransferJob.fromJson(upload())),
        throwsStateError,
      );
      final paused = transport.pauseSubmissions();
      ready.complete();
      await paused;
      await pending;
      expect(matches, 0);
    } finally {
      if (!ready.isCompleted) ready.complete();
      await subscription.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
