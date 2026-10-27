import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'album_art_service.dart';
import 'ios_widget_snapshot_builder.dart';

/// Reads already materialized covers only. No extraction, catalogue requests,
/// network fetch or dependency on the audio session is permitted here.
class IosWidgetOwnedArtworkLoader {
  IosWidgetOwnedArtworkLoader({
    required this.ownedRoots,
    required this.materializedPathFor,
    this.cachedNetworkPathFor,
    this.maximumImageBytes = 4 * 1024 * 1024,
    this.maximumTotalBytes = 12 * 1024 * 1024,
  }) {
    if (maximumImageBytes <= 0 ||
        maximumImageBytes > 12 * 1024 * 1024 ||
        maximumTotalBytes <= 0 ||
        maximumTotalBytes > 12 * 1024 * 1024) {
      throw ArgumentError('Widget artwork byte limits must stay within 12 MiB');
    }
  }

  factory IosWidgetOwnedArtworkLoader.system() => IosWidgetOwnedArtworkLoader(
    ownedRoots: () async => [
      await getApplicationSupportDirectory(),
      await getApplicationDocumentsDirectory(),
      await getTemporaryDirectory(),
    ],
    materializedPathFor: (song) async =>
        AlbumArtService.instance.cachedArtworkPathFor(song.filePath),
    cachedNetworkPathFor: (url) async =>
        (await DefaultCacheManager().getFileFromCache(url))?.file.path,
  );

  final Future<List<Directory>> Function() ownedRoots;
  final Future<String?> Function(Song) materializedPathFor;
  final Future<String?> Function(String)? cachedNetworkPathFor;
  final int maximumImageBytes, maximumTotalBytes;

  Future<Map<String, Uint8List>> load(Iterable<Song> sources) async {
    final roots = <String>[];
    for (final root in (await ownedRoots()).take(8)) {
      try {
        roots.add(await root.resolveSymbolicLinks());
      } catch (_) {}
    }
    if (roots.isEmpty) return {};
    final result = <String, Uint8List>{};
    var bytes = 0;
    for (final song in sources.take(13)) {
      if (bytes >= maximumTotalBytes) break;
      final alias = iosWidgetTrackAlias(song.id);
      if (result.containsKey(alias)) continue;
      try {
        String? candidate;
        final raw = song.albumArt;
        final uri = raw == null ? null : Uri.tryParse(raw);
        if (uri?.scheme == 'http' || uri?.scheme == 'https') {
          candidate = await cachedNetworkPathFor?.call(raw!);
        } else if (uri?.scheme == 'file' &&
            (uri!.host.isEmpty || uri.host == 'localhost')) {
          candidate = uri.toFilePath();
        } else if (raw != null && paths.isAbsolute(raw)) {
          candidate = raw;
        }
        final remaining = maximumTotalBytes - bytes;
        final limit = remaining < maximumImageBytes
            ? remaining
            : maximumImageBytes;
        var image = await _readOwned(candidate, roots, limit);
        image ??= await _readOwned(
          await materializedPathFor(song),
          roots,
          limit,
        );
        if (image == null) continue;
        result[alias] = image;
        bytes += image.length;
      } catch (_) {
        // Missing, evicted, denied or unsupported covers degrade metadata only.
      }
    }
    return result;
  }

  Future<Uint8List?> _readOwned(
    String? candidate,
    List<String> roots,
    int limit,
  ) async {
    if (candidate == null) return null;
    try {
      final resolved = await File(candidate).resolveSymbolicLinks();
      if (!roots.any((root) => paths.isWithin(root, resolved))) return null;
      if (await FileSystemEntity.type(resolved, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final file = await File(resolved).open();
      try {
        final size = await file.length();
        if (size <= 0 || size > limit) return null;
        final image = await file.read(limit + 1);
        return image.isEmpty || image.length > limit ? null : image;
      } finally {
        await file.close();
      }
    } catch (_) {
      return null;
    }
  }
}
