import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/theme/lokal_genre_palette.dart';
import 'package:flick/core/theme/lokal_interaction.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lokal_genre_taxonomy.dart';
import 'lokal_library_kit.dart';
import 'lokal_song_browser.dart';

const _other = 'Other';
const _minimumGenreTracks = 2;
final _separators = RegExp(r'[\\/;,|]');
final _nonLetterOrDigit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _marks = RegExp(r'[\u0300-\u036f]');
final _allNumbers = RegExp(r'^\d+$');
final _whitespace = RegExp(r'\s+');

/// Dart has no built-in NFKD normalizer. Fold precomposed Latin marks before
/// stripping Unicode combining marks, matching desktop's taxonomy identity.
const _latinFolds = <String, String>{
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
  'æ': 'ae', 'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ð': 'd', 'ñ': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
  'œ': 'oe', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ý': 'y', 'ÿ': 'y', 'þ': 'th', 'ß': 'ss', 'ł': 'l',
};

String _taxonomyKey(String value) {
  final lower = value.toLowerCase();
  final folded = lower.split('').map((ch) => _latinFolds[ch] ?? ch).join();
  return folded.replaceAll(_marks, '').replaceAll(_nonLetterOrDigit, '');
}

final _aliases = () {
  final names = <String, String>{};
  for (final group in lokalDesktopGenreGroups) {
    final canonical = group.$1;
    names[_taxonomyKey(canonical)] = canonical;
    for (final alias in group.$2) {
      names[_taxonomyKey(alias)] = canonical;
    }
  }
  return names;
}();

/// Conservative word-boundary classification for real subgenres absent from
/// the exact aliases. Examples: "melodic deep techno" → Electronic and
/// "experimental jazz quartet" → Jazz. A phrase pointing to two families
/// remains Other unless a specific exact alias resolves the hybrid.
String _genreWords(String value) {
  final lower = value.toLowerCase();
  final folded = lower.split('').map((ch) => _latinFolds[ch] ?? ch).join();
  return folded
      .replaceAll(_marks, '')
      .replaceAll(_nonLetterOrDigit, ' ')
      .trim()
      .replaceAll(_whitespace, ' ');
}

final _normalizedFamilyHints = [
  for (final family in lokalDesktopGenreHints)
    (
      family.$1,
      [for (final hint in family.$2) _genreWords(hint)],
    ),
];

String? _inferGenreFamily(String raw) {
  final words = _genreWords(raw);
  if (words.isEmpty) return null;
  final padded = ' $words ';
  String? found;
  for (final family in _normalizedFamilyHints) {
    if (!family.$2.any((hint) => padded.contains(' $hint '))) continue;
    // "Indie" and "Alternative" are modifiers when another clear style
    // is present. E.g. indie shoegaze remains Rock, not Other.
    if (family.$1 == 'Indie / Alternative' && found != null) continue;
    if (found == 'Indie / Alternative') {
      found = family.$1;
      continue;
    }
    if (found != null && found != family.$1) return null;
    found = family.$1;
  }
  return found;
}

/// Raw tag identity (also used by radio). The grouping layer maps these tags
/// to broad canonical categories but never rewrites the song's stored genre.
String lokalGenreKey(String name) => _taxonomyKey(name);

/// A tag is either a desktop canonical category, Other, or unusable metadata.
String? lokalNormalizeGenreName(String? value) {
  final raw = (value ?? '').replaceAll(_whitespace, ' ').trim();
  final key = _taxonomyKey(raw);
  if (key.isEmpty || _allNumbers.hasMatch(key) ||
      lokalDesktopGenreNoise.contains(key)) {
    return null;
  }
  // Never create a standalone category for an unfamiliar string. Infer a
  // familiar broad family when unambiguous; otherwise use Other.
  return _aliases[key] ?? _inferGenreFamily(raw) ?? _other;
}

/// Split a file's raw multi-genre tag without changing what is on disk.
/// Desktop supports slash, backslash, comma, semicolon, and pipe separators.
List<String> lokalSplitGenres(String? value) {
  final out = <String>[];
  final seen = <String>{};
  for (final part in (value ?? '').split(_separators)) {
    final name = part.replaceAll(_whitespace, ' ').trim();
    final key = name.toLowerCase();
    if (key.isEmpty || !seen.add(key)) continue;
    out.add(name);
  }
  return out;
}

/// Distinct broad categories per song, identical to desktop trackGenres.
List<String> lokalTrackGenres(Song song) {
  final out = <String>[];
  final seen = <String>{};
  for (final tag in lokalSplitGenres(song.genre)) {
    final canonical = lokalNormalizeGenreName(tag);
    if (canonical != null && seen.add(lokalGenreKey(canonical))) {
      out.add(canonical);
    }
  }
  return out;
}

