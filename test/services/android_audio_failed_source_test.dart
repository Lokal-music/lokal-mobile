import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:flick/models/song.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/services/android_audio_engine.dart';
import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/services/automix_analysis_cache.dart';
import 'package:flick/services/automix_stem_clip.dart';

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
  // Own idle streams so every subscription can be cleaned up explicitly.
  final idleStreams = <StreamController<dynamic>>[];
  Stream<T> idle<T>() {
    final controller = StreamController<T>.broadcast(sync: true);
    idleStreams.add(controller);
    return controller.stream;
  }

  double currentVolume = 1.0;
  int loads = 0, seeks = 0;
  int disposals = 0;
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
  Stream<ja.PlayerState> get playerStateStream => idle<ja.PlayerState>();
  @override
  Stream<ja.PlaybackEvent> get playbackEventStream => idle<ja.PlaybackEvent>();
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration> get bufferedPositionStream => idle<Duration>();
  @override
  Stream<Duration?> get durationStream => idle<Duration?>();
  @override
  Stream<ja.SequenceState> get sequenceStateStream => idle<ja.SequenceState>();
  @override
  Stream<int?> get currentIndexStream => idle<int?>();
  @override
  Stream<ja.ProcessingState> get processingStateStream =>
      idle<ja.ProcessingState>();
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
  Future<void> setVolume(double volume) async {
    currentVolume = volume;
  }

  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setLoopMode(ja.LoopMode mode) async {}
  @override
  Future<void> stop() async {
    currentPlaying = false;
  }

  @override
  Future<void> play() async {
    currentPlaying = true;
    playCalls++;
  }

  @override
  Future<void> pause() async {
    currentPlaying = false;
  }

  @override
  Future<void> dispose() async {
    currentPlaying = false;
    disposals++;
  }

  Future<void> closeFixture() async {
    await Future.wait([
      errors.close(),
      positions.close(),
      for (final controller in idleStreams) controller.close(),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// The fake clock advances the production load/seek deadline; stream cleanup
// also schedules real event-loop work. Drain both until the checked operation
// completes, with a bound so a regression fails instead of hanging the suite.
Future<void> finishCleanup(WidgetTester tester, Future<void> operation) async {
  var completed = false;
  operation.whenComplete(() => completed = true).ignore();
  for (var turn = 0; turn < 32 && !completed; turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(completed, true, reason: 'Decoder cleanup did not complete');
  await operation;
}

Future<void> pumpForState(WidgetTester tester, bool Function() ready) async {
  for (var turn = 0; turn < 20 && !ready(); turn++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  const resetSong = Song(
    id: 'retained',
    title: 'Retained',
    artist: 'Artist',
    duration: Duration(minutes: 3),
    fileType: 'FLAC',
    filePath: '/retained.flac',
  );

  AndroidAudioEngine guarded(
    Future<ja.AudioPlayer> Function() create, {
    Future<void> Function()? destroy,
  }) => AndroidAudioEngine(
    guardRetirement: true,
    playerProvider: create,
    sourcesBuilder: () async =>
        ja.AudioSource.uri(Uri.parse('file:///retained.flac')),
    sourceBuilder: (_) async =>
        ja.AudioSource.uri(Uri.parse('file:///retained.flac')),
    playlistProvider: () => [resetSong],
    configurePlayer: (_) async {},
    disposeEngine: destroy ?? () async {},
    shouldSuppressTrackSync: () => false,
    shouldIgnoreTrack: (_) => false,
    shouldFastStartCurrentTrackOnly: () => false,
  );

  testWidgets(
    'iPhone uses ordinary crossfade without offline model or stem decoders',
    (tester) async {
      final outgoing = _Player(), incoming = _Player();
      final songs = [
        resetSong,
        resetSong.copyWith(id: 'next', filePath: '/next.flac'),
      ];
      var profileReads = 0, stemReads = 0, stemDecoders = 0;
      final engine = AndroidAudioEngine(
        engineType: AudioEngineType.iosSystem,
        guardRetirement: true,
        playerProvider: () async => outgoing,
        secondaryPlayerProvider: () async => incoming,
        sourcesBuilder: () async =>
            ja.AudioSource.uri(Uri.file('/retained.flac')),
        sourceBuilder: (_) async => ja.AudioSource.uri(Uri.file('/next.flac')),
        playlistProvider: () => songs,
        configurePlayer: (_) async {},
        disposeEngine: outgoing.dispose,
        shouldSuppressTrackSync: () => false,
        shouldIgnoreTrack: (_) => false,
        shouldFastStartCurrentTrackOnly: () => false,
        crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
          enabled: true,
          durationSecs: 3,
          curve: AndroidCrossfadeCurve.equalPower,
        ),
        automixProfileLookup: (_) async {
          profileReads++;
          return null;
        },
        stemClipLookup: (_, _) async {
          stemReads++;
          return null;
        },
        stemPlayerProvider: () async {
          stemDecoders++;
          return _Player();
        },
        onNextSong: () => songs.last,
      );
      addTearDown(() async {
        await engine.dispose();
        await outgoing.closeFixture();
        await incoming.closeFixture();
      });
      try {
        await engine.load(songs.first);
        await engine.play();
        outgoing.positions.add(const Duration(seconds: 151));
        for (var i = 0; i < 5; i++) await tester.pump();
        expect(
          incoming.loads,
          0,
          reason: 'offline model cue times are not enabled on iPhone',
        );
        outgoing.positions.add(const Duration(seconds: 178));
        for (var i = 0; i < 6; i++) await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          incoming.playCalls,
          1,
          reason: 'ordinary two-player crossfade remains available',
        );
        expect(profileReads, 0);
        expect(stemReads, 0);
        expect(stemDecoders, 0);
      } finally {
        await engine.stop();
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
  );

  test('iPhone disposal waits for a pending native player factory', () async {
    final factory = Completer<ja.AudioPlayer>();
    final player = _Player();
    final engine = guarded(() => factory.future);
    final rejected = expectLater(
      engine.load(resetSong),
      throwsA(isA<LocalAudioRequestRetired>()),
    );
    await Future<void>.delayed(Duration.zero);
    final cleanup = engine.dispose();
    expect(identical(cleanup, engine.dispose()), isTrue);
    var cleaned = false;
    cleanup.then((_) => cleaned = true);
    await Future<void>.delayed(Duration.zero);
    expect(cleaned, isFalse);
    factory.complete(player);
    await cleanup;
    await rejected;
    expect(player.disposals, greaterThanOrEqualTo(1));
    expect(player.loads, 0);
    await player.closeFixture();
  });

  test(
    'iPhone retired source load cannot continue into configure or play',
    () async {
      final player = _Player()..hungLoad = Completer<Duration?>();
      final engine = guarded(() async => player, destroy: player.dispose);
      final rejected = expectLater(
        engine.load(resetSong),
        throwsA(isA<LocalAudioRequestRetired>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(player.loads, 1);
      await engine.dispose();
      player.hungLoad!.complete(const Duration(minutes: 3));
      await rejected;
      await expectLater(
        engine.play(),
        throwsA(isA<LocalAudioRequestRetired>()),
      );
      expect(player.disposals, 1);
      await player.closeFixture();
    },
  );

  test(
    'iPhone retirement disposes both players after a crossfade swap',
    () async {
      final primary = _Player(), incoming = _Player();
      final next = resetSong.copyWith(
        id: 'next',
        title: 'Next',
        filePath: '/next.flac',
      );
      final engine = AndroidAudioEngine(
        guardRetirement: true,
        playerProvider: () async => primary,
        secondaryPlayerProvider: () async => incoming,
        sourcesBuilder: () async =>
            ja.AudioSource.uri(Uri.parse('file:///retained.flac')),
        sourceBuilder: (_) async =>
            ja.AudioSource.uri(Uri.parse('file:///retained.flac')),
        playlistProvider: () => [resetSong, next],
        configurePlayer: (_) async {},
        disposeEngine: primary.dispose,
        shouldSuppressTrackSync: () => false,
        shouldIgnoreTrack: (_) => false,
        shouldFastStartCurrentTrackOnly: () => false,
        crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
          enabled: true,
          durationSecs: 3,
          curve: AndroidCrossfadeCurve.linear,
        ),
        onNextSong: () => next,
      );
      addTearDown(() async {
        await engine.dispose();
        await primary.closeFixture();
        await incoming.closeFixture();
      });
      Song? displayed;
      final states = engine.playbackStateStream.listen(
        (state) => displayed = state.currentTrack,
      );
      addTearDown(states.cancel);
      await engine.load(resetSong);
      await engine.play();
      primary.positions.add(const Duration(minutes: 2, seconds: 58));
      for (var turn = 0; turn < 20 && displayed?.id != next.id; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(incoming.loads, 1);
      expect(displayed?.id, next.id);
      await states.cancel();
      await engine.dispose();
      expect(primary.disposals, 1);
      expect(incoming.disposals, 1);
    },
  );

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
      await player.closeFixture();
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
    await tester.runAsync(
      () => expectLater(engine.load(song), throwsA(isA<ja.PlayerException>())),
    );
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
    await finishCleanup(tester, timedOut);
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
      await primary.closeFixture();
      await stalledFade.closeFixture();
      await nextFade.closeFixture();
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
    await finishCleanup(tester, timeout);
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
    await engine
        .stop(); // Stop the deliberately paused ramp before test invariants.
  });

  testWidgets('pausing during early preparation cannot start the fade', (
    tester,
  ) async {
    final outgoing = _Player();
    final incoming = _Player()..hungLoad = Completer<Duration?>();
    final songs = [
      const Song(
        id: 'first',
        title: 'First',
        artist: 'Artist',
        duration: Duration(minutes: 3),
        fileType: 'FLAC',
        filePath: '/first.flac',
      ),
      const Song(
        id: 'second',
        title: 'Second',
        artist: 'Artist',
        duration: Duration(minutes: 3),
        fileType: 'FLAC',
        filePath: '/second.flac',
      ),
    ];
    final engine = AndroidAudioEngine(
      playerProvider: () async => outgoing,
      secondaryPlayerProvider: () async => incoming,
      sourcesBuilder: () async =>
          ja.AudioSource.uri(Uri.parse('file:///first.flac')),
      sourceBuilder: (_) async =>
          ja.AudioSource.uri(Uri.parse('file:///second.flac')),
      playlistProvider: () => songs,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
        enabled: true,
        durationSecs: 3,
        curve: AndroidCrossfadeCurve.equalPower,
      ),
      onNextSong: () => songs.last,
    );
    addTearDown(() async {
      if (incoming.hungLoad != null && !incoming.hungLoad!.isCompleted) {
        incoming.hungLoad!.complete();
      }
      await engine.dispose();
      await outgoing.closeFixture();
      await incoming.closeFixture();
    });
    try {
      await engine.load(songs.first);
      await engine.play();
      outgoing.positions.add(const Duration(minutes: 2, seconds: 52));
      await tester.pump();
      await tester.pump();
      expect(
        incoming.loads,
        1,
        reason: 'the next decoder starts loading early',
      );
      expect(incoming.playCalls, 0);
      await engine.pause();
      await engine.play();
      expect(
        incoming.playCalls,
        0,
        reason: 'resume cannot commit a prepared-only mix',
      );
      incoming.hungLoad!.complete(const Duration(minutes: 3));
      await tester.pump();
      outgoing.positions.add(const Duration(minutes: 2, seconds: 58));
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        incoming.playCalls,
        1,
        reason: 'mix commits only in the fade window',
      );
    } finally {
      await engine.stop();
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('cached lead-in is used for a prepared local crossfade', (
    tester,
  ) async {
    final outgoing = _Player();
    final incoming = _Player();
    final songs = [
      const Song(
        id: 'first',
        title: 'First',
        artist: 'Artist',
        duration: Duration(minutes: 3),
        fileType: 'FLAC',
        filePath: '/first.flac',
      ),
      const Song(
        id: 'second',
        title: 'Second',
        artist: 'Artist',
        duration: Duration(minutes: 3),
        fileType: 'FLAC',
        filePath: '/second.flac',
      ),
    ];
    final engine = AndroidAudioEngine(
      playerProvider: () async => outgoing,
      secondaryPlayerProvider: () async => incoming,
      sourcesBuilder: () async =>
          ja.AudioSource.uri(Uri.parse('file:///first.flac')),
      sourceBuilder: (_) async =>
          ja.AudioSource.uri(Uri.parse('file:///second.flac')),
      playlistProvider: () => songs,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
        enabled: true,
        durationSecs: 3,
        curve: AndroidCrossfadeCurve.equalPower,
      ),
      automixProfileLookup: (song) async => song.id == 'second'
          ? const AutoMixProfile(
              durationSeconds: 180,
              leadInSeconds: 2,
              audibleEndSeconds: 180,
              fadeOutStartSeconds: 177,
              entrances: [],
              exits: [],
            )
          : null,
      onNextSong: () => songs.last,
    );
    addTearDown(() async {
      await engine.dispose();
      await outgoing.closeFixture();
      await incoming.closeFixture();
    });
    try {
      await engine.load(songs.first);
      await engine.play();
      outgoing.positions.add(const Duration(minutes: 2, seconds: 58));
      for (var i = 0; i < 6; i++) await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(incoming.playCalls, 1);
      expect(incoming.currentPosition, const Duration(seconds: 2));
    } finally {
      await engine.stop();
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets(
    'paired offline cues begin a prepared fade at the model overlap',
    (tester) async {
      final outgoing = _Player();
      final incoming = _Player();
      final songs = [
        const Song(
          id: 'model-out',
          title: 'Outro',
          artist: 'Artist',
          duration: Duration(minutes: 3),
          fileType: 'FLAC',
          filePath: '/out.flac',
        ),
        const Song(
          id: 'model-in',
          title: 'Intro',
          artist: 'Artist',
          duration: Duration(minutes: 3),
          fileType: 'FLAC',
          filePath: '/in.flac',
        ),
      ];
      final engine = AndroidAudioEngine(
        playerProvider: () async => outgoing,
        secondaryPlayerProvider: () async => incoming,
        sourcesBuilder: () async =>
            ja.AudioSource.uri(Uri.parse('file:///out.flac')),
        sourceBuilder: (_) async =>
            ja.AudioSource.uri(Uri.parse('file:///in.flac')),
        playlistProvider: () => songs,
        configurePlayer: (_) async {},
        disposeEngine: () async {},
        shouldSuppressTrackSync: () => false,
        shouldIgnoreTrack: (_) => false,
        shouldFastStartCurrentTrackOnly: () => false,
        crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
          enabled: true,
          durationSecs: 3,
          curve: AndroidCrossfadeCurve.equalPower,
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
      try {
        await engine.load(songs.first);
        await engine.play();
        await tester.pump(); // publish outgoing cached cue profile
        outgoing.positions.add(const Duration(seconds: 149));
        await tester.pump();
        expect(
          incoming.loads,
          0,
          reason: 'preparation starts at cue minus 8s (150s), not earlier',
        );
        outgoing.positions.add(const Duration(seconds: 151));
        for (var i = 0; i < 4; i++) await tester.pump();
        expect(incoming.loads, 1);
        expect(incoming.playCalls, 0);
        outgoing.positions.add(const Duration(seconds: 158));
        await pumpForState(tester, () => incoming.playCalls == 1);
        expect(incoming.playCalls, 1);
        expect(incoming.currentPosition, const Duration(seconds: 6));
      } finally {
        await engine.stop();
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
  );

  testWidgets(
    'verified offline stem uses third decoder then resumes next track',
    (tester) async {
      final outgoing = _Player();
      final incoming = _Player();
      final stem = _Player();
      final songs = [
        const Song(
          id: 'out',
          title: 'Outgoing',
          artist: 'A',
          duration: Duration(minutes: 3),
          filePath: '/out.flac',
          fileType: 'FLAC',
        ),
        const Song(
          id: 'in',
          title: 'Incoming',
          artist: 'B',
          duration: Duration(minutes: 3),
          filePath: '/in.flac',
          fileType: 'FLAC',
        ),
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
          enabled: true,
          durationSecs: 3,
          curve: AndroidCrossfadeCurve.equalPower,
        ),
        stemClipLookup: (_, _) async => const AutoMixStemClip(
          path: '/out.flac.lokal-stem-to-ffffffffffffffffffffffff.wav',
          outStart: 158,
          inStart: 6,
          resumeIn: 22,
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
      try {
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
        await pumpForState(tester, () => stem.playCalls == 1);
        expect(
          stem.playCalls,
          1,
          reason: 'only the mixed third decoder plays first',
        );
        expect(
          incoming.playCalls,
          0,
          reason: 'real incoming song stays muted until clip end',
        );
        await engine.pause();
        expect(stem.playing, isFalse);
        await engine.play();
        expect(stem.playing, isTrue);
        stem.positions.add(const Duration(seconds: 15, milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          incoming.seeks,
          greaterThan(1),
        ); // preload entry + exact resume seek
        expect(incoming.playCalls, greaterThan(0));
        stem.positions.add(const Duration(seconds: 16));
        await tester.pump(const Duration(milliseconds: 100));
        expect(stem.playing, isFalse);
        expect(incoming.currentVolume, closeTo(1, .001));
      } finally {
        await engine.stop();
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
  );

  testWidgets(
    'a stalled source is discarded and the next tap uses a fresh player',
    (tester) async {
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
        await stale.closeFixture();
        await healthy.closeFixture();
      });
      final first = expectLater(
        engine.load(song),
        throwsA(isA<TimeoutException>()),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 34));
      await finishCleanup(tester, first);
      expect(retired, [same(stale)]);
      await engine.load(song);
      expect(healthy.loads, 1);
      expect(stale.loads, 1);
    },
  );

  testWidgets('Discovery Repeat All never prepares unresolved native sources', (
    tester,
  ) async {
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
      await native.closeFixture();
    });
    await engine.load(first);
    expect(fullSequenceBuilds, 0);
    expect(individualBuilds, 1);
    expect(native.loads, 1);
    expect(engine.isSingleTrackOnly, isTrue);
  });

  testWidgets('asynchronous source error retires decoder for next selection', (
    tester,
  ) async {
    final firstNative = _Player();
    final replacement = _Player();
    var created = 0;
    final retired = <ja.AudioPlayer>[];
    final tracks = [
      Song(
        id: 'bad',
        title: 'Bad remote',
        artist: 'Artist',
        duration: const Duration(minutes: 2),
        fileType: 'FLAC',
        filePath: '/cache/bad.flac',
      ),
      Song(
        id: 'good',
        title: 'Next recording',
        artist: 'Artist',
        duration: const Duration(minutes: 2),
        fileType: 'FLAC',
        filePath: '/cache/good.flac',
      ),
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
      await firstNative.closeFixture();
      await replacement.closeFixture();
    });
    await engine.load(tracks.first);
    firstNative.errors.add(ja.PlayerException(0, 'Source error', 0));
    await tester.pump();
    await engine.load(tracks.last);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(created, 2);
    expect(retired, [same(firstNative)]);
    expect(replacement.loads, 1);
  });
}
