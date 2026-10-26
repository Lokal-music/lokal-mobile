import 'package:flick/features/flow/domain/flow_codec.dart';
import 'package:flick/features/flow/domain/flow_models.dart';
import 'package:flick/features/flow/flow_controller.dart';
import 'package:flick/features/flow/flow_library.dart';
import 'package:flick/features/flow/flow_playback.dart';
import 'package:flick/features/flow/flow_store.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/providers/playlist_provider.dart';
import 'package:flick/services/playlist_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PlayerProbe extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
  void publish(PlayerState next) => state = next;
}

class _PlaybackProbe implements FlowPlayback {
  @override
  PlayerState state = const PlayerState();
  int? seed;
  int playCalls = 0;
  int nextCalls = 0;
  final appended = <Song>[];
  List<Song> lastPlaylist = [];
  @override
  bool ownsSession(int seed) => this.seed == seed;
  @override
  Future<void> play(List<Song> songs, Song first, int seed) async {
    playCalls++;
    this.seed = seed;
    lastPlaylist = songs;
    state = PlayerState(
      currentSong: first,
      isPlaying: true,
      upNext: songs.skip(songs.indexOf(first) + 1).toList(),
    );
  }

  @override
  Future<void> append(Song song) async {
    appended.add(song);
    state = state.copyWith(upNext: [...state.upNext, song]);
  }

  @override
  Future<void> next() async {
    nextCalls++;
  }

