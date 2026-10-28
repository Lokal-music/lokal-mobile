import 'lyrics_matching.dart';

import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'lyrics_sources.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/models/song.dart';
import 'package:flick/services/online_lyrics_service.dart';

/// A single word (or whitespace-joined token) within a lyric line, with an
/// optional timing window for karaoke-style highlighting.
class LyricsWord {
  final Duration start;
  final Duration end;
  final String text;

  const LyricsWord({
    required this.start,
    required this.end,
    required this.text,
  });
}

/// A single lyric line, optionally timestamped for synchronized display.
/// [words] carries per-word timings when the source was enhanced LRC;
/// otherwise it is null and the renderer keeps whole-line timing.
class LyricsLine {
  final Duration timestamp;
  final String text;
  final List<LyricsWord>? words;

  /// The line in another language, shown under it: in an LRC, the unstamped
  /// line right under a stamped one (desktop Lokal v9.2's rule).
  final String? translation;

  const LyricsLine({
    required this.timestamp,
    required this.text,
    this.words,
    this.translation,
  });

  LyricsLine withTranslation(String? translation) => LyricsLine(
    timestamp: timestamp,
    text: text,
    words: words,
    translation: translation,
  );
}

/// Parsed lyrics payload.
class LyricsData {
  final List<LyricsLine> lines;
  final bool isSynchronized;
  final String? source;
  final String rawContent;
  final String? language, translationLanguage;

  const LyricsData({
    required this.lines,
    required this.isSynchronized,
    this.source,
    required this.rawContent,
    this.language,
    this.translationLanguage,
  });
}

/// Last checked availability for an individual lyric provider on one song.
class LyricsSourceHit {
  final String status; // 'checking', 'hit', or 'miss'
  final String? timing; // 'Syllable', 'Line', or 'Plain'
  const LyricsSourceHit(this.status, [this.timing]);
}

class LyricsSaveResult {
  final LyricsData data;
  final String path;
  final bool savedBesideSong;

  const LyricsSaveResult({
    required this.data,
    required this.path,
    required this.savedBesideSong,
  });
}

class LyricsService {
  static const MethodChannel _storageChannel = MethodChannel(
    'com.mossapps.flick/storage',
  );
  static const String _manualLyricsOverridesKey = 'lyrics_manual_overrides_v1';
  static const String _managedLyricsDirectoryName = 'lyrics';
  static final RegExp _wordTimestampPattern = RegExp(
    r'<(\d{1,2}:\d{2}(?::\d{2})?(?:\.\d{1,3})?)>',
  );

  LyricsService({this.online});

  /// Where lyrics are looked up online (LRCLIB unless given).
  final OnlineLyricsService? online;
  final Map<String, LyricsData?> _cache = {};
  // Shared across the player and the prefetcher's LyricsService instance.
  // A source receives a green check only after usable lyrics were actually
  // parsed for this recording; stale hits never carry over to another song.
  static final ValueNotifier<int> sourceHitsRevision = ValueNotifier<int>(0);
  static final Map<String, Map<String, LyricsSourceHit>> _sourceHits = {};
  static final Map<String, DateTime> _sourceHitChecks = {};
  static final Map<String, Future<void>> _sourceProbes = {};
  static const _sourceHitTtl = Duration(minutes: 10);

  static String _hitKey(Song song) =>
      '${song.id}|${song.title}|${song.artist}|${song.duration.inMilliseconds}';

  static LyricsSourceHit? sourceHitFor(Song song, String provider) =>
      _sourceHits[_hitKey(song)]?[provider];

  static void _setSourceHit(
    Song song, String provider, LyricsSourceHit value,
  ) {
    final key = _hitKey(song);
    if (!_sourceHits.containsKey(key) && _sourceHits.length >= 24) {
      final oldest = _sourceHits.keys.first;
      _sourceHits.remove(oldest);
      _sourceHitChecks.remove(oldest);
    }
    final byProvider = _sourceHits.putIfAbsent(key, () => {});
    byProvider[provider] = value;
    sourceHitsRevision.value++;
  }

  /// Probe only when the chooser is opened. Three bounded workers, 10-minute
  /// result reuse, no automatic network fanout for ordinary playback.
  Future<void> probeSourceHits(Song song) {
    final key = _hitKey(song);
    final running = _sourceProbes[key];
    if (running != null) return running;
    final checked = _sourceHitChecks[key];
    if (checked != null &&
        DateTime.now().difference(checked) < _sourceHitTtl) {
      return Future.value();
    }
    final ids = <String>['local', ...lyricsSources.keys]
        .where((id) => _sourceHits[key]?[id]?.status != 'hit')
        .toList();
    for (final id in ids) {
      _setSourceHit(song, id, const LyricsSourceHit('checking'));
    }
    final future = _probeSourceHits(song, ids);
    _sourceProbes[key] = future;
    return future.whenComplete(() { _sourceProbes.remove(key); });
  }

  Future<void> _probeSourceHits(Song song, List<String> ids) async {
    var index = 0;
    Future<void> worker() async {
      while (index < ids.length) {
        final id = ids[index++];
        LyricsData? result;
        try {
          result = await (id == 'local'
              ? loadLyricsForSong(song, source: 'local')
              : fetchOnlineLyrics(song, source: id))
              .timeout(const Duration(seconds: 20), onTimeout: () => null);
        } catch (_) {}
        _setSourceHit(song, id, result != null && result.lines.isNotEmpty
            ? LyricsSourceHit(
                'hit',
                result.lines.any((l) => l.words?.isNotEmpty == true)
                    ? 'Syllable'
                    : result.isSynchronized ? 'Line' : 'Plain',
              )
            : const LyricsSourceHit('miss'));
      }
    }
    await Future.wait(List.generate(3, (_) => worker()));
    _sourceHitChecks[_hitKey(song)] = DateTime.now();
  }

