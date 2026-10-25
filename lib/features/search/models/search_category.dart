import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/l10n/l10n.dart';

enum SearchCategory {
  songs,
  artists,
  albums,
  lyrics,
  albumArtists,
  folders,
  year,
  playlists,
}

extension SearchCategoryX on SearchCategory {
  String get label {
    switch (this) {
      case SearchCategory.songs:
        return l10n.songs14;
      case SearchCategory.artists:
        return l10n.artists;
      case SearchCategory.albums:
        return l10n.albums;
      case SearchCategory.lyrics:
        return l10n.lyrics;
      case SearchCategory.albumArtists:
        return l10n.albumArtists;
      case SearchCategory.folders:
        return l10n.folders;
      case SearchCategory.year:
        return l10n.year;
      case SearchCategory.playlists:
        return l10n.playlists;
    }
  }

  String get storageKey => name;

  IconData get icon {
    switch (this) {
      case SearchCategory.songs:
        return LucideIcons.music;
      case SearchCategory.artists:
        return LucideIcons.mic;
      case SearchCategory.albums:
        return LucideIcons.disc3;
      case SearchCategory.lyrics:
        return LucideIcons.listMusic;
      case SearchCategory.albumArtists:
        return LucideIcons.users;
      case SearchCategory.folders:
        return LucideIcons.folder;
      case SearchCategory.year:
        return LucideIcons.calendar;
      case SearchCategory.playlists:
        return LucideIcons.listMusic;
    }
  }

  static SearchCategory? fromStorageKey(String key) {
    for (final v in SearchCategory.values) {
      if (v.name == key) return v;
    }
    return null;
  }
}
