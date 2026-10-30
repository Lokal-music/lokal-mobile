import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/ios_transfer_mutation_barrier.dart';

void main() {
  test('serializes independent mutations through the complete resume', () async {
    final gate = IosTransferMutationBarrier();
    final firstEntered = Completer<void>();
    final firstMayFinish = Completer<void>();
    final events = <String>[];

    final first = gate.run<void>(
      pause: () async => events.add('pause-1'),
      mutate: () async {
        events.add('mutate-1');
        firstEntered.complete();
        await firstMayFinish.future;
      },
      resume: () async => events.add('resume-1'),
    );
    await firstEntered.future;
    final second = gate.run<void>(
      pause: () async => events.add('pause-2'),
      mutate: () async => events.add('mutate-2'),
      resume: () async => events.add('resume-2'),
    );

    await Future<void>.delayed(Duration.zero);
    expect(events, ['pause-1', 'mutate-1']);
    firstMayFinish.complete();
    await Future.wait([first, second]);
    expect(events, [
      'pause-1', 'mutate-1', 'resume-1',
      'pause-2', 'mutate-2', 'resume-2',
    ]);
  });

  test('failed retirement refuses mutation and does not resume', () async {
    final gate = IosTransferMutationBarrier();
    var mutated = false, resumed = false;
    await expectLater(
      gate.run<void>(
        pause: () async => throw StateError('retirement refused'),
        mutate: () async => mutated = true,
        resume: () async => resumed = true,
      ),
      throwsStateError,
    );
    expect(mutated, isFalse);
    expect(resumed, isFalse);
    final recovered = await gate.run<int>(
      pause: () async {},
      mutate: () async => 42,
      resume: () async {},
    );
    expect(recovered, 42);
  });

  test('storage failure still finishes retirement before next write', () async {
    final gate = IosTransferMutationBarrier();
    final events = <String>[];
    await expectLater(
      gate.run<void>(
        pause: () async => events.add('pause'),
        mutate: () async {
          events.add('write');
          throw StateError('storage failed');
        },
        resume: () async => events.add('resume'),
      ),
      throwsStateError,
    );
    await gate.run<void>(
      pause: () async => events.add('next pause'),
      mutate: () async => events.add('next write'),
      resume: () async => events.add('next resume'),
    );
    expect(events, ['pause', 'write', 'resume', 'next pause', 'next write', 'next resume']);
  });
}
