import 'dart:async';

/// Stops a preview promptly; late I/O must check before publishing or starting
/// another operation. The preview never deletes or transfers audio files.
class CopyCheckGuard {
  CopyCheckGuard({this.limit = const Duration(seconds: 90)});
  final Duration limit;
  final _stopped = Completer<void>();
  StateError? _reason;
  Timer? _idleTimer;
  bool _running = false;
  bool get stopped => _reason != null;

  void cancel() => _stop('File check cancelled.');

  void _stop(String message) {
    if (stopped) return;
    _idleTimer?.cancel();
    _reason = StateError(message);
    _stopped.complete();
  }

  void check() {
    if (_reason case final reason?) throw reason;
  }

  /// The preview may legitimately inspect many files. Only abort when an
  /// individual operation stops making progress, not after 90 seconds total.
  /// Call on completed stages, checked records and fingerprint stream chunks.
  void pulse() {
    check();
    if (!_running) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(
      limit,
      () => _stop(
        'Checking files stopped making progress. Nothing was copied. Reconnect and try again.',
      ),
    );
  }

  Future<T> run<T>(Future<T> Function() work) async {
    check();
    if (_running) throw StateError('A file check is already running.');
    _running = true;
    pulse();
    try {
      return await Future.any([
        work(),
        _stopped.future.then<T>((_) => throw _reason!),
      ]);
    } finally {
      _running = false;
      _idleTimer?.cancel();
    }
  }
}
