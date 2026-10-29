import 'package:flick/features/flow/flow_screen.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/features/konnekted/lokal_home_greeting.dart';
import 'package:flick/features/konnekted/lokal_mixes.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/favorites_provider.dart';
import 'package:flick/providers/songs_provider.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/lokal/lokal_cover_flow.dart';
import 'package:flick/widgets/lokal/lokal_glass.dart';
import 'package:flick/widgets/lokal/lokal_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'konnekted_data.dart';
import 'konnekted_destination.dart';
import 'konnekted_discovery_view.dart';
import 'konnekted_style.dart';

/// Home modes: local library, online discovery, and Flow.
enum KonnektedHomeTab {
  local('Local'),
  discovery('Discovery'),
  flow('Flow');

  const KonnektedHomeTab(this.label);
  final String label;
}

/// Where "Add your music" leads: Settings › Library › Folders.
const _addMusic = KonnektedDestination.settingsAt(
  LokalSettingsGroup.library,
  section: 'Folders',
);

class KonnektedHome extends ConsumerStatefulWidget {
  const KonnektedHome({
    super.key,
    required this.onNavigate,
    required this.onPlay,
  });

  final ValueChanged<KonnektedDestination> onNavigate;
  final void Function(Song song, List<Song> shelf) onPlay;

  @override
  ConsumerState<KonnektedHome> createState() => _KonnektedHomeState();
}

class _KonnektedHomeState extends ConsumerState<KonnektedHome> {
  late KonnektedHomeTab _tab =
      PageStorage.maybeOf(context)
              ?.readState(context, identifier: 'konnekted-home-tab')
          as KonnektedHomeTab? ??
      KonnektedHomeTab.local;

  void _select(KonnektedHomeTab tab) {
    if (tab == _tab) return;
    HapticFeedback.selectionClick();
    PageStorage.maybeOf(context)
        ?.writeState(context, tab, identifier: 'konnekted-home-tab');
    setState(() => _tab = tab);
  }

