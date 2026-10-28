import '../widgets/android_output_chooser.dart';

import 'package:flutter/services.dart';
import 'package:flick/services/android_audio_device_service.dart';
import 'package:flick/core/theme/lokal_tokens.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flick/features/appearance/lokal_performance_advisor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/duration_format.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/features/player/widgets/player_action_button_row.dart';
import 'package:flick/features/player/widgets/player_controls.dart';
import 'package:flick/features/player/widgets/player_layout_sheet.dart';
import 'package:flick/features/player/widgets/player_navigation.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/features/player/widgets/full_player_usb_restart_menu.dart';
import 'package:flick/features/player/widgets/speed_bottom_sheet.dart';
import 'package:flick/features/player/widgets/sleep_timer_bottom_sheet.dart';
import 'package:flick/features/player/widgets/song_stage.dart';
import 'package:flick/features/player/widgets/song_stage_carousel.dart';
import 'package:flick/features/player/widgets/lyrics_mode_waveform_strip.dart';
import 'package:flick/features/player/widgets/full_player_action_chip_row.dart';
import 'package:flick/features/player/widgets/album_color_helpers.dart';
import 'package:flick/features/player/widgets/animated_blurred_album_backdrop.dart';
import 'package:flick/models/album_color_mode.dart';
import 'package:flick/models/player_screen_mode.dart';
import 'package:flick/models/player_action_button.dart';
import 'package:flick/models/progress_bar_style.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/player_volume_control.dart';
import 'package:flick/services/external_playback_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/player_screen_mode_preference_service.dart';
import 'package:flick/widgets/common/animated_album_art.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';
import 'package:flick/widgets/uac2/iso_volume_popup.dart';
import 'package:flick/widgets/uac2/uac2_error_notification.dart';
import 'package:flick/features/settings/screens/casting_settings_screen.dart';
import 'package:flick/features/settings/screens/equalizer_screen.dart';
import 'package:flick/providers/providers.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/l10n/l10n.dart';

class ClassicFullPlayerScreen extends ConsumerStatefulWidget {
  final Object heroTag;
  const ClassicFullPlayerScreen({super.key, this.heroTag = 'album_art_hero'});

  @override
  ConsumerState<ClassicFullPlayerScreen> createState() =>
      _ClassicFullPlayerScreenState();
}

