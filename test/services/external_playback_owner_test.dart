import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/external_playback_owner.dart';

void main() {
  test(
    'reset waits for native quiet while retaining selected video ownership',
    () async {
      final owner = ExternalPlaybackOwner();
      final quiet = Completer<void>();
      var resetCalls = 0;
      var releases = 0;
      final lease = owner.claim(
        () async => releases++,
        onMediaReset: () {
          resetCalls++;
          return quiet.future;
        },
      );
      final first = owner.retireForMediaReset();
      final repeated = owner.retireForMediaReset();
      expect(resetCalls, 1);
      expect(identical(first, repeated), isTrue);
      expect(() => owner.claim(() async {}), throwsStateError);
      quiet.complete();
      await first;
      expect(lease.isReleased, isFalse);
      expect(lease.isLatest, isTrue);
      expect(releases, 0);
      await owner.releaseCurrent();
      expect(releases, 1);
    },
  );

  test(
    'unconfirmed reset keeps video ownership and rejects replacement',
    () async {
      final owner = ExternalPlaybackOwner();
      final lease = owner.claim(
        () async {},
        onMediaReset: () async {
          throw StateError('WebKit suspension unconfirmed');
        },
      );
      await expectLater(owner.retireForMediaReset(), throwsStateError);
      expect(lease.isReleased, isFalse);
      expect(() => owner.claim(() async {}), throwsStateError);
    },
  );

  test('an unreleased output cannot be replaced', () async {
    final owner = ExternalPlaybackOwner();
    final first = owner.claim(() async {});
    expect(() => owner.claim(() async {}), throwsStateError);
    await first.release();
    final second = owner.claim(() async {});
    expect(first.isLatest, isFalse);
    expect(second.isLatest, isTrue);
    await owner.releaseCurrent();
  });

  test(
    'concurrent releases share one acknowledgement and block new ownership',
    () async {
      final owner = ExternalPlaybackOwner();
      final acknowledgement = Completer<void>();
      var calls = 0;
      final lease = owner.claim(() {
        calls++;
        return acknowledgement.future;
      });
      final first = lease.release();
      final second = lease.release();
      expect(identical(first, second), isTrue);
      expect(calls, 1);
      expect(lease.isReleased, isFalse);
      expect(() => owner.claim(() async {}), throwsStateError);
      acknowledgement.complete();
      await Future.wait([first, second]);
      expect(lease.isReleased, isTrue);
      await owner.releaseCurrent();
      expect(calls, 1);
    },
  );

  test('a synchronous release failure remains retryable', () async {
    final owner = ExternalPlaybackOwner();
    var calls = 0;
    final lease = owner.claim(() {
      if (++calls == 1) throw StateError('native pause unavailable');
      return Future<void>.value();
    });
    await expectLater(owner.releaseCurrent(), throwsStateError);
    expect(lease.isReleased, isFalse);
    expect(() => owner.claim(() async {}), throwsStateError);
    await owner.releaseCurrent();
    expect(calls, 2);
    expect(lease.isReleased, isTrue);
  });

  test(
    'an asynchronous release failure does not permit another player to start',
    () async {
      final owner = ExternalPlaybackOwner();
      var attempts = 0;
      final lease = owner.claim(() async {
        await Future<void>.delayed(Duration.zero);
        if (++attempts == 1) throw StateError('native pause failed');
      });
      await expectLater(owner.releaseCurrent(), throwsStateError);
      expect(lease.isReleased, isFalse);
      await owner.releaseCurrent();
      expect(lease.isReleased, isTrue);
    },
  );

  test('a replacement acquired after acknowledgement is also drained before local play', () async {
    final owner = ExternalPlaybackOwner();
    final acknowledgement = Completer<void>();
    final old = owner.claim(() => acknowledgement.future);
    final release = old.release();
    var replacementReleased = false;
    final replacement = release.then(
      (_) => owner.claim(() async {
        replacementReleased = true;
      }),
    );
    final drain = owner.releaseCurrent();
    acknowledgement.complete();
    final lease = await replacement;
    await drain;
    expect(replacementReleased, isTrue);
    expect(lease.isReleased, isTrue);
    expect(old.isLatest, isFalse);
  });
}
