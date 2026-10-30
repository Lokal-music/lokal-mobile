import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 17 protects LAN sockets with ACCESS_LOCAL_NETWORK, separately
/// from INTERNET. The existing desktop-link bridge owns the native prompt;
/// reuse it for SMB, WebDAV and other network libraries.
class NetworkLocalAccess {
  NetworkLocalAccess._();

  static const channel = MethodChannel('lokal/desktop_link');

  @visibleForTesting
  static bool isPrivateHost(String host) {
    final name = host.toLowerCase().replaceFirst(RegExp(r'\., '');
    if (name == 'localhost' || name.endsWith('.localhost')) return false;
    final address = InternetAddress.tryParse(name.split('%').first);
    if (address == null) {
      // Single-label NAS names and mDNS are normally local. Public domains
      // must not trigger a LAN permission prompt.
      return !name.contains('.') || name.endsWith('.local') ||
          name == 'home.arpa' || name.endsWith('.home.arpa');
    }
    if (address.isLoopback) return false;
    final bytes = address.rawAddress;
    if (bytes.length == 16) {
      return bytes[0] & 0xfe == 0xfc || address.isLinkLocal;
    }
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
  }

  static Future<void>? _pending;

  static Future<void> ensure(Uri uri, {
    MethodChannel bridge = channel,
    bool? isAndroid,
  }) async {
    if (!(isAndroid ?? Platform.isAndroid) || !isPrivateHost(uri.host)) return;
    await (_pending ??= _ask(bridge).whenComplete(() => _pending = null));
  }

  static Future<void> _ask(MethodChannel bridge) async {
    try {
      final granted = await bridge.invokeMethod<bool>('requestLocalNetwork');
      if (granted != true) {
        throw const NetworkAccessDenied();
      }
    } on PlatformException catch (e) {
      throw NetworkAccessDenied(e.code == 'busy'
          ? 'Another network permission request is already open.'
          : 'Local-network permission is required. Enable it in Android app permissions.');
    } on MissingPluginException {
      // Non-Android hosts don't register the desktop-link bridge.
      throw const NetworkAccessDenied();
    }
  }
}

class NetworkAccessDenied implements Exception {
  const NetworkAccessDenied([
    this.message = 'Local-network permission is required. Allow Local network access for Lokal in Android settings.',
  ]);

  final String message;
  @override
  String toString() => message;
}
), '');
    if (name == 'localhost' || name.endsWith('.localhost')) return false;
    final address = InternetAddress.tryParse(name.split('%').first);
    if (address == null) {
      // Single-label NAS names and mDNS are normally local. Public domains
      // must not trigger a LAN permission prompt.
      return !name.contains('.') || name.endsWith('.local') ||
          name == 'home.arpa' || name.endsWith('.home.arpa');
    }
    if (address.isLoopback) return false;
    final bytes = address.rawAddress;
    if (bytes.length == 16) {
      return bytes[0] & 0xfe == 0xfc || address.isLinkLocal;
    }
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
  }

  static Future<void>? _pending;

  static Future<void> ensure(Uri uri, {
    MethodChannel bridge = channel,
    bool? isAndroid,
  }) async {
    if (!(isAndroid ?? Platform.isAndroid) || !isPrivateHost(uri.host)) return;
    await (_pending ??= _ask(bridge).whenComplete(() => _pending = null));
  }

  static Future<void> _ask(MethodChannel bridge) async {
    try {
      final granted = await bridge.invokeMethod<bool>('requestLocalNetwork');
      if (granted != true) {
        throw const NetworkAccessDenied();
      }
    } on PlatformException catch (e) {
      throw NetworkAccessDenied(e.code == 'busy'
          ? 'Another network permission request is already open.'
          : 'Local-network permission is required. Enable it in Android app permissions.');
    } on MissingPluginException {
      // Non-Android hosts don't register the desktop-link bridge.
      throw const NetworkAccessDenied();
    }
  }
}

class NetworkAccessDenied implements Exception {
  const NetworkAccessDenied([
    this.message = 'Local-network permission is required. Allow Local network access for Lokal in Android settings.',
  ]);

  final String message;
  @override
  String toString() => message;
}
