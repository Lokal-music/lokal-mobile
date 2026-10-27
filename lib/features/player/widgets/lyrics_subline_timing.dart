import 'package:flick/services/lyrics_service.dart';

/// Give a translated/romanized display line the source vocal's non-uniform
/// syllable timing. This is only a visual projection: no translated word
/// alignment is claimed or written back to the source lyrics.
LyricsLine projectLyricsSubline(LyricsLine source, String text) {
  final original = source.words;
  if (text.trim().isEmpty || original == null || original.isEmpty) {
    return LyricsLine(timestamp: source.timestamp, text: text);
  }
  final units = original.where((word) =>
      word.text.trim().isNotEmpty && word.end >= word.start).toList();
  final total = units.fold<int>(0, (sum, word) => sum + word.text.runes.length);
  if (total == 0) {
    return LyricsLine(timestamp: source.timestamp, text: text);
  }

  Duration at(double fraction) {
    var remaining = fraction.clamp(0.0, 1.0) * total;
    for (final unit in units) {
      final length = unit.text.runes.length;
      if (remaining <= length) {
        final us = unit.start.inMicroseconds +
            ((unit.end - unit.start).inMicroseconds * remaining / length).round();
        return Duration(microseconds: us);
      }
      remaining -= length;
    }
    return units.last.end;
  }

  final display = text.trim();
  // Keep whitespace-delimited words together. For CJK with no word breaks,
  // reveal Unicode characters independently rather than lighting one huge word.
  final tokens = RegExp(r'\s').hasMatch(display)
      ? RegExp(r'\S+').allMatches(display).map((m) => m.group(0)!).toList()
      : display.runes.map(String.fromCharCode).toList();
  final targetCount = tokens.fold<int>(0, (sum, token) => sum + token.runes.length);
  if (targetCount == 0) {
    return LyricsLine(timestamp: source.timestamp, text: display);
  }

  var offset = 0;
  final words = <LyricsWord>[];
  for (final token in tokens) {
    final start = at(offset / targetCount);
    offset += token.runes.length;
    final end = at(offset / targetCount);
    words.add(LyricsWord(
      start: start,
      end: end < start ? start : end,
      text: token,
    ));
  }
  return LyricsLine(
    timestamp: source.timestamp,
    text: display,
    words: words,
  );
}
