import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/ios_local_audio_requests.dart';
import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/src/rust/api/audio_api.dart' as native_audio;

const _ios = MethodChannel('lokal/ios');

Future<void> _awaitPhase(WidgetTester tester, LocalAudioPhase phase) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (IosLocalAudioRequests.lifecycle.phase.value == phase) return;
    expect(
      IosLocalAudioRequests.lifecycle.phase.value,
      isNot(LocalAudioPhase.blocked),
      reason: '${IosLocalAudioRequests.lifecycle.cleanupError}',
    );
  }
  fail(
    'Audio did not reach $phase: ${IosLocalAudioRequests.lifecycle.phase.value}',
  );
}

/// Posts the real AVAudioSession notification inside the app. This exercises
/// observer/FFI/AVPlayer/Core Audio paths, not an actual media-daemon restart.
Future<void> probeIosMediaReset(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  PlayerService player, {
  required AudioEngineType engine,
  required Song song,
  required Future<int> Function() expectProgress,
}) async {
  final lifecycle = IosLocalAudioRequests.lifecycle;
  expect(IosLocalAudioRequests.isObserving, isTrue);
  expect(player.currentEngineType, engine);
  final position = player.positionNotifier.value;
  final playlist = player.playlist.map((s) => s.id).toList();
  final loop = player.loopModeNotifier.value;
  final shuffle = player.shuffleModeNotifier.value;
  final speed = player.playbackSpeedNotifier.value;
  final epoch = lifecycle.epoch;
  await _ios.invokeMethod<void>('postMediaServicesResetForIntegrationTest');
  await _awaitPhase(tester, LocalAudioPhase.paused);
  expect(lifecycle.epoch, epoch + BigInt.one);
  expect(player.isPlayingNotifier.value, isFalse);
  expect(player.currentSongNotifier.value?.id, song.id);
  expect(player.playlist.map((s) => s.id).toList(), playlist);
  expect(
    player.positionNotifier.value.inMilliseconds,
    inInclusiveRange(
      (position.inMilliseconds - 250).clamp(0, 10000000),
      position.inMilliseconds + 1000,
    ),
  );
  expect(player.loopModeNotifier.value, loop);
  expect(player.shuffleModeNotifier.value, shuffle);
  expect(player.playbackSpeedNotifier.value, speed);
  final pausedAt = player.positionNotifier.value;
  await tester.pump(const Duration(milliseconds: 750));
  expect(player.isPlayingNotifier.value, isFalse);
  expect(player.positionNotifier.value, pausedAt);
  await binding.takeScreenshot('ios-reset-${engine.name}-paused');

  // A second reset while paused must also stay paused. A seek retains intent
  // without constructing an output before the subsequent explicit Play.
  await _ios.invokeMethod<void>('postMediaServicesResetForIntegrationTest');
  await _awaitPhase(tester, LocalAudioPhase.paused);
  expect(lifecycle.epoch, epoch + BigInt.two);
  expect(player.isPlayingNotifier.value, isFalse);
  await player.seek(const Duration(seconds: 1));
  expect(player.isPlayingNotifier.value, isFalse);
  await player.resume();
  final progress = await expectProgress();
  expect(player.currentEngineType, engine);
  expect(lifecycle.phase.value, LocalAudioPhase.ready);
  binding.reportData!['media_reset_${engine.name}'] = {
    'scope': 'Posted AVAudioSession notifications; not a daemon restart',
    'notifications': 2,
    'queue_and_preferences_retained': true,
    'playing_and_paused_preserved': true,
    'explicit_play_progress_ms': progress,
  };
}

