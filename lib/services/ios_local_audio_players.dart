import 'dart:async';
import 'dart:io';

import 'package:flick/services/ios_local_audio_requests.dart';
import 'package:flick/services/local_audio_output_registry.dart';
import 'package:just_audio/just_audio.dart' as ja;

abstract final class IosLocalAudioPlayers {
  static final _outputs = LocalAudioOutputRegistry<ja.AudioPlayer>();
  static final _owner = Object();
  static bool _registered = false;

  static ja.AudioPlayer create({
    bool useProxyForRequestHeaders = true,
    bool handleInterruptions = true,
  }) {
    ja.AudioPlayer construct() => ja.AudioPlayer(
      useProxyForRequestHeaders: useProxyForRequestHeaders,
      handleInterruptions: handleInterruptions,
    );
    if (!Platform.isIOS) return construct();
    IosLocalAudioRequests.check();
    if (!_registered) {
      IosLocalAudioRequests.lifecycle.register(_owner, _outputs.retireAll);
      _registered = true;
    }
    final player = _outputs.create(construct, (output) => output.dispose());
    try {
      // The system can advance the native epoch on another thread during the
      // constructor. Retain disposal ownership even before Dart gets the event.
      IosLocalAudioRequests.check();
    } catch (_) {
      unawaited(_outputs.dispose(player).catchError((Object _) {}));
      rethrow;
    }
    return player;
  }

  static Future<void> dispose(ja.AudioPlayer player) =>
      Platform.isIOS ? _outputs.dispose(player) : player.dispose();
}
