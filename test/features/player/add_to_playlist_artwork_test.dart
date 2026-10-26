import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/library/lokal_playlists.dart';
import 'package:flick/features/player/widgets/add_to_playlist_sheet.dart';
import 'package:flick/models/playlist.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/playlist_provider.dart';
import 'package:flick/services/link/library_song_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _track = Song(
  id: 'track-1',
  title: 'Track One',
  artist: 'Artist',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
);

final _owned = Playlist(
  id: 'owned',
  name: 'My playlist',
  songIds: [_track.id],
  createdAt: DateTime(2026),
);

final _empty = Playlist(
  id: 'empty',
  name: 'Empty playlist',
  createdAt: DateTime(2026),
);

class _FixturePlaylistsNotifier extends PlaylistsNotifier {
  @override
  Future<PlaylistsState> build() async =>
      PlaylistsState(isLoading: false, playlists: [_owned, _empty]);
}

void main() {
  testWidgets('Add to playlist uses actual Library artwork and empty fallback',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistsProvider.overrideWith(_FixturePlaylistsNotifier.new),
          konnektedLibraryIndexProvider.overrideWith(
            (ref) => AsyncData(preferredLibrarySongIndex([_track])),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: AddToPlaylistSheet(songs: [_track])),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final artwork = tester
        .widgetList<LokalPlaylistArtwork>(find.byType(LokalPlaylistArtwork))
        .toList();
    expect(artwork, hasLength(2));
    // This song was already in a playlist; the existing checked/disabled
    // selection state does not suppress the playlist's artwork.
    expect(artwork.first.playlist.id, 'owned');
    expect(artwork.first.songs.map((song) => song.id), ['track-1']);
    expect(artwork.last.playlist.id, 'empty');
    expect(artwork.last.songs, isEmpty);

    expect(find.text('My playlist'), findsOneWidget);
    expect(find.text('Empty playlist'), findsOneWidget);
  });
}
