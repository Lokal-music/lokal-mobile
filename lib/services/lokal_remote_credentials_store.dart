import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flick/services/playback_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/lokal_remote_state.dart';
import 'lokal_remote_service.dart' show LokalRemoteService;
import 'link/link_protocol.dart' show linkUuid;

/// Storage seam for the remote controller. Tests can keep credentials in
/// memory without touching platform secure storage.
abstract interface class LokalRemoteCredentialsStore {
  Future<LokalRemoteCredentials?> read();
  Future<void> write(LokalRemoteCredentials credentials);
  Future<void> clear();
  /// Compare and delete in the same serialized credential-store operation.
  /// A replacement pairing must never be erased by a stale Forget callback.
  Future<void> clearIfMatching(LokalRemoteCredentials? expected);
}

/// Stores an atomic origin/pairing/credential record in secure storage.
/// A non-secret origin mirror keeps legacy connection settings compatible.
/// Tokens never enter a URL, ordinary preferences, widget state, or logs.
class SecureLokalRemoteCredentialsStore implements LokalRemoteCredentialsStore {
  SecureLokalRemoteCredentialsStore({
    FlutterSecureStorage? secureStorage,
    this._preferences,
  }) : _secureStorage = secureStorage ?? const PlaybackSecureStorage();

  static const originKey = 'konnekted.lokal_remote.origin.v1';
  static const secureKey = 'konnekted.lokal_remote.secrets.v1';

  final FlutterSecureStorage _secureStorage;
  SharedPreferences? _preferences;
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final pending = _tail.then((_) => operation());
    _tail = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<LokalRemoteCredentials?> read() => _serial(_read);

  Future<LokalRemoteCredentials?> _read() async {
    final raw = await _secureStorage.read(key: secureKey);
    Map<String, dynamic> record = const {'version': 1};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic> ||
            (decoded['version'] != 1 && decoded['version'] != 2)) {
          return null;
        }
        record = decoded;
      } on FormatException {
        return null;
      }
    }
    final atomic = record['version'] == 2;
    final origin = atomic
        ? record['origin'] as String?
        : (await _prefs).getString(originKey);
    if (origin == null || origin.trim().isEmpty) return null;
    final pairingID = record['pairingID'];
    if (atomic && (pairingID is! String || !_validPairingID(pairingID))) {
      return null;
    }
    return LokalRemoteCredentials(
      origin: LokalRemoteService.normalizeOrigin(origin),
      remoteToken: record['remoteToken'] as String? ?? '',
      apiKey: record['apiKey'] as String? ?? '',
      desktopId: record['desktopId'] as String?,
      desktopUserId: record['desktopUserId'] as String?,
      pairingID: atomic ? pairingID as String : null,
    );
  }

  static bool _validPairingID(String value) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(value);

  @override
  Future<void> write(LokalRemoteCredentials credentials) =>
      _serial(() => _write(credentials));

  Future<void> _write(LokalRemoteCredentials credentials) async {
    final origin = LokalRemoteService.normalizeOrigin(
      credentials.origin.toString(),
    );
    final pairingID = credentials.pairingID ?? linkUuid();
    if (!_validPairingID(pairingID)) {
      throw const FormatException('Invalid pairing identity.');
    }
    // The native background session reads only this atomic record. An origin
    // preference from a partial write can never redirect an older bearer token.
    await _secureStorage.write(
      key: secureKey,
      value: jsonEncode({
        'version': 2,
        'origin': origin.toString(),
        'pairingID': pairingID,
        'remoteToken': credentials.remoteToken,
        'apiKey': credentials.apiKey,
        'desktopId': credentials.desktopId,
        'desktopUserId': credentials.desktopUserId,
      }),
    );
    if (!await (await _prefs).setString(originKey, origin.toString())) {
      throw StateError('Could not save desktop connection preferences.');
    }
  }

  static bool sameAuthority(
    LokalRemoteCredentials? current,
    LokalRemoteCredentials? expected,
  ) {
    if (current == null || expected == null) return current == expected;
    return current.origin == expected.origin &&
        current.desktopId == expected.desktopId &&
        current.desktopUserId == expected.desktopUserId &&
        current.pairingID == expected.pairingID &&
        current.remoteToken == expected.remoteToken &&
        current.apiKey == expected.apiKey;
  }

  @override
  Future<void> clearIfMatching(LokalRemoteCredentials? expected) =>
      _serial(() async {
        final current = await _read();
        if (!sameAuthority(current, expected)) {
          throw StateError('Desktop pairing changed. Refresh and retry.');
        }
        await _clear();
      });

  @override
  Future<void> clear() => _serial(_clear);

  Future<void> _clear() async {
    // Delete authority first. A preferences failure must not leave background
    // networking with a valid secret after the user forgets this desktop.
    await _secureStorage.delete(key: secureKey);
    if (!await (await _prefs).remove(originKey)) {
      throw StateError('Could not clear desktop connection preferences.');
    }
  }
}
