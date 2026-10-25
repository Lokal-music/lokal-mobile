import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/player/widgets/player_artwork_quality.dart';

void main() {
  group('full-player cover after Canvas is disabled', () {
    test('promotes Spotify 300px art to the same album hash at 640px', () {
      const old =
          'https://i.scdn.co/image/ab67616d00001e02abcdef0123456789';
      expect(PlayerArtworkQuality.candidates(old), [
        'https://i.scdn.co/image/ab67616d0000b273abcdef0123456789',
        old,
      ]);
    });

    test('also upgrades Spotify mini-player thumbnails without changing hash', () {
      for (final size in ['00004851', '000082c1']) {
        final old = 'https://i.scdn.co/image/ab67616d$size-abc';
        expect(
          PlayerArtworkQuality.candidates(old).first,
          'https://i.scdn.co/image/ab67616d0000b273-abc',
        );
      }
    });

    test('already large Spotify artwork is left intact', () {
      const old =
          'https://i.scdn.co/image/ab67616d0000b273abcdef0123456789';
      expect(PlayerArtworkQuality.candidates(old), [old]);
    });

    test('iTunes static cover requests 1200px with original fallback', () {
      const old =
          'https://is2-ssl.mzstatic.com/image/thumb/Music/covers/100x100bb.jpg';
      expect(PlayerArtworkQuality.candidates(old), [
        'https://is2-ssl.mzstatic.com/image/thumb/Music/covers/1200x1200bb.jpg',
        old,
      ]);
    });

    test('Deezer static cover requests full-resolution variant', () {
      const old =
          'https://e-cdns-images.dzcdn.net/images/cover/hash/250x250-000000-80-0-0.jpg';
      expect(PlayerArtworkQuality.candidates(old), [
        'https://e-cdns-images.dzcdn.net/images/cover/hash/1000x1000-000000-80-0-0.jpg',
        old,
      ]);
    });

    test('Tidal artwork is upgraded by size without changing the image UUID', () {
      const old =
          'https://resources.tidal.com/images/6f5c52be/c21c/4fb7/9ce6/0c270f6f1a5a/320x320.jpg';
      expect(PlayerArtworkQuality.candidates(old), [
        'https://resources.tidal.com/images/6f5c52be/c21c/4fb7/9ce6/0c270f6f1a5a/1280x1280.jpg',
        old,
      ]);
    });

    test('large Apple/Deezer/Tidal covers are not downgraded', () {
      for (final original in [
        'https://is1-ssl.mzstatic.com/music/1500x1500bb.jpg',
        'https://e-cdns-images.dzcdn.net/images/cover/hash/1400x1400-000000-80-0-0.jpg',
        'https://resources.tidal.com/images/abcdef/1500x1500.jpg',
      ]) {
        expect(PlayerArtworkQuality.candidates(original), [original]);
      }
    });

    test('YouTube requests a max-resolution poster with safe fallback', () {
      const old = 'https://i.ytimg.com/vi/abc123/hqdefault.jpg';
      expect(PlayerArtworkQuality.candidates(old), [
        'https://i.ytimg.com/vi/abc123/maxresdefault.jpg',
        'https://i.ytimg.com/vi/abc123/sddefault.jpg',
        old,
      ]);
    });

    test('upgrades YouTube Music artwork without changing crop parameters', () {
      const google = 'https://lh3.googleusercontent.com/abc=w120-h120-l90-rj';
      expect(PlayerArtworkQuality.candidates(google), [
        'https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj',
        google,
      ]);
      const square = 'https://lh3.googleusercontent.com/abc=s60';
      expect(PlayerArtworkQuality.candidates(square), [
        'https://lh3.googleusercontent.com/abc=s1200',
        square,
      ]);
      const current = 'https://lh3.googleusercontent.com/abc=w1400-h1400-l90-rj';
      expect(PlayerArtworkQuality.candidates(current), [current]);
    });

    test('YouTube video thumbnail has SD fallback if maxres is missing', () {
      const old = 'https://i.ytimg.com/vi/xyz/hqdefault.jpg';
      expect(PlayerArtworkQuality.candidates(old), [
        'https://i.ytimg.com/vi/xyz/maxresdefault.jpg',
        'https://i.ytimg.com/vi/xyz/sddefault.jpg',
        old,
      ]);
    });

        test('does not rewrite unknown CDNs, local files or unrelated hosts', () {
      expect(PlayerArtworkQuality.candidates('/data/app/full-cover.jpg'), [
        '/data/app/full-cover.jpg',
      ]);
      expect(PlayerArtworkQuality.candidates(null), isEmpty);
      const other = 'https://example.com/image/ab67616d00001e02xxx';
      expect(PlayerArtworkQuality.candidates(other), [other]);
    });

    test('keeps query parameters and original as a last resort', () {
      const old = 'https://is1-ssl.mzstatic.com/music/200x200bb.jpg?source=abc';
      expect(PlayerArtworkQuality.candidates(old), [
        'https://is1-ssl.mzstatic.com/music/1200x1200bb.jpg?source=abc',
        old,
      ]);
    });
  });
}
