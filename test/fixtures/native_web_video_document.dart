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
</head><body><video id="media" playsinline controls preload="auto"></video><script>
const media = document.getElementById('media');
// Give WebKit a byte-backed seekable resource. The document owns this one Blob
// until native view retirement; no network, provider URL or synthetic clock.
const mediaBytes = Uint8Array.from(atob('$iosNativeVideoFixtureBase64'), function(c) { return c.charCodeAt(0); });
media.src = URL.createObjectURL(new Blob([mediaBytes], {type: 'video/mp4'}));
let pendingSeekSeconds = null;
function applyPendingSeek() {
  // WebKit can leave a seek pending forever if it is issued at metadata-only
  // readiness. A provider cue must wait for decoded future data; the raw
  // currentTime getter below remains the actual media clock throughout.
  if (pendingSeekSeconds === null || media.readyState < 3) return;
  const position = pendingSeekSeconds;
  pendingSeekSeconds = null;
  media.currentTime = position;
}
for (const name of ['loadeddata', 'canplay'])
  media.addEventListener(name, function() { applyPendingSeek(); report('data'); });
let presentedFrames = 0;
let frameCallbacks = 0;
let presentedMediaTime = 0;
function observeFrame(now, metadata) {
  frameCallbacks++;
  if (Number.isFinite(metadata.presentedFrames))
    presentedFrames = Math.max(presentedFrames, metadata.presentedFrames);
  if (Number.isFinite(metadata.mediaTime)) presentedMediaTime = metadata.mediaTime;
  report('frame');
  media.requestVideoFrameCallback(observeFrame);
}
if (media.requestVideoFrameCallback) media.requestVideoFrameCallback(observeFrame);
function ranges(value) {
  const result = [];
  for (let i = 0; i < Math.min(value.length, 4); i++)
    result.push([value.start(i), value.end(i)]);
  return result;
}
function report(kind) {
  const quality = media.getVideoPlaybackQuality ? media.getVideoPlaybackQuality() : null;
  const qualityFrames = quality && Number.isFinite(quality.totalVideoFrames) ? quality.totalVideoFrames : 0;
  const droppedFrames = quality && Number.isFinite(quality.droppedVideoFrames) ? quality.droppedVideoFrames : 0;
  const decodedFrames = Number.isFinite(media.webkitDecodedFrameCount) ? media.webkitDecodedFrameCount : 0;
  const callbackSupported = typeof media.requestVideoFrameCallback === 'function';
  const rect = typeof media.getBoundingClientRect === 'function' ? media.getBoundingClientRect() : null;
  parent.postMessage({fixture: 'lokal-native-video', kind: kind,
    position: media.currentTime, duration: Number.isFinite(media.duration) ? media.duration : 0,
    state: media.ended ? 0 : media.paused ? 2 : media.readyState < 3 ? 3 : 1,
    frames: callbackSupported ? frameCallbacks : Math.max(0, qualityFrames - droppedFrames, decodedFrames),
    qualityFrames: qualityFrames, droppedFrames: droppedFrames, decodedFrames: decodedFrames,
    presentedFrames: presentedFrames, frameCallbacks: frameCallbacks,
    presentedMediaTime: presentedMediaTime,
    frameCallbackSupported: callbackSupported,
    videoWidth: media.videoWidth, videoHeight: media.videoHeight,
    readyState: media.readyState,
    seeking: media.seeking, pendingSeekSeconds: pendingSeekSeconds,
    documentVisibility: typeof document.visibilityState === 'string' ? document.visibilityState : 'unknown',
    documentHidden: document.hidden === true,
    documentFocused: typeof document.hasFocus === 'function' ? document.hasFocus() : null,
    viewportWidth: Number.isFinite(window.innerWidth) ? window.innerWidth : null,
    viewportHeight: Number.isFinite(window.innerHeight) ? window.innerHeight : null,
    videoRectangle: rect ? {left: rect.left, top: rect.top, width: rect.width, height: rect.height} : null,
    paused: media.paused, ended: media.ended,
    playbackRate: media.playbackRate,
    seekable: ranges(media.seekable), buffered: ranges(media.buffered),
    resourceKind: media.currentSrc.startsWith('blob:') ? 'blob' : 'other'}, '*');
}
media.addEventListener('loadedmetadata', function() { report('ready'); });
for (const name of ['playing','pause','waiting','seeked','ended','timeupdate'])
  media.addEventListener(name, function() { report('state'); });
media.addEventListener('error', function() { report('error'); });
window.addEventListener('message', function(event) {
  if (event.source !== parent || !event.data || event.data.fixture !== 'lokal-native-video') return;
  const command = event.data;
  if (command.method === 'play') {
    applyPendingSeek();
    media.play().catch(function() { report('error'); });
  }
  else if (command.method === 'pause') media.pause();
  else if (command.method === 'seek' || command.method === 'cue') {
    if (command.method === 'cue') media.pause();
    pendingSeekSeconds = command.position;
    applyPendingSeek();
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
