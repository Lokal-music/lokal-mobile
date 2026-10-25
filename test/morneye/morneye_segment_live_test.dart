import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/morneye/morneye_host.dart';
import 'package:flick/features/morneye/morneye_live_playback.dart';

List<int> flacHeader() {
  final bytes = List<int>.filled(42, 0);
  bytes.setRange(0, 4, [0x66, 0x4c, 0x61, 0x43]);
  bytes[7] = 34;
  bytes[18] = (44100 >> 12) & 255;
  bytes[19] = (44100 >> 4) & 255;
  bytes[20] = ((44100 & 15) << 4);
  bytes[21] = 0xf0;
  return bytes;
}

void main() {
  test('only explicit byte lengths can authorize segmented live playback', () {
    expect(morneyeKnownSegmentTotal([
      {'url': 'https://cdn.example/s1', 'contentLength': 65000},
      {'url': 'https://cdn.example/s2', 'byte_length': 100000},
    ]), 165000);
    expect(morneyeKnownSegmentTotal([
      {'duration': 65000},
      {'sizeBytes': 100000},
    ]), isNull, reason: 'Track duration must never be mistaken for byte length');
    expect(morneyeKnownSegmentTotal(['https://cdn.example/segment']), isNull);
    expect(morneyeKnownSegmentTotal([
      {'sizeBytes': -5},
    ]), isNull);
    expect(morneyeKnownSegmentTotal([
      {'sizeBytes': 3 * 1024 * 1024 * 1024},
      {'sizeBytes': 2 * 1024 * 1024 * 1024},
    ]), isNull, reason: 'Guard the maximum aggregate audio size');
  });

  test('Tidal raw FLAC can play from contiguous segments without full buffer',
      () async {
    final temp = await Directory.systemTemp.createTemp('lokal_segments_');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/tidal.flac.part';
    final file = File(path);
    final initial = [...flacHeader(), ...List<int>.filled(65536 - 42, 1)];
    await file.writeAsBytes(initial);

    final session = MorneyeLiveSession();
    const segmentTotal = 100000;
    session.observe(MorneyeTransfer(
      part: path, file: '${temp.path}/tidal.flac',
      total: segmentTotal, written: initial.length,
    ));
    await session.playable.timeout(const Duration(seconds: 1));
    expect(session.bitDepth, 16);
    expect(session.sampleRate, 44100);
    final response = await session.request(0, segmentTotal);
    expect(response.sourceLength, segmentTotal);
    expect(response.contentType, 'audio/flac');
    final future = response.stream.expand((chunk) => chunk).toList();
    await file.writeAsBytes(List<int>.filled(segmentTotal - initial.length, 2),
        mode: FileMode.append);
    session.observe(MorneyeTransfer(
      part: path, file: '${temp.path}/tidal.flac',
      total: segmentTotal, written: segmentTotal,
    ));
    final collected = await future.timeout(const Duration(seconds: 2));
    expect(collected.length, segmentTotal);
    expect(collected.last, 2);
  });

  test('encrypted or non-FLAC Tidal segment data stays on full-file fallback',
      () async {
    final temp = await Directory.systemTemp.createTemp('lokal_segments_');
    addTearDown(() => temp.delete(recursive: true));
    final part = File('${temp.path}/tidal.flac.part');
    await part.writeAsBytes(List<int>.filled(65536, 0xab));
    final session = MorneyeLiveSession();
    session.observe(MorneyeTransfer(
      part: part.path, file: '${temp.path}/tidal.flac',
      total: 100000, written: 65536,
    ));
    expect(session.isPlayable, isFalse);
  });
}
