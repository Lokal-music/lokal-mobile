import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File cached;
  final upserts = <SongEntity>[];
  final registered = <String>[];
  final indexed = <String>[];
  final covers = <String>[];
  final tags = <String>[];
  final savedLyrics = <String?>[];
  LyricsData? downloadLyrics;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('library_download_test');
    cached = File(p.join(root.path, 'cache', 'abc.m4a'));
    await cached.create(recursive: true);
    await cached.writeAsBytes(List.filled(64, 7));
    upserts.clear();
    registered.clear();
    indexed.clear();
    covers.clear();
    tags.clear();
    savedLyrics.clear();
    downloadLyrics = null;
  });

  tearDown(() => root.delete(recursive: true));

  Song prepared() => Song(
    id: 'discovery:abc',
    title: 'Song: One?',
    artist: 'The Artist',
    album: 'Album',
    duration: const Duration(seconds: 200),
    fileType: 'M4A',
    sampleRate: 44100,
    filePath: cached.path,
    isExternal: true,
  );

  LibraryDownloader downloader(
    List<LibraryDownloadFolder> folders, {
    bool tagged = true,
  }) => LibraryDownloader(
    folders: () async => folders,
    fallbackRoot: p.join(root.path, 'Music'),
    registerFolder: (path, name) async => registered.add(path),
    upsert: (entity) async => upserts.add(entity),
    tag: (path, song, lyrics) async {
      tags.add(path);
      if (lyrics != null) savedLyrics.add(LibraryDownloader.portableLyrics(lyrics));
      return tagged;
    },
    lyricsLookup: (_) async => downloadLyrics,
    cover: (path, song, url) async => covers.add(url),
    indexMedia: (paths) async => indexed.addAll(paths),
    now: () => DateTime(2026, 10, 20),
  );

  test('download embeds portable line lyrics without fabricating word stamps', () async {
    downloadLyrics = const LyricsData(
      lines: [
        LyricsLine(timestamp: Duration(seconds: 8), text: 'First verse'),
        LyricsLine(timestamp: Duration(seconds: 12), text: 'Second verse'),
      ],
      isSynchronized: true,
      source: 'LyricsPlus',
      rawContent: '',
    );
    final music = Directory(p.join(root.path, 'Library'))..createSync();
    await downloader([
      LibraryDownloadFolder(uri: 'u', name: 'Music', path: music.path),
    ]).save(prepared());
    expect(savedLyrics.single, contains('[00:08.00]First verse'));
    expect(savedLyrics.single, contains('[00:12.00]Second verse'));
    expect(savedLyrics.single, isNot(contains('<00:08.00>')));
  });

  test('a syllable-timed download keeps enhanced timing beside portable tags', () async {
    downloadLyrics = const LyricsData(
      lines: [
        LyricsLine(
          timestamp: Duration(seconds: 10),
          text: 'Hello world',
          words: [
            LyricsWord(
              start: Duration(seconds: 10),
              end: Duration(milliseconds: 10500),
              text: 'Hello ',
            ),
            LyricsWord(
              start: Duration(milliseconds: 10500),
              end: Duration(seconds: 11),
              text: 'world',
            ),
          ],
        ),
      ],
      isSynchronized: true,
      rawContent: '',
    );
    final music = Directory(p.join(root.path, 'Library'))..createSync();
    final result = await downloader([
      LibraryDownloadFolder(uri: 'u', name: 'Music', path: music.path),
    ]).save(prepared());
    expect(savedLyrics.single, contains('[00:10.00]Hello world'));
    expect(savedLyrics.single, isNot(contains('<00:10.00>')));
    final enhanced = File(p.setExtension(result.path, '.elrc'));
    expect(await enhanced.exists(), isTrue);
    expect(await enhanced.readAsString(), contains('<00:10.00>Hello '));
    expect(await enhanced.readAsString(), contains('<00:10.50>world'));
  });

  test('plain lyrics are embedded without fake synchronization timestamps', () async {
    downloadLyrics = const LyricsData(
      lines: [
        LyricsLine(timestamp: Duration.zero, text: 'Verse'),
        LyricsLine(timestamp: Duration.zero, text: 'Chorus'),
      ],
      isSynchronized: false,
      rawContent: '',
    );
    final music = Directory(p.join(root.path, 'Library'))..createSync();
    await downloader([
      LibraryDownloadFolder(uri: 'u', name: 'Music', path: music.path),
    ]).save(prepared());
    expect(savedLyrics.single, 'Verse\nChorus');
  });

  test('a lyrics lookup miss does not prevent downloaded audio from being saved', () async {
    final music = Directory(p.join(root.path, 'Library'))..createSync();
    final result = await downloader([
      LibraryDownloadFolder(uri: 'u', name: 'Music', path: music.path),
    ]).save(prepared());
    expect(File(result.path).existsSync(), isTrue);
    expect(savedLyrics, isEmpty);
  });

  test('Atmos download remains byte-identical and retains codec identity', () async {
    final music = Directory(p.join(root.path, 'Library'))..createSync();
    final original = await cached.readAsBytes();
    final joc = prepared().copyWith(
      fileType: 'E-AC-3 JOC',
      atmosAvailable: true,
      atmosEncoded: true,
    );
    final saved = await downloader([
      LibraryDownloadFolder(uri: 'content://music', name: 'Music',
        path: music.path),
    ]).save(joc, artwork: 'https://example.com/cover.jpg');
    expect(saved.path, endsWith('.atmos.m4a'));
    expect(await File(saved.path).readAsBytes(), original);
    expect(upserts.single.fileType, 'E-AC-3 JOC');
    expect(upserts.single.hasLocalEdits, isTrue);
    expect(tags, isEmpty, reason: 'Tagging must not rewrite JOC MP4 boxes');
    expect(covers, isEmpty, reason: 'Do not embed artwork into the Atmos container');
  });

  test('AC-4 saves preserve bytes and a rescan-safe codec suffix', () async {
    cached = await cached.rename(p.setExtension(cached.path, '.mp4'));
    final original = await cached.readAsBytes();
    final music = Directory(p.join(root.path, 'Library'))..createSync();
    final ac4 = prepared().copyWith(fileType: 'AC-4', atmosEncoded: true);
    final folders = [
      LibraryDownloadFolder(uri: 'u', name: 'Music', path: music.path),
    ];
    await downloader(folders).save(ac4);
    final saved = await downloader(folders).save(ac4);
    expect(saved.path, endsWith(' (2).ac4.atmos.mp4'));
    expect(await File(saved.path).readAsBytes(), original);
    expect(upserts.last.fileType, 'AC-4');
    expect(tags, isEmpty);
    expect(covers, isEmpty);
  });

  test('copies into the first writable library folder and adds it', () async {
    final music = Directory(p.join(root.path, 'Library'))..createSync();
    final saved = await downloader([
      const LibraryDownloadFolder(uri: 'content://saf-only', name: 'SD'),
      LibraryDownloadFolder(
        uri: 'content://tree/music',
        name: 'Music',
        path: music.path,
      ),
    ]).save(prepared(), artwork: 'https://example.com/cover.jpg');

    expect(saved.fallback, isFalse);
    expect(saved.folderName, 'Music');
    expect(
      saved.path,
      p.join(music.path, 'The Artist', 'Album', 'The Artist - Song One.m4a'),
    );
    expect(File(saved.path).readAsBytesSync(), hasLength(64));
    expect(cached.existsSync(), isTrue, reason: 'the cache keeps its copy');

    final entity = upserts.single;
    expect(entity.filePath, saved.path);
    expect(entity.title, 'Song: One?');
    expect(entity.artist, 'The Artist');
    expect(entity.album, 'Album');
    expect(entity.durationMs, 200000);
    expect(entity.fileType, 'M4A');
    expect(entity.folderUri, 'content://tree/music');
    expect(entity.relativeFolderPath, 'The Artist/Album');
    expect(entity.hasLocalEdits, isFalse);
    expect(indexed, [saved.path]);
    expect(covers, ['https://example.com/cover.jpg']);
    expect(registered, isEmpty);
  });

  test(
    'a second copy gets a numbered name; untagged keeps its names',
    () async {
      final music = Directory(p.join(root.path, 'Library'))..createSync();
      final folders = [
        LibraryDownloadFolder(uri: 'u', name: 'Music', path: music.path),
      ];
      await downloader(folders).save(prepared());
      final second = await downloader(folders, tagged: false).save(prepared());
      expect(p.basename(second.path), 'The Artist - Song One (2).m4a');
      expect(upserts.last.hasLocalEdits, isTrue);
    },
  );

  test(
    'falls back to Lokal Downloads in Music and adds it to the library',
    () async {
      // A library folder that can't hold a new folder (it's a file here).
      final blocked = File(p.join(root.path, 'blocked'))..createSync();
      final saved = await downloader([
        LibraryDownloadFolder(uri: 'u', name: 'Locked', path: blocked.path),
      ]).save(prepared());

      final fallback = p.join(root.path, 'Music', 'Lokal Downloads');
      expect(saved.fallback, isTrue);
      expect(saved.folderName, 'Lokal Downloads');
      expect(p.dirname(saved.path), p.join(fallback, 'The Artist', 'Album'));
      expect(registered, [fallback]);
      expect(upserts.single.folderUri, fallback);
      expect(upserts.single.relativeFolderPath, 'The Artist/Album');
    },
  );

  test('fails with a message when nothing can be written', () async {
    File(p.join(root.path, 'Music')).createSync(); // Music is a file.
    await expectLater(
      downloader(const []).save(prepared()),
      throwsA(isA<DiscoveryException>()),
    );
    expect(upserts, isEmpty);
  });

  test('a missing download is an error', () async {
    cached.deleteSync();
    await expectLater(
      downloader(const []).save(prepared()),
      throwsA(isA<DiscoveryException>()),
    );
  });

  test('file names drop characters file systems refuse', () {
    final song = prepared();
    expect(
      LibraryDownloader.fileName(song, '.mp3'),
      'The Artist - Song One.mp3',
    );
    expect(
      LibraryDownloader.fileName(
        Song(
          id: 'x',
          title: '..',
          artist: '/',
          duration: Duration.zero,
          fileType: 'MP3',
        ),
        '.mp3',
      ),
      'Song.mp3',
    );
  });

  test('a Monochrome FLAC download keeps catalogue title, artist, album and cover', () async {
    final flac = File(p.join(root.path, 'cache', '155142501534011392.flac'));
    await flac.writeAsBytes(List.filled(64, 7));
    final song = Song(
      id: 'discovery:mono',
      title: 'Get Lucky',
      artist: 'Daft Punk',
      album: 'Random Access Memories',
      duration: const Duration(seconds: 370),
      fileType: 'FLAC',
      filePath: flac.path,
      sourceDisplayName: 'Monochrome',
      isExternal: true,
    );
    final music = Directory(p.join(root.path, 'Library'))..createSync();
    final saved = await downloader([
      LibraryDownloadFolder(uri: 'test-library', name: 'Music', path: music.path),
    ]).save(song, artwork: 'https://tracks.monochrome.st/cover.jpg');

    expect(p.basename(saved.path), 'Daft Punk - Get Lucky.flac');
    expect(upserts.single.title, 'Get Lucky');
    expect(upserts.single.artist, 'Daft Punk');
    expect(upserts.single.album, 'Random Access Memories');
    expect(upserts.single.fileType, 'FLAC');
    expect(upserts.single.hasLocalEdits, isFalse);
    expect(tags, [saved.path], reason: 'FLAC tags must be written into the file');
    expect(covers, ['https://tracks.monochrome.st/cover.jpg']);
  });
}
