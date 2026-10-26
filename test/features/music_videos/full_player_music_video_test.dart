import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/music_videos/music_video_player_page.dart';
import 'package:flick/features/music_videos/music_video_surface.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:flick/models/song.dart';

void main() {
  const song = Song(
    id: 'song-1',
    title: 'Track',
    artist: 'Artist',
    duration: Duration(minutes: 3),
    fileType: 'FLAC',
  );

  testWidgets('video route uses root navigator, above the shell mini-player',
      (tester) async {
    final rootNavigator = GlobalKey<NavigatorState>();
    final tabNavigator = GlobalKey<NavigatorState>();
    NavigatorState? selected;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: rootNavigator,
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Navigator(
                key: tabNavigator,
                onGenerateRoute: (_) => MaterialPageRoute(
                  builder: (context) => Builder(
                    builder: (tabContext) {
                      selected = musicVideoRouteNavigator(tabContext);
                      return const Text('Videos tab');
                    },
                  ),
                ),
              ),
            ),
            const Text('Persistent app-shell mini player'),
          ],
        ),
      ),
    ));
    expect(selected, same(rootNavigator.currentState));
    expect(selected, isNot(same(tabNavigator.currentState)),
        reason: 'The video route must cover the shell footer');
  });

  test('video ID validation rejects arbitrary embed destinations', () {
    expect(validMusicVideoId('abcdefghijk'), isTrue);
    expect(validMusicVideoId('bad'), isFalse);
    expect(validMusicVideoId('abcdefghijk?x=1'), isFalse);
    expect(() => musicVideoEmbedHtml('bad'), throwsArgumentError);
  });

  test('music-video embed uses the official player without stream extraction', () {
    final html = musicVideoEmbedHtml('abcdefghijk');
    expect(html, contains('https://www.youtube.com/embed/abcdefghijk'));
    expect(html, contains('playsinline=1'));
    expect(html, contains('origin='));
    expect(html, contains('allowfullscreen'));
    expect(html, isNot(contains('youtubei/v1/player')));
    expect(html, isNot(contains('googlevideo.com')));
  });

  test('full-player video route keeps song metadata separate from audio queue', () {
    const screen = FullPlayerScreen(
      videoSong: song,
      videoId: 'abcdefghijk',
    );
    expect(screen.videoSong, same(song));
    expect(screen.videoId, 'abcdefghijk');
    expect(
      () => FullPlayerScreen(videoSong: song),
      throwsAssertionError,
    );
  });
}
