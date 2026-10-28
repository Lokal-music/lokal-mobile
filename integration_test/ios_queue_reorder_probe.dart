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

  // Exercise a large logical context against the actual AVFoundation-backed
  // just_audio player. Reusing the generated audio tests queue ownership and
  // source preparation, not a 2,654-file scanner or physical performance.
  final large = List<Song>.generate(
    2654,
    (index) => source.copyWith(id: 'ios-large-library-$index'),
  );
  await player.play(large[1730], playlist: large, playlistIndex: 1730)
      .timeout(const Duration(seconds: 30));
  final baseline = player.positionNotifier.value;
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (player.positionNotifier.value - baseline > const Duration(milliseconds: 300)) break;
  }
  expect(player.isPlayingNotifier.value, true);
  expect(player.positionNotifier.value - baseline, greaterThan(const Duration(milliseconds: 300)));
  expect(player.currentIndex, 1730);
  expect(player.playlist.map((song) => song.id), large.map((song) => song.id));
  expect(player.debugNativeSequenceLength, 1);
  await player.pause();
  await player.seek(Duration.zero);
  await player.previousBySwipe();
  await player.pause();
  expect(player.currentIndex, 1729);
  expect(player.currentSongNotifier.value?.id, large[1729].id);
  expect(player.debugNativeSequenceLength, 1);
  final pausedAt = player.positionNotifier.value;
  await player.setShuffleMode(ShuffleMode.songs);
  expect(player.currentSongNotifier.value?.id, large[1729].id);
  expect(player.debugNativeSequenceLength, 1);
  expect(player.isPlayingNotifier.value, false);
  expect((player.positionNotifier.value - pausedAt).abs(), lessThan(const Duration(milliseconds: 250)));
  await player.setShuffleMode(ShuffleMode.off);
  binding.reportData!['large_library_on_demand_native'] = {
    'scope': '2,654 logical entries sharing generated audio; actual native sequence, not scanner/device performance',
    'logical_entries': large.length,
    'selected_index': 1730,
    'native_sources': player.debugNativeSequenceLength,
    'previous_index': 1729,
    'paused_shuffle_preserves_recording_position': true,
  };
  await player.play(source, playlist: [source]);
  await player.pause();
}
