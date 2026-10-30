import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:synchronized/synchronized.dart';

/// One native libsmb2 connection for a NAS operation. Mornye uses the same
/// native transport, including SMB 2/3 dialect, signing and encryption support.
/// Connections are always closed, including on failed scans and downloads.
typedef NativeSmbEntry = ({
  String name,
  String path,
  int size,
  bool isDir,
});

abstract class NativeSmbSession {
  Future<List<NativeSmbEntry>> list(String directory);
  Future<List<int>> read(String path);
  Future<void> download(
    String path,
    String destination, {
    void Function(int received, int total)? onProgress,
  });
  Future<void> close();
}

typedef NativeSmbConnector = Future<NativeSmbSession> Function({
  required String host,
  required int port,
  required String share,
  required String username,
  required String password,
});

/// Serializes native libsmb2 calls across pools: its native context registry
/// is process-global. Other Dart tasks remain asynchronous.
class Libsmb2Transport implements NativeSmbSession {
  Libsmb2Transport._(this._pool);

  static final _native = Lock();
  final Smb2Pool _pool;
  bool _closed = false;

  static Future<NativeSmbSession> connect({
    required String host,
    required int port,
    required String share,
    required String username,
    required String password,
  }) async {
    // DOMAIN\\username is supported without introducing a new setting.
    final separator = username.indexOf('\\');
    final domain = separator > 0 ? username.substring(0, separator) : '';
    final user = separator > 0 ? username.substring(separator + 1) : username;
    final address = port == 445 ? host : '$host:$port';
    final pool = await _native.synchronized(() => Smb2Pool.connect(
      host: address,
      share: share,
      user: user,
      password: password,
      domain: domain,
      workers: 1,
      timeoutSeconds: 20,
      version: Smb2Version.any,
    ));
    return Libsmb2Transport._(pool);
  }

  @override
  Future<List<NativeSmbEntry>> list(String directory) async {
    final rows = await _native.synchronized(() => _pool.listDirectory(directory));
    return [
      for (final row in rows)
        if (row.name != '.' && row.name != '..')
          (
            name: row.name,
            path: directory.isEmpty ? row.name : '$directory/${row.name}',
            size: row.size,
            isDir: row.isDirectory,
          ),
    ];
  }

  @override
  Future<List<int>> read(String path) async =>
      _native.synchronized(() => _pool.readFile(path));

  @override
  Future<void> download(
    String path,
    String destination, {
    void Function(int received, int total)? onProgress,
  }) async {
    final partial = File(
      '$destination.smb-part-${DateTime.now().microsecondsSinceEpoch}',
    );
    final file = partial.openWrite();
    var completed = false;
    try {
      final (handle, size) =
          await _native.synchronized(() => _pool.openFileWithSize(path));
      try {
        var offset = 0;
        while (offset < size) {
          final chunk = await _native.synchronized(() => _pool.readFromHandle(
            handle,
            offset: offset,
            length: (size - offset).clamp(1, 256 * 1024),
          ));
          if (chunk.isEmpty) {
            throw const FileSystemException('SMB download truncated');
          }
          file.add(chunk);
          offset += chunk.length;
          onProgress?.call(offset, size);
        }
      } finally {
        await _native.synchronized(() => _pool.closeHandle(handle));
      }
      await file.flush();
      await file.close();
      await partial.rename(destination);
      completed = true;
    } finally {
      if (!completed) {
        try { await file.close(); } catch (_) {}
        try { await partial.delete(); } catch (_) {}
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _native.synchronized(() => _pool.disconnect());
  }
}
