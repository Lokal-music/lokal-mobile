/// Converts LyricsPlus v2's millisecond-based lyric lines to enhanced LRC.
///
/// Provider responses can contain unsorted rows, invalid times, background-only
/// syllabus entries, or timelines from a different recording. When the words
/// are usable but the timestamps are not, return unsynchronized plain text
/// rather than pretending that the last verse starts at the opening.
String? normalizeLyricsPlusV2(
  Object? payload, {
  required Duration duration,
}) {
  if (payload is! Map) return null;
  final raw = payload['lyrics'];
  if (raw is! List || raw.isEmpty) return null;

  final durationMs = duration.inMilliseconds;
  final entries = <({int time, String text, List<({int time, String text})> words})>[];
  var invalid = 0;
  for (final item in raw) {
    if (item is! Map || item['time'] is! num) continue;
    final value = (item['time'] as num).toDouble();
    if (!value.isFinite) { invalid++; continue; }
    final time = value.round();
    // Allow a short postlude/metadata difference, but not an unrelated
    // recording whose lyric timeline begins beyond the song's end.
    if (time < 0 || (durationMs > 0 && time > durationMs + 5000)) {
      invalid++;
      continue;
    }
    final fallback = (item['text'] ?? '').toString().trim();
    final words = <({int time, String text})>[];
    final syllables = item['syllabus'];
    if (syllables is List && syllables.isNotEmpty) {
      for (final syllable in syllables) {
        if (syllable is! Map || syllable['isBackground'] == true ||
            syllable['time'] is! num) continue;
        final wordTime = (syllable['time'] as num).toDouble();
        if (!wordTime.isFinite) continue;
        final timestamp = wordTime.round();
        if (timestamp < time - 500 ||
            (durationMs > 0 && timestamp > durationMs + 5000)) continue;
        final text = (syllable['text'] ?? '').toString();
        if (text.trim().isNotEmpty) words.add((time: timestamp, text: text));
      }
    }
    words.sort((a, b) => a.time.compareTo(b.time));
    final text = words.isNotEmpty
        ? words.map((word) => word.text).join('').trim()
        : fallback;
    if (text.isEmpty) continue;
    entries.add((time: time, text: text, words: words));
  }
  if (entries.isEmpty) return null;
  // A malformed timed answer can still contain correct words (as for plain
  // LyricsPlus results). Render those words, never fake word-by-word timing.
  String plain() => entries.map((entry) => entry.text)
      .where((text) => text.isNotEmpty).join('\n');
  if (invalid > entries.length ~/ 4) return plain();
  entries.sort((a, b) => a.time.compareTo(b.time));

  // Many identical timestamps mean this is not usable synchronized lyrics:
  // the binary-search player would immediately jump to the final duplicate.
  if (entries.length >= 3) {
    final occurrences = <int, int>{};
    for (final entry in entries) {
      occurrences[entry.time] = (occurrences[entry.time] ?? 0) + 1;
    }
    final largest = occurrences.values.fold<int>(
      0, (maximum, count) => count > maximum ? count : maximum,
    );
    if (largest > entries.length / 2) return plain();
  }

  // A purported full-song lyric transcript whose *first* line is in the
  // final portion of a normal-length track is not usable for following it.
  // Reject it, leaving the auto selector free to use another provider.
  if (durationMs >= 60000 &&
      entries.first.time > durationMs * 0.75) return plain();

  String stamp(int ms) =>
      '${(ms ~/ 60000).toString().padLeft(2, '0')}:'
      '${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}.'
      '${(ms % 1000).toString().padLeft(3, '0')}';

  final output = StringBuffer();
  for (final entry in entries) {
    output.write('[${stamp(entry.time)}]');
    if (entry.words.isNotEmpty) {
      for (final word in entry.words) {
        output.write('<${stamp(word.time)}>${word.text}');
      }
    } else {
      output.write(entry.text);
    }
    output.writeln();
  }
  return output.isEmpty ? null : output.toString();
}
