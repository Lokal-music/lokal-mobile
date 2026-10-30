import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import '../../core/utils/app_log.dart';
import '../../data/entities/network_server_entity.dart';
import '../../data/entities/song_entity.dart';
import '../../data/repositories/song_repository.dart';
import '../library_scanner_service.dart' show ScanProgress;
import '../network_cache_service.dart';
import 'network_source_service.dart';
import 'local_network_access.dart';

/// WebDAV client. Recursive PROPFIND walk of the share, HTTP Basic auth.
///
/// Auth: HTTP Basic needs the recoverable password, so [NetworkServerEntity.token]
/// stores `base64(password)` (not a hash). The tradeoff is accepted: the secret
/// is at-rest reversible, but never in plaintext and only in the local DB.
///
/// Metadata limitation: WebDAV exposes only filename + size + mtime. Title is
/// derived from the filename, album from the parent folder, artist from the
/// grandparent (or Unknown). Full tag extraction would require downloading each
/// file, out of scope for the first cut.
class WebdavService implements NetworkSourceService {
  WebdavService._({
    http.Client? client,
    SongRepository? songRepository,
    NetworkCacheService? networkCache,
    Future<void> Function(Uri)? ensureLocalAccess,
  })  : _songRepository = songRepository,
        _networkCache = networkCache,
        _ensureLocalAccess = ensureLocalAccess ?? NetworkLocalAccess.ensure {
    if (client != null) {
      _client = client;
    } else {
      final nativeClient = HttpClient();
      nativeClient.badCertificateCallback = _validateUntrustedCertificate;
      nativeClient.connectionTimeout = const Duration(seconds: 15);
      nativeClient.maxConnectionsPerHost = 2;
      _client = IOClient(nativeClient);
    }
  }

  static WebdavService instance = WebdavService._();

  @visibleForTesting
  static WebdavService create({
    http.Client? client,
    SongRepository? songRepository,
    NetworkCacheService? networkCache,
    Future<void> Function(Uri)? ensureLocalAccess,
  }) =>
      WebdavService._(
        client: client,
        songRepository: songRepository,
        networkCache: networkCache,
        ensureLocalAccess: ensureLocalAccess,
      );

  static const String _coverMarkerScheme = 'webdav-cover://';

