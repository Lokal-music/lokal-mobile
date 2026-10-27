import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Read-only CUE-DETR report produced by the desktop/offline importer.
/// No Python, ML model weights, or untrusted remote URLs are executed here.
class AutoMixAdvancedReport {
  const AutoMixAdvancedReport({
    required this.durationSeconds,
    required this.entrances,
    required this.exits,
    this.bpm,
  });

  static const suffix = '.lokal-automix.json';
  static const maxBytes = 128 * 1024;
  final double durationSeconds;
  final List<double> entrances;
  final List<double> exits;
  final double? bpm;

  static AutoMixAdvancedReport? parse(
    Object? raw, {
    required int sourceSize,
    required int sourceModifiedMs,
    required double expectedDuration,
    bool verifiedContentHash = false,
  }) {
    if (raw is! Map<String, dynamic> ||
        raw['schema'] != 'lokal-automix-advanced-v1') return null;
    final source = raw['source'];
    final analyzer = raw['analyzer'];
    final cueRoot = raw['transitionCues'];
    if (source is! Map || analyzer is! Map || cueRoot is! Map ||
        source['size'] != sourceSize ||
        source['mtimeMs'] is! num ||
        (!verifiedContentHash &&
         ((source['mtimeMs'] as num).toDouble() - sourceModifiedMs).abs() > 2) ||
        source['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(source['sha256'] as String) ||
        analyzer['id'] != 'disco-eth/cue-detr' ||
        analyzer['revision'] is! String ||
        (analyzer['revision'] as String).length > 150) return null;

    double? positiveNumber(Object? input) {
      if (input is! num || !input.toDouble().isFinite) return null;
      return input.toDouble();
    }
    final duration = positiveNumber(raw['durationSeconds']);
    if (duration == null || duration < 20 || duration > 7200 ||
        (duration - expectedDuration).abs() > 2) return null;
    final bpm = raw['bpm'] == null ? null : positiveNumber(raw['bpm']);
    if (bpm != null && (bpm < 50 || bpm > 220)) return null;

    List<double>? cues(Object? raw) {
      if (raw is! List || raw.length > 24) return null;
      final parsed = <double>[];
      for (final item in raw) {
        if (item is! Map) return null;
        final time = positiveNumber(item['time']);
        final confidence = positiveNumber(item['confidence']);
        if (time == null || confidence == null ||
            time < 0 || time > duration ||
            confidence < 0.55 || confidence > 1) return null;
        parsed.add(time);
      }
      return List.unmodifiable(parsed);
    }
    final entrances = cues(cueRoot['entrances']);
    final exits = cues(cueRoot['exits']);
    if (entrances == null || exits == null) return null;
    return AutoMixAdvancedReport(
      durationSeconds: duration, entrances: entrances, exits: exits, bpm: bpm,
    );
  }

  static Future<AutoMixAdvancedReport?> read(
    String audioPath,
    FileStat audioStamp,
    Duration expectedDuration,
  ) async {
    try {
      final file = File('$audioPath$suffix');
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size <= 0 || stat.size > maxBytes) return null;
      final raw = jsonDecode(await file.readAsString());
      final duration = expectedDuration.inMilliseconds / 1000;
      final timestampMatch = parse(raw,
        sourceSize: audioStamp.size,
        sourceModifiedMs: audioStamp.modified.millisecondsSinceEpoch,
        expectedDuration: duration);
      if (timestampMatch != null) return timestampMatch;
      // A copied file may have the same exact bytes but a different mtime.
      // Only explicitly prepared, structurally valid sidecars can trigger
      // content verification. Hashing is asynchronous and restricted to the
      // local file; ordinary playback never downloads or decodes anything.
      final portable = parse(raw,
        sourceSize: audioStamp.size,
        sourceModifiedMs: audioStamp.modified.millisecondsSinceEpoch,
        expectedDuration: duration,
        verifiedContentHash: true);
      if (portable == null || raw is! Map) return null;
      final source = raw['source'];
      if (source is! Map || source['sha256'] is! String) return null;
      final expectedHash = source['sha256'] as String;
      // Large lossless files can take appreciable CPU to hash. Never run
      // source validation on Flutter's UI isolate.
      final actualHash = await Isolate.run(() async =>
          (await sha256.bind(File(audioPath).openRead()).first).toString());
      return actualHash == expectedHash ? portable : null;
    } catch (_) {
      return null;
    }
  }
}
