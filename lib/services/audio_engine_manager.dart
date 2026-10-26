import 'dart:async';

import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/audio_engine.dart';
import 'package:flick/core/utils/dev_log.dart';

class AudioEngineTransitionRetired implements Exception {
  const AudioEngineTransitionRetired();
}

class AudioEngineManager {
  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();

  Stream<PlaybackState> get playbackState => _controller.stream;
  PlaybackState? get latestState => _latestState;
  AudioEngineType? get activeEngineType => _currentEngineType;
  bool get hasAttachedEngine => _currentEngine != null;

  AudioEngine? _currentEngine;
  StreamSubscription<PlaybackState>? _engineSubscription;
  PlaybackState? _latestState;
  AudioEngineType? _currentEngineType;
  bool _engineInitialized = false;
  bool _engineHasLoadedTrack = false;
  Future<void>? _transitionInFlight;
  int _attachToken = 0;
  int _retirementRevision = 0;
  bool _retiring = false;
  Future<void>? _retirementInFlight;
  final _attachments = <Future<void>>{};
  final _transitions = <Future<void>>{};
  final _disposals = Expando<Future<void>>();

  bool get canResumeCurrentTrack => _engineHasLoadedTrack;

  /// An asynchronous decoder/source error invalidates the resume shortcut.
  void invalidateLoadedTrack() => _engineHasLoadedTrack = false;

  Future<void> attachEngine(
    AudioEngine engine, {
    AudioEngineType? engineType,
    bool disposePrevious = true,
  }) {
    final work = _attachEngine(
      engine,
      engineType: engineType,
      disposePrevious: disposePrevious,
    );
    _attachments.add(work);
    return work.whenComplete(() => _attachments.remove(work));
  }

  Future<void> _attachEngine(
    AudioEngine engine, {
    AudioEngineType? engineType,
    required bool disposePrevious,
  }) async {
    final revision = _retirementRevision;
    if (_retiring) {
      await _disposeOnce(engine);
      throw const AudioEngineTransitionRetired();
    }
    if (identical(engine, _currentEngine)) {
      return;
    }

    final previousEngine = _currentEngine;
    final previousSubscription = _engineSubscription;
    _currentEngine = engine;

    await previousSubscription?.cancel();
    if (disposePrevious && previousEngine != null) {
      await _disposeOnce(previousEngine);
    }
    if (revision != _retirementRevision) {
      await _disposeOnce(engine);
      throw const AudioEngineTransitionRetired();
    }

    _attachToken += 1;
    final activeToken = _attachToken;
    final engineLabel = engineType == null
        ? engine.runtimeType.toString()
        : engineType.logLabel;
    _currentEngineType = engineType;
    _engineInitialized = true;
    _engineHasLoadedTrack = false;
    devLog('[Engine] Attached: $engineLabel');

    if (engineType != null) {
      // Preserve the last-known track while the engine is initialising so the
      // UI (mini-player, ambient background) doesn't flash to empty/black.
      final transitional = PlaybackState(
        currentTrack: _latestState?.currentTrack,
        isPlaying: false,
        position: _latestState?.position ?? Duration.zero,
        bufferedPosition: Duration.zero,
        duration: _latestState?.duration ?? Duration.zero,
        engine: engineType,
      );
      _latestState = transitional;
      _controller.add(transitional);
    }

    _engineSubscription = engine.playbackStateStream.listen((state) {
      if (activeToken != _attachToken) return;
      _latestState = state;
      _controller.add(state);
    });
  }

  Future<void> ensureEngine({
    required AudioEngineType engineType,
    required Future<AudioEngine> Function() createEngine,
  }) async {
    final revision = _retirementRevision;
    _checkRevision(revision);
    if (_engineInitialized &&
        _currentEngine != null &&
        _currentEngineType == engineType) {
      devLog('[Engine] Prevented duplicate initialization');
      return;
    }

    final inFlight = _transitionInFlight;
    if (inFlight != null) {
      devLog('[Engine] Waiting for in-flight engine transition to complete');
      await inFlight;
      _checkRevision(revision);
      if (_engineInitialized &&
          _currentEngine != null &&
          _currentEngineType == engineType) {
        return;
      }
    }

    final future = _doEnsureEngine(engineType, createEngine, revision);
    _transitionInFlight = future;
    _transitions.add(future);
    try {
      await future;
    } finally {
      _transitions.remove(future);
      if (identical(_transitionInFlight, future)) {
        _transitionInFlight = null;
      }
    }
  }

  Future<void> _doEnsureEngine(
    AudioEngineType engineType,
    Future<AudioEngine> Function() createEngine,
    int revision,
  ) async {
    final engine = await createEngine();
    if (revision != _retirementRevision || _retiring) {
      await _disposeOnce(engine);
      throw const AudioEngineTransitionRetired();
    }
    await attachEngine(engine, engineType: engineType);
  }

