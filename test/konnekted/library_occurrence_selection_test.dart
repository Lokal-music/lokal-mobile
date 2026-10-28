import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/library/lokal_library_kit.dart';
import 'package:flick/features/konnekted/library/lokal_song_browser.dart';
import 'package:flick/features/konnekted/library/replayable_stream_songs.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/queue_pre_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Player extends PlayerNotifier {
  int? selectedIndex;
  Song? selected;
  List<Song>? queue;

  @override
  PlayerState build() => const PlayerState();

  @override
  Future<void> play(
    Song song, {
    List<Song>? playlist,
    int? playlistIndex,
    PlaybackContext? context,
  }) async {
    selected = song;
    selectedIndex = playlistIndex;
    queue = playlist;
  }
}

const _song = Song(
  id: 'repeated',
  title: 'Repeated track',
  artist: 'Artist',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
  filePath: '/library/song.flac',
);

void main() {
  testWidgets('tapping a repeated library row selects its actual occurrence', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(400, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = _Player();
    final songs = [_song, _song.copyWith(id: 'middle'), _song];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerProvider.overrideWith(() => player)],
        child: MaterialApp(
          theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                LokalSongBrowser(
                  songs: songs,
                  initialSort: LokalSongSort.original,
                  originalLabel: 'Playlist order',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final last = find.byType(LokalTrackRow).at(2);
    await tester.ensureVisible(last);
    await tester.tap(
      find.descendant(of: last, matching: find.text('Repeated track')),
    );
    await tester.pumpAndSettle();
    expect(player.selectedIndex, 2);
    expect(player.selected, same(player.queue![2]));
    expect(player.queue!.map((song) => song.id), [
      'repeated',
      'middle',
      'repeated',
    ]);
    expect(tester.takeException(), isNull);
  });

  test('stream reconstruction preserves the selected repeated slot', () {
    final resolver = QueuePreResolver();
    final expired = _song.copyWith(
      sourcePackage: 'konnekted.progressive',
      filePath: 'https://expired.invalid/media',
    );
    final songs = replayableStreamQueue(
      [expired, _song.copyWith(id: 'middle'), expired],
      resolver: resolver,
      lookup: (_, {onStatus, cancel}) async => _song,
    );
    final index = PlayerService.selectedPlaylistIndex(
      songs,
      expired,
      indexHint: 2,
    );
    expect(index, 2);
    expect(songs[index].isPending, isTrue);
    expect(songs.map((song) => song.id), ['repeated', 'middle', 'repeated']);
  });
}
