import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/features/discovery/recommendation_match.dart';

/// Shared artist favorites. Preserves the boolean preferences created by
/// older artist detail pages and records display names for Spotify-only follows.
class ArtistFollowStore extends ChangeNotifier {
  ArtistFollowStore({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;
  static final instance = ArtistFollowStore();
  static const _prefix = 'lokal.artist.follow.';
  static const registryKey = 'lokal.artist.follow.names.v1';
  final Future<SharedPreferences> Function() _preferences;
  Future<void>? _loading;
  SharedPreferences? _prefs;
  Map<String, String> _names = {};

  static String keyOf(String? name) => recommendationKey(name);
  bool get isLoaded => _prefs != null;
  bool isFollowed(String? name) => _names.containsKey(keyOf(name));
  List<String> get followedNames => List.unmodifiable(_names.values);
  int get count => _names.length;

  Future<void> load() {
    if (_prefs != null) return Future.value();
    return _loading ??= _restore().whenComplete(() => _loading = null);
  }

  Future<void> _restore() async {
    final prefs = await _preferences();
    final names = <String, String>{};
    for (final name in prefs.getStringList(registryKey) ?? const <String>[]) {
      final clean = name.trim();
      final key = keyOf(clean);
      if (key.isNotEmpty && prefs.getBool('$_prefix$key') != false) {
        names.putIfAbsent(key, () => clean);
      }
    }
    // Legacy flags remain authoritative (even when there is no registry).
    for (final key in prefs.getKeys()) {
      if (key == registryKey || !key.startsWith(_prefix) ||
          prefs.getBool(key) != true) continue;
      final artistKey = key.substring(_prefix.length);
      if (artistKey.isNotEmpty) names.putIfAbsent(artistKey, () => artistKey);
    }
    _names = names;
    _prefs = prefs;
    notifyListeners();
  }

  Future<void> setFollowed(String artist, bool value) async {
    await load();
    final name = artist.trim();
    final key = keyOf(name);
    if (key.isEmpty) return;
    final next = Map<String, String>.of(_names);
    if (value) {
      next.putIfAbsent(key, () => name);
    } else {
      next.remove(key);
    }
    await _prefs!.setBool('$_prefix$key', value);
    await _prefs!.setStringList(registryKey, next.values.toList());
    _names = next;
    notifyListeners();
  }

  /// Additive, one-way import: never unfollow a local artist or change Spotify.
  /// Fetching all remote pages before calling this avoids partial imports.
  Future<ArtistFollowImport> importNames(Iterable<String> artists) async {
    await load();
    final next = Map<String, String>.of(_names);
    final reenabled = <String>[];
    var received = 0;
    var added = 0;
    for (final raw in artists) {
      final name = raw.trim();
      final key = keyOf(name);
      if (name.isEmpty || name.length > 200 || key.isEmpty) continue;
      if (++received > 2000) {
        throw StateError('Too many Spotify artists to import safely.');
      }
      if (next.containsKey(key)) continue;
      if (_prefs!.getBool('$_prefix$key') == false) reenabled.add(key);
      next[key] = name;
      added++;
    }
    for (final key in reenabled) {
      await _prefs!.setBool('$_prefix$key', true);
    }
    await _prefs!.setStringList(registryKey, next.values.toList());
    _names = next;
    notifyListeners();
    return ArtistFollowImport(received: received, added: added);
  }
}

@immutable
class ArtistFollowImport {
  const ArtistFollowImport({required this.received, required this.added});
  final int received;
  final int added;
}
