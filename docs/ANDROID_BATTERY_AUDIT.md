# Android battery audit and validation plan

## Scope and confidence

This change reduces **unnecessary Dart timer and native FFI activity** in the
audio service. Source inspection establishes the polling behavior, but **does
not establish a measured battery percentage improvement**. Do not claim energy
savings until profiling on real phones is complete.

### Confirmed code paths

- `RustAudioService.init()` started an event poll every 50 ms, even after the
  Rust manager was initialized but no track was playing.
- While Rust playback was active, progress and event polls each ran at 50 ms,
  including with the app backgrounded (40 scheduled callbacks/second total).
- After pause, progress continued polling every 250 ms while event polling
  continued at 50 ms.
- `PlayerService._ensurePositionSaveTimer()` wrote last-played state every
  5 seconds and the pause path did not stop the timer.
- `AppLog.initializePersistence()` started a repeating 5-second timer even
  when the log buffer was empty.
- `PriorityAnchorService` continuously writes silent PCM on an independent
  Java `AudioTrack` when the optional anchor feature is active. The previous
  preference default was enabled, including when users had never opted in.
  This PR changes the fallback default to disabled. Persisted explicit
  `true`/ `false` settings remain unchanged.
- `MusicNotificationService` owns a partial wake lock while playing. Removing
  it unconditionally could interrupt screen-off playback, so this PR does not
  change it.

### Implementation

- **Foreground playing:** keep 50 ms Rust event and progress cadence for
  responsive seek bars, synchronized lyrics, and gapless/crossfade UI handoff.
- **Background playing:** reduce both timers to 250 ms. Native playback,
  gapless handoff and audio DSP run independently of Dart polling.
- **Paused:** stop progress polling altogether; refresh position immediately
  after seek and on pause. Check events at 500 ms in foreground or 1 second
  in background.
- **Idle/stopped:** check native events once per second while foregrounded
  or once every 2 seconds backgrounded; immediately drain/rearm after an
  explicit play, resume, stop, or lifecycle transition.
- **Persistence:** cancel the 5-second position-save timer on playback pause,
  persisting the final resume position once. Do not cancel it merely because
  the UI is backgrounded; audio still plays there.
- **Logging:** schedule disk flushes only when the queue contains entries,
  retain flush-on-lifecycle and retry-on-error semantics, and serialize writes.
- **Priority Anchor:** disable the silent 48 kHz companion AudioTrack by default
  for existing installations with no saved preference and new installations.
  Keep the setting as an opt-in compatibility workaround for screen-off
  bit-perfect audio on devices that need it. Preserve explicit saved choices;
  do not clear user preferences. Add opt-in/change/start/stop diagnostic logs,
  reliably stop on playback-state transitions and player disposal, release
  the track on worker failure or Activity destruction, and always attempt
  release even when AudioTrack.stop() throws.

**Compatibility trade-off:** users whose device depended on the previous
default-on Anchor may experience screen-off stalls with Rust/USB output.
They can opt back into Settings > Playback > Background > Background playback
anchor. Capture Lokal logs, device model, Android build, route/backend,
and whether enabling the switch fixes the issue. Screen-off playback with
Anchor disabled is a release validation scenario.

## Required device A/B profiling before merge

Compare the same device, release/profile build, network, audio quality,
display brightness, volume, and Android battery policy on base and PR head.
Run each scenario at least three times. Prefer Android Studio Power Profiler
or Perfetto/System Tracing over Battery Historian (deprecated).

1. Reset the profiling window with `adb shell dumpsys batterystats --reset`
   (this clears device battery statistics).
2. Unplug the device and run for 30 minutes, then collect:
   `adb shell dumpsys batterystats > batterystats.txt` and
   `adb bugreport bugreport.zip`.
3. Compare app CPU time, scheduling/wakeup counts, partial wake-lock
   held time, network bytes, and device-reported battery drain / mAh where
   available. Never compare raw % with different charge levels or signal.
4. Test **no audio / app backgrounded**, **paused with song loaded**,
   **screen-off local FLAC**, **screen-off Qobuz streaming**,
   **visible player with synced lyrics**, and **queue of four upcoming songs**.
5. Also test USB bit-perfect / Priority Anchor enabled and disabled, Bluetooth,
   Android Auto, cast routes, pause/resume/headset-button interactions,
   radio and next-track/crossfade. Check that Android's media session and
   notification show the right position and artwork after wake.

Targets (acceptance criteria, not measurements): eliminate periodic audio
progress polls while paused; no empty-log recurring timer; background
Rust timer count at most 8/s while playing, compared with 40/s before;
no repeated paused position persistence; no lost track-ended/next-track events
or audible discontinuities; wake lock released on pause/stop; comparable
battery drain and app CPU measurements no worse than baseline.

## Follow-up optimization candidates (only after profiling)

- **Partial wake lock ownership:** confirm whether the media engine and
  `MusicNotificationService` both hold locks. Preserve a correct lock for
  screen-off streaming; narrow ownership rather than deleting blindly.
- **Priority Anchor (now default-off):** quantify the extra silent 48 kHz
  AudioTrack thread versus screen-off playback reliability, and use
  reproducible bug logs to refine device/route-specific fallback if needed.
- **Notification refresh:** the Rust position listener publishes every ~2s
  through `_updateNotificationState()`, including favorite lookup and album
  color handling. Separate position-only updates from metadata reconstruction
  if profiling shows material overhead.
- **Network prefetch:** use bytes, requests, and on-device radio power to
  evaluate four-track prefetch. Retain rapid next-track playback; bound
  concurrency and cancel obsolete work rather than simply disabling preload.

Any percent battery savings reported for this PR must come from device
measurements rather than extrapolating timer count reductions.
