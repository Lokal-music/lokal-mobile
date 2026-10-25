import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:home_widget/home_widget.dart';

import '../models/song.dart';
import 'apple_music/apple_music_metadata_service.dart';
import 'online_radio_recommendations.dart';

/// A durable, small, *metadata-only* recommendation snapshot. No stream URLs,
/// auth headers or provider credentials are persisted to the launcher.
class WidgetRecommendationService {
  WidgetRecommendationService._();
  static final instance = WidgetRecommendationService._();

  static const key = 'flick_widget_recommendations';
  static const provider =
      'com.mossapps.flick.widgets.CoverFlowRecommendationWidgetProvider';

  String? _seedId;
  int _generation = 0;

  /// The recommendations are generated from the current track, not the next
  /// tracks in the user's manual queue. If the network fails, fall back to
  /// the upcoming queue as a useful offline selection.
  void refreshFor(Song? seed, Iterable<Song> next) {
    final identity = seed?.id;
    if (seed == null || identity == _seedId) return;
    _seedId = identity;
    final generation = ++_generation;
    unawaited(_populate(seed, next.toList(), generation));
  }

  Future<void> _populate(Song seed, List<Song> next, int generation) async {
    // Do not perform any catalogue requests for users who haven't added
    // the Cover Flow widget. Native onEnabled/onDisabled owns this switch.
    try {
      await HomeWidget.setAppGroupId('group.com.mossapps.flick.widgets');
      final enabled = await HomeWidget.getWidgetData<bool>(
        'flick_widget_recommend_enabled', defaultValue: false,
      );
      if (enabled != true || generation != _generation) {
        if (enabled != true) _seedId = null;
        return;
      }
    } catch (_) {
      _seedId = null;
      return;
    }
    List<Song> rows;
    try {
      rows = await const OnlineRadioRecommendations()
          .recommend(seed, count: 7, existing: [seed])
          .timeout(const Duration(seconds: 16));
    } catch (_) {
      rows = const [];
    }
    if (rows.isEmpty) {
      rows = next.where((song) =>
          song.title.trim().isNotEmpty &&
          song.artist.trim().isNotEmpty &&
          song.id != seed.id).take(7).toList();
    }
    if (generation != _generation) return;
    final seen = <String>{};
    final sanitized = <Map<String, Object?>>[];
    final artworkSources = <String?>[];
    for (final song in rows) {
      if (generation != _generation || sanitized.length >= 7) break;
      final title = song.title.trim();
      final artist = song.artist.trim();
      if (title.isEmpty || artist.isEmpty) continue;
      if (!seen.add(radioRecordingKey(artist, title))) continue;
      final remote = song.remoteId;
      sanitized.add({
        'title': title,
        'artist': artist,
        'album': song.album ?? '',
        'durationMs': song.duration.inMilliseconds,
        'remoteId': remote != null &&
                RegExp(r'^yt:[A-Za-z0-9_-]{11}$').hasMatch(remote)
            ? remote : '',
        'artwork': '',
      });
      artworkSources.add(song.albumArt);
    }
    if (generation != _generation) return;
    // Only publish entries with verified local artwork. In particular, do not
    // fill the home screen with blank covers for catalogue metadata-only songs.
    if (sanitized.isNotEmpty) {
      await _hydrateArtwork(sanitized, artworkSources, generation);
    }
  }

  Future<void> _publish(List<Map<String, Object?>> rows, int generation) async {
    if (generation != _generation) return;
    try {
      await HomeWidget.setAppGroupId('group.com.mossapps.flick.widgets');
      if (generation != _generation) return;
      await HomeWidget.saveWidgetData<String>(key, jsonEncode(rows));
      if (generation != _generation) return;
      await HomeWidget.updateWidget(qualifiedAndroidName: provider);
    } catch (_) {
      // The music player must keep working without the launcher.
    }
  }

