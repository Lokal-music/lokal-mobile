import 'dart:async';

import 'rust_playback_state.dart';

/// Schedules read-only engine observations; it never starts an audio output.
/// Foreground changes only rearm observations already owned by this session.
class RustAudioPolling {
  RustAudioPolling({
    required this.state,
    required this.progress,
    required this.events,
  });

  final RustPlaybackState Function() state;
  final void Function() progress;
  final void Function() events;
  bool _foreground = true;
  bool _progressEnabled = false;
  bool _eventsEnabled = false;
  int _progressRevision = 0;
  int _eventRevision = 0;
  Timer? _progressTimer;
  Timer? _eventTimer;
  bool Function()? _transitionComplete;
  int _transitionPolls = 0;
  int _debugProgressCallbacks = 0;
  int _debugEventCallbacks = 0;

  bool get observingEvents => _eventsEnabled;

  /// Debug assertions count observation batches, not all native FFI calls.
  ({int progress, int events}) get debugCounts =>
      (progress: _debugProgressCallbacks, events: _debugEventCallbacks);

  bool get _active => switch (state()) {
    RustPlaybackState.playing ||
    RustPlaybackState.buffering ||
    RustPlaybackState.crossfading => true,
    _ => false,
  };

  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (_eventsEnabled) startEvents(until: _transitionComplete);
    if (_progressEnabled) startProgress();
  }

  void startProgress() {
    stopProgress();
    _progressEnabled = true;
    _scheduleProgress(_progressRevision);
  }

  void stopProgress() {
    _progressEnabled = false;
    _progressRevision++;
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _scheduleProgress(int revision) {
    if (!_progressEnabled || revision != _progressRevision) return;
    if (!_active) {
      _progressEnabled = false;
      return;
    }
    _progressTimer = Timer(Duration(milliseconds: _foreground ? 50 : 250), () {
      _progressTimer = null;
      try {
        assert(() {
          _debugProgressCallbacks++;
          return true;
        }());
        progress();
      } finally {
        _scheduleProgress(revision);
      }
    });
  }

  void startEvents({bool Function()? until}) {
    _eventsEnabled = true;
    _transitionComplete = until;
    // Queued native commands are not acknowledgement of applied state. Poll
    // promptly for at most two seconds, then return to the steady-state rate.
    _transitionPolls = until == null ? 0 : (_foreground ? 40 : 8);
    final revision = ++_eventRevision;
    _eventTimer?.cancel();
    _eventTimer = null;
    _pollEvents(revision);
  }

  void stopEvents() {
    _eventsEnabled = false;
    _eventRevision++;
    _eventTimer?.cancel();
    _eventTimer = null;
    _transitionComplete = null;
    _transitionPolls = 0;
  }

  void _pollEvents(int revision) {
    try {
      assert(() {
        _debugEventCallbacks++;
        return true;
      }());
      events();
    } finally {
      // A callback can retire this output or synchronously start another
      // session. Its old timer must never resurrect or duplicate that work.
      if (_eventsEnabled && revision == _eventRevision) {
        if (_active && _progressTimer == null) {
          startProgress();
        } else if (!_active && _progressEnabled) {
          stopProgress();
        }
        if (_transitionComplete?.call() == true) _transitionPolls = 0;
        final transitioning = _transitionPolls > 0;
        if (transitioning) _transitionPolls--;
        if (_transitionPolls == 0) _transitionComplete = null;
        final interval = transitioning
            ? Duration(milliseconds: _foreground ? 50 : 250)
            : switch (state()) {
                RustPlaybackState.playing ||
                RustPlaybackState.buffering ||
                RustPlaybackState.crossfading => Duration(
                  milliseconds: _foreground ? 50 : 250,
                ),
                RustPlaybackState.paused => Duration(
                  milliseconds: _foreground ? 500 : 1000,
                ),
                _ => Duration(seconds: _foreground ? 1 : 2),
              };
        _eventTimer = Timer(interval, () {
          _eventTimer = null;
          _pollEvents(revision);
        });
      }
    }
  }

  void stop() {
    stopProgress();
    stopEvents();
  }
}
