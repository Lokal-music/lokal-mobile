import 'package:flick/models/playlist.dart';
import 'package:flick/models/song.dart';

enum PlaylistLinkSource {
  spotify,
  youtube,
  tidal,
  apple,
  qobuz,
  deezer;

  String get label => switch (this) {
    spotify => 'Spotify',
    youtube => 'YouTube',
    tidal => 'Tidal',
    apple => 'Apple Music',
    qobuz => 'Qobuz',
    deezer => 'Deezer',
  };
}

enum PlaylistLinkSyncStatus { complete, partial }

class ParsedPlaylistLink {
  final PlaylistLinkSource source;
  final String remoteId;
  final String canonicalUrl;

  const ParsedPlaylistLink({
    required this.source,
    required this.remoteId,
    required this.canonicalUrl,
  });

  String get linkId => '${source.name}:$remoteId';
}

class RemotePlaylistEntry {
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final String? remoteId;

  const RemotePlaylistEntry({
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.remoteId,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': duration?.inMilliseconds,
    'remoteId': remoteId,
  };

  factory RemotePlaylistEntry.fromJson(Map<String, dynamic> json) {
    final durationMs = (json['durationMs'] as num?)?.toInt();
    return RemotePlaylistEntry(
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String?,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      remoteId: json['remoteId'] as String?,
    );
  }
}

/// A response may be useful while still incomplete. Consumers must inspect
/// [complete] before replacing or removing local playlist entries.
class RemotePlaylistSnapshot {
  final String title;
  final String? description;
  final String? thumbnailUrl;
  final List<RemotePlaylistEntry> entries;
  final int? totalEntries;
  final bool complete;
  final String? truncationReason;

  const RemotePlaylistSnapshot({
    required this.title,
    required this.entries,
    required this.complete,
    this.description,
    this.thumbnailUrl,
    this.totalEntries,
    this.truncationReason,
  });
}

class PlaylistLinkMatch {
  final RemotePlaylistEntry remoteEntry;
  final Song song;

  const PlaylistLinkMatch({required this.remoteEntry, required this.song});
}

class PlaylistLinkMatchReport {
  final int remoteEntryCount;
  final List<PlaylistLinkMatch> matches;
  final List<RemotePlaylistEntry> unmatchedEntries;
  final int duplicateMatches;

  const PlaylistLinkMatchReport({
    required this.remoteEntryCount,
    required this.matches,
    required this.unmatchedEntries,
    required this.duplicateMatches,
  });

  int get matchedEntryCount => matches.length + duplicateMatches;
  int get matchedSongCount => matches.length;
}

class PlaylistLinkRecord {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String linkId;
  final PlaylistLinkSource source;
  final String remoteId;
  final String canonicalUrl;
  final String playlistId;
  final String remoteTitle;
  final String? description;
  final String? thumbnailUrl;
  final List<String> managedSongIds;
  final List<RemotePlaylistEntry> unmatchedEntries;
  final int remoteEntryCount;
  final int fetchedEntryCount;
  final int duplicateMatches;
  final PlaylistLinkSyncStatus syncStatus;
  final DateTime? lastSyncedAt;
  final String? lastSyncMessage;

  const PlaylistLinkRecord({
    this.schemaVersion = currentSchemaVersion,
    required this.linkId,
    required this.source,
    required this.remoteId,
    required this.canonicalUrl,
    required this.playlistId,
    required this.remoteTitle,
    this.description,
    this.thumbnailUrl,
    this.managedSongIds = const [],
    this.unmatchedEntries = const [],
    required this.remoteEntryCount,
    required this.fetchedEntryCount,
    required this.duplicateMatches,
    required this.syncStatus,
    this.lastSyncedAt,
    this.lastSyncMessage,
  });

  bool get isPartial => syncStatus == PlaylistLinkSyncStatus.partial;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'linkId': linkId,
    'source': source.name,
    'remoteId': remoteId,
    'canonicalUrl': canonicalUrl,
    'playlistId': playlistId,
    'remoteTitle': remoteTitle,
    'description': description,
    'thumbnailUrl': thumbnailUrl,
    'managedSongIds': managedSongIds,
    'unmatchedEntries': unmatchedEntries.map((e) => e.toJson()).toList(),
    'remoteEntryCount': remoteEntryCount,
    'fetchedEntryCount': fetchedEntryCount,
    'duplicateMatches': duplicateMatches,
    'syncStatus': syncStatus.name,
    'lastSyncedAt': lastSyncedAt?.toIso8601String(),
    'lastSyncMessage': lastSyncMessage,
  };

