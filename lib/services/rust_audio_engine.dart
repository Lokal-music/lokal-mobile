import 'package:flick/services/ios_local_audio_requests.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/audio_engine.dart';
import 'package:flick/services/rust_audio_service.dart';
import 'package:flick/services/local_audio_lifecycle.dart';

typedef RustEngineInitializer = Future<void> Function();
typedef RustEngineDisposer = Future<void> Function();
typedef RustPlaybackPathResolver = Future<String?> Function(Song track);
typedef RustHttpSourceResolver =
    Future<({String url, Map<String, String> headers})?> Function(Song track);

class RustAudioEngine implements AudioEngine {
  RustAudioEngine({
    required AudioEngineType playbackMode,
    required RustAudioService rustAudioService,
    required RustEngineInitializer ensureInitialized,
    required RustPlaybackPathResolver resolvePlaybackPath,
    required RustEngineDisposer disposeEngine,
    RustHttpSourceResolver? resolveHttpSource,
    bool? guardPausedState,
  }) : _playbackMode = playbackMode,
       _rustAudioService = rustAudioService,
       _ensureInitialized = ensureInitialized,
       _resolvePlaybackPath = resolvePlaybackPath,
       _disposeEngine = disposeEngine,
       _resolveHttpSource = resolveHttpSource,
       _guardPausedState = guardPausedState ?? Platform.isIOS;

  final AudioEngineType _playbackMode;
  final RustAudioService _rustAudioService;
  final RustEngineInitializer _ensureInitialized;
  final RustPlaybackPathResolver _resolvePlaybackPath;
  final RustEngineDisposer _disposeEngine;
  final RustHttpSourceResolver? _resolveHttpSource;
  final bool _guardPausedState;
  bool _pauseRequested = false;
  bool _retired = false;
  Future<void>? _disposal;

  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();
  final List<VoidCallback> _notifierUnsubscribers = [];
  late PlaybackState _state = PlaybackState.empty(_playbackMode);
  Song? _loadedTrack;
  Duration? _pendingSeekPosition;
  bool _initialized = false;
  Future<void>? _initInFlight;
  bool _needsFreshPlay = false;

  @override
  Stream<PlaybackState> get playbackStateStream => _controller.stream;

  Future<void> _safeEnsureInitialized() async {
    _requireLive();
    if (_initialized) return;
    final inFlight = _initInFlight;
    if (inFlight != null) {
      await _wait(inFlight);
      _requireLive();
      return;
    }
    final future = _ensureInitialized();
    _initInFlight = future;
    try {
      await _wait(future);
      _requireLive();
      _initialized = true;
    } finally {
      if (identical(_initInFlight, future)) {
        _initInFlight = null;
      }
    }
  }

  void _attachListeners() {
    _requireLive();
    if (_notifierUnsubscribers.isNotEmpty) return;

    void addListener(ValueNotifier<dynamic> notifier, VoidCallback listener) {
      notifier.addListener(listener);
      _notifierUnsubscribers.add(() => notifier.removeListener(listener));
    }

    addListener(_rustAudioService.stateNotifier, () {
      final rustState = _rustAudioService.stateNotifier.value;
      final isPlaying =
          !_pauseRequested &&
          (rustState == RustPlaybackState.playing ||
              rustState == RustPlaybackState.crossfading ||
              rustState == RustPlaybackState.buffering);
      _emit(
        _state.copyWith(
          isPlaying: isPlaying,
          isBuffering:
              !_pauseRequested && rustState == RustPlaybackState.buffering,
        ),
      );
    });

    addListener(_rustAudioService.positionNotifier, () {
      _emit(
        _state.copyWith(position: _rustAudioService.positionNotifier.value),
      );
      _syncBufferedFromLevel();
    });

    addListener(_rustAudioService.durationNotifier, () {
      _emit(
        _state.copyWith(duration: _rustAudioService.durationNotifier.value),
      );
      _syncBufferedFromLevel();
    });

    addListener(_rustAudioService.bufferLevelNotifier, _syncBufferedFromLevel);
  }

  void _syncBufferedFromLevel() {
    final level = _rustAudioService.bufferLevelNotifier.value.clamp(0.0, 1.0);
    final duration = _state.duration;
    if (duration == Duration.zero) return;
    final buffered = Duration(
      milliseconds: (duration.inMilliseconds * level).round(),
    );
    _emit(_state.copyWith(bufferedPosition: buffered));
  }

  void _emit(PlaybackState next) {
    if (_retired) return;
    if (next == _state) return;
    _state = next;
    _controller.add(next);
  }

  @override
  Future<void> load(Song track) => IosLocalAudioRequests.run(() async {
    _requireLive();
    await _wait(_safeEnsureInitialized());
    _attachListeners();
    _loadedTrack = track;
    _needsFreshPlay = true;
    _pendingSeekPosition = Duration.zero;
    _emit(
      _state.copyWith(
        currentTrack: track,
        isPlaying: false,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: track.duration,
      ),
    );
  });

