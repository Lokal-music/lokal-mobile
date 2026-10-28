import 'package:flick/l10n/l10n.dart';

import 'dart:async';

import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/providers/favorites_provider.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lokal_albums_artists.dart';
import 'lokal_genres.dart';
import 'lokal_playlists.dart';
import 'lokal_song_browser.dart';

/// Songs Lokal downloaded (they live in its "Lokal Downloads" folder).
final lokalDownloadsProvider = Provider<AsyncValue<List<Song>>>((ref) {
  final folder = RegExp(
    '[/\\\\]${RegExp.escape(LibraryDownloader.folderName)}[/\\\\]',
  );
  return ref
      .watch(konnektedLibraryProvider)
      .whenData(
        (songs) => [
          for (final song in songs)
            if (folder.hasMatch(song.filePath ?? '')) song,
        ],
      );
});

/// Your history, newest first, each song once.
final lokalRecentlyPlayedProvider = StreamProvider.autoDispose<List<Song>>((
  ref,
) {
  final repository = ref.watch(konnektedHistoryRepositoryProvider);
  final changes = StreamController<void>();
  final subscription = repository.watchHistory().listen(
    changes.add,
    onError: changes.addError,
  );
  changes.add(null);
  ref.onDispose(() {
    unawaited(subscription.cancel());
    unawaited(changes.close());
  });
  return changes.stream.asyncMap((_) async {
    final entries = await repository.getRecentHistory(limit: 300);
    final seen = <String>{};
    return [
      for (final entry in entries)
        if (seen.add(entry.song.id)) entry.song,
    ];
  });
});

/// The Library page for a destination name, or null when it isn't one.
Widget? lokalLibraryPage(String name) => switch (name) {
  'songs' => LokalSongListPage(
    title: lokalText('Songs'),
    preferencesKey: 'lokal.library.songs.song_browser_view.v1',
    source: (ref) => ref.watch(konnektedLibraryProvider),
  ),
  'favorites' => LokalSongListPage(
    title: lokalText('Liked'),
    source: (ref) => ref.watch(konnektedFavoritesProvider),
    // "Recently added" means added to Likes here, not imported into Library.
    initialSort: LokalSongSort.recentlyAdded,
    recentlyAddedRanks: (ref) =>
        ref.watch(favoritesProvider).value?.likedRanks ?? const <String, int>{},
    preferencesKey: 'lokal.likes.song_browser_view.v1',
    emptyIcon: Icons.favorite_border_rounded,
    emptyTitle: 'No liked songs yet',
    emptyMessage: 'Tap the heart on any song and it shows up here.',
  ),
  'downloads' => LokalSongListPage(
    title: lokalText('Downloads'),
    preferencesKey: 'lokal.library.downloads.song_browser_view.v1',
    source: (ref) => ref.watch(lokalDownloadsProvider),
    emptyIcon: Icons.download_rounded,
    emptyTitle: 'No downloads yet',
    emptyMessage: 'Songs you download from Search go to the Lokal Downloads folder and show up here.',
  ),
  'recentlyPlayed' => LokalSongListPage(
    title: lokalText('Recently played'),
    preferencesKey: 'lokal.library.recently_played.song_browser_view.v1',
    source: (ref) => ref.watch(lokalRecentlyPlayedProvider),
    initialSort: LokalSongSort.original,
    originalLabel: 'Most recent',
    emptyIcon: Icons.history_rounded,
    emptyTitle: 'Nothing played yet',
    emptyMessage: 'Songs you play show up here.',
  ),
  'recentlyAdded' => LokalSongListPage(
    title: lokalText('Recently added'),
    preferencesKey: 'lokal.library.recently_added.song_browser_view.v1',
    source: (ref) => ref.watch(konnektedLibraryProvider),
  ),
  'albums' => const LokalAlbumsPage(),
  'artists' => const LokalArtistsPage(),
  'genres' => const LokalGenresPage(),
  'playlists' => const LokalPlaylistsPage(),
  _ => null,
};
