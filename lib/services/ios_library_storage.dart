import 'dart:convert';
import 'dart:io';

import 'package:flick/data/database.dart';
import 'package:flick/services/music_folder_service.dart';
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// iOS may move an app's container during an update/re-sign. Keep the existing
/// library IDs and rebase only app-owned locators, before any player restores.
String relocateIosPath(String path, String previousRoot, String currentRoot) {
  for (final prefix in [
    previousRoot,
    Uri.directory(previousRoot).toString().replaceFirst(RegExp(r'/$'), ''),
  ]) {
    if (path == prefix || path.startsWith('$prefix/')) {
      final replacement = prefix.startsWith('file:')
          ? Uri.directory(currentRoot)
                .toString()
                .replaceFirst(RegExp(r'/$'), '')
          : currentRoot;
      return '$replacement${path.substring(prefix.length)}';
    }
  }
  return path;
}

Object? relocateIosStoredValue(
  Object? value,
  String previousRoot,
  String currentRoot,
) {
  if (value is String) {
    final path = relocateIosPath(value, previousRoot, currentRoot);
    if (path != value) return path;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map || decoded is List) {
        return jsonEncode(
          relocateIosStoredValue(decoded, previousRoot, currentRoot),
        );
      }
    } on FormatException {
      // Ordinary labels and identifiers are not serialized JSON.
    }
  } else if (value is List) {
    return [
      for (final item in value)
        relocateIosStoredValue(item, previousRoot, currentRoot),
    ];
  } else if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key: relocateIosStoredValue(
          entry.value,
          previousRoot,
          currentRoot,
        ),
    };
  }
  return value;
}

class IosLibraryStorage {
  static const _containerKey = 'lokal.ios.container_root';

  static Future<void> initialize() async {
    if (!Platform.isIOS) return;
    final documents = await getApplicationDocumentsDirectory();
    final currentRoot = documents.parent.path;
    final prefs = await SharedPreferences.getInstance();
    final previousRoot = prefs.getString(_containerKey);
    if (previousRoot != null && previousRoot != currentRoot) {
      String? move(String? path) => path == null
          ? null
          : relocateIosPath(path, previousRoot, currentRoot);
      final songs = await Database.songs.where().findAll();
      final folders = await Database.folders.where().findAll();
      final artists = await Database.artists.where().findAll();
      await Database.instance.writeTxn(() async {
        for (final song in songs) {
          song.filePath = move(song.filePath)!;
          song.folderUri = move(song.folderUri);
          song.mediaStoreUri = move(song.mediaStoreUri);
          song.albumArtPath = move(song.albumArtPath);
        }
        for (final folder in folders) {
          folder.uri = move(folder.uri)!;
        }
        for (final artist in artists) {
          artist.artPath = move(artist.artPath);
        }
        await Database.songs.putAll(songs);
        await Database.folders.putAll(folders);
        await Database.artists.putAll(artists);
      });
      for (final key in prefs.getKeys().toList()) {
        if (key == _containerKey) continue;
        final value = prefs.get(key);
        if (value is String) {
          await prefs.setString(
            key,
            relocateIosStoredValue(value, previousRoot, currentRoot) as String,
          );
        } else if (value is List<String>) {
          await prefs.setStringList(key, [
            for (final item in value)
              relocateIosStoredValue(item, previousRoot, currentRoot) as String,
          ]);
        }
      }
    }
    await prefs.setString(_containerKey, currentRoot);
    final music = Directory('${documents.path}/Music');
    await music.create(recursive: true);
    await MusicFolderService().addLocalFolder(music.path, 'Lokal Music');
  }
}
