# Lokal Mobile for iPhone: architecture and release plan

Status: implementation and hosted native validation, 26 October 2026 (Europe/Paris).
The original audit used `42f8f1dbc939`; implementation is tracked in
[PR #172](https://github.com/lokal-music/lokal-mobile/pull/172).

Hosted Xcode 26.0.1 builds the complete simulator app and release/AOT iPhone app.
**Build 27 remains the last complete native pass on iOS 18.6 and 26.0.**
Build 32 validates the current continuation through #217 on iOS 18.6; its iOS 26
simulator fails before app execution. The updated workflow isolates that runtime
on a fresh Mac, with current-source results pending. The iOS 16+
unsigned engineering IPA passes inspection of 34 device binaries, Cast resources,
privacy metadata, source/notices and matching symbols. See the exact source,
checksum and native evidence in the build-27 checkpoint below. Installation still
requires local signing; physical-device and Windows install/update acceptance
remain open.

The branch integrates **38 merged mobile PRs after #172 through #217**, including
Likes stream revalidation, retained-artwork Space, separate video timing, search,
profile, notification artwork, playlists and locale updates. See
[the PR-by-PR UI/behavior review and revised WidgetKit design](IOS_POST172_REVIEW.md)
and [current integration feasibility findings](IOS_FOLLOWUP_FEASIBILITY.md).

The earlier iOS 18.5 startup abort matches
[WebKit bug 293831](https://bugs.webkit.org/show_bug.cgi?id=293831). CI explicitly
tests iOS 18.6 first and iOS 26.0 second, using an isolated iPhone 16. The old launcher-subprocess and launchctl-label checks were not
reliable evidence of app liveness; direct VM readiness now supplies that gate.
Native console, process sampling, screenshots and crash reports remain available.

The IPA is an engineering build, not a qualified release. See
[Windows installation and acceptance](IOS_SIDELOADING.md).

```mermaid
flowchart LR
  Source["Flutter + Rust source"] --> Mac["Hosted Xcode 26.0.1"]
  Mac --> Device["arm64 release/AOT · build passes"]
  Mac --> Sim["iOS 26 + 18.6 · full app shell renders"]
  Device --> IPA["Unsigned engineering IPA · inspection passes"]
  Sim --> Smoke["Scanner / QuickJS / audio · simulator passes"]
  IPA --> Windows["Windows re-sign/install · untested"]
  Windows --> Phone["Physical iPhone acceptance · pending"]
```

### Implementation already in place

- iPhone-only runner, iOS 16 floor, generated alternate icons, pinned build tools
  and locked dependencies, source/license bundle and unsigned IPA inspection.
- Swift document imports with scoped/coordinated transactional copies; persistent
  app-owned library root and ID-preserving sandbox-path rebasing; database files
  in Application Support with a nondestructive legacy migration.
- Explicit iOS system and Rust/Core Audio modes; single audio-session owner,
  interruptions, Now Playing/remote controls, route diagnostics and AirPlay UI.
  Rust is selected for DSP or unsupported system formats without claiming direct
  USB or bit-perfect output. System WAV, Rust DSP and WavPack routes pass the
  simulator smoke test; physical routes and interruptions remain unvalidated.
- Spotify's existing web-session protocol ported to isolated WKWebView and the
  existing Keychain-backed credential store. Live account checks remain pending.
- Native Files export for recap CSV/TXT and M3U/M3U8 playlists; manual playlist
  import persists an app-owned snapshot before resolving existing song IDs.
  Cancellation/provider errors and bounded UTF-8 input have contract coverage.
  The native picker UI and exports still need iPhone acceptance.
- Integration smoke test exercises real startup, scanner, QuickJS, system WAV
  playback, Rust DSP and WavPack fallback. No native mocks substitute for these
  operations; these assertions passed on iOS 26.0. Broader fixture and device
  coverage remain acceptance work.

The [Cast sender transport](IOS_CAST_TRANSPORT.md) now has a pinned real SDK,
native channel adapter, confirmed commands and a guarded local/remote handoff.
Its standalone native device/simulator linkage and integrated application tests
pass; actual receiver acceptance remains pending. WidgetKit, Discord feasibility and resumable
background transfers remain open work. Native desktop Bonjour discovery
passes its controlled service/HTTP checks on build 18 / iOS 18.6. Live add-on stream handles currently
retain the system streaming adapter and explicitly report Rust DSP bypass;
DSP support for those sources remains open rather than attempting to open an
opaque stream handle as a native file. Shared UI and source availability do not
establish iOS parity.

## Product brief

Deliver a sideloadable iPhone version with the Android product's features wherever
iOS reasonably supports them. Time is not a constraint. Preserve Lokal's visual
identity, local-first library, optional online services, and existing Android
behavior. Do not trade away online sources, add-ons, or desktop integration to
reach an early release date.

Advanced audio is a separate feasibility track: direct USB, bit-perfect output,
native DSD/DoP, DAP controls, Android codec selection and privileged audio paths
are not required. Ordinary headphone/Bluetooth/USB audio through iOS, reliable
playback, codec coverage, and practical sound controls remain product goals.
DSD **file decoding to PCM** is distinct from native DSD output.

The maintainer uses Windows and currently has no Mac, iPhone, or paid Apple
Developer membership. Build using hosted macOS/Xcode. Sign on the installer's
Windows machine using their own Apple account. Recruit an iPhone tester before
calling any build release-ready. Keep account credentials out of CI and chat.

## Recommended architecture

Keep Flutter/Riverpod/Isar and the existing Rust bridge. Add small platform
adapters around the platform-dependent services; preserve repositories, queue
rules, library identity and shared presentation. A SwiftUI rewrite would duplicate
the largest tested part of the product while still requiring native audio and
file integration. A web wrapper would discard useful existing native work.

```mermaid
flowchart TB
  UI["Shared Flutter UI · themes · lyrics · Cover Flow · Classipod"]
  Domain["Existing Dart orchestration · Riverpod · library · queue · sources"]
  DB["Isar · preferences · app-owned files"]
  Ports["Platform adapters + capability registry"]
  Android["Existing Android implementation"]
  IOS["iOS adapters · Swift where Apple APIs are needed"]
  Session["One audio session coordinator"]
  System["just_audio / AVPlayer · system audio"]
  Rust["Rust · metadata · QuickJS · decoders · optional DSP"]
  CoreAudio["CPAL / Core Audio · codec fallback, after validation"]
  Files["Files picker · scoped access · import transactions"]
  OS["Now Playing · remote commands · routes · lifecycle"]
  UI --> Domain
  Domain --> DB
  Domain --> Ports
  Ports --> Android
  Ports --> IOS
  Domain --> Rust
  IOS --> Session
  Session --> System
  Session --> CoreAudio
  Rust --> CoreAudio
  IOS --> Files
  IOS --> OS
```

These are architectural boundaries, not a requirement for a new class per box.
The current adapters extend the existing player and platform channels; focused
regression coverage protects the shared Android paths.

| Boundary | Responsibility and rule |
| --- | --- |
| Platform capabilities | Availability and reason for each feature, plus runtime route/permission state. Hide irrelevant Android controls. Unsupported actions return a typed result; a missing plugin is not success. |
| Playback backend | Add an explicit iOS system mode rather than persisting `normalAndroid` or displaying Oboe on iOS. Keep queue ownership in the existing player. Exactly one active playback backend. |
| Audio session | Adapt `audio_session` for iOS music playback, activation, interruption, route loss and media-services reset. One owner configures the process-wide session, including video/radio/casting handoffs. Swift observes or supplies missing events without independently fighting that owner. |
| System media controls | Map current notification-owner semantics to `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. Library, radio and desktop remote must publish the actual current owner. Remove duplicate command handlers on disposal. |
| Library file access | Represent an app-owned file or leased external resource, not an Android `content://` URI. Resolve imported paths against the current sandbox; never persist its absolute installation prefix as identity. |
| Native integration | Typed contracts for document imports, build identity, route diagnostics, OAuth, share/save, casting and lifecycle. Use generated Pigeon bindings if the added contract surface justifies that dev dependency. Preserve existing Android channel names. |
| Credentials | Use iOS Keychain through the existing secure-storage package. Audit access-group requirements with free signing; do not require shared groups or iCloud entitlements for the base app. |
| Jobs | Separate active playback from scan/copy/download work. Use resumable persisted job state; iOS suspension is normal. Background audio is not permission for indefinite unrelated work. |

### Audio decision and experiments

Use the existing `just_audio` iOS backend as the baseline for system-supported
formats. It already declares iOS support. Validate real gapless transitions,
seeking, background playback and protected-header streams on the locked version.
Do not infer support from Android's implementation or from the package's latest
documentation.

The shared Rust engine remains needed by metadata and add-ons at startup. Compile
it with `--no-default-features --features native_audio,rquickjs/bindgen` on iOS. Prove the dependency
graph contains no `rusb`/`libusb1-sys`. Cargokit now selects the iOS feature set
by platform, while Android retains its default `native_audio` and `uac2` features.

The resolved `rquickjs-sys` 0.14.0 ships macOS bindings but no
`aarch64-apple-ios` or simulator bindings. The manifest now enables generated
bindings for iOS with the matching Xcode SDK
and explicit Clang device/simulator triples; macOS ABI bindings are not reused.
The native probes and Cargokit integration compile this configuration.

For formats that AVPlayer cannot play, investigate the already-vendored CPAL iOS
Core Audio backend with Rust decoders. Its source exists, but includes TODOs for
session-derived sample rates and buffer sizing. Compare it against AVPlayer using
the same fixture corpus and measured interruptions/route changes. Do not choose
it as the default based only on a successful compile. Avoid full-file PCM
transcoding as the normal fallback: it adds startup delay and storage cost.

Preserve practical EQ, ReplayGain, crossfade and speed controls where the iOS
backend actually implements them. Some existing just_audio extensions are
Android-specific: pitch, Android effects and boost must be explicitly audited.
Use the Rust DSP path if it meets stability and power targets; otherwise record
the limitation with the exact affected feature. Do not label mixed or
DSP-processed output bit-perfect.

The iPhone routing rules now include independent pitch and positive ReplayGain.
The locked system player does not implement independent pitch; AVPlayer volume
cannot provide gain above unity. Use native SoundTouch for pitch and Rust gain
for positive normalization. Negative ReplayGain can stay on the system player.
A codec fallback is re-evaluated for the next explicitly selected/resumed track,
so ordinary flat playback can return to AVPlayer. Live changes preserve the current track/position; resetting processing returns
to system playback when the format permits it. These pitch/normalization transitions and the expanded codec corpus pass on
both iOS 18.6 and 26.0 in build 17.

```mermaid
flowchart TD
  Track["Track requested or advanced"] --> Handle{"Add-on live stream handle?"}
  Handle -->|Yes| Streaming["System streaming adapter · report DSP bypass"]
  Handle -->|No| Codec{"DSF / DFF / WavPack / Ogg / Opus?"}
  Codec -->|Yes| Native["Rust decoder + DSP · Core Audio"]
  Codec -->|No| Processing{"EQ / crossfeed / independent pitch / positive ReplayGain?"}
  Processing -->|Yes| Native
  Processing -->|No| System["System player · AVPlayer"]
```

The codec corpus generates MP3 VBR, AAC/M4A, ALAC, 96 kHz stereo FLAC, AIFF,
Vorbis and Opus from an in-memory tone, including Unicode filenames. It verifies
native scanning, sample-rate metadata, intended backend and advancing position.
An additional queue case exercises system-to-Rust auto-advance into Opus. It does
not certify output fidelity, gapless timing, or physical headphone/DAC behavior.

Activation occurs after the listener presses Play. On interruption, remember both
the prior playing state and subsequent user actions. Resume only when permitted
and still wanted. Headphone removal pauses without unexpectedly moving audio to
the speaker. Rebuild routes/streams after media-services reset and report the
actual rate/channel count, rather than requested values.

### Native metadata bridge

The Rust scan DTO now carries album-artist tags from ordinary files and DSF/DFF
ID3 tags. iPhone metadata adapters and library scans preserve compilation-album
identity; the existing Android row-selection behavior is retained. The bridge was
regenerated with the exact 2.13.0 CLI, without manually editing serialized fields.
A preliminary regeneration retained all 139 native/Dart entrypoints while putting
the add-on entrypoints in generator order.

The default-feature Rust suite still passes all 303 tests, including extended WAV
and DFF album-artist checks. A real host shared-library test passes tag write/read,
scanner-to-Dart album-artist transport, native add-on sealing/opening and QuickJS
echo. It loads the actual native library; it does not initialize mock bindings.
The iOS smoke test also writes and checks a distinct album artist. The regenerated bridge also passes the Apple simulator checks on both OS versions
in build 17.

### Playback credentials while the screen is locked

The locked secure-storage plugin defaults to `WhenUnlocked` on iOS. Playback
credentials now use `AfterFirstUnlock`, without synchronization or a shared access
group, so normal screen locking need not interrupt token refresh, scrobbling or
add-on vault access. Android keeps the plugin's existing default options.

A small Swift Keychain operation changes legacy nonsynchronized items in the
locked plugin's default service in place. It changes the accessibility attribute
without retrieving, deleting or copying credential values. Reads/writes retry
preparation after a failure; concurrent requests share the in-flight operation.
Failures propagate instead of reporting migration success. Device-bound storage
is deliberately avoided because restoring encrypted add-on files also requires
their backed-up master key. No new signing entitlement is required.

The native smoke test creates a synthetic legacy Keychain item, migrates/reads it,
updates it through the playback store and deletes it. It also navigates Library,
You and Settings through the actual UI and captures each screen. These additional
checks pass on both runtimes in build 17. The simulator cannot establish protected-data
behavior after a real device reboot/lock, free-account re-signing continuity or
live-account refresh; those remain explicit device acceptance gates.

### Files, imports and desktop transfers

Default to copying listener-selected files into app-owned persistent storage
through the Files document picker. A picker may return an iCloud/File Provider
resource that must first be coordinated and downloaded. Security-scoped access
must stay valid until the operation completes and be released on all exits.

Use staging -> validation -> atomic finalization -> database update. Persist a
relative locator and stable track ID; resolve against the current application
container on each launch. Handle duplicate imports, cancellation, low disk space,
provider errors, moves and relaunch after interruption. Imported music is not an
evictable cache. Exclude reproducible caches from backup and choose/document the
backup policy for music and user data. Offer export/backup before destructive
library operations.

External-folder references can follow after a spike proves picker support,
bookmark persistence, stale/revoked access and provider coordination on real
iPhones. Never pass a bare external path to a long-running Rust scan after its
access lease ends. iOS does not offer Android-style whole-device scanning.

Desktop sync keeps the existing authentication/pairing and song identities.
Write copied songs through the same import transaction. Test local-network
permission denial and changed Wi-Fi networks. Bonjour service declarations are
needed only if used. Audit raw multicast discovery against iOS entitlements;
provide manual address/QR pairing if needed. Plain local HTTP requires a narrow,
justified transport policy; do not disable ATS globally as a shortcut.

### Desktop Bonjour discovery

The new Swift adapter browses `_lokal._tcp` through Apple's `NetServiceBrowser`,
resolves numeric IPv4/IPv6 addresses, accepts protocol-1 TXT records and returns
the same id/name/host/port contract as Android. Searches are explicit, bounded to
eight seconds and limited in concurrent resolution. Backgrounding and completion
stop the browser/resolvers; stale delegate callbacks cannot modify a later search.
Apple owns Local Network authorization through the actual operation; the adapter
does not fabricate a permission grant or require raw multicast entitlements.
Manual-address and QR pairing retain the existing shared protocol.

```mermaid
flowchart LR
  Scan["User scans for desktops"] --> Dart["Existing Desktop Link service"]
  Dart --> Bonjour["Swift · system Bonjour browser"]
  Bonjour --> TXT["Resolve address + protocol-1 TXT record"]
  TXT --> Pair["Existing pairing / authenticated HTTP + WebSocket"]
  Manual["Manual address / QR"] --> Pair
```

The native test harness advertises a real Bonjour service and an incompatible
protocol-2 service on the Mac, using a run/attempt-specific identifier. The app
must discover the compatible service, reject the incompatible one, and reach the
advertised HTTP probe endpoint. This controlled fixture does not establish actual
Windows desktop pairing, transfer behavior, or real-device permission denial.
These native checks pass on build 18 / iOS 18.6 (run 40242638631, attempt 1,
source `d345edb3dae4b3a41c4524d163d44bdb83fd5309`). iOS 26 did not execute them
because its simulator failed to boot. Shared Desktop Link/remote-service
regressions pass 40 tests, including actionable native error propagation.

## Source audit and feature disposition

The source findings below record the **original audit**, not the current tree.
The last column remains the acceptance target. Consult the implementation and
validation ledger above for current evidence. Shared source and plugin
registration are not evidence that an iOS feature works.

| Area | Finding in audited source | iPhone plan / acceptance evidence |
| --- | --- | --- |
| App shell/startup | No root `ios/` runner. `main.dart` awaits `RustLib.init`, database and external playback before `runApp`. | Generate and commit an iPhone runner using pinned Flutter. Prove clean launch with no Android plugins installed. |
| External intents | `ExternalPlaybackService._consumePendingExternalPlayback` calls an Android channel and catches `PlatformException`, not `MissingPluginException`. | Supply iOS document/open-URL integration and capability-gate Android Locker integration. Add a real startup regression at this seam. |
| Library and playlists | Existing Flutter/Isar library and Rust scanner; Android MediaStore/SAF channels in storage services. | Reuse models/IDs; implement import and supported folder access, export, metadata/tag editing, lyrics/artwork sidecars. Verify install updates preserve data. |
| Player, radio and controls | `NotificationService` uses `com.mossapps.flick/player`; session selection and interruption setup assume Android. | iOS media/session adapter, background audio mode, system controls and ownership handoffs. |
| Codec coverage | Rust scanner lists MP3/FLAC/Ogg/Opus/M4A/WAV/AIFF/ALAC/DSF/DFF/WavPack. | Fixture matrix per container/codec; system path first, Rust fallback where needed. DSD-to-PCM remains a normal codec goal. |
| Lyrics | Timed lyrics, translation, romanization and imported files already shared. | Preserve all modes, provider ordering and manual correction; test iOS file import and Reduce Motion. |
| Discovery/accounts | Shared online sources, in-app webviews and secure storage; Spotify OAuth has an Android channel. | Preserve each existing protocol: browser PKCE for the Web API integration; isolated WKWebView for the existing Spotify web-session bridge. Audit callback origins, cookies and Keychain. No embedded client secret. |
| Downloads and add-ons | Rust `rquickjs` plus Dart host/network/package manager; FFmpeg plugin declares iOS. | Preserve opt-in add-ons for the sideload build. Test QuickJS without JIT, filesystem sandbox, cancellations, binary slices and provider authentication. Persist/restart jobs interrupted by suspension. |
| Network libraries/scrobbling | Shared Subsonic/Jellyfin/WebDAV/SMB/UPnP and Last.fm/ListenBrainz integration. | Per-service contract tests plus representative live integration; offline/error states, TLS and credential redaction. |
| Desktop link | Pairing, remote controls, merge and bidirectional copying already exist; destination storage is Android-specific. | Retain the full feature set using iOS destinations, local-network permission and restartable transfer state. |
| Artwork and presentation | Shared Flutter themes, motion artwork, Classipod, queue gestures and glass shaders. | Keep the full experience; safe areas, keyboard, accessibility, high-refresh pacing and real-device shader/memory checks. |
| Listening/library tools | Flow, personal mixes, recaps/stats, sleep timer, CUE/EAC, metadata editing, duplicate detection and file organization exist in the shared product. | Preserve ordinary features; validate timers under suspension and edits/organization within scoped file access. Assess Automix, gapless, crossfade, EQ and skip-silence backend support individually. |
| Sharing/images | Picker/share/gallery channels and platform plugins coexist. | Use native share sheet, Files export and Photos save permissions only in context. Test cancellation and temp-file cleanup. |
| Casting | Existing Chromecast native channel and DLNA route integration; no AirPlay backend was found in the audited casting directory. | Add system AirPlay route UI; investigate Chromecast iOS sender integration and DLNA discovery/control. Test actual receivers; handle multicast restrictions without promising unverified parity. |
| Bluetooth/USB | Android Bluetooth, volume and direct UAC2 controls. | Normal iOS output routes, system volume and diagnostics. Defer raw USB, codec forcing and Android-specific direct audio. A USB DAC can still be an ordinary iOS system route. |
| Discord | Local `mornye_discord` plugin declares Android only. | Investigate an officially supported iOS integration. Do not present a no-op as working presence; document unsupported account/device behavior if necessary. |
| Widgets/icons | `home_widget` declares iOS; app-side widget implementation is Android-specific. | Plan WidgetKit and declared alternate icons. Prove entitlements/re-signing before enabling widgets; avoid an extension dependency for basic playback. |
| Car/overlay integrations | Android Auto and draw-over-other-app player are Android services. | Evaluate CarPlay separately: appropriate entitlement is a prerequisite. Use in-app mini-player and system controls on iPhone; arbitrary floating overlays have no equivalent public iOS API. |
| Updates/build identity | APK updater, Play updates and custom build-info channels. | iOS bundle metadata adapter and Windows sideload update instructions. No in-app APK installer. Preserve library and Keychain behavior across re-signing tests. |

The resolved plugin inventory contains 22 iOS registrations including the Rust
builder and integration-test plugin. `flutter_displaymode`, `in_app_update` and
`mornye_discord` declare Android-only implementations. Federated packages use
different Android/iOS package names, so subtracting those name lists would create
false missing-plugin findings.

The locked file picker, FFmpeg audio and home-widget native specifications declare
iOS 14 floors. The app now targets **iOS 16+** (maintainer choice for the current Cast SDK); all 33 device Mach-O binaries in the
first engineering package declare minimum versions at or below that floor.
Actual OS-version compatibility still needs runtime and physical-device tests.
The hosted workflows now pin Xcode 26.0.1 (17A400), Flutter 3.47.1 and Rust 1.98.0.
Binary compilation is proven for that combination; runtime compatibility remains
under investigation.

The standalone environment dump has been removed from
`rust_builder/cargokit/build_pod.sh`, and the pod explicitly invokes Bash. Inspect pod linker flags/static symbol retention and the
flutter_rust_bridge loader on iOS; staticlib support in the manifest alone is
insufficient. FFmpeg downloads and all vendored native libraries need device and
Apple Silicon simulator slice checks plus their redistribution notices.

## Build, signing and Windows installation

```mermaid
flowchart LR
  Source["Reviewed commit + locked dependencies"] --> Mac["Hosted macOS / Xcode"]
  Mac --> Tests["Native compile + simulator integration"]
  Tests --> App["Release arm64 iPhone .app · no signing"]
  App --> IPA["Payload/Lokal.app → unsigned .ipa + checksum"]
  IPA --> Windows["Windows · Sideloadly or AltStore Classic"]
  Windows --> Sign["Installer's Apple account · local re-signing"]
  Sign --> Phone["iPhone · install and device acceptance"]
```

An unsigned IPA is an input to a signing/install tool; it cannot be installed by
tapping a download link. The iPhone build must use Flutter **release/AOT**, not a
debug build requiring a JIT/debugger. Simulator output is a different artifact
and cannot be packaged as an iPhone app.

Flutter's pinned `build_ios.dart` explicitly skips IPA export with
`--no-codesign`. For the later artifact job, use `flutter build ios --release
--no-codesign`, validate the resulting bundle, and package its actual `.app` under
`Payload/` using macOS `ditto` to preserve bundle metadata/symlinks. Do not assume
`flutter build ipa --no-codesign` produces the desired IPA. Build from a clean
output directory and fail if expected current outputs are absent.

Before publishing an artifact, inspect the main executable and embedded
frameworks using `file`, `lipo` and `otool` for correct device platform/slices and
dependencies; verify executable permissions, bundle identity, build number,
minimum iOS, icon, background-audio configuration and intended entitlements.
Supply SHA-256, source commit, toolchain versions, license notices and matching
source. Keep dSYMs for crash symbolication. This package inspection is separate
from a successful local signing/install test.

The locked FFmpeg plugin's `setup_ios.sh` creates its arm64 simulator variant by
retagging the device slice with `vtool`; its x86_64 simulator slice is separately
supplied. Therefore a simulator platform tag is not evidence of a genuine
simulator compilation for that dependency. The real FFmpeg conversion fixture
must pass, and a source-built simulator dependency should replace this workaround
if it causes runtime incompatibility. Do not apply this technique to other
native libraries as a substitute for correct target compilation.

Use Sideloadly on Windows as the first documented install route; AltStore Classic
is an alternative. Their documentation supports free Apple accounts. Free-account
installs generally expire after seven days and must be refreshed; Apple also
limits concurrently installed apps/App IDs. AltStore itself occupies an app slot.
Extensions can increase signing/capability complexity. Maintain a stable bundle
identity and signing account across updates to protect access to application
data/Keychain; verify the actual chosen tool's rewrite behavior.

The installer supplies their account directly to the chosen tool, never the
repository, CI or this chat. Device trust and Developer Mode may be required.
Avoid uninstalling the app as a routine refresh/update instruction; that can
delete imported music. Explain expiry, refresh and backup in user-facing install
documentation. A paid program is for a later TestFlight/App Store route, not a
prerequisite for this unsigned-artifact pipeline.

Sideload distribution preserves the existing GPL-3.0 and third-party attribution
requirements. App Store distribution is a separate decision: re-evaluate current
Apple review rules for downloadable add-ons/online services and GPL distribution
compatibility before treating it as a straightforward signing change.

## Phases and exit criteria

These are evidence-based gates, not calendar estimates. The complete feature
scope remains the destination; an engineering milestone is not a public release.

| Phase | Deliverable | Exit criteria |
| --- | --- | --- |
| 0 — Investigate | Source audit, architecture, capability matrix, baseline tests, native probe tools. | Concrete blockers and unknowns recorded; maintainer's Windows/sideloading/full-parity requirements incorporated. This document is the initial result. |
| 1 — Prove the build | Hosted Mac builds actual Rust for device and simulator; clean Flutter iOS runner links locked plugins, FFI and database. | Both native targets compile without raw USB; scanner and QuickJS execute in a simulator smoke test; no Android channel blocks startup. Pin observed Xcode/CocoaPods/native SDK versions. |
| 2 — Prove playback/storage | iOS session/media adapters, transaction-based import, native/system codec experiments. | Import -> scan -> play -> lock screen -> interrupt -> resume -> relaunch passes. Real iPhone tester recruited; sample-rate/route and unsupported codecs are measured. |
| 3 — Restore product parity | All ordinary features in the matrix: online services/add-ons, downloads, desktop link, lyrics/artwork, network libraries, share/export, presentation. | Each applicable row has contract tests plus simulator/device evidence. Each exception names the actual platform restriction or failed experiment, and receives a product decision. |
| 4 — Integrations/polish | Casting, widgets/icons, Discord feasibility, accessible iPhone UX, diagnostics, migration/update robustness. | Actual receiver/accessory tests where relevant; optional entitlement-dependent features cannot block base-app signing. No silent no-ops or Android-only settings. |
| 5 — Package and qualify | Versioned unsigned IPA, checksum/source/notices, Windows signing/refresh/update guide. | Cold install, second-build upgrade and refresh tested from Windows; release/AOT works without debugger; library preserved; no unresolved critical data-loss/playback issue. |

For feedback, show the first simulator recording after Phase 1, the playback/import
prototype after Phase 2, and a completed feature matrix before release
qualification. Consult the maintainer on concrete tradeoffs (e.g. widgets with
signing constraints or a service lacking a supported iOS SDK). Routine platform
adapter work does not require repeated approval.

## Validation strategy

| Layer | Tests and required evidence |
| --- | --- |
| Shared logic | Existing focused Flutter suites; queue/state transitions, source auth, add-on permissions, sync merge and import identity. Preserve Android behavior while introducing adapters. |
| Native compilation | Device `aarch64-apple-ios` and simulator `aarch64-apple-ios-sim`; later Intel simulator only if supported. Check features and binary slices. Compile success does not establish FFI linkage or runtime behavior. |
| Simulator integration | Cold start, actual Rust scanner/QuickJS calls, database reopen/migration, local fixture playback, denied permissions, import cancellation, queue/control transitions and accessibility semantics. No native mocks in the iOS smoke test. |
| Real iPhone | Screen-off/background playback; calls/Siri/alarms; Bluetooth connect/disconnect; USB-C/Lightning system output; route removal; media-services reset; large libraries; low storage; thermal/memory pressure; downloads/desktop transfers through suspension. |
| Installation | Windows sign/install, free-account entitlement compatibility, app launch without debugger, expiry/refresh, stable bundle identity, upgrade/re-sign keeping library and usable credentials, backup/restore. |
| Receivers/services | Real AirPlay/Chromecast/DLNA targets and opt-in live service checks; local fixture tests do not establish account/API availability. |

Build a licensed or generated fixture corpus: MP3 VBR/CBR, AAC/M4A, ALAC, FLAC,
WAV/AIFF, Ogg/Vorbis, Opus, WavPack, DSF/DFF-to-PCM, malformed/truncated files,
Unicode paths, artwork, tags and timed lyric sidecars. Include 44.1/48/96 kHz
cases, stereo/mono and gapless album transitions. Check audio progress/content,
not merely the UI's playing flag. Test network headers, MIME types and byte-range
behavior; iOS format/container matching can be stricter than Android's.

Establish performance budgets from the first real-device baseline: cold start,
time to first audio, import throughput, peak RSS, battery/thermal behavior and
frame-time percentiles. Target the device's refresh interval (16.7 ms at 60 Hz,
8.3 ms at 120 Hz), respect Reduce Motion and Dynamic Type, support VoiceOver,
use safe areas and accessible touch targets. Profile release/profile builds on
hardware. Simulator frame rates and battery readings are not device evidence.
Set a measured soak duration and acceptance threshold before qualification;
include long screen-off sessions and repeated route/interruption cycles.

### Tooling available in this change

Run from the repository root (Python 3.11+):

```text
python3 tool/ios_readiness.py
python3 tool/ios_readiness.py --json
python3 tool/ios_readiness.py --require-scaffold
```

The last command checks that the iOS scaffold exists; it is only a structural
gate, and currently passes. After `flutter pub get --enforce-lockfile`, the inventory also
lists the actual resolved iOS plugins and all discovered literal channel
callsites. JSON contains source-relative locations and no credential values.

On a Mac with Xcode, Rustup and Python 3.11+:

```text
bash tool/ios_native_probe.sh aarch64-apple-ios
bash tool/ios_native_probe.sh aarch64-apple-ios-sim
```

The `iOS native feasibility probe` Actions workflow runs both targets without
Apple credentials and has passed on the pull request.
GitHub requires the manual workflow to exist on the default branch before the
normal Run workflow UI is available. Public/private repository runner quotas and
costs follow the repository's Actions plan. This probe bypasses Cargokit to isolate
native-engine feasibility; it does not exercise the pod script, Flutter plugin
linkage, simulator runtime, or IPA packaging. Do not count a green probe as an
iPhone app build.

### Original baseline evidence

The following observations were recorded before implementation. They remain
historical evidence; the current validation ledger follows this section.

- Locked Flutter dependency resolution passed with Flutter 3.47.1 / Dart 3.13.1;
  `pubspec.lock` was preserved.
- Cargo manifest metadata resolved with Rust 1.98.0 and the existing lockfile;
  the manifest defaults to `native_audio` plus `uac2`.
- The locked iPhone dependency graph resolved with native audio and no default
  features; it includes Core Audio, Rust decoders and QuickJS and excludes
  `rusb`/`libusb1-sys`. This is dependency-resolution evidence, not compilation.
  It also resolved successfully with explicit `rquickjs/bindgen` enabled.
- 109 existing Flutter tests passed across engine failure recovery, notification
  state, scan sessions, player gestures/Reduce Motion, Spotify, Morneye add-ons
  and codec routing. An initial invocation also referenced a nonexistent
  external-playback test file; the corrected complete command passed.
- Scoped analysis of `main.dart`, audio-session manager, external playback,
  permissions and player found **11 existing informational lints**; it exited
  nonzero. No analyzer errors or warnings were reported in that scope. This is
  not a clean full-project analysis claim.
- The read-only inventory ran, found 44 literal channel callsites and correctly
  reported the absent runner. Python compilation, shell syntax and diff whitespace
  checks passed. Hosted native compilation remains unrun.
- This Linux host has no Xcode or iOS simulator. No iPhone was available. No IPA
  or iOS hardware behavior has been verified.

Re-run the focused baseline with:

```text
flutter test --no-pub test/services/player_service_engine_failure_test.dart test/services/player_service_notification_test.dart test/services/scan_session_controller_test.dart test/widgets/lokal/lokal_player_route_test.dart test/spotify test/morneye test/services/song_engine_routing_test.dart
flutter analyze --no-pub lib/main.dart lib/services/audio_session_manager.dart lib/services/external_playback_service.dart lib/services/permission_service.dart lib/services/player_service.dart
```

## Current validation ledger

- Build 20 passes the updated search scopes/four filters and root profile editor
  on iOS 18.6, with screenshots and exact-source metadata. An artwork-file test
  fixture inflated its raw scanner file count; creating artwork after the scan
  corrects the fixture without relaxing the assertion. Later playback/panel
  checks require the next native run.
- Build 21 fails the minimal Flutter control VM gate before Lokal runs. One
  bounded control-only fresh-device recovery is implemented for the next run;
  both attempts retain evidence, and application test failures are not retried.
- The post-#172 changed-file selections now pass 248 shared tests plus all five
  repaired decoder-recovery cases. A real host Rust/Isar persistence check also
  preserves song IDs and playlist references across rescans/retagging/database
  reopen. These host results do not prove native File Provider UI or app restart.
  See [the detailed review](IOS_POST172_REVIEW.md) for the evidence boundaries.


- Host Rust tests with the default native-audio/USB features: **303 passed**.
  No USB hardware test is inferred from that result.
- Both Android arm64 debug APKs (`full` and `play`) build with the iOS changes.
  The Kotlin plugin guard passes across 27 Android modules. The first local
  Android attempt inherited host Linux pkg-config paths; clearing those paths
  for the Android cross-build resolved the environment failure. No audio code
  change was needed.

- Full simulator and release iPhone builds passed on hosted macOS/Xcode 26.0.1.
  Engineering IPA inspection passed; its SHA-256 is published with the artifact.
- Both native Rust target probes passed with no `rusb`/`libusb1-sys` dependency.
- The latest metadata/audio/routing selection, including the real host bridge,
  passes **69 tests**. This overlaps earlier selections.
- Pitch/normalization/routing regression selection: **42 passed**. Scoped
  analysis reports the same 11 informational lints and no errors/warnings.
  The full Android debug APK also rebuilds after these processing changes.
- A selected shared regression run passed 158 tests; the later iOS storage,
  routing and processing regression run passed 63 tests. These counts overlap.
- Follow-up storage/routing/session tests passed 15 tests; download tests passed
  eight, including the iPhone app-owned fallback. The existing Cargokit helper
  checks passed for Android arm64/armv7, native linker failure and Rust pinning.
- iOS document adapter and shared playlist regressions passed 27 tests, including
  Unicode export, provider removal after import, stable-song matching, cancellation,
  oversized/malformed input, provider failure and scoped cleanup.
- Application/integration analysis has no errors; existing warnings/information
  remain. This is not a clean repository-wide lint claim.
- The broad Flutter run recorded 578 passes, two skips and 27 failures including
  a crossfade timeout. All 26 other failing test cases reproduced on the untouched
  audit baseline; the crossfade hang reproduced separately there too. The full
  suite remains red; this comparison does not turn baseline failures into passes.
- Native console identified the original abort: iOS 18.5 simulator cannot load
  `libswiftWebKit`, matching WebKit bug 293831. iOS 26.0 now runs the control app
  and actual Lokal welcome screen, with direct Dart VM readiness confirmed.
  The Android-only Cast/Bluetooth event subscriptions are now platform-gated.
  Build 17 passes the expanded native UI, Keychain, metadata, DSP, pitch,
  normalization, codec corpus and queue checks on both iOS 18.6 and 26.0.
  Matching crash symbols, native screenshots and measured JSON reports are saved. This is simulator execution
  evidence, not an audible-fidelity or physical-accessory measurement.
- Run 15 stopped at the independent minimal Flutter control app: its VM never
  became ready, its console remained empty, and simulator termination timed out.
  Lokal was not built or tested in that run. Saved control evidence is retained;
  run 16 then timed out in iOS 26.0 boot before any app was built.
  Both are simulator setup failures, not application-test results. CI now creates
  an isolated iPhone 16, tests iOS 18.6 first, and retains the iOS 26.0 gate.
  The release IPA is built before simulator setup, and boot identity/logs are
  preserved on failure. Three coordinator contract tests pass; these do not
  execute a simulator.
  Artifact names and provenance now include the run attempt so reruns cannot
  collide with earlier evidence.
- The smoke harness uses the supported Flutter drive existing-app adapter and
  probes the real loopback Dart VM directly, with native console capture and
  bounded timeouts. Its HTTP handshake was checked against a real local Dart VM;
  that check is not an iOS runtime pass.
- FFmpeg's 25,612,207-byte native archive matches the pinned GitHub release digest
  `63da3becdd2c7cefd77292054683e4f9b712efd09a4d8a8b2319d92f9fbcdd30`.
  CI verifies it before regenerating native dependency outputs; the archive-fetch
  and CI handoff were exercised in an isolated temporary package fixture.
- The credential-store regression selection records **83 passes and one known
  baseline failure** (`cover metadata reaches player track; quality goes to
  search/stream`, an existing HTTP request-order expectation). The secure settings
  persistence case passes; this is the same failure already reproduced on the
  untouched baseline, not a newly green full suite.
- No physical iPhone, Windows re-sign/install/update, background playback,
  Bluetooth/USB/AirPlay receiver, or live-account acceptance has occurred.

## Reference material checked

Checked 25 October 2026. External documentation describes platform possibilities;
the repository's locked versions and actual builds decide compatibility.

- [Flutter: build and release iOS](https://docs.flutter.dev/deployment/ios) — macOS/Xcode requirement and versioned iOS release process.
- [Pinned Flutter source: build_ios.dart](https://github.com/flutter/flutter/blob/6655482ec06e547f90abf8ae7590466f4415978d/packages/flutter_tools/lib/src/commands/build_ios.dart) — unsigned build skips IPA export.
- [GitHub hosted runner selection](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job) — hosted macOS and Apple Silicon runner options.
- [Sideloadly](https://sideloadly.io/) — Windows IPA signing/install support and free-account expiry.
- [AltStore Classic on Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) and [refresh/installed-app limits](https://faq.altstore.io/altstore-classic/your-altstore) — installation and seven-day refresh model.
- [Apple developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account) — account/program distinctions.
- [Apple: activating an audio session](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/ConfiguringanAudioSession/ConfiguringanAudioSession.html) — activation/refusal, interruption and background lifecycle. Archived reference; verify current API behavior on supported OS versions.
- [Apple: directory access](https://developer.apple.com/documentation/uikit/providing-access-to-directories) — document-picker directory access and scoped resource ownership; consult during the storage spike.
- [just_audio platform matrix](https://pub.dev/documentation/just_audio/latest/) — documented iOS capabilities and file/network requirements; validate locked 0.10.6 separately.
- [Flutter app extensions](https://docs.flutter.dev/platform-integration/ios/app-extensions) — extension lifecycle and shared-resource/App Group considerations.


Compatibility decision, 26 October 2026: the maintainer chose one full-featured
**iOS 16+** app rather than separate iOS 15/base and iOS 16/Cast distributions.
Runner/pod/native probe/compiler targets and the package gate follow that floor.
Earlier recorded engineering IPAs retain their original metadata and are not
retroactively described as iOS 16 builds.


### Build 24 native evidence (iOS 16 floor)

[Build 24](https://github.com/lokal-music/lokal-mobile/actions/runs/40273185020)
packages the new iOS 16 release and reaches the actual iOS 18.6 test app. Exact
merge source: `0fda1f5e314475639cde9ef26dc1ae8737c01270`.
Its incremental report passes post-172 search/profile UX, the corrected scanner,
QuickJS, WAV transport, repeated Queue/Lyrics panels and return to mini player,
**timed Space lyrics**, native EQ/pitch/positive ReplayGain, WavPack conversion,
the complete MP3/AAC/ALAC/96 kHz FLAC/AIFF/Vorbis/Opus corpus, the system-to-Rust
queue handoff, and Bonjour protocol filtering plus HTTP. Actual Space screenshots
show the expected current and next generated lyric at the retained song clock.

The run then fails at `nowPlayingMetadataState`: Runner Debug had C preprocessor
`DEBUG=1` but no Swift `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`, so the new
DEBUG-only metadata probe was excluded. Runner Debug now explicitly inherits and
sets Swift DEBUG; Release/Profile remain unaffected. No metadata assertion is
removed. Remote artwork and the subsequent Turkish switch still require the next
native run; iOS 26 was not reached. This is partial native evidence, not a fully
green run. The same logs expose repeated Android-only HomeWidget update calls on
iPhone; the Android publisher is now gated on iOS until a real WidgetKit snapshot
adapter exists, matching the already-gated settings UI.


Current upstream review extends through merged **#209 and #210**, main
`4504f64177e0826acacd7d06ab080718b947c3a4` (31 PRs after #172). Likes playback
revalidates expired stream sources while preserving identity. Space now overlays
the existing player artwork rather than opening a separate stage; the native
harness has been updated to check the retained artwork elements and actual song
clock. These assertions pass on both native runtimes in build 27. See the audit for focused test evidence.


### Build 26: Cast-integrated application and pause acknowledgement

[Build 26](https://github.com/lokal-music/lokal-mobile/actions/runs/40286173853)
compiles the Cast-integrated iOS 16 app, inspects all **34** device binaries and
requires Cast core resources, privacy metadata and notice bundles. Its preserved
IPA SHA-256 is `10cbfbbe68a851cca91529c842d6bc0d6c3152f0a61b21ea3fa39612b7de138d`.
Exact source is `9c230b90f80e9536dd08b6d794a6485b057c0c44`, tree
`c61258b7559dc23008008883dfa7e08d8d5fb959`.

**The complete iOS 18.6 native suite passes**, including the actual registered
Cast bridge with no startup discovery, remote HTTP artwork into native Now
Playing, live Turkish switching, the full playback/DSP/codec corpus, source
handoff, updated search/profile/panels and Bonjour. This source still contains
the older pre-#210 Space stage; the current overlay is a subsequent change.

The iOS 26 run passes startup/search/profile/Keychain, scanner/QuickJS, Space,
EQ/pitch/ReplayGain, WavPack, MP3/AAC/ALAC/96 kHz FLAC/AIFF/Vorbis, then fails its
Opus Pause assertion (UI remains playing after awaited Pause). Later checks are
not reached. This is an application transport race, not a simulator boot failure,
and the test assertion is retained.

The native pause API previously returned on command enqueue. The iPhone path now
waits up to two seconds for the command worker to apply pause; it releases the
global engine mutex before waiting so synchronous UI queries remain available.
The worker reply is bounded/non-blocking, and a timeout does not claim cancellation.
Android's existing Pause path and all PCM/DSD/USB rendering logic remain unchanged.
The iPhone Rust adapter suppresses stale playing/buffering notifications until a
new explicit Play; failed pause restores actual backend state. The native harness
also checks Rust's actual paused state and repeats Opus resume/pause.

All **307 Rust tests pass**, including real command-worker acknowledgement and
paused render silence, no-source completion, delayed reply and timeout behavior.
Three targeted Dart tests pass for stale events, explicit resume and failure.
The latest affected Dart selection passes **90** checks; the earlier broader
player/Likes/locale selection passes **123** (overlap). New iPhone-native results
remain pending the next source build. Google Cast's real context initialization
without automatic discovery is also added as a DEBUG-only acceptance check;
receiver behavior remains unqualified.


### Build 27: complete native checkpoint on both runtimes

[Build 27](https://github.com/lokal-music/lokal-mobile/actions/runs/40305306973)
passes the complete native suite on **iOS 18.6 and 26.0**, plus release/AOT
compilation and inspection of all **34** iPhone binaries, iOS 16 minimum, Cast
resources/privacy/notices, source and symbols. Exact tested merge source:
`659140532c300887de408a362377f6a6779916bb`; tree:
`ecaf093a021db35bf75bb66d521656f147dbb2bb`. The matching unsigned IPA SHA-256 is
`61fd97565f0b64168e3b16e347c7496cf0e28b84c5d15e017eabd935776faaf8`.

Both runtimes pass startup/Keychain, updated search/profile/panels, scanner/tag
album-artist, QuickJS, AVPlayer transport, native EQ/pitch/ReplayGain, WavPack,
MP3/AAC/ALAC/96 kHz FLAC/AIFF/Vorbis/Opus, system-to-Rust queue handoff, real
Bonjour filtering/HTTP, remote artwork into Now Playing and live Turkish switching.
The #210 Space screenshot and element-identity assertions confirm the existing
artwork survives entry while generated captions follow the actual song clock.
The suite also confirms an external-owner acknowledgement gates actual AVPlayer
resume, a newer manual Pause defeats a stale video-exit resume, real Cast context
initialization starts no discovery, and repeated Opus resume/pause reaches Rust's
actual paused state. The original pause failure is resolved without weakening
its assertion. Independent [Rust device/simulator probes](https://github.com/lokal-music/lokal-mobile/actions/runs/40305307004)
and [Cast SDK probe 4](https://github.com/lokal-music/lokal-mobile/actions/runs/40305307048)
also pass on this source.

These are simulator and package results, not physical iPhone, iOS 16 runtime,
actual Cast receiver or live YouTube acceptance. The subsequent unobstructed
embedded-video Space layout and HTTP range fixes require their own source build.
The preceding build-24/build-26 sections are historical checkpoints.


### Current continuation through #216

Main `63280241a5216ef987111eb8cd17c93e0626f1e4` is integrated, including all six
additional merged PRs #211–#216. Build 27 remains the validated checkpoint through
#210; the current source needs a fresh native run. The detailed audit records
Cover availability, Last.fm discovery, root video navigation, unshaded smooth and
concurrent Space lyrics, video quality and individual artist links. Android's
upstream USB registration/transfer-lifetime fix is preserved, excluded from iOS.

The iPhone uses the official embed's own quality control, with translated guidance
in Appearance. Native Android retains its 360p–4K/Auto selector. Space uses a
separate advancing clock signal for video, so its interpolation freezes during
buffering while transport can still represent a pending Play. Official player
controls and branding stay unobstructed; captions and explicit Exit Space sit
below the same live player.

The current host selection passes **114** UI/transport/locale tests, including
HTTP suffix/clamped/unsatisfiable/HEAD/empty-file behavior. A broader run also
reached the known historical ARB unused-key failure; no full-suite-green claim is
made. Analysis finds no errors; warning/info findings remain.

A manual workflow input, `live_video_probe`, opts into the public YouTube fixture
on both actual simulator WebKit runtimes. The probe uses production HTML and
channels and records readiness, advancing playback, pause/seek, same-State Space
entry/exit and native WebKit release. Network/provider restrictions are recorded
as **inconclusive** with a screenshot and provider code, never successful video
acceptance. Even an unavailable player must acknowledge native media suspension.
The ordinary deterministic corpus runs regardless; this probe is not physical
background/fullscreen/accessory acceptance.


The subsequent CI evidence improvement preserves each runtime's report/screenshots
immediately after its pass, as well as the combined diagnostics at the end. This
lets the first runtime's exact result be inspected while the second boots/tests;
it does not alter or relax either native gate.


### Build 29: current #216 source, real WebKit observations

[Build 29](https://github.com/lokal-music/lokal-mobile/actions/runs/40315993836)
packages the iOS 16+ app and passes the **complete iOS 18.6 native suite**, including
#215's two concurrent generated Space lines and the previous codec/DSP/queue,
Keychain, scanner, QuickJS, Cast initialization, external ownership, Bonjour,
remote-artwork and live-locale checks. Its Space screenshot now shows the smooth
unshaded concurrent presentation over the retained artwork.

Exact source: `f71f7501c5679188dbc99ee9776ea6d0da70d83d`; tree:
`fbab3adcabefc1806e4c9f2ed6ee777666ea9042`. The preserved unsigned IPA passes
inspection of all 34 device binaries and Cast resources/notices; SHA-256:
`d715ad0a46c4efebc82a5f946bd38004fdb966ff7e9ae64bfaa1cc5467294d07`.

The opt-in production WebKit probe reads the actual installed `app.lokal.mobile`
identity and observes real iframe API readiness. YouTube then returns error 150;
the screenshot explicitly shows **"Sign in to confirm you're not a bot"**. Position
advance is zero. The real native WebKit media-suspension acknowledgement succeeds.
The report correctly marks playback **inconclusive**; neither successful live
playback/seek nor a generic embedding prohibition is inferred from the error code.
The challenge is not bypassed, and no account credentials are introduced into CI.

The overall workflow fails because the **iOS 26 simulator does not boot**:
`simctl bootstatus` times out after 300 seconds and even the simulator screenshot
fails. Lokal never executes on that runtime. This is not a current iOS 26 app
pass; build 27 remains the last complete dual-runtime checkpoint. A fresh hosted
runner must retry the current source without weakening its native gate.

The later Library-label/raw-video-sample follow-ups have their own host checks and
await a new native source build. This checkpoint does not cover those later changes.


### Add-on continuation through #217

Main `ba8c7f5b9e6ab4e004f106ec1c02231143fb1d5b` is carried forward, bringing the
review to **38** merged PRs after #172. Documented `.spotiflac-ext` packages now
pass the shared import picker and URL install path, alongside `.sflx` and
`.morneye-ext`; archive/manifest/permission and SHA-256 protections are retained.
Only isolated download workers receive the host-selected 256 MiB maximum heap;
browsing/startup retain 64 MiB, with the native host clamping configuration.
These are ceilings, not an allocation of 256 MiB at worker startup. Physical
oldest-phone peak-memory and third-party search/auth/download/persistence remain
acceptance work. Metadata-only and lyrics-only extensions are not represented as
working audio sources.

The package/panel selection passes **42** Flutter tests. All **308** host Rust
tests pass, including the eight real QuickJS cases and the new heap-bound test.
No FRB entrypoint/signature changed. The previous build-29 checkpoint is through
#216 and does not cover #217; the updated source needs its fresh native run.


### Build 32 and isolated current-runtime acceptance

[Build 32](https://github.com/lokal-music/lokal-mobile/actions/runs/40321960451)
passes the complete iOS 18.6 suite on the current source through #217, including
the six translated Library shortcut assertions and concurrent Space. Exact source:
`c2ad2f0bbcc8bfda32cb0e650647b8cfd72a77f5`; tree:
`aa72e2cbfcd0ee87020577637f93027365bdd44e`. The preserved iOS 16+ engineering IPA
SHA-256 is `6dda95cf443741d9d147a940f92bb0de2b35aa77fd858ca483cc77eed3589f2d`.

The raw-source video probe reaches the real iframe API and acknowledges native
WebKit suspension, but the hosted network again receives YouTube's sign-in/bot
challenge (150) with zero source-position advance. Playback remains inconclusive.
The iOS 26 simulator again fails to boot before any app test; the run is not a
complete dual-runtime pass.

The following CI change runs iOS 26 on a **fresh hosted Mac**, using the exact
already-compiled integration app from the iOS 18.6 build job. An archive preserves
bundle symlinks and executable modes; the receiving job downloads its exact
artifact ID and safely extracts it. Both OS gates stay required. A failing iOS
18.6 assertion does not suppress the second runtime when the compiled app exists;
cancelling a workflow does suppress extra jobs. Failed iOS 26 jobs can now be
retried without recompiling the IPA or rerunning the completed iOS 18.6 job.

The iOS 26 host also runs the minimal Flutter control before Lokal. Boot, control,
actual playback, reports and logs are recorded independently. No app assertion,
OS-version requirement or simulator boot check is relaxed. Driver timeouts now
match the selected four-minute deterministic/six-minute optional-video test bounds.
The updated workflow passes YAML/shell parsing and all nine existing simulator/
control-coordinator tests; the changed Dart driver analyzes without issues.

```mermaid
flowchart LR
  Build[Compile release and simulator app once] --> IPA[Unsigned IPA / source / symbols]
  Build --> Old[Native suite on iOS 18.6]
  Build --> Bundle[Compiled integration app archive]
  Bundle --> Fresh[Fresh hosted Mac]
  Fresh --> Boot[Required iOS 26 boot and minimal Flutter control]
  Boot --> Current[Same app / same native acceptance suite]
  Old --> Evidence[Separate reports / screenshots / outcomes]
  Current --> Evidence
```

The compiled app's Bonjour fixture identity is also forwarded to the isolated
host, so retrying only that job does not change the identity baked into the app.
A screenshot-driven Library follow-up allows two-line shortcut labels and switches
to one column as text grows. All six Turkish labels fit the bundled app font at
200% on 320/393/430px screens; navigation/import and component/dock selection
passes **18** host tests. The native harness now checks rendered labels for actual
truncation; that added assertion still requires the next hosted run.
