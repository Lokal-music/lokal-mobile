import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/src/rust/api/audio_api.dart' as native_audio;

/// iPhone-only request scopes. Observation is activated separately, after every
/// local output owner has registered confirmed reset cleanup.
abstract final class IosLocalAudioRequests {
  static LocalAudioLifecycle? _lifecycle;
  static Future<void> Function()? restoreSession;
  static Future<void>? _observation;
  static Future<void>? _observationFailure;
  static StreamSubscription<dynamic>? _events;
  static Timer? _cleanupWatchdog;

  static bool get isObserving =>
      _events != null && lifecycle.phase.value != LocalAudioPhase.blocked;

  /// Called only after PlayerService has registered its retirement/session
  /// callbacks. Lazy local owners register before constructing native objects.
  static Future<void> startObservation() => !Platform.isIOS
      ? Future<void>.value()
      : _observation ??= _startObservation();

  static Future<void> _startObservation() async {
    final first = Completer<void>();
    try {
      await const MethodChannel('lokal/ios')
          .invokeMethod<void>('startAudioLifecycle')
          .timeout(const Duration(seconds: 5));
      _events = const EventChannel('lokal/audio_lifecycle')
          .receiveBroadcastStream()
          .listen(
            (data) {
              try {
                if (data is! Map ||
                    data['phase'] is! String ||
                    data['epoch'] is! String) {
                  throw const FormatException(
                    'Invalid audio lifecycle snapshot',
                  );
                }
                final raw = data['epoch'] as String;
                if (!RegExp(r'^\d+$').hasMatch(raw)) {
                  throw const FormatException('Invalid native request epoch');
                }
                final epoch = BigInt.parse(raw);
                if (epoch > BigInt.parse('18446744073709551615')) {
                  throw const FormatException('Native request epoch overflow');
                }
                switch (data['phase']) {
                  case 'ready':
                    if (epoch != lifecycle.epoch) {
                      throw const FormatException(
                        'Unexpected audio lifecycle snapshot',
                      );
                    }
                  case 'lost':
                    _accept(LocalAudioNativeEvent.lost, epoch);
                  case 'reset':
                    _accept(LocalAudioNativeEvent.reset, epoch);
                  default:
                    throw const FormatException(
                      'Unknown audio lifecycle event',
                    );
                }
                if (!first.isCompleted) first.complete();
              } catch (error, stack) {
                unawaited(_observationFailed(error));
                if (!first.isCompleted) first.completeError(error, stack);
              }
            },
            onError: (Object error, StackTrace stack) {
              unawaited(_observationFailed(error));
              if (!first.isCompleted) first.completeError(error, stack);
            },
            onDone: () {
              final error = StateError('Audio lifecycle observation ended');
              unawaited(_observationFailed(error));
              if (!first.isCompleted) first.completeError(error);
            },
          );
      await first.future.timeout(const Duration(seconds: 5));
    } catch (error) {
      await _observationFailed(error);
      throw LocalAudioUnavailable(lifecycle.phase.value);
    }
  }

  static void _accept(LocalAudioNativeEvent event, BigInt epoch) {
    try {
      // An exhausted C counter cannot advance again. Native health must still
      // close local output when that epoch is delivered more than once.
      native_audio.audioLocalRequestEpoch();
    } catch (error) {
      unawaited(_observationFailed(error));
      return;
    }
    final cleanup = lifecycle.accept(event, epoch);
    if (epoch != lifecycle.epoch) return;
    _cleanupWatchdog ??= Timer(const Duration(seconds: 12), () {
      _cleanupWatchdog = null;
      unawaited(
        failLocalOutput(
          TimeoutException('Native audio cleanup was not acknowledged'),
        ),
      );
    });
    unawaited(
      cleanup.then((_) {
        if (epoch != lifecycle.epoch) return;
        _cleanupWatchdog?.cancel();
        _cleanupWatchdog = null;
      }),
    );
  }

  /// An uncertain native teardown must never authorize another local player.
  /// The original cleanup future remains owned and observed after a timeout.
  static Future<void> failLocalOutput(Object error) =>
      Platform.isIOS ? _observationFailed(error) : Future<void>.value();

  static Future<void> _observationFailed(Object error) =>
      _observationFailure ??= _retireAfterObservationFailure(error);

  static Future<void> _retireAfterObservationFailure(Object error) async {
    _cleanupWatchdog?.cancel();
    _cleanupWatchdog = null;
    BigInt epoch;
    try {
      // Independent of the Flutter event channel and engine/network locks.
      epoch = native_audio.audioLocalRetireRequests();
    } catch (_) {
      // Counter exhaustion already closes native validation permanently.
      epoch = lifecycle.epoch;
    }
    await lifecycle.failClosed(error, epoch);
  }

  static LocalAudioLifecycle get lifecycle =>
      _lifecycle ??= LocalAudioLifecycle(
        nativeEpoch: native_audio.audioLocalRequestEpoch,
        destroyNativeOutput: native_audio.audioShutdown,
        restoreSession: () async {
          final restore = restoreSession;
          if (restore == null) {
            throw StateError('iPhone session owner is not registered');
          }
          await restore();
        },
      );

  static Future<T> run<T>(Future<T> Function() action) => !Platform.isIOS
      ? action()
      : lifecycle.run(() async {
          final observation = _observation;
          if (observation != null) await wait(observation);
          check();
          return action();
        });

  static Future<T> runRemote<T>(Future<T> Function() action) =>
      Platform.isIOS ? lifecycle.runRemote(action) : action();

  static BigInt? get epoch => Platform.isIOS ? lifecycle.requestEpoch : null;

  static void check() {
    if (Platform.isIOS) lifecycle.checkRequest();
  }

  static Future<T> wait<T>(Future<T> result) =>
      Platform.isIOS ? _checkedWait(result) : result;

  static Future<T> _checkedWait<T>(Future<T> result) async {
    final value = await result;
    lifecycle.checkAfterAwait();
    return value;
  }

  static bool isRetired(Object error) =>
      error is LocalAudioRequestRetired ||
      error is LocalAudioUnavailable ||
      error.toString().contains('AUDIO_LOCAL_REQUEST_RETIRED') ||
      error.toString().contains('AUDIO_LOCAL_CLEANUP_UNCONFIRMED');
}
