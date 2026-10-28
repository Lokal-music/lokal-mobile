import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lastfm_provider.dart';
import 'lokal_remote_provider.dart';
import '../models/lokal_remote_state.dart';
import '../services/link/remote_playback_target.dart';
import 'listenbrainz_provider.dart';
import '../models/playback_context.dart';
import '../models/shuffle_mode.dart';
import '../models/song.dart';
import '../services/player_service.dart';

import 'package:flick/core/utils/dev_log.dart';

// Re-export LoopMode from player_service
export '../services/player_service.dart' show LoopMode;
export '../models/shuffle_mode.dart' show ShuffleMode;
export '../models/playback_context.dart' show PlaybackContext, PlaybackSource;

/// State class representing the current player state.
@immutable
class PlayerState {
  final Song? currentSong;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final bool isShuffle;
  final ShuffleMode shuffleMode;
  final LoopMode loopMode;
  final double playbackSpeed;
  final Duration? sleepTimerRemaining;
  final List<Song> queue;
  final List<Song> upNext;
  final List<Song> autoplayUpNext;
  /// The full ordered playback context, including tracks before Now Playing.
  final List<Song> playlist;
  final int currentIndex;

  const PlayerState({
    this.currentSong,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.isShuffle = false,
    this.shuffleMode = ShuffleMode.off,
    this.loopMode = LoopMode.all,
    this.playbackSpeed = 1.0,
    this.sleepTimerRemaining,
    this.queue = const [],
    this.upNext = const [],
    this.autoplayUpNext = const [],
    this.playlist = const [],
    this.currentIndex = -1,
  });

  PlayerState copyWith({
    Song? currentSong,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    bool? isShuffle,
    ShuffleMode? shuffleMode,
    LoopMode? loopMode,
    double? playbackSpeed,
    Duration? sleepTimerRemaining,
    List<Song>? queue,
    List<Song>? upNext,
    List<Song>? autoplayUpNext,
    List<Song>? playlist,
    int? currentIndex,
    bool clearSong = false,
    bool clearSleepTimer = false,
  }) {
    return PlayerState(
      currentSong: clearSong ? null : (currentSong ?? this.currentSong),
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      isShuffle: isShuffle ?? this.isShuffle,
      shuffleMode: shuffleMode ?? this.shuffleMode,
      loopMode: loopMode ?? this.loopMode,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      sleepTimerRemaining: clearSleepTimer
          ? null
          : (sleepTimerRemaining ?? this.sleepTimerRemaining),
      queue: queue ?? this.queue,
      upNext: upNext ?? this.upNext,
      autoplayUpNext: autoplayUpNext ?? this.autoplayUpNext,
      playlist: playlist ?? this.playlist,
      currentIndex: currentIndex ?? this.currentIndex,
    );
  }

