import 'package:flutter/material.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';

import 'queue_screen.dart';

/// The miniplayer's queue shares the app's slide-up action surfaces, with a
/// scroll-coupled list that can expand or pull down to dismiss.
/// Returns true when the user wants to open Now Playing, after the sheet has
/// fully left the overlay so the cover transition has a clear source/destination.
Future<bool> showQueueSheet(BuildContext context) async {
  final theme = context.lokal;
  ModalRoute<bool>? route;
  final openPlayer = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: theme.surface,
    barrierColor: Colors.black.withValues(alpha: theme.isLight ? .25 : .5),
    shape: RoundedRectangleBorder(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      side: BorderSide(color: theme.border),
    ),
    builder: (sheetContext) {
      route = ModalRoute.of<bool>(sheetContext);
      return DraggableScrollableSheet(
        key: const ValueKey('miniplayer-queue-sheet'),
        initialChildSize: .55,
        minChildSize: .3,
        maxChildSize: .9,
        expand: false,
        builder: (context, controller) => SafeArea(
          top: false,
          child: AdaptiveColorProvider(
            backgroundColor: theme.surface,
            child: QueueList(
              sheet: true,
              scrollController: controller,
              onOpenPlayer: () => Navigator.of(sheetContext).pop(true),
            ),
          ),
        ),
      );
    },
  );
  await route?.completed;
  return openPlayer == true;
}
