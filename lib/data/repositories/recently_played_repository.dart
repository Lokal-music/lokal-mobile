import 'dart:async';
import 'dart:convert';

import 'package:isar_community/isar.dart';

import '../../core/utils/audio_metadata_utils.dart';
import '../../core/utils/string_sort_utils.dart';
import '../database.dart';
import '../../models/song.dart';
import 'song_repository.dart';

import 'package:flick/l10n/l10n.dart';

enum ListeningRecapPeriod { daily, weekly, monthly, yearly }

extension ListeningRecapPeriodX on ListeningRecapPeriod {
  String get label {
    return switch (this) {
      ListeningRecapPeriod.daily => l10n.daily,
      ListeningRecapPeriod.weekly => l10n.weekly,
      ListeningRecapPeriod.monthly => l10n.monthly,
      ListeningRecapPeriod.yearly => l10n.yearly,
    };
  }

  String get title {
    return switch (this) {
      ListeningRecapPeriod.daily => l10n.todaySRecap,
      ListeningRecapPeriod.weekly => l10n.thisWeekSRecap,
      ListeningRecapPeriod.monthly => l10n.thisMonthSRecap,
      ListeningRecapPeriod.yearly => l10n.thisYearSRecap,
    };
  }

  String get emptyMessage {
    return switch (this) {
      ListeningRecapPeriod.daily => l10n.playAFewTracksTodayTo,
      ListeningRecapPeriod.weekly => l10n.yourWeeklyRecapAppearsOnceYou,
      ListeningRecapPeriod.monthly => l10n.yourMonthlyRecapNeedsABit,
      ListeningRecapPeriod.yearly => l10n.yourYearlyRecapFillsInAs,
    };
  }

  ListeningRecapRange rangeFor(DateTime anchor) {
    final normalizedAnchor = DateTime(anchor.year, anchor.month, anchor.day);

    return switch (this) {
      ListeningRecapPeriod.daily => ListeningRecapRange(
        start: normalizedAnchor,
        endExclusive: normalizedAnchor.add(const Duration(days: 1)),
      ),
      ListeningRecapPeriod.weekly => () {
        final start = normalizedAnchor.subtract(
          Duration(days: normalizedAnchor.weekday - 1),
        );
        return ListeningRecapRange(
          start: start,
          endExclusive: start.add(const Duration(days: 7)),
        );
      }(),
      ListeningRecapPeriod.monthly => ListeningRecapRange(
        start: DateTime(anchor.year, anchor.month),
        endExclusive: anchor.month == 12
            ? DateTime(anchor.year + 1, 1)
            : DateTime(anchor.year, anchor.month + 1),
      ),
      ListeningRecapPeriod.yearly => ListeningRecapRange(
        start: DateTime(anchor.year),
        endExclusive: DateTime(anchor.year + 1),
      ),
    };
  }
}

class ListeningRecapRange {
  final DateTime start;
  final DateTime endExclusive;

  const ListeningRecapRange({required this.start, required this.endExclusive});
}

class RankedRecapSong {
  final Song song;
  final int plays;
  final Duration listeningTime;
  final DateTime lastPlayedAt;

  const RankedRecapSong({
    required this.song,
    required this.plays,
    required this.listeningTime,
    required this.lastPlayedAt,
  });
}

class RankedRecapArtist {
  final String artist;
  final int plays;
  final int uniqueSongs;
  final Duration listeningTime;
  final DateTime lastPlayedAt;

  const RankedRecapArtist({
    required this.artist,
    required this.plays,
    required this.uniqueSongs,
    required this.listeningTime,
    required this.lastPlayedAt,
  });
}

class RankedRecapAlbum {
  final String album;
  final String artist;
  final int plays;
  final int uniqueSongs;
  final Duration listeningTime;
  final DateTime lastPlayedAt;
  final Song representativeSong;

  const RankedRecapAlbum({
    required this.album,
    required this.artist,
    required this.plays,
    required this.uniqueSongs,
    required this.listeningTime,
    required this.lastPlayedAt,
    required this.representativeSong,
  });
}

