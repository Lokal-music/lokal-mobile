import 'dart:convert';
import 'dart:typed_data';

/// A bounded prefix read is enough for the common FLAC PICTURE and MP3 APIC
/// tags, without downloading an entire NAS audio file just to paint an album.
/// A missing or later-placed picture is a cache miss, not a reason to fetch
/// arbitrarily large media while playback is active.
const int networkArtworkPrefixBytes = 4 * 1024 * 1024;
const int networkEmbeddedImageMaxBytes = 3 * 1024 * 1024;

int? _u32(Uint8List data, int offset) {
  if (offset < 0 || offset + 4 > data.length) return null;
  return (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];
}

int? _synchsafe(Uint8List data, int offset) {
  if (offset < 0 || offset + 4 > data.length) return null;
  if (data.skip(offset).take(4).any((byte) => (byte & 0x80) != 0)) {
    return null;
  }
  return (data[offset] << 21) |
      (data[offset + 1] << 14) |
      (data[offset + 2] << 7) |
      data[offset + 3];
}

bool _imageMime(String mime) => const {
  'image/jpeg', 'image/jpg', 'image/png', 'image/webp',
  'image/gif', 'image/bmp',
}.contains(mime.toLowerCase());

bool _imageSignature(Uint8List data, int start, int length) {
  if (length < 3 || start < 0 || start + length > data.length) return false;
  final a = data[start], b = data[start + 1], c = data[start + 2];
  return (a == 0xff && b == 0xd8 && c == 0xff) ||
      (a == 0x89 && b == 0x50 && c == 0x4e) ||
      (a == 0x47 && b == 0x49 && c == 0x46) ||
      (a == 0x42 && b == 0x4d) ||
      (length >= 12 &&
          a == 0x52 && b == 0x49 && c == 0x46 &&
          data[start + 8] == 0x57 && data[start + 9] == 0x45 &&
          data[start + 10] == 0x42 && data[start + 11] == 0x50);
}

Uint8List? _flacPicture(Uint8List data, int start, int end) {
  var p = start;
  int? take() {
    if (p + 4 > end) return null;
    final value = _u32(data, p);
    p += 4;
    return value;
  }

  final kind = take();
  final mimeLength = take();
  if (kind == null || mimeLength == null ||
      mimeLength > 256 || p + mimeLength > end) return null;
  final mime = ascii.decode(data.sublist(p, p + mimeLength),
      allowInvalid: true).toLowerCase();
  p += mimeLength;
  final descriptionLength = take();
  if (descriptionLength == null || p + descriptionLength > end) return null;
  p += descriptionLength;
  if (p + 16 > end) return null;
  p += 16; // width, height, bit depth, indexed colors
  final pictureLength = take();
  if (pictureLength == null || pictureLength <= 0 ||
      pictureLength > networkEmbeddedImageMaxBytes ||
      p + pictureLength > end || !_imageMime(mime) ||
      !_imageSignature(data, p, pictureLength)) return null;
  return Uint8List.sublistView(data, p, p + pictureLength);
}

Uint8List? _extractFlac(Uint8List data) {
  var pos = 4;
  Uint8List? fallback;
  while (pos + 4 <= data.length) {
    final header = data[pos];
    final last = (header & 0x80) != 0;
    final blockType = header & 0x7f;
    final blockLength = (data[pos + 1] << 16) |
        (data[pos + 2] << 8) | data[pos + 3];
    pos += 4;
    if (pos + blockLength > data.length) break;
    if (blockType == 6) {
      final kind = _u32(data, pos);
      final art = _flacPicture(data, pos, pos + blockLength);
      if (art != null) {
        if (kind == 3) return art; // Prefer the front cover.
        fallback ??= art;
      }
    }
    pos += blockLength;
    if (last) break;
  }
  return fallback;
}

Uint8List? _apic(Uint8List data, int start, int end) {
  if (start + 5 >= end) return null;
  final encoding = data[start];
  if (encoding > 3) return null;
  var p = start + 1;
  var mimeEnd = p;
  while (mimeEnd < end && data[mimeEnd] != 0) mimeEnd++;
  if (mimeEnd >= end || mimeEnd - p > 128) return null;
  final mime = ascii.decode(data.sublist(p, mimeEnd),
      allowInvalid: true).toLowerCase();
  p = mimeEnd + 1;
  if (!_imageMime(mime) || p >= end) return null;
  p++; // picture type
  if (encoding == 0 || encoding == 3) {
    while (p < end && data[p] != 0) p++;
    p++;
  } else {
    // UTF-16 descriptions end in two null bytes. Respect two-byte alignment.
    final descriptionStart = p;
    while (p + 1 < end && !(data[p] == 0 && data[p + 1] == 0)) p += 2;
    if (p + 1 >= end || p < descriptionStart) return null;
    p += 2;
  }
  final size = end - p;
  if (size <= 0 || size > networkEmbeddedImageMaxBytes ||
      !_imageSignature(data, p, size)) return null;
  return Uint8List.sublistView(data, p, end);
}

Uint8List? _extractId3(Uint8List data) {
  if (data.length < 10) return null;
  final version = data[3];
  if (version != 3 && version != 4) return null;
  final flags = data[5];
  // Unsynchronization and extended headers need their own decoding rules.
  // Refuse these rather than misidentifying bytes as a picture.
  if ((flags & 0xc0) != 0) return null;
  final size = _synchsafe(data, 6);
  if (size == null) return null;
  final end = (10 + size).clamp(10, data.length);
  var p = 10;
  Uint8List? fallback;
  while (p + 10 <= end) {
    if (data[p] == 0) break;
    final frame = ascii.decode(data.sublist(p, p + 4),
        allowInvalid: true);
    final frameSize = version == 4
        ? _synchsafe(data, p + 4) : _u32(data, p + 4);
    if (frameSize == null || frameSize <= 0 ||
        p + 10 + frameSize > end) break;
    if (frame == 'APIC' && data[p + 8] == 0 && data[p + 9] == 0) {
      final payloadStart = p + 10;
      final typeOffset = data.indexOf(0, payloadStart + 1);
      final kind = typeOffset >= 0 && typeOffset + 1 < p + 10 + frameSize
          ? data[typeOffset + 1] : -1;
      final image = _apic(data, payloadStart, p + 10 + frameSize);
      if (image != null) {
        if (kind == 3) return image;
        fallback ??= image;
      }
    }
    p += 10 + frameSize;
  }
  return fallback;
}

/// Extract an embedded cover from an initial FLAC/MP3 byte range.
/// Returns null when the picture is not present in the bounded prefix.
Uint8List? extractNetworkEmbeddedArtwork(List<int> prefix) {
  if (prefix.length < 10 || prefix.length > networkArtworkPrefixBytes) {
    return null;
  }
  final data = prefix is Uint8List ? prefix : Uint8List.fromList(prefix);
  if (data[0] == 0x66 && data[1] == 0x4c &&
      data[2] == 0x61 && data[3] == 0x43) return _extractFlac(data);
  if (data[0] == 0x49 && data[1] == 0x44 &&
      data[2] == 0x33) return _extractId3(data);
  return null;
}
