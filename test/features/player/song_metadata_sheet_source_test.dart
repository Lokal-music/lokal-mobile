import 'dart:io';

import 'package:flick/features/player/widgets/song_metadata_sheet.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Song makeSong({
  String? path,
  String? sourcePackage,
  String? sourceDisplayName,
  int? fileSizeBytes,
}) => Song(
  id: 'test',
  title: 'Test title',
  artist: 'Test artist',
  duration: const Duration(seconds: 90),
  fileType: 'FLAC',
  filePath: path,
  sourcePackage: sourcePackage,
  sourceDisplayName: sourceDisplayName,
  fileSizeBytes: fileSizeBytes,
);

void main() {
  test('Morneye and HTTP add-ons display their configured names', () {
    expect(metadataSourceLabel(makeSong(
      sourcePackage: 'konnekted.morneye-live',
      sourceDisplayName: 'Tidal [Morneye]',
    )), 'Tidal [Morneye]');
    expect(metadataSourceLabel(makeSong(
      sourcePackage: 'konnekted.progressive',
      sourceDisplayName: 'Qobuz (HTTP)',
    )), 'Qobuz (HTTP)');
    expect(metadataSourceLabel(makeSong(
      sourcePackage: 'konnekted.morneye-live',
    )), 'Morneye');
    expect(metadataSourceLabel(makeSong()), 'Local file');
  });

  test('file size is exact decimal MB, not a bitrate estimate', () {
    expect(metadataFileSizeMb(12500000), '12.50 MB');
    expect(metadataFileSizeMb(1024 * 1024), '1.05 MB');
    expect(metadataFileSizeMb(null), isNull);
    expect(metadataFileSizeMb(0), isNull);
  });

  test('declared streaming bytes are used without stat-ing opaque handles', () async {
    expect(await metadataFileBytes(makeSong(
      path: 'lokal-morneye-live://audio/opaque',
      fileSizeBytes: 12500000,
    )), 12500000);
    expect(await metadataFileBytes(makeSong(
      path: 'lokal-progressive://audio/opaque',
    )), isNull);
  });

  test('local disk length is read when metadata does not have bytes', () async {
    final folder = await Directory.systemTemp.createTemp('lokal_metadata_');
    addTearDown(() async => folder.delete(recursive: true));
    final file = File('${folder.path}/sample.flac');
    await file.writeAsBytes(List<int>.filled(1200000, 1));
    expect(await metadataFileBytes(makeSong(path: file.path)), 1200000);
  });

  testWidgets('quality-tag information sheet shows both source and MB', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SongMetadataSheet(
        song: makeSong(
          sourcePackage: 'konnekted.progressive',
          sourceDisplayName: 'My Qobuz extension',
          fileSizeBytes: 25200000,
        ),
      )),
    ));
    await tester.pump();
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('My Qobuz extension'), findsOneWidget);
    expect(find.text('Size'), findsOneWidget);
    expect(find.text('25.20 MB'), findsOneWidget);
  });
}
