import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/database.dart';
import '../../data/repositories/song_repository.dart';
import '../../models/lokal_remote_state.dart';
import '../lokal_remote_credentials_store.dart';
import 'lokal_desktop_source.dart';

/// Opt-in copies are queued only by completed phone downloads, never by a scan.
/// Failed transfers remain queued; original phone files are never moved/deleted.
class LinkDownloadOutbox {
  /// Organization changes physical paths without creating a new download.
  static Future<void> relocate(String oldPath, String newPath) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where(
      (key) =>
          key.startsWith('lokal.link.') && key.endsWith('.download_outbox'),
    )) {
      final paths = prefs.getStringList(key) ?? const <String>[];
      if (!paths.contains(oldPath)) continue;
      if (!await prefs.setStringList(
        key,
        paths.map((path) => path == oldPath ? newPath : path).toSet().toList(),
      )) {
        throw StateError('Could not update pending desktop download copies.');
      }
    }
  }

  static Future<void> enqueue(String path) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs
            .getString(SecureLokalRemoteCredentialsStore.originKey)
            ?.isNotEmpty !=
        true)
      return;
    try {
      final credentials = await SecureLokalRemoteCredentialsStore().read();
      if (credentials?.desktopId == null ||
          prefs.getBool(
                'lokal.link.${credentials!.desktopId}.send_downloads',
              ) !=
              true)
        return;
      final key = 'lokal.link.${credentials.desktopId}.download_outbox';
      final pending = (prefs.getStringList(key) ?? []).toSet()..add(path);
      await prefs.setStringList(key, pending.toList());
    } catch (_) {
      /* Download success does not depend on secure-store availability. */
    }
  }

  bool _flushing = false;
  bool get busy => _flushing;
  Future<void> flush(
    LokalRemoteCredentials credentials, {
    required bool Function() connected,
  }) async {
    if (_flushing || !Database.isInitialized) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('lokal.link.${credentials.desktopId}.send_downloads') !=
        true)
      return;
    _flushing = true;
    try {
      final key = 'lokal.link.${credentials.desktopId}.download_outbox';
      final pending = List<String>.from(prefs.getStringList(key) ?? []);
      if (pending.isEmpty) return;
      final repository = SongRepository();
      for (final path in pending) {
        if (!connected()) break;
        if (await File(path).exists()) {
          // Never fetch every song for one pending download. Large libraries
          // can otherwise freeze manual sync before it even starts.
          final song = await repository.getSongByFilePath(path);
          if (song == null) continue;
          await LokalDesktopSource.instance.uploadToDesktop(
            song,
            credentials,
          );
        }
        final latest = List<String>.from(prefs.getStringList(key) ?? [])
          ..remove(path);
        await prefs.setStringList(key, latest);
      }
    } finally {
      _flushing = false;
    }
  }
}
