import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/core/utils/app_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// Controlled asynchronous storage for disk ordering/failure and timer tests.
/// A separate real-file case checks the persisted JSONL/replay boundary.
class _File implements File {
  String content = '';
  bool present = false;
  bool failNextWrite = false;
  bool failTrim = false;
  int writes = 0;
  int deletes = 0;
  Completer<void>? nextWriteGate;

  List<String> get messages => content
      .split('\n')
      .where((line) => line.isNotEmpty)
      .map((line) => (jsonDecode(line) as Map)['m'] as String)
      .toList();

  @override
  Future<bool> exists() async => present;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    writes++;
    final fail = failNextWrite;
    failNextWrite = false;
    final gate = nextWriteGate;
    nextWriteGate = null;
    if (gate != null) await gate.future;
    if (fail) throw const FileSystemException('Controlled write failure');
    content = mode == FileMode.append ? content + contents : contents;
    present = true;
    return this;
  }

  @override
  Future<int> length() async => failTrim ? 600 * 1024 : content.length;

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) async {
    if (failTrim) throw const FileSystemException('Controlled trim failure');
    return const LineSplitter().convert(content);
  }

  @override
  Future<File> delete({bool recursive = false}) async {
    deletes++;
    content = '';
    present = false;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

Future<AppLog> _open(_File file) async {
  final log = AppLog.forTesting(() async => file);
  await log.initializePersistence();
  return log;
}

void main() {
  testWidgets(
    'idle persistence creates no timer; a burst schedules one flush',
    (tester) async {
      final file = _File();
      final oneShots = <Duration>[];
      final repeating = <Duration>[];
      var wakeups = 0;
      await runZoned(
        () async {
          final log = await _open(file);
          try {
            await tester.pump(const Duration(seconds: 30));
            expect(oneShots, isEmpty);
            expect(repeating, isEmpty);
            log.add('first');
            log.add('second');
            expect(oneShots, [const Duration(seconds: 5)]);
            await tester.pump(const Duration(seconds: 5));
            expect(file.messages, ['first', 'second']);
            expect(file.writes, 1);
            expect(wakeups, 1);
            await tester.pump(const Duration(seconds: 30));
            expect(wakeups, 1);
            expect(oneShots, hasLength(1));
            expect(repeating, isEmpty);
          } finally {
            log.dispose();
          }
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            oneShots.add(duration);
            return parent.createTimer(zone, duration, () {
              wakeups++;
              callback();
            });
          },
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            repeating.add(duration);
            return parent.createPeriodicTimer(zone, duration, callback);
          },
        ),
      );
    },
  );

  test(
    'explicit lifecycle flush joins a write and drains newer entries',
    () async {
      final file = _File();
      final log = await _open(file);
      try {
        final gate = Completer<void>();
        file.nextWriteGate = gate;
        log.add('before');
        final first = log.flushToDisk();
        await Future<void>.delayed(Duration.zero);
        log.add('during');
        var joined = false;
        final second = log.flushToDisk().then((_) => joined = true);
        await Future<void>.delayed(Duration.zero);
        expect(joined, isFalse);
        expect(file.writes, 1);
        gate.complete();
        await Future.wait([first, second]);
        expect(joined, isTrue);
        expect(file.messages, ['before', 'during']);
        expect(file.writes, 2);
      } finally {
        log.dispose();
      }
    },
  );

  for (final failedOldWrite in [false, true]) {
    test(
      'clear orders deletion behind ${failedOldWrite ? 'failed' : 'successful'} old write',
      () async {
        final file = _File();
        final log = await _open(file);
        try {
          final gate = Completer<void>();
          file.nextWriteGate = gate;
          file.failNextWrite = failedOldWrite;
          log.add('discarded');
          final old = log.flushToDisk();
          await Future<void>.delayed(Duration.zero);
          log.clear();
          log.add('retained');
          final latest = log.flushToDisk();
          gate.complete();
          await Future.wait([old, latest]);
          expect(log.entries.map((entry) => entry.message), ['retained']);
          expect(file.messages, ['retained']);
        } finally {
          log.dispose();
        }
      },
    );
  }

  testWidgets('failed append retains entries and retries after the delay', (
    tester,
  ) async {
    final file = _File()..failNextWrite = true;
    final log = await _open(file);
    try {
      log.add('retained after failure');
      await log.flushToDisk();
      expect(file.writes, 1);
      expect(file.messages, isEmpty);
      await tester.pump(const Duration(seconds: 4));
      expect(file.writes, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(file.writes, 2);
      expect(file.messages, ['retained after failure']);
      await tester.pump(const Duration(seconds: 20));
      expect(file.writes, 2);
    } finally {
      log.dispose();
    }
  });

  test('trim failure does not append an already saved batch again', () async {
    final file = _File()..failTrim = true;
    final log = await _open(file);
    try {
      log.add('persisted once');
      await log.flushToDisk();
      file.failTrim = false;
      await log.flushToDisk();
      expect(file.messages, ['persisted once']);
      expect(file.writes, 1);
    } finally {
      log.dispose();
    }
  });

  test(
    'clear during initialization discards persisted history and keeps new logs',
    () async {
      final file = _File()
        ..present = true
        ..content =
            '${jsonEncode({'t': 1, 's': 'dart', 'm': 'old history'})}\n';
      final opened = Completer<File>();
      final log = AppLog.forTesting(() => opened.future);
      try {
        final initializing = log.initializePersistence();
        log.clear();
        log.add('new history');
        opened.complete(file);
        await initializing;
        await log.flushToDisk();
        expect(log.entries.map((entry) => entry.message), ['new history']);
        expect(file.messages, ['new history']);
        expect(file.deletes, 1);
      } finally {
        log.dispose();
      }
    },
  );

  testWidgets('clear cancels an unsaved burst without a later disk append', (
    tester,
  ) async {
    final file = _File();
    final log = await _open(file);
    try {
      log.add('discarded');
      log.clear();
      await tester.pump(const Duration(seconds: 30));
      expect(file.writes, 0);
      expect(log.entries, isEmpty);
    } finally {
      log.dispose();
    }
  });

  test(
    'real JSONL preserves source and Unicode through flush and replay',
    () async {
      final directory = await Directory.systemTemp.createTemp('lokal-log-');
      final file = File('${directory.path}/log.jsonl');
      final log = AppLog.forTesting(() async => file);
      final replayed = AppLog.forTesting(() async => file);
      try {
        await log.initializePersistence();
        log.add('Été — 音楽', source: LogSource.rust);
        await log.flushToDisk();
        await replayed.initializePersistence();
        expect(replayed.entries.single.message, 'Été — 音楽');
        expect(replayed.entries.single.source, LogSource.rust);
        replayed.clear();
        replayed.add('after clear');
        await replayed.flushToDisk();
        final lines = await file.readAsLines();
        expect(lines, hasLength(1));
        expect(jsonDecode(lines.single)['m'], 'after clear');
      } finally {
        log.dispose();
        replayed.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
