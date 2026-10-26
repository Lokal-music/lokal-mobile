import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

typedef NotificationArtworkFetcher = Future<String?> Function(String url);

/// Converts remote album covers into files Android's MediaSession can decode.
///
/// The Flutter player accepts HTTPS artwork URLs, but the native notification
/// currently accepts a local bitmap path. Never await artwork before starting
/// playback or publishing the initial media notification.
class NotificationArtworkResolver {
  NotificationArtworkResolver({NotificationArtworkFetcher? fetcher})
      : _fetcher = fetcher ?? _cacheRemoteImage;

  final NotificationArtworkFetcher _fetcher;
  int _generation = 0;
  String? _identity;
  String? _resolvedPath;

  /// Returns an immediately usable local path, or null while a remote cover
  /// is being cached. Only the latest track can publish an async completion.
  String? pathFor({
    required String identity,
    required String? artwork,
    required void Function(String path) onResolved,
  }) {
    final source = artwork?.trim();
    final key = identity + '\u0000' + (source ?? '');
    if (key == _identity) return _resolvedPath;

    final generation = ++_generation;
    _identity = key;
    _resolvedPath = null;

    if (source == null || source.isEmpty) return null;
    final uri = Uri.tryParse(source);
    if (uri == null || !uri.hasScheme) {
      // Filesystem paths are already directly readable by Android.
      return _resolvedPath = source;
    }
    if ((uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      // Do not hand arbitrary provider schemes to BitmapFactory.decodeFile.
      return null;
    }

    unawaited(_resolveRemote(source, generation, onResolved));
    return null;
  }

  Future<void> _resolveRemote(
    String source,
    int generation,
    void Function(String path) onResolved,
  ) async {
    try {
      final path = await _fetcher(source);
      if (path == null || path.isEmpty || generation != _generation) return;
      _resolvedPath = path;
      onResolved(path);
    } catch (_) {
      // Missing artwork must never prevent audio or the media notification.
    }
  }

  /// Invalidates late completions on notification dismissal/owner handoff.
  void invalidate() {
    ++_generation;
    _identity = null;
    _resolvedPath = null;
  }

  static Future<String?> _cacheRemoteImage(String url) async {
    // Reuse the same disk cache as other Flutter cover-art consumers.
    final image = await DefaultCacheManager()
        .getSingleFile(url)
        .timeout(const Duration(seconds: 15));
    return await image.exists() ? image.path : null;
  }
}