class ListeningRecap {
  final ListeningRecapPeriod period;
  final DateTime start;
  final DateTime endExclusive;
  final int totalPlays;
  final Duration totalListeningTime;
  final int uniqueSongs;
  final int uniqueArtists;
  final int activeDays;
  final int? peakHour;
  final RankedRecapSong? topSong;
  final RankedRecapArtist? topArtist;
  final RankedRecapAlbum? topAlbum;
  final List<RankedRecapSong> topSongs;
  final List<RankedRecapArtist> topArtists;
  final List<RankedRecapAlbum> topAlbums;

  const ListeningRecap({
    required this.period,
    required this.start,
    required this.endExclusive,
    required this.totalPlays,
    required this.totalListeningTime,
    required this.uniqueSongs,
    required this.uniqueArtists,
    required this.activeDays,
    required this.peakHour,
    required this.topSong,
    required this.topArtist,
    required this.topAlbum,
    required this.topSongs,
    required this.topArtists,
    required this.topAlbums,
  });

  factory ListeningRecap.empty(
    ListeningRecapPeriod period,
    ListeningRecapRange range,
  ) {
    return ListeningRecap(
      period: period,
      start: range.start,
      endExclusive: range.endExclusive,
      totalPlays: 0,
      totalListeningTime: Duration.zero,
      uniqueSongs: 0,
      uniqueArtists: 0,
      activeDays: 0,
      peakHour: null,
      topSong: null,
      topArtist: null,
      topAlbum: null,
      topSongs: const [],
      topArtists: const [],
      topAlbums: const [],
    );
  }

  bool get hasData => totalPlays > 0;
}

/// Entry representing a recently played song with its timestamp.
class RecentlyPlayedEntry {
  final Song song;
  final DateTime playedAt;
  final int? listenedMs;

  RecentlyPlayedEntry({
    required this.song,
    required this.playedAt,
    this.listenedMs,
  });
}

/// Repository for recently played history operations.
class RecentlyPlayedRepository {
  final Isar _isar;
  final SongRepository _songRepository;

  /// Maximum number of history entries to keep
  static const int maxHistoryEntries = 50000;

  RecentlyPlayedRepository({Isar? isar, SongRepository? songRepository})
    : _isar = isar ?? Database.instance,
      _songRepository = songRepository ?? SongRepository();

  /// Record a song as played.
  Future<void> recordPlay(
    String songId, {
    String? eventId,
    DateTime? playedAt,
    int? listenedMs,
  }) async {
    final id = int.tryParse(songId);
    if (id == null) return;

    await _isar.writeTxn(() async {
      final existing = eventId == null
          ? null
          : await _isar.recentlyPlayedEntitys
                .filter()
                .eventIdEqualTo(eventId)
                .findFirst();
      final entity = existing ?? RecentlyPlayedEntity();
      entity.songId = id;
      entity.playedAt = playedAt ?? existing?.playedAt ?? DateTime.now();
      entity.eventId = eventId;
      entity.listenedMs = listenedMs ?? existing?.listenedMs;

      await _isar.recentlyPlayedEntitys.put(entity);

      // Cleanup old entries if we exceed max
      final count = await _isar.recentlyPlayedEntitys.count();
      if (count > maxHistoryEntries) {
        final toDelete = count - maxHistoryEntries;
        final oldEntries = await _isar.recentlyPlayedEntitys
            .filter()
            .eventIdIsNull()
            .sortByPlayedAt()
            .limit(toDelete)
            .findAll();

        await _isar.recentlyPlayedEntitys.deleteAll(
          oldEntries.map((e) => e.id).toList(),
        );
      }
    });
  }

