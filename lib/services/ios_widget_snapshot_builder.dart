import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flick/models/ios_widget_snapshot.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';

enum IosWidgetFlowKind { none, flow, radio }

/// Stable opaque alias for an app-owned identity. The future command inbox
/// resolves aliases in the app; the extension never receives source paths,
/// remote IDs, HTTP headers or stream URLs.
String iosWidgetTrackAlias(String identity) => sha256
    .convert(utf8.encode('lokal-widget-track-v1\u0000$identity'))
    .toString();

/// Prepare a single atomic snapshot from canonical state, without starting
/// discovery, fetching artwork, activating a session or constructing a player.
/// This is not yet wired to the Android publisher or an iOS App Group.
IosWidgetSnapshot buildIosWidgetSnapshot(
  PlayerState state, {
  required DateTime updatedAt,
  required int revision,
  required int accentArgb,
  String? lastArtwork,
  Map<String, String> artworkNamesBySongId = const {},
  Iterable<Song> recommendations = const [],
  IosWidgetFlowKind flowKind = IosWidgetFlowKind.none,
  String flowStatus = '',
}) {
  Map<String, Object?> track(Song song) => {
    'id': iosWidgetTrackAlias(song.id),
    'title': song.title,
    'artist': song.artist,
    'album': song.album,
    // Accept only filenames returned by the future owned-artwork writer.
    'artwork': artworkNamesBySongId[song.id],
  };

  return IosWidgetSnapshot.fromJson({
    'schemaVersion': IosWidgetSnapshot.schemaVersion,
    'revision': revision,
    'updatedAtMs': updatedAt.millisecondsSinceEpoch,
    'current': state.currentSong == null ? null : track(state.currentSong!),
    'lastArtwork': lastArtwork,
    'isPlaying': state.isPlaying,
    'isBuffering': state.isBuffering,
    'positionMs': state.position.inMilliseconds,
    'durationMs': state.duration.inMilliseconds,
    'playbackRate': state.playbackSpeed,
    'queueCount': state.upNext.length,
    'accentArgb': accentArgb,
    'flowKind': flowKind.name,
    'flowStatus': flowStatus,
    'recommendations': [
      for (final song in recommendations.take(48)) track(song),
    ],
  });
}
