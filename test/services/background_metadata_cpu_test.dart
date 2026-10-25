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
import 'package:flutter/services.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();
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
    '5500 complete local songs do not trigger startup header probes',
    () async {
      final rows = {
        for (var i = 1; i <= 5500; i++)
          i: (_row(i)
            ..filePath = '/music/$i.flac'
            ..metadataComplete = true),
      };
      var probes = 0;
      var yields = 0;
      final worker = LocalMetadataRepair(
        databaseReady: () => true,
        loadSong: (id) async => rows[id],
        inspect: (_) async {
          probes++;
          return true;
        },
        rest: (_) async => yields++,
      );
      final songs = [for (var i = 1; i <= 5500; i++) _song(i)];
      worker.warm(songs);
      await worker.idle;
      worker.warm(songs); // An artwork/metadata refresh must stay idle too.
      await worker.idle;
      expect(probes, 0);
      expect(yields, greaterThan(80)); // Cached checks still yield in batches.
    },
  );

  test(
    'SAF library has one metadata owner and is never queued for repair',
    () async {
      var loads = 0;
      final worker = LocalMetadataRepair(
        databaseReady: () => true,
        loadSong: (_) async {
          loads++;
          return null;
        },
        rest: (_) async {},
      );
      worker.warm([
        for (var i = 0; i < 5500; i++)
          _song(i).copyWith(filePath: 'content://music/$i'),
      ]);
      await worker.idle;
      expect(loads, 0);
    },
  );

  test(
    'automatic repair never stages inaccessible files or SAF documents',
    () async {
      for (final path in ['content://music/1', '/missing/audio/1.flac']) {
        final row = _row(1)..filePath = path;
        // No platform channel or Rust initialization: these must return before
        // any copy or parser is invoked, even for unknown source sizes.
        expect(
          await LocalMetadataRepair.probe(
            row,
            persist: false,
            allowStaging: false,
          ),
          false,
        );
      }
    },
  );

  test('explicit repair retains the staging fallback and size cap', () async {
    const channel = MethodChannel('com.mossapps.flick/storage');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null; // Provider refuses this copy; do not invoke a Rust parser.
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await LocalMetadataRepair.probe(_row(1), persist: false), false);
    expect(calls.map((call) => call.method), ['cacheUriForPlayback']);
    expect((calls.single.arguments as Map)['maxSizeBytes'], 256 * 1024 * 1024);
  });

  test(
    'desktop codec corrections and incomplete files still get inspected',
    () async {
      final rows = {
        1: (_row(1)..filePath = '/music/1.flac'),
        2: (_row(2)
          ..filePath = '/data/desktop_music/2.flac'
          ..metadataComplete = true),
        3: (_row(3)
          ..filePath = '/music/3.flac'
          ..metadataComplete = true),
      };
      final inspected = <int>[];
      final worker = LocalMetadataRepair(
        databaseReady: () => true,
        loadSong: (id) async => rows[id],
        inspect: (row) async {
          inspected.add(row.id);
          return true;
        },
        rest: (_) async {},
      );
      worker.warm([_song(1), _song(2), _song(3)]);
      await worker.idle;
      expect(inspected, [1, 2]);
    },
  );

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
