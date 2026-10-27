import 'dart:async';
import 'dart:io';

import 'music_video_controller.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flick/services/ios_local_audio_requests.dart';
import 'package:flick/services/local_audio_lifecycle.dart';

/// This origin identifies Lokal to YouTube's official iframe embed. It is
/// deliberately unrelated to add-on/stream URLs or the audio engine.
const musicVideoAppOrigin = 'https://com.lokalkonnekt.konnekted2';

String musicVideoOriginForAppId(String appId) {
  final id = appId.toLowerCase();
  if (!RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$').hasMatch(id)) {
    throw const FormatException('Installed app identity is unavailable.');
  }
  return 'https://$id';
}

String musicVideoOriginPattern(String origin) =>
    '^${RegExp.escape(origin)}(?::443)?\$';

final _musicVideoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

bool validMusicVideoId(String videoId) => _musicVideoId.hasMatch(videoId);

/// Uses YouTube's player; no media URL extraction, cookies, or stream proxy.
@visibleForTesting
String musicVideoEmbedHtml(
  String videoId, {
  String? appId,
  bool deferAutoplayToHost = false,
  bool startPaused = false,
  Duration initialPosition = Duration.zero,
}) {
  if (!validMusicVideoId(videoId)) {
    throw ArgumentError.value(videoId, 'videoId', 'Invalid YouTube video ID');
  }
  final src = Uri.https('www.youtube.com', '/embed/$videoId', {
    'autoplay': '0',
    'playsinline': '1',
    'rel': '0',
    'enablejsapi': '1',
    'origin': appId == null
        ? musicVideoAppOrigin
        : musicVideoOriginForAppId(appId),
  });
  return '''<!doctype html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
</head><body>
<iframe id="player" src="$src" title="YouTube video player"
 allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
 referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
<script>
let lokalPlayer = null;
let lokalReady = false;
let lokalReleased = false;
let lokalClock = null;
const lokalStartPaused = $startPaused;
const lokalHostAutoplay = $deferAutoplayToHost;
const lokalInitialSeconds = ${initialPosition.inMilliseconds < 0 ? 0 : initialPosition.inMilliseconds / 1000};
function lokalSnapshot(error) {
  if (!window.flutter_inappwebview) return;
  try {
    const state = lokalReady ? lokalPlayer.getPlayerState() : -1;
    window.flutter_inappwebview.callHandler('LokalVideo', {
      videoId: '$videoId', ready: lokalReady, error: error || null,
      positionMs: lokalReady ? Math.max(0, lokalPlayer.getCurrentTime() * 1000) : 0,
      durationMs: lokalReady ? Math.max(0, lokalPlayer.getDuration() * 1000) : 0,
      playing: !lokalReleased && state === 1, buffering: state === 3
    });
  } catch (_) {}
}
window.lokalVideoCommand = function(method, positionMs) {
  if (method === 'release') {
    lokalReleased = true;
    if (lokalClock) clearInterval(lokalClock);
    if (lokalReady) lokalPlayer.pauseVideo();
    return true;
  }
  if (!lokalReady || lokalReleased) return false;
  if (method === 'play') lokalPlayer.playVideo();
  else if (method === 'pause') lokalPlayer.pauseVideo();
  else if (method === 'seek' && Number.isFinite(positionMs) && positionMs >= 0) {
    const state = lokalPlayer.getPlayerState();
    if ((lokalStartPaused || lokalHostAutoplay) && [-1, 0, 5].includes(state))
      lokalPlayer.cueVideoById({videoId: '$videoId', startSeconds: positionMs / 1000});
    else {
      lokalPlayer.seekTo(positionMs / 1000, true);
      if ((lokalStartPaused || lokalHostAutoplay) && state !== 1)
        lokalPlayer.pauseVideo();
    }
  }
  else return false;
  lokalSnapshot();
  return true;
};
window.lokalVideoPaused = function() {
  return !lokalReady || [-1, 0, 2, 5].includes(lokalPlayer.getPlayerState());
};
window.onYouTubeIframeAPIReady = function() {
  lokalPlayer = new YT.Player('player', {events: {
    onReady: function() {
      lokalReady = true;
      if (lokalReleased) lokalPlayer.pauseVideo();
      else {
        if (lokalStartPaused) lokalPlayer.cueVideoById({videoId: '$videoId', startSeconds: lokalInitialSeconds});
        else if (!lokalHostAutoplay) lokalPlayer.playVideo();
        lokalClock = setInterval(lokalSnapshot, 250);
      }
      lokalSnapshot();
    },
    onStateChange: function(event) {
      if (lokalReleased && (event.data === 1 || event.data === 3)) lokalPlayer.pauseVideo();
      lokalSnapshot();
    },
    onError: function(event) {
      lokalReady = false;
      if (lokalClock) clearInterval(lokalClock);
      lokalSnapshot(Number(event.data) || -1);
    }
  }});
};
</script>
<script src="https://www.youtube.com/iframe_api"></script>
</body></html>''';
}

