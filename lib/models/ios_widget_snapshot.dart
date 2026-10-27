import 'dart:convert';

/// Metadata-only wire contract shared with the optional WidgetKit extension.
/// No app publisher or App Group is enabled by this model alone.
class IosWidgetSnapshot {
  IosWidgetSnapshot._(this._json);

  static const schemaVersion = 1;
  static const maximumBytes = 65536;
  static const maximumMediaMs = 604800000; // Seven days; no unbounded timers.
  static const maximumTimestampMs = 4102444800000; // 2100-01-01 UTC.
  static const staleAfterMs = 15 * 60 * 1000;
  static const futureToleranceMs = 5 * 60 * 1000;
  final Map<String, Object?> _json;

  factory IosWidgetSnapshot.decode(String document) {
    // Reject excessive nesting before the platform JSON parser recurses.
    if (document.length > maximumBytes ||
        utf8.encode(document).length > maximumBytes ||
        !_boundedNesting(document)) {
      return IosWidgetSnapshot.fromJson(null);
    }
    try {
      final raw = jsonDecode(document);
      return IosWidgetSnapshot.fromJson(_validJsonTree(raw) ? raw : null);
    } on FormatException {
      return IosWidgetSnapshot.fromJson(null);
    }
  }

  factory IosWidgetSnapshot.fromJson(Object? raw) {
    final data = raw is Map && _integer(raw['schemaVersion'], 1, 1) == 1
        ? raw
        : const <String, Object?>{};
    final current = _track(data['current']);
    final recommendations = <Map<String, Object?>>[];
    final seen = <String>{};
    final candidates = data['recommendations'];
    if (candidates is List) {
      for (final raw in candidates.take(48)) {
        final row = _track(raw);
        if (row != null && seen.add(row['id']! as String)) {
          recommendations.add(row);
          if (recommendations.length == 12) break;
        }
      }
    }
    final duration = current == null
        ? 0
        : _integer(data['durationMs'], 0, maximumMediaMs) ?? 0;
    var position = current == null
        ? 0
        : _integer(data['positionMs'], 0, maximumMediaMs) ?? 0;
    if (duration > 0 && position > duration) position = duration;
    final color = _integer(data['accentArgb'], -2147483648, 4294967295);
    final kind = data['flowKind'];
    final rate = data['playbackRate'];
    return IosWidgetSnapshot._({
      'schemaVersion': schemaVersion,
      'revision': _integer(data['revision'], 0, 9007199254740991) ?? 0,
      'updatedAtMs': _integer(data['updatedAtMs'], 1, maximumTimestampMs) ?? 0,
      'current': current,
      'lastArtwork': current?['artwork'] ?? _artwork(data['lastArtwork']),
      'isPlaying': current != null && data['isPlaying'] == true,
      'isBuffering': current != null && data['isBuffering'] == true,
      'positionMs': position,
      'durationMs': duration,
      'playbackRate': rate is num && rate.isFinite && rate >= .25 && rate <= 4
          ? rate.toDouble()
          : 1.0,
      'queueCount': _integer(data['queueCount'], 0, 1000000) ?? 0,
      // Legacy unsigned ARGB is accepted; the wire value is always Int32.
      'accentArgb': color?.toSigned(32) ?? 0,
      'flowKind': kind == 'flow' || kind == 'radio' ? kind : 'none',
      'flowStatus': _text(data['flowStatus']),
      'recommendations': recommendations,
    });
  }

  /// Returns a detached allowlist, so a caller cannot mutate a saved snapshot.
  Map<String, Object?> toJson() {
    final current = _json['current'] as Map<String, Object?>?;
    return {
      ..._json,
      'current': current == null ? null : {...current},
      'recommendations': [
        for (final row in _json['recommendations']! as List)
          {...row as Map<String, Object?>},
      ],
    };
  }

  String encode() => jsonEncode(_json);

