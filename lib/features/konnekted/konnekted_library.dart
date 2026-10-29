import 'package:flick/l10n/l10n.dart';

import 'dart:async';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/classipod/classipod_screen.dart';
import 'package:flick/features/internet_radio/internet_radio_page.dart';
import 'package:flick/features/music_videos/music_videos_page.dart';
import 'package:flick/features/settings/library_scan/library_scan_flow.dart';
import 'package:flick/providers/songs_provider.dart';
import 'package:flick/widgets/lokal/lokal_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'konnekted_data.dart';
import 'konnekted_destination.dart';
import 'konnekted_home.dart';
import 'konnekted_style.dart';
import 'library/lokal_library_add_sheet.dart';
import 'library/lokal_library_kit.dart';
import 'library/lokal_playlists.dart';

/// Library overview: navigation tiles, recently added and compact shortcuts.
/// The full song browser remains available through dedicated song routes.
class KonnektedLibrary extends ConsumerWidget {
  const KonnektedLibrary({
    super.key,
    required this.onNavigate,
    this.onAddFolder,
  });

  final ValueChanged<KonnektedDestination> onNavigate;

  /// The empty state's action; defaults to the system folder picker followed
  /// by a scan ([LibraryScanFlow.addFolder]).
  final ValueChanged<BuildContext>? onAddFolder;

  void _addFolder(BuildContext context) => onAddFolder != null
      ? onAddFolder!(context)
      : unawaited(LibraryScanFlow.addFolder(context));

  Future<void> _showAdd(BuildContext context, WidgetRef ref) async {
    final choice = await showLokalLibraryAddSheet(context);
    if (!context.mounted) return;
    switch (choice) {
      case LokalLibraryAddAction.playlist:
        await lokalCreatePlaylist(context, ref);
      case LokalLibraryAddAction.link:
        onNavigate(KonnektedDestination.linkedPlaylists);
      case LokalLibraryAddAction.m3u:
        await lokalImportM3u(context, ref);
      case LokalLibraryAddAction.folder:
        // The action promises to add a folder; go straight to Android's
        // persisted folder picker and start its library scan.
        _addFolder(context);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(konnektedLibraryProvider);
    final songs = library.value;
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        key: const PageStorageKey('konnekted-library'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: konnektedTopBarPadding,
              child: SizedBox(
                height: konnektedHeaderHeight(context),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          // Preserve the Classipod easter egg on the title.
                          onLongPress: () => Navigator.of(context)
                              .push(ClassipodScreen.route(context)),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              lokalText('Library'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -.8,
                                color: context.lokal.text,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    LokalRoundAction(
                      icon: Icons.add_rounded,
                      iconSize: 24,
                      label: lokalText('Add music, playlists and folders'),
                      onPressed: () => _showAdd(context, ref),
                    ),
                    const SizedBox(width: 10),
                    KonnektedHeaderActions(
                      onSettings: () => onNavigate(
                        KonnektedDestination.settings,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 18)),
          if (library.hasError && songs == null)
            SliverToBoxAdapter(
              child: KonnektedMessage(
                title: lokalText('Couldn’t open your collection'),
                message: lokalText('Try again or manage your music folders.'),
                actionLabel: 'Try again',
                onAction: () => ref.invalidate(songsProvider),
              ),
            )
          else if (songs != null && songs.isEmpty)
            SliverToBoxAdapter(
              child: KonnektedMessage(
                title: lokalText('All your music. All yours.'),
                message: lokalText(
                  'Choose a folder and let your collection take shape.',
                ),
                icon: Icons.library_music_rounded,
                actionLabel: 'Add a music folder',
                onAction: () => _addFolder(context),
              ),
            ),
          SliverToBoxAdapter(child: _Tiles(onNavigate: onNavigate)),
          if (songs != null && songs.isNotEmpty)
            SliverToBoxAdapter(
              child: KonnektedSongShelf(
                title: lokalText('Recently added'),
                songs: ref.watch(konnektedRecentlyAddedProvider),
                emptyTitle: 'Nothing new yet',
                emptyMessage: 'New songs show up here.',
                onSeeAll: () => onNavigate(KonnektedDestination.recentlyAdded),
                onRetry: () => ref.invalidate(songsProvider),
                onPlay: (song, queue) =>
                    lokalPlay(context, ref, queue, start: song),
              ),
            ),
          SliverToBoxAdapter(
            child: LokalSectionTitle(title: lokalText('More')),
          ),
          SliverToBoxAdapter(child: _MoreRows(onNavigate: onNavigate)),
          if (songs == null)
            SliverToBoxAdapter(
              child: KonnektedLoading(
                label: lokalText('Opening your collection'),
              ),
            ),

          SliverToBoxAdapter(
            child: SizedBox(height: 150 + MediaQuery.paddingOf(context).bottom),
          ),
        ],
      ),
    );
  }
}

class _Tiles extends ConsumerWidget {
  const _Tiles({required this.onNavigate});

  final ValueChanged<KonnektedDestination> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const tiles = [
      ('Liked', Icons.favorite_rounded, KonnektedDestination.favorites),
      ('Playlists', Icons.queue_music_rounded, KonnektedDestination.playlists),
      ('Albums', Icons.album_rounded, KonnektedDestination.albums),
      ('Artists', Icons.mic_external_on_rounded, KonnektedDestination.artists),
      ('Genres', Icons.category_rounded, KonnektedDestination.genres),
      ('Videos', Icons.smart_display_rounded, null),
    ];
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
      child: LayoutBuilder(
        builder: (context, c) {
          final columns = c.maxWidth < 300 ? 1 : 2;
          final width = (c.maxWidth - 12 * (columns - 1)) / columns;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (label, icon, destination) in tiles)
                SizedBox(
                  width: width,
                  height: 58 * scale,
                  child: _Tile(
                    label: label,
                    icon: icon,
                    onTap: destination == null
                        ? () => pushLokal(context, const MusicVideosPage())
                        : () => onNavigate(destination),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Semantics(
      button: true,
      child: LokalGlass(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        thickness: LokalGlassThickness.thin,
        shadow: false,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(icon, color: t.accent, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreRows extends StatelessWidget {
  const _MoreRows({required this.onNavigate});

  final ValueChanged<KonnektedDestination> onNavigate;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      LokalNavRow(
        icon: Icons.history_rounded,
        label: lokalText('Recently played'),
        onTap: () => onNavigate(KonnektedDestination.recentlyPlayed),
      ),
      LokalNavRow(
        icon: Icons.auto_graph_rounded,
        label: lokalText('Recap'),
        onTap: () => onNavigate(KonnektedDestination.recap),
      ),
      LokalNavRow(
        icon: Icons.folder_rounded,
        label: lokalText('Folders'),
        onTap: () => onNavigate(KonnektedDestination.folders),
      ),
      LokalNavRow(
        icon: Icons.link_rounded,
        label: lokalText('Linked playlists'),
        onTap: () => onNavigate(KonnektedDestination.linkedPlaylists),
      ),
      LokalNavRow(
        icon: Icons.radio_rounded,
        label: lokalText('Radio'),
        onTap: () => pushLokal(context, const InternetRadioPage()),
      ),
    ],
  );
}
