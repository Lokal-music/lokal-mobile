import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/konnekted/library/lokal_library_kit.dart';
import 'package:flick/models/song.dart';

const desktopOffline = Song(
  id: 'remote-offline',
  title: 'Unavailable Desktop',
  artist: 'Artist',
  duration: Duration(minutes: 2),
  fileType: 'FLAC',
  sourceType: 'lokal',
  remoteId: 'offline',
  remoteServerId: 2,
  filePath: 'lokal://2/offline',
);
const desktopCached = Song(
  id: 'remote-cached',
  title: 'Cached Desktop',
  artist: 'Artist',
  duration: Duration(minutes: 2),
  fileType: 'FLAC',
  sourceType: 'lokal',
  remoteId: 'cached',
  remoteServerId: 2,
  filePath: 'lokal://2/cached',
);
const localTrack = Song(
  id: 'local',
  title: 'Local',
  artist: 'Artist',
  duration: Duration(minutes: 2),
  fileType: 'FLAC',
  filePath: '/music/local.flac',
);

void main() {
  test(
    'a retired fallback scan never selects its delayed cached result',
    () async {
      final pending = Completer<bool>();
      var current = true;
      final selecting = firstAvailableLibraryFallback(
        [desktopCached],
        (_) => pending.future,
        stillCurrent: () => current,
      );
      current = false;
      pending.complete(true);
      expect(await selecting, isNull);
    },
  );

  test(
    'Play All prefers phone-local songs even when first is offline PC',
    () async {
      var checkedDesktop = 0;
      final selected = await firstAvailableLibraryFallback(
        [desktopOffline, desktopCached, localTrack],
        (_) async {
          checkedDesktop++;
          return true;
        },
      );
      expect(selected, same(localTrack));
      expect(checkedDesktop, 0);
    },
  );

  test(
    'Play All uses cached desktop when there are no phone-local songs',
    () async {
      final checked = <String>[];
      final selected = await firstAvailableLibraryFallback(
        [desktopOffline, desktopCached],
        (song) async {
          checked.add(song.id);
          return song.id == desktopCached.id;
        },
      );
      expect(selected, same(desktopCached));
      expect(checked, ['remote-offline', 'remote-cached']);
    },
  );

  test('Play All refuses unplayable all-desktop queue', () async {
    final selected = await firstAvailableLibraryFallback([
      desktopOffline,
    ], (_) async => false);
    expect(selected, isNull);
  });
}