/// Debug acceptance document seam; product routes use the official embed.
typedef NativeAcceptanceVideoDocument = String Function({
  required String videoId,
  required String? appId,
  required bool deferAutoplayToHost,
  required bool startPaused,
  required Duration initialPosition,
});

/// In-full-player video stage, retained while toggling fullscreen/Space.
class MusicVideoSurface extends StatefulWidget {
  const MusicVideoSurface({super.key, required this.videoId, this.controller})
    : _acceptanceDocument = null,
      _onAcceptanceViewCreated = null;

  /// Runs the production owner/bridge against controlled local media in debug
  /// acceptance. Product routes always use the official document above.
  @visibleForTesting
  const MusicVideoSurface.forNativeAcceptance({
    super.key,
    required this.videoId,
    this.controller,
    required NativeAcceptanceVideoDocument document,
    required void Function(InAppWebViewController) onViewCreated,
  }) : _acceptanceDocument = document,
       _onAcceptanceViewCreated = onViewCreated,
       assert(kDebugMode);

  final String videoId;
  final Media3MusicVideoController? controller;
  final NativeAcceptanceVideoDocument? _acceptanceDocument;
  final void Function(InAppWebViewController)? _onAcceptanceViewCreated;

  @override
  State<MusicVideoSurface> createState() => _MusicVideoSurfaceState();
}

/// A platform view keeps its own acknowledgement after the widget is removed.
/// A delayed creation or command may never acknowledge a replacement's lease.
class _IframeOutput {
  _IframeOutput(
    this.controller, {
    required this.startPaused,
    required this.position,
    required this.epoch,
  });
  final Media3MusicVideoController? controller;
  final bool startPaused;
  final Duration position;
  final BigInt? epoch;
  int? lease;
  InAppWebViewController? view;
  final created = Completer<void>();
  bool creationStarted = false;
  bool released = false;
  bool ready = false;
  bool autoplayRequested = false;
  bool initialPositionConfirmed = false;
  bool quietConfirmed = false;
  Future<void> commands = Future<void>.value();
  Future<void>? quiet;
}

