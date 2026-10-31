import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/playlist_links/playlist_link_models.dart';
import 'package:flick/features/playlist_links/playlist_unmatched_downloader.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_test/flutter_test.dart';

const _youtube = ParsedPlaylistLink(
  source: PlaylistLinkSource.youtube,
  remoteId: 'PL_abc-12345',
  canonicalUrl: 'https://www.youtube.com/playlist?list=PL_abc-12345',
);
const _spotify = ParsedPlaylistLink(
  source: PlaylistLinkSource.spotify,
  remoteId: '0123456789abcdefghijkl',
  canonicalUrl: 'https://open.spotify.com/playlist/0123456789abcdefghijkl',
);

void main() {
  test('unmatched regular YouTube entry retains the source video identity', () {
    const entry = RemotePlaylistEntry(
      title: 'Original video', artist: 'Uploader',
      remoteId: 'abcdefghijk',
    );
    final chosen = PlaylistUnmatchedDownloader.directYouTube(_youtube, entry);
    expect(chosen, isNotNull);
    expect(chosen!.sourceId, 'yt');
    expect(chosen.track.id, 'abcdefghijk');
    expect(chosen.track.sourceUrl.toString(),
        'https://www.youtube.com/watch?v=abcdefghijk');
    expect(PlaylistUnmatchedDownloader.directYouTube(_spotify, entry), isNull);
    expect(PlaylistUnmatchedDownloader.directYouTube(
      _youtube,
      const RemotePlaylistEntry(
        title: 'Invalid', artist: '', remoteId: 'not-a-video-id',
      ),
    ), isNull);
  });

  test('Spotify unmatched entry never downloads first unrelated search result', () async {
    final source = OnlineSource(
      id: 'yt',
      name: 'YouTube Music',
      results: (_) async => [
        OnlineResult(const DiscoveryTrack(
          id: 'wrong123456', title: 'Dangerous',
          artist: 'Someone Else', source: DiscoverySource.youtubeMusic,
        )),
        OnlineResult(const DiscoveryTrack(
          id: 'right123456', title: 'Dangerous',
          artist: 'Big Data', source: DiscoverySource.youtubeMusic,
        )),
      ],
      play: (_) async => throw StateError('Should not play during selection'),
    );
    const entry = RemotePlaylistEntry(
      title: 'Dangerous', artist: 'Big Data',
      remoteId: 'spotify:track:someid',
    );
    final chosen = await const PlaylistUnmatchedDownloader()
        .findSource(entry, [source]);
    expect(chosen?.track.id, 'right123456');
  });

  test('an unresolvable entry can be skipped without failing the batch', () async {
    const entry = RemotePlaylistEntry(title: 'Unavailable', artist: 'Unknown', remoteId: 'song-id');
    await expectLater(
      const PlaylistUnmatchedDownloader().download(
        _spotify, entry, sources: (_) async => [],
      ),
      throwsA(isA<PlaylistDownloadSourceUnavailable>()),
    );
  });

  test('search errors are reported only after all sources fail to match', () async {
    const entry = RemotePlaylistEntry(title: 'Song', artist: 'Artist');
    final failed = OnlineSource(id: 'failed', name: 'Failed',
      results: (_) async => throw StateError('search failed'),
      play: (_) async => throw StateError('not used'));
    final empty = OnlineSource(id: 'empty', name: 'Empty',
      results: (_) async => [], play: (_) async => throw StateError('not used'));
    final good = OnlineSource(id: 'good', name: 'Good',
      results: (_) async => [OnlineResult(const DiscoveryTrack(
        id: 'correct', title: 'Song', artist: 'Artist', source: DiscoverySource.youtubeMusic))],
      play: (_) async => throw StateError('not used'));
    const downloader = PlaylistUnmatchedDownloader();
    expect((await downloader.findSource(entry, [failed, good]))?.track.id, 'correct');
    await expectLater(downloader.findSource(entry, [failed, empty]), throwsStateError);
    expect(await downloader.findSource(entry, [empty]), isNull);
  });

  test('unmatched entry downloads and saves through the injected source pipeline', () async {
    const entry = RemotePlaylistEntry(
      title: 'Original video', artist: 'Uploader', remoteId: 'abcdefghijk',
    );
    var preparedFrom = '';
    var saved = false;
    final result = await const PlaylistUnmatchedDownloader().download(
      _youtube,
      entry,
      prepare: (sourceId, track) async {
        preparedFrom = '$sourceId:${track.id}';
        return Song(
          id: 'ready', title: track.title, artist: track.artist,
          duration: const Duration(seconds: 190), fileType: 'MP3',
        );
      },
      save: (ready) async {
        saved = true;
        expect(ready.title, 'Original video');
        return const LibraryDownloadResult(
          path: '/music/downloaded.mp3',
          folderName: 'Lokal Downloads',
          fallback: true,
        );
      },
    );
    expect(preparedFrom, 'yt:abcdefghijk');
    expect(saved, isTrue);
    expect(result.path, '/music/downloaded.mp3');
  });
}
