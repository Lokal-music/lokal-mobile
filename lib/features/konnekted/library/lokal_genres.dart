import 'package:flick/l10n/l10n.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lokal_library_kit.dart';
import 'lokal_song_browser.dart';

final _separators = RegExp(r'[\\/;,|]');
final _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// A genre's identity: "Hip-Hop" and "hip hop" are one genre.
String lokalGenreKey(String name) =>
    name.toLowerCase().replaceAll(_notLetterOrDigit, '');

/// "Rock / Pop; Indie" -> Rock, Pop, Indie, without repeats (desktop's
/// `splitGenres`).
List<String> lokalSplitGenres(String? value) {
  final out = <String>[];
  final seen = <String>{};
  for (final part in (value ?? '').split(_separators)) {
    final name = part.replaceAll(RegExp(r'\s+'), ' ').trim();
    final key = lokalGenreKey(name);
    if (key.isEmpty || !seen.add(key)) continue;
    out.add(name);
  }
  return out;
}

@immutable
class LokalGenre {
  const LokalGenre(this.name, this.songs);

  final String name;
  final List<Song> songs;
}

/// The library's genres from its tags, most songs first.
List<LokalGenre> lokalGenres(Iterable<Song> library) {
  final names = <String, String>{};
  final songs = <String, List<Song>>{};
  for (final song in library) {
    for (final name in lokalSplitGenres(song.genre)) {
      final key = lokalGenreKey(name);
      names.putIfAbsent(key, () => name);
      (songs[key] ??= []).add(song);
    }
  }
  final genres = [
    for (final entry in songs.entries)
      LokalGenre(names[entry.key]!, entry.value),
  ];
  genres.sort((a, b) {
    final c = b.songs.length.compareTo(a.songs.length);
    return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return genres;
}

final lokalGenresProvider = Provider<AsyncValue<List<LokalGenre>>>(
  (ref) => ref.watch(konnektedLibraryProvider).whenData(lokalGenres),
);

/// Library › Genres: a grid of the genres in your tags.
class LokalGenresPage extends ConsumerWidget {
  const LokalGenresPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final genres = ref.watch(lokalGenresProvider);
    final list = genres.value;
    return LokalLibraryPage(
      title: lokalText('Genres'),
      subtitle: list == null
          ? null
          : lokalText("{arg0} genres", args: {'arg0': list.length}),
      slivers: [
        if (list == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (list.isEmpty)
          SliverToBoxAdapter(
            child: LokalEmptyState(
              icon: Icons.category_rounded,
              title: lokalText('No genres yet'),
              message: lokalText(
                'Genres come from your files’ tags. Add a genre in Edit metadata and it shows up here.',
              ),
            ),
          )
        else
          LokalCardGrid(
            itemCount: list.length,
            itemBuilder: (context, index) {
              final genre = list[index];
              return LokalCoverCard(
                art: LokalCollage(songs: genre.songs),
                title: genre.name,
                subtitle: lokalSongCount(genre.songs.length),
                onTap: () => pushLokal(context, LokalGenrePage(genre: genre)),
              );
            },
          ),
      ],
    );
  }
}

/// One genre's songs with Play and Shuffle.
class LokalGenrePage extends ConsumerWidget {
  const LokalGenrePage({super.key, required this.genre});

  final LokalGenre genre;

  @override
  Widget build(BuildContext context, WidgetRef ref) => LokalSongListPage(
    title: genre.name,
    source: (ref) => ref.watch(lokalGenresProvider).whenData((genres) {
      final key = lokalGenreKey(genre.name);
      for (final g in genres) {
        if (lokalGenreKey(g.name) == key) return g.songs;
      }
      return const <Song>[];
    }),
    initialSort: LokalSongSort.artist,
    preferencesKey: 'lokal.genre.${lokalGenreKey(genre.name)}.song_browser_view.v1',
  );
}
