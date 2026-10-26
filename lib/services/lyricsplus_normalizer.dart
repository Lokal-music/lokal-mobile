/// Converts LyricsPlus v2's millisecond-based lyric lines to enhanced LRC.
///
/// Provider responses can contain unsorted rows, invalid times, background-only
/// syllabus entries, or timelines from a different recording. Reject an
/// implausible timeline instead of letting its last verse appear at song start.
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
  if (entries.isEmpty || invalid > entries.length ~/ 4) return null;
  entries.sort((a, b) => a.time.compareTo(b.time));

  // A purported full-song lyric transcript whose *first* line is in the
  // final portion of a normal-length track is not usable for following it.
  // Reject it, leaving the auto selector free to use another provider.
  if (durationMs >= 60000 &&
      entries.first.time > durationMs * 0.75) return null;

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
