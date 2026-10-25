import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flutter/foundation.dart';

import 'morneye_host.dart';

/// Read a genuine, still-growing FLAC file through just_audio's ranged local
/// audio proxy. Never expose a guest URL, credentials, or its staging path as
/// a persisted Song. This mirrors desktop's Morneye liveResponse() path.
///
/// Eligible sources are single-file, unprocessed FLAC downloads or complete-
/// header, unencrypted, fast-start M4A audio with a known Content-Length.
/// Tidal DASH segment concatenation, DRM/decryption, post-processing and
/// explicit Atmos are intentionally left on verified full-file playback.
class MorneyeLiveSession {
  static const minReadyBytes = 64 * 1024;
  static const _readChunkBytes = 256 * 1024;
  static const _stallTimeout = Duration(seconds: 45);
  static const _pollInterval = Duration(milliseconds: 100);

  final Completer<void> _ready = Completer<void>();
  String? _part;
  String? _downloaded;
  String? _cached;
  int _written = 0;
  int _total = 0;
  bool _transferred = false;
  bool _invalid = false;
  Object? _error;
  DateTime _lastMovement = DateTime.now();

  Future<void> get playable => _ready.future;
  bool get isPlayable => _ready.isCompleted && !_invalid;
  bool get isTransferring => isPlayable && !_transferred;
  int get total => _total;
  // FLAC STREAMINFO records the actual encoding in the stream header.
  int? _sampleRate, _bitDepth;
  String? _mediaType;
  String? get mediaType => _mediaType;
  String? get fileType => _mediaType == 'audio/flac' ? 'FLAC' :
      _mediaType == 'audio/mp4' ? 'ONLINE' : null;
  int? get sampleRate => _sampleRate;
  int? get bitDepth => _bitDepth;

  @visibleForTesting
  static ({int bitDepth, int sampleRate})? readFlacStreamInfo(List<int> bytes) {
    if (bytes.length < 22 || bytes[0] != 0x66 || bytes[1] != 0x4c ||
        bytes[2] != 0x61 || bytes[3] != 0x43 ||
        (bytes[4] & 0x7f) != 0 ||
        ((bytes[5] << 16) | (bytes[6] << 8) | bytes[7]) != 34) {
      return null;
    }
    final rate = (bytes[18] << 12) | (bytes[19] << 4) | (bytes[20] >> 4);
    final bits = (((bytes[20] & 1) << 4) | (bytes[21] >> 4)) + 1;
    if (rate < 8000 || rate > 768000 || bits < 8 || bits > 32) return null;
    return (bitDepth: bits, sampleRate: rate);
  }

  /// Recognize only complete, unencrypted and self-describing headers.
  /// An arbitrary file extension or an add-on's "FLAC requested" setting
  /// alone is insufficient evidence that playback can start.
  @visibleForTesting
  static String? playableMime(List<int> prefix, String fileName) {
    if (prefix.length < 42) return null;
    final extension = fileName.toLowerCase();
    if (extension.endsWith('.flac')) {
      return readFlacStreamInfo(prefix) == null ? null : 'audio/flac';
    }
    if (!extension.endsWith('.m4a') && !extension.endsWith('.mp4')) return null;
    bool atom(String name) {
      final bytes = name.codeUnits;
      for (var i = 4; i <= prefix.length - bytes.length; i++) {
        if (prefix[i] == bytes[0] &&
            prefix[i + 1] == bytes[1] &&
            prefix[i + 2] == bytes[2] &&
            prefix[i + 3] == bytes[3]) return true;
      }
      return false;
    }
    // MP4 must start with ftyp and contain a complete, fast-start moov atom.
    if (prefix.length < 16 ||
        String.fromCharCodes(prefix.sublist(4, 8)) != 'ftyp' ||
        !atom('moov')) return null;
    // Never hand encrypted/delayed-conversion Amazon or Tidal media to the
    // Android player before the addon has decrypted/validated it.
    if (atom('sinf') || atom('schm') || atom('enca') || atom('encv') ||
        atom('pssh') || atom('drms')) return null;
    if (!atom('mp4a') && !atom('alac')) return null;
    return 'audio/mp4';
  }