Future<void> probeIosNewSelectionDuringReset(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  PlayerService player,
  Song original, {
  required Future<int> Function() expectProgress,
}) async {
  final lifecycle = IosLocalAudioRequests.lifecycle;
  final acknowledged = Completer<void>();
  final owner = Object();
  lifecycle.register(owner, () => acknowledged.future);
  final selected = original.copyWith(
    id: 'ios-reset-new-selection',
    title: 'New selection during audio recovery',
  );
  try {
    await _ios.invokeMethod<void>('postMediaServicesResetForIntegrationTest');
    await _awaitPhase(tester, LocalAudioPhase.recovering);
    final pending = player.play(selected, playlist: [original, selected]);
    await tester.pump(const Duration(milliseconds: 250));
    expect(player.currentSongNotifier.value?.id, selected.id);
    expect(player.isPlayingNotifier.value, isFalse);
    await binding.takeScreenshot('ios-reset-new-selection-recovering');
    await _ios.invokeMethod<void>('postMediaServicesResetForIntegrationTest');
    await tester.pump(const Duration(milliseconds: 250));
    // The superseded Play returns without waiting for the artificial gate.
    await pending.timeout(const Duration(seconds: 2));
    acknowledged.complete();
    await _awaitPhase(tester, LocalAudioPhase.paused);
    expect(player.currentSongNotifier.value?.id, selected.id);
    expect(player.playlist.map((s) => s.id).toList(), [
      original.id,
      selected.id,
    ]);
    expect(player.isPlayingNotifier.value, isFalse);
    expect(player.positionNotifier.value, Duration.zero);
    await player.resume();
    binding.reportData!['media_reset_newer_selection'] = {
      'scope': 'Real native disposal plus controlled acknowledgement gate',
      'repeat_reset_retires_waiting_play': true,
      'new_selection_retained_paused': true,
      'explicit_play_progress_ms': await expectProgress(),
    };
  } finally {
    if (!acknowledged.isCompleted) acknowledged.complete();
    lifecycle.unregister(owner);
  }
}

/// Holds a real native HTTP probe across reset and confirmed replacement.
/// The old FFI future is observed directly so only Rust's fence can reject it.
Future<void> probeIosDelayedHttpReset(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  PlayerService player,
  File wav, {
  required Future<int> Function() expectProgress,
}) async {
  final bytes = await wav.readAsBytes();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final entered = Completer<void>();
  final release = Completer<void>();
  final requests = <Future<void>>[];
  final listener = server.listen((request) {
    final handling = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      final start = match == null ? 0 : int.parse(match.group(1)!);
      final end = match == null || match.group(2)!.isEmpty
          ? bytes.length - 1
          : int.parse(match.group(2)!).clamp(0, bytes.length - 1);
      if (start > end || start >= bytes.length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      } else {
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'audio/wav',
        );
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (match != null) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          );
        }
        request.response.contentLength = end - start + 1;
        if (request.method != 'HEAD')
          request.response.add(bytes.sublist(start, end + 1));
      }
      await request.response.close();
    }();
    // Observe disconnects immediately; this fixture owns every handler.
    requests.add(
      handling.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  });
  try {
    final old = native_audio.audioPlayFromHttp(
      url: 'http://127.0.0.1:${server.port}/delayed.wav',
      headers: const {},
      requestEpoch: native_audio.audioLocalRequestEpoch(),
    );
    final settled = old.then<Object?>(
      (_) => null,
      onError: (Object error, StackTrace _) => error,
    );
    for (var i = 0; i < 40 && !entered.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(
      entered.isCompleted,
      isTrue,
      reason: 'Native HTTP probe did not reach fixture',
    );
    await _ios.invokeMethod<void>('postMediaServicesResetForIntegrationTest');
    await _awaitPhase(tester, LocalAudioPhase.paused);
    await player.seek(const Duration(seconds: 1));
    await player.resume();
    await expectProgress();
    final replacementPosition = player.positionNotifier.value;
    release.complete();
    final oldResult = await settled.timeout(const Duration(seconds: 15));
    expect(oldResult.toString(), contains('AUDIO_LOCAL_REQUEST_RETIRED'));
    expect(player.isPlayingNotifier.value, isTrue);
    expect(
      player.positionNotifier.value.inMilliseconds,
      greaterThanOrEqualTo(replacementPosition.inMilliseconds - 150),
    );
    binding.reportData!['media_reset_late_native_http'] = {
      'scope': 'Real loopback HTTP probe through FRB and Rust',
      'old_request_rejected_after_new_output': true,
      'replacement_progress_ms': await expectProgress(),
    };
  } finally {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
    await listener.cancel();
    await Future.wait(requests);
  }
}
