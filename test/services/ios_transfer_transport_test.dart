import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> intentDocument() => Map<String, dynamic>.from(
  (jsonDecode(
        File('test/fixtures/ios_transfer_intents_v1.json').readAsStringSync(),
      ) as List).single
      as Map,
);

Uint8List encoded(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
Object? request(MethodCall call) =>
    jsonDecode(utf8.decode(call.arguments as Uint8List));

Map<String, Object?> summary() => {
  'generation': 1,
  'total': 1,
  'counts': {'queued': 1},
  'progress': [],
  'pauses': [],
  'persistenceFailed': false,
};

Map<String, Object?> job({String phase = 'queued', int revision = 1}) => {
  ...intentDocument(),
  'direction': 'download',
  'revision': revision,
  'updatedMs': 2000,
  'phase': phase,
  if (phase == 'transferring' || phase == 'received') 'taskID': 8,
  if (phase == 'staged') ...{'receivedBytes': 12, 'receivedSHA256': 'a' * 64},
};

Future<void> incomingChange(MethodChannel channel) {
  final done = Completer<void>();
  ServicesBinding.instance.channelBuffers.push(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(const MethodCall('changed')),
    (_) => done.complete(),
  );
  return done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('Dart user intent round-trips the exact shared Swift fixture', () {
    final json = intentDocument();
    final intent = IosTransferIntent.fromJson(json);
    intent.validate(submission: true);
    expect(intent.toJson(), json);
    expect(intent.identity.localSongId, '42');
    expect(intent.identity.localServerId, 3);
    expect(intent.identity.desktopUserId, 'contract-user');
    expect(intent.metadata.title, '曲 — Café');
    expect(intent.metadata.sampleRate, 96000);
    expect(intent.metadata.bitDepth, 24);
    expect(intent.metadata.albumArtist, 'Fixture album artist');
    expect(intent.metadata.trackNumber, 2);
  });

  test(
    'credential/path payloads and malformed public identity are rejected',
    () {
      for (final change in [
        {
          'headers': {'authorization': 'synthetic-forbidden-token'},
        },
        {'destinationPath': '/outside/song.flac'},
        {'phase': 'complete'},
      ]) {
        expect(
          () => IosTransferIntent.fromJson({...intentDocument(), ...change}),
          throwsFormatException,
        );
      }
      final json = intentDocument();
      final identity = Map<String, dynamic>.from(json['identity'] as Map);
      expect(
        () => IosTransferIdentity.fromJson({
          ...identity,
          'token': 'synthetic-token',
        }),
        throwsFormatException,
      );
      expect(
        () => IosTransferIdentity.fromJson({
          ...identity,
          'origin': 'https://user:secret@pc.invalid',
        }),
        throwsFormatException,
      );
      expect(
        () => IosTransferIdentity.fromJson({
          ...identity,
          'sourceID': 'https://pc/file?token=secret',
        }),
        throwsFormatException,
      );
      final legacy = IosTransferIdentity.fromJson({
        ...identity,
        'localServerID': null,
      });
      expect(() => legacy.validate(submission: true), throwsFormatException);
    },
  );

  test('network retention cannot pretend to be verified importable media', () {
    expect(
      IosTransferJob.fromJson(job(phase: 'received')).phase,
      IosTransferPhase.received,
    );
    expect(
      () => IosTransferJob.fromJson({
        ...job(),
        'receivedBytes': 12,
        'receivedSHA256': 'a' * 64,
      }),
      throwsFormatException,
    );
    expect(
      () => IosTransferJob.fromJson({
        ...job(phase: 'staged'),
        'receivedSHA256': null,
      }),
      throwsFormatException,
    );
    expect(
      () => IosTransferJob.fromJson({
        ...job(phase: 'staged'),
        'receivedSHA256': 'b' * 64,
      }),
      throwsFormatException,
    );
    expect(
      () => IosTransferJob.fromJson({...job(), 'revision': false}),
      throwsFormatException,
    );
    expect(
      IosTransferJob.fromJson(job(phase: 'staged')).receivedSha256,
      'a' * 64,
    );
    expect(
      () => IosTransferSummary.fromJson({...summary(), 'total': 2}),
      throwsFormatException,
    );
  });

  test(
    'partial native capability cannot enable the product copy adapter',
    () async {
      const channel = MethodChannel('test/ios-transfer-capability');
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => encoded({
          'available': true,
          'protocolVersion': 1,
          'download': true,
          'libraryImport': false,
          'upload': false,
          'maximumIntents': 10000,
          'maximumIntentBytes': 16 * 1024 * 1024,
        }),
      );
      final transport = IosTransferTransport(channel: channel, supported: true);
      addTearDown(transport.dispose);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final capability = await transport.capability();
      expect(capability.available, isTrue);
      expect(capability.download, isTrue);
      expect(capability.canCopyToLibrary, isFalse);
    },
  );

  test(
    'frozen submission, bounded pages and revision controls use typed bytes',
    () async {
      const channel = MethodChannel('test/ios-transfer-calls');
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'enqueue':
            expect(request(call), [intentDocument()]);
            return encoded(summary());
          case 'page':
            expect(request(call), {'offset': 0, 'limit': 100});
            return encoded([job()]);
          case 'cancel':
            expect(request(call), {
              'id': intentDocument()['id'],
              'revision': 1,
            });
            return encoded(job(phase: 'cancelled', revision: 2));
          default:
            throw MissingPluginException();
        }
      });
      final transport = IosTransferTransport(channel: channel, supported: true);
      addTearDown(transport.dispose);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(
        (await transport.enqueue([
          IosTransferIntent.fromJson(intentDocument()),
        ])).total,
        1,
      );
      final pending = (await transport.page()).single;
      expect((await transport.cancel(pending)).revision, 2);
      expect(calls.map((call) => call.method), ['enqueue', 'page', 'cancel']);
      await expectLater(transport.page(limit: 101), throwsFormatException);
      await expectLater(
        transport.enqueue([pending.intent, pending.intent]),
        throwsFormatException,
      );
      expect(calls, hasLength(3));
    },
  );

  test(
    'submission freezes the original plan before asynchronous encoding',
    () async {
      const channel = MethodChannel('test/ios-transfer-frozen-plan');
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'enqueue');
        expect(request(call), [intentDocument()]);
        return encoded(summary());
      });
      final transport = IosTransferTransport(channel: channel, supported: true);
      addTearDown(transport.dispose);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final selected = [IosTransferIntent.fromJson(intentDocument())];
      final submitting = transport.enqueue(selected);
      selected.clear();
      expect((await submitting).total, 1);
    },
  );

  test('malformed native JSON never appears in a decoder error', () async {
    const channel = MethodChannel('test/ios-transfer-invalid-json');
    messenger.setMockMethodCallHandler(
      channel,
      (_) async =>
          Uint8List.fromList(utf8.encode('{synthetic-sensitive-response')),
    );
    final transport = IosTransferTransport(channel: channel, supported: true);
    addTearDown(transport.dispose);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    try {
      await transport.summary();
      fail('Malformed native response was accepted.');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains('synthetic-sensitive-response')));
    }
  });

  test(
    'disposing an old listener cannot stop or detach its replacement',
    () async {
      const channel = MethodChannel('test/ios-transfer-observation');
      String? nativeOwner;
      final firstObserve = Completer<void>();
      final observed = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final id = (request(call) as Map)['clientID'] as String;
        if (call.method == 'observe') {
          nativeOwner = id;
          observed.add(id);
          if (observed.length == 1) await firstObserve.future;
        } else if (call.method == 'stopObserving' && nativeOwner == id) {
          nativeOwner = null;
        }
        return null;
      });
      final old = IosTransferTransport(channel: channel, supported: true);
      final next = IosTransferTransport(channel: channel, supported: true);
      var oldEvents = 0, nextEvents = 0;
      final oldListener = old.changes.listen((_) => oldEvents++);
      await Future<void>.delayed(Duration.zero);
      final nextListener = next.changes.listen((_) => nextEvents++);
      try {
        await Future<void>.delayed(Duration.zero);
        expect(observed, hasLength(2));
        expect(observed[0], isNot(observed[1]));
        await oldListener.cancel();
        await old.dispose();
        firstObserve.complete();
        await Future<void>.delayed(Duration.zero);
        expect(nativeOwner, observed[1]);
        await incomingChange(channel);
        expect(oldEvents, 0);
        expect(nextEvents, 1);
      } finally {
        if (!firstObserve.isCompleted) firstObserve.complete();
        await oldListener.cancel();
        await nextListener.cancel();
        await old.dispose();
        await next.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
}
