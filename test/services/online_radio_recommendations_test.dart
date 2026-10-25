import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/services/online_radio_recommendations.dart';

Song sample(String title, String artist, {String id = 'local'}) => Song(
  id: id,
  title: title,
  artist: artist,
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
  filePath: '/music/song.flac',
);

LokalDiscoveryTrack candidate(String title, String artist) =>
    LokalDiscoveryTrack(title: title, artist: artist);

void main() {
  test('catalogue audio/video duplicates are one recommendation', () {
    final result = pickOnlineRadio(
      seed: sample('Seed', 'Artist'),
      existing: [sample('Already played', 'Other', id: 'played')],
      candidates: [
        candidate('Seed (Official Audio)', 'Artist'),
        candidate('Already played', 'Other'),
        candidate('Fresh (Official Video)', 'New artist'),
        candidate('Fresh', 'New artist'),
        candidate('Fresh (Live)', 'New artist'),
      ],
    );
    expect(result.map((track) => track.title),
        ['Fresh (Official Video)', 'Fresh (Live)']);
  });

  test('other artists capped at two, seed artist capped at four', () {
    final result = pickOnlineRadio(
      seed: sample('Seed', 'Artist'),
      existing: const [],
      candidates: [
        for (var i = 0; i < 8; i++) candidate('Another $i', 'Artist'),
        for (var i = 0; i < 7; i++) candidate('Other $i', 'New artist'),
        candidate('Different', 'Third artist'),
      ],
      count: 20,
    );
    expect(result.where((track) => track.artist == 'Artist'), hasLength(4));
    expect(result.where((track) => track.artist == 'New artist'), hasLength(2));
    expect(result.last.artist, 'Third artist');
  });

  test('does not suggest the same recording from another provider', () {
    final result = pickOnlineRadio(
      seed: sample('Seed', 'Artist'),
      existing: [sample('Song', 'Artist 2', id: 'offline-file')],
      candidates: [
        candidate('Song (Official Audio)', 'Artist 2'),
        candidate('New', 'Artist 3'),
      ],
    );
    expect(result.single.title, 'New');
  });
}