  /// Only progress from the host's actual file writer can authorize a stream.
  void observe(MorneyeTransfer info) {
    if (_error != null || _invalid || _cached != null) return;
    if (info.total <= 0 ||
        info.total > 4 * 1024 * 1024 * 1024 ||
        !(info.file.toLowerCase().endsWith('.flac') ||
          info.file.toLowerCase().endsWith('.m4a') ||
          info.file.toLowerCase().endsWith('.mp4')) ||
        info.written < 0 ||
        info.written > info.total) {
      return;
    }
    if (_part != null &&
        (_part != info.part || _downloaded != info.file ||
            (info.written < _written && !info.done))) {
      // A retry replaced the bytes backing a live decoder. Never splice
      // recordings or resume the old byte stream from a different file.
      if (_ready.isCompleted) {
        fail(StateError('Audio transfer restarted'));
        return;
      }
      _written = 0;
    }
    _part = info.part;
    _downloaded = info.file;
    _total = info.total;
    if (info.written > _written) _lastMovement = DateTime.now();
    _written = info.written;
    if (info.done) _transferred = true;
    if (!_ready.isCompleted && _written >= minReadyBytes) {
      try {
        final source = File(_transferred ? info.file : info.part);
        final handle = source.openSync();
        try {
          // 64 KiB is sufficient for a FLAC STREAMINFO or a small MP4
          // initialization atom; larger/delayed MP4 headers fall back to the
          // full-file path rather than launching a broken decoder.
          final head = handle.readSync(min(_written, minReadyBytes));
          final mime = playableMime(head, info.file);
          if (mime != null) {
            _mediaType = mime;
            if (mime == 'audio/flac') {
              final audio = readFlacStreamInfo(head);
              _sampleRate = audio?.sampleRate;
              _bitDepth = audio?.bitDepth;
            }
            _ready.complete();
          }
        } finally {
          handle.closeSync();
        }
      } on FileSystemException {
        // The writer can rename the .part between observe and open. The
        // completed-download path will take over if this remains unreadable.
      }
    }
  }

  /// Called only after validation and cache adoption have succeeded. New
  /// decoder range requests now use the permanent cache, not staged files.
  void promote(String path) {
    _cached = path;
    _transferred = true;
    _written = _total;
    _lastMovement = DateTime.now();
  }

  void fail(Object error) {
    _invalid = true;
    _error = error;
  }

  Future<RandomAccessFile> _open() async {
    for (;;) {
      if (_error != null) throw StateError('Morneye stream failed');
      for (final path in [
        if (_cached != null) _cached!,
        if (_transferred && _downloaded != null) _downloaded!,
        if (_part != null) _part!,
      ]) {
        try {
          return await File(path).open();
        } on FileSystemException {
          // A file can be renamed from .part to final and then cache.
        }
      }
      if (DateTime.now().difference(_lastMovement) > _stallTimeout) {
        throw TimeoutException('Morneye stream did not become readable');
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  // ignore: experimental_member_use
  Future<just_audio.StreamAudioResponse> request([int? start, int? end]) async {
    if (!isPlayable || _total <= 0) {
      throw StateError('Morneye stream is not playable');
    }
    final from = (start ?? 0).clamp(0, _total);
    final to = (end ?? _total).clamp(from, _total);
    return just_audio.StreamAudioResponse(
      sourceLength: _total,
      contentLength: to - from,
      offset: from,
      contentType: _mediaType ?? 'application/octet-stream',
      stream: _read(from, to),
    );
  }

  Stream<List<int>> _read(int start, int end) async* {
    final handle = await _open();
    try {
      final buffer = Uint8List(_readChunkBytes);
      var offset = start;
      while (offset < end) {
        if (_error != null) throw StateError('Morneye stream failed');
        // A stable on-disk descriptor is held across the .part -> .flac
        // rename. Seeking beyond downloaded bytes waits for the host writer.
        final available = (_cached != null || _transferred)
            ? _total
            : _written;
        if (offset < available) {
          await handle.setPosition(offset);
          final count = await handle.readInto(
            buffer, 0, min(buffer.length, min(end, available) - offset),
          );
          if (count > 0) {
            offset += count;
            yield Uint8List.fromList(Uint8List.sublistView(buffer, 0, count));
            continue;
          }
        }
        if (_transferred && _written >= _total) {
          throw StateError('Morneye stream ended before the declared length');
        }
        if (DateTime.now().difference(_lastMovement) > _stallTimeout) {
          throw TimeoutException('Morneye stream stalled');
        }
        await Future<void>.delayed(_pollInterval);
      }
    } finally {
      await handle.close();
    }
  }
}

/// The audio engine gets only a random opaque handle. Keeping the descriptor
/// in-process also prevents signed/provider paths from being persisted or
/// disclosed in notifications.
class MorneyeLiveRegistry {
  MorneyeLiveRegistry._();
  static final instance = MorneyeLiveRegistry._();

  final _random = Random.secure();
  final _streams = <String, ({MorneyeLiveSession session, DateTime created})>{};
  static const _ttl = Duration(hours: 2);

  String register(MorneyeLiveSession stream) {
    prune();
    final token = List.generate(16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final handle = 'lokal-morneye-live://audio/$token';
    _streams[handle] = (session: stream, created: DateTime.now());
    return handle;
  }

  MorneyeLiveSession? resolve(String? handle) => _streams[handle]?.session;

  void prune() {
    final now = DateTime.now();
    _streams.removeWhere((_, entry) =>
        now.difference(entry.created) > _ttl);
  }

  void clear() => _streams.clear();
}

// ignore: experimental_member_use
class MorneyeLiveAudioSource extends just_audio.StreamAudioSource {
  MorneyeLiveAudioSource(this.session);
  final MorneyeLiveSession session;

  @override
  // ignore: experimental_member_use
  Future<just_audio.StreamAudioResponse> request([int? start, int? end]) =>
      session.request(start, end);
}
