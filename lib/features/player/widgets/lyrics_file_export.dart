import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flick/models/song.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/services/lyrics_service.dart';

import 'lyrics_subline_timing.dart';

/// Portable lyrics export, independent from the library storage path.
class LyricsFileExport {
  const LyricsFileExport({
    required this.fileName,
    required this.extension,
    required this.mimeType,
    required this.content,
  });

  final String fileName;
  final String extension;
  final String mimeType;
  final String content;

  Uint8List get bytes => Uint8List.fromList(utf8.encode(content));
}

String _safeFilePart(String text) {
  final cleaned = text
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  final result = StringBuffer();
  var bytes = 0;
  for (final rune in cleaned.runes.take(64)) {
    final character = String.fromCharCode(rune);
    final length = utf8.encode(character).length;
    if (bytes + length > 112) break;
    result.write(character);
    bytes += length;
  }
  return result.toString().trimRight();
}

String _timestamp(Duration time) {
  final ms = time.inMilliseconds < 0 ? 0 : time.inMilliseconds;
  final minutes = (ms ~/ 60000).toString().padLeft(2, '0');
  final seconds = ((ms ~/ 1000) % 60).toString().padLeft(2, '0');
  final centiseconds = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
  final fraction = ms % 10 == 0
      ? centiseconds
      : (ms % 1000).toString().padLeft(3, '0');
  return '$minutes:$seconds.$fraction';
}

String _renderProjectedWords(String translation, List<LyricsWord> projected) {
  final chars = translation.trim().runes.map(String.fromCharCode).toList();
  final output = StringBuffer();
  var cursor = 0;
  for (var index = 0; index < projected.length; index++) {
    final word = projected[index];
    while (cursor < chars.length && chars[cursor].trim().isEmpty) {
      output.write(chars[cursor++]);
    }
    output.write('<${_timestamp(word.start)}>');
    var remaining = word.text.runes.length;
    while (cursor < chars.length && remaining > 0) {
      final char = chars[cursor++];
      output.write(char);
      if (char.trim().isNotEmpty) remaining--;
    }
    if (word.end > word.start &&
        (index == projected.length - 1 ||
            word.end < projected[index + 1].start)) {
      output.write('<${_timestamp(word.end)}>');
    }
  }
  if (cursor < chars.length) output.write(chars.skip(cursor).join());
  return output.toString();
}

String _renderOriginalWords(
  List<LyricsWord> words, {
  required bool retainEnds,
}) {
  final output = StringBuffer();
  for (var index = 0; index < words.length; index++) {
    final word = words[index];
    output.write('<${_timestamp(word.start)}>${word.text}');
    if (retainEnds &&
        word.end > word.start &&
        (index == words.length - 1 || word.end < words[index + 1].start)) {
      output.write('<${_timestamp(word.end)}>');
    }
  }
  return output.toString();
}

String _renderLyrics(
  LyricsData lyrics, {
  bool includeDisplayedSubline = false,
}) {
  final output = <String>[];
  final timestampCounts = <int, int>{};
  if (includeDisplayedSubline && lyrics.isSynchronized) {
    for (final line in lyrics.lines) {
      final time = line.timestamp.inMilliseconds;
      timestampCounts[time] = (timestampCounts[time] ?? 0) + 1;
    }
  }
  final playback = includeDisplayedSubline && lyrics.isSynchronized
      ? LyricsService().playbackLines(lyrics)
      : null;
  var untaggedTranslations = 0;
  for (var index = 0; index < lyrics.lines.length; index++) {
    final line = lyrics.lines[index];
    final words = line.words;
    final wordTimed = words?.isNotEmpty == true;
    final originalText = line.text.trim().isNotEmpty
        ? line.text
        : words?.map((word) => word.text).join() ?? '';
    final text = lyrics.isSynchronized && wordTimed
        ? _renderOriginalWords(words!, retainEnds: includeDisplayedSubline)
        : originalText;
    final stamp = '[${_timestamp(line.timestamp)}]';
    output.add(lyrics.isSynchronized ? '$stamp$text' : text);
    final translation = line.translation?.trim();
    if (!includeDisplayedSubline ||
        translation == null ||
        translation.isEmpty ||
        translation == originalText.trim())
      continue;
    final source = playback?[index];
    final projected = source != null && wordTimed
        ? projectLyricsSubline(source, translation).words
        : null;
    final translatedText = projected?.isNotEmpty == true
        ? _renderProjectedWords(translation, projected!)
        : translation;
    // ELRC has no unambiguous vocal/subline association. The parser preserves
    // simultaneous enhanced singers, so our known translated word-timed row
    // needs an ignored metadata tag even when only one original sings here.
    // Other ELRC players still receive ordinary paired timed text records.
    if (lyrics.isSynchronized &&
        (wordTimed ||
            (timestampCounts[line.timestamp.inMilliseconds] ?? 0) > 1)) {
      // The parser folds plain bilingual pairs only after reading every row.
      // Earlier untagged translations still occupy its physical record index.
      output.add('[lokaltr:${index + untaggedTranslations}]');
    } else if (lyrics.isSynchronized) {
      untaggedTranslations++;
    }
    output.add(lyrics.isSynchronized ? '$stamp$translatedText' : translation);
  }
  return "${output.join('\n')}\n";
}

