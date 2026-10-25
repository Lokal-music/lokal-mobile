import 'package:flick/core/theme/lokal_performance_scope.dart';
import 'dart:io';
import 'package:flick/features/player/widgets/full_player_visuals.dart';
import 'package:flick/features/player/widgets/full_bleed_artwork_frame.dart';
import 'package:flick/features/player/widgets/full_player_identity_layout.dart';

import '../widgets/artist_credit_links.dart';
import 'package:flick/widgets/common/overflow_marquee_title.dart';

import 'package:flick/core/theme/lokal_appearance.dart';

import '../widgets/lyrics_source_button.dart';
import '../widgets/player_panel_stage.dart';
import '../widgets/motion_art_widget.dart';

import 'package:flick/services/motion_art/moving_cover_settings.dart';

import '../widgets/player_transport_controls.dart';
import '../widgets/artwork_gradient_backdrop.dart';
import '../widgets/artwork_mesh_blur_backdrop.dart';
import '../widgets/lyric_motion_line.dart';
import '../widgets/material_player_thumb.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flick/features/appearance/lokal_performance_advisor.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/player/widgets/song_stage_carousel.dart';
import 'package:flick/features/player/widgets/player_artwork_image.dart';
import 'package:flick/features/queue/screens/queue_screen.dart';
import 'package:flick/widgets/lokal/lokal_like_burst.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/widgets/lokal/lokal_player_artwork.dart';
import 'package:flick/widgets/lokal/lokal_pull_to_dismiss.dart';
import 'package:flick/widgets/lokal/lokal_quality.dart';
import 'package:flick/services/catalogue_quality.dart';
import 'package:flick/widgets/lokal/lokal_queue_reveal.dart';
import 'package:flick/features/player/widgets/loop_mode_sheet.dart';
import 'package:flick/features/player/widgets/online_lyrics_search_sheet.dart';

import '../widgets/lyrics_subline_buttons.dart';

import 'package:flick/features/player/widgets/shuffle_mode_sheet.dart';
import 'package:flick/features/player/widgets/sleep_timer_bottom_sheet.dart';
import 'package:flick/features/player/widgets/pitch_bottom_sheet.dart';
import 'package:flick/features/konnekted/library/lokal_navigation.dart';
import 'package:flick/features/player/widgets/song_metadata_sheet.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/features/player/widgets/speed_bottom_sheet.dart';
import 'package:flick/features/settings/screens/casting_settings_screen.dart';
import 'package:flick/features/settings/screens/equalizer_screen.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/models/shuffle_mode.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/lyrics_playback_prefetch.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/player_volume_control.dart';

import '../widgets/android_output_chooser.dart';

const String _font = 'GoogleSansFlex';

/// Wave player: fluid artwork backdrop, big art, flowing lyrics, and labeled
/// action chips. The same constructor keeps the mini-player and navigation
/// entry points working with this player.
class FullPlayerScreen extends ConsumerStatefulWidget {
  final Object heroTag;
  const FullPlayerScreen({super.key, this.heroTag = 'album_art_hero'});

