import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/audio_engine.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/services/atmos_diagnostics.dart';

/// A queue entry's identity includes the actual encoded media source. Two
/// versions of the same catalogue song can share an ID but not a decoder or
/// cached URL. Reusing the old playlist here silently plays the wrong track.
@visibleForTesting
String androidAudioSourceIdentity(Song song) =>
    jsonEncode([song.id, song.filePath, song.atmosEncoded, song.fileType]);

@visibleForTesting
bool shouldResetAndroidAtmosDecoder(Song? previous, Song next) =>
    previous != null && previous.atmosEncoded != next.atmosEncoded;

typedef AndroidAudioSourcesBuilder = Future<just_audio.AudioSource> Function();
typedef AndroidAudioSourceBuilder = Future<just_audio.AudioSource> Function(
  Song track,
);
typedef AndroidPlaylistProvider = List<Song> Function();
typedef AndroidPlayerProvider = Future<just_audio.AudioPlayer> Function();
typedef AndroidPlayerConfigurator = Future<void> Function(
  just_audio.AudioPlayer player,
);
typedef AndroidEngineDisposer = Future<void> Function();
typedef AndroidStalledPlayerRetirer = Future<void> Function(
  just_audio.AudioPlayer player,
);
typedef AndroidTrackSyncBlocker = bool Function();
typedef AndroidTrackIgnorePredicate = bool Function(Song track);
typedef AndroidFastStartPredicate = bool Function();
typedef AndroidCrossfadeConfigProvider = AndroidCrossfadeConfig Function();
typedef AndroidNextSongProvider = Song? Function();
typedef AndroidTrackAdvancedCallback = void Function(Song track);
typedef AndroidTrackErrorCallback = void Function(Song track);

/// Crossfade curve applied to the outgoing/incoming volume ramps.
enum AndroidCrossfadeCurve { equalPower, linear, squareRoot, sCurve }

/// Live snapshot of crossfade settings consumed by [AndroidAudioEngine].
class AndroidCrossfadeConfig {
  const AndroidCrossfadeConfig({
    required this.enabled,
    required this.durationSecs,
    required this.curve,
  });

  final bool enabled;
  final double durationSecs;
  final AndroidCrossfadeCurve curve;

  static const disabled = AndroidCrossfadeConfig(
    enabled: false,
    durationSecs: 3.0,
    curve: AndroidCrossfadeCurve.equalPower,
  );
}

/// Incoming-track volume fraction (0..1) at ramp progress [p] (0..1).
/// The outgoing fraction is [crossfadeInVolume] evaluated at `(1 - p)`, which
/// keeps every curve symmetric (equal-power satisfies `out^2 + in^2 == 1`).
@visibleForTesting
double crossfadeInVolume(AndroidCrossfadeCurve curve, double p) {
  final c = p.clamp(0.0, 1.0).toDouble();
  switch (curve) {
    case AndroidCrossfadeCurve.equalPower:
      return math.sin(c * math.pi / 2);
    case AndroidCrossfadeCurve.linear:
      return c;
    case AndroidCrossfadeCurve.squareRoot:
      return math.sqrt(c);
    case AndroidCrossfadeCurve.sCurve:
      return c * c * (3 - 2 * c);
  }
}

/// Pure trigger predicate: should a crossfade be armed given the current
/// playback position? Extracted so it can be unit-tested without a player.
@visibleForTesting
bool shouldArmCrossfade({
  required bool enabled,
  required Duration duration,
  required Duration position,
  required double fadeSecs,
}) {
  if (!enabled || fadeSecs <= 0) return false;
  if (duration.inMilliseconds <= 0) return false;
  final fadeMs = (fadeSecs * 1000).round();
  // A track shorter than (or equal to) the fade has no solo segment to fade
  // out of — let it end naturally.
  if (duration.inMilliseconds <= fadeMs) return false;
  final remaining = duration - position;
  return remaining.inMilliseconds <= fadeMs;
}

@visibleForTesting
bool shouldUseFastStartCurrentTrackOnly({
  required bool allowFastStart,
  required bool loadedSingleTrackOnly,
  required bool sequenceIsEmpty,
  required int playlistLength,
}) {
  return allowFastStart &&
      (loadedSingleTrackOnly || sequenceIsEmpty) &&
      playlistLength > AndroidAudioEngine.fastStartPlaylistThreshold;
}

