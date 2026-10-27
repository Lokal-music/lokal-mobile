import 'dart:async';

/// Share one muted video decoder between Now Playing and its thumbnail. A short
/// handoff window retains its position while one view replaces the other.
class SharedMotionPlayback<T> {
  SharedMotionPlayback({
    required this.create,
    required this.activate,
    required this.dispose,
    this.handoff = const Duration(milliseconds: 500),
  });
  final Future<T> Function(String url) create;
  final Future<void> Function(T resource, bool active) activate;
  final Future<void> Function(T resource) dispose;
  final Duration handoff;
  final _entries = <String, _Entry<T>>{};

  Future<MotionPlaybackLease<T>> acquire(String key, String url) async {
    final id = '$key\u0000$url';
    final entry = _entries.putIfAbsent(id, () => _Entry(create(url)));
    entry.timer?.cancel();
    final token = Object();
    entry.users[token] = false;
    try {
      final resource = await entry.ready;
      entry.resource = resource;
      return _lease(id, entry, token, resource);
    } catch (_) {
      entry.users.remove(token);
      if (entry.users.isEmpty && identical(_entries[id], entry))
        _entries.remove(id);
      rethrow;
    }
  }

  /// Synchronous handoff for a preview: it may paint an already decoded frame
  /// even with TickerMode disabled, without doing a lookup or creating video.
  MotionPlaybackLease<T>? acquireExisting(String key) {
    for (final item in _entries.entries) {
      final entry = item.value;
      final resource = entry.resource;
      if (!item.key.startsWith('$key\u0000') || resource == null) continue;
      entry.timer?.cancel();
      final token = Object();
      entry.users[token] = false;
      return _lease(item.key, entry, token, resource);
    }
    return null;
  }

  MotionPlaybackLease<T> _lease(
    String id,
    _Entry<T> entry,
    Object token,
    T resource,
  ) {
    return MotionPlaybackLease._(
      resource,
      (value) {
        if (!entry.users.containsKey(token)) return Future.value();
        entry.users[token] = value;
        return _sync(entry);
      },
      (immediate) async {
        entry.users.remove(token);
        if (entry.users.isNotEmpty) {
          await _sync(entry);
        } else {
          // No view needs frames now. Pause immediately, even when retaining
          // the decoder briefly for a mini/full-player handoff. Otherwise
          // ExoPlayer continues rendering a video nobody can see.
          final pause = _sync(entry);
          if (immediate) {
            await pause.catchError((Object _) {});
            await _remove(id, entry);
          } else {
            unawaited(pause.catchError((Object _) {}));
            entry.timer = Timer(handoff, () => unawaited(_remove(id, entry)));
          }
        }
      },
    );
  }

  Future<void> _sync(_Entry<T> entry) {
    final playing = entry.users.values.any((active) => active);
    if (entry.playing == playing) return entry.tail;
    entry.playing = playing;
    return entry.tail = entry.tail.catchError((Object _) {}).then((_) async {
      await activate(await entry.ready, playing);
    });
  }

  Future<void> _remove(String id, _Entry<T> entry) async {
    if (entry.users.isNotEmpty || !identical(_entries[id], entry)) return;
    _entries.remove(id);
    entry.timer?.cancel();
    try {
      await entry.tail.catchError((Object _) {});
      await dispose(await entry.ready);
    } catch (_) {
      /* A platform decoder can already have been released. */
    }
  }
}

class _Entry<T> {
  _Entry(this.ready);
  final Future<T> ready;
  T? resource;
  final users = <Object, bool>{};
  Timer? timer;
  bool playing = false;
  Future<void> tail = Future.value();
}

class MotionPlaybackLease<T> {
  MotionPlaybackLease._(this.resource, this._activate, this._release);
  final T resource;
  final Future<void> Function(bool) _activate;
  final Future<void> Function(bool) _release;
  bool _released = false;
  Future<void> setActive(bool active) =>
      _released ? Future.value() : _activate(active);
  Future<void> release({bool immediate = false}) async {
    if (_released) return;
    _released = true;
    await _release(immediate);
  }
}
