/// Unicode-aware matching for the *local* lyrics search in Library.
///
/// Dart has no built-in NFKC API. Fold the common full-width Latin/number
/// forms without transliterating Chinese, Japanese or Indic characters.
/// Preserve combining marks: Hindi matras and Punjabi vowel signs carry
/// meaning and must not be stripped by ASCII-only "word" cleaners.
final _lyricNonWord = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);
final _lyricWhitespace = RegExp(r'\s+');

String normalizeLocalLyricSearch(String value) {
  final out = StringBuffer();
  for (var rune in value.runes) {
    if (rune >= 0xff01 && rune <= 0xff5e) rune -= 0xfee0;
    if (rune == 0x3000) rune = 0x20;
    out.writeCharCode(rune);
  }
  return out.toString()
      .toLowerCase()
      .replaceAll(_lyricNonWord, ' ')
      .replaceAll(_lyricWhitespace, ' ')
      .trim();
}

/// Compare lyric content and a user query by normalized phrase, not an
/// ASCII-only tokenization or the raw input's punctuation/width.
bool matchesLocalLyricLine(String line, String query) {
  final needle = normalizeLocalLyricSearch(query);
  return needle.isNotEmpty &&
      normalizeLocalLyricSearch(line).contains(needle);
}
