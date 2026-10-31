import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/playlist_links/playlist_link_models.dart';
import 'package:flick/features/spotify/provider_playlist_track_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
            accountId: 'test-account',
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

  test('sorting preserves duplicate occurrences, stable ties, and provider order', () {
    expect(providerPlaylistVisibleIndices(tracks, ''), [0, 1, 2]);
    expect(providerPlaylistVisibleIndices(tracks, '',
        descending: true), [2, 1, 0]);
    expect(providerPlaylistVisibleIndices(tracks, '',
        sort: ProviderPlaylistSort.title), [1, 0, 2]);
    expect(providerPlaylistVisibleIndices(tracks, '',
        sort: ProviderPlaylistSort.title, descending: true), [0, 2, 1]);
    expect(providerPlaylistVisibleIndices(tracks, 'album a',
        sort: ProviderPlaylistSort.title, descending: true), [0, 2]);
    expect(providerPlaylistVisibleIndices(tracks, '',
        sort: ProviderPlaylistSort.artist), [1, 0, 2]);
    expect(providerPlaylistVisibleIndices(tracks, '',
        sort: ProviderPlaylistSort.album, descending: true), [1, 0, 2]);
    expect(providerPlaylistMatchingIndices(tracks, ''), [0, 1, 2]);
  });

  test('unknown durations sort last in both directions', () {
    const songs = [
      LokalDiscoveryTrack(title: 'Missing', artist: 'A'),
      LokalDiscoveryTrack(title: 'Long', artist: 'B',
          duration: Duration(minutes: 5)),
      LokalDiscoveryTrack(title: 'Short', artist: 'C',
          duration: Duration(minutes: 2)),
    ];
    expect(providerPlaylistVisibleIndices(songs, '',
        sort: ProviderPlaylistSort.duration), [2, 1, 0]);
    expect(providerPlaylistVisibleIndices(songs, '',
        sort: ProviderPlaylistSort.duration, descending: true), [1, 2, 0]);
  });

  test('saved playlist view order decodes safely', () {
    expect(ProviderPlaylistOrder.decode(null).sort, ProviderPlaylistSort.original);
    expect(ProviderPlaylistOrder.decode('malformed').sort, ProviderPlaylistSort.original);
    expect(ProviderPlaylistOrder.decode('other:desc').sort, ProviderPlaylistSort.original);
    final saved = const ProviderPlaylistOrder(
      sort: ProviderPlaylistSort.album, descending: true,
    );
    expect(saved.encode(), 'album:desc');
    final loaded = ProviderPlaylistOrder.decode(saved.encode());
    expect(loaded.sort, ProviderPlaylistSort.album);
    expect(loaded.descending, true);
  });

  testWidgets('sorting changes list and playback queue, but not playlist data',
      (tester) async {
    List<int>? selectedQueue;
    int? selectedStart;
    await tester.pumpWidget(app(
      onPlay: (queue, start) {
        selectedQueue = queue;
        selectedStart = start;
      },
      onActions: (_) {},
    ));
    await tester.tap(find.byTooltip('Sort: Playlist order'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    expect(selectedQueue, [1, 0, 2]);
    expect(selectedStart, 0);

    await tester.tap(find.byTooltip('Ascending · switch to descending'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    expect(selectedQueue, [0, 2, 1]);
    await tester.tap(find.text('Another song'));
    expect(selectedQueue, [0, 2, 1]);
    expect(selectedStart, 2);
    expect(providerPlaylistMatchingIndices(tracks, ''), [0, 1, 2]);
  });

  testWidgets('sort and direction are restored per account playlist',
      (tester) async {
    await tester.pumpWidget(app(onPlay: (_, __) {}, onActions: (_) {}));
    await tester.tap(find.byTooltip('Sort: Playlist order'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artist').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ascending · switch to descending'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(onPlay: (_, __) {}, onActions: (_) {}));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Sort: Artist'), findsOneWidget);
    expect(find.byTooltip('Descending · switch to ascending'), findsOneWidget);
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