  ValueChanged<KonnektedDestination> get onNavigate => widget.onNavigate;
  void Function(Song song, List<Song> shelf) get onPlay => widget.onPlay;

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(konnektedLibraryProvider);
    final topBar = KonnektedHomeTopBar(
      greeting: ref.watch(konnektedGreetingProvider).value,
      selectedTab: _tab,
      onTabChanged: _select,
      onSettings: () => onNavigate(KonnektedDestination.settings),
      onAppearance: () => onNavigate(
        const KonnektedDestination.settingsAt(LokalSettingsGroup.themeAccent),
      ),
    );
    // Flow uses its own scrolling surface while sharing the Home header.
    if (_tab == KonnektedHomeTab.flow) {
      return SafeArea(
        bottom: false,
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverToBoxAdapter(child: topBar),
          ],
          body: const FlowScreen(embedded: true),
        ),
      );
    }
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        notificationPredicate: (notification) =>
            _tab == KonnektedHomeTab.local && notification.depth == 0,
        onRefresh: () async {
          ref.read(konnektedMixRefreshProvider.notifier).refresh();
          await ref.read(konnektedMixesProvider.future);
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          key: const PageStorageKey('konnekted-listen'),
          slivers: [
            SliverToBoxAdapter(child: topBar),
            if (_tab == KonnektedHomeTab.discovery)
              SliverToBoxAdapter(
                child: KonnektedDiscoveryView(
                  onNavigate: onNavigate,
                  onPlay: onPlay,
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: KonnektedCoverFlowSection(onPlay: onPlay),
              ),
              SliverToBoxAdapter(
                child: library.when(
                  skipLoadingOnReload: true,
                  skipError: true,
                  loading: () => const KonnektedLoading(),
                  error: (_, _) => KonnektedMessage(
                    title: lokalText('Your library needs another look'),
                    message: lokalText(
                      'We couldn’t load your music. Try again, or check your music folders in Library.',
                    ),
                    icon: Icons.cloud_off_rounded,
                    actionLabel: 'Try again',
                    onAction: () => ref.invalidate(songsProvider),
                  ),
                  data: (songs) => songs.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: KonnektedMessage(
                            title: lokalText('Make room for your favorites'),
                            message: lokalText(
                              'Add a music folder to start your collection. Your albums, favorites, and listening history will live here.',
                            ),
                            icon: Icons.library_music_rounded,
                            actionLabel: 'Add your music',
                            onAction: () => onNavigate(_addMusic),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              SliverToBoxAdapter(
                child: KonnektedYourMixes(
                  mixes: ref.watch(konnektedMixesProvider).value ?? const [],
                  onPlay: onPlay,
                ),
              ),
              SliverToBoxAdapter(
                child: KonnektedSongShelf(
                  title: lokalText('On repeat, lately'),
                  songs: ref.watch(konnektedRecentSongsProvider),
                  emptyTitle: 'Your next listen starts a story',
                  emptyMessage: 'The music you play will appear here. Pick something from your library to begin.',
                  onSeeAll: () =>
                      onNavigate(KonnektedDestination.recentlyPlayed),
                  onRetry: () => ref.invalidate(konnektedRecentSongsProvider),
                  onPlay: onPlay,
                ),
              ),
              SliverToBoxAdapter(
                child: KonnektedSongShelf(
                  title: lokalText('Close to your heart'),
                  songs: ref.watch(konnektedFavoritesProvider),
                  emptyTitle: 'Keep the songs you love close',
                  emptyMessage:
                      'Tap the heart in the player to build your favorites.',
                  onSeeAll: () => onNavigate(KonnektedDestination.favorites),
                  onRetry: () => ref.invalidate(favoritesProvider),
                  onPlay: onPlay,
                ),
              ),
            ],
            // The shell already provides the dock's full clearance through
            // MediaQuery.padding.bottom. Add only a small visual margin.
            SliverToBoxAdapter(
              child: SizedBox(
                key: const Key('home-bottom-clearance'),
                height: 12 + MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home's top bar: the Lokal logo and glass buttons floating over content.
class KonnektedHomeTopBar extends StatelessWidget {
  const KonnektedHomeTopBar({
    super.key,
    required this.onSettings,
    required this.onAppearance,
    this.selectedTab = KonnektedHomeTab.local,
    this.onTabChanged,
    this.greeting,
    this.now,
  });

  final VoidCallback onSettings;

  /// Opens Appearance, from the logo.
  final VoidCallback onAppearance;
  final KonnektedHomeTab selectedTab;
  final ValueChanged<KonnektedHomeTab>? onTabChanged;

  /// The personal line under the salutation; a time-of-day line until
  /// history has loaded.
  final LokalHomeMessages? greeting;

  /// The clock, for tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final at = now ?? DateTime.now();
    return Padding(
      padding: konnektedTopBarPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: konnektedHeaderHeight(context),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 44,
                  child: Semantics(
                    button: true,
                    label: lokalText('Appearance'),
                    excludeSemantics: true,
                    onTap: onAppearance,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onAppearance();
                      },
                      child: const Center(child: LokalLogo(size: 32)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _HomeModeSelector(
                    selectedTab: selectedTab,
                    onTabChanged: onTabChanged,
                  ),
                ),
                const SizedBox(width: 8),
                KonnektedHeaderActions(onSettings: onSettings),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Desktop's greeting: a salutation, then a line from your listening.
          Semantics(
            header: true,
            child: Text(
              lokalText(
                (greeting ?? lokalHomeMessages(const [], now: at)).headline,
              ),
              style: TextStyle(
                fontSize: context.responsiveText(34),
                fontWeight: FontWeight.w600,
                letterSpacing: -.7,
                color: context.lokal.text,
              ),
            ),
          ),
          const SizedBox(height: 2),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Text(
              lokalText(
                (greeting ?? lokalHomeMessages(const [], now: at)).subheader,
              ),
              key: ValueKey(greeting),
              style: TextStyle(
                fontSize: context.responsiveText(15),
                color: context.lokal.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single balanced Home mode control. Discovery's longer label receives
/// more width, while a truly narrow header scrolls instead of squeezing all
/// three labels into indistinguishable boxes.
class _HomeModeSelector extends StatefulWidget {
  const _HomeModeSelector({
    required this.selectedTab,
    required this.onTabChanged,
  });

  final KonnektedHomeTab selectedTab;
  final ValueChanged<KonnektedHomeTab>? onTabChanged;

  @override
  State<_HomeModeSelector> createState() => _HomeModeSelectorState();
}

class _HomeModeSelectorState extends State<_HomeModeSelector> {
  static const _selectorMinWidth = 196.0;
  static const _segmentGap = 4.0;

  bool _revealScheduled = false;
  final _segmentKeys = {
    for (final tab in KonnektedHomeTab.values) tab: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    _revealSelection();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _revealSelection();
  }

  @override
  void didUpdateWidget(covariant _HomeModeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedTab != widget.selectedTab) _revealSelection();
  }

  void _revealSelection() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted) return;
      final selected = _segmentKeys[widget.selectedTab]?.currentContext;
      if (selected == null) return;
      // Only scroll the compact horizontal control; never shift the Home page
      // vertically when the user changes modes.
      final scrollable = Scrollable.maybeOf(selected);
      final object = selected.findRenderObject();
      if (scrollable == null ||
          scrollable.position.axis != Axis.horizontal ||
          object == null) {
        return;
      }
      scrollable.position.ensureVisible(
        object,
        alignment: .5,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Widget _segment(KonnektedHomeTab tab) => _ShelfChip(
    key: _segmentKeys[tab],
    indicatorKey: ValueKey('home-mode-indicator-${tab.name}'),
    label: lokalText(tab.label),
    selected: tab == widget.selectedTab,
    onTap: () => widget.onTabChanged?.call(tab),
  );

  Widget _segments({Map<KonnektedHomeTab, double>? scrollWidths}) => Row(
    mainAxisSize: scrollWidths == null ? MainAxisSize.max : MainAxisSize.min,
    children: [
      for (final tab in KonnektedHomeTab.values) ...[
        if (tab != KonnektedHomeTab.values.first)
          const SizedBox(width: _segmentGap),
        if (scrollWidths != null)
          SizedBox(width: scrollWidths[tab], child: _segment(tab))
        else
          Expanded(
            flex: tab == KonnektedHomeTab.discovery ? 16 : 10,
            child: _segment(tab),
          ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      var minWidth = _selectorMinWidth;
      final scrollWidths = <KonnektedHomeTab, double>{};
      var contentWidth = 14.0;
      for (final tab in KonnektedHomeTab.values) {
        final painter = TextPainter(
          text: TextSpan(
            text: lokalText(tab.label).toUpperCase(),
            style: LokalTheme.label(
              context.lokal,
              size: 11,
            ).copyWith(fontWeight: FontWeight.w700, letterSpacing: .6),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final required = (painter.width + 12).clamp(44.0, double.infinity);
        scrollWidths[tab] = required;
        contentWidth += required;
        painter.dispose();
      }
      if (contentWidth > minWidth) minWidth = contentWidth;
      final needsScroll = constraints.maxWidth < minWidth;
      return SizedBox(
        width: constraints.maxWidth,
        height: 44,
        child: LokalGlass.capsule(
          thickness: LokalGlassThickness.thin,
          shadow: false,
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: needsScroll
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: _segments(scrollWidths: scrollWidths),
                )
              : _segments(),
        ),
      );
    },
  );
}

/// Local Cover Flow. One tap plays the selected album with the shelf queued.
class KonnektedCoverFlowSection extends ConsumerStatefulWidget {
  const KonnektedCoverFlowSection({super.key, required this.onPlay});

  final void Function(Song song, List<Song> shelf) onPlay;

  @override
  ConsumerState<KonnektedCoverFlowSection> createState() =>
      _KonnektedCoverFlowSectionState();
}

class _KonnektedCoverFlowSectionState
    extends ConsumerState<KonnektedCoverFlowSection> {
  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final list =
        ref.watch(konnektedCoverAlbumsProvider).value ?? const <AlbumGroup>[];
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        const SizedBox(height: 18),
        LokalCoverFlow(
          // Match desktop: land on the middle pick, not the first. Recreate
          // the flow if the shelf length changes so the initial index updates.
          key: ValueKey(list.length),
          initialIndex: list.length ~/ 2,
          albums: list,
          onPlay: widget.onPlay,
          onSelect: (i) =>
              widget.onPlay(list[i].coverSong ?? list[i].songs.first, [
                // Cover Flow is a shelf of recommended tracks. Expanding each
                // card's back must not turn a front-face tap into a queue of
                // every album (nor duplicate songs across featured covers).
                for (final entry in list) entry.coverSong ?? entry.songs.first,
              ]),
          cover: (entry) {
            final placeholder = Container(
              color: t.surface3,
              alignment: Alignment.center,
              child: Icon(Icons.music_note_rounded, color: t.muted, size: 56),
            );
            return CachedImageWidget(
              imagePath: (entry.coverSong ?? entry.songs.first).albumArt,
              audioSourcePath: (entry.coverSong ?? entry.songs.first).filePath,
              fit: BoxFit.cover,
              placeholder: placeholder,
              errorWidget: placeholder,
            );
          },
        ),
      ],
    );
  }
}

class _ShelfChip extends StatelessWidget {
  const _ShelfChip({
    super.key,
    required this.indicatorKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key indicatorKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Center(
            child: AnimatedContainer(
              key: indicatorKey,
              height: 36,
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                color: selected
                    ? (t.isLight
                          ? Colors.black.withValues(alpha: .08)
                          : Colors.white.withValues(alpha: .14))
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                textAlign: TextAlign.center,
                style:
                    LokalTheme.label(
                      t,
                      size: 11,
                      color: selected ? t.text : t.muted,
                    ).copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: .6,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class KonnektedSongShelf extends StatelessWidget {
  const KonnektedSongShelf({
    super.key,
    required this.title,
    required this.songs,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.onSeeAll,
    required this.onRetry,
    required this.onPlay,
  });

  final String title;
  final AsyncValue<List<Song>> songs;
  final String emptyTitle;
  final String emptyMessage;
  final VoidCallback onSeeAll;
  final VoidCallback onRetry;
  final void Function(Song, List<Song>) onPlay;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      KonnektedSectionHeading(title: title, onSeeAll: onSeeAll),
      songs.when(
        skipLoadingOnReload: true,
        skipError: true,
        loading: () => KonnektedLoading(
          label: lokalText("Loading {arg0}", args: {'arg0': title}),
        ),
        error: (_, _) => KonnektedMessage(
          title: lokalText('Couldn’t load this shelf'),
          message: lokalText(
            'Your music is still yours. Try loading this section again.',
          ),
          actionLabel: 'Try again',
          onAction: onRetry,
          icon: Icons.refresh_rounded,
        ),
        data: (items) {
          if (items.isEmpty) {
            return KonnektedMessage(title: emptyTitle, message: emptyMessage);
          }
          final scale = MediaQuery.textScalerOf(context);
          final width = MediaQuery.sizeOf(context).width < 360 ? 142.0 : 164.0;
          final height =
              width + scale.scale(14) * 2.6 + scale.scale(12) * 1.5 + 24;
          return SizedBox(
            height: height,
            child: ListView.separated(
              key: PageStorageKey('shelf-$title'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: items.length > 12 ? 12 : items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final song = items[index];
                return SizedBox(
                  width: width,
                  child: Semantics(
                    button: true,
                    label: lokalText(
                      "Play {arg0} by {arg1}",
                      args: {'arg0': song.title, 'arg1': song.artist},
                    ),
                    onTap: () => onPlay(song, items),
                    onLongPressHint: 'Song actions',
                    onLongPress: () =>
                        SongActionsBottomSheet.show(context, song),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => onPlay(song, items),
                      onLongPress: () =>
                          SongActionsBottomSheet.show(context, song),
                      excludeFromSemantics: true,
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            KonnektedArtwork(
                              song: song,
                              size: width,
                              radius: 16,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              song.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.3,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: context.lokal.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    ],
  );
}

class KonnektedArtwork extends StatelessWidget {
  const KonnektedArtwork({
    super.key,
    required this.song,
    required this.size,
    this.radius = 10,
  });

  final Song song;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: context.lokal.surface3,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note_rounded,
        color: context.lokal.accent,
        size: size * .35,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedImageWidget(
        imagePath: song.albumArt,
        audioSourcePath: song.filePath,
        width: size,
        height: size,
        useThumbnail: true,
        placeholder: placeholder,
        errorWidget: placeholder,
      ),
    );
  }
}

/// Your Mixes: the first six as cards in two columns, each a collage of
/// its covers, as on desktop. A tap plays the mix from the top.
class KonnektedYourMixes extends StatelessWidget {
  const KonnektedYourMixes({
    super.key,
    required this.mixes,
    required this.onPlay,
  });

  final List<LokalMix> mixes;
  final void Function(Song song, List<Song> queue) onPlay;

  @override
  Widget build(BuildContext context) {
    if (mixes.isEmpty) return const SizedBox.shrink();
    final shown = mixes.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KonnektedSectionHeading(
          title: lokalText('Your Mixes'),
          icon: Icons.radio_rounded,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.maxWidth - 14) / 2;
              return Wrap(
                spacing: 14,
                runSpacing: 18,
                children: [
                  for (final mix in shown)
                    SizedBox(
                      width: width,
                      child: _MixCard(mix: mix, onPlay: onPlay),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MixCard extends StatelessWidget {
  const _MixCard({required this.mix, required this.onPlay});

  final LokalMix mix;
  final void Function(Song song, List<Song> queue) onPlay;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    void play() {
      HapticFeedback.lightImpact();
      onPlay(mix.tracks.first, mix.tracks);
    }

    return Semantics(
      button: true,
      label: lokalText(
        "Play {arg0}, {arg1} songs",
        args: {'arg0': mix.title, 'arg1': mix.tracks.length},
      ),
      excludeSemantics: true,
      onTap: play,
      child: InkWell(
        onTap: play,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: KonnektedMixArt(songs: mix.tracks),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              mix.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              lokalText("{arg0} songs", args: {'arg0': mix.tracks.length}),
              style: TextStyle(fontSize: 12, color: t.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// A mix's cover: four of its album covers in a square, or the one cover it
/// has, or a radio glyph.
class KonnektedMixArt extends StatelessWidget {
  const KonnektedMixArt({super.key, required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final covers = <String, Song>{};
    for (final song in songs) {
      final key =
          song.albumArt ??
          '${song.album ?? song.title}|${song.albumArtist ?? song.artist}';
      covers.putIfAbsent(key, () => song);
      if (covers.length == 4) break;
    }
    final placeholder = Container(
      color: t.surface3,
      alignment: Alignment.center,
      child: Icon(Icons.radio_rounded, color: t.muted, size: 36),
    );
    Widget art(Song song) => CachedImageWidget(
      imagePath: song.albumArt,
      audioSourcePath: song.filePath,
      fit: BoxFit.cover,
      useThumbnail: true,
      placeholder: placeholder,
      errorWidget: placeholder,
    );
    final list = covers.values.toList();
    if (list.isEmpty) return placeholder;
    if (list.length < 4) return SizedBox.expand(child: art(list.first));
    return Column(
      children: [
        for (final row in [list.sublist(0, 2), list.sublist(2, 4)])
          Expanded(
            child: Row(
              children: [
                for (final song in row)
                  Expanded(child: SizedBox.expand(child: art(song))),
              ],
            ),
          ),
      ],
    );
  }
}
