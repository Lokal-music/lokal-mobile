import 'dart:async';

import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late BigInt nativeEpoch;
  late int destroyed;
  late int restored;
  late LocalAudioLifecycle lifecycle;

  setUp(() {
    nativeEpoch = BigInt.zero;
    destroyed = 0;
    restored = 0;
    lifecycle = LocalAudioLifecycle(
      nativeEpoch: () => nativeEpoch,
      destroyNativeOutput: () async => destroyed++,
      restoreSession: () async => restored++,
    );
  });

  Future<void> event(LocalAudioNativeEvent event) {
    nativeEpoch += BigInt.one;
    return lifecycle.accept(event, nativeEpoch);
  }

  test(
    'late probe cannot revive or refresh a retired nested request',
    () async {
      final probe = Completer<void>();
      final finished = Completer<void>();
      var replacements = 0;
      final old = lifecycle.run(() async {
        expect(lifecycle.requestEpoch, BigInt.zero);
        try {
          await probe.future;
          await lifecycle.run(() async => replacements++);
        } finally {
          finished.complete();
        }
      });
      final rejected = expectLater(
        old,
        throwsA(isA<LocalAudioRequestRetired>()),
      );
      await event(LocalAudioNativeEvent.reset);
      await rejected; // Does not wait for the underlying probe.
      expect(finished.isCompleted, isFalse);
      probe.complete();
      await finished.future;
      await Future<void>.delayed(Duration.zero);
      expect(replacements, 0);
      expect(lifecycle.phase.value, LocalAudioPhase.paused);
      await lifecycle.run(() async {
        expect(lifecycle.requestEpoch, BigInt.one);
        replacements++;
      });
      expect(replacements, 1);
    },
  );

  test(
    'native epoch fences requests before Dart notification arrives',
    () async {
      final probe = Completer<void>();
      var commands = 0;
      final old = lifecycle.run(() async {
        await probe.future;
        lifecycle.checkRequest();
        commands++;
      });
      final rejected = expectLater(
        old,
        throwsA(isA<LocalAudioRequestRetired>()),
      );
      nativeEpoch = BigInt.one;
      probe.complete();
      await rejected;
      await expectLater(
        lifecycle.run(() async => commands++),
        throwsA(isA<LocalAudioRequestRetired>()),
      );
      expect(commands, 0);
    },
  );

  test(
    'retire immediately; explicit Play waits for confirmed disposal',
    () async {
      final disposed = Completer<void>();
      var retired = false;
      var plays = 0;
      final owner = Object();
      lifecycle.register(owner, () {
        retired = true;
        return disposed.future;
      });
      final cleanup = event(LocalAudioNativeEvent.reset);
      expect(retired, isTrue);
      expect(lifecycle.phase.value, LocalAudioPhase.recovering);
      final play = lifecycle.run(() async => plays++);
      await Future<void>.delayed(Duration.zero);
      expect(plays, 0);
      expect(restored, 0);
      disposed.complete();
      await cleanup;
      await play;
      expect(plays, 1);
      expect(destroyed, 1);
      expect(restored, 1);
    },
  );

  test('another reset cancels Play waiting for earlier cleanup', () async {
    final disposed = Completer<void>();
    lifecycle.register(Object(), () => disposed.future);
    event(LocalAudioNativeEvent.reset);
    var plays = 0;
    final stalePlay = lifecycle.run(() async => plays++);
    final rejected = expectLater(
      stalePlay,
      throwsA(isA<LocalAudioRequestRetired>()),
    );
    final cleanup = event(LocalAudioNativeEvent.reset);
    await rejected;
    disposed.complete();
    await cleanup;
    expect(plays, 0);
    expect(restored, 1);
    expect(destroyed, 2);
  });

  test('lost never blocks remote controls or automatically resumes', () async {
    var localPlays = 0;
    var remoteCommands = 0;
    await event(LocalAudioNativeEvent.lost);
    await expectLater(
      lifecycle.run(() async => localPlays++),
      throwsA(isA<LocalAudioUnavailable>()),
    );
    remoteCommands++; // Receiver controls never enter a local request scope.
    expect(lifecycle.phase.value, LocalAudioPhase.lost);
    expect(restored, 0);
    await event(LocalAudioNativeEvent.reset);
    expect(lifecycle.phase.value, LocalAudioPhase.paused);
    expect(localPlays, 0);
    expect(remoteCommands, 1);
  });

  test(
    'cleanup failure awaits every owner and latches output closed',
    () async {
      final disposed = Completer<void>();
      var otherRetired = false;
      lifecycle.register(
        Object(),
        () => Future.error(StateError('dispose failed')),
      );
      lifecycle.register(Object(), () {
        otherRetired = true;
        return disposed.future;
      });
      final cleanup = event(LocalAudioNativeEvent.reset);
      var completed = false;
      cleanup.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(otherRetired, isTrue);
      expect(completed, isFalse);
      expect(restored, 0);
      disposed.complete();
      await cleanup;
      expect(lifecycle.phase.value, LocalAudioPhase.blocked);
      await expectLater(
        lifecycle.run(() async {}),
        throwsA(isA<LocalAudioUnavailable>()),
      );
      await event(LocalAudioNativeEvent.reset);
      expect(lifecycle.phase.value, LocalAudioPhase.blocked);
      expect(restored, 0);
      expect(destroyed, 2);
    },
  );

  test(
    'out-of-order and duplicate events cannot reset a newer epoch',
    () async {
      nativeEpoch = BigInt.from(4);
      await lifecycle.accept(LocalAudioNativeEvent.reset, nativeEpoch);
      await lifecycle.accept(LocalAudioNativeEvent.lost, BigInt.from(3));
      await lifecycle.accept(LocalAudioNativeEvent.lost, BigInt.from(4));
      expect(lifecycle.epoch, BigInt.from(4));
      expect(lifecycle.phase.value, LocalAudioPhase.paused);
      expect(destroyed, 1);
      expect(restored, 1);
    },
  );

  test(
    'session failure blocks replacement and unscoped mutations fail',
    () async {
      lifecycle = LocalAudioLifecycle(
        nativeEpoch: () => nativeEpoch,
        destroyNativeOutput: () async => destroyed++,
        restoreSession: () => Future.error(StateError('session unavailable')),
      );
      expect(() => lifecycle.requestEpoch, throwsStateError);
      await event(LocalAudioNativeEvent.reset);
      expect(lifecycle.phase.value, LocalAudioPhase.blocked);
      await expectLater(
        lifecycle.run(() async {}),
        throwsA(isA<LocalAudioUnavailable>()),
      );
    },
  );
}
