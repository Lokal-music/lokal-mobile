import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';

void main() {
  Song song(String id) => Song(
    id: id,
    title: 'Song $id',
    artist: 'Artist $id',
    duration: const Duration(minutes: 3),
    fileType: 'MP3',
  );

  group('PlayerService mid-queue selection', () {
    test(
      'selects the real middle index without truncating the source list',
      () {
        final tracks = [song('a'), song('b'), song('c'), song('d')];
        final index = PlayerService.selectedPlaylistIndex(tracks, tracks[2]);

        expect(index, 2);
        expect(tracks.map((song) => song.id).toList(), ['a', 'b', 'c', 'd']);
        expect(tracks.sublist(0, index).map((song) => song.id), ['a', 'b']);
        expect(tracks.sublist(index + 1).map((song) => song.id), ['d']);
      },
    );

    test('identifies the tapped occurrence of duplicate song IDs', () {
      final first = song('a');
      final second = song('a');
      final songs = [first, song('b'), second];

      expect(PlayerService.selectedPlaylistIndex(songs, second), 2);
      expect(PlayerService.selectedPlaylistIndex(songs, first), 0);
      expect(PlayerService.selectedPlaylistIndex(songs, song('a')), 0);
    });

    test(
      'an explicit occurrence survives shared objects and reconstruction',
      () {
        final repeated = song('a');
        final songs = [repeated, song('b'), repeated];
        expect(
          PlayerService.selectedPlaylistIndex(songs, repeated, indexHint: 2),
          2,
        );
        expect(
          PlayerService.selectedPlaylistIndex(songs, song('a'), indexHint: 2),
          2,
        );
        for (final invalid in [-1, 1, 3]) {
          expect(
            PlayerService.selectedPlaylistIndex(
              songs,
              repeated,
              indexHint: invalid,
            ),
            0,
          );
        }
      },
    );
  });

  group('PlayerService shuffle ordering', () {
    test('keeps the current song first when shuffle is enabled', () {
      final songs = [song('a'), song('b'), song('c'), song('d')];

      final reordered = buildShufflePlaybackOrder(
        songs: songs,
        current: songs[2],
        random: math.Random(7),
      );

      expect(reordered, hasLength(songs.length));
      expect(reordered.first.id, 'c');
      expect(reordered.map((item) => item.id).toSet(), {'a', 'b', 'c', 'd'});
    });

    test(
      'restores the original order and reinserts a missing current song',
      () {
        final original = [song('a'), song('b'), song('c')];
        final queuedCurrent = song('x');

        final restored = restorePlaybackOrder(
          originalPlaylist: original,
          current: queuedCurrent,
          insertionIndex: 1,
        );

        expect(restored.map((item) => item.id).toList(), ['a', 'x', 'b', 'c']);
      },
    );
  });
}
