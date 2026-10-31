import 'dart:async';

import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/services/ios_transfer_queue.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_transport_test.dart' show intentDocument;

IosTransferJob queueJob({
  int index = 1,
  String direction = 'upload',
  String phase = 'interrupted',
  int revision = 1,
}) {
  final row = intentDocument();
  row['id'] =
      'aaaaaaaa-aaaa-4aaa-8aaa-${index.toRadixString(16).padLeft(12, '0')}';
  (row['identity'] as Map)['localSongID'] = '42';
  return IosTransferJob.fromJson({
    ...row,
    'direction': direction,
    'phase': phase,
    'revision': revision,
    'updatedMs': 2000,
    if (phase == 'interrupted') 'lastFailure': 'network',
    if (phase == 'complete' && direction == 'upload')
      'resultOriginalID': 'original-file',
  });
}

class QueueNative extends IosTransferTransport {
  QueueNative() : super(supported: true);
  bool qualified = true,
      failedStorage = false,
      failRead = false,
      didDispose = false,
      cleanupFails = false;
  int generation = 1,
      matchCalls = 0,
      retryCalls = 0,
      cancelCalls = 0,
      cleanupCalls = 0;
  List<Map<String, Object?>> pauses = [];
  int resumes = 0;
  final events = StreamController<void>.broadcast();
  final pageCalls = <(int, int)>[];
  List<IosTransferJob> rows = [queueJob()];
  void Function()? duringPage;
  IosTransferJob? matched;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<IosTransferCapability> capability() async => IosTransferCapability(
    available: true,
    download: true,
    libraryImport: qualified,
    upload: qualified,
  );
  @override
  Future<IosTransferSummary> summary() async {
    if (failRead) throw StateError('Fixture unavailable');
    final counts = <String, int>{};
    for (final job in rows) {
      counts.update(job.phase.name, (n) => n + 1, ifAbsent: () => 1);
    }
    return IosTransferSummary.fromJson({
      'generation': generation,
      'total': rows.length,
      'counts': counts,
      'progress': [],
      'pauses': pauses,
      'persistenceFailed': failedStorage,
    });
  }

  @override
  Future<List<IosTransferJob>> page({int offset = 0, int limit = 100}) async {
    pageCalls.add((offset, limit));
    final result = rows.skip(offset).take(limit).toList();
    duringPage?.call();
    return result;
  }

  @override
  Future<IosTransferJob?> matchUploadedOriginal(IosTransferJob job) async {
    matchCalls++;
    if (matched != null) rows = [matched!];
    return matched;
  }

  @override
  Future<void> cleanupUploadBody(IosTransferJob job) async {
    cleanupCalls++;
    if (cleanupFails) throw StateError('Task still draining');
  }

  @override
  Future<IosTransferJob> retryDownloadFromQueue(IosTransferJob job) async {
    retryCalls++;
    return job;
  }

  @override
  Future<IosTransferJob> cancelFromQueue(IosTransferJob job) async {
    cancelCalls++;
    final result = queueJob(phase: 'cancelled', revision: job.revision + 1);
    rows = [result];
    generation++;
    return result;
  }

  @override
  Future<IosTransferSummary> resumeFromQueue(IosTransferScope scope) async {
    resumes++;
    pauses.clear();
    generation++;
    return summary();
  }

