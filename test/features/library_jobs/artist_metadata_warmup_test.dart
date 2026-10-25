import 'dart:async';

import 'package:flick/core/utils/artist_credits.dart';
import 'package:flick/features/library_jobs/artist_metadata.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(int id, String artist) => Song(
  id: '$id',
  title: 'Song $id',
  artist: artist,
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

class _Metadata extends ArtistMetadata {
  _Metadata({super.parseCredits});
  final refreshed = <String>[];
  @override
  Future<void> refresh(String name, {bool force = false}) async {
    refreshed.add(name);
  }
}

void main() {
  test(
    '5500-song warmup yields and only parses changed credit pairs',
    () async {
      var parsed = 0;
      final worker = _Metadata(
        parseCredits: (song) {
          parsed++;
          return songArtistNames(song);
        },
      );
      final container = ProviderContainer(
        overrides: [artistMetadataProvider.overrideWith(() => worker)],
      );
      addTearDown(container.dispose);
      container.read(artistMetadataProvider);
      final songs = [for (var i = 0; i < 5500; i++) song(i, 'Artist $i')];
      worker.warm(songs);
      expect(parsed, 0); // The library listener itself does no credit parsing.
      var parsedAtYield = -1;
      Timer.run(() => parsedAtYield = parsed);
      await worker.warmupIdle;
      expect(parsedAtYield, inInclusiveRange(1, 64));
      expect(parsed, 5500);
      worker.warm(
        songs.map((s) => s.copyWith(albumArt: '/new/cover.jpg')).toList(),
      );
      await worker.warmupIdle;
      expect(parsed, 5500);
      worker.warm([songs.first.copyWith(artist: 'New Artist feat. Guest')]);
      await worker.warmupIdle;
      expect(parsed, 5501);
    },
  );

  test(
    'newer snapshots supersede queued work and dispose stops parsing',
    () async {
      final parsed = <String>[];
      final worker = _Metadata(
        parseCredits: (song) {
          parsed.add(song.artist);
          return [song.artist];
        },
      );
      final container = ProviderContainer(
        overrides: [artistMetadataProvider.overrideWith(() => worker)],
      );
      container.read(artistMetadataProvider);
      worker.warm([for (var i = 0; i < 5500; i++) song(i, 'Old $i')]);
      worker.warm([song(1, 'Newest')]);
      await worker.warmupIdle;
      expect(parsed, ['Newest']);
      worker.warm([song(2, 'Disposed')]);
      container.dispose();
      await worker.warmupIdle;
      expect(parsed, ['Newest']);
    },
  );
}