  /// Get recently played songs grouped by time period.
  /// Returns a map with keys like "Today", "Yesterday", "This Week", etc.
  Future<Map<String, List<RecentlyPlayedEntry>>> getGroupedHistory() async {
    final entries = await _isar.recentlyPlayedEntitys
        .where()
        .sortByPlayedAtDesc()
        .findAll();

    if (entries.isEmpty) return {};

    // Get all song entities
    final allSongEntities = await _songRepository.getAllSongEntities();
    final songMap = {for (var e in allSongEntities) e.id: e};

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final thisWeekStart = today.subtract(Duration(days: today.weekday - 1));
    final lastWeekStart = thisWeekStart.subtract(const Duration(days: 7));
    final thisMonthStart = DateTime(now.year, now.month, 1);

    final grouped = <String, List<RecentlyPlayedEntry>>{};

    for (final entry in entries) {
      final songEntity = songMap[entry.songId];
      if (songEntity == null) continue;

      final song = _entityToSong(songEntity);
      final recentEntry = RecentlyPlayedEntry(
        song: song,
        playedAt: entry.playedAt,
        listenedMs: entry.listenedMs,
      );

      final playedDate = DateTime(
        entry.playedAt.year,
        entry.playedAt.month,
        entry.playedAt.day,
      );

      String groupKey;
      if (playedDate == today) {
        groupKey = 'Today';
      } else if (playedDate == yesterday) {
        groupKey = 'Yesterday';
      } else if (playedDate.isAfter(thisWeekStart) ||
          playedDate == thisWeekStart) {
        groupKey = 'This Week';
      } else if (playedDate.isAfter(lastWeekStart) ||
          playedDate == lastWeekStart) {
        groupKey = 'Last Week';
      } else if (playedDate.isAfter(thisMonthStart) ||
          playedDate == thisMonthStart) {
        groupKey = 'This Month';
      } else {
        groupKey = 'Earlier';
      }

      grouped.putIfAbsent(groupKey, () => []).add(recentEntry);
    }

    return grouped;
  }

  /// Get flat list of recently played entries (most recent first).
  Future<List<RecentlyPlayedEntry>> getRecentHistory({int limit = 50}) async {
    return getRecentHistoryPaginated(offset: 0, limit: limit);
  }

  /// Get a paginated slice of recently played entries (most recent first).
  Future<List<RecentlyPlayedEntry>> getRecentHistoryPaginated({
    int offset = 0,
    int limit = 50,
  }) async {
    final entries = await _isar.recentlyPlayedEntitys
        .where()
        .sortByPlayedAtDesc()
        .offset(offset)
        .limit(limit)
        .findAll();

    if (entries.isEmpty) return const [];

    final allSongEntities = await _songRepository.getAllSongEntities();
    final songMap = {for (var e in allSongEntities) e.id: e};

    final result = <RecentlyPlayedEntry>[];
    for (final entry in entries) {
      final songEntity = songMap[entry.songId];
      if (songEntity == null) continue;

      result.add(
        RecentlyPlayedEntry(
          song: _entityToSong(songEntity),
          playedAt: entry.playedAt,
          listenedMs: entry.listenedMs,
        ),
      );
    }

    return result;
  }

  /// Build Wrapped-style recaps for the current day, week, month, and year.
  Future<Map<ListeningRecapPeriod, ListeningRecap>> getListeningRecaps({
    Iterable<ListeningRecapPeriod>? periods,
    DateTime? now,
  }) async {
    final resolvedPeriods = (periods ?? ListeningRecapPeriod.values).toList();
    if (resolvedPeriods.isEmpty) {
      return const {};
    }

    final anchor = now ?? DateTime.now();
    final ranges = {
      for (final period in resolvedPeriods) period: period.rangeFor(anchor),
    };

    final earliestStart = ranges.values
        .map((range) => range.start)
        .reduce((current, next) => current.isBefore(next) ? current : next);
    final latestEndExclusive = ranges.values
        .map((range) => range.endExclusive)
        .reduce((current, next) => current.isAfter(next) ? current : next);

    final mappedEntries = await _getEntriesBetween(
      start: earliestStart,
      endExclusive: latestEndExclusive,
    );

    return {
      for (final period in resolvedPeriods)
        period: _buildListeningRecap(
          period: period,
          range: ranges[period]!,
          entries: mappedEntries.where((entry) {
            return !entry.playedAt.isBefore(ranges[period]!.start) &&
                entry.playedAt.isBefore(ranges[period]!.endExclusive);
          }).toList(),
        ),
    };
  }

  /// Build a Wrapped-style recap for a single period.
  Future<ListeningRecap> getListeningRecap(
    ListeningRecapPeriod period, {
    DateTime? now,
  }) async {
    final recaps = await getListeningRecaps(periods: [period], now: now);
    return recaps[period]!;
  }

  /// Clear all play history.
  Future<void> clearHistory() async {
    await _isar.writeTxn(() async {
      await _isar.recentlyPlayedEntitys.clear();
    });
  }

  /// Get history count.
  Future<int> getHistoryCount() async {
    return await _isar.recentlyPlayedEntitys.count();
  }