  @override
  Future<void> dispose() async {
    didDispose = true;
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late QueueNative native;
  late IosTransferQueueController queue;
  int prepared = 0, started = 0;
  setUp(() {
    native = QueueNative();
    prepared = 0;
    started = 0;
    queue = IosTransferQueueController(
      native: native,
      ensureReady: () async {
        started++;
      },
      prepareUpload: (_) async {
        prepared++;
      },
    );
  });
  tearDown(() async {
    queue.dispose();
    await native.events.close();
    await native.dispose();
  });
  test(
    'unqualified queue does not observe, page or start the native engine',
    () async {
      native.qualified = false;
      await queue.start();
      expect(queue.available, false);
      expect(started, 0);
      expect(native.pageCalls, isEmpty);
      expect(native.events.hasListener, false);
    },
  );
  test('paged snapshots replace rather than duplicate rows and retain root ownership', () async {
    native.rows = List.generate(121, (i) => queueJob(index: i + 1));
    await queue.start();
    expect(queue.jobs.length, 50);
    expect(queue.hasMore, true);
    await queue.loadMore();
    expect(queue.jobs.length, 100);
    await queue.loadMore();
    expect(queue.jobs.length, 121);
    expect(queue.hasMore, false);
    expect(native.pageCalls.every((call) => call.$2 <= 100), true);
    expect(queue.jobs.map((job) => job.id).toSet().length, 121);
    queue.dispose();
    expect(native.didDispose, false);
    // Recreate only the view controller, not a new native session.
    queue = IosTransferQueueController(
      native: native,
      ensureReady: () async {},
      prepareUpload: (_) async {},
    );
  });
  test('changing generations cannot publish a mixed-page snapshot or enable actions', () async {
    await queue.start();
    final original = queue.jobs.single;
    native.duringPage = () {
      native.generation++;
    };
    await queue.refresh();
    expect(queue.stale, true);
    expect(queue.canAct, false);
    expect(queue.jobs.single, same(original));
    await queue.act(original, IosTransferQueueAction.matchUpload);
    expect(native.matchCalls, 0);
    native.duringPage = null;
    await queue.refresh();
    expect(queue.stale, false);
  });
  test(
    'a one-time deletion while paging retries against the new generation',
    () async {
      native.rows = List.generate(60, (i) => queueJob(index: i + 1));
      native.duringPage = () {
        native.rows.removeAt(0);
        native.generation++;
        native.duringPage = null;
      };
      await queue.start();
      expect(queue.stale, false);
      expect(queue.jobs.first.id, queueJob(index: 2).id);
    },
  );
  test('uncertain upload match miss never prepares or retries audio', () async {
    await queue.start();
    final job = queue.jobs.single;
    expect(queue.actions(job), contains(IosTransferQueueAction.matchUpload));
    expect(
      queue.actions(job),
      isNot(contains(IosTransferQueueAction.prepareUpload)),
    );
    await queue.act(job, IosTransferQueueAction.matchUpload);
    expect(native.matchCalls, 1);
    expect(prepared, 0);
    expect(native.retryCalls, 0);
    expect(native.cleanupCalls, 0);
    expect(queue.notice, IosTransferQueueNotice.noMatch);
  });
  test(
    'positive receipt settles then cleans only the temporary body',
    () async {
      native.matched = queueJob(phase: 'complete');
      await queue.start();
      await queue.act(queue.jobs.single, IosTransferQueueAction.matchUpload);
      expect(queue.jobs.single.phase, IosTransferPhase.complete);
      expect(native.cleanupCalls, 1);
      expect(prepared, 0);
      expect(native.retryCalls, 0);
    },
  );
  test(
    'pending task drainage preserves settled status and allows later cleanup',
    () async {
      native.cleanupFails = true;
      await queue.start();
      await queue.act(queue.jobs.single, IosTransferQueueAction.cancel);
      expect(queue.jobs.single.phase, IosTransferPhase.cancelled);
      expect(queue.notice, IosTransferQueueNotice.cleanupPending);
      native.cleanupFails = false;
      await queue.act(queue.jobs.single, IosTransferQueueAction.cleanupUpload);
      expect(native.cleanupCalls, 2);
      expect(queue.notice, IosTransferQueueNotice.none);
    },
  );
  test(
    'only never-started upload preparation reaches the frozen-source adapter',
    () async {
      native.rows = [queueJob(phase: 'waiting')];
      await queue.start();
      await queue.act(queue.jobs.single, IosTransferQueueAction.prepareUpload);
      expect(prepared, 1);
      expect(native.retryCalls, 0);
    },
  );
  test('storage failure and mutation pause disable all actions', () async {
    native.failedStorage = true;
    await queue.start();
    await queue.act(queue.jobs.single, IosTransferQueueAction.cancel);
    expect(native.cancelCalls, 0);
    native.failedStorage = false;
    await queue.refresh();
    await native.pauseSubmissions();
    expect(queue.canAct, false);
    await queue.act(queue.jobs.single, IosTransferQueueAction.matchUpload);
    expect(native.matchCalls, 0);
  });
  test('scoped pauses block resending actions but permit cancellation and explicit connection resume', () async {
    native.pauses = [
      {
        'scope': native.rows.single.intent.identity.scope.toJson(),
        'reason': 'unauthorized',
      },
    ];
    await queue.start();
    final job = queue.jobs.single;
    expect(queue.canActOn(job, IosTransferQueueAction.matchUpload), false);
    expect(queue.canActOn(job, IosTransferQueueAction.cancel), true);
    await queue.resumePause(queue.summary!.pauses.single);
    expect(native.resumes, 1);
    expect(queue.summary!.pauses, isEmpty);
    expect(native.matchCalls, 0);
    expect(prepared, 0);
  });
  test('retired pairing pause cannot be resumed by a queue action', () async {
    native.pauses = [
      {
        'scope': native.rows.single.intent.identity.scope.toJson(),
        'reason': 'pairingChanged',
      },
    ];
    await queue.start();
    await queue.resumePause(queue.summary!.pauses.single);
    expect(native.resumes, 0);
  });
  test(
    'explicit storage recovery uses the root session without retrying audio',
    () async {
      queue.dispose();
      var recovered = 0;
      native.failedStorage = true;
      queue = IosTransferQueueController(
        native: native,
        ensureReady: () async {},
        prepareUpload: (_) async {},
        recoverSession: () async {
          recovered++;
          native.failedStorage = false;
        },
      );
      await queue.start();
      expect(queue.canAct, false);
      await queue.recoverStorage();
      expect(recovered, 1);
      expect(queue.canAct, true);
      expect(native.matchCalls, 0);
      expect(native.retryCalls, 0);
    },
  );
  test('initial read failure can recover through explicit reload', () async {
    native.failRead = true;
    await queue.start();
    expect(queue.stale, true);
    native.failRead = false;
    await queue.reload();
    expect(queue.stale, false);
    expect(queue.jobs.length, 1);
  });
}
