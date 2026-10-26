# iPhone integration follow-up

Checked 26 October 2026. These findings guide remaining implementation; they do
not establish receiver, account or physical-iPhone acceptance.

## Media-services reset

Apple requires orphaned audio objects and session configuration to be rebuilt,
with playback remaining paused until a user starts it again. See
[the current AVAudioSession reset contract](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification).
This differs from an ordinary resumable interruption.

The locked `audio_session` 0.2.4 already delivers
`AVAudioSession().mediaServicesWereResetStream`; an additional Swift session owner
is unnecessary. PlayerService currently subscribes to interruptions and noisy
routes, but does not consume this reset event. Recovery remains unimplemented.

```mermaid
flowchart LR
  Reset[Media services reset] --> Invalidate[Suppress interruption auto-resume / stale playback work]
  Invalidate --> Dispose[Serialize disposal of old native players]
  Dispose --> Paused[Restore session configuration / keep queue and saved position paused]
  Paused --> User[User presses Play or selects another song]
  User --> Rebuild[Create the intended backend and load at the retained position]
```

Implementation must retain song IDs, queue order, processing preferences and the
selected source. A pending new user selection wins over an older reset snapshot.
Keep one audio-session owner and await native cleanup before constructing another
Rust/Core Audio output; a Dart timeout alone cannot cancel native cleanup. Remote
receiver playback must not be paused merely because the phone's local media
services restarted. Clear interruption auto-resume state so an old interruption
end cannot restart music after reset.

Qualification requires both ordinary system playback and Rust/DSP playback,
playing/paused states, repeated resets, a concurrent song selection and an active
remote receiver. A posted notification can exercise recovery logic, but does not
prove an actual media-daemon restart. Use Apple's Developer Settings reset on a
real test phone for that acceptance.

## Chromecast

Google's current [iOS package manifest](https://github.com/googlecast/google-cast-ios-sdk/blob/main/Package.swift)
selects SDK 4.8.6 and **iOS 16**. Its setup page has older summary text mentioning
15, so the executable package requirement takes precedence for build planning.
[Google's setup guide](https://developers.google.com/cast/docs/ios_sender)
requires the generic and receiver-specific Bonjour service declarations and
explicit discovery for a custom picker. Current CocoaPods publication ends at
4.8.6; newer integration uses SPM or a verified direct framework distribution.

The base Lokal app still targets iOS 15. Do not silently raise that floor or ship
a mandatory newer framework under a false minimum-OS declaration. First prove an
availability-gated distribution or explicitly choose a higher-floor Cast build.
AirPlay remains the system route UI. Then adapt the existing Cast channel/state
contract, file HTTP server, transport controls and local/remote ownership handoff.
A simulator discovery fixture cannot substitute for an actual Cast receiver.

## Discord Rich Presence

Discord's [August 2026 mobile announcement](https://discord.com/blog/mobile-platform-support-arrives-in-discord-social-sdk)
confirms an official iOS Social SDK; it is incorrect to call iPhone presence
categorically impossible. The existing Mornye bridge is Android-only. Its use of
the installed Android client's unauthenticated RPC session does not establish an
equivalent iOS transport.

The candidate iPhone path is the official SDK and explicit account linking. See
[the SDK client/authentication reference](https://discord.com/developers/docs/social-sdk/classdiscordpp_1_1Client.html)
and [release notes](https://discord.com/developers/docs/social-sdk/release_notes.html).
Use the minimal presence scopes; Lokal needs no voice, DM or friends-list UI for
music presence. Confirm this application's configuration/eligibility, callback
scheme, supported iOS minimum and existing SDK redistribution/notices handling
before enabling an opt-in iOS account control. The SDK now has mobile-specific
authentication fixes, so select an observed version and test it instead of
assuming old Android bridge behavior transfers unchanged.

No Discord account credentials are needed in CI. No iOS presence is implemented
or accepted yet. The existing community invite button is a separate working URL
feature.

## Music video and timed lyrics from PRs 199–200

The shared full player includes Video and synchronized-only Space actions.
Android uses Media3. The explicit non-Android branch uses the existing official
YouTube iframe in WKWebView, rather than attempting an Android platform view on
an iPhone. It does not pretend the album recording shares the video's clock.
Direct native AVPlayer paired-stream presentation is still a separate port task;
watching through the authorized embed is the current fallback.

Verify pause-before-enter, stop-before-song-resume, dismissal, backgrounding,
fullscreen and failed/expired embeds on iPhone. In particular, the fallback's
asynchronous WebView teardown needs an observed audio-ownership handoff before
claiming no overlap with local playback. Timed Space lyrics use the shared song
clock; unsynchronized lyrics must not acquire invented timestamps. The native
harness now supplies local generated LRC lyrics and checks entering/leaving Space
with the real player paused at a known position. That new native check is pending.
