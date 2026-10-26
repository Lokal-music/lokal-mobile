import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flick/features/morneye/morneye_host.dart';
import 'package:flick/features/morneye/morneye_runtime.dart';
import 'package:flick/features/morneye/morneye_storage.dart';

/// Stands in for the native core: a keyed XOR "seal" with a checksum, so a
/// wrong key fails like AES-GCM would.
class FakeNative implements MorneyeNative {
  Map<String, Object?> info = {
    'codec': 'flac',
    'format': 'flac',
    'duration_ms': 0,
  };

  Uint8List _xor(List<int> data, List<int> key) => Uint8List.fromList([
    for (var i = 0; i < data.length; i++) data[i] ^ key[i % key.length],
  ]);

  @override
  Uint8List seal(Uint8List data, Uint8List key, Uint8List nonce) {
    final tag = sha256.convert([...key, ...data]).bytes.sublist(0, 16);
    return Uint8List.fromList([...nonce, ..._xor(data, key), ...tag]);
  }

  @override
  Uint8List open(Uint8List data, Uint8List key) {
    final plain = _xor(data.sublist(12, data.length - 16), key);
    final tag = sha256.convert([...key, ...plain]).bytes.sublist(0, 16);
    final given = data.sublist(data.length - 16);
    for (var i = 0; i < 16; i++) {
      if (tag[i] != given[i]) throw const FormatException('Bad tag');
    }
    return plain;
  }

  @override
  Uint8List cipher(
    Uint8List data, {
    required String algorithm,
    required String mode,
    required Uint8List key,
    required Uint8List iv,
    required bool pkcs7,
    required bool decrypt,
  }) => _xor(data, key);

  @override
  Future<Map<String, Object?>> mediaInfo(String path) async => info;
}

class MemoryVault implements MorneyeKeyVault {
  Uint8List? key;

  @override
  Future<Uint8List?> read() async => key;

  @override
  Future<void> write(Uint8List key) async => this.key = key;

  @override
  Future<void> delete() async => key = null;
}

typedef GuestMethod = Future<Object?> Function(
  List<Object?> args,
  Future<Object?> Function(String method, List<Object?> args) host,
);

/// A package's script, written in Dart: [FakeGuest] runs it in place of
/// QuickJS, calling the host through the same JSON bridge.
class FakeGuest implements MorneyeGuest {
  FakeGuest(this.script, this.bridge);

  final Map<String, GuestMethod> script;
  final MorneyeHostBridge bridge;
  bool _closed = false;
  final calls = <String>[];

  Future<Object?> host(String method, List<Object?> args) async {
    final reply = jsonDecode(await bridge(method, jsonEncode(args))) as Map;
    if (reply.containsKey('failure')) throw StateError('${reply['failure']}');
    return reply['value'];
  }

  @override
  List<String> get methods => script.keys.toList();

  @override
  bool get closed => _closed;

  @override
  Future<String> invoke(
    String method,
    String argsJson,
    Duration timeout,
  ) async {
    if (_closed) throw StateError('Extension runtime closed');
    calls.add(method);
    final run = script[method];
    if (run == null) throw StateError('Method $method is not registered');
    try {
      final value = await run(
        (jsonDecode(argsJson) as List).cast<Object?>(),
        host,
      ).timeout(timeout);
      return jsonEncode(value);
    } on TimeoutException {
      _closed = true;
      throw StateError('Extension execution timed out');
    }
  }

  @override
  Future<String> callback(int id, String argsJson) async => '';

  @override
  void close() => _closed = true;
}

/// Starts [FakeGuest]s, looking each script up by the package's code.
class FakeEngine {
  final scripts = <String, Map<String, GuestMethod>>{};
  final started = <FakeGuest>[];
  final configurations = <Map<String, Object?>>[];

  Future<MorneyeGuest> start(
    String code,
    String config,
    MorneyeHostBridge bridge,
  ) async {
    final script = scripts[code];
    if (script == null) throw StateError('SyntaxError: unknown script');
    configurations.add((jsonDecode(config) as Map).cast<String, Object?>());
    final guest = FakeGuest(script, bridge);
    started.add(guest);
    return guest;
  }
}

Map<String, Object?> manifestFor(
  String name, {
  String version = '1.0.0',
  List<String> network = const ['api.example.com'],
  Map<String, Object?> extra = const {},
}) => {
  'name': name,
  'displayName': name.toUpperCase(),
  'version': version,
  'type': ['download_provider'],
  'permissions': {'network': network, 'storage': true, 'file': true},
  ...extra,
};

Uint8List packageBytes(Map<String, Object?> manifest, String code) {
  final archive = Archive()
    ..add(ArchiveFile.string('manifest.json', jsonEncode(manifest)))
    ..add(ArchiveFile.string('index.js', code));
  return ZipEncoder().encodeBytes(archive);
}
