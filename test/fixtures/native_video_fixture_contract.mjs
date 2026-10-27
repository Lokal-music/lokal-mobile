// Executes the generated document and child scripts without claiming native
// decoding. The iPhone acceptance probe separately requires real WK frames.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {createContext, runInContext} from 'node:vm';

let checks = 0;
function equal(...args) { checks++; assert.equal(...args); }
function ok(...args) { checks++; assert.ok(...args); }

const html = readFileSync(process.argv[2], 'utf8');
const paused = process.argv[3] === 'paused';
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
equal(scripts.length, 3, 'controlled API + unchanged production bridge + initializer');
const events = [];
const timers = new Set();
let topMessage, childMessage, childContext, nextFrame, mediaBlob;
const handlers = new Map();
let qualityTotal = 0, droppedTotal = 0;
const media = {
  currentTime: 0, duration: 12, paused: true, ended: false, readyState: 1,
  seeking: false, playbackRate: 1, currentSrc: 'blob:https://app.lokal.mobile/generated',
  seekable: {length: 1, start: () => 0, end: () => 12}, buffered: {length: 0},
  plays: 0, pauses: 0,
  getBoundingClientRect() { return {left: 1, top: 2, width: 320, height: 240}; },
  addEventListener(name, handler) { handlers.set(name, handler); },
  play() { this.plays++; this.paused = false; return Promise.resolve(); },
  pause() { this.pauses++; this.paused = true; },
  getVideoPlaybackQuality() { return {totalVideoFrames: qualityTotal, droppedVideoFrames: droppedTotal}; },
  requestVideoFrameCallback(callback) { nextFrame = callback; return 1; },
};
const parentSender = {};
const frame = {srcdoc: '', contentWindow: {
  postMessage(data) { childMessage({source: parentSender, data}); },
}};
const top = createContext({
  document: {getElementById(id) { equal(id, 'player'); return frame; }},
  setInterval(callback) { timers.add(callback); return callback; },
  clearInterval(callback) { timers.delete(callback); },
  addEventListener(name, callback) { equal(name, 'message'); topMessage = callback; },
  flutter_inappwebview: {callHandler(name, data) { equal(name, 'LokalVideo'); events.push(data); }},
});
top.window = top;
for (const script of scripts) runInContext(script, top);
ok(frame.srcdoc.endsWith('</script></body></html>'));
const childScript = /<script>([\s\S]*?)<\/script>/.exec(frame.srcdoc)[1];
childContext = createContext({
  Blob, Uint8Array,
  atob: value => Buffer.from(value, 'base64').toString('binary'),
  URL: {createObjectURL(blob) { mediaBlob = blob; return media.currentSrc; }},
  document: {visibilityState: 'visible', hidden: false, hasFocus: () => true,
    getElementById(id) { equal(id, 'media'); return media; }},
  innerWidth: 320, innerHeight: 240,
  parent: Object.assign(parentSender, {postMessage(data) {
    topMessage({source: frame.contentWindow, data});
  }}),
  addEventListener(name, callback) { equal(name, 'message'); childMessage = callback; },
  setInterval() {},
});
childContext.window = childContext;
runInContext(childScript, childContext);
equal(mediaBlob.type, 'video/mp4');
equal(createHash('sha256').update(Buffer.from(await mediaBlob.arrayBuffer())).digest('hex'),
  '416a7558921761a26aca370a294be0080ae969afb3249acfef720b3d54b24f37',
  'the seekable Blob must retain the exact generated H.264/AAC bytes');
equal(media.src, media.currentSrc, 'media loads the actual owned Blob resource');
handlers.get('loadedmetadata')();
equal(media.currentTime, 0, 'a provider cue must not seek at metadata-only readiness');
equal(top.__lokalNativeVideoSnapshot().pendingSeekSeconds, paused ? 2.345 : null);
media.readyState = 4;
handlers.get('loadeddata')();
equal(top.__lokalNativeVideoSnapshot().pendingSeekSeconds, null, 'decoded media applies the queued seek');
equal(JSON.stringify(top.__lokalNativeVideoSnapshot().seekable), '[[0,12]]',
  'native seekable ranges are reported without invented media time');
equal(top.__lokalNativeVideoSnapshot().frames, 0, 'source-clock samples must never invent frames');
equal(top.__lokalNativeVideoSnapshot().documentVisibility, 'visible');
equal(top.__lokalNativeVideoSnapshot().documentHidden, false);
equal(top.__lokalNativeVideoSnapshot().documentFocused, true);
equal(top.__lokalNativeVideoSnapshot().viewportWidth, 320);
equal(top.__lokalNativeVideoSnapshot().viewportHeight, 240);
equal(JSON.stringify(top.__lokalNativeVideoSnapshot().videoRectangle), JSON.stringify({left: 1, top: 2, width: 320, height: 240}));
handlers.get('timeupdate')();
equal(top.__lokalNativeVideoSnapshot().frames, 0, 'timeupdate is not frame delivery');
equal(typeof nextFrame, 'function');
nextFrame(10, {presentedFrames: 4, mediaTime: 0.4});
equal(top.__lokalNativeVideoSnapshot().frames, 1, 'count delivered callbacks rather than infer missing frames');
equal(top.__lokalNativeVideoSnapshot().presentedFrames, 4);
equal(top.__lokalNativeVideoSnapshot().qualityFrames, 0);
equal(top.__lokalNativeVideoSnapshot().frameCallbacks, 1);
equal(top.__lokalNativeVideoSnapshot().presentedMediaTime, 0.4);
const callbackAPI = media.requestVideoFrameCallback;
delete media.requestVideoFrameCallback;
qualityTotal = 10; droppedTotal = 10;
handlers.get('timeupdate')();
equal(top.__lokalNativeVideoSnapshot().frames, 0, 'dropped frames are not delivered frames');
media.webkitDecodedFrameCount = 3;
handlers.get('timeupdate')();
equal(top.__lokalNativeVideoSnapshot().frames, 3, 'legacy actual decoder counter is retained');
media.webkitDecodedFrameCount = 0;
qualityTotal = 6; droppedTotal = 1;
handlers.get('timeupdate')();
equal(top.__lokalNativeVideoSnapshot().frames, 5, 'quality fallback excludes dropped frames');
media.requestVideoFrameCallback = callbackAPI;
handlers.get('timeupdate')();
equal(top.__lokalNativeVideoSnapshot().frames, 1, 'a supported presentation API stays authoritative');
equal(media.plays, 0, 'host-controlled documents never self-autoplay');
equal(events.at(-1).ready, true);
equal(media.currentTime, paused ? 2.345 : 0);
equal(top.lokalVideoCommand('seek', 1501), true);
equal(media.currentTime, 1.501);
equal(media.plays, 0, 'paused seek cannot start the real media element');
equal(top.lokalVideoCommand('play'), true);
equal(media.plays, 1);
equal(top.lokalVideoCommand('pause'), true);
equal(media.paused, true);
equal(top.lokalVideoCommand('release'), true);
equal(top.lokalVideoCommand('play'), false);
equal(timers.size, 0);
console.log(JSON.stringify({checks, scope: 'Actual fixture/production scripts with controlled DOM; no native decoding claim'}));
