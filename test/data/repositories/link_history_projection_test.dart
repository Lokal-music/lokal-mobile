import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/data/entities/recently_played_entity.dart';
import 'package:flick/data/entities/link_event_entities.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final config = File('.dart_tool/package_config.json').absolute.uri;
    final packages =
        (jsonDecode(await File.fromUri(config).readAsString())
                as Map)['packages']
            as List;
    final package = packages.cast<Map>().singleWhere(
      (row) => row['name'] == 'isar_community_flutter_libs',
    );
    final root = config.resolve('${package['rootUri']}/');
    final path = root
        .resolve(Platform.isMacOS ? 'macos/libisar.dylib' : 'linux/libisar.so')
        .toFilePath();
    expect(
      await File(path).exists(),
      true,
      reason: 'Actual native Isar core is required',
    );
    Isar.initializeIsarCore(libraries: {Abi.current(): path});
  });
  late Directory directory;
  late Isar database;
  late SongRepository songs;
  late RecentlyPlayedRepository history;
  final now = DateTime(2026, 10, 30, 12);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lokal-linked-history-');
    database = await Isar.open(
      [SongEntitySchema, RecentlyPlayedEntitySchema, PlayEventEntitySchema],
      directory: directory.path,
      name: 'linked-history',
    );
    songs = SongRepository(isar: database);
    history = RecentlyPlayedRepository(isar: database, songRepository: songs);
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });
  SongEntity song(String path, String title) => SongEntity()
    ..filePath = path
    ..title = title
    ..artist = 'Fixture'
    ..dateAdded = now;
  PlayEventEntity event(String id, String title, int ms) => PlayEventEntity()
    ..eventId = id
    ..deviceId = 'synthetic-desktop'
    ..trackKey = title
    ..playedAt = now.millisecondsSinceEpoch
    ..msPlayed = ms
    ..source = 'desktop'
    ..trackJson = jsonEncode({'title': title, 'artist': 'Fixture'});

  test(
    'replaying a projected page does not double count local or remote plays',
    () async {
      final local = song('/fixture/local.wav', 'Local');
      await songs.upsertSong(local);
      await database.writeTxn(
        () => database.playEventEntitys.putAll([
          event('local-event', 'Local', 45000),
          event('remote-event', 'Desktop only', 60000),
        ]),
      );
      final page = [
        (
          songId: local.id.toString(),
          eventId: 'local-event',
          playedAt: now,
          listenedMs: 45000,
        ),
      ];
      await history.recordLinkPlays(page);
      await history.recordLinkPlays(page);
      expect(await database.recentlyPlayedEntitys.count(), 1);
      final recap = await history.getListeningRecap(
        ListeningRecapPeriod.daily,
        now: now,
      );
      expect(recap.totalPlays, 2);
      expect(recap.totalListeningTime.inMilliseconds, 105000);
      expect(recap.topSongs.map((entry) => entry.song.title).toSet(), {
        'Local',
        'Desktop only',
      });
      // Deleting the phone recording retains the immutable event once in stats.
      await songs.deleteSongsByIds([local.id]);
      final after = await history.getListeningRecap(
        ListeningRecapPeriod.daily,
        now: now,
      );
      expect(after.totalPlays, 2);
      expect(after.totalListeningTime.inMilliseconds, 105000);
    },
  );

  test(
    'incremental title matches are capped and opaque paths round trip',
    () async {
      await songs.upsertSongs([
        for (var i = 0; i < 70; i++) song('/fixture/$i.wav', 'Same title'),
        song('/fixture/Café # %.wav', 'MixedCase'),
      ]);
      expect((await songs.getHistoryMatchCandidates('Same title')).length, 64);
      expect(
        (await songs.getHistoryMatchCandidates('mixedcase')).single.title,
        'MixedCase',
      );
      expect(await songs.getHistoryMatchCandidates(' '), isEmpty);
      expect(
        (await songs.getSongByFilePath('/fixture/Café # %.wav'))?.title,
        'MixedCase',
      );
      expect(await songs.getSongByFilePath('/fixture/missing.wav'), isNull);
    },
  );
}
