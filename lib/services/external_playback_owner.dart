/// A native/video output must acknowledge release before another player starts.
/// PlayerService serializes acquisitions and local output operations; a surface
/// may also release its own lease when the user explicitly leaves video mode.
class ExternalPlaybackOwner {
  ExternalPlaybackLease? _current;
  int _revision = 0;

  Future<void> releaseCurrent() async {
    while (_current != null) {
      final lease = _current!;
      await lease.release();
      if (identical(_current, lease)) _current = null;
    }
  }

  Future<void> retireForMediaReset() {
    final lease = _current;
    if (lease == null || lease.isReleased) return Future<void>.value();
    return lease._onMediaReset == null
        ? releaseCurrent()
        : lease._retireForMediaReset();
  }

  ExternalPlaybackLease claim(
    Future<void> Function() release, {
    Future<void> Function()? onMediaReset,
  }) {
    if (_current?.isReleased == false) {
      throw StateError('The previous output has not released audio.');
    }
    final revision = ++_revision;
    final lease = ExternalPlaybackLease._(
      release,
      () => revision == _revision,
      onMediaReset,
    );
    _current = lease;
    return lease;
  }
}

class ExternalPlaybackLease {
  ExternalPlaybackLease._(this._release, this._isLatest, this._onMediaReset);
  final Future<void> Function() _release;
  final bool Function() _isLatest;
  final Future<void> Function()? _onMediaReset;
  Future<void>? _resetInFlight;
  Future<void>? _inFlight;
  bool _released = false;
  bool get isReleased => _released;
  bool get isLatest => _isLatest();

  Future<void> _retireForMediaReset() {
    if (_resetInFlight != null) return _resetInFlight!;
    late final Future<void> work;
    work = Future<void>.sync(_onMediaReset!).whenComplete(() {
      if (identical(_resetInFlight, work)) _resetInFlight = null;
    });
    _resetInFlight = work;
    return work;
  }

  Future<void> release() {
    if (_released) return Future<void>.value();
    if (_inFlight != null) return _inFlight!;
    late final Future<void> operation;
    operation = Future<void>.sync(_release)
        .then((_) {
          _released = true;
        })
        .whenComplete(() {
          if (identical(_inFlight, operation)) _inFlight = null;
        });
    _inFlight = operation;
    return operation;
  }
}
