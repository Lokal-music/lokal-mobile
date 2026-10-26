import '../models/song.dart';

/// Snapshot and local controls available only while PlayerService holds its
/// playback queue. A new user selection/pause invalidates [isCurrent] immediately.
class PlaybackOutputTransition {
  const PlaybackOutputTransition({
    required this.song,
    required this.position,
    required this.wasPlaying,
    required this.isCurrent,
    required this.pauseLocal,
    required this.resumeLocal,
  });

  final Song? song;
  final Duration position;
  final bool wasPlaying;
  final bool Function() isCurrent;
  final Future<void> Function() pauseLocal;
  final Future<void> Function() resumeLocal;
}
