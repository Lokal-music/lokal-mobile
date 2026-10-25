import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/morneye/morneye_packages.dart';
import 'package:flick/features/player/widgets/player_artwork_quality.dart';

void main() {
  test('Amazon original-resolution artwork keeps the same image identity', () {
    const thumb = 'https://m.media-amazon.com/images/I/ABCD1234._AC_UY218_.jpg';
    const full = 'https://m.media-amazon.com/images/I/ABCD1234.jpg';
    expect(morneyeAlbumArtworkUrl(thumb), full);
    expect(PlayerArtworkQuality.candidates(thumb), [full, thumb]);
    expect(morneyeAlbumArtworkUrl(full), full);
    expect(morneyeAlbumArtworkUrl('https://elsewhere.org/thumb._AC_UY218_.jpg'),
        'https://elsewhere.org/thumb._AC_UY218_.jpg');
  });

  test('Search receives Amazon cover_art and album artwork fallbacks', () {
    final cover = MorneyeTrack.of({
      'id': 'B012345678',
      'name': 'Test',
      'artists': ['Artist'],
      'cover_art': 'https://m.media-amazon.com/images/I/X123._AC_SL300_.jpg',
    }, 'a-amazon');
    expect(cover.thumbnail, 'https://m.media-amazon.com/images/I/X123._AC_SL300_.jpg');
    expect(PlayerArtworkQuality.candidates(cover.thumbnail).first,
        'https://m.media-amazon.com/images/I/X123.jpg');

    final album = MorneyeTrack.of({
      'id': 'B012345678',
      'name': 'Test',
      'artists': ['Artist'],
      'album': {
        'name': 'Record',
        'images': [
          'https://m.media-amazon.com/images/I/Y123._AC_SL75_.jpg',
          'https://m.media-amazon.com/images/I/Y123._AC_SL500_.jpg',
        ],
      },
    }, 'a-amazon');
    expect(album.thumbnail, 'https://m.media-amazon.com/images/I/Y123._AC_SL500_.jpg');
    expect(PlayerArtworkQuality.candidates(album.thumbnail).first,
        'https://m.media-amazon.com/images/I/Y123.jpg');
  });

  test('Amazon canonical search results skip a redundant metadata fetch', () {
    expect(providerIdentityIsAmazon('amazon', {
      'id': 'B012345678', 'provider_id': 'amazon',
    }), isTrue);
    expect(providerIdentityIsAmazon('tidal-web', {
      'id': 'B012345678', 'provider_id': 'amazon',
    }), isFalse);
    expect(providerIdentityIsAmazon('amazon', {
      'id': 'not an ASIN', 'provider_id': 'amazon',
    }), isFalse);
    expect(providerIdentityIsAmazon('amazon', {
      'id': 'B012345678', 'provider_id': 'other',
    }), isFalse);
  });
}
