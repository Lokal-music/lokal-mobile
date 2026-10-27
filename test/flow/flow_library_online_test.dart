import 'package:flick/features/flow/domain/flow_models.dart';
import 'package:flick/features/flow/flow_library.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(
  String id, {
  required String artist,
  required String title,
  String? genre,
}) => Song(
  id: id,
  title: title,
  artist: artist,
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
  genre: genre,
  filePath: '/music/$id.flac',
);

void main() {
  test('online refills respect banned recordings, genres and queue duplicates', () {
    final library = FlowLibrary(
      songs: [
        song('queued', artist: 'Artist A', title: 'Existing'),
        song('banned', artist: 'Artist B', title: 'Forbidden'),
      ],
      favoriteIds: {'queued', 'banned'},
    );
    final data = FlowData(
      bannedIds: {'banned'},
      config: FlowConfig(excludedGenres: {'Metal'}),
      session: FlowSession(trackIds: ['queued']),
    );
    final accepted = library.eligibleOnline(data, [
      song('duplicate-id', artist: 'Artist A', title: 'Existing'),
      song('banned-alt', artist: 'Artist B', title: 'Forbidden'),
      song('excluded', artist: 'Artist C', title: 'Heavy', genre: 'Metal'),
      song('new-1', artist: 'Artist D', title: 'Allowed', genre: 'Jazz'),
      song('new-2', artist: 'Artist D', title: 'Allowed'),
      song('new-3', artist: 'Artist E', title: 'Second'),
    ]);
    expect(accepted.map((s) => s.id).toList(), ['new-1', 'new-3']);
  });

  test('top-ups space artists against online discoveries appended first', () {
    final locals = [
      for (var i = 0; i < 48; i++)
        song('local-$i', artist: 'Artist ${i % 12}', title: 'Track $i'),
    ];
    final library = FlowLibrary(
      songs: locals,
      favoriteIds: locals.take(20).map((song) => song.id).toSet(),
    );
    final data = FlowData(session: FlowSession(
      trackIds: ['local-0', 'local-1', 'local-2'],
      seed: 31,
    ));
    final appended = library.topUp(
      data, trailingArtists: const ['Artist 3', 'Artist 4'],
    );
    expect(appended, isNotEmpty);
    final artists = [
      'Artist 0', 'Artist 1', 'Artist 2', 'Artist 3', 'Artist 4',
      ...appended.map((s) => s.artist),
    ];
    // Only the last three artists can block the first new pick. Later
    // picks should also avoid the most recent three when choices remain.
    for (var i = 5; i < artists.length; i++) {
      for (var j = 1; j <= 3; j++) {
        expect(artists[i], isNot(artists[i - j]),
            reason: 'duplicate artist at appended position $i');
      }
    }
  });

  test('online filtering keeps unknown genre candidates and obeys caps', () {
    final library = FlowLibrary(songs: [], favoriteIds: {});
    final accepted = library.eligibleOnline(
      FlowData(config: FlowConfig(excludedGenres: ['rock'])),
      [
        song('a', artist: 'A', title: 'A'),
        song('b', artist: 'B', title: 'B', genre: 'R&B'),
        song('c', artist: 'C', title: 'C'),
      ],
      limit: 2,
    );
    expect(accepted.map((s) => s.id).toList(), ['a', 'b']);
    expect(library.eligibleOnline(FlowData(), [song('d', artist: 'D', title: 'D')], limit: 0), isEmpty);
  });
}
