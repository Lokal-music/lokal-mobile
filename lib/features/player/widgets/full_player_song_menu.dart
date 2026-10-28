import 'package:flutter/material.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';

/// Shared full-player actions follow playback while the menu remains open.
/// Android direct-USB restart is outside the iPhone port's transport scope.
Future<void> showFullPlayerSongMenu(
  BuildContext context, {
  required Song song,
  required PlayerService player,
  List<LokalSongMenuAction> extras = const [],
  bool keepBrowseActions = false,
}) => SongActionsBottomSheet.show(
  context,
  player.currentSongNotifier.value ?? song,
  nowPlaying: !keepBrowseActions,
  followPlaybackSong: true,
  hideMediaActions: true,
  extras: extras,
);
