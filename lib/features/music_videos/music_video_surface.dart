import 'dart:async';
import 'dart:io';

import 'music_video_controller.dart';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

/// This origin identifies Lokal to YouTube's official iframe embed. It is
/// deliberately unrelated to add-on/stream URLs or the audio engine.
const musicVideoAppOrigin = 'https://com.lokalkonnekt.konnekted2';

final _musicVideoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

bool validMusicVideoId(String videoId) => _musicVideoId.hasMatch(videoId);

/// Uses YouTube's player; no media URL extraction, cookies, or stream proxy.
@visibleForTesting
String musicVideoEmbedHtml(String videoId) {
  if (!validMusicVideoId(videoId)) {
    throw ArgumentError.value(videoId, 'videoId', 'Invalid YouTube video ID');
  }
  final src = Uri.https('www.youtube.com', '/embed/$videoId', {
    'autoplay': '0',
    'playsinline': '1',
    'rel': '0',
    'enablejsapi': '1',
    'origin': musicVideoAppOrigin,
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
  else if (method === 'seek' && Number.isFinite(positionMs) && positionMs >= 0)
    lokalPlayer.seekTo(positionMs / 1000, true);
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
        lokalPlayer.playVideo();
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

/// Reusable in-full-player music video stage. Kept alive while toggling
/// fullscreen so the YouTube iframe does not restart mid-video.
class MusicVideoSurface extends StatefulWidget {
  const MusicVideoSurface({super.key, required this.videoId, this.controller});

  final String videoId;
  final Media3MusicVideoController? controller;

  @override
  State<MusicVideoSurface> createState() => _MusicVideoSurfaceState();
}

class _MusicVideoSurfaceState extends State<MusicVideoSurface>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _failed = false;
  bool _ready = false;
  bool _released = false;
  int _generation = 0;
  int? _lease;
  InAppWebViewController? _webView;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  void _attach() {
    _lease = widget.controller?.attach(_command);
    widget.controller?.fallback();
  }

  Future<void> _command(String method, Map<String, Object?> args) async {
    final view = _webView;
    if (method == 'release') {
      _released = true;
      if (view == null) return; // No web player has been created.
      await view.evaluateJavascript(
        source:
            "window.lokalVideoCommand && window.lokalVideoCommand('release')",
      );
      if (Platform.isIOS) {
        // Unlike a posted iframe pause, this native completion stops playback
        // across all frames and prevents a late autoplay before view disposal.
        await view.setAllMediaPlaybackSuspended(suspended: true);
      } else {
        for (var attempt = 0; attempt < 20; attempt++) {
          final paused = await view.evaluateJavascript(
            source: 'window.lokalVideoPaused && window.lokalVideoPaused()',
          );
          if (paused == true) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        throw StateError('Video pause was not confirmed.');
      }
      return;
    }
    if (view == null || !_ready || _released) {
      throw StateError('Video controls are not ready.');
    }
    if (method == 'play' && Platform.isIOS) {
      await view.setAllMediaPlaybackSuspended(suspended: false);
    }
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
    final accepted = await view.evaluateJavascript(source: command);
    if (accepted != true) throw StateError('Video command was not accepted.');
    if (method == 'pause' && Platform.isIOS) await view.pauseAllMediaPlayback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_command('pause', const {}).catchError((Object _) {}));
      final view = _webView;
      if (view != null && Platform.isIOS) {
        unawaited(
          view
              .setAllMediaPlaybackSuspended(suspended: true)
              .catchError((Object _) {}),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?.detach(_lease);
    final view = _webView;
    if (view != null && Platform.isIOS) {
      unawaited(
        view
            .setAllMediaPlaybackSuspended(suspended: true)
            .catchError((Object _) {}),
      );
    }
    _webView = null;
    super.dispose();
  }

  void _snapshot(Object? value, int generation) {
    if (!mounted ||
        generation != _generation ||
        value is! Map ||
        value['videoId'] != widget.videoId ||
        _released) {
      return;
    }
    final controller = widget.controller;
    if (controller != null && !controller.owns(_lease)) return;
    if (value['error'] != null) {
      controller?.fallback();
      setState(() {
        _failed = true;
        _loading = false;
        _ready = false;
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
    _ready = true;
    if (_loading || _failed) {
      setState(() {
        _loading = false;
        _failed = false;
      });
    }
    controller?.update(
      positionMs: position.toInt(),
      durationMs: duration.toInt(),
      playing: value['playing'] == true,
      buffering: value['buffering'] == true,
    );
  }

  Future<NavigationActionPolicy> _navigate(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    if (action.isForMainFrame != true) return NavigationActionPolicy.ALLOW;
    final url = action.request.url;
    if (url == null || url.toString() == '$musicVideoAppOrigin/') {
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
    if (oldWidget.videoId != widget.videoId) {
      oldWidget.controller?.detach(_lease);
      _generation++;
      final oldView = _webView;
      if (oldView != null && Platform.isIOS) {
        unawaited(
          oldView
              .setAllMediaPlaybackSuspended(suspended: true)
              .catchError((Object _) {}),
        );
      }
      _webView = null;
      _ready = false;
      _released = false;
      _loading = true;
      _failed = false;
      _attach();
    } else if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.detach(_lease);
      _attach();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!validMusicVideoId(widget.videoId)) {
      return const Center(
        child: Text('Invalid video', style: TextStyle(color: Colors.white70)),
      );
    }
    final generation = _generation;
    return Stack(
      fit: StackFit.expand,
      children: [
        InAppWebView(
          key: ValueKey(widget.videoId),
          onWebViewCreated: (view) {
            if (generation != _generation) return;
            _webView = view;
            view.addJavaScriptHandler(
              handlerName: 'LokalVideo',
              callback: (arguments) {
                if (arguments.isNotEmpty) {
                  _snapshot(arguments.first, generation);
                }
                return null;
              },
            );
            if (_released && Platform.isIOS) {
              unawaited(
                view
                    .setAllMediaPlaybackSuspended(suspended: true)
                    .catchError((Object _) {}),
              );
            }
          },
          initialData: InAppWebViewInitialData(
            data: musicVideoEmbedHtml(widget.videoId),
            baseUrl: WebUri('$musicVideoAppOrigin/'),
            historyUrl: WebUri('$musicVideoAppOrigin/'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            javaScriptHandlersForMainFrameOnly: true,
            javaScriptBridgeForMainFrameOnly: true,
            javaScriptHandlersOriginAllowList: {
              r'^https://com\.lokalkonnekt\.konnekted2(?::443)?$',
            },
            javaScriptBridgeOriginAllowList: {
              r'^https://com\.lokalkonnekt\.konnekted2(?::443)?$',
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
            if (mounted && generation == _generation)
              setState(() => _loading = false);
          },
          onReceivedError: (_, request, __) {
            if (!mounted || generation != _generation) return;
            final url = request.url;
            final embedFailed =
                request.isForMainFrame == false &&
                url.host == 'www.youtube.com' &&
                url.path == '/embed/${widget.videoId}';
            if (mounted && (request.isForMainFrame == true || embedFailed)) {
              setState(() {
                _failed = true;
                _loading = false;
                _ready = false;
              });
              widget.controller?.fallback();
            }
          },
          shouldOverrideUrlLoading: _navigate,
        ),
        if (_loading)
          const IgnorePointer(
            child: Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
        if (_failed)
          ColoredBox(
            color: Colors.black,
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
