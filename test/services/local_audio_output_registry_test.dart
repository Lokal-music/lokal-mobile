import 'dart:async';

import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/services/local_audio_output_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wrapper and reset share actual disposal acknowledgement', () async {
    final registry = LocalAudioOutputRegistry<Object>();
    final destroyed = Completer<void>();
    var calls = 0;
    final output = registry.create(Object.new, (_) {
      calls++;
      return destroyed.future;
    });
    final first = registry.dispose(output);
    expect(identical(first, registry.dispose(output)), isTrue);
    final cleanup = registry.retireAll();
    expect(identical(cleanup, registry.retireAll()), isTrue);
    var finished = false;
    cleanup.then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    expect(calls, 1);
    destroyed.complete();
    await cleanup;
  });

  test('a factory has ownership before its asynchronous return', () async {
    final registry = LocalAudioOutputRegistry<Object>();
    var destroyed = false;
    final output = registry.create(Object.new, (_) async => destroyed = true);
    // The factory has not handed the object to an engine yet.
    await registry.retireAll();
    expect(destroyed, isTrue);
    await registry.dispose(output); // Original confirmed future remains valid.
  });

  test('construction is blocked while old native cleanup waits', () async {
    final registry = LocalAudioOutputRegistry<Object>();
    final destroyed = Completer<void>();
    registry.create(Object.new, (_) => destroyed.future);
    final cleanup = registry.retireAll();
    var constructed = false;
    expect(
      () => registry.create(() {
        constructed = true;
        return Object();
      }, (_) async {}),
      throwsA(isA<LocalAudioRequestRetired>()),
    );
    expect(constructed, isFalse);
    destroyed.complete();
    await cleanup;
    registry.create(() {
      constructed = true;
      return Object();
    }, (_) async {});
    expect(constructed, isTrue);
    await registry.retireAll();
  });

  test(
    'failed disposal still waits for every output and stays failed',
    () async {
      final registry = LocalAudioOutputRegistry<Object>();
      final destroyed = Completer<void>();
      registry.create(
        Object.new,
        (_) => Future.error(StateError('native failure')),
      );
      registry.create(Object.new, (_) => destroyed.future);
      final cleanup = registry.retireAll();
      var failed = false;
      final rejected = expectLater(
        cleanup.whenComplete(() => failed = true),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(failed, isFalse);
      destroyed.complete();
      await rejected;
      expect(identical(cleanup, registry.retireAll()), isTrue);
      expect(
        () => registry.create(Object.new, (_) async {}),
        throwsA(isA<LocalAudioRequestRetired>()),
      );
    },
  );
}
