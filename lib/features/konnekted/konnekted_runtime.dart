import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/features/updates/lokal_update_sheet.dart';
import 'package:flick/services/library_job_notification.dart';
import 'package:flick/features/spotify/spotify_likes_sync_service.dart';
import 'package:flick/services/queue_pre_resolver.dart';
import 'package:flick/services/local_metadata_repair.dart';
import 'package:flick/services/lokal_launcher_icon.dart';
import 'package:flick/features/library_jobs/artist_metadata.dart';

import 'konnekted_data.dart';
import 'konnekted_discovery.dart';

import 'package:flick/features/library_jobs/library_jobs.dart';
import 'package:flick/widgets/lokal/lokal_status_snack.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/providers/app_build_info_provider.dart';

import 'dart:async';

import 'package:flick/core/utils/app_log.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/features/whats_new/widgets/whats_new_bottom_sheet.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/library_scanner_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/discord_presence_service.dart';
import 'package:flick/services/widget_intent_handler.dart';
import 'package:flick/services/widget_sync_service.dart';
import 'package:flick/widgets/common/floating_scan_progress.dart';
import 'package:flick/widgets/uac2/usb_bit_perfect_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Non-visual responsibilities formerly owned by MainShell. Mount exactly once,
/// after onboarding and native/bootstrap initialization, inside a Scaffold.
class KonnektedRuntime extends ConsumerStatefulWidget {
  const KonnektedRuntime({
    super.key,
    required this.child,
    required this.onOpenPlayer,
    required this.onOpenQueue,
  });

  final Widget child;
  final VoidCallback onOpenPlayer;
  final VoidCallback onOpenQueue;

  @override
  ConsumerState<KonnektedRuntime> createState() => _KonnektedRuntimeState();
}

