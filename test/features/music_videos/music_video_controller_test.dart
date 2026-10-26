import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/music_videos/music_video_controller.dart';

void main() {
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
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 70)));
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
