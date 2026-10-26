import 'dart:io';

import 'package:flick/features/discovery/discovery_progressive_streams.dart';
import 'package:flick/features/konnekted/library/liked_playback.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(
  String id, {
  String? sourcePackage,
  String? filePath,
  bool isExternal = true,
  String? sourceType,
}) => Song(
  id: id,
  title: 'Test song',
  artist: 'Artist',
  duration: const Duration(minutes: 4),
  fileType: 'FLAC',
  sourcePackage: sourcePackage,
  filePath: filePath,
  isExternal: isExternal,
  sourceType: sourceType,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a valid HTTP streaming handle stays playable without re-resolution', () {
    final handle = DiscoveryProgressiveStreams.instance.register(
      Uri.parse('https://streams.example.org/audio.flac'),
    );
    final current = _song(
      'http-live', sourcePackage: 'konnekted.progressive', filePath: handle,
    );
    expect(likedSongNeedsFreshSource(current), isFalse);
    expect(identical(playableLikedQueue([current]).single, current), isTrue);
  });

  test('expired HTTP and Mornye handles are re-resolved', () {
    final a = _song(
      'old-http', sourcePackage: 'konnekted.progressive',
      filePath: 'lokal-progressive://unregistered',
    );
    final b = _song(
      'old-morneye', sourcePackage: 'konnekted.morneye-live',
      filePath: 'lokal-morneye-live://audio/stale',
    );
    expect(likedSongNeedsFreshSource(a), isTrue);
    expect(likedSongNeedsFreshSource(b), isTrue);
    final next = playableLikedQueue([a, b]);
    expect(next, hasLength(2));
    expect(next.every((song) => song.isPending), isTrue);
    expect(next.map((song) => song.id).toSet(), hasLength(2));
    expect(next.any((song) => song.filePath == a.filePath), isFalse);
    expect(next.any((song) => song.filePath == b.filePath), isFalse);
  });

  test('saved stream snapshots with missing files become playable pending', () {
    final stale = _song('saved-stream', sourcePackage: 'konnekted.discovery');
    expect(likedSongNeedsFreshSource(stale), isTrue);
    final prepared = playableLikedQueue([stale]);
    expect(prepared.single.isPending, isTrue);
    expect(prepared.single.title, stale.title);
    expect(prepared.single.artist, stale.artist);
  });

  test('real downloaded files and remote library songs remain untouched', () async {
    final dir = await Directory.systemTemp.createTemp('lokal-liked-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(dir.path + '/track.flac');
    await file.writeAsBytes([0, 1, 2]);
    final download = _song(
      'downloaded', filePath: file.path, sourcePackage: 'konnekted.discovery',
    );
    final local = _song('local', filePath: file.path, isExternal: false);
    final network = _song('navidrome', sourceType: 'subsonic');
    final selection = [download, local, network];
    for (final item in selection) {
      expect(likedSongNeedsFreshSource(item), isFalse);
    }
    final playback = playableLikedQueue(selection);
    for (var i = 0; i < selection.length; i++) {
      expect(identical(playback[i], selection[i]), isTrue);
    }
  });
}
