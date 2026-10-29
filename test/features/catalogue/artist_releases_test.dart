import 'package:flick/features/konnekted/library/lokal_online_catalogue.dart';
import 'package:flick/services/apple_music/apple_music_metadata_service.dart';
import 'package:flick/services/apple_music/apple_music_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

AppleMusicAlbumMatch release(
  String id, String title, String artist, String date,
) => AppleMusicAlbumMatch(
  collectionId: id,
  name: title,
  artistName: artist,
  url: 'https://music.apple.com/ng/album/-/$id',
  releaseDate: date,
  trackCount: 10,
);

class _ArtistApple extends Fake implements AppleMusicMetadataService {
  _ArtistApple(this.name);
  final String name;
  int verifiedCalls = 0;
  int searchedCalls = 0;

  @override
  Future<AppleMusicArtistData?> getArtistData(
    String artist, {
    int topSongLimit = 10,
    String? storefront,
    bool refresh = false,
  }) async => AppleMusicArtistData(
    artist: AppleMusicArtist(artistId: 'artist-id', name: name),
    info: AppleMusicArtistInfo(
      artistId: 'artist-id', name: name, storefront: 'ng',
      url: 'https://music.apple.com/ng/artist/-/artist-id',
      imageUrl: 'https://example.test/artist.jpg',
    ),
    topSongs: [
      AppleMusicTopSong(
        trackName: 'Popular track',
        artistName: name,
        collectionName: 'Popular song release',
      ),
    ],
  );

  @override
  Future<List<AppleMusicAlbumMatch>> getArtistReleases(
    String artist, {
    String? storefront,
    bool refresh = false,
  }) async {
    verifiedCalls++;
    return [
      release('1', 'Album One', name, '2022-01-01'),
      release('2', 'Album Two', name, '2023-01-01'),
      release('3', 'Album Three', name, '2024-01-01'),
      release('4', 'Album Four', name, '2025-01-01'),
      // An artist-ID lookup can attribute a joint release whose display
      // credit does not exactly match the searched artist.
      release('5', 'Joint EP', 'Shared Credit', '2025-02-01'),
      // Distinct catalogue editions need distinct cards, not a title-only
      // dedupe. Their dates and collection IDs differ.
      release('6', 'Album Four', name, '2026-01-01'),
    ];
  }

  @override
  Future<List<AppleMusicAlbumMatch>> searchAlbums(
    String query, {
    int limit = 25,
    String? storefront,
    bool refresh = false,
  }) async {
    searchedCalls++;
    return [
      release('2', 'Album Two', name, '2023-01-01'),
      release('7', 'Credited Collaboration', '$name & Guest', '2025-05-01'),
      release('8', 'Wrong artist album', 'Another $name Fan', '2025-01-01'),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final artist in ['Asake', 'Davido']) {
    test('$artist artist page merges verified releases, collaborations, and song albums', () async {
      final api = _ArtistApple(artist);
      final catalogue = LokalOnlineCatalogue(
        apple: api,
        sources: (http.Client _) async => [],
        youtubeReleases: (_) async => [],
      );
      final page = await catalogue.artist(artist);
      final names = page.albums.map((album) => album.title).toList();
      expect(page.albums, hasLength(8));
      expect(names, containsAll([
        'Album One', 'Album Two', 'Album Three', 'Album Four',
        'Joint EP', 'Credited Collaboration', 'Popular song release',
      ]));
      expect(names, isNot(contains('Wrong artist album')));
      expect(names.where((name) => name == 'Album Four'), hasLength(2));
      expect(page.albums.where((album) => album.id == '2'), hasLength(1));
      expect(
        page.albums.firstWhere((album) => album.title == 'Joint EP').kind,
        LokalReleaseKind.feature,
      );
      expect(
        page.albums.firstWhere((album) => album.title == 'Credited Collaboration').kind,
        LokalReleaseKind.feature,
      );
      expect(api.verifiedCalls, 1);
      expect(api.searchedCalls, 1);
      expect(page.tracks, hasLength(1));
      // A saved page should reuse its merged results, not re-fetch everything.
      await catalogue.artist(artist);
      expect(api.verifiedCalls, 1);
    });
  }
}
