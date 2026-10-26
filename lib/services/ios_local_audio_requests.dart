import 'dart:io';

import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/src/rust/api/audio_api.dart' as native_audio;

/// iPhone-only request scopes. Observation is activated separately, after every
/// local output owner has registered confirmed reset cleanup.
abstract final class IosLocalAudioRequests {
  static LocalAudioLifecycle? _lifecycle;
  static Future<void> Function()? restoreSession;

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

  static Future<T> run<T>(Future<T> Function() action) =>
      Platform.isIOS ? lifecycle.run(action) : action();

  static BigInt? get epoch => Platform.isIOS ? lifecycle.requestEpoch : null;

  static void check() {
    if (Platform.isIOS) lifecycle.checkRequest();
  }

  static Future<T> wait<T>(Future<T> result) =>
      Platform.isIOS ? _checkedWait(result) : result;

  static Future<T> _checkedWait<T>(Future<T> result) async {
    final value = await result;
    check();
    return value;
  }

  static bool isRetired(Object error) =>
      error is LocalAudioRequestRetired ||
      error is LocalAudioUnavailable ||
      error.toString().contains('AUDIO_LOCAL_REQUEST_RETIRED') ||
      error.toString().contains('AUDIO_LOCAL_CLEANUP_UNCONFIRMED');
}
