import 'dart:async';

/// Serializes destructive app mutations against the iPhone transfer owner.
///
/// A failed pause must fail closed: no mutation is executed and no premature
/// resume is sent. A successful pause is always paired with exactly one resume,
/// including when the storage operation throws.
class IosTransferMutationBarrier {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>({
    required Future<void> Function() pause,
    required Future<void> Function() resume,
    required Future<T> Function() mutate,
  }) {
    final previous = _tail;
    final completed = Completer<void>();
    _tail = completed.future;

    return () async {
      await previous;
      try {
        await pause();
        try {
          return await mutate();
        } finally {
          await resume();
        }
      } finally {
        completed.complete();
      }
    }();
  }
}
