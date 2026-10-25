import 'package:flick/models/playlist.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/online_playlist_reference.dart';

/// One transaction reorders the actual local playlist, unlike browser sorts
/// which only change the visible view. Network playlist mirrors are read-only.
enum LokalPlaylistOrder {
  titleAscending,
  titleDescending,
  artistAscending,
  artistDescending,
  dateAscending,
  dateDescending,
  reverse,
}

List<String> lokalOrderedPlaylistIds(
  Playlist playlist,
  Map<String, Song> byId,
  LokalPlaylistOrder order,
) {
  if (order == LokalPlaylistOrder.reverse) {
    return playlist.songIds.reversed.toList(growable: false);
  }
  final entries = <({String id, Song? song, int position})>[
    for (var i = 0; i < playlist.songIds.length; i++)
      (
        id: playlist.songIds[i],
        song: byId[playlist.songIds[i]] ??
            (playlist.songSnapshots[playlist.songIds[i]] == null
              ? null
              : playlist.songIds[i].startsWith(onlinePlaylistPrefix)
                ? restoreOnlinePlaylistSong(playlist.songIds[i],
                    playlist.songSnapshots[playlist.songIds[i]]!)
                : playlist.songSnapshots[playlist.songIds[i]]!.toSong(playlist.songIds[i])),
        position: i,
      ),
  ];
  final descending = switch (order) {
    LokalPlaylistOrder.titleDescending ||
    LokalPlaylistOrder.artistDescending ||
    LokalPlaylistOrder.dateDescending => true,
    _ => false,
  };
  entries.sort((a, b) {
    var comparison = 0;
    if (order == LokalPlaylistOrder.dateAscending ||
        order == LokalPlaylistOrder.dateDescending) {
      final dateA = playlist.songAddedAt[a.id];
      final dateB = playlist.songAddedAt[b.id];
      if (dateA == null && dateB != null) return 1;
      if (dateA != null && dateB == null) return -1;
      if (dateA != null && dateB != null) comparison = dateA.compareTo(dateB);
      if (dateA == null && dateB == null) {
        comparison = a.position.compareTo(b.position);
      }
    } else {
      final keyA = order == LokalPlaylistOrder.titleAscending ||
              order == LokalPlaylistOrder.titleDescending
          ? a.song?.title
          : a.song?.artist;
      final keyB = order == LokalPlaylistOrder.titleAscending ||
              order == LokalPlaylistOrder.titleDescending
          ? b.song?.title
          : b.song?.artist;
      // Missing entries remain at the end and are never deleted.
      if (keyA == null && keyB != null) return 1;
      if (keyA != null && keyB == null) return -1;
      comparison = (keyA ?? '').toLowerCase().compareTo(
        (keyB ?? '').toLowerCase(),
      );
    }
    if (comparison != 0) return descending ? -comparison : comparison;
    // Stable ties preserve the stored order, including repeated titles.
    return a.position.compareTo(b.position);
  });
  return entries.map((row) => row.id).toList(growable: false);
}
