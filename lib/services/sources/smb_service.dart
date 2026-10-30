import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/utils/app_log.dart';
import '../../data/entities/network_server_entity.dart';
import '../../data/entities/song_entity.dart';
import '../../data/repositories/song_repository.dart';
import '../library_scanner_service.dart' show ScanProgress;
import '../network_cache_service.dart';
import 'native_smb_transport.dart';
import 'network_source_service.dart';
import '../ios_library_scan_epoch.dart';
import 'local_network_access.dart';

/// SMB2/3 client backed by the signed native libsmb2 transport.
///
/// Auth: NTLM needs the recoverable password, so [NetworkServerEntity.token]
/// stores `base64(password)` (not a hash) — same tradeoff as WebDAV.
///
/// Metadata limitation: SMB exposes only filename + size + mtime. Title is
/// derived from the filename, album from the parent folder, artist from the
/// grandparent (or Unknown). Full tag extraction would require downloading each
/// file, out of scope for the first cut.
class SmbService implements NetworkSourceService {
  SmbService._({
    SongRepository? songRepository,
    NetworkCacheService? networkCache,
    NativeSmbConnector? connector,
    bool? iosScanSafety,
  })  : _songRepository = songRepository,
        _networkCache = networkCache,
        _connector = connector ?? Libsmb2Transport.connect,
        _iosScanSafety = iosScanSafety ?? Platform.isIOS;

  /// Allows a mock SMB transport in tests without native libraries or NAS.
  static SmbService create({
    SongRepository? songRepository,
    NetworkCacheService? networkCache,
    NativeSmbConnector? connector,
    bool? iosScanSafety,
  }) => SmbService._(
    songRepository: songRepository,
    networkCache: networkCache,
    connector: connector,
    iosScanSafety: iosScanSafety,
  );

  static SmbService instance = SmbService._();

