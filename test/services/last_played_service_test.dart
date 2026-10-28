import 'dart:async';
import 'dart:convert';

import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/last_played_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise the locked preference implementation's actual asynchronous boundary.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _a = Song(
  id: 'a',
  title: 'Été 音楽',
  artist: 'A',
  album: 'Local',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
);
const _b = Song(
  id: 'b',
  title: 'B',
  artist: 'B',
  album: 'Local',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
);

class _Songs implements SongRepository {
  Completer<void>? lookupGate;
  final lookupStarted = Completer<void>();
  int lookups = 0;

  @override
  Future<List<Song>> getAllSongs() async {
    lookups++;
    if (!lookupStarted.isCompleted) lookupStarted.complete();
    await lookupGate?.future;
    return [_a, _b];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();

  Completer<void>? nextWriteGate;
  final writeStarted = Completer<void>();
  bool failNextWrite = false;
  bool rejectNextWrite = false;
  final writes = <String>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(key);
    final gate = nextWriteGate;
    nextWriteGate = null;
    final fail = failNextWrite;
    failNextWrite = false;
    final reject = rejectNextWrite;
    rejectNextWrite = false;
    if (!writeStarted.isCompleted) writeStarted.complete();
    await gate?.future;
    if (fail) throw StateError('Controlled preference failure');
    if (reject) return false;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Preferences store;
  late _Songs songs;
  late LastPlayedService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = _Preferences();
    SharedPreferencesStorePlatform.instance = store;
    songs = _Songs();
    service = LastPlayedService(songRepository: songs);
  });

  Completer<void> gateNextWrite() {
    final gate = Completer<void>();
    store.nextWriteGate = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    return gate;
  }

  test('overlapping service instances persist in invocation order', () async {
    final gate = gateNextWrite();
    final first = service.saveLastPlayed('a', const Duration(seconds: 1));
    await store.writeStarted.future;
    final second = LastPlayedService(songRepository: songs).saveLastPlayed(
      'b',
      const Duration(seconds: 9),
      playlistSongIds: ['a', 'b'],
      currentIndex: 1,
      wasPlaying: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, ['flutter.last_played_snapshot_v1']);
    gate.complete();
    await Future.wait([first, second]);
    final saved = (await service.getLastPlayed())!;
    expect(saved.song.id, 'b');
    expect(saved.position, const Duration(seconds: 9));
    expect(saved.playlist!.map((s) => s.id), ['a', 'b']);
    expect(saved.playlistIndex, 1);
    expect(saved.wasPlaying, isTrue);
  });

  test('a queued save freezes its caller-owned playlist immediately', () async {
    final gate = gateNextWrite();
    final first = service.saveLastPlayed('a', Duration.zero);
    await store.writeStarted.future;
    final ids = ['a', 'b'];
    final second = service.saveLastPlayed(
      'b',
      Duration.zero,
      playlistSongIds: ids,
      currentIndex: 1,
    );
    ids.clear();
    gate.complete();
    await Future.wait([first, second]);
    expect((await service.getLastPlayed())!.playlist!.map((s) => s.id), [
      'a',
      'b',
    ]);
  });

  test('restore cannot mix a saved ID with a later cursor or queue', () async {
    await service.saveLastPlayed(
      'a',
      const Duration(seconds: 3),
      playlistSongIds: ['a', 'b'],
      currentIndex: 0,
    );
    final gate = Completer<void>();
    songs.lookupGate = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final restore = service.getLastPlayed();
    await songs.lookupStarted.future;
    await service.saveLastPlayed(
      'b',
      const Duration(seconds: 20),
      playlistSongIds: ['b'],
      currentIndex: 0,
      wasPlaying: true,
    );
    gate.complete();
    final saved = (await restore)!;
    expect(saved.song.id, 'a');
    expect(saved.position, const Duration(seconds: 3));
    expect(saved.playlist!.map((s) => s.id), ['a', 'b']);
    expect(saved.playlistIndex, 0);
    expect(saved.wasPlaying, isFalse);
  });

  test(
    'restore joins a pending complete write before library lookup',
    () async {
      final gate = gateNextWrite();
      final write = service.saveLastPlayed('b', const Duration(seconds: 7));
      await store.writeStarted.future;
      final read = service.getLastPlayed();
      await Future<void>.delayed(Duration.zero);
      expect(songs.lookups, 0);
      gate.complete();
      await write;
      expect((await read)!.position, const Duration(seconds: 7));
    },
  );

  test(
    'clear waits for an older save and cannot be resurrected by it',
    () async {
      final gate = gateNextWrite();
      final write = service.saveLastPlayed(
        'a',
        const Duration(seconds: 4),
        playlistSongIds: ['a'],
        currentIndex: 0,
        wasPlaying: true,
      );
      await store.writeStarted.future;
      final clear = LastPlayedService(songRepository: songs).clearLastPlayed();
      gate.complete();
      await Future.wait([write, clear]);
      expect(await service.getLastPlayed(), isNull);
      final all = await store.getAll();
      expect(all.keys, ['flutter.last_played_snapshot_v1']);
      expect(jsonDecode(all.values.single as String)['cleared'], isTrue);
    },
  );

  test('a newer save after Clear wins with a complete new context', () async {
    await service.saveLastPlayed(
      'a',
      const Duration(seconds: 4),
      playlistSongIds: ['a', 'b'],
      currentIndex: 0,
      wasPlaying: true,
    );
    final clear = service.clearLastPlayed();
    final write = service.saveLastPlayed('b', const Duration(seconds: 2));
    await Future.wait([clear, write]);
    final saved = (await service.getLastPlayed())!;
    expect(saved.song.id, 'b');
    expect(saved.position, const Duration(seconds: 2));
    expect(saved.playlist, isNull);
    expect(saved.playlistIndex, isNull);
    expect(saved.wasPlaying, isFalse);
  });

  test(
    'a failed write reports its error without blocking a newer save',
    () async {
      final gate = gateNextWrite();
      store.failNextWrite = true;
      final failed = service.saveLastPlayed('a', const Duration(seconds: 4));
      final checked = expectLater(failed, throwsStateError);
      await store.writeStarted.future;
      final newer = service.saveLastPlayed('b', const Duration(seconds: 8));
      gate.complete();
      await checked;
      await newer;
      final saved = (await service.getLastPlayed())!;
      expect(saved.song.id, 'b');
      expect(saved.position, const Duration(seconds: 8));
    },
  );

  test(
    'replacing a playlist without an index removes the stale index',
    () async {
      await service.saveLastPlayed(
        'a',
        Duration.zero,
        playlistSongIds: ['a', 'b', 'a'],
        currentIndex: 2,
      );
      await service.saveLastPlayed(
        'a',
        Duration.zero,
        playlistSongIds: ['a', 'a', 'b'],
      );
      final prefs = await SharedPreferences.getInstance();
      final snapshot = jsonDecode(prefs.getString('last_played_snapshot_v1')!);
      expect(snapshot['playlistIndex'], isNull);
      expect((await service.getLastPlayed())!.playlistIndex, 0);
    },
  );

  test(
    'legacy preferences retain Unicode and duplicate occurrence index',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_played_song_id', 'a');
      await prefs.setInt('last_played_position_ms', 1234);
      await prefs.setString(
        'last_played_playlist_song_ids',
        jsonEncode(['a', 'missing', 'b', 'a']),
      );
      await prefs.setInt('last_played_playlist_index', 3);
      final saved = (await service.getLastPlayed())!;
      expect(saved.song.title, 'Été 音楽');
      expect(saved.playlist!.map((s) => s.id), ['a', 'b', 'a']);
      expect(saved.position.inMilliseconds, 1234);
      // Removed library rows invalidate the old index; use a surviving match.
      expect(saved.playlistIndex, 0);
    },
  );

  test('invalid legacy playlist and negative cursor restore safely', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_played_song_id', 'a');
    await prefs.setInt('last_played_position_ms', -400);
    await prefs.setString('last_played_playlist_song_ids', '{invalid');
    final saved = (await service.getLastPlayed())!;
    expect(saved.position, Duration.zero);
    expect(saved.playlist, isNull);
  });

  test('a recording missing from the library is not restored', () async {
    await service.saveLastPlayed('missing', const Duration(seconds: 4));
    expect(await service.getLastPlayed(), isNull);
  });

  test('one platform value contains the complete recording snapshot', () async {
    await service.saveLastPlayed(
      'b',
      const Duration(seconds: 2),
      playlistSongIds: ['a', 'b'],
      currentIndex: 1,
      wasPlaying: true,
    );
    expect(store.writes, ['flutter.last_played_snapshot_v1']);
    final data = jsonDecode((await store.getAll()).values.single as String);
    expect(data, {
      'schemaVersion': 1,
      'songId': 'b',
      'positionMs': 2000,
      'wasPlaying': true,
      'playlistSongIds': ['a', 'b'],
      'playlistIndex': 1,
    });
  });

  test(
    'a rejected platform write restores the last committed cache value',
    () async {
      await service.saveLastPlayed('a', const Duration(seconds: 3));
      store.rejectNextWrite = true;
      await expectLater(
        service.saveLastPlayed('b', const Duration(seconds: 9)),
        throwsStateError,
      );
      final saved = (await service.getLastPlayed())!;
      expect(saved.song.id, 'a');
      expect(saved.position, const Duration(seconds: 3));
    },
  );

  test(
    'cleared or invalid new records never resurrect legacy preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_played_song_id', 'a');
      for (final raw in [
        '{bad',
        '{"schemaVersion":2}',
        '{"schemaVersion":1,"cleared":true}',
        '{"schemaVersion":1,"songId":"b","positionMs":false,"wasPlaying":true}',
        '{"schemaVersion":1,"songId":"b","positionMs":0,"wasPlaying":true,"playlistSongIds":[4]}',
      ]) {
        await prefs.setString('last_played_snapshot_v1', raw);
        expect(await service.getLastPlayed(), isNull, reason: raw);
      }
    },
  );

  test('failed Clear preserves the previously committed snapshot', () async {
    await service.saveLastPlayed('a', const Duration(seconds: 3));
    store.failNextWrite = true;
    await expectLater(service.clearLastPlayed(), throwsStateError);
    expect((await service.getLastPlayed())!.song.id, 'a');
  });
}