class _ClassicFullPlayerScreenState
    extends ConsumerState<ClassicFullPlayerScreen>
    with TickerProviderStateMixin {
  final PlayerService _playerService = PlayerService();
  final ExternalPlaybackService _externalPlaybackService =
      ExternalPlaybackService();
  final FavoritesService _favoritesService = FavoritesService();
  final LyricsService _lyricsService = LyricsService();
  final PlayerScreenModePreferenceService _playerScreenModePreferenceService =
      PlayerScreenModePreferenceService();
  final SongRepository _songRepository = SongRepository();
  late final PlayerNavigation _navigation = PlayerNavigation(
    playerService: _playerService,
    songRepository: _songRepository,
  );

  void _close(BuildContext context) {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    Navigator.of(context).pop();
  }

  static const String _topBarTextFontFamily = 'GoogleSansFlex';
  static const FontWeight _topBarTextFontWeight = FontWeight.w500;

  late AnimationController _dragController;
  double _dragOffset = 0.0;
  DateTime _lastDragUpdate = DateTime.now();
  static const double _backGestureEdgeWidth = 32.0;

  late final ValueNotifier<Duration> _throttledPositionNotifier;
  final ValueNotifier<Duration> _zeroPosition = ValueNotifier(Duration.zero);
  Timer? _positionThrottleTimer;
  String? _cachedTopBarText;
  double? _cachedTopBarFontSize;
  bool _isLyricsMode = false;
  bool _isVinylRotationActive = false;
  bool _isVinylMode = false;
  bool _isVisualizationMode = false;
  bool _isImmersiveFullView = false;
  bool _isCarouselDragging = false;
  bool _queueDragEligible = false;
  PlayerScreenMode _playerScreenMode = PlayerScreenMode.immersive;
  int _immersiveAutoFullViewDelaySeconds = 0;
  Timer? _immersiveFullViewTimer;
  final GlobalKey _usbVolumeButtonKey = GlobalKey();
  final GlobalKey<SongStageCarouselState> _carouselKey = GlobalKey();
  VoidCallback? _dismissVolumePopup;

  @override
  void initState() {
    super.initState();
    LokalPerformanceAdvisor.enterPlayerSurface('classic-full-player');
    _immersiveAutoFullViewDelaySeconds = ref
        .read(appPreferencesProvider)
        .immersiveAutoFullViewSeconds;
    _dragController = AnimationController(
      vsync: this,
      duration: AppConstants.animationFast,
      lowerBound: 0.0,
      upperBound: 1000.0,
    );
    _dragController.value = 0.0;
    _throttledPositionNotifier = ValueNotifier(
      _playerService.positionNotifier.value,
    );
    _positionThrottleTimer = Timer.periodic(const Duration(milliseconds: 50), (
      timer,
    ) {
      if (mounted) {
        final newPosition = _playerService.positionNotifier.value;
        if (_throttledPositionNotifier.value != newPosition) {
          _throttledPositionNotifier.value = newPosition;
        }
      }
    });
    _playerService.currentSongNotifier.addListener(_handleCurrentSongChanged);
    _playerService.favoriteNotificationToggleNotifier.addListener(
      _handleFavoriteToggledFromNotification,
    );
    _loadPlayerScreenMode();
    _refreshImmersiveFullViewTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateTopBarTextMeasurement(_playerService.currentSongNotifier.value);
  }

  @override
  void dispose() {
    LokalPerformanceAdvisor.exitPlayerSurface('classic-full-player');
    _playerService.currentSongNotifier.removeListener(
      _handleCurrentSongChanged,
    );
    _playerService.favoriteNotificationToggleNotifier.removeListener(
      _handleFavoriteToggledFromNotification,
    );
    _positionThrottleTimer?.cancel();
    _immersiveFullViewTimer?.cancel();
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    _throttledPositionNotifier.dispose();
    _zeroPosition.dispose();
    _dragController.dispose();
    super.dispose();
  }

  void _handleCurrentSongChanged() {
    if (_playerService.currentSongNotifier.value == null) return;
    if (_isImmersiveFullView) {
      setState(() => _isImmersiveFullView = false);
    }
    _updateTopBarTextMeasurement(_playerService.currentSongNotifier.value);
    _refreshImmersiveFullViewTimer();
  }

  void _handleFavoriteToggledFromNotification() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPlayerScreenMode() async {
    final mode = await _playerScreenModePreferenceService.getMode();
    if (!mounted) return;
    if (_playerScreenMode != mode) {
      setState(() {
        _playerScreenMode = mode;
        if (mode != PlayerScreenMode.immersive) _isImmersiveFullView = false;
      });
    }
    _refreshImmersiveFullViewTimer();
  }

  Future<void> _setPlayerScreenMode(PlayerScreenMode mode) async {
    if (_playerScreenMode == mode) return;
    setState(() {
      _playerScreenMode = mode;
      if (mode != PlayerScreenMode.immersive) _isImmersiveFullView = false;
    });
    _refreshImmersiveFullViewTimer();
    await _playerScreenModePreferenceService.setMode(mode);
  }

  bool get _canUseImmersiveFullView =>
      _playerScreenMode == PlayerScreenMode.immersive && !_isLyricsMode;

  void _refreshImmersiveFullViewTimer() {
    _immersiveFullViewTimer?.cancel();
    if (!_canUseImmersiveFullView ||
        _isImmersiveFullView ||
        _immersiveAutoFullViewDelaySeconds <= 0) {
      return;
    }
    _immersiveFullViewTimer = Timer(
      Duration(seconds: _immersiveAutoFullViewDelaySeconds),
      () {
        if (!mounted || !_canUseImmersiveFullView || _isImmersiveFullView) {
          return;
        }
        setState(() => _isImmersiveFullView = true);
      },
    );
  }

  void _setImmersiveAutoFullViewDelaySeconds(int value) {
    if (_immersiveAutoFullViewDelaySeconds == value) return;
    _immersiveAutoFullViewDelaySeconds = value;
    _refreshImmersiveFullViewTimer();
  }

  void _setLyricsMode(bool value) {
    final nextVisualizationMode = value ? false : _isVisualizationMode;
    final nextImmersiveFullView = value ? false : _isImmersiveFullView;
    if (_isLyricsMode == value &&
        _isVisualizationMode == nextVisualizationMode &&
        _isImmersiveFullView == nextImmersiveFullView) {
      return;
    }
    setState(() {
      _isLyricsMode = value;
      _isVisualizationMode = nextVisualizationMode;
      _isImmersiveFullView = nextImmersiveFullView;
    });
    _refreshImmersiveFullViewTimer();
  }

  void _setVisualizationMode(bool value) {
    final nextLyricsMode = value ? false : _isLyricsMode;
    if (_isVisualizationMode == value && _isLyricsMode == nextLyricsMode) {
      return;
    }
    setState(() {
      _isVisualizationMode = value;
      _isLyricsMode = nextLyricsMode;
    });
    _refreshImmersiveFullViewTimer();
  }

  void _handleImmersiveSceneTap() {
    if (_playerScreenMode != PlayerScreenMode.immersive) return;
    if (_isLyricsMode) return;
    setState(() => _isImmersiveFullView = !_isImmersiveFullView);
    _refreshImmersiveFullViewTimer();
  }

  Future<void> _animateToNextSong() async {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    final carousel = _carouselKey.currentState;
    if (carousel != null && !_isVinylRotationActive) {
      await carousel.animateToNext();
    } else {
      await _playerService.next();
    }
  }

  Future<void> _animateToPreviousSong() async {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    // Button: restart after ten seconds; swiping artwork still changes tracks.
    if (shouldRestartCurrentTrackOnPrevious(
      _playerService.positionNotifier.value,
    )) {
      await _playerService.previous(allowRestart: true);
      return;
    }
    final carousel = _carouselKey.currentState;
    if (carousel != null && !_isVinylRotationActive) {
      await carousel.animateToPrevious();
    } else {
      await _playerService.previous(allowRestart: false);
    }
  }

  Future<void> _handleCarouselNext() async {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    await _playerService.next();
  }

  Future<void> _handleCarouselPrevious() async {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = null;
    // Swipe/slide: always go to previous track, ignoring the 10s restart rule
    await _playerService.previous(allowRestart: false);
  }

  void _updateTopBarTextMeasurement(Song? song) {
    if (!mounted || song == null) return;
    final text = '${song.title} - ${song.artist}';
    final fontSize = context.responsiveText(
      context.responsive(13.0, 14.0, 15.0),
    );
    if (_cachedTopBarText == text && _cachedTopBarFontSize == fontSize) return;
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _topBarTextFontFamily,
          fontFamilyFallback: AppTheme.fontFamilyFallback,
          fontSize: fontSize,
          fontWeight: _topBarTextFontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _cachedTopBarText = text;
    _cachedTopBarFontSize = fontSize;
    textPainter.width; // measure kept for future use
  }

  void _showUsbVolumePopup(BuildContext context) {
    _dismissVolumePopup?.call();
    _dismissVolumePopup = showIsoVolumePopup(context, _usbVolumeButtonKey);
  }

  // ---------------------------------------------------------------------------
  // Background (static, not sliding)
  // ---------------------------------------------------------------------------

  Widget _buildBackground(
    BuildContext context,
    Song song,
    AlbumColorMode albumColorMode,
    Color? albumColor,
    List<Color> albumPalette,
    bool visualizationMode,
    String visStyle,
    String visFreq,
    String visMove,
    bool animatedArtwork,
  ) {
    final bgBlend = albumColorMode.backgroundBlend;
    final hasAlbumTint = albumColor != null && bgBlend > 0;
    final scrimColor = hasAlbumTint
        ? Color.lerp(
            Colors.black,
            albumColor,
            (bgBlend * 1.2).clamp(0.0, 0.35),
          )!
        : Colors.black;
    return Stack(
      children: [
        Positioned.fill(
          child: _buildBaseBackground(
            context,
            song,
            albumColorMode,
            albumColor,
            albumPalette,
            visualizationMode,
            visStyle,
            visFreq,
            visMove,
            animatedArtwork,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: AppConstants.animationNormal,
              opacity: _isLyricsMode ? 1.0 : 0.0,
              child: AnimatedContainer(
                duration: AppConstants.animationNormal,
                color: scrimColor.withValues(alpha: 0.45),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBaseBackground(
    BuildContext context,
    Song song,
    AlbumColorMode albumColorMode,
    Color? albumColor,
    List<Color> albumPalette,
    bool visualizationMode,
    String visStyle,
    String visFreq,
    String visMove,
    bool animatedArtwork,
  ) {
    final bgBlend = albumColorMode.backgroundBlend;
    final hasAlbumTint = albumColor != null && bgBlend > 0;

    if (_playerScreenMode == PlayerScreenMode.artworkCard) {
      final placeholder = Container(
        color: AppColors.background,
        child: const Center(
          child: FlickArtworkPlaceholder(size: 96, opacity: 0.35),
        ),
      );
      return Stack(
        children: [
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 520),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ...previousChildren,
                    ...?currentChild == null ? null : [currentChild],
                  ],
                );
              },
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: AnimatedBlurredAlbumBackdrop(
                key: ValueKey('album-backdrop-${song.id}'),
                imagePath: song.albumArt,
                audioSourcePath: song.filePath,
                placeholder: placeholder,
                errorWidget: placeholder,
              ),
            ),
          ),
        ],
      );
    }

    final gradientBase = hasAlbumTint
        ? albumSurface(albumColor, bgBlend)
        : const Color(0xFF121212);
    final gradientColors = _isImmersiveFullView
        ? [
            gradientBase.withValues(alpha: 0.3),
            gradientBase.withValues(alpha: 0.25),
            gradientBase.withValues(alpha: 0.2),
            gradientBase.withValues(alpha: 0.15),
            gradientBase.withValues(alpha: 0.08),
            Colors.transparent,
          ]
        : [
            gradientBase,
            gradientBase.withValues(alpha: 0.95),
            gradientBase.withValues(alpha: 0.85),
            gradientBase.withValues(alpha: 0.6),
            gradientBase.withValues(alpha: 0.3),
            Colors.transparent,
          ];
    final placeholder = Container(
      color: AppColors.background,
      child: const Center(
        child: FlickArtworkPlaceholder(size: 96, opacity: 0.35),
      ),
    );
    final hasArtwork = song.albumArt != null || song.filePath != null;
    final artLayer = animatedArtwork && hasArtwork
        ? AnimatedAlbumArt(
            imagePath: song.albumArt,
            audioSourcePath: song.filePath,
            dominantColor: albumColor,
            placeholder: placeholder,
            errorWidget: placeholder,
            albumName: song.album,
            artistName:
                (song.albumArtist != null &&
                    song.albumArtist!.trim().isNotEmpty)
                ? song.albumArtist
                : song.artist,
            representativeSongTitle: song.title,
            preferVertical: true,
            // In the standard layout the art card carries Motion Art; only the
            // immersive full-bleed view needs a second video layer.
            motionEnabled: _isImmersiveFullView,
          )
        : CachedImageWidget(
            imagePath: song.albumArt,
            audioSourcePath: song.filePath,
            fit: BoxFit.cover,
            placeholder: placeholder,
            errorWidget: placeholder,
          );
    return Stack(
      children: [
        Positioned.fill(child: artLayer),
        Positioned.fill(
          child: AnimatedContainer(
            duration: AppConstants.animationNormal,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: gradientColors,
                stops: const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Top chrome (pinned)
  // ---------------------------------------------------------------------------

  Widget _buildTopChrome(
    BuildContext context,
    Song song,
    Color? albumColor,
    AlbumColorMode albumColorMode,
    dynamic appPrefs,
  ) {
    final isCasting = ref.watch(isCastingProvider);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.responsive(8.0, 12.0, 16.0),
        vertical: context.responsive(4.0, 6.0, 8.0),
      ),
      child: Row(
        children: [
          _buildChromeButton(
            context,
            icon: LucideIcons.chevronLeft,
            albumColor: albumColor,
            albumColorMode: albumColorMode,
            onTap: () => _close(context),
          ),
          const Spacer(),
          _buildOutputDeviceChip(context, song),
          SizedBox(width: context.responsive(6.0, 8.0, 10.0)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (song.isFromLocker) _buildReturnToLockerButton(context),
              if (song.isFromLocker)
                SizedBox(width: context.responsive(6.0, 8.0, 10.0)),
              _buildChromeButton(
                context,
                icon: LucideIcons.cast,
                albumColor: isCasting ? albumColor : null,
                albumColorMode: isCasting ? albumColorMode : null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CastingSettingsScreen(),
                  ),
                ),
              ),
              SizedBox(width: context.responsive(6.0, 8.0, 10.0)),
              _buildChromeButton(
                context,
                icon: Icons.more_vert,
                albumColor: albumColor,
                albumColorMode: albumColorMode,
                onTap: () => unawaited(showFullPlayerSongMenu(
                  context,
                  song: song,
                  player: _playerService,
                  keepBrowseActions: true,
                  extras: [
                    LokalSongMenuAction(
                      icon: Icons.lyrics_outlined,
                      label: 'Lyrics',
                      onTap: () => _setLyricsMode(true),
                    ),
                    LokalSongMenuAction(
                      icon: Icons.dashboard_customize_outlined,
                      label: 'Player layout',
                      onTap: () => PlayerLayoutSheet.show(
                        context,
                        playerService: _playerService,
                        currentMode: _playerScreenMode,
                        onModeChanged: _setPlayerScreenMode,
                        song: _playerService.currentSongNotifier.value,
                      ),
                    ),
                    LokalSongMenuAction(
                      icon: Icons.speed_rounded,
                      label: 'Playback speed',
                      onTap: () =>
                          SpeedBottomSheet.show(context, _playerService),
                    ),
                    LokalSongMenuAction(
                      icon: Icons.bedtime_outlined,
                      label: 'Sleep timer',
                      onTap: () =>
                          SleepTimerBottomSheet.show(context, _playerService),
                    ),
                  ],
                )),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOutputDeviceChip(BuildContext context, Song song) {
    final diagnostics = ref.watch(audioOutputDiagnosticsProvider);
    final label = diagnostics?.outputDeviceLabel.trim().isNotEmpty == true
        ? diagnostics!.outputDeviceLabel.trim()
        : diagnostics?.routeLabel.trim().isNotEmpty == true
        ? diagnostics!.routeLabel.trim()
        : l10n.thisDevice;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => _showOutputDevicePopup(context, song),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: context.responsive(150, 190, 230),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: context.responsive(12, 14, 16),
            vertical: context.responsive(7, 8, 9),
          ),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.headphones,
                size: context.responsive(17, 19, 21),
                color: Colors.white.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'GoogleSansFlex',
                    fontSize: context.responsive(12, 13, 14),
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showOutputDevicePopup(BuildContext context, Song song) =>
      openAndroidOutputChooser(context);

  Widget _buildReturnToLockerButton(BuildContext context) {
    return GestureDetector(
      onTap: () {
        unawaited(
          _externalPlaybackService.returnToLocker().then((returned) {
            if (!returned && context.mounted) Navigator.of(context).pop();
          }),
        );
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.responsive(12.0, 14.0, 16.0),
          vertical: context.responsive(10.0, 11.0, 12.0),
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF121212).withValues(alpha: 0.76),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.undo2,
              size: context.responsive(14.0, 15.0, 16.0),
              color: Colors.white.withValues(alpha: 0.9),
            ),
            SizedBox(width: context.responsive(6.0, 7.0, 8.0)),
            Text(
              l10n.backToLocker,
              style: TextStyle(
                fontFamily: 'GoogleSansFlex',
                fontSize: context.responsive(11.0, 12.0, 13.0),
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.92),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChromeButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback onTap,
    Color? albumColor,
    AlbumColorMode? albumColorMode,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: AppHaptics.wrap(onTap),
        padding: EdgeInsets.all(context.responsive(8.0, 10.0, 12.0)),
        constraints: const BoxConstraints(),
        icon: Icon(
          icon,
          color: Colors.white,
          size: context.responsive(20.0, 22.0, 24.0),
        ),
      ),
    );
  }

  /// Pinned waveform — stays fixed while carousel slides art+identity.
  /// Lazy-loads for current song only; peek stages no longer build waveforms.
  /// Always builds LyricsModeWaveformStrip so the WaveformLayer inside keeps
  /// its state (no re-appear animation / peaks reload) when lyrics toggle.
  Widget _buildPinnedWaveform(
    BuildContext context,
    Song song,
    PlayerScreenMode mode,
  ) {
    final isImmersive = mode == PlayerScreenMode.immersive;
    // The seekbar shows an animated floating time bubble while dragging. The
    // compact elapsed/total labels remain below it in the settled state.
    return LyricsModeWaveformStrip(
      playerService: _playerService,
      positionNotifier: _throttledPositionNotifier,
      currentSong: song,
      formatDuration: formatDuration,
      horizontalPadding: isImmersive
          ? context.responsive(18.0, 24.0, 30.0)
          : context.responsive(24.0, 28.0, 32.0),
      timeLabelsPadding: isImmersive
          ? null
          : context.responsive(14.0, 16.0, 18.0),
      onSwipeUp: () => _setLyricsMode(false),
      showTimeLabels: !isImmersive && !_isLyricsMode,
      showArrow: _isLyricsMode && isImmersive,
      styleOverride: isImmersive ? null : ProgressBarStyle.line,
      targetStyle: !isImmersive,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appPreferencesProvider, (previous, next) {
      _setImmersiveAutoFullViewDelaySeconds(next.immersiveAutoFullViewSeconds);
    });

    final appPrefs = ref.watch(appPreferencesProvider);
    final visStyle = appPrefs.visualizerAnimationStyle;
    final visFreq = appPrefs.visualizerFrequencyMode;
    final visMove = appPrefs.visualizerMovementMode;

    final colorMode = ref.watch(albumColorModeProvider);
    final dominantColor = ref.watch(albumDominantColorSyncProvider);
    final albumPalette = ref.watch(albumPaletteSyncProvider);
    final useArtworkTint =
        _playerScreenMode == PlayerScreenMode.artworkCard &&
        dominantColor != null;
    final playerColorMode = colorMode == AlbumColorMode.off && useArtworkTint
        ? AlbumColorMode.vibrant
        : colorMode;
    final Color? albumColor =
        (playerColorMode != AlbumColorMode.off && dominantColor != null)
        ? dominantColor
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _close(context);
      },
      child: DisplayModeWrapper(
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: ValueListenableBuilder<Song?>(
            valueListenable: _playerService.currentSongNotifier,
            builder: (context, song, _) {
              if (song == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) Navigator.of(context).pop();
                });
                return const SizedBox.shrink();
              }

              final isShortHeight = MediaQuery.sizeOf(context).height < 620.0;
              final showImmersiveFullView =
                  _isImmersiveFullView &&
                  _playerScreenMode == PlayerScreenMode.immersive &&
                  !isShortHeight;
              final showVisualizerOnly =
                  _isVisualizationMode &&
                  appPrefs.visualizerEnabled &&
                  showImmersiveFullView;

              // Outer vertical-dismiss gesture (kept). Horizontal is now inside carousel.
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _handleImmersiveSceneTap,
                onVerticalDragStart: (details) {
                  if (_isVinylRotationActive || _isCarouselDragging) return;
                  final screenHeight = MediaQuery.sizeOf(context).height;
                  _queueDragEligible =
                      details.globalPosition.dy >= screenHeight * 0.62;
                  if (details.globalPosition.dy >=
                      screenHeight - _backGestureEdgeWidth) {
                    _queueDragEligible = false;
                    _dragOffset = 0.0;
                    return;
                  }
                  _dragController.stop();
                },
                onVerticalDragUpdate: (details) {
                  if (_isVinylRotationActive || _isCarouselDragging) return;
                  if (_queueDragEligible) {
                    if (details.delta.dy < 0) {
                      _dragOffset = (_dragOffset + details.delta.dy).clamp(
                        -1000.0,
                        0.0,
                      );
                    }
                    return;
                  }
                  if (details.delta.dy > 0) {
                    final now = DateTime.now();
                    if (now.difference(_lastDragUpdate).inMilliseconds < 16) {
                      return;
                    }
                    _lastDragUpdate = now;
                    _dragOffset = (_dragOffset + details.delta.dy).clamp(
                      0.0,
                      1000.0,
                    );
                    _dragController.value = _dragOffset;
                  }
                },
                onVerticalDragEnd: (details) {
                  if (_isVinylRotationActive || _isCarouselDragging) return;
                  if (_queueDragEligible) {
                    final shouldOpenQueue =
                        _dragOffset < -90 ||
                        (details.primaryVelocity ?? 0) < -500;
                    _queueDragEligible = false;
                    _dragOffset = 0.0;
                    if (shouldOpenQueue) {
                      unawaited(_navigation.openQueue(context));
                    }
                    return;
                  }
                  if (_dragOffset > 100 ||
                      (details.primaryVelocity ?? 0) > 500) {
                    _close(context);
                    return;
                  }
                  _dragOffset = 0.0;
                  _dragController.animateTo(0.0);
                },
                child: AnimatedBuilder(
                  animation: _dragController,
                  builder: (context, child) {
                    final offset = _dragController.value * 0.5;
                    return Transform.translate(
                      offset: Offset(0, offset),
                      child: child!,
                    );
                  },
                  child: _buildPlayerBody(
                    context,
                    song,
                    appPrefs,
                    playerColorMode,
                    albumColor,
                    albumPalette,
                    visStyle,
                    visFreq,
                    visMove,
                    showImmersiveFullView,
                    showVisualizerOnly,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerBody(
    BuildContext context,
    Song song,
    dynamic appPrefs,
    AlbumColorMode colorMode,
    Color? albumColor,
    List<Color> albumPalette,
    String visStyle,
    String visFreq,
    String visMove,
    bool showImmersiveFullView,
    bool showVisualizerOnly,
  ) {
    final visualizationMode =
        _isVisualizationMode && appPrefs.visualizerEnabled;

    // Shared file-info builder for stages; also drawn pinned (overlay) so the
    // left/right buttons don't slide with the carousel.
    Widget fileInfoBuilder(Song s, bool lm, PlayerScreenMode mode) {
      return PlayerActionButtonRow(
        song: s,
        lyricsMode: lm,
        isVisualizationMode: _isVisualizationMode,
        playerScreenMode: mode,
        albumColor: albumColor,
        albumColorMode: colorMode,
        leftTopAction: PlayerActionButtonX.fromStorageValue(
          appPrefs.leftTopActionButton,
        ),
        leftAction: PlayerActionButtonX.fromStorageValue(
          appPrefs.leftActionButton,
        ),
        rightTopAction: PlayerActionButtonX.fromStorageValue(
          appPrefs.rightTopActionButton,
        ),
        rightAction: PlayerActionButtonX.fromStorageValue(
          appPrefs.rightActionButton,
        ),
        playerService: _playerService,
        favoritesService: _favoritesService,
        onToggleLyrics: () => setState(() => _isLyricsMode = !lm),
        onToggleVisualization: (v) => _setVisualizationMode(v),
        onOpenQueue: (ctx) => _navigation.openQueue(ctx),
        usbVolumeButtonKey: _usbVolumeButtonKey,
        onShowUsbVolumePopup: (ctx) => _showUsbVolumePopup(ctx),
      );
    }

    // Overlay shows over the stage's reserved invisible row slot.
    final showPinnedActionRow = _playerScreenMode == PlayerScreenMode.immersive
        ? (appPrefs.immersiveShowFileInfo && !_isLyricsMode)
        : false;
    // Match the stage's own row padding so the overlay lines up exactly.
    final pinnedActionRowPadding =
        _playerScreenMode == PlayerScreenMode.immersive
        ? context.responsive(12.0, 16.0, 20.0)
        : (MediaQuery.sizeOf(context).width < 360
              ? 16.0
              : context.responsive(20.0, 28.0, 36.0));

    // Background is always behind
    final background = _buildBackground(
      context,
      song,
      colorMode,
      albumColor,
      albumPalette,
      visualizationMode,
      visStyle,
      visFreq,
      visMove,
      appPrefs.animatedAlbumArt && appPrefs.animationsEnabled,
    );

    if (showVisualizerOnly) {
      // Full-bleed visualizer, tap to exit full-view
      return Stack(
        children: [
          Positioned.fill(child: background),
          // keep top chrome hidden in full-view; still allow tap to exit
        ],
      );
    }

    if (showImmersiveFullView) {
      // Minimal bottom card — no top chrome, no pinned controls
      return Stack(
        children: [
          Positioned.fill(child: background),
          SafeArea(
            child: ValueListenableBuilder<List<Song>>(
              valueListenable: _playerService.upNextNotifier,
              builder: (context, upNext, _) {
                return ValueListenableBuilder<int>(
                  valueListenable: _playerService.currentIndexNotifier,
                  builder: (context, idx, _) {
                    final prev = _playerService.peekPrevious;
                    final next = _playerService.peekNext;
                    return SongStageCarousel(
                      key: _carouselKey,
                      currentSong: song,
                      prevSong: prev,
                      nextSong: next,
                      enabled: !_isVinylRotationActive,
                      onDragStateChanged: (v) => _isCarouselDragging = v,
                      onNext: _handleCarouselNext,
                      onPrevious: _handleCarouselPrevious,
                      stageBuilder: (s) {
                        final isCurrent = s.id == song.id;
                        return SongStage(
                          key: ValueKey('song-stage-${s.id}'),
                          song: s,
                          lyricsMode: _isLyricsMode,
                          visualizationMode: visualizationMode,
                          immersiveFullView: true,
                          playerScreenMode: _playerScreenMode,
                          albumColorMode: colorMode,
                          albumColor: albumColor,
                          playerService: _playerService,
                          lyricsService: _lyricsService,
                          positionNotifier: isCurrent
                              ? _throttledPositionNotifier
                              : _zeroPosition,
                          formatDuration: formatDuration,
                          onNavigateToArtistDetail: (s) =>
                              _navigation.openArtistFromSong(context, s),
                          onNavigateToArtistName: (s, name) => _navigation
                              .openArtistFromSong(context, s, artistName: name),
                          onNavigateToAlbumDetail: (s) =>
                              _navigation.openAlbumFromSong(context, s),
                          buildFileInfoRow: fileInfoBuilder,
                          visualizerAnimationStyle: visStyle,
                          visualizerFrequencyMode: visFreq,
                          visualizerMovementMode: visMove,
                          artworkCardArtworkScale:
                              appPrefs.artworkCardArtworkScale,
                          artworkCardTextScale: appPrefs.artworkCardTextScale,
                          artworkCardVerticalOffset:
                              appPrefs.artworkCardVerticalOffset,
                          artworkCardArtworkOffset:
                              appPrefs.artworkCardArtworkOffset,
                          artworkCardShowTitle: appPrefs.artworkCardShowTitle,
                          artworkCardShowArtist: appPrefs.artworkCardShowArtist,
                          artworkCardShowAlbum: appPrefs.artworkCardShowAlbum,
                          artworkCardShowFileInfo:
                              appPrefs.artworkCardShowFileInfo,
                          artworkCardShowFrame: false,
                          immersiveTextScale: appPrefs.immersiveTextScale,
                          immersiveVerticalOffset:
                              appPrefs.immersiveVerticalOffset,
                          immersiveFullViewScale:
                              appPrefs.immersiveFullViewScale,
                          immersiveShowTitle: appPrefs.immersiveShowTitle,
                          immersiveShowArtist: appPrefs.immersiveShowArtist,
                          immersiveShowFileInfo: appPrefs.immersiveShowFileInfo,
                          onRotationEnabledChanged: (enabled) {
                            _isVinylRotationActive = enabled;
                          },
                          vinylMode: _isVinylMode,
                          onVinylChanged: (v) => _isVinylMode = v,
                          onToggleLyrics: () => _setLyricsMode(!_isLyricsMode),
                          showWaveform: false,
                          motionArtEnabled:
                              isCurrent &&
                              _playerScreenMode != PlayerScreenMode.artworkCard,
                          active: isCurrent,
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      );
    }

    // Default: pinned top chrome + sliding stage + pinned controls
    return Stack(
      children: [
        Positioned.fill(child: background),
        SafeArea(
          child: Column(
            children: [
              const Uac2ErrorNotification(),
              _buildTopChrome(context, song, albumColor, colorMode, appPrefs),
              SizedBox(height: context.responsive(8.0, 10.0, 12.0)),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ValueListenableBuilder<List<Song>>(
                        valueListenable: _playerService.upNextNotifier,
                        builder: (context, upNext, _) {
                          return ValueListenableBuilder<int>(
                            valueListenable:
                                _playerService.currentIndexNotifier,
                            builder: (context, idx, _) {
                              final prev = _playerService.peekPrevious;
                              final next = _playerService.peekNext;
                              // Precache adjacent artwork for buttery peek
                              final nextArt = next?.albumArt;
                              if (nextArt != null) {
                                precacheImage(
                                  FileImage(File(nextArt)),
                                  context,
                                  onError: (_, __) {},
                                );
                              }
                              return SongStageCarousel(
                                key: _carouselKey,
                                currentSong: song,
                                prevSong: prev,
                                nextSong: next,
                                enabled: !_isVinylRotationActive,
                                onDragStateChanged: (v) =>
                                    _isCarouselDragging = v,
                                onNext: _handleCarouselNext,
                                onPrevious: _handleCarouselPrevious,
                                stageBuilder: (s) {
                                  final isCurrent = s.id == song.id;
                                  return SongStage(
                                    key: ValueKey('song-stage-${s.id}'),
                                    song: s,
                                    lyricsMode: _isLyricsMode,
                                    visualizationMode: visualizationMode,
                                    immersiveFullView: false,
                                    playerScreenMode: _playerScreenMode,
                                    albumColorMode: colorMode,
                                    albumColor: albumColor,
                                    playerService: _playerService,
                                    lyricsService: _lyricsService,
                                    positionNotifier: isCurrent
                                        ? _throttledPositionNotifier
                                        : _zeroPosition,
                                    formatDuration: formatDuration,
                                    onNavigateToArtistDetail: (s) => _navigation
                                        .openArtistFromSong(context, s),
                                    onNavigateToArtistName: (s, name) =>
                                        _navigation.openArtistFromSong(
                                          context,
                                          s,
                                          artistName: name,
                                        ),
                                    onNavigateToAlbumDetail: (s) => _navigation
                                        .openAlbumFromSong(context, s),
                                    buildFileInfoRow: fileInfoBuilder,
                                    fileInfoRowVisible: false,
                                    visualizerAnimationStyle: visStyle,
                                    visualizerFrequencyMode: visFreq,
                                    visualizerMovementMode: visMove,
                                    motionArtEnabled:
                                        isCurrent &&
                                        _playerScreenMode !=
                                            PlayerScreenMode.artworkCard,
                                    artworkCardArtworkScale:
                                        appPrefs.artworkCardArtworkScale,
                                    artworkCardTextScale:
                                        appPrefs.artworkCardTextScale,
                                    artworkCardVerticalOffset:
                                        appPrefs.artworkCardVerticalOffset,
                                    artworkCardArtworkOffset:
                                        appPrefs.artworkCardArtworkOffset,
                                    artworkCardShowTitle:
                                        appPrefs.artworkCardShowTitle,
                                    artworkCardShowArtist:
                                        appPrefs.artworkCardShowArtist,
                                    artworkCardShowAlbum:
                                        appPrefs.artworkCardShowAlbum,
                                    artworkCardShowFileInfo:
                                        appPrefs.artworkCardShowFileInfo,
                                    artworkCardShowFrame: false,
                                    immersiveTextScale:
                                        appPrefs.immersiveTextScale,
                                    immersiveVerticalOffset:
                                        appPrefs.immersiveVerticalOffset,
                                    immersiveFullViewScale:
                                        appPrefs.immersiveFullViewScale,
                                    immersiveShowTitle:
                                        appPrefs.immersiveShowTitle,
                                    immersiveShowArtist:
                                        appPrefs.immersiveShowArtist,
                                    immersiveShowFileInfo:
                                        appPrefs.immersiveShowFileInfo,
                                    onRotationEnabledChanged: (enabled) {
                                      _isVinylRotationActive = enabled;
                                    },
                                    vinylMode: _isVinylMode,
                                    onVinylChanged: (v) => _isVinylMode = v,
                                    onToggleLyrics: () =>
                                        _setLyricsMode(!_isLyricsMode),
                                    showWaveform: false,
                                    active: isCurrent,
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                    if (showPinnedActionRow)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: pinnedActionRowPadding,
                          ),
                          child: fileInfoBuilder(
                            song,
                            _isLyricsMode,
                            _playerScreenMode,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Pinned waveform — not sliding, lazy-loads current song only.
              // Mirrors the gap SongStage previously had before its waveform.
              Builder(
                builder: (context) {
                  final isImmersive =
                      _playerScreenMode == PlayerScreenMode.immersive;
                  double topGap;
                  if (_isLyricsMode && isImmersive) {
                    topGap = context.responsive(10.0, 12.0, 14.0);
                  } else if (isImmersive) {
                    topGap = context.responsive(12.0, 14.0, 16.0);
                  } else {
                    // artworkCard gap before waveform (playbackSpacing)
                    final isVeryShort = MediaQuery.sizeOf(context).height < 540;
                    topGap = appPrefs.artworkCardShowFileInfo
                        ? (isVeryShort
                              ? 10.0
                              : context.responsive(18.0, 22.0, 26.0))
                        : context.responsive(8.0, 10.0, 12.0);
                  }
                  final timeLabelsPadding = isImmersive
                      ? context.responsive(18.0, 24.0, 30.0)
                      : context.responsive(16.0, 20.0, 24.0);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOut,
                        height: topGap,
                      ),
                      _buildPinnedWaveform(context, song, _playerScreenMode),
                      // Unified default: when lyrics are on, keep single time
                      // labels under waveform for BOTH immersive and artworkCard.
                      // This replaces the duplicated labels previously inside
                      // PlayerControls and (for immersive) inside the strip.
                      // AnimatedSize so the waveform lowers/raises smoothly.
                      AnimatedSize(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOut,
                        alignment: Alignment.topCenter,
                        child: _isLyricsMode
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    height: context.responsive(8.0, 10.0, 12.0),
                                  ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: timeLabelsPadding,
                                    ),
                                    child: ValueListenableBuilder<Duration>(
                                      valueListenable:
                                          _playerService.positionNotifier,
                                      builder: (context, position, _) {
                                        return ValueListenableBuilder<Duration>(
                                          valueListenable:
                                              _playerService.durationNotifier,
                                          builder:
                                              (context, engineDuration, _) {
                                                final duration =
                                                    engineDuration
                                                            .inMilliseconds >
                                                        0
                                                    ? engineDuration
                                                    : (song.duration);
                                                return PlaybackTimeLabels(
                                                  position: position,
                                                  duration: duration,
                                                  formatDuration:
                                                      formatDuration,
                                                  horizontalPadding:
                                                      timeLabelsPadding,
                                                );
                                              },
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  );
                },
              ),
              // Gap between pinned waveform/time-labels and controls.
              // When lyrics are open we keep only the one under the waveform,
              // so tighten the gap and hide the duplicate inside PlayerControls.
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut,
                height: _isLyricsMode
                    ? context.responsive(8.0, 10.0, 12.0)
                    : context.responsive(10.0, 12.0, 14.0),
              ),
              // Pinned controls — do not slide. Deduplicate time labels:
              // immersive lyrics keeps strip's labels, artworkCard lyrics keeps
              // the pinned labels just above (under waveform). Hide duplicate
              // inside PlayerControls when lyrics are open.
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: _playerScreenMode == PlayerScreenMode.immersive
                      ? context.responsive(18.0, 24.0, 30.0)
                      : context.responsive(16.0, 20.0, 24.0),
                ),
                child: PlayerControls(
                  playerService: _playerService,
                  formatDuration: formatDuration,
                  currentSong: song,
                  onPrevious: _animateToPreviousSong,
                  onNext: _animateToNextSong,
                  timelineHorizontalPadding:
                      _playerScreenMode == PlayerScreenMode.immersive
                      ? context.responsive(18.0, 24.0, 30.0)
                      : context.responsive(16.0, 20.0, 24.0),
                  albumColorMode: colorMode,
                  albumColor: albumColor,
                  showTimeLabels:
                      _playerScreenMode == PlayerScreenMode.immersive &&
                      !_isLyricsMode,
                  targetLayout:
                      _playerScreenMode == PlayerScreenMode.artworkCard,
                  favoritesService: _favoritesService,
                ),
              ),
              if (_playerScreenMode == PlayerScreenMode.artworkCard) ...[
                SizedBox(height: context.responsive(6.0, 8.0, 10.0)),
                FullPlayerActionChipRow(
                  playerService: _playerService,
                  lyricsActive: _isLyricsMode,
                  onOpenQueue: () => _navigation.openQueue(context),
                  onToggleLyrics: () => _setLyricsMode(!_isLyricsMode),
                  onOpenEqualizer: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EqualizerScreen(),
                    ),
                  ),
                ),
              ],
              // Original bottom spacing: immersive 24-40, artworkCard directorySpacing 24-40
              SizedBox(height: context.responsive(8.0, 12.0, 16.0)),
            ],
          ),
        ),
      ],
    );
  }
}

class OutputDevicePopup extends StatefulWidget {
  final Song song;
  final PlayerService playerService;
  final String deviceLabel;

  const OutputDevicePopup({
    required this.song,
    required this.playerService,
    required this.deviceLabel,
  });

  @override
  State<OutputDevicePopup> createState() => _OutputDevicePopupState();
}

class _OutputDevicePopupState extends State<OutputDevicePopup> {
  late final PlayerVolumeControl _volumeControl;

  @override
  void initState() {
    super.initState();
    _volumeControl = PlayerVolumeControl(widget.playerService);
  }

  @override
  void dispose() {
    _volumeControl.dispose();
    super.dispose();
  }

  bool _openingOutput = false;

  Future<void> _chooseOutput() async {
    if (_openingOutput) return;
    setState(() => _openingOutput = true);
    try {
      final opened = await AndroidAudioDeviceService.instance
          .showOutputSwitcher();
      if (!mounted) return;
      if (opened) {
        Navigator.of(context).pop();
      } else {
        setState(
          () => _outputError = 'Android could not open the output chooser. Start playback, then try again.',
        );
      }
    } on PlatformException catch (error) {
      if (mounted)
        setState(
          () => _outputError =
              error.message ?? 'Could not open Android output selection.',
        );
    } on MissingPluginException {
      if (mounted)
        setState(
          () => _outputError =
              'Output selection requires the updated Android app.',
        );
    } finally {
      if (mounted) setState(() => _openingOutput = false);
    }
  }

  String? _outputError;

  String _time(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.lokal.surface,
            borderRadius: BorderRadius.circular(34),
            border: Border.all(
              color: context.lokal.text.withValues(alpha: 0.08),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 28, 28, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: SizedBox(
                        width: 82,
                        height: 82,
                        child: CachedImageWidget(
                          imagePath: widget.song.albumArt,
                          audioSourcePath: widget.song.filePath,
                          fit: BoxFit.cover,
                          placeholder: const ColoredBox(color: Colors.black26),
                          errorWidget: const ColoredBox(color: Colors.black26),
                        ),
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.lokal.text,
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'GoogleSansFlex',
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${widget.song.artist}${widget.song.album == null ? '' : ' · ${widget.song.album}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.lokal.text.withValues(alpha: 0.62),
                              fontSize: 15,
                              fontFamily: 'GoogleSansFlex',
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                onPressed: () => unawaited(
                                  widget.playerService.previous(),
                                ),
                                icon: const Icon(LucideIcons.skipBack),
                                color: context.lokal.text,
                                iconSize: 26,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 40,
                                  minHeight: 40,
                                ),
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable:
                                    widget.playerService.isPlayingNotifier,
                                builder: (context, isPlaying, _) {
                                  return IconButton(
                                    onPressed:
                                        widget.playerService.togglePlayPause,
                                    icon: Icon(
                                      isPlaying
                                          ? LucideIcons.pause
                                          : LucideIcons.play,
                                    ),
                                    color: context.lokal.text,
                                    iconSize: 32,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 48,
                                      minHeight: 40,
                                    ),
                                  );
                                },
                              ),
                              IconButton(
                                onPressed: () =>
                                    unawaited(widget.playerService.next()),
                                icon: const Icon(LucideIcons.skipForward),
                                color: context.lokal.text,
                                iconSize: 26,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 40,
                                  minHeight: 40,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                ValueListenableBuilder<Duration>(
                  valueListenable: widget.playerService.positionNotifier,
                  builder: (context, position, _) {
                    return ValueListenableBuilder<Duration>(
                      valueListenable: widget.playerService.durationNotifier,
                      builder: (context, duration, _) {
                        final effective = duration.inMilliseconds > 0
                            ? duration
                            : widget.song.duration;
                        final progress = effective.inMilliseconds == 0
                            ? 0.0
                            : (position.inMilliseconds /
                                      effective.inMilliseconds)
                                  .clamp(0.0, 1.0);
                        return Column(
                          children: [
                            LinearProgressIndicator(
                              value: progress,
                              minHeight: 7,
                              borderRadius: BorderRadius.circular(99),
                              backgroundColor: Colors.black.withValues(
                                alpha: 0.28,
                              ),
                              valueColor: AlwaysStoppedAnimation(
                                context.lokal.text,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _time(position),
                                  style: TextStyle(
                                    color: context.lokal.text.withValues(
                                      alpha: 0.58,
                                    ),
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  _time(effective),
                                  style: TextStyle(
                                    color: context.lokal.text.withValues(
                                      alpha: 0.58,
                                    ),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(
                      Icons.volume_down_rounded,
                      color: context.lokal.text.withValues(alpha: 0.72),
                    ),
                    Expanded(
                      child: ListenableBuilder(
                        listenable: _volumeControl,
                        builder: (context, _) => Slider(
                          value: _volumeControl.value,
                          max: _volumeControl.max,
                          onChanged: !_volumeControl.available
                              ? null
                              : (value) {
                                  unawaited(_volumeControl.set(value));
                                },
                          activeColor: context.lokal.text,
                          inactiveColor: context.lokal.text.withValues(
                            alpha: 0.16,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                InkWell(
                  borderRadius: BorderRadius.circular(28),
                  onTap: _openingOutput ? null : _chooseOutput,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    decoration: BoxDecoration(
                      color: context.lokal.text,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.phone_android_rounded,
                          color: Color(0xFF4F7DF3),
                        ),
                        const SizedBox(width: 18),
                        Text(
                          lokalText(
                            _openingOutput
                                ? 'Opening outputs…'
                                : 'Choose output',
                          ),
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'GoogleSansFlex',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.deviceLabel,
                  style: TextStyle(color: context.lokal.muted, fontSize: 13),
                ),
                if (_outputError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      lokalText(_outputError!),
                      style: TextStyle(color: context.lokal.text, fontSize: 13),
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
