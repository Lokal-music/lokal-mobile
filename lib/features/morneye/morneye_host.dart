import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'morneye_network.dart';
import 'morneye_session.dart';
import 'morneye_storage.dart';
import 'morneye_ffmpeg.dart';

/// Answers Morneye add-ons' host calls, as desktop's
/// electron/morneye/host.js does: files inside the add-on's own folder,
/// network within its permissions, its storage and logins, and the helper
/// functions Morneye packages expect. Converting audio with FFmpeg isn't
/// available on the phone; the player decodes FLAC, ALAC, AAC, MP3, Opus and
/// Vorbis itself.

/// The native pieces: ciphers, sealing, and reading an audio file's format.
abstract class MorneyeNative implements MorneyeSealer {
  Uint8List cipher(
    Uint8List data, {
    required String algorithm,
    required String mode,
    required Uint8List key,
    required Uint8List iv,
    required bool pkcs7,
    required bool decrypt,
  });

  Future<Map<String, Object?>> mediaInfo(String path);
}

/// Runs a guest callback (a progress function it passed) with [args].
typedef MorneyeCallback = Future<void> Function(
  Object? descriptor,
  List<Object?> args, {
  bool strict,
});

/// What a whole-file download has written so far, for playing while it
/// arrives.
class MorneyeTransfer {
  const MorneyeTransfer({
    required this.part,
    required this.file,
    required this.total,
    required this.written,
    this.done = false,
  });

  final String part;
  final String file;
  final int total;
  final int written;
  final bool done;
}

/// Bytes must describe the actual segment payload, not audio duration.
@pragma('vm:entry-point')
int? morneyeSegmentBytes(Object? segment) {
  if (segment is! Map) return null;
  for (final key in ['byteLength', 'byte_length', 'contentLength',
                     'content_length', 'sizeBytes', 'size_bytes']) {
    final raw = segment[key];
    final bytes = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    if (bytes != null && bytes > 0 && bytes <= _maxAudio) return bytes;
  }
  return null;
}

int? morneyeKnownSegmentTotal(List segments) {
  var total = 0;
  for (final segment in segments) {
    final length = morneyeSegmentBytes(segment);
    if (length == null) return null;
    total += length;
    if (total > _maxAudio) return null;
  }
  return total > 0 ? total : null;
}

class MorneyeCancelled implements Exception {
  const MorneyeCancelled();
  @override
  String toString() => 'Cancelled';
}

class _HttpStatusError implements Exception {
  _HttpStatusError(this.status);
  final int status;
  @override
  String toString() => 'Download returned HTTP $status';
}

const _maxRead = 16 * 1024 * 1024;
const _maxAudio = 4 * 1024 * 1024 * 1024;

String morneyeSanitize(Object? value) {
  var text = '${value ?? ''}'.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  text = text.replaceFirst(RegExp(r'[. ]+$'), '');
  return text.length > 180 ? text.substring(0, 180) : text;
}

