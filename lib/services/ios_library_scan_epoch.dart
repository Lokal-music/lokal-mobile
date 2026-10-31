import 'dart:async';

/// A scan keeps the generation in which it was subscribed, including detached
/// metadata work. Library mutations retire that generation synchronously.
/// Repository checks run inside the Isar writer, so an older queued write can
/// never run after the user's mutation. No generation persists across restart:
/// neither does the Dart scan that held it.
class IosLibraryScanEpoch {
  static final _zoneKey = Object();
  static int _epoch = 0, _holds = 0;
  static bool get current => _holds == 0 && Zone.current[_zoneKey] == _epoch;

  /// A reviewed copy plan can outlive its async scan zone. Its authority still
  /// ends synchronously when a library mutation begins, including a clear that
  /// happens to leave the selected server or file path looking unchanged.
  static void Function() consentGuard() {
    final epoch = _epoch;
    void check() {
      if (_holds != 0 || _epoch != epoch) {
        throw StateError('The library changed. Review the copy plan again.');
      }
    }
    check();
    return check;
  }

  static void requireCurrent() {
    if (!current) throw StateError('The library changed. Start a new scan.');
  }

  static Future<T> withMutation<T>(Future<T> Function() mutation) async {
    _epoch++;
    _holds++;
    try {
      return await mutation();
    } finally {
      _holds--;
    }
  }

  static Future<T> run<T>(Future<T> Function() work) {
    if (_holds != 0) {
      return Future.error(StateError('The library is changing.'));
    }
    return runZoned(() => Future<T>.sync(work), zoneValues: {_zoneKey: _epoch});
  }

  /// Forward subscription, pause and cancellation to the original scan. The
  /// source is listened to inside the captured zone, rather than merely being
  /// constructed there (async generators execute on listen).
  static Stream<T> bind<T>(Stream<T> Function() source) {
    late final StreamController<T> output;
    StreamSubscription<T>? input;
    output = StreamController<T>(
      sync: true,
      onListen: () {
        if (_holds != 0) {
          output.addError(StateError('The library is changing.'));
          unawaited(output.close());
          return;
        }
        runZoned(() {
          try {
            input = source().listen(
              output.add,
              onError: output.addError,
              onDone: output.close,
            );
          } catch (error, stack) {
            output.addError(error, stack);
            unawaited(output.close());
          }
        }, zoneValues: {_zoneKey: _epoch});
      },
      onPause: () => input?.pause(),
      onResume: () => input?.resume(),
      onCancel: () => input?.cancel(),
    );
    return output.stream;
  }
}
