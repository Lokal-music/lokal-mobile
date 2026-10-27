import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/queue/screens/queue_screen.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Song _track(String id) => Song(
  id: id, title: 'Track $id', artist: 'Artist $id',
  duration: const Duration(minutes: 3), fileType: 'FLAC',
);

class _QueuePlayer extends PlayerNotifier {
  final upcomingMoves = <(int, int)>[];
  final manualMoves = <(int, int)>[];

  @override
  PlayerState build() => PlayerState(
    currentSong: _track('playing'),
    upNext: [_track('a'), _track('b'), _track('c')],
    queue: [_track('d'), _track('e'), _track('f')],
  );

  @override
  Future<void> moveUpNextItem(int from, int to) async {
    upcomingMoves.add((from, to));
    final songs = [...state.upNext];
    songs.insert(to, songs.removeAt(from));
    state = state.copyWith(upNext: songs);
  }

  @override
  Future<void> moveQueueItem(int from, int to) async {
    manualMoves.add((from, to));
    final songs = [...state.queue];
    songs.insert(to, songs.removeAt(from));
    state = state.copyWith(queue: songs);
  }

  List<String> get upcomingIds => state.upNext.map((s) => s.id).toList();
  List<String> get manualIds => state.queue.map((s) => s.id).toList();
}

Future<void> _drag(WidgetTester tester, String key, double dy) async {
  final grip = find.byKey(ValueKey(key));
  await tester.ensureVisible(grip);
  await tester.pump();
  final gesture = await tester.startGesture(tester.getCenter(grip));
  await tester.pump(const Duration(milliseconds: 40));
  await gesture.moveBy(Offset(0, dy));
  await tester.pump(const Duration(milliseconds: 250));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  test('queue drop positions use one pre-removal normalization', () {
    expect(queueDropIndex(0, 2, 3), 1);
    expect(queueDropIndex(0, 3, 3), 2);
    expect(queueDropIndex(2, 0, 3), 0);
    expect(queueDropIndex(1, 1, 3), 1);
  });

  test('row keys remain unique across moves and repeated songs', () {
    final songs = [_track('a'), _track('b'), _track('a'), _track('c')];
    final first = queueRowIdentities(songs, 'next');
    final moved = queueRowIdentities([songs[1], songs[0], songs[2], songs[3]], 'next');
    expect(first.toSet(), hasLength(4));
    expect(moved.toSet(), hasLength(4));
    expect(first[0], moved[1]);
    expect(first[1], moved[0]);
    expect(first[2], moved[2]);
  });

  for (final embedded in [false, true]) {
    testWidgets('${embedded ? 'full-player' : 'standalone'} queue drags playback order in both directions',
        (tester) async {
      tester.view.physicalSize = const Size(440, 1024);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = _QueuePlayer();
      await tester.pumpWidget(ProviderScope(
        overrides: [playerProvider.overrideWith(() => player)],
        child: MaterialApp(
          theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
          home: Scaffold(body: QueueList(embedded: embedded)),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Queue'), findsOneWidget);
      expect(find.text('Manual queue'), findsNothing,
          reason: 'Manual songs must not appear a second time below Up Next');
      expect(find.byType(SliverReorderableList), findsOneWidget);
      await _drag(tester, 'queue-grip-0', 180);
      expect(player.upcomingMoves, isNotEmpty);
      expect(player.upcomingMoves.last.$1, 0);
      expect(player.upcomingMoves.last.$2, greaterThan(0));
      expect(player.upcomingIds.first, isNot('a'));

      await _drag(tester, 'queue-grip-2', -180);
      expect(player.upcomingMoves.length, 2);
      expect(player.upcomingMoves.last.$1, 2);
      expect(player.upcomingMoves.last.$2, lessThan(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('manual queue with no active playback is reorderable',
      (tester) async {
    tester.view.physicalSize = const Size(440, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = _ManualOnlyPlayer();
    await tester.pumpWidget(ProviderScope(
      overrides: [playerProvider.overrideWith(() => player)],
      child: MaterialApp(
        theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
        home: const Scaffold(body: QueueList()),
      ),
    ));
    await tester.pumpAndSettle();
    await _drag(tester, 'queue-grip-0', 180);
    expect(player.manualMoves, [(0, 1)]);
    expect(player.manualIds, ['e', 'd', 'f']);
  });
}

class _ManualOnlyPlayer extends _QueuePlayer {
  @override
  PlayerState build() => PlayerState(queue: [_track('d'), _track('e'), _track('f')]);
}
