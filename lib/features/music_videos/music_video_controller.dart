import 'dart:async';

import 'package:flutter/foundation.dart';

/// One clock and transport interface for the native video and the regular
/// Full Player chrome/Space subtitles. Album playback has a separate clock.
class Media3MusicVideoController {
  final positionNotifier = ValueNotifier<Duration>(Duration.zero);
  final durationNotifier = ValueNotifier<Duration>(Duration.zero);
  final playingNotifier = ValueNotifier<bool>(false);
  // A buffering player can still report "playing". Captions must not advance
  // until the source clock actually resumes.
  final advancingNotifier = ValueNotifier<bool>(false);
  final nativeNotifier = ValueNotifier<bool>(true);
  final timingAvailableNotifier = ValueNotifier<bool>(false);
  final embedErrorNotifier = ValueNotifier<int?>(null);
  Future<void> Function(String, Map<String, Object?>)? _send;
  Timer? _ticker;
  final Stopwatch _sampleClock = Stopwatch();
  Duration _samplePosition = Duration.zero;

  /// Last position reported by the transport, before UI interpolation.
  Duration get sourcePosition => _samplePosition;
  bool _buffering = true;
  int _owner = 0;
  bool _disposed = false;

  int attach(Future<void> Function(String, Map<String, Object?>) command) {
    _send = command;
    return ++_owner;
  }

  bool owns(int? owner) => !_disposed && owner == _owner;

  void detach([int? owner]) {
    if (_disposed || (owner != null && !owns(owner))) return;
    _send = null;
    _owner++;
    _ticker?.cancel();
    _ticker = null;
    playingNotifier.value = false;
    advancingNotifier.value = false;
    timingAvailableNotifier.value = false;
  }

  void update({
    required int positionMs,
    required int durationMs,
    required bool playing,
    required bool buffering,
  }) {
    if (_disposed) return;
    _sampleClock
      ..reset()
      ..start();
    _samplePosition = Duration(milliseconds: positionMs);
    _buffering = buffering;
    durationNotifier.value = Duration(milliseconds: durationMs);
    playingNotifier.value = playing;
    advancingNotifier.value = playing && !buffering;
    positionNotifier.value = _samplePosition;
    timingAvailableNotifier.value = true;
    if (!playing || buffering) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!playingNotifier.value || _buffering) return;
      final projected = _samplePosition + _sampleClock.elapsed;
      final duration = durationNotifier.value;
      final capped = duration > Duration.zero && projected > duration
          ? duration
          : projected;
      positionNotifier.value = capped;
    });
  }

  void fallback({int? errorCode}) {
    if (_disposed) return;
    nativeNotifier.value = false;
    playingNotifier.value = false;
    advancingNotifier.value = false;
    timingAvailableNotifier.value = false;
    embedErrorNotifier.value = errorCode;
    _ticker?.cancel();
    _ticker = null;
  }

  void reset() {
    if (_disposed) return;
    _ticker?.cancel();
    _ticker = null;
    positionNotifier.value = Duration.zero;
    durationNotifier.value = Duration.zero;
    playingNotifier.value = false;
    advancingNotifier.value = false;
    nativeNotifier.value = true;
    timingAvailableNotifier.value = false;
    embedErrorNotifier.value = null;
    _sampleClock
      ..stop()
      ..reset();
    _samplePosition = Duration.zero;
    _buffering = true;
  }

  Future<void> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final send = _send;
    if (_disposed || send == null) {
      throw StateError('Video controls are not ready.');
    }
    await send(method, args);
  }

  Future<void> releaseAudio() async {
    if (_disposed) return;
    final owner = _owner;
    final send = _send;
    if (send != null) await send('release', const {});
    if (owns(owner)) {
      _ticker?.cancel();
      _ticker = null;
      playingNotifier.value = false;
      advancingNotifier.value = false;
    }
  }

  Future<void> togglePlayPause() =>
      command(playingNotifier.value ? 'pause' : 'play');
  Future<void> seek(Duration position) =>
      command('seek', {'positionMs': position.inMilliseconds});

  void dispose() {
    if (_disposed) return;
    detach();
    _disposed = true;
    positionNotifier.dispose();
    durationNotifier.dispose();
    playingNotifier.dispose();
    advancingNotifier.dispose();
    nativeNotifier.dispose();
    timingAvailableNotifier.dispose();
    embedErrorNotifier.dispose();
  }
}