  /// Progress as a value between 0.0 and 1.0.
  double get progress {
    if (duration.inMilliseconds == 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Whether there is a song loaded.
  bool get hasSong => currentSong != null;
}

/// Provider for the PlayerService singleton.
/// This keeps the service alive for the app lifetime.
final playerServiceProvider = Provider<PlayerService>((ref) {
  return PlayerService();
});

/// Notifier that bridges PlayerService ValueNotifiers to Riverpod state.
class PlayerNotifier extends Notifier<PlayerState> {
  late PlayerService _service;
  DesktopPlaybackTarget? get _desktop {
    final link = ref.read(lokalRemoteControllerProvider);
    return link.controlsDesktop
        ? DesktopPlaybackTarget(
            outputName: link.desktopName,
            command: (action, value) => ref
                .read(lokalRemoteControllerProvider.notifier)
                .sendRawCommand(action, value),
          )
        : null;
  }

  Song? _lastTrackedSong;
  int _lastTrackedPositionSeconds = 0;
  int _lastTrackedDurationSeconds = 0;

  /// Accumulated actual listen time for the current track (ignores seeks).
  int _accumulatedListenSeconds = 0;

  /// Expose accumulated listen seconds for lifecycle hooks (e.g. app pause).
  int get accumulatedListenSeconds => _accumulatedListenSeconds;

  @override
  PlayerState build() {
    _service = ref.watch(playerServiceProvider);

    // Sync initial state from service
    final initial = PlayerState(
      currentSong: _service.currentSongNotifier.value,
      isPlaying: _service.isPlayingNotifier.value,
      position: _service.positionNotifier.value,
      duration: _service.durationNotifier.value,
      bufferedPosition: _service.bufferedPositionNotifier.value,
      isShuffle: _service.isShuffleNotifier.value,
      shuffleMode: _service.shuffleModeNotifier.value,
      loopMode: _service.loopModeNotifier.value,
      playbackSpeed: _service.playbackSpeedNotifier.value,
      sleepTimerRemaining: _service.sleepTimerRemainingNotifier.value,
      queue: _service.queueNotifier.value,
      upNext: _service.upNextNotifier.value,
      autoplayUpNext: _service.autoplayQueueNotifier.value,
      playlist: _service.playlist,
      currentIndex: _service.currentIndexNotifier.value,
    );

    DateTime lastPositionSync = DateTime.now();
    const positionThrottle = Duration(milliseconds: 250);

    // Listen to ValueNotifiers and update state (except position/bufferedPosition)
    void syncState() {
      if (ref.read(lokalRemoteControllerProvider).controlsDesktop) return;
      final latestSong = _service.currentSongNotifier.value;
      final latestDurationSeconds = _service.durationNotifier.value.inSeconds;

      if (_lastTrackedSong != null && latestSong?.id != _lastTrackedSong!.id) {
        _handleTrackEnded(
          endedSong: _lastTrackedSong!,
          listenedSeconds: _accumulatedListenSeconds,
          trackDurationSeconds: _lastTrackedDurationSeconds,
        );
      }

      if (latestSong != null && latestSong.id != _lastTrackedSong?.id) {
        _handleTrackStarted(latestSong);
        _accumulatedListenSeconds = 0;
        _lastTrackedPositionSeconds = _service.positionNotifier.value.inSeconds;
      }

      final isSameTrack =
          latestSong != null && latestSong.id == _lastTrackedSong?.id;

      // Latch duration to highest value for the same track. During gapless
      // transitions the player may briefly reset duration to 0 before the
      // song notifier fires, which would wipe the stored value.
      if (!isSameTrack) {
        _lastTrackedDurationSeconds = latestDurationSeconds;
      } else if (latestDurationSeconds > _lastTrackedDurationSeconds) {
        _lastTrackedDurationSeconds = latestDurationSeconds;
      }

      _lastTrackedSong = latestSong;

      state = state.copyWith(
        currentSong: latestSong,
        isPlaying: _service.isPlayingNotifier.value,
        position: _service.positionNotifier.value,
        duration: _service.durationNotifier.value,
        bufferedPosition: _service.bufferedPositionNotifier.value,
        isShuffle: _service.isShuffleNotifier.value,
        shuffleMode: _service.shuffleModeNotifier.value,
        loopMode: _service.loopModeNotifier.value,
        playbackSpeed: _service.playbackSpeedNotifier.value,
        sleepTimerRemaining: _service.sleepTimerRemainingNotifier.value,
        queue: _service.queueNotifier.value,
        upNext: _service.upNextNotifier.value,
        autoplayUpNext: _service.autoplayQueueNotifier.value,
        playlist: _service.playlist,
        currentIndex: _service.currentIndexNotifier.value,
        clearSong: _service.currentSongNotifier.value == null,
        clearSleepTimer: _service.sleepTimerRemainingNotifier.value == null,
      );
    }

    void syncPosition() {
      if (ref.read(lokalRemoteControllerProvider).controlsDesktop) return;
      final latestPosition = _service.positionNotifier.value;
      final latestPositionSeconds = latestPosition.inSeconds;
      final latestSong = _service.currentSongNotifier.value;
      final latestDurationSeconds = _service.durationNotifier.value.inSeconds;

      final isSameTrack =
          latestSong != null && latestSong.id == _lastTrackedSong?.id;

      if (isSameTrack) {
        // Accumulate actual listen time: only count small position deltas
        // (≤ 3s) as real playback. Larger jumps indicate seeks.
        final delta = latestPositionSeconds - _lastTrackedPositionSeconds;
        if (delta > 0 && delta <= 3) {
          _accumulatedListenSeconds += delta;
        }

        final positionAdvanced =
            latestPositionSeconds > _lastTrackedPositionSeconds;
        if (positionAdvanced && !latestSong.isExternal) {
          unawaited(
            ref
                .read(lastFmScrobbleProvider.notifier)
                .onPlaybackProgress(
                  artist: latestSong.artist,
                  track: latestSong.title,
                  album: latestSong.album,
                  albumArtist: null,
                  listenedSeconds: _accumulatedListenSeconds,
                  trackDurationSeconds: latestDurationSeconds,
                ),
          );
        }
      }

      _lastTrackedPositionSeconds = latestPositionSeconds;

      final now = DateTime.now();
      if (now.difference(lastPositionSync) > positionThrottle) {
        lastPositionSync = now;
        state = state.copyWith(
          position: latestPosition,
          bufferedPosition: _service.bufferedPositionNotifier.value,
        );
      }
    }

    ref.listen(lokalRemoteControllerProvider, (previous, next) {
      if (next.controlsDesktop) {
        final remote = next.snapshot;
        if (remote == null) return;
        Song convert(LokalRemoteTrack track) => Song(
          id: 'desktop:${track.id}',
          title: track.title,
          artist: track.artist,
          album: track.album,
          duration: Duration(milliseconds: (track.duration * 1000).round()),
          fileType: track.fileType,
          sourceType: 'lokal',
          remoteId: track.id,
        );
        state = state.copyWith(
          currentSong: remote.currentTrack == null
              ? null
              : convert(remote.currentTrack!),
          clearSong: remote.currentTrack == null,
          isPlaying: remote.isPlaying,
          position: Duration(milliseconds: (remote.progress * 1000).round()),
          duration: Duration(milliseconds: (remote.duration * 1000).round()),
          isShuffle: remote.shuffle,
          shuffleMode: remote.shuffle ? ShuffleMode.songs : ShuffleMode.off,
          loopMode: remote.repeat == 'one'
              ? LoopMode.one
              : remote.repeat == 'all'
              ? LoopMode.all
              : LoopMode.off,
          queue: remote.queue.map(convert).toList(),
          upNext: const [],
          autoplayUpNext: const [],
          // Desktop queue indices belong to its own playback context.
          // Never display the previous mobile playlist as desktop history.
          playlist: const [],
          currentIndex: remote.currentIndex,
        );
      } else if (previous?.controlsDesktop == true) {
        syncState();
      }
    });

    // Add listeners
    _service.currentSongNotifier.addListener(syncState);
    _service.isPlayingNotifier.addListener(syncState);
    _service.positionNotifier.addListener(syncPosition);
    _service.durationNotifier.addListener(syncState);
    _service.bufferedPositionNotifier.addListener(syncPosition);
    _service.isShuffleNotifier.addListener(syncState);
    _service.shuffleModeNotifier.addListener(syncState);
    _service.loopModeNotifier.addListener(syncState);
    _service.playbackSpeedNotifier.addListener(syncState);
    _service.sleepTimerRemainingNotifier.addListener(syncState);
    _service.queueNotifier.addListener(syncState);
    _service.upNextNotifier.addListener(syncState);
    _service.autoplayQueueNotifier.addListener(syncState);
    _service.currentIndexNotifier.addListener(syncState);

    // Cleanup listeners when provider is disposed
    ref.onDispose(() {
      _service.currentSongNotifier.removeListener(syncState);
      _service.isPlayingNotifier.removeListener(syncState);
      _service.positionNotifier.removeListener(syncPosition);
      _service.durationNotifier.removeListener(syncState);
      _service.bufferedPositionNotifier.removeListener(syncPosition);
      _service.isShuffleNotifier.removeListener(syncState);
      _service.shuffleModeNotifier.removeListener(syncState);
      _service.loopModeNotifier.removeListener(syncState);
      _service.playbackSpeedNotifier.removeListener(syncState);
      _service.sleepTimerRemainingNotifier.removeListener(syncState);
      _service.queueNotifier.removeListener(syncState);
      _service.upNextNotifier.removeListener(syncState);
      _service.autoplayQueueNotifier.removeListener(syncState);
      _service.currentIndexNotifier.removeListener(syncState);
    });

    return initial;
  }

  void _handleTrackStarted(Song song) {
    if (song.isExternal) {
      return;
    }
    unawaited(
      ref
          .read(lastFmScrobbleProvider.notifier)
          .onTrackStarted(
            artist: song.artist,
            track: song.title,
            album: song.album,
            albumArtist: null,
            durationSeconds: song.duration.inSeconds,
          )
          .catchError((e) => devLog('[LastFm] onTrackStarted error: $e')),
    );
    unawaited(
      ref
          .read(listenBrainzScrobbleProvider.notifier)
          .onTrackStarted(
            artist: song.artist,
            track: song.title,
            album: song.album,
            albumArtist: null,
            durationSeconds: song.duration.inSeconds,
          )
          .catchError((e) => devLog('[ListenBrainz] onTrackStarted error: $e')),
    );
  }

  void _handleTrackEnded({
    required Song endedSong,
    required int listenedSeconds,
    required int trackDurationSeconds,
  }) {
    if (endedSong.isExternal) {
      return;
    }
    unawaited(
      ref
          .read(lastFmScrobbleProvider.notifier)
          .onTrackEnded(
            artist: endedSong.artist,
            track: endedSong.title,
            album: endedSong.album,
            albumArtist: null,
            listenedSeconds: listenedSeconds,
            trackDurationSeconds: trackDurationSeconds,
          )
          .catchError((e) => devLog('[LastFm] onTrackEnded error: $e')),
    );
    unawaited(
      ref
          .read(listenBrainzScrobbleProvider.notifier)
          .onTrackEnded(
            artist: endedSong.artist,
            track: endedSong.title,
            album: endedSong.album,
            albumArtist: null,
            listenedSeconds: listenedSeconds,
            trackDurationSeconds: trackDurationSeconds,
          )
          .catchError((e) => devLog('[ListenBrainz] onTrackEnded error: $e')),
    );
  }

  /// Play a song, optionally with a playlist context.
  Future<void> play(
    Song song, {
    List<Song>? playlist,
    PlaybackContext? context,
  }) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.play(song, queue: playlist);
      return;
    }
    await _service.play(song, playlist: playlist, context: context);
  }

