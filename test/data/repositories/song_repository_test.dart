import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';

class _UnusedIsar implements Isar {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song({required String artist, String? albumArtist}) => Song(
  id: artist,
  title: 'T',
  artist: artist,
  albumArtist: albumArtist,
  duration: Duration(seconds: 1),
  fileType: 'FLAC',
);

void main() {
  test('AC-4 identity survives MP4 rescans without inventing catalogue Atmos', () {
    final repository = SongRepository(isar: _UnusedIsar());
    for (final path in ['/music/track.ac4.atmos.mp4', '/music/track (2).ac4.atmos.mp4']) {
      final row = SongEntity()
        ..filePath = path
        ..title = 'Track'
        ..artist = 'Artist'
        ..dateAdded = DateTime(2026, 10, 29)
        ..fileType = 'MP4';
      final song = repository.songFromEntity(row);
      expect(song.fileType, 'AC-4');
      expect(song.atmosEncoded, isTrue);
      expect(song.atmosAvailable, isFalse);
    }
  });

  group('SongRepository.albumArtistForSong', () {
    test('literal Various Artists tag falls back to per-track artist', () {
      expect(
        SongRepository.albumArtistForSong(
          _song(artist: 'Kendrick Lamar', albumArtist: 'Various Artists'),
        ),
        'Kendrick Lamar',
      );
    });

    test('Various Artists track artist keeps the tag', () {
      expect(
        SongRepository.albumArtistForSong(
          _song(artist: 'Various Artists', albumArtist: 'various artists'),
        ),
        'various artists',
      );
    });

    test('real albumArtist tag is untouched', () {
      expect(
        SongRepository.albumArtistForSong(
          _song(artist: 'Kendrick Lamar', albumArtist: 'ScHoolboy Q'),
        ),
        'ScHoolboy Q',
      );
    });
  });

  group('SongRepository.resolveGroupArtist', () {
    test('single artist stays as-is', () {
      expect(SongRepository.resolveGroupArtist({'Pink Floyd'}), 'Pink Floyd');
    });

    test('distinct albumArtists resolve to comma-joined names (untagged comp)',
        () {
      expect(
        SongRepository.resolveGroupArtist({'A Tribe Called Quest', 'De La Soul'}),
        'A Tribe Called Quest, De La Soul',
      );
    });

    test('Various Artists tag stays stable when mixed with poisoned values',
        () {
      expect(
        SongRepository.resolveGroupArtist(
          {'Various Artists', 'Kanye West', 'Jay‑Z'},
        ),
        'Various Artists',
      );
    });

    test('empty/blank values fall back to Unknown Artist', () {
      expect(SongRepository.resolveGroupArtist({''}), 'Unknown Artist');
      expect(SongRepository.resolveGroupArtist(<String>{}), 'Unknown Artist');
    });
  });
}
