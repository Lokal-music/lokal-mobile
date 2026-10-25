import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flick/services/playback_secure_storage.dart';

import 'youtube_music_account.dart';

/// Stores provider cookies only in the platform's secure storage.
class YoutubeMusicSessionStore {
  YoutubeMusicSessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const PlaybackSecureStorage();

  static const _key = 'lokal.ytmusic.session.v1';
  final FlutterSecureStorage _storage;

  Future<YoutubeMusicSession?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final session = YoutubeMusicSession.fromJson(jsonDecode(raw));
      return session != null && session.signedIn ? session : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> write(YoutubeMusicSession session) =>
      _storage.write(key: _key, value: jsonEncode(session.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}
