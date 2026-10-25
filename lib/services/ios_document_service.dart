import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SelectedPlaylistDocument {
  const SelectedPlaylistDocument({required this.name, required this.bytes});
  final String name;
  final Stream<List<int>> bytes;
}

class ImportedPlaylistDocument {
  const ImportedPlaylistDocument._(this.file, this.name, this.content);
  final File file;
  final String name;
  final String content;

  /// Only this import's private directory is removed; provider originals stay.
  Future<void> discard() => file.parent.delete(recursive: true);
}

/// Files export and persistent playlist snapshots. Picker callbacks are seams
/// for contract tests; production uses the locked native Darwin file picker.
class IosDocumentService {
  IosDocumentService({
    Future<Uri?> Function(String, String, Uint8List)? export,
    Future<SelectedPlaylistDocument?> Function()? pickPlaylist,
    Future<Directory> Function()? supportDirectory,
  }) : _export = export ?? _nativeExport,
       _pickPlaylist = pickPlaylist ?? _nativePickPlaylist,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Uri?> Function(String, String, Uint8List) _export;
  final Future<SelectedPlaylistDocument?> Function() _pickPlaylist;
  final Future<Directory> Function() _supportDirectory;
  static const maxPlaylistBytes = 10 * 1024 * 1024;

  static Future<Uri?> _nativeExport(
    String name,
    String mime,
    Uint8List bytes,
  ) => FilePicker.saveFile(fileName: name, mimeType: mime, bytes: bytes);

  static Future<SelectedPlaylistDocument?> _nativePickPlaylist() async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8'],
    );
    if (selected == null) return null;
    return SelectedPlaylistDocument(
      name: selected.name,
      bytes: selected.readAsByteStream(),
    );
  }

  Future<bool> saveText({
    required String fileName,
    required String mimeType,
    required String content,
  }) async =>
      await _export(
        fileName,
        mimeType,
        Uint8List.fromList(utf8.encode(content)),
      ) !=
      null;

  Future<ImportedPlaylistDocument?> importPlaylist() async {
    final selected = await _pickPlaylist();
    if (selected == null) return null;
    final name = p.basename(selected.name.replaceAll('\\', '/'));
    if (!const ['.m3u', '.m3u8'].contains(p.extension(name).toLowerCase())) {
      throw const FormatException('Choose an M3U or M3U8 playlist.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in selected.bytes) {
      if (bytes.length + chunk.length > maxPlaylistBytes) {
        throw const FormatException('The playlist is larger than 10 MB.');
      }
      bytes.add(chunk);
    }
    final content = utf8.decode(bytes.takeBytes());
    if (content.trim().isEmpty) {
      throw const FormatException('Selected playlist file is empty');
    }
    final root = Directory(
      p.join((await _supportDirectory()).path, 'ImportedPlaylists'),
    );
    await root.create(recursive: true);
    final directory = await root.createTemp('playlist-');
    try {
      final file = File(p.join(directory.path, name));
      await file.writeAsString(content, flush: true);
      return ImportedPlaylistDocument._(file, name, content);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}
