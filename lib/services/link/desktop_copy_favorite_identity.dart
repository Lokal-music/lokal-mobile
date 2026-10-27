import '../../models/song.dart';

/// A copied desktop original and its desktop-streaming library row have the
/// same remote identity even though their local database IDs may differ.
/// Only a proven server/track-ID pair is merged: matching titles are NOT proof
/// that different recordings belong to the same favorite.
Map<String, String> desktopCopyFavoriteRedirects(Iterable<Song> songs) {
  final groups = <String, List<Song>>{};
  for (final song in songs) {
    if (song.remoteServerId == null ||
        song.remoteId == null ||
        song.remoteId!.isEmpty) {
      continue;
    }
    final key = '\${song.remoteServerId}\u0000\${song.remoteId}';
    groups.putIfAbsent(key, () => <Song>[]).add(song);
  }
  final redirects = <String, String>{};
  for (final group in groups.values) {
    if (group.length < 2) continue;
    // Prefer the available on-phone original to the streamable desktop ghost.
    // Do not delete either library row: playlists/history may reference them.
    final local = group.where((song) =>
        song.sourceType == null &&
        song.filePath != null &&
        !song.filePath!.startsWith('ghost://') &&
        !song.filePath!.startsWith('lokal://'));
    final canonical = local.isNotEmpty ? local.first : group.first;
    for (final song in group) {
      if (song.id != canonical.id) redirects[song.id] = canonical.id;
    }
  }
  return redirects;
}

Set<String> canonicalDesktopCopyFavoriteIds(
    Iterable<String> ids, Map<String, String> redirects) {
  return ids.map((id) => redirects[id] ?? id).toSet();
}
