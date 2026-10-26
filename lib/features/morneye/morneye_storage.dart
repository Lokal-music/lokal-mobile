import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flick/services/playback_secure_storage.dart';
import 'package:path/path.dart' as p;

/// What Morneye add-ons keep between runs, as desktop's
/// electron/morneye/storage.js: plain `storage` JSON, and everything else
/// (settings, credentials, logins) sealed with AES-256-GCM under a key that
/// lives in the phone's secure storage.

/// AES-256-GCM, provided by the native core.
abstract class MorneyeSealer {
  Uint8List seal(Uint8List data, Uint8List key, Uint8List nonce);
  Uint8List open(Uint8List data, Uint8List key);
}

/// Holds the 32-byte key everything sealed is derived from.
abstract class MorneyeKeyVault {
  Future<Uint8List?> read();
  Future<void> write(Uint8List key);
  Future<void> delete();
}

class SecureMorneyeKeyVault implements MorneyeKeyVault {
  SecureMorneyeKeyVault([FlutterSecureStorage? storage])
    : _storage = storage ?? const PlaybackSecureStorage();

  static const _key = 'lokal.morneye.master.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> read() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    try {
      return base64.decode(value);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(Uint8List key) =>
      _storage.write(key: _key, value: base64.encode(key));

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

Uint8List morneyeRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

/// Writes [data] to [file] through a temporary file, so a crash never leaves
/// half a record.
void morneyeAtomicWrite(File file, List<int> data) {
  file.parent.createSync(recursive: true);
  final temp = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    temp.writeAsBytesSync(data, flush: true);
    temp.renameSync(file.path);
  } finally {
    if (temp.existsSync()) temp.deleteSync();
  }
}

class MorneyeStorage {
  MorneyeStorage(this.root, {required this.sealer, MorneyeKeyVault? vault})
    : _vault = vault ?? SecureMorneyeKeyVault();

  final Directory root;
  final MorneyeSealer sealer;
  final MorneyeKeyVault _vault;
  Uint8List? _key;

  static const _limit = 5 * 1024 * 1024;

  /// Loads (or makes) the key; call before reading or writing sealed data.
  Future<void> open() async {
    if (_key != null) return;
    var key = await _vault.read();
    if (key == null || key.length != 32) {
      // A lost key also loses what it sealed: start over cleanly.
      _discardSealed();
      key = morneyeRandomBytes(32);
      await _vault.write(key);
    }
    _key = key;
  }

  /// Forgets the key and every saved login and setting.
  Future<void> reset() async {
    _key = null;
    await _vault.delete();
    _discardSealed();
  }

  void _discardSealed() {
    final data = Directory(p.join(root.path, 'data'));
    if (!data.existsSync()) return;
    for (final entry in data.listSync(recursive: true)) {
      if (entry is File && entry.path.endsWith('.enc')) entry.deleteSync();
    }
  }

  File _file(String namespace, String purpose) {
    if (!RegExp(r'^[a-f0-9]{10,64}$').hasMatch(namespace) ||
        !RegExp(r'^[a-z]+$').hasMatch(purpose)) {
      throw ArgumentError('Invalid addon storage namespace');
    }
    final extension = purpose == 'storage' ? 'json' : 'enc';
    return File(p.join(root.path, 'data', namespace, '$purpose.$extension'));
  }

  Uint8List _derived(String namespace, String purpose) {
    final key = _key;
    if (key == null) throw StateError('Addon storage is not open');
    return Uint8List.fromList(
      Hmac(sha256, key)
          .convert(
            utf8.encode(
              'Lokal Morneye storage v1\u0000$purpose\u0000$namespace',
            ),
          )
          .bytes,
    );
  }

  Map<String, Object?> read(String namespace, String purpose) {
    final file = _file(namespace, purpose);
    if (!file.existsSync()) return {};
    final bytes = file.readAsBytesSync();
    final text = purpose == 'storage'
        ? utf8.decode(bytes)
        : utf8.decode(sealer.open(bytes, _derived(namespace, purpose)));
    final value = jsonDecode(text);
    if (value is! Map) {
      throw const FormatException('Invalid addon storage record');
    }
    return value.cast<String, Object?>();
  }

  void write(String namespace, String purpose, Map<String, Object?> value) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    if (bytes.length > _limit) throw StateError('Addon storage exceeds 5 MB');
    final file = _file(namespace, purpose);
    morneyeAtomicWrite(
      file,
      purpose == 'storage'
          ? bytes
          : sealer.seal(
              bytes,
              _derived(namespace, purpose),
              morneyeRandomBytes(12),
            ),
    );
  }

  Map<String, Object?> update(
    String namespace,
    String purpose,
    String key,
    Object? value, {
    bool remove = false,
  }) {
    final current = read(namespace, purpose);
    if (remove) {
      current.remove(key);
    } else {
      current[key] = value;
    }
    write(namespace, purpose, current);
    return {'success': true};
  }

  /// Removes everything kept for [namespace].
  void forget(String namespace) {
    final dir = Directory(p.join(root.path, 'data', namespace));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}
