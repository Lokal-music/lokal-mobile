import 'dart:async';

import 'package:flutter/foundation.dart';
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
    'autoplay': '1',
    'playsinline': '1',
    'rel': '0',
    'enablejsapi': '0',
    'origin': musicVideoAppOrigin,
  });
  return '''<!doctype html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
</head><body>
<iframe src="$src" title="YouTube video player"
 allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
 referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
</body></html>''';
}

/// Reusable in-full-player music video stage. Kept alive while toggling
/// fullscreen so the YouTube iframe does not restart mid-video.
class MusicVideoSurface extends StatefulWidget {
  const MusicVideoSurface({
    super.key,
    required this.videoId,
  });

  final String videoId;

  @override
  State<MusicVideoSurface> createState() => _MusicVideoSurfaceState();
}

class _MusicVideoSurfaceState extends State<MusicVideoSurface> {
  bool _loading = true;
  bool _failed = false;

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
      _loading = true;
      _failed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!validMusicVideoId(widget.videoId)) {
      return const Center(
        child: Text('Invalid video', style: TextStyle(color: Colors.white70)),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        InAppWebView(
          key: ValueKey(widget.videoId),
          initialData: InAppWebViewInitialData(
            data: musicVideoEmbedHtml(widget.videoId),
            baseUrl: WebUri('$musicVideoAppOrigin/'),
            historyUrl: WebUri('$musicVideoAppOrigin/'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            incognito: true,
            thirdPartyCookiesEnabled: false,
            useShouldOverrideUrlLoading: true,
            supportMultipleWindows: false,
            useHybridComposition: false,
          ),
          onLoadStop: (_, __) {
            if (mounted) setState(() => _loading = false);
          },
          onReceivedError: (_, request, __) {
            if (request.isForMainFrame == true && mounted) {
              setState(() { _failed = true; _loading = false; });
            }
          },
          shouldOverrideUrlLoading: _navigate,
        ),
        if (_loading)
          const IgnorePointer(
            child: Center(child: CircularProgressIndicator(color: Colors.white)),
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