@visibleForTesting
bool shouldExitSingleTrackMode({
  required bool loadedSingleTrackOnly,
  required int playerSequenceLength,
}) {
  return loadedSingleTrackOnly && playerSequenceLength > 1;
}

class AndroidAudioEngine implements AudioEngine {
  AndroidAudioEngine({
    required AndroidPlayerProvider playerProvider,
    required AndroidAudioSourcesBuilder sourcesBuilder,
    required AndroidAudioSourceBuilder sourceBuilder,
    required AndroidPlaylistProvider playlistProvider,
    required AndroidPlayerConfigurator configurePlayer,
    required AndroidEngineDisposer disposeEngine,
    AndroidStalledPlayerRetirer? retireStalledPlayer,
    AndroidPlayerProvider? secondaryPlayerProvider,
    required AndroidTrackSyncBlocker shouldSuppressTrackSync,
    required AndroidTrackIgnorePredicate shouldIgnoreTrack,
    required AndroidFastStartPredicate shouldFastStartCurrentTrackOnly,
    AndroidCrossfadeConfigProvider? crossfadeConfigProvider,
    AndroidNextSongProvider? onNextSong,
    AndroidTrackAdvancedCallback? onTrackAdvanced,
    AndroidTrackErrorCallback? onTrackError,
  }) : _playerProvider = playerProvider,
       _sourcesBuilder = sourcesBuilder,
       _sourceBuilder = sourceBuilder,
       _playlistProvider = playlistProvider,
       _configurePlayer = configurePlayer,
       _disposeEngine = disposeEngine,
       _retireStalledPlayer = retireStalledPlayer,
       _secondaryPlayerProvider = secondaryPlayerProvider,
       _shouldSuppressTrackSync = shouldSuppressTrackSync,
       _shouldIgnoreTrack = shouldIgnoreTrack,
       _shouldFastStartCurrentTrackOnly = shouldFastStartCurrentTrackOnly,
       _crossfadeConfigProvider =
           crossfadeConfigProvider ?? (() => AndroidCrossfadeConfig.disabled),
       _onNextSong = onNextSong,
       _onTrackAdvanced = onTrackAdvanced,
       _onTrackError = onTrackError;

  final AndroidPlayerProvider _playerProvider;
  final AndroidAudioSourcesBuilder _sourcesBuilder;
  final AndroidAudioSourceBuilder _sourceBuilder;
  final AndroidPlaylistProvider _playlistProvider;
  final AndroidPlayerConfigurator _configurePlayer;
  final AndroidEngineDisposer _disposeEngine;
  final AndroidStalledPlayerRetirer? _retireStalledPlayer;
  final AndroidPlayerProvider? _secondaryPlayerProvider;
  final AndroidTrackSyncBlocker _shouldSuppressTrackSync;
  final AndroidTrackIgnorePredicate _shouldIgnoreTrack;
  final AndroidFastStartPredicate _shouldFastStartCurrentTrackOnly;
  final AndroidCrossfadeConfigProvider _crossfadeConfigProvider;
  final AndroidNextSongProvider? _onNextSong;
  final AndroidTrackAdvancedCallback? _onTrackAdvanced;
  final AndroidTrackErrorCallback? _onTrackError;

  /// Fast-start and crossfade may load only one audio source even though the
  /// logical playlist contains more tracks. A native repeat-all on that source
  /// would endlessly repeat one song.
  bool get isSingleTrackOnly => _loadedSingleTrackOnly;
  bool get isCrossfadeActive => _crossfadeConfigProvider().enabled;

