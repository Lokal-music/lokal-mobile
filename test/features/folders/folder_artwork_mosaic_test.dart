import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/folders/widgets/folder_artwork_mosaic.dart';
import 'package:flick/models/song.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

Song _song(String id, {String? artwork}) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  albumArt: artwork,
  filePath: '/music/$id.flac',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

Widget _preview(List<Song> songs) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox.square(
        dimension: 180,
        child: FolderArtworkMosaic(songs: songs),
      ),
    ),
  ),
);

void main() {
  test('one cover for any track count is one distinct artwork', () {
    final tracks = [
      for (var i = 0; i < 150; i++) _song('$i', artwork: '/art/album.jpg'),
    ];
    expect(FolderArtworkMosaic.distinctCoverSongs(tracks), hasLength(1));
    expect(FolderArtworkMosaic.distinctCoverSongs(tracks).single.id, '0');
    expect(
      FolderArtworkMosaic.distinctCoverSongs([
        _song('no-cover'),
        _song('has-cover', artwork: '/art/album.jpg'),
        _song('blank-cover', artwork: '  '),
      ]).single.id,
      'has-cover',
    );
  });

  test('multiple covers retain at most four unique images', () {
    final selected = FolderArtworkMosaic.distinctCoverSongs([
      _song('no-cover'),
      _song('one', artwork: '/art/a.jpg'),
      _song('same', artwork: '/art/a.jpg'),
      _song('two', artwork: '/art/b.jpg'),
      _song('three', artwork: '/art/c.jpg'),
      _song('four', artwork: '/art/d.jpg'),
      _song('five', artwork: '/art/e.jpg'),
    ]);
    expect(selected.map((song) => song.id), ['one', 'two', 'three', 'four']);
    expect(FolderArtworkMosaic.distinctCoverSongs([_song('none')]), isEmpty);
  });

  testWidgets('one cover fills the square without a 2x2 grid', (tester) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('folder-cover-single-'),
    ))!;
    addTearDown(() async => dir.delete(recursive: true));
    final artwork = File('${dir.path}/art.png');
    await tester.runAsync(
      () => artwork.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/9qkAAAAASUVORK5CYII=',
        ),
      ),
    );
    final sharedArtwork = [
      for (var i = 0; i < 12; i++) _song('$i', artwork: artwork.path),
    ];

    await tester.pumpWidget(_preview(sharedArtwork));
    expect(
      find.byType(GridView),
      findsNothing,
      reason: 'one cover is rendered as one continuous image',
    );
    expect(find.byType(CachedImageWidget), findsOneWidget);
    final fullSize = tester
        .widget<CachedImageWidget>(find.byType(CachedImageWidget))
        .thumbnailWidth!;
    expect(fullSize, greaterThan(0));
    expect(
      tester
          .widget<CachedImageWidget>(find.byType(CachedImageWidget))
          .thumbnailHeight,
      fullSize,
    );

    await tester.pumpWidget(
      _preview([
        sharedArtwork.first,
        _song('other', artwork: '${dir.path}/other.png'),
      ]),
    );
    expect(
      find.byType(GridView),
      findsOneWidget,
      reason: 'two distinct covers keep the 2x2 collage',
    );
    expect(find.byType(CachedImageWidget), findsNWidgets(2));
    final mosaicSize = tester
        .widget<CachedImageWidget>(find.byType(CachedImageWidget).first)
        .thumbnailWidth!;
    expect(
      fullSize,
      greaterThan(mosaicSize),
      reason: 'the single-cover thumbnail uses full tile resolution',
    );

    await tester.pumpWidget(_preview(sharedArtwork));
    expect(
      find.byType(GridView),
      findsNothing,
      reason: 'changing back to a single cover removes the mosaic',
    );
    expect(find.byType(CachedImageWidget), findsOneWidget);
  });

  testWidgets('folders with no covers keep the existing placeholder grid', (
    tester,
  ) async {
    await tester.pumpWidget(
      _preview([_song('no-cover-one'), _song('no-cover-two')]),
    );
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(CachedImageWidget), findsNothing);
  });
}
