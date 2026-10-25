import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/app_preferences_service.dart';

import 'package:flick/core/utils/dev_log.dart';

class WidgetSyncService {
  WidgetSyncService._();
  static final WidgetSyncService instance = WidgetSyncService._();

  int? _lastLokalAccent;

  /// App accent is stored separately so explicit per-widget overrides survive.
  Future<void> setLokalAccent(int color) async {
    if (!Platform.isAndroid || _lastLokalAccent == color) return;
    _lastLokalAccent = color;
    try {
      await _ensureInit();
      await HomeWidget.saveWidgetData<int>('lokal_widget_accent_argb', color);
      await _updateAll();
    } catch (_) {
      _lastLokalAccent = null;
    }
  }

  static const String _appGroup = 'group.com.mossapps.flick.widgets';

  static const String miniPlayerProvider =
      'com.mossapps.flick.widgets.MiniPlayerWidgetProvider';
  static const String flagshipProvider =
      'com.mossapps.flick.widgets.FlagshipWidgetProvider';
  static const String compactProvider =
      'com.mossapps.flick.widgets.CompactWidgetProvider';

  static const String keyFlagshipAccent = 'flick_widget_flagship_accent';
  static const String keyFlagshipShowArtist =
      'flick_widget_flagship_show_artist';
  static const String keyCompactBgOpacity = 'flick_widget_compact_bg_opacity';
  static const String keyCompactShowAlbumArt =
      'flick_widget_compact_show_album_art';
  static const String keyCompactShowArtist = 'flick_widget_compact_show_artist';
  static const String keyCompactAccent = 'flick_widget_compact_accent';
  static const String keyMiniTextScale = 'flick_widget_text_scale';
  static const String keyFlagshipTextScale = 'flick_widget_flagship_text_scale';
  static const String keyCompactTextScale = 'flick_widget_compact_text_scale';

  static const String keySongId = 'flick_widget_song_id';
  static const String keyTitle = 'flick_widget_title';
  static const String keyArtist = 'flick_widget_artist';
  static const String keyAlbumArt = 'flick_widget_album_art';
  static const String keyIsPlaying = 'flick_widget_is_playing';
  static const String keyHasSong = 'flick_widget_has_song';

  static const String keyBgOpacity = 'flick_widget_bg_opacity';
  static const String keyShowAlbumArt = 'flick_widget_show_album_art';
  static const String keyShowArtist = 'flick_widget_show_artist';
  static const String keyAccentColor = 'flick_widget_accent_color';
  static const String keyPositionMs = 'flick_widget_position_ms';
  static const String keyDurationMs = 'flick_widget_duration_ms';
  static const String keyIsShuffle = 'flick_widget_is_shuffle';
  static const String keyLoopMode = 'flick_widget_loop_mode';
  static const String keyQueueCount = 'flick_widget_queue_count';

