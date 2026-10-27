import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'app_preferences_service.dart';

/// An externally prepared, source-verified transition WAV; no Demucs model,
/// PyTorch runtime or CPU-intensive audio decoding runs inside Flutter.
class AutoMixStemClip {
  const AutoMixStemClip({
    required this.path,
    required this.outStart,
    required this.inStart,
    required this.resumeIn,
    required this.durationSeconds,
  });

  final String path;
  final double outStart;
  final double inStart;
  final double resumeIn;
  final double durationSeconds;

  Duration get start => Duration(milliseconds: (outStart * 1000).round());
  Duration get resume => Duration(milliseconds: (resumeIn * 1000).round());
  Duration get length =>
      Duration(milliseconds: (durationSeconds * 1000).round());

  static const schema = 'lokal-automix-stem-clip-v1';

  static AutoMixStemClip? parse(
    Object? raw,
    String audioPath, {
    required String outgoingSha,
    required String incomingSha,
    required String clipSha,
    required int clipBytes,
  }) {
    if (raw is! Map<String, dynamic> || raw['schema'] != schema) return null;
    final source = raw['source'],
        audio = raw['clip'],
        timeline = raw['timeline'];
    if (source is! Map ||
        audio is! Map ||
        timeline is! Map ||
        source['outgoingSha256'] != outgoingSha ||
        source['incomingSha256'] != incomingSha ||
        audio['sha256'] != clipSha ||
        audio['bytes'] != clipBytes) {
      return null;
    }
    double? validNumber(Object? value) =>
        value is num && value.toDouble().isFinite ? value.toDouble() : null;
    final outStart = validNumber(timeline['outStart']);
    final inStart = validNumber(timeline['inStart']);
    final resumeIn = validNumber(timeline['resumeIn']);
    final length = validNumber(timeline['length']);
    final masterGain = validNumber(timeline['masterGain']);
    final encodedLength = validNumber(audio['durationSeconds']);
    if (outStart == null ||
        inStart == null ||
        resumeIn == null ||
        length == null ||
        masterGain == null ||
        encodedLength == null ||
        outStart < 15 ||
        inStart < 0 ||
        inStart > 60 ||
        resumeIn <= inStart ||
        resumeIn > 7200 ||
        length < 6 ||
        length > 45 ||
        masterGain <= 0 ||
        masterGain > 1.05 ||
        (encodedLength - length).abs() > .1) {
      return null;
    }
    return AutoMixStemClip(
      path: audioPath,
      outStart: outStart,
      inStart: inStart,
      resumeIn: resumeIn,
      durationSeconds: length,
    );
  }

  static bool suitableForCues(
    AutoMixStemClip clip, {
    required double? outgoingStart,
    required double? incomingStart,
  }) =>
      outgoingStart != null &&
      incomingStart != null &&
      (clip.outStart - outgoingStart).abs() <= 1.2 &&
      (clip.inStart - incomingStart).abs() <= 1.2;
}

/// Scan only the outgoing recording's own folder, matching a strictly bounded
/// sidecar suffix. Users can transfer the desktop-made WAV + JSON even if
/// Android gives the original audio files different absolute paths.
class AutoMixStemClipCache {
  AutoMixStemClipCache._();
  static final instance = AutoMixStemClipCache._();
  final Map<String, Future<AutoMixStemClip?>> _pending = {};
  static final fileName = RegExp(r'\.lokal-stem-to-[a-f0-9]{24}\.wav$');

  Future<AutoMixStemClip?> read(Song outgoing, Song incoming) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(AppPreferencesService.automixStemClipsKey) ?? false)) {
      return null;
    }
    final a = outgoing.filePath, b = incoming.filePath;
    if (a == null ||
        b == null ||
        a.isEmpty ||
        b.isEmpty ||
        a == b ||
        outgoing.isNetworkSource ||
        incoming.isNetworkSource ||
        !a.startsWith('/') ||
        !b.startsWith('/') ||
        outgoing.atmosEncoded ||
        incoming.atmosEncoded ||
        outgoing.startOffsetMs != null ||
        outgoing.endOffsetMs != null ||
        incoming.startOffsetMs != null ||
        incoming.endOffsetMs != null) {
      return null;
    }
    FileStat firstStamp, secondStamp;
    try {
      firstStamp = await File(a).stat();
      secondStamp = await File(b).stat();
      if (firstStamp.type != FileSystemEntityType.file ||
          secondStamp.type != FileSystemEntityType.file)
        return null;
    } catch (_) {
      return null;
    }
    // Prevent reusing a previously verified pair after an in-place replace.
    final key = jsonEncode([
      a,
      b,
      firstStamp.size,
      firstStamp.modified.millisecondsSinceEpoch,
      secondStamp.size,
      secondStamp.modified.millisecondsSinceEpoch,
    ]);
    if (_pending[key] case final cached?) return cached;
    final future = _resolve(a, b);
    _pending[key] = future;
    if (_pending.length > 12) _pending.remove(_pending.keys.first);
    return future;
  }

  Future<AutoMixStemClip?> _resolve(String outgoing, String incoming) async {
    try {
      final folder = File(outgoing).parent;
      var inspected = 0;
      await for (final candidate in folder.list(followLinks: false)) {
        // No recursive scan, no file downloads and no large manifests.
        if (candidate is! File ||
            !candidate.path.startsWith('$outgoing.lokal-stem-to-') ||
            !fileName.hasMatch(candidate.path))
          continue;
        if (++inspected > 32) break;
        final wavStat = await candidate.stat();
        if (wavStat.type != FileSystemEntityType.file ||
            wavStat.size < 128 ||
            wavStat.size > 100 * 1024 * 1024)
          continue;
        // Reject non-WAV payloads before passing any sidecar to Media3.
        final handle = await candidate.open();
        List<int> header;
        try {
          header = await handle.read(12);
        } finally {
          await handle.close();
        }
        if (header.length != 12 ||
            !['RIFF', 'RF64'].contains(ascii.decode(header.sublist(0, 4))) ||
            ascii.decode(header.sublist(8, 12)) != 'WAVE')
          continue;
        final manifest = File('${candidate.path}.json');
        final mstat = await manifest.stat();
        if (mstat.size < 100 || mstat.size > 16 * 1024) continue;
        final raw = jsonDecode(await manifest.readAsString());
        if (raw is! Map || raw['schema'] != AutoMixStemClip.schema) continue;
        final clip = raw['clip'], source = raw['source'];
        if (clip is! Map ||
            source is! Map ||
            clip['bytes'] != wavStat.size ||
            !isSha(clip['sha256']) ||
            !isSha(source['outgoingSha256']) ||
            !isSha(source['incomingSha256']))
          continue;
        // Hash large local source files off the UI isolate. The result is
        // memoized per pair, never run for remote streaming or during audio
        // decoding. Check this candidate's original bytes AND mixed clip.
        final paths = [outgoing, incoming, candidate.path];
        final hashes = await Isolate.run(() async {
          final result = <String>[];
          for (final path in paths) {
            result.add(
              (await sha256.bind(File(path).openRead()).first).toString(),
            );
          }
          return result;
        });
        final parsed = AutoMixStemClip.parse(
          raw,
          candidate.path,
          outgoingSha: hashes[0],
          incomingSha: hashes[1],
          clipSha: hashes[2],
          clipBytes: wavStat.size,
        );
        if (parsed != null) return parsed;
      }
    } catch (_) {
      // Optional asset. Any corrupt/absent clip retains original crossfade.
    }
    return null;
  }

  static bool isSha(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  void invalidate() => _pending.clear();
}
