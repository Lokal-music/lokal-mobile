import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
    tag: (path, song) async {
      tags.add(path);
      return tagged;
    },
    cover: (path, song, url) async => covers.add(url),
    indexMedia: (paths) async => indexed.addAll(paths),
    now: () => DateTime(2026, 10, 20),
  );

  test('iPhone download fallback uses persistent app-owned Music', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getApplicationDocumentsDirectory');
      return p.join(root.path, 'Documents');
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final saved = await LibraryDownloader(
      folders: () async => [],
      registerFolder: (path, _) async => registered.add(path),
      upsert: (entity) async => upserts.add(entity),
      tag: (_, _) async => false,
      indexMedia: (_) async {},
    ).save(prepared());
    final expectedRoot = p.join(
      root.path,
      'Documents',
      'Music',
      'Lokal Downloads',
    );
    expect(p.isWithin(expectedRoot, saved.path), true);
    expect(registered, [expectedRoot]);
    expect(File(saved.path).readAsBytesSync(), cached.readAsBytesSync());
    expect(upserts.single.folderUri, expectedRoot);
  });

  test(
    'Atmos download remains byte-identical and retains codec identity',
    () async {
      final music = Directory(p.join(root.path, 'Library'))..createSync();
      final original = await cached.readAsBytes();
      final joc = prepared().copyWith(
        fileType: 'E-AC-3 JOC',
        atmosAvailable: true,
        atmosEncoded: true,
      );
      final saved = await downloader([
        LibraryDownloadFolder(
          uri: 'content://music',
          name: 'Music',
          path: music.path,
        ),
      ]).save(joc, artwork: 'https://example.com/cover.jpg');
      expect(saved.path, endsWith('.atmos.m4a'));
      expect(await File(saved.path).readAsBytes(), original);
      expect(upserts.single.fileType, 'E-AC-3 JOC');
      expect(upserts.single.hasLocalEdits, isTrue);
      expect(tags, isEmpty, reason: 'Tagging must not rewrite JOC MP4 boxes');
      expect(
        covers,
        isEmpty,
        reason: 'Do not embed artwork into the Atmos container',
      );
    },
  );

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
}
