// Runs the application's actual inline iframe bridge, not a copied implementation.
// The YouTube API is a controlled contract fixture; no live playback is claimed.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createContext, runInContext} from 'node:vm';

const html = readFileSync(process.argv[2], 'utf8');
const source = /<script>([\s\S]*?)<\/script>/.exec(html)?.[1];
assert.ok(source, 'application inline bridge is present');
const src = /<iframe[^>]+src="([^"]+)"/.exec(html)?.[1];
assert.equal(new URL(src).searchParams.get('enablejsapi'), '1');
assert.equal(new URL(src).searchParams.get('autoplay'), '0');

function fixture() {
  const events = [];
  const timers = new Set();
  let player;
  const context = createContext({
    setInterval(callback) { timers.add(callback); return callback; },
    clearInterval(callback) { timers.delete(callback); },
    window: {flutter_inappwebview: {callHandler(name, payload) { events.push({name, payload}); }}},
    YT: {Player: function(id, options) {
      assert.equal(id, 'player');
      player = {
        position: 21.25, duration: 180, state: -1, plays: 0, pauses: 0,
        getCurrentTime() { return this.position; }, getDuration() { return this.duration; },
        getPlayerState() { return this.state; },
        playVideo() { this.plays++; this.state = 1; },
        pauseVideo() { this.pauses++; }, // acknowledgement deliberately separate
        seekTo(seconds) { this.position = seconds; },
        ready() { options.events.onReady(); },
        stateChanged(state) { this.state = state; options.events.onStateChange({data: state}); },
        error(code) { options.events.onError({data: code}); },
      };
      return player;
    }},
  });
  runInContext(source, context);
  context.window.onYouTubeIframeAPIReady();
  return {window: context.window, player, events, timers};
}

let checks = 0;
{
  const f = fixture();
  assert.equal(f.window.lokalVideoCommand('play'), false, 'no false success before ready');
  f.player.ready();
  assert.equal(f.player.plays, 1);
  const snapshot = f.events.at(-1);
  assert.equal(snapshot.name, 'LokalVideo');
  assert.equal(snapshot.payload.videoId, 'abcdefghijk');
  assert.equal(snapshot.payload.positionMs, 21250);
  assert.equal(snapshot.payload.durationMs, 180000);
  assert.equal(snapshot.payload.playing, true);
  assert.equal(f.window.lokalVideoCommand('seek', 12345), true);
  assert.equal(f.player.position, 12.345);
  assert.equal(f.window.lokalVideoCommand('arbitrary'), false);
  checks++;
}
{
  const f = fixture();
  assert.equal(f.window.lokalVideoCommand('release'), true);
  f.player.ready();
  assert.equal(f.player.plays, 0, 'release before ready prevents late autoplay');
  assert.equal(f.player.pauses, 1);
  assert.equal(f.timers.size, 0);
  assert.equal(f.window.lokalVideoCommand('play'), false);
  checks++;
}
{
  const f = fixture();
  f.player.ready();
  f.player.stateChanged(3);
  f.window.lokalVideoCommand('release');
  assert.equal(f.window.lokalVideoPaused(), false, 'buffering is not a pause acknowledgement');
  f.player.stateChanged(2);
  assert.equal(f.window.lokalVideoPaused(), true);
  assert.equal(f.timers.size, 0);
  const pauses = f.player.pauses;
  f.player.stateChanged(1);
  assert.equal(f.player.pauses, pauses + 1, 'late playback after release is paused again');
  assert.equal(f.events.at(-1).payload.playing, false);
  checks++;
}
{
  const f = fixture();
  f.player.ready();
  f.player.error(150);
  assert.equal(f.events.at(-1).payload.error, 150);
  assert.equal(f.events.at(-1).payload.ready, false);
  assert.equal(f.timers.size, 0);
  assert.equal(f.window.lokalVideoCommand('play'), false);
  checks++;
}
console.log(JSON.stringify({checks, scope: 'Production JavaScript with controlled YouTube API; no live receiver or WebKit acceptance'}));
