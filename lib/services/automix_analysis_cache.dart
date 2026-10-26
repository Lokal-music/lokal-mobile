import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../data/entities/song_audio_cache_entity.dart';
import '../data/repositories/song_repository.dart';
import '../models/song.dart';

/// Lightweight cue and energy hints derived from the existing, persisted
/// waveform cache. These are NOT beat grids, vocal detection or Demucs stems.
/// A future optional model analyzer can use a different version/quality tier.
class AutoMixProfile {
  const AutoMixProfile({
    required this.durationSeconds,
    required this.leadInSeconds,
    required this.audibleEndSeconds,
    required this.fadeOutStartSeconds,
    required this.entrances,
    required this.exits,
    this.energy,
  });

  final double durationSeconds;
  final double leadInSeconds;
  final double audibleEndSeconds;
  final double fadeOutStartSeconds;
  final List<double> entrances;
  final List<double> exits;
  final double? energy;

  Map<String, dynamic> toJson() => {
    'duration': durationSeconds,
    'leadIn': leadInSeconds,
    'audibleEnd': audibleEndSeconds,
    'fadeOutStart': fadeOutStartSeconds,
    'entrances': entrances,
    'exits': exits,
    'energy': energy,
  };

  static AutoMixProfile? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    double? number(Object? input) {
      if (input is! num || !input.toDouble().isFinite) return null;
      return input.toDouble();
    }
    final duration = number(value['duration']);
    final start = number(value['leadIn']);
    final end = number(value['audibleEnd']);
    final fade = number(value['fadeOutStart']);
    if (duration == null || duration <= 0 || start == null || end == null ||
        fade == null || start < 0 || end > duration || end <= start ||
        fade < start || fade > end) return null;
    List<double>? cues(Object? raw) {
      if (raw is! List || raw.length > 24) return null;
      final values = <double>[];
      for (final item in raw) {
        final time = number(item);
        if (time == null || time < 0 || time > duration) return null;
        values.add(time);
      }
      return List.unmodifiable(values);
    }
    final entrances = cues(value['entrances']);
    final exits = cues(value['exits']);
    if (entrances == null || exits == null) return null;
    final energy = value['energy'] == null ? null : number(value['energy']);
    if (energy != null && (energy < 0 || energy > 1)) return null;
    return AutoMixProfile(
      durationSeconds: duration, leadInSeconds: start,
      audibleEndSeconds: end, fadeOutStartSeconds: fade,
      entrances: entrances, exits: exits, energy: energy,
    );
  }

  /// Low-resolution analysis of already cached 240-point waveform peaks.
  /// Never infer BPM/beat phase or a vocal-free phrase from these amplitudes.
  static AutoMixProfile? fromWaveform(
    List<double> peaks, Duration duration, {double? lufs}
  ) {
    final seconds = duration.inMilliseconds / 1000.0;
    if (peaks.length < 12 || seconds < 20 ||
        peaks.any((v) => !v.isFinite || v < 0)) return null;
    final maxPeak = peaks.reduce(math.max);
    if (maxPeak <= 0) return null;
    final normalized = peaks.map((v) => v / maxPeak).toList(growable: false);
    final bucket = seconds / normalized.length;
    // Near-digital silence only (~-54 dB relative peak). Do not classify
    // acoustic intros, quiet breakdowns or intentional fade tails as silence.
    const floor = 0.002;
    var first = 0;
    while (first < normalized.length && normalized[first] < floor) first++;
    var last = normalized.length - 1;
    while (last > first && normalized[last] < floor) last--;
    if (first >= last) return null;
    final lead = first * bucket;
    final audibleEnd = math.min(seconds, (last + 1) * bucket);
    // Only a sustained fall in the final 20 seconds counts as a fade.
    final active = normalized.sublist(first, last + 1)..sort();
    final reference = active[active.length ~/ 2];
    var fadeIndex = last;
    if (reference > 0.08) {
      final searchStart = math.max(first, last - (20 / bucket).ceil());
      var below = 0;
      for (var i = last; i >= searchStart; i--) {
        if (normalized[i] < reference * 0.55) {
          below++;
          if (below >= 2) fadeIndex = i;
        } else if (below >= 2) {
          break;
        } else {
          below = 0;
        }
      }
    }
    double mean(int from, int to) {
      if (from >= to) return 0;
      var total = 0.0;
      for (var i = from; i < to; i++) {
        total += normalized[i] * normalized[i];
      }
      return math.sqrt(total / (to - from));
    }
    final entrances = <double>[];
    final exits = <double>[];
    final window = math.max(1, (3 / bucket).ceil());
    final step = math.max(1, (2 / bucket).ceil());
    for (var i = first + window; i + window < last; i += step) {
      final before = mean(i - window, i);
      final after = mean(i, i + window);
      final changeDb = 20 * math.log((after + 0.001) / (before + 0.001)) / math.ln10;
      final t = i * bucket;
      if (changeDb >= 6 && t <= math.min(65, seconds * 0.4) &&
          entrances.length < 8) entrances.add(t);
      if (changeDb <= -6 && t >= math.max(15, seconds - 75) &&
          exits.length < 8) exits.add(t);
    }
    final energy = lufs != null && lufs.isFinite
        ? ((lufs + 30) / 22).clamp(0.0, 1.0).toDouble()
        : null;
    return AutoMixProfile(
      durationSeconds: seconds,
      leadInSeconds: lead,
      audibleEndSeconds: audibleEnd,
      fadeOutStartSeconds: math.min(audibleEnd, fadeIndex * bucket),
      entrances: List.unmodifiable(entrances),
      exits: List.unmodifiable(exits),
      energy: energy,
    );
  }
}