  @override
  ConsumerState<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends ConsumerState<FullPlayerScreen>
    with TickerProviderStateMixin {
  final PlayerService _player = PlayerService();
  final LyricsService _lyricsService = LyricsService();

  bool _showLyrics = false;
  bool _lyricsLoading = false;
  String _lyricsSource = 'auto';
  int _lyricsRequest = 0;
  LyricsData? _lyrics;
  LyricsData? _sublineLyrics;
  String? _lyricsForSongId;

  bool _isFav = false;
  String? _favForSongId;

  late final PlayerVolumeControl _volumeControl;
  double _volume = 1.0;
  bool _draggingSeek = false;
  double _seekDrag = 0;
  bool _draggingVolume = false;

  bool _carouselDragging = false;
  final _carouselKey = GlobalKey<SongStageCarouselState>();
  final _playerBoundsKey = GlobalKey();
  final _posterAnchorKey = GlobalKey();
  final _infoAnchorKey = GlobalKey();
  double? _posterBottom;
  bool _posterMeasurePending = false;

  void _measurePoster() {
    if (_posterMeasurePending) return;
    _posterMeasurePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _posterMeasurePending = false;
      if (!mounted || _showLyrics || _queue.engaged) return;
      final slot = _posterAnchorKey.currentContext?.findRenderObject();
      final info = _infoAnchorKey.currentContext?.findRenderObject();
      final frame = _playerBoundsKey.currentContext?.findRenderObject();
      if (slot is! RenderBox ||
          info is! RenderBox ||
          frame is! RenderBox ||
          !slot.hasSize ||
          !info.hasSize) {
        return;
      }
      // End the poster dissolve below the actual artist/quality row.
      final bottom = math.max(
            slot.localToGlobal(Offset(0, slot.size.height), ancestor: frame).dy,
            info.localToGlobal(Offset(0, info.size.height), ancestor: frame).dy,
          ) +
          8;
      if (_posterBottom == null || (_posterBottom! - bottom).abs() > .5) {
        setState(() => _posterBottom = bottom);
      }
    });
  }

  /// The queue opens in place: the cover shrinks into a header row and the
  /// list rises under it, all off this one value (0 = player, 1 = queue).
  late final AnimationController _queueProgress = AnimationController(
    vsync: this,
  );
  late final LokalQueueRevealMotion _queue = LokalQueueRevealMotion(
    _queueProgress,
  )..addListener(_onQueueTargetChanged);

  late final AnimationController _lyricsProgress = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  bool _canvasHidden = false;
  String? _canvasReadyForSong;
  late final _canvasChrome = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 250),
  );

  bool _motionEnabled(Song song) {
    final prefs = ref.watch(appPreferencesProvider);
    return prefs.animatedAlbumArt &&
        prefs.animationsEnabled &&
        !ref
            .watch(movingCoverSettingsProvider)
            .disabledSongs
            .contains(movingCoverSongKey(song));
  }

  void _restoreCanvasControls() {
    if (_canvasHidden) setState(() => _canvasHidden = false);
    _canvasChrome.forward();
  }

  void _reportCanvas(String songId, bool available) {
    final desired = available ? songId : null;
    if (_canvasReadyForSong == desired) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _player.currentSongNotifier.value?.id != songId ||
          _canvasReadyForSong == desired)
        return;
      setState(() => _canvasReadyForSong = desired);
      if (!available) _restoreCanvasControls();
    });
  }

  void _toggleCanvasControls() {
    setState(() => _canvasHidden = !_canvasHidden);
    _canvasHidden ? _canvasChrome.reverse() : _canvasChrome.forward();
  }

  int _burst = 0;
  bool _burstVisible = false;

  @override
  void initState() {
    super.initState();
    LokalPerformanceAdvisor.enterPlayerSurface('modern-full-player');
    _volumeControl = PlayerVolumeControl(_player);
    _volume = _volumeControl.value;
    _player.currentSongNotifier.addListener(_onSongChanged);
    _player.favoriteNotificationToggleNotifier.addListener(_refreshFavorite);
    _refreshFavorite();
  }

  @override
  void dispose() {
    LokalPerformanceAdvisor.exitPlayerSurface('modern-full-player');
    _volumeControl.dispose();
    _queue.dispose();
    _queueProgress.dispose();
    _lyricsProgress.dispose();
    _canvasChrome.dispose();
    _player.currentSongNotifier.removeListener(_onSongChanged);
    _player.favoriteNotificationToggleNotifier.removeListener(_refreshFavorite);
    super.dispose();
  }

  void _onSongChanged() {
    _canvasReadyForSong = null;
    _restoreCanvasControls();
    _draggingSeek = false;
    _refreshFavorite();
    if (_showLyrics) _loadLyrics();
  }

  Future<void> _refreshFavorite() async {
    final song = _player.currentSongNotifier.value;
    if (song == null) return;
    // Notification toggles write through PlayerService's separate service.
    // Use a fresh reader to avoid a stale per-instance favorites cache.
    final fav = await FavoritesService().isFavorite(song.id);
    if (!mounted || _player.currentSongNotifier.value?.id != song.id) return;
    setState(() {
      _isFav = fav;
      _favForSongId = song.id;
    });
  }

  Future<void> _toggleFavorite() async {
    final song = _player.currentSongNotifier.value;
    if (song == null) return;
    AppHaptics.selection();
    // Update the shared favorites provider: the Liked library folder watches
    // this provider, while a direct FavoritesService call left it stale.
    final nowFav = await ref.read(favoritesProvider.notifier).toggleFavorite(song.id, song: song);
    if (!mounted) return;
    setState(() {
      _isFav = nowFav;
      _favForSongId = song.id;
    });
  }

  Future<void> _loadLyrics({
    bool force = false,
    bool refreshOnline = false,
  }) async {
    final song = _player.currentSongNotifier.value;
    if (song == null) return;
    if (!force && _lyricsForSongId == song.id && _lyrics != null) return;
    final request = ++_lyricsRequest;
    setState(() {
      _lyricsLoading = true;
      if (_lyricsForSongId != song.id) _lyrics = null;
      _lyricsForSongId = song.id;
    });
    _sublineLyrics = null;
    final warm = !force && !refreshOnline && _lyricsSource == 'auto';
    try {
      // Display local sidecar/embedded lyrics as soon as filesystem lookup
      // completes; never gate them on LRCLIB / remote lyric providers.
      final local = warm
          ? await LyricsPlaybackPrefetch.instance.local(song)
          : await _lyricsService.loadLyricsForSong(
              song, forceRefresh: force, fetchOnline: false,
              source: _lyricsSource,
            );
      if (!mounted || request != _lyricsRequest ||
          _player.currentSongNotifier.value?.id != song.id) return;
      setState(() {
        _lyrics = local;
        _lyricsLoading = local == null;
      });
      final best = warm
          ? await LyricsPlaybackPrefetch.instance.enhanced(song)
          : await _lyricsService.loadLyricsForSong(
              song, forceRefresh: force, refreshOnline: refreshOnline,
              source: _lyricsSource,
              stillCurrent: () => mounted && request == _lyricsRequest,
              fetchOnline: refreshOnline ||
                  ref.read(appPreferencesProvider).lyricsAutoFetch,
            );
      if (!mounted || request != _lyricsRequest ||
          _player.currentSongNotifier.value?.id != song.id) return;
      setState(() {
        if (lyricQualityRank(best) > lyricQualityRank(_lyrics)) {
          _lyrics = best;
        } else if (_lyrics == null) {
          _lyrics = best;
        }
        _lyricsLoading = false;
      });
    } catch (_) {
      if (mounted && request == _lyricsRequest) {
        setState(() => _lyricsLoading = false);
      }
    }
  }

  void _moveLyrics(bool open) {
    _restoreCanvasControls();
    setState(() => _showLyrics = open);
    final target = open ? 1.0 : 0.0;
    if (!_animate) {
      _lyricsProgress.value = target;
    } else {
      _lyricsProgress.animateTo(target, curve: Curves.easeInOutCubicEmphasized);
    }
    if (open) unawaited(_loadLyrics());
  }

  void _toggleLyrics() {
    HapticFeedback.selectionClick();
    if (_showLyrics) {
      // At the lyric pose the hidden queue can reset without moving artwork.
      // Mid-flight, animate it instead so a rapid reversal stays continuous.
      _queue.setOpen(false, animate: _animate && _lyricsProgress.value < .999);
      _moveLyrics(false);
    } else {
      _queueProgress.stop();
      _moveLyrics(true);
    }
  }

  void _onQueueTargetChanged() {
    if (mounted) setState(() {});
  }

  bool get _animate => !MediaQuery.disableAnimationsOf(context);

  void _setQueueOpen(bool open) {
    if (open == _queue.isOpen && !_showLyrics) return;
    HapticFeedback.selectionClick();
    _queue.setOpen(open, animate: _animate && _lyricsProgress.value < .999);
    if (_showLyrics) _moveLyrics(false);
  }

  void _toggleQueue() => _setQueueOpen(_showLyrics || !_queue.isOpen);

  void _releaseQueue(double upVelocity) {
    final was = _queue.isOpen;
    if (_queue.release(upVelocity, animate: _animate) != was) {
      HapticFeedback.selectionClick();
    }
  }

  void _close() => Navigator.of(context).pop();

  // ───────────────────────────── gestures ─────────────────────────────

  /// Double-tapping the artwork likes the song (never unlikes it), with a
  /// burst over the cover.
  void _likeFromArtwork() {
    HapticFeedback.mediumImpact();
    setState(() {
      _burst++;
      _burstVisible = true;
    });
    if (!_isFav) _toggleFavorite();
  }

  Future<void> _openEqualizer() => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const EqualizerScreen()));

  Future<void> _openCasting() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const CastingSettingsScreen()),
  );

  /// The Now Playing menu retains only actions that aren't already surfaced
  /// as player controls or as taps on the track title, artist, and quality pill.
  void _openMore(Song song) {
    SongActionsBottomSheet.show(
      context,
      song,
      nowPlaying: true,
      extras: [
        LokalSongMenuAction(
          icon: Icons.graphic_eq_rounded,
          label: 'Pitch',
          onTap: () {
            if (mounted) PitchBottomSheet.show(context, _player);
          },
        ),
      ],
    );
  }

  // ───────────────────────────── build ─────────────────────────────

  @override
  Widget build(BuildContext context) {
    final palette = ref.watch(albumPaletteSyncProvider);
    final dominant = ref.watch(albumDominantColorSyncProvider);
    final isCasting = ref.watch(isCastingProvider);
    final diagnostics = ref.watch(audioOutputDiagnosticsProvider);
    final colors = palette.length >= 2
        ? palette
        : [
            dominant ?? const Color(0xFF3B3B44),
            HSLColor.fromColor(dominant ?? const Color(0xFF3B3B44))
                .withLightness(0.3)
                .toColor(),
            const Color(0xFF14141A),
          ];

    return PopScope(
      // Back puts the queue or the lyrics away first, then closes the player.
      canPop: !_showLyrics && !_queue.isOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showLyrics) {
          _toggleLyrics();
        } else if (_queue.isOpen) {
          _setQueueOpen(false);
        }
      },
      child: LokalPullToDismiss(
        onDismiss: _close,
        // Pulling up drags the queue in, following the finger.
        onPullUpUpdate: _showLyrics ? null : _queue.dragBy,
        onPullUpEnd: _showLyrics ? null : _releaseQueue,
        // While the queue is out, its header owns vertical drags.
        isBlocked: () => _carouselDragging || _queue.engaged,
        child: _scaffold(colors, isCasting, diagnostics),
      ),
    );
  }

  Widget _scaffold(
    List<Color> colors,
    bool isCasting,
    AudioOutputDiagnostics? diagnostics,
  ) {
    final fullCover = ref.watch(
      lokalAppearanceProvider.select((look) => look.fullscreenCover),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: ValueListenableBuilder<Song?>(
        valueListenable: _player.currentSongNotifier,
        builder: (context, song, _) {
          if (song == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final clearViewAvailable =
              fullCover &&
              _motionEnabled(song) &&
              _canvasReadyForSong == song.id &&
              !_showLyrics &&
              !_queue.engaged;
          final hidden = clearViewAvailable && _canvasHidden;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: clearViewAvailable ? _toggleCanvasControls : null,
            child: Stack(
              key: _playerBoundsKey,
              fit: StackFit.expand,
              children: [
                ArtworkGradientBackdrop(colors: colors, vibrant: true),
                ArtworkMeshBlurBackdrop(
                  song: song,
                  preserveArtworkContrast: fullCover,
                ),
                if (fullCover)
                  FadeTransition(
                    opacity: _canvasChrome,
                    child: const IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x33000000),
                               Color(0x08000000),
                               Color(0x10000000),
                               Color(0x40000000),
                            ],
                            stops: [0, .28, .66, 1],
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  Container(color: Colors.black.withValues(alpha: 0.10)),
                if (fullCover) _fullscreenArtwork(song),
                // Keep the controls, title and quality metadata above the
                // fullscreen Canvas while its artwork travels out of the
                // mini-player. The same chrome continues its sheet motion;
                // the Canvas clear-view toggle still fades this entire tree.
                LokalPlayerChrome(
                  enabled: fullCover,
                  child: IgnorePointer(
                    ignoring: hidden,
                  child: FadeTransition(
                    opacity: _canvasChrome,
                    child: TickerMode(
                      enabled: !hidden,
                      child: SafeArea(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            23,
                            0,
                            23,
                            14, // keeps the chip row clear of the system nav bar
                          ),
                          child: LayoutBuilder(
                            builder: (context, c) {
                              final compact = c.maxHeight < 640;
                              return AnimatedBuilder(
                                animation: _lyricsProgress,
                                builder: (context, _) {
                                  final l = _lyricsProgress.value;
                                  return Column(
                                    children: [
                                      ClipRect(
                                        child: Align(
                                          heightFactor: 1 - l,
                                          alignment: Alignment.topCenter,
                                          child: IgnorePointer(
                                            ignoring: _showLyrics,
                                            child: Opacity(
                                              opacity: 1 - l,
                                              child: _topBar(
                                                song,
                                                isCasting,
                                                diagnostics,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: _panelStage(
                                          song,
                                          compact,
                                          fullCover: fullCover,
                                        ),
                                      ),
                                      _seekRow(),
                                      // The timeline sits above the transport pads,
                                      // rather than being visually glued to them.
                                      SizedBox(height: compact ? 12 : 24),
                                      SizedBox(
                                        height: lerpDouble(
                                          compact ? 6 : 10,
                                          6,
                                          l,
                                        ),
                                      ),
                                      _transport(compact, l),
                                      ClipRect(
                                        child: Align(
                                          heightFactor: 1 - l,
                                          alignment: Alignment.topCenter,
                                          child: IgnorePointer(
                                            ignoring: _showLyrics,
                                            child: Opacity(
                                              opacity: 1 - l,
                                              child: Padding(
                                                padding: EdgeInsets.only(
                                                  top: compact ? 13 : 17,
                                                ),
                                                child: _optionsStrip(),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      SizedBox(height: compact ? 13 : 17),
                                      _chipRow(),
                                    ],
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ───────────────────────────── top bar ─────────────────────────────

  Widget _topBar(
    Song song, bool isCasting, AudioOutputDiagnostics? diagnostics,
  ) {
    final label = diagnostics?.outputDeviceLabel.trim().isNotEmpty == true
        ? diagnostics!.outputDeviceLabel.trim()
        : diagnostics?.routeLabel.trim().isNotEmpty == true
        ? diagnostics!.routeLabel.trim()
        : l10n.thisDevice;
    final route = diagnostics?.routeType.toLowerCase() ?? '';
    // Android reports 'bluetooth' for multiple physical device classes.
    // Prefer the output's actual product name instead of a connection icon.
    final deviceName = [
      diagnostics?.outputDeviceLabel ?? '',
      diagnostics?.routeLabel ?? '',
    ].join(' ').toLowerCase();
    final isSpeaker = RegExp(
      r'speaker|soundbar|boombox|homepod|soundlink|flip |charge |boom ',
    ).hasMatch(deviceName);
    final isHeadset = RegExp(
      r'earbud|earphone|airpod|buds|headphone|headset|freebuds|tws|'
      r'wh-|wf-|quietcomfort|momentum|tour pro|fokus',
    ).hasMatch(deviceName);
    final outputIcon = isCasting
        ? LucideIcons.cast
        : route == 'internal' || route == 'speaker'
            ? LucideIcons.speaker
            : route == 'bluetooth'
                ? isSpeaker
                    ? LucideIcons.speaker
                    : isHeadset
                        ? LucideIcons.headphones
                        : LucideIcons.bluetooth
                : route == 'usb' || route == 'dock'
                    ? LucideIcons.usb
                    : LucideIcons.headphones;
    final displayLabel = isCasting
        ? label
        : route == 'internal' || route == 'speaker'
            ? lokalText('Speaker')
            : label == 'Device DAC'
                ? lokalText('Speaker')
                : label;
    return SizedBox(
      height: 58,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(alignment: Alignment.centerLeft,
            child: _roundIcon(LucideIcons.chevronLeft, _close)),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 215),
              child: _pill(
                onTap: () => openAndroidOutputChooser(context),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(outputIcon, size: 17,
                        color: FullPlayerVisuals.primaryText),
                    const SizedBox(width: 8),
                    Flexible(child: Text(displayLabel,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: _font, fontSize: 13,
                          color: FullPlayerVisuals.primaryText))),
                  ],
                ),
              ),
            ),
          ),
          Align(alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _roundIcon(LucideIcons.cast, _openCasting, active: isCasting),
              _roundIcon(Icons.more_vert, () => _openMore(song)),
            ])),
        ],
      ),
    );
  }

  Widget _roundIcon(IconData icon, VoidCallback onTap, {bool active = false}) {
    return Material(
      color: active ? Colors.white.withValues(alpha: 0.26) : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 22, color: Colors.white),
        ),
      ),
    );
  }

  Widget _pill({
    required Widget child,
    VoidCallback? onTap,
    bool selected = false,
    bool compact = false,
  }) {
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: FullPlayerVisuals.border,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 12, vertical: 9),
          child: child,
        ),
      ),
    );
  }

  // ───────────────────────────── artwork / lyrics ─────────────────────────────

  Widget _fullscreenArtwork(Song song) {
    final motion = _motionEnabled(song);
    return AnimatedBuilder(
      animation: Listenable.merge([_queueProgress, _lyricsProgress]),
      builder: (context, _) {
        final progress =
            (_lyricsProgress.value +
                    _queueProgress.value * (1 - _lyricsProgress.value))
                .clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: _showLyrics || _queue.engaged,
          child: Opacity(
            opacity: 1 - progress,
            child: TickerMode(
              enabled: progress < 1,
              child: ValueListenableBuilder<List<Song>>(
                valueListenable: _player.upNextNotifier,
                builder: (context, _, __) => ValueListenableBuilder<int>(
                  valueListenable: _player.currentIndexNotifier,
                  builder: (context, _, __) => SongStageCarousel(
                    key: _carouselKey,
                    currentSong: song,
                    nextSong: _player.peekNext,
                    prevSong: _player.peekPrevious,
                    enabled: progress == 0 && !_showLyrics && !_queue.isOpen,
                    onDragStateChanged: (value) {
                      _carouselDragging = value;
                      if (value) _restoreCanvasControls();
                    },
                    onNext: _player.next,
                    onPrevious: _player.previousBySwipe,
                    stageBuilder: (track) {
                      final current = track.id == song.id;
                      final still = PlayerArtworkImage(
                        song: track,
                        radius: 0,
                        crossfade: false,
                      );
                      Widget frame(Widget artwork, bool canvas) {
                        if (current) _reportCanvas(track.id, canvas);
                        return AnimatedBuilder(
                          animation: _canvasChrome,
                          child: artwork,
                          builder: (context, child) => FullBleedArtworkFrame(
                            canvas: canvas,
                            morphEnabled: current,
                            controlsOpacity: canvas ? _canvasChrome.value : 1,
                            bannerBottom: _posterBottom,
                            child: child!,
                          ),
                        );
                      }

                      // Remove the video subtree entirely when disabled; a
                      // retained platform texture must not cover the poster.
                      final content = current && motion
                          ? ValueListenableBuilder<bool>(
                              valueListenable: _player.isPlayingNotifier,
                              builder: (context, playing, _) => MotionArtView(
                                sharedPlaybackKey: 'player:${track.id}',
                                presentationBuilder: (
                                  context,
                                  artwork,
                                  canvas,
                                ) => frame(artwork, canvas),
                                title: track.title,
                                artist: track.artist,
                                album: track.album,
                                duration: track.duration,
                                playbackActive: progress < 1 && playing,
                                borderRadius: BorderRadius.zero,
                                fallback: still,
                              ),
                            )
                          : frame(still, false);
                      final shownBurst = _burst;
                      return GestureDetector(
                        onDoubleTap: current ? _likeFromArtwork : null,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            HeroMode(
                              enabled: current,
                              child: Hero(
                                tag: widget.heroTag,
                                createRectTween: (begin, end) =>
                                    RectTween(begin: begin, end: end),
                                flightShuttleBuilder: (
                                  _,
                                  __,
                                  ___,
                                  ____,
                                  _____,
                                ) => content,
                                child: content,
                              ),
                            ),
                            if (current && _burstVisible)
                              Center(
                                child: LokalLikeBurst(
                                  key: ValueKey(_burst),
                                  color: context.lokal.accent,
                                  size: MediaQuery.sizeOf(context).width * .28,
                                  onDone: () {
                                    if (mounted && shownBurst == _burst)
                                      setState(() => _burstVisible = false);
                                  },
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _panelStage(Song song, bool compact, {bool fullCover = false}) {
    final titleSize = compact ? 25.0 : 29.0;
    return LayoutBuilder(
      builder: (context, c) {
        _queue.travel = math.max(math.min(c.maxWidth, c.maxHeight) * .8, 200);
        return PlayerPanelStage(
          queueProgress: _queueProgress,
          lyricsProgress: _lyricsProgress,
          queueOpen: _queue.isOpen,
          lyricsOpen: _showLyrics,
          artGap: compact ? 10 : 17,
          onQueueHeaderTap: () => _setQueueOpen(false),
          onLyricsCoverReturn: _toggleLyrics,
          onQueueHeaderDrag: _queue.dragBy,
          onQueueHeaderRelease: _releaseQueue,
          artwork: (context, size, p) {
            if (fullCover) {
              // The poster owns the single Hero and carousel in this mode.
              // Only reveal the compact cover while entering lyrics/queue.
              if (p == 0) {
                _measurePoster();
                return SizedBox.expand(key: _posterAnchorKey);
              }
              return IgnorePointer(
                child: HeroMode(
                  enabled: false,
                  child: Opacity(
                    opacity: p,
                    child: _artwork(song, size, current: true, progress: p),
                  ),
                ),
              );
            }
            final atRest = p == 0 && !_queue.isOpen && !_showLyrics;
            return ValueListenableBuilder<List<Song>>(
              valueListenable: _player.upNextNotifier,
              builder: (context, _, __) => ValueListenableBuilder<int>(
                valueListenable: _player.currentIndexNotifier,
                builder: (context, _, __) => SongStageCarousel(
                  key: _carouselKey,
                  currentSong: song,
                  nextSong: _player.peekNext,
                  prevSong: _player.peekPrevious,
                  enabled: atRest,
                  onDragStateChanged: (v) => _carouselDragging = v,
                  onNext: _player.next,
                  onPrevious: _player.previousBySwipe,
                  stageBuilder: (s) => Align(
                    alignment: Alignment.center,
                    child: _artwork(
                      s,
                      size,
                      current: s.id == song.id,
                      progress: p,
                    ),
                  ),
                ),
              ),
            );
          },
          info: (context, p) => SizedBox(
            key: _infoAnchorKey,
            width: double.infinity,
            child: AnimatedSwitcher(
            duration: _animate
                ? const Duration(milliseconds: 420)
                : Duration.zero,
            // Keep both tracks anchored to the same origin. AnimatedSwitcher\'s
            // default ScaleTransition subtly moves title, credits and quality
            // pill as their intrinsic widths differ between providers.
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: child,
            ),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, if (current != null) current],
            ),
            child: FullPlayerIdentityLayout(
              key: ValueKey(song.id),
              titleFontSize: lerpDouble(titleSize, 18, p)!,
              titleToArtistGap: lerpDouble(3, 1, p)!,
              title: Semantics(
                button: true,
                label: 'Open album for ${song.title}',
                child: InkWell(
                  onTap: () => openLokalAlbumForSong(context, song),
                  borderRadius: BorderRadius.circular(8),
                  child: OverflowMarqueeTitle(
                    key: ValueKey('full-title:${song.id}'),
                    title: song.title,
                    style: TextStyle(
                      fontFamily: _font,
                      fontSize: lerpDouble(titleSize, 18, p),
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.55,
                      color: FullPlayerVisuals.primaryText,
                    ),
                  ),
                ),
              ),
              artist: ArtistCreditLinks(
                credit: song.artist,
                onArtistTap: (name) =>
                    openLokalArtist(context, name: name, song: song),
                style: TextStyle(
                  fontFamily: _font,
                  fontSize: lerpDouble(13, 12, p),
                  fontWeight: FontWeight.w500,
                  color: FullPlayerVisuals.secondaryText,
                ),
              ),
              trailing: [
                if (song.year != null && song.year! > 0) ...[
                  const _MetadataDot(),
                  Text(
                    '${song.year}',
                    style: TextStyle(
                      fontFamily: _font,
                      fontSize: lerpDouble(11, 10, p),
                      color: FullPlayerVisuals.tertiaryText,
                    ),
                  ),
                ],
                if (song.atmosEncoded) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => SongMetadataSheet.show(context, song),
                    child: const LokalAtmosStreamPill(),
                  ),
                ],
                if (LokalQualityTier.of(song) case final tier?
                    when !song.atmosEncoded) ...[
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: () => SongMetadataSheet.show(context, song),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: FullPlayerVisuals.secondaryText,
                        ),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        switch (tier) {
                          LokalQualityTier.hiRes => 'HI-RES LOSSLESS',
                          LokalQualityTier.lossless => 'LOSSLESS',
                          LokalQualityTier.high => 'HIGH',
                          LokalQualityTier.low => 'LOW',
                          LokalQualityTier.unknown =>
                              (song.sourcePackage == 'konnekted.progressive' ||
                               song.sourcePackage == 'konnekted.morneye-live')
                                  ? (catalogueStreamTierLabel(
                                        quality: song.resolution,
                                        codec: song.fileType,
                                        bitDepth: song.bitDepth,
                                        sampleRate: song.sampleRate,
                                      ) ?? 'UNKNOWN')
                                  : 'UNKNOWN',
                        },
                        style: const TextStyle(
                          fontFamily: _font,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .6,
                          color: FullPlayerVisuals.primaryText,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          )),
          queue: const QueueList(embedded: true),
          lyrics: _lyricsArea(song),
        );
      },
    );
  }

  Widget _artwork(
    Song song,
    double side, {
    required bool current,
    double progress = 0,
  }) {
    final prefs = ref.watch(appPreferencesProvider);
    final radius = BorderRadius.circular(lerpDouble(20, 12, progress)!);
    final still = PlayerArtworkImage(
      song: song,
      radius: radius.topLeft.x,
      crossfade: false,
    );
    final motionEnabled =
        current &&
        prefs.animatedAlbumArt &&
        prefs.animationsEnabled &&
        !ref
            .watch(movingCoverSettingsProvider)
            .disabledSongs
            .contains(movingCoverSongKey(song));
    final art = ClipRRect(
      borderRadius: radius,
      child: ValueListenableBuilder<bool>(
        valueListenable: _player.isPlayingNotifier,
        builder: (context, playing, _) => MotionArtView(
          sharedPlaybackKey: 'player:${song.id}',
          title: song.title,
          artist: song.artist,
          album: song.album,
          duration: song.duration,
          enabled: motionEnabled,
          playbackActive: current && progress < .999 && playing,
          borderRadius: radius,
          fallback: still,
        ),
      ),
    );
    final shown = _burst;
    return GestureDetector(
      onDoubleTap: current && progress == 0 ? _likeFromArtwork : null,
      child: LokalPlayerArtwork(
        enabled: current,
        child: SizedBox(
          width: side,
          height: side,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: HeroMode(
                  enabled: current,
                  child: Hero(
                    tag: widget.heroTag,
                    createRectTween: (begin, end) =>
                        RectTween(begin: begin, end: end),
                    flightShuttleBuilder:
                        (
                          flightContext,
                          animation,
                          direction,
                          fromContext,
                          toContext,
                        ) => AnimatedBuilder(
                          animation: animation,
                          builder: (context, child) => ClipRRect(
                            borderRadius: BorderRadius.circular(
                              lerpDouble(
                                21,
                                28,
                                Curves.easeInOutCubic.transform(
                                  animation.value,
                                ),
                              )!,
                            ),
                            child: child,
                          ),
                          child: art,
                        ),
                    child: art,
                  ),
                ),
              ),
              if (current && _burstVisible)
                LokalLikeBurst(
                  key: ValueKey(_burst),
                  color: context.lokal.accent,
                  size: side * .28,
                  onDone: () {
                    if (mounted && shown == _burst) {
                      setState(() => _burstVisible = false);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lyricsArea(Song song) {
    final data = _lyrics;
    final display = _sublineLyrics ?? data;
    Widget body;
    if (_lyricsLoading && data == null) {
      body = const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Colors.white70,
          ),
        ),
      );
    } else if (data == null || data.lines.isEmpty) {
      body = _noLyrics(song);
    } else if (!data.isSynchronized) {
      body = SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 24, 0, 40),
        child: Text(
          display!.lines
              .map(
                (l) =>
                    _sublineLyrics != null && l.translation?.isNotEmpty == true
                    ? '${l.text}\n${l.translation}'
                    : l.text,
              )
              .join('\n'),
          style: const TextStyle(
            fontFamily: _font,
            fontSize: 26,
            height: 1.35,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      );
    } else {
      body = _FlowingLyrics(
        key: ValueKey(song.id),
        player: _player,
        lyrics: display!,
        showTranslation: _sublineLyrics != null,
      );
    }

    return Column(
      key: const ValueKey('lyrics'),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Lyrics',
                style: TextStyle(
                  fontFamily: _font,
                  fontSize: 13,
                  letterSpacing: 0.6,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ),
            LyricsSourceButton(
              selected: _lyricsSource,
              lyrics: data,
              busy: _lyricsLoading,
              onSelected: (source) {
                setState(() => _lyricsSource = source);
                unawaited(_loadLyrics(force: true));
              },
              onRefresh: () =>
                  unawaited(_loadLyrics(force: true, refreshOnline: true)),
            ),
            if (data != null)
              LyricsSublineButtons(
                lyrics: data,
                onChanged: (value) => setState(() => _sublineLyrics = value),
              ),
            IconButton(
              tooltip: 'Search online',
              icon: const Icon(
                LucideIcons.search,
                size: 20,
                color: Colors.white70,
              ),
              onPressed: () => _searchOnline(song),
            ),
          ],
        ),
        Expanded(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0.0, 0.07, 0.9, 1.0],
            ).createShader(r),
            child: body,
          ),
        ),
      ],
    );
  }

  Widget _noLyrics(Song song) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No lyrics found',
            style: TextStyle(
              fontFamily: _font,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            onPressed: () => _searchOnline(song),
            icon: const Icon(LucideIcons.search, size: 18),
            label: const Text('Search online'),
          ),
        ],
      ),
    );
  }

  Future<void> _searchOnline(Song song) async {
    final result = await OnlineLyricsSearchSheet.show(
      context: context,
      song: song,
      lyricsService: _lyricsService,
    );
    if (result == true && mounted) await _loadLyrics(force: true);
  }

  String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$sec' : '$m:$sec';
  }

  Widget _seekRow() {
    const mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: FullPlayerVisuals.tertiaryText,
    );
    return ValueListenableBuilder<Duration>(
      valueListenable: _player.durationNotifier,
      builder: (context, duration, _) {
        final totalMs = math.max(duration.inMilliseconds, 1).toDouble();
        return ValueListenableBuilder<Duration>(
          valueListenable: _player.positionNotifier,
          builder: (context, position, _) {
            final live = (position.inMilliseconds / totalMs).clamp(0.0, 1.0);
            final value = _draggingSeek ? _seekDrag : live;
            return Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.5,
                    trackShape: const GappedSliderTrackShape(),
                    trackGap: 5,
                    thumbShape: const MaterialPlayerThumb(),
                    overlayShape: SliderComponentShape.noOverlay,
                    activeTrackColor: FullPlayerVisuals.primaryText,
                    inactiveTrackColor: Colors.white.withValues(alpha: .30),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: value,
                    onChangeStart: (v) => setState(() {
                      _draggingSeek = true;
                      _seekDrag = v;
                    }),
                    onChanged: (v) => setState(() => _seekDrag = v),
                    onChangeEnd: (v) async {
                      // One double-pulse on release, not on continuous drag updates.
                      AppHaptics.doublePulse();
                      final id = _player.currentSongNotifier.value?.id;
                      try {
                        await _player.seek(
                          Duration(milliseconds: (v * totalMs).round()),
                        );
                      } finally {
                        if (mounted &&
                            _player.currentSongNotifier.value?.id == id &&
                            _seekDrag == v)
                          setState(() => _draggingSeek = false);
                      }
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _clock(
                          Duration(milliseconds: (value * totalMs).round()),
                        ),
                        style: mono,
                      ),
                      Text(_clock(duration), style: mono),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _transport(bool compact, double lyricsProgress) =>
      ValueListenableBuilder<bool>(
        valueListenable: _player.isPlayingNotifier,
        builder: (context, playing, _) => PlayerTransportControls(
          compact: compact,
          tallerButtons: true,
          lyricsProgress: lyricsProgress,
          playing: playing,
          accent: FullPlayerVisuals.fromPalette(
            ref.watch(albumPaletteSyncProvider),
          ).play,
          onAccent: Colors.black,
          onPrevious: () =>
              _carouselKey.currentState?.animateToPrevious() ??
              _player.previous(),
          onNext: () =>
              _carouselKey.currentState?.animateToNext() ?? _player.next(),
          onPlayPause: () => _player.togglePlayPause(),
        ),
      );

  Widget _optionsStrip() => ListenableBuilder(
    listenable: _volumeControl,
    builder: (context, _) => _buildOptionsStrip(),
  );

  Widget _buildOptionsStrip() {
    final maxVol = _volumeControl.max;
    final sliderValue = (_draggingVolume ? _volume : _volumeControl.value)
        .clamp(0.0, maxVol)
        .toDouble();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: FullPlayerVisuals.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                trackShape: const GappedSliderTrackShape(),
                trackGap: 5,
                thumbShape: const MaterialPlayerThumb(),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: sliderValue,
                min: 0,
                max: maxVol,
                onChangeStart: (_) => setState(() => _draggingVolume = true),
                onChanged: !_volumeControl.available
                    ? null
                    : (v) {
                        setState(() => _volume = v);
                        unawaited(_volumeControl.set(v));
                      },
                onChangeEnd: (_) => setState(() => _draggingVolume = false),
              ),
            ),
          ),
          const SizedBox(width: 13),
          Icon(
            sliderValue <= 0.001 ? LucideIcons.volumeX : LucideIcons.volume2,
            size: 18,
            color: FullPlayerVisuals.secondaryText,
          ),
          const SizedBox(width: 18),
          Container(
            width: 1,
            height: 26,
            color: FullPlayerVisuals.border,
          ),
          const SizedBox(width: 10),
          ValueListenableBuilder<ShuffleMode>(
            valueListenable: _player.shuffleModeNotifier,
            builder: (_, mode, __) => _toggle(
              LucideIcons.shuffle,
              mode.isActive,
              () => _player.toggleShuffle(),
              onLong: () => ShuffleModeSheet.show(context, _player),
            ),
          ),
          ValueListenableBuilder<LoopMode>(
            valueListenable: _player.loopModeNotifier,
            builder: (_, mode, __) => _toggle(
              mode == LoopMode.one ? LucideIcons.repeat1 : LucideIcons.repeat,
              mode != LoopMode.off,
              () => _player.toggleLoopMode(),
              onLong: () => LoopModeSheet.show(context, _player),
            ),
          ),
          _toggle(
            _isFav ? Icons.favorite : Icons.favorite_border,
            _isFav,
            _toggleFavorite,
          ),
        ],
      ),
    );
  }

  Widget _toggle(
    IconData icon,
    bool on,
    VoidCallback onTap, {
    VoidCallback? onLong,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: on
            ? FullPlayerVisuals.selectedSurface
            : Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: onTap,
          onLongPress: onLong,
          child: SizedBox(
            width: 36,
            height: 40,
            child: Icon(
              icon,
              size: 19,
              color: on ? FullPlayerVisuals.primaryText : FullPlayerVisuals.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  // ───────────────────────────── chips ─────────────────────────────

  Widget _chipRow() {
    Widget chip(
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool active = false,
      double? width,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 2),
        child: SizedBox(
          width: width,
          child: _pill(
          selected: active,
          compact: true,
          onTap: onTap,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 19,
                color: active
                    ? FullPlayerVisuals.primaryText
                    : FullPlayerVisuals.secondaryText,
              ),
              const SizedBox(width: 4),
              Flexible(child: Text(
                label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: _font,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: FullPlayerVisuals.primaryText,
                ),
              )),
            ],
          ),
        )),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          chip(
            LucideIcons.listMusic,
            l10n.queue,
            _toggleQueue,
            active: _queue.isOpen && !_showLyrics,
            width: (constraints.maxWidth - 8) / 4,
          ),
          chip(
            LucideIcons.messageSquareQuote,
            l10n.lyrics,
            _toggleLyrics,
            active: _showLyrics,
            width: (constraints.maxWidth - 8) / 4,
          ),
          ValueListenableBuilder<Duration?>(
            valueListenable: _player.sleepTimerRemainingNotifier,
            builder: (_, remaining, __) => chip(
              LucideIcons.moonStar,
              remaining == null ? lokalText('Sleep') : _clock(remaining),
              () => SleepTimerBottomSheet.show(context, _player),
              active: remaining != null,
              width: (constraints.maxWidth - 8) / 4,
            ),
          ),
          if (_player.currentSongNotifier.value case final song?)
            chip(
              Icons.motion_photos_on_rounded,
              lokalText('Cover'),
              () => ref
                  .read(movingCoverSettingsProvider.notifier)
                  .setSongEnabled(
                    movingCoverSongKey(song),
                    ref
                        .read(movingCoverSettingsProvider)
                        .disabledSongs
                        .contains(movingCoverSongKey(song)),
                  ),
              active: !ref
                  .watch(movingCoverSettingsProvider)
                  .disabledSongs
                  .contains(movingCoverSongKey(song)),
              width: (constraints.maxWidth - 8) / 4,
            ),
          ValueListenableBuilder<double>(
            valueListenable: _player.playbackSpeedNotifier,
            builder: (_, speed, __) => chip(
              LucideIcons.gauge,
              (speed - 1.0).abs() < 0.01
                  ? l10n.speedUp
                  : '${speed.toStringAsFixed(2)}x',
              () => SpeedBottomSheet.show(context, _player),
              active: (speed - 1.0).abs() >= 0.01,
              width: (constraints.maxWidth - 8) / 4,
            ),
          ),
          chip(LucideIcons.slidersHorizontal, l10n.equalizer, _openEqualizer,
            width: (constraints.maxWidth - 8) / 4),
        ],
      ),
    ));
  }
}

class _MetadataDot extends StatelessWidget {
  const _MetadataDot();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 7),
    child: Text('·', style: TextStyle(
      fontSize: 13, color: FullPlayerVisuals.tertiaryText,
    )),
  );
}

