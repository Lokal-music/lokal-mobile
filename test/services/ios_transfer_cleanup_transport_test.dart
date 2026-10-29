import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/models/ios_transfer_cleanup.dart';
import 'package:flick/models/ios_transfer_import.dart';
import 'package:flick/models/ios_transfer_recovery.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_recovery_transport_test.dart' show work;
import 'ios_transfer_transport_test.dart' show encoded, importLease, request;

final sharedCleanupFixture = jsonDecode(
  File('test/fixtures/ios_transfer_cleanup_v1.json').readAsStringSync(),
) as Map<String, dynamic>;

Map<String, Object?> cleanup({String? client}) => {
  ...work(),
  'permission': 'cleanup',
  'clientID': client ?? importLease()['clientID'],
  'leaseID': importLease()['leaseID'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'cleanup is a distinct frozen authority without a publication source',
    () {
      final claim = IosTransferCleanupLease.fromJson(cleanup());
      expect(
        cleanup().keys.toSet(),
        (sharedCleanupFixture['replyKeys'] as List).cast<String>().toSet(),
      );
      expect(cleanup()['permission'], sharedCleanupFixture['permission']);
      claim.validateFor(IosTransferImportWork.fromJson(work()));
      expect(claim.songId, 42);
      expect(claim.control.keys, ['id', 'revision', 'leaseID', 'clientID']);
      expect(
        () => IosTransferImportLease.fromJson(cleanup()),
        throwsFormatException,
      );
      for (final patch in [
        {'sourcePath': '/private/staged'},
        {'copyNonce': 'caller'},
        {'permission': 'write'},
        {'songID': 43},
        {'currentRevision': 0},
        {'currentPhase': 'cancelled'},
        {'currentPhase': null},
        {'currentRevision': 9223372036854775807},
        {'clientID': 'NOT-A-CLIENT'},
        {'leaseID': ''},
        {'targetRelativePath': '../Music/file.flac'},
      ]) {
        expect(
          () => IosTransferCleanupLease.fromJson({...cleanup(), ...patch}),
          throwsFormatException,
          reason: patch.keys.single,
        );
      }
    },
  );

  test('cleanup retains canceled revisions and validates durable resolution outcomes', () {
    final claim = IosTransferCleanupLease.fromJson({
      ...cleanup(),
      'currentRevision': 2,
      'currentPhase': 'cancelled',
      'resolution': {'mode': 'abandoned', 'abandonment': 'preservedUserFile'},
    });
    expect(claim.job.revision, 1);
    expect(claim.currentRevision, 2);
    expect(
      claim.resolution!.abandonment,
      IosTransferAbandonment.preservedUserFile,
    );
    expect(
      IosTransferCleanupLease.fromJson({
        ...cleanup(),
        'currentRevision': 2,
        'currentPhase': 'cancelled',
        'resolution': {'mode': 'committed'},
      }).resolution!.mode,
      IosTransferCleanupMode.committed,
    );
    for (final resolution in [
      {'mode': 'abandoned'},
      {'mode': 'committed', 'abandonment': 'missingFile'},
      {'mode': 'abandoned', 'abandonment': 'caller-delete'},
      {'mode': 'caller'},
      {'mode': 'committed', 'future': true},
    ]) {
      expect(
        () => IosTransferCleanupLease.fromJson({
          ...cleanup(),
          'currentRevision': 2,
          'currentPhase': 'cancelled',
          'resolution': resolution,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => IosTransferCleanupLease.fromJson({
        ...cleanup(),
        'currentRevision': 2,
        'currentPhase': 'cancelled',
        'publicationRecorded': false,
        'resolution': {'mode': 'committed'},
      }),
      throwsFormatException,
    );
  });

  test('claim may observe a newly recorded publication but never replace frozen intent', () {
    final claim = IosTransferCleanupLease.fromJson(cleanup());
    claim.validateFor(
      IosTransferImportWork.fromJson({...work(), 'publicationRecorded': false}),
    );
    expect(
      () => IosTransferCleanupLease.fromJson({
        ...cleanup(),
        'publicationRecorded': false,
      }).validateFor(IosTransferImportWork.fromJson(work())),
      throwsFormatException,
    );
    final job = cleanup()['job'] as Map;
    expect(
      () => IosTransferCleanupLease.fromJson({
        ...cleanup(),
        'job': {...job, 'updatedMs': (job['updatedMs'] as int) + 1},
      }).validateFor(IosTransferImportWork.fromJson(work())),
      throwsFormatException,
    );
    expect(
      () => claim.validateFor(
        IosTransferImportWork.fromJson(
          work(currentRevision: 2, phase: 'cancelled'),
        ),
      ),
      throwsFormatException,
    );
  });

  test('cleanup channel binds the current root client and accepts no caller file path', () async {
    const channel = MethodChannel('test/ios-cleanup-claim');
    final ready = Completer<String>();
    final calls = <String>[];
    var foreignReply = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        ready.complete((request(call) as Map)['clientID'] as String);
        return null;
      }
      if (call.method == 'stopObserving') return null;
      final client = await ready.future;
      calls.add(call.method);
      final payload = request(call) as Map;
      if (call.method == 'claimImportCleanup') {
        expect(payload, {
          ...sharedCleanupFixture['claim'] as Map,
          'clientID': client,
        });
        return encoded(
          cleanup(
            client: foreignReply
                ? '34397ec1-7e18-40e2-a97e-48b4dcbb65a1'
                : client,
          ),
        );
      }
      expect(payload.keys.toSet(), {'id', 'revision', 'clientID', 'leaseID'});
      expect(payload['clientID'], client);
      return encoded(true);
    });
    final native = IosTransferTransport(channel: channel, supported: true);
    final subscription = native.changes.listen((_) {});
    try {
      await ready.future;
      final claim = await native.claimImportCleanup(
        IosTransferImportWork.fromJson(work()),
      );
      await native.validateImportCleanup(claim);
      await native.releaseImportCleanup(claim);
      expect(calls, [
        'claimImportCleanup',
        'validateImportCleanup',
        'releaseImport',
      ]);
      foreignReply = true;
      await expectLater(
        native.claimImportCleanup(IosTransferImportWork.fromJson(work())),
        throwsStateError,
      );
    } finally {
      await subscription.cancel();
      await native.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
