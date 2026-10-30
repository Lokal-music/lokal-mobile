import 'dart:async';

/// Drains foreground desktop copies before an iPhone library mutation. The
/// native transfer journal has its own barrier; this covers the existing Dart
/// paths, including requests already past their last connection check.
class IosForegroundTransferBarrier {
  final _zoneKey = Object();
  final _pending = <Object, Future<void>>{};
  final _abort = <Object, List<void Function()>>{};
  int _holds = 0, _epoch = 0;
  bool get paused => _holds > 0;
  int get epoch => _epoch;

  Future<T> run<T>(Future<T> Function() operation) {
    if (paused) {
      return Future.error(
        StateError('The library is changing. Retry the transfer afterward.'),
      );
    }
    final token = Object();
    final result = Completer<T>();
    final drained = Completer<void>();
    _pending[token] = drained.future;
    _abort[token] = [];
    runZoned(() {
      Future<T>.sync(operation)
          .then(result.complete, onError: result.completeError);
    }, zoneValues: {_zoneKey: token});
    return result.future.whenComplete(() {
      _pending.remove(token);
      _abort.remove(token);
      drained.complete();
    });
  }

  /// A client registered by a tracked request closes immediately on pause.
  /// Requests outside this barrier are unaffected.
  void cancelOnPause(void Function() cancel) {
    final token = Zone.current[_zoneKey];
    final callbacks = _abort[token];
    if (callbacks == null) return;
    callbacks.add(cancel);
    if (paused) cancel();
  }

  Future<T> withMutation<T>(Future<T> Function() mutation) async {
    _holds++;
    _epoch++;
    try {
      for (final callbacks
          in _abort.values.map(List<void Function()>.of).toList()) {
        for (final cancel in callbacks) {
          // Closing an already completed client may throw; its tracked future
          // must still finish before the database mutation is admitted.
          try {
            cancel();
          } catch (_) {}
        }
      }
      while (_pending.isNotEmpty) {
        await Future.wait(_pending.values.toList());
      }
      return await mutation();
    } finally {
      _holds--;
    }
  }
}
