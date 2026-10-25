import 'package:flick/core/utils/album_match.dart';
import 'package:flick/features/konnekted/library/lokal_online_catalogue.dart';
import 'package:flick/services/apple_music/apple_music_metadata_service.dart';
import 'package:flick/services/apple_music/apple_music_models.dart';
import 'package:flutter_test/flutter_test.dart';

const title = 'Dude (Original Motion Picture Soundtrack)';
const credits = 'Sai Abhyankar, Paal Dabba, Bhumi, Deepthi Suresh';

class _Apple implements AppleMusicMetadataService {
  AppleMusicAlbumData? data;
  @override
  Future<AppleMusicAlbumData?> getAlbumData({
    required String album,
    required String artist,
    String? storefront,
    bool refresh = false,
  }) async => data;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

AppleMusicAlbumData album({String name = title, String? cover}) =>
    AppleMusicAlbumData(
      match: AppleMusicAlbumMatch(
        collectionId: '1848715390',
        name: name,
        artistName: 'Sai Abhyankkar',
        url: 'https://music.apple.com/us/album/dude/1848715390',
        artworkUrl: cover,
      ),
      tracks: const [
        AppleMusicTrack(
          trackName: 'Singari',
          artistName: 'Sai Abhyankkar',
          trackNumber: 2,
        ),
        AppleMusicTrack(
          trackName: 'Oorum Blood',
          artistName: 'Sai Abhyankkar, Paal Dabba',
          trackNumber: 1,
        ),
      ],
    );
void main() {
  test('identical generic credits match without becoming wildcards', () {
    for (final credit in ['Various Artists', 'Unknown Artist']) {
      expect(albumArtistsMatch(credit, credit.toUpperCase()), true);
      expect(albumArtistsMatch(credit, 'Sai Abhyankkar'), false);
      expect(albumArtistsMatch('Sai Abhyankkar', credit), false);
    }
    expect(albumArtistsMatch('', ''), false);
    expect(albumArtistsMatch('Various Artists', 'Unknown Artist'), false);
  });
  test('a verified cover survives an unavailable track list', () async {
    final api = _Apple()
      ..data = AppleMusicAlbumData(
        match: album(cover: 'https://art.example/apple.jpg').match,
      );
    final page = await LokalOnlineCatalogue(
      apple: api,
      sources: (_) async => [],
    ).album(title, credits);
    expect(page.tracks, isEmpty);
    expect(page.albums.single.artwork, 'https://art.example/apple.jpg');
    expect(page.url, contains('1848715390'));
    expect(page.completeAlbum, false);
  });

  test('soundtrack matching tolerates credit lists and generic wording, preserves editions', () {
    expect(albumArtistsMatch(credits, 'Sai Abhyankkar'), true);
    expect(albumArtistsMatch(credits, 'Another Composer'), false);
    expect(albumTitlesMatch(title, 'Dude'), true);
    for (final wrong in [
      'Dude (Telugu) [Original Motion Picture Soundtrack]',
      'Dude (Deluxe)',
      'Dude - Side A (Original Score)',
      'Dude Live',
    ]) {
      expect(albumTitlesMatch(title, wrong), false, reason: wrong);
    }
  });
  test(
    'combined credits retain complete track list and verified fallback cover',
    () async {
      final api = _Apple()..data = album();
      var artLookups = 0;
      final catalogue = LokalOnlineCatalogue(
        apple: api,
        sources: (_) async => [],
        albumArtwork: (title, artist) async {
          artLookups++;
          return 'https://art.example/dude.jpg';
        },
      );
      final page = await catalogue.album(title, credits);
      expect(page.completeAlbum, true);
      expect(page.tracks.map((s) => s.metadata.title), [
        'Oorum Blood',
        'Singari',
      ]);
      expect(page.albums.single.artwork, 'https://art.example/dude.jpg');
      expect(
        page.tracks.every(
          (s) => s.metadata.artworkUrl == 'https://art.example/dude.jpg',
        ),
        true,
      );
      await catalogue.album(title, credits);
      expect(artLookups, 1); // Page cache coalesces artwork fetches too.
    },
  );
  test('authoritative cover is preferred and unrelated language tracklists rejected', () async {
    final api = _Apple()..data = album(cover: 'https://art.example/apple.jpg');
    final catalogue = LokalOnlineCatalogue(
      apple: api,
      sources: (_) async => [],
      albumArtwork: (_, _) async =>
          throw StateError('unneeded artwork request'),
    );
    expect(
      (await catalogue.album(title, credits)).albums.single.artwork,
      'https://art.example/apple.jpg',
    );
    api.data = album(
      name: 'Dude (Telugu) [Original Motion Picture Soundtrack]',
    );
    final page = await catalogue.album(title, credits, refresh: true);
    expect(page.tracks, isEmpty);
    expect(page.completeAlbum, false);
  });
}