  bool _initialized = false;
  Future<void>? _initialization;
  Timer? _debounce;
  String? _lastPushedSongId;
  bool? _lastPushedIsPlaying;
  bool? _lastPushedIsShuffle;
  int? _lastPushedLoopMode;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    if (_initialization case final ongoing?) {
      await ongoing;
      return;
    }
    final future = () async {
      await HomeWidget.setAppGroupId(_appGroup);
      _initialized = true;
    }();
    _initialization = future;
    try {
      await future;
    } finally {
      if (identical(_initialization, future)) _initialization = null;
    }
  }

  Future<void> _updateAll() async {
    await HomeWidget.updateWidget(qualifiedAndroidName: miniPlayerProvider);
    await HomeWidget.updateWidget(qualifiedAndroidName: flagshipProvider);
    await HomeWidget.updateWidget(qualifiedAndroidName: compactProvider);
  }

  PlayerState? _pendingState;
  bool _pushing = false;
  final _savedData = <String, Object?>{};

  Future<void> _save<T>(String key, T value) async {
    if (_savedData.containsKey(key) && _savedData[key] == value) return;
    await HomeWidget.saveWidgetData<T>(key, value);
    _savedData[key] = value;
  }

  void schedulePush(PlayerState state) {
    _pendingState = state;
    final structuralChange =
        state.currentSong?.id != _lastPushedSongId ||
        state.isPlaying != _lastPushedIsPlaying ||
        state.isShuffle != _lastPushedIsShuffle ||
        state.loopMode.index != _lastPushedLoopMode;
    if (structuralChange) {
      _debounce?.cancel();
      unawaited(_drainPushes());
    } else if (_debounce?.isActive != true) {
      _debounce = Timer(
        const Duration(seconds: 2),
        () => unawaited(_drainPushes()),
      );
    }
  }

  Future<void> _drainPushes() async {
    if (_pushing) return;
    _pushing = true;
    try {
      while (_pendingState != null) {
        final latest = _pendingState!;
        _pendingState = null;
        await _push(latest);
        // Only a structural change needs another immediate broadcast.
        final next = _pendingState;
        if (next != null &&
            next.currentSong?.id == _lastPushedSongId &&
            next.isPlaying == _lastPushedIsPlaying &&
            next.isShuffle == _lastPushedIsShuffle &&
            next.loopMode.index == _lastPushedLoopMode) {
          _debounce?.cancel();
          _debounce = Timer(
            const Duration(seconds: 2),
            () => unawaited(_drainPushes()),
          );
          break;
        }
      }
    } finally {
      _pushing = false;
    }
  }

  Future<void> _push(PlayerState state) async {
    try {
      await _ensureInit();
      final Song? song = state.currentSong;
      final structuralChange =
          _savedData[keySongId] != (song?.id ?? '') ||
          _savedData[keyIsPlaying] != state.isPlaying ||
          _savedData[keyTitle] != (song?.title ?? '') ||
          _savedData[keyArtist] != (song?.artist ?? '') ||
          _savedData[keyAlbumArt] != _resolveLocalArt(song?.albumArt) ||
          _savedData[keyIsShuffle] != state.isShuffle ||
          _savedData[keyLoopMode] != _loopModeToInt(state.loopMode) ||
          _savedData[keyQueueCount] != state.upNext.length;
      final positionChanged =
          _savedData[keyPositionMs] != state.position.inMilliseconds ||
          _savedData[keyDurationMs] != state.duration.inMilliseconds;
      await _save<bool>(keyHasSong, song != null);
      await _save<bool>(keyIsPlaying, state.isPlaying);
      await _save<String>(keySongId, song?.id ?? '');
      await _save<String>(keyTitle, song?.title ?? '');
      await _save<String>(keyArtist, song?.artist ?? '');
      await _save<String>(keyAlbumArt, _resolveLocalArt(song?.albumArt));
      await _save<int>(keyPositionMs, state.position.inMilliseconds);
      await _save<int>(keyDurationMs, state.duration.inMilliseconds);
      await _save<bool>(keyIsShuffle, state.isShuffle);
      await _save<int>(keyLoopMode, _loopModeToInt(state.loopMode));
      await _save<int>(keyQueueCount, state.upNext.length);

      if (structuralChange) {
        await _updateAll();
      } else if (positionChanged) {
        // Only the mini widget has a progress bar. Avoid rebuilding the two
        // artwork/text bitmap widgets for every position-only update.
        await HomeWidget.updateWidget(qualifiedAndroidName: miniPlayerProvider);
      }

      _lastPushedSongId = song?.id;
      _lastPushedIsPlaying = state.isPlaying;
      _lastPushedIsShuffle = state.isShuffle;
      _lastPushedLoopMode = state.loopMode.index;
    } catch (e, st) {
      // A partially saved preference batch must not suppress the next real
      // broadcast. Recover when Android's widget host becomes available.
      _savedData.clear();
      _lastPushedSongId = null;
      _lastPushedIsPlaying = null;
      _lastPushedIsShuffle = null;
      _lastPushedLoopMode = null;
      devLog('WidgetSyncService push failed: $e\n$st');
    }
  }

  Future<void> pushPaused() async {
    _savedData.remove(keyIsPlaying);
    try {
      await _ensureInit();
      await HomeWidget.saveWidgetData<bool>(keyIsPlaying, false);
      await _updateAll();
    } catch (e, st) {
      devLog('WidgetSyncService pushPaused failed: $e\n$st');
    }
  }

  Future<void> pushKilled() async {
    _savedData.remove(keyIsPlaying);
    try {
      await _ensureInit();
      await HomeWidget.saveWidgetData<bool>(keyIsPlaying, false);
      await _updateAll();
    } catch (e, st) {
      devLog('WidgetSyncService pushKilled failed: $e\n$st');
    }
  }

  Future<void> pushCustomization(AppPreferences prefs) async {
    try {
      await _ensureInit();
      await HomeWidget.saveWidgetData<int>(keyBgOpacity, prefs.widgetBgOpacity);
      await HomeWidget.saveWidgetData<bool>(
        keyShowAlbumArt,
        prefs.widgetShowAlbumArt,
      );
      await HomeWidget.saveWidgetData<bool>(
        keyShowArtist,
        prefs.widgetShowArtist,
      );
      await HomeWidget.saveWidgetData<String>(
        keyAccentColor,
        prefs.widgetAccentColor,
      );
      await HomeWidget.saveWidgetData<double>(
        keyMiniTextScale,
        prefs.widgetTextScale,
      );

      // Flagship widget customization
      await HomeWidget.saveWidgetData<String>(
        keyFlagshipAccent,
        prefs.widgetFlagshipAccent,
      );
      await HomeWidget.saveWidgetData<bool>(
        keyFlagshipShowArtist,
        prefs.widgetFlagshipShowArtist,
      );
      await HomeWidget.saveWidgetData<double>(
        keyFlagshipTextScale,
        prefs.widgetFlagshipTextScale,
      );

      // Compact widget customization
      await HomeWidget.saveWidgetData<int>(
        keyCompactBgOpacity,
        prefs.widgetCompactBgOpacity,
      );
      await HomeWidget.saveWidgetData<bool>(
        keyCompactShowAlbumArt,
        prefs.widgetCompactShowAlbumArt,
      );
      await HomeWidget.saveWidgetData<bool>(
        keyCompactShowArtist,
        prefs.widgetCompactShowArtist,
      );
      await HomeWidget.saveWidgetData<String>(
        keyCompactAccent,
        prefs.widgetCompactAccent,
      );
      await HomeWidget.saveWidgetData<double>(
        keyCompactTextScale,
        prefs.widgetCompactTextScale,
      );

      await _updateAll();
    } catch (e, st) {
      devLog('WidgetSyncService pushCustomization failed: $e\n$st');
    }
  }

  Future<void> pushInitialCustomization() async {
    try {
      await _ensureInit();
      final prefs = await _loadPrefsFromAppPrefs();
      await pushCustomization(prefs);
    } catch (_) {}
  }

  Future<AppPreferences> _loadPrefsFromAppPrefs() async {
    try {
      final prefsService = AppPreferencesService();
      return await prefsService.getPreferences();
    } catch (_) {
      return const AppPreferences();
    }
  }

  int _loopModeToInt(LoopMode mode) {
    switch (mode) {
      case LoopMode.off:
        return 0;
      case LoopMode.one:
        return 1;
      case LoopMode.all:
        return 2;
      case LoopMode.advanceAlbum:
        return 3;
      case LoopMode.advanceArtist:
        return 4;
      case LoopMode.advanceFolder:
        return 5;
      case LoopMode.advancePlaylist:
        return 6;
      case LoopMode.stopAfterCurrent:
        return 7;
    }
  }

  String _resolveLocalArt(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return '';
    final cleaned = raw.startsWith('file://') ? raw.substring(7) : raw;
    if (!File(cleaned).existsSync()) return '';
    return cleaned;
  }
}

ProviderSubscription<PlayerState> installWidgetSync(WidgetRef ref) {
  unawaited(WidgetSyncService.instance.pushInitialCustomization());
  return ref.listenManual<PlayerState>(
    playerProvider,
    (prev, next) => WidgetSyncService.instance.schedulePush(next),
    fireImmediately: true,
  );
}
