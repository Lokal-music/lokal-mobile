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
import 'package:flick/core/utils/app_log.dart';
import 'package:flick/services/atmos_diagnostics.dart';
import 'package:flick/services/automix_analysis_cache.dart';
import 'package:flick/services/automix_stem_clip.dart';

/// A queue entry's identity includes the actual encoded media source. Two
/// versions of the same catalogue song can share an ID but not a decoder or
/// cached URL. Reusing the old playlist here silently plays the wrong track.
@visibleForTesting
String androidAudioSourceIdentity(Song song) =>
    jsonEncode([song.id, song.filePath, song.atmosEncoded, song.fileType]);

@visibleForTesting
String androidDolbyCodec(Song song) =>
    song.atmosEncoded
        ? (song.fileType.toUpperCase() == 'AC-4' ? 'ac4' : 'eac3_joc')
        : 'normal';

@visibleForTesting
bool shouldResetAndroidAtmosDecoder(Song? previous, Song next) =>
    previous != null && androidDolbyCodec(previous) != androidDolbyCodec(next);

typedef AndroidAudioSourcesBuilder = Future<just_audio.AudioSource> Function();
typedef AndroidAudioSourceBuilder = Future<just_audio.AudioSource> Function(
  Song track,
);
typedef AndroidPlaylistProvider = List<Song> Function();
typedef AndroidSelectedPlaylistIndexProvider = int Function();
typedef AndroidNativePlaylistIndexCallback = void Function(int index);
typedef AndroidPlayerProvider = Future<just_audio.AudioPlayer> Function();
typedef AndroidPlayerConfigurator = Future<void> Function(
  just_audio.AudioPlayer player,
);
typedef AndroidEngineDisposer = Future<void> Function();
typedef AndroidStalledPlayerRetirer = Future<void> Function(
  just_audio.AudioPlayer player,
);
typedef AndroidPlayerCacheInvalidator = void Function(
  just_audio.AudioPlayer player,
);
typedef AndroidTrackSyncBlocker = bool Function();
typedef AndroidTrackIgnorePredicate = bool Function(Song track);
typedef AndroidFastStartPredicate = bool Function();
typedef AndroidCrossfadeConfigProvider = AndroidCrossfadeConfig Function();
typedef AndroidNextSongProvider = Song? Function();
typedef AndroidAutoMixProfileLookup = Future<AutoMixProfile?> Function(Song song);
typedef AndroidStemClipLookup = Future<AutoMixStemClip?> Function(Song outgoing, Song incoming);
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

/// Prepare the next decoder before the overlap begins. This gives remote
/// add-ons time to resolve and buffer without advancing the outgoing song
/// early. The actual handoff still waits for the fade window.
@visibleForTesting
bool shouldPrepareCrossfade({
  required bool enabled,
  required Duration duration,
  required Duration position,
  required double fadeSecs,
  double preparationLeadSecs = 8,
}) {
  if (!enabled || !fadeSecs.isFinite || fadeSecs <= 0 ||
      !preparationLeadSecs.isFinite) return false;
  final fadeMs = (fadeSecs * 1000).round();
  if (duration.inMilliseconds <= fadeMs) return false;
  final left = (duration - position).inMilliseconds;
  return left > 0 &&
      left <= fadeMs + (math.max(0.0, preparationLeadSecs) * 1000).round();
}

/// Only substantial terminal silence should shorten an AutoMix overlap.
/// A mismatch with the decoder duration or a very long quiet outro returns
/// the original duration rather than risking a premature skip.
@visibleForTesting
Duration automixEffectiveAudibleEnd(
  Duration duration,
  AutoMixProfile? profile,
) {
  if (profile == null || duration.inMilliseconds < 25000) return duration;
  if ((duration.inMilliseconds / 1000 - profile.durationSeconds).abs() > 2) {
    return duration;
  }
  final audible = Duration(
    milliseconds: (profile.audibleEndSeconds * 1000).round(),
  );
  final silence = duration - audible;
  return silence >= const Duration(seconds: 3) &&
          silence <= const Duration(seconds: 15) &&
          audible >= const Duration(seconds: 20)
      ? audible
      : duration;
}

/// The upstream model identifies the start of a 32-beat phrase. Native
/// Android playback currently has no independent pitch-locked stem mixer,
/// so a long overlap is safe only when the two beat rates already match
/// closely. Otherwise retain the configured short crossfade.
@visibleForTesting
double? automixPhraseOverlapSeconds(AutoMixProfile? outgoing) {
  final bpm = outgoing?.analyzedBpm;
  if (bpm == null || !bpm.isFinite || bpm < 85 || bpm > 200) return null;
  final seconds = 32 * 60 / bpm;
  return seconds >= 9 && seconds <= 22 ? seconds : null;
}

@visibleForTesting
bool automixNativePhraseCompatible(
  AutoMixProfile? outgoing, AutoMixProfile? incoming,
) {
  final first = outgoing?.analyzedBpm;
  final second = incoming?.analyzedBpm;
  return first != null && second != null &&
      first.isFinite && second.isFinite &&
      first > 0 && second > 0 &&
      ((first / second) - 1).abs() <= 0.01;
}