  Future<void> _hydrateArtwork(
    List<Map<String, Object?>> rows, List<String?> sources, int generation,
  ) async {
    // Resolve covers in small parallel batches to stay under the launcher
    // image transaction limit and publish as soon as each batch is ready.
    try {
      for (var start = 0; start < rows.length; start += 3) {
        if (generation != _generation) return;
        final end = (start + 3).clamp(0, rows.length);
        await Future.wait([
          for (var i = start; i < end; i++)
            _cacheCover(rows[i], sources[i], generation),
        ]);
        await _publish(
          rows.where((row) => (row['artwork'] as String? ?? '').isNotEmpty)
              .toList(), generation,
        );
      }
    } catch (_) {
      // Browsing and playback are still functional when album art fails.
    }
  }

  Future<void> _cacheCover(
    Map<String, Object?> row, String? source, int generation,
  ) async {
    final song = Song(
      id: 'widget:' + (row['artist'] as String? ?? '') + ':' +
          (row['title'] as String? ?? ''),
      title: row['title'] as String? ?? '',
      artist: row['artist'] as String? ?? '',
      album: row['album'] as String?,
      albumArt: source,
      remoteId: row['remoteId'] as String?,
      duration: Duration.zero,
      fileType: 'ONLINE',
    );
    final path = await resolveTrackArtwork(song);
    if (generation == _generation) row['artwork'] = path;
  }

  /// A widget must make the same effort to show real artwork as the player.
  /// Try the app's cached cover, YouTube's public thumbnail for a known video
  /// ID, then an *exact* artist/title Apple catalogue artwork match. Never
  /// transmit catalogue tokens, audio URLs, or user credentials to widgets.
  static Future<String> resolveTrackArtwork(Song song) async {
    var path = await widgetSafeArtwork(song.albumArt);
    if (path.isNotEmpty) return path;

    final remoteId = song.remoteId ?? '';
    if (remoteId.startsWith('yt:') && remoteId.length == 14 &&
        RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(remoteId.substring(3))) {
      final id = remoteId.substring(3);
      path = await widgetSafeArtwork(
        'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      );
      if (path.isNotEmpty) return path;
    }

    if (song.title.trim().isEmpty || song.artist.trim().isEmpty) return '';
    try {
      final candidates = await AppleMusicMetadataService.instance
          .searchSongs('${song.artist} ${song.title}', limit: 8)
          .timeout(const Duration(seconds: 6));
      final target = radioRecordingKey(song.artist, song.title);
      for (final candidate in candidates) {
        if (radioRecordingKey(candidate.artist, candidate.title) != target ||
            candidate.artworkUrl.isEmpty) continue;
        final higherQuality = candidate.artworkUrl
            .replaceFirst('100x100bb', '600x600bb');
        path = await widgetSafeArtwork(higherQuality);
        if (path.isEmpty && higherQuality != candidate.artworkUrl) {
          path = await widgetSafeArtwork(candidate.artworkUrl);
        }
        if (path.isNotEmpty) return path;
      }
    } catch (_) {
      // The first-party cover cache and track playback remain authoritative.
    }
    return '';
  }

  /// Enforce local, bounded artwork paths. Remote URLs and signed tokens are
  /// never written to HomeWidgetPreferences. Cache Manager handles network
  /// IO asynchronously and reuses its usual response cache.
  static Future<String> widgetSafeArtwork(String? raw) async {
    if (raw == null || raw.trim().isEmpty) return '';
    try {
      if (!raw.startsWith('https://') && !raw.startsWith('http://')) {
        final path = raw.startsWith('file://') ? raw.substring(7) : raw;
        return File(path).existsSync() ? path : '';
      }
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.scheme != 'https') return '';
      final file = await DefaultCacheManager().getSingleFile(raw)
          .timeout(const Duration(seconds: 5));
      return file.existsSync() ? file.path : '';
    } catch (_) { return ''; }
  }

  static Future<List<Map<String, dynamic>>> restore() async {
    try {
      await HomeWidget.setAppGroupId('group.com.mossapps.flick.widgets');
      final raw = await HomeWidget.getWidgetData<String>(key);
      final decoded = jsonDecode(raw ?? '[]');
      if (decoded is! List) return const [];
      return decoded.whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .take(7).toList();
    } catch (_) { return const []; }
  }
}