  /// Toggle play/pause.
  Future<void> togglePlayPause() async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.command('togglePlay', null);
      return;
    }
    await _service.togglePlayPause();
  }

  /// Pause playback.
  Future<void> pause() async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.pause();
      return;
    }
    await _service.pause();
  }

  /// Resume playback.
  Future<void> resume() async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.resume();
      return;
    }
    await _service.resume();
  }

  /// Seek to a position.
  Future<void> seek(Duration position) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.seek(position);
      return;
    }
    await _service.seek(position);
  }

  /// Skip to next song.
  Future<void> next() async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.next();
      return;
    }
    await _service.next();
  }

  /// Skip to previous song.
  /// [allowRestart] true = button behavior (restart if >3s), false = swipe/slide (always previous track)
  Future<void> previous({bool allowRestart = true}) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.previous();
      return;
    }
    await _service.previous(allowRestart: allowRestart);
  }

  Future<void> previousBySwipe() async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.previous();
      return;
    }
    await _service.previousBySwipe();
  }

  /// Toggle shuffle mode.
  Future<void> toggleShuffle() async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.command('setShuffle', !state.isShuffle);
      return;
    }
    await _service.toggleShuffle();
  }

  Future<int> addToQueue(Song song) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.addToQueue(song);
      return state.queue.length;
    }
    return _service.addToQueue(song);
  }

  Future<void> playFromQueueIndex(int index) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.command('playQueueIndex', index);
      return;
    }
    await _service.playFromQueueIndex(index);
  }

  /// Plays any slot in the existing context without rebuilding the queue.
  Future<void> playFromPlaylistIndex(int index) async {
    // Remote desktop state does not expose the mobile playlist's indices.
    if (_desktop != null) return;
    await _service.playFromPlaylistIndex(index);
  }

  Future<void> playFromUpNextIndex(int index) async {
    await _service.playFromUpNextIndex(index);
  }

  Future<void> playFromAutoplayIndex(int index) async {
    await _service.playFromAutoplayIndex(index);
  }

  Future<void> clearQueue() async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.command('clearQueue', null);
      return;
    }
    await _service.clearQueue();
  }

  Future<void> removeFromQueue(int index) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.removeFromQueue(index);
      return;
    }
    await _service.removeFromQueue(index);
  }

  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.reorderQueue(oldIndex, newIndex);
      return;
    }
    await _service.moveQueueItem(oldIndex, newIndex);
  }

  Future<void> moveQueueItemToNext(int index) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.reorderQueue(index, state.currentIndex + 1);
      return;
    }
    await _service.moveQueueItemToNext(index);
  }

  Future<void> moveUpNextItem(int oldIndex, int newIndex) async {
    await _service.moveUpNextItem(oldIndex, newIndex);
  }

  Future<void> clearAllUpcoming() async {
    await _service.clearAllUpcoming();
  }

  Future<void> removeFromUpNext(int upNextIndex) async {
    await _service.removeFromUpNext(upNextIndex);
  }

  /// Toggle loop mode (quick cycle: off → all → one).
  void toggleLoopMode() {
    final desktop = _desktop;
    if (desktop != null) {
      unawaited(
        desktop.command(
          'setRepeat',
          state.loopMode == LoopMode.off
              ? 'all'
              : state.loopMode == LoopMode.all
              ? 'one'
              : 'none',
        ),
      );
      return;
    }
    unawaited(_service.toggleLoopMode());
  }

  /// Set a specific loop mode.
  Future<void> setLoopMode(LoopMode mode) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.command(
        'setRepeat',
        mode == LoopMode.one
            ? 'one'
            : mode == LoopMode.all
            ? 'all'
            : 'none',
      );
      return;
    }
    await _service.setLoopMode(mode);
  }

  /// Set a specific shuffle mode.
  Future<void> setShuffleMode(ShuffleMode mode) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.command('setShuffle', mode != ShuffleMode.off);
      return;
    }
    await _service.setShuffleMode(mode);
  }

  /// Set A-B repeat point A at current position.
  void setAbRepeatA() {
    _service.setAbRepeatA();
  }

  /// Set A-B repeat point B at current position.
  void setAbRepeatB() {
    _service.setAbRepeatB();
  }

  /// Clear A-B repeat.
  void clearAbRepeat() {
    _service.clearAbRepeat();
  }

  /// Set playback speed.
  Future<void> setPlaybackSpeed(double speed) async {
    await _service.setPlaybackSpeed(speed);
  }

  /// Cycle through playback speeds.
  Future<void> cyclePlaybackSpeed() async {
    await _service.cyclePlaybackSpeed();
  }

  /// Set a sleep timer.
  void setSleepTimer(Duration duration) {
    _service.setSleepTimer(duration);
  }

  /// Cancel the sleep timer.
  void cancelSleepTimer() {
    _service.cancelSleepTimer();
  }

  /// Set volume (0.0 to 1.0).
  Future<void> setVolume(double volume) async {
    final desktop = _desktop;
    if (desktop != null) {
      await desktop.setVolume(volume);
      return;
    }
    await _service.setVolume(volume);
  }

  /// Sync UI state with the actual engine playback state.
  void syncNow() {
    _service.syncNow();
  }
}