  factory PlaylistLinkRecord.fromJson(Map<String, dynamic> json) {
    final sourceName = json['source'] as String?;
    final statusName = json['syncStatus'] as String?;
    final rawUnmatched = json['unmatchedEntries'];
    return PlaylistLinkRecord(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      linkId: json['linkId'] as String,
      source: PlaylistLinkSource.values.firstWhere(
        (value) => value.name == sourceName,
        orElse: () =>
            throw const FormatException('Unknown playlist link source'),
      ),
      remoteId: json['remoteId'] as String,
      canonicalUrl: json['canonicalUrl'] as String,
      playlistId: json['playlistId'] as String,
      remoteTitle: json['remoteTitle'] as String? ?? 'Linked playlist',
      description: json['description'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      managedSongIds:
          (json['managedSongIds'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          const [],
      unmatchedEntries: rawUnmatched is List
          ? rawUnmatched
                .whereType<Map>()
                .map(
                  (item) => RemotePlaylistEntry.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : const [],
      remoteEntryCount: (json['remoteEntryCount'] as num?)?.toInt() ?? 0,
      fetchedEntryCount: (json['fetchedEntryCount'] as num?)?.toInt() ?? 0,
      duplicateMatches: (json['duplicateMatches'] as num?)?.toInt() ?? 0,
      syncStatus: PlaylistLinkSyncStatus.values.firstWhere(
        (value) => value.name == statusName,
        orElse: () => PlaylistLinkSyncStatus.partial,
      ),
      lastSyncedAt: _parseDate(json['lastSyncedAt']),
      lastSyncMessage: json['lastSyncMessage'] as String?,
    );
  }

  PlaylistLinkRecord copyWith({
    String? remoteTitle,
    String? description,
    String? thumbnailUrl,
    List<String>? managedSongIds,
    List<RemotePlaylistEntry>? unmatchedEntries,
    int? remoteEntryCount,
    int? fetchedEntryCount,
    int? duplicateMatches,
    PlaylistLinkSyncStatus? syncStatus,
    DateTime? lastSyncedAt,
    String? lastSyncMessage,
  }) {
    return PlaylistLinkRecord(
      schemaVersion: schemaVersion,
      linkId: linkId,
      source: source,
      remoteId: remoteId,
      canonicalUrl: canonicalUrl,
      playlistId: playlistId,
      remoteTitle: remoteTitle ?? this.remoteTitle,
      description: description ?? this.description,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      managedSongIds: managedSongIds ?? this.managedSongIds,
      unmatchedEntries: unmatchedEntries ?? this.unmatchedEntries,
      remoteEntryCount: remoteEntryCount ?? this.remoteEntryCount,
      fetchedEntryCount: fetchedEntryCount ?? this.fetchedEntryCount,
      duplicateMatches: duplicateMatches ?? this.duplicateMatches,
      syncStatus: syncStatus ?? this.syncStatus,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      lastSyncMessage: lastSyncMessage ?? this.lastSyncMessage,
    );
  }

  static DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

class PlaylistLinkPreview {
  final ParsedPlaylistLink link;
  final RemotePlaylistSnapshot remote;
  final PlaylistLinkMatchReport matches;
  final PlaylistLinkRecord? existingLink;
  final Playlist? existingPlaylist;

  const PlaylistLinkPreview({
    required this.link,
    required this.remote,
    required this.matches,
    this.existingLink,
    this.existingPlaylist,
  });

  bool get isRefresh => existingLink != null;
  bool get isComplete => remote.complete;
}

class PlaylistLinkRefreshResult {
  final PlaylistLinkRecord record;
  final Playlist playlist;
  final PlaylistLinkMatchReport report;
  final bool changed;
  final bool removedMissing;

  const PlaylistLinkRefreshResult({
    required this.record,
    required this.playlist,
    required this.report,
    required this.changed,
    required this.removedMissing,
  });
}
