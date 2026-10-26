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
