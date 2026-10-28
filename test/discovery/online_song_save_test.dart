import 'dart:io';

import 'package:flick/features/search/online_song_save.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    OnlineSongSaveRegistry.instance.clear();
    tmp = await Directory.systemTemp.createTemp('online_song_save');
  });
  tearDown(() async {
    OnlineSongSaveRegistry.instance.clear();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test(
    'live HTTP/Morneye handles download via the original provider',
    () async {
      final sourceFile = File(p.join(tmp.path, 'track.flac'));
      await sourceFile.writeAsBytes(List.filled(512, 42));
      final music = Directory(p.join(tmp.path, 'library'))..createSync();
      var downloaded = 0;
      final live = Song(
        id: 'live:one',
        title: 'Song',
        artist: 'Artist',
        fileType: 'FLAC',
        duration: const Duration(minutes: 2),
        filePath: 'lokal-progressive://stream/1',
        isExternal: true,
        sourcePackage: 'konnekted.progressive',
      );
      OnlineSongSaveRegistry.instance.register(live, () async {
        downloaded++;
        return live.copyWith(filePath: sourceFile.path);
      });
      expect(OnlineSongSaveRegistry.instance.canSave(live), isTrue);
      final saved = await OnlineSongSaveRegistry.instance.save(
        live,
        downloader: LibraryDownloader(
          folders: () async => [
            LibraryDownloadFolder(
              uri: 'test://folder',
              name: 'Music',
              path: music.path,
            ),
          ],
          registerFolder: (_, __) async {},
          upsert: (_) async {},
          tag: (_, __, ___) async => true,
          cover: (_, __, ___) async {},
          indexMedia: (_) async {},
        ),
      );
      expect(downloaded, 1);
      expect(await File(saved.path).readAsBytes(), List.filled(512, 42));
    },
  );

  test('unresolved live handles without a source cannot be saved', () {
    final live = Song(
      id: 'lost',
      title: 'Song',
      artist: 'Artist',
      fileType: 'FLAC',
      duration: Duration.zero,
      filePath: 'lokal-morneye://missing',
      sourcePackage: 'konnekted.morneye-live',
    );
    expect(OnlineSongSaveRegistry.instance.canSave(live), isFalse);
  });
}
