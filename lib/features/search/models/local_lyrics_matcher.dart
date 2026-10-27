import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Unicode-aware matching for the *local* lyrics search in Library.
/// Preserve Indic vowel signs and emoji bases (symbols), while folding common
/// full-width punctuation/Latin forms and canonical Unicode equivalents.
final _lyricNonWord = RegExp(r'[^\p{L}\p{M}\p{N}\p{S}]+', unicode: true);
final _lyricWhitespace = RegExp(r'\s+');
final _lyricSearchable = RegExp(r'[\p{L}\p{N}\p{S}]', unicode: true);

bool _isCjkRune(int rune) =>
    (rune >= 0x3400 && rune <= 0x4dbf) || // CJK Extension A
    (rune >= 0x4e00 && rune <= 0x9fff) || // CJK Unified
    (rune >= 0xf900 && rune <= 0xfaff) || // Compatibility ideographs
    (rune >= 0x20000 && rune <= 0x323af) || // Supplementary ideographs
    (rune >= 0x3040 && rune <= 0x30ff) || // Hiragana / Katakana
    (rune >= 0x31f0 && rune <= 0x31ff) || // Katakana extensions
    (rune >= 0xac00 && rune <= 0xd7af); // Hangul syllables

/// Treat separators *between* CJK characters as optional, but not separators
/// in Latin/Indic text or between a CJK character and a different script.
String _joinCjkPhrase(String value) {
  final runes = value.runes.toList(growable: false);
  final result = StringBuffer();
  for (var i = 0; i < runes.length; i++) {
    if (runes[i] == 0x20 &&
        i > 0 &&
        i + 1 < runes.length &&
        _isCjkRune(runes[i - 1]) &&
        _isCjkRune(runes[i + 1])) {
      continue;
    }
    result.writeCharCode(runes[i]);
  }
  return result.toString();
}

String normalizeLocalLyricSearch(String value) {
  final out = StringBuffer();
  for (var rune in value.runes) {
    if (rune >= 0xff01 && rune <= 0xff5e) rune -= 0xfee0;
    if (rune == 0x3000) rune = 0x20;
    out.writeCharCode(rune);
  }
  // NFC makes precomposed and combining-mark spellings identical without
  // deleting the marks required by Devanagari, Gurmukhi and Japanese.
  return unorm.nfc(out.toString().toLowerCase())
      .replaceAll(_lyricNonWord, ' ')
      .replaceAll(_lyricWhitespace, ' ')
      .trim();
}

/// Match local lyric phrases without spurious matches on variation selectors.
bool matchesLocalLyricLine(String line, String query) {
  final needle = normalizeLocalLyricSearch(query);
  if (!_lyricSearchable.hasMatch(needle)) return false;
  final haystack = normalizeLocalLyricSearch(line);
  return haystack.contains(needle) ||
      _joinCjkPhrase(haystack).contains(_joinCjkPhrase(needle));
}
