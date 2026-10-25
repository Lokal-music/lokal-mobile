import 'dart:convert';
import 'dart:io';

import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/ios_document_service.dart';
import 'package:flick/services/playlist_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _Songs extends Fake implements SongRepository {
  _Songs(this.songs);
  final List<Song> songs;
  @override
  Future<List<Song>> getAllSongs() async => songs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory support;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('ios-documents-');
    support = Directory(p.join(root.path, 'Support'));
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'native export receives complete UTF-8 data and reports cancellation',
    () async {
      const content = 'Title,Artist\n"Café, live",演奏者\n';
      var saved = false;
      final service = IosDocumentService(
        export: (name, mime, bytes) async {
          expect(name, 'recap.csv');
          expect(mime, 'text/csv');
          expect(utf8.decode(bytes), content);
          return saved ? Uri.file('/Files/recap.csv') : null;
        },
      );
      expect(
        await service.saveText(
          fileName: 'recap.csv',
          mimeType: 'text/csv',
          content: content,
        ),
        false,
      );
      saved = true;
      expect(
        await service.saveText(
          fileName: 'recap.csv',
          mimeType: 'text/csv',
          content: content,
        ),
        true,
      );
    },
  );

  test(
    'import survives provider removal and feeds existing stable-song matching',
    () async {
      final original = File(p.join(root.path, 'Provider', 'Voyage.m3u8'));
      await original.parent.create();
      await original.writeAsString(
        '#EXTM3U\n#EXTINF:8,演奏者 - Café\nMusic/Café.flac\n',
      );
      final service = IosDocumentService(
        supportDirectory: () async => support,
        pickPlaylist: () async => SelectedPlaylistDocument(
          name: original.path,
          bytes: original.openRead(),
        ),
      );
      final imported = (await service.importPlaylist())!;
      expect(imported.name, 'Voyage.m3u8');
      expect(p.isWithin(support.path, imported.file.path), true);
      expect(await original.readAsString(), imported.content);
      await original.delete();
      expect(await imported.file.readAsString(), imported.content);
      final song = Song(
        id: 'stable-song',
        title: 'Café',
        artist: '演奏者',
        duration: const Duration(seconds: 8),
        fileType: 'FLAC',
        filePath: '/Documents/Music/Café.flac',
      );
      final results = await PlaylistService(songRepository: _Songs([song]))
          .syncPlaylistsFromSources([
            PlaylistSourceFile(
              sourcePath: imported.file.path,
              displayName: imported.name,
            ),
          ]);
      expect(results.single.playlist.songIds, ['stable-song']);
      expect(results.single.playlist.name, 'Voyage');
      expect(results.single.playlist.sourcePath, imported.file.path);
    },
  );

  test('picker cancellation creates no stored playlist', () async {
    final service = IosDocumentService(
      supportDirectory: () async => support,
      pickPlaylist: () async => null,
    );
    expect(await service.importPlaylist(), isNull);
    expect(await support.exists(), false);
  });

  test(
    'provider error and oversized input leave no partial snapshot',
    () async {
      final failure = IosDocumentService(
        supportDirectory: () async => support,
        pickPlaylist: () async => SelectedPlaylistDocument(
          name: 'test.m3u',
          bytes: Stream.error(
            const FileSystemException('Provider unavailable'),
          ),
        ),
      );
      await expectLater(
        failure.importPlaylist(),
        throwsA(isA<FileSystemException>()),
      );
      final oversized = IosDocumentService(
        supportDirectory: () async => support,
        pickPlaylist: () async => SelectedPlaylistDocument(
          name: 'test.m3u8',
          bytes: Stream.value(
            List<int>.filled(IosDocumentService.maxPlaylistBytes + 1, 32),
          ),
        ),
      );
      await expectLater(oversized.importPlaylist(), throwsFormatException);
      expect(await support.exists(), false);
    },
  );

  test('invalid or empty text is rejected before persistence', () async {
    for (final bytes in [
      <int>[],
      [0xff, 0xff],
    ]) {
      final service = IosDocumentService(
        supportDirectory: () async => support,
        pickPlaylist: () async => SelectedPlaylistDocument(
          name: 'test.m3u8',
          bytes: Stream.value(bytes),
        ),
      );
      await expectLater(service.importPlaylist(), throwsFormatException);
    }
    expect(await support.exists(), false);
  });

  test(
    'discard removes only its own copy and preserves provider originals',
    () async {
      final original = File(p.join(root.path, 'original.m3u8'));
      await original.writeAsString('#EXTM3U\ntrack.flac\n');
      final service = IosDocumentService(
        supportDirectory: () async => support,
        pickPlaylist: () async => SelectedPlaylistDocument(
          name: 'original.m3u8',
          bytes: original.openRead(),
        ),
      );
      final first = (await service.importPlaylist())!;
      final second = (await service.importPlaylist())!;
      await first.discard();
      expect(await first.file.exists(), false);
      expect(await second.file.exists(), true);
      expect(await original.exists(), true);
    },
  );
}
