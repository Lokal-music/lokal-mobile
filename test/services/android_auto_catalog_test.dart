import 'package:flutter_test/flutter_test.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/playback_context.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/android_auto_catalog.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/playlist_service.dart';
import 'package:flick/models/playlist.dart';

const _a = Song(
  id: 'local:one/track', title: 'Autumn', artist: 'Artist A',
  album: 'First Album', duration: Duration(minutes: 3), fileType: 'FLAC',
);
const _b = Song(
  id: 'local:two', title: 'Blue Sky', artist: 'Artist B',
  album: 'First Album', duration: Duration(minutes: 4), fileType: 'MP3',
);

class _Songs implements SongRepository {
  @override
  Future<List<Song>> getAllSongs() async => [_a, _b];

  @override
  Future<Map<String, List<Song>>> getSongsByAlbum() async =>
      {'First Album': [_a, _b]};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Likes implements FavoritesService {
  @override
  Future<List<Song>> getFavorites() async => [_b];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playlists implements PlaylistService {
  final playlist = Playlist(
    id: 'playlist/1',
    name: 'Road Trip',
    songIds: [_b.id, _a.id],
    createdAt: DateTime(2026),
  );

  @override
  Future<List<Playlist>> getPlaylists() async => [playlist];

  @override
  Future<Playlist?> getPlaylist(String id) async =>
      id == playlist.id ? playlist : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements PlayerService {
  Song? selected;
  List<Song>? queued;
  PlaybackContext? context;

  @override
  Future<void> play(Song song, {List<Song>? playlist, int? playlistIndex, PlaybackContext? context}) async {
    selected = song;
    queued = playlist;
    this.context = context;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AndroidAutoCatalog catalog;
  late _Player player;

  setUp(() {
    player = _Player();
    catalog = AndroidAutoCatalog(
      songs: _Songs(),
      favorites: _Likes(),
      playlists: _Playlists(),
      player: player,
    );
  });

  test('car root exposes four browsable sections', () async {
    final items = await catalog.browse(AndroidAutoCatalog.root);
    expect(items.map((e) => e['id']), [
      AndroidAutoCatalog.songs, AndroidAutoCatalog.likes,
      AndroidAutoCatalog.playlists, AndroidAutoCatalog.albums,
    ]);
    expect(items.every((e) => e['playable'] == false), isTrue);
  });

  test('song IDs are opaque and preserve path separators', () async {
    final buckets = await catalog.browse(AndroidAutoCatalog.songs);
    expect(buckets.map((e) => e['title']), containsAll(['A', 'B']));
    final songs = await catalog.browse('lokal/songs/A');
    expect(songs.single['playable'], isTrue);
    expect(songs.single['id'], isNot(contains('local:one/track')));
    expect(await catalog.playMediaId(songs.single['id'] as String), isTrue);
    expect(player.selected?.id, _a.id);
    expect(player.queued, hasLength(2));
  });

  test('liked songs are browsable and playable', () async {
    final liked = await catalog.browse(AndroidAutoCatalog.likes);
    expect(liked.single['title'], 'Blue Sky');
    expect(await catalog.playMediaId(liked.single['id'] as String), isTrue);
    expect(player.selected?.id, _b.id);
  });

  test('playlist selections preserve playlist queue order and context', () async {
    final folders = await catalog.browse(AndroidAutoCatalog.playlists);
    expect(folders.single['title'], 'Road Trip');
    final children = await catalog.browse(folders.single['id'] as String);
    expect(children.map((e) => e['title']), ['Blue Sky', 'Autumn']);
    expect(await catalog.playMediaId(children.last['id'] as String), isTrue);
    expect(player.queued?.map((s) => s.id), [_b.id, _a.id]);
    expect(player.context?.source, PlaybackSource.playlist);
    expect(player.context?.sourceId, 'playlist/1');
  });

  test('album browsing preserves source context', () async {
    final albums = await catalog.browse(AndroidAutoCatalog.albums);
    expect(albums.single['title'], 'First Album');
    final songs = await catalog.browse(albums.single['id'] as String);
    expect(songs.map((e) => e['title']), ['Autumn', 'Blue Sky']);
    expect(await catalog.playMediaId(songs.first['id'] as String), isTrue);
    expect(player.context?.source, PlaybackSource.album);
    expect(player.context?.sourceId, 'First Album');
  });

  test('car browser search returns playable results', () async {
    final results = await catalog.search('artist b');
    expect(results.single['title'], 'Blue Sky');
    expect(await catalog.playMediaId(results.single['id'] as String), isTrue);
    expect(player.selected?.id, _b.id);
    expect(await catalog.search('no match'), isEmpty);
  });

  test('car voice search queues matching library titles', () async {
    expect(await catalog.playSearch('BLUE'), isTrue);
    expect(player.selected?.id, _b.id);
    expect(await catalog.playSearch('missing title'), isFalse);
    expect(await catalog.playMediaId('lokal/track/not-valid'), isFalse);
  });
}