/// Levenshtein similarity of two strings' UTF-8 bytes, 0–1.
double morneyeCompareStrings(String left, String right) {
  final a = utf8.encode(left.trim().toLowerCase());
  final b = utf8.encode(right.trim().toLowerCase());
  if (a.isEmpty || b.isEmpty) return 0;
  if (a.length > 2000 || b.length > 2000) {
    throw ArgumentError('Matching input is too long');
  }
  var row = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final next = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      next[j] = [
        next[j - 1] + 1,
        row[j] + 1,
        row[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    row = next;
  }
  return 1 - row[b.length] / (a.length > b.length ? a.length : b.length);
}

String morneyeNormalizeString(String value) => value
    .toLowerCase()
    .replaceAll(
      RegExp(
        r'\s*[(\[](?:feat\.?|ft\.?|with|remaster(?:ed)?|official).*?[)\]]',
      ),
      '',
    )
    .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Bytes from what a guest sent: `{__bytes}`, a byte list, or encoded text.
Uint8List morneyeBytes(Object? value, [String encoding = 'base64']) {
  if (value is Map && value['__bytes'] is List) {
    return Uint8List.fromList(
      (value['__bytes'] as List).map((v) => (v as num).toInt()).toList(),
    );
  }
  if (value is List) {
    return Uint8List.fromList(value.map((v) => (v as num).toInt()).toList());
  }
  final text = '${value ?? ''}';
  switch (encoding) {
    case 'base64':
      return base64.decode(
        base64.normalize(text.replaceAll(RegExp(r'\s'), '')),
      );
    case 'base64url':
      return base64Url.decode(base64Url.normalize(text));
    case 'hex':
      if (!RegExp(r'^(?:[a-fA-F0-9]{2})*$').hasMatch(text)) {
        throw const FormatException('Invalid hex payload');
      }
      return Uint8List.fromList([
        for (var i = 0; i < text.length; i += 2)
          int.parse(text.substring(i, i + 2), radix: 16),
      ]);
    case 'utf8':
    case 'utf-8':
      return Uint8List.fromList(utf8.encode(text));
    case 'binary':
    case 'latin1':
    case 'raw':
    case 'bytes':
      return Uint8List.fromList(text.codeUnits.map((c) => c & 0xff).toList());
  }
  throw FormatException('Unsupported binary encoding');
}

/// [value] encoded for the guest.
Object morneyeEncoded(List<int> value, [String encoding = 'base64']) {
  switch (encoding) {
    case 'bytes':
    case 'raw':
      return {'__bytes': value, '__buffer': true};
    case 'hex':
      return value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    case 'base64url':
      return base64Url.encode(value);
    case 'utf8':
    case 'utf-8':
      return utf8.decode(value, allowMalformed: true);
    case 'binary':
    case 'latin1':
      return String.fromCharCodes(value);
  }
  return base64.encode(value);
}

/// The fields a WHATWG `URL` exposes.
Map<String, String> morneyeParseUrl(String input, String? base) {
  var url = base == null ? Uri.parse(input) : Uri.parse(base).resolve(input);
  if (!url.hasScheme) throw const FormatException('Invalid URL');
  if (url.path.isEmpty && url.hasAuthority) url = url.replace(path: '/');
  final scheme = url.scheme;
  final defaultPort =
      (scheme == 'https' && url.port == 443) ||
      (scheme == 'http' && url.port == 80);
  final port = url.hasPort && !defaultPort ? '${url.port}' : '';
  final host = port.isEmpty ? url.host : '${url.host}:$port';
  final userInfo = url.userInfo.split(':');
  final search = url.hasQuery && url.query.isNotEmpty ? '?${url.query}' : '';
  final hash = url.hasFragment && url.fragment.isNotEmpty
      ? '#${url.fragment}'
      : '';
  final origin = url.hasAuthority ? '$scheme://$host' : 'null';
  return {
    'href': url.toString(),
    'origin': origin,
    'protocol': '$scheme:',
    'host': host,
    'hostname': url.host,
    'port': port,
    'pathname': url.path,
    'search': search,
    'hash': hash,
    'username': userInfo.first,
    'password': userInfo.length > 1 ? userInfo.sublist(1).join(':') : '',
  };
}

String _decodeForm(String value) {
  try {
    return Uri.decodeQueryComponent(value);
  } catch (_) {
    return value.replaceAll('+', ' ');
  }
}

/// `URLSearchParams` entries of [init] (a query string or entry list).
List<List<String>> morneyeQueryEntries(Object? init) {
  if (init is List) {
    return [
      for (final entry in init)
        if (entry is List && entry.length >= 2) ['${entry[0]}', '${entry[1]}'],
    ];
  }
  if (init is Map) {
    return [
      for (final entry in init.entries) ['${entry.key}', '${entry.value}'],
    ];
  }
  var text = '${init ?? ''}';
  if (text.startsWith('?')) text = text.substring(1);
  return [
    for (final part in text.split('&'))
      if (part.isNotEmpty)
        part.contains('=')
            ? [
                _decodeForm(part.substring(0, part.indexOf('='))),
                _decodeForm(part.substring(part.indexOf('=') + 1)),
              ]
            : [_decodeForm(part), ''],
  ];
}

String _encodeForm(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final c = String.fromCharCode(byte);
    if (RegExp(r'[A-Za-z0-9*\-._]').hasMatch(c)) {
      out.write(c);
    } else if (byte == 0x20) {
      out.write('+');
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// Serializes entries the way `URLSearchParams.toString()` does.
String morneyeEncodeQuery(Object? entries) =>
    morneyeQueryEntries(entries)
        .map((e) => '${_encodeForm(e[0])}=${_encodeForm(e[1])}')
        .join('&');

/// The add-on facts the host needs.
class MorneyeAddonInfo {
  const MorneyeAddonInfo({
    required this.key,
    required this.name,
    required this.manifest,
  });

  final String key;
  final String name;
  final Map<String, Object?> manifest;

  MorneyePermissions get permissions =>
      MorneyePermissions.fromJson(manifest['permissions']);

  Map get capabilities => manifest['capabilities'] is Map
      ? manifest['capabilities'] as Map
      : const {};

  Map get downloadTransfer => capabilities['downloadTransfer'] is Map
      ? capabilities['downloadTransfer'] as Map
      : const {};
}

/// Finds the library song with an ISRC: its path, or null.
typedef MorneyeIsrcLookup = Future<String?> Function(String isrc);

class MorneyeHost {
  MorneyeHost({
    required this.addon,
    required this.storage,
    required this.network,
    required this.native,
    required String root,
    this.session,
    List<String> grants = const [],
    this.isrcLookup,
    this.onProgress,
    this.onTransfer,
    this.appVersion = '1.0.0',
    this.stallTimeout = const Duration(seconds: 30),
  }) : root = p.normalize(p.absolute(root)),
       grants = [for (final grant in grants) p.normalize(p.absolute(grant))] {
    Directory(this.root).createSync(recursive: true);
  }

  final MorneyeAddonInfo addon;
  final MorneyeStorage storage;
  final MorneyeNetwork network;
  final MorneyeSignedSession? session;
  final MorneyeNative native;
  final String root;
  final List<String> grants;
  final MorneyeIsrcLookup? isrcLookup;

  /// Download progress: a percent and/or a status message.
  final void Function({double? percent, String? message})? onProgress;
  final void Function(MorneyeTransfer transfer)? onTransfer;
  final String appVersion;

  /// How long a download may go without a byte before its connection is
  /// dropped and the download resumed.
  final Duration stallTimeout;
  final DateTime _startedAt = DateTime.now();

  bool _aborted = false;
  final _abort = Completer<void>();

  bool get aborted => _aborted;

  void abort() {
    if (_aborted) return;
    _aborted = true;
    _abort.complete();
  }

  void _check() {
    if (_aborted) throw const MorneyeCancelled();
  }

  Future<void> _sleep(Duration duration) =>
      Future.any([Future<void>.delayed(duration), _abort.future])
          .then((_) => _check());

  Map<String, Object?> get auth => network.auth;

  static bool _contained(String root, String value) =>
      value == root || p.isWithin(root, value);

  /// [raw] inside the add-on's folder or a granted one, with no links.
  String file(Object? raw) {
    if (!addon.permissions.file) throw StateError('File permission denied');
    if (raw is! String ||
        raw.isEmpty ||
        raw.contains('\u0000') ||
        (!p.isAbsolute(raw) &&
            RegExp(r'(^|[\\/])\.\.([\\/]|$)').hasMatch(raw))) {
      throw ArgumentError('Invalid addon file path');
    }
    final value = p.normalize(p.isAbsolute(raw) ? raw : p.join(root, raw));
    final allowed = [
      root,
      ...grants,
    ].where((base) => _contained(base, value)).firstOrNull;
    if (allowed == null) {
      throw StateError('File path is outside the addon sandbox');
    }
    var current = allowed;
    final parts = p
        .split(p.relative(value, from: allowed))
        .where((part) => part != '.');
    for (final part in ['.', ...parts]) {
      if (part != '.') current = p.join(current, part);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.file &&
              type != FileSystemEntityType.directory)) {
        throw StateError('Addon paths cannot contain links or special files');
      }
    }
    return value;
  }

  Future<Map<String, Object?>> transfer(
    String url,
    String destination,
    Map options,
    Future<void> Function(int written, int total) progress, {
    bool segment = false,
  }) async {
    final settings = {...addon.downloadTransfer, ...options};
    final live = segment ? null : onTransfer;
    final target = file(destination);
    await Directory(p.dirname(target)).create(recursive: true);
    final part = file('$target.part');
    final checkpoint = file('$target.checkpoint');
    final attempts = ((settings['maxAttempts'] as num?)?.toInt() ?? 3).clamp(
      1,
      6,
    );
    final resume = settings['resume'] != false;
    final urlHash = sha256.convert(utf8.encode(url)).toString();
    var validator = '';
    var written = 0;
    var total = 0;
    // The Dart↔JS guest callback is much more expensive on Android than
    // desktop's worker IPC. Sending one for every network chunk throttles
    // Qobuz itself. Keep host-byte updates immediate for live playback, but
    // limit guest/UI progress notifications to four per second.
    var lastGuestProgress = DateTime.fromMillisecondsSinceEpoch(0);
    var lastGuestWritten = -1;
    if (settings['persistentCheckpoint'] == true && resume) {
      try {
        final saved = jsonDecode(await File(checkpoint).readAsString());
        if (saved is Map && saved['urlHash'] == urlHash) {
          validator = '${saved['validator'] ?? ''}';
        }
      } catch (_) {}
    }
    for (var attempt = 1; attempt <= attempts; attempt++) {
      _check();
      final headers = <String, String>{
        if (settings['headers'] is Map)
          for (final e in (settings['headers'] as Map).entries)
            '${e.key}': '${e.value}',
      };
      var offset = 0;
      if (resume && validator.isNotEmpty) {
        final existing = File(part);
        offset = existing.existsSync() ? existing.lengthSync() : 0;
      }
      if (offset > 0) {
        headers['Range'] = 'bytes=$offset-';
        headers['If-Range'] = validator;
      }
      MorneyeResponse? response;
      RandomAccessFile? output;
      try {
        response = await network.request(
          url,
          headers: headers,
          directMedia: settings['directMedia'] == true,
        );
        final status = response.status;
        if (status < 200 || status >= 300) throw _HttpStatusError(status);
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
            .firstMatch(response.headers['content-range'] ?? '');
        if (offset > 0 &&
            (status != 206 ||
                range == null ||
                int.parse(range.group(1)!) != offset)) {
          if (status == 206) throw StateError('Invalid resumed content range');
          offset = 0;
        }
        final etag = response.headers['etag'];
        final nextValidator = etag != null && !etag.startsWith('W/')
            ? etag
            : response.headers['last-modified'] ?? '';
        if (offset > 0 && nextValidator != validator) {
          throw StateError('Download validator changed');
        }
        validator = nextValidator;
        final length = int.tryParse(response.headers['content-length'] ?? '');
        total = range != null
            ? int.parse(range.group(3)!)
            : (length == null ? 0 : length + offset);
        if (total > _maxAudio) {
          throw StateError('Addon audio exceeds the file size limit');
        }
        if (settings['persistentCheckpoint'] == true) {
          await File(checkpoint).writeAsString(
            jsonEncode({'urlHash': urlHash, 'validator': validator}),
          );
        }
        output = await File(part)
            .open(mode: offset > 0 ? FileMode.append : FileMode.write);
        written = offset;
        live?.call(
          MorneyeTransfer(
            part: part,
            file: target,
            total: total,
            written: written,
          ),
        );
        // A connection that goes quiet is dropped and resumed (desktop's
        // socket timeout): otherwise the download sits at the same
        // percentage until the add-on's day-long limit.
        await for (final chunk in response.body.timeout(stallTimeout)) {
          _check();
          await output.writeFrom(chunk);
          written += chunk.length;
          if (written > _maxAudio) {
            throw StateError('Addon audio exceeds the file size limit');
          }
          live?.call(
            MorneyeTransfer(
              part: part,
              file: target,
              total: total,
              written: written,
            ),
          );
          // Do not await a JS callback for *every* 8–64 KiB network chunk:
          // this can turn a playable Qobuz transfer into a long download.
          // Live readers still get onTransfer immediately for every chunk.
          final now = DateTime.now();
          final report = total > 0 && written == total ||
              now.difference(lastGuestProgress) >=
                  const Duration(milliseconds: 250);
          if (report) {
            lastGuestProgress = now;
            lastGuestWritten = written;
            if (!segment && total > 0) {
              onProgress?.call(percent:
                  (written * 100.0 / total).clamp(0.0, 100.0));
            }
            await progress(written, total);
          }
        }
        if (written != lastGuestWritten) {
          if (!segment && total > 0) {
            onProgress?.call(percent:
                (written * 100.0 / total).clamp(0.0, 100.0));
          }
          await progress(written, total);
        }
        if (written == 0 || (total > 0 && written != total)) {
          throw StateError('Incomplete addon audio download');
        }
        await output.close();
        output = null;
        _check();
        await File(part).rename(target);
        final saved = File(checkpoint);
        if (saved.existsSync()) await saved.delete();
        live?.call(
          MorneyeTransfer(
            part: part,
            file: target,
            total: total,
            written: written,
            done: true,
          ),
        );
        return {
          'success': true,
          'path': destination,
          'size': written,
          'attempts': attempt,
          if (offset > 0) 'resumed': true,
        };
      } catch (error) {
        await output?.close().catchError((_) {});
        output = null;
        if (_aborted) rethrow;
        if (validator.isEmpty || !resume) {
          final leftover = File(part);
          if (leftover.existsSync()) await leftover.delete();
        }
        final retryable =
            error is! _HttpStatusError ||
            const {408, 429, 500, 502, 503, 504}.contains(error.status);
        if (attempt == attempts || !retryable) rethrow;
        await _sleep(
          Duration(milliseconds: (500 * (1 << (attempt - 1))).clamp(0, 8000)),
        );
      } finally {
        await output?.close().catchError((_) {});
        await response?.close();
      }
    }
    throw StateError('Download failed');
  }

  /// Segment byte lengths are needed to expose a safe seekable stream.
  /// Prefer verified byte lengths from the manifest; optionally probe HEAD
  /// in parallel with downloading. Unsupported endpoints fall back to normal
  /// full-file preparation, never to a guessed length.
  Future<int?> _segmentTotalForLive(List segments, Map options) async {
    if (onTransfer == null || segments.length > 48) return null;
    final known = morneyeKnownSegmentTotal(segments);
    if (known != null) return known;
    Future<int?> inspect(Object? segment) async {
      final declared = morneyeSegmentBytes(segment);
      if (declared != null) return declared;
      final url = segment is String
          ? segment
          : (segment is Map ? '${segment['url'] ?? ''}' : '');
      if (url.isEmpty) return null;
      final headers = <String, String>{
        if (options['headers'] is Map)
          for (final e in (options['headers'] as Map).entries)
            '${e.key}': '${e.value}',
        if (segment is Map && segment['headers'] is Map)
          for (final e in (segment['headers'] as Map).entries)
            '${e.key}': '${e.value}',
      };
      MorneyeResponse? response;
      try {
        response = await network.request(
          url,
          method: 'HEAD',
          headers: headers,
          directMedia: options['directMedia'] == true,
          timeout: const Duration(seconds: 2),
        );
        if (response.status < 200 || response.status >= 300) return null;
        final length = int.tryParse(response.headers['content-length'] ?? '');
        return length != null && length > 0 && length <= _maxAudio
            ? length
            : null;
      } catch (_) {
        return null;
      } finally {
        await response?.close();
      }
    }

    // Cap aggregate probe time so faster segment downloads never stall
    // behind unavailable HEAD endpoints.
    Future<int?> measured() async {
      var total = 0;
      for (var i = 0; i < segments.length; i += 8) {
        final batch = await Future.wait(
          segments.skip(i).take(8).map(inspect),
        );
        if (batch.any((size) => size == null)) return null;
        for (final length in batch) {
          total += length!;
          if (total > _maxAudio) return null;
        }
      }
      return total > 0 ? total : null;
    }
    try {
      return await measured().timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>> segments(
    List segmentsList,
    String destination,
    Map options,
    MorneyeCallback callback,
  ) async {
    if (segmentsList.isEmpty || segmentsList.length > 20000) {
      throw ArgumentError('Invalid download segments');
    }
    final output = file(destination);
    final dir = file('$output.segments');
    await Directory(dir).create(recursive: true);
    final progress = <int, int>{};
    // Start preflight alongside the actual download, not in front of it.
    final liveTotal = _segmentTotalForLive(segmentsList, options);
    int? verifiedTotal;
    var flushedBytes = 0;
    var completedFile = false;
    unawaited(liveTotal.then((length) {
      if (completedFile || length == null) return;
      verifiedTotal = length;
      onTransfer?.call(MorneyeTransfer(
        part: '$output.part',
        file: output,
        total: length,
        written: flushedBytes,
      ));
    }));
    void reportLive() {
      final total = verifiedTotal;
      if (completedFile || total == null || flushedBytes > total) return;
      onTransfer?.call(MorneyeTransfer(
        part: '$output.part',
        file: output,
        total: total,
        written: flushedBytes,
      ));
    }
    var completed = 0;
    var serial = Future<void>.value();
    var lastReportedCompleted = -1;
    Future<void> report() {
      final done = completed;
      // A Tidal segment invokes this for every streamed chunk. Previously
      // each chunk awaited another JS bridge callback AND emitted the same
      // "Downloading audio segments" notice even though completed progress
      // had not changed. That serialized media transfers behind the runtime
      // and made the global loading toast appear to flicker.
      //
      // Report only new completed segments. Per-chunk byte accounting stays
      // local; completion is the only honest denominator for this protocol.
      if (done == lastReportedCompleted) return Future<void>.value();
      lastReportedCompleted = done;
      final sum = progress.values.fold<int>(0, (a, b) => a + b);
      onProgress?.call(
        percent: done * 100.0 / segmentsList.length,
        message: 'Downloading audio segments…',
      );
      serial = serial.then(
        (_) => callback(options['onProgress'], [
          sum,
          0,
          done,
          segmentsList.length,
        ]),
      );
      return serial;
    }

    final width =
        ((options['maxParallel'] ??
                        addon.downloadTransfer['maxParallelSegments'])
                    as num? ??
                3)
            .toInt()
            .clamp(1, 8);
    try {
      // The early reader follows a stable .part file while segments append.
      final temp = file('$output.part');
      final sink = await File(temp).open(mode: FileMode.write);
      var size = 0;
      try {
        for (var start = 0; start < segmentsList.length; start += width) {
          final indices = [
            for (
              var i = start;
              i < start + width && i < segmentsList.length;
              i++
            )
              i,
          ];
          final results = await Future.wait(
            indices.map((index) async {
              try {
                final segment = segmentsList[index];
                final url = segment is String
                    ? segment
                    : (segment is Map ? '${segment['url']}' : '');
                final headers = {
                  if (options['headers'] is Map) ...(options['headers'] as Map),
                  if (segment is Map && segment['headers'] is Map)
                    ...(segment['headers'] as Map),
                };
                await transfer(
                  url,
                  p.join(dir, '$index'),
                  {...options, 'headers': headers},
                  (written, _) async {
                    progress[index] = written;
                    await report();
                  },
                  segment: true,
                );
                completed++;
                await report();
                return null;
              } catch (error) {
                return error;
              }
            }),
          );
          final failure = results.whereType<Object>().firstOrNull;
          if (failure != null) throw failure;
          for (final index in indices) {
            final piece = File(p.join(dir, '$index'));
            await for (final chunk in piece.openRead()) {
              _check();
              size += chunk.length;
              if (size > _maxAudio) {
                throw StateError('Segmented audio exceeds the file size limit');
              }
              await sink.writeFrom(chunk);
            }
            // Publish only contiguous bytes in original segment order. A
            // completed future segment must never expose a gap to the decoder.
            await sink.flush();
            flushedBytes = size;
            reportLive();
            await piece.delete();
          }
        }
      } finally {
        await sink.close();
      }
      completedFile = true;
      await File(temp).rename(output);
      if (verifiedTotal == size) {
        onTransfer?.call(MorneyeTransfer(
          part: temp, file: output, total: size, written: size, done: true,
        ));
      }
      return {
        'success': true,
        'path': destination,
        'size': size,
        'segments': segmentsList.length,
      };
    } finally {
      completedFile = true;
      final leftover = Directory(dir);
      if (leftover.existsSync()) await leftover.delete(recursive: true);
    }
  }

  Uint8List _transformBlock(Uint8List input, Map options, bool decrypt) {
    final iv = morneyeBytes(
      options['iv'],
      '${options['ivEncoding'] ?? 'utf8'}',
    );
    return native.cipher(
      input,
      algorithm: '${options['algorithm'] ?? ''}',
      mode: '${options['mode'] ?? 'cbc'}',
      key: morneyeBytes(
        options['key'],
        '${options['keyEncoding'] ?? 'utf8'}',
      ),
      iv: iv,
      pkcs7: options['padding'] == 'pkcs7',
      decrypt: decrypt,
    );
  }

  Future<Map<String, Object?>> patterned(
    Object? input,
    Object? output,
    Map options,
    Object? progress,
    MorneyeCallback callback,
  ) async {
    final source = file(input);
    final target = file(output);
    final temp = file('$target.tmp');
    final segmentSize = (options['segmentSize'] as num?)?.toInt() ?? 0;
    final every = (options['transformEvery'] as num?)?.toInt() ?? 1;
    final offset = (options['transformOffset'] as num?)?.toInt() ?? 0;
    if (segmentSize < 1 ||
        segmentSize > _maxRead ||
        every < 1 ||
        offset < 0 ||
        offset >= every ||
        (options['padding'] != null && options['padding'] != 'none')) {
      throw ArgumentError('Invalid patterned transform options');
    }
    final reader = await File(source).open();
    await Directory(p.dirname(target)).create(recursive: true);
    final writer = await File(temp).open(mode: FileMode.write);
    var processed = 0, index = 0, transformed = 0;
    try {
      final total = await reader.length();
      for (;;) {
        _check();
        var chunk = await reader.read(segmentSize);
        if (chunk.isEmpty) break;
        final count = chunk.length;
        if (index % every == offset &&
            (count == segmentSize || options['transformPartial'] == true)) {
          chunk = _transformBlock(
            chunk,
            options,
            options['operation'] != 'encrypt',
          );
          transformed++;
        }
        await writer.writeFrom(chunk);
        processed += count;
        index++;
        await callback(progress, [processed, total], strict: true);
      }
      await reader.close();
      await writer.close();
      _check();
      await File(temp).rename(target);
      return {
        'success': true,
        'path': output,
        'bytes_processed': processed,
        'segments_processed': index,
        'segments_transformed': transformed,
      };
    } finally {
      await reader.close().catchError((_) {});
      await writer.close().catchError((_) {});
      final leftover = File(temp);
      if (leftover.existsSync()) await leftover.delete();
    }
  }

  Future<Object?> fileCall(
    String name,
    List<Object?> args,
    MorneyeCallback callback,
  ) async {
    final raw = args.isNotEmpty ? args[0] : null;
    final data = args.length > 1 ? args[1] : null;
    final opts = args.length > 2 && args[2] is Map ? args[2] as Map : const {};
    if (name == 'download') {
      return transfer(
        '$raw',
        '$data',
        opts,
        (written, total) => callback(opts['onProgress'], [written, total]),
      );
    }
    if (name == 'downloadSegments') {
      return segments(raw as List, '$data', opts, callback);
    }
    if (name == 'transformPatternedBlocks') {
      return patterned(
        raw,
        data,
        opts,
        args.length > 3 ? args[3] : null,
        callback,
      );
    }
    final path = file(raw);
    switch (name) {
      case 'exists':
        return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
      case 'getSize':
        return {'success': true, 'size': await File(path).length()};
      case 'delete':
        final target = File(path);
        if (target.existsSync()) await target.delete();
        return {'success': true};
      case 'copy':
      case 'move':
        final target = file(data);
        await Directory(p.dirname(target)).create(recursive: true);
        if (name == 'copy') {
          await File(path).copy(target);
        } else {
          await File(path).rename(target);
        }
        return {'success': true};
      case 'read':
      case 'readBytes':
        final options = name == 'readBytes' && data is Map ? data : const {};
        final start = (options['offset'] as num?)?.toInt() ?? 0;
        final length = (options['length'] as num?)?.toInt() ?? _maxRead;
        if (start < 0 || length < 0 || length > _maxRead) {
          throw ArgumentError('Invalid binary read range');
        }
        final handle = await File(path).open();
        try {
          final size = await handle.length();
          if (name == 'read' && size > _maxRead) {
            throw StateError('File read exceeds 16 MB');
          }
          await handle.setPosition(start);
          final bytes = await handle.read((size - start).clamp(0, length));
          return {
            'success': true,
            'data': name == 'read'
                ? utf8.decode(bytes, allowMalformed: true)
                : morneyeEncoded(bytes, '${options['encoding'] ?? 'base64'}'),
            'offset': start,
            'size': size,
            'eof': start + bytes.length >= size,
            'bytes_read': bytes.length,
          };
        } finally {
          await handle.close();
        }
      case 'write':
      case 'writeBytes':
        final value = name == 'write'
            ? Uint8List.fromList(utf8.encode('$data'))
            : morneyeBytes(data, '${opts['encoding'] ?? 'base64'}');
        if (value.length > _maxRead) {
          throw StateError('File write exceeds 16 MB');
        }
        await Directory(p.dirname(path)).create(recursive: true);
        if (name == 'write') {
          await File(path).writeAsBytes(value, flush: true);
        } else {
          final start = (opts['offset'] as num?)?.toInt() ?? 0;
          if (start < 0) throw ArgumentError('Invalid write offset');
          final mode = opts['append'] == true
              ? FileMode.append
              : opts['truncate'] == true
              ? FileMode.write
              : File(path).existsSync()
              ? FileMode.append
              : FileMode.write;
          final handle = await File(path).open(mode: mode);
          try {
            if (opts['append'] != true) await handle.setPosition(start);
            await handle.writeFrom(value);
          } finally {
            await handle.close();
          }
        }
        return {'success': true, 'bytes_written': value.length};
    }
    throw StateError('Unknown file API');
  }

  Future<Object?> authCall(String name, List<Object?> args) async {
    final value = args.isNotEmpty ? args[0] : null;
    switch (name) {
      case 'getAuthCode':
        return auth['code'];
      case 'getTokens':
        return {
          'access_token': auth['access_token'] ?? '',
          'refresh_token': auth['refresh_token'] ?? '',
          'expires_at': auth['expires_at'],
        };
      case 'isAuthenticated':
        final expires = auth['expires_at'];
        return '${auth['access_token'] ?? ''}'.isNotEmpty &&
            (expires == null ||
                (expires is num &&
                    expires > DateTime.now().millisecondsSinceEpoch));
      case 'clearAuth':
        auth.clear();
        return true;
      case 'setAuthCode':
        if (value is String) {
          auth['code'] = value;
        } else if (value is Map) {
          auth.addAll(value.cast<String, Object?>());
        }
        return true;
      case 'generatePKCE':
        final length = ((value as num?)?.toInt() ?? 64).clamp(43, 128);
        final verifier = base64Url
            .encode(morneyeRandomBytes(96))
            .replaceAll('=', '')
            .substring(0, length);
        final challenge = base64Url
            .encode(sha256.convert(utf8.encode(verifier)).bytes)
            .replaceAll('=', '');
        return auth['pkce'] = {
          'verifier': verifier,
          'challenge': challenge,
          'method': 'S256',
        };
      case 'getPKCE':
        return auth['pkce'] ?? {};
      case 'openAuthUrl':
      case 'startOAuthWithPKCE':
        final config = value is Map
            ? value
            : {
                'authUrl': value,
                'redirectUri': args.length > 1 ? args[1] : null,
              };
        var url = morneyeValidateUrl(
          '${config['authUrl']}',
          network.permissions,
        );
        final state = base64Url
            .encode(morneyeRandomBytes(24))
            .replaceAll('=', '');
        final query = {...url.queryParameters, 'state': state};
        if (name == 'startOAuthWithPKCE') {
          final pkce = await authCall('generatePKCE', [64]) as Map;
          final scopes = config['scopes'] is List
              ? (config['scopes'] as List).join(' ')
              : null;
          final extra = {
            'client_id': config['clientId'],
            'redirect_uri': config['redirectUri'],
            'response_type': 'code',
            'scope': config['scope'] ?? scopes,
            'code_challenge': pkce['challenge'],
            'code_challenge_method': 'S256',
            if (config['extraParams'] is Map) ...(config['extraParams'] as Map),
          };
          extra.forEach((key, v) {
            if (v != null) query['$key'] = '$v';
          });
        }
        url = url.replace(queryParameters: query);
        auth['pending'] = {
          'url': url.toString(),
          'state': state,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'callback': config['redirectUri'] ?? '',
        };
        return {
          'success': true,
          'open_auth_url': url.toString(),
          'message': 'Log in on the page Lokal opens; access is checked when it closes.',
        };
      case 'exchangeCodeWithPKCE':
        final config = value is Map ? value : const {};
        final pkce = auth['pkce'] is Map ? auth['pkce'] as Map : const {};
        final form = {
          'grant_type': 'authorization_code',
          'client_id': '${config['clientId'] ?? ''}',
          'code': '${config['code'] ?? auth['code'] ?? ''}',
          'code_verifier': '${pkce['verifier'] ?? ''}',
          if (config['redirectUri'] != null)
            'redirect_uri': '${config['redirectUri']}',
          if (config['extraParams'] is Map)
            for (final e in (config['extraParams'] as Map).entries)
              '${e.key}': '${e.value}',
        };
        final generation = network.generation;
        final result = await network.jsonResponse(
          '${config['tokenUrl']}',
          method: 'POST',
          body: morneyeEncodeQuery(form),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        );
        if (result['ok'] != true) {
          throw StateError('OAuth exchange returned HTTP ${result['status']}');
        }
        if (network.generation != generation) {
          return {'success': false, 'error': 'Disconnected'};
        }
        final tokens = (jsonDecode(result['body'] as String) as Map)
            .cast<String, Object?>();
        auth.addAll(tokens);
        auth['expires_at'] =
            DateTime.now().millisecondsSinceEpoch +
            ((tokens['expires_in'] as num?)?.toInt() ?? 3600) * 1000;
        return {'success': true, ...tokens};
    }
    throw StateError('Unknown auth API');
  }

  Future<Map<String, Object?>> mediaInfo(String path) async {
    final info = await native.mediaInfo(path);
    if (info['codec'] == null) {
      throw StateError('The addon produced no audio stream');
    }
    return info;
  }

  String _hmac(
    Hash hash,
    List<int> key,
    List<int> data, {
    String digest = 'hex',
  }) {
    final bytes = Hmac(hash, key).convert(data).bytes;
    return digest == 'hex' ? Digest(bytes).toString() : base64.encode(bytes);
  }

  Map<String, Object?> _blockCall(String operation, Object? data, Map options) {
    try {
      final input = morneyeBytes(
        data,
        '${options['inputEncoding'] ?? 'base64'}',
      );
      if (input.length > _maxRead) {
        throw StateError('Binary payload exceeds 16 MB');
      }
      final size = options['algorithm'] == 'blowfish' ? 8 : 16;
      if (operation == 'segments') {
        final output = Uint8List.fromList(input);
        if (options['segments'] is! List) {
          throw ArgumentError('Segments array is required');
        }
        var count = 0;
        for (final segment in options['segments'] as List) {
          final start = (segment['offset'] as num).toInt();
          final length = (segment['size'] as num).toInt();
          if (start < 0 || length < 0 || start + length > output.length) {
            throw RangeError('Cipher segment is out of bounds');
          }
          if (length == 0) continue;
          final iv = morneyeBytes(
            segment['iv'],
            '${options['ivEncoding'] ?? 'base64'}',
          );
          if (iv.length > size) throw ArgumentError('Segment IV is too long');
          final padded = Uint8List(size)..setRange(0, iv.length, iv);
          final result = native.cipher(
            Uint8List.sublistView(output, start, start + length),
            algorithm: '${options['algorithm'] ?? 'aes'}',
            mode: 'ctr',
            key: morneyeBytes(
              options['key'],
              '${options['keyEncoding'] ?? 'hex'}',
            ),
            iv: padded,
            pkcs7: false,
            decrypt: true,
          );
          output.setRange(start, start + length, result);
          count++;
        }
        return {
          'success': true,
          'data': morneyeEncoded(
            output,
            '${options['outputEncoding'] ?? 'base64'}',
          ),
          'segments_processed': count,
        };
      }
      final output = _transformBlock(input, options, operation == 'decrypt');
      return {
        'success': true,
        'data': morneyeEncoded(
          output,
          '${options['outputEncoding'] ?? 'base64'}',
        ),
        'block_size': size,
      };
    } catch (error) {
      return {'success': false, 'error': '$error'};
    }
  }

  Map<String, Object?> _textCrypt(bool decrypt, Object? value, Object? key) {
    try {
      final derived = Uint8List.fromList(
        sha256.convert(utf8.encode('$key')).bytes,
      );
      final data = decrypt
          ? utf8.decode(native.open(morneyeBytes(value), derived))
          : base64.encode(
              native.seal(
                Uint8List.fromList(utf8.encode('$value')),
                derived,
                morneyeRandomBytes(12),
              ),
            );
      return {'success': true, 'data': data};
    } catch (error) {
      return {'success': false, 'error': '$error'};
    }
  }

  List<int> _keyBytes(Object? value) =>
      value is List ? morneyeBytes(value) : utf8.encode('$value');

  /// One host call from the add-on.
  Future<Object?> call(
    String method,
    List<Object?> args,
    MorneyeCallback callback,
  ) async {
    _check();
    final dot = method.indexOf('.');
    final name = dot < 0 ? method : method.substring(0, dot);
    final action = dot < 0 ? '' : method.substring(dot + 1);
    Object? arg(int i) => i < args.length ? args[i] : null;

    if (name == 'file') {
      try {
        return await fileCall(action, args, callback);
      } catch (error) {
        if (action == 'exists') return false;
        return {
          'success': false,
          'error': error is MorneyeCancelled
              ? 'Cancelled'
              : '$error'.replaceFirst(RegExp(r'^\w+(Error|Exception): '), ''),
          'error_type': _aborted ? 'cancelled' : 'download_error',
        };
      }
    }
    if (name == 'http') {
      if (action == 'clearCookies') {
        network.cookies.clear();
        network.persist?.call();
        return true;
      }
      try {
        final options = arg(1) is Map ? arg(1) as Map : const {};
        final headers = <String, String>{
          if (options['headers'] is Map)
            for (final e in (options['headers'] as Map).entries)
              '${e.key}': '${e.value}',
        };
        final method = '${options['method'] ?? 'GET'}';
        final body = '${options['body'] ?? ''}';
        final asFetch = options['asFetch'] == true;
        if (!asFetch &&
            (body.isNotEmpty || method == 'POST') &&
            !headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
          headers['Content-Type'] = 'application/json';
        }
        return await network.jsonResponse(
          '${arg(0)}',
          method: method,
          body: body,
          headers: headers,
          asFetch: asFetch,
        );
      } catch (error) {
        return {'ok': false, 'status': 0, 'error': '$error'};
      }
    }
    if (name == 'storage' || name == 'credentials') {
      if (!addon.permissions.storage) {
        throw StateError('Storage permission denied');
      }
      final purpose = name;
      if (action == 'get') {
        final saved = storage.read(addon.key, purpose);
        final key = '${arg(0)}';
        return {'found': saved.containsKey(key), 'value': saved[key]};
      }
      if (action == 'clear') {
        storage.write(addon.key, purpose, {});
        return {'success': true};
      }
      return storage.update(
        addon.key,
        purpose,
        '${arg(0)}',
        arg(1),
        remove: action == 'remove',
      );
    }
    if (name == 'session') {
      final session = this.session;
      if (session == null) {
        throw StateError('Signed sessions are not configured');
      }
      switch (action) {
        case 'signedFetch':
          return session.signedFetch(
            '${arg(0)}',
            '${arg(1)}',
            '${arg(2) ?? ''}',
            {
              if (arg(3) is Map)
                for (final e in (arg(3) as Map).entries)
                  '${e.key}': '${e.value}',
            },
            _sleep,
          );
        case 'completeGrant':
          return session.completeGrant(arg(0) as String?);
        case 'status':
          return session.status();
        case 'clear':
          return session.clear();
      }
    }
    if (name == 'auth') {
      final generation = network.generation;
      final result = await authCall(action, args);
      if (network.generation != generation) {
        return {'success': false, 'error': 'Disconnected'};
      }
      if (!const {
        'getAuthCode',
        'getTokens',
        'isAuthenticated',
        'getPKCE',
      }.contains(action)) {
        network.persist?.call();
      }
      return result;
    }
    if (name == 'ffmpeg') {
      try {
        if (action == 'getInfo') return await mediaInfo(file(arg(0)));
        if (action == 'convert') {
          if (args.length < 2) {
            return {'success': false, 'error': 'Expected input and output paths'};
          }
          final inputPath = file('${arg(0)}');
          final outputPath = file('${arg(1)}');
          final options = args.length > 2 && args[2] is Map
              ? args[2] as Map
              : const {};
          final codec = '${options['codec'] ?? 'copy'}'.toLowerCase();
          await morneyeConvertAudio(
            inputPath: inputPath,
            outputPath: outputPath,
            codec: codec,
          );
          return {
            'success': true,
            'path': outputPath,
            'bytes_processed': await File(outputPath).length(),
          };
        }
        return {'success': false, 'error': 'Unsupported FFmpeg operation'};
      } catch (error) {
        return {'success': false, 'error': '$error'};
      }
    }
    switch (method) {
      case 'progress':
        onProgress?.call(percent: (arg(0) as num?)?.toDouble());
        return true;
      case 'log':
        return true; // Guest logs never reach the app's logs: they can hold tokens.
      case 'encode':
        return {'__bytes': utf8.encode('${arg(0)}')};
      case 'decode':
        return utf8.decode(morneyeBytes(arg(0)), allowMalformed: true);
      case 'base64Bytes':
        return base64.encode(morneyeBytes(arg(0)));
      case 'decodeBase64Bytes':
        return morneyeBytes('${arg(0) ?? ''}', 'base64');
    }
    if (name == 'url') {
      switch (action) {
        case 'parse':
          return morneyeParseUrl('${arg(0)}', arg(1) as String?);
        case 'query':
          return morneyeQueryEntries(arg(0));
        case 'encode':
          return morneyeEncodeQuery(arg(0));
      }
    }
    if (name == 'matching') {
      if (action == 'normalizeString') {
        return morneyeNormalizeString('${arg(0)}');
      }
      return morneyeCompareStrings('${arg(0)}', '${arg(1)}');
    }
    if (name == 'gobackend') {
      switch (action) {
        case 'sanitizeFilename':
          return morneyeSanitize(arg(0));
        case 'buildFilename':
          final values = arg(1) is Map ? arg(1) as Map : const {};
          return morneyeSanitize(
            '${arg(0)}'.replaceAllMapped(
              RegExp(r'\{([^}]+)\}'),
              (m) => '${values[m.group(1)] ?? ''}',
            ),
          );
        case 'getLocalTime':
          final now = DateTime.now();
          return {
            'hour': now.hour,
            'minute': now.minute,
            'second': now.second,
            'timezone': now.timeZoneName,
            'offset': now.timeZoneOffset.inSeconds,
          };
        case 'getAudioQuality':
          return mediaInfo(file(arg(0)));
        case 'checkISRCExists':
          final path = await isrcLookup?.call('${arg(1)}');
          return {'exists': path != null, 'file_path': path ?? ''};
        case 'addToISRCIndex':
          return {'success': true};
        case 'getLyricsLRC':
          return {'lyrics': '', 'lrc': ''};
      }
    }
    if (name == 'utils') {
      switch (action) {
        case 'isDownloadCancelled':
        case 'isRequestCancelled':
          return _aborted;
        case 'appVersion':
          return '5.1.0';
        case 'appUserAgent':
          return 'Lokal/$appVersion Morneye-compatible/5.1.0';
        case 'randomUserAgent':
          return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36';
        case 'setDownloadStatus':
          final text = '${arg(0)}';
          onProgress?.call(
            message: text.length > 200 ? text.substring(0, 200) : text,
          );
          return true;
        case 'getResolutionRemainingMs':
          return (60000 - DateTime.now().difference(_startedAt).inMilliseconds)
              .clamp(0, 60000);
        case 'sleep':
          await _sleep(
            Duration(
              milliseconds: ((arg(0) as num?)?.toInt() ?? 0).clamp(0, 300000),
            ),
          );
          return true;
        case 'base64Encode':
          return base64.encode(utf8.encode('${arg(0)}'));
        case 'base64Decode':
          try {
            return utf8.decode(
              morneyeBytes('${arg(0)}', 'base64'),
              allowMalformed: true,
            );
          } catch (_) {
            return '';
          }
        case 'md5':
          return md5.convert(utf8.encode('${arg(0)}')).toString();
        case 'sha256':
          return sha256.convert(utf8.encode('${arg(0)}')).toString();
        case 'hmacSHA256':
          return _hmac(
            sha256,
            utf8.encode('${arg(1)}'),
            utf8.encode('${arg(0)}'),
          );
        case 'hmacSHA256Base64':
          return _hmac(
            sha256,
            utf8.encode('${arg(1)}'),
            utf8.encode('${arg(0)}'),
            digest: 'base64',
          );
        case 'hmacSHA1':
          return Hmac(sha1, _keyBytes(arg(0))).convert(_keyBytes(arg(1))).bytes;
        case 'encrypt':
        case 'decrypt':
          return _textCrypt(action == 'decrypt', arg(0), arg(1));
        case 'generateKey':
          final length = (arg(0) as num?)?.toInt() ?? 32;
          if (length < 1 || length > 4096) {
            return {'success': false, 'error': 'Invalid key length'};
          }
          final key = morneyeRandomBytes(length);
          return {
            'success': true,
            'key': base64.encode(key),
            'hex': morneyeEncoded(key, 'hex'),
          };
        case 'encryptBlockCipher':
        case 'decryptBlockCipher':
        case 'decryptCTRSegments':
          final options = arg(1) is Map ? arg(1) as Map : const {};
          return _blockCall(
            action == 'decryptCTRSegments'
                ? 'segments'
                : action == 'encryptBlockCipher'
                ? 'encrypt'
                : 'decrypt',
            arg(0),
            options,
          );
      }
    }
    throw StateError('Unsupported host API: $method');
  }
}