/// Main player state provider.
final playerProvider = NotifierProvider<PlayerNotifier, PlayerState>(
  PlayerNotifier.new,
);

// ============================================================================
// Convenience selectors for granular rebuilds
// ============================================================================

/// Current song selector.
///
/// Watches `playerProvider` without `.select` so in-place updates that don't
/// change `Song.id` (e.g. album-art rewrites via `syncAlbumArtPaths`) still
/// re-emit. `Song.==` is by id, so `.select((s) => s.currentSong)` would mask
/// those changes.
final currentSongProvider = Provider<Song?>((ref) {
  return ref.watch(playerProvider).currentSong;
});

/// Is playing selector.
final isPlayingProvider = Provider<bool>((ref) {
  return ref.watch(playerProvider.select((state) => state.isPlaying));
});

final queueProvider = Provider<List<Song>>((ref) {
  return ref.watch(playerProvider.select((state) => state.queue));
});

final upNextProvider = Provider<List<Song>>((ref) {
  return ref.watch(playerProvider.select((state) => state.upNext));
});

/// Preview of Autoplay tracks beyond the explicit queue. Not part of the
/// reorderable manual queue until the first suggestion starts playing.
final autoplayUpNextProvider = Provider<List<Song>>((ref) {
  return ref.watch(playerProvider.select((state) => state.autoplayUpNext));
});

