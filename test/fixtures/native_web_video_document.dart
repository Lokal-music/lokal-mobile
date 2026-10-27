import 'dart:convert';

import 'package:flick/features/music_videos/music_video_surface.dart';

import 'generated_ios_video.dart';

/// Controlled provider API backed by a real iframe <video> and H.264/AAC
/// decoder. The production Lokal bridge below is included verbatim. There are
/// no external URLs, cookies, provider responses or interpolated source clocks.
String nativeWebVideoFixtureDocument({
  required String videoId,
  required String? appId,
  required bool deferAutoplayToHost,
  required bool startPaused,
  required Duration initialPosition,
}) {
  final child =
      '''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;background:#000;height:100%;overflow:hidden}video{width:100%;height:100%}</style>
</head><body><video id="media" playsinline controls preload="auto"
src="data:video/mp4;base64,$iosNativeVideoFixtureBase64"></video><script>
const media = document.getElementById('media');
function report(kind) {
  const quality = media.getVideoPlaybackQuality ? media.getVideoPlaybackQuality() : null;
  parent.postMessage({fixture: 'lokal-native-video', kind: kind,
    position: media.currentTime, duration: Number.isFinite(media.duration) ? media.duration : 0,
    state: media.ended ? 0 : media.paused ? 2 : media.readyState < 3 ? 3 : 1,
    frames: quality ? quality.totalVideoFrames : (media.webkitDecodedFrameCount || 0)}, '*');
}
media.addEventListener('loadedmetadata', function() { report('ready'); });
for (const name of ['playing','pause','waiting','seeked','ended','timeupdate'])
  media.addEventListener(name, function() { report('state'); });
media.addEventListener('error', function() { report('error'); });
window.addEventListener('message', function(event) {
  if (event.source !== parent || !event.data || event.data.fixture !== 'lokal-native-video') return;
  const command = event.data;
  if (command.method === 'play') media.play().catch(function() { report('error'); });
  else if (command.method === 'pause') media.pause();
  else if (command.method === 'seek' || command.method === 'cue') {
    if (command.method === 'cue') media.pause();
    media.currentTime = command.position;
  }
  report('state');
});
setInterval(function() { report('sample'); }, 100);
</script></body></html>''';
  // An HTML parser recognizes </script> even inside JavaScript strings.
  final childLiteral = jsonEncode(child).replaceAll('</', r'<\/');
  final shim =
      '''window.YT = {Player: function(id, options) {
  const frame = document.getElementById(id);
  let current = {position: 0, duration: 0, state: -1, frames: 0};
  let ready = false;
  function send(method, position) {
    frame.contentWindow.postMessage({fixture: 'lokal-native-video', method: method, position: position || 0}, '*');
  }
  window.__lokalNativeVideoSnapshot = function() { return current; };
  window.addEventListener('message', function(event) {
    if (event.source !== frame.contentWindow || !event.data || event.data.fixture !== 'lokal-native-video') return;
    const previous = current.state;
    current = event.data;
    if (current.kind === 'error') { options.events.onError({data: 900}); return; }
    if (!ready && current.kind === 'ready') { ready = true; options.events.onReady(); }
    else if (ready && previous !== current.state) options.events.onStateChange({data: current.state});
  });
  frame.srcdoc = $childLiteral;
  return {
    getCurrentTime: function() { return current.position; },
    getDuration: function() { return current.duration; },
    getPlayerState: function() { return current.state; },
    playVideo: function() { send('play'); },
    pauseVideo: function() { send('pause'); },
    seekTo: function(seconds) { send('seek', seconds); },
    cueVideoById: function(value) { send('cue', value.startSeconds); }
  };
}};''';
  var html = musicVideoEmbedHtml(
    videoId,
    appId: appId,
    deferAutoplayToHost: deferAutoplayToHost,
    startPaused: startPaused,
    initialPosition: initialPosition,
  );
  final iframe = RegExp(r'<iframe id="player"[\s\S]*?</iframe>');
  if (iframe.allMatches(html).length != 1) {
    throw StateError(
      'Production iframe structure changed; review native fixture.',
    );
  }
  html = html.replaceFirst(
    iframe,
    '<iframe id="player" title="Generated native fixture" allow="autoplay; fullscreen" allowfullscreen></iframe>',
  );
  html = html.replaceFirst('<script>', '<script>$shim</script><script>');
  const api = '<script src="https://www.youtube.com/iframe_api"></script>';
  if (!html.contains(api)) throw StateError('Production API loader changed.');
  return html.replaceFirst(
    api,
    '<script>window.onYouTubeIframeAPIReady();</script>',
  );
}
