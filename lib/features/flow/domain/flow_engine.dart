import 'dart:math' as math;

import 'flow_models.dart';

/// Deterministic weighted sampling without replacement, followed by a modest
/// artist-spacing pass. Same inputs/seed produce the same order across runs.
class FlowEngine {
  const FlowEngine();

  List<FlowTrack> recommend({
    required List<FlowTrack> library,
    required Set<String> favoriteIds,
    required FlowData data,
    Iterable<String> historyIds = const [],
    Iterable<String> previousArtists = const [],
    Set<String> excludeIds = const {},
    int? seed,
    int limit = FlowRules.initialTracks,
  }) {
    if (limit <= 0 ||
        !FlowRules.isUnlocked(
          library.map((s) => s.id).toSet().intersection(favoriteIds).length,
        )) {
      return const [];
    }
    final history = {...data.recentIds, ...historyIds}.toList();
    final rank = {for (var i = 0; i < history.length; i++) history[i]: i};
    final favoriteRecordings = <String>{};
    final historyRecordings = <String>{};
    final blockedRecordings = <String>{};
    final likedArtists = <String>{};
    final likedGenres = <String>{};
    for (final song in library) {
      if (favoriteIds.contains(song.id)) {
        favoriteRecordings.add(song.recordingKey);
        // Excluded genres do not seed affinity either.
        if (!song.genres.any(data.config.excludedGenres.contains) &&
            !data.bannedIds.contains(song.id) &&
            (data.skipCounts[song.id] ?? 0) < 3) {
          likedArtists.add(song.artistKey);
          likedGenres.addAll(song.genres);
        }
      }
      if (rank.containsKey(song.id)) historyRecordings.add(song.recordingKey);
      if (data.bannedIds.contains(song.id) ||
          excludeIds.contains(song.id) ||
          song.genres.any(data.config.excludedGenres.contains) ||
          (data.skipCounts[song.id] ?? 0) >= 3) {
        blockedRecordings.add(song.recordingKey);
      }
    }
    final candidates = <({FlowTrack track, double priority})>[];
    final ids = <String>{};
    final recordings = <String>{};
    // Sorting before deduplication makes input/library ordering irrelevant.
    final sorted = [...library]..sort((a, b) => a.id.compareTo(b.id));
    for (final song in sorted) {
      if (song.id.trim().isEmpty ||
          !ids.add(song.id) ||
          blockedRecordings.contains(song.recordingKey) ||
          song.genres.any(data.config.excludedGenres.contains)) {
        continue;
      }
      final liked = favoriteRecordings.contains(song.recordingKey);
      final familiar = liked || historyRecordings.contains(song.recordingKey);
      if (data.config.discovery <= .15 && !familiar) continue;
      if (data.config.discovery >= .85 && familiar) continue;
      if (!recordings.add(song.recordingKey)) continue;
      final weight = score(
        song,
        config: data.config,
        favorite: liked,
        familiar: familiar,
        historyRank: rank[song.id],
        skips: data.skipCounts[song.id] ?? 0,
        artistAffinity: likedArtists.contains(song.artistKey),
        genreAffinity: song.genres.any(likedGenres.contains),
      );
      final random = _unit('${seed ?? data.session.seed}:${song.id}');
      candidates.add((track: song, priority: -math.log(random) / weight));
    }
    candidates.sort((a, b) {
      final order = a.priority.compareTo(b.priority);
      return order != 0 ? order : a.track.id.compareTo(b.track.id);
    });
    final pending = candidates.map((c) => c.track).toList();
    final result = <FlowTrack>[];
    // Preserve the last artists across refills, not merely within this batch.
    // The previous condition only spaced artists after an A/A repeat already
    // happened; a three-track rolling window prevents A/B/A when alternatives
    // exist, while retaining a fallback for libraries with few artists.
    final recentArtists = previousArtists
        .map(normalizeFlowText)
        .where((name) => name.isNotEmpty)
        .toList();
    if (recentArtists.length > 3) {
      recentArtists.removeRange(0, recentArtists.length - 3);
    }
    while (pending.isNotEmpty && result.length < limit) {
      var index = pending.indexWhere(
        (song) => song.artistKey.isEmpty ||
            !recentArtists.contains(song.artistKey),
      );
      if (index < 0) index = 0;
      // Among similarly ranked eligible tracks, prefer a shared genre for
      // a less jarring handoff. This is a soft preference, not a hard filter.
      if (result.isNotEmpty && result.last.genres.isNotEmpty) {
        final searchLimit = math.min(pending.length, math.max(6, index + 1));
        for (var i = 0; i < searchLimit; i++) {
          final next = pending[i];
          if (i > index + 2) break;
          if ((next.artistKey.isEmpty ||
                  !recentArtists.contains(next.artistKey)) &&
              next.genres.any(result.last.genres.contains)) {
            index = i;
            break;
          }
        }
      }
      final selected = pending.removeAt(index);
      result.add(selected);
      if (selected.artistKey.isNotEmpty) {
        recentArtists.add(selected.artistKey);
        if (recentArtists.length > 3) recentArtists.removeAt(0);
      }
    }
    return result;
  }

  double score(
    FlowTrack track, {
    required FlowConfig config,
    bool favorite = false,
    bool familiar = false,
    int? historyRank,
    int skips = 0,
    bool artistAffinity = false,
    bool genreAffinity = false,
  }) {
    var weight = 1.0;
    if (favorite) {
      weight += 4 * (1 - config.discovery) * (1 - .65 * config.memory);
    }
    if (historyRank != null) {
      weight += (1 - math.min(historyRank, 40) / 42) * (.4 + 5 * config.memory);
    }
    if (!familiar) weight += 4 * config.discovery;
    if (artistAffinity) weight += 1.2;
    if (genreAffinity) weight += .7;
    if (track.genres.any((g) => config.mood.genreHints.any(g.contains))) {
      weight += 2;
    }
    if (skips >= 2) weight *= .25;
    if (skips == 1) weight *= .7;
    return math.max(.05, weight);
  }

  /// Restore only resolvable, eligible IDs; never fabricate Song metadata.
  /// Discovery is applied when building a session, not retroactively when its
  /// own fresh tracks enter history during playback. Hard bans still apply.
  List<FlowTrack> restore({
    required List<FlowTrack> library,
    required FlowData data,
    required DateTime now,
  }) {
    if (!data.session.isFresh(now)) return const [];
    final byId = {for (final song in library) song.id: song};
    final blocked = {
      for (final song in library)
        if (data.bannedIds.contains(song.id) ||
            song.genres.any(data.config.excludedGenres.contains) ||
            (data.skipCounts[song.id] ?? 0) >= 3)
          song.recordingKey,
    };
    final seen = <String>{};
    return [
      for (final id in data.session.trackIds)
        if (byId[id] case final song?)
          if (!blocked.contains(song.recordingKey) &&
              !song.genres.any(data.config.excludedGenres.contains) &&
              seen.add(song.recordingKey))
            song,
    ];
  }

  // FNV followed by avalanche, with bounded 32-bit arithmetic (no hashCode).
  static double _unit(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    hash = ((hash ^ (hash >> 16)) * 0x45d9f3b) & 0xffffffff;
    hash = ((hash ^ (hash >> 16)) * 0x45d9f3b) & 0xffffffff;
    hash ^= hash >> 16;
    return (hash + 1) / 4294967297;
  }
}
