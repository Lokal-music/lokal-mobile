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
  static final _preparation = PlaybackCredentialPreparation(
    (key) => _channel.invokeMethod<void>(
      'preparePlaybackCredentials',
      key == null ? null : {'key': key},
    ),
  );

  static Future<void> _prepare({String? key}) async {
    if (!Platform.isIOS) return;
    await _preparation.prepare(key: key);
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
    if (iOptions == null) await _prepare(key: key);
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
    if (iOptions == null && value != null) await _prepare(key: key);
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
    if (iOptions == null) await _prepare(key: key);
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

/// Preparation may coalesce only for the same account. A migration already
/// running for another account can precede a just-completed legacy write.
/// Global enumeration has its own lease; it cannot satisfy a later keyed read.
class PlaybackCredentialPreparation {
  PlaybackCredentialPreparation(this._migrate);
  final Future<void> Function(String? key) _migrate;
  final _pending = <String?, Future<void>>{};

  Future<void> prepare({String? key}) async {
    final existing = _pending[key];
    if (existing != null) return existing;
    final pending = _migrate(key);
    _pending[key] = pending;
    try {
      await pending;
    } finally {
      if (identical(_pending[key], pending)) _pending.remove(key);
    }
  }
}