  /// How many times each song id has been played, over the whole history.
  Future<Map<String, int>> getPlayCounts() async {
    final ids = await _isar.recentlyPlayedEntitys
        .where()
        .songIdProperty()
        .findAll();
    final counts = <String, int>{};
    for (final id in ids) {
      final key = id.toString();
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  /// Count distinct, non-empty artist names across the entire play history.
  Future<int> getDistinctArtistCount() async {
    final entries = await _isar.recentlyPlayedEntitys.where().findAll();
    final allSongEntities = await _songRepository.getAllSongEntities();
    final songMap = {for (final e in allSongEntities) e.id: e};

    final artists = <String>{};
    for (final entry in entries) {
      final entity = songMap[entry.songId];
      if (entity == null) continue;
      final name = entity.artist.trim();
      if (name.isNotEmpty) artists.add(name.toLowerCase());
    }
    // A streamed recording can count as listening without being a library file.
    for (final event in await _isar.playEventEntitys.where().findAll()) {
      try {
        final track = jsonDecode(event.trackJson);
        final artist = (track['artist'] ?? '').toString().trim().toLowerCase();
        if (artist.isNotEmpty && event.msPlayed >= 30000) artists.add(artist);
      } catch (_) {
        /* Legacy events may lack track metadata. */
      }
    }
    return artists.length;
  }

  /// Watch for changes in the history collection.
  Stream<void> watchHistory() {
    late final StreamController<void> controller;
    StreamSubscription<void>? recentSubscription;
    StreamSubscription<void>? journalSubscription;
    controller = StreamController<void>(
      onListen: () {
        recentSubscription = _isar.recentlyPlayedEntitys.watchLazy().listen(
          (_) => controller.add(null),
        );
        journalSubscription = _isar.playEventEntitys.watchLazy().listen(
          (_) => controller.add(null),
        );
      },
      onCancel: () async {
        await recentSubscription?.cancel();
        await journalSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// Get the most-played songs for a specific artist.
  /// Returns songs sorted by play count, most played first.
  Future<List<Song>> getMostPlayedSongsByArtist(
    String artistName, {
    int limit = 5,
  }) async {
    final entries = await _isar.recentlyPlayedEntitys
        .where()
        .sortByPlayedAtDesc()
        .findAll();

    if (entries.isEmpty) return const [];

    final allSongEntities = await _songRepository.getAllSongEntities();
    final songMap = {for (final entity in allSongEntities) entity.id: entity};

    final playCounts = <String, int>{};
    final songEntities = <String, SongEntity>{};

    for (final entry in entries) {
      final songEntity = songMap[entry.songId];
      if (songEntity == null) continue;
      if (songEntity.artist != artistName) continue;

      final id = songEntity.id.toString();
      songEntities[id] = songEntity;
      playCounts[id] = (playCounts[id] ?? 0) + 1;
    }

    final sortedIds = playCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final result = <Song>[];
    for (final entry in sortedIds.take(limit)) {
      final entity = songEntities[entry.key];
      if (entity != null) {
        result.add(_entityToSong(entity));
      }
    }

    return result;
  }

  /// Get the most-played song from a specific set of song IDs.
  /// Ties are broken by the most recent play. Returns null if no
  /// songs in the given IDs have been played yet.
  Future<Song?> getMostPlayedSongAmong(Iterable<String> songIds) async {
    final ids = songIds.toSet();
    if (ids.isEmpty) return null;

    final entries = await _isar.recentlyPlayedEntitys
        .where()
        .sortByPlayedAtDesc()
        .findAll();

    if (entries.isEmpty) return null;

    final allSongEntities = await _songRepository.getAllSongEntities();
    final songMap = {for (final entity in allSongEntities) entity.id: entity};

    final playCounts = <String, int>{};
    final songEntities = <String, SongEntity>{};
    final lastPlayedAt = <String, DateTime>{};

    for (final entry in entries) {
      final songEntity = songMap[entry.songId];
      if (songEntity == null) continue;
      final id = songEntity.id.toString();
      if (!ids.contains(id)) continue;

      songEntities[id] = songEntity;
      playCounts[id] = (playCounts[id] ?? 0) + 1;
      final existing = lastPlayedAt[id];
      if (existing == null || entry.playedAt.isAfter(existing)) {
        lastPlayedAt[id] = entry.playedAt;
      }
    }

    if (playCounts.isEmpty) return null;

    final sortedIds = playCounts.entries.toList()
      ..sort((a, b) {
        final playCompare = b.value.compareTo(a.value);
        if (playCompare != 0) return playCompare;
        return lastPlayedAt[b.key]!.compareTo(lastPlayedAt[a.key]!);
      });

    final topEntity = songEntities[sortedIds.first.key];
    if (topEntity == null) return null;
    return _entityToSong(topEntity);
  }

  Future<List<RecentlyPlayedEntry>> _getEntriesBetween({
    required DateTime start,
    required DateTime endExclusive,
  }) async {
    final entries = await _isar.recentlyPlayedEntitys
        .where()
        .playedAtBetween(start, endExclusive, includeUpper: false)
        .sortByPlayedAtDesc()
        .findAll();

    final result = <RecentlyPlayedEntry>[];
    final displayedEventIds = <String>{};
    if (entries.isNotEmpty) {
      final allSongEntities = await _songRepository.getAllSongEntities();
      final songMap = {for (final entity in allSongEntities) entity.id: entity};
      for (final entry in entries) {
        final songEntity = songMap[entry.songId];
        if (songEntity == null) continue;
        if (entry.eventId != null) displayedEventIds.add(entry.eventId!);
        result.add(
          RecentlyPlayedEntry(
            song: _entityToSong(songEntity),
            playedAt: entry.playedAt,
            listenedMs: entry.listenedMs,
          ),
        );
      }
    }

    // A desktop play should contribute listening minutes even if its song
    // has not been imported into the phone library. The immutable journal is
    // deduplicated by event ID; don't count projected local history twice.
    final events = await _isar.playEventEntitys
        .where()
        .playedAtBetween(
          start.millisecondsSinceEpoch,
          endExclusive.millisecondsSinceEpoch,
          includeUpper: false,
        )
        .findAll();
    for (final event in events) {
      if (displayedEventIds.contains(event.eventId)) continue;
      Map<String, dynamic> track;
      try {
        track = Map<String, dynamic>.from(jsonDecode(event.trackJson) as Map);
      } catch (_) {
        track = {};
      }
      final length = track['duration'];
      final durationMs = length is num && length.isFinite && length > 0
          ? (length * 1000).round()
          : event.msPlayed;
      result.add(
        RecentlyPlayedEntry(
          song: Song(
            id: 'history:${event.trackKey}',
            title: (track['title'] as String?) ?? 'Unknown track',
            artist: (track['artist'] as String?) ?? 'Unknown artist',
            album: track['album'] as String?,
            duration: Duration(milliseconds: durationMs),
            fileType: 'history',
            isExternal: true,
          ),
          playedAt: DateTime.fromMillisecondsSinceEpoch(event.playedAt),
          listenedMs: event.msPlayed,
        ),
      );
    }
    return result;
  }

  ListeningRecap _buildListeningRecap({
    required ListeningRecapPeriod period,
    required ListeningRecapRange range,
    required List<RecentlyPlayedEntry> entries,
  }) {
    if (entries.isEmpty) {
      return ListeningRecap.empty(period, range);
    }

    final songStats = <String, _SongRecapAccumulator>{};
    final artistStats = <String, _ArtistRecapAccumulator>{};
    final albumStats = <String, _AlbumRecapAccumulator>{};
    final playedDays = <DateTime>{};
    final hourStats = <int, int>{};

    var totalListeningTime = Duration.zero;

    for (final entry in entries) {
      final song = entry.song;
      totalListeningTime += entry.listenedMs == null
          ? song.duration
          : Duration(milliseconds: entry.listenedMs!);

      final songAccumulator = songStats.putIfAbsent(
        song.id,
        () => _SongRecapAccumulator(song),
      );
      songAccumulator.addPlay(entry.playedAt);

      final artistKey = song.artist.trim().isEmpty
          ? l10n.unknownArtist
          : song.artist.trim();
      final artistAccumulator = artistStats.putIfAbsent(
        artistKey,
        () => _ArtistRecapAccumulator(artistKey),
      );
      artistAccumulator.addPlay(song, entry.playedAt);

      final albumName = (song.album?.trim().isNotEmpty ?? false)
          ? song.album!.trim()
          : l10n.unknownAlbum;
      final albumArtist = (song.albumArtist?.trim().isNotEmpty ?? false)
          ? song.albumArtist!.trim()
          : artistKey;
      final albumKey = '$albumArtist::$albumName';
      final albumAccumulator = albumStats.putIfAbsent(
        albumKey,
        () => _AlbumRecapAccumulator(albumName, albumArtist, song),
      );
      albumAccumulator.addPlay(song, entry.playedAt);

      playedDays.add(
        DateTime(entry.playedAt.year, entry.playedAt.month, entry.playedAt.day),
      );
      hourStats.update(
        entry.playedAt.hour,
        (count) => count + 1,
        ifAbsent: () {
          return 1;
        },
      );
    }

    final rankedSongs = songStats.values.map((item) => item.toRanked()).toList()
      ..sort(_compareRankedSongs);
    final rankedArtists =
        artistStats.values.map((item) => item.toRanked()).toList()
          ..sort(_compareRankedArtists);
    final rankedAlbums =
        albumStats.values.map((item) => item.toRanked()).toList()
          ..sort(_compareRankedAlbums);
    final peakHour = _findPeakHour(hourStats);

    return ListeningRecap(
      period: period,
      start: range.start,
      endExclusive: range.endExclusive,
      totalPlays: entries.length,
      totalListeningTime: totalListeningTime,
      uniqueSongs: songStats.length,
      uniqueArtists: artistStats.length,
      activeDays: playedDays.length,
      peakHour: peakHour,
      topSong: rankedSongs.isEmpty ? null : rankedSongs.first,
      topArtist: rankedArtists.isEmpty ? null : rankedArtists.first,
      topAlbum: rankedAlbums.isEmpty ? null : rankedAlbums.first,
      topSongs: rankedSongs.take(5).toList(),
      topArtists: rankedArtists.take(5).toList(),
      topAlbums: rankedAlbums.take(3).toList(),
    );
  }

  int? _findPeakHour(Map<int, int> hourStats) {
    if (hourStats.isEmpty) return null;

    final rankedHours = hourStats.entries.toList()
      ..sort((left, right) {
        final playCompare = right.value.compareTo(left.value);
        if (playCompare != 0) return playCompare;
        return left.key.compareTo(right.key);
      });
    return rankedHours.first.key;
  }

  int _compareRankedSongs(RankedRecapSong left, RankedRecapSong right) {
    final playCompare = right.plays.compareTo(left.plays);
    if (playCompare != 0) return playCompare;

    final timeCompare = right.listeningTime.inMilliseconds.compareTo(
      left.listeningTime.inMilliseconds,
    );
    if (timeCompare != 0) return timeCompare;

    final recentCompare = right.lastPlayedAt.compareTo(left.lastPlayedAt);
    if (recentCompare != 0) return recentCompare;

    return compareCaseInsensitive(left.song.title, right.song.title);
  }

  int _compareRankedArtists(RankedRecapArtist left, RankedRecapArtist right) {
    final playCompare = right.plays.compareTo(left.plays);
    if (playCompare != 0) return playCompare;

    final timeCompare = right.listeningTime.inMilliseconds.compareTo(
      left.listeningTime.inMilliseconds,
    );
    if (timeCompare != 0) return timeCompare;

    final recentCompare = right.lastPlayedAt.compareTo(left.lastPlayedAt);
    if (recentCompare != 0) return recentCompare;

    return compareCaseInsensitive(left.artist, right.artist);
  }

  int _compareRankedAlbums(RankedRecapAlbum left, RankedRecapAlbum right) {
    final playCompare = right.plays.compareTo(left.plays);
    if (playCompare != 0) return playCompare;

    final timeCompare = right.listeningTime.inMilliseconds.compareTo(
      left.listeningTime.inMilliseconds,
    );
    if (timeCompare != 0) return timeCompare;

    final recentCompare = right.lastPlayedAt.compareTo(left.lastPlayedAt);
    if (recentCompare != 0) return recentCompare;

    final albumCompare = compareCaseInsensitive(left.album, right.album);
    if (albumCompare != 0) return albumCompare;

    return compareCaseInsensitive(left.artist, right.artist);
  }

  /// Convert entity to Song model.
  Song _entityToSong(SongEntity entity) {
    return Song(
      id: entity.id.toString(),
      title: entity.title,
      artist: entity.artist,
      albumArt: entity.albumArtPath,
      duration: Duration(milliseconds: entity.durationMs ?? 0),
      fileType: entity.fileType ?? 'unknown',
      resolution: _buildResolutionString(entity),
      sampleRate: entity.sampleRate,
      bitDepth: entity.bitDepth,
      album: entity.album,
      filePath: entity.filePath,
      dateAdded: entity.dateAdded,
      sourceType: entity.sourceType,
      remoteId: entity.remoteId,
      remoteServerId: entity.remoteServerId,
    );
  }

  /// Build a resolution string from entity properties. Null when the source
  /// sync had no audio metrics (SMB/WebDAV) — callers hide the chip instead
  /// of showing a placeholder.
  String? _buildResolutionString(SongEntity entity) {
    final parts = <String>[];
    if (entity.bitDepth != null) {
      parts.add('${entity.bitDepth}-bit');
    }
    if (entity.sampleRate != null) {
      parts.add('${_formatSampleRateKhz(entity.sampleRate!)}kHz');
    }
    final bitrateLabel = AudioMetadataUtils.formatBitrateLabel(
      entity.bitrate,
      sampleRate: entity.sampleRate,
      bitDepth: entity.bitDepth,
    );
    if (bitrateLabel != null) {
      parts.add(bitrateLabel);
    }
    return parts.isEmpty ? null : parts.join(' / ');
  }

  String _formatSampleRateKhz(int sampleRateHz) {
    final khz = sampleRateHz / 1000;
    if (sampleRateHz % 1000 == 0) {
      return khz.toStringAsFixed(0);
    }
    return khz.toStringAsFixed(1);
  }
}

class _SongRecapAccumulator {
  final Song song;
  int plays = 0;
  Duration listeningTime = Duration.zero;
  DateTime? lastPlayedAt;

  _SongRecapAccumulator(this.song);

  void addPlay(DateTime playedAt) {
    plays += 1;
    listeningTime += song.duration;
    if (lastPlayedAt == null || playedAt.isAfter(lastPlayedAt!)) {
      lastPlayedAt = playedAt;
    }
  }

  RankedRecapSong toRanked() {
    return RankedRecapSong(
      song: song,
      plays: plays,
      listeningTime: listeningTime,
      lastPlayedAt: lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class _ArtistRecapAccumulator {
  final String artist;
  final Set<String> uniqueSongIds = <String>{};
  int plays = 0;
  Duration listeningTime = Duration.zero;
  DateTime? lastPlayedAt;

  _ArtistRecapAccumulator(this.artist);

  void addPlay(Song song, DateTime playedAt) {
    plays += 1;
    listeningTime += song.duration;
    uniqueSongIds.add(song.id);
    if (lastPlayedAt == null || playedAt.isAfter(lastPlayedAt!)) {
      lastPlayedAt = playedAt;
    }
  }

  RankedRecapArtist toRanked() {
    return RankedRecapArtist(
      artist: artist,
      plays: plays,
      uniqueSongs: uniqueSongIds.length,
      listeningTime: listeningTime,
      lastPlayedAt: lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class _AlbumRecapAccumulator {
  final String album;
  final String artist;
  final Set<String> uniqueSongIds = <String>{};
  Song representativeSong;
  int plays = 0;
  Duration listeningTime = Duration.zero;
  DateTime? lastPlayedAt;

  _AlbumRecapAccumulator(this.album, this.artist, this.representativeSong);

  void addPlay(Song song, DateTime playedAt) {
    plays += 1;
    listeningTime += song.duration;
    uniqueSongIds.add(song.id);
    if ((representativeSong.albumArt == null ||
            representativeSong.albumArt!.isEmpty) &&
        song.albumArt != null &&
        song.albumArt!.isNotEmpty) {
      representativeSong = song;
    }
    if (lastPlayedAt == null || playedAt.isAfter(lastPlayedAt!)) {
      lastPlayedAt = playedAt;
    }
  }

  RankedRecapAlbum toRanked() {
    return RankedRecapAlbum(
      album: album,
      artist: artist,
      plays: plays,
      uniqueSongs: uniqueSongIds.length,
      listeningTime: listeningTime,
      lastPlayedAt: lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      representativeSong: representativeSong,
    );
  }
}
