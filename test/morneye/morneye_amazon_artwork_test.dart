import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/morneye/morneye_packages.dart';
import 'package:flick/features/player/widgets/player_artwork_quality.dart';

void main() {
  test('Amazon artwork picks the largest image in either ordering', () {
    const large = 'https://m.media-amazon.com/images/I/HASH._SX1500_.jpg';
    const small = 'https://m.media-amazon.com/images/I/HASH._SX75_.jpg';
    for (final images in [[large, small], [small, large]]) {
      expect(MorneyeTrack.of({'id': 'B012345678', 'images': images}, 'amazon').thumbnail, large);
    }
  });
  test('Amazon image dimensions beat array order and a small top-level thumbnail', () {
    final track = MorneyeTrack.of({'id': 'B012345678',
      'images': [{'url': 'https://m.media-amazon.com/images/I/SMALL.jpg', 'width': 75, 'height': 75}],
      'album': {'images': [
        {'url': 'https://m.media-amazon.com/images/I/LARGE.jpg', 'width': 1500, 'height': 1500},
        {'url': 'https://m.media-amazon.com/images/I/THUMB.jpg', 'width': 100, 'height': 100},
      ]},
    }, 'amazon');
    expect(track.thumbnail, 'https://m.media-amazon.com/images/I/LARGE.jpg');
  });
  test('Amazon host variants preserve query and original thumbnail fallback', () {
    for (final host in ['images-fe.ssl-images-amazon.com', 'images.amazon.com', 'ecx.images-amazon.com']) {
      final thumb = 'https://$host/images/I/HASH._SX75_.jpg?x=1';
      final full = 'https://$host/images/I/HASH.jpg?x=1';
      expect(morneyeAlbumArtworkUrl(thumb), full);
      expect(PlayerArtworkQuality.candidates(thumb), [full, thumb]);
    }
  });

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