  static const _audioExtensions = {
    'flac', 'mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac', 'wv', 'ape', 'mpc',
    'aiff', 'dsf', 'dff',
  };
  static const _imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};
  static const _coverNames = ['cover', 'folder', 'album', 'albumart', 'front'];

  SongRepository? _songRepository;
  NetworkCacheService? _networkCache;
  final NativeSmbConnector _connector;
  final bool _iosScanSafety;

  Future<NativeSmbSession> _connect(
    ({String host, int port, String share, String rootPath}) s,
    NetworkServerEntity server,
  ) => _connector(
    host: s.host,
    port: s.port,
    share: s.share,
    username: server.username ?? '',
    password: _password(server),
  );

  SongRepository get _repo => _songRepository ??= SongRepository();
  NetworkCacheService get _cache => _networkCache ??= NetworkCacheService();

  String? _lastPingError;

  @override
  String? get lastPingError => _lastPingError;

  @override
  String get protocol => NetworkProtocol.smb;

  @override
  String get coverScheme => 'smb-cover://';

  // --- Auth + URL parsing -------------------------------------------------

  @override
  Future<String?> resolveToken(
    NetworkServerEntity server,
    String password,
  ) async {
    // NTLM needs the recoverable password.
    return password.isEmpty ? null : base64Encode(utf8.encode(password));
  }

  String _password(NetworkServerEntity server) {
    if (server.token == null || server.token!.isEmpty) return '';
    try {
      return utf8.decode(base64Decode(server.token!));
    } catch (_) {
      return '';
    }
  }

  ({String host, int port, String share, String rootPath}) _parseServer(
    NetworkServerEntity server,
  ) =>
      parseServerUrl(server.baseUrl);

  /// Parse a saved server URL into host/port/share/root. Accepts both
  /// `smb://host/share/path` and the Windows form `\\host\share\path`.
  /// Throws [FormatException] with user-facing text when the host or share is
  /// missing; the edit screen shows it in the failure banner.
  static ({String host, int port, String share, String rootPath})
      parseServerUrl(String url) {
    var source = url.trim();
    if (source.startsWith(r'\\')) {
      source = 'smb://${source.substring(2).replaceAll(r'\', '/')}';
    }
    final uri = Uri.parse(source);
    if (uri.scheme.toLowerCase() != 'smb' || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment) {
      throw const FormatException(
        'Use an SMB share URL like smb://nas/Music — not an HTTP address.',
      );
    }
    if (uri.host.isEmpty) {
      throw const FormatException(
        'Missing server address — use smb://host/share (e.g. smb://nas/music).',
      );
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      throw const FormatException(
        'Missing share name — use smb://host/share (e.g. smb://nas/music).',
      );
    }
    return (
      host: uri.host,
      port: uri.port == 0 ? 445 : uri.port,
      share: segments.first,
      rootPath: segments.length > 1
          ? segments.skip(1).join('/')
          : '',
    );
  }

  Future<void> _ensureLanAccess(
    ({String host, int port, String share, String rootPath}) server,
  ) => NetworkLocalAccess.ensure(
    Uri(scheme: 'smb', host: server.host, port: server.port),
  );

  // --- ping ---------------------------------------------------------------

  @override
  Future<bool> ping(NetworkServerEntity server) async {
    _lastPingError = null;
    try {
      final s = _parseServer(server);
      await _ensureLanAccess(s);
      final session = await _connect(s, server);
      try {
        // Test the configured *folder*, not merely SMB authentication.
        // Some NASes grant tree access but deny listing the selected folder.
        await session.list(s.rootPath);
        return true;
      } finally {
        await session.close();
      }
    } catch (e) {
      _lastPingError = e is FormatException ? e.message : describePingError(e);
      AppLog.instance.add('SMB ping failed: $e');
      return false;
    }
  }

  /// Turn an smb2 error into one actionable line for the failure banner. The
  /// raw error still goes to [AppLog] for full detail.
  static String describePingError(Object error) {
    final raw = error.toString();
    final lower = raw.toLowerCase();
    if (error is NetworkAccessDenied) return error.message;
    if (lower.contains('authentication failed') ||
        lower.contains('logon_failure')) {
      return 'The server rejected the username or password. Check the '
          'account — Samba may map unknown users to guest.';
    }
    if (lower.contains('bad_network_name') || lower.contains('name_not_found')) {
      return 'The server answered but the share was not found. Check the '
          'share name in the URL.';
    }
    if (lower.contains('access_denied') || lower.contains('access denied')) {
      if (lower.contains('directory listing')) {
        return 'SMB login succeeded, but this account cannot list the share '
            'folder. Check NAS folder read/list permissions.';
      }
      if (lower.contains('share access')) {
        return 'SMB login succeeded, but this account cannot connect to the '
            'named share. Check the share name and NAS share permissions.';
      }
      return 'SMB access denied during authentication or protocol setup. '
          'Verify credentials, required signing and SMB2/3 compatibility.';
    }
    if (lower.contains('lookup') ||
        lower.contains('resolve') ||
        lower.contains('name or service not known')) {
      return 'Could not resolve the server name. Try the IP address instead — '
          'Android cannot resolve NetBIOS/.local names.';
    }
    if (lower.contains('timed out')) {
      return 'Timed out. Use the server IP (not a NetBIOS/.local name), check '
          'port 445, and that the phone is on the same network.';
    }
    if (lower.contains('connection refused')) {
      return 'Connection refused. Check that file sharing is enabled and '
          'port 445 is reachable.';
    }
    if (lower.contains('could not connect') ||
        lower.contains('unreachable') ||
        lower.contains('no route')) {
      return 'Could not reach the server. Check the IP address, then that the '
          'phone is on the same network.';
    }
    if (lower.contains('server stopped answering') ||
        lower.contains('unresponsive')) {
      return 'The server stopped answering. Check the server, then retry.';
    }
    return raw;
  }

  // --- Cover art + stream -------------------------------------------------

  @override
  Future<List<int>> getCoverArt(
    NetworkServerEntity server,
    String marker,
  ) async {
    final path = utf8.decode(base64Decode(marker));
    final s = _parseServer(server);
    await _ensureLanAccess(s);
    final session = await _connect(s, server);
    try {
      return await session.read(path);
    } finally {
      await session.close();
    }
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

    final s = _parseServer(server);
    await _ensureLanAccess(s);
    final destPath =
        await _cache.pathFor(server.id, remoteId, extension: extension);
    final session = await _connect(s, server);
    try {
      await session.download(
        remoteId,
        destPath,
        onProgress: (received, total) {
          if (onProgress != null && total > 0) {
            onProgress(received / total);
          }
        },
      );
      await _cache.commitDownload(destPath);
      return destPath;
    } finally {
      await session.close();
    }
  }

  @override
  Future<({String url, Map<String, String> headers})?> streamDescriptor(
    NetworkServerEntity server,
    String remoteId, {
    String? extension,
  }) async => null;

  // --- Library walk -------------------------------------------------------

  @override
  Stream<ScanProgress> syncLibrary(NetworkServerEntity server) => _iosScanSafety
      ? IosLibraryScanEpoch.bind(() => _syncLibrary(server))
      : _syncLibrary(server);

  Stream<ScanProgress> _syncLibrary(NetworkServerEntity server) async* {
    final s = _parseServer(server);
    await _ensureLanAccess(s);
    // Keep one signed/encrypted SMB2/3 session during the entire scan.
    // If a folder fails, propagate the error: never interpret partial
    // listings as deletions of previously indexed songs.
    final byDir = <String, List<NativeSmbEntry>>{};
    var totalEntries = 0;
    final session = await _connect(s, server);
    try {
      final queue = <String>[s.rootPath];
      final visited = <String>{};
      while (queue.isNotEmpty) {
        final directory = queue.removeAt(0);
        if (!visited.add(directory)) continue;
        if (_iosScanSafety) IosLibraryScanEpoch.requireCurrent();
        final entries = await session.list(directory);
        if (_iosScanSafety) IosLibraryScanEpoch.requireCurrent();
        for (final entry in entries) {
          totalEntries++;
          if (entry.isDir) {
            queue.add(entry.path);
          } else {
            final parent = _parentDir(entry.path);
            (byDir[parent] ??= <NativeSmbEntry>[]).add(entry);
          }
          if (totalEntries % 500 == 0) {
            yield ScanProgress(
              songsFound: 0,
              totalFiles: totalEntries,
              filesProcessed: totalEntries,
              phase: 'Syncing ${server.label}',
              currentFile: entry.name,
            );
          }
        }
      }
    } finally {
      await session.close();
    }

    final syncedRemoteIds = <String>{};
    var songsFound = 0;
    for (final dirPath in byDir.keys) {
      final entries = byDir[dirPath]!;
      String? coverPath;
      final songEntries = <NativeSmbEntry>[];
      for (final e in entries) {
        if (_isCoverName(e.name)) {
          coverPath ??= e.path;
        } else if (_isAudio(e.name)) {
          songEntries.add(e);
        }
      }
      if (songEntries.isEmpty) continue;

      final album = _lastPathSegment(dirPath);
      final artist = _grandparentSegment(dirPath);
      final entities = songEntries
          .map((e) => _songEntity(
                server: server,
                entry: e,
                remoteId: e.path,
                album: album,
                artist: artist,
                coverPath: coverPath,
              ))
          .toList();
      if (_iosScanSafety) {
        await _repo.upsertScannedSongs(entities);
      } else {
        await _repo.upsertSongs(entities);
      }
      syncedRemoteIds.addAll(entities.map((e) => e.remoteId!));
      songsFound += entities.length;
    }

    await purgeAndStampNetworkSync(server, syncedRemoteIds, repo: _songRepository,
        enforceScanEpoch: _iosScanSafety);

    yield ScanProgress(
      songsFound: songsFound,
      totalFiles: totalEntries,
      filesProcessed: totalEntries,
      phase: 'Syncing ${server.label}',
      isComplete: true,
    );
  }

  SongEntity _songEntity({
    required NetworkServerEntity server,
    required NativeSmbEntry entry,
    required String remoteId,
    required String album,
    required String artist,
    required String? coverPath,
  }) {
    final fileName = entry.name;
    final dot = fileName.lastIndexOf('.');
    final baseName = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot + 1).toLowerCase() : null;
    return SongEntity()
      ..filePath = '${NetworkProtocol.smb}://${server.id}/$remoteId'
      ..title = baseName.replaceAll(RegExp(r'^\d+[.\-\s]+'), '')
      ..artist = artist
      ..album = album.isEmpty ? null : album
      ..fileSize = entry.size
      ..fileType = ext
      ..albumArtPath = coverPath != null
          ? '$coverScheme${base64Encode(utf8.encode(coverPath))}'
          : null
      ..sourceType = NetworkProtocol.smb
      ..remoteId = remoteId
      ..remoteServerId = server.id
      ..metadataComplete = true
      ..dateAdded = DateTime.now()
      ..lastModified = DateTime.now();
  }

  String _parentDir(String path) {
    final slash = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(0, slash) : '';
  }

  bool _isAudio(String name) {
    final ext = _extension(name);
    return ext != null && _audioExtensions.contains(ext);
  }

  bool _isCoverName(String name) {
    final ext = _extension(name);
    if (ext == null || !_imageExtensions.contains(ext)) return false;
    final dot = name.lastIndexOf('.');
    final stem =
        dot > 0 ? name.substring(0, dot).toLowerCase() : name.toLowerCase();
    return _coverNames.any((c) => stem == c || stem.startsWith('$c.'));
  }

  String? _extension(String name) {
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
    final slash = p.lastIndexOf('/');
    if (slash <= 0) return 'Unknown';
    final parent = p.substring(0, slash);
    final artist = _lastPathSegment(parent);
    return artist.isEmpty ? 'Unknown' : artist;
  }
}
