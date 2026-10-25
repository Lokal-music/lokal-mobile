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