@immutable
class LokalGenre {
  const LokalGenre(this.name, this.songs);

  final String name;
  final List<Song> songs;
}

/// The desktop Genres summary also tracks files without a usable category.
@immutable
class LokalGenreSummary {
  const LokalGenreSummary(this.genres, this.noGenre);

  final List<LokalGenre> genres;
  final List<Song> noGenre;
}

final _knownGenreKeys = <String>{
  for (final group in lokalDesktopGenreGroups) _taxonomyKey(group.$1),
};

List<String> _visibleGenres(List<String> genres, Set<String> rare) {
  final common = [
    for (final name in genres)
      if (name != _other && !rare.contains(lokalGenreKey(name))) name,
  ];
  if (common.isNotEmpty) return common;
  return genres.isNotEmpty && !rare.contains(lokalGenreKey(_other))
      ? const [_other] : const [];
}

/// Mirrors desktop electron/genreList.js genreSummary:
///  * classify aliases and subgenres into broad categories;
///  * count each track only once per category;
///  * keep every recognized category, even when it has only one song;
///  * infer broad genres from distinct musical style words, with strict
///    boundaries and explicit aliases taking precedence;
///  * keep genuinely unknown/ambiguous tags in Other even if repeated;
///  * suppress a one-track Other card in favor of No genre;
///  * keep order newest-first for cover art and count-desc for the grid.
/// Ghost/pending catalogue placeholders are not real library recordings.
LokalGenreSummary lokalGenreSummary(Iterable<Song> library) {
  final ordered = <(int, Song)>[];
  var inputIndex = 0;
  for (final song in library) {
    if (!song.isPending && !(song.filePath?.startsWith('ghost://') ?? false)) {
      ordered.add((inputIndex, song));
    }
    inputIndex++;
  }
  // Match the desktop's newest-first art order while retaining the original
  // source order for songs with identical or missing import timestamps.
  ordered.sort((a, b) {
    final aDate = a.$2.dateAdded?.millisecondsSinceEpoch ?? 0;
    final bDate = b.$2.dateAdded?.millisecondsSinceEpoch ?? 0;
    final byDate = bDate.compareTo(aDate);
    return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
  });
  final tracks = [for (final entry in ordered) entry.$2];

  final categorized = [for (final song in tracks) lokalTrackGenres(song)];
  final counts = <String, int>{};
  for (final genres in categorized) {
    for (final name in genres) {
      final key = lokalGenreKey(name);
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }

  final rare = <String>{
    for (final entry in counts.entries)
      if (entry.key != lokalGenreKey(_other) &&
          !_knownGenreKeys.contains(entry.key) &&
          entry.value < _minimumGenreTracks) entry.key,
  };
  final otherCount = categorized.where(
    (genres) => _visibleGenres(genres, rare).contains(_other),
  ).length;
  if (otherCount < _minimumGenreTracks) rare.add(lokalGenreKey(_other));

  final grouped = <String, List<Song>>{};
  final noGenre = <Song>[];
  for (var i = 0; i < tracks.length; i++) {
    final visible = _visibleGenres(categorized[i], rare);
    if (visible.isEmpty) {
      noGenre.add(tracks[i]);
      continue;
    }
    for (final name in visible) {
      (grouped[name] ??= []).add(tracks[i]);
    }
  }
  final genres = [
    for (final entry in grouped.entries)
      LokalGenre(entry.key, List<Song>.unmodifiable(entry.value)),
  ]..sort((a, b) {
    final byCount = b.songs.length.compareTo(a.songs.length);
    return byCount != 0
        ? byCount
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return LokalGenreSummary(
    List<LokalGenre>.unmodifiable(genres),
    List<Song>.unmodifiable(noGenre),
  );
}

List<LokalGenre> lokalGenres(Iterable<Song> library) =>
    lokalGenreSummary(library).genres;

final lokalGenreSummaryProvider = Provider<AsyncValue<LokalGenreSummary>>(
  (ref) => ref.watch(konnektedLibraryProvider).whenData(lokalGenreSummary),
);

final lokalGenresProvider = Provider<AsyncValue<List<LokalGenre>>>(
  (ref) => ref.watch(lokalGenreSummaryProvider).whenData((data) => data.genres),
);

/// Library › Genres: desktop's canonical broad categories (no custom genre
/// cards), plus Other, No genre, and search over visible family labels.
class LokalGenresPage extends ConsumerStatefulWidget {
  const LokalGenresPage({super.key});

  @override
  ConsumerState<LokalGenresPage> createState() => _LokalGenresPageState();
}

class _LokalGenresPageState extends ConsumerState<LokalGenresPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(lokalGenreSummaryProvider).value;
    final query = _query.trim().toLowerCase();
    final shown = summary == null ? const <LokalGenre>[] : [
      for (final group in summary.genres)
        if (query.isEmpty || group.name.toLowerCase().contains(query)) group,
    ];
    final noGenreLabel = lokalText('No genre');
    final showNoGenre = summary != null &&
        summary.noGenre.isNotEmpty &&
        (query.isEmpty || noGenreLabel.toLowerCase().contains(query));
    final count = shown.length + (showNoGenre ? 1 : 0);

    return LokalLibraryPage(
      title: lokalText('Genres'),
      subtitle: summary == null
          ? null
          : lokalText('{arg0} genres', args: {'arg0': summary.genres.length}),
      slivers: [
        if (summary != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: LokalSearchField(
                controller: _search,
                hint: lokalText('Search genres...'),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
          ),
        if (summary == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (count == 0)
          SliverToBoxAdapter(
            child: LokalEmptyState(
              icon: Icons.category_rounded,
              title: lokalText(query.isNotEmpty
                  ? 'No genres match your search.'
                  : 'No genres yet'),
              message: query.isNotEmpty
                  ? ''
                  : lokalText(
                      'Genres come from your files’ tags. Add a genre in Edit metadata and it shows up here.',
                    ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                final columns = width >= 850 ? 4 : (width >= 560 ? 3 : 2);
                final cell = (width - (columns - 1) * 14) / columns;
                final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    mainAxisExtent: (cell * .91).clamp(150.0, 222.0) * scale,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      if (index == shown.length) {
                        return _LokalGenreCard(
                          name: noGenreLabel,
                          count: summary.noGenre.length,
                          onTap: () => pushLokal(
                            context,
                            LokalGenrePage(
                              genre: LokalGenre(noGenreLabel, summary.noGenre),
                              isUnclassified: true,
                            ),
                          ),
                        );
                      }
                      final genre = shown[index];
                      return _LokalGenreCard(
                        name: genre.name,
                        count: genre.songs.length,
                        onTap: () => pushLokal(context, LokalGenrePage(genre: genre)),
                      );
                    },
                    childCount: count,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Colour is semantic and stable, independent of scroll order or artwork.
class _LokalGenreCard extends StatelessWidget {
  const _LokalGenreCard({
    required this.name,
    required this.count,
    required this.onTap,
  });

  final String name;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = LokalGenrePalette.of(name);
    return LokalPressable(
      radius: 24,
      semanticLabel: '$name, ${lokalSongCount(count)}',
      onTap: onTap,
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [tone.highlight, tone.base, tone.base],
                stops: const [0, .45, 1],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  right: -25,
                  bottom: -31,
                  child: Transform.rotate(
                    angle: -.18,
                    child: Icon(
                      tone.icon,
                      size: 126,
                      color: Colors.white.withValues(alpha: .19),
                    ),
                  ),
                ),
                Positioned(
                  top: 1, left: 1, right: 1,
                  child: Container(
                    height: 1,
                    color: Colors.white.withValues(alpha: .21),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: LokalTheme.sans,
                          fontSize: 22,
                          height: 1.06,
                          letterSpacing: -.65,
                          fontStyle: tone.italic ? FontStyle.italic : FontStyle.normal,
                          fontWeight: FontWeight.w800,
                          color: LokalGenrePalette.foreground,
                        ),
                      ),
                      const Spacer(),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .13),
                          border: Border.all(color: Colors.white.withValues(alpha: .22)),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          child: Text(
                            lokalSongCount(count),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: LokalGenrePalette.foreground,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Each grouped category remains a live song list with Play, Shuffle,
/// searching and sorting. The No genre category follows desktop too.
class LokalGenrePage extends ConsumerWidget {
  const LokalGenrePage({
    super.key,
    required this.genre,
    this.isUnclassified = false,
  });

  final LokalGenre genre;
  final bool isUnclassified;

  @override
  Widget build(BuildContext context, WidgetRef ref) => LokalSongListPage(
    title: genre.name,
    source: (ref) => ref.watch(lokalGenreSummaryProvider).whenData((summary) {
      if (isUnclassified) return summary.noGenre;
      final key = lokalGenreKey(genre.name);
      for (final group in summary.genres) {
        if (lokalGenreKey(group.name) == key) return group.songs;
      }
      return const <Song>[];
    }),
    initialSort: LokalSongSort.recentlyAdded,
    preferencesKey: 'lokal.genre.${isUnclassified ? '__none__' : lokalGenreKey(genre.name)}.song_browser_view.v1',
  );
}
