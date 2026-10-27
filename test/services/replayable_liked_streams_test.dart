import 'dart:io';

import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/features/discovery/discovery_progressive_streams.dart';
import 'package:flick/features/konnekted/library/replayable_stream_songs.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/queue_pre_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Songs implements SongRepository {
  _Songs(this.songs);
  final List<Song> songs;

  @override
  Future<List<Song>> getAllSongs() async => songs;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Song _stream(String id, String source) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  album: 'Test Album',
  albumArt: 'https://example.com/art.jpg',
  duration: const Duration(minutes: 4),
  fileType: 'FLAC',
  filePath: 'expired-session-handle:$id',
  sourcePackage: source,
  isExternal: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('liking another song cannot turn existing Likes into dead streams',
      () async {
    final service = FavoritesService(songRepository: _Songs([]));
    final first = _stream('song-1', 'konnekted.morneye-live');
    final second = _stream('song-2', 'konnekted.progressive');
    await service.addFavorite(first.id, song: first);
    await service.addFavorite(second.id, song: second);

    // A heart tap invalidates FavoritesNotifier, whose next build reloads
    // persisted Song records (including previously expired stream handles).
    await service.addFavorite('song-3', song: _stream(
      'song-3', 'konnekted.morneye-live',
    ));
    final rebuilt = await FavoritesService(
      songRepository: _Songs([]),
    ).getFavorites();
    expect(rebuilt, hasLength(3));

    final resolver = QueuePreResolver();
    var lookups = 0;
    final playable = replayableStreamQueue(
      rebuilt,
      resolver: resolver,
      lookup: (track, {onStatus, cancel}) async {
        lookups++;
        return Song(
          id: 'resolved-${track.title}',
          title: track.title,
          artist: track.artist,
          duration: const Duration(minutes: 4),
          fileType: 'FLAC',
          filePath: '/fresh/audio.flac',
          isExternal: true,
        );
      },
    );
    expect(playable, everyElement(isA<Song>()));
    expect(playable.every((song) => song.isPending), isTrue);
    expect(playable.map((s) => s.id), rebuilt.map((s) => s.id));

    final a = await resolver.resolveNow(playable[0]);
    final b = await resolver.resolveNow(playable[1]);
    expect(lookups, 2);
    expect(a?.id, rebuilt[0].id);
    expect(b?.id, rebuilt[1].id);
    expect(a?.filePath, '/fresh/audio.flac');
    expect(b?.filePath, '/fresh/audio.flac');

    // A subsequent favorite refresh still registers new resolvers for
    // persisted metadata rather than reusing the short-lived handles.
    final nextRefresh = await FavoritesService(
      songRepository: _Songs([]),
    ).getFavorites();
    expect(
      replayableStreamQueue(nextRefresh, resolver: resolver)
          .every((song) => song.isPending),
      isTrue,
    );
  });

  test('does not overwrite an active Discovery source-specific resolver',
      () async {
    final resolver = QueuePreResolver();
    var sourceSpecific = 0;
    final pending = resolver.pending(
      key: 'exact-catalogue-choice',
      title: 'Precise match',
      artist: 'Artist',
      resolve: ({onStatus, cancel}) async {
        sourceSpecific++;
        return const Song(
          id: 'exact-result', title: 'Precise match', artist: 'Artist',
          duration: Duration(minutes: 2), fileType: 'FLAC',
          filePath: '/exact-selection.flac',
        );
      },
    );
    final unchanged = replayableStreamSong(
      pending,
      queueResolver: resolver,
      lookup: (track, {onStatus, cancel}) async => throw StateError(
        'Generic lookup should never replace a live exact-source resolver',
      ),
    );
    expect(identical(unchanged, pending), isTrue);
    final ready = await resolver.resolveNow(unchanged);
    expect(sourceSpecific, 1);
    expect(ready?.id, 'exact-result');
  });

  test('saved-song resolver registration survives queues longer than 500', () async {
    final resolver = QueuePreResolver();
    final pending = replayableStreamQueue(
      [for (var i = 0; i < 650; i++)
        _stream('liked-$i', 'konnekted.morneye-live')],
      resolver: resolver,
      lookup: (track, {onStatus, cancel}) async => Song(
        id: 'fresh',
        title: track.title,
        artist: track.artist,
        duration: const Duration(minutes: 4),
        fileType: 'FLAC',
        filePath: '/fresh/file.flac',
      ),
    );
    expect(pending, hasLength(650));
    final first = await resolver.resolveNow(pending.first);
    expect(first?.id, 'liked-0');
  });

  test('registered progressive HTTP stream starts without another lookup', () {
    final handle = DiscoveryProgressiveStreams.instance.register(
      Uri.parse('https://streams.example.org/song.flac'),
    );
    final current = Song(
      id: 'live-http',
      title: 'Live HTTP', artist: 'Artist',
      duration: const Duration(minutes: 2), fileType: 'FLAC',
      filePath: handle, sourcePackage: 'konnekted.progressive',
      isExternal: true,
    );
    expect(needsStreamReResolution(current), isFalse);
    expect(identical(replayableStreamSong(current), current), isTrue);
  });

  test('keeps downloaded files, local songs and true network sources', () async {
    final directory = await Directory.systemTemp.createTemp('lokal-like-');
    addTearDown(() async => directory.delete(recursive: true));
    final path = '${directory.path}/cached.flac';
    await File(path).writeAsBytes([1, 2, 3]);

    final cached = Song(
      id: 'cached', title: 'Downloaded', artist: 'Artist',
      duration: const Duration(minutes: 2), fileType: 'FLAC',
      filePath: path, sourcePackage: 'konnekted.discovery',
    );
    final local = Song(
      id: 'local', title: 'Local', artist: 'Artist',
      duration: const Duration(minutes: 2), fileType: 'FLAC',
      filePath: '/music/local.flac',
    );
    final subsonic = Song(
      id: 'remote', title: 'Remote', artist: 'Artist',
      duration: const Duration(minutes: 2), fileType: 'FLAC',
      sourceType: 'subsonic', remoteId: 'track-1',
    );
    expect(identical(replayableStreamSong(cached), cached), isTrue);
    expect(identical(replayableStreamSong(local), local), isTrue);
    expect(identical(replayableStreamSong(subsonic), subsonic), isTrue);
  });

  test('long-running Qobuz queue renews expired Morneye and HTTP sources', () async {
    final resolver = QueuePreResolver();
    var lookups = 0;
    final selected = _stream('qobuz-song', 'konnekted.morneye-live');
    final http = _stream('http-song', 'konnekted.progressive');
    final local = const Song(
      id: 'local', title: 'Local', artist: 'Artist',
      duration: Duration(minutes: 2), fileType: 'FLAC',
      filePath: '/local/complete.flac',
    );
    final prepared = replayableStreamSelection(
      selected, [selected, http, local], resolver: resolver,
      lookup: (track, {onStatus, cancel}) async {
        lookups++;
        return Song(
          id: 'new-stream', title: track.title, artist: track.artist,
          duration: const Duration(minutes: 4), fileType: 'FLAC',
          filePath: '/cache/fresh.flac',
        );
      },
    );
    expect(prepared.selected.isPending, isTrue);
    expect(identical(prepared.selected, prepared.queue.first), isTrue);
    expect(prepared.queue[1].isPending, isTrue);
    expect(identical(prepared.queue.last, local), isTrue);
    expect(await resolver.resolveNow(prepared.selected), isNotNull);
    final httpReady = await resolver.resolveNow(prepared.queue[1]);
    expect(httpReady?.id, http.id);
    expect(lookups, 2);
    expect(resolver.hasResolver(selected.id), isTrue);
    expect(resolver.hasResolver(http.id), isTrue);
  });

  test('new user selection supersedes an old recording with the same id', () {
    final previouslyQueued = _stream('same', 'konnekted.progressive');
    final replacement = const Song(
      id: 'same', title: 'New rendition', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: '/fresh/new-rendition.flac',
    );
    final result = replayableStreamSelection(
      replacement, [previouslyQueued, _stream('another', 'konnekted.morneye-live')],
      resolver: QueuePreResolver(),
      lookup: (track, {onStatus, cancel}) async => replacement,
    );
    expect(identical(result.selected, replacement), isTrue);
    expect(identical(result.queue.first, replacement), isTrue);
    expect(result.queue[1].isPending, isTrue);
  });

  test('live HTTP descriptor is retained until it actually expires', () {
    final handle = DiscoveryProgressiveStreams.instance.register(
      Uri.parse('https://cdn.example.net/audio.flac'),
    );
    final selected = Song(
      id: 'valid', title: 'Valid', artist: 'Artist',
      duration: const Duration(minutes: 4), fileType: 'FLAC',
      filePath: handle, sourcePackage: 'konnekted.progressive',
      isExternal: true,
    );
    final first = replayableStreamSelection(selected, [selected],
      resolver: QueuePreResolver());
    expect(identical(first.selected, selected), isTrue);
    DiscoveryProgressiveStreams.instance.clear();
    final stale = replayableStreamSelection(selected, [selected],
      resolver: QueuePreResolver(),
      lookup: (track, {onStatus, cancel}) async => null);
    expect(stale.selected.isPending, isTrue);
    expect(stale.queue.single.isPending, isTrue);
  });

  test('verified Atmos cannot silently fall back to stereo', () async {
    final resolver = QueuePreResolver();
    final atmos = _stream('atmos', 'konnekted.morneye-live')
        .copyWith(atmosEncoded: true);
    final pending = replayableStreamSong(
      atmos,
      queueResolver: resolver,
      lookup: (track, {onStatus, cancel}) async => Song(
        id: 'stereo', title: track.title, artist: track.artist,
        duration: const Duration(minutes: 4), fileType: 'FLAC',
        filePath: '/stereo.flac',
      ),
    );
    await expectLater(
      resolver.resolveNow(pending),
      throwsA(isA<StateError>()),
    );
  });
}
