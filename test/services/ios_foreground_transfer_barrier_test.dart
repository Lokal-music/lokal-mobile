import 'dart:async';

import 'package:flick/services/ios_foreground_transfer_barrier.dart';
import 'package:flick/services/ios_transfer_mutation_barrier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('closes tracked request and drains its last writer before metadata mutation', () async {
    final gate = IosForegroundTransferBarrier();
    final entered = Completer<void>(), cancelled = Completer<void>();
    final releaseMutation = Completer<void>();
    var writerFinished = false, mutationStarted = false;
    final transfer = gate.run(() async {
      gate.cancelOnPause(() => cancelled.complete());
      entered.complete();
      await cancelled.future;
      writerFinished = true;
      throw StateError('request cancelled');
    });
    final observed = expectLater(transfer, throwsStateError);
    await entered.future;
    final mutation = gate.withMutation(() async {
      expect(writerFinished, true);
      mutationStarted = true;
      await releaseMutation.future;
    });
    await observed;
    await pumpEventQueue();
    expect(mutationStarted, true);
    await expectLater(gate.run(() async {}), throwsStateError);
    releaseMutation.complete();
    await mutation;
    expect(gate.paused, false);
    expect(await gate.run(() async => 42), 42);
  });

  test(
    'queued app mutations retain the pause across the first completion',
    () async {
      final gate = IosForegroundTransferBarrier(),
          serial = IosTransferMutationBarrier();
      final first = Completer<void>(), second = Completer<void>();
      final events = <String>[];
      Future<void> mutate(String name, Completer<void> release) =>
          gate.withMutation(
            () => serial.run(
              pause: () async {},
              resume: () async {},
              mutate: () async {
                events.add(name);
                await release.future;
              },
            ),
          );
      final a = mutate('first', first), b = mutate('second', second);
      await pumpEventQueue();
      expect(events, ['first']);
      first.complete();
      await a;
      await pumpEventQueue();
      expect(events, ['first', 'second']);
      expect(gate.paused, true);
      await expectLater(gate.run(() async {}), throwsStateError);
      second.complete();
      await b;
      expect(gate.paused, false);
    },
  );

  test(
    'failed metadata mutation releases pause and retires old preview epoch',
    () async {
      final gate = IosForegroundTransferBarrier();
      final epoch = gate.epoch;
      await expectLater(
        gate.withMutation(() async => throw StateError('storage failed')),
        throwsStateError,
      );
      expect(gate.epoch, greaterThan(epoch));
      expect(gate.paused, false);
      expect(await gate.run(() async => 'fresh consent'), 'fresh consent');
    },
  );

  test(
    'a cancellation callback cannot bypass an outstanding operation',
    () async {
      final gate = IosForegroundTransferBarrier();
      final release = Completer<void>();
      var mutated = false;
      final transfer = gate.run(() async {
        gate.cancelOnPause(() => throw StateError('already closed'));
        await release.future;
      });
      final mutation = gate.withMutation(() async {
        mutated = true;
      });
      await pumpEventQueue();
      expect(mutated, false);
      release.complete();
      await Future.wait([transfer, mutation]);
      expect(mutated, true);
    },
  );
}
