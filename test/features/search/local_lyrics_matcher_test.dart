import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/search/models/local_lyrics_matcher.dart';

void main() {
  test('Chinese and Japanese lyric phrases match directly', () {
    expect(matchesLocalLyricLine('夜空中最亮的星', '最亮'), isTrue);
    expect(matchesLocalLyricLine('君の心には光がある', '心に'), isTrue);
    expect(matchesLocalLyricLine('東京の夜', '東京'), isTrue);
    expect(matchesLocalLyricLine('東京の夜', '大阪'), isFalse);
  });

  test('Hindi matras and Punjabi vowel signs stay searchable', () {
    expect(matchesLocalLyricLine('दिल से दिल तक', 'दिल'), isTrue);
    expect(matchesLocalLyricLine('ਦਿਲ ਦੀ ਗੱਲ', 'ਦਿਲ'), isTrue);
    expect(matchesLocalLyricLine('ਮੈਂ ਪੰਜਾਬੀ ਹਾਂ', 'ਪੰਜਾਬੀ'), isTrue);
    expect(matchesLocalLyricLine('दिल से दिल तक', 'दुल'), isFalse);
    expect(matchesLocalLyricLine('ਦਿਲ ਦੀ ਗੱਲ', 'ਦੁਲ'), isFalse);
  });

  test('punctuation and full-width forms normalize without transliteration', () {
    expect(normalizeLocalLyricSearch('ＡＢＣ， 日本　語'), 'abc 日本 語');
    expect(matchesLocalLyricLine('Love, is all you need', 'LOVE is'), isTrue);
    expect(matchesLocalLyricLine('夜空、の 星', '夜空 の'), isTrue);
    expect(matchesLocalLyricLine('दुनिया！ सुंदर', 'दुनिया सुंदर'), isTrue);
    expect(matchesLocalLyricLine('ਕਿ-ਹਾਲ', 'ਕਿ ਹਾਲ'), isTrue);
    expect(matchesLocalLyricLine('abc', '!!!'), isFalse);
  });

  test('variation selectors never make unrelated emoji match', () {
    expect(matchesLocalLyricLine('☀️', '❤️'), isFalse);
    expect(matchesLocalLyricLine('sun ☀️', '❤️'), isFalse);
    expect(matchesLocalLyricLine('sun ☀️', '☀️'), isTrue);
    expect(matchesLocalLyricLine('I ❤️ you', '❤'), isTrue);
    expect(matchesLocalLyricLine('☀️', '\uFE0F'), isFalse);
  });

  test('NFC handles composed and decomposed Japanese/Latin', () {
    expect(matchesLocalLyricLine('がく', 'か\u3099く'), isTrue);
    expect(matchesLocalLyricLine('か\u3099く', 'がく'), isTrue);
    expect(matchesLocalLyricLine('café au lait', 'cafe\u0301'), isTrue);
    expect(matchesLocalLyricLine('किताब', 'कताब'), isFalse);
  });

  test('CJK phrases cross punctuation and optional spaces only', () {
    expect(matchesLocalLyricLine('夜空、の星', '夜空の星'), isTrue);
    expect(matchesLocalLyricLine('夜 空 の 星', '夜空の星'), isTrue);
    expect(matchesLocalLyricLine('夜空の星', '夜空 の 星'), isTrue);
    expect(matchesLocalLyricLine('love, is', 'loveis'), isFalse);
    expect(matchesLocalLyricLine('दिल से दिल', 'दिलसेदिल'), isFalse);
  });

  test('unrelated lyric lines are never returned', () {
    expect(matchesLocalLyricLine('पुराने दिन', 'नया शहर'), isFalse);
    expect(matchesLocalLyricLine('ਗੱਲ ਕਰ', 'किताब'), isFalse);
    expect(matchesLocalLyricLine('', 'दिल'), isFalse);
    expect(matchesLocalLyricLine('दिल', ''), isFalse);
  });
}