/// A source may contain timestamp-only/blank lines, but those must not
/// produce a "successful" empty export.
bool hasUsableLyrics(LyricsData lyrics) => lyrics.lines.any(
  (line) =>
      line.text.trim().isNotEmpty ||
      (line.words?.any((word) => word.text.trim().isNotEmpty) ?? false),
);

/// Keep valid original LRC/ELRC/XML bytes unless the player is showing a
/// translation or romanization that is not part of the original document.
/// In that case export the selected rendered lines, not stale rawContent.
LyricsFileExport prepareLyricsFileExport(
  Song song,
  LyricsData lyrics, {
  bool includeDisplayedSubline = false,
}) {
  if (!hasUsableLyrics(lyrics)) {
    throw ArgumentError('There are no lyrics to save');
  }

  final raw = lyrics.rawContent.trim();
  // The root element may follow XML comments or processing instructions.
  // Inspect only the prolog; preserving the original bytes keeps TTML
  // syllable timing and metadata intact.
  final xmlBody = raw.replaceFirst(
    RegExp(r'^(?:\s*(?:<!--[\s\S]*?-->|<\?[\s\S]*?\?>))*\s*'),
    '',
  );
  final root = RegExp(
    r'^<(?:[A-Za-z0-9_.-]+:)?(tt|lyrics|line)\b',
    caseSensitive: false,
  ).firstMatch(xmlBody)?.group(1)?.toLowerCase();
  final xml = root != null;
  final ttml = root == 'tt';
  final lrc = RegExp(r'\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]').hasMatch(raw);
  final enhanced =
      lrc && RegExp(r'<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>').hasMatch(raw);
  final withSubline =
      includeDisplayedSubline &&
      lyrics.lines.any(
        (line) =>
            line.translation?.trim().isNotEmpty == true &&
            line.translation!.trim() != line.text.trim(),
      );
  // Plain text files should also survive a normal save byte-for-byte.
  // Serialized desktop JSON is a model payload, not a portable lyric file.
  final plainText =
      !lyrics.isSynchronized &&
      raw.isNotEmpty &&
      !((raw.startsWith('{') && raw.endsWith('}')) ||
          (raw.startsWith('[') && raw.endsWith(']')));
  final preserveOriginal = !withSubline && (xml || lrc || plainText);
  final wordTimed = lyrics.lines.any((line) => line.words?.isNotEmpty == true);
  final extension = preserveOriginal && xml
      ? (ttml ? 'ttml' : 'xml')
      : lyrics.isSynchronized
      ? (withSubline
            ? (wordTimed ? 'elrc' : 'lrc')
            : ((preserveOriginal && enhanced || !preserveOriginal && wordTimed)
                  ? 'elrc'
                  : 'lrc'))
      : 'txt';
  final content = preserveOriginal
      ? lyrics.rawContent
      : _renderLyrics(lyrics, includeDisplayedSubline: withSubline);
  final title = _safeFilePart(song.title);
  final artist = _safeFilePart(song.artist);
  final stem = [
    if (artist.isNotEmpty) artist,
    if (title.isNotEmpty) title,
  ].join(' - ');
  return LyricsFileExport(
    fileName: "${stem.isEmpty ? 'Lyrics' : stem}.$extension",
    extension: extension,
    mimeType: preserveOriginal && xml ? 'application/xml' : 'text/plain',
    content: content,
  );
}

typedef LyricsExportPicker = Future<Uri?> Function(LyricsFileExport file);

/// The system document picker commits the bytes to the selected URI. A null
/// result is a cancellation; genuine file/permissions errors are propagated.
Future<bool> saveCurrentLyricsFile({
  required Song song,
  required LyricsData lyrics,
  bool includeDisplayedSubline = false,
  LyricsExportPicker? picker,
}) async {
  final file = prepareLyricsFileExport(
    song,
    lyrics,
    includeDisplayedSubline: includeDisplayedSubline,
  );
  // A cancelled injected picker must not fall through and open a second
  // platform picker. Both production and test cancellation return false.
  final saved = picker != null
      ? await picker(file)
      : await FilePicker.saveFile(
          dialogTitle: lokalText('Save lyrics to file'),
          fileName: file.fileName,
          mimeType: file.mimeType,
          bytes: file.bytes,
        );
  return saved != null;
}
