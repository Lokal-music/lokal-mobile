import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../features/flow/flow_controller.dart';
import '../features/flow/flow_library.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import 'online_playlist_reference.dart';
import 'online_radio_recommendations.dart';
import 'widget_recommendation_service.dart';
import 'widget_sync_service.dart';
import 'package:flick/core/utils/dev_log.dart';

/// Handles launcher widget commands even when Flutter was cold-started by a
/// native broadcast. Returns to the channel only after the command completes,
/// so lost/failed actions are visible instead of silently becoming no-ops.
class WidgetIntentHandler {
  WidgetIntentHandler(this._ref, {VoidCallback? onOpenQueue})
      : _onOpenQueue = onOpenQueue;

  final WidgetRef _ref;
  final VoidCallback? _onOpenQueue;
  MethodChannel? _channel;

  Future<void> attach() async {
    await detach();
    _channel = const MethodChannel('com.mossapps.flick/widget');
    _channel!.setMethodCallHandler((call) async {
      if (call.method == 'dispatchPending') return _drainNativeAction();
      if (call.method == 'dispatch') {
        final uri = Uri.tryParse(call.arguments as String? ?? '');
        await _dispatch(uri);
        return true;
      }
      return null;
    });

    final consumed = await _drainNativeAction();
    if (!consumed) {
      final launchUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (launchUri != null) await _dispatch(launchUri);
    }
  }

  Future<bool> _drainNativeAction() async {
    try {
      final raw = await _channel?.invokeMethod<String>('takePendingAction');
      if (raw == null || raw.isEmpty) return false;
      await _dispatch(Uri.tryParse(raw));
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      devLog('WidgetIntentHandler could not consume action: $e');
      return false;
    }
  }

  Future<void> detach() async {
    _channel?.setMethodCallHandler(null);
    _channel = null;
  }

  Future<void> _dispatch(Uri? uri) async {
    if (uri == null || uri.scheme != 'flickwidget') return;
    try {
      final action = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
      switch (uri.host) {
        case 'player':
          await _handlePlayer(action);
          break;
        case 'flow':
          await _handleFlow(action);
          break;
        case 'recommend':
          if (action == 'play') await _playRecommendation(uri);
          break;
        case 'queue':
          _onOpenQueue?.call();
          break;
        default:
          devLog('WidgetIntentHandler: unknown widget intent');
      }
    } catch (e, st) {
      devLog('Widget command failed: $e\n$st');
      await WidgetSyncService.instance.setFlowStatus('Could not start playback. Open Lokal to retry.');
    }
  }

  Future<void> _handlePlayer(String action) async {
    final notifier = _ref.read(playerProvider.notifier);
    switch (action) {
      case 'play_pause':
        await notifier.togglePlayPause();
        break;
      case 'next':
        await notifier.next();
        break;
      case 'previous':
        await notifier.previous();
        break;
      case 'shuffle':
        await notifier.toggleShuffle();
        break;
      case 'repeat':
        notifier.toggleLoopMode();
        break;
      default:
        return;
    }
    await _pushWidgetState();
  }

  Future<void> _handleFlow(String action) async {
    await WidgetSyncService.instance.setFlowStatus('Preparing your music…');
    try {
      if (action == 'radio') {
        final seed = _ref.read(playerProvider).currentSong;
        if (seed == null) {
          await WidgetSyncService.instance.setFlowStatus(
            'Play a song to start its radio, or choose Flow.');
          return;
        }
        final found = await const OnlineRadioRecommendations().recommend(
          seed, count: 8, existing: [seed],
        ).timeout(const Duration(seconds: 17));
        if (found.isEmpty) {
          await WidgetSyncService.instance.setFlowStatus(
            'No radio matches yet. Try another song.');
          return;
        }
        final tracks = [seed, ...found.map(stableOnlinePlaylistSong)];
        await _ref.read(playerProvider.notifier).play(
          tracks.first, playlist: tracks,
        );
        await WidgetSyncService.instance.setFlowStatus('Song Radio · ' + seed.artist);
      } else if (action == 'play' || action == 'new') {
        // Flow's library has an explicit unlock threshold; never report
        // success when the user cannot start a mix.
        final library = await _ref.read(flowLibraryProvider.future);
        if (!library.unlocked) {
          await WidgetSyncService.instance.setFlowStatus(
            'Like more library songs to unlock Flow.');
          return;
        }
        await _ref.read(flowControllerProvider.future);
        await _ref.read(flowControllerProvider.notifier).play(
          shuffle: action == 'new',
        );
        await WidgetSyncService.instance.setFlowStatus(
          action == 'new' ? 'New Flow mix is playing' : 'Flow is playing');
      }
      await _pushWidgetState();
    } catch (error) {
      devLog('Widget Flow/Radio failed: $error');
      await WidgetSyncService.instance.setFlowStatus(
        'Could not start Flow or Radio. Try again.');
    }
  }

  Future<void> _playRecommendation(Uri uri) async {
    final widgetId = int.tryParse(uri.queryParameters['id'] ?? '');
    if (widgetId == null || widgetId < 0) return;
    final rows = await WidgetRecommendationService.restore();
    if (rows.isEmpty) return;
    await HomeWidget.setAppGroupId('group.com.mossapps.flick.widgets');
    final cursor = await HomeWidget.getWidgetData<int>(
      'flick_widget_recommend_cursor_$widgetId', defaultValue: 0,
    ) ?? 0;
    final idx = cursor % rows.length;
    final records = <Song>[];
    for (final row in rows) {
      final title = (row['title'] ?? '').toString();
      final artist = (row['artist'] ?? '').toString();
      if (title.isEmpty || artist.isEmpty) continue;
      records.add(stableOnlinePlaylistSong(Song(
        id: 'widget:' + artist + ':' + title,
        title: title,
        artist: artist,
        album: (row['album'] ?? '').toString(),
        albumArt: (row['artwork'] ?? '').toString(),
        duration: Duration(milliseconds: (row['durationMs'] as num?)?.toInt() ?? 0),
        fileType: 'ONLINE',
        sourcePackage: Song.pendingSourcePackage,
        remoteId: (row['remoteId'] ?? '').toString(),
      )));
    }
    if (records.isEmpty) return;
    await _ref.read(playerProvider.notifier).play(
      records[idx % records.length],
      playlist: records,
    );
    await _pushWidgetState();
  }

  Future<void> _pushWidgetState() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    WidgetSyncService.instance.schedulePush(_ref.read(playerProvider));
  }
}
