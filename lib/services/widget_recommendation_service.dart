import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:home_widget/home_widget.dart';

import '../models/song.dart';
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
    for (final song in rows) {
      if (generation != _generation || sanitized.length == 7) return;
      final title = song.title.trim();
      final artist = song.artist.trim();
      if (title.isEmpty || artist.isEmpty) continue;
      if (!seen.add(radioRecordingKey(artist, title))) continue;
      final art = await widgetSafeArtwork(song.albumArt);
      if (generation != _generation) return;
      final remote = song.remoteId;
      sanitized.add({
        'title': title,
        'artist': artist,
        'album': song.album ?? '',
        'durationMs': song.duration.inMilliseconds,
        'remoteId': remote != null &&
                RegExp(r'^yt:[A-Za-z0-9_-]{11}$').hasMatch(remote)
            ? remote : '',
        'artwork': art,
      });
    }
    if (generation != _generation) return;
    try {
      await HomeWidget.setAppGroupId('group.com.mossapps.flick.widgets');
      await HomeWidget.saveWidgetData<String>(key, jsonEncode(sanitized));
      await HomeWidget.updateWidget(qualifiedAndroidName: provider);
    } catch (_) {
      // The core player must keep working without a launcher widget host.
    }
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
