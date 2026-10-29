import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flick/core/utils/app_log.dart';

/// Persistent, bounded, privacy-safe diagnostic events for Atmos investigation.
///
/// Never pass track titles, IDs, file paths, URL values, raw provider responses,
/// exceptions or signed download links. Each field must be a known diagnostic
/// property; string values must be categorical tokens, not arbitrary text.
class AtmosDiagnostics {
  AtmosDiagnostics._();

  static const _safeKeys = <String>{
    'stage', 'mode', 'quality', 'codec', 'engine', 'desiredEngine',
    'reason', 'outcome', 'errorClass', 'errorCode', 'container', 'source',
    'from', 'to',
    'jocDecoder', 'passthrough', 'ac4Decoder', 'ac4Passthrough',
    'available', 'encoded',
    'downloadOnly', 'crossfadeDisabled', 'requested', 'sdk',
    'sampleRate', 'channels', 'trackCount', 'megabytes',
  };

  static String format(String event, [Map<String, Object?> fields = const {}]) {
    final value = <String, Object?>{
      'event': _token(event),
    };
    for (final entry in fields.entries) {
      if (!_safeKeys.contains(entry.key)) continue;
      final item = entry.value;
      if (item is bool) {
        value[entry.key] = item;
      } else if (item is int && item >= 0 && item <= 1000000) {
        value[entry.key] = item;
      } else if (item is String) {
        value[entry.key] = _token(item);
      }
    }
    return '[Atmos] ${jsonEncode(value)}';
  }

  static String _token(String input) =>
      RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]{0,47}$').hasMatch(input)
          ? input
          : 'redacted';

  static void record(String event, [Map<String, Object?> fields = const {}]) {
    final line = format(event, fields);
    // Both the in-app log export and logcat receive the same sanitized line,
    // even with developer mode disabled. No separate verbose/protocol logs.
    AppLog.instance.add(line, source: LogSource.dart);
    debugPrint(line);
  }
}
