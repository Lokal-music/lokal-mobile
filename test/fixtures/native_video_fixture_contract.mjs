// Executes the generated document and child scripts without claiming native
// decoding. The iPhone acceptance probe separately requires real WK frames.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createContext, runInContext} from 'node:vm';

const html = readFileSync(process.argv[2], 'utf8');
const paused = process.argv[3] === 'paused';
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
assert.equal(scripts.length, 3, 'controlled API + unchanged production bridge + initializer');
const events = [];
const timers = new Set();
let topMessage, childMessage, childContext;
const handlers = new Map();
const media = {
  currentTime: 0, duration: 12, paused: true, ended: false, readyState: 4,
  plays: 0, pauses: 0,
  addEventListener(name, handler) { handlers.set(name, handler); },
  play() { this.plays++; this.paused = false; return Promise.resolve(); },
  pause() { this.pauses++; this.paused = true; },
  getVideoPlaybackQuality() { return {totalVideoFrames: 0}; },
};
const parentSender = {};
const frame = {srcdoc: '', contentWindow: {
  postMessage(data) { childMessage({source: parentSender, data}); },
}};
const top = createContext({
  document: {getElementById(id) { assert.equal(id, 'player'); return frame; }},
  setInterval(callback) { timers.add(callback); return callback; },
  clearInterval(callback) { timers.delete(callback); },
  addEventListener(name, callback) { assert.equal(name, 'message'); topMessage = callback; },
  flutter_inappwebview: {callHandler(name, data) { assert.equal(name, 'LokalVideo'); events.push(data); }},
});
top.window = top;
for (const script of scripts) runInContext(script, top);
assert.ok(frame.srcdoc.endsWith('</script></body></html>'));
const childScript = /<script>([\s\S]*?)<\/script>/.exec(frame.srcdoc)[1];
childContext = createContext({
  document: {getElementById(id) { assert.equal(id, 'media'); return media; }},
  parent: Object.assign(parentSender, {postMessage(data) {
    topMessage({source: frame.contentWindow, data});
  }}),
  addEventListener(name, callback) { assert.equal(name, 'message'); childMessage = callback; },
  setInterval() {},
});
childContext.window = childContext;
runInContext(childScript, childContext);
handlers.get('loadedmetadata')();
assert.equal(media.plays, 0, 'host-controlled documents never self-autoplay');
assert.equal(events.at(-1).ready, true);
assert.equal(media.currentTime, paused ? 2.345 : 0);
assert.equal(top.lokalVideoCommand('seek', 1501), true);
assert.equal(media.currentTime, 1.501);
assert.equal(media.plays, 0, 'paused seek cannot start the real media element');
assert.equal(top.lokalVideoCommand('play'), true);
assert.equal(media.plays, 1);
assert.equal(top.lokalVideoCommand('pause'), true);
assert.equal(media.paused, true);
assert.equal(top.lokalVideoCommand('release'), true);
assert.equal(top.lokalVideoCommand('play'), false);
assert.equal(timers.size, 0);
console.log(JSON.stringify({checks: 8, scope: 'Actual fixture/production scripts with controlled DOM; no native decoding claim'}));
