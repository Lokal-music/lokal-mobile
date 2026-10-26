import 'dart:async';

import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/audio_engine.dart';
import 'package:flick/services/audio_engine_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _Engine implements AudioEngine {
  final states = StreamController<PlaybackState>.broadcast();
  Completer<void>? disposal;
  Completer<void>? loading;
  Object? disposalError;
  int disposals = 0;
  int plays = 0;

  @override
  Stream<PlaybackState> get playbackStateStream => states.stream;
  @override
  Future<void> load(Song track) async => loading?.future;
  @override
  Future<void> play() async => plays++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {
    disposals++;
    await disposal?.future;
    if (disposalError != null) throw disposalError!;
  }

  @override
  void updateTrack(Song track) {}
}

void main() {
  late AudioEngineManager manager;
  setUp(() => manager = AudioEngineManager());
  tearDown(() => manager.dispose());

  test(
    'pending factory must retire its candidate before cleanup completes',
    () async {
      final factory = Completer<AudioEngine>();
      final candidate = _Engine()..disposal = Completer<void>();
      final transition = manager.ensureEngine(
        engineType: AudioEngineType.values.first,
        createEngine: () => factory.future,
      );
      final rejected = expectLater(
        transition,
        throwsA(isA<AudioEngineTransitionRetired>()),
      );
      final cleanup = manager.retireLocalOutputs();
      var cleaned = false;
      cleanup.then((_) => cleaned = true);
      factory.complete(candidate);
      await Future<void>.delayed(Duration.zero);
      expect(candidate.disposals, 1);
      expect(cleaned, isFalse);
      candidate.disposal!.complete();
      await cleanup;
      await rejected;
      expect(manager.hasAttachedEngine, isFalse);
      expect(manager.canResumeCurrentTrack, isFalse);
    },
  );

  test(
    'retirement during previous disposal cannot attach a new engine',
    () async {
      final previous = _Engine()..disposal = Completer<void>();
      final candidate = _Engine();
      await manager.attachEngine(previous);
      final attach = manager.attachEngine(candidate);
      final rejected = expectLater(
        attach,
        throwsA(isA<AudioEngineTransitionRetired>()),
      );
      final cleanup = manager.retireLocalOutputs();
      expect(identical(cleanup, manager.retireLocalOutputs()), isTrue);
      previous.disposal!.complete();
      await cleanup;
      await rejected;
      expect(previous.disposals, 1);
      expect(candidate.disposals, 1);
      expect(manager.hasAttachedEngine, isFalse);
    },
  );

  test('late load cannot auto-play or restore the resume shortcut', () async {
    final engine = _Engine()..loading = Completer<void>();
    await manager.attachEngine(engine);
    final play = manager.playTrack(
      Song(
        id: 'retained-song',
        title: 'Song',
        artist: 'Artist',
        duration: const Duration(seconds: 30),
        fileType: 'FLAC',
      ),
    );
    final rejected = expectLater(
      play,
      throwsA(isA<AudioEngineTransitionRetired>()),
    );
    await manager.retireLocalOutputs();
    engine.loading!.complete();
    await rejected;
    expect(engine.plays, 0);
    expect(manager.canResumeCurrentTrack, isFalse);
  });

  test(
    'latest song/position survive paused; old engine events are ignored',
    () async {
      final engine = _Engine();
      await manager.attachEngine(engine);
      final song = Song(
        id: 'keep-id',
        title: 'Song',
        artist: 'Artist',
        duration: const Duration(seconds: 30),
        fileType: 'FLAC',
      );
      final state = PlaybackState.empty(AudioEngineType.values.first).copyWith(
        currentTrack: song,
        position: const Duration(seconds: 12),
        isPlaying: true,
      );
      engine.states.add(state);
      await Future<void>.delayed(Duration.zero);
      await manager.retireLocalOutputs();
      engine.states.add(state);
      await Future<void>.delayed(Duration.zero);
      expect(manager.latestState!.currentTrack!.id, 'keep-id');
      expect(manager.latestState!.position, const Duration(seconds: 12));
      expect(manager.latestState!.isPlaying, isFalse);
    },
  );

  test('failed destruction keeps replacement blocked and is not retried as success', () async {
    final engine = _Engine()
      ..disposalError = StateError('native disposal failed');
    await manager.attachEngine(engine);
    final cleanup = manager.retireLocalOutputs();
    await expectLater(cleanup, throwsStateError);
    expect(identical(cleanup, manager.retireLocalOutputs()), isTrue);
    var created = false;
    await expectLater(
      manager.ensureEngine(
        engineType: AudioEngineType.values.first,
        createEngine: () async {
          created = true;
          return _Engine();
        },
      ),
      throwsA(isA<AudioEngineTransitionRetired>()),
    );
    expect(created, isFalse);
    expect(engine.disposals, 1);
  });
}
