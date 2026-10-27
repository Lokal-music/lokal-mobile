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
  test('reorder row identities survive moves and distinguish duplicate tracks', () {
    final songs = [_track('a'), _track('b'), _track('a'), _track('c')];
    final before = queueRowIdentities(songs, 'upnext');
    final reordered = [songs[1], songs[0], songs[2], songs[3]];
    final after = queueRowIdentities(reordered, 'upnext');
    expect(before.toSet(), hasLength(4));
    expect(after.toSet(), hasLength(4));
    expect(before[0], after[1],
        reason: 'Original first song must retain its key after moving');
    expect(before[1], after[0]);
    expect(before[2], after[2],
        reason: 'Repeated song IDs cannot collide within a list');
  });

  for (final embedded in [false, true]) {
    testWidgets('${embedded ? 'full-player embedded' : 'full-screen'} queue supports drag in both sections',
        (tester) async {
      tester.view.physicalSize = const Size(440, 1024);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = _QueuePlayer();
      await tester.pumpWidget(ProviderScope(
        overrides: [playerProvider.overrideWith(() => player)],
        child: MaterialApp(
          theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
          home: Scaffold(
            body: QueueList(embedded: embedded),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await _drag(tester, 'upnext-drag-0', 190);
      expect(player.upcomingMoves, isNotEmpty);
      expect(player.upcomingMoves.last.$1, 0);
      expect(player.upcomingMoves.last.$2, greaterThan(0));
      expect(player.upcomingIds.first, isNot('a'));

      await _drag(tester, 'manual-queue-drag-2', -180);
      expect(player.manualMoves, isNotEmpty);
      expect(player.manualMoves.last.$1, 2);
      expect(player.manualMoves.last.$2, lessThan(2));
      expect(player.manualIds.last, isNot('f'));
      expect(tester.takeException(), isNull);
    });
  }
}
