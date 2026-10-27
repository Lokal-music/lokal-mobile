import 'dart:convert';

import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/ios_widget_snapshot_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final timestamp = DateTime.utc(2026, 10, 27);
  const song = Song(
    id: 'https://provider.invalid/song?token=DO_NOT_EXPORT',
    title: 'Canonical song',
    artist: 'Canonical artist',
    album: 'Canonical album',
    duration: Duration(minutes: 5),
    fileType: 'FLAC',
    filePath: '/private/container/Music/secret.flac',
    remoteId: 'private:remote-id',
    albumArt: 'https://provider.invalid/cover?token=DO_NOT_EXPORT',
  );

  test(
    'canonical state supplies actual clock and theme with opaque identities',
    () {
      final snapshot = buildIosWidgetSnapshot(
        const PlayerState(
          currentSong: song,
          isPlaying: true,
          position: Duration(seconds: 2),
          duration: Duration(seconds: 12),
          playbackSpeed: 1.5,
          upNext: [song],
        ),
        updatedAt: timestamp,
        revision: 7,
        accentArgb: 0xff123456,
        artworkNamesBySongId: {song.id: '${'b' * 64}.png'},
        flowKind: IosWidgetFlowKind.radio,
        flowStatus: 'Radio ready',
      );
      final data = snapshot.toJson();
      expect(data['revision'], 7);
      expect(data['lastArtwork'], '${'b' * 64}.png');
      expect(data['positionMs'], 2000);
      expect(
        data['durationMs'],
        12000,
      ); // Not the file metadata's five minutes.
      expect(data['queueCount'], 1);
      expect(data['accentArgb'], 0xff123456.toSigned(32));
      expect(data['flowKind'], 'radio');
      expect(data['updatedAtMs'], timestamp.millisecondsSinceEpoch);
      expect((data['current'] as Map)['id'], iosWidgetTrackAlias(song.id));
      expect((data['current'] as Map)['artwork'], '${'b' * 64}.png');
      expect(
        snapshot.projectedPositionAt(timestamp.millisecondsSinceEpoch + 1000),
        3500,
      );
      final wire = snapshot.encode();
      for (final private in [
        'DO_NOT_EXPORT',
        '/private/',
        'private:remote-id',
        'https://',
      ]) {
        expect(wire, isNot(contains(private)));
      }
      expect((data['current'] as Map).keys.toSet(), {
        'id',
        'title',
        'artist',
        'album',
        'artwork',
      });
    },
  );

  test('aliases are deterministic, domain separated and distinct for IDs', () {
    expect(
      iosWidgetTrackAlias('one'),
      '81e5f4bd665ba5e0f98220d03fb0bed4448050993aeb93baabd1cf8dd34c2806',
      reason: 'Keep the versioned alias protocol stable for app command lookup',
    );
    expect(iosWidgetTrackAlias('one'), iosWidgetTrackAlias('one'));
    expect(iosWidgetTrackAlias('one'), matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(iosWidgetTrackAlias('one'), isNot(iosWidgetTrackAlias('two')));
    expect(iosWidgetTrackAlias('one'), isNot(iosWidgetTrackAlias(' one')));
  });

  test('no owned artwork means no remote or sandbox artwork is exported', () {
    for (final supplied in [
      null,
      song.albumArt,
      song.filePath,
      '../cover.png',
    ]) {
      final snapshot = buildIosWidgetSnapshot(
        const PlayerState(currentSong: song),
        updatedAt: timestamp,
        revision: 7,
        accentArgb: 0,
        artworkNamesBySongId: supplied == null ? {} : {song.id: supplied},
      );
      expect((snapshot.toJson()['current'] as Map)['artwork'], isNull);
    }
  });

  test('a cleared song does not serialize playing or the old audio clock', () {
    final data = buildIosWidgetSnapshot(
      const PlayerState(
        isPlaying: true,
        position: Duration(seconds: 5),
        duration: Duration(seconds: 12),
      ),
      updatedAt: timestamp,
      revision: 7,
      accentArgb: 0,
    ).toJson();
    expect(data['current'], isNull);
    expect(data['isPlaying'], isFalse);
    expect(data['positionMs'], 0);
    expect(data['durationMs'], 0);
  });

  test('recommendation work is bounded without contacting a catalogue', () {
    var visited = 0;
    Iterable<Song> unbounded() sync* {
      while (true) {
        yield song.copyWith(id: 'local:${visited++}');
      }
    }

    final data = buildIosWidgetSnapshot(
      const PlayerState(currentSong: song),
      updatedAt: timestamp,
      revision: 7,
      accentArgb: 0,
      recommendations: unbounded(),
    ).toJson();
    expect(visited, 48);
    expect(data['recommendations'], hasLength(12));
    final names = (data['recommendations'] as List).cast<Map>();
    expect(names.map((row) => row['id']).toSet(), hasLength(12));
    expect(jsonEncode(data), isNot(contains('local:')));
  });
}
