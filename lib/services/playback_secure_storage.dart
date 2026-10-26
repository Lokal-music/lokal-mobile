import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Credential reads/writes used during playback. iOS must allow token refresh,
/// scrobbling and add-on vault access after the listener locks the screen.
///
/// Keep the locked plugin's service, keys and Android defaults. Swift changes
/// existing iOS items' accessibility in place before access: no copy/delete of
/// secrets, no shared access group, no iCloud synchronization. The standard
/// after-first-unlock class also preserves encrypted-backup restoration of the
/// Morneye vault key; this deliberately does not use ThisDeviceOnly.
class PlaybackSecureStorage extends FlutterSecureStorage {
  const PlaybackSecureStorage()
    : super(
        iOptions: const IOSOptions(
          accessibility: KeychainAccessibility.first_unlock,
        ),
      );

  static const _channel = MethodChannel('lokal/ios');
  static Future<void>? _preparing;

  static Future<void> _prepare() async {
    if (!Platform.isIOS) return;
    final existing = _preparing;
    if (existing != null) return existing;
    final pending = _channel.invokeMethod<void>('preparePlaybackCredentials');
    _preparing = pending;
    try {
      await pending;
    } finally {
      if (identical(_preparing, pending)) _preparing = null;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (iOptions == null) await _prepare();
    return super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (iOptions == null && value != null) await _prepare();
    return super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (iOptions == null) await _prepare();
    return super.containsKey(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (iOptions == null) await _prepare();
    return super.readAll(
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}
