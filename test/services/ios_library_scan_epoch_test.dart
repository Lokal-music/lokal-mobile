import 'dart:async';

import 'package:flick/services/ios_library_scan_epoch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'retired async generator and detached work cannot regain scan authority',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final detachedDone = Completer<void>();
      late Future<void> detached;
      Stream<int> scan() async* {
        expect(IosLibraryScanEpoch.current, true);
        detached = Future<void>(() async {
          await detachedDone.future;
          IosLibraryScanEpoch.requireCurrent();
        });
        entered.complete();
        await release.future;
        IosLibraryScanEpoch.requireCurrent();
        yield 1;
      }

      final result = IosLibraryScanEpoch.bind(scan).toList();
      final failed = expectLater(result, throwsStateError);
      await entered.future;
      await IosLibraryScanEpoch.withMutation(() async {
        await expectLater(
          IosLibraryScanEpoch.run(() async {}),
          throwsStateError,
        );
      });
      final detachedFailed = expectLater(detached, throwsStateError);
      release.complete();
      detachedDone.complete();
      await failed;
      await detachedFailed;
      expect(
        await IosLibraryScanEpoch.bind(() async* {
          IosLibraryScanEpoch.requireCurrent();
          yield 42;
        }).single,
        42,
      );
    },
  );

  test('queued mutation holds do not admit scans between operations', () async {
    final first = Completer<void>(), second = Completer<void>();
    final a = IosLibraryScanEpoch.withMutation(() => first.future);
    final b = IosLibraryScanEpoch.withMutation(() => second.future);
    first.complete();
    await a;
    await expectLater(
      IosLibraryScanEpoch.bind(() async* {
        yield 1;
      }).single,
      throwsStateError,
    );
    second.complete();
    await b;
    expect(IosLibraryScanEpoch.current, false);
    expect(
      await IosLibraryScanEpoch.run(() async {
        IosLibraryScanEpoch.requireCurrent();
        return true;
      }),
      true,
    );
  });

  test('cancelling the consumer awaits source generator cleanup', () async {
    final emitted = Completer<void>(), release = Completer<void>();
    var cleaned = false;
    final subscription = IosLibraryScanEpoch.bind(() async* {
      try {
        yield 1;
        emitted.complete();
        await release.future;
        yield 2;
      } finally {
        cleaned = true;
      }
    }).listen((_) {});
    await emitted.future;
    final cancelled = subscription.cancel();
    await pumpEventQueue();
    expect(cleaned, false);
    release.complete();
    await cancelled;
    expect(cleaned, true);
  });
}
