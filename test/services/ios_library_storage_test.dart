import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/ios_library_storage.dart';

void main() {
  const oldRoot = '/private/var/mobile/Containers/Data/Application/OLD';
  const newRoot = '/private/var/mobile/Containers/Data/Application/NEW';

  test(
    'an app update rebases owned files without moving sibling or remote paths',
    () {
      expect(
        relocateIosPath('$oldRoot/Documents/Music/song.flac', oldRoot, newRoot),
        '$newRoot/Documents/Music/song.flac',
      );
      expect(
        relocateIosPath(
          'file://$oldRoot/Library/Caches/art.jpg',
          oldRoot,
          newRoot,
        ),
        'file://$newRoot/Library/Caches/art.jpg',
      );
      expect(
        relocateIosPath('${oldRoot}ER/Documents/song.flac', oldRoot, newRoot),
        '${oldRoot}ER/Documents/song.flac',
      );
      expect(
        relocateIosPath('https://example.com$oldRoot/song', oldRoot, newRoot),
        'https://example.com$oldRoot/song',
      );
    },
  );

  test(
    'folder and playlist JSON preserve IDs, types and user text across updates',
    () {
      final stored = jsonEncode({
        'id': 'stable-track-id',
        'path': '$oldRoot/Documents/Music/a.wav',
        'liked': true,
        'plays': 4,
        'title': 'See $oldRoot',
        'queue': [
          {'uri': 'file://$oldRoot/Documents/Music/a.wav'},
        ],
      });
      final migrated = jsonDecode(
        relocateIosStoredValue(stored, oldRoot, newRoot) as String,
      ) as Map;
      expect(migrated['id'], 'stable-track-id');
      expect(migrated['path'], '$newRoot/Documents/Music/a.wav');
      expect(migrated['liked'], true);
      expect(migrated['plays'], 4);
      expect(migrated['title'], 'See $oldRoot');
      expect(
        migrated['queue'][0]['uri'],
        'file://$newRoot/Documents/Music/a.wav',
      );
      expect(relocateIosStoredValue('Not JSON', oldRoot, newRoot), 'Not JSON');
    },
  );
}