class _KonnektedRuntimeState extends ConsumerState<KonnektedRuntime>
    with WidgetsBindingObserver {
  late final PlayerService _player;
  final _jobNotification = LibraryJobNotification();
  late final WidgetIntentHandler _widgetIntents;
  late final ProviderSubscription<PlayerState> _widgetSync;
  late final _jobProgress = LokalStatusSnack(() => mounted ? context : null);
  late final _playbackProgress = LokalStatusSnack(
    () => mounted ? context : null,
  );
  String? _lastPlaybackProgress;
  void _onPreparationStatus() {
    if (!mounted) return;
    final message = QueuePreResolver.shared.status.value;
    String? status = message;
    if (status == null && _player.isNetworkLoadingNotifier.value) {
      final title =
          _player.onlinePreparationTitleNotifier.value ??
          _player.currentSongNotifier.value?.title;
      final current = _player.currentSongNotifier.value;
      final bufferedMs = _player.bufferedPositionNotifier.value.inMilliseconds;
      final durationMs = _player.durationNotifier.value.inMilliseconds;
      // Progressive HTTP sources do not have a full-download percentage.
      // Use Media3's actual buffered *playback duration*, clearly labelled,
      // rather than a misleading static provider '5%' completion estimate.
      if (current?.sourcePackage == 'konnekted.progressive' &&
          title == current?.title &&
          bufferedMs > 0 &&
          durationMs > 0) {
        final buffered = (bufferedMs * 100 / durationMs).clamp(0, 100).floor();
        status = 'Buffering $title… $buffered% of track buffered';
      } else {
        status = title == null || title.isEmpty
            ? 'Preparing audio…'
            : 'Preparing $title…';
      }
    }
    if (status == null) {
      _lastPlaybackProgress = null;
      _playbackProgress.clear();
    } else if (status != _lastPlaybackProgress || !_playbackProgress.showing) {
      _lastPlaybackProgress = status;
      _playbackProgress.update(status);
    }
  }

  bool _backgrounded = false;
  bool _showingWhatsNew = false;
  bool _showingUpdate = false;
  String? _offeredUpdate;

  void _maybeShowUpdate() {
    final release = ref.read(updateCheckProvider).release;
    if (!mounted ||
        _backgrounded ||
        _showingWhatsNew ||
        _showingUpdate ||
        release == null ||
        release.identity == _offeredUpdate ||
        !ref.read(onboardingCompletedProvider))
      return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _backgrounded ||
          _showingWhatsNew ||
          _showingUpdate ||
          ModalRoute.of(context)?.isCurrent == false)
        return;
      _offeredUpdate = release.identity;
      _showingUpdate = true;
      _run('Update prompt', () async {
        try {
          await showLokalUpdates(context);
        } finally {
          _showingUpdate = false;
          if (mounted) _maybeShowWhatsNew();
        }
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    playbackSourceVerification = (source) async {
      if (!mounted || _backgrounded || source.verify == null) return false;
      // The auth sheet is the very same one Search uses, except the queue
      // remains parked on its pending Mix track until verification finishes.
      return source.verify!(context);
    };
    ref.listenManual(lokalAppearanceProvider, (_, next) {
      LocalMetadataRepair.instance.ultraPerformanceMode =
          next.ultraPerformanceMode;
    }, fireImmediately: true);
    SpotifyLikesSyncService.instance.resume();
    ref.listenManual(libraryJobsProvider, (previous, next) {
      _jobNotification.update(next);
      _updateIconBusy();
      if (next.running)
        _jobProgress.update(next.message);
      else if (previous?.running == true)
        _jobProgress.fail(next.message);
    });
    ref.listenManual(konnektedLibraryProvider, (_, next) {
      final songs = next.value;
      if (songs != null) {
        ref.read(artistMetadataProvider.notifier).warm(songs);
        LocalMetadataRepair.instance.warm(songs);
      }
    }, fireImmediately: true);
    _player = ref.read(playerServiceProvider);
    _player.isPlayingNotifier.addListener(_updateIconBusy);
    _player.isNetworkLoadingNotifier.addListener(_updateIconBusy);
    _player.isNetworkLoadingNotifier.addListener(_onPreparationStatus);
    _player.currentSongNotifier.addListener(_onPreparationStatus);
    _player.onlinePreparationTitleNotifier.addListener(_onPreparationStatus);
    _player.bufferedPositionNotifier.addListener(_onPreparationStatus);
    _player.durationNotifier.addListener(_onPreparationStatus);
    _updateIconBusy();
    _onPreparationStatus();
    _run(
      'Discord presence',
      () => DiscordPresenceService.instance.start(_player),
    );
    ref.read(equalizerProvider);
    ref.listenManual(updateCheckProvider, (_, next) {
      if (next.updateAvailable) _maybeShowUpdate();
    });
    ref.read(updateCheckProvider.notifier);
    _widgetSync = installWidgetSync(ref);
    _widgetIntents = WidgetIntentHandler(
      ref,
      onOpenQueue: () {
        if (mounted) widget.onOpenQueue();
      },
    );
    _run('Widget intent attachment', _widgetIntents.attach);
    _player.playbackDesyncedNotifier.addListener(_onPlaybackDesync);
    _player.onlinePlaybackError.addListener(_onOnlinePlaybackError);
    QueuePreResolver.shared.status.addListener(_onPreparationStatus);

    ref.listenManual(appPreferencesProvider, (_, _) => _maybeShowWhatsNew());
    ref.listenManual(appBuildInfoProvider, (_, _) => _maybeShowWhatsNew());

    ref.listenManual(currentSongProvider, (_, _) => _maybeOpenExternalPlayer());
    ref.listenManual(isPlayingProvider, (_, _) => _maybeOpenExternalPlayer());
    // Songs a scan added still need their details (sample rate, disc,
    // album artist) read in the background. That is not part of the scan:
    // start it straight away and silently, instead of a snackbar per batch
    // (they queued up and read as a scan that never ended).
    ref.listenManual<AsyncValue<int>>(libraryWarmupProvider, (previous, next) {
      final count = next.value ?? 0;
      if (!mounted || count <= (previous?.value ?? 0)) return;
      final service = ref.read(backgroundMetadataServiceProvider);
      if (service != null) {
        _run('Metadata warmup', service.extractPendingMetadata);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeOpenExternalPlayer();
      ref.read(autoLibrarySyncServiceProvider);
      ref.read(updateCheckProvider.notifier).refreshIfOnline();
      _run('Library deletion refresh', () async {
        await LibraryScannerService().refreshDeletions();
        if (!mounted) return;
        ref.invalidate(songsProvider);
        ref.invalidate(musicFoldersProvider);
      });
    });
  }

  void _run(String label, FutureOr<void> Function() operation) {
    unawaited(
      Future<void>.sync(operation).catchError((Object error, StackTrace stack) {
        devLog('$label failed: $error');
      }),
    );
  }

  void _maybeOpenExternalPlayer() {
    if (!mounted) return;
    final song = ref.read(currentSongProvider);
    if (song?.isExternal != true || !ref.read(isPlayingProvider)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || NavigationHelper.isFullPlayerOpen) return;
      if (ref.read(currentSongProvider)?.id == song!.id &&
          ref.read(isPlayingProvider)) {
        widget.onOpenPlayer();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _updateIconBusy() => unawaited(
    LokalLauncherIcon.setBusy(
      _player.isPlayingNotifier.value ||
          _player.isNetworkLoadingNotifier.value ||
          ref.read(libraryJobsProvider).running,
    ),
  );

  void _maybeShowWhatsNew() {
    if (!mounted ||
        _showingWhatsNew ||
        _showingUpdate ||
        !ref.read(onboardingCompletedProvider)) {
      return;
    }
    final notifier = ref.read(whatsNewProvider.notifier);
    notifier.evaluate();
    final entry = ref.read(whatsNewProvider).pendingEntry;
    if (entry == null) return;
    _showingWhatsNew = true;
    _run('What’s new', () async {
      try {
        await notifier.markCurrentVersionSeen();
        if (mounted) await WhatsNewBottomSheet.show(context, entry: entry);
      } finally {
        _showingWhatsNew = false;
        if (mounted) _maybeShowUpdate();
      }
    });
  }

  void _onOnlinePlaybackError() {
    final message = _player.onlinePlaybackError.value;
    if (!mounted || message == null) return;
    LokalToast.show(context, message);
  }

  void _onPlaybackDesync() {
    if (!mounted || !_player.playbackDesyncedNotifier.value) return;
    LokalToast.show(
      context,
      lokalText('Playback needs to be synchronized'),
      actionLabel: lokalText('Sync'),
      onAction: () => _run('Playback sync', _player.syncNow),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _run('Persist playback', _player.persistLastPlayed);
      _run('Widget shutdown sync', WidgetSyncService.instance.pushKilled);
      // Match MainShell: this also deactivates the Android floating overlay.
      _run('Detached player cleanup', _player.onAppResumed);
      _run('Flush app log', AppLog.instance.flushToDisk);
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_backgrounded) return;
      _backgrounded = true;
      SpotifyLikesSyncService.instance.pause();
      ref.read(autoLibrarySyncServiceProvider).notifyPaused();
      _run('Persist playback', _player.persistLastPlayed);
      _run('Widget background sync', WidgetSyncService.instance.pushPaused);
      _run('Pause app lifecycle', _player.onAppPaused);
      _run('Flush app log', AppLog.instance.flushToDisk);
      _finishPausedScrobble();
    } else if (state == AppLifecycleState.resumed) {
      SpotifyLikesSyncService.instance.resume();
      _backgrounded = false;
      _maybeShowUpdate();
      _run('Resume app lifecycle', _player.onAppResumed);
      _run(
        'Widget profile retry',
        WidgetSyncService.instance.retryIosPublication,
      );
      ref.read(updateCheckProvider.notifier).refreshIfOnline();
      _run('Last.fm queue flush', ref.read(lastFmScrobbleQueueProvider).flush);
      _run(
        'ListenBrainz queue flush',
        ref.read(listenbrainzScrobbleQueueProvider).flush,
      );
      ref.read(autoLibrarySyncServiceProvider).notifyResumed();
    }
  }

  void _finishPausedScrobble() {
    final state = ref.read(playerProvider);
    final song = state.currentSong;
    if (song == null || song.isExternal || state.isPlaying) return;
    final seconds = ref.read(playerProvider.notifier).accumulatedListenSeconds;
    _run(
      'Last.fm paused scrobble',
      () => ref
          .read(lastFmScrobbleProvider.notifier)
          .onTrackEnded(
            artist: song.artist,
            track: song.title,
            album: song.album,
            albumArtist: null,
            listenedSeconds: seconds,
            trackDurationSeconds: state.duration.inSeconds,
          ),
    );
    _run(
      'ListenBrainz paused scrobble',
      () => ref
          .read(listenBrainzScrobbleProvider.notifier)
          .onTrackEnded(
            artist: song.artist,
            track: song.title,
            album: song.album,
            albumArtist: null,
            listenedSeconds: seconds,
            trackDurationSeconds: state.duration.inSeconds,
          ),
    );
  }

  @override
  void dispose() {
    playbackSourceVerification = null;
    WidgetsBinding.instance.removeObserver(this);
    SpotifyLikesSyncService.instance.pause();
    _player.playbackDesyncedNotifier.removeListener(_onPlaybackDesync);
    _player.onlinePlaybackError.removeListener(_onOnlinePlaybackError);
    QueuePreResolver.shared.status.removeListener(_onPreparationStatus);
    _playbackProgress.dispose();
    _player.isPlayingNotifier.removeListener(_updateIconBusy);
    _player.isNetworkLoadingNotifier.removeListener(_updateIconBusy);
    _player.isNetworkLoadingNotifier.removeListener(_onPreparationStatus);
    _player.currentSongNotifier.removeListener(_onPreparationStatus);
    _player.onlinePreparationTitleNotifier.removeListener(_onPreparationStatus);
    _player.bufferedPositionNotifier.removeListener(_onPreparationStatus);
    _player.durationNotifier.removeListener(_onPreparationStatus);
    _jobProgress.dispose();
    _jobNotification.dispose();
    _widgetSync.close();
    WidgetSyncService.instance.detachIosRuntime();
    _run('Widget intent detach', _widgetIntents.detach);
    _run('Discord presence shutdown', DiscordPresenceService.instance.stop);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(child: widget.child),
      const Positioned.fill(child: FloatingScanProgress()),
      const UsbBitPerfectPrompt(),
    ],
  );
}
