import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';
import 'package:flick/services/automix_analysis_cache.dart';
import 'package:flick/services/automix_stem_clip.dart';

class _Player implements ja.AudioPlayer {
  _Player() {
    // The mock's synchronous position stream and position getter must agree:
    // the transition planner now waits on the real media clock, not a timer.
    positions.stream.listen((value) => currentPosition = value);
  }
  Duration currentPosition = Duration.zero;
  Duration? currentDuration = const Duration(minutes: 3);
  int? activeIndex = 0;
  bool currentPlaying = false;
  int playCalls = 0;
  final errors = StreamController<ja.PlayerException>.broadcast(sync: true);
  List<ja.IndexedAudioSource> sources = [];
  final positions = StreamController<Duration>.broadcast(sync: true);
  final indices = StreamController<int?>.broadcast(sync: true);
  final durations = StreamController<Duration?>.broadcast(sync: true);
  final processing = StreamController<ja.ProcessingState>.broadcast(sync: true);
  double currentVolume = 1.0;
  int loads = 0, seeks = 0;
  int? lastInitialIndex;
  int? lastSeekIndex;
  bool failLoad = false;
  Completer<void>? hungSeek;
  Completer<Duration?>? hungLoad;
  @override
  List<ja.IndexedAudioSource> get sequence => sources;
  @override
  int? get currentIndex => activeIndex;
  @override
  bool get playing => currentPlaying;
  @override
  Duration get position => currentPosition;
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  Duration? get duration => currentDuration;
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
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<ja.SequenceState> get sequenceStateStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => indices.stream;
  @override
  Stream<ja.ProcessingState> get processingStateStream => processing.stream;
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
    lastInitialIndex = initialIndex;
    if (failLoad) throw ja.PlayerException(0, 'Source error', 0);
    if (hungLoad != null) return await hungLoad!.future;
    sources = [ja.AudioSource.uri(Uri.parse('file:///song.flac'))];
    currentPosition = Duration.zero;
    return duration;
  }

  @override
  Future<void> addAudioSource(ja.AudioSource source) async {
    sources.add(source as ja.IndexedAudioSource);
  }

  @override
  Future<void> removeAudioSourceRange(int start, int end) async {
    sources.removeRange(start, end);
    if (activeIndex != null && activeIndex! >= end) {
      activeIndex = activeIndex! - (end - start);
    } else if (activeIndex != null && activeIndex! >= start) {
      activeIndex = start.clamp(0, sources.length - 1);
    }
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks++;
    lastSeekIndex = index;
    await hungSeek?.future;
    if (position != null) currentPosition = position;
    if (index != null) activeIndex = index;
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
  Future<void> dispose() async { currentPlaying = false; }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('entering on-demand mode trims a restored native queue '
      'without changing the audible song', (tester) async {
    final a = const Song(
      id: 'a', title: 'A', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: '/a.flac',
    );
    final b = const Song(
      id: 'b', title: 'B', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: '/b.flac',
    );
    final c = const Song(
      id: 'c', title: 'C', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: '/c.flac',
    );
    final logical = [a, b, c];
    final player = _Player();
    var nativeIndexUpdates = 0;
    final engine = AndroidAudioEngine(
      playerProvider: () async => player,
      sourcesBuilder: () async => ja.ConcatenatingAudioSource(
        children: [
          for (final song in logical) ja.AudioSource.uri(Uri.file(song.filePath!)),
        ],
      ),
      sourceBuilder: (song) async =>
          ja.AudioSource.uri(Uri.file(song.filePath!)),
      playlistProvider: () => logical,
      selectedPlaylistIndexProvider: () => 1,
      onNativePlaylistIndex: (_) => nativeIndexUpdates++,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => true,
    );
    addTearDown(() async {
      await engine.dispose();
      await player.errors.close();
      await player.positions.close();
      await player.indices.close();
      await player.durations.close();
      await player.processing.close();
    });

    await engine.load(b);
    player.sources = [
      for (final song in logical) ja.AudioSource.uri(Uri.file(song.filePath!)),
    ];
    player.activeIndex = 1;
    player.currentPosition = const Duration(seconds: 35);
    player.currentPlaying = true;
    // The player was expanded via restoreFastStartPlaylist, so PlayerService
    // has no corresponding ConcatenatingAudioSource to trim.
    expect(await engine.enterOnDemandQueueMode(), isTrue);
    expect(player.sources, hasLength(1));
    expect(player.activeIndex, 0);
    expect(player.currentPosition, const Duration(seconds: 35));
    expect(player.currentPlaying, isTrue);
    expect(engine.isSingleTrackOnly, isTrue);
    final before = nativeIndexUpdates;
    logical..clear()..addAll([c, b, a]); // logical shuffle
    player.indices.add(0);
    await tester.pump();
    expect(nativeIndexUpdates, before,
        reason: 'single-source native index is not a logical queue index');
  });

  test('resolved online handles force on-demand mode even in a tiny queue', () {
    const progressive = Song(
      id: 'http', title: 'HTTP', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: 'lokal-progressive://playback-123',
      sourcePackage: 'konnekted.progressive',
    );
    const morneye = Song(
      id: 'morneye', title: 'Live', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: 'morneye-live://handle',
      sourcePackage: 'konnekted.morneye-live',
    );
    expect(requiresOnDemandAndroidSequence([progressive]), isTrue);
    expect(requiresOnDemandAndroidSequence([morneye]), isTrue);
  });

  testWidgets('on-demand gapless preloads one source and maps logical indices',
      (tester) async {
    final library = List<Song>.generate(
      80,
      (i) => Song(
        id: 'song-$i', title: 'Recording $i', artist: 'Artist',
        duration: const Duration(minutes: 3), fileType: 'FLAC',
        filePath: '/music/song-$i.flac',
      ),
    );
    final player = _Player();
    var logicalIndex = 30;
    var sourcesBuilt = 0;
    final played = <Song>[];
    final engine = AndroidAudioEngine(
      playerProvider: () async => player,
      sourcesBuilder: () async =>
          throw StateError('Do not construct the whole large playlist'),
      sourceBuilder: (song) async {
        sourcesBuilt++;
        return ja.AudioSource.uri(Uri.file(song.filePath!));
      },
      playlistProvider: () => library,
      selectedPlaylistIndexProvider: () => logicalIndex,
      onNativePlaylistIndex: (i) => logicalIndex = i,
      onNextSong: () => logicalIndex + 1 < library.length
          ? library[logicalIndex + 1] : null,
      gaplessEnabledProvider: () => true,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
    );
    final subscription = engine.playbackStateStream.listen((state) {
      if (state.currentTrack != null) played.add(state.currentTrack!);
    });
    addTearDown(() async {
      await subscription.cancel();
      await engine.dispose();
      await player.errors.close();
      await player.positions.close();
      await player.indices.close();
      await player.durations.close();
      await player.processing.close();
    });

    await engine.load(library[30]);
    await tester.pump();
    await tester.pump();
    expect(player.sources.length, 2);
    expect(sourcesBuilt, 2);
    expect(engine.isSingleTrackOnly, isTrue,
        reason: 'logical queue still uses manual end-of-list completion');

    player.activeIndex = 1;
    player.indices.add(1);
    await tester.pump();
    await tester.pump();
    expect(logicalIndex, 31);
    expect(played.last.id, 'song-31');
    expect(player.sources.length, 3);
    expect(sourcesBuilt, 3);

    // Advance far enough to require dropping already played slots. The
    // full 80-item Library must never be materialized in Media3.
    for (var i = 32; i <= 46; i++) {
      player.activeIndex = player.sources.length - 1;
      player.indices.add(player.activeIndex);
      await tester.pump();
      await tester.pump();
      expect(logicalIndex, i);
    }
    expect(player.sources.length, lessThan(16));
    expect(sourcesBuilt, 18);
    expect(played.last.id, 'song-46');
  });

  testWidgets('on-demand queue mutation invalidates stale native successor',
      (tester) async {
    final songs = List<Song>.generate(
      70,
      (index) => Song(
        id: 'track-$index',
        title: 'Track $index',
        artist: 'Artist',
        duration: const Duration(minutes: 3),
        fileType: 'FLAC',
        filePath: '/music/$index.flac',
      ),
    );
    final player = _Player();
    var allowNext = true;
    final engine = AndroidAudioEngine(
      playerProvider: () async => player,
      sourcesBuilder: () async => throw StateError('Must use fast-start'),
      sourceBuilder: (song) async =>
          ja.AudioSource.uri(Uri.file(song.filePath!)),
      playlistProvider: () => songs,
      selectedPlaylistIndexProvider: () => 0,
      onNextSong: () => allowNext ? songs[1] : null,
      gaplessEnabledProvider: () => true,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
    );
    addTearDown(() async {
      await engine.dispose();
      await player.errors.close();
      await player.positions.close();
      await player.indices.close();
      await player.durations.close();
      await player.processing.close();
    });
    await engine.load(songs.first);
    await tester.pump();
    expect(player.sources.length, 2);

    // Stop After Current must remove the native child before Media3 can
    // advance into an already prepared successor.
    allowNext = false;
    await engine.invalidateOnDemandGaplessSuccessor();
    await tester.pump();
    expect(player.sources.length, 1);

    // Queue edit: the new logical successor must replace the old native one.
    songs[1] = Song(
      id: 'replacement', title: 'Replacement', artist: 'Artist',
      duration: const Duration(minutes: 3), fileType: 'FLAC',
      filePath: '/music/replacement.flac',
    );
    allowNext = true;
    await engine.invalidateOnDemandGaplessSuccessor();
    await tester.pump();
    expect(player.sources.length, 2);
  });

  test('large Library queues prepare only the tapped track', () async {
    final library = List<Song>.generate(
      2654,
      (i) => Song(
        id: 'song-$i', title: 'Recording $i', artist: 'Artist',
        duration: const Duration(minutes: 3), fileType: 'FLAC',
        filePath: '/music/song-$i.flac',
      ),
    );
    expect(hasUnresolvedAudioSources(library), isFalse);
    expect(requiresOnDemandAndroidSequence(library), isTrue);
    final player = _Player();
    var nativeSequenceBuilds = 0;
    var singleSourceBuilds = 0;
    final engine = AndroidAudioEngine(
      playerProvider: () async => player,
      sourcesBuilder: () async {
        nativeSequenceBuilds++;
        throw StateError('The complete Library must not be materialized');
      },
      sourceBuilder: (song) async {
        singleSourceBuilds++;
        return ja.AudioSource.uri(Uri.file(song.filePath!));
      },
      playlistProvider: () => library,
      selectedPlaylistIndexProvider: () => 1730,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
    );
    addTearDown(() async {
      await engine.dispose();
      await player.errors.close();
      await player.positions.close();
      await player.indices.close();
      await player.durations.close();
      await player.processing.close();
    });

    await engine.load(library[1730]);
    expect(nativeSequenceBuilds, 0);
    expect(singleSourceBuilds, 1);
    expect(engine.isSingleTrackOnly, isTrue);
    expect(
      await engine.restoreFastStartPlaylist(isCurrent: () => true),
      isFalse,
    );
    expect(singleSourceBuilds, 1,
        reason: 'No background restore across thousands of library songs');
  });

  test('remote songs stay on demand, small local queues retain native sequence', () {
    const local = Song(
      id: 'local', title: 'Local', artist: 'A',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: '/music/local.flac',
    );
    const desktop = Song(
      id: 'desktop', title: 'PC only', artist: 'A',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: 'lokal://1/abc', sourceType: 'lokal',
      remoteId: 'abc', remoteServerId: 1,
    );
    expect(requiresOnDemandAndroidSequence([local, desktop]), isTrue);
    expect(requiresOnDemandAndroidSequence([local, local]), isFalse);
  });

  testWidgets('native Android playback uses the selected duplicate occurrence',
      (tester) async {
    // Different entries can have the same ID and source path; identity alone
    // must not snap the selected song back to the first occurrence.
    final first = Song(
      id: 'repeated', title: 'Repeat', artist: 'Artist',
      duration: const Duration(minutes: 3),
      filePath: '/repeat.flac', fileType: 'FLAC',
    );
    final second = Song(
      id: 'repeated', title: 'Repeat', artist: 'Artist',
      duration: const Duration(minutes: 3),
      filePath: '/repeat.flac', fileType: 'FLAC',
    );
    final between = Song(
      id: 'different', title: 'Other', artist: 'Artist',
      duration: const Duration(minutes: 3),
      filePath: '/other.flac', fileType: 'FLAC',
    );
    final playlist = [first, between, second];
    final player = _Player();
    final nativeIndices = <int>[];
    final engine = AndroidAudioEngine(
      playerProvider: () async => player,
      sourcesBuilder: () async => ja.ConcatenatingAudioSource(
        children: [
          for (final song in playlist)
            ja.AudioSource.uri(Uri.file(song.filePath!)),
        ],
      ),
      sourceBuilder: (song) async =>
          ja.AudioSource.uri(Uri.file(song.filePath!)),
      playlistProvider: () => playlist,
      selectedPlaylistIndexProvider: () => 2,
      onNativePlaylistIndex: nativeIndices.add,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
    );
    addTearDown(() async {
      await engine.dispose();
      await player.errors.close();
      await player.positions.close();
      await player.indices.close();
      await player.durations.close();
      await player.processing.close();
    });

    await engine.load(second);
    expect(player.lastInitialIndex, 2,
        reason: 'native source preparation must select second occurrence');
    expect(player.lastSeekIndex, 2,
        reason: 'the initial seek must use the exact queue index');

    // Index changes must also reach PlayerService even when two adjacent
    // sequence entries represent identical logical tracks.
    player.sources = [
      for (final song in playlist)
        ja.AudioSource.uri(Uri.file(song.filePath!)),
    ];
    player.activeIndex = 1;
    player.indices.add(1);
    await tester.pump();
    expect(nativeIndices, contains(1));
    player.activeIndex = 2;
    player.indices.add(2);
    await tester.pump();
    expect(nativeIndices.last, 2);
  });

  testWidgets('native playlist auto-advance rejects a 30-second HTTP item',
      (tester) async {
    final player = _Player();
    final first = const Song(
      id: 'first', title: 'Local', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: '/first.flac',
    );
    final preview = const Song(
      id: 'second', title: 'Qobuz full track', artist: 'Artist',
      duration: Duration(minutes: 4), fileType: 'FLAC',
      sourcePackage: 'konnekted.progressive',
      filePath: 'lokal-progressive://123',
    );
    final failed = <Song>[];
    var completed = 0;
    final engine = AndroidAudioEngine(
      playerProvider: () async => player,
      sourcesBuilder: () async => ja.ConcatenatingAudioSource(children: [
        ja.AudioSource.uri(Uri.file('/first.flac')),
        ja.AudioSource.uri(Uri.parse('https://cdn.example/preview.flac')),
      ]),
      sourceBuilder: (_) async =>
          ja.AudioSource.uri(Uri.file('/first.flac')),
      playlistProvider: () => [first, preview],
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      onTrackError: failed.add,
    )..onTrackEnded = () => completed++;
    addTearDown(() async {
      await engine.dispose();
      await player.positions.close();
      await player.indices.close();
      await player.durations.close();
      await player.processing.close();
      await player.errors.close();
    });
    await engine.load(first);
    final firstSource = ja.AudioSource.uri(Uri.file('/first.flac'));
    firstSource.duration = const Duration(minutes: 3);
    final previewSource =
        ja.AudioSource.uri(Uri.parse('https://cdn.example/preview.flac'));
    previewSource.duration = const Duration(seconds: 30);
    player.sources = [firstSource, previewSource];
    player.activeIndex = 1;
    player.currentDuration = const Duration(seconds: 30);
    player.indices.add(1);
    await tester.pump();
    expect(failed.map((s) => s.id), ['second']);
    player.processing.add(ja.ProcessingState.completed);
    await tester.pump();
    expect(completed, 0, reason: 'a preview must never advance the queue');
    expect(player.currentPlaying, isFalse);
  });

  testWidgets('a 30-second crossfade candidate is rejected before handoff',
      (tester) async {
    final outgoing = _Player();
    final incoming = _Player()
      ..currentDuration = const Duration(seconds: 30);
    final first = const Song(
      id: 'first', title: 'Local', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'FLAC',
      filePath: '/first.flac',
    );
    final next = const Song(
      id: 'second', title: 'Qobuz full track', artist: 'Artist',
      duration: Duration(minutes: 4), fileType: 'FLAC',
      sourcePackage: 'konnekted.progressive',
      filePath: 'lokal-progressive://456',
    );
    final advanced = <Song>[];
    final engine = AndroidAudioEngine(
      playerProvider: () async => outgoing,
      secondaryPlayerProvider: () async => incoming,
      sourcesBuilder: () async =>
          ja.AudioSource.uri(Uri.file('/first.flac')),
      sourceBuilder: (_) async =>
          ja.AudioSource.uri(Uri.parse('https://cdn.example/preview.flac')),
      playlistProvider: () => [first, next],
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
        enabled: true, durationSecs: 3, curve: AndroidCrossfadeCurve.linear,
      ),
      onNextSong: () => next,
      onTrackAdvanced: advanced.add,
    );
    addTearDown(() async {
      await engine.dispose();
      await outgoing.positions.close();
      await incoming.positions.close();
      await outgoing.indices.close();
      await incoming.indices.close();
      await outgoing.durations.close();
      await incoming.durations.close();
      await outgoing.processing.close();
      await incoming.processing.close();
      await outgoing.errors.close();
      await incoming.errors.close();
    });
    await engine.load(first);
    await engine.play();
    outgoing.positions.add(const Duration(minutes: 2, seconds: 58));
    for (var i = 0; i < 8; i++) await tester.pump();
    expect(incoming.loads, 1);
    expect(incoming.playCalls, 0);
    expect(advanced, isEmpty);
    expect(outgoing.currentPlaying, isTrue);
  });

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

  testWidgets('paired offline cues begin a prepared fade at the model overlap', (tester) async {
    final outgoing = _Player();
    final incoming = _Player();
    final songs = [
      const Song(id: 'model-out', title: 'Outro', artist: 'Artist',
          duration: Duration(minutes: 3), fileType: 'FLAC',
          filePath: '/out.flac'),
      const Song(id: 'model-in', title: 'Intro', artist: 'Artist',
          duration: Duration(minutes: 3), fileType: 'FLAC',
          filePath: '/in.flac'),
    ];
    final engine = AndroidAudioEngine(
      playerProvider: () async => outgoing,
      secondaryPlayerProvider: () async => incoming,
      sourcesBuilder: () async => ja.AudioSource.uri(Uri.parse('file:///out.flac')),
      sourceBuilder: (_) async => ja.AudioSource.uri(Uri.parse('file:///in.flac')),
      playlistProvider: () => songs,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
        enabled: true, durationSecs: 3, curve: AndroidCrossfadeCurve.equalPower,
      ),
      automixProfileLookup: (song) async => AutoMixProfile(
        durationSeconds: 180,
        leadInSeconds: 0,
        audibleEndSeconds: 180,
        fadeOutStartSeconds: 177,
        entrances: const [],
        exits: const [],
        modelExits: song.id == 'model-out' ? const [158] : const [],
        modelEntrances: song.id == 'model-in' ? const [6] : const [],
      ),
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
    await tester.pump(); // publish outgoing cached cue profile
    outgoing.positions.add(const Duration(seconds: 149));
    await tester.pump();
    expect(incoming.loads, 0, reason: 'preparation starts at cue minus 8s (150s), not earlier');
    outgoing.positions.add(const Duration(seconds: 151));
    for (var i = 0; i < 4; i++) await tester.pump();
    expect(incoming.loads, 1);
    expect(incoming.playCalls, 0);
    outgoing.positions.add(const Duration(seconds: 158));
    await tester.pump(const Duration(milliseconds: 200));
    expect(incoming.playCalls, 1);
    expect(incoming.currentPosition, const Duration(seconds: 6));
  });

  testWidgets('verified offline stem uses third decoder then resumes next track', (tester) async {
    final outgoing = _Player();
    final incoming = _Player();
    final stem = _Player();
    final songs = [
      const Song(id: 'out', title: 'Outgoing', artist: 'A',
          duration: Duration(minutes: 3), filePath: '/out.flac', fileType: 'FLAC'),
      const Song(id: 'in', title: 'Incoming', artist: 'B',
          duration: Duration(minutes: 3), filePath: '/in.flac', fileType: 'FLAC'),
    ];
    Song? next = songs.last;
    final engine = AndroidAudioEngine(
      playerProvider: () async => outgoing,
      secondaryPlayerProvider: () async => incoming,
      stemPlayerProvider: () async => stem,
      sourcesBuilder: () async => ja.AudioSource.uri(Uri.file('/out.flac')),
      sourceBuilder: (_) async => ja.AudioSource.uri(Uri.file('/in.flac')),
      playlistProvider: () => songs,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
        enabled: true, durationSecs: 3, curve: AndroidCrossfadeCurve.equalPower,
      ),
      stemClipLookup: (_, _) async => const AutoMixStemClip(
        path: '/out.flac.lokal-stem-to-ffffffffffffffffffffffff.wav',
        outStart: 158, inStart: 6, resumeIn: 22,
        durationSeconds: 16,
      ),
      onNextSong: () => next,
    );
    addTearDown(() async {
      await engine.dispose();
      for (final player in [outgoing, incoming, stem]) {
        await player.positions.close();
        await player.errors.close();
      }
    });
    await engine.load(songs.first);
    await engine.play();
    outgoing.positions.add(const Duration(seconds: 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // Clip report is available before the source window starts.
    outgoing.positions.add(const Duration(seconds: 150));
    for (var i = 0; i < 5; i++) await tester.pump();
    outgoing.positions.add(const Duration(seconds: 158));
    await tester.pump(const Duration(milliseconds: 200));
    expect(stem.playCalls, 1, reason: 'only the mixed third decoder plays first');
    expect(incoming.playCalls, 0, reason: 'real incoming song stays muted until clip end');
    await engine.pause();
    expect(stem.playing, isFalse);
    await engine.play();
    expect(stem.playing, isTrue);
    stem.positions.add(const Duration(seconds: 15, milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(incoming.seeks, greaterThan(1)); // preload entry + exact resume seek
    expect(incoming.playCalls, greaterThan(0));
    stem.positions.add(const Duration(seconds: 16));
    await tester.pump(const Duration(milliseconds: 100));
    expect(stem.playing, isFalse);
    expect(incoming.currentVolume, closeTo(1, .001));
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
