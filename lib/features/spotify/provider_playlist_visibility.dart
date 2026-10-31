import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Visibility only: hidden playlists remain cached and stay on the provider.
/// No credentials are stored here. Caller supplies a hashed account key.
class ProviderPlaylistVisibility {
  const ProviderPlaylistVisibility();

  String? _key(String provider, String account) {
    if (!{'spotify', 'youtube'}.contains(provider) ||
        !RegExp(r'^[0-9a-f]{24}([0-9a-f]{40})?$').hasMatch(account)) {
      return null;
    }
    return 'lokal.playlists.hidden.v1.$provider.$account';
  }

  Future<Set<String>> hidden(String provider, String account) async {
    final key = _key(provider, account);
    if (key == null) return {};
    final prefs = await SharedPreferences.getInstance();
    try {
      final json = jsonDecode(prefs.getString(key) ?? '[]');
      return json is List
          ? json.whereType<String>().where((id) => id.length <= 120).toSet()
          : <String>{};
    } catch (_) { return {}; }
  }

  Future<Set<String>> setHidden(
      String provider, String account, String playlistId, bool hide) async {
    final key = _key(provider, account);
    if (key == null || playlistId.isEmpty || playlistId.length > 120) return {};
    final ids = await hidden(provider, account);
    if (hide) { ids.add(playlistId); } else { ids.remove(playlistId); }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(ids.toList()));
    return ids;
  }

  Future<void> clear(String provider, String account) async {
    final key = _key(provider, account);
    if (key == null) return;
    await (await SharedPreferences.getInstance()).remove(key);
  }
}
