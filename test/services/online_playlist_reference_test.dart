import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/playlist.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/online_playlist_reference.dart';
import 'package:flick/services/queue_pre_resolver.dart';

Song online(String id, {String? remote}) => Song(
  id: id,
  title: 'Test recommendation',
  artist: 'Test artist',
  album: 'Test album',
  albumArt: 'https://lh3.googleusercontent.com/example=w120-h120',
  duration: const Duration(minutes: 4),
  fileType: 'ONLINE',
  sourcePackage: Song.pendingSourcePackage,
  remoteId: remote,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late QueuePreResolver resolver;
  setUp(() => resolver = QueuePreResolver());
  tearDown(() => resolver.reset());

  test('same recording from two providers saves as one stable reference', () {
    final yt = stableOnlinePlaylistSong(
      online('pending:somewhere', remote: 'yt:aB0_1234567'),
      resolver: resolver,
    );
    final alternate = stableOnlinePlaylistSong(
      online('discovery:elsewhere', remote: 'yt:aB0_1234567'),
      resolver: resolver,
    );
    expect(yt.id, alternate.id);
    expect(yt.id, startsWith(onlinePlaylistPrefix));
    expect(yt.remoteId, 'yt:aB0_1234567');
    expect(yt.isPending, isTrue);
    expect(yt.filePath, isNull);
  });

  test('playlist JSON round-trip registers a new stream resolver', () {
    final reference = stableOnlinePlaylistSong(
      online('pending:temporary', remote: 'yt:aB0_1234567'),
      resolver: resolver,
    );
    final playlist = Playlist(
      id: 'flow-saved',
      name: 'Saved Flow',
      createdAt: DateTime(2026),
      songIds: [reference.id],
      songSnapshots: {reference.id: PlaylistSongSnapshot.fromSong(reference)},
    );
    final restored = Playlist.fromJson(playlist.toJson());
    final pending = restoreOnlinePlaylistSong(
      reference.id,
      restored.songSnapshots[reference.id]!,
      resolver: resolver,
    );
    expect(restored.songIds, [reference.id]);
    expect(pending.id, reference.id);
    expect(pending.remoteId, 'yt:aB0_1234567');
    expect(pending.isPending, isTrue);
    expect(pending.filePath, isNull);
  });

  test('temporary URLs are not saved as playlist references', () {
    final track = online('provider:song').copyWith(
      filePath: 'https://audio.example.com/live?token=secret',
      remoteId: 'https://audio.example.com/live?token=secret',
    );
    final reference = stableOnlinePlaylistSong(track, resolver: resolver);
    final snapshot = PlaylistSongSnapshot.fromSong(reference);
    expect(snapshot.filePath, isNull);
    expect(snapshot.remoteId, isNull);
    expect(snapshot.toJson().toString(), isNot(contains('secret')));
  });
}
