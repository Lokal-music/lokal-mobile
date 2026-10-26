import 'package:flick/models/audio_engine_type.dart';

/// Picks a backend that can decode the track while retaining source ownership.
///
/// The Android system tier (just_audio/ExoPlayer) cannot decode DSD
/// (DSF/DFF) or WavPack containers. When the audio route prefers that tier
/// but the track needs the Rust decoder, route it to the Rust shared output
/// so it still plays as PCM on non-bit-perfect routes (speaker/Bluetooth).
/// Every other combination keeps the route-derived preference untouched.
AudioEngineType resolveEngineForSong({
  required AudioEngineType preferred,
  required bool requiresRustDecoder,
  bool isAtmosJoc = false,
  bool requiresSystemStreaming = false,
}) {
  if (requiresSystemStreaming &&
      (preferred == AudioEngineType.iosSystem ||
          preferred == AudioEngineType.iosRust)) {
    // Add-on stream handles belong to the Dart/just_audio streaming adapter.
    // Rust must not receive their opaque locators as filesystem paths.
    return AudioEngineType.iosSystem;
  }
  if (preferred == AudioEngineType.iosSystem) {
    return requiresRustDecoder ? AudioEngineType.iosRust : preferred;
  }
  if (preferred == AudioEngineType.iosRust) return preferred;
  // Rust/Oboe PCM decoding discards JOC object metadata. Keep verified
  // Dolby Digital Plus with Atmos on Android's Media3/AudioTrack path.
  if (isAtmosJoc) return AudioEngineType.normalAndroid;
  if (!requiresRustDecoder || preferred.usesRustBackend) {
    return preferred;
  }
  return AudioEngineType.rustOboe;
}
