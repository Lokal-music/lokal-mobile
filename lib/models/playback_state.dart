import 'package:flutter/foundation.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/song.dart';

@immutable
class PlaybackState {
  final Song? currentTrack;
  final bool isPlaying;
  final bool isBuffering;
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;
  final AudioEngineType engine;

  const PlaybackState({
    required this.currentTrack,
    required this.isPlaying,
    this.isBuffering = false,
    required this.position,
    required this.bufferedPosition,
    required this.duration,
    required this.engine,
  });

  factory PlaybackState.empty(AudioEngineType engine) => PlaybackState(
    currentTrack: null,
    isPlaying: false,
    position: Duration.zero,
    bufferedPosition: Duration.zero,
    duration: Duration.zero,
    engine: engine,
  );

  PlaybackState copyWith({
    Song? currentTrack,
    bool? isPlaying,
    bool? isBuffering,
    Duration? position,
    Duration? bufferedPosition,
    Duration? duration,
    AudioEngineType? engine,
    bool clearTrack = false,
  }) {
    return PlaybackState(
      currentTrack: clearTrack ? null : (currentTrack ?? this.currentTrack),
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      position: position ?? this.position,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      duration: duration ?? this.duration,
      engine: engine ?? this.engine,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackState &&
          runtimeType == other.runtimeType &&
          other.currentTrack?.id == currentTrack?.id &&
          other.isPlaying == isPlaying &&
          other.isBuffering == isBuffering &&
          other.position == position &&
          other.bufferedPosition == bufferedPosition &&
          other.duration == duration &&
          other.engine == engine;

  @override
  int get hashCode => Object.hash(
    currentTrack?.id,
    isPlaying,
    isBuffering,
    position,
    bufferedPosition,
    duration,
    engine,
  );
}
