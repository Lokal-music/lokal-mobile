import 'dart:async';

import 'package:flick/models/ios_transfer_recovery.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_transport_test.dart' show encoded, importLease, request;

Map<String, Object?> work({
  int revision = 1,
  int? currentRevision,
  String phase = 'validating',
}) {
  final lease = importLease();
  final job = {...lease['job'] as Map, 'revision': revision};
  return {
    'job': job,
    'songID': 42,
    'targetRelativePath':
        'Desktop Copies/Fixture - ${job['id']}-r$revision.flac',
    'publicationRecorded': true,
    'currentRevision': currentRevision ?? revision,
    'currentPhase': phase,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final id = (work()['job'] as Map)['id'];
  test('recovery uses numeric keysets and permits a filtered page to advance without entries', () {
    final page = IosTransferImportWorkPage.fromJson({
      'generation': 3,
      'entries': [work(revision: 2), work(revision: 10)],
      'nextCursor': '$id:10',
    }, limit: 2);
    expect(page.entries.map((w) => w.job.revision), [2, 10]);
    final cursor = IosTransferWorkCursor.parse('$id:10');
    final filtered = IosTransferImportWorkPage.fromJson(
      {'generation': 3, 'entries': [], 'nextCursor': '$id:20'},
      limit: 2,
      after: cursor,
    );
    expect(filtered.nextCursor!.revision, 20);
    for (final value in [
      '$id:01',
      '${id.toString().toUpperCase()}:1',
      '$id:0',
      '$id:9223372036854775807',
      '../path',
    ]) {
      expect(() => IosTransferWorkCursor.parse(value), throwsFormatException);
    }
    for (final rows in [
      [work(revision: 10), work(revision: 2)],
      [work(), work()],
    ]) {
      expect(
        () => IosTransferImportWorkPage.fromJson({
          'generation': 1,
          'entries': rows,
        }, limit: 2),
        throwsFormatException,
      );
    }
    expect(
      () => IosTransferImportWorkPage.fromJson(
        {'generation': 1, 'entries': [], 'nextCursor': cursor.value},
        limit: 2,
        after: cursor,
      ),
      throwsFormatException,
    );
  });
  test('old frozen intent is bookkeeping without file authority or a new Song binding', () {
    final frozen = IosTransferImportWork.fromJson(
      work(currentRevision: 2, phase: 'cancelled'),
    );
    expect(frozen.job.revision, 1);
    expect(frozen.isCurrentRevision, false);
    for (final patch in [
      {'songID': 43},
      {'publicationRecorded': 1},
      {'currentRevision': 0},
      {'currentPhase': 'caller'},
      {'currentPhase': null},
      {'copyNonce': 'caller'},
      {'targetRelativePath': '../outside'},
      {
        'job': {...work()['job'] as Map, 'phase': 'complete'},
      },
    ]) {
      expect(
        () => IosTransferImportWork.fromJson({...work(), ...patch}),
        throwsFormatException,
      );
    }
  });
  test('candidate pages refuse terminal/queued rows and a cursor inconsistent with returned work', () {
    final candidate = work()['job'];
    expect(
      IosTransferImportCandidatePage.fromJson({
        'generation': 1,
        'entries': [candidate],
      }, limit: 1).entries,
      hasLength(1),
    );
    for (final phase in ['complete', 'queued']) {
      final job = {...candidate as Map, 'phase': phase};
      if (phase == 'queued') {
        job.remove('receivedBytes');
        job.remove('receivedSHA256');
      }
      expect(
        () => IosTransferImportCandidatePage.fromJson({
          'generation': 1,
          'entries': [job],
        }, limit: 1),
        throwsFormatException,
      );
    }
    expect(
      () => IosTransferImportCandidatePage.fromJson({
        'generation': 1,
        'entries': [candidate],
        'nextCursor': '$id:2',
      }, limit: 1),
      throwsFormatException,
    );
  });
  test('bounded recovery and drainage use only the active root client and typed native replies', () async {
    const channel = MethodChannel('test/ios-recovery-page');
    final ready = Completer<String>();
    var drainReply = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        ready.complete((request(call) as Map)['clientID'] as String);
        return null;
      }
      if (call.method == 'stopObserving') return null;
      final client = await ready.future;
      if (call.method == 'drainImports') {
        expect(request(call), {'clientID': client});
        return encoded(drainReply);
      }
      expect(request(call), {'limit': 2, 'clientID': client, 'after': '$id:1'});
      return encoded({
        'generation': 2,
        'entries': [],
        if (call.method == 'importWorkPage') 'nextCursor': '$id:2',
      });
    });
    final native = IosTransferTransport(channel: channel, supported: true);
    final subscription = native.changes.listen((_) {});
    try {
      await ready.future;
      final after = IosTransferWorkCursor.parse('$id:1');
      expect(
        (await native.importWorkPage(
          after: after,
          limit: 2,
        )).nextCursor!.revision,
        2,
      );
      expect(
        (await native.importCandidatesPage(after: after, limit: 2)).entries,
        isEmpty,
      );
      await native.drainImports();
      drainReply = false;
      await expectLater(native.drainImports(), throwsFormatException);
      await expectLater(
        native.importWorkPage(limit: 101),
        throwsFormatException,
      );
    } finally {
      await subscription.cancel();
      await native.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
