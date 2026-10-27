import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/link/desktop_copy_favorite_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Songs implements SongRepository {
  _Songs(this.songs);
  final List<Song> songs;

  @override
  Future<List<Song>> getAllSongs() async => songs;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const remote = Song(
    id: '101', title: 'Track', artist: 'Artist',
    duration: Duration(minutes: 3), fileType: 'FLAC',
    sourceType: 'lokal', filePath: 'lokal://7/old-track',
    remoteServerId: 7, remoteId: 'old-track',
  );
  const copy = Song(
    id: '202', title: 'Track', artist: 'Artist',
    duration: Duration(minutes: 3), fileType: 'FLAC',
    filePath: '/music/Lokal Desktop/Track.flac',
    remoteServerId: 7, remoteId: 'old-track',
  );
  const otherPc = Song(
    id: '303', title: 'Track', artist: 'Artist',
    duration: Duration(minutes: 3), fileType: 'FLAC',
    sourceType: 'lokal', remoteServerId: 8, remoteId: 'old-track',
  );
  const differentRecording = Song(
    id: '404', title: 'Track', artist: 'Artist',
    duration: Duration(minutes: 3), fileType: 'FLAC',
    sourceType: 'lokal', remoteServerId: 7, remoteId: 'another-track',
  );

  test('only identical original IDs from the same PC are aliases', () {
    final redirect = desktopCopyFavoriteRedirects([
      remote, copy, otherPc, differentRecording,
    ]);
    expect(redirect, {'101': '202'});
    expect(
      canonicalDesktopCopyFavoriteIds(
          {'101', '202', '303', '404'}, redirect),
      {'202', '303', '404'},
    );
  });

  test('legacy double-likes repair on read without deleting library rows',
      () async {
    SharedPreferences.setMockInitialValues({
      'favorite_song_ids': ['101', '202', '303'],
      'favorite_song_liked_order_v1':
          '{"101":123,"202":500,"303":900}',
      'lokal.link.favorites_snapshot': ['101', '202', '303'],
    });
    final songs = _Songs([remote, copy, otherPc, differentRecording]);
    final service = FavoritesService(songRepository: songs);
    final likes = await service.getFavorites();

    expect(likes.map((song) => song.id).toSet(), {'202', '303'});
    expect(await service.getFavoriteIds(), {'202', '303'});
    expect((await service.getFavoriteRanks())['202'], 123);
    expect(await service.isFavorite('101'), true);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('lokal.link.favorites_snapshot')!.toSet(),
      {'202', '303'},
    );
    // No extra remote unlike is journaled just because duplicate IDs merged.
    expect((await songs.getAllSongs()).length, 4);
    expect((await service.getFavorites()).length, 2);
  });

  test('toggling from either duplicate row changes the same heart', () async {
    final service = FavoritesService(songRepository: _Songs([remote, copy]));
    expect(await service.toggleFavorite('101', song: remote), true);
    expect(await service.getFavoriteIds(), {'202'});
    expect(await service.isFavorite('202'), true);
    expect(await service.toggleFavorite('202', song: copy), false);
    expect(await service.getFavoriteIds(), isEmpty);
    expect(await service.getFavorites(), isEmpty);
  });

  test('identical metadata without a shared original ID stays separate',
      () async {
    final service = FavoritesService(
      songRepository: _Songs([remote, otherPc, differentRecording]),
    );
    await service.addFavorite('101', song: remote);
    await service.addFavorite('303', song: otherPc);
    await service.addFavorite('404', song: differentRecording);
    expect(await service.getFavoriteIds(), {'101', '303', '404'});
  });
}
