import 'dart:async';

import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/features/music_videos/music_video_controller.dart';
import 'package:flick/features/music_videos/music_video_surface.dart';
import 'package:flick/features/player/widgets/video_space_layout.dart';
import 'package:flick/services/ios_local_audio_requests.dart';
import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/widgets/common/ios_audio_recovery_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/fixtures/native_web_video_document.dart';
import 'native_probe_cleanup.dart';

/// Real WKWebView, generated H.264/AAC and the exact production iframe bridge.
/// This establishes local decoder/retirement behavior, not YouTube acceptance.
Future<void> probeIosWebKitReset(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  PlayerService player,
) async {
  final video = Media3MusicVideoController(trackNativeOutputQuiescence: true);
  final space = ValueNotifier(false);
  final key = GlobalKey();
  final views = <InAppWebViewController>[];
  final lifecycle = IosLocalAudioRequests.lifecycle;
  await player.pause();
  final lease = await player.acquireExternalPlayback(
    video.releaseAudio,
    onMediaReset: video.retireForMediaReset,
  );

  final clock = Stopwatch()..start();
  final trace = <Map<String, Object?>>[];
  Map<String, Object?> observation(String event) => {
    'event': event,
    'elapsed_ms': clock.elapsedMilliseconds,
    'epoch': lifecycle.epoch.toString(),
    'phase': lifecycle.phase.value.name,
    'cleanup_error': lifecycle.cleanupError?.toString(),
    'views': views.length,
    'timing_available': video.timingAvailableNotifier.value,
    'playing': video.playingNotifier.value,
    'source_ms': video.sourcePosition.inMilliseconds,
    'embed_error': video.embedErrorNotifier.value,
  };
  void changed() {
    trace.add(observation('state'));
    if (trace.length > 64) trace.removeAt(0);
  }

  lifecycle.phase.addListener(changed);
  video.timingAvailableNotifier.addListener(changed);
  binding.reportData!['media_reset_webkit_retirement_trace'] = trace;

  Future<void> until(
    FutureOr<bool> Function() ready,
    String reason, {
    bool coldBootstrap = false,
  }) async {
    // Build 72's native log measures a 23.029-second WebContent launch on a
    // fresh iOS 26 simulator; build 73 also delays a replacement document.
    // Give new WebContent documents a separate bounded readiness budget.
    // Native retirement and subsequent seek/frame gates retain their limits.
    final deadline = Stopwatch()..start();
    final attempts = coldBootstrap ? 180 : 60;
    Object? pollingError;
    StackTrace? pollingStack;
    try {
      for (var i = 0; i < attempts; i++) {
        if (coldBootstrap && deadline.elapsed >= const Duration(seconds: 45)) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          lifecycle.phase.value,
          isNot(LocalAudioPhase.blocked),
          reason: '$reason: ${lifecycle.cleanupError}',
        );
        expect(
          video.embedErrorNotifier.value,
          isNull,
          reason: '$reason: generated local media did not become playable',
        );
        if (await ready()) return;
      }
    } catch (error, stack) {
      pollingError = error;
      pollingStack = stack;
    }
    final diagnostics = observation(reason);
    diagnostics['gate_elapsed_ms'] = deadline.elapsedMilliseconds;
    diagnostics['cold_bootstrap'] = coldBootstrap;
    if (pollingError != null) {
      diagnostics['polling_error'] = pollingError.toString();
    }
    if (views.isNotEmpty) {
      try {
        diagnostics['native_sample'] = await views.last
            .evaluateJavascript(
              source: 'window.__lokalNativeVideoSnapshot && window.__lokalNativeVideoSnapshot()',
            )
            .timeout(const Duration(seconds: 2));
      } catch (error) {
        diagnostics['native_probe_error'] = error.toString();
      }
      // Native load progress remains useful when the WebContent process never
      // answers JavaScript. One failed diagnostic must not skip the other.
      try {
        diagnostics['native_load_progress'] = await views.last
            .getProgress()
            .timeout(const Duration(seconds: 2));
      } catch (error) {
        diagnostics['native_load_progress_error'] = error.toString();
      }
    }
    binding.reportData!['media_reset_webkit_gate_timeout'] = diagnostics;
    try {
      await binding
          .takeScreenshot('ios-webkit-gate-timeout')
          .timeout(const Duration(seconds: 5));
    } catch (error) {
      diagnostics['failure_screenshot_error'] = error.toString();
    }
    if (pollingError != null) {
      Error.throwWithStackTrace(pollingError, pollingStack!);
    }
    fail(reason);
  }

  Future<Map> nativeSnapshot() async {
    final value = await views.last
        .evaluateJavascript(
          source: 'window.__lokalNativeVideoSnapshot && window.__lokalNativeVideoSnapshot()',
        )
        .timeout(const Duration(seconds: 2));
    expect(value, isA<Map>());
    return value as Map;
  }

  Future<int> progress(String stage) async {
    // A retained seek target is an intent, not elapsed playback. Establish
    // progress baselines only after the actual native seek has completed.
    await until(() async {
      final sample = await nativeSnapshot();
      binding.reportData!['media_reset_webkit_seek_observation'] = {
        'stage': stage,
        'native_sample': Map<String, dynamic>.from(sample),
      };
      return sample['seeking'] == false &&
          sample['pendingSeekSeconds'] == null &&
          ((sample['readyState'] as num?) ?? 0) >= 3 &&
          sample['state'] == 1;
    }, 'Native WebKit seek must complete before playback progress is measured');
    final before = video.sourcePosition;
    final initialFrame = await nativeSnapshot();
    final beforeFrames = (initialFrame['frames'] as num?) ?? 0;
    final beforeMediaTime = (initialFrame['position'] as num?) ?? 0;
    final beforePresentedTime =
        (initialFrame['presentedMediaTime'] as num?) ?? 0;
    Map snapshot = initialFrame;
    await until(() async {
      snapshot = await nativeSnapshot();
      binding.reportData!['media_reset_webkit_last_frame_observation'] = {
        'stage': stage,
        'before_frames': beforeFrames,
        'before_media_time': beforeMediaTime,
        'bridge_progress_ms': (video.sourcePosition - before).inMilliseconds,
        'native_sample': Map<String, dynamic>.from(snapshot),
      };
      return video.playingNotifier.value &&
          snapshot['state'] == 1 &&
          video.sourcePosition - before > const Duration(milliseconds: 350) &&
          ((snapshot['position'] as num?) ?? 0) - beforeMediaTime > .350 &&
          ((snapshot['frames'] as num?) ?? 0) - beforeFrames > 2 &&
          (snapshot['frameCallbackSupported'] != true ||
              ((snapshot['presentedMediaTime'] as num?) ?? 0) -
                      beforePresentedTime >
                  .250);
    }, 'Real WebKit must advance both source time and newly delivered frames');
    expect(snapshot['state'], 1);
    expect(
      (snapshot['frames'] as num) - beforeFrames,
      greaterThan(2),
      reason: 'The real WebKit video decoder must deliver new frames',
    );
    return (video.sourcePosition - before).inMilliseconds;
  }

  Widget surface() => MusicVideoSurface.forNativeAcceptance(
    key: key,
    videoId: 'abcdefghijk',
    controller: video,
    document: nativeWebVideoFixtureDocument,
    onViewCreated: (view) {
      views.add(view);
      trace.add(observation('view_created'));
      if (trace.length > 64) trace.removeAt(0);
    },
    onNavigationEvent: (view, event, progress) {
      trace.add({
        ...observation(event),
        'native_view': views.indexOf(view) + 1,
        'load_progress': ?progress,
      });
      if (trace.length > 64) trace.removeAt(0);
    },
  );

  await runNativeProbeWithCleanup(
    name: 'media_reset_webkit',
    report: binding.reportData!,
    body: () async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: IosAudioRecoveryHost(
              child: ValueListenableBuilder(
                valueListenable: space,
                builder: (context, active, _) => active
                    ? VideoSpaceLayout(
                        player: surface(),
                        subtitles: const Text('Generated local video'),
                        onExit: () => space.value = false,
                        onOptions: () {},
                      )
                    : Center(
                        child: SizedBox(
                          width: 320,
                          height: 320,
                          child: surface(),
                        ),
                      ),
              ),
            ),
          ),
        ),
      );
      await until(
        () => video.timingAvailableNotifier.value && views.length == 1,
        'Production video bridge did not observe the local decoder',
        coldBootstrap: true,
      );
      binding.reportData!['media_reset_webkit_initial_ready_ms'] =
          clock.elapsedMilliseconds;
      final initialProgress = await progress('initial');
      final presentation = key.currentState;
      space.value = true;
      await tester.pump();
      expect(key.currentState, same(presentation));
      expect(
        views,
        hasLength(1),
        reason: 'Space must retain the same native view',
      );
      final before = video.sourcePosition;
      final oldView = views.single;
      await const MethodChannel('lokal/ios')
          .invokeMethod<void>('postMediaServicesResetForIntegrationTest');
      await until(
        () =>
            lifecycle.phase.value == LocalAudioPhase.paused &&
            views.length == 2,
        'WebKit reset did not acknowledge retirement and create a paused replacement',
      );
      await until(
        () => video.timingAvailableNotifier.value && views.length == 2,
        'Replacement WebKit document did not observe the local decoder',
        coldBootstrap: true,
      );
      expect(views.last, isNot(same(oldView)));
      expect(key.currentState, same(presentation));
      expect(space.value, isTrue);
      expect(
        lease.isReleased,
        isFalse,
        reason: 'Retain selected video ownership',
      );
      expect(
        video.sourcePosition.inMilliseconds,
        inInclusiveRange(
          (before.inMilliseconds - 350).clamp(0, 12000),
          before.inMilliseconds + 1000,
        ),
      );
      expect(video.playingNotifier.value, isFalse);
      final pausedAt = video.sourcePosition;
      await tester.pump(const Duration(milliseconds: 750));
      expect(video.playingNotifier.value, isFalse);
      expect(
        (video.sourcePosition - pausedAt).abs(),
        lessThan(const Duration(milliseconds: 100)),
      );
      binding.reportData!['media_reset_webkit_paused_native_sample'] =
          Map<String, dynamic>.from(await nativeSnapshot());
      await binding.takeScreenshot('ios-webkit-reset-paused-space');
      await video.command('play');
      final replayProgress = await progress('explicit-replay');
      expect(lifecycle.phase.value, LocalAudioPhase.ready);

      await video.command('pause');
      await until(
        () => !video.playingNotifier.value,
        'Native video Pause not observed',
      );
      final pausedBeforeSecondReset = video.sourcePosition;
      await const MethodChannel('lokal/ios')
          .invokeMethod<void>('postMediaServicesResetForIntegrationTest');
      await until(
        () =>
            lifecycle.phase.value == LocalAudioPhase.paused &&
            views.length == 3,
        'Repeated paused video reset did not reconstruct the selected source',
      );
      await until(
        () => video.timingAvailableNotifier.value && views.length == 3,
        'Repeated replacement WebKit document did not observe the local decoder',
        coldBootstrap: true,
      );
      expect(key.currentState, same(presentation));
      expect(video.playingNotifier.value, isFalse);
      expect(
        (video.sourcePosition - pausedBeforeSecondReset).abs(),
        lessThan(const Duration(milliseconds: 350)),
      );
      expect(player.isPlayingNotifier.value, isFalse);
      binding.reportData!['media_reset_webkit_local_video'] = {
        'scope': 'Generated H.264/AAC decoded by real WKWebView; controlled provider API, not YouTube or a daemon restart',
        'native_views_created': views.length,
        'initial_progress_ms': initialProgress,
        'explicit_replay_progress_ms': replayProgress,
        'space_and_selected_video_retained': true,
        'playing_and_paused_reset_preserved': true,
        'native_cleanup_acknowledged': true,
      };
    },
    cleanup: {
      'native_release': () =>
          lease.release().timeout(const Duration(seconds: 12)),
      'unmount': () => tester.pumpWidget(const SizedBox.shrink()),
      'remove_lifecycle_listener': () async =>
          lifecycle.phase.removeListener(changed),
      'remove_timing_listener': () async =>
          video.timingAvailableNotifier.removeListener(changed),
      'dispose_video': () async => video.dispose(),
      'dispose_space': () async => space.dispose(),
    },
  );
}
