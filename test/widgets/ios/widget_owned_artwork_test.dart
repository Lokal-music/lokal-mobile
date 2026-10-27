import 'dart:io';

import 'package:flick/models/song.dart';
import 'package:flick/services/ios_widget_owned_artwork.dart';
import 'package:flick/services/ios_widget_snapshot_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory suite, owned;
  Song song(String id, String? artwork) => Song(
    id: id,
    title: id,
    artist: 'Artist',
    duration: const Duration(minutes: 3),
    fileType: 'FLAC',
    filePath: '/music/$id.flac',
    albumArt: artwork,
  );
  setUp(() async {
    suite = await Directory.systemTemp.createTemp('lokal-widget-art-');
    owned = await Directory('${suite.path}/owned').create();
  });
  tearDown(() async => suite.delete(recursive: true));

  test(
    'owned files and existing network-cache files are read without fetching',
    () async {
      final cover = await File('${owned.path}/cover').writeAsBytes([1, 2, 3]);
      var cacheLookups = 0;
      final loader = IosWidgetOwnedArtworkLoader(
        ownedRoots: () async => [owned],
        materializedPathFor: (_) async => null,
        cachedNetworkPathFor: (url) async {
          cacheLookups++;
          return cover.path;
        },
      );
      final images = await loader.load([
        song('local', cover.uri.toString()),
        song('cached', 'https://example.invalid/cover.jpg'),
      ]);
      expect(images.keys.toSet(), {
        iosWidgetTrackAlias('local'),
        iosWidgetTrackAlias('cached'),
      });
      expect(images.values.map((bytes) => bytes.toList()), [
        [1, 2, 3],
        [1, 2, 3],
      ]);
      expect(cacheLookups, 1);
    },
  );

  test(
    'external paths and symlinks escaping the owned roots are rejected',
    () async {
      final outside = await File('${suite.path}/outside').writeAsBytes([7]);
      final link = await Link('${owned.path}/escape').create(outside.path);
      final loader = IosWidgetOwnedArtworkLoader(
        ownedRoots: () async => [owned],
        materializedPathFor: (_) async => null,
        cachedNetworkPathFor: (_) async => outside.path,
      );
      expect(
        await loader.load([
          song('external', outside.path),
          song('link', link.path),
          song('cache-escape', 'https://example.invalid/cover'),
        ]),
        isEmpty,
      );
    },
  );

  test('per-image and aggregate budgets bound actual file reads', () async {
    final first = await File('${owned.path}/first')
        .writeAsBytes(List.filled(32, 1));
    final huge = await File('${owned.path}/huge')
        .writeAsBytes(List.filled(33, 2));
    final last = await File('${owned.path}/last')
        .writeAsBytes(List.filled(16, 3));
    final loader = IosWidgetOwnedArtworkLoader(
      ownedRoots: () async => [owned],
      materializedPathFor: (_) async => null,
      maximumImageBytes: 32,
      maximumTotalBytes: 48,
    );
    final images = await loader.load([
      song('first', first.path),
      song('huge', huge.path),
      song('over-total', first.path),
      song('last', last.path),
    ]);
    expect(images.keys.toSet(), {
      iosWidgetTrackAlias('first'),
      iosWidgetTrackAlias('last'),
    });
    expect(images.values.fold<int>(0, (n, bytes) => n + bytes.length), 48);
  });

  test(
    'missing roots skip lookups; sources are bounded to current plus twelve',
    () async {
      var lookups = 0;
      final file = await File('${owned.path}/cover').writeAsBytes([1]);
      final loader = IosWidgetOwnedArtworkLoader(
        ownedRoots: () async => [owned],
        materializedPathFor: (_) async {
          lookups++;
          return file.path;
        },
      );
      final images = await loader.load([
        for (var i = 0; i < 100; i++) song('$i', null),
      ]);
      expect(images, hasLength(13));
      expect(lookups, 13);
      final absent = IosWidgetOwnedArtworkLoader(
        ownedRoots: () async => [Directory('${suite.path}/missing')],
        materializedPathFor: (_) async {
          fail('No valid owned root');
        },
      );
      expect(await absent.load([song('a', null)]), isEmpty);
    },
  );

  test('invalid custom budgets cannot bypass the native aggregate cap', () {
    for (final budget in [0, -1, 13 * 1024 * 1024]) {
      expect(
        () => IosWidgetOwnedArtworkLoader(
          ownedRoots: () async => [owned],
          materializedPathFor: (_) async => null,
          maximumTotalBytes: budget,
        ),
        throwsArgumentError,
      );
    }
  });
  test(
    'an evicted raw cover can use an already materialized owned replacement',
    () async {
      final cover = await File('${owned.path}/materialized')
          .writeAsBytes([8, 9]);
      final loader = IosWidgetOwnedArtworkLoader(
        ownedRoots: () async => [owned],
        materializedPathFor: (_) async => cover.path,
      );
      final images = await loader.load([song('a', '${owned.path}/evicted')]);
      expect(images.values.single, [8, 9]);
    },
  );
}
