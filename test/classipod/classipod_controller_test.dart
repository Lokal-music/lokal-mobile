import 'dart:async';
import 'dart:math' as math;

import 'package:flick/features/classipod/classipod_controller.dart';
import 'package:flick/features/classipod/classipod_data.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/player_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'classipod_fixtures.dart';

class _Service implements PlayerService {
  final recorder = RecordingPlayback();
  @override
  Future<void> play(
    Song song, {
    List<Song>? playlist,
    int? playlistIndex,
    PlaybackContext? context,
  }) => recorder.play(song, playlist!, context!);
  @override
  Future<void> togglePlayPause() => recorder.togglePlayPause();
  @override
  Future<void> next() => recorder.next();
  @override
  Future<void> previous({bool allowRestart = true}) => recorder.previous();
  @override
  Future<void> playFromQueueIndex(int index) => recorder.playQueueIndex(index);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late RecordingPlayback playback;
  late ClassipodController controller;
  setUp(() {
    playback = RecordingPlayback();
    controller = ClassipodController(playback)
      ..updateLibrary(AsyncData(ClassipodLibrary([gamma, alpha, beta])));
  });
  tearDown(() => controller.dispose());

  test(
    'wheel navigation is bounded and back restores the parent selection',
    () async {
      controller.move(-999);
      expect(controller.selected, 0);
      controller.move(999);
      expect(controller.selected, ClassipodController.menu.length - 1);
      await controller.activate(1);
      expect(controller.page, ClassipodPage.albums);
      controller.move(999);
      expect(controller.selected, 1);
      await controller.activate();
      expect(controller.title, 'Second album');
      expect(controller.tracks, [gamma]);
      expect(controller.back(), isTrue);
      expect(controller.selected, 1);
      expect(controller.back(), isTrue);
      expect(controller.selected, 1);
      expect(controller.back(), isFalse);
    },
  );

  test('songs, albums and artists hand original Songs and contextual queues to playback', () async {
    await controller.activate(0);
    await controller.activate(1);
    expect(playback.song, same(beta));
    expect(playback.queue, [alpha, beta, gamma]);
    expect(playback.context!.source, PlaybackSource.allSongs);
    expect(controller.page, ClassipodPage.nowPlaying);
    controller.back();
    controller.back();
    await controller.activate(1);
    await controller.activate(0);
    await controller.activate(0);
    expect(playback.queue, [beta, alpha]); // Existing album track ordering.
    expect(playback.song, same(beta));
    expect(playback.context!.source, PlaybackSource.album);
    controller.back();
    controller.back();
    controller.back();
    await controller.activate(2);
    await controller.activate(0);
    await controller.activate(1);
    expect(playback.queue, [alpha, beta]);
    expect(playback.context!.source, PlaybackSource.artist);
  });

  test(
    'library refresh clamps removed rows and never plays stale tracks',
    () async {
      await controller.activate(0);
      controller.move(999);
      controller.updateLibrary(AsyncData(ClassipodLibrary([alpha])));
      expect(controller.selected, 0);
      await controller.activate();
      expect(playback.song, same(alpha));
      controller.back();
      controller.updateLibrary(AsyncData(ClassipodLibrary([])));
      controller.move(10);
      await controller.activate();
      expect(controller.selected, 0);
      expect(playback.calls, ['play:alpha']);
    },
  );

  test(
    'empty/error/loading never dispatch playback and transport requires a song',
    () async {
      await controller.activate(0);
      for (final value in <AsyncValue<ClassipodLibrary>>[
        const AsyncLoading(),
        AsyncError(StateError('read failed'), StackTrace.empty),
        AsyncData(ClassipodLibrary([])),
      ]) {
        controller.updateLibrary(value);
        controller.move(-100);
        await controller.activate();
        await controller.togglePlayPause();
        await controller.next();
        await controller.previous();
        expect(controller.canSelect, isFalse);
      }
      expect(playback.calls, isEmpty);
    },
  );

