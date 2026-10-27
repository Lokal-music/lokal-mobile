import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/album_art_import_service.dart';
import 'package:flick/services/artwork_repair_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image;

class _Songs implements SongRepository {
  _Songs(this.current);
  Song current;
  @override
  Future<List<Song>> getAllSongs() async => [current];
  @override
  Future<Song?> getSongById(String id) async =>
      current.id == id ? current : null;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

const _candidate = AlbumArtCandidate(
  previewUrl: 'https://covers.example/album.jpg',
  imageUrl: 'https://covers.example/album.jpg',
  title: 'Album',
  artist: 'Artist',
  sourceLabel: 'iTunes',
);

class _Importer implements AlbumArtImportService {
  Future<List<AlbumArtCandidate>> Function()? lookup;
  final applied = <Song>[];
  @override
  bool isCustomArtworkPath(String? path) => path == '/manual/cover.png';
  @override
  Future<List<AlbumArtCandidate>> searchOnlineCandidates(Song song) async =>
      lookup == null ? [_candidate] : await lookup!();
  @override
  Future<AlbumArtUpdateResult> applyImageBytesToSong({
    required Song song,
    required Uint8List bytes,
  }) async {
    applied.add(song);
    return AlbumArtUpdateResult(
      albumName: song.album!,
      albumArtist: song.artist,
      albumArtPath: 'controlled-result.jpg',
      filePaths: [song.filePath!],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _Client extends http.BaseClient {
  _Client(this.reply);
  final Future<http.StreamedResponse> Function(http.BaseRequest) reply;
  final aborts = <Future<void>>[];
  int sends = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    aborts.add((request as http.AbortableRequest).abortTrigger!);
    return reply(request);
  }
}

void main() {
  late Directory directory;
  late _Songs songs;
  late _Importer importer;
  late Uint8List jpeg;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lokal-cover-repair-');
    final audio = await File('${directory.path}/recording.flac')
        .writeAsBytes([0]);
    songs = _Songs(
      Song(
        id: '1',
        title: 'Track',
        artist: 'Artist',
        album: 'Album',
        albumArtist: 'Artist',
        duration: Duration.zero,
        fileType: 'FLAC',
        filePath: audio.path,
      ),
    );
    importer = _Importer();
    jpeg = Uint8List.fromList(
      image.encodeJpg(image.Image(width: 640, height: 640)),
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  _Client successfulClient() => _Client(
    (_) async => http.StreamedResponse(
      Stream.value(jpeg),
      200,
      contentLength: jpeg.length,
    ),
  );

  for (final edited in [false, true]) {
    test(
      'refresh ${edited ? 'preserves a manual edit made during lookup' : 'applies a verified exact larger cover'}',
      () async {
        final client = successfulClient();
        if (edited) {
          importer.lookup = () async {
            songs.current = songs.current.copyWith(
              albumArt: '/manual/cover.png',
            );
            return [_candidate];
          };
        }
        final service = ArtworkRepairService(
          repository: songs,
          importer: importer,
          client: client,
        );
        try {
          final result = await service.refresh(onProgress: (_) {});
          expect(result.updated, edited ? 0 : 1);
          expect(result.skipped, edited ? 1 : 0);
          expect(result.checked, 1);
          expect(importer.applied, hasLength(edited ? 0 : 1));
          var aborted = false;
          client.aborts.single.then((_) => aborted = true);
          service.cancel();
          await Future<void>.delayed(Duration.zero);
          expect(
            aborted,
            isFalse,
            reason: 'Late cancel must not abort a consumed response',
          );
        } finally {
          service.dispose();
        }
      },
    );
  }

  test(
    'cancel during catalogue lookup starts no artwork request or write',
    () async {
      final started = Completer<void>();
      final lookup = Completer<List<AlbumArtCandidate>>();
      importer.lookup = () {
        started.complete();
        return lookup.future;
      };
      final client = successfulClient();
      final service = ArtworkRepairService(
        repository: songs,
        importer: importer,
        client: client,
      );
      try {
        final operation = service.refresh(onProgress: (_) {});
        await started.future;
        service.cancel();
        lookup.complete([_candidate]);
        final result = await operation;
        expect(result.cancelled, isTrue);
        expect(result.failed, 0);
        expect(client.sends, 0);
        expect(importer.applied, isEmpty);
      } finally {
        service.dispose();
      }
    },
  );

  test(
    'cancel aborts a blocked transfer without reporting a failed cover',
    () async {
      final started = Completer<void>();
      var aborted = false;
      final client = _Client((request) {
        started.complete();
        return (request as http.AbortableRequest).abortTrigger!.then((_) {
          aborted = true;
          throw StateError('Controlled native request abort');
        });
      });
      final service = ArtworkRepairService(
        repository: songs,
        importer: importer,
        client: client,
      );
      try {
        final operation = service.refresh(onProgress: (_) {});
        await started.future;
        service.cancel();
        final result = await operation;
        expect(aborted, isTrue);
        expect(result.cancelled, isTrue);
        expect(result.failed, 0);
        expect(importer.applied, isEmpty);
      } finally {
        service.dispose();
      }
    },
  );
}
