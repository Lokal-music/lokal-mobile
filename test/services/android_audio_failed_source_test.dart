import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';
import 'package:flick/services/automix_analysis_cache.dart';

class _Player implements ja.AudioPlayer {
  _Player() {
    // The mock's synchronous position stream and position getter must agree:
    // the transition planner now waits on the real media clock, not a timer.
    positions.stream.listen((value) => currentPosition = value);
  }
  Duration currentPosition = Duration.zero;
  bool currentPlaying = false;
  int playCalls = 0;
  final errors = StreamController<ja.PlayerException>.broadcast(sync: true);
  List<ja.IndexedAudioSource> sources = [];
  final positions = StreamController<Duration>.broadcast(sync: true);
  double currentVolume = 1.0;
  int loads = 0, seeks = 0;
  bool failLoad = false;
  Completer<void>? hungSeek;
  Completer<Duration?>? hungLoad;
  @override
  List<ja.IndexedAudioSource> get sequence => sources;
  @override
  int? get currentIndex => 0;
  @override
  bool get playing => currentPlaying;
  @override
  Duration get position => currentPosition;
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  Stream<ja.PlayerException> get errorStream => errors.stream;
  @override
  Stream<ja.PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<ja.PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration> get bufferedPositionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<ja.SequenceState> get sequenceStateStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
  @override
  Stream<ja.ProcessingState> get processingStateStream => const Stream.empty();
  @override
  ja.ProcessingState get processingState => ja.ProcessingState.ready;
  @override
  Future<Duration?> setAudioSource(
    ja.AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loads++;
    if (failLoad) throw ja.PlayerException(0, 'Source error', 0);
    if (hungLoad != null) return await hungLoad!.future;
    sources = [ja.AudioSource.uri(Uri.parse('file:///song.flac'))];
    currentPosition = Duration.zero;
    return duration;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks++;
    await hungSeek?.future;
    if (position != null) currentPosition = position;
  }

