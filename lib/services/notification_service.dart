import 'dart:async';

import 'package:flick/services/android_auto_catalog.dart';
import 'package:flick/services/notification_artwork_resolver.dart';

import 'package:flutter/services.dart';
import 'package:flick/models/song.dart';
import 'package:flick/core/utils/dev_log.dart';

/// A player other than the library player (internet radio) that holds the
/// media notification and lock-screen session for now.
class MediaNotificationOwner {
  const MediaNotificationOwner({
    required this.onTogglePlayPause,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    this.onNext,
    this.onPrevious,
    this.onSeek,
    this.onToggleFavorite,
    this.onToggleShuffle,
  });

  final VoidCallback onTogglePlayPause;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final void Function(Duration)? onSeek;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onToggleShuffle;
}

/// Flutter service to communicate with native Android notification service.
/// Handles media playback notifications with controls.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static const _channel = MethodChannel('com.mossapps.flick/player');

  final NotificationArtworkResolver _artwork = NotificationArtworkResolver();

  String? _artworkPath(Song song, {MediaNotificationOwner? owner}) {
    final identity = (owner == null ? 'library' : 'owner:' + identityHashCode(owner).toString()) +
        ':' + song.id + ':' + song.title + ':' + song.artist;
    return _artwork.pathFor(
      identity: identity,
      artwork: song.albumArt,
      onResolved: (path) {
        // A delayed cover request must not overwrite the next track, a radio
        // takeover, or a notification that has already been dismissed.
        if (owner == null ? _owner != null : !identical(_owner, owner)) return;
        unawaited(_publishResolvedArtwork(path));
      },
    );
  }

  Future<void> _publishResolvedArtwork(String path) async {
    try {
      // Metadata-only update: preserve the current play state and position.
      await _channel.invokeMethod('updateNotification', {
        'albumArtPath': path,
      });
    } on PlatformException {
      // A subsequent metadata update can still publish the cached path.
    } on MissingPluginException {
      // Non-Android host.
    }
  }

  int? _accentColor;
  Future<void> setLokalAccent(int color) async {
    if (_accentColor == color) return;
    _accentColor = color;
    if (!_isNotificationVisible) return;
    try {
      await _channel.invokeMethod('updateNotification', {'color': color});
    } on PlatformException {
      /* The next metadata update carries the accent. */
    } on MissingPluginException {
      /* Non-Android host. */
    }
  }

  bool _isNotificationVisible = false;
  bool get isNotificationVisible => _isNotificationVisible;

  /// While set, notification and headset commands go to this owner and the
  /// library player's own updates are held back, so the one media session
  /// shows what is actually playing.
  MediaNotificationOwner? _owner;
  bool get isClaimed => _owner != null;

  /// Shows [song] in the media notification on behalf of [owner], routing
  /// its play/pause/stop buttons there until [release].
  Future<void> showFor(
    MediaNotificationOwner owner, {
    required Song song,
    String? outputName,
    required bool isPlaying,
    bool isLive = true,
    bool isFavorite = false,
    bool isShuffle = false,
    Duration position = Duration.zero,
  }) async {
    _owner = owner;
    final artworkPath = _artworkPath(song, owner: owner);
    try {
      await _channel.invokeMethod('showNotification', <String, dynamic>{
        'title': song.title,
        'outputName': outputName,
        'artist': song.artist,
        'albumArtPath': artworkPath,
        'isPlaying': isPlaying,
        'duration': isLive ? 0 : song.duration.inMilliseconds,
        'position': position.inMilliseconds,
        if (_accentColor != null) 'color': _accentColor,
        'isShuffle': isShuffle,
        'isFavorite': isFavorite,
        'isCasting': false,
        // A live station: the notification shows play/pause only.
        'isLive': isLive,
      });
      _isNotificationVisible = true;
    } catch (e) {
      devLog('Failed to show notification: $e');
    }
  }

  Future<void> updateFor(
    MediaNotificationOwner owner, {
    required Duration position,
    required bool isPlaying,
  }) async {
    if (!identical(_owner, owner)) return;
    try {
      await _channel.invokeMethod('updateNotification', {
        'position': position.inMilliseconds,
        'isPlaying': isPlaying,
        if (_accentColor != null) 'color': _accentColor,
      });
    } on PlatformException {
      /* Reconnect republishes metadata. */
    } on MissingPluginException {
      /* Non-Android host. */
    }
  }

  /// Used when the listener explicitly chooses another playback output.
  void stopCurrentOwner() {
    final owner = _owner;
    _owner = null;
    _artwork.invalidate();
    owner?.onStop();
  }

  /// Hands the notification back to the library player.
  void release(MediaNotificationOwner owner) {
    if (identical(_owner, owner)) {
      _owner = null;
      _artwork.invalidate();
    }
  }

  /// Initialize the notification service and set up method call handler
  /// for receiving commands from the notification buttons.
  void init({
    required VoidCallback onTogglePlayPause,
    required VoidCallback onPlay,
    required VoidCallback onPause,
    required VoidCallback onNext,
    required VoidCallback onPrevious,
    required VoidCallback onStop,
    required Function(Duration) onSeek,
    required FutureOr<void> Function() onToggleShuffle,
    required FutureOr<void> Function() onToggleFavorite,
    VoidCallback? onDisconnectCast,
    Function(double)? onSetCastVolume,
  }) {
    _channel.setMethodCallHandler((call) async {
      // Car clients browse the same database and playlists as the phone UI.
      // Handle catalog requests even when radio temporarily owns the session.
      if (call.method == 'androidAutoBrowse') {
        final args = call.arguments;
        final parentId = args is Map ? args['parentId'] as String? : null;
        return AndroidAutoCatalog().browse(parentId ?? AndroidAutoCatalog.root);
      }
      if (call.method == 'androidAutoSearch') {
        final args = call.arguments;
        final query = args is Map ? args['query'] as String? : null;
        return AndroidAutoCatalog().search(query ?? '');
      }
      if (call.method == 'androidAutoPlayMediaId') {
        final args = call.arguments;
        final mediaId = args is Map ? args['mediaId'] as String? : null;
        if (mediaId == null) return false;
        if (_owner != null) stopCurrentOwner();
        return AndroidAutoCatalog().playMediaId(mediaId);
      }
      if (call.method == 'androidAutoPlaySearch') {
        final args = call.arguments;
        final query = args is Map ? args['query'] as String? : null;
        if (query == null || query.trim().isEmpty) return false;
        if (_owner != null) stopCurrentOwner();
        return AndroidAutoCatalog().playSearch(query);
      }
      final owner = _owner;
      if (owner != null) {
        switch (call.method) {
          case 'togglePlayPause':
            owner.onTogglePlayPause();
          case 'play':
            owner.onPlay();
          case 'pause':
            owner.onPause();
          case 'stop':
            owner.onStop();
          case 'next':
            owner.onNext?.call();
          case 'previous':
            owner.onPrevious?.call();
          case 'toggleFavorite':
            owner.onToggleFavorite?.call();
          case 'toggleShuffle':
            owner.onToggleShuffle?.call();
          case 'seek':
            final raw = call.arguments;
            final value = raw is Map ? raw['position'] : raw;
            if (value is num)
              owner.onSeek?.call(Duration(milliseconds: value.toInt()));
        }
        // A live stream has no next/previous, seek, shuffle or favorite.
        // This is a value-returning async MethodCallHandler: returning null
        // acknowledges the handled command without a Dart compile error.
        return null;
      }
      switch (call.method) {
        case 'togglePlayPause':
          onTogglePlayPause();
          break;
        case 'play':
          onPlay();
          break;
        case 'pause':
          onPause();
          break;
        case 'next':
          onNext();
          break;
        case 'previous':
          onPrevious();
          break;
        case 'stop':
          onStop();
          break;
        case 'seek':
          final position = call.arguments['position'] as int?;
          if (position != null) {
            onSeek(Duration(milliseconds: position));
          }
          break;
        case 'toggleShuffle':
          await onToggleShuffle();
          break;
        case 'toggleFavorite':
          await onToggleFavorite();
          break;
        case 'disconnectCast':
          onDisconnectCast?.call();
          break;
        case 'setCastVolume':
          final volume = (call.arguments['volume'] as num?)?.toDouble();
          if (volume != null) onSetCastVolume?.call(volume);
          break;
      }
    });

    // A cold Android Auto connection may have started Flutter headlessly.
    // Release its pending browse requests only after the Dart catalog and
    // playback command handler are ready to receive calls.
    unawaited(
      _channel.invokeMethod<void>('androidAutoReady').onError(
        (Object _, StackTrace __) {},
      ),
    );
  }

  /// Show or update the notification with song information.
  Future<void> showNotification({
    required Song song,
    required bool isPlaying,
    Duration? duration,
    Duration? position,
    bool isShuffle = false,
    bool isFavorite = false,
    int? color,
    bool isCasting = false,
    String? castDeviceName,
    int? castVolumePercent,
  }) async {
    if (_owner != null) return;
    final artworkPath = _artworkPath(song);
    try {
      final args = <String, dynamic>{
        'title': song.title,
        'outputName': null,
        'artist': song.artist,
        'albumArtPath': artworkPath,
        'isPlaying': isPlaying,
        'duration': duration?.inMilliseconds ?? 0,
        'position': position?.inMilliseconds ?? 0,
        'isShuffle': isShuffle,
        'isFavorite': isFavorite,
        'isCasting': isCasting,
        'isLive': false,
      };
      if (castDeviceName != null) args['castDeviceName'] = castDeviceName;
      if (castVolumePercent != null) {
        args['castVolume'] = castVolumePercent;
      }
      final effectiveColor = _accentColor ?? color;
      if (effectiveColor != null) args['color'] = effectiveColor;
      await _channel.invokeMethod('showNotification', args);
      _isNotificationVisible = true;
    } catch (e) {
      devLog('Failed to show notification: $e');
    }
  }

  /// Update only the playback state (play/pause button) in the notification.
  Future<void> updatePlaybackState({
    required bool isPlaying,
    Duration? position,
  }) async {
    if (!_isNotificationVisible || _owner != null) return;

    try {
      final args = <String, dynamic>{'isPlaying': isPlaying};
      if (position != null) {
        args['position'] = position.inMilliseconds;
      }
      await _channel.invokeMethod('updateNotification', args);
    } catch (e) {
      devLog('Failed to update notification state: $e');
    }
  }

  /// Update the notification with new song metadata or state.
  Future<void> updateNotification({
    required Song song,
    required bool isPlaying,
    Duration? duration,
    Duration? position,
    bool? isShuffle,
    bool? isFavorite,
    int? color,
    bool? isCasting,
    String? castDeviceName,
    int? castVolumePercent,
  }) async {
    if (_owner != null) return;
    final artworkPath = _artworkPath(song);
    try {
      final args = <String, dynamic>{
        'title': song.title,
        'outputName': null,
        'artist': song.artist,
        'albumArtPath': artworkPath,
        'isPlaying': isPlaying,
        'duration': duration?.inMilliseconds ?? 0,
        'position': position?.inMilliseconds ?? 0,
        'isLive': false,
      };

      if (isShuffle != null) args['isShuffle'] = isShuffle;
      if (isFavorite != null) args['isFavorite'] = isFavorite;
      final effectiveColor = _accentColor ?? color;
      if (effectiveColor != null) args['color'] = effectiveColor;
      if (isCasting != null) {
        args['isCasting'] = isCasting;
        args['castDeviceName'] = castDeviceName;
        if (castVolumePercent != null) args['castVolume'] = castVolumePercent;
      }

      await _channel.invokeMethod('updateNotification', args);
      _isNotificationVisible = true;
    } catch (e) {
      devLog('Failed to update notification: $e');
    }
  }

  /// Lightweight cast-only update: swaps the MediaSession between local and
  /// remote volume without touching metadata (no favorite/color churn while
  /// the volume slider is dragged).
  Future<void> updateCastState({
    required bool isCasting,
    String? castDeviceName,
    int? castVolumePercent,
  }) async {
    if (!_isNotificationVisible || _owner != null) return;
    try {
      final args = <String, dynamic>{
        'isCasting': isCasting,
        'castDeviceName': castDeviceName,
      };
      if (castVolumePercent != null) args['castVolume'] = castVolumePercent;
      await _channel.invokeMethod('updateNotification', args);
    } catch (e) {
      devLog('Failed to update cast state: $e');
    }
  }

  /// Hide the notification and stop the foreground service.
  Future<void> hideNotification() async {
    _artwork.invalidate();
    try {
      await _channel.invokeMethod('hideNotification');
      _isNotificationVisible = false;
    } catch (e) {
      devLog('Failed to hide notification: $e');
    }
  }
}
