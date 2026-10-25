import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';

void main() {
  Song song(String id, {String? filePath}) => Song(
    id: id,
    title: 'Track $id',
    artist: 'Artist',
    duration: const Duration(minutes: 3),
    fileType: 'FLAC',
    filePath: filePath,
  );

  group('Repeat All without rebuilding active audio', () {
    test('single-source Android must manually advance logical playlist', () {
      expect(shouldHandleManualCompletion(
        usingRustBackend: false,
        loopMode: LoopMode.all,
        androidSingleTrackOnly: true,
      ), isTrue);
      expect(shouldHandleManualCompletion(
        usingRustBackend: false,
        loopMode: LoopMode.all,
        androidSingleTrackOnly: false,
      ), isFalse, reason: 'A fully loaded native queue repeats on its own');
      expect(shouldHandleManualCompletion(
        usingRustBackend: false,
        loopMode: LoopMode.one,
        androidSingleTrackOnly: true,
      ), isFalse, reason: 'Native Repeat One must remain unchanged');
    });
  });

  group('Autoplay queue preview', () {
    test('selects a bounded, unique, playable set ahead of time', () {
      final library = [
        song('current', filePath: '/music/current.flac'),
        song('manual', filePath: '/music/manual.flac'),
        for (var i = 0; i < 10; i++)
          song('next-$i', filePath: '/music/next-$i.flac'),
        song('next-0', filePath: '/music/duplicate.flac'),
        song('empty-path', filePath: ''),
        song('no-source'),
      ];
      final suggestions = selectAutoplayRecommendations(
        library: library,
        excludedIds: {'current', 'manual'},
        count: 4,
        random: math.Random(5),
      );

      expect(suggestions, hasLength(4));
      expect(suggestions.map((s) => s.id).toSet(), hasLength(4));
      expect(suggestions.every((s) => s.filePath?.isNotEmpty == true), isTrue);
      expect(suggestions.any((s) => s.id == 'current'), isFalse);
      expect(suggestions.any((s) => s.id == 'manual'), isFalse);
      expect(suggestions.first.id, isNotEmpty,
          reason: 'The first displayed recommendation is the queue-end pick');
    });

    test('does not fabricate a next song when the library has no alternatives', () {
      expect(
        selectAutoplayRecommendations(
          library: [song('only', filePath: '/music/only.flac')],
          excludedIds: {'only'},
        ),
        isEmpty,
      );
      expect(
        selectAutoplayRecommendations(
          library: [song('unresolved')],
          excludedIds: {},
        ),
        isEmpty,
      );
      expect(
        selectAutoplayRecommendations(
          library: [song('a', filePath: '/music/a.flac')],
          excludedIds: {},
          count: 0,
        ),
        isEmpty,
      );
    });
  });
}
