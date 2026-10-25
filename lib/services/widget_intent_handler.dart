import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'widget_sync_service.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import 'package:flick/core/utils/dev_log.dart';

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
      if (call.method == 'dispatchPending') {
        return _drainNativeAction();
      } else if (call.method == 'dispatch') {
        final uri = Uri.tryParse(call.arguments as String? ?? '');
        _dispatch(uri);
      }
    });

    // Native widget broadcasts are delivered before the Dart handler exists
    // during a cold launch. Atomically consume any saved action exactly once.
    final consumed = await _drainNativeAction();
    if (!consumed) {
      final launchUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (launchUri != null) _dispatch(launchUri);
    }
  }

  Future<bool> _drainNativeAction() async {
    try {
      final raw = await _channel?.invokeMethod<String>('takePendingAction');
      if (raw == null || raw.isEmpty) return false;
      _dispatch(Uri.tryParse(raw));
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

  void _dispatch(Uri? uri) {
    if (uri == null) return;
    try {
      final segments = uri.pathSegments;
      if (uri.host == 'player') {
        _handlePlayer(segments.isEmpty ? '' : segments.first);
      } else if (uri.host == 'queue') {
        _onOpenQueue?.call();
      } else {
        devLog('WidgetIntentHandler: unknown host ${uri.host}');
      }
    } catch (e, st) {
      devLog('WidgetIntentHandler dispatch error: $e\n$st');
    }
  }

  void _handlePlayer(String action) {
    final notifier = _ref.read(playerProvider.notifier);
    switch (action) {
      case 'play_pause':
        unawaited(notifier.togglePlayPause().then((_) => _pushWidgetState()));
        break;
      case 'next':
        unawaited(notifier.next().then((_) => _pushWidgetState()));
        break;
      case 'previous':
        unawaited(notifier.previous().then((_) => _pushWidgetState()));
        break;
      case 'shuffle':
        unawaited(notifier.toggleShuffle().then((_) => _pushWidgetState()));
        break;
      case 'repeat':
        notifier.toggleLoopMode();
        unawaited(_pushWidgetState());
        break;
      default:
        devLog('WidgetIntentHandler: unknown player action $action');
    }
  }

  Future<void> _pushWidgetState() async {
    // Do not write raw remote artwork URLs or only part of playback state.
    // The canonical widget sync service normalizes paths and broadcasts all
    // fields with the same debounce/race handling as normal player changes.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    WidgetSyncService.instance.schedulePush(_ref.read(playerProvider));
  }
}
