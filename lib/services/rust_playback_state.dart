/// Playback states published by the native Rust engine.
enum RustPlaybackState {
  idle,
  playing,
  paused,
  buffering,
  crossfading,
  stopped,
}