  /// Expand a fast-started *single source* into the full playlist in place.
  /// Unlike setAudioSource(), insertAudioSources preserves the live decoder,
  /// playing state and position. The caller performs this asynchronously,
  /// keeping repeat-all in manual-advance mode until it completes.
  Future<bool> restoreFastStartPlaylist() async {
    final player = _player;
    final playing = _loadedTrack;
    if (player == null || playing == null || !_loadedSingleTrackOnly ||
        isCrossfadeActive) return false;
    final songs = _playlistProvider();
    final index = songs.indexWhere(
      (song) => androidAudioSourceIdentity(song) ==
          androidAudioSourceIdentity(playing),
    );
    if (index < 0 || songs.length < 2 || player.sequence.length != 1) {
      return false;
    }

    // Build asynchronously, outside the synchronous UI toggle. Do not mutate
    // the audio sequence if another tap has selected a different source.
    final before = <just_audio.AudioSource>[];
    final after = <just_audio.AudioSource>[];
    try {
      for (var i = 0; i < songs.length; i++) {
        if (i == index) continue;
        final source = await _sourceBuilder(songs[i]);
        if (i < index) {
          before.add(source);
        } else {
          after.add(source);
        }
      }
      if (!identical(_player, player) || !_loadedSingleTrackOnly ||
          !identical(_loadedTrack, playing) || player.sequence.length != 1 ||
          !listEquals(
            songs.map(androidAudioSourceIdentity).toList(),
            _playlistProvider().map(androidAudioSourceIdentity).toList(),
          )) return false;

      _restoringFastStartPlaylist = true;
      // Followed by preceding tracks: the existing track stays the active
      // source, with its logical index shifted to match the full playlist.
      if (after.isNotEmpty) await player.addAudioSources(after);
      if (before.isNotEmpty) await player.insertAudioSources(0, before);
      _loadedSingleTrackOnly = false;
      _playlistSignature =
          songs.map(androidAudioSourceIdentity).toList(growable: false);
      devLog('[Playback] Restored repeat-all sequence in place '
          '(${songs.length} tracks)');
      return true;
    } catch (error) {
      devLog('[Playback] Repeat-all sequence restore failed: $error');
      return false;
    } finally {
      _restoringFastStartPlaylist = false;
      _syncPlaylistStateFromPlayer();
      _syncTrackFromIndex(player.currentIndex);
    }
  }

  bool _restoringFastStartPlaylist = false;

  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  just_audio.AudioPlayer? _player;
  // The instance supplied by PlayerService may be parked in _secondary
  // after crossfade. Unlike internally created fade players, it must remain
  // available to the service's provider/cache after a timed-out load.
  just_audio.AudioPlayer? _providerPlayer;
  PlaybackState _state = PlaybackState.empty(AudioEngineType.normalAndroid);
  Song? _loadedTrack;
  String? _lastAtmosPlaybackState;
  List<String> _playlistSignature = const <String>[];
  bool _awaitingInitialSeek = false;
  bool _loadedSingleTrackOnly = false;
  bool _sourceFailed = false;

  // Crossfade state. [_player] is always the currently-audible/active player;
  // [_secondary] is the idle slot reused as the incoming player on each fade.
  // On a crossfade the two swap roles (ping-pong), so both stay attached but
  // only the active one's stream emissions are forwarded.
  just_audio.AudioPlayer? _secondary;
  Timer? _crossfadeTimer;
  bool _crossfadeArmed = false;
  double _rampUserVolume = 1.0;
  Duration _rampElapsed = Duration.zero;
  Duration _rampTotal = Duration.zero;
  AndroidCrossfadeCurve _rampCurve = AndroidCrossfadeCurve.equalPower;

  VoidCallback? onTrackEnded;

  static const int fastStartPlaylistThreshold = 24;
  static const Duration _rampTick = Duration(milliseconds: 20);

  @override
  Stream<PlaybackState> get playbackStateStream => _controller.stream;

  Future<just_audio.AudioPlayer> _ensurePlayer() async {
    final existing = _player;
    if (existing != null) return existing;
    final player = await _playerProvider();
    _player = player;
    _providerPlayer = player;
    _attachListeners(player);
    return player;
  }

  Future<just_audio.AudioPlayer> _ensureSecondary() async {
    final existing = _secondary;
    if (existing != null) return existing;
    final player = _secondaryPlayerProvider == null
        ? just_audio.AudioPlayer(useProxyForRequestHeaders: false)
        : await _secondaryPlayerProvider!();
    _secondary = player;
    _attachListeners(player);
    await player.setVolume(0);
    await player.setLoopMode(just_audio.LoopMode.off);
    return player;
  }