  void _checkRevision(int revision) {
    if (_retiring || revision != _retirementRevision) {
      throw const AudioEngineTransitionRetired();
    }
  }

  Future<void> _disposeOnce(AudioEngine engine) =>
      _disposals[engine] ??= Future<void>.sync(engine.dispose);

  /// Immediately invalidate pending attachment/publication, retain the last
  /// track and position paused, then await every old native candidate. A timeout
  /// is not proof of disposal. Cleanup failures leave replacement blocked.
  Future<void> retireLocalOutputs() {
    final inFlight = _retirementInFlight;
    if (inFlight != null) return inFlight;
    _retiring = true;
    _retirementRevision++;
    _attachToken++;
    final engine = _currentEngine;
    final subscription = _engineSubscription;
    final pending = [..._attachments, ..._transitions];
    _currentEngine = null;
    _engineSubscription = null;
    _currentEngineType = null;
    _engineInitialized = false;
    _engineHasLoadedTrack = false;
    _transitionInFlight = null;
    final state = _latestState;
    if (state != null) {
      _latestState = state.copyWith(isPlaying: false);
      _controller.add(_latestState!);
    }
    final work =
        Future.wait<void>([
          if (subscription != null) subscription.cancel(),
          if (engine != null) _disposeOnce(engine),
          for (final future in pending)
            future.onError<AudioEngineTransitionRetired>((_, _) {}),
        ]).then<void>((_) {
          _retiring = false;
        });
    _retirementInFlight = work;
    // Keep a failed retirement retained; later calls cannot claim it succeeded.
    work.then<void>(
      (_) => _retirementInFlight = null,
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }

  Future<void> playTrack(
    Song track, {
    Duration initialPosition = Duration.zero,
    bool autoPlay = true,
  }) async {
    final revision = _retirementRevision;
    final engine = _requireEngine();
    devLog('[Playback] load(${track.id})');
    _engineHasLoadedTrack = false;
    await engine.load(track);
    _checkRevision(revision);
    _engineHasLoadedTrack = true;
    if (initialPosition > Duration.zero) {
      await engine.seek(initialPosition);
      _checkRevision(revision);
    }
    if (autoPlay) {
      devLog('[Playback] play()');
      await engine.play();
    }
  }

  void publishIdleState(AudioEngineType engineType) {
    if (_currentEngine != null) {
      return;
    }

    final idleState = PlaybackState.empty(engineType);
    if (_latestState == idleState) {
      return;
    }

    _currentEngineType = engineType;
    _latestState = idleState;
    _controller.add(idleState);
  }

  Future<void> load(Song track) async {
    final revision = _retirementRevision;
    final engine = _requireEngine();
    devLog('[Playback] load(${track.id})');
    _engineHasLoadedTrack = false;
    await engine.load(track);
    _checkRevision(revision);
    _engineHasLoadedTrack = true;
  }

  Future<void> play() async {
    final engine = _requireEngine();
    devLog('[Playback] play()');
    await engine.play();
  }

  Future<void> pause() async {
    final engine = _requireEngine();
    devLog('[Playback] pause()');
    await engine.pause();
  }

  Future<void> stop() async {
    final engine = _requireEngine();
    _engineHasLoadedTrack = false;
    await engine.stop();
  }

  Future<void> seek(Duration position) async {
    final engine = _requireEngine();
    await engine.seek(position);
  }

  void updateTrack(Song track) {
    final engine = _currentEngine;
    if (engine != null) {
      engine.updateTrack(track);
    }
  }

  Future<void> dispose() async {
    await _engineSubscription?.cancel();
    _engineSubscription = null;
    if (_currentEngine != null) {
      await _disposeOnce(_currentEngine!);
      _currentEngine = null;
    }
    _currentEngineType = null;
    _engineInitialized = false;
    _engineHasLoadedTrack = false;
    await _controller.close();
  }

  Future<void> detachEngine({bool disposeCurrent = true}) async {
    final revision = _retirementRevision;
    final previousEngineType = _currentEngineType;
    await _engineSubscription?.cancel();
    if (revision != _retirementRevision) return;
    _engineSubscription = null;
    if (disposeCurrent && _currentEngine != null) {
      await _disposeOnce(_currentEngine!);
    }
    if (revision != _retirementRevision) return;
    _currentEngine = null;
    _currentEngineType = null;
    _engineInitialized = false;
    _engineHasLoadedTrack = false;
    _attachToken += 1;
    if (previousEngineType != null) {
      publishIdleState(previousEngineType);
    }
  }

  AudioEngine _requireEngine() {
    final engine = _currentEngine;
    if (engine == null) {
      throw StateError('No audio engine attached');
    }
    return engine;
  }
}
