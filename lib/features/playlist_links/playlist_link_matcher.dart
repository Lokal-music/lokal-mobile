import 'playlist_link_models.dart';
import 'package:flick/models/song.dart';

class PlaylistLinkMatcher {
  const PlaylistLinkMatcher();

  PlaylistLinkMatchReport match(
    List<RemotePlaylistEntry> entries,
    List<Song> songs, {
    Map<String, String> resolvedSongIds = const {},
  }) {
    final byId = {for (final song in songs) song.id: song};
    final byKey = <String, List<Song>>{};
    for (final song in songs) {
      final title = normalize(song.title);
      final artist = normalize(song.artist);
      if (title.isEmpty || artist.isEmpty) continue;
      byKey.putIfAbsent('$title\u0000$artist', () => []).add(song);
    }

    final matches = <PlaylistLinkMatch>[];
    final unmatched = <RemotePlaylistEntry>[];
    final usedSongIds = <String>{};
    var duplicateMatches = 0;

    for (final entry in entries) {
      final key = '${normalize(entry.title)}\u0000${normalize(entry.artist)}';
      final candidates = byKey[key].orEmpty;
      final constrained = candidates.where((song) {
        if (entry.duration != null && song.duration.inMilliseconds > 0) {
          final difference =
              (song.duration.inMilliseconds - entry.duration!.inMilliseconds)
                  .abs();
          if (difference > 2000) return false;
        } else if (entry.duration != null) {
          return false;
        }
        final album = normalize(entry.album ?? '');
        if (album.isNotEmpty && normalize(song.album ?? '') != album) {
          return false;
        }
        return true;
      }).toList();

      // A playlist link may not choose a search result merely because it was
      // first. Duplicate library metadata is ambiguous and stays unmatched.
      final verified = byId[resolvedSongIds[entry.identityKey] ??
          resolvedSongIds[entry.legacyIdentityKey]];
      if (verified == null && constrained.length != 1) {
        unmatched.add(entry);
        continue;
      }
      final song = verified ?? constrained.single;
      if (!usedSongIds.add(song.id)) {
        duplicateMatches += 1;
        continue;
      }
      matches.add(PlaylistLinkMatch(remoteEntry: entry, song: song));
    }

    return PlaylistLinkMatchReport(
      remoteEntryCount: entries.length,
      matches: matches,
      unmatchedEntries: unmatched,
      duplicateMatches: duplicateMatches,
    );
  }

  /// Case-insensitive, punctuation-insensitive comparison that preserves the
  /// words and their order. It intentionally does not do fuzzy matching,
  /// featured-artist guessing, or substring matching.
  static String normalize(String value) {
    final result = StringBuffer();
    var needsSpace = false;
    for (final rune in value.toLowerCase().runes) {
      final isAsciiLetter = rune >= 0x61 && rune <= 0x7a;
      final isAsciiDigit = rune >= 0x30 && rune <= 0x39;
      final isUnicodeLetterOrDigit =
          rune >= 0x80 &&
          ((rune >= 0x00c0 && rune <= 0x02ff) ||
              (rune >= 0x0370 && rune <= 0x1fff) ||
              (rune >= 0x2000 && rune <= 0xd7ff) ||
              (rune >= 0xf900 && rune <= 0xfdcf) ||
              (rune >= 0xfe70 && rune <= 0xfefc));
      if (isAsciiLetter || isAsciiDigit || isUnicodeLetterOrDigit) {
        if (needsSpace && result.isNotEmpty) result.write(' ');
        result.writeCharCode(rune);
        needsSpace = false;
      } else {
        needsSpace = true;
      }
    }
    return result.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
  }
}

extension on List<Song>? {
  List<Song> get orEmpty => this ?? const [];
}
