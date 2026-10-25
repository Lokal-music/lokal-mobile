import 'package:flick/features/discovery/recommendation_match.dart'
    show leadArtist, recommendationKey, titleKey;
import 'package:flick/models/song.dart';

/// Visible library rows and a lookup for existing playlist IDs. An imported
/// desktop song may be hidden in the library in favour of an equivalent local
/// recording, but that must never make a saved playlist entry disappear.
class PreferredLibrarySongIndex {
  const PreferredLibrarySongIndex({required this.visible, required this.byId});

  final List<Song> visible;

  /// Includes aliases from suppressed desktop track IDs to their phone copies.
  /// Ghost-only history tracks are intentionally absent.
  final Map<String, Song> byId;
}

/// Recording-level matching, not fuzzy artwork matching: require a lead
/// artist, normalized title, duration within two seconds, and compatible
/// known album tags. Do not conflate different edits/masters.
PreferredLibrarySongIndex preferredLibrarySongIndex(List<Song> songs) {
  // Most phone libraries have no desktop stream rows to reconcile. Avoid
  // normalizing every title/artist on every artwork or metadata update.
  if (!songs.any(
    (song) =>
        song.sourceType == 'lokal' &&
        !(song.filePath?.startsWith('ghost://') ?? false),
  )) {
    final visible = [
      for (final song in songs)
        if (!(song.filePath?.startsWith('ghost://') ?? false)) song,
    ];
    return PreferredLibrarySongIndex(
      visible: visible,
      byId: {for (final song in visible) song.id: song},
    );
  }
  String? recordingKey(Song song) {
    if (song.duration <= Duration.zero) return null;
    final artist = recommendationKey(leadArtist(song.artist));
    final title = titleKey(song.title);
    if (artist.isEmpty || title.isEmpty) return null;
    return '$artist\u0000$title';
  }

  final locallyAvailable = <String, List<Song>>{};
  for (final song in songs) {
    if (song.isNetworkSource ||
        song.isPending ||
        song.filePath?.isNotEmpty != true ||
        song.filePath!.startsWith('ghost://')) {
      continue;
    }
    final key = recordingKey(song);
    if (key != null) (locallyAvailable[key] ??= []).add(song);
  }

  Song? matchingPhoneCopy(Song desktop) {
    if (desktop.sourceType != 'lokal') return null;
    final key = recordingKey(desktop);
    if (key == null) return null;
    for (final phone in locallyAvailable[key] ?? const <Song>[]) {
      if ((phone.duration - desktop.duration).abs() >
          const Duration(seconds: 2)) {
        continue;
      }

      final localAlbum = recommendationKey(phone.album);
      final desktopAlbum = recommendationKey(desktop.album);
      if (localAlbum.isEmpty ||
          desktopAlbum.isEmpty ||
          localAlbum == desktopAlbum) {
        return phone;
      }
    }
    return null;
  }

  final visible = <Song>[];
  final byId = <String, Song>{};
  for (final song in songs) {
    if (song.filePath?.startsWith('ghost://') ?? false) continue;
    final replacement = matchingPhoneCopy(song);
    if (replacement == null) visible.add(song);
    // Retain original IDs as aliases for playlists and other references.
    byId[song.id] = replacement ?? song;
  }
  return PreferredLibrarySongIndex(visible: visible, byId: byId);
}

/// In the library, prefer phone copies to equivalent desktop records.
/// The desktop records remain in the database; saved playlists can resolve
/// their original IDs through [preferredLibrarySongIndex].
List<Song> preferLocalLibrarySongs(List<Song> songs) =>
    preferredLibrarySongIndex(songs).visible;
