import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/models/ios_transfer_import.dart';
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

const fixtureClientId = '12dcde21-562f-4417-b660-cd1385ea44ca';
Map<String, Object?> importLease({
  bool reconcileOnly = false,
  String clientId = fixtureClientId,
}) {
  final document = job(phase: 'staged');
  document['phase'] = 'validating';
  return {
    'job': document,
    'leaseID': 'a7d96b93-6526-4f1f-a1af-688ffb5c799d',
    'clientID': clientId,
    'reconcileOnly': reconcileOnly,
    'targetRelativePath': 'Desktop Copies/Fixture - ${document['id']}-r1.flac',
    if (!reconcileOnly)
      'sourcePath': '/private/fixture/${document['id']}-r1.download',
  };
}

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

  test(
    'native import leases bind verified revision, target and recovery role',
    () {
      final writer = IosTransferImportLease.fromJson(importLease());
      expect(writer.job.phase, IosTransferPhase.validating);
      expect(writer.sourcePath, startsWith('/private/'));
      final historical = IosTransferImportLease.fromJson(
        importLease(reconcileOnly: true),
      );
      expect(historical.sourcePath, isNull);
      for (final patch in [
        {'reconcileOnly': 1},
        {'leaseID': 'caller'},
        {'leaseID': 'A7D96B93-6526-4F1F-A1AF-688FFB5C799D'},
        {'clientID': null},
        {'clientID': 'caller'},
        {'clientID': fixtureClientId.toUpperCase()},
        {'targetRelativePath': 'Desktop Copies/other.flac'},
        {'sourcePath': 'file:///private/fixture.wav'},
        {'sourcePath': '/private/../outside.wav'},
        {'sourcePath': '/private/fixture\u0000.wav'},
        {'sourcePath': 7},
        {'headers': <String, Object>{}},
        {'reconcileOnly': true, 'sourcePath': '/private/fixture.wav'},
        {'job': job(phase: 'staged')},
      ]) {
        expect(
          () => IosTransferImportLease.fromJson({...importLease(), ...patch}),
          throwsFormatException,
        );
      }
    },
  );

  test('scoped retirement binds to the observed client and contains only public pairing identity', () async {
    const channel = MethodChannel('test/ios-retire-network-scope');
    final ready = Completer<String>();
    const scope = IosTransferScope(
      desktopId: 'fixture-pc',
      origin: 'https://music.example.test:8443',
      pairingId: 'a7d96b93-6526-4f1f-a1af-688ffb5c799d',
    );
    var retired = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        final owner = (request(call) as Map)['clientID'] as String;
        ready.complete(owner);
        return null;
      }
      if (call.method == 'stopObserving') return null;
      expect(call.method, anyOf('retireNetworkScope', 'cancelNetworkScopePreservingFiles'));
      expect(request(call), {
        'clientID': await ready.future,
        'scope': scope.toJson(),
      });
      retired++;
      return encoded({
        ...summary(),
        'counts': {'cancelled': 1},
        'pauses': [
          {'scope': scope.toJson(), 'reason': 'pairingChanged'},
        ],
      });
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    try {
      await expectLater(transport.retireNetworkScope(scope), throwsStateError);
      final listener = transport.changes.listen((_) {});
      try {
        await ready.future;
        final result = await transport.retireNetworkScope(scope);
        expect(result.total, 1);
        expect(result.pauses.single.scope.pairingId, scope.pairingId);
        expect(retired, 1);
        await transport.cancelNetworkScopePreservingFiles(scope);
        expect(retired, 2);
        await expectLater(
          transport.retireNetworkScope(const IosTransferScope(
            desktopId: 'fixture-pc',
            origin: 'https://credentials:secret@music.example.test',
          )),
          throwsFormatException,
        );
        expect(retired, 2);
      } finally {
        await listener.cancel();
      }
    } finally {
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('import waits for root observation and sends no caller paths or account credentials', () async {
    const channel = MethodChannel('test/ios-import-root');
    final observing = Completer<void>();
    late String clientId;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'observe') {
        clientId = (request(call) as Map)['clientID'] as String;
        await observing.future;
        return null;
      }
      if (call.method == 'stopObserving') return null;
      if (call.method == 'claimImport') {
        expect(request(call), {
          'id': job()['id'],
          'revision': 1,
          'reconcileOnly': false,
          'clientID': clientId,
        });
        return encoded(importLease(clientId: clientId));
      }
      expect(
        request(call),
        IosTransferImportLease.fromJson(importLease(clientId: clientId))
            .control,
      );
      return encoded(true);
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    final subscription = transport.changes.listen((_) {});
    try {
      final pending = transport.claimImport(
        IosTransferJob.fromJson(job(phase: 'staged')),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((call) => call.method), ['observe']);
      observing.complete();
      final lease = await pending;
      await transport.validateImport(lease);
      await transport.validateImport(lease, requiresWrite: false);
      await transport.releaseImport(lease);
      expect(calls.map((call) => call.method), [
        'observe',
        'claimImport',
        'validateImport',
        'validateImportReconciliation',
        'releaseImport',
      ]);
    } finally {
      if (!observing.isCompleted) observing.complete();
      await subscription.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test(
    'no-listener and replaced clients cannot acquire or use an import lease',
    () async {
      const channel = MethodChannel('test/ios-import-replacement');
      final claimReply = Completer<void>();
      final claimEntered = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'claimImport') {
          claimEntered.complete();
          await claimReply.future;
          return encoded(
            importLease(clientId: (request(call) as Map)['clientID'] as String),
          );
        }
        return null;
      });
      final old = IosTransferTransport(channel: channel, supported: true);
      final next = IosTransferTransport(channel: channel, supported: true);
      final staged = IosTransferJob.fromJson(job(phase: 'staged'));
      await expectLater(old.claimImport(staged), throwsStateError);
      expect(calls, isEmpty);
      final oldListener = old.changes.listen((_) {});
      StreamSubscription<void>? nextListener;
      try {
        final pending = old.claimImport(staged);
        final rejected = expectLater(pending, throwsStateError);
        await claimEntered.future;
        nextListener = next.changes.listen((_) {});
        await Future<void>.delayed(Duration.zero);
        claimReply.complete();
        await rejected;
        final lease = IosTransferImportLease.fromJson(importLease());
        await expectLater(old.validateImport(lease), throwsStateError);
        await expectLater(old.releaseImport(lease), throwsStateError);
        expect(calls, isNot(contains('validateImport')));
        expect(calls, isNot(contains('releaseImport')));
      } finally {
        if (!claimReply.isCompleted) claimReply.complete();
        await oldListener.cancel();
        await nextListener?.cancel();
        await old.dispose();
        await next.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  test(
    'import rejects changed frozen intent and recovery role in native replies',
    () async {
      const channel = MethodChannel('test/ios-import-frozen-intent');
      Map<String, Object?> response = importLease();
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'claimImport'
            ? encoded({
                ...response,
                'clientID': (request(call) as Map)['clientID'],
              })
            : null,
      );
      final transport = IosTransferTransport(channel: channel, supported: true);
      final subscription = transport.changes.listen((_) {});
      try {
        final staged = IosTransferJob.fromJson(job(phase: 'staged'));
        final altered = importLease();
        final alteredJob = Map<String, Object?>.from(altered['job'] as Map);
        final metadata = Map<String, Object?>.from(
          alteredJob['metadata'] as Map,
        );
        alteredJob['metadata'] = {
          ...metadata,
          'title': 'Different frozen recording',
        };
        response = {...altered, 'job': alteredJob};
        await expectLater(transport.claimImport(staged), throwsFormatException);
        response = importLease();
        await expectLater(
          transport.claimImport(staged, reconcileOnly: true),
          throwsFormatException,
        );
        final noDeclaredProof = job(phase: 'staged')
          ..remove('expectedBytes')
          ..remove('expectedSHA256');
        final nativeChangedProof = Map<String, Object?>.from(noDeclaredProof)
          ..['phase'] = 'validating'
          ..['receivedBytes'] = 13
          ..['receivedSHA256'] = 'b' * 64;
        response = {...importLease(), 'job': nativeChangedProof};
        await expectLater(
          transport.claimImport(IosTransferJob.fromJson(noDeclaredProof)),
          throwsFormatException,
        );
      } finally {
        await subscription.cancel();
        await transport.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  test('read-only reconciliation cannot call writer guard; native false acknowledgements fail', () async {
    const channel = MethodChannel('test/ios-import-readonly');
    final calls = <String>[];
    final observing = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'observe') {
        observing.complete((request(call) as Map)['clientID'] as String);
        return null;
      }
      if (call.method == 'stopObserving') {
        return null;
      }
      return encoded(false);
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    final subscription = transport.changes.listen((_) {});
    try {
      final historical = IosTransferImportLease.fromJson(
        importLease(reconcileOnly: true, clientId: await observing.future),
      );
      await expectLater(transport.validateImport(historical), throwsStateError);
      expect(calls, isNot(contains('validateImport')));
      await expectLater(
        transport.validateImport(historical, requiresWrite: false),
        throwsFormatException,
      );
      await expectLater(
        transport.releaseImport(historical),
        throwsFormatException,
      );
    } finally {
      await subscription.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('foreign-client replies and imported leases never inherit the active client', () async {
    const channel = MethodChannel('test/ios-import-client-binding');
    final calls = <String>[];
    late String clientId;
    var foreignReply = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'observe') {
        clientId = (request(call) as Map)['clientID'] as String;
      } else if (call.method == 'claimImport') {
        return encoded(
          importLease(clientId: foreignReply ? fixtureClientId : clientId),
        );
      }
      return null;
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    final subscription = transport.changes.listen((_) {});
    try {
      final staged = IosTransferJob.fromJson(job(phase: 'staged'));
      await expectLater(transport.claimImport(staged), throwsStateError);
      foreignReply = false;
      final current = await transport.claimImport(staged);
      expect(current.clientId, clientId);
      final foreign = IosTransferImportLease.fromJson(importLease());
      final callsBefore = calls.length;
      await expectLater(transport.validateImport(foreign), throwsStateError);
      await expectLater(transport.releaseImport(foreign), throwsStateError);
      expect(calls.length, callsBefore);
    } finally {
      await subscription.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

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
      String? client;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'observe') {
          client = (request(call) as Map)['clientID'] as String;
          return null;
        }
        if (call.method == 'stopObserving') return null;
        calls.add(call);
        switch (call.method) {
          case 'enqueue':
            expect(request(call), {
              'clientID': client,
              'intents': [intentDocument()],
            });
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
      final observation = transport.changes.listen((_) {});
      addTearDown(observation.cancel);
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
      String? client;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'observe') {
          client = (request(call) as Map)['clientID'] as String;
          return null;
        }
        if (call.method == 'stopObserving') return null;
        expect(call.method, 'enqueue');
        expect(request(call), {
          'clientID': client,
          'intents': [intentDocument()],
        });
        return encoded(summary());
      });
      final transport = IosTransferTransport(channel: channel, supported: true);
      final observation = transport.changes.listen((_) {});
      addTearDown(observation.cancel);
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
