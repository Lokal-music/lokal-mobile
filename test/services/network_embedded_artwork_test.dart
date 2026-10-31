import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/sources/network_embedded_artwork.dart';

List<int> u32(int n) => [
  (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255,
];

List<int> flacPicture(List<int> jpeg, {int kind = 3}) => [
  ...u32(kind),
  ...u32('image/jpeg'.length), ...ascii.encode('image/jpeg'),
  ...u32(0), // no description
  ...u32(300), ...u32(300), ...u32(24), ...u32(0),
  ...u32(jpeg.length), ...jpeg,
];

List<int> block(int type, List<int> body, {bool last = true}) => [
  type | (last ? 0x80 : 0),
  (body.length >> 16) & 255, (body.length >> 8) & 255,
  body.length & 255,
  ...body,
];

List<int> synchsafe(int n) => [
  (n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127,
];

final jpeg = <int>[0xff, 0xd8, 0xff, 0xe0, 0, 1, 2, 3];

void main() {
  test('recovers a FLAC front cover without downloading the audio body', () {
    final prefix = Uint8List.fromList([
      ...ascii.encode('fLaC'),
      ...block(0, List<int>.filled(34, 0), last: false),
      ...block(6, flacPicture(jpeg)),
      ...List<int>.filled(100, 55),
    ]);
    expect(extractNetworkEmbeddedArtwork(prefix), orderedEquals(jpeg));
  });

  test('prefers a FLAC front cover over an earlier back cover', () {
    final back = <int>[0xff, 0xd8, 0xff, 0xe1, 4];
    final bytes = [
      ...ascii.encode('fLaC'),
      ...block(6, flacPicture(back, kind: 4), last: false),
      ...block(6, flacPicture(jpeg)),
    ];
    expect(extractNetworkEmbeddedArtwork(bytes), orderedEquals(jpeg));
  });

  test('rejects a truncated picture and oversized claimed picture', () {
    final flac = [
      ...ascii.encode('fLaC'),
      ...block(6, flacPicture(jpeg)),
    ];
    expect(extractNetworkEmbeddedArtwork(flac.sublist(0, flac.length - 2)),
        isNull);
    final tooBigPicture = flacPicture(jpeg);
    final imageSizeOffset = tooBigPicture.length - jpeg.length - 4;
    tooBigPicture.replaceRange(imageSizeOffset, imageSizeOffset + 4,
        u32(networkEmbeddedImageMaxBytes + 1));
    expect(extractNetworkEmbeddedArtwork([
      ...ascii.encode('fLaC'),
      ...block(6, tooBigPicture),
    ]), isNull);
  });

  test('recovers ID3v2.3 APIC without loading the MP3 frames', () {
    final payload = [
      0, ...ascii.encode('image/jpeg'), 0, 3, 0, ...jpeg,
    ];
    final frame = [
      ...ascii.encode('APIC'),
      ...u32(payload.length), 0, 0,
      ...payload,
    ];
    final bytes = [
      ...ascii.encode('ID3'), 3, 0, 0,
      ...synchsafe(frame.length),
      ...frame,
      ...List<int>.filled(100, 99),
    ];
    expect(extractNetworkEmbeddedArtwork(bytes), orderedEquals(jpeg));
  });

  test('does not mistake arbitrary NAS audio or unsupported MIME for art', () {
    expect(extractNetworkEmbeddedArtwork(List<int>.filled(1024, 7)), isNull);
    final bad = flacPicture(jpeg);
    final mimeOffset = 8;
    bad.replaceRange(mimeOffset, mimeOffset + 10, ascii.encode('application'));
    expect(extractNetworkEmbeddedArtwork([
      ...ascii.encode('fLaC'),
      ...block(6, bad),
    ]), isNull);
  });

  test('never processes a prefix above its resource cap', () {
    expect(extractNetworkEmbeddedArtwork(
        Uint8List(networkArtworkPrefixBytes + 1)), isNull);
  });
}
