/// Matching and genre selection for desktop-to-phone metadata reconciliation.
/// Pure logic so ambiguous titles cannot tag the wrong local recording.
library;

import 'dart:convert';

bool isUnclassifiedLinkGenre(String? value) {
  final text = (value ?? '').trim().toLowerCase();
  return text.isEmpty ||
      const {
        'music', 'unknown', 'unknown genre', 'no genre', 'nogenre',
        'not set', 'notset', 'unspecified', 'undefined', 'genre',
      }.contains(text);
}

/// Desktop stores the main genre and a (usually comma-separated) genre list.
/// Preserve every meaningful genre for Mobile's grouped Genres browser.
String? desktopLinkGenres(Map<String, dynamic> track) {
  final tags = <String>[];
  final multi = track['genres'];
  if (multi is List) {
    tags.addAll(multi.whereType<String>());
  } else if (multi is String && multi.trim().isNotEmpty) {
    Object? decoded;
    try {
      decoded = jsonDecode(multi);
    } on FormatException {
      // Desktop's genres column may be a plain comma-separated tag list.
    }
    if (decoded is List) {
      tags.addAll(decoded.whereType<String>());
    } else {
      tags.addAll(multi.split(RegExp(r'[,;|]')));
    }
  }
  final primary = track['genre']?.toString().trim() ?? '';
  if (!isUnclassifiedLinkGenre(primary)) tags.insert(0, primary);
  final seen = <String>{};
  final meaningful = <String>[];
  for (final tag in tags) {
    final normalized = tag.trim();
    if (isUnclassifiedLinkGenre(normalized) ||
        !seen.add(normalized.toLowerCase())) continue;
    meaningful.add(normalized);
  }
  return meaningful.isEmpty ? null : meaningful.join('; ');
}

String _normalizeLinkName(String? value) =>
    (value ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

class DesktopGenreIdentity {
  const DesktopGenreIdentity({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    this.remoteServerId,
    this.remoteId,
  });

  final int id;
  final String title;
  final String artist;
  final String? album;
  final int durationMs;
  final int? remoteServerId;
  final String? remoteId;
}

/// Prioritize the stable desktop ID for copied and streamed desktop originals.
/// When matching independent phone files, refuse ambiguous titles/editions.
class DesktopGenreMatcher {
  DesktopGenreMatcher(Iterable<DesktopGenreIdentity> records) {
    for (final record in records) {
      final remote = record.remoteId;
      if (remote != null && remote.isNotEmpty && record.remoteServerId != null) {
        (_remote['${record.remoteServerId}:$remote'] ??= []).add(record);
      }
      final key = _key(record.artist, record.title);
      (_titles[key] ??= []).add(record);
    }
  }

  final _remote = <String, List<DesktopGenreIdentity>>{};
  final _titles = <String, List<DesktopGenreIdentity>>{};

  static String _key(String? artist, String? title) =>
      '${_normalizeLinkName(artist)}|\u0000${_normalizeLinkName(title)}';

  List<int> matchingIds(int serverId, Map<String, dynamic> desktop) {
    final remoteId = desktop['id']?.toString();
    if (remoteId != null && remoteId.isNotEmpty) {
      final linked = _remote['$serverId:$remoteId'];
      if (linked != null && linked.isNotEmpty) {
        return [for (final row in linked) row.id];
      }
    }

    final title = desktop['title']?.toString() ?? '';
    final artist = desktop['artist']?.toString() ?? '';
    if (title.trim().isEmpty || artist.trim().isEmpty) return const [];
    final duration = (desktop['duration'] as num?)?.toDouble();
    if (duration == null || !duration.isFinite || duration <= 0) return const [];
    final album = _normalizeLinkName(desktop['album']?.toString());
    final matching = (_titles[_key(artist, title)] ?? const <DesktopGenreIdentity>[])
        .where((row) =>
            (row.durationMs / 1000 - duration).abs() <= 2 &&
            (album.isEmpty || _normalizeLinkName(row.album).isEmpty ||
                _normalizeLinkName(row.album) == album))
        .toList();
    // A recording with two equally plausible matches should never propagate
    // metadata to an unrelated version or remaster.
    return matching.length == 1 ? [matching.single.id] : const [];
  }
}