  @override
  Future<void> play() => IosLocalAudioRequests.run(() async {
    _requireLive();
    _pauseRequested = false;
    await _wait(_safeEnsureInitialized());
    _attachListeners();
    final track = _loadedTrack;
    if (track == null) {
      final currentPath = _rustAudioService.currentPath;
      if (currentPath == null || currentPath.isEmpty) {
        throw StateError(
          'RustAudioEngine.play() was called before load(track) prepared a source',
        );
      }
      await _wait(_rustAudioService.resume());
      return;
    }

    final rustState = _rustAudioService.stateNotifier.value;
    if (rustState == RustPlaybackState.paused && !_needsFreshPlay) {
      await _wait(_rustAudioService.resume());
      final pendingSeek = _pendingSeekPosition;
      if (pendingSeek != null && pendingSeek > Duration.zero) {
        await _wait(_rustAudioService.seek(pendingSeek));
      }
      _pendingSeekPosition = null;
      return;
    }

    _needsFreshPlay = false;
    // ponytail: HTTP-first for network sources. Try a direct ranged stream; on
    // any failure (no ranges, auth, network) fall back to cache-then-play.
    final httpResolver = _resolveHttpSource;
    if (httpResolver != null) {
      try {
        final http = await _wait(httpResolver(track));
        if (http != null) {
          try {
            await _wait(
              _rustAudioService.playHttp(url: http.url, headers: http.headers),
            );
            await _wait(_applyInitialSeekAfterStart());
            return;
          } catch (e) {
            if (IosLocalAudioRequests.isRetired(e)) rethrow;
            debugPrint(
              '[RustAudioEngine] HTTP direct play failed, falling back to cache: $e',
            );
          }
        }
      } catch (e) {
        if (IosLocalAudioRequests.isRetired(e)) rethrow;
        debugPrint('[RustAudioEngine] HTTP source resolve failed: $e');
      }
    }

    final path = await _wait(_resolvePlaybackPath(track));
    if (path == null || path.isEmpty) {
      final sourcePath = track.filePath ?? '';
      final scheme = Uri.tryParse(sourcePath)?.scheme ?? '';
      throw StateError(
        'Failed to resolve Rust playback path for "${track.title}" '
        '(source scheme: ${scheme.isEmpty ? 'file' : scheme})',
      );
    }

    await _wait(_rustAudioService.play(path));
    await _wait(_applyInitialSeekAfterStart());
  });

  // ponytail: after a fresh source start (HTTP or path), seek to the desired
  // position. _pendingSeekPosition is the explicit deferred seek (load+seek
  // before first play); _state.position is the fallback so a seek that left
  // the engine in idle/stopped (e.g. Jellyfin range-request failure during
  // handle_seek) doesn't restart from zero on the next play(). Upgrade path:
  // surface the seek error from Rust so we can distinguish "seek landed" from
  // "seek failed and we recovered via play()" — both work today.
  Future<void> _applyInitialSeekAfterStart() async {
    final target = _pendingSeekPosition ?? _state.position;
    if (target > Duration.zero) {
      try {
        await _wait(_rustAudioService.seek(target));
      } catch (e) {
        if (IosLocalAudioRequests.isRetired(e)) rethrow;
        debugPrint('[RustAudioEngine] initial seek to $target failed: $e');
      }
    }
    _pendingSeekPosition = null;
  }

  @override
  Future<void> pause() => IosLocalAudioRequests.run(() async {
    _requireLive();
    await _wait(_safeEnsureInitialized());
    _attachListeners();
    if (_guardPausedState) {
      _pauseRequested = true;
      _emit(_state.copyWith(isPlaying: false));
    }
    try {
      await _wait(_rustAudioService.pause());
      if (_guardPausedState) _emit(_state.copyWith(isPlaying: false));
    } catch (error) {
      if (IosLocalAudioRequests.isRetired(error)) rethrow;
      _pauseRequested = false;
      final state = _rustAudioService.stateNotifier.value;
      _emit(
        _state.copyWith(
          isPlaying:
              state == RustPlaybackState.playing ||
              state == RustPlaybackState.crossfading ||
              state == RustPlaybackState.buffering,
        ),
      );
      rethrow;
    }
  });

  @override
  Future<void> stop() => IosLocalAudioRequests.run(() async {
    _requireLive();
    await _wait(_safeEnsureInitialized());
    _attachListeners();
    await _wait(_rustAudioService.stop());
  });

  @override
  Future<void> seek(Duration position) => IosLocalAudioRequests.run(() async {
    _requireLive();
    await _wait(_safeEnsureInitialized());
    _attachListeners();
    _pendingSeekPosition = position;
    _emit(_state.copyWith(position: position));

    final rustState = _rustAudioService.stateNotifier.value;
    final canSeekImmediately =
        rustState == RustPlaybackState.playing ||
        rustState == RustPlaybackState.paused ||
        rustState == RustPlaybackState.buffering ||
        rustState == RustPlaybackState.crossfading;
    if (!canSeekImmediately) {
      return;
    }

    await _wait(_rustAudioService.seek(position));
    _pendingSeekPosition = null; // ponytail: immediate seek applied; clears stale value so resume() won't re-seek backward
  });

  @override
  void updateTrack(Song track) {
    _requireLive();
    _loadedTrack = track;
    _emit(_state.copyWith(currentTrack: track, duration: track.duration));
  }

  @override
  Future<void> dispose() {
    _retired = true;
    return _disposal ??= _dispose();
  }

  Future<T> _wait<T>(Future<T> result) async {
    final value = await IosLocalAudioRequests.wait(result);
    _requireLive();
    return value;
  }

  void _requireLive() {
    if (_retired) throw const LocalAudioRequestRetired();
  }

  Future<void> _dispose() async {
    for (final remove in _notifierUnsubscribers) {
      remove();
    }
    _notifierUnsubscribers.clear();
    final initializing = _initInFlight;
    if (initializing != null) {
      try {
        await initializing;
      } catch (error) {
        if (!IosLocalAudioRequests.isRetired(error)) rethrow;
      }
    }
    await _disposeEngine();
    await _controller.close();
  }
}