  test(
    'refresh with cached data disables stale track selection until loaded',
    () async {
      var pending = Completer<ClassipodLibrary>();
      final provider = FutureProvider<ClassipodLibrary>(
        (ref) => pending.future,
      );
      final container = ProviderContainer();
      final subscription = container.listen(provider, (_, next) {
        controller.updateLibrary(next);
      }, fireImmediately: true);
      addTearDown(() {
        subscription.close();
        container.dispose();
      });
      pending.complete(ClassipodLibrary([alpha]));
      await container.read(provider.future);
      await controller.activate(0);
      expect(controller.canSelect, isTrue);
      pending = Completer<ClassipodLibrary>();
      container.invalidate(provider);
      controller.updateLibrary(container.read(provider));
      expect(controller.library.hasValue, isTrue);
      expect(controller.library.isLoading, isTrue);
      await controller.activate();
      expect(controller.canSelect, isFalse);
      expect(playback.calls, isEmpty);
      pending.complete(ClassipodLibrary([gamma]));
      await container.read(provider.future);
      await controller.activate();
      expect(playback.song, same(gamma));
    },
  );

  test(
    'busy playback is serialized; failure is visible and retry works',
    () async {
      final completer = Completer<void>();
      playback.onPlay = () => completer.future;
      await controller.activate(0);
      final playing = controller.activate(0);
      await controller.activate(1);
      expect(playback.calls, ['play:alpha']);
      expect(controller.busy, isTrue);
      completer.completeError(StateError('device unavailable'));
      await playing;
      expect(controller.playbackError, isNotNull);
      expect(controller.page, ClassipodPage.songs);
      playback.onPlay = null;
      await controller.activate(0);
      expect(controller.playbackError, isNull);
      expect(controller.page, ClassipodPage.nowPlaying);
    },
  );

  test(
    'pending playback does not force navigation after the user backs out',
    () async {
      final completer = Completer<void>();
      playback.onPlay = () => completer.future;
      await controller.activate(0);
      final pending = controller.activate(0);
      controller.back();
      completer.complete();
      await pending;
      expect(controller.page, ClassipodPage.menu);
    },
  );

  test('queue and now playing follow live state and route queue selection by index', () async {
    controller.updatePlayer(
      const PlayerState(
        currentSong: alpha,
        queue: [alpha, beta],
        currentIndex: 0,
      ),
    );
    await controller.activate(4);
    await controller.activate();
    expect(controller.page, ClassipodPage.queue);
    await controller.activate(1);
    expect(playback.calls, ['queue:1']);
    expect(controller.page, ClassipodPage.nowPlaying);
    controller.updatePlayer(
      const PlayerState(
        currentSong: beta,
        isPlaying: true,
        queue: [alpha, beta],
        currentIndex: 1,
      ),
    );
    expect(controller.player.currentSong, same(beta));
    await controller.togglePlayPause();
    await controller.next();
    await controller.previous();
    expect(playback.calls, ['queue:1', 'toggle', 'next', 'previous']);
    controller.updatePlayer(const PlayerState());
    expect(controller.canSelect, isFalse);
  });

  test('default adapter delegates actual objects to the existing PlayerService seam', () async {
    final service = _Service();
    final container = ProviderContainer(
      overrides: [playerServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final adapter = container.read(classipodPlaybackProvider);
    const context = PlaybackContext(
      source: PlaybackSource.album,
      sourceId: 'First album',
    );
    final queue = [beta, alpha];
    await adapter.play(alpha, queue, context);
    await adapter.togglePlayPause();
    await adapter.next();
    await adapter.previous();
    await adapter.playQueueIndex(1);
    expect(service.recorder.song, same(alpha));
    expect(service.recorder.queue, same(queue));
    expect(service.recorder.context, same(context));
    expect(service.recorder.calls, [
      'play:alpha',
      'toggle',
      'next',
      'previous',
      'queue:1',
    ]);
  });

  test(
    'local catalog excludes provider/handoff tracks without inventing artwork',
    () {
      final remote = alpha.copyWith(id: 'remote', sourceType: 'subsonic');
      final external = beta.copyWith(id: 'external', isExternal: true);
      final library = ClassipodLibrary([gamma, remote, beta, external, alpha]);
      expect(library.songs, [alpha, beta, gamma]);
      expect(classipodAlbumArtwork(library.albums.first), same(alpha));
    },
  );

  test('rotary tracker handles seam crossing, dead zone, and direction', () {
    final tracker = ClassipodWheelTracker();
    int at(double degrees) => tracker.update(
      90 * math.cos(degrees * math.pi / 180),
      90 * math.sin(degrees * math.pi / 180),
      100,
    );
    expect(at(170), 0);
    expect(at(-170), 0);
    expect(at(-160), 1);
    expect(at(170), -1);
    expect(tracker.update(0, 0, 100), 0);
    expect(at(0), 0);
    expect(at(90), 4);
  });
}
