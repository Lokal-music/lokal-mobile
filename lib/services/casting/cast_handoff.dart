import '../playback_output_transition.dart';

class CastHandoffCancelled implements Exception {
  const CastHandoffCancelled();
}

/// Receiver shutdown was not confirmed. Keep remote ownership so a queued Play
/// cannot fall through to the local engine while the receiver may still play.
class CastHandoffUncertain implements Exception {
  const CastHandoffUncertain(this.cause, this.cleanupError);
  final Object cause;
  final Object cleanupError;
}

/// Transfer ownership with the receiver initially loaded *paused*. The caller
/// holds the player operation queue throughout, including failure cleanup.
Future<void> handoffToCast({
  required PlaybackOutputTransition local,
  required Future<void> Function() connect,
  required Future<void> Function() preparePaused,
  required Future<void> Function() play,
  required Future<void> Function() disconnect,
  required void Function() claimRemote,
  required void Function() releaseRemote,
}) async {
  var pausedLocal = false;
  var claimed = false;
  void checkCurrent() {
    if (!local.isCurrent()) throw const CastHandoffCancelled();
  }

  try {
    await connect();
    checkCurrent();
    if (local.song != null) {
      await preparePaused();
      checkCurrent();
      if (local.wasPlaying) {
        await local.pauseLocal();
        pausedLocal = true;
        checkCurrent();
      }
    }
    claimRemote();
    claimed = true;
    if (local.song != null && local.wasPlaying) await play();
    checkCurrent();
  } catch (error, stack) {
    try {
      await disconnect();
    } catch (cleanupError) {
      // A failed connection can still leave an in-flight receiver operation.
      // Yield the phone before quarantining ownership, even if preparation had
      // not reached the normal local-pause step.
      try {
        if (!pausedLocal && local.wasPlaying) await local.pauseLocal();
      } finally {
        if (!claimed) claimRemote();
      }
      throw CastHandoffUncertain(error, cleanupError);
    }
    if (claimed) releaseRemote();
    if (pausedLocal && local.isCurrent()) await local.resumeLocal();
    Error.throwWithStackTrace(error, stack);
  }
}