  @override
  Future<void> removeUpcoming(Set<String> ids) async {
    state = state.copyWith(
      upNext: state.upNext.where((s) => !ids.contains(s.id)).toList(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late FlowController controller;
  late _PlaybackProbe playback;
  late _PlayerProbe player;
  late FlowLibrary library;
  late PlaylistService playlists;
  String? stored;
  var failWrites = false;
  final online = <Song>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    stored = null;
    failWrites = false;
    online.clear();
    playback = _PlaybackProbe();
    player = _PlayerProbe();
    playlists = PlaylistService();
    library = FlowLibrary(
      songs: List.generate(
        60,
        (i) => Song(
          id: '$i',
          title: 'Track $i',
          artist: 'Artist ${i % 8}',
          duration: const Duration(minutes: 3),
          fileType: 'FLAC',
          filePath: '/library/$i.flac',
          genre: 'Jazz',
        ),
      ),
      favoriteIds: {for (var i = 0; i < 16; i++) '$i'},
    );
    container = ProviderContainer(
      overrides: [
        flowLibraryProvider.overrideWith((ref) async => library),
        flowStoreProvider.overrideWith(
          (ref) async => FlowStore(
            read: () async => stored,
            write: (text) async {
              if (failWrites) return false;
              stored = text;
              return true;
            },
          ),
        ),
        flowPlaybackProvider.overrideWithValue(playback),
        flowRadioProvider.overrideWithValue((seed, existing, count) async =>
            online.take(count).toList()),
        playerProvider.overrideWith(() => player),
        playlistServiceProvider.overrideWithValue(playlists),
      ],
    );
    await container.read(flowControllerProvider.future);
    controller = container.read(flowControllerProvider.notifier);
  });
  tearDown(() => container.dispose());

  test(
    'Apply persists atomically without starting or restarting playback',
    () async {
      final config = FlowConfig(mood: FlowMood.focus, discovery: .6);
      await controller.apply(config);
      expect(
        container.read(flowControllerProvider).requireValue.config,
        config,
      );
      expect(FlowCodec.decode(stored).config, config);
      expect(playback.playCalls, 0);
      failWrites = true;
      await expectLater(
        controller.apply(FlowConfig(mood: FlowMood.party)),
        throwsStateError,
      );
      expect(
        container.read(flowControllerProvider).requireValue.config,
        config,
      );
      expect(FlowCodec.decode(stored).config, config);
    },
  );

  test(
    'Play forwards real library Song instances and persists a resumable queue',
    () async {
      await controller.play();
      expect(playback.playCalls, 1);
      expect(playback.lastPlaylist.length, 5);
      expect(
        identical(
          playback.lastPlaylist.first,
          library.byId[playback.lastPlaylist.first.id],
        ),
        isTrue,
      );
      final saved = FlowCodec.decode(stored);
      expect(saved.session.trackIds, playback.lastPlaylist.map((s) => s.id));
      expect(saved.session.currentId, playback.state.currentSong!.id);
    },
  );

  test(
    'queue prefetches when four tracks remain without replay or duplicates',
    () async {
      await controller.play();
      final initial = [...playback.lastPlaylist];
      await controller.grow(onlyWhenLast: true);
      expect(playback.appended.length, 10, reason: 'prepare before queue is empty');
      playback.state = playback.state.copyWith(
        currentSong: initial.last,
        upNext: [],
      );
      await controller.grow(onlyWhenLast: true);
      expect(playback.appended.length, 20);
      expect(playback.playCalls, 1);
      expect(
        playback.appended
            .map((s) => s.id)
            .toSet()
            .intersection(initial.map((s) => s.id).toSet()),
        isEmpty,
      );
      expect(FlowCodec.decode(stored).session.trackIds.length, 25);
      playback.seed = -1;
      playback.state = playback.state.copyWith(upNext: []);
      await controller.grow(onlyWhenLast: true);
      expect(playback.appended.length, 20);
    },
  );

  test(
    'ban removes upcoming track and persists; explicit skip records only once',
    () async {
      await controller.play();
      final banned = playback.state.upNext.first;
      await controller.ban(banned);
      expect(playback.state.upNext, isNot(contains(banned)));
      expect(FlowCodec.decode(stored).bannedIds, contains(banned.id));
      final current = playback.state.currentSong!;
      player.publish(playback.state); // real observation: a start is not a skip
      await controller.skip();
      expect(FlowCodec.decode(stored).skipCounts[current.id], 1);
      expect(playback.nextCalls, 1);
      expect(FlowCodec.decode(stored).recentIds.first, current.id);
      await controller.unban(banned.id);
      expect(FlowCodec.decode(stored).bannedIds, isEmpty);
    },
  );

  test(
    'player events grow the last track even without a mounted Flow screen',
    () async {
      await controller.play();
      playback.state = playback.state.copyWith(
        currentSong: playback.lastPlaylist.last,
        upNext: [],
      );
      player.publish(playback.state);
      // Join the controller's serialized operations after the event's top-up.
      await controller.unban('not-banned');
      expect(playback.appended.length, 10);
      expect(playback.playCalls, 1);
      expect(
        FlowCodec.decode(stored).recentIds.first,
        playback.lastPlaylist.last.id,
      );
    },
  );

  test(
    'failed growth persistence cannot partially mutate the player queue',
    () async {
      await controller.play();
      playback.state = playback.state.copyWith(
        currentSong: playback.lastPlaylist.last,
        upNext: [],
      );
      failWrites = true;
      await expectLater(controller.grow(onlyWhenLast: true), throwsStateError);
      expect(playback.appended, isEmpty);
      expect(FlowCodec.decode(stored).session.trackIds.length, 5);
      failWrites = false;
      await controller.grow(onlyWhenLast: true);
      expect(playback.appended.length, 10);
    },
  );

  test(
    'save uses inherited PlaylistService, preserves order and rejects duplicate names',
    () async {
      await controller.play();
      await controller.savePlaylist('  Evening Flow  ');
      final saved = (await playlists.getPlaylists()).single;
      expect(saved.name, 'Evening Flow');
      expect(saved.songIds, playback.lastPlaylist.map((s) => s.id));
      // A fresh inherited service reads the persisted playlist, not just memory.
      expect(
        (await PlaylistService().getPlaylists()).single.songIds,
        saved.songIds,
      );
      await expectLater(
        controller.savePlaylist('evening flow'),
        throwsStateError,
      );
      expect((await playlists.getPlaylists()).length, 1);
      expect(playback.appended, isEmpty);
      expect(playback.playCalls, 1);
    },
  );

  test('Flow prefers online suggestions and keeps their session identity', () async {
    online.addAll([
      for (var i = 0; i < 10; i++)
        Song(
          id: 'pending:radio-$i',
          title: 'Online $i',
          artist: 'New artist $i',
          duration: const Duration(minutes: 3),
          fileType: 'ONLINE',
          sourcePackage: Song.pendingSourcePackage,
        ),
    ]);
    await controller.play();
    await controller.grow(onlyWhenLast: true);
    expect(playback.appended, hasLength(10));
    expect(playback.appended.every((song) => song.id.startsWith('pending:')), isTrue);
    final data = container.read(flowControllerProvider).requireValue;
    expect(data.session.trackIds, hasLength(15));
    expect(library.mix(data, DateTime.now()).length, 15);
  });

  test(
    'adapter counts only playable local favorites and keeps network tracks out',
    () {
      final local = library.songs.first;
      final filtered = FlowLibrary(
        songs: [
          local,
          local.copyWith(id: 'remote', sourceType: 'subsonic'),
          local.copyWith(id: 'external', isExternal: true),
          const Song(
            id: 'no-path',
            title: 'Absent',
            artist: 'Artist',
            duration: Duration.zero,
            fileType: 'FLAC',
          ),
        ],
        favoriteIds: {'0', 'remote', 'external', 'no-path', 'missing'},
      );
      expect(filtered.songs, [local]);
      expect(filtered.favoriteCount, 1);
      expect(filtered.unlocked, isFalse);
    },
  );
}
