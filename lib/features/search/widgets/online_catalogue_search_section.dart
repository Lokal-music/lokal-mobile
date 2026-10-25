import 'package:flutter/material.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/providers/apple_music_provider.dart';
import 'package:flick/services/apple_music/apple_music_models.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/features/konnekted/library/lokal_music_detail_page.dart';
import 'package:flick/features/konnekted/library/lokal_online_catalogue.dart';

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
  late Future<List<Object>> _results;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load({bool refresh = false}) {
    final api = ref.read(appleMusicMetadataServiceProvider);
    _results = widget.category == SearchCategory.albums
        ? api
              .searchAlbums(widget.query, refresh: refresh)
              .then((rows) => rows.cast<Object>())
        : api
              .searchArtists(widget.query, refresh: refresh)
              .then((rows) => rows.cast<Object>());
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
          Text(
            lokalText(
              widget.category == SearchCategory.albums
                  ? 'Online albums'
                  : 'Online artists',
            ),
            style: TextStyle(
              color: t.text,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            lokalText(
              'Apple Music catalogue · plays through your configured sources',
            ),
            style: TextStyle(color: t.muted, fontSize: 11),
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<Object>>(
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
              final rows = snapshot.data ?? const [];
              if (rows.isEmpty) {
                return Text(
                  lokalText(
                    widget.category == SearchCategory.albums
                        ? 'No albums found online.'
                        : 'No artists found online.',
                  ),
                  style: TextStyle(color: t.muted),
                );
              }
              return Column(
                children: [
                  for (final row in rows.take(
                    widget.previewLimit ?? rows.length,
                  ))
                    if (row is AppleMusicAlbumMatch)
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
                          row.artistName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(
                          LokalMusicDetailPage.album(
                            title: row.name,
                            artist: row.artistName,
                            localSongs: const [],
                            initialOnline: true,
                            release: LokalCatalogueAlbum.fromApple(row),
                          ),
                        ),
                      )
                    else if (row is AppleMusicArtist)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: t.surface2,
                          child: Icon(Icons.person_outline, color: t.muted),
                        ),
                        title: Text(row.name),
                        subtitle: Text(row.genre ?? lokalText('Artist')),
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