  @override
  double get volume => currentVolume;
  @override
  double get speed => 1;
  @override
  Future<void> setVolume(double volume) async { currentVolume = volume; }
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setLoopMode(ja.LoopMode mode) async {}
  @override
  Future<void> stop() async { currentPlaying = false; }
  @override
  Future<void> play() async { currentPlaying = true; playCalls++; }
  @override
  Future<void> pause() async { currentPlaying = false; }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('failed sources and stalled seeks cannot poison later playback', (
    tester,
  ) async {
    final player = _Player();
    final song = Song(
      id: 'song',
      title: 'Tearz',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      fileType: 'FLAC',
      filePath: '/song.flac',
    );
    final engine = AndroidAudioEngine(
      playerProvider: () async => player,
      sourcesBuilder: () async =>
          ja.AudioSource.uri(Uri.parse('file:///song.flac')),
      sourceBuilder: (_) async =>
          ja.AudioSource.uri(Uri.parse('file:///song.flac')),
      playlistProvider: () => [song],
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
    );
    addTearDown(() async {
      await engine.dispose();
      await player.errors.close();
    });
    await engine.load(song);
    await engine.load(song);
    expect(player.loads, 1); // Healthy playback can reuse its playlist.
    player.errors.add(ja.PlayerException(0, 'Source error', 0));
    await engine.load(song);
    expect(player.loads, 2); // A source error invalidates that shortcut.
    player.errors.add(ja.PlayerException(0, 'Source error', 0));
    await engine.play();
    expect(player.loads, 3); // Resume also reconstructs the failed source.
    player.errors.add(ja.PlayerException(0, 'Source error', 0));
    player.failLoad = true;
    await expectLater(engine.load(song), throwsA(isA<ja.PlayerException>()));
    player.failLoad = false;
    await engine.load(song);
    expect(player.loads, 5);
    player.hungSeek = Completer<void>();
    final timedOut = expectLater(
      engine.seek(const Duration(seconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await timedOut;
    player.hungSeek!.complete();
    player.hungSeek = null;
    await engine.load(song);
    expect(player.loads, 6);
  });
  testWidgets('crossfade timeout never aliases the provider and fade players', (
    tester,
  ) async {
    final primary = _Player();
    final stalledFade = _Player();
    final nextFade = _Player();
    final fadePlayers = [stalledFade, nextFade];
    Song? nextSong;
    var fadeCreations = 0;
    final retired = <ja.AudioPlayer>[];
    final first = Song(
      id: 'first',
      title: 'First',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      fileType: 'FLAC',
      filePath: '/first.flac',
    );
    final second = Song(
      id: 'second',
      title: 'Second',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      fileType: 'FLAC',
      filePath: '/second.flac',
    );
    nextSong = second;
    final engine = AndroidAudioEngine(
      playerProvider: () async => primary,
      secondaryPlayerProvider: () async => fadePlayers[fadeCreations++],
      sourcesBuilder: () async =>
          ja.AudioSource.uri(Uri.parse('file:///second.flac')),
      sourceBuilder: (_) async =>
          ja.AudioSource.uri(Uri.parse('file:///second.flac')),
      playlistProvider: () => [first, second],
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      retireStalledPlayer: (player) async => retired.add(player),
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
        enabled: true,
        durationSecs: 3,
        curve: AndroidCrossfadeCurve.linear,
      ),
      onNextSong: () => nextSong,
    );
    addTearDown(() async {
      stalledFade.hungLoad?.complete();
      await engine.dispose();
      await primary.positions.close();
      await stalledFade.positions.close();
      await nextFade.positions.close();
      await primary.errors.close();
      await stalledFade.errors.close();
      await nextFade.errors.close();
    });
    await engine.load(first);
    await engine.play();
    primary.positions.add(const Duration(minutes: 2, seconds: 58));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(fadeCreations, 1);
    // Crossfade has made the internally created fade player the active
    // player, while PlayerService still owns the original in _secondary.
    stalledFade.hungLoad = Completer<Duration?>();
    final timeout = expectLater(
      engine.load(second),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 34));
    await timeout;
    expect(retired, [same(stalledFade)]);

    // The surviving provider player is reused as the sole active player,
    // never simultaneously in the secondary slot.
    await engine.load(second);
    await engine.play();
    expect(primary.loads, 2);
    nextSong = first;
    primary.positions.add(const Duration(minutes: 2, seconds: 58));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(fadeCreations, 2);
    expect(nextFade.loads, 1);
  });

  testWidgets('pausing during early preparation cannot start the fade', (tester) async {
    final outgoing = _Player();
    final incoming = _Player()..hungLoad = Completer<Duration?>();
    final songs = [
      const Song(id: 'first', title: 'First', artist: 'Artist',
          duration: Duration(minutes: 3), fileType: 'FLAC',
          filePath: '/first.flac'),
      const Song(id: 'second', title: 'Second', artist: 'Artist',
          duration: Duration(minutes: 3), fileType: 'FLAC',
          filePath: '/second.flac'),
    ];
    final engine = AndroidAudioEngine(
      playerProvider: () async => outgoing,
      secondaryPlayerProvider: () async => incoming,
      sourcesBuilder: () async => ja.AudioSource.uri(Uri.parse('file:///first.flac')),
      sourceBuilder: (_) async => ja.AudioSource.uri(Uri.parse('file:///second.flac')),
      playlistProvider: () => songs,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
        enabled: true, durationSecs: 3, curve: AndroidCrossfadeCurve.equalPower,
      ),
      onNextSong: () => songs.last,
    );
    addTearDown(() async {
      if (incoming.hungLoad != null && !incoming.hungLoad!.isCompleted) {
        incoming.hungLoad!.complete();
      }
      await engine.dispose();
      await outgoing.positions.close();
      await incoming.positions.close();
      await outgoing.errors.close();
      await incoming.errors.close();
    });
    await engine.load(songs.first);
    await engine.play();
    outgoing.positions.add(const Duration(minutes: 2, seconds: 52));
    await tester.pump();
    await tester.pump();
    expect(incoming.loads, 1, reason: 'the next decoder starts loading early');
    expect(incoming.playCalls, 0);
    await engine.pause();
    await engine.play();
    expect(incoming.playCalls, 0, reason: 'resume cannot commit a prepared-only mix');
    incoming.hungLoad!.complete(const Duration(minutes: 3));
    await tester.pump();
    outgoing.positions.add(const Duration(minutes: 2, seconds: 58));
    await tester.pump(const Duration(milliseconds: 180));
    expect(incoming.playCalls, 1, reason: 'mix commits only in the fade window');
  });

