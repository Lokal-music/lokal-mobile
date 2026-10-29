import 'dart:async';

import 'package:flick/services/link/link_download_outbox.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/atmos_diagnostics.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/album_art_import_service.dart';
import 'package:flick/services/music_folder_service.dart';
import 'package:flick/services/music_library_path.dart';
import 'package:flick/src/rust/api/metadata_editor.dart' as rust_metadata;

/// A library folder, with where it is on disk when Android says.
class LibraryDownloadFolder {
  const LibraryDownloadFolder({
    required this.uri,
    required this.name,
    this.path,
  });

  final String uri;
  final String name;
  final String? path;
}

/// Where a song saved to the library went.
class LibraryDownloadResult {
  const LibraryDownloadResult({
    required this.path,
    required this.folderName,
    required this.fallback,
  });

  final String path;

  /// The library folder it is in.
  final String folderName;

  /// True when no library folder could be written to, so it went to Lokal's
  /// own Downloads folder (now part of the library).
  final bool fallback;
}

/// Saves a song found online (already downloaded and checked into the
/// playback cache by [OnlineSource.play]) to your library, as desktop's
/// "Save to library": copied into Artist/Album inside your
/// first writable library folder (else into Music/Lokal Downloads/Artist/Album,
/// which then becomes a library folder), tagged, given its cover and added
/// to the library straight away.
class LibraryDownloader {
  LibraryDownloader({
    Future<List<LibraryDownloadFolder>> Function()? folders,
    this.fallbackRoot = '/storage/emulated/0/Music',
    Future<void> Function(String path, String name)? registerFolder,
    Future<void> Function(SongEntity entity)? upsert,
    Future<bool> Function(String path, Song song, LyricsData? lyrics)? tag,
    Future<LyricsData?> Function(Song song)? lyricsLookup,
    Future<void> Function(String path, Song song, String artwork)? cover,
    Future<void> Function(List<String> paths)? indexMedia,
    DateTime Function()? now,
  }) : _folders = folders ?? _savedFolders,
       _registerFolder = registerFolder ?? _register,
       _upsert = upsert ?? SongRepository().upsertSong,
       _tag = tag ?? _writeTags,
       _lyricsLookup = lyricsLookup ?? _getDownloadLyrics,
       _cover = cover ?? _applyCover,
       _indexMedia = indexMedia ?? MusicFolderService().indexMediaFiles,
       _now = now ?? DateTime.now;

  static const folderName = 'Lokal Downloads';

  /// Where Lokal's own Downloads folder goes when no library folder can be
  /// written to (shared storage's Music folder).
  final String fallbackRoot;
  final Future<List<LibraryDownloadFolder>> Function() _folders;
  final Future<void> Function(String path, String name) _registerFolder;
  final Future<void> Function(SongEntity entity) _upsert;
  final Future<bool> Function(String path, Song song, LyricsData? lyrics) _tag;
  final Future<LyricsData?> Function(Song song) _lyricsLookup;
  final Future<void> Function(String path, Song song, String artwork) _cover;
  final Future<void> Function(List<String> paths) _indexMedia;
  final DateTime Function() _now;

  static Future<List<LibraryDownloadFolder>> _savedFolders() async {
    final service = MusicFolderService();
    return [
      for (final folder in await service.getSavedFolders())
        LibraryDownloadFolder(
          uri: folder.uri,
          name: folder.displayName,
          path: (await service.resolveStorageInfo(folder.uri)).fsPath,
        ),
    ];
  }

  static Future<void> _register(String path, String name) =>
      MusicFolderService().addLocalFolder(path, name);

  /// The saved file must carry usable lyrics, not just its cover and names.
  /// Online lookup is best-effort and bounded; a provider outage never blocks
  /// the audio download. Prefer the cached file's lyrics when they are better.
  static Future<LyricsData?> _getDownloadLyrics(Song song) async {
    return LyricsService().loadLyricsForSong(song, fetchOnline: true)
        .timeout(const Duration(seconds: 14), onTimeout: () => null);
  }

  static String? portableLyrics(LyricsData? data) {
    if (data == null || data.lines.isEmpty) return null;
    final content = data.isSynchronized
        ? LyricsService().buildLrcContent(
            lines: [
              for (final line in data.lines)
                LyricsLine(
                  timestamp: line.timestamp,
                  text: line.text,
                  translation: line.translation,
                ),
            ],
          )
        : data.lines.map((l) => l.text).where((s) => s.trim().isNotEmpty)
              .join('\n');
    return content.trim().isEmpty ? null : content;
  }

