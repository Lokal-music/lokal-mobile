import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/spotify/provider_playlist_track_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const track = LokalDiscoveryTrack(title: 'Saved track', artist: 'Artist');

  testWidgets('tap plays provider playlist track, without opening its actions', (tester) async {
    var plays = 0;
    var menus = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProviderPlaylistTrackTile(
          track: track,
          leading: const Icon(Icons.music_note),
          onPlay: () => plays++,
          onSongActions: () => menus++,
        ),
      ),
    ));

    await tester.tap(find.text('Saved track'));
    await tester.pump();
    expect(plays, 1);
    expect(menus, 0);
  });

  testWidgets('long press opens provider song actions without starting playback', (tester) async {
    var plays = 0;
    var menus = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProviderPlaylistTrackTile(
          track: track,
          leading: const Icon(Icons.music_note),
          onPlay: () => plays++,
          onSongActions: () => menus++,
        ),
      ),
    ));

    await tester.longPress(find.text('Saved track'));
    await tester.pump();
    expect(plays, 0);
    expect(menus, 1);
  });
}