// ═════════════════════════════ backdrop ═════════════════════════════

// ═════════════════════════════ flowing lyrics ═════════════════════════════

/// Continuously flowing synced lyrics.
///
/// * One 60 fps ticker drives everything; playback position is extrapolated
///   between the player's position updates so motion never steps.
/// * The scroll offset chases the active line with a critically damped spring
///   (slightly anticipating the next line), so lines glide instead of jumping.
/// * A second smoothed "focus" value drives per-line scale, opacity and blur,
///   so emphasis flows from line to line.
/// * The active line sweeps word by word (real word timing when the lyrics
///   have it, untimed sources keep line-level focus).
/// * Drag to browse (auto-follow resumes after 3 s), tap a line to seek.
class _FlowingLyrics extends StatefulWidget {
  final PlayerService player;
  final LyricsData lyrics;

  /// Each line's translation under it, when it has one.
  final bool showTranslation;
  const _FlowingLyrics({
    super.key,
    required this.player,
    required this.lyrics,
    this.showTranslation = false,
  });

  @override
  State<_FlowingLyrics> createState() => _FlowingLyricsState();
}

class _FlowingLyricsState extends State<_FlowingLyrics>
    with SingleTickerProviderStateMixin {
  static const double _gap = 26;
  static const double _anchor = 0.28;
  static const double _introHeight = 44;
  static const TextStyle _base = TextStyle(
    fontFamily: _font,
    fontSize: 31,
    height: 1.2,
    fontWeight: FontWeight.w800,
    color: Colors.white,
  );
  static const double _subGap = 6;
  static const TextStyle _sub = TextStyle(
    fontFamily: _font,
    fontSize: 18,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: Colors.white,
  );

  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  Duration _lastElapsed = Duration.zero;
  Duration _lastPaintElapsed = Duration.zero;
  bool _ultra = false;

  Duration _anchorPos = Duration.zero;
  DateTime _anchorAt = DateTime.now();
  bool _clockPlaying = false;
  double _clockSpeed = 1;

  // The parser keeps start-only enhanced-LRC words for lossless editing.
  // Resolve their end windows once for painting; never do it on each tick.
  late List<LyricsLine> _playbackLines;
  List<LyricsLine> get _lines => _playbackLines;
  late List<int> _ts = [
    for (final l in widget.lyrics.lines) l.timestamp.inMilliseconds,
  ];

  List<double> _heights = const [];
  List<double> _baseHeights = const [], _subHeights = const [];
  final _subText = <int, String>{};
  double _sublineReveal = 0;
  LyricsData? _layoutLyrics;
  TextScaler? _layoutScaler;
  Locale? _layoutLocale;
  TextDirection? _layoutDirection;
  List<double> _tops = const [];
  double _w = 0;
  double _h = 0;

  double _offset = 0;
  double _focus = -1;
  bool _needsJump = true;
  bool _following = true;
  Timer? _resume;
  int _active = -1;
  int _posMs = 0;

  @override
  void initState() {
    super.initState();
    _playbackLines = LyricsService().playbackLines(widget.lyrics);
    _anchorPos = widget.player.positionNotifier.value;
    _clockPlaying = widget.player.isPlayingNotifier.value;
    _clockSpeed = widget.player.playbackSpeedNotifier.value;
    widget.player.isPlayingNotifier.addListener(_onClockState);
    widget.player.playbackSpeedNotifier.addListener(_onClockState);
    widget.player.positionNotifier.addListener(_onPosition);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(_FlowingLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.lyrics, oldWidget.lyrics)) {
      for (final line in oldWidget.lyrics.lines) {
        if (line.translation?.isNotEmpty == true)
          _subText[line.timestamp.inMilliseconds] = line.translation!;
      }
      _playbackLines = LyricsService().playbackLines(widget.lyrics);
      _ts = [for (final line in _lines) line.timestamp.inMilliseconds];
      _layoutLyrics = null;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _resume?.cancel();
    widget.player.positionNotifier.removeListener(_onPosition);
    widget.player.isPlayingNotifier.removeListener(_onClockState);
    widget.player.playbackSpeedNotifier.removeListener(_onClockState);
    _frame.dispose();
    super.dispose();
  }

  void _onPosition() {
    final v = widget.player.positionNotifier.value;
    // A big jump means the user sought: glide there instead of snapping.
    _anchorPos = v;
    _anchorAt = DateTime.now();
  }

  void _onClockState() {
    _anchorPos = Duration(milliseconds: _posNowMs());
    _anchorAt = DateTime.now();
    _clockPlaying = widget.player.isPlayingNotifier.value;
    _clockSpeed = widget.player.playbackSpeedNotifier.value;
  }

  int _posNowMs() {
    if (!_clockPlaying) return _anchorPos.inMilliseconds;
    final speed = _clockSpeed;
    final elapsed = DateTime.now()
        .difference(_anchorAt)
        .inMilliseconds
        .clamp(0, 600);
    return _anchorPos.inMilliseconds + (elapsed * speed).round();
  }

  int _indexAt(int ms) {
    var low = 0, high = _ts.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_ts[mid] <= ms) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }

  double _centerFor(int a) =>
      a < 0 ? -(_introHeight + _gap) : _tops[a.clamp(0, _tops.length - 1)];

  void _ensureLayout(double w, double h) {
    // A panel transition changes the viewport height every frame, not the
    // shaping width. Keep measured paragraphs and only move their anchor.
    _h = h;
    if ((w - _w).abs() < 0.5 &&
        _heights.length == _lines.length &&
        identical(_layoutLyrics, widget.lyrics) &&
        _layoutScaler == MediaQuery.textScalerOf(context) &&
        _layoutLocale == Localizations.maybeLocaleOf(context) &&
        _layoutDirection == Directionality.of(context)) {
      return;
    }
    _w = w;
    _h = h;
    final hs = <double>[], subs = <double>[];
    for (final l in _lines) {
      double lh;
      var sh = 0.0;
      if (l.text.trim().isEmpty) {
        lh = 30;
      } else {
        lh = LyricMotionLine.height(context, l.text, _base, math.max(w, 40));
        if (_translationOf(l) case final sub?) {
          final sp = LyricMotionLine.layout(
            context,
            sub,
            _sub,
            math.max(w, 40),
          );
          sh = _subGap + sp.height;
          sp.dispose();
        }
      }
      hs.add(lh);
      subs.add(sh);
    }
    _baseHeights = hs;
    _subHeights = subs;
    _layoutLyrics = widget.lyrics;
    _layoutScaler = MediaQuery.textScalerOf(context);
    _layoutLocale = Localizations.maybeLocaleOf(context);
    _layoutDirection = Directionality.of(context);
    _geometry();
  }

  void _geometry() {
    var y = 0.0;
    final tops = <double>[], heights = <double>[];
    for (var i = 0; i < _baseHeights.length; i++) {
      tops.add(y);
      final height = _baseHeights[i] + _subHeights[i] * _sublineReveal;
      heights.add(height);
      y += height + _gap;
    }
    _heights = heights;
    _tops = tops;
  }

  String? _translationOf(LyricsLine line) {
    if (line.translation?.trim().isNotEmpty == true)
      _subText[line.timestamp.inMilliseconds] = line.translation!.trim();
    if (widget.showTranslation) {
      return line.translation?.trim().isNotEmpty == true
          ? line.translation!.trim()
          : null;
    }
    return _subText[line.timestamp.inMilliseconds];
  }

  void _onTick(Duration elapsed) {
    if (_ultra &&
        elapsed - _lastPaintElapsed < const Duration(microseconds: 33333))
      return;
    _lastPaintElapsed = elapsed;
    final dt = ((elapsed - _lastElapsed).inMicroseconds / 1e6)
        .clamp(0.0, 0.05)
        .toDouble();
    _lastElapsed = elapsed;
    if (_heights.isEmpty || _heights.length != _lines.length) return;

    final previousReveal = _sublineReveal;
    final targetReveal = widget.showTranslation ? 1.0 : 0.0;
    final subMoving = (_sublineReveal - targetReveal).abs() > .002;
    _sublineReveal = MediaQuery.disableAnimationsOf(context)
        ? targetReveal
        : _sublineReveal +
              (targetReveal - _sublineReveal) * (1 - math.exp(-dt * 10));
    if (!subMoving) _sublineReveal = targetReveal;
    if (previousReveal != _sublineReveal) _geometry();
    final ms = _posNowMs();
    final a = _indexAt(ms);
    final aScroll = _indexAt(ms + 300);
    final target = _following ? _centerFor(aScroll) : _offset;
    final playing = widget.player.isPlayingNotifier.value;

    if (_needsJump) {
      _offset = _centerFor(aScroll);
      _focus = a.toDouble();
      _needsJump = false;
    } else {
      if (_following) _offset += (target - _offset) * (1 - math.exp(-dt * 7.0));
      _focus += (a - _focus) * (1 - math.exp(-dt * 10.0));
    }

    final settled =
        !playing &&
        !subMoving &&
        (target - _offset).abs() < 0.2 &&
        (a - _focus).abs() < 0.003 &&
        a == _active;
    _posMs = ms;
    _active = a;
    if (!settled) _frame.value++;
  }

  void _pauseFollow() {
    _following = false;
    _resume?.cancel();
    _resume = Timer(
      const Duration(milliseconds: 3200),
      () => _following = true,
    );
  }

  Widget _line(int i) {
    final l = _lines[i];
    if (l.text.trim().isEmpty) return SizedBox(height: _heights[i]);
    final d = (i - _focus).abs();
    final op = d < 1
        ? 1 - 0.66 * d
        : 0.34 - 0.18 * ((d - 1) / 3).clamp(0.0, 1.0);
    final scale = 1 - 0.1 * math.min(d, 1.0);
    final blur = _ultra || d < 1.0 ? 0.0 : math.min((d - 1) * 0.9, 2.8);

    final end = l.words?.lastOrNull?.end;
    final singing =
        i == _active ||
        (end != null && end.inMilliseconds > _posMs && _ts[i] <= _posMs);
    final text = singing
        ? LyricMotionLine(
            line: l,
            position: Duration(milliseconds: _posMs),
            style: _base,
          )
        : Opacity(
            opacity: op,
            child: LyricMotionLine(
              line: l,
              timing: false,
              position: Duration.zero,
              style: _base,
            ),
          );

    final sub = _translationOf(l);
    Widget child = Transform.scale(
      alignment: Alignment.centerLeft,
      scale: scale,
      child: sub == null
          ? text
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                text,
                ClipRect(
                  child: Align(
                    alignment: Alignment.topLeft,
                    heightFactor: _sublineReveal,
                    child: Opacity(
                      opacity: _sublineReveal,
                      child: Padding(
                        padding: const EdgeInsets.only(top: _subGap),
                        child: Transform.translate(
                          offset: Offset(0, (1 - _sublineReveal) * 6),
                          child: Text(
                            sub,
                            style: _sub.copyWith(
                              color: Colors.white.withValues(
                                alpha: i == _active ? .72 : op * .8,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
    if (blur > 0.3) {
      child = ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: blur,
          sigmaY: blur,
          tileMode: TileMode.decal,
        ),
        child: child,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _resume?.cancel();
        _following = true;
        widget.player.seek(Duration(milliseconds: _ts[i]));
      },
      child: child,
    );
  }

  Widget _introDots() {
    final firstMs = _ts.isEmpty ? 0 : _ts.first;
    final p = firstMs <= 0 ? 1.0 : (_posMs / firstMs).clamp(0.0, 1.0);
    final fade = (0 - _focus).clamp(0.0, 1.0).toDouble();
    return Opacity(
      opacity: fade,
      child: SizedBox(
        height: _introHeight,
        child: Row(
          children: [
            for (var k = 0; k < 3; k++)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(
                      alpha: 0.28 + 0.72 * (p * 3 - k).clamp(0.0, 1.0),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _ultra = LokalPerformanceScope.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        _ensureLayout(c.maxWidth, c.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (_) => _pauseFollow(),
          onVerticalDragUpdate: (d) {
            _pauseFollow();
            _offset = (_offset - d.delta.dy)
                .clamp(
                  -(_introHeight + _gap + _h * 0.3),
                  math.max(_tops.isEmpty ? 0.0 : _tops.last, 0.0),
                )
                .toDouble();
            _frame.value++;
          },
          child: ClipRect(
            child: ValueListenableBuilder<int>(
              valueListenable: _frame,
              builder: (context, _, __) {
                if (_heights.length != _lines.length) {
                  return const SizedBox.expand();
                }
                final anchorY = _h * _anchor;
                final children = <Widget>[];
                final dotsTop = anchorY - (_introHeight + _gap) - _offset;
                if (dotsTop > -80 && dotsTop < _h) {
                  children.add(
                    Positioned(left: 0, top: dotsTop, child: _introDots()),
                  );
                }
                var first = 0, end = _tops.length;
                while (first < end) {
                  final mid = (first + end) ~/ 2;
                  if (anchorY + _tops[mid] - _offset + _heights[mid] < -80) {
                    first = mid + 1;
                  } else {
                    end = mid;
                  }
                }
                for (var i = first; i < _lines.length; i++) {
                  final top = anchorY + _tops[i] - _offset;
                  if (top > _h + 80) break;
                  children.add(
                    Positioned(left: 0, right: 0, top: top, child: _line(i)),
                  );
                }
                return Stack(clipBehavior: Clip.hardEdge, children: children);
              },
            ),
          ),
        );
      },
    );
  }
}