  static const _audioExtensions = {
    'flac', 'mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac', 'wv', 'ape', 'mpc',
    'aiff', 'dsf', 'dff',
  };
  static const _imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};
  // Cover filenames scanned per folder, in priority order.
  static const _coverNames = [
    'cover', 'folder', 'album', 'albumart', 'front',
  ];

  final Future<void> Function(Uri) _ensureLocalAccess;
  late final http.Client _client;

  static const _certificatePrefix = 'network_webdav_certificate_sha256_';
  final Map<String, String> _trusted = {};
  final Map<String, String> _trial = {};
  String? _untrustedFingerprint;
  String? _untrustedOrigin;

  String? get untrustedCertificateFingerprint => _untrustedFingerprint;
  String? get untrustedCertificateOrigin => _untrustedOrigin;

  /// Deterministic seam for tests of the certificate approval/persistence
  /// workflow without a physical self-signed NAS or test TLS private key.
  @visibleForTesting
  void recordRejectedCertificateForTest(String origin, String fingerprint) {
    _untrustedOrigin = origin;
    _untrustedFingerprint = fingerprint;
  }

  static String _fingerprint(X509Certificate certificate) =>
      sha256.convert(certificate.der).toString();

  bool _validateUntrustedCertificate(
      X509Certificate certificate, String host, int port) {
    final origin = Uri(scheme: 'https', host: host, port: port).origin;
    final fingerprint = _fingerprint(certificate);
    _untrustedOrigin = origin;
    _untrustedFingerprint = fingerprint;
    return _trusted[origin] == fingerprint || _trial[origin] == fingerprint;
  }

  static String _certificateKey(String origin) =>
      '$_certificatePrefix${Uri.encodeComponent(origin)}';

  Future<void> _loadCertificateTrust(Uri uri) async {
    if (uri.scheme != 'https') return;
    final preferences = await SharedPreferences.getInstance();
    final trusted = preferences.getString(_certificateKey(uri.origin));
    if (trusted != null) _trusted[uri.origin] = trusted;
  }

  /// Only a fingerprint explicitly approved by the user is allowed, only
  /// for that HTTPS origin. The probe must still return valid WebDAV data
  /// before the exception is persisted.
  Future<bool> trustPresentedCertificate(
    NetworkServerEntity server, {
    required String approvedFingerprint,
  }) async {
    final uri = Uri.parse(server.baseUrl);
    if (uri.scheme != 'https') return false;
    final origin = uri.origin;
    if (_untrustedOrigin != origin ||
        _untrustedFingerprint != approvedFingerprint ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(approvedFingerprint)) {
      return false;
    }
    _trial[origin] = approvedFingerprint;
    try {
      if (!await ping(server)) return false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_certificateKey(origin), approvedFingerprint);
      _trusted[origin] = approvedFingerprint;
      return true;
    } finally {
      _trial.remove(origin);
    }
  }

  Future<bool> hasTrustedCertificate(NetworkServerEntity server) async {
    final uri = Uri.parse(server.baseUrl);
    await _loadCertificateTrust(uri);
    return _trusted.containsKey(uri.origin);
  }
  SongRepository? _songRepository;
  NetworkCacheService? _networkCache;

  SongRepository get _repo => _songRepository ??= SongRepository();
  NetworkCacheService get _cache => _networkCache ??= NetworkCacheService();

  @override
  String get protocol => NetworkProtocol.webdav;

  @override
  String get coverScheme => _coverMarkerScheme;

  String? _lastPingError;

  @override
  String? get lastPingError => _lastPingError;

  static String describePingFailure(Object error) {
    final raw = error.toString().toLowerCase();
    if (error is NetworkAccessDenied) return error.message;
    if (raw.contains('certificate_verify_failed') ||
        raw.contains('handshakeexception') ||
        raw.contains('certificate verify failed')) {
      return 'HTTPS certificate validation failed. This NAS may use a '
          'self-signed certificate. Use a trusted certificate, or the '
          'server’s verified HTTP/WebDAV address on your private LAN.';
    }
    if (raw.contains('connection refused')) {
      return 'Connection refused. Check the protocol (HTTP vs HTTPS), '
          'port and server WebDAV setting.';
    }
    if (raw.contains('timed out')) {
      return 'Server timed out. Check that the phone and NAS share a network.';
    }
    return 'Could not connect to the WebDAV service: $error';
  }

  static String describeStatus(int status) => switch (status) {
    401 => 'The WebDAV server rejected the username or password (HTTP 401).',
    403 => 'This account cannot access the requested WebDAV folder (HTTP 403).',
    404 => 'WebDAV folder not found (HTTP 404). Check the full share path.',
    405 || 501 => 'This URL does not offer WebDAV PROPFIND (HTTP $status). '
        'An ordinary HTTPS file server is not necessarily WebDAV.',
    _ => 'WebDAV server returned HTTP $status.',
  };

  // --- Auth ---------------------------------------------------------------

  @override
  Future<String?> resolveToken(
    NetworkServerEntity server,
    String password,
  ) async {
    // Local transform: HTTP Basic needs the recoverable password.
    return base64Encode(utf8.encode(password));
  }

  String _basicAuth(NetworkServerEntity server) {
    final user = server.username ?? '';
    final password = _password(server);
    final credentials = base64Encode(utf8.encode('$user:$password'));
    return 'Basic $credentials';
  }

  String _password(NetworkServerEntity server) {
    if (server.token == null || server.token!.isEmpty) return '';
    try {
      return utf8.decode(base64Decode(server.token!));
    } catch (_) {
      return '';
    }
  }

  String _origin(NetworkServerEntity server) =>
      Uri.parse(server.baseUrl).origin;

  // --- Path encoding ------------------------------------------------------
  //
  // Invariant: every path inside this service is stored decoded exactly once
  // (at PROPFIND parse time) and re-encoded only when building a request URL.
  // Decoding twice throws ArgumentError on non-ASCII or literal `%` names,
  // which used to abort sync; skipping the re-encode lets `#`/`?` in names be
  // reparsed as fragment/query.

  /// Single-pass decode. Falls back to the raw string when the server returns
  /// non-conformant hrefs (raw UTF-8, bare `%`), so one odd entry can't abort
  /// a whole directory walk.
  static String _tryDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return value;
    }
  }

  /// Percent-encodes each path segment, preserving `/` separators.
  static String _encodePath(String decodedPath) =>
      decodedPath.split('/').map(Uri.encodeComponent).join('/');

  Uri _requestUri(NetworkServerEntity server, String decodedPath) =>
      Uri.parse('${_origin(server)}${_encodePath(decodedPath)}');

  // --- PROPFIND -----------------------------------------------------------

  static const _propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
      '<D:propfind xmlns:D="DAV:"><D:prop>'
      '<D:resourcetype/><D:getcontentlength/><D:getlastmodified/>'
      '<D:displayname/>'
      '</D:prop></D:propfind>';

  Future<http.Response> _propfind(
    NetworkServerEntity server,
    String url, {
    int depth = 1,
  }) async {
    var uri = Uri.parse(url);
    await _ensureLocalAccess(uri);
    await _loadCertificateTrust(uri);
    for (var attempt = 0; attempt < 2; attempt++) {
      final request = http.Request('PROPFIND', uri)
        ..followRedirects = false
        // Several Android builds report uncaught _HttpClient._returnConnection
        // errors after failed NAS requests. Do not return these connections
        // to Dart's keep-alive pool while certificate trust is changing.
        ..headers['Connection'] = 'close'
        ..headers['Depth'] = '$depth'
        ..headers['Content-Type'] = 'application/xml; charset=utf-8'
        ..headers['Authorization'] = _basicAuth(server)
        ..body = _propfindBody;
      final streamed = await _client.send(request).timeout(
        const Duration(seconds: 30),
      );
      final response = await http.Response.fromStream(streamed);
      final redirect = response.headers['location'];
      if (attempt == 0 &&
          (response.statusCode == 301 ||
              response.statusCode == 302 ||
              response.statusCode == 307 ||
              response.statusCode == 308) &&
          redirect != null) {
        final target = uri.resolve(redirect);
        // NASes frequently add a trailing slash to WebDAV collections.
        // Only repeat that exact canonicalization; never forward HTTP Basic
        // credentials to a different host, scheme, port or arbitrary path.
        if (target.scheme == uri.scheme &&
            target.origin == uri.origin &&
            target.path == '${uri.path}/' &&
            target.query == uri.query &&
            !target.hasFragment &&
            target.userInfo.isEmpty) {
          uri = target;
          continue;
        }
        return http.Response(
          'WebDAV redirected outside the requested collection.',
          400,
        );
      }
      return response;
    }
    throw StateError('WebDAV redirect limit exceeded');
  }

  List<_DavEntry> _parseMultistatus(
    String body,
    String requestedHref, {
    String? requestUrl,
    String? shareRoot,
  }) {
    final results = <_DavEntry>[];
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } catch (_) {
      return results;
    }
    for (final response
        in doc.findAllElements('response', namespace: '*')) {
      final href = response
          .findElements('href', namespace: '*')
          .firstOrNull
          ?.innerText
          .trim();
      if (href == null) continue;
      final decoded = requestUrl == null
          ? _tryDecode(href)
          : _resolveDavHref(href, requestUrl, shareRoot ?? requestedHref);
      // Skip the self entry (the requested collection itself).
      if (_samePath(decoded, requestedHref)) continue;

      final isCollection = response
              .findAllElements('collection', namespace: '*')
              .isNotEmpty;
      // ponytail: getcontentlength nests under propstat/prop; recursive find
      // keeps this robust to both flattened and nested multistatus bodies.
      final sizeText = response
          .findAllElements('getcontentlength', namespace: '*')
          .firstOrNull
          ?.innerText;
      results.add(_DavEntry(
        href: decoded,
        isCollection: isCollection,
        size: sizeText == null ? null : int.tryParse(sizeText),
      ));
    }
    return results;
  }

  /// RFC 4918 permits both absolute and relative hrefs. Some GL.iNet and
  /// other NAS WebDAV servers return absolute HTTPS URLs in PROPFIND bodies.
  /// Treating the entire URL as a path broke recursive scans and could cause
  /// invalid requests such as https://nas/https%3A%2F%2Fnas%2Falbum.
  static String _resolveDavHref(
    String href,
    String requestUrl,
    String shareRoot,
  ) {
    final parent = Uri.parse(requestUrl);
    // PROPFIND may target a collection URL without a final slash. Relative
    // hrefs are children of that collection, not siblings of its path.
    final collection = parent.path.endsWith('/')
        ? parent
        : parent.replace(path: '${parent.path}/');
    final resolved = collection.resolve(href);
    if (resolved.origin != parent.origin ||
        resolved.scheme != parent.scheme ||
        resolved.userInfo.isNotEmpty ||
        resolved.hasQuery ||
        resolved.hasFragment) {
      throw const FormatException('Cross-origin or malformed WebDAV href');
    }
    final segments = resolved.pathSegments;
    if (segments.any((segment) =>
        segment.contains('/') || segment.contains('\\') ||
        segment.contains(String.fromCharCode(0)) ||
        segment == '.' || segment == '..')) {
      throw const FormatException('Invalid encoded WebDAV path segment');
    }
    // Uri.pathSegments already includes the trailing empty segment for
    // collection URLs. Never append another slash.
    final path = '/${segments.join('/')}';
    final root = shareRoot.endsWith('/')
        ? shareRoot.substring(0, shareRoot.length - 1)
        : shareRoot;
    // The root itself permits any absolute child path. Other shares must
    // still be contained on a whole path-segment boundary.
    if (root.isNotEmpty && path != root && !path.startsWith('$root/')) {
      throw FormatException('WebDAV href is outside the shared folder: $path');
    }
    return path;
  }

  bool _samePath(String a, String b) {
    String norm(String s) => s.endsWith('/') && s.length > 1
        ? s.substring(0, s.length - 1)
        : s;
    return norm(a) == norm(b);
  }

  // --- Test surface (pure parse helpers, no network) ----------------------

  @visibleForTesting
  static List<({String href, bool isCollection, int? size})> parseMultistatusForTest(
    String body,
    String requestedHref, {
    String? requestUrl,
    String? shareRoot,
  }) {
    final svc = WebdavService._();
    return svc
        ._parseMultistatus(
          body, requestedHref, requestUrl: requestUrl, shareRoot: shareRoot,
        )
        .map((e) => (
              href: e.href,
              isCollection: e.isCollection,
              size: e.size,
            ))
        .toList();
  }

  @visibleForTesting
  static bool isAudioPath(String href) => WebdavService._()._isAudio(href);

  @visibleForTesting
  static bool isCoverPath(String href) => WebdavService._()._isCoverName(href);

  // --- ping ---------------------------------------------------------------

  @override
  Future<bool> ping(NetworkServerEntity server) async {
    _lastPingError = null;
    _untrustedFingerprint = null;
    _untrustedOrigin = null;
    try {
      final response = await _propfind(server, server.baseUrl, depth: 0);
      // PROPFIND normally returns 207, including the target folder.
      // A plain HTML 200 response is not evidence of a WebDAV server.
      if ((response.statusCode == 207 || response.statusCode == 200) &&
          _isMultistatusDocument(response.body)) return true;
      _lastPingError = response.statusCode == 400 &&
              response.body.startsWith('WebDAV redirected')
          ? response.body
          : response.statusCode == 200
          ? 'The server answered with HTTP 200 but no WebDAV multistatus. '
              'Use the WebDAV endpoint, not an ordinary HTTP page.'
          : describeStatus(response.statusCode);
      return false;
    } catch (e) {
      _lastPingError = describePingFailure(e);
      AppLog.instance.add('WebDAV ping failed: $e');
      return false;
    }
  }

  // --- Cover art + stream -------------------------------------------------

  @override
  Future<List<int>> getCoverArt(
    NetworkServerEntity server,
    String marker,
  ) async {
    final href = utf8.decode(base64Decode(marker));
    final uri = _requestUri(server, href);
    await _ensureLocalAccess(uri);
    await _loadCertificateTrust(uri);
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Connection'] = 'close'
      ..headers['Authorization'] = _basicAuth(server);
    final streamed = await _client.send(request).timeout(const Duration(seconds: 30));
    if (streamed.statusCode != 200) {
      throw WebdavNetworkException('HTTP ${streamed.statusCode} for cover');
    }
    // Cover requests are untrusted NAS input. Avoid Response.fromStream,
    // which buffers arbitrarily large images into memory ahead of decoding.
    const limit = 12 * 1024 * 1024;
    if ((streamed.contentLength ?? 0) > limit) {
      throw WebdavNetworkException('NAS cover exceeds 12 MiB');
    }
    final bytes = BytesBuilder(copy: false);
    var size = 0;
    await for (final chunk in streamed.stream.timeout(
      const Duration(seconds: 30),
    )) {
      size += chunk.length;
      if (size > limit) {
        throw WebdavNetworkException('NAS cover exceeds 12 MiB');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @override
  Future<String> stream(
    NetworkServerEntity server,
    String remoteId, {
    String? extension,
    void Function(double progress)? onProgress,
  }) async {
    final cached =
        await _cache.getPath(server.id, remoteId, extension: extension);
    if (cached != null) return cached;

    // remoteId is stored url-encoded so the cache key is filesystem-safe;
    // decode once, then re-encode at the request boundary.
    final href = _tryDecode(remoteId);
    final uri = _requestUri(server, href);
    await _ensureLocalAccess(uri);
    await _loadCertificateTrust(uri);
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Connection'] = 'close'
      ..headers['Authorization'] = _basicAuth(server);
    final response =
        await _client.send(request).timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) {
      throw WebdavNetworkException('HTTP ${response.statusCode} for stream');
    }
    // Stream directly to a temporary cache file. Keeping an entire FLAC in a
    // BytesBuilder doubles peak RAM and can kill the app on large albums.
    // Publish atomically: partial transfers must never be returned as hits.
    final destination = await _cache.pathFor(server.id, remoteId, extension: extension);
    final partial = File('$destination.part.$pid.${DateTime.now().microsecondsSinceEpoch}');
    final output = partial.openWrite();
    final total = response.contentLength;
    var received = 0;
    try {
      // Sending response headers is not proof that the NAS continues sending
      // the body. Time out stalled chunks and let the catch block remove the
      // partial cache file instead of leaving playback pending indefinitely.
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        output.add(chunk);
        received += chunk.length;
        if (onProgress != null && total != null && total > 0) {
          onProgress(received / total);
        }
      }
      await output.flush();
      await output.close();
      if (total != null && received != total) {
        throw WebdavNetworkException('Incomplete WebDAV download: $received of $total bytes');
      }
      await partial.rename(destination);
      await _cache.commitDownload(destination);
      return destination;
    } catch (_) {
      try { await output.close(); } catch (_) {}
      try { if (await partial.exists()) await partial.delete(); } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<({String url, Map<String, String> headers})?> streamDescriptor(
    NetworkServerEntity server,
    String remoteId, {
    String? extension,
  }) async {
    // remoteId is stored url-encoded (cache-key-safe); decode once, then
    // re-encode at the request boundary.
    final href = _tryDecode(remoteId);
    final uri = _requestUri(server, href);
    // Direct Rust/Media3 network playback does not share this client's
    // certificate pin, so a self-signed NAS must take the verified cache
    // path instead of failing on the second TLS handshake.
    if (await hasTrustedCertificate(server)) return null;
    // Direct Media3/Rust playback bypasses this Dart HTTP client. Request
    // Android local-network access before handing off the authenticated URL.
    await _ensureLocalAccess(uri);
    return (url: uri.toString(), headers: {'Authorization': _basicAuth(server)});
  }

  // --- Library walk -------------------------------------------------------

  bool _isMultistatusDocument(String body) {
    try {
      final root = XmlDocument.parse(body).rootElement;
      // A nested <multistatus> inside HTML (or a non-DAV namespace) is NOT
      // a WebDAV collection listing. Accepting it as an empty collection
      // could purge every indexed song for the requested directory.
      if (root.name.local != 'multistatus' || root.namespaceUri != 'DAV:') {
        return false;
      }
      var responseCount = 0;
      var hasDescription = false;
      for (final child in root.childElements) {
        if (child.name.local == 'responsedescription' &&
            child.namespaceUri == 'DAV:' && !hasDescription) {
          // RFC 4918 permits one optional description after responses.
          hasDescription = true;
          continue;
        }
        if (child.name.local != 'response' ||
            child.namespaceUri != 'DAV:' || hasDescription) return false;
        final hrefs = child.findElements('href', namespaceUri: 'DAV:').toList();
        if (hrefs.length != 1 || hrefs.single.innerText.trim().isEmpty) {
          return false;
        }
        responseCount++;
      }
      // PROPFIND for a collection must return at least its own response.
      return responseCount > 0;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static bool isValidMultistatusForTest(String body) =>
      WebdavService._()._isMultistatusDocument(body);

  @override
  Stream<ScanProgress> syncLibrary(NetworkServerEntity server) async* {
    final syncedRemoteIds = <String>{};
    var songsFound = 0;

    // Queue holds (absolutePath, depth). absolutePath is the server-relative
    // path used both to build child URLs and to derive album/artist names.
    final queue = <_DavDir>[];
    final allDirs = <String>[];
    final visitedDirs = <String>{};
    final scanErrors = <String>[];
    final origin = _origin(server);

    String rootPath;
    try {
      rootPath = _tryDecode(Uri.parse(server.baseUrl).path);
    } catch (_) {
      rootPath = '';
    }
    queue.add(_DavDir(url: server.baseUrl, path: rootPath));
    allDirs.add(rootPath);

    var filesProcessed = 0;
    var scanIncomplete = false;
    while (queue.isNotEmpty) {
      final dir = queue.removeAt(0);
      if (!visitedDirs.add(dir.path)) continue;
      List<_DavEntry> entries;
      try {
        final response = await _propfind(server, dir.url);
        if ((response.statusCode != 207 && response.statusCode != 200) ||
            !_isMultistatusDocument(response.body)) {
          scanIncomplete = true;
          final detail =
              response.statusCode == 207 || response.statusCode == 200
              ? 'invalid multistatus XML'
              : 'HTTP ${response.statusCode}';
          scanErrors.add('${dir.path}: $detail');
          AppLog.instance.add(
            'WebDAV directory scan failed at "${dir.path}" on '
            '${server.label}: $detail',
          );
          filesProcessed++;
          yield _progress(server, songsFound, allDirs.length, filesProcessed,
              dir.path);
          continue;
        }
        entries = _parseMultistatus(
          response.body, dir.path,
          requestUrl: dir.url, shareRoot: rootPath,
        );
      } catch (e) {
        scanIncomplete = true;
        scanErrors.add('${dir.path}: $e');
        AppLog.instance
            .add('WebDAV sync skipped "${dir.path}" on ${server.label}: $e');
        filesProcessed++;
        yield _progress(
            server, songsFound, allDirs.length, filesProcessed, dir.path);
        continue;
      }

      String? coverHref;
      final songEntries = <_DavEntry>[];
      for (final e in entries) {
        if (e.isCollection) {
          allDirs.add(e.href);
          queue.add(_DavDir(url: '$origin${_encodePath(e.href)}', path: e.href));
        } else if (_isCoverName(e.href)) {
          coverHref ??= e.href;
        } else if (_isAudio(e.href)) {
          songEntries.add(e);
        }
      }

      if (songEntries.isNotEmpty) {
        final albumName = _lastPathSegment(dir.path);
        final artist = _grandparentSegment(dir.path);
        final entities = songEntries.map((e) {
          final remoteId = Uri.encodeComponent(e.href);
          return _songEntity(
            server: server,
            href: e.href,
            remoteId: remoteId,
            size: e.size,
            album: albumName,
            artist: artist,
            coverHref: coverHref,
          );
        }).toList();
        await _repo.upsertSongs(entities);
        syncedRemoteIds.addAll(entities.map((e) => e.remoteId!));
        songsFound += entities.length;
      }

      filesProcessed++;
      yield _progress(
          server, songsFound, allDirs.length, filesProcessed, dir.path);
    }

    // A single failed folder can hide hundreds of previously indexed
    // tracks. Never interpret missing responses as deleted files or advance
    // lastSyncedAt following an incomplete walk.
    if (scanIncomplete) {
      throw WebdavNetworkException(
        'Library scan incomplete (${scanErrors.length} folder error(s)). '
        '${scanErrors.take(2).join('; ')}. Previously indexed songs were '
        'preserved; check the NAS share and retry.',
      );
    }
    await purgeAndStampNetworkSync(
      server,
      syncedRemoteIds,
      repo: _songRepository,
    );

    yield ScanProgress(
      songsFound: songsFound,
      totalFiles: allDirs.length,
      filesProcessed: filesProcessed,
      phase: 'Syncing ${server.label}',
      isComplete: true,
    );
  }

  ScanProgress _progress(
    NetworkServerEntity server,
    int songsFound,
    int totalDirs,
    int filesProcessed,
    String currentPath,
  ) {
    return ScanProgress(
      songsFound: songsFound,
      totalFiles: totalDirs,
      filesProcessed: filesProcessed,
      phase: 'Syncing ${server.label}',
      currentFile: _lastPathSegment(currentPath),
    );
  }

  SongEntity _songEntity({
    required NetworkServerEntity server,
    required String href,
    required String remoteId,
    required int? size,
    required String album,
    required String artist,
    required String? coverHref,
  }) {
    final fileName = _lastPathSegment(href);
    final dot = fileName.lastIndexOf('.');
    final baseName = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot + 1).toLowerCase() : null;
    return SongEntity()
      ..filePath = '${NetworkProtocol.webdav}://${server.id}/$remoteId'
      ..title = baseName.replaceAll(RegExp(r'^\d+[.\-\s]+'), '')
      ..artist = artist
      ..album = album.isEmpty ? null : album
      ..fileSize = size
      ..fileType = ext
      ..albumArtPath = coverHref != null
          ? '$_coverMarkerScheme${base64Encode(utf8.encode(coverHref))}'
          : null
      ..sourceType = NetworkProtocol.webdav
      ..remoteId = remoteId
      ..remoteServerId = server.id
      ..metadataComplete = true
      ..dateAdded = DateTime.now()
      ..lastModified = DateTime.now();
  }

  bool _isAudio(String href) {
    final ext = _extension(href);
    return ext != null && _audioExtensions.contains(ext);
  }

  bool _isCoverName(String href) {
    final ext = _extension(href);
    if (ext == null || !_imageExtensions.contains(ext)) return false;
    final name = _lastPathSegment(href);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot).toLowerCase() : name.toLowerCase();
    return _coverNames.any((c) => stem == c || stem.startsWith('$c.'));
  }

  String? _extension(String href) {
    final name = _lastPathSegment(href);
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  String _lastPathSegment(String path) {
    var p = path;
    while (p.endsWith('/') && p.length > 1) {
      p = p.substring(0, p.length - 1);
    }
    final slash = p.lastIndexOf('/');
    return slash >= 0 ? p.substring(slash + 1) : p;
  }

  String _grandparentSegment(String path) {
    var p = path;
    while (p.endsWith('/') && p.length > 1) {
      p = p.substring(0, p.length - 1);
    }
    // Drop the last segment (album folder) and read the new last (artist).
    final slash = p.lastIndexOf('/');
    if (slash <= 0) return 'Unknown';
    final parent = p.substring(0, slash);
    final artist = _lastPathSegment(parent);
    return artist.isEmpty ? 'Unknown' : artist;
  }
}

class _DavEntry {
  const _DavEntry({
    required this.href,
    required this.isCollection,
    this.size,
  });
  final String href;
  final bool isCollection;
  final int? size;
}

class _DavDir {
  const _DavDir({required this.url, required this.path});
  final String url;
  final String path;
}

class WebdavNetworkException implements Exception {
  final String message;
  WebdavNetworkException(this.message);
  @override
  String toString() => 'WebDAV error: $message';
}
