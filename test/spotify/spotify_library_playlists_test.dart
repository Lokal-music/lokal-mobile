import 'package:flick/features/spotify/spotify_web_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saved playlists parser includes nested and collaborative playlists', () {
    final id = List.filled(22, 'A').join();
    final id2 = List.filled(22, 'B').join();
    final rows = [
      {
        'item': {
          '__typename': 'PlaylistResponseWrapper',
          '_uri': 'spotify:playlist:$id',
          'data': {
            'name': 'Saved in folder',
            'ownerV2': {'data': {'name': 'Someone'}},
            'content': {'totalCount': 14},
            'images': {'items': [
              {'sources': [
                {'url': 'https://i.scdn.co/small', 'width': 128},
                {'url': 'https://i.scdn.co/large', 'width': 640},
              ]},
            ]},
          },
        },
      },
      {'item': {'__typename': 'FolderResponseWrapper', '_uri': 'spotify:folder:test'}},
      {
        'item': {
          '__typename': 'CollaborativePlaylistResponseWrapper',
          '_uri': 'spotify:playlist:$id2',
          'data': {'name': 'Collaborative'},
        },
      },
      {'item': {'__typename': 'PlaylistResponseWrapper', '_uri': 'bad'}},
    ];
    final result = SpotifyWebApi.parseLibraryPlaylistItems(rows);
    expect(result.map((p) => p.id), [id, id2]);
    expect(result.first.name, 'Saved in folder');
    expect(result.first.owner, 'Someone');
    expect(result.first.tracksTotal, 14);
    expect(result.first.imageUrl, 'https://i.scdn.co/large');
    expect(result.last.name, 'Collaborative');
  });

  test('invalid or unavailable data yields no invented Spotify playlists', () {
    expect(SpotifyWebApi.parseLibraryPlaylistItems(null), isEmpty);
    expect(SpotifyWebApi.parseLibraryPlaylistItems([
      {'item': {'__typename': 'FolderResponseWrapper'}},
      {'item': {'__typename': 'PlaylistResponseWrapper', '_uri': 'spotify:playlist:not-an-id', 'data': {'name': 'Invalid'}}},
    ]), isEmpty);
  });
}
