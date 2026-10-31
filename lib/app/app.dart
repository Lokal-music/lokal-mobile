import 'package:flick/core/theme/lokal_performance_scope.dart';
import 'package:flick/services/notification_service.dart';
import 'package:flick/services/widget_sync_service.dart';
import 'package:flick/features/appearance/lokal_performance_advisor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_interaction.dart';
import 'package:flick/core/navigation/root_navigator.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/features/onboarding/screens/onboarding_screen.dart';
import 'package:flick/widgets/common/connection_notice_host.dart';
import 'package:flick/services/lokal_launcher_icon.dart';
import 'package:flick/features/konnekted/konnekted_shell.dart';
import 'package:flick/l10n/l10n.dart';

/// Main application widget for Flick Player.
class FlickPlayerApp extends StatelessWidget {
  const FlickPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final appearance = ref.watch(lokalAppearanceProvider);
        // The launcher icon's sticker follows the accent, like desktop's
        // Dock icon.
        ref.listen(lokalAppearanceProvider, (_, next) {
          LokalLauncherIcon.sync(next);
          NotificationService().setLokalAccent(next.tokens.accent.toARGB32());
          WidgetSyncService.instance.setLokalAccent(
            next.tokens.accent.toARGB32(),
          );
        });
        final tokens = appearance.tokens;
        // Also initialize the current accent after process restart.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final current = ref.read(lokalAppearanceProvider);
          LokalLauncherIcon.sync(current);
          NotificationService().setLokalAccent(
            current.tokens.accent.toARGB32(),
          );
          WidgetSyncService.instance.setLokalAccent(
            current.tokens.accent.toARGB32(),
          );
        });
        // The older screens read AppColors directly; point it at the new
        // tokens and rebuild everything once so they all follow at once.
        if (AppColors.bind(tokens)) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildAll());
        }
        final iconBrightness = tokens.isLight
            ? Brightness.dark
            : Brightness.light;
        // Set system UI overlay style for immersive experience
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: iconBrightness,
            systemNavigationBarColor: tokens.bg,
            systemNavigationBarIconBrightness: iconBrightness,
          ),
        );
        return ValueListenableBuilder<Locale?>(
          valueListenable: LocaleController.instance,
          builder: (context, selectedLocale, _) =>
              _app(context, selectedLocale, appearance),
        );
      },
    );
  }

  Widget _app(
    BuildContext context,
    Locale? selectedLocale,
    LokalAppearance appearance,
  ) {
    return MaterialApp(
      scrollBehavior: const LokalScrollBehavior(),
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      theme: LokalTheme.build(appearance.tokens),
      // A theme or accent change cross-fades every colour at once.
      themeAnimationDuration: const Duration(milliseconds: 200),
      themeAnimationCurve: Curves.easeInOutCubic,
      navigatorKey: rootNavigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      // null means "follow the device locale".
      locale: selectedLocale,
      home: const _RootRouter(),
      // Global connectivity notice. It sits below the app content so it is
      // never covered by routes and never covers any interface itself.
      builder: (context, child) {
        // Keep the global `l10n` accessor pointed at the active locale, so
        // service-layer strings resolve consistently with the widget layer.
        LocaleController.instance.bind(AppLocalizations.of(context));
        // Desktop's Text Size multiplies the system text scale.
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: _ScaledTextScaler(
              media.textScaler,
              appearance.textScale,
            ),
          ),
          child: LokalPerformanceScope(
            enabled: appearance.ultraPerformanceMode,
            child: Consumer(
              builder: (context, ref, _) => ConnectionNoticeHost(
                showNotice: ref.watch(
                  appPreferencesProvider.select(
                    (preferences) => preferences.connectionNoticesEnabled,
                  ),
                ),
                child: LokalPerformanceAdvisor(
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Marks every element dirty, as a hot reload does, so widgets that read
/// [AppColors] statically pick up a theme or accent change without losing
/// their state.
void _rebuildAll() {
  void rebuild(Element element) {
    element.markNeedsBuild();
    element.visitChildren(rebuild);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(rebuild);
}

/// The system text scale times the listener's Lokal text size.
class _ScaledTextScaler extends TextScaler {
  const _ScaledTextScaler(this.system, this.factor);

  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => system.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is _ScaledTextScaler &&
      other.system == system &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);
}

class _RootRouter extends ConsumerWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboardingComplete = ref.watch(onboardingCompletedProvider);
    final appPreferences = ref.watch(appPreferencesProvider);

    // Apply animation and haptic preferences globally.
    // When the OS requests reduced motion (e.g. Accessibility "remove
    // animations"), that flag wins over the in-app preference so the app
    // settles into a static state like native Android apps do.
    final systemReducedMotion = MediaQuery.of(context).disableAnimations;
    final animationsEnabled =
        appPreferences.animationsEnabled && !systemReducedMotion;
    AppConstants.setAnimationsEnabled(animationsEnabled);
    AppHaptics.setEnabled(appPreferences.hapticsEnabled);

    final child = onboardingComplete
        ? const KonnektedShell()
        : const OnboardingScreen();

    return MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(disableAnimations: !animationsEnabled),
      child: child,
    );
  }
}
