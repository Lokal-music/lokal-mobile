import 'dart:async';

import 'package:flutter/foundation.dart';

enum LocalAudioPhase { ready, lost, recovering, paused, blocked }

enum LocalAudioNativeEvent { lost, reset }

class LocalAudioRequestRetired implements Exception {
  const LocalAudioRequestRetired();

  @override
  String toString() => 'Local audio request retired by media-services reset';
}

class LocalAudioUnavailable implements Exception {
  const LocalAudioUnavailable(this.phase);
  final LocalAudioPhase phase;

  @override
  String toString() => phase == LocalAudioPhase.blocked
      ? 'Audio cleanup could not be confirmed. Restart the app to play locally.'
      : 'iOS media services are unavailable. Try Play after services return.';
}

/// Owns local reset cleanup independently of the player's operation queue.
/// Remote receiver controls deliberately do not enter this scope.
///
/// Native notification handling advances [nativeEpoch] before notifying Dart.
/// Every asynchronous local operation must enter [run], preserve its zone through
/// fallback/retry, and pass [requestEpoch] to native mutating requests. This
/// component alone does not install observers or enable reset recovery.
class LocalAudioLifecycle {
  LocalAudioLifecycle({
    required BigInt Function() nativeEpoch,
    required this.destroyNativeOutput,
    required this.restoreSession,
  }) : _nativeEpoch = nativeEpoch,
       _epoch = nativeEpoch();

  final BigInt Function() _nativeEpoch;
  final Future<void> Function() destroyNativeOutput;
  final Future<void> Function() restoreSession;
  final _zoneKey = Object();
  final _participants = <Object, Future<void> Function()>{};
  final _requests = <_LocalAudioRequest>{};
  final phase = ValueNotifier(LocalAudioPhase.ready);
  BigInt _epoch;
  Future<void> _cleanup = Future<void>.value();
  Object? cleanupError;

  BigInt get epoch => _epoch;

  /// Retire synchronously, then return actual disposal acknowledgement. A
  /// participant must coalesce repeated disposal of the same native objects.
  void register(Object owner, Future<void> Function() retireAndDispose) {
    if (phase.value != LocalAudioPhase.ready &&
        phase.value != LocalAudioPhase.paused) {
      throw LocalAudioUnavailable(phase.value);
    }
    _participants[owner] = retireAndDispose;
  }

  void unregister(Object owner) => _participants.remove(owner);

  BigInt get requestEpoch {
    final request = Zone.current[_zoneKey] as _LocalAudioRequest?;
    if (request == null) {
      throw StateError(
        'Local audio mutation requires a captured request scope',
      );
    }
    request.check();
    return request.epoch;
  }

  void checkRequest() {
    requestEpoch;
  }

  /// The returned future retires promptly even when an old HTTP/native future
  /// cannot be cancelled. Its eventual completion/error remains observed.
  Future<T> run<T>(Future<T> Function() action) {
    final parent = Zone.current[_zoneKey] as _LocalAudioRequest?;
    if (parent != null) {
      return Future<T>.sync(() {
        parent.check();
        return parent.wait(Future<T>.sync(action));
      });
    }
    if (phase.value == LocalAudioPhase.lost ||
        phase.value == LocalAudioPhase.blocked) {
      return Future<T>.error(LocalAudioUnavailable(phase.value));
    }
    final request = _LocalAudioRequest(this, _epoch);
    _requests.add(request);
    final work = runZoned(() async {
      request.check();
      // Cleanup never runs behind this action on the player's operation queue.
      if (phase.value == LocalAudioPhase.recovering) {
        await request.wait(_cleanup);
      }
      request.check();
      if (phase.value == LocalAudioPhase.blocked) {
        throw LocalAudioUnavailable(phase.value);
      }
      final result = await action();
      request.check();
      return result;
    }, zoneValues: {_zoneKey: request});
    return request.wait(work).whenComplete(() => _requests.remove(request));
  }

  /// [epoch] comes from the native observer, never a Dart-generated counter.
  /// Ignore duplicate/out-of-order notifications. Errors latch local output
  /// closed, but all remaining cleanup is still attempted on later events.
  Future<void> accept(LocalAudioNativeEvent event, BigInt epoch) {
    if (epoch <= _epoch) return _cleanup;
    _epoch = epoch;
    for (final request in _requests.toList()) {
      request.retire();
    }
    _requests.clear();
    phase.value = cleanupError != null
        ? LocalAudioPhase.blocked
        : event == LocalAudioNativeEvent.lost
        ? LocalAudioPhase.lost
        : LocalAudioPhase.recovering;

    // Invoke every retirement immediately, before waiting for earlier cleanup.
    final retired = [
      for (final participant in _participants.values.toList())
        Future<void>.sync(participant),
    ];
    // Observe errors immediately, including while earlier native cleanup waits.
    final retiredAll = _settle(retired);
    final previous = _cleanup;
    _cleanup = () async {
      await previous;
      await _settle([retiredAll, Future<void>.sync(destroyNativeOutput)]);
      if (epoch != _epoch) return;
      if (cleanupError != null) {
        phase.value = LocalAudioPhase.blocked;
        return;
      }
      if (event == LocalAudioNativeEvent.reset) {
        await _settle([Future<void>.sync(restoreSession)]);
        if (epoch != _epoch) return;
        phase.value = cleanupError == null
            ? LocalAudioPhase.paused
            : LocalAudioPhase.blocked;
      }
    }();
    return _cleanup;
  }

  Future<void> _settle(List<Future<void>> futures) async {
    await Future.wait([
      for (final future in futures)
        future.then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            cleanupError ??= error;
          },
        ),
    ]);
  }
}

class _LocalAudioRequest {
  _LocalAudioRequest(this.owner, this.epoch);
  final LocalAudioLifecycle owner;
  final BigInt epoch;
  final _retired = Completer<void>();

  void check() {
    if (_retired.isCompleted ||
        epoch != owner._epoch ||
        epoch != owner._nativeEpoch()) {
      throw const LocalAudioRequestRetired();
    }
  }

  void retire() {
    if (!_retired.isCompleted) _retired.complete();
  }

  Future<T> wait<T>(Future<T> work) => Future.any([
    work,
    _retired.future.then<T>((_) => throw const LocalAudioRequestRetired()),
  ]);
}
