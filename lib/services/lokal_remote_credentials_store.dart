import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flick/services/playback_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/lokal_remote_state.dart';
import 'lokal_remote_service.dart' show LokalRemoteService;

/// Storage seam for the remote controller. Tests can keep credentials in
/// memory without touching platform secure storage.
abstract interface class LokalRemoteCredentialsStore {
  Future<LokalRemoteCredentials?> read();
  Future<void> write(LokalRemoteCredentials credentials);
  Future<void> clear();
}

/// Stores the LAN origin in preferences and bearer values in secure storage.
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

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<LokalRemoteCredentials?> read() async {
    final preferences = await _prefs;
    final origin = preferences.getString(originKey)?.trim() ?? '';
    if (origin.isEmpty) return null;
    final normalized = LokalRemoteService.normalizeOrigin(origin);
    final raw = await _secureStorage.read(key: secureKey);
    var remoteToken = '';
    var apiKey = '';
    String? desktopId;
    String? desktopUserId;
    if (raw != null && raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw);
        if (json is Map && json['version'] == 1) {
          if (json['remoteToken'] is String) {
            remoteToken = json['remoteToken'] as String;
          }
          if (json['apiKey'] is String) apiKey = json['apiKey'] as String;
          if (json['desktopId'] is String)
            desktopId = json['desktopId'] as String;
          if (json['desktopUserId'] is String)
            desktopUserId = json['desktopUserId'] as String;
        }
      } catch (_) {
        // A corrupt secret record behaves like an unauthenticated endpoint;
        // the user can replace it from the settings page.
      }
    }
    return LokalRemoteCredentials(
      origin: normalized,
      remoteToken: remoteToken,
      apiKey: apiKey,
      desktopId: desktopId,
      desktopUserId: desktopUserId,
    );
  }

  @override
  Future<void> write(LokalRemoteCredentials credentials) async {
    final origin = LokalRemoteService.normalizeOrigin(
      credentials.origin.toString(),
    );
    await (await _prefs).setString(originKey, origin.toString());
    await _secureStorage.write(
      key: secureKey,
      value: jsonEncode({
        'version': 1,
        'remoteToken': credentials.remoteToken,
        'apiKey': credentials.apiKey,
        'desktopId': credentials.desktopId,
        'desktopUserId': credentials.desktopUserId,
      }),
    );
  }

  @override
  Future<void> clear() async {
    await (await _prefs).remove(originKey);
    await _secureStorage.delete(key: secureKey);
  }
}
