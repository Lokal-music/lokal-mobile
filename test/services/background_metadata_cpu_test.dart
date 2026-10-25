import 'dart:async';

import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/artwork_gate.dart';
import 'package:flick/services/background_metadata_budget.dart';
import 'package:flick/services/background_metadata_service.dart';
import 'package:flick/services/local_metadata_repair.dart';
import 'package:flick/services/music_folder_service.dart';
import 'package:flick/src/rust/api/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repository implements SongRepository {
  final List<SongEntity> rows;
  final batches = <List<SongEntity>>[];
  _Repository(this.rows);
  @override
  Future<List<SongEntity>> getIncompleteMetadataSongs() async => rows;
  @override
  Future<void> upsertSongs(List<SongEntity> entities) async {
    batches.add(List.of(entities));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Folders implements MusicFolderService {
  final calls = <List<String>>[];
  int active = 0, peak = 0;
  Completer<void>? block;
  @override
  Future<List<AudioFileInfo>> fetchMetadata(List<String> uris) async {
    calls.add(List.of(uris));
    active++;
    if (active > peak) peak = active;
    if (block != null) await block!.future;
    active--;
    return [
      for (final uri in uris)
        AudioFileInfo(
          uri: uri,
          name: 'song',
          size: 100,
          lastModified: 0,
          extension: 'flac',
          sampleRate: 48000,
          bitDepth: 24,
        ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SongEntity _row(int id) => SongEntity()
  ..id = id
  ..filePath = 'content://music/$id'
  ..title = 'Song $id'
  ..artist = 'Artist'
  ..metadataComplete = false;

Song _song(int id) => Song(
  id: '$id',
  title: 'Song $id',
  artist: 'Artist',
  duration: const Duration(seconds: 10),
  filePath: '/music/$id.flac',
  fileType: 'FLAC',
);

AudioFileMetadata _metadata({
  String format = 'flac',
  int? sampleRate = 48000,
  int? bitDepth = 24,
  int? bitrate = 900,
}) => AudioFileMetadata(
  path: '/music/1.flac',
  format: format,
  lastModified: 0,
  fileSize: BigInt.from(100),
  sampleRate: sampleRate,
  bitDepth: bitDepth,
  bitrate: bitrate,
  genre: 'Jazz',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'background idle budget grows with probe cost; Ultra leaves more rest',
    () {
      expect(
        backgroundMetadataDelay(Duration.zero),
        const Duration(milliseconds: 200),
      );
      expect(
        backgroundMetadataDelay(const Duration(milliseconds: 500)),
        const Duration(seconds: 2),
      );
      expect(
        backgroundMetadataDelay(const Duration(milliseconds: 500), ultra: true),
        const Duration(milliseconds: 4500),
      );
    },
  );

  test(
    'backfill keeps native calls single-file and serial, with a rest per probe',
    () async {
      final repo = _Repository([for (var i = 0; i < 19; i++) _row(i)]);
      final folders = _Folders();
      final rests = <Duration>[];
      final worker = BackgroundMetadataService(
        songRepository: repo,
        musicFolderService: folders,
        rest: (delay) async => rests.add(delay),
      );
      expect(await worker.extractPendingMetadata(), 19);
      expect(folders.calls, hasLength(19));
      expect(folders.calls.every((call) => call.length == 1), true);
      expect(folders.peak, 1);
      expect(rests, hasLength(19));
      expect(
        rests.every((delay) => delay >= const Duration(milliseconds: 200)),
        true,
      );
      expect(repo.batches.map((b) => b.length), [8, 8, 3]);
      expect(
        repo.rows.every((r) => r.metadataComplete && r.sampleRate == 48000),
        true,
      );
    },
  );

  test(
    'stop during a probe does not complete or persist unvisited rows',
    () async {
      final repo = _Repository([_row(1), _row(2)]);
      final folders = _Folders()..block = Completer<void>();
      final worker = BackgroundMetadataService(
        songRepository: repo,
        musicFolderService: folders,
        rest: (_) async {},
      );
      final running = worker.extractPendingMetadata();
      await Future<void>.delayed(Duration.zero);
      expect(await worker.extractPendingMetadata(), 0); // No overlapping pass.
      worker.stop();
      folders.block!.complete();
      expect(await running, 0);
      expect(folders.calls, hasLength(1));
      expect(repo.batches, isEmpty);
      expect(repo.rows.every((r) => !r.metadataComplete), true);
    },
  );

  test('automatic probes respect the shared scroll/preload gate', () async {
    final repo = _Repository([_row(1)]);
    final folders = _Folders();
    var waitedForGate = false;
    pauseArtworkExtraction(true);
    try {
      final worker = BackgroundMetadataService(
        songRepository: repo,
        musicFolderService: folders,
        rest: (delay) async {
          if (!waitedForGate) {
            expect(folders.calls, isEmpty);
            waitedForGate = true;
            pauseArtworkExtraction(false);
          }
        },
      );
      expect(await worker.extractPendingMetadata(), 1);
      expect(waitedForGate, true);
    } finally {
      if (artworkExtractionPaused) pauseArtworkExtraction(false);
    }
  });

  test('unchanged repair metadata generates no write; real codec corrections still apply', () {
    final row = _row(1)..genre = 'Custom';
    final meta = _metadata();
    expect(LocalMetadataRepair.applyMetadata(row, meta), true);
    expect(row.genre, 'Custom');
    expect(LocalMetadataRepair.applyMetadata(row, meta), false);
    expect(LocalMetadataRepair.applyMetadata(row, meta, codec: 'OPUS'), true);
    expect(row.fileType, 'OPUS');
    expect(LocalMetadataRepair.applyMetadata(row, meta, codec: 'OPUS'), false);
  });

  test('repair preserves lossless completeness and sample-rate fallback', () {
    final row = _row(1);
    expect(
      LocalMetadataRepair.applyMetadata(row, _metadata(bitDepth: null)),
      true,
    );
    expect(row.metadataComplete, false);
    LocalMetadataRepair.applyMetadata(
      row,
      _metadata(sampleRate: null, bitDepth: null),
      probedRate: 96000,
      probedBits: 24,
    );
    expect(row.sampleRate, 48000); // Known header values keep priority.
    expect(row.bitDepth, 24);
    expect(row.metadataComplete, true);
  });

  test(
    'repair checkpoints during a backlog and resumes without reprobes',
    () async {
      final rows = {for (var i = 1; i <= 20; i++) i: _row(i)};
      final prefs = await SharedPreferences.getInstance();
      final inspected = <int>[];
      final checkpointSizes = <int>[];
      LocalMetadataRepair makeWorker() => LocalMetadataRepair(
        databaseReady: () => true,
        loadSong: (id) async => rows[id],
        inspect: (row) async {
          inspected.add(row.id);
          return true;
        },
        rest: (_) async {
          checkpointSizes.add(
            (prefs.getStringList('lokal.local_metadata.v2') ?? []).length,
          );
        },
      );
      final first = makeWorker();
      first.warm([for (var i = 1; i <= 20; i++) _song(i)]);
      await first.idle;
      expect(inspected, hasLength(20));
      expect(checkpointSizes, contains(1));
      expect(checkpointSizes, contains(17));
      expect(prefs.getStringList('lokal.local_metadata.v2'), hasLength(20));
      inspected.clear();
      final second = makeWorker();
      second.warm([for (var i = 1; i <= 20; i++) _song(i)]);
      await second.idle;
      expect(inspected, isEmpty);
      // A changed fingerprint must still be repaired next session.
      rows[1]!.fileSize = (rows[1]!.fileSize ?? 0) + 1;
      final changed = makeWorker();
      changed.warm([_song(1)]);
      await changed.idle;
      expect(inspected, [1]);
    },
  );
}
