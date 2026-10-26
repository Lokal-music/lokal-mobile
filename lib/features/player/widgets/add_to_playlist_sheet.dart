import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/library/lokal_playlists.dart'
    show LokalPlaylistArtwork, lokalPlaylistCoverSongs;
import 'package:flick/widgets/common/glass_bottom_sheet.dart';
import 'package:flick/l10n/l10n.dart';

class AddToPlaylistSheet extends ConsumerWidget {
  final List<Song> songs;
  const AddToPlaylistSheet({super.key, required this.songs});

  Song get song => songs.first;

  static Future<void> show(BuildContext context, Song song) {
    return showSongs(context, [song]);
  }

  static Future<void> showSongs(BuildContext context, List<Song> songs) {
    return showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => AddToPlaylistSheet(songs: songs),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: AppBottomSheetSurface.decoration,
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.listPlus,
                color: AppColors.accent,
                size: 24,
              ),
              const SizedBox(width: 12),
              Text(
                songs.length == 1
                    ? l10n.addToPlaylist2
                    : l10n.addSongsToPlaylist2(songs.length),
                style: TextStyle(
                  fontFamily: 'GoogleSansFlex',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: context.adaptiveTextPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Consumer(
            builder: (context, ref, _) {
              final playlistsAsync = ref.watch(playlistsProvider);
              return playlistsAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text(
                  l10n.errorLoadingPlaylists,
                  style: TextStyle(color: context.adaptiveTextTertiary),
                ),
                data: (state) {
                  // Resolve covers exactly as Library > Playlists does, using
                  // preferred local song copies and stored online snapshots.
                  // Observe this once for the list, never scan the whole
                  // library separately for each scrolling playlist row.
                  final libraryById =
                      ref.watch(konnektedLibraryIndexProvider).value?.byId ??
                      const <String, Song>{};
                  if (state.playlists.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          l10n.noPlaylistsYetNcreateOneIn,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: context.adaptiveTextTertiary,
                            fontFamily: 'GoogleSansFlex',
                          ),
                        ),
                      ),
                    );
                  }
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.4,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: state.playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = state.playlists[index];
                        final songIds = songs.map((s) => s.id).toSet();
                        final isAlreadyAdded = playlist.songIds
                            .where((id) => songIds.contains(id))
                            .length >=
                            songs.length;
                        // Older app versions could save an online ID without
                        // its metadata. Permit selecting that playlist again
                        // to repair the entry rather than trapping it as
                        // "Missing song" behind a disabled row.
                        final needsMetadataRepair = isAlreadyAdded &&
                            songs.any((song) =>
                                playlist.songIds.contains(song.id) &&
                                !playlist.songSnapshots.containsKey(song.id) &&
                                (song.isPending ||
                                    song.filePath?.isNotEmpty != true ||
                                    song.filePath!.startsWith('http')));
                        return ListTile(
                          // Match the actual playlist art in Library:
                          // server-supplied artwork for Navidrome, otherwise
                          // the same bounded four-song cover collage. Only
                          // empty/unresolvable playlists get a placeholder.
                          leading: SizedBox.square(
                            dimension: 48,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LokalPlaylistArtwork(
                                key: ValueKey(playlist.id),
                                playlist: playlist,
                                songs: lokalPlaylistCoverSongs(
                                  playlist,
                                  libraryById,
                                ),
                              ),
                            ),
                          ),
                          title: Text(
                            playlist.name,
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                              fontFamily: 'GoogleSansFlex',
                            ),
                          ),
                          subtitle: Text(
                            l10n.songs9(playlist.songIds.length),
                            style: TextStyle(
                              color: context.adaptiveTextTertiary,
                              fontFamily: 'GoogleSansFlex',
                            ),
                          ),
                          trailing: isAlreadyAdded
                              ? Icon(
                                  LucideIcons.check,
                                  color: AppColors.accent,
                                )
                              : null,
                          onTap: isAlreadyAdded && !needsMetadataRepair
                              ? null
                              : () async {
                                  final notifier = ref.read(
                                    playlistsProvider.notifier,
                                  );
                                  for (final s in songs) {
                                    await notifier.addSongToPlaylist(
                                      playlist.id,
                                      s.id,
                                      song: s,
                                    );
                                  }
                                  if (context.mounted) {
                                    Navigator.pop(context);
                                    LokalToast.fromSnackBar(context, 
                                      SnackBar(
                                        content: Text(
                                          songs.length == 1
                                              ? l10n.addedTo2(playlist.name)
                                              : l10n.addedSongsTo(songs.length, playlist.name),
                                        ),
                                      ),
                                    );
                                  }
                                },
                        );
                      },
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
