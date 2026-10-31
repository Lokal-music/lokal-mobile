import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/playlist_links/playlist_link_models.dart';
import 'package:flick/features/spotify/provider_playlist_track_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tracks = [
    LokalDiscoveryTrack(title: 'Same song', artist: 'Singer', album: 'Album A'),
    LokalDiscoveryTrack(title: 'Another song', artist: 'Other', album: 'Album B'),
    LokalDiscoveryTrack(title: 'Same song', artist: 'Singer', album: 'Album A'),
  ];

  Widget app({
    required void Function(List<int> queue, int index) onPlay,
    required void Function(int index) onActions,
  }) => ProviderScope(child: MaterialApp(
        home: Scaffold(
          body: ProviderPlaylistTrackBrowser(
            tracks: tracks,
            source: PlaylistLinkSource.spotify,
            playlistId: 'test-playlist',
            artworkBuilder: (_) => const Icon(Icons.music_note),
            onPlay: onPlay,
            onSongActions: onActions,
          ),
        ),
      ));

  test('search retains source ordering and duplicate occurrences', () {
    expect(providerPlaylistMatchingIndices(tracks, ''), [0, 1, 2]);
    expect(providerPlaylistMatchingIndices(tracks, ' SAME  '), [0, 2]);
    expect(providerPlaylistMatchingIndices(tracks, 'album b'), [1]);
    expect(providerPlaylistMatchingIndices(tracks, 'singer'), [0, 2]);
    expect(providerPlaylistMatchingIndices(tracks, 'not present'), isEmpty);
  });

  test('download entries preserve source identity and metadata', () {
    const video = LokalDiscoveryTrack(
      title: 'Video', artist: 'Artist', album: 'Album',
      videoId: 'abcdefghijk', duration: Duration(seconds: 185),
    );
    final youtube = providerPlaylistDownloadEntry(
      video, PlaylistLinkSource.youtube,
    );
    expect(youtube.remoteId, 'abcdefghijk');
    expect(youtube.duration, const Duration(seconds: 185));
    final spotify = providerPlaylistDownloadEntry(
      video, PlaylistLinkSource.spotify,
    );
    expect(spotify.remoteId, isNull);
    expect(spotify.album, 'Album');
  });

  testWidgets('Play and song tap preserve the visible queue and selection',
      (tester) async {
    List<int>? lastQueue;
    int? lastStart;
    var actions = 0;
    await tester.pumpWidget(app(
      onPlay: (queue, index) {
        lastQueue = queue;
        lastStart = index;
      },
      onActions: (_) => actions++,
    ));

    await tester.tap(find.text('Play'));
    expect(lastQueue, [0, 1, 2]);
    expect(lastStart, 0);

    await tester.enterText(find.byType(TextField), 'same');
    await tester.pump();
    expect(find.text('Another song'), findsNothing);
    expect(find.text('2 of 3 songs'), findsOneWidget);

    await tester.tap(find.text('Play'));
    expect(lastQueue, [0, 2]);
    expect(lastStart, 0);

    await tester.tap(find.text('Same song').last);
    expect(lastQueue, [0, 2]);
    expect(lastStart, 1);
    expect(actions, 0);

    await tester.longPress(find.text('Same song').first);
    expect(actions, 1);
  });

  testWidgets('Shuffle uses filtered tracks and leaves playlist unchanged',
      (tester) async {
    List<int>? shuffled;
    int? start;
    await tester.pumpWidget(app(
      onPlay: (queue, index) {
        shuffled = queue;
        start = index;
      },
      onActions: (_) {},
    ));
    expect(find.text('Download playlist'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'album a');
    await tester.pump();
    await tester.tap(find.text('Shuffle'));
    expect(start, 0);
    expect(shuffled, isNotNull);
    expect(shuffled!.length, 2);
    expect(shuffled!.toSet(), {0, 2});
    expect(providerPlaylistMatchingIndices(tracks, ''), [0, 1, 2]);
    await tester.enterText(find.byType(TextField), 'no results');
    await tester.pump();
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('No matching songs'), findsOneWidget);
  });

  testWidgets('Download playlist requires explicit confirmation',
      (tester) async {
    await tester.pumpWidget(app(
      onPlay: (_, __) {},
      onActions: (_) {},
    ));
    await tester.tap(find.text('Download playlist'));
    await tester.pumpAndSettle();
    expect(find.text('Download playlist?'), findsOneWidget);
    expect(find.textContaining('substantial data'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Download playlist'), findsOneWidget);
  });
}