  static Future<bool> _writeTags(
    String path, Song song, LyricsData? lyrics,
  ) async {
    try {
      final result = await rust_metadata.writeTags(
        path: path,
        fields: rust_metadata.TagEditFields(
          title: song.title,
          artist: song.artist,
          album: song.album,
          lyrics: portableLyrics(lyrics),
        ),
      );
      return result.success;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _applyCover(String path, Song song, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) return;
    await AlbumArtImportService.instance.applyImageBytesToSong(
      song: _withPath(song, path),
      bytes: Uint8List.fromList(response.bodyBytes),
    );
  }

  static Song _withPath(Song song, String path) => Song(
    id: song.id,
    title: song.title,
    artist: song.artist,
    album: song.album,
    duration: song.duration,
    fileType: song.fileType,
    filePath: path,
  );

  /// A file name for [song]: "Artist - Title.ext", without characters file
  /// systems refuse.
  static String fileName(Song song, String extension) {
    final base = '${song.artist} - ${song.title}'
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
    final name = RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(base)
        ? base
        : 'Song';
    return '${name.length > 120 ? name.substring(0, 120).trim() : name}'
        '$extension';
  }

  static bool _inside(String child, String parent) =>
      p.equals(child, parent) || p.isWithin(parent, child);

  /// Copies [prepared] into the library. [artwork] is the cover to give it.
  Future<LibraryDownloadResult> save(Song prepared, {String? artwork}) async {
    if (prepared.atmosEncoded) AtmosDiagnostics.record('library_save_start', {
      'codec': 'eac3_joc',
      'stage': 'copy',
    });
    final source = prepared.filePath;
    if (source == null || !File(source).existsSync()) {
      throw const DiscoveryException('The downloaded song is gone. Try again.');
    }
    final extension = p.extension(source).toLowerCase();
    // Mark saved Atmos files in the filename as well as the DB. A later
    // filesystem scan may replace the codec field with the MP4 container
    // extension; the suffix keeps the original JOC routing identifiable.
    final savedExtension = prepared.atmosEncoded
        ? (prepared.fileType.toUpperCase() == 'AC-4'
          ? '.ac4.atmos$extension' : '.atmos$extension') : extension;
    final folders = await _folders();
    final directories = MusicLibraryPath.directories(
      artist: prepared.artist,
      album: prepared.album,
      albumArtist: prepared.albumArtist,
    );

    var targets =
        <({String dir, String root, String uri, String name, bool fallback})>[
          for (final folder in folders)
            if (folder.path case final String path when path.isNotEmpty)
              (
                dir: p.joinAll([path, ...directories]),
                root: path,
                uri: folder.uri,
                name: folder.name,
                fallback: false,
              ),
        ];
    final fallbackDir = p.join(fallbackRoot, folderName);
    final covering = folders
        .where((f) => f.path != null && _inside(fallbackDir, f.path!))
        .firstOrNull;
    targets = [
      ...targets,
      (
        dir: p.joinAll([fallbackDir, ...directories]),
        root: covering?.path ?? fallbackDir,
        uri: covering?.uri ?? fallbackDir,
        name: covering?.name ?? folderName,
        fallback: covering == null,
      ),
    ];

    for (final target in targets) {
      final File copy;
      try {
        final dir = Directory(target.dir);
        await dir.create(recursive: true);
        var path = p.join(dir.path, fileName(prepared, savedExtension));
        for (var n = 2; File(path).existsSync(); n++) {
          path = p.join(dir.path, fileName(prepared, ' ($n)$savedExtension'));
        }
        copy = await File(source).copy(path);
      } on FileSystemException {
        continue; // Not writable: try the next folder.
      }

      if (target.fallback) await _registerFolder(target.root, folderName);
      // Rust tag editors may rewrite the MP4 audio sample description;
      // preserve E-AC-3 JOC bitstream metadata byte for byte.
      LyricsData? lyrics;
      if (!prepared.atmosEncoded) {
        try {
          lyrics = await _lyricsLookup(prepared);
        } catch (_) {
          // Lyrics failure must not prevent the download being saved.
        }
      }
      final tagged = prepared.atmosEncoded
          ? false : await _tag(copy.path, prepared, lyrics);
      // The portable embedded tag stores plain/line LRC so other players do
      // not display "<word time>" markup. Preserve actual per-word timings
      // in a companion enhanced-LRC file that Lokal reads before the tag.
      if (!prepared.atmosEncoded &&
          lyrics?.isSynchronized == true &&
          lyrics!.lines.any((line) => line.words?.isNotEmpty == true)) {
        final enhanced = LyricsService().buildLrcContent(
          lines: lyrics.lines,
          song: prepared,
          length: prepared.duration,
        );
        try {
          await File(p.setExtension(copy.path, '.elrc')).writeAsString(enhanced);
        } catch (_) {
          // The audio and its embedded portable lyric are still valid.
        }
      }
      final stat = await copy.stat();
      final now = _now();
      await _upsert(
        SongEntity()
          ..filePath = copy.path
          ..title = prepared.title
          ..artist = prepared.artist
          ..album = prepared.album
          ..durationMs = prepared.duration.inMilliseconds
          ..fileType = prepared.atmosEncoded
              ? (prepared.fileType.toUpperCase() == 'AC-4' ? 'AC-4' : 'E-AC-3 JOC')
              : extension.replaceFirst('.', '').toUpperCase()
          ..fileSize = stat.size
          ..sampleRate = prepared.sampleRate
          ..bitDepth = prepared.bitDepth
          ..dateAdded = now
          ..lastModified = stat.modified
          ..folderUri = target.uri
          ..relativeFolderPath = p
              .relative(target.dir, from: target.root)
              .replaceFirst(RegExp(r'^\.$'), '')
          ..metadataComplete = true
          // Untagged: keep these names over the file's when rescanned.
          ..hasLocalEdits = !tagged,
      );
      await _indexMedia([copy.path]);
      // For JOC, do not embed artwork by rewriting the downloaded MP4.
      if (!prepared.atmosEncoded && artwork != null && artwork.isNotEmpty) {
        try {
          await _cover(copy.path, prepared, artwork);
        } catch (_) {
          // The song is saved; the cover can be added later.
        }
      }
      unawaited(LinkDownloadOutbox.enqueue(copy.path));
      if (prepared.atmosEncoded) AtmosDiagnostics.record('library_save_complete', {
        'codec': 'eac3_joc',
        'outcome': 'saved',
        'reason': target.fallback ? 'fallback_folder' : 'chosen_folder',
      });
      return LibraryDownloadResult(
        path: copy.path,
        folderName: target.name,
        fallback: target.fallback,
      );
    }
    throw const DiscoveryException(
      'Android didn’t let Lokal write to your music folders or to Music.',
    );
  }
}