  static int _desktopRevision = 0;
  int _seenDesktopRevision = 0;

  /// Notifies search results when local lyric sources are saved, replaced, or
  /// detached. Also includes lyrics delivered by the desktop sync channel.
  static final ValueNotifier<int> contentRevision = ValueNotifier<int>(0);
  int _seenContentRevision = contentRevision.value;

  /// The song's own lyrics (a manual pick, its tags, a file beside it). With
  /// [fetchOnline], a song that carries none is looked up on LRCLIB, as
  /// desktop's "Fetch lyrics automatically" does; nothing is written to disk.
  Future<LyricsData?> loadLyricsForSong(
    Song song, {
    bool forceRefresh = false,
    bool fetchOnline = false,
    bool refreshOnline = false,
    String source = 'auto',
    bool Function()? stillCurrent,
  }) async {
    if (refreshOnline) OnlineLyricsService.clearLookupCache();
    if (_seenDesktopRevision != _desktopRevision ||
        _seenContentRevision != contentRevision.value) {
      _cache.clear();
      _seenDesktopRevision = _desktopRevision;
      _seenContentRevision = contentRevision.value;
    }
    if (source != 'auto' && source != 'local')
      return fetchOnlineLyrics(
        song,
        source: source,
        stillCurrent: stillCurrent,
      );
    final own = await _loadOwnLyrics(song, forceRefresh: forceRefresh);
    if (!fetchOnline ||
        source == 'local' ||
        (!refreshOnline &&
            own?.lines.any((l) => l.words?.isNotEmpty == true) == true))
      return own;
    if (own != null && await getManualLyricsPathForSong(song) != null)
      return own;
    final found = await fetchOnlineLyrics(song, stillCurrent: stillCurrent);
    int rank(LyricsData? data) => data == null
        ? 0
        : data.lines.any((l) => l.words?.isNotEmpty == true)
        ? 3
        : data.isSynchronized
        ? 2
        : 1;
    return rank(found) > rank(own) ? found : own ?? found;
  }

  /// Ordered online fallback, or an explicit source selected during playback.
  Future<LyricsData?> fetchOnlineLyrics(
    Song song, {
    String source = 'auto',
    bool Function()? stillCurrent,
  }) async {
    if (song.title.trim().isEmpty || song.artist.trim().isEmpty) return null;
    final settings = online == null
        ? await LyricsSourcesState.load()
        : const LyricsSourcesState();
    final sources = source == 'auto'
        ? (online != null
              ? ['lrclib']
              : settings.order.where((id) => !settings.disabled.contains(id)))
        : [source];
    var active = true;
    bool current() => active && (stillCurrent?.call() ?? true);
    final query = song.copyWith(
      title: lyricsSearchTitle(song.title),
      artist: lyricsSearchArtist(song.artist),
    );
    Future<LyricsData?> fetch(String id) async {
      if (!current()) return null;
      try {
        String? text;
        if (id == 'lrclib') {
          final result = online != null
              ? await online!.fetchExact(
                  artist: song.artist,
                  title: song.title,
                  album: song.album,
                  duration: song.duration,
                )
              : await OnlineLyricsService().fetchBest(
                  artist: song.artist,
                  title: song.title,
                  album: song.album,
                  duration: song.duration,
                );
          if (result != null && !result.instrumental) text = result.bestLyrics;
        } else {
          text = await AdditionalLyricsSources.fetch(
            id,
            query,
            stillCurrent: current,
          );
        }
        if (!current() || text == null || text.trim().isEmpty) return null;
        if (text.trimLeft().startsWith('<') &&
            !text.contains('<tt') &&
            !text.contains('<line'))
          return null;
        final parsed = _parseLyrics(text, source: lyricsSources[id] ?? id);
        if (parsed.lines.isEmpty) return null;
        // Populate the chooser from lyrics the ordinary auto-lookup already
        // found. Opening it should not re-fetch known successful providers.
        _setSourceHit(song, id, LyricsSourceHit(
          'hit',
          parsed.lines.any((line) => line.words?.isNotEmpty == true)
              ? 'Syllable' : parsed.isSynchronized ? 'Line' : 'Plain',
        ));
        return parsed;
      } catch (_) {
        return null;
      }
    }

    // Start together, consume in saved priority order. Plain-only lyrics.ovh
    // is lazy, and plain text can never preempt a synchronized result.
    final jobs = {
      for (final id in sources)
        if (id != 'lyricsovh')
          id: fetch(id)
              .timeout(const Duration(seconds: 18), onTimeout: () => null),
    };
    LyricsData? lineFallback, plainFallback;
    try {
      for (final id in sources) {
        if (!current()) return null;
        if (id == 'lyricsovh' &&
            (lineFallback != null || plainFallback != null))
          continue;
        final parsed = await (jobs[id] ?? fetch(id));
        if (parsed == null) continue;
        if (source != 'auto') return parsed;
        if (parsed.lines.any((line) => line.words?.isNotEmpty == true))
          return parsed;
        if (parsed.isSynchronized) {
          if (!settings.preferWords) return parsed;
          lineFallback ??= parsed;
        } else {
          plainFallback ??= parsed;
        }
      }
      return lineFallback ?? plainFallback;
    } finally {
      active = false;
    }
  }

