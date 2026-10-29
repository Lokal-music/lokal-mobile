import 'dart:async';

import 'package:flick/models/ios_transfer_import.dart';
import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_transport_test.dart' show encoded, importLease, request;

Map<String, Object?> publicationDocument() {
  final lease = importLease();
  return {
    'job': {
      ...Map<String, Object?>.from(lease['job'] as Map),
      'phase': 'importing',
    },
    'songID': 42,
    'receipt': {
      'relativePath': lease['targetRelativePath'],
      'bytes': 12,
      'sha256': 'a' * 64,
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('native publication cannot claim complete, change identity or fabricate byte proof', () {
    final lease = IosTransferImportLease.fromJson(importLease());
    final raw = publicationDocument();
    final published = IosTransferPublishedImport.fromJson(raw);
    published.validateFor(lease, songId: 42);
    expect(published.job.phase, IosTransferPhase.importing);
    for (final patch in [
      {'songID': 0},
      {'songID': true},
      {'songID': 43},
      {'sourcePath': '/caller/audio.wav'},
      {
        'job': {...raw['job'] as Map, 'phase': 'complete'},
      },
      {
        'job': {...raw['job'] as Map, 'phase': 'validating'},
      },
      {
        'receipt': {...raw['receipt'] as Map, 'bytes': 13},
      },
      {
        'receipt': {...raw['receipt'] as Map, 'sha256': 'b' * 64},
      },
      {
        'receipt': {...raw['receipt'] as Map, 'relativePath': '../outside.wav'},
      },
    ]) {
      expect(
        () => IosTransferPublishedImport.fromJson({...raw, ...patch}),
        throwsFormatException,
      );
    }
    expect(
      () => published.validateFor(lease, songId: 43),
      throwsFormatException,
    );
  });

  test('publication waits for observation and sends only lease plus prepared Song ID', () async {
    const channel = MethodChannel('test/ios-publication-root');
    final ready = Completer<void>();
    final client = Completer<String>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'observe') {
        client.complete((request(call) as Map)['clientID'] as String);
        await ready.future;
        return null;
      }
      if (call.method == 'stopObserving') return null;
      expect(call.method, 'publishImport');
      final lease = IosTransferImportLease.fromJson(
        importLease(clientId: await client.future),
      );
      expect(request(call), {...lease.control, 'songID': 42});
      return encoded(publicationDocument());
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    final subscription = transport.changes.listen((_) {});
    try {
      final lease = IosTransferImportLease.fromJson(
        importLease(clientId: await client.future),
      );
      final pending = transport.publishImport(lease, songId: 42);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['observe']);
      ready.complete();
      final result = await pending;
      expect(result.songId, 42);
      expect(result.job.phase, IosTransferPhase.importing);
      expect(result.receipt.relativePath, lease.target.relativePath);
      expect(calls, ['observe', 'publishImport']);
      final before = calls.length;
      await expectLater(
        transport.publishImport(lease, songId: 0),
        throwsStateError,
      );
      final historical = IosTransferImportLease.fromJson(
        importLease(clientId: lease.clientId, reconcileOnly: true),
      );
      await expectLater(
        transport.publishImport(historical, songId: 42),
        throwsStateError,
      );
      expect(calls.length, before);
    } finally {
      if (!ready.isCompleted) ready.complete();
      await subscription.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('publication checks frozen metadata and exact target in native replies', () async {
    const channel = MethodChannel('test/ios-publication-frozen');
    final client = Completer<String>();
    var response = publicationDocument();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        client.complete((request(call) as Map)['clientID'] as String);
      }
      return call.method == 'publishImport' ? encoded(response) : null;
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    final subscription = transport.changes.listen((_) {});
    try {
      final lease = IosTransferImportLease.fromJson(
        importLease(clientId: await client.future),
      );
      final raw = publicationDocument();
      final rawJob = Map<String, Object?>.from(raw['job'] as Map);
      response = {
        ...raw,
        'job': {
          ...rawJob,
          'metadata': {
            ...rawJob['metadata'] as Map,
            'title': 'A different recording',
          },
        },
      };
      await expectLater(
        transport.publishImport(lease, songId: 42),
        throwsFormatException,
      );
      response = {
        ...raw,
        'receipt': {
          ...raw['receipt'] as Map,
          'relativePath':
              'Desktop Copies/Another name - ${lease.job.id}-r1.flac',
        },
      };
      await expectLater(
        transport.publishImport(lease, songId: 42),
        throwsFormatException,
      );
      // Even internally consistent changed byte proof cannot replace the lease.
      final undeclared = {
        ...rawJob,
        'expectedBytes': null,
        'expectedSHA256': null,
      };
      final originalLease = IosTransferImportLease.fromJson({
        ...importLease(clientId: lease.clientId),
        'job': {...undeclared, 'phase': 'validating'},
      });
      response = {
        ...raw,
        'job': {...undeclared, 'receivedBytes': 13, 'receivedSHA256': 'b' * 64},
        'receipt': {...raw['receipt'] as Map, 'bytes': 13, 'sha256': 'b' * 64},
      };
      await expectLater(
        transport.publishImport(originalLease, songId: 42),
        throwsFormatException,
      );
    } finally {
      await subscription.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('a replaced client rejects a delayed publication response and foreign leases', () async {
    const channel = MethodChannel('test/ios-publication-replacement');
    final clients = <String>[];
    final entered = Completer<void>(), response = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        clients.add((request(call) as Map)['clientID'] as String);
      }
      if (call.method == 'publishImport') {
        entered.complete();
        await response.future;
        return encoded(publicationDocument());
      }
      return null;
    });
    final old = IosTransferTransport(channel: channel, supported: true);
    final next = IosTransferTransport(channel: channel, supported: true);
    final oldSubscription = old.changes.listen((_) {});
    StreamSubscription<void>? nextSubscription;
    try {
      await Future<void>.delayed(Duration.zero);
      final lease = IosTransferImportLease.fromJson(
        importLease(clientId: clients.single),
      );
      final pending = old.publishImport(lease, songId: 42);
      final rejected = expectLater(pending, throwsStateError);
      await entered.future;
      nextSubscription = next.changes.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      response.complete();
      await rejected;
      await expectLater(
        next.publishImport(lease, songId: 42),
        throwsStateError,
      );
    } finally {
      if (!response.isCompleted) response.complete();
      await oldSubscription.cancel();
      await nextSubscription?.cancel();
      await old.dispose();
      await next.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('completed history is read-only and acknowledgement preserves the frozen job', () async {
    const channel = MethodChannel('test/ios-import-acknowledgement');
    final client = Completer<String>();
    final source = Map<String, Object?>.from(
      publicationDocument()['job'] as Map,
    );
    var reply = {...source, 'phase': 'complete'};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        client.complete((request(call) as Map)['clientID'] as String);
        return null;
      }
      if (call.method == 'stopObserving') return null;
      expect(call.method, 'acknowledgeImport');
      expect(request(call), {
        'id': source['id'],
        'revision': 1,
        'leaseID': importLease()['leaseID'],
        'clientID': await client.future,
        'songID': 42,
      });
      return encoded(reply);
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    final subscription = transport.changes.listen((_) {});
    try {
      final raw = {
        ...importLease(reconcileOnly: true, clientId: await client.future),
        'job': reply,
      };
      final historical = IosTransferImportLease.fromJson(raw);
      expect(historical.sourcePath, isNull);
      expect(
        () => IosTransferImportLease.fromJson({...raw, 'reconcileOnly': false}),
        throwsFormatException,
      );
      final completed = await transport.acknowledgeImport(
        historical,
        songId: 42,
      );
      expect(completed.phase, IosTransferPhase.complete);
      reply = source;
      await expectLater(
        transport.acknowledgeImport(historical, songId: 42),
        throwsFormatException,
      );
      reply = {
        ...source,
        'phase': 'complete',
        'metadata': {
          ...source['metadata'] as Map,
          'title': 'Changed completion recording',
        },
      };
      await expectLater(
        transport.acknowledgeImport(historical, songId: 42),
        throwsFormatException,
      );
      await expectLater(
        transport.acknowledgeImport(historical, songId: 0),
        throwsFormatException,
      );
    } finally {
      await subscription.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