/// Position selector - updates frequently during playback.
final positionProvider = Provider<Duration>((ref) {
  return ref.watch(playerProvider.select((state) => state.position));
});

/// Duration selector.
final durationProvider = Provider<Duration>((ref) {
  return ref.watch(playerProvider.select((state) => state.duration));
});

/// Progress selector (0.0 to 1.0).
final progressProvider = Provider<double>((ref) {
  return ref.watch(playerProvider.select((state) => state.progress));
});

/// Shuffle mode selector.
final isShuffleProvider = Provider<bool>((ref) {
  return ref.watch(playerProvider.select((state) => state.isShuffle));
});

/// Loop mode selector.
final loopModeProvider = Provider<LoopMode>((ref) {
  return ref.watch(playerProvider.select((state) => state.loopMode));
});

/// Playback speed selector.
final playbackSpeedProvider = Provider<double>((ref) {
  return ref.watch(playerProvider.select((state) => state.playbackSpeed));
});

/// Shuffle mode selector (full enum).
final shuffleModeProvider = Provider<ShuffleMode>((ref) {
  return ref.watch(playerProvider.select((state) => state.shuffleMode));
});

/// Sleep timer remaining selector.
final sleepTimerRemainingProvider = Provider<Duration?>((ref) {
  return ref.watch(playerProvider.select((state) => state.sleepTimerRemaining));
});
