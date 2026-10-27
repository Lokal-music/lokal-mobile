import 'package:flick/services/lyrics_service.dart';

/// One fragment of a translated or romanized line is confined to one actual
/// original vocal window. Splitting at boundaries preserves silent gaps and
/// never asserts that a translation has its own measured phoneme alignment.
LyricsLine projectLyricsSubline(LyricsLine source, String text) {
  final original = source.words;
  if (text.trim().isEmpty || original == null || original.isEmpty) {
    return LyricsLine(timestamp: source.timestamp, text: text);
  }

  final units = original.where((word) =>
      word.text.trim().isNotEmpty && word.end >= word.start).toList();
  final totalSource = units.fold<int>(0, (sum, word) => sum + word.text.runes.length);
  if (totalSource == 0) {
    return LyricsLine(timestamp: source.timestamp, text: text);
  }

  final spans = <({LyricsWord word, int start, int end, int length})>[];
  var sourceOffset = 0;
  for (final word in units) {
    final length = word.text.runes.length;
    spans.add((word: word, start: sourceOffset,
        end: sourceOffset + length, length: length));
    sourceOffset += length;
  }

  final display = text.trim();
  // Latin words remain unbroken visually; whitespace-free CJK/romaji
  // characters are each their own segment.
  final tokens = RegExp(r'\s').hasMatch(display)
      ? RegExp(r'\S+').allMatches(display).map((m) => m.group(0)!).toList()
      : display.runes.map(String.fromCharCode).toList();
  final totalTarget = tokens.fold<int>(0, (sum, token) => sum + token.runes.length);
  if (totalTarget == 0) {
    return LyricsLine(timestamp: source.timestamp, text: display);
  }

  Duration timestampAt(({LyricsWord word, int start, int end, int length}) span,
      int index) {
    final position = (index * totalSource / totalTarget).clamp(
        span.start.toDouble(), span.end.toDouble());
    final fraction = (position - span.start) / span.length;
    return span.word.start + Duration(
      microseconds: ((span.word.end - span.word.start).inMicroseconds *
          fraction).round(),
    );
  }

  final words = <LyricsWord>[];
  var offset = 0;
  var spanIndex = 0;
  for (final token in tokens) {
    var fragment = '';
    var fragmentStart = 0;
    var fragmentSpan = -1;

    void emit(int end) {
      if (fragment.isEmpty) return;
      final span = spans[fragmentSpan];
      final start = timestampAt(span, fragmentStart);
      final finish = timestampAt(span, end);
      words.add(LyricsWord(
        start: start,
        end: finish < start ? start : finish,
        text: fragment,
      ));
      fragment = '';
    }

    for (final char in token.runes.map(String.fromCharCode)) {
      final middle = (offset + .5) / totalTarget * totalSource;
      while (spanIndex < spans.length - 1 &&
          middle >= spans[spanIndex].end) {
        spanIndex++;
      }
      if (fragment.isNotEmpty && fragmentSpan != spanIndex) emit(offset);
      if (fragment.isEmpty) {
        fragmentStart = offset;
        fragmentSpan = spanIndex;
      }
      fragment += char;
      offset++;
    }
    emit(offset);
  }

  return LyricsLine(
    timestamp: source.timestamp,
    text: display,
    words: words,
  );
}