  void _attachListeners(just_audio.AudioPlayer player) {
    _subscriptions.add(
      player.playerStateStream.listen((state) {
        if (!identical(player, _player)) return;
        final song = _loadedTrack;
        if (song?.atmosEncoded == true) {
          final status = '${state.processingState.name}:${state.playing}';
          if (status != _lastAtmosPlaybackState) {
            _lastAtmosPlaybackState = status;
            AtmosDiagnostics.record('playback_state', {
              'stage': state.processingState.name,
              'outcome': state.playing ? 'playing' : 'paused_or_buffering',
              'codec': 'eac3_joc',
            });
          }
        }
        _emit(_state.copyWith(isPlaying: state.playing && !_sourceFailed));
      }),
    );

    _subscriptions.add(
      player.playbackEventStream.listen((event) {
        if (!identical(player, _player)) return;
        final nextDuration = event.duration ?? _state.duration;
        _emit(
          _state.copyWith(
            position: event.updatePosition,
            bufferedPosition: event.bufferedPosition,
            duration: nextDuration,
          ),
        );
        _syncTrackFromIndex(player.currentIndex);
      }),
    );

    _subscriptions.add(
      player.positionStream.listen((pos) {
        if (!identical(player, _player)) return;
        _emit(_state.copyWith(position: pos));
        _syncTrackFromIndex(player.currentIndex);
        _maybeArmCrossfade(player, pos);
      }),
    );

    _subscriptions.add(
      player.bufferedPositionStream.listen((pos) {
        if (!identical(player, _player)) return;
        _emit(_state.copyWith(bufferedPosition: pos));
      }),
    );

    _subscriptions.add(
      player.durationStream.listen((dur) {
        if (!identical(player, _player)) return;
        if (dur == null) return;
        _emit(_state.copyWith(duration: dur));
      }),
    );

    _subscriptions.add(
      player.sequenceStateStream.listen((sequenceState) {
        if (!identical(player, _player)) return;
        _syncTrackFromIndex(sequenceState.currentIndex);
      }),
    );

    _subscriptions.add(
      player.currentIndexStream.listen((index) {
        if (!identical(player, _player)) return;
        _syncTrackFromIndex(index);
      }),
    );

    _subscriptions.add(
      player.processingStateStream.listen((state) {
        if (!identical(player, _player)) return;
        if (state == just_audio.ProcessingState.completed) {
          if (_loadedTrack?.atmosEncoded == true) {
            AtmosDiagnostics.record('playback_end', {
              'codec': 'eac3_joc', 'outcome': 'completed',
            });
          }
          onTrackEnded?.call();
        }
      }),
    );

    _subscriptions.add(
      player.errorStream.listen((error) {
        if (!identical(player, _player)) return;
        if (_loadedTrack?.atmosEncoded == true) {
          // Media3/ExoPlayer errors sometimes contain file:// paths or
          // signed source URLs. Log only the error code and error class.
          AtmosDiagnostics.record('playback_error', {
            'errorCode': error.code,
            'errorClass': error.runtimeType.toString(),
            'reason': 'android_player_error',
            'codec': 'eac3_joc',
          });
        } else {
          devLog(
            '[Playback] Android player error: '
            'code=${error.code} message=${error.message} index=${error.index} '
            'trackId=${_loadedTrack?.id} '
            'trackFileType=${_loadedTrack?.fileType} '
            'trackTitle=${_loadedTrack?.title}',
          );
        }
        _sourceFailed = true;
        _playlistSignature = const [];
        _emit(_state.copyWith(isPlaying: false));
        final failedTrack = _resolveTrack(error.index) ?? _loadedTrack;
        if (failedTrack != null) {
          _onTrackError?.call(failedTrack);
        }
      }),
    );
  }