typedef AutoMixWaveformLoader = Future<SongAudioCacheEntity?> Function(int id);
typedef AutoMixDirectory = Future<Directory> Function();

/// Content-stamped, on-disk DJ cue cache. Reuses Isar's waveform/LUFS data;
/// no playback request has to decode PCM or initialize a machine-learning
/// model. A changed file, CUE segment, or algorithm version gets a new key.
/// Entries are bounded and written atomically so force-closes cannot publish
/// partial JSON or leave a growing cache for large libraries.
class AutoMixAnalysisCache {
  AutoMixAnalysisCache({AutoMixWaveformLoader? loadWaveform, AutoMixDirectory? directory})
    : _loadWaveform = loadWaveform ?? ((id) => SongRepository().getAudioCache(id)),
      _directory = directory ?? (() async {
        final root = await getApplicationSupportDirectory();
        return Directory('${root.path}/automix_profiles');
      });

  static final instance = AutoMixAnalysisCache();
  static const version = 1;
  static const maxEntries = 512;

  final AutoMixWaveformLoader _loadWaveform;
  final AutoMixDirectory _directory;
  final Map<String, Future<AutoMixProfile?>> _inFlight = {};
  final Map<String, AutoMixProfile> _memory = {};
  int _writes = 0;
  int _nonce = 0;

  /// Cache-only lookup: unsupported, remote, CUE-sliced and not-yet-scanned
  /// sources fall back to ordinary crossfade. Never downloads signed streams.
  Future<AutoMixProfile?> read(Song song) async {
    final path = song.filePath;
    final songId = int.tryParse(song.id);
    if (songId == null || path == null || path.isEmpty ||
        path.contains('://') || song.isNetworkSource ||
        song.startOffsetMs != null || song.endOffsetMs != null ||
        song.duration.inMilliseconds < 20000) return null;
    final source = File(path);
    FileStat stamp;
    try {
      stamp = await source.stat();
      if (stamp.type != FileSystemEntityType.file) return null;
    } catch (_) { return null; }
    final identity = sha256.convert(utf8.encode(jsonEncode([
      version, path, stamp.size, stamp.modified.millisecondsSinceEpoch,
      song.duration.inMilliseconds,
    ]))).toString();
    if (_memory[identity] case final cached?) return cached;
    if (_inFlight[identity] case final existing?) return existing;
    final task = _readOrCreate(songId, stamp, identity, song.duration);
    _inFlight[identity] = task;
    try { return await task; } finally { _inFlight.remove(identity); }
  }

  Future<AutoMixProfile?> _readOrCreate(
    int songId, FileStat stamp, String identity, Duration duration,
  ) async {
    try {
      final directory = await _directory();
      final file = File('${directory.path}/$identity.json');
      if (await file.exists()) {
        try {
          final profile = AutoMixProfile.fromJson(jsonDecode(await file.readAsString()));
          if (profile != null) return _remember(identity, profile);
        } catch (_) {
          // Half-written/corrupted old entries are regenerable, not fatal.
        }
        // Delete only a malformed *derived* cache entry; never touch audio
        // or the underlying Isar waveform scan.
        try { await file.delete(); } catch (_) {}
      }
      final cached = await _loadWaveform(songId);
      if (cached == null || cached.version != 1 || cached.peaks.isEmpty ||
          cached.computedAt < stamp.modified.millisecondsSinceEpoch) return null;
      final profile = AutoMixProfile.fromWaveform(
        cached.peaks, duration, lufs: cached.lufs,
      );
      if (profile == null) return null;
      await directory.create(recursive: true);
      final temp = File('${file.path}.${_nonce++}.tmp');
      try {
        await temp.writeAsString(jsonEncode(profile.toJson()), flush: true);
        await temp.rename(file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      if (++_writes % 32 == 0) unawaited(_prune(directory));
      return _remember(identity, profile);
    } catch (_) {
      // Storage can be full or metadata unavailable: use normal crossfade.
      return null;
    }
  }

  AutoMixProfile _remember(String identity, AutoMixProfile profile) {
    if (_memory.length >= 32) _memory.remove(_memory.keys.first);
    _memory[identity] = profile;
    return profile;
  }

  /// Serial warm-up of the immediate local queue; no parallel Rust decoding,
  /// network requests, or waiting for the player to start.
  Future<void> warm(Iterable<Song> songs, {int limit = 4}) async {
    for (final song in songs.take(limit.clamp(0, 8))) {
      await read(song);
    }
  }

  Future<void> _prune(Directory directory) async {
    try {
      final files = await directory.list().where((entry) =>
          entry is File && entry.path.endsWith('.json')).cast<File>().toList();
      if (files.length <= maxEntries) return;
      final dated = await Future.wait(files.map((file) async =>
          (file: file, time: (await file.stat()).modified)));
      dated.sort((a, b) => a.time.compareTo(b.time));
      for (final entry in dated.take(dated.length - maxEntries)) {
        try { await entry.file.delete(); } catch (_) {}
      }
    } catch (_) {}
  }
}
