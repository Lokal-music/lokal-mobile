import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/services/uac2_preferences_service.dart';

/// Physical USB attachment, not current routing or the song's codec, decides
/// if the Now Playing menu offers DAC recovery. The player can be on Android
/// fallback while a connected DAC still needs its engine restarted.
Future<bool> isUsbDacPhysicallyConnected() async {
  if (!Platform.isAndroid) return false;
  try {
    return (await Uac2Service.instance.listDevices(
      verifyPhysicalAttachment: true,
    )).isNotEmpty;
  } catch (_) {
    // A transient UsbManager failure must not invent a connected DAC.
    return false;
  }
}

/// Build the Now Playing menu from the current track, not an old song snapshot.
/// Device discovery is inventory-only and never opens or claims the USB route.
Future<void> showFullPlayerSongMenu(
  BuildContext context, {
  required Song song,
  required PlayerService player,
  List<LokalSongMenuAction> extras = const [],
}) async {
  final connectedDac = await isUsbDacPhysicallyConnected();
  if (!context.mounted) return;

  // The track may have advanced while Android enumerated USB devices.
  final current = player.currentSongNotifier.value ?? song;
  await SongActionsBottomSheet.show(
    context,
    current,
    nowPlaying: true,
    extras: [
      ...extras,
      if (connectedDac)
        LokalSongMenuAction(
          icon: Icons.restart_alt_rounded,
          label: 'Force restart USB audio engine',
          onTap: () {
            unawaited(_restartUsbEngineFromFullPlayer(context, player));
          },
        ),
    ],
  );
}

Future<void> _restartUsbEngineFromFullPlayer(
  BuildContext context,
  PlayerService player,
) async {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  void notice(String message, {bool short = false}) {
    if (!context.mounted || messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: short ? 3 : 7),
    ));
  }

  if (await Uac2PreferencesService().getAudioEnginePreference() !=
      AudioEnginePreference.isochronousUsb) {
    notice('Select Isochronous USB as the playback engine in USB DAC '
        'settings before restarting.', short: true);
    return;
  }
  if (!context.mounted) return;
  notice('Restarting USB DAC audio engine…');
  bool restored = false;
  try {
    restored = await player.forceRestartUsbAudioEngine();
  } catch (_) {
    restored = false;
  }
  notice(
    restored
        ? 'USB engine verified. Track restarted from the beginning.'
        : 'USB restart failed. Check the connected DAC and logs.',
    short: !restored,
  );
}