  void _syncTrackFromIndex(int? index) {
    if (_restoringFastStartPlaylist) return;
    _syncPlaylistStateFromPlayer();
    if (_shouldSuppressTrackSync()) return;
    if (_awaitingInitialSeek) return;
    final nextTrack = _resolveTrack(index);
    if (nextTrack != null && _shouldIgnoreTrack(nextTrack)) {
      return;
    }
    if (nextTrack == _state.currentTrack) return;
    _loadedTrack = nextTrack ?? _loadedTrack;
    _emit(
      _state.copyWith(
        currentTrack: nextTrack,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: nextTrack?.duration ?? Duration.zero,
      ),
    );
  }

  void _syncPlaylistStateFromPlayer() {
    if (_restoringFastStartPlaylist) return;
    final player = _player;
    if (player == null) return;

    if (shouldExitSingleTrackMode(
      loadedSingleTrackOnly: _loadedSingleTrackOnly,
      playerSequenceLength: player.sequence.length,
    )) {
      _loadedSingleTrackOnly = false;
      _playlistSignature = _playlistProvider()
          .map(androidAudioSourceIdentity)
          .toList(growable: false);
    } else if (player.sequence.isEmpty) {
      _playlistSignature = const <String>[];
    }
  }

  Song? _resolveTrack(int? index) {
    if (_loadedSingleTrackOnly) {
      return _loadedTrack;
    }
    if (index == null) return _loadedTrack;
    final playlist = _playlistProvider();
    if (index < 0 || index >= playlist.length) {
      return _loadedTrack;
    }
    return playlist[index];
  }

  void _emit(PlaybackState next) {
    if (next == _state) return;
    _state = next;
    _controller.add(next);
  }

  /// A timed-out Media3/just_audio prepare can leave its platform decoder
  /// wedged even after stop(). Unregister this player synchronously so the
  /// next user selection gets a new native instance, not the poisoned one.
  /// The owner clears its own cached player and disposes this one separately.
  Future<void> _retireTimedOutPlayer(just_audio.AudioPlayer player) async {
    if (!identical(_player, player)) return;
    // If a crossfade swapped the primary with its secondary slot, the
    // PlayerService-owned instance can still live in _secondary. Clearing
    // only _player would alias the two slots on the next _ensurePlayer().
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _crossfadeArmed = false;
    final survivor = _secondary;
    _secondary = null;
    _player = null;
    _playlistSignature = const <String>[];
    _loadedSingleTrackOnly = false;
    _sourceFailed = true;
    final orphanedFadePlayer =
        survivor != null && !identical(survivor, _providerPlayer)
            ? survivor
            : null;
    if (identical(player, _providerPlayer)) _providerPlayer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    if (orphanedFadePlayer != null) {
      try {
        await orphanedFadePlayer.dispose().timeout(
          const Duration(seconds: 3),
        );
      } catch (error) {
        devLog('[Playback] Crossfade player cleanup failed: $error');
      }
    }
    // If the survivor belongs to PlayerService, its cached provider returns
    // it as the *sole* primary on the next attempt. Its listeners are
    // re-attached by _ensurePlayer(), never as a secondary.
    try {
      final retire = _retireStalledPlayer;
      await (retire == null ? player.dispose() : retire(player))
          .timeout(const Duration(seconds: 3));
    } catch (error) {
      devLog('[Playback] Timed-out Android player retirement failed: $error');
    }
  }

  Future<void> _loadSource(
    just_audio.AudioPlayer player,
    just_audio.AudioSource source, {
    int? initialIndex,
  }) async {
    try {
      await player
          .setAudioSource(source, initialIndex: initialIndex, preload: true)
          .timeout(const Duration(seconds: 30));
      _sourceFailed = false;
    } catch (error) {
      // A failed source must never be reused by seek/resume. stop() also
      // cancels an outstanding prepare before the next queued command.
      _sourceFailed = true;
      _emit(_state.copyWith(isPlaying: false));
      try {
        await player.stop().timeout(const Duration(seconds: 3));
      } catch (_) {}
      _playlistSignature = const [];
      _loadedSingleTrackOnly = false;
      if (error is TimeoutException) {
        await _retireTimedOutPlayer(player);
        throw TimeoutException(
          'Audio source did not become ready. The audio engine was reset; retry playback.',
        );
      }
      rethrow;
    }
  }

