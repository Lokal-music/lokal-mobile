import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/navigation/root_navigator.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:flick/features/queue/screens/queue_sheet.dart';
import 'package:flick/widgets/lokal/lokal_player_route.dart';

/// Helper class to prevent duplicate navigation to FullPlayerScreen
class NavigationHelper {
  // Track if navigation is in progress to prevent double navigation
  static bool _isNavigating = false;
  static Timer? _navigationTimer;

  // Track if FullPlayerScreen is currently open
  static bool _isFullPlayerOpen = false;

  /// Checks if FullPlayerScreen is already on the navigation stack
  static bool _isFullPlayerScreenOnStack(BuildContext context) {
    // First check our flag
    if (_isFullPlayerOpen) {
      return true;
    }

    // Check the current route
    final route = ModalRoute.of(context);
    if (route?.settings.name == '/full_player') {
      return true;
    }

    return false;
  }

  /// Returns true if the full player is currently open or navigation is in progress.
  static bool get isFullPlayerOpen => _isFullPlayerOpen || _isNavigating;

  /// Opens Now Playing as a sheet rising out of the mini player. [startTop]
  /// gives the mini player's top edge, where the sheet starts and lands
  /// (null: the bottom of the screen); [initialProgress] is how far a pull
  /// on the mini player already brought it ([pullFullPlayer]).
  static Future<int?> navigateToFullPlayer(
    BuildContext context, {
    required String heroTag,
    double? Function()? startTop,
    double? initialProgress,
    Rect? Function()? sourceArtwork,
    Key? playerKey,
  }) async {
    // Prevent multiple simultaneous navigations
    if (_isNavigating || _isFullPlayerOpen) {
      return null;
    }

    // Check if FullPlayerScreen is already on the stack
    if (_isFullPlayerScreenOnStack(context)) {
      return null;
    }

    // Set flags immediately to prevent double navigation
    _isNavigating = true;
    _isFullPlayerOpen = true;

    // Clear any existing timer
    _navigationTimer?.cancel();

    // Reset navigation flag after navigation animation completes
    _navigationTimer = Timer(const Duration(milliseconds: 800), () {
      _isNavigating = false;
    });

    if (!context.mounted) {
      _isNavigating = false;
      _isFullPlayerOpen = false;
      _navigationTimer?.cancel();
      _navigationTimer = null;
      return null;
    }

    try {
      // Navigate to full player screen on the root navigator so it covers
      // the persistent bottom bar. Falls back to the local navigator during
      // tests where the root key is not mounted.
      final navigator = rootNavigatorKey.currentState != null
          ? rootNavigatorKey.currentState!
          : Navigator.of(context);
      final route = LokalPlayerRoute<int>(
        builder: (context) =>
            FullPlayerScreen(key: playerKey, heroTag: heroTag),
        startTop: startTop,
        initialProgress: initialProgress,
        sourceArtwork: sourceArtwork,
        reduceMotion: () => AppConstants.animationNormal == Duration.zero,
        settings: const RouteSettings(name: '/full_player'),
      );
      final result = await navigator.push<int>(route);

      // Reset flags after navigation completes (screen was popped)
      _isFullPlayerOpen = false;
      _isNavigating = false;
      _navigationTimer?.cancel();
      _navigationTimer = null;

      return result;
    } catch (e) {
      // If navigation fails, reset flags
      _isFullPlayerOpen = false;
      _isNavigating = false;
      _navigationTimer?.cancel();
      _navigationTimer = null;
      rethrow;
    }
  }

  /// A pull up on the mini player: Now Playing rises under the finger and,
  /// once let go far or fast enough, opens with [navigateToFullPlayer] from
  /// where it got to ([onOpen] runs that). Null while the player is open.
  static LokalPlayerPull? pullFullPlayer(
    BuildContext context, {
    required String heroTag,
    required double? Function() startTop,
    required void Function(double progress) onOpen,
    Rect? Function()? sourceArtwork,
    VoidCallback? onClosed,
    Key? playerKey,
  }) {
    if (_isNavigating || _isFullPlayerOpen) return null;
    final navigator = rootNavigatorKey.currentState ?? Navigator.of(context);
    return LokalPlayerPull.start(
      navigator,
      builder: (_) => FullPlayerScreen(key: playerKey, heroTag: heroTag),
      startTop: startTop,
      onOpen: onOpen,
      sourceArtwork: sourceArtwork,
      onClosed: onClosed,
      reduceMotion: () => AppConstants.animationNormal == Duration.zero,
    );
  }

  static Future<T?> navigateToQueue<T>(
    BuildContext context, {
    Future<void> Function()? onOpenPlayer,
  }) async {
    final openPlayer = await showQueueSheet(context);
    if (!openPlayer || !context.mounted) return null;
    if (onOpenPlayer != null) {
      await onOpenPlayer();
    } else {
      await navigateToFullPlayer(context, heroTag: 'album_art_hero');
    }
    return null;
  }

  /// Push on the root navigator so the persistent bottom bar is hidden.
  static Future<T?> pushOnRoot<T>(BuildContext context, Route<T> route) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator != null) return navigator.push<T>(route);
    return Navigator.of(context, rootNavigator: true).push<T>(route);
  }

  /// Fade-only push for screens that share the persistent blurred background.
  /// A slide would drag the opaque ambient background with the route and look
  /// like the artwork is panning; a fade keeps the background visually static.
  static Future<T?> pushFade<T>(
    BuildContext context,
    WidgetBuilder builder, {
    RouteSettings? settings,
  }) {
    return Navigator.of(context).push<T>(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          if (AppConstants.animationNormal == Duration.zero) {
            return child;
          }
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(opacity: curved, child: child);
        },
        transitionDuration: AppConstants.animationNormal,
        reverseTransitionDuration: AppConstants.animationFast,
        settings: settings,
      ),
    );
  }
}
