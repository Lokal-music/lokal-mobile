import 'package:flick/models/song.dart';
import 'package:flick/models/shuffle_mode.dart';
import 'package:flick/services/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Exercise the real service and its native player, rather than only the
/// gesture tests' fake notifier. Queue edits must preserve the paused source.
Future<void> probeIosQueueReorder(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  PlayerService player,
  Song source,
) async {
  final next = [
    source.copyWith(id: 'ios-reorder-next-a'),
    source.copyWith(id: 'ios-reorder-next-b'),
  ];
  await player.play(source, playlist: [source, ...next]);
  await player.pause();
  await tester.pump(const Duration(milliseconds: 150));
  final position = player.positionNotifier.value;
  await player.moveUpNextItem(0, 1);
  expect(player.upNextNotifier.value.map((song) => song.id), [
    next[1].id,
    next[0].id,
  ]);

  final manual = [
    for (var i = 0; i < 3; i++) source.copyWith(id: 'ios-reorder-manual-$i'),
  ];
  for (final song in manual) {
    await player.addToQueue(song);
  }
  await player.moveQueueItem(0, 2);
  expect(player.queueNotifier.value.map((song) => song.id), [
    manual[1].id,
    manual[2].id,
    manual[0].id,
  ]);
  await player.moveUpNextItem(1, 0);
  final expected = [manual[2].id, manual[1].id, manual[0].id];
  expect(player.queueNotifier.value.map((song) => song.id), expected);
  expect(player.upNextNotifier.value.take(3).map((song) => song.id), expected);
  expect(player.currentSongNotifier.value?.id, source.id);
  expect(player.isPlayingNotifier.value, false);
  expect(
    (player.positionNotifier.value - position).abs(),
    lessThan(const Duration(milliseconds: 250)),
  );
  binding.reportData!['queue_reorder_native_service'] = {
    'normalized_adjacent_downward_move': true,
    'manual_notifier_immediate': true,
    'up_next_updates_manual_order': true,
    'paused_current_source_preserved': true,
  };
  await player.clearQueue();
  // Real native sequence indices must retain a tapped duplicate occurrence,
  // even when a library alias maps two rows to the exact same Song object.
  await player.setShuffleMode(ShuffleMode.off);
  final repeated = [source, next[0], source, next[1]];
  await player.play(source, playlist: repeated, playlistIndex: 2);
  await player.pause();
  await tester.pump(const Duration(milliseconds: 200));
  expect(player.currentIndex, 2);
  expect(
    player.playlist.map((song) => song.id),
    repeated.map((song) => song.id),
  );
  expect(player.upNextNotifier.value.map((song) => song.id), [next[1].id]);
  await player.previousBySwipe();
  await player.pause();
  expect(player.currentIndex, 1);
  expect(player.currentSongNotifier.value?.id, next[0].id);
  await player.playFromPlaylistIndex(0);
  await player.pause();
  expect(player.currentIndex, 0);
  expect(player.currentSongNotifier.value?.id, source.id);
  expect(
    player.playlist.map((song) => song.id),
    repeated.map((song) => song.id),
  );
  binding.reportData!['full_queue_occurrence_selection'] = {
    'shared_object_occurrence_index': 2,
    'ordered_context_preserved': true,
    'previous_swipe_index': 1,
    'absolute_history_selection_index': 0,
  };
  await player.play(source, playlist: [source]);
  await player.pause();
}