  Future<void> _seekPlayer(
    just_audio.AudioPlayer player,
    Duration position, {
    int? index,
  }) async {
    try {
      await player
          .seek(position, index: index)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      _sourceFailed = true;
      _playlistSignature = const [];
      _emit(_state.copyWith(isPlaying: false));
      try {
        await player.stop().timeout(const Duration(seconds: 3));
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> load(Song track) async {
    await _cancelCrossfade();
    final player = await _ensurePlayer();
    final playlist = _playlistProvider();
    var index = playlist.indexWhere((song) => song.id == track.id);
    if (index < 0) {
      index = 0;
    }

    final nextSignature = playlist
        .map(androidAudioSourceIdentity)
        .toList(growable: false);
    var canReusePlaylist =
        !_sourceFailed &&
        _playlistSignature.isNotEmpty &&
        listEquals(_playlistSignature, nextSignature);

    final priorTrack = _loadedTrack;
    final outputModeChanged = shouldResetAndroidAtmosDecoder(priorTrack, track);
    if (outputModeChanged) {
      // Stop Media3's old codec / audio sink before reloading a different
      // audio format. A JOC decoder may still own the output when stereo
      // starts; a seek into the previous playlist cannot release it.
      AtmosDiagnostics.record('playback_handoff', {
        'from': priorTrack!.atmosEncoded ? 'atmos' : 'normal',
        'to': track.atmosEncoded ? 'atmos' : 'normal',
        'outcome': 'releasing_previous_decoder',
      });
      await player.stop().timeout(const Duration(seconds: 5));
      _playlistSignature = const <String>[];
      canReusePlaylist = false;
      _loadedSingleTrackOnly = false;
      _sourceFailed = false;
    }
    _loadedTrack = track;
    _lastAtmosPlaybackState = null;
    if (track.atmosEncoded) {
      AtmosDiagnostics.record('native_load_start', {
        'codec': 'eac3_joc',
        'engine': 'normalAndroid',
        'crossfadeDisabled': true,
      });
    }
    await _configurePlayer(player);

    // Passthrough and object-based Atmos rendering cannot be crossfaded as
    // PCM. Preserve the original JOC frames and use a single player.
    final cfg = track.atmosEncoded
        ? AndroidCrossfadeConfig.disabled
        : _crossfadeConfigProvider();
    if (cfg.enabled) {
      // Crossfade needs a single-track source so the engine can intercept the
      // tail; a ConcatenatingAudioSource would auto-advance with a hard cut.
      devLog('[Playback] Android load(${track.id}) single-track (crossfade)');
      _awaitingInitialSeek = true;
      try {
        final source = await _sourceBuilder(track)
            .timeout(const Duration(seconds: 30));
        await _loadSource(player, source);
        await _seekPlayer(player, Duration.zero);
      } finally {
        _awaitingInitialSeek = false;
      }
      _loadedSingleTrackOnly = true;
      _playlistSignature = const <String>[];
      _emit(
        _state.copyWith(
          currentTrack: track,
          isPlaying: player.playing,
          position: player.position,
          bufferedPosition: player.bufferedPosition,
          duration: player.duration ?? track.duration,
        ),
      );
      return;
    }

    final shouldFastStartCurrentTrackOnly = shouldUseFastStartCurrentTrackOnly(
      allowFastStart: _shouldFastStartCurrentTrackOnly(),
      loadedSingleTrackOnly: _loadedSingleTrackOnly,
      sequenceIsEmpty: player.sequence.isEmpty,
      playlistLength: playlist.length,
    );

    if (canReusePlaylist &&
        player.sequence.isNotEmpty &&
        !_loadedSingleTrackOnly) {
      devLog('[Playback] Android load(${track.id}) using existing playlist');
      await _seekPlayer(player, Duration.zero, index: index);
    } else if (shouldFastStartCurrentTrackOnly) {
      devLog(
        '[Playback] Android load(${track.id}) fast-starting current track',
      );
      _awaitingInitialSeek = true;
      try {
        final source = await _sourceBuilder(track)
            .timeout(const Duration(seconds: 30));
        await _loadSource(player, source);
        await _seekPlayer(player, Duration.zero);
      } finally {
        _awaitingInitialSeek = false;
      }
      _loadedSingleTrackOnly = true;
      _playlistSignature = const <String>[];
    } else {
      devLog('[Playback] Android load(${track.id}) rebuilding playlist');
      _awaitingInitialSeek = true;
      try {
        final source = await _sourcesBuilder().timeout(
          const Duration(seconds: 30),
        );
        // ignore: deprecated_member_use
        if (source is just_audio.ConcatenatingAudioSource &&
            source.children.isEmpty) {
          throw StateError('No audio sources available for playback');
        }
        await _loadSource(player, source, initialIndex: index);
        await _seekPlayer(player, Duration.zero, index: index);
      } finally {
        _awaitingInitialSeek = false;
      }
      _loadedSingleTrackOnly = false;
      _playlistSignature = nextSignature;
    }

    _emit(
      _state.copyWith(
        currentTrack: track,
        isPlaying: player.playing,
        position: player.position,
        bufferedPosition: player.bufferedPosition,
        duration: player.duration ?? track.duration,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (_sourceFailed && _loadedTrack != null) {
      await load(_loadedTrack!);
    }
    final player = await _ensurePlayer();
    // just_audio keeps this future alive while playback is active, which would
    // block the PlayerService command queue until the track ends.
    try {
      final playback = player.play();
      unawaited(
        playback.catchError((Object error, StackTrace stackTrace) {
          devLog('[Playback] Android play() failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }),
      );
    } catch (error, stackTrace) {
      devLog('[Playback] Android play() failed immediately: $error');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
    // Resume a crossfade ramp that was frozen by pause().
    if (_crossfadeArmed) {
      final outgoing = _secondary;
      if (outgoing != null) {
        try {
          unawaited(
            outgoing.play().catchError((Object error) {
              devLog('[crossfade] resume failed: $error');
            }),
          );
        } catch (_) {}
        _startRampTimer(outgoing, player);
      }
    }
  }

  @override
  Future<void> pause() async {
    final player = await _ensurePlayer();
    await player.pause();
    if (_crossfadeArmed) {
      // Freeze the ramp where it is; play() resumes from [_rampElapsed].
      _crossfadeTimer?.cancel();
      _crossfadeTimer = null;
      final outgoing = _secondary;
      if (outgoing != null) {
        try {
          await outgoing.pause();
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> stop() async {
    await _cancelCrossfade();
    final player = await _ensurePlayer();
    await player.stop();
    _emit(
      _state.copyWith(
        isPlaying: player.playing,
        position: player.position,
        bufferedPosition: player.bufferedPosition,
        duration: player.duration ?? _state.duration,
      ),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    final player = await _ensurePlayer();
    if (_crossfadeArmed) {
      // Aborting the in-flight fade: silence the outgoing tail and snap the
      // active player back to full volume before seeking.
      await _cancelCrossfade();
      try {
        await player.setVolume(_rampUserVolume);
      } catch (_) {}
    }
    await _seekPlayer(player, position);
  }

  @override
  void updateTrack(Song track) {}

  void _maybeArmCrossfade(just_audio.AudioPlayer player, Duration pos) {
    if (_crossfadeArmed || _loadedTrack?.atmosEncoded == true) return;
    final cfg = _crossfadeConfigProvider();
    final duration = player.duration;
    if (!shouldArmCrossfade(
      enabled: cfg.enabled,
      duration: duration ?? Duration.zero,
      position: pos,
      fadeSecs: cfg.durationSecs,
    )) {
      return;
    }
    _armCrossfade(cfg, (cfg.durationSecs * 1000).round());
  }

  void _armCrossfade(AndroidCrossfadeConfig cfg, int fadeMs) {
    // Set synchronously so the next position tick can't re-enter.
    _crossfadeArmed = true;
    unawaited(() async {
      final outgoing = _player;
      if (outgoing == null) {
        _crossfadeArmed = false;
        return;
      }
      final next = _onNextSong?.call();
      if (next == null || next.atmosEncoded ||
          next.id == _loadedTrack?.id) {
        // Nothing to crossfade into (end of list / loop-one): let the track
        // end naturally so onTrackEnded handles it.
        _crossfadeArmed = false;
        return;
      }
      try {
        final incoming = await _ensureSecondary();
        final source = await _sourceBuilder(next);
        _rampUserVolume = outgoing.volume <= 0 ? 1.0 : outgoing.volume;
        await incoming
            .setAudioSource(source, preload: true)
            .timeout(const Duration(seconds: 30));
        await incoming.seek(Duration.zero).timeout(const Duration(seconds: 15));
        await incoming.setVolume(0);
        await incoming.setSpeed(outgoing.speed);
        await incoming.setLoopMode(just_audio.LoopMode.off);
        unawaited(
          incoming.play().catchError((Object error, StackTrace stackTrace) {
            devLog('[crossfade] incoming play() failed: $error');
            debugPrintStack(stackTrace: stackTrace);
          }),
        );
        _loadedTrack = next;
        _loadedSingleTrackOnly = true;
        _playlistSignature = const <String>[];
        _rampTotal = Duration(milliseconds: fadeMs);
        _rampElapsed = Duration.zero;
        _rampCurve = cfg.curve;
        // Swap roles: incoming becomes the active player, outgoing becomes the
        // idle slot and is faded out by the ramp.
        _player = incoming;
        _secondary = outgoing;
        _startRampTimer(outgoing, incoming);
        // The emitted state drives PlayerService's track-change bookkeeping
        // (index sync, notification, replay tracking, position save).
        _emit(
          _state.copyWith(
            currentTrack: next,
            position: Duration.zero,
            bufferedPosition: Duration.zero,
            duration: incoming.duration ?? next.duration,
          ),
        );
        // Queue-entry consumption + priority anchor are not covered by the
        // playback-state subscription, so the service does them here.
        _onTrackAdvanced?.call(next);
      } catch (error, stackTrace) {
        devLog('[crossfade] arm failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        _crossfadeArmed = false;
        final active = _player;
        if (active != null) {
          try {
            await active.setVolume(_rampUserVolume);
          } catch (_) {}
        }
      }
    }());
  }

  void _startRampTimer(
    just_audio.AudioPlayer outgoing,
    just_audio.AudioPlayer incoming,
  ) {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = Timer.periodic(_rampTick, (timer) {
      // Hold the ramp while paused; play() restarts it from [_rampElapsed].
      if (!incoming.playing) return;
      _rampElapsed += _rampTick;
      final p = _rampTotal.inMilliseconds <= 0
          ? 1.0
          : (_rampElapsed.inMilliseconds / _rampTotal.inMilliseconds)
                .clamp(0.0, 1.0)
                .toDouble();
      final inVol = _rampUserVolume * crossfadeInVolume(_rampCurve, p);
      final outVol = _rampUserVolume * crossfadeInVolume(_rampCurve, 1 - p);
      incoming.setVolume(inVol);
      outgoing.setVolume(outVol);
      if (p >= 1.0) {
        timer.cancel();
        _crossfadeTimer = null;
        unawaited(_finishCrossfade(outgoing));
      }
    });
  }

  Future<void> _finishCrossfade(just_audio.AudioPlayer outgoing) async {
    try {
      await outgoing.stop().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await outgoing.setVolume(_rampUserVolume);
    } catch (_) {}
    _crossfadeArmed = false;
  }

  Future<void> _cancelCrossfade() async {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    final wasArmed = _crossfadeArmed;
    _crossfadeArmed = false;
    final secondary = _secondary;
    if (secondary != null) {
      try {
        await secondary.stop().timeout(const Duration(seconds: 3));
      } catch (_) {}
      try {
        await secondary.setVolume(_rampUserVolume);
      } catch (_) {}
    }
    // If we were mid-fade, the active player's volume was being ramped down;
    // restore it so the user doesn't get a silently-seeking track.
    if (wasArmed) {
      final active = _player;
      if (active != null) {
        try {
          await active.setVolume(_rampUserVolume);
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> dispose() async {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _crossfadeArmed = false;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final secondary = _secondary;
    _secondary = null;
    _player = null;
    _providerPlayer = null;
    _playlistSignature = const <String>[];
    _loadedSingleTrackOnly = false;
    try {
      await secondary?.dispose();
    } catch (_) {}
    await _disposeEngine();
    await _controller.close();
  }
}
