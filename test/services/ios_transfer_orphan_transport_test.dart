import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/models/ios_transfer_cleanup.dart';
import 'package:flick/models/ios_transfer_import.dart';
import 'package:flick/models/ios_transfer_orphan.dart';
import 'package:flick/models/ios_transfer_recovery.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_transport_test.dart' show encoded, importLease, request;

final sharedOrphanFixture = jsonDecode(
  File('test/fixtures/ios_transfer_orphan_v1.json').readAsStringSync(),
) as Map<String, dynamic>;

Map<String, Object?> orphan({String? client}) => {
  ...sharedOrphanFixture['claim'] as Map<String, dynamic>,
  'permission': sharedOrphanFixture['permission'],
  'clientID': client ?? importLease()['clientID'],
  'leaseID': importLease()['leaseID'],
  'currentJob': {
    ...importLease()['job'] as Map,
    'revision': 2,
    'phase': 'cancelled',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'orphan recovery accepts no paths, ownership proof or writer conversion',
    () {
      final lease = IosTransferOrphanLease.fromJson(orphan());
      expect(lease.key.revision, 1);
      expect(lease.currentJob.revision, 2);
      expect(
        orphan().keys.toSet(),
        (sharedOrphanFixture['replyKeys'] as List).toSet(),
      );
      expect(
        () => IosTransferImportLease.fromJson(orphan()),
        throwsFormatException,
      );
      expect(
        () => IosTransferCleanupLease.fromJson(orphan()),
        throwsFormatException,
      );
      for (final patch in [
        {'sourcePath': '/private/staging'},
        {'targetRelativePath': 'Desktop Copies/file.wav'},
        {'copyNonce': 'caller'},
        {'permission': 'cleanup'},
        {'songID': 43},
        {'songID': 0},
        {'songID': 9223372036854775807},
        {'revision': 2},
        {'clientID': 'invalid'},
        {'leaseID': 'invalid'},
        {
          'currentJob': {...importLease()['job'] as Map, 'revision': 1},
        },
      ]) {
        expect(
          () => IosTransferOrphanLease.fromJson({...orphan(), ...patch}),
          throwsFormatException,
          reason: patch.toString(),
        );
      }
    },
  );

  test('orphan channel binds reservation and current client with a shared native codec', () async {
    const channel = MethodChannel('test/ios-orphan-cleanup');
    final ready = Completer<String>();
    final calls = <String>[];
    var wrongReply = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        ready.complete((request(call) as Map)['clientID'] as String);
        return null;
      }
      if (call.method == 'stopObserving') return null;
      final client = await ready.future;
      calls.add(call.method);
      final payload = request(call) as Map;
      if (call.method == 'claimOrphanCleanup') {
        expect(payload, {
          ...sharedOrphanFixture['claim'] as Map,
          'clientID': client,
        });
        return encoded({
          ...orphan(client: client),
          if (wrongReply) 'revision': 0,
        });
      }
      expect(payload.keys.toSet(), {'id', 'revision', 'leaseID', 'clientID'});
      expect(payload['clientID'], client);
      return encoded(true);
    });
    final native = IosTransferTransport(channel: channel, supported: true);
    final observation = native.changes.listen((_) {});
    try {
      await ready.future;
      final claim = sharedOrphanFixture['claim'] as Map;
      final key = IosTransferWorkCursor.parse(
        '${claim['id']}:${claim['revision']}',
      );
      final lease = await native.claimOrphanCleanup(key, songId: 42);
      await native.validateOrphanCleanup(lease);
      await native.releaseOrphanCleanup(lease);
      expect(calls, [
        'claimOrphanCleanup',
        'validateOrphanCleanup',
        'releaseImport',
      ]);
      wrongReply = true;
      await expectLater(
        native.claimOrphanCleanup(key, songId: 42),
        throwsFormatException,
      );
      final count = calls.length;
      await expectLater(
        native.claimOrphanCleanup(key, songId: 0),
        throwsFormatException,
      );
      expect(calls.length, count);
    } finally {
      await observation.cancel();
      await native.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