  Future<LyricsData?> _loadOwnLyrics(
    Song song, {
    bool forceRefresh = false,
  }) async {
    final filePath = song.filePath;
    if (filePath == null || filePath.isEmpty) return null;

    if (forceRefresh) {
      _cache.remove(filePath);
    }

    if (!forceRefresh && _cache.containsKey(filePath)) {
      return _cache[filePath];
    }

    final manualPath = await getManualLyricsPathForSong(song);
    if (manualPath != null && manualPath.isNotEmpty) {
      final manualLoaded = await _loadLyricsFromAbsolutePath(manualPath);
      if (manualLoaded != null && manualLoaded.content.trim().isNotEmpty) {
        final parsed = _parseLyrics(
          manualLoaded.content,
          source: manualLoaded.source,
        );
        _cache[filePath] = parsed;
        return parsed;
      }

      await clearManualLyricsPathForSong(song);
    }

    final desktop = await _desktopLyrics(song);
    if (desktop != null &&
        desktop.lines.any((l) => l.words?.isNotEmpty == true)) {
      _cache[filePath] = desktop;
      return desktop;
    }
    final loaded = await _loadLyricsText(filePath);
    if (loaded == null || loaded.content.trim().isEmpty) {
      if (desktop != null) {
        _cache[filePath] = desktop;
        return desktop;
      }
      final embedded = await _loadEmbeddedLyricsText(filePath);
      if (embedded != null && embedded.content.trim().isNotEmpty) {
        final parsed = _parseLyrics(embedded.content, source: embedded.source);
        _cache[filePath] = parsed;
        return parsed;
      }
      _cache[filePath] = null;
      return null;
    }

    final parsed = _parseLyrics(loaded.content, source: loaded.source);
    _cache[filePath] = parsed;
    return parsed;
  }

  static LyricsData? fromDesktop(Map<String, dynamic> payload) {
    final rows = payload['lines'];
    if (rows is! List) return null;
    Duration seconds(Object? value) => Duration(
      microseconds: ((value is num ? value.toDouble() : 0) * 1000000).round(),
    );
    final lines = <LyricsLine>[];
    for (final row in rows.whereType<Map>()) {
      if (row['gap'] == true) continue;
      final words = <LyricsWord>[];
      for (final word
          in (row['words'] is List ? row['words'] as List : const [])
              .whereType<Map>()) {
        if (word['time'] is! num || word['end'] is! num) continue;
        words.add(
          LyricsWord(
            start: seconds(word['time']),
            end: seconds(word['end']),
            text: '${word['word'] ?? ''}${word['space'] == true ? ' ' : ''}',
          ),
        );
      }
      final text = row['text']?.toString() ?? '';
      if (text.trim().isEmpty) continue;
      final translation = row['translation'];
      lines.add(
        LyricsLine(
          timestamp: seconds(row['time']),
          text: text,
          words: words.isEmpty ? null : words,
          translation: translation is Map
              ? translation['text']?.toString()
              : translation?.toString(),
        ),
      );
    }
    if (lines.isEmpty) return null;
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return LyricsData(
      lines: lines,
      isSynchronized:
          payload['type'] == 'synced' ||
          payload['type'] == 'syllable' ||
          payload['sync'] == 'syllable' ||
          payload['sync'] == 'line',
      source: payload['source']?.toString() ?? 'Desktop',
      rawContent: jsonEncode(payload),
      language: payload['language']?.toString(),
      translationLanguage: payload['translationLang']?.toString(),
    );
  }