  bool isStaleAt(int nowMs) {
    final updated = _json['updatedAtMs']! as int;
    return updated == 0 ||
        nowMs < 1 ||
        nowMs > maximumTimestampMs ||
        updated - nowMs > futureToleranceMs ||
        nowMs - updated > staleAfterMs;
  }

  /// WidgetKit can render system progress from the accepted timestamp. Never
  /// advance an unknown-duration, stale, future-dated or paused recording.
  int projectedPositionAt(int nowMs) {
    final position = _json['positionMs']! as int;
    final duration = _json['durationMs']! as int;
    if (duration == 0 ||
        _json['isPlaying'] != true ||
        _json['isBuffering'] == true ||
        isStaleAt(nowMs)) {
      return position;
    }
    final elapsed = (nowMs - (_json['updatedAtMs']! as int)).clamp(
      0,
      staleAfterMs,
    );
    return (position + (elapsed * (_json['playbackRate']! as double)).floor())
        .clamp(0, duration);
  }

  static Map<String, Object?>? _track(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    // IDs are SHA-256 aliases resolved inside the app. Never serialize a raw
    // Song.id/path/remoteId, which can contain a URL or a provider credential.
    if (id is! String ||
        id.length != 64 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      return null;
    }
    return {
      'id': id,
      'title': _text(raw['title']),
      'artist': _text(raw['artist']),
      'album': _text(raw['album']),
      // Content-addressed files copied into the group by the future native
      // publisher. No absolute paths, URLs or caller-supplied directories.
      'artwork': _artwork(raw['artwork']),
    };
  }

  static String? _artwork(Object? raw) =>
      raw is String &&
          raw.length == 68 &&
          RegExp(r'^[a-f0-9]{64}\.(jpg|png)$').hasMatch(raw)
      ? raw
      : null;

  static int? _integer(Object? raw, int minimum, int maximum) {
    if (raw is! num ||
        !raw.isFinite ||
        raw < minimum ||
        raw > maximum ||
        raw != raw.truncateToDouble()) {
      return null;
    }
    return raw.toInt();
  }

  static String _text(Object? raw) {
    if (raw is! String) return '';
    final scalars = <int>[];
    var bytes = 0;
    // Bound work as well as stored text; do not scan an arbitrary huge value.
    for (final rune in raw.runes.take(1024)) {
      if (rune < 32 || rune == 127 || (rune >= 0xd800 && rune <= 0xdfff)) {
        continue;
      }
      final width = rune <= 0x7f
          ? 1
          : rune <= 0x7ff
          ? 2
          : rune <= 0xffff
          ? 3
          : 4;
      if (scalars.length == 256 || bytes + width > 1024) break;
      scalars.add(rune);
      bytes += width;
    }
    return String.fromCharCodes(scalars).replaceAll(RegExp(r'^ +| +$'), '');
  }

  static bool _boundedNesting(String text) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (final unit in text.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == 92) {
          escaped = true;
        } else if (unit == 34) {
          inString = false;
        }
      } else if (unit == 34) {
        inString = true;
      } else if (unit == 91 || unit == 123) {
        if (++depth > 8) return false;
      } else if (unit == 93 || unit == 125) {
        if (--depth < 0) return false;
      }
    }
    return !inString && depth == 0;
  }

  // Foundation rejects non-finite JSON numbers and unpaired UTF-16 escapes.
  // Match that boundary rather than letting the two readers diverge.
  static bool _validJsonTree(Object? value) {
    if (value is num) return value.isFinite;
    if (value is String) {
      final units = value.codeUnits;
      for (var i = 0; i < units.length; i++) {
        final unit = units[i];
        if (unit >= 0xd800 && unit <= 0xdbff) {
          if (++i == units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
            return false;
          }
        } else if (unit >= 0xdc00 && unit <= 0xdfff) {
          return false;
        }
      }
    } else if (value is List) {
      return value.every(_validJsonTree);
    } else if (value is Map) {
      return value.entries.every(
        (entry) => _validJsonTree(entry.key) && _validJsonTree(entry.value),
      );
    }
    return true;
  }
}
