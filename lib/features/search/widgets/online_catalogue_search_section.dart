import 'package:flutter/material.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/services/global_catalogue_source.dart';
import 'package:flick/services/global_catalogue_search.dart';

import 'global_catalogue_search_section.dart';

import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/features/konnekted/library/lokal_music_detail_page.dart';

import 'artist_search_portrait.dart';

import '../models/search_category.dart';
import '../providers/search_filter_provider.dart';

/// Album/artist categories return catalogue entities, not unfiltered song rows.
class OnlineCatalogueSearchSection extends ConsumerStatefulWidget {
  const OnlineCatalogueSearchSection({
    super.key,
    required this.query,
    required this.category,
    this.previewLimit,
  });
  final String query;
  final SearchCategory category;
  final int? previewLimit;
  @override
  ConsumerState<OnlineCatalogueSearchSection> createState() =>
      _OnlineCatalogueSearchSectionState();
}

class _OnlineCatalogueSearchSectionState
    extends ConsumerState<OnlineCatalogueSearchSection> {
  late Future<GlobalCatalogueMatches> _results;
  @override
  void initState() {
    super.initState();
    GlobalCatalogueSource.selected.addListener(_onCatalogueChanged);
    _load();
  }

  void _onCatalogueChanged() {
    if (mounted) setState(() => _load());
  }

  @override
  void dispose() {
    GlobalCatalogueSource.selected.removeListener(_onCatalogueChanged);
    super.dispose();
  }

  void _load({bool refresh = false}) {
    _results = ref
        .read(globalCatalogueSearchServiceProvider)
        .search(widget.query, refresh: refresh, songsOnly: false);
  }

  @override
  void didUpdateWidget(covariant OnlineCatalogueSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.category != widget.category) {
      _load();
    }
  }

  Future<void> _open(Widget page) => Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      transitionDuration: AppConstants.animationNormal,
      reverseTransitionDuration: AppConstants.animationNormal,
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(.08, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic),
        ),
        child: FadeTransition(opacity: animation, child: child),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FutureBuilder<GlobalCatalogueMatches>(
            future: _results,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              if (snapshot.hasError) {
                return TextButton.icon(
                  onPressed: () => setState(() => _load(refresh: true)),
                  icon: const Icon(Icons.refresh),
                  label: Text(lokalText('Could not search. Retry')),
                );
              }
              final data =
                  snapshot.data ??
                  const GlobalCatalogueMatches(catalogue: 'apple');
              final rows = widget.category == SearchCategory.albums
                  ? data.albums
                  : data.artists;
              if (rows.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (data.notice != null)
                      Text(
                        data.notice!,
                        style: TextStyle(color: t.muted, fontSize: 11),
                      ),
                    Text(
                      lokalText(
                        widget.category == SearchCategory.albums
                            ? 'No albums found online.'
                            : 'No artists found online.',
                      ),
                      style: TextStyle(color: t.muted),
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (data.notice != null)
                    Text(
                      data.notice!,
                      style: TextStyle(color: t.muted, fontSize: 11),
                    ),
                  const SizedBox(height: 8),
                  for (final row in rows.take(
                    widget.previewLimit ?? rows.length,
                  ))
                    if (row is GlobalCatalogueAlbum)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: SizedBox.square(
                          dimension: 52,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedImageWidget(imagePath: row.artworkUrl),
                          ),
                        ),
                        title: Text(
                          row.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          row.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(
                          LokalMusicDetailPage.album(
                            title: row.name,
                            artist: row.artist,
                            localSongs: const [],
                            initialOnline: true,
                          ),
                        ),
                      )
                    else if (row is GlobalCatalogueArtist)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: ArtistSearchPortrait(
                          name: row.name,
                          artworkUrl: row.artworkUrl,
                        ),
                        title: Text(row.name),
                        subtitle: Text(lokalText('Artist')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(
                          LokalMusicDetailPage.artist(
                            name: row.name,
                            localSongs: const [],
                            initialOnline: true,
                          ),
                        ),
                      ),
                  if (widget.previewLimit != null &&
                      rows.length > widget.previewLimit!)
                    TextButton(
                      onPressed: () => ref
                          .read(searchFilterProvider.notifier)
                          .select(widget.category),
                      child: Text(
                        lokalText(
                          widget.category == SearchCategory.albums
                              ? 'See all albums'
                              : 'See all artists',
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