  testWidgets('cached lead-in is used for a prepared local crossfade', (tester) async {
    final outgoing = _Player();
    final incoming = _Player();
    final songs = [
      const Song(id: 'first', title: 'First', artist: 'Artist',
          duration: Duration(minutes: 3), fileType: 'FLAC',
          filePath: '/first.flac'),
      const Song(id: 'second', title: 'Second', artist: 'Artist',
          duration: Duration(minutes: 3), fileType: 'FLAC',
          filePath: '/second.flac'),
    ];
    final engine = AndroidAudioEngine(
      playerProvider: () async => outgoing,
      secondaryPlayerProvider: () async => incoming,
      sourcesBuilder: () async => ja.AudioSource.uri(Uri.parse('file:///first.flac')),
      sourceBuilder: (_) async => ja.AudioSource.uri(Uri.parse('file:///second.flac')),
      playlistProvider: () => songs,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
        enabled: true, durationSecs: 3, curve: AndroidCrossfadeCurve.equalPower,
      ),
      automixProfileLookup: (song) async => song.id == 'second'
          ? const AutoMixProfile(
              durationSeconds: 180, leadInSeconds: 2,
              audibleEndSeconds: 180, fadeOutStartSeconds: 177,
              entrances: [], exits: [],
            )
          : null,
      onNextSong: () => songs.last,
    );
    addTearDown(() async {
      await engine.dispose();
      await outgoing.positions.close();
      await incoming.positions.close();
      await outgoing.errors.close();
      await incoming.errors.close();
    });
    await engine.load(songs.first);
    await engine.play();
    outgoing.positions.add(const Duration(minutes: 2, seconds: 58));
    for (var i = 0; i < 6; i++) await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(incoming.playCalls, 1);
    expect(incoming.currentPosition, const Duration(seconds: 2));
  });

  testWidgets('a stalled source is discarded and the next tap uses a fresh player', (
    tester,
  ) async {
    final stale = _Player()..hungLoad = Completer<Duration?>();
    final healthy = _Player();
    var active = stale;
    final retired = <ja.AudioPlayer>[];
    final song = Song(
      id: 'recovery',
      title: 'Recovered',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      fileType: 'FLAC',
      filePath: '/song.flac',
    );
    final engine = AndroidAudioEngine(
      playerProvider: () async => active,
      sourcesBuilder: () async =>
          ja.AudioSource.uri(Uri.parse('file:///song.flac')),
      sourceBuilder: (_) async =>
          ja.AudioSource.uri(Uri.parse('file:///song.flac')),
      playlistProvider: () => [song],
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      retireStalledPlayer: (player) async {
        retired.add(player);
        active = healthy;
      },
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
    );
    addTearDown(() async {
      stale.hungLoad?.complete();
      await engine.dispose();
      await stale.errors.close();
      await healthy.errors.close();
    });
    final first = expectLater(engine.load(song), throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 34));
    await first;
    expect(retired, [same(stale)]);
    await engine.load(song);
    expect(healthy.loads, 1);
    expect(stale.loads, 1);
  });

  testWidgets('Discovery Repeat All never prepares unresolved native sources', (tester) async {
    final native = _Player();
    var fullSequenceBuilds = 0;
    var individualBuilds = 0;
    final first = Song(
      id: 'discovery-first',
      title: 'Playing discovery song',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      fileType: 'FLAC',
      filePath: '/cached/first.flac',
    );
    final queued = [
      first,
      for (var i = 0; i < 29; i++)
        Song(
          id: 'pending:$i',
          title: 'Next track $i',
          artist: 'Artist',
          duration: Duration.zero,
          fileType: 'ONLINE',
          sourcePackage: Song.pendingSourcePackage,
        ),
    ];
    expect(hasUnresolvedAudioSources(queued), isTrue);

    final engine = AndroidAudioEngine(
      playerProvider: () async => native,
      sourcesBuilder: () async {
        fullSequenceBuilds++;
        throw StateError('Pending URL was passed to native player');
      },
      sourceBuilder: (_) async {
        individualBuilds++;
        return ja.AudioSource.uri(Uri.parse('file:///cached/first.flac'));
      },
      playlistProvider: () => queued,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      // Repeat All used to force constructing the full 30-item native queue.
      shouldFastStartCurrentTrackOnly: () => false,
    );
    addTearDown(() async {
      await engine.dispose();
      await native.errors.close();
      await native.positions.close();
    });
    await engine.load(first);
    expect(fullSequenceBuilds, 0);
    expect(individualBuilds, 1);
    expect(native.loads, 1);
    expect(engine.isSingleTrackOnly, isTrue);
  });

  testWidgets('asynchronous source error retires decoder for next selection', (tester) async {
    final firstNative = _Player();
    final replacement = _Player();
    var created = 0;
    final retired = <ja.AudioPlayer>[];
    final tracks = [
      Song(id: 'bad', title: 'Bad remote', artist: 'Artist',
          duration: const Duration(minutes: 2), fileType: 'FLAC',
          filePath: '/cache/bad.flac'),
      Song(id: 'good', title: 'Next recording', artist: 'Artist',
          duration: const Duration(minutes: 2), fileType: 'FLAC',
          filePath: '/cache/good.flac'),
    ];
    final engine = AndroidAudioEngine(
      playerProvider: () async => created++ == 0 ? firstNative : replacement,
      sourcesBuilder: () async =>
          ja.AudioSource.uri(Uri.parse('file:///cache/bad.flac')),
      sourceBuilder: (_) async =>
          ja.AudioSource.uri(Uri.parse('file:///cache/good.flac')),
      playlistProvider: () => tracks,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      retireStalledPlayer: (player) async => retired.add(player),
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
    );
    addTearDown(() async {
      await engine.dispose();
      await firstNative.errors.close();
      await replacement.errors.close();
      await firstNative.positions.close();
      await replacement.positions.close();
    });
    await engine.load(tracks.first);
    firstNative.errors.add(ja.PlayerException(0, 'Source error', 0));
    await tester.pump();
    await engine.load(tracks.last);
    expect(created, 2);
    expect(retired, [same(firstNative)]);
    expect(replacement.loads, 1);
  });

}
