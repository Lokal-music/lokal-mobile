import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_transport_test.dart' show encoded, request, summary;

final submissionFixture = jsonDecode(
  File('test/fixtures/ios_transfer_submission_v1.json').readAsStringSync(),
) as Map<String, dynamic>;
List<IosTransferIntent> plan() => (submissionFixture['intents'] as List)
    .map(IosTransferIntent.fromJson)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'submission requires a current observed owner before encoding or posting',
    () async {
      const channel = MethodChannel('test/submission-no-owner');
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return encoded(summary());
      });
      final transport = IosTransferTransport(channel: channel, supported: true);
      try {
        await expectLater(transport.enqueue(plan()), throwsStateError);
        expect(calls, 0);
      } finally {
        await transport.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  test('retirement fences a frozen plan waiting for observation and permits explicit fresh consent', () async {
    const channel = MethodChannel('test/submission-before-encoding');
    final entered = Completer<void>(), observationReady = Completer<void>();
    String? client;
    var submissions = 0, fences = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        client = (request(call) as Map)['clientID'] as String;
        entered.complete();
        await observationReady.future;
        return null;
      }
      if (call.method == 'stopObserving') return null;
      if (call.method == 'retireSubmissions') {
        expect(request(call), {'clientID': client});
        fences++;
        return encoded(true);
      }
      expect(call.method, 'enqueue');
      expect(request(call), {...submissionFixture, 'clientID': client});
      submissions++;
      return encoded(summary());
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    final listener = transport.changes.listen((_) {});
    try {
      await entered.future;
      final old = transport.enqueue(plan());
      final refused = expectLater(old, throwsStateError);
      final barrier = transport.pauseSubmissions();
      observationReady.complete();
      await barrier;
      await refused;
      expect(submissions, 0);
      expect(fences, 1);
      await expectLater(transport.enqueue(plan()), throwsStateError);
      transport.resumeSubmissions();
      expect((await transport.enqueue(plan())).total, 1);
      expect(submissions, 1);
    } finally {
      if (!observationReady.isCompleted) observationReady.complete();
      await listener.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test(
    'retirement awaits an in-flight native reply and rejects stale success',
    () async {
      const channel = MethodChannel('test/submission-in-flight');
      final observed = Completer<void>(), entered = Completer<void>();
      final reply = Completer<Uint8List>();
      var first = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'observe') {
          observed.complete();
          return null;
        }
        if (call.method == 'stopObserving') return null;
        if (call.method == 'retireSubmissions') return encoded(true);
        expect(call.method, 'enqueue');
        if (first) {
          first = false;
          entered.complete();
          return reply.future;
        }
        return encoded(summary());
      });
      final transport = IosTransferTransport(channel: channel, supported: true);
      final listener = transport.changes.listen((_) {});
      try {
        await observed.future;
        final old = transport.enqueue(plan());
        final refused = expectLater(old, throwsStateError);
        await entered.future;
        var drained = false;
        final barrier = transport.pauseSubmissions().then((_) {
          drained = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(drained, false);
        reply.complete(encoded(summary()));
        await barrier;
        await refused;
        expect(drained, true);
        transport.resumeSubmissions();
        expect((await transport.enqueue(plan())).total, 1);
      } finally {
        if (!reply.isCompleted) reply.complete(encoded(summary()));
        await listener.cancel();
        await transport.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
}
