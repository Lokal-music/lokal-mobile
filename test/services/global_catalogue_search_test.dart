import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/global_catalogue_source.dart';
import 'package:flick/services/global_catalogue_search.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Spotify global search supplies catalogue identifiers but never audio URLs', () {
    final results = parseSpotifyGlobal({
      'tracks': {
        'items': [
          {
            'id': 'spotify-track-123', 'name': 'Example',
            'artists': [{'name': 'Singer'}],
            'album': {'name': 'Album', 'images': [
              {'url': 'https://i.scdn.co/image/master'},
            ]},
            'duration_ms': 221000,
            'preview_url': 'https://p.scdn.co/signed-preview.mp3',
          },
          {
            'id': 'spotify-track-123', 'name': 'Example',
            'artists': [{'name': 'Singer'}],
          },
        ],
      },
      'albums': { 'items': [
        {'name': 'Album', 'artists': [{'name': 'Singer'}]},
      ] },
      'artists': { 'items': [
        {'name': 'Singer'},
      ] },
    });
    expect(results.catalogue, GlobalCatalogueSource.spotify);
    expect(results.songs, hasLength(1));
    expect(results.songs.single.title, 'Example');
    expect(results.songs.single.duration, const Duration(seconds: 221));
    expect(results.albums.single.artist, 'Singer');
    expect(results.artists.single.name, 'Singer');
    expect(results.songs.single.artworkUrl, startsWith('https://'));
    expect(results.songs.single.toString(), isNot(contains('signed-preview')));
  });

  test('Spotify Pathfinder fallback extracts tracks when REST denies cookie session', () {
    final results = parseSpotifyPathfinder({
      'searchV2': {
        'tracksV2': {
          'items': [
            {'item': {'data': {
              'uri': 'spotify:track:xyz', 'name': 'Test',
              'artists': {'items': [{'profile': {'name': 'Singer'}}]},
              'albumOfTrack': {'name': 'A'},
              'duration': {'totalMilliseconds': 80000},
            }}},
          ],
        },
      },
    });
    expect(results.songs, hasLength(1));
    expect(results.songs.single.catalogueId, 'xyz');
    expect(results.songs.single.artist, 'Singer');
    expect(results.songs.single.duration, const Duration(seconds: 80));
  });


  test('Spotify REST skips invalid artwork and uses the largest valid cover', () {
    final results = parseSpotifyGlobal({
      'tracks': {'items': [
        {'id': 'track-1', 'name': 'Top song',
         'artists': [{'name': 'Artist'}],
         'album': {'name': 'Record', 'images': [
           {'url': '', 'width': 640, 'height': 640},
           {'url': 'http://example.com/unsafe.jpg', 'width': 1200, 'height': 1200},
           {'url': 'https://example.com/small.jpg', 'width': 64, 'height': 64},
           {'url': 'https://example.com/full.jpg', 'width': 640, 'height': 640},
         ]}},
      ]},
      'albums': {'items': [
        {'name': 'Record', 'artists': [{'name': 'Artist'}], 'images': [
          {'url': 'not-a-url'},
          {'url': 'https://example.com/album.jpg', 'width': 300, 'height': 300},
        ]},
      ]},
    });
    expect(results.songs.single.artworkUrl, 'https://example.com/full.jpg');
    expect(results.albums.single.artworkUrl, 'https://example.com/album.jpg');
  });

  test('Spotify Pathfinder selects a valid cover even if the first source is empty', () {
    final results = parseSpotifyPathfinder({
      'searchV2': {'tracksV2': {'items': [
        {'item': {'data': {
          'uri': 'spotify:track:song-1', 'name': 'Top song',
          'artists': {'items': [{'profile': {'name': 'Artist'}}]},
          'albumOfTrack': {'name': 'Record', 'coverArt': {'sources': [
            {'url': null, 'width': 640, 'height': 640},
            {'url': 'https://example.com/160.jpg', 'width': 160, 'height': 160},
            {'url': 'https://example.com/640.jpg', 'width': 640, 'height': 640},
          ]}},
        }}},
      ]}},
    });
    expect(results.songs.single.artworkUrl, 'https://example.com/640.jpg');
  });

  test('Global choice persists independently from playback source priorities', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await GlobalCatalogueSource.load(), GlobalCatalogueSource.apple);
    await GlobalCatalogueSource.set(GlobalCatalogueSource.spotify);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(GlobalCatalogueSource.key), GlobalCatalogueSource.spotify);
    expect(prefs.getStringList('lokal.playback.source_order'), isNull);
    await GlobalCatalogueSource.set(GlobalCatalogueSource.apple);
    expect(prefs.getString(GlobalCatalogueSource.key), GlobalCatalogueSource.apple);
  });
}
