import 'dart:convert';

import 'package:flick/features/konnekted/library/lokal_song_browser.dart';
import 'package:flick/features/konnekted/library/lokal_song_filter.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(String id, String title, DateTime added) => Song(
  id: id,
  title: title,
  artist: 'Artist',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
  dateAdded: added,
);

void main() {
  final oldLibrarySong = _song('new-like', 'Zebra', DateTime(2020));
  final newLibrarySong = _song('old-like', 'Alpha', DateTime(2026));

  test('Likes newest-first follows heart dates, not file-import dates', () {
    final likedRanks = {'old-like': 100, 'new-like': 200};
    final tracks = [newLibrarySong, oldLibrarySong];

    tracks.sort((a, b) => compareSongAddedOrder(
      a, b, descending: true, likedRanks: likedRanks,
    ));
    expect(tracks.first.id, 'new-like');

    tracks.sort((a, b) => compareSongAddedOrder(
      a, b, descending: false, likedRanks: likedRanks,
    ));
    expect(tracks.first.id, 'old-like');

    // Every other library page must continue sorting by actual dateAdded.
    tracks.sort((a, b) => compareSongAddedOrder(
      a, b, descending: true,
    ));
    expect(tracks.first.id, 'old-like');
  });

  test('Likes view roundtrips direction, sort, location, format and search', () {
    const settings = LokalSongBrowserViewSettings(
      sort: LokalSongSort.artist,
      descending: true,
      location: LokalSongLocation.phone,
      audioFilter: 'format:16:44100',
      query: 'Soundtrack',
    );
    final decoded = LokalSongBrowserViewSettings.decode(
      jsonEncode(settings.toJson()),
    );
    expect(decoded, isNotNull);
    expect(decoded!.sort, LokalSongSort.artist);
    expect(decoded.descending, isTrue);
    expect(decoded.location, LokalSongLocation.phone);
    expect(decoded.audioFilter, 'format:16:44100');
    expect(decoded.query, 'Soundtrack');
  });

  test('malformed settings and removed format/quality names are safe', () {
    expect(LokalSongBrowserViewSettings.decode('{broken'), isNull);
    final restored = LokalSongBrowserViewSettings.decode(jsonEncode({
      'sort': 'original',
      'descending': false,
      'location': 'invalid-location',
      'audioFilter': 'quality:gone',
      'query': 'ok',
    }));
    expect(restored!.sort, LokalSongSort.recentlyAdded);
    expect(restored.descending, isFalse);
    expect(restored.location, LokalSongLocation.all);
    expect(restored.audioFilter, 'all');
  });
}