class _MusicVideoSurfaceState extends State<MusicVideoSurface>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _failed = false;
  bool _needsRebuild = false;
  Duration _resetPosition = Duration.zero;
  late _IframeOutput _output;
  String? _appId;
  bool _identityReady = !Platform.isIOS;
  String get _appOrigin =>
      _appId == null ? musicVideoAppOrigin : musicVideoOriginForAppId(_appId!);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _output = _newOutput();
    if (Platform.isIOS) {
      IosLocalAudioRequests.lifecycle.phase.addListener(_onLifecycle);
      unawaited(_loadInstalledIdentity());
    }
  }

  _IframeOutput _newOutput({
    bool paused = false,
    Duration position = Duration.zero,
  }) {
    final output = _IframeOutput(
      widget.controller,
      startPaused: paused,
      position: position,
      epoch: Platform.isIOS ? IosLocalAudioRequests.lifecycle.epoch : null,
    );
    output.lease = output.controller?.attach(
      (method, args) => _command(output, method, args),
    );
    output.controller?.fallback();
    return output;
  }

  bool _isCurrent(_IframeOutput output) =>
      mounted &&
      identical(output, _output) &&
      !output.released &&
      (output.controller == null || output.controller!.owns(output.lease));

  void _onLifecycle() {
    if (!mounted ||
        !_needsRebuild ||
        !Platform.isIOS ||
        !IosLocalAudioRequests.lifecycle.canUseLocalOutput) {
      return;
    }
    // All owners, including the retired WebKit view, have confirmed cleanup.
    setState(() {
      _output = _newOutput(paused: true, position: _resetPosition);
      _needsRebuild = false;
      _loading = true;
      _failed = false;
    });
  }

  Future<void> _loadInstalledIdentity() async {
    try {
      final info = await const MethodChannel('lokal/app_info')
          .invokeMapMethod<String, dynamic>('get');
      final id = info?['bundleId'];
      if (id is! String) throw const FormatException('No installed bundle ID');
      musicVideoOriginForAppId(id);
      if (!mounted) return;
      setState(() {
        _appId = id;
        _identityReady = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _queue(_IframeOutput output, Future<void> Function() action) {
    final work = output.commands.then((_) => action());
    output.commands = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }

  Future<void> _command(
    _IframeOutput output,
    String method,
    Map<String, Object?> args,
  ) {
    if (method == 'release' || method == 'mediaReset') {
      // Tombstone synchronously, before an earlier unsuspend can complete.
      output.released = true;
      if (method == 'mediaReset' && identical(output, _output)) {
        final ms = args['positionMs'];
        _resetPosition = Duration(milliseconds: ms is int && ms >= 0 ? ms : 0);
        _needsRebuild = true;
      }
      return _queue(output, () async {
        await _suspend(output);
        if (mounted && identical(output, _output)) {
          setState(() {
            _loading = false;
          });
          _onLifecycle();
        }
      });
    }
    return IosLocalAudioRequests.run(
      () => _queue(output, () async {
        if (!_isCurrent(output) || !output.ready || output.view == null) {
          throw StateError('Video controls are not ready.');
        }
        IosLocalAudioRequests.check();
        final view = output.view!;
        if (Platform.isIOS && (method == 'play' || method == 'seek')) {
          final permitted = await IosLocalAudioRequests.wait(
            const MethodChannel('lokal/ios').invokeMethod<bool>(
              'canStartWebVideo',
              {'epoch': output.epoch.toString()},
            ),
          );
          if (permitted != true || !_isCurrent(output)) {
            throw StateError(
              'Video is waiting for active iPhone audio services.',
            );
          }
        }
        if (method == 'play' && Platform.isIOS) {
          await IosLocalAudioRequests.wait(
            view.setAllMediaPlaybackSuspended(suspended: false),
          );
        }
        if (!_isCurrent(output)) throw const LocalAudioRequestRetired();
        final position = args['positionMs'];
        final ms = position is num && position.isFinite && position >= 0
            ? position.toInt()
            : 0;
        final command = switch (method) {
          'play' => "window.lokalVideoCommand('play')",
          'pause' => "window.lokalVideoCommand('pause')",
          'seek' => "window.lokalVideoCommand('seek', $ms)",
          _ => throw ArgumentError.value(method, 'method'),
        };
        if (method == 'seek') output.initialPositionConfirmed = true;
        final accepted = await IosLocalAudioRequests.wait(
          view.evaluateJavascript(source: command),
        );
        if (accepted != true) {
          throw StateError('Video command was not accepted.');
        }
        if (method == 'pause' && Platform.isIOS) {
          await IosLocalAudioRequests.wait(view.pauseAllMediaPlayback());
        }
      }),
    );
  }

  Future<void> _suspend(_IframeOutput output) => output.quiet ??= () async {
    try {
      if (output.view == null && output.creationStarted) {
        // A timeout reports uncertainty; the pending creation remains owned.
        await output.created.future.timeout(const Duration(seconds: 12));
      }
      final view = output.view;
      if (view != null) {
        if (Platform.isIOS) {
          // Native acknowledgement is required even if JS is unresponsive.
          await view.setAllMediaPlaybackSuspended(suspended: true);
          // Native suspension is authoritative; the JS tombstone adds defence
          // against a queued iframe API Ready callback in the retired document.
          unawaited(
            view
                .evaluateJavascript(
                  source: "window.lokalVideoCommand && window.lokalVideoCommand('release')",
                )
                .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
          );
        } else {
          await view.evaluateJavascript(
            source: "window.lokalVideoCommand && window.lokalVideoCommand('release')",
          );
          var confirmed = false;
          for (var attempt = 0; attempt < 20; attempt++) {
            if (await view.evaluateJavascript(
                  source:
                      'window.lokalVideoPaused && window.lokalVideoPaused()',
                ) ==
                true) {
              confirmed = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          if (!confirmed) throw StateError('Video pause was not confirmed.');
        }
      }
      output.quietConfirmed = true;
      output.controller?.acknowledgeNativeQuiet(output.lease);
    } catch (error, stack) {
      output.controller?.acknowledgeNativeQuiet(
        output.lease,
        error: error,
        stack: stack,
      );
      if (Platform.isIOS) {
        unawaited(IosLocalAudioRequests.failLocalOutput(error));
      }
      rethrow;
    }
  }();

  Future<void> _removeOutput(_IframeOutput output) {
    output.released = true;
    output.controller?.detach(output.lease);
    // Serialized behind an in-flight unsuspend: final native state is quiet.
    return _queue(output, () => _suspend(output));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    final output = _output;
    if (Platform.isIOS) {
      // Do not release ownership; explicit Play may unsuspend on foreground.
      unawaited(
        _queue(output, () async {
          final view = output.view;
          if (view != null) {
            await view.setAllMediaPlaybackSuspended(suspended: true);
          }
        }).catchError((Object error) {
          unawaited(IosLocalAudioRequests.failLocalOutput(error));
        }),
      );
    } else {
      unawaited(_command(output, 'pause', const {}).catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isIOS) {
      IosLocalAudioRequests.lifecycle.phase.removeListener(_onLifecycle);
    }
    unawaited(
      _removeOutput(_output)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    super.dispose();
  }

  void _snapshot(Object? value, _IframeOutput output) {
    if (!_isCurrent(output) ||
        value is! Map ||
        value['videoId'] != widget.videoId) {
      return;
    }
    if (Platform.isIOS && !IosLocalAudioRequests.lifecycle.canUseLocalOutput) {
      return;
    }
    final controller = output.controller;
    if (value['error'] != null) {
      final error = value['error'];
      controller?.fallback(errorCode: error is num ? error.toInt() : -1);
      setState(() {
        _failed = true;
        _loading = false;
        output.ready = false;
      });
      return;
    }
    if (value['ready'] != true) return;
    final position = value['positionMs'];
    final duration = value['durationMs'];
    if (position is! num ||
        duration is! num ||
        !position.isFinite ||
        !duration.isFinite ||
        position < 0 ||
        duration < 0) {
      return;
    }
    output.ready = true;
    if (_loading || _failed) {
      setState(() {
        _loading = false;
        _failed = false;
      });
    }
    // cueVideoById is asynchronous. Its first Ready snapshot can still be at
    // zero; a second reset must retain the requested cue position in that gap.
    if (position > 0 || value['playing'] == true) {
      output.initialPositionConfirmed = true;
    }
    final reportedPosition =
        output.startPaused && !output.initialPositionConfirmed && position == 0
        ? output.position.inMilliseconds
        : position.toInt();
    controller?.update(
      positionMs: reportedPosition,
      durationMs: duration.toInt(),
      playing: value['playing'] == true,
      buffering: value['buffering'] == true,
    );
    if (Platform.isIOS && value['playing'] == true) {
      IosLocalAudioRequests.lifecycle.confirmLocalPlaybackStarted();
    }
    if (Platform.isIOS && !output.startPaused && !output.autoplayRequested) {
      output.autoplayRequested = true;
      // iOS documents never self-autoplay: the host checks epoch + foreground.
      unawaited(_command(output, 'play', const {}).catchError((Object _) {}));
    }
  }

  Future<NavigationActionPolicy> _navigate(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    if (action.isForMainFrame != true) return NavigationActionPolicy.ALLOW;
    final url = action.request.url;
    if (url == null || url.toString() == '$_appOrigin/') {
      return NavigationActionPolicy.ALLOW;
    }
    if (url.scheme == 'https') {
      unawaited(launchUrl(url, mode: LaunchMode.externalApplication));
    }
    return NavigationActionPolicy.CANCEL;
  }

  @override
  void didUpdateWidget(covariant MusicVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.controller != widget.controller) {
      final previous = _output;
      final removed = _removeOutput(previous);
      removed.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      _needsRebuild = false;
      _loading = true;
      _failed = false;
      // Preserve Android's established handoff. iOS creates the replacement
      // only once the retired native view confirms suspension.
      if (!Platform.isIOS) {
        _output = _newOutput();
      } else {
        unawaited(
          removed.then<void>((_) {
            if (!mounted || !identical(previous, _output)) return;
            setState(() => _output = _newOutput());
          }, onError: (Object _, StackTrace _) {}),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!validMusicVideoId(widget.videoId)) {
      return const Center(
        child: Text('Invalid video', style: TextStyle(color: Colors.white70)),
      );
    }
    final output = _output;
    final canCreate =
        _identityReady &&
        !output.released &&
        (!Platform.isIOS || IosLocalAudioRequests.lifecycle.canUseLocalOutput);
    if (canCreate) output.creationStarted = true;
    // A lifecycle notice can rebuild the root before WebKit acknowledges
    // suspension. Keep that platform view mounted until its native call returns.
    final retainUntilQuiet = output.creationStarted && !output.quietConfirmed;
    return Column(
      children: [
        Expanded(
          child: !canCreate && !retainUntilQuiet
              ? const SizedBox.shrink()
              : InAppWebView(
                  key: ObjectKey(output),
                  onWebViewCreated: (view) {
                    output.view = view;
                    if (!output.created.isCompleted) output.created.complete();
                    if (!_isCurrent(output)) {
                      // Also covers a creation that completes after a timeout/dispose.
                      if (Platform.isIOS) {
                        unawaited(
                          view
                              .setAllMediaPlaybackSuspended(suspended: true)
                              .then<void>(
                                (_) {},
                                onError: (Object error, StackTrace _) {
                                  unawaited(
                                    IosLocalAudioRequests.failLocalOutput(
                                      error,
                                    ),
                                  );
                                },
                              ),
                        );
                      }
                      return;
                    }
                    widget._onAcceptanceViewCreated?.call(view);
                    view.addJavaScriptHandler(
                      handlerName: 'LokalVideo',
                      callback: (arguments) {
                        if (arguments.isNotEmpty) {
                          _snapshot(arguments.first, output);
                        }
                        return null;
                      },
                    );
                  },
                  initialData: InAppWebViewInitialData(
                    data:
                        widget._acceptanceDocument?.call(
                          videoId: widget.videoId,
                          appId: _appId,
                          deferAutoplayToHost: Platform.isIOS,
                          startPaused: output.startPaused,
                          initialPosition: output.position,
                        ) ??
                        musicVideoEmbedHtml(
                          widget.videoId,
                          appId: _appId,
                          deferAutoplayToHost: Platform.isIOS,
                          startPaused: output.startPaused,
                          initialPosition: output.position,
                        ),
                    baseUrl: WebUri('$_appOrigin/'),
                    historyUrl: WebUri('$_appOrigin/'),
                  ),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    javaScriptHandlersForMainFrameOnly: true,
                    javaScriptBridgeForMainFrameOnly: true,
                    javaScriptHandlersOriginAllowList: {
                      musicVideoOriginPattern(_appOrigin),
                    },
                    javaScriptBridgeOriginAllowList: {
                      musicVideoOriginPattern(_appOrigin),
                    },
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    incognito: true,
                    thirdPartyCookiesEnabled: false,
                    useShouldOverrideUrlLoading: true,
                    supportMultipleWindows: false,
                    useHybridComposition: false,
                  ),
                  onLoadStop: (_, __) {
                    if (_isCurrent(output)) setState(() => _loading = false);
                  },
                  onReceivedError: (_, request, __) {
                    if (!_isCurrent(output)) return;
                    final url = request.url;
                    final embedFailed =
                        request.isForMainFrame == false &&
                        url.host == 'www.youtube.com' &&
                        url.path == '/embed/${widget.videoId}';
                    if (request.isForMainFrame == true || embedFailed) {
                      setState(() {
                        _failed = true;
                        _loading = false;
                        output.ready = false;
                      });
                      output.controller?.fallback();
                    }
                  },
                  shouldOverrideUrlLoading: _navigate,
                ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 3),
        if (_failed)
          SizedBox(
            height: 48,
            child: Center(
              child: TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.https('www.youtube.com', '/watch', {'v': widget.videoId}),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open video on YouTube'),
              ),
            ),
          ),
      ],
    );
  }
}
