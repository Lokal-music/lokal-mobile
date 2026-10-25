import 'package:flick/services/apple_music/apple_music_metadata_service.dart';
import 'package:flick/services/apple_music/apple_music_models.dart';
import 'package:flick/services/global_catalogue_search.dart';
import 'package:flutter_test/flutter_test.dart';

class _Apple extends Fake implements AppleMusicMetadataService {
  final calls = <String>[];
  bool rejectOtherEntities = false;

  @override
  Future<List<AppleMusicSearchSong>> searchSongs(
    String term, {
    int limit = 40,
    String? storefront,
    bool refresh = false,
  }) async {
    calls.add('songs');
    return const [
      AppleMusicSearchSong(
        catalogueId: '1',
        title: 'Song',
        artist: 'Singer',
        album: 'Album',
        artworkUrl: '',
        duration: Duration.zero,
      ),
    ];
  }

  @override
  Future<List<AppleMusicAlbumMatch>> searchAlbums(
    String term, {
    int limit = 25,
    String? storefront,
    bool refresh = false,
  }) async {
    calls.add('albums');
    if (rejectOtherEntities) throw StateError('Album search unavailable');
    return const [
      AppleMusicAlbumMatch(
        collectionId: '2',
        name: 'Album',
        artistName: 'Singer',
        url: '',
      ),
    ];
  }

  @override
  Future<List<AppleMusicArtist>> searchArtists(
    String term, {
    int limit = 25,
    String? storefront,
    bool refresh = false,
  }) async {
    calls.add('artists');
    if (rejectOtherEntities) throw StateError('Artist search unavailable');
    return const [AppleMusicArtist(artistId: '3', name: 'Singer')];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Songs makes only a song lookup even when album and artist requests would fail', () async {
    final apple = _Apple()..rejectOtherEntities = true;
    final data = await GlobalCatalogueSearchService(appleMusic: apple)
        .search('Wanted', selected: 'apple', songsOnly: true, refresh: true);
    expect(apple.calls, ['songs']);
    expect(data.songs.single.title, 'Song');
    expect(data.albums, isEmpty);
    expect(data.artists, isEmpty);
  });
  test('All retains album and artist lookups for the same query', () async {
    final apple = _Apple();
    final service = GlobalCatalogueSearchService(appleMusic: apple);
    await service.search(
      'Wanted',
      selected: 'apple',
      songsOnly: true,
      refresh: true,
    );
    apple.calls.clear();
    final data = await service.search(
      'Wanted',
      selected: 'apple',
      refresh: true,
    );
    expect(apple.calls, ['songs', 'albums', 'artists']);
    expect(data.songs, hasLength(1));
    expect(data.albums, hasLength(1));
    expect(data.artists, hasLength(1));
  });
}
