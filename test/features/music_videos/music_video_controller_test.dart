import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/music_videos/music_video_controller.dart';
import 'package:flick/services/external_playback_owner.dart';
import 'package:flick/services/local_audio_lifecycle.dart';

void main() {
  test(
    'native quiet failure stays observed while the release sender is pending',
    () async {
      final video = Media3MusicVideoController(
        trackNativeOutputQuiescence: true,
      );
      addTearDown(video.dispose);
      final sender = Completer<void>();
      final owner = video.attach((_, _) => sender.future);
      final release = expectLater(video.releaseAudio(), throwsStateError);
      video.acknowledgeNativeQuiet(
        owner,
        error: StateError('native suspension failed'),
      );
      await Future<void>.delayed(Duration.zero);
      sender.completeError(StateError('release failed'));
      await release;
    },
  );
  test(
    'reset retires a pending video release without losing selected ownership',
    () async {
      final video = Media3MusicVideoController(
        trackNativeOutputQuiescence: true,
      );
      addTearDown(video.dispose);
      final quiet = Completer<void>();
      video.attach((_, _) => quiet.future);
      final owner = ExternalPlaybackOwner();
      final lease = owner.claim(
        video.releaseAudio,
        onMediaReset: video.retireForMediaReset,
      );
      final releasing = expectLater(
        lease.release(),
        throwsA(isA<LocalAudioRequestRetired>()),
      );
      final resetting = owner.retireForMediaReset();
      quiet.complete();
      await Future.wait([releasing, resetting]);
      expect(lease.isReleased, isFalse);
      expect(lease.isLatest, isTrue);
      video.attach(
        (_, _) async {},
      ); // Confirmed cleanup permits a fresh paused view.
      await owner.releaseCurrent();
      expect(lease.isReleased, isTrue);
    },
  );

  test('an old release rejects replacement ownership instead of waiting on its future', () async {
    final video = Media3MusicVideoController(trackNativeOutputQuiescence: true);
    addTearDown(video.dispose);
    final oldQuiet = Completer<void>();
    video.attach((_, _) => oldQuiet.future);
    final release = expectLater(
      video.releaseAudio(),
      throwsA(isA<LocalAudioRequestRetired>()),
    );
    video.attach((_, _) async {});
    oldQuiet.complete();
    await release;
    await video.releaseAudio();
  });
  test(
    'disposed or detached iPhone video waits for actual native suspension',
    () async {
      final video = Media3MusicVideoController(
        trackNativeOutputQuiescence: true,
      );
      final owner = video.attach((_, _) async {});
      video.dispose();
      var quiet = false;
      final release = video.releaseAudio().then((_) => quiet = true);
      await Future<void>.delayed(Duration.zero);
      expect(quiet, isFalse);
      video.acknowledgeNativeQuiet(owner);
      await release;
      expect(quiet, isTrue);
    },
  );

  test('failed native suspension stays failed after widget removal', () async {
    final video = Media3MusicVideoController(trackNativeOutputQuiescence: true);
    final owner = video.attach((_, _) async {});
    video.detach(owner);
    video.acknowledgeNativeQuiet(
      owner,
      error: StateError('WebKit did not confirm'),
    );
    await expectLater(video.releaseAudio(), throwsStateError);
    video.acknowledgeNativeQuiet(
      owner,
    ); // A late callback cannot erase failure.
    await expectLater(video.releaseAudio(), throwsStateError);
    video.dispose();
  });

  test(
    'reset preserves source position and waits for native quiet without Play',
    () async {
      final video = Media3MusicVideoController(
        trackNativeOutputQuiescence: true,
      );
      addTearDown(video.dispose);
      final suspended = Completer<void>();
      final commands = <String>[];
      video.attach((method, args) {
        commands.add(method);
        expect(args, {'positionMs': 12345});
        return suspended.future;
      });
      video.update(
        positionMs: 12345,
        durationMs: 90000,
        playing: true,
        buffering: false,
      );
      var retired = false;
      final reset = video.retireForMediaReset().then((_) => retired = true);
      expect(video.positionNotifier.value, const Duration(milliseconds: 12345));
      expect(video.playingNotifier.value, isFalse);
      expect(video.advancingNotifier.value, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(retired, isFalse);
      suspended.complete();
      await reset;
      expect(video.sourcePosition, const Duration(milliseconds: 12345));
      expect(commands, ['mediaReset']);
    },
  );

  test(
    'a quiet replacement does not acknowledge an earlier removed view',
    () async {
      final video = Media3MusicVideoController(
        trackNativeOutputQuiescence: true,
      );
      addTearDown(video.dispose);
      final old = video.attach((_, _) async {});
      video.detach(old);
      video.attach((_, _) async {});
      var quiet = false;
      final release = video.releaseAudio().then((_) => quiet = true);
      await Future<void>.delayed(Duration.zero);
      expect(quiet, isFalse);
      video.acknowledgeNativeQuiet(old);
      await release;
      expect(quiet, isTrue);
    },
  );

  testWidgets('transport samples remain distinct from the smoothed UI clock', (
    tester,
  ) async {
    final video = Media3MusicVideoController();
    video.update(
      positionMs: 100,
      durationMs: 4000,
      playing: true,
      buffering: false,
    );
    // Production uses a monotonic Stopwatch; let real time advance outside
    // Flutter's fake clock before delivering the periodic UI samples.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 70)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      video.positionNotifier.value,
      greaterThan(const Duration(milliseconds: 100)),
    );
    expect(
      video.sourcePosition,
      const Duration(milliseconds: 100),
      reason: 'An interpolated UI clock cannot qualify real playback progress',
    );
    video.update(
      positionMs: 500,
      durationMs: 4000,
      playing: true,
      buffering: false,
    );
    expect(video.sourcePosition, const Duration(milliseconds: 500));
    video.dispose();
  });

  test('video clock freezes on buffering and on confirmed release', () async {
    final controller = Media3MusicVideoController();
    addTearDown(controller.dispose);
    controller.attach((_, _) async {});
    controller.update(
      positionMs: 100,
      durationMs: 1000,
      playing: true,
      buffering: true,
    );
    expect(controller.playingNotifier.value, isTrue);
    expect(controller.advancingNotifier.value, isFalse);
    controller.update(
      positionMs: 150,
      durationMs: 1000,
      playing: true,
      buffering: false,
    );
    expect(controller.advancingNotifier.value, isTrue);
    await controller.releaseAudio();
    expect(controller.advancingNotifier.value, isFalse);
  });

  test(
    'video transport and timeline stay independent from album playback',
    () async {
      final controller = Media3MusicVideoController();
      addTearDown(controller.dispose);
      final commands = <(String, Map<String, Object?>)>[];
      controller.attach((method, args) async {
        commands.add((method, args));
      });
      controller.fallback();
      expect(controller.timingAvailableNotifier.value, isFalse);
      controller.update(
        positionMs: 42000,
        durationMs: 90000,
        playing: false,
        buffering: false,
      );
      expect(
        controller.nativeNotifier.value,
        isFalse,
        reason: 'Official iframe clock is not native Media3',
      );
      expect(controller.timingAvailableNotifier.value, isTrue);
      expect(controller.positionNotifier.value, const Duration(seconds: 42));
      await controller.togglePlayPause();
      await controller.seek(const Duration(milliseconds: 12123));
      expect(commands.map((command) => command.$1), ['play', 'seek']);
      expect(commands.first.$2, isEmpty);
      expect(commands.last.$2, {'positionMs': 12123});
    },
  );

  test('an old surface cannot detach the replacement transport', () async {
    final controller = Media3MusicVideoController();
    addTearDown(controller.dispose);
    final oldLease = controller.attach((_, _) async => fail('stale transport'));
    final calls = <String>[];
    final newLease = controller.attach((method, _) async {
      calls.add(method);
    });
    controller.detach(oldLease);
    expect(controller.owns(newLease), isTrue);
    await controller.command('pause');
    expect(calls, ['pause']);
  });

  test(
    'release waits for the audio owner before allowing the caller to continue',
    () async {
      final controller = Media3MusicVideoController();
      addTearDown(controller.dispose);
      final paused = Completer<void>();
      controller.attach((method, _) {
        expect(method, 'release');
        return paused.future;
      });
      controller.update(
        positionMs: 100,
        durationMs: 1000,
        playing: true,
        buffering: false,
      );
      var released = false;
      final release = controller.releaseAudio().then((_) => released = true);
      await Future<void>.delayed(Duration.zero);
      expect(released, isFalse);
      paused.complete();
      await release;
      expect(released, isTrue);
      expect(controller.playingNotifier.value, isFalse);
    },
  );

  test(
    'failed release remains an error and cannot authorize local resume',
    () async {
      final controller = Media3MusicVideoController();
      addTearDown(controller.dispose);
      controller.attach((_, _) async => throw StateError('pause failed'));
      await expectLater(controller.releaseAudio(), throwsStateError);
    },
  );

  test(
    'late release cannot pause replacement state or touch disposed notifiers',
    () async {
      final controller = Media3MusicVideoController();
      final oldPaused = Completer<void>();
      controller.attach((_, _) => oldPaused.future);
      final release = controller.releaseAudio();
      controller.attach((_, _) async {});
      controller.update(
        positionMs: 200,
        durationMs: 1000,
        playing: true,
        buffering: false,
      );
      oldPaused.complete();
      await release;
      expect(controller.playingNotifier.value, isTrue);
      final pending = Completer<void>();
      controller.attach((_, _) => pending.future);
      final lastRelease = controller.releaseAudio();
      controller.dispose();
      pending.complete();
      await lastRelease;
    },
  );

  test(
    'commands without a live sender fail instead of reporting false success',
    () async {
      final controller = Media3MusicVideoController();
      addTearDown(controller.dispose);
      await expectLater(controller.command('play'), throwsStateError);
    },
  );
}
