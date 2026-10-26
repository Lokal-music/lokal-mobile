import 'dart:ffi';
import 'dart:io';

import 'package:flick/data/database.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/services/library_scanner_service.dart';
import 'package:flick/services/music_folder_service.dart';
import 'package:flick/services/playlist_service.dart';
import 'package:flick/src/rust/api/metadata_editor.dart' as tags;
import 'package:flick/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
// The directory seam belongs to path_provider's locked platform interface.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fixtures/generated_audio.dart';

class _OwnedPaths extends PathProviderPlatform {
  _OwnedPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/Documents';
  @override
  Future<String?> getApplicationSupportPath() async => '$root/Support';
  @override
  Future<String?> getTemporaryPath() async => '$root/Temporary';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rust = Platform.environment['LOKAL_NATIVE_LIBRARY'];
  final isarCore = Platform.environment['LOKAL_ISAR_LIBRARY'];

  test(
    'real scanner and database preserve library IDs and playlists on reopen',
    () async {
      // This is a host integration check. Only directory/preferences storage is
      // isolated; the Rust scanner, production indexing and Isar store are real.
      // It does not exercise Apple's picker, signing, or a process relaunch.
      final root = await Directory.systemTemp.createTemp(
        'lokal-library-proof-',
      );
      addTearDown(() => root.delete(recursive: true));
      for (final name in ['Documents', 'Support', 'Temporary']) {
        await Directory('${root.path}/$name').create();
      }
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _OwnedPaths(root.path);
      addTearDown(() => PathProviderPlatform.instance = paths);
      SharedPreferences.setMockInitialValues({'lyrics_auto_fetch': false});
      await RustLib.init(externalLibrary: ExternalLibrary.open(rust!));
      addTearDown(RustLib.dispose);
      Isar.initializeIsarCore(libraries: {Abi.current(): isarCore!});
      await Database.init();
      addTearDown(Database.close);

      final source = File('${root.path}/Été 音楽.wav');
      await source.writeAsBytes(generatedPcmTone(), flush: true);
      expect(
        (await tags.writeTags(
          path: source.path,
          fields: const tags.TagEditFields(
            title: 'Persistent native fixture',
            artist: 'Fixture performer',
            album: 'Owned files',
            albumArtist: 'Various fixtures',
          ),
        )).success,
        true,
      );
      final music = await Directory('${root.path}/Documents/Music/Imported')
          .create(recursive: true);
      final copied = await source.copy('${music.path}/Été 音楽.wav');
      final sourceBytes = await source.readAsBytes();
      await MusicFolderService().addLocalFolder(music.path, 'Fixture import');
      final scanner = LibraryScannerService();
      final repository = SongRepository();
      final playlists = PlaylistService(songRepository: repository);

      Future<List<ScanProgress>> scan(ScanMode mode) async {
        final progress = await scanner
            .scanFolder(music.path, 'Fixture import', mode: mode)
            .toList();
        await scanner.awaitAllArtworkBackfill();
        expect(progress.last.isComplete, true);
        return progress;
      }

      await scan(ScanMode.full);
      final first = (await repository.searchSongs('Persistent native fixture'))
          .single;
      expect(first.filePath, copied.path);
      expect(first.sampleRate, 44100);
      expect(first.duration.inSeconds, 8);
      final id = first.id;
      final playlist = (await playlists.createPlaylist(
        'Persistent fixture queue',
      ))!;
      expect(
        await playlists.addSongToPlaylist(playlist.id, id, song: first),
        true,
      );

      final unchanged = await scan(ScanMode.quick);
      expect(unchanged.last.newSongs, 0);
      expect((await repository.getAllSongs()).single.id, id);
      expect((await repository.getAllSongs()).single.filePath, copied.path);

      expect(
        (await tags.writeTags(
          path: copied.path,
          fields: const tags.TagEditFields(
            title: 'Retagged native fixture',
            artist: 'Fixture performer',
            album: 'Owned files',
            albumArtist: 'Various fixtures',
          ),
        )).success,
        true,
      );
      await scan(ScanMode.full);
      expect(
        (await repository.searchSongs('Retagged native fixture')).single.id,
        id,
      );
      expect(
        await repository.searchSongs('Persistent native fixture'),
        isEmpty,
      );
      expect(
        await source.readAsBytes(),
        sourceBytes,
        reason: 'Indexing/retagging must not modify the provider original',
      );

      await Database.close();
      await Database.init();
      final reopened = SongRepository();
      final restored = (await reopened.getAllSongs()).single;
      expect(restored.id, id);
      expect(restored.title, 'Retagged native fixture');
      expect(restored.filePath, copied.path);
      final restoredPlaylist = await PlaylistService(songRepository: reopened)
          .getPlaylist(playlist.id);
      expect(restoredPlaylist?.songIds, [id]);
      expect(
        (await MusicFolderService().getSavedFolders()).single.uri,
        music.path,
      );
    },
    skip: rust == null || isarCore == null
        ? 'Set LOKAL_NATIVE_LIBRARY and LOKAL_ISAR_LIBRARY to actual host libraries.'
        : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