  static Future<File> _desktopFile(Song song) async {
    final directory = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/desktop_lyrics',
    );
    await directory.create(recursive: true);
    return File('${directory.path}/${Uri.encodeComponent(song.id)}.json');
  }

  static Future<void> storeDesktopLyrics(
    Song song,
    Map<String, dynamic> payload,
  ) async {
    final candidate = fromDesktop(payload);
    if (candidate == null) return;
    final file = await _desktopFile(song);
    final encoded = jsonEncode(payload);
    int rank(LyricsData data) =>
        data.lines.any((l) => l.words?.isNotEmpty == true)
        ? 3
        : data.isSynchronized
        ? 2
        : 1;
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        if (raw == encoded) return;
        final existing = fromDesktop(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
        if (existing != null && rank(existing) > rank(candidate)) return;
      } catch (_) {}
    }
    final part = File('${file.path}.part');
    await part.writeAsString(encoded, flush: true);
    await part.rename(file.path);
    _desktopRevision++;
    contentRevision.value++;
  }

  static Future<LyricsData?> _desktopLyrics(Song song) async {
    try {
      final file = await _desktopFile(song);
      if (!await file.exists()) return null;
      return fromDesktop(
        Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> getManualLyricsPathForSong(Song song) async {
    final filePath = song.filePath;
    if (filePath == null || filePath.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_manualLyricsOverridesKey);
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = decoded[filePath];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    } catch (_) {
      // Ignore malformed preference payload and fall back to auto lookup.
    }

    return null;
  }

  Future<void> clearManualLyricsPathForSong(Song song) async {
    await _setManualLyricsPath(song, null);
  }

  Future<LyricsSaveResult> importLyricsForSong({
    required Song song,
    required String fileName,
    required String content,
  }) async {
    final extension = _preferredLyricsExtension(fileName);
    final savedPath = await _writeManagedLyricsCopy(
      song: song,
      extension: extension,
      content: content,
    );
    await _setManualLyricsPath(song, savedPath);
    final data =
        (await loadLyricsForSong(song, forceRefresh: true)) ??
        _parseLyrics(content, source: savedPath);
    return LyricsSaveResult(
      data: data,
      path: savedPath,
      savedBesideSong: false,
    );
  }

  Future<LyricsSaveResult> saveLyricsForSong({
    required Song song,
    required String content,
  }) async {
    final sidecarPath = suggestSidecarLrcPath(song);
    var savedBesideSong = false;
    late final String savedPath;

    if (sidecarPath != null) {
      try {
        final file = File(sidecarPath);
        await file.parent.create(recursive: true);
        await file.writeAsString(content);
        await _setManualLyricsPath(song, null);
        savedBesideSong = true;
        savedPath = file.path;
      } catch (_) {
        savedPath = await _writeManagedLyricsCopy(
          song: song,
          extension: 'lrc',
          content: content,
        );
        await _setManualLyricsPath(song, savedPath);
      }
    } else {
      savedPath = await _writeManagedLyricsCopy(
        song: song,
        extension: 'lrc',
        content: content,
      );
      await _setManualLyricsPath(song, savedPath);
    }

    final data =
        (await loadLyricsForSong(song, forceRefresh: true)) ??
        _parseLyrics(content, source: savedPath);
    return LyricsSaveResult(
      data: data,
      path: savedPath,
      savedBesideSong: savedBesideSong,
    );
  }

  Future<LyricsSaveResult> saveLyricsToPath({
    required Song song,
    required String content,
    required String path,
  }) async {
    final file = File(path);
    final alreadyExists = await file.exists();
    if (!alreadyExists) {
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }
    await _setManualLyricsPath(song, path);
    final data =
        (await loadLyricsForSong(song, forceRefresh: true)) ??
        _parseLyrics(content, source: path);
    return LyricsSaveResult(data: data, path: path, savedBesideSong: false);
  }

  Future<LyricsSaveResult> saveLyricsToManaged({
    required Song song,
    required String content,
  }) async {
    final path = await _writeManagedLyricsCopy(
      song: song,
      extension: 'lrc',
      content: content,
    );
    await _setManualLyricsPath(song, path);
    final data =
        (await loadLyricsForSong(song, forceRefresh: true)) ??
        _parseLyrics(content, source: path);
    return LyricsSaveResult(data: data, path: path, savedBesideSong: false);
  }

  int findCurrentLineIndex(LyricsData lyrics, Duration position) {
    if (!lyrics.isSynchronized || lyrics.lines.isEmpty) return -1;

    final targetMs = position.inMilliseconds;
    int left = 0;
    int right = lyrics.lines.length - 1;
    int result = -1;

    while (left <= right) {
      final mid = left + ((right - left) ~/ 2);
      final lineMs = lyrics.lines[mid].timestamp.inMilliseconds;
      if (lineMs <= targetMs) {
        result = mid;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }

    return result;
  }

  /// Whitespace-token matches used for karaoke word segmentation.
  static List<RegExpMatch> tokenMatches(String text) =>
      _tokenPattern.allMatches(text).toList();

  static final RegExp _tokenPattern = RegExp(r'\S+\s*');

  /// Splits a [LyricsWord] whose text spans multiple tokens into one segment
  /// per token, distributing the word's window proportionally to token
  /// length. Each segment renders with its own gradient, so a line that wraps
  /// across rows sweeps in reading order instead of highlighting the same
  /// horizontal band on every row.
  static List<LyricsWord> splitKaraokeWord(LyricsWord word) {
    final matches = tokenMatches(word.text);
    if (matches.length <= 1) return [word];

    final leading = word.text.substring(0, matches.first.start);
    final windowMs = word.end.inMilliseconds - word.start.inMilliseconds;

    final weights = [
      for (final match in matches)
        (match.group(0) ?? '').trim().length.clamp(1, 64),
    ];
    final weightSum = weights.fold<int>(0, (a, b) => a + b);

    final segments = <LyricsWord>[];
    var consumed = 0;
    for (var i = 0; i < matches.length; i++) {
      final text = (i == 0 ? leading : '') + (matches[i].group(0) ?? '');
      if (windowMs <= 0 || weightSum <= 0) {
        segments.add(LyricsWord(start: word.start, end: word.end, text: text));
        continue;
      }
      final startRatio = consumed / weightSum;
      consumed += weights[i];
      final endRatio = consumed / weightSum;
      segments.add(
        LyricsWord(
          start:
              word.start +
              Duration(milliseconds: (startRatio * windowMs).round()),
          end:
              word.start +
              Duration(milliseconds: (endRatio * windowMs).round()),
          text: text,
        ),
      );
    }
    return segments;
  }

  /// Fill progress (0..1) of a word at [position]. Values below the window
  /// are unsung, above fully sung.
  static double fillForWord(LyricsWord word, Duration position) {
    final startMs = word.start.inMilliseconds;
    final endMs = word.end.inMilliseconds;
    if (endMs <= startMs) return position >= word.end ? 1.0 : 0.0;
    final ratio =
        (position.inMilliseconds - startMs).toDouble() / (endMs - startMs);
    return ratio.clamp(0.0, 1.0);
  }

  /// Per-word timing windows for the given line. Enhanced-LRC lines chain
  /// their real timestamps. Plain synced lines carry no word data, so they
  /// get a single whole-line window instead of guessed per-word timing —
  /// the karaoke sweep then tracks real data only.
  /// Prepare word windows once for the fullscreen flowing-lyrics renderer.
  /// Embedded enhanced LRC stores word starts without ends (end == start);
  /// painting those directly makes the highlight jump in 1 ms steps.
  /// Preserve explicit end times from providers and leave original data intact.
  List<LyricsLine> playbackLines(LyricsData lyrics) {
    final rendered = <LyricsLine>[];
    for (var i = 0; i < lyrics.lines.length; i++) {
      final line = lyrics.lines[i];
      final words = line.words;
      if (words == null ||
          words.isEmpty ||
          words.every((word) => word.end > word.start)) {
        rendered.add(line);
        continue;
      }
      rendered.add(
        LyricsLine(
          timestamp: line.timestamp,
          text: line.text,
          words: resolveWords(lyrics, i),
          translation: line.translation,
        ),
      );
    }
    return rendered;
  }

  List<LyricsWord> resolveWords(LyricsData lyrics, int lineIndex) {
    final line = lyrics.lines[lineIndex];
    final lineEnd = _lineEndTime(lyrics, lineIndex);

    final existing = line.words;
    if (existing != null && existing.isNotEmpty) {
      return [
        for (var i = 0; i < existing.length; i++)
          LyricsWord(
            start: existing[i].start,
            end: i + 1 < existing.length
                ? existing[i + 1].start > existing[i].start
                      ? existing[i + 1].start
                      : existing[i].start
                : _tailTrimmedEnd(existing[i].start, lineEnd),
            text: existing[i].text,
          ),
      ];
    }

    if (line.text.trim().isEmpty) return const [];

    var end = _tailTrimmedEnd(line.timestamp, lineEnd);
    final maxWindow = const Duration(seconds: 6);
    if (end - line.timestamp > maxWindow) {
      end = line.timestamp + maxWindow;
    }
    return [LyricsWord(start: line.timestamp, end: end, text: line.text)];
  }

  Duration _lineEndTime(LyricsData lyrics, int index) {
    final ts = lyrics.lines[index].timestamp;
    // Concurrent lines may share the same timestamp. Do not give the first
    // one an arbitrary five-second end just because its immediate successor
    // starts at the same time; both should end against the next later line.
    for (var i = index + 1; i < lyrics.lines.length; i++) {
      final next = lyrics.lines[i].timestamp;
      if (next > ts) return next;
    }
    return ts + const Duration(seconds: 5);
  }

  /// Fraction of a line's lifetime the karaoke sweep spans. The remaining
  /// tail rests fully filled, so the scroll to the next line never starts
  /// while words are still filling.
  static const double _sweepWindowFactor = 0.85;

  Duration _tailTrimmedEnd(Duration start, Duration lineEnd) {
    final remainingMs = (lineEnd - start).inMilliseconds;
    if (remainingMs <= 0) return start + const Duration(seconds: 4);
    return start +
        Duration(milliseconds: (remainingMs * _sweepWindowFactor).round());
  }

  List<LyricsWord>? _extractWords(String body, int offsetMs) {
    final times = <Duration>[];
    final starts = <int>[];
    final ends = <int>[];

    for (final match in _wordTimestampPattern.allMatches(body)) {
      final parsed = _parseTimestamp(match.group(1) ?? '');
      if (parsed == null) continue;
      final adjustedMs = parsed.inMilliseconds + offsetMs;
      times.add(Duration(milliseconds: adjustedMs < 0 ? 0 : adjustedMs));
      starts.add(match.start);
      ends.add(match.end);
    }
    if (times.isEmpty) return null;

    final words = <LyricsWord>[];
    for (var i = 0; i < times.length; i++) {
      final segStart = i == 0 ? 0 : ends[i];
      final segEnd = i + 1 < times.length ? starts[i + 1] : body.length;
      final segment = body
          .substring(segStart, segEnd)
          .replaceAll(_wordTimestampPattern, '');
      if (segment.isEmpty && i > 0) continue;
      var explicitEnd = times[i];
      if (i + 1 < times.length && times[i + 1] > times[i]) {
        final afterNext = i + 2 < times.length ? starts[i + 2] : body.length;
        // Consecutive markers with no sung text between them encode a word
        // end followed by a vocal gap. Keep ordinary start-only ELRC's existing
        // playback completion policy, while retaining explicitly saved gaps.
        if (body.substring(ends[i + 1], afterNext).trim().isEmpty) {
          explicitEnd = times[i + 1];
        }
      }
      words.add(LyricsWord(start: times[i], end: explicitEnd, text: segment));
    }
    return words.isEmpty ? null : words;
  }

  LyricsData parseLyricsText(String raw, {String? source}) {
    return _parseLyrics(raw, source: source);
  }

  Duration? parseTimestamp(String timestamp) {
    return _parseTimestamp(timestamp);
  }

  String _formatClock(Duration duration) {
    final totalMinutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    final centiseconds = (duration.inMilliseconds.remainder(1000) ~/ 10);
    return '${totalMinutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${centiseconds.toString().padLeft(2, '0')}';
  }

  String formatTimestamp(Duration duration) {
    return '[${_formatClock(duration)}]';
  }

  String formatLengthTag(Duration duration) {
    return '[length:${_formatClock(duration)}]';
  }

  String buildLrcContent({
    required List<LyricsLine> lines,
    Song? song,
    Duration? length,
  }) {
    final buffer = StringBuffer();
    if (song?.title case final title? when title.trim().isNotEmpty) {
      buffer.writeln('[ti:${title.trim()}]');
    }
    if (song?.artist case final artist? when artist.trim().isNotEmpty) {
      buffer.writeln('[ar:${artist.trim()}]');
    }
    if (song?.album case final album? when album.trim().isNotEmpty) {
      buffer.writeln('[al:${album.trim()}]');
    }
    if (length != null) {
      buffer.writeln(formatLengthTag(length));
    }
    if (buffer.isNotEmpty) {
      buffer.writeln();
    }

    final timestampCounts = <int, int>{};
    for (final line in lines) {
      final time = line.timestamp.inMilliseconds;
      timestampCounts[time] = (timestampCounts[time] ?? 0) + 1;
    }
    var untaggedTranslations = 0;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final words = line.words;
      if (words != null && words.isNotEmpty) {
        final enhanced = words
            .map((w) => '<${_formatClock(w.start)}>${w.text}')
            .join();
        buffer.writeln('${formatTimestamp(line.timestamp)}$enhanced');
      } else {
        buffer.writeln('${formatTimestamp(line.timestamp)}${line.text}');
      }
      // Portable bilingual LRC pairs share a timestamp in other players too.
      if (line.translation case final translation?
          when translation.trim().isNotEmpty && translation.trim() != line.text.trim()) {
        if ((timestampCounts[line.timestamp.inMilliseconds] ?? 0) > 1) {
          buffer.writeln('[lokaltr:${index + untaggedTranslations}]');
        } else {
          untaggedTranslations++;
        }
        buffer.writeln('${formatTimestamp(line.timestamp)}${translation.trim()}');
      }
    }
    return buffer.toString().trimRight();
  }

  String? suggestSidecarLrcPath(Song song) {
    final filePath = song.filePath;
    if (filePath == null || filePath.isEmpty) return null;
    final localPath = _resolveLocalPath(filePath);
    if (localPath == null || localPath.isEmpty) return null;

    final audioFile = File(localPath);
    final parent = audioFile.parent;
    final stem = _basenameWithoutExtension(audioFile.path);
    return '${parent.path}${Platform.pathSeparator}$stem.lrc';
  }

  Future<_LoadedLyrics?> _loadEmbeddedLyricsText(String filePath) async {
    try {
      final result = await _storageChannel.invokeMapMethod<String, dynamic>(
        'readEmbeddedLyrics',
        {'audioUri': filePath},
      );
      final content = result?['content'] as String?;
      if (content != null && content.trim().isNotEmpty) {
        return _LoadedLyrics(
          content: content,
          source: result?['source'] as String? ?? 'embedded',
        );
      }
    } catch (_) {
      // Best-effort lookup. Fall back to sidecar lookup.
    }
    return null;
  }

  Future<_LoadedLyrics?> _loadLyricsFromAbsolutePath(
    String absolutePath,
  ) async {
    final file = File(absolutePath);
    if (!await file.exists()) return null;
    final content = await _readTextFile(file);
    if (content == null || content.trim().isEmpty) return null;
    return _LoadedLyrics(content: content, source: file.path);
  }

  Future<_LoadedLyrics?> _loadLyricsText(String filePath) async {
    final parsedUri = Uri.tryParse(filePath);
    final isAndroidContentUri =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        parsedUri?.scheme == 'content';

    if (isAndroidContentUri) {
      try {
        final result = await _storageChannel.invokeMapMethod<String, dynamic>(
          'readSiblingLyrics',
          {'audioUri': filePath},
        );
        final content = result?['content'] as String?;
        if (content != null && content.trim().isNotEmpty) {
          return _LoadedLyrics(
            content: content,
            source: result?['name'] as String? ?? result?['uri'] as String?,
          );
        }
      } catch (_) {
        // Best-effort only. Fall back to local path resolution.
      }
    }

    final localPath = _resolveLocalPath(filePath);
    if (localPath == null || localPath.isEmpty) return null;

    final audioFile = File(localPath);
    final parent = audioFile.parent;
    final stem = _basenameWithoutExtension(audioFile.path);
    final sep = Platform.pathSeparator;

    final candidates = <String>[
      '${parent.path}$sep$stem.ttml',
      '${parent.path}$sep$stem.elrc',
      '${parent.path}$sep$stem.lrc',
      '${parent.path}$sep$stem.txt',
      '${parent.path}$sep$stem.xml',
      '${parent.path}$sep$stem.LRC',
      '${parent.path}$sep$stem.TXT',
      '${parent.path}$sep$stem.XML',
    ];

    for (final candidatePath in candidates) {
      final file = File(candidatePath);
      if (!await file.exists()) continue;

      final content = await _readTextFile(file);
      if (content != null && content.trim().isNotEmpty) {
        return _LoadedLyrics(content: content, source: file.path);
      }
    }

    return null;
  }

  String? _resolveLocalPath(String filePath) {
    if (RegExp(r'^[a-zA-Z]:\\').hasMatch(filePath)) {
      return filePath;
    }

    final parsed = Uri.tryParse(filePath);
    if (parsed != null && parsed.scheme == 'file') {
      return parsed.toFilePath();
    }

    if (parsed != null && parsed.scheme.isNotEmpty) {
      return null;
    }

    return filePath;
  }

  String _basenameWithoutExtension(String path) {
    final normalized = path.replaceAll('\\', '/');
    final filename = normalized.split('/').last;
    final dotIndex = filename.lastIndexOf('.');
    if (dotIndex <= 0) return filename;
    return filename.substring(0, dotIndex);
  }

  Future<String?> _readTextFile(File file) async {
    try {
      return await file.readAsString();
    } catch (_) {
      try {
        return await file.readAsString(encoding: latin1);
      } catch (_) {
        return null;
      }
    }
  }

  LyricsData _parseLyrics(String raw, {String? source}) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('<?xml') || trimmed.startsWith('<')) {
      final xmlData = _parseXmlLyrics(trimmed, source: source);
      if (xmlData != null) return xmlData;
    }

    final normalized = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceFirst(RegExp(r'^\uFEFF'), '');
    final rows = normalized.split('\n');

    final timestampPattern = RegExp(
      r'\[(\d{1,2}:\d{2}(?::\d{2})?(?:\.\d{1,3})?)\]',
    );
    final offsetPattern = RegExp(
      r'^\s*\[offset:([+-]?\d+)\]\s*$',
      caseSensitive: false,
    );
    final metadataPattern = RegExp(r'^\s*\[[a-zA-Z]+:.*\]\s*$');

    var offsetMs = 0;
    var hasTimestamps = false;
    final parsedLines = <LyricsLine>[];
    // Unstamped rows, kept apart: in a synced file one right under a stamped
    // line is that line's translation; the rest are notes and credits.
    final plainLines = <LyricsLine>[];
    final translations = <(List<int>, String)>[];
    // An optional association tag identifies known translated rows in
    // simultaneous vocals and enhanced bilingual exports. Untagged enhanced
    // rows retain their independent vocal identities.
    final taggedTranslation = RegExp(r'^\[lokaltr:(\d+)\]$');
    int? taggedSourceIndex;
    var previous = <int>[]; // indexes the last stamped row made

    for (final row in rows) {
      final line = row.trimRight();
      if (line.trim().isEmpty) {
        previous = [];
        continue;
      }

      final offsetMatch = offsetPattern.firstMatch(line);
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1) ?? '') ?? offsetMs;
        continue;
      }

      final marker = taggedTranslation.firstMatch(line.trim());
      if (marker != null) {
        taggedSourceIndex = int.tryParse(marker.group(1)!);
        previous = [];
        continue;
      }

      final matches = timestampPattern.allMatches(line).toList();
      if (matches.isNotEmpty) {
        hasTimestamps = true;
        final body = line.replaceAll(timestampPattern, '');
        final words = _extractWords(body, offsetMs);
        final lyricText = body.replaceAll(_wordTimestampPattern, '').trim();
        previous = [];
        final target = taggedSourceIndex;
        taggedSourceIndex = null;
        if (target != null &&
            target >= 0 &&
            target < parsedLines.length &&
            matches.length == 1 &&
            lyricText.isNotEmpty &&
            parsedLines[target].translation == null) {
          final time = _parseTimestamp(matches.single.group(1) ?? '');
          if (time != null &&
              parsedLines[target].timestamp.inMilliseconds ==
                  (time.inMilliseconds + offsetMs).clamp(0, 1 << 62)) {
            parsedLines[target] =
                parsedLines[target].withTranslation(lyricText);
            continue;
          }
        }
        for (final match in matches) {
          final parsedTime = _parseTimestamp(match.group(1) ?? '');
          if (parsedTime == null) continue;

          final adjustedMs = parsedTime.inMilliseconds + offsetMs;
          final clamped = Duration(
            milliseconds: adjustedMs < 0 ? 0 : adjustedMs,
          );
          if (lyricText.isEmpty) continue;
          previous.add(parsedLines.length);
          parsedLines.add(
            LyricsLine(timestamp: clamped, text: lyricText, words: words),
          );
        }
        continue;
      }

      if (metadataPattern.hasMatch(line)) {
        previous = [];
        continue;
      }

      final text = line.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (previous.isNotEmpty) translations.add((previous, text));
      previous = [];
      plainLines.add(LyricsLine(timestamp: Duration.zero, text: line.trim()));
    }

    if (hasTimestamps) {
      // A stray note isn't a translation: a translated file has one under at
      // least half its sung lines.
      final sung = parsedLines.map((line) => line.timestamp).toSet().length;
      if (translations.isNotEmpty && translations.length >= sung / 2) {
        for (final (indexes, text) in translations) {
          for (final index in indexes) {
            parsedLines[index] = parsedLines[index].withTranslation(text);
          }
        }
      }
      // Bilingual LRC commonly repeats the original timestamp for its
      // translation. Fold adjacent pairs before sorting so original/subline
      // ordering survives; leave simultaneous word-timed or 3+ vocal parts
      // separate. Unstamped translations above remain supported.
      final bilingualLines = <LyricsLine>[];
      for (var i = 0; i < parsedLines.length;) {
        var end = i + 1;
        while (end < parsedLines.length &&
            parsedLines[end].timestamp == parsedLines[i].timestamp) {
          end++;
        }
        if (end == i + 2 &&
            parsedLines[i].translation == null &&
            parsedLines[i + 1].translation == null &&
            parsedLines[i + 1].words == null &&
            parsedLines[i].text.trim() != parsedLines[i + 1].text.trim()) {
          bilingualLines.add(
            parsedLines[i].withTranslation(parsedLines[i + 1].text),
          );
        } else {
          bilingualLines.addAll(parsedLines.getRange(i, end));
        }
        i = end;
      }
      bilingualLines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return LyricsData(
        lines: bilingualLines,
        isSynchronized: true,
        source: source,
        rawContent: raw,
      );
    }

    return LyricsData(
      lines: plainLines.where((line) => line.text.isNotEmpty).toList(),
      isSynchronized: false,
      source: source,
      rawContent: raw,
    );
  }

  LyricsData? _parseXmlLyrics(String xml, {String? source}) {
    try {
      final document = XmlDocument.parse(xml);
      Duration? time(String? value) {
        if (value == null) return null;
        if (value.endsWith('ms'))
          return Duration(
            microseconds:
                ((double.tryParse(value.substring(0, value.length - 2)) ?? 0) *
                        1000)
                    .round(),
          );
        if (value.endsWith('s'))
          return Duration(
            microseconds:
                ((double.tryParse(value.substring(0, value.length - 1)) ?? 0) *
                        1000000)
                    .round(),
          );
        final parts = value.split(':');
        if (parts.isEmpty) return null;
        var seconds = 0.0;
        for (final part in parts) {
          final number = double.tryParse(part);
          if (number == null) return null;
          seconds = seconds * 60 + number;
        }
        return Duration(microseconds: (seconds * 1000000).round());
      }

      final paragraphs = document.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'p',
      );
      final lines = <LyricsLine>[];
      final plain = <LyricsLine>[];
      for (final paragraph in paragraphs) {
        final start = time(paragraph.getAttribute('begin'));
        final text = paragraph.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isEmpty) continue;
        if (start == null) {
          plain.add(LyricsLine(timestamp: Duration.zero, text: text));
          continue;
        }
        final words = <LyricsWord>[];
        for (final span in paragraph.descendants.whereType<XmlElement>().where(
          (e) => e.name.local == 'span',
        )) {
          final begin = time(span.getAttribute('begin')),
              end = time(span.getAttribute('end'));
          if (begin == null ||
              end == null ||
              end < begin ||
              span.innerText.trim().isEmpty)
            continue;
          if (span.descendants.whereType<XmlElement>().any(
            (child) => child.getAttribute('begin') != null,
          ))
            continue;
          final tail = span.nextSibling;
          final separator = tail is XmlText && tail.value.trim().isEmpty
              ? tail.value
              : '';
          words.add(
            LyricsWord(
              start: begin,
              end: end,
              text: span.innerText + separator,
            ),
          );
        }
        lines.add(
          LyricsLine(
            timestamp: start,
            text: text,
            words: words.isEmpty ? null : words,
          ),
        );
      }
      if (lines.isNotEmpty || plain.isNotEmpty) {
        final timed = lines.isNotEmpty;
        if (!timed) lines.addAll(plain);
        lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return LyricsData(
          lines: lines,
          isSynchronized: timed,
          source: source,
          rawContent: xml,
          language: document.rootElement.attributes
              .where((a) => a.name.local == 'lang')
              .firstOrNull
              ?.value,
        );
      }
    } catch (_) {
      /* Try the legacy XML formats below. */
    }
    try {
      final linePattern = RegExp(
        r'<line\s+start="(\d+)"\s*>([^<]*)</line>',
        caseSensitive: false,
      );
      final altPattern = RegExp(
        r'<line\s+start="(\d{1,2}):(\d{2})\.(\d{2})"\s*>([^<]*)</line>',
        caseSensitive: false,
      );

      final lines = <LyricsLine>[];
      var hasTimestamps = false;

      for (final match in linePattern.allMatches(xml)) {
        hasTimestamps = true;
        final ms = int.tryParse(match.group(1) ?? '') ?? 0;
        final text = match.group(2)?.trim() ?? '';
        if (text.isNotEmpty) {
          lines.add(
            LyricsLine(
              timestamp: Duration(milliseconds: ms),
              text: text,
            ),
          );
        }
      }

      if (lines.isEmpty) {
        for (final match in altPattern.allMatches(xml)) {
          hasTimestamps = true;
          final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
          final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
          final centis = int.tryParse(match.group(3) ?? '0') ?? 0;
          final ms = (minutes * 60 + seconds) * 1000 + centis * 10;
          final text = match.group(4)?.trim() ?? '';
          if (text.isNotEmpty) {
            lines.add(
              LyricsLine(
                timestamp: Duration(milliseconds: ms),
                text: text,
              ),
            );
          }
        }
      }

      if (lines.isNotEmpty) {
        lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return LyricsData(
          lines: lines,
          isSynchronized: hasTimestamps,
          source: source,
          rawContent: xml,
        );
      }
    } catch (_) {
      // Fall through to plain-text parser
    }
    return null;
  }

  Duration? _parseTimestamp(String timestamp) {
    final trimmed = timestamp.trim();

    var match = RegExp(r'^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?$')
        .firstMatch(trimmed);
    if (match != null) {
      final hours = int.tryParse(match.group(1) ?? '') ?? 0;
      final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
      final seconds = int.tryParse(match.group(3) ?? '') ?? 0;
      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: _parseFraction(match.group(4)),
      );
    }

    match = RegExp(r'^(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?$').firstMatch(trimmed);
    if (match == null) return null;

    final minutes = int.tryParse(match.group(1) ?? '');
    final seconds = int.tryParse(match.group(2) ?? '');
    if (minutes == null || seconds == null) return null;

    return Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: _parseFraction(match.group(3)),
    );
  }

  int _parseFraction(String? fractionRaw) {
    if (fractionRaw == null || fractionRaw.isEmpty) return 0;
    if (fractionRaw.length == 1) return int.parse(fractionRaw) * 100;
    if (fractionRaw.length == 2) return int.parse(fractionRaw) * 10;
    return int.parse(fractionRaw.substring(0, 3));
  }

  Future<void> _setManualLyricsPath(Song song, String? manualPath) async {
    final filePath = song.filePath;
    if (filePath == null || filePath.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final existingRaw = prefs.getString(_manualLyricsOverridesKey);
    final map = <String, String>{};
    if (existingRaw != null && existingRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(existingRaw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is String) {
              map[entry.key as String] = entry.value as String;
            }
          }
        }
      } catch (_) {
        // Reset malformed preferences payload.
      }
    }

    if (manualPath == null || manualPath.isEmpty) {
      map.remove(filePath);
    } else {
      map[filePath] = manualPath;
    }

    if (map.isEmpty) {
      await prefs.remove(_manualLyricsOverridesKey);
    } else {
      await prefs.setString(_manualLyricsOverridesKey, jsonEncode(map));
    }
    _cache.remove(filePath);
    // This runs for imported, saved, replaced and cleared manual/sidecar
    // lyrics. Invalidate search and all LyricsService instance caches.
    contentRevision.value++;
  }

  Future<String> _writeManagedLyricsCopy({
    required Song song,
    required String extension,
    required String content,
  }) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final lyricsDirectory = Directory(
      '${documentsDirectory.path}${Platform.pathSeparator}$_managedLyricsDirectoryName',
    );
    await lyricsDirectory.create(recursive: true);

    final prefs = await SharedPreferences.getInstance();
    final matchAudioFilename =
        prefs.getBool('lyrics_match_audio_filename') ?? false;

    final String safeStem;
    if (matchAudioFilename) {
      final filePath = song.filePath;
      if (filePath != null && filePath.isNotEmpty) {
        final localPath = _resolveLocalPath(filePath);
        if (localPath != null && localPath.isNotEmpty) {
          safeStem = _basenameWithoutExtension(localPath);
        } else {
          safeStem = _safeLyricsStem(song);
        }
      } else {
        safeStem = _safeLyricsStem(song);
      }
    } else {
      safeStem = _safeLyricsStem(song);
    }

    final file = File(
      '${lyricsDirectory.path}${Platform.pathSeparator}$safeStem.$extension',
    );
    await file.writeAsString(content);
    return file.path;
  }

  String _preferredLyricsExtension(String fileName) {
    final normalized = fileName.toLowerCase();
    if (normalized.endsWith('.txt')) return 'txt';
    if (normalized.endsWith('.xml')) return 'xml';
    return 'lrc';
  }

  String _safeLyricsStem(Song song) {
    final parts = [
      if (song.artist.trim().isNotEmpty) song.artist.trim(),
      if (song.title.trim().isNotEmpty) song.title.trim(),
      song.id,
    ];
    final stem = parts.join('_');
    return stem.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
  }
}

class _LoadedLyrics {
  final String content;
  final String? source;

  const _LoadedLyrics({required this.content, this.source});
}
