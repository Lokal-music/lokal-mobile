import 'dart:io';

import 'package:flick/core/utils/app_log.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProcessExitDiagnosticsService {
  static const _channel = MethodChannel('com.mossapps.flick/diagnostics');
  static const _lastSeenKey = 'diagnostics.last_process_exit_timestamp';

  /// Coarse lifecycle events only: never include filenames, titles, URLs,
  /// server IDs, user names or tokens. Android stores the last 12 events in
  /// ApplicationExitInfo so they survive SIGSEGV/abort without Dart flushing.
  static Future<void> recordBreadcrumb(String stage) async {
    if (!Platform.isAndroid) return;
    if (!RegExp(r'^[a-z0-9:_-]{1,64}

  Future<void> reportPreviousExits() async {
    if (!Platform.isAndroid) return;
    try {
      final exits = await _channel.invokeListMethod<Object?>(
        'getProcessExitInfo',
      );
      if (exits == null || exits.isEmpty) return;

      final preferences = await SharedPreferences.getInstance();
      final lastSeen = preferences.getInt(_lastSeenKey) ?? 0;
      var newest = lastSeen;

      for (final raw in exits) {
        if (raw is! Map) continue;
        final info = raw.cast<String, Object?>();
        final timestamp = (info['timestamp'] as num?)?.toInt() ?? 0;
        if (timestamp <= lastSeen) continue;
        final reason = (info['reason'] as num?)?.toInt() ?? 0;
        final status = (info['status'] as num?)?.toInt() ?? 0;
        final source = isLikelyCrash(reason: reason, status: status)
            ? LogSource.crash
            : LogSource.platform;
        AppLog.instance.add(_describe(info), source: source);
        final trace = info['trace'];
        if (trace is String && trace.isNotEmpty) {
          AppLog.instance.add('[native-exit-trace] $trace', source: source);
        } else if (isLikelyCrash(reason: reason, status: status)) {
          AppLog.instance.add(
            '[native-exit-trace] No Android tombstone available for this exit '
            '(OS may not retain it).', source: source,
          );
        }
        final checkpoints = info['processStateSummary'];
        if (checkpoints is String && checkpoints.isNotEmpty &&
            isLikelyCrash(reason: reason, status: status)) {
          AppLog.instance.add(
            '[native-exit-breadcrumbs] ${checkpoints.length > 1024 ? checkpoints.substring(0, 1024) : checkpoints}',
            source: source,
          );
        }
        if (timestamp > newest) newest = timestamp;
      }

      if (newest > lastSeen) {
        await preferences.setInt(_lastSeenKey, newest);
      }
    } catch (error) {
      devLog('Process exit diagnostics failed: $error');
    }
  }

  /// Android's REASON_SIGNALED does not mean the app crashed. In
  /// particular SIGKILL (9) can be a system kill or user/OEM action, and
  /// should not be counted as a confirmed native crash without a trace.
  /// Fatal native signals (SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGFPE,
  /// SIGSEGV) provide stronger crash evidence.
  static bool isLikelyCrash({required int reason, required int status}) {
    if (reason == 2) return {4, 5, 6, 7, 8, 11}.contains(status);
    return {3, 4, 5, 6, 7, 9, 12}.contains(reason);
  }

  String _describe(Map<String, Object?> info) {
    final timestamp = (info['timestamp'] as num?)?.toInt() ?? 0;
    final reason = (info['reason'] as num?)?.toInt() ?? 0;
    final parts = <String>[
      'previous run ended: ${_reasonLabel(reason)} (reason $reason)'
          '${reason == 2 && info['status'] == 9 ? ' [SIGKILL; source unknown]' : ''}',
      if (timestamp > 0)
        'at ${DateTime.fromMillisecondsSinceEpoch(timestamp).toIso8601String()}',
      'importance ${info['importance'] ?? '?'}',
      'pid ${info['pid'] ?? '?'}',
      'pss ${info['pss'] ?? '?'}kB',
      'rss ${info['rss'] ?? '?'}kB',
      'status ${info['status'] ?? '?'}',
    ];
    final description = info['description'];
    if (description is String && description.isNotEmpty) {
      parts.add(description);
    }
    return '[native-exit] ${parts.join(' ')}';
  }

  String _reasonLabel(int reason) => switch (reason) {
    1 => 'exit self',
    2 => 'signal',
    3 => 'low memory',
    4 => 'crash',
    5 => 'native crash',
    6 => 'anr',
    7 => 'initialization failure',
    8 => 'permission change',
    9 => 'excessive resource usage',
    10 => 'user requested',
    11 => 'user stopped',
    12 => 'dependency died',
    13 => 'other',
    _ => 'unknown',
  };
}
).hasMatch(stage)) return;
    try {
      await _channel.invokeMethod<bool>(
        'recordCrashBreadcrumb', <String, String>{'stage': stage},
      );
    } on MissingPluginException {
      // Older/native-unavailable builds have no crash breadcrumb service.
    } on PlatformException {
      // Telemetry must never interfere with playback.
    }
  }

  Future<void> reportPreviousExits() async {
    if (!Platform.isAndroid) return;
    try {
      final exits = await _channel.invokeListMethod<Object?>(
        'getProcessExitInfo',
      );
      if (exits == null || exits.isEmpty) return;

      final preferences = await SharedPreferences.getInstance();
      final lastSeen = preferences.getInt(_lastSeenKey) ?? 0;
      var newest = lastSeen;

      for (final raw in exits) {
        if (raw is! Map) continue;
        final info = raw.cast<String, Object?>();
        final timestamp = (info['timestamp'] as num?)?.toInt() ?? 0;
        if (timestamp <= lastSeen) continue;
        final reason = (info['reason'] as num?)?.toInt() ?? 0;
        final status = (info['status'] as num?)?.toInt() ?? 0;
        final source = isLikelyCrash(reason: reason, status: status)
            ? LogSource.crash
            : LogSource.platform;
        AppLog.instance.add(_describe(info), source: source);
        final trace = info['trace'];
        if (trace is String && trace.isNotEmpty) {
          AppLog.instance.add('[native-exit-trace] $trace', source: source);
        }
        if (timestamp > newest) newest = timestamp;
      }

      if (newest > lastSeen) {
        await preferences.setInt(_lastSeenKey, newest);
      }
    } catch (error) {
      devLog('Process exit diagnostics failed: $error');
    }
  }

  /// Android's REASON_SIGNALED does not mean the app crashed. In
  /// particular SIGKILL (9) can be a system kill or user/OEM action, and
  /// should not be counted as a confirmed native crash without a trace.
  /// Fatal native signals (SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGFPE,
  /// SIGSEGV) provide stronger crash evidence.
  static bool isLikelyCrash({required int reason, required int status}) {
    if (reason == 2) return {4, 5, 6, 7, 8, 11}.contains(status);
    return {3, 4, 5, 6, 7, 9, 12}.contains(reason);
  }

  String _describe(Map<String, Object?> info) {
    final timestamp = (info['timestamp'] as num?)?.toInt() ?? 0;
    final reason = (info['reason'] as num?)?.toInt() ?? 0;
    final parts = <String>[
      'previous run ended: ${_reasonLabel(reason)} (reason $reason)'
          '${reason == 2 && info['status'] == 9 ? ' [SIGKILL; source unknown]' : ''}',
      if (timestamp > 0)
        'at ${DateTime.fromMillisecondsSinceEpoch(timestamp).toIso8601String()}',
      'importance ${info['importance'] ?? '?'}',
      'pid ${info['pid'] ?? '?'}',
      'pss ${info['pss'] ?? '?'}kB',
      'rss ${info['rss'] ?? '?'}kB',
      'status ${info['status'] ?? '?'}',
    ];
    final description = info['description'];
    if (description is String && description.isNotEmpty) {
      parts.add(description);
    }
    return '[native-exit] ${parts.join(' ')}';
  }

  String _reasonLabel(int reason) => switch (reason) {
    1 => 'exit self',
    2 => 'signal',
    3 => 'low memory',
    4 => 'crash',
    5 => 'native crash',
    6 => 'anr',
    7 => 'initialization failure',
    8 => 'permission change',
    9 => 'excessive resource usage',
    10 => 'user requested',
    11 => 'user stopped',
    12 => 'dependency died',
    13 => 'other',
    _ => 'unknown',
  };
}
