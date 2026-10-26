import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';

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

String _renderLyrics(LyricsData lyrics) {
  final output = <String>[];
  for (final line in lyrics.lines) {
    if (lyrics.isSynchronized) {
      final words = line.words;
      final text = words != null && words.isNotEmpty
          ? words.map((word) => '<${_timestamp(word.start)}>${word.text}').join()
          : line.text;
      output.add('[${_timestamp(line.timestamp)}]$text');
    } else {
      output.add(line.text);
    }
    if (line.translation?.trim().isNotEmpty == true) {
      output.add(line.translation!);
    }
  }
  return "${output.join('\n')}\n";
}

/// Keep valid original LRC/ELRC/XML bytes. Convert desktop JSON lyric payloads
/// from parsed lines so that the downloaded file works in ordinary players.
LyricsFileExport prepareLyricsFileExport(Song song, LyricsData lyrics) {
  if (lyrics.lines.isEmpty) {
    throw ArgumentError('There are no lyrics to save');
  }

  final raw = lyrics.rawContent.trim();
  final xml = raw.startsWith('<') &&
      (raw.startsWith('<?xml') || RegExp(r'^<(?:[A-Za-z0-9_-]+:)?(?:tt|lyrics|line)\b',
        caseSensitive: false).hasMatch(raw));
  final ttml = xml && RegExp(r'<(?:[A-Za-z0-9_-]+:)?tt\b',
      caseSensitive: false).hasMatch(raw);
  final lrc = RegExp(r'\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]').hasMatch(raw);
  final enhanced = lrc &&
      RegExp(r'<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>').hasMatch(raw);
  final extension = xml
      ? (ttml ? 'ttml' : 'xml')
      : lyrics.isSynchronized
          ? ((enhanced || (!lrc && lyrics.lines.any(
                (line) => line.words?.isNotEmpty == true))) ? 'elrc' : 'lrc')
          : 'txt';
  final content = xml || lrc ? lyrics.rawContent : _renderLyrics(lyrics);
  final title = _safeFilePart(song.title);
  final artist = _safeFilePart(song.artist);
  final stem = [
    if (artist.isNotEmpty) artist,
    if (title.isNotEmpty) title,
  ].join(' - ');
  return LyricsFileExport(
    fileName: "${stem.isEmpty ? 'Lyrics' : stem}.$extension",
    extension: extension,
    mimeType: xml ? 'application/xml' : 'text/plain',
    content: content,
  );
}

typedef LyricsExportPicker = Future<Uri?> Function(LyricsFileExport file);

/// Android's document picker commits the bytes to the selected URI. A null
/// result is a cancellation; genuine file/permissions errors are propagated.
Future<bool> saveCurrentLyricsFile({
  required Song song,
  required LyricsData lyrics,
  LyricsExportPicker? picker,
}) async {
  final file = prepareLyricsFileExport(song, lyrics);
  final saved = await (picker?.call(file) ??
      FilePicker.saveFile(
        dialogTitle: 'Save lyrics to file',
        fileName: file.fileName,
        mimeType: file.mimeType,
        type: FileType.custom,
        allowedExtensions: [file.extension],
        bytes: file.bytes,
      ));
  return saved != null;
}