@visibleForTesting
Duration? automixModelEnd(
  Duration decoderDuration, AutoMixProfile? profile, double fadeSecs,
) {
  if (profile == null || profile.modelExits.isEmpty ||
      !fadeSecs.isFinite || fadeSecs <= 0) return null;
  final duration = decoderDuration.inMilliseconds / 1000;
  if (duration < 30 ||
      (duration - profile.durationSeconds).abs() > 2) return null;
  // A CUE-DETR overlap start is not proof of a vocal-free region. Limit
  // early skips to the last 30 seconds unless a real stem mixer is present.
  final candidates = profile.modelExits.where((time) =>
      time.isFinite && time >= math.max(duration * 0.6, duration - 30) &&
      time >= 20 && time + fadeSecs <= duration);
  if (candidates.isEmpty) return null;
  final start = candidates.reduce(math.max);
  return Duration(milliseconds: ((start + fadeSecs) * 1000).round());
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

/// A Discovery/Search queue can contain placeholders that do not yet have
/// playable sources. Never submit them to just_audio's native sequence:
/// repeat-all would otherwise cause Media3 to prepare an empty URI.
bool hasUnresolvedAudioSources(List<Song> playlist) =>
    playlist.any((song) => song.isPending ||
        song.filePath == null || song.filePath!.isEmpty);

/// The logical Library/Recently Added queue may contain thousands of entries
/// (including desktop songs that require network credentials). Preparing all
/// of them as a native Media3 sequence can block taps for minutes, repeatedly
/// open offline desktop streams and trigger an Android input ANR. Keep the
/// complete logical queue but prepare only the selected audio source; regular
/// completion/previous/next then advances through that original queue.
@visibleForTesting
bool requiresOnDemandAndroidSequence(List<Song> playlist) {
  if (playlist.length > 64) return true;
  return playlist.any((song) =>
      song.isPending ||
      song.filePath == null ||
      song.filePath!.isEmpty ||
      song.isNetworkSource ||
      song.sourcePackage == 'konnekted.progressive' ||
      song.sourcePackage == 'konnekted.morneye-live');
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
    AndroidSelectedPlaylistIndexProvider? selectedPlaylistIndexProvider,
    AndroidNativePlaylistIndexCallback? onNativePlaylistIndex,
    required AndroidPlayerConfigurator configurePlayer,
    required AndroidEngineDisposer disposeEngine,
    AndroidStalledPlayerRetirer? retireStalledPlayer,
    AndroidPlayerCacheInvalidator? invalidatePlayerCache,
    AndroidPlayerProvider? secondaryPlayerProvider,
    required AndroidTrackSyncBlocker shouldSuppressTrackSync,
    required AndroidTrackIgnorePredicate shouldIgnoreTrack,
    required AndroidFastStartPredicate shouldFastStartCurrentTrackOnly,
    AndroidCrossfadeConfigProvider? crossfadeConfigProvider,
    AndroidAutoMixProfileLookup? automixProfileLookup,
    AndroidStemClipLookup? stemClipLookup,
    double Function()? stemVolumeProvider,
    Future<just_audio.AudioPlayer> Function()? stemPlayerProvider,
    AndroidNextSongProvider? onNextSong,
    bool Function()? gaplessEnabledProvider,
    AndroidTrackAdvancedCallback? onTrackAdvanced,
    AndroidTrackErrorCallback? onTrackError,
  }) : _playerProvider = playerProvider,
       _sourcesBuilder = sourcesBuilder,
       _sourceBuilder = sourceBuilder,
       _playlistProvider = playlistProvider,
       _selectedPlaylistIndexProvider = selectedPlaylistIndexProvider,
       _onNativePlaylistIndex = onNativePlaylistIndex,
       _configurePlayer = configurePlayer,
       _disposeEngine = disposeEngine,
       _retireStalledPlayer = retireStalledPlayer,
       _invalidatePlayerCache = invalidatePlayerCache,
       _secondaryPlayerProvider = secondaryPlayerProvider,
       _shouldSuppressTrackSync = shouldSuppressTrackSync,
       _shouldIgnoreTrack = shouldIgnoreTrack,
       _shouldFastStartCurrentTrackOnly = shouldFastStartCurrentTrackOnly,
       _crossfadeConfigProvider =
           crossfadeConfigProvider ?? (() => AndroidCrossfadeConfig.disabled),
       _automixProfileLookup = automixProfileLookup,
       _stemClipLookup = stemClipLookup,
       _stemVolumeProvider = stemVolumeProvider,
       _stemPlayerProvider = stemPlayerProvider,
       _onNextSong = onNextSong,
       _gaplessEnabledProvider = gaplessEnabledProvider ?? (() => false),
       _onTrackAdvanced = onTrackAdvanced,
       _onTrackError = onTrackError;

  final AndroidPlayerProvider _playerProvider;
  final AndroidAudioSourcesBuilder _sourcesBuilder;
  final AndroidAudioSourceBuilder _sourceBuilder;
  final AndroidPlaylistProvider _playlistProvider;
  final AndroidSelectedPlaylistIndexProvider? _selectedPlaylistIndexProvider;
  final AndroidNativePlaylistIndexCallback? _onNativePlaylistIndex;
  final AndroidPlayerConfigurator _configurePlayer;
  final AndroidEngineDisposer _disposeEngine;
  final AndroidStalledPlayerRetirer? _retireStalledPlayer;
  final AndroidPlayerCacheInvalidator? _invalidatePlayerCache;
  final AndroidPlayerProvider? _secondaryPlayerProvider;
  final AndroidTrackSyncBlocker _shouldSuppressTrackSync;
  final AndroidTrackIgnorePredicate _shouldIgnoreTrack;
  final AndroidFastStartPredicate _shouldFastStartCurrentTrackOnly;
  final AndroidCrossfadeConfigProvider _crossfadeConfigProvider;
  final AndroidAutoMixProfileLookup? _automixProfileLookup;
  final AndroidStemClipLookup? _stemClipLookup;
  final double Function()? _stemVolumeProvider;
  final Future<just_audio.AudioPlayer> Function()? _stemPlayerProvider;
  Future<AutoMixStemClip?>? _stemCandidate;
  String? _stemCandidateIdentity;
  AutoMixStemClip? _stemReady;
  just_audio.AudioPlayer? _stemPlayer;
  Timer? _stemTimer;
  bool _stemHandoffStarted = false;
  bool _stemPausedByUser = false;
  bool _stemOutgoingStopped = false;
  int _stemLastPositionMs = 0;
  DateTime? _stemLastProgressAt;
  AutoMixStemClip? _activeStemClip;
  just_audio.AudioPlayer? _stemOutgoing;
  just_audio.AudioPlayer? _stemIncoming;
  int _stemEpoch = 0;
  Future<void>? _stemHandoffFuture;
  AutoMixProfile? _currentAutoMixProfile;
  int _autoMixProfileGeneration = 0;
  final AndroidNextSongProvider? _onNextSong;
  final bool Function() _gaplessEnabledProvider;
  final AndroidTrackAdvancedCallback? _onTrackAdvanced;
  final AndroidTrackErrorCallback? _onTrackError;

  /// Fast-start and crossfade may load only one audio source even though the
  /// logical playlist contains more tracks. A native repeat-all on that source
  /// would endlessly repeat one song.
  bool get isSingleTrackOnly => _loadedSingleTrackOnly;
  bool get isCrossfadeActive => _crossfadeConfigProvider().enabled;

  /// Collapse a previously restored/full native playlist when a network,
  /// pending or 65th entry makes the logical queue on-demand. Retain the
  /// decoder, current source and position: the native sequence must not carry
  /// stale slots after shuffle or play unexpected entries automatically.
  ///
  /// [concatenated] is the sequence originally handed to setAudioSource.
  /// Fast-start restoration instead adds sources directly to AudioPlayer, so
  /// that path must remove them through the player API.
  Future<bool> enterOnDemandQueueMode({
    just_audio.ConcatenatingAudioSource? concatenated,
  }) async {
    final restoring = _sequenceRestoreCompletion;
    if (restoring != null) await restoring.future;
    final player = _player;
    final active = _loadedTrack;
    if (player == null || active == null) return false;
    if (player.sequence.isEmpty) return false;
    if (player.sequence.length == 1) {
      _loadedSingleTrackOnly = true;
      _playlistSignature = const <String>[];
      return true;
    }

    final nativeIndex = player.currentIndex;
    if (nativeIndex == null || nativeIndex < 0 ||
        nativeIndex >= player.sequence.length) return false;

    _restoringFastStartPlaylist = true;
    try {
      if (concatenated != null &&
          concatenated.children.length == player.sequence.length) {
        if (nativeIndex + 1 < concatenated.children.length) {
          await concatenated.removeRange(
              nativeIndex + 1, concatenated.children.length);
        }
        if (nativeIndex > 0) {
          await concatenated.removeRange(0, nativeIndex);
        }
      } else {
        if (nativeIndex + 1 < player.sequence.length) {
          await player.removeAudioSourceRange(
              nativeIndex + 1, player.sequence.length);
        }
        if (nativeIndex > 0) {
          await player.removeAudioSourceRange(0, nativeIndex);
        }
      }
      _loadedSingleTrackOnly = true;
      _playlistSignature = const <String>[];
      devLog('[Playback] Collapsed native playlist to active track for '
          'on-demand queue');
      return true;
    } catch (error) {
      // A partially trimmed Media3 sequence must not be reused against a
      // reordered logical queue. Restore just the currently audible item.
      devLog('[Playback] Native queue collapse failed, restoring active '
          'track only: $error');
      try {
        final position = player.position;
        final wasPlaying = player.playing;
        final source = await _sourceBuilder(active);
        await player.setAudioSource(
          source, initialPosition: position,
        ).timeout(const Duration(seconds: 30));
        if (wasPlaying) {
          unawaited(player.play().catchError((Object _) {}));
        }
        _loadedSingleTrackOnly = true;
        _playlistSignature = const <String>[];
        return true;
      } catch (fallbackError) {
        _sourceFailed = true;
        devLog('[Playback] Native queue collapse recovery failed: '
            '$fallbackError');
        return false;
      }
    } finally {
      _restoringFastStartPlaylist = false;
    }
  }

  /// Expand a fast-started *single source* into the full playlist in place.
  /// Unlike setAudioSource(), insertAudioSources preserves the live decoder,
  /// playing state and position. The caller performs this asynchronously,
  /// keeping repeat-all in manual-advance mode until it completes.
  Future<bool> restoreFastStartPlaylist({
    required bool Function() isCurrent,
  }) async {
    final player = _player;
    final playing = _loadedTrack;
    if (player == null || playing == null || !_loadedSingleTrackOnly ||
        isCrossfadeActive || !isCurrent()) return false;
    final songs = _playlistProvider();
    // Never asynchronously restore an entire imported Library or a network
    // queue after fast start. This ran source resolution for 2,600+ songs and
    // could destroy a healthy player when just one desktop was disconnected.
    if (requiresOnDemandAndroidSequence(songs)) return false;
    final selectedIndex = _selectedPlaylistIndexProvider?.call() ?? -1;
    final index = selectedIndex >= 0 &&
            selectedIndex < songs.length &&
            androidAudioSourceIdentity(songs[selectedIndex]) ==
                androidAudioSourceIdentity(playing)
        ? selectedIndex
        : songs.indexWhere(
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
    var restored = false;
    try {
      for (var i = 0; i < songs.length; i++) {
        if (!isCurrent()) return false;
        if (i == index) continue;
        final source = await _sourceBuilder(songs[i]);
        if (i < index) {
          before.add(source);
        } else {
          after.add(source);
        }
      }
      if (!isCurrent() || !identical(_player, player) ||
          !_loadedSingleTrackOnly ||
          !identical(_loadedTrack, playing) || player.sequence.length != 1 ||
          !listEquals(
            songs.map(androidAudioSourceIdentity).toList(),
            _playlistProvider().map(androidAudioSourceIdentity).toList(),
          )) return false;

      _restoringFastStartPlaylist = true;
      final completed = Completer<void>();
      _sequenceRestoreCompletion = completed;
      // Followed by preceding tracks: the existing track stays the active
      // source, with its logical index shifted to match the full playlist.
      if (after.isNotEmpty) await player.addAudioSources(after);
      if (before.isNotEmpty) await player.insertAudioSources(0, before);
      _loadedSingleTrackOnly = false;
      _playlistSignature =
          songs.map(androidAudioSourceIdentity).toList(growable: false);
      restored = true;
      devLog('[Playback] Restored repeat-all sequence in place '
          '(${songs.length} tracks)');
      return true;
    } catch (error) {
      devLog('[Playback] Repeat-all sequence restore failed: $error');
      return false;
    } finally {
      if (_restoringFastStartPlaylist) {
        _restoringFastStartPlaylist = false;
        _sequenceRestoreCompletion?.complete();
        _sequenceRestoreCompletion = null;
        // A failed partial insert cannot be treated as a valid playlist.
        // Retain manual-completion mode and force a fresh sequence on the
        // next track instead of accidentally repeating/skipping wrong songs.
        if (restored && identical(_player, player)) {
          _syncPlaylistStateFromPlayer();
          _syncTrackFromIndex(player.currentIndex);
        } else if (identical(_player, player)) {
          _loadedSingleTrackOnly = true;
          _playlistSignature = const <String>[];
        }
      }
    }
  }

  bool _restoringFastStartPlaylist = false;
  Completer<void>? _sequenceRestoreCompletion;

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

  // A small Media3 queue even when the logical playlist has thousands of
  // entries. Native indices must map to exact logical occurrences, not IDs.
  List<({Song song, int playlistIndex})>? _onDemandGaplessSlots;
  int _onDemandGaplessEpoch = 0;
  int? _onDemandPreparingEpoch;

  // Crossfade state. [_player] is always the currently-audible/active player;
  // [_secondary] is the idle slot reused as the incoming player on each fade.
  // On a crossfade the two swap roles (ping-pong), so both stay attached but
  // only the active one's stream emissions are forwarded.
  just_audio.AudioPlayer? _secondary;
  Timer? _crossfadeTimer;
  bool _crossfadeArmed = false;
  bool _crossfadeCommitted = false; // true only after the two players swap
  int _crossfadeEpoch = 0; // invalidates late async decoder preparations
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

  /// Refuse an online sample in place of a longer catalogue recording.
  /// Local files and genuinely short songs are intentionally excluded.
  static bool isTruncatedHttpAddonAudio(Song? song, Duration? decodedDuration) {
    if (song?.sourcePackage != 'konnekted.progressive' ||
        decodedDuration == null) return false;
    return song!.duration >= const Duration(seconds: 90) &&
        decodedDuration >= const Duration(seconds: 10) &&
        decodedDuration <= const Duration(seconds: 60) &&
        decodedDuration.inMilliseconds * 2 < song.duration.inMilliseconds;
  }

  /// Reject an active preview without allowing Media3 to advance the queue.
  /// This also handles items reached through native playlist auto-advance.
  bool _rejectTruncatedActiveHttpTrack(
    just_audio.AudioPlayer player,
    Song? track,
    Duration? decodedDuration,
  ) {
    if (!identical(_player, player) ||
        _sourceFailed ||
        !isTruncatedHttpAddonAudio(track, decodedDuration)) return false;
    _sourceFailed = true;
    // Native auto-advance may have changed the item before the engine
    // received its duration. Keep retry/error state on that actual item.
    _loadedTrack = track;
    AppLog.instance.add('[Playback] HTTP add-on truncated audio rejected: '
        'expectedMs=${track!.duration.inMilliseconds} '
        'decodedMs=${decodedDuration!.inMilliseconds}');
    _emit(_state.copyWith(
      currentTrack: track,
      isPlaying: false,
      position: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: decodedDuration,
    ));
    _onTrackError?.call(track);
    // Pause immediately, before the asynchronous decoder retirement.
    unawaited(player.pause().catchError((Object _) {}));
    unawaited(_retireTimedOutPlayer(player));
    return true;
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
              'codec': androidDolbyCodec(song!),
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
        if (!identical(player, _player) || _sourceFailed) return;
        if (dur == null) return;
        // A duration event at a sequence transition may still represent the
        // previous item. Prefer the newly indexed source's own duration.
        final index = player.currentIndex;
        final indexedDuration = index != null && index >= 0 &&
                index < player.sequence.length
            ? player.sequence[index].duration
            : null;
        final verifiedDuration = indexedDuration ??
            (_loadedSingleTrackOnly ? dur : null);
        if (!_awaitingInitialSeek && !_shouldSuppressTrackSync() &&
            _rejectTruncatedActiveHttpTrack(
              player, _resolveTrack(index), verifiedDuration,
            )) return;
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
          if (_sourceFailed) return;
          if (_rejectTruncatedActiveHttpTrack(
            player, _resolveTrack(player.currentIndex), player.duration,
          )) return; // A preview is not a completed track.
          if (_loadedTrack?.atmosEncoded == true) {
            AtmosDiagnostics.record('playback_end', {
              'codec': androidDolbyCodec(_loadedTrack!), 'outcome': 'completed',
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
            'codec': androidDolbyCodec(_loadedTrack!),
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
        // Source errors often leave Media3's native decoder poisoned. A
        // subsequent user tap must get a fresh player, rather than entering
        // another load/seek on the same failed instance indefinitely.
        unawaited(_retireTimedOutPlayer(player));
      }),
    );
  }

  void _syncTrackFromIndex(int? index) {
    if (_restoringFastStartPlaylist || _sourceFailed) return;
    _syncPlaylistStateFromPlayer();
    if (_shouldSuppressTrackSync()) return;
    if (_awaitingInitialSeek) return;
    final nextTrack = _resolveTrack(index);
    if (nextTrack != null && _shouldIgnoreTrack(nextTrack)) {
      return;
    }
    // A global player.duration may still belong to the previous item.
    // Check the current IndexedAudioSource instead, then watch durationStream
    // for delayed decoder metadata.
    final player = _player;
    if (player != null && index != null &&
        index >= 0 && index < player.sequence.length &&
        _rejectTruncatedActiveHttpTrack(
          player, nextTrack, player.sequence[index].duration,
        )) return;
    // Report the native slot even if adjacent songs have identical IDs or
    // metadata. A single-source fast start has native index 0 regardless of
    // its absolute logical position, so never report that as a queue index.
    if (!_loadedSingleTrackOnly &&
        index != null &&
        player != null &&
        player.sequence.length == _playlistProvider().length &&
        listEquals(
          _playlistSignature,
          _playlistProvider().map(androidAudioSourceIdentity).toList(),
        )) {
      _onNativePlaylistIndex?.call(index);
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
    ++_crossfadeEpoch;
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _crossfadeArmed = false;
    _crossfadeCommitted = false;
    final survivor = _secondary;
    _secondary = null;
    _player = null;
    // Invalidate PlayerService's cached instance *before* awaiting stream
    // cancellation. New taps must not reattach to this poisoned decoder.
    _invalidatePlayerCache?.call(player);
    _playlistSignature = const <String>[];
    _loadedSingleTrackOnly = false;
    _sourceFailed = true;
    final orphanedFadePlayer =
        survivor != null && !identical(survivor, _providerPlayer)
            ? survivor
            : null;
    if (identical(player, _providerPlayer)) _providerPlayer = null;
    final oldSubscriptions = List<StreamSubscription<dynamic>>.of(
      _subscriptions,
    );
    _subscriptions.clear();
    for (final subscription in oldSubscriptions) {
      await subscription.cancel();
    }
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
      final loadedDuration = await player
          .setAudioSource(source, initialIndex: initialIndex, preload: true)
          .timeout(const Duration(seconds: 30));
      final actualDuration = loadedDuration ?? player.duration;
      if (isTruncatedHttpAddonAudio(_loadedTrack, actualDuration)) {
        AppLog.instance.add('[Playback] HTTP add-on truncated audio rejected at load: '
            'expectedMs=${_loadedTrack?.duration.inMilliseconds} '
            'decodedMs=${actualDuration?.inMilliseconds}');
        throw const FormatException(
          'The HTTP add-on returned a preview or truncated audio stream.',
        );
      }
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
      // Error 0 ("Source error") is just as capable of wedging ExoPlayer
      // as a timeout. The old player cannot be reused for a new selection.
      await _retireTimedOutPlayer(player);
      if (error is TimeoutException) {
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
    } catch (error) {
      _sourceFailed = true;
      _playlistSignature = const [];
      _emit(_state.copyWith(isPlaying: false));
      // Media3 can remain wedged after a source error or a 15-second seek
      // timeout. stop() alone leaves that native decoder attached, causing
      // each new Discovery track to fail in the same way. Retire the player
      // before the next selection; the provider constructs a fresh instance.
      await _retireTimedOutPlayer(player);
      Error.throwWithStackTrace(error, StackTrace.current);
    }
  }

  @override
  Future<void> load(Song track) async {
    await _cancelCrossfade();
    final player = await _ensurePlayer();
    final playlist = _playlistProvider();
    // The active queue slot is supplied by PlayerService. Searching by ID
    // alone wrongly loads the first occurrence of a duplicated song.
    final selectedIndex = _selectedPlaylistIndexProvider?.call() ?? -1;
    var index = selectedIndex >= 0 &&
            selectedIndex < playlist.length &&
            playlist[selectedIndex].id == track.id
        ? selectedIndex
        : playlist.indexWhere((song) => identical(song, track));
    if (index < 0) {
      index = playlist.indexWhere((song) => song.id == track.id);
    }
    if (index < 0) index = 0;

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
      // audio format. An AC-4 or JOC decoder may still own the output when stereo
      // starts; a seek into the previous playlist cannot release it.
      AtmosDiagnostics.record('playback_handoff', {
        'from': androidDolbyCodec(priorTrack!),
        'to': androidDolbyCodec(track),
        'outcome': 'releasing_previous_decoder',
      });
      await player.stop().timeout(const Duration(seconds: 5));
      _playlistSignature = const <String>[];
      canReusePlaylist = false;
      _loadedSingleTrackOnly = false;
      _sourceFailed = false;
    }
    _loadedTrack = track;
    _currentAutoMixProfile = null;
    final profileRequest = ++_autoMixProfileGeneration;
    final lookup = _automixProfileLookup;
    if (lookup != null && !track.atmosEncoded) {
      unawaited(lookup(track).then((profile) {
        if (profileRequest == _autoMixProfileGeneration &&
            identical(_loadedTrack, track)) {
          _currentAutoMixProfile = profile;
        }
      }).catchError((Object _) {}));
    }
    _lastAtmosPlaybackState = null;
    if (track.atmosEncoded) {
      AtmosDiagnostics.record('native_load_start', {
        'codec': androidDolbyCodec(track),
        'engine': 'normalAndroid',
        'crossfadeDisabled': true,
      });
    }
    await _configurePlayer(player);

    // Passthrough and object-based Atmos rendering cannot be crossfaded as
    // PCM. Preserve the original compressed frames and use a single player.
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

    final unresolvedQueue = requiresOnDemandAndroidSequence(playlist);
    // Repeat All is a logical queue setting, not permission to send pending
    // Discovery slots as empty URIs to Android. Keep one playable source
    // loaded and use PlayerService's manual completion until resolved.
    final shouldFastStartCurrentTrackOnly = unresolvedQueue ||
        shouldUseFastStartCurrentTrackOnly(
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
      // Reapply the *logical* loop preference after entering fast-start.
      // Repeat All becomes manual advancement for a one-item native source,
      // while Repeat One must remain native LoopMode.one.
      if (playlist.length > 1) {
        await _configurePlayer(player);
      }
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
    final stem = _stemPlayer;
    if (stem != null) {
      _stemPausedByUser = false;
      _stemLastProgressAt = DateTime.now();
      if (stem.processingState == just_audio.ProcessingState.completed &&
          _activeStemClip != null && _stemOutgoing != null &&
          _stemIncoming != null) {
        await _finishStemClip(_stemEpoch, _activeStemClip!, _stemOutgoing!,
            _stemIncoming!, stem);
        return;
      }
      unawaited(stem.play().catchError((Object _) {}));
      if (_stemHandoffStarted && _player != null) {
        final pending = _stemHandoffFuture;
        if (pending != null) {
          try { await pending.timeout(const Duration(milliseconds: 300)); }
          catch (_) {}
        }
        unawaited(_player!.play().catchError((Object _) {}));
      }
      if (_secondary != null && _secondary!.volume > 0) {
        unawaited(_secondary!.play().catchError((Object _) {}));
      }
      return;
    }
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
    // Only a committed ramp needs both decoders resumed. While merely
    // preloading, the original player owns playback and remains solo.
    if (_crossfadeCommitted) {
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
    final stem = _stemPlayer;
    if (stem != null) {
      _stemPausedByUser = true;
      try { await stem.pause(); } catch (_) {}
      try { await _player?.pause(); } catch (_) {}
      try { await _secondary?.pause(); } catch (_) {}
      return;
    }
    final player = await _ensurePlayer();
    await player.pause();
    if (_crossfadeCommitted) {
      // Freeze only a live ramp, never a still-buffering incoming decoder.
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
    // A stuck Media3 stop() must not indefinitely block the resolver when
    // switching from a failed Discovery source to its next placeholder.
    final player = _player;
    if (player == null) return;
    try {
      await player.stop().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      await _retireTimedOutPlayer(player);
      throw TimeoutException('Android playback stop stalled; player reset.');
    }
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

  /// Use cached waveform analysis only to omit a substantial trailing
  /// digital silence. Never trim ambiguous short fades or sources whose
  /// measured duration disagrees with the active decoder.
  Duration _audibleTransitionEnd(Duration? decoderDuration) =>
      automixEffectiveAudibleEnd(
        decoderDuration ?? _loadedTrack?.duration ?? Duration.zero,
        _currentAutoMixProfile,
      );

  // Begin fingerprint checks up to 60s ahead; SHA over large FLAC files
  // stays off the UI isolate. Only one candidate is outstanding per source
  // pair. Unknown/remote/unprepared pairs never hold normal playback.
  void _prewarmStemCandidate(just_audio.AudioPlayer player, Duration pos) {
    final lookup = _stemClipLookup;
    final outgoing = _loadedTrack;
    final next = _onNextSong?.call();
    if (lookup == null || outgoing == null || next == null ||
        outgoing.atmosEncoded || next.atmosEncoded ||
        (player.duration ?? outgoing.duration) - pos >
            const Duration(seconds: 60)) return;
    final id = '${androidAudioSourceIdentity(outgoing)}->${androidAudioSourceIdentity(next)}';
    if (id == _stemCandidateIdentity) return;
    _stemCandidateIdentity = id;
    _stemReady = null;
    final task = lookup(outgoing, next).catchError((Object _) => null);
    _stemCandidate = task;
    unawaited(task.then((clip) {
      if (_stemCandidateIdentity == id) _stemReady = clip;
    }));
  }

  void _maybeArmCrossfade(just_audio.AudioPlayer player, Duration pos) {
    if (_sourceFailed || _crossfadeArmed || _loadedTrack?.atmosEncoded == true) return;
    final cfg = _crossfadeConfigProvider();
    if (cfg.enabled) _prewarmStemCandidate(player, pos);
    final duration = player.duration;
    final audibleDuration = _audibleTransitionEnd(duration);
    final phraseSecs = automixPhraseOverlapSeconds(_currentAutoMixProfile);
    // A verified offline render has its own exact outgoing and incoming
    // timeline. It can run even when separate model sidecars were not copied.
    final prepared = _stemReady;
    final modelEnd = prepared != null
        ? prepared.start + prepared.length
        : automixModelEnd(duration ?? Duration.zero,
            _currentAutoMixProfile, phraseSecs ?? cfg.durationSecs);
    // If the model cue passed during a seek or late analysis, revert to
    // the ordinary end-of-track transition instead of disabling AutoMix.
    final usableModelEnd = modelEnd != null && modelEnd > pos ? modelEnd : null;
    final targetEnd = usableModelEnd ?? audibleDuration;
    if (!shouldPrepareCrossfade(
      enabled: cfg.enabled,
      duration: targetEnd,
      position: pos,
      fadeSecs: prepared != null ? prepared.durationSeconds
          : usableModelEnd != null && phraseSecs != null
              ? phraseSecs : cfg.durationSecs,
    )) {
      return;
    }
    _armCrossfade(cfg, (cfg.durationSecs * 1000).round(),
        audibleDuration, usableModelEnd, phraseSecs);
  }

  void _armCrossfade(AndroidCrossfadeConfig cfg, int fadeMs,
      Duration normalMixEnd, Duration? modelMixEnd, double? phraseSecs) {
    // The preparation phase is independent of the fade itself: streams may
    // require several seconds to buffer. Skips/stops/route changes invalidate
    // this attempt and cannot start an obsolete successor after an await.
    _crossfadeArmed = true;
    _crossfadeCommitted = false;
    final epoch = ++_crossfadeEpoch;
    final outgoing = _player;
    final outgoingTrack = _loadedTrack;
    final next = _onNextSong?.call();
    if (outgoing == null || outgoingTrack == null ||
        next == null || next.atmosEncoded ||
        next.id == outgoingTrack.id) {
      _crossfadeArmed = false;
      return;
    }
    final nextIdentity = androidAudioSourceIdentity(next);
    bool valid() {
      final candidate = _onNextSong?.call();
      return _crossfadeArmed && epoch == _crossfadeEpoch &&
          _crossfadeConfigProvider().enabled &&
          identical(_player, outgoing) &&
          identical(_loadedTrack, outgoingTrack) &&
          candidate != null &&
          androidAudioSourceIdentity(candidate) == nextIdentity;
    }
    // A queue edit can invalidate the candidate without calling load/stop.
    // In that case no new epoch is created, so release our own armed state.
    void releaseIfOwned() {
      if (epoch == _crossfadeEpoch) _crossfadeArmed = false;
    }

    unawaited(() async {
      try {
        final incoming = await _ensureSecondary();
        if (!valid()) { releaseIfOwned(); return; }
        // A cached local profile can trim verified leading silence. Provider
        // streams and unavailable analyses keep their natural start.
        AutoMixProfile? upcomingProfile;
        if (_automixProfileLookup case final fetch?) {
          try {
            upcomingProfile = await fetch(next).timeout(
              const Duration(milliseconds: 400), onTimeout: () => null,
            );
          } catch (_) {}
        }
        if (!valid()) { releaseIfOwned(); return; }
        final modelEntry = upcomingProfile?.modelEntrances.where((t) =>
            t.isFinite && t >= 0 && t <= 45 &&
            t <= upcomingProfile!.durationSeconds - 20).firstOrNull;
        final hasPairedCues = modelMixEnd != null && modelEntry != null;
        // The longer 32-beat window is not safe without pitch-preserving
        // tempo correction; only accept essentially matched rates.
        final phraseCompatible = phraseSecs != null &&
            automixNativePhraseCompatible(
              _currentAutoMixProfile, upcomingProfile,
            );
        final modelPair = hasPairedCues &&
            (phraseSecs == null || phraseCompatible);
        AutoMixStemClip? preparedStem;
        final lookup = _stemClipLookup;
        if (lookup != null && (outgoing.speed - 1).abs() < .001) {
          final id = '${androidAudioSourceIdentity(outgoingTrack)}->${nextIdentity}';
          try {
            final pending = _stemCandidateIdentity == id
                ? _stemCandidate
                : lookup(outgoingTrack, next);
            preparedStem = await pending?.timeout(
              const Duration(milliseconds: 450), onTimeout: () => null,
            );
            if (!valid()) { releaseIfOwned(); return; }
            if (preparedStem != null && hasPairedCues &&
                !AutoMixStemClip.suitableForCues(preparedStem,
                  outgoingStart: _currentAutoMixProfile?.modelExits.isNotEmpty == true
                      ? _currentAutoMixProfile!.modelExits.last : null,
                  incomingStart: modelEntry)) {
              preparedStem = null;
            }
          } catch (_) { preparedStem = null; }
        }
        final fallbackOverlapMs = modelPair && phraseCompatible
            ? (phraseSecs! * 1000).round() : fadeMs;
        final fallbackMixEnd = modelPair ? modelMixEnd! : normalMixEnd;
        var overlapMs = preparedStem?.length.inMilliseconds ?? fallbackOverlapMs;
        var mixEnd = preparedStem == null
            ? fallbackMixEnd : preparedStem.start + preparedStem.length;
        final source = await _sourceBuilder(next);
        if (!valid()) { releaseIfOwned(); return; }
        // A muted track must stay muted through the preparation and ramp.
        _rampUserVolume = outgoing.volume;
        final incomingDuration = await incoming
            .setAudioSource(source, preload: true)
            .timeout(const Duration(seconds: 30));
        if (!valid()) { releaseIfOwned(); return; }
        // This crossfade decoder bypasses _loadSource. Never commit or
        // advance the queue with a 30-second preview.
        final actualDuration = incomingDuration ?? incoming.duration;
        if (isTruncatedHttpAddonAudio(next, actualDuration)) {
          AppLog.instance.add('[Playback] HTTP add-on crossfade preview rejected: '
              'expectedMs=${next.duration.inMilliseconds} '
              'decodedMs=${actualDuration?.inMilliseconds}');
          releaseIfOwned();
          try { await incoming.stop(); } catch (_) {}
          return; // Keep outgoing audio until normal completion.
        }
        final entrance = modelPair ? modelEntry! :
            (upcomingProfile?.leadInSeconds ?? 0);
        final entry = (modelEntry != null || (entrance >= 0.4 && entrance <= 3)) &&
                (upcomingProfile?.durationSeconds ?? 0) >= 20
            ? Duration(milliseconds: (entrance * 1000).round())
            : Duration.zero;
        await incoming.seek(entry).timeout(const Duration(seconds: 15));
        if (!valid()) { releaseIfOwned(); return; }
        await incoming.setVolume(0);
        await incoming.setSpeed(outgoing.speed);
        await incoming.setLoopMode(just_audio.LoopMode.off);
        if (!valid()) { releaseIfOwned(); return; }
        // Decoder preparation must happen *before* the cue, not at its
        // musical start. Otherwise a cold Media3 decoder misses the precise
        // overlap even with a cached WAV. The last 8 seconds are reserved
        // for starting the already-prepared third player.
        just_audio.AudioPlayer? preparedStemPlayer;
        if (preparedStem != null) {
          try {
            preparedStemPlayer = _stemPlayerProvider != null
                ? await _stemPlayerProvider!()
                : just_audio.AudioPlayer(useProxyForRequestHeaders: false);
            await preparedStemPlayer.setVolume(0);
            await preparedStemPlayer.setLoopMode(just_audio.LoopMode.off);
            await preparedStemPlayer.setAudioSource(
              just_audio.AudioSource.uri(Uri.file(preparedStem.path)),
              preload: true,
            ).timeout(const Duration(seconds: 8));
            if (!valid()) {
              await preparedStemPlayer.dispose();
              releaseIfOwned();
              return;
            }
          } catch (error) {
            devLog('[automix] third decoder unavailable: $error');
            try { await preparedStemPlayer?.dispose(); } catch (_) {}
            preparedStemPlayer = null;
            preparedStem = null;
            overlapMs = fallbackOverlapMs;
            mixEnd = fallbackMixEnd;
          }
        }

        // Do not advance the queue while the next song is only buffered.
        // Poll the media position rather than wall time so pause/buffering
        // cannot cause a premature transition. The guard also covers manual
        // queue edits that do not trigger a player.load().
        while (valid()) {
          final remainingMs = (mixEnd - outgoing.position).inMilliseconds;
          if (outgoing.processingState == just_audio.ProcessingState.completed) {
            if (preparedStemPlayer != null) {
              unawaited(preparedStemPlayer.dispose().catchError((Object _) {}));
            }
            _crossfadeArmed = false; // normal end-of-track takes over
            return;
          }
          // A slow add-on may become ready after the *analysed* audible end
          // while the media element is still playing its silent tail. Start
          // immediately in that case, but never start while paused.
          if (outgoing.playing && remainingMs <= overlapMs) break;
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        if (!valid()) {
          if (preparedStemPlayer != null) {
            unawaited(preparedStemPlayer.dispose().catchError((Object _) {}));
          }
          releaseIfOwned();
          return;
        }
        // Volume may change while the incoming decoder is buffering.
        _rampUserVolume = outgoing.volume;

        final physicalRemainingMs =
            ((outgoing.duration ?? outgoingTrack.duration) - outgoing.position)
                .inMilliseconds;
        if (physicalRemainingMs <= 0) {
          _crossfadeArmed = false;
          return;
        }
        final remainingMs = (mixEnd - outgoing.position).inMilliseconds;
        // When the cached audible endpoint has already passed, use the
        // physically available silence rather than abandon the transition.
        // Never schedule a ramp past the actual decoder's end.
        final activeFadeMs = math.min(
          overlapMs, remainingMs > 0
              ? math.min(remainingMs, physicalRemainingMs)
              : physicalRemainingMs,
        );
        if (preparedStem != null && preparedStemPlayer != null &&
            (outgoing.position - preparedStem.start).inMilliseconds.abs() <= 650 &&
            await _commitStemClip(
              clip: preparedStem, preparedPlayer: preparedStemPlayer,
              outgoing: outgoing, incoming: incoming,
              next: next, nextProfile: upcomingProfile,
              valid: valid, epoch: epoch,
            )) {
          return;
        }
        if (preparedStemPlayer != null &&
            !identical(_stemPlayer, preparedStemPlayer)) {
          unawaited(preparedStemPlayer.dispose().catchError((Object _) {}));
        }
        unawaited(
          incoming.play().catchError((Object error, StackTrace stackTrace) {
            devLog('[crossfade] incoming play() failed: $error');
            debugPrintStack(stackTrace: stackTrace);
          }),
        );
        _loadedTrack = next;
        // Advance profile ownership together with the two playback decoders.
        ++_autoMixProfileGeneration;
        _currentAutoMixProfile = upcomingProfile;
        _loadedSingleTrackOnly = true;
        _playlistSignature = const <String>[];
        _rampTotal = Duration(milliseconds: activeFadeMs);
        _rampElapsed = Duration.zero;
        _rampCurve = cfg.curve;
        // Ping-pong decoders only when the incoming audio is committed.
        _player = incoming;
        _secondary = outgoing;
        _crossfadeCommitted = true;
        _startRampTimer(outgoing, incoming);
        _emit(
          _state.copyWith(
            currentTrack: next,
            position: Duration.zero,
            bufferedPosition: Duration.zero,
            duration: incoming.duration ?? next.duration,
          ),
        );
        _onTrackAdvanced?.call(next);
      } catch (error, stackTrace) {
        if (epoch != _crossfadeEpoch) return;
        devLog('[crossfade] preparation failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        _crossfadeArmed = false;
        _crossfadeCommitted = false;
        final active = _player;
        if (active != null) {
          try {
            await active.setVolume(_rampUserVolume);
          } catch (_) {}
        }
      }
    }());
  }

  /// Third decoder is only for a verified, offline-rendered Demucs window.
  /// It is never used for network sources, bit-perfect routes or Atmos.
  Future<bool> _commitStemClip({
    required AutoMixStemClip clip,
    required just_audio.AudioPlayer preparedPlayer,
    required just_audio.AudioPlayer outgoing,
    required just_audio.AudioPlayer incoming,
    required Song next,
    required AutoMixProfile? nextProfile,
    required bool Function() valid,
    required int epoch,
  }) async {
    just_audio.AudioPlayer? mixed = preparedPlayer;
    try {
      // Already source-decoded ahead of the model cue.
      if (mixed.processingState == just_audio.ProcessingState.idle) {
        await mixed.dispose();
        return false;
      }
      final lateMs = (outgoing.position - clip.start).inMilliseconds;
      if (!valid() || !outgoing.playing || lateMs.abs() > 650) {
        await mixed.dispose();
        return false;
      }
      if (lateMs > 0) await mixed.seek(Duration(milliseconds: lateMs));
      if (!valid() || !outgoing.playing) {
        await mixed.dispose();
        return false;
      }
      // Capture a non-null decoder for periodic callbacks after this async
      // setup; the mutable nullable handle is used only for failure cleanup.
      final just_audio.AudioPlayer clipPlayer = mixed!;
      _stemPlayer = clipPlayer;
      _stemHandoffStarted = false;
      _stemPausedByUser = false;
      _stemOutgoingStopped = false;
      _stemLastPositionMs = 0;
      _stemLastProgressAt = DateTime.now();
      _activeStemClip = clip;
      _stemOutgoing = outgoing;
      _stemIncoming = incoming;
      _stemEpoch = epoch;
      _stemHandoffFuture = null;
      _rampUserVolume = outgoing.volume;
      // just_audio.play returns only when playback completes: never await.
      unawaited(clipPlayer.play().catchError((Object error) {
        devLog('[automix] stem render failed: $error');
        if (!_stemPausedByUser) {
          unawaited(_finishStemClip(epoch, clip, outgoing, incoming, clipPlayer));
        }
      }));
      _loadedTrack = next;
      ++_autoMixProfileGeneration;
      _currentAutoMixProfile = nextProfile;
      _loadedSingleTrackOnly = true;
      _playlistSignature = const <String>[];
      _player = incoming;
      _secondary = outgoing;
      _crossfadeCommitted = true;
      _emit(_state.copyWith(
        currentTrack: next,
        position: Duration(milliseconds: (clip.inStart * 1000).round()),
        bufferedPosition: Duration.zero,
        duration: incoming.duration ?? next.duration,
      ));
      try { _onTrackAdvanced?.call(next); }
      catch (error) { devLog('[automix] queue sync: $error'); }
      _stemTimer?.cancel();
      _stemTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        if (epoch != _crossfadeEpoch || !identical(_stemPlayer, clipPlayer)) return;
        if (!clipPlayer.playing) {
          // A prepared decoder can fail silently before entering the ready
          // state. Never keep Flow blocked indefinitely on a missing play.
          if (!_stemPausedByUser && _stemLastProgressAt != null &&
              DateTime.now().difference(_stemLastProgressAt!) >
                  const Duration(seconds: 6)) {
            unawaited(_finishStemClip(epoch, clip, outgoing, incoming, clipPlayer));
            return;
          }
          if (!_stemPausedByUser &&
              clipPlayer.processingState == just_audio.ProcessingState.completed) {
            unawaited(_finishStemClip(epoch, clip, outgoing, incoming, clipPlayer));
          }
          return;
        }
        final position = clipPlayer.position.inMilliseconds;
        if (position > _stemLastPositionMs + 10) {
          _stemLastPositionMs = position;
          _stemLastProgressAt = DateTime.now();
        } else if (!_stemPausedByUser && _stemLastProgressAt != null &&
            DateTime.now().difference(_stemLastProgressAt!) >
                const Duration(seconds: 10)) {
          unawaited(_finishStemClip(epoch, clip, outgoing, incoming, clipPlayer));
          return;
        }
        final total = clip.length.inMilliseconds;
        final userVolume = _stemVolumeProvider?.call() ?? _rampUserVolume;
        if (!_stemHandoffStarted) {
          _emit(_state.copyWith(
            position: Duration(milliseconds:
                (clip.inStart * 1000).round() + position),
          ));
        }
        final initial = (position / 180).clamp(0.0, 1.0);
        // Once the pre-rendered overlap owns the audio, retire the old
        // decoder instead of needlessly decoding a silent song for 16s.
        if (position >= 240 && !_stemOutgoingStopped) {
          _stemOutgoingStopped = true;
          unawaited(outgoing.stop().catchError((Object _) {}));
        }
        if (!_stemHandoffStarted) {
          unawaited(outgoing.setVolume(userVolume * (1 - initial)));
          unawaited(clipPlayer.setVolume(userVolume * initial));
          if (total - position <= 900) {
            _stemHandoffStarted = true;
            final remaining = math.max(0, total - position);
            final resume = clip.resume - Duration(milliseconds: remaining);
            final pendingHandoff = () async {
              try {
                await incoming.seek(resume);
                if (epoch != _crossfadeEpoch || _stemPausedByUser ||
                    !identical(_stemPlayer, clipPlayer)) return;
                await incoming.setVolume(0);
                unawaited(incoming.play());
              } catch (_) {}
            }();
            _stemHandoffFuture = pendingHandoff;
            unawaited(pendingHandoff);
          }
        } else {
          final p = ((position - (total - 900)) / 900).clamp(0.0, 1.0);
          unawaited(clipPlayer.setVolume(userVolume * (1 - p)));
          unawaited(incoming.setVolume(userVolume * p));
        }
        if (position >= total - 20 ||
            clipPlayer.processingState == just_audio.ProcessingState.completed) {
          unawaited(_finishStemClip(epoch, clip, outgoing, incoming, clipPlayer));
        }
      });
      return true;
    } catch (error) {
      devLog('[automix] prepared stem unavailable: $error');
      if (mixed != null) {
        if (identical(_stemPlayer, mixed)) _stemPlayer = null;
        try { await mixed.dispose(); } catch (_) {}
      }
      return false;
    }
  }

  Future<void> _finishStemClip(
    int epoch, AutoMixStemClip clip,
    just_audio.AudioPlayer outgoing, just_audio.AudioPlayer incoming,
    just_audio.AudioPlayer mixed,
  ) async {
    if (epoch != _crossfadeEpoch || !identical(_stemPlayer, mixed) ||
        _stemPausedByUser) return;
    _stemTimer?.cancel();
    _stemTimer = null;
    _stemPlayer = null;
    _activeStemClip = null;
    _stemOutgoing = null;
    _stemIncoming = null;
    final pendingHandoff = _stemHandoffFuture;
    _stemHandoffFuture = null;
    if (pendingHandoff != null) {
      try { await pendingHandoff.timeout(const Duration(milliseconds: 300)); }
      catch (_) {}
    }
    if (epoch != _crossfadeEpoch) {
      try { await mixed.dispose(); } catch (_) {}
      return;
    }
    final hadHandoff = _stemHandoffStarted;
    _stemHandoffStarted = false;
    _stemPausedByUser = false;
    _stemOutgoingStopped = false;
    _stemLastProgressAt = null;
    try {
      if (!hadHandoff || !incoming.playing) {
        await incoming.seek(clip.resume);
        if (epoch == _crossfadeEpoch) unawaited(incoming.play());
      }
      if (epoch == _crossfadeEpoch) {
        await incoming.setVolume(_stemVolumeProvider?.call() ?? _rampUserVolume);
      }
    } catch (_) {}
    try { await mixed.stop(); } catch (_) {}
    try { await mixed.dispose(); } catch (_) {}
    if (epoch != _crossfadeEpoch) return;
    try { await outgoing.stop().timeout(const Duration(seconds: 3)); } catch (_) {}
    _crossfadeCommitted = false;
    _crossfadeArmed = false;
  }

  void _disposeStemPlayer() {
    _stemTimer?.cancel();
    _stemTimer = null;
    _stemHandoffStarted = false;
    _stemPausedByUser = false;
    _stemOutgoingStopped = false;
    _stemLastProgressAt = null;
    _activeStemClip = null;
    _stemOutgoing = null;
    _stemIncoming = null;
    _stemHandoffFuture = null;
    final mixed = _stemPlayer;
    _stemPlayer = null;
    if (mixed != null) {
      unawaited(mixed.dispose().catchError((Object _) {}));
    }
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
    _crossfadeCommitted = false;
  }

  Future<void> _cancelCrossfade() async {
    ++_crossfadeEpoch;
    _disposeStemPlayer();
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    final wasArmed = _crossfadeArmed;
    _crossfadeArmed = false;
    _crossfadeCommitted = false;
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
    ++_crossfadeEpoch;
    _disposeStemPlayer();
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _crossfadeArmed = false;
    _crossfadeCommitted = false;
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
