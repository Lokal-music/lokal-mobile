import 'package:flick/models/song.dart';
import 'package:flick/services/link/library_song_identity.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(
  String id,
  String title,
  String path, {
  String artist = 'Artist',
  String? album = 'Album',
  String? source,
  Duration duration = const Duration(minutes: 3),
}) => Song(
  id: id,
  title: title,
  artist: artist,
  album: album,
  duration: duration,
  fileType: 'FLAC',
  filePath: path,
  sourceType: source,
);

void main() {
  test(
    '5500 phone songs retain order, identity and lookups without desktop rows',
    () {
      final library = [
        for (var i = 0; i < 5500; i++)
          song('$i', 'Song $i (2011 Remaster)', '/music/$i.flac'),
      ];
      final remote = song(
        'remote',
        'Remote',
        'webdav://1/song',
        source: 'webdav',
      );
      final ghost = song('ghost', 'Ghost', 'ghost://1/song', source: 'lokal');
      final index = preferredLibrarySongIndex([...library, remote, ghost]);
      expect(index.visible, [...library, remote]);
      expect(index.byId.length, 5501);
      for (final original in library) {
        expect(identical(index.byId[original.id], original), true);
      }
      expect(index.byId['ghost'], isNull);
    },
  );


  test('history ghosts stay hidden, desktop-only songs stay available', () {
    final local = song('1', 'Local', '/music/local.flac');
    final duplicate = song('2', 'Local', 'lokal://1/2', source: 'lokal');
    final ghost = song(
      '3',
      'Streamed once',
      'ghost://desktop/1/3',
      source: 'lokal',
    );
    final owned = song('4', 'PC file', 'lokal://1/4', source: 'lokal');
    expect(
      preferLocalLibrarySongs([local, duplicate, ghost, owned])
          .map((s) => s.id),
      ['1', '4'],
    );
  });

  test('mobile version wins over desktop featured-credit variant', () {
    final phone = song(
      'phone',
      'Sun Is Rising',
      '/storage/emulated/0/Music/sun.flac',
      artist: 'Ships of the Pharaohs, Last Nubian',
      duration: const Duration(minutes: 4, seconds: 3),
    );
    final desktop = song(
      'pc',
      'Sun Is Rising',
      'lokal://1/track',
      artist: 'Ships of the Pharaohs',
      source: 'lokal',
      duration: const Duration(minutes: 4, seconds: 2),
    );
    expect(preferLocalLibrarySongs([desktop, phone]).map((s) => s.id),
        ['phone']);
    // Deduplication must work independently of incoming sort order.
    expect(preferLocalLibrarySongs([phone, desktop]).map((s) => s.id),
        ['phone']);
  });

  test('credits and recording title normalize without fuzzy lookalikes', () {
    final local = song('phone', 'Halo (2011 Remaster)',
        '/storage/Music/halo.flac', artist: 'Beyoncé feat. Jay-Z');
    final pc = song('pc', 'Halo', 'lokal://1/2',
        artist: 'Beyonce', source: 'lokal');
    // A punctuation-normalized, version-labeled track is not a second copy.
    expect(preferLocalLibrarySongs([local, pc]).map((s) => s.id),
        ['phone']);
  });

  test('different versions, masters and artists remain separate', () {
    final local = song('phone', 'Sun Is Rising',
        '/storage/Music/sun.flac', artist: 'Ships of the Pharaohs',
        duration: const Duration(minutes: 4, seconds: 3));
    final wrongArtist = song('otherArtist', 'Sun Is Rising',
        'lokal://1/other', artist: 'Another Artist', source: 'lokal',
        duration: const Duration(minutes: 4, seconds: 3));
    final remix = song('remix', 'Sun Is Rising (Remix)',
        'lokal://1/remix', artist: 'Ships of the Pharaohs',
        source: 'lokal', duration: const Duration(minutes: 4, seconds: 3));
    final differentLength = song('long', 'Sun Is Rising',
        'lokal://1/long', artist: 'Ships of the Pharaohs',
        source: 'lokal', duration: const Duration(minutes: 4, seconds: 8));
    final differentAlbum = song('otherAlbum', 'Sun Is Rising',
        'lokal://1/album', artist: 'Ships of the Pharaohs',
        album: 'Different Release', source: 'lokal',
        duration: const Duration(minutes: 4, seconds: 3));
    expect(
      preferLocalLibrarySongs([
        local, wrongArtist, remix, differentLength, differentAlbum
      ]).map((s) => s.id),
      ['phone', 'otherArtist', 'remix', 'long', 'otherAlbum'],
    );
  });

  test('no local copy: keep a remotely synced recording', () {
    final remote = song('remote', 'PC only', 'lokal://1/remote',
        source: 'lokal');
    final server = song('navidrome', 'Server only', 'subsonic://7/remote',
        source: 'subsonic');
    expect(preferLocalLibrarySongs([remote, server]).map((s) => s.id),
        ['remote', 'navidrome']);
  });

  test('unknown durations, ghosts and pending local sources cannot hide PCs',
      () {
    final pc = song('pc', 'Track', 'lokal://1/track', source: 'lokal');
    final emptyLength = song('empty', 'Track', '/music/unknown.flac',
        duration: Duration.zero);
    final noPath = song('noPath', 'Track', '',
        duration: const Duration(minutes: 3));
    final ghost = song('ghost', 'Track', 'ghost://desktop/track',
        source: 'lokal');
    expect(
      preferLocalLibrarySongs([pc, emptyLength, noPath, ghost])
          .map((s) => s.id),
      ['pc', 'empty', 'noPath'],
    );
  });

  test('missing album on one side still resolves a strong recording match', () {
    final phone = song('phone', 'Sun Is Rising', '/music/sun.flac',
        album: '', artist: 'Ships of the Pharaohs');
    final pc = song('pc', 'Sun Is Rising', 'lokal://1/a',
        album: 'Greatest Hits', artist: 'Ships of the Pharaohs',
        source: 'lokal');
    expect(preferLocalLibrarySongs([pc, phone]).map((s) => s.id),
        ['phone']);
  });
  test('playlist lookup retains IDs hidden by deduplication', () {
    final phone = song('phone', 'Same song', '/music/song.flac');
    final desktop = song('desktop', 'Same song', 'lokal://1/song',
        source: 'lokal');
    final ghost = song('ghost', 'History', 'ghost://1/history',
        source: 'lokal');
    final index = preferredLibrarySongIndex([desktop, phone, ghost]);

    expect(index.visible.map((s) => s.id), ['phone']);
    expect(index.byId['desktop'], same(phone));
    expect(index.byId['phone'], same(phone));
    expect(index.byId.containsKey('ghost'), isFalse);
  });

  test('a nonmatching desktop version keeps its own playlist identity', () {
    final phone = song('phone', 'Same song', '/music/song.flac');
    final remix = song('remix', 'Same song (Live)', 'lokal://1/live',
        source: 'lokal');
    final index = preferredLibrarySongIndex([phone, remix]);
    expect(index.byId['remix'], same(remix));
    expect(index.visible, [phone, remix]);
  });
}
