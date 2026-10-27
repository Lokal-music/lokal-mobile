import 'dart:async';

import 'package:flick/services/local_audio_lifecycle.dart';

/// Tracks native objects synchronously when constructed, including objects not
/// yet returned by an asynchronous player factory. Disposal acknowledgement is
/// shared across wrapper, provider and reset cleanup callers.
class LocalAudioOutputRegistry<T extends Object> {
  final _outputs = <T, Future<void> Function()>{};
  final _disposals = Expando<Future<void>>();
  Future<void>? _retirement;

  T create(T Function() construct, Future<void> Function(T) destroy) {
    if (_retirement != null) throw const LocalAudioRequestRetired();
    final output = construct();
    _outputs[output] = () => destroy(output);
    return output;
  }

  Future<void> dispose(T output) {
    final existing = _disposals[output];
    if (existing != null) return existing;
    final destroy = _outputs[output];
    if (destroy == null) {
      throw StateError('Native output has no registered owner');
    }
    final work = Future<void>.sync(destroy);
    _disposals[output] = work;
    // Observe immediately even when the first caller has already retired. Keep
    // a failed output retained so later reset cleanup cannot report success.
    work.then<void>(
      (_) => _outputs.remove(output),
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }

  Future<void> retireAll() {
    final previous = _retirement;
    if (previous != null) return previous;
    final work = Future.wait<void>([
      for (final output in _outputs.keys.toList()) dispose(output),
    ]).then<void>((_) {});
    _retirement = work;
    work.then<void>(
      (_) => _retirement = null,
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }
}
