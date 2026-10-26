import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/rust_audio_engine.dart';
import 'package:flick/services/rust_audio_service.dart';

class _Service implements RustAudioService {
  @override
  final stateNotifier = ValueNotifier(RustPlaybackState.idle);
  @override
  final positionNotifier = ValueNotifier(Duration.zero);
  @override
  final durationNotifier = ValueNotifier(const Duration(seconds: 8));
  @override
  final bufferLevelNotifier = ValueNotifier(1.0);
  final pauseAcknowledged = Completer<void>();
  @override
  Future<void> play(String path) async {
    stateNotifier.value = RustPlaybackState.playing;
  }

  @override
  Future<void> resume() async {
    stateNotifier.value = RustPlaybackState.playing;
  }

  @override
  Future<void> pause() async {
    await pauseAcknowledged.future;
    stateNotifier.value = RustPlaybackState.paused;
  }

  void close() {
    stateNotifier.dispose();
    positionNotifier.dispose();
    durationNotifier.dispose();
    bufferLevelNotifier.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  const song = Song(
    id: 'fixture',
    title: 'Fixture',
    artist: 'Fixture',
    duration: Duration(seconds: 8),
    fileType: 'OPUS',
    filePath: 'fixture.opus',
  );
  late _Service service;
  late RustAudioEngine engine;
  late List<PlaybackState> states;
  late StreamSubscription<PlaybackState> subscription;
  setUp(() async {
    service = _Service();
    states = [];
    engine = RustAudioEngine(
      playbackMode: AudioEngineType.iosRust,
      rustAudioService: service,
      guardPausedState: true,
      ensureInitialized: () async {},
      resolvePlaybackPath: (song) async => song.filePath,
      disposeEngine: () async {},
    );
    subscription = engine.playbackStateStream.listen(states.add);
    await engine.load(song);
    await engine.play();
    await Future<void>.delayed(Duration.zero);
    expect(states.last.isPlaying, true);
  });
  tearDown(() async {
    await subscription.cancel();
    await engine.dispose();
    service.close();
  });

  test('iPhone pause waits for acknowledgement and rejects stale playing/buffering events', () async {
    var completed = false;
    final pause = engine.pause().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, false);
    service.stateNotifier.value = RustPlaybackState.buffering;
    service.stateNotifier.value = RustPlaybackState.playing;
    service.positionNotifier.value = const Duration(seconds: 1);
    await Future<void>.delayed(Duration.zero);
    expect(states.last.isPlaying, false);
    service.pauseAcknowledged.complete();
    await pause;
    service.stateNotifier.value = RustPlaybackState.playing;
    service.bufferLevelNotifier.value = .5;
    await Future<void>.delayed(Duration.zero);
    expect(states.last.isPlaying, false);
  });

  test('a later explicit play lifts the pause guard', () async {
    service.pauseAcknowledged.complete();
    await engine.pause();
    await Future<void>.delayed(Duration.zero);
    expect(states.last.isPlaying, false);
    await engine.play();
    await Future<void>.delayed(Duration.zero);
    expect(states.last.isPlaying, true);
  });

  test(
    'failed pause propagates and restores the actual backend state',
    () async {
      final expectation = expectLater(engine.pause(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      service.pauseAcknowledged.completeError(
        StateError('worker did not acknowledge'),
      );
      await expectation;
      await Future<void>.delayed(Duration.zero);
      expect(states.last.isPlaying, true);
    },
  );
}
