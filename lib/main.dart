import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/widgets/lokal/lokal_glass.dart';
import 'package:flick/features/player/widgets/cloud_cover_reveal.dart';
import 'package:flick/src/rust/frb_generated.dart';
import 'package:flick/app/app.dart';
import 'package:flick/data/database.dart';
import 'package:flick/services/app_preferences_service.dart';
import 'package:flick/services/display_mode_service.dart';
import 'package:flick/services/external_playback_service.dart';
import 'package:flick/services/permission_service.dart';
import 'package:flick/providers/onboarding_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/playback_cache_maintenance.dart';
import 'package:flick/services/process_exit_diagnostics_service.dart';
import 'package:flick/services/motion_art/motion_art_memory_pressure.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/core/utils/app_log.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/utils/frame_timings_monitor.dart';
import 'package:flick/src/rust/api/logging.dart';
import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/services/notification_service.dart';

Future<void> main() async {
  await runZonedGuarded(_bootstrapApp, (error, stack) {
    AppLog.instance.add('$error\n$stack', source: LogSource.zone);
  });
}

Future<void> _bootstrapApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Observe memory pressure even when no Now Playing artwork is mounted.
  MotionArtMemoryPressure.instance.start();

  // Snapshot install freshness before anything can write to the preference
  // store: new installations start on the adaptive refresh-rate default.
  await AppPreferencesService.captureInstallFreshness();
  final initialAppearance = await LokalAppearanceNotifier.readSaved();
  AppColors.bind(initialAppearance.tokens);
  await NotificationService().setLokalAccent(
    initialAppearance.tokens.accent.toARGB32(),
  );

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  await AppLog.instance.initializePersistence();
  await Uac2PreferencesService().initializeDeveloperModeCache();
  FrameTimingsMonitor.instance.start();

  // Resolve the UI language before anything can produce a user-visible string.
  // The global `l10n` accessor is a plain global (see lib/l10n/l10n.dart), so
  // service-layer strings need it pointed at the right locale from the start.
  await LocaleController.instance.load();
  LocaleController.instance.bindLocale(
    LocaleController.instance.effectiveLocale,
  );

  FlutterError.onError = (details) {
    AppLog.instance.add(
      '${details.exception}\n${details.stack}',
      source: LogSource.crash,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.add('$error\n$stack', source: LogSource.platform);
    return true;
  };

  await RustLib.init();
  _subscribeRustLogs();
  unawaited(ProcessExitDiagnosticsService().reportPreviousExits());

  await Database.init();

  final externalPlaybackHandled = await ExternalPlaybackService().initialize();
  if (!externalPlaybackHandled) {
    await _restoreLastPlayedSong();
  }

  // Glass renders frosted until the lens is ready, so don't wait for it.
  unawaited(LokalGlassShaders.load());
  runApp(
    ProviderScope(
      overrides: [
        lokalInitialAppearanceProvider.overrideWithValue(initialAppearance),
      ],
      child: const FlickPlayerApp(),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_bootstrapAppAfterFirstFrame());
  });
}

void _subscribeRustLogs() {
  registerLogSink().listen(
    (msg) => AppLog.instance.add(msg, source: LogSource.rust),
    onError: (Object e) => AppLog.instance.add(
      'rust log stream error: $e',
      source: LogSource.rust,
    ),
  );
}

Future<void> _bootstrapAppAfterFirstFrame() async {
  unawaited(DisplayModeService().initialize());
  unawaited(
    _requestNotificationPermission().catchError(
      (Object e) => devLog('Notification permission request failed: $e'),
    ),
  );
  unawaited(
    Uac2Service.instance.initializeAndroidRouteMonitoring().catchError(
      (Object e) => devLog('USB route probe failed: $e'),
    ),
  );
  unawaited(
    PlayerService().prepareForAppLaunch().catchError(
      (Object e) => devLog('Audio prewarm failed: $e'),
    ),
  );
  unawaited(
    runPlaybackCacheMaintenance().catchError(
      (Object e) => devLog('Playback cache maintenance failed: $e'),
    ),
  );
}

Future<void> _requestNotificationPermission() async {
  // First run asks on its last step, in context, instead of at launch.
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(OnboardingCompletedNotifier.prefKey) != true) return;
  final permissionService = PermissionService();
  final hasPermission = await permissionService.hasNotificationPermission();
  if (!hasPermission) {
    await permissionService.requestNotificationPermission();
  }
}

Future<void> _restoreLastPlayedSong() async {
  try {
    final playerService = PlayerService();
    await playerService.restorePlaybackModes();
    await playerService.restoreLastPlayed();
  } catch (e) {
    devLog('Failed to restore last played song: $e');
  }
}
