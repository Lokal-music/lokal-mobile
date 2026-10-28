import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flick/models/song.dart';
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
  return cleaned.length <= 64 ? cleaned : cleaned.substring(0, 64).trimRight();
}

String _timestamp(Duration time) {
  final ms = time.inMilliseconds < 0 ? 0 : time.inMilliseconds;
  final minutes = (ms ~/ 60000).toString().padLeft(2, '0');
  final seconds = ((ms ~/ 1000) % 60).toString().padLeft(2, '0');
  final centiseconds = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
  return '$minutes:$seconds.$centiseconds';
}

/// Reapply the projected per-syllable timings to the exact selected subline.
/// The playback projection omits whitespace when splitting across source vocal
/// windows. Emit that whitespace *before* each next marker so save/reload keeps
/// the same visible translated sentence (including spaces and punctuation).
String _renderProjectedWords(String translation, List<LyricsWord> projected) {
  final chars = translation.trim().runes.map(String.fromCharCode).toList();
  final output = StringBuffer();
  var cursor = 0;
  for (final word in projected) {
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
  }
  if (cursor < chars.length) output.write(chars.skip(cursor).join());
  return output.toString();
}

String _renderLyrics(LyricsData lyrics, {bool includeDisplayedSubline = false}) {
  final output = <String>[];
  // Same-time vocals are not necessarily a bilingual pair. For collisions,
  // emit a non-singing Lokal association tag before the translated LRC row
  // so re-import never mistakes that row for a third singer.
  final timestampCounts = <int, int>{};
  if (includeDisplayedSubline && lyrics.isSynchronized) {
    for (final line in lyrics.lines) {
      final time = line.timestamp.inMilliseconds;
      timestampCounts[time] = (timestampCounts[time] ?? 0) + 1;
    }
  }
  // Source-provided words sometimes have only start markers. The existing
  // playback resolver completes their end windows before translation timing
  // is projected, without altering the originals being exported.
  final playbackLines = includeDisplayedSubline && lyrics.isSynchronized
      ? LyricsService().playbackLines(lyrics)
      : null;
  for (var index = 0; index < lyrics.lines.length; index++) {
    final line = lyrics.lines[index];
    final words = line.words;
    final text = lyrics.isSynchronized && words != null && words.isNotEmpty
        ? words.map((word) => '<${_timestamp(word.start)}>${word.text}').join()
        : line.text.isNotEmpty
            ? line.text
            : words?.map((word) => word.text).join() ?? '';
    final stamp = '[${_timestamp(line.timestamp)}]';
    output.add(lyrics.isSynchronized ? '$stamp$text' : text);
    final translation = line.translation?.trim();
    final originalText = line.text.trim().isNotEmpty
        ? line.text.trim()
        : words?.map((word) => word.text).join().trim() ?? '';
    if (includeDisplayedSubline && translation != null &&
        translation.isNotEmpty && translation != originalText) {
      // An explicit association is needed only for simultaneous vocal
      // lines sharing the same clock; ordinary bilingual ELRC uses adjacent
      // original + translated lines exactly as in common lyric files.
      if (lyrics.isSynchronized &&
          (timestampCounts[line.timestamp.inMilliseconds] ?? 0) > 1) {
        output.add('[lokaltr:$index]');
      }
      final source = playbackLines?[index];
      final projected = source != null && words?.isNotEmpty == true
          ? projectLyricsSubline(source, translation).words
          : null;
      final translatedText = projected?.isNotEmpty == true
          ? _renderProjectedWords(translation, projected!)
          : translation;
      output.add(lyrics.isSynchronized ? '$stamp$translatedText' : translation);
    }
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

/// Keep valid original LRC/ELRC/XML bytes for normal saves. Only an explicit
/// translated save renders the selected sublines (which may not exist in raw
/// source content). When the original has word timings, bilingual saves use
/// paired enhanced ELRC rows with projected translation timing. Otherwise
/// they use line-level LRC; normal saves preserve source XML/ELRC bytes.
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
  final enhanced = lrc &&
      RegExp(r'<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>').hasMatch(raw);
  final withSubline = includeDisplayedSubline && lyrics.lines.any(
    (line) => line.translation?.trim().isNotEmpty == true &&
        line.translation!.trim() != line.text.trim(),
  );
  // Plain text files should also survive a normal save byte-for-byte.
  // Serialized desktop JSON is a model payload, not a portable lyric file.
  final plainText = !lyrics.isSynchronized && raw.isNotEmpty &&
      !((raw.startsWith('{') && raw.endsWith('}')) ||
          (raw.startsWith('[') && raw.endsWith(']')));
  final preserveOriginal = !withSubline && (xml || lrc || plainText);
  final wordTimed = lyrics.lines.any((line) => line.words?.isNotEmpty == true);
  final extension = preserveOriginal && xml
      ? (ttml ? 'ttml' : 'xml')
      : lyrics.isSynchronized
          ? ((preserveOriginal && enhanced || wordTimed)
              ? 'elrc'
              : 'lrc')
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

/// Android's document picker commits the bytes to the selected URI. A null
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
          dialogTitle: 'Save lyrics to file',
          fileName: file.fileName,
          mimeType: file.mimeType,
          type: FileType.custom,
          allowedExtensions: [file.extension],
          bytes: file.bytes,
        );
  return saved != null;
}
