# Konnekted2 feature parity

This is the implementation ledger for the Flutter fusion. A feature is marked
**delivered** only when it has a real code path and a focused automated check.
"Inherited" means the Flick implementation is present in this repository; it
does not mean a USB DAC or every Android OEM has been tested here.

The iPhone port is **implemented in part, not runtime-qualified**. Hosted builds
produce a simulator app and unsigned release/AOT IPA; both native Rust targets
compile. The actual Lokal app shell renders on iOS 26.0 and 18.6, and the integration
driver attaches. Android-only event subscriptions are gated; native scanner, QuickJS, WAV
play/pause/seek, Rust DSP and WavPack conversion/playback pass on iOS 26.0 and 18.6. Storage,
media/session adapters, ordinary DSP/codec routing, Files playlist/recap exports,
Spotify session bridge and platform settings are implemented. No physical iPhone
installation or hardware behavior is validated.

See the [iOS architecture and evidence ledger](IOS_PORT.md) and
[Windows sideloading guide](IOS_SIDELOADING.md). The tables below describe the
existing Android/shared implementation, and do not establish iOS support.

## Konnekted / `flow-feature`

| Area | Status | Evidence / boundary |
| --- | --- | --- |
| Flow unlock at 16 favorites | Delivered | `lib/features/flow/domain/`, `test/flow/` |
| Flow mood pills and tuner | Delivered | Draft-until-Apply tuner, genre exclusion and discovery/memory axes |
| Persistent Flow session, bans and refresh | Delivered | Versioned store; partial/corrupt data is handled explicitly |
| Flow save as a local playlist | Delivered | Uses inherited `PlaylistService`, not a second playlist database |
| Local songs, albums, artists, folders | Inherited | Flick screens, Isar repository and scanner |
| Favorites and recent history | Inherited / shell integrated | Real providers feed Listen and Library |
| Local playlist creation, editing, M3U import/export | Inherited | `PlaylistService` and playlist screens |
| Playlist links and refresh | Delivered | Spotify public embed and YouTube Music browse; preview, partial safety, matching, refresh, unlink |
| Spotify OAuth and library | Delivered | PKCE, secure tokens, paginated Web API, playlist import, bounded retry |
| Spotify Liked Songs → local likes | Delivered | Explicit one-way sync, strict title/artist/duration matching, readback verification |
| YouTube Music catalog search | Delivered | Explicit guest catalog search; opens canonical source page |
| Authorized addon search/playback | Delivered | Opt-in HTTPS manifest/search/stream subset; bounded staging and native probe |
| Ordered multi-addon source registry | Delivered | Up to eight named sources; secure v1 migration; draft-only edit/reorder/enable/remove; source-bound credentials and stale-row refusal; `test/discovery/` |
| YouTube Music account sign-in/personalized shelves | Delivered | Opt-in in-app WebView session import, secure session storage, account shelves and local/add-on playback matching |
| Listen Together / jam invite links | Not yet ported | Requires a listener-owned realtime coordination service and lifecycle design; no fake local-only “sync” control is exposed |
| Classipod click-wheel shell and Cover Flow | Delivered local-library slice | Library entry; accessible wheel, songs/albums/artists, real shared playback/queue, Cover Flow-like artwork; 20 host tests; broader Kotlin/provider parity not claimed |
| Spotify/Tidal/Apple/community animated canvas providers | Partial | Flick animated artwork/theming is inherited; the full Konnekted provider precedence and canvas cache are not yet ported |
| JioSaavn / Octave / FLAC-downloader source resolver modules | Partial | Ordered listener-owned addon registry is implemented; provider adapters, cross-source matching and quality fallback graph remain unported |
| Subsonic / Jellyfin / WebDAV / SMB / UPnP | Inherited | Existing Flick network-source services and settings |
| Tidal device flow/source | Inherited | Existing Flick Tidal service; account/source behavior remains opt-in |
| Last.fm / ListenBrainz | Inherited | Existing scrobble providers and background queue flush |
| Discord Rich Presence | Inherited | Existing integration service; metadata uses actual player diagnostics |
| Chromecast / DLNA / UPnP casting | Inherited | Existing Android/native and Dart cast paths |
| Widgets and media notification | Inherited / shell preserved | Runtime mounts widget sync, intents and foreground playback |
| Lyrics search, synced words, translation/editor | Inherited | Existing lyric providers and player screens |
| Animated artwork, dynamic theming, recaps, stats | Inherited | Existing services/screens; not removed by the new shell |
| Automix, crossfade, gapless, skip silence, sleep timer | Inherited | Existing PlayerService/native audio path |
| Quality ceilings, downloads and offline cache | Inherited | Existing quality/download services; online discovery is separate and honest about limits |

## Flick audio and library architecture

| Capability | Status |
| --- | --- |
| Rust engine via `flutter_rust_bridge` | Inherited and build-wired |
| Symphonia decoding and metadata probing | Inherited |
| USB UAC 2.0 direct output | Inherited; requires physical DAC validation |
| Native DSD and DoP paths | Inherited; requires physical DAC validation |
| DAP hi-res Oboe/AAudio exclusive output | Inherited; requires target-DAP validation |
| DSP: 31-band EQ, dynamics, convolution, crossfade/gapless | Inherited; DSP is intentionally not bit-perfect |
| Bit-perfect safeguards | Inherited and preserved | Protected volume tiers and output diagnostics prevent unsupported software gain on wire DSD/passthrough |
| MediaStore/SAF and full-storage flavor | Inherited and build-wired | `play` omits All Files Access; `full` includes it |
| Metadata editing, CUE/EAC, duplicate detection, artwork | Inherited |

## Required Flick baseline

These are the capabilities that must remain part of the Konnekted product
baseline. The status describes source-backed behavior; **hardware-unverified**
does not mean a USB DAC, Bluetooth codec, receiver, or background route has
passed on a physical phone.

| Capability | Status | Boundary |
| --- | --- | --- |
| Preload library analysis/cache | Delivered | Caches waveform/loudness/artwork analysis; it is not a decoded playback-buffer cache |
| ReplayGain | Delivered | Local PCM tag/analysis paths; DSD/DFF/WavPack and network-source scans need separate validation |
| Remove duplicates | Partial | Groups by normalized title/artist and removes library rows; it does not delete files or fingerprint audio |
| Scanning settings | Delivered | Filters, deep scan, M3U import, and preload preference are persisted and routed through Android scan engines |
| Preload audio data after scanning | Delivered | The setting now schedules the shared preload pass for Rust, MediaStore, and SAF scan paths; `content://` and unsupported formats remain explicit skips |
| Network sources / remote libraries | Delivered | Subsonic, Jellyfin, WebDAV, SMB, UPnP, and Tidal source paths are opt-in; live server coverage remains device/integration work |
| Gapless playback | Partial | Same-rate buffered paths work; bit-perfect, raw-DSD, and incompatible-rate transitions intentionally renegotiate |
| Background playback anchor | Partial | Wired/speaker route pinning exists; Bluetooth and OEM background-kill behavior require device validation |
| Motion art during bit-perfect playback | Partial / opt-in | Suppressed by default to protect direct output; the opt-in path requires USB/DAP validation |
| USB audio UAC2 | Hardware-unverified | Native discovery, negotiation, stream, volume, and recovery paths exist; requires a real UAC2 DAC |
| Bluetooth Hi-Res direct | Partial / hardware-unverified | Engine and codec preference paths exist, but OEM codec negotiation is not guaranteed by the app |
| Bluetooth low latency | Partial / hardware-unverified | Preference/routing path exists; measured latency and dropout targets are not yet proven |
| Casting | Partial / hardware-unverified | Chromecast/DLNA discovery, transport, and controls exist; real receiver queue/disconnect behavior remains to test |
| Two-way remote with Lokal | Delivered | Authenticated HTTP LAN state polling and commands, secure credentials, reconnect backoff and stale-state suppression; mDNS pairing and stronger multi-client revisions remain outside this slice |

## Explicit non-claims

- Spotify metadata is not Spotify audio. Imported playlist entries must match
  local files before they can play.
- YouTube catalog results are not stream extraction. The app opens YouTube
  Music externally unless the user configures an authorized addon.
- A source's word “lossless”, sample rate or bit depth is never accepted as
  proof. The local/native probe and the selected output route decide what is
  verified.
- Automated checks use fake transports and controller seams. They do not prove
  native output on a specific phone, DAC, DAP, Android version or USB cable.

## Remaining work for full parity

Remaining gaps include unported product features and real-device validation:

1. Extend the Lokal remote with mDNS pairing and stronger multi-client
   revision/acknowledgement semantics.
2. Harden duplicate removal with duration/content identity checks and an
   explicit library-only versus filesystem-delete choice.
3. Validate preload cache hits through MediaStore/SAF, including removable
   storage and unsupported-format behavior.
4. Port the remaining source-backed features above: Listen Together, provider
   canvas precedence, and the Konnekted source registry/fallback graph.
5. Update inherited localization/tutorial copy from Flick to Konnekted.
6. Run the Spotify OAuth flow with a registered Spotify developer app and an
   authorized account.
7. Run linked-playlist refresh against real public Spotify/YouTube playlists;
   both providers can change undocumented web response shapes.
8. Validate each native output mode on real USB DACs and DAPs, including volume
   rejection, DoP/native DSD, route changes, Bluetooth codecs/latency,
   background playback and widgets.
9. Add design assets and a release signing configuration outside the repository;
   signing material must never be committed.

### Discord Rich Presence

Android integration adapted from Mornye’s official Social SDK bridge is prepared, opt-in under Data → Accounts. Lokal application ID is configured; the verified SDK is encrypted in the repository and staged by signed build workflows using an Actions secret. SDK-enabled native bridge is packaged for arm64-v8a only. APK/device behavior is not yet validated. See [setup and limitations](DISCORD_PRESENCE.md).

## Mobile library and player follow-up (2026-10-21)

Implemented, pending Android device validation:

- Explicit library jobs for videos, album releases and artist metadata, with global
  progress messages and cancellation between requests. New artists also queue a
  bounded, serial portrait lookup through the existing Apple metadata cache.
- Local recordings take precedence over matching desktop placeholders in visible
  library/search results; storage, files and existing playlist references remain.
- Lyrics settings order/enable LRCLIB, BiniLyrics, BetterLyrics, BetterLyrics
  Portato, LyricsPlus, Unison, KuGou and lyrics.ovh. Both full player variants can
  choose a source. TTML word timestamps are parsed. These public provider adapters
  have not all been live-validated; Spicy Lyrics is not implemented.
- Online queue lookup inactivity has a cancellation watchdog. This does not
  establish the cause of the reported device playback stall. Xiaomi cleanup and
  force-stop records are classified as platform events rather than crashes.
- Exact theme launcher resources, deferred idle/background icon application,
  compact settings, quality badges beside artist labels and vertical recent-song
  search covers. Existing explicitly saved performance preferences are preserved.
- Visualizer screens/renderers, mini-player actions and Android capture bridge
  are removed. Legacy serialized preference fields remain compatible.

Focused launcher resource tests and Dart analysis validate source changes;
launcher lifecycle behavior, online providers and hardware playback still need
validation in the installed Android app. Native PCM/DSD/UAC2 paths are unchanged.

## Playback, metadata and sync repair follow-up (2026-10-21)

Implemented; Android profiling/device validation remains outstanding:

- Full-player backdrop paints artwork palette gradients directly, with no artwork
  blur pass or duplicate background image. Performance mode stops continuous
  drift; route/interactive-pull handling pauses decoration and reuses a repaint
  boundary. This removes known rendering work; no measured FPS claim is made.
- Shared lyric sweep/lift/held-note renderer follows desktop timing. Mobile uses
  actual word timestamps and leaves line-synced sources line-synced. LRCLIB adds
  cleaned-title and duration-constrained search fallback; enabled providers start
  concurrently and results retain priority, with plain lyrics last. This is not
  full desktop parity for all duet/background/TTML document features.
- Lyrics Studio is removed; picker import remains. On-demand translate/romanize
  icons use desktop's public Google batch protocol, cache exact text/language,
  preserve timings/source selection, and ignore stale responses. Source-provided
  translations take precedence. Live endpoint availability is not guaranteed.
- Local metadata repair reads audio headers through existing Rust parsers, stores
  sample rate/bit depth/kbps/actual codec, fills missing file genres, and repairs
  already-copied desktop files during sync without re-downloading. One bounded
  worker performs the initial repair; inaccessible files need their folder grant.
  No new database schema or hardware audio route is introduced.
- Rust-to-Android metadata fallback converts Lofty's kbps to retriever bps before
  existing storage conversion, and retries missing lossless depth/bitrate.
  Unknown quality displays Not read instead of guessing Lossless from extension.
- Desktop history never imports library placeholders. A catalogue reconciliation
  archives old non-owned remote rows without deleting downloaded files, playlist
  references or journal events. Sync counters count the owned catalogue only.
- Milestone hours add other devices' uniquely keyed events to the local live
  counter, excluding this device to avoid double counting. Unique artists include
  journal history even for streamed-only tracks. Reached/lower tiers no longer
  depend on individual popup acknowledgements.
- Log-driven fixes cover Cover Flow teardown ancestor access, add-on HTTP pool
  closing, Android preparation timeouts and a crossfade resume future that could
  hold the playback command queue. The ANR trace does not by itself prove a
  single root cause; native hardware paths remain unchanged.


## Lyrics motion, paired lyrics and failed-source recovery (2026-10-21)

Implemented; Android device confirmation remains outstanding:

- One cover and title move between full artwork, the queue header and a compact
  row beneath lyrics. Queue/lyrics switches retain compact artwork and both
  scroll positions. The header/options collapse and transport buttons shorten
  on the same lyric progress. Play/pause morphs continuously, with press feedback
  and animated button widths. Hidden panel tickers are disabled; measured lyric
  paragraphs are reused when only the viewport height changes.
- Manual lyric search follows desktop's title/artist → Search → tap-result flow.
  It remembers the last edits/results for up to 20 songs in memory, drops stale
  answers and reports search/save failures. No exact-match banner, filters,
  preview or second confirmation is required. Explicit search bypasses cached
  misses. Seek drag state is held until handoff.
- Timed lyrics are shaped and measured as one TextPainter paragraph, including
  CJK wrapping, text scaling and RTL runs. Word sweep/lift and held notes reuse
  cached paragraph geometry. This does not add desktop's full duet/bg-word model.
- Bini matching follows desktop's title/artist/duration/timing scoring rather
  than exact artist strings. Fresh source preferences prioritize syllable lyrics;
  existing custom order and timing preference remain. Manual selections remain
  authoritative. TTML supports bare-second timestamps and language metadata.
- The player source bottom sheet shows the current timing type, source
  capabilities and refresh search; refresh retries cached LRCLIB misses.
  Translation/romanization sublines animate without remounting the lyric view.
  Translation rejects known/detected matches to the system language.
- The paired desktop endpoint exports existing cache/sidecar lyrics without
  online requests. Mobile copies normalized words/timestamps/language, retains
  better cached timing and repairs already copied songs on the next merge.
  This requires the companion desktop update; older desktops still copy audio.
- Home wheel opens Playback; You wheel opens Data with Accounts first.
  You → More has dedicated Online sources and About rows. Cover Flow fills newly available mixes rather
  than freezing the first partial set, keeping valid picks stable.
- The supplied log ends in two Android Source errors for Tearz. Failed prepares,
  async source errors and seek failures invalidate source/playlist/resume reuse.
  Resume reloads rejected sources, seeks have a bounded wait and failures reach
  the user. Redundant crossfade cleanup seeks are removed. The log does not
  identify the underlying file/network failure; no claim of a reproduced Xiaomi
  hardware fix is made.

Validation: focused Dart lyric/parser/matching/layout/mix and failed-source tests,
Dart analysis (no errors), and desktop export/quality tests. No APK or CI build
was run for this follow-up. Public-provider availability and device frame pacing
remain unverified.

## Moving covers, accounts and source readiness (2026-10-22)

Implemented in source; authenticated/device confirmation remains outstanding:

- Both player styles use moving artwork. Added direct Apple editorial video,
  Tidal video covers, the desktop community list, m8tec and Spotify Canvas
  (Pathfinder with protobuf fallback). Added providers are opt-in in Appearance;
  Apple remains the existing default. Spotify priority is configurable. Per-song
  disables persist by normalized artist/title and apply to saved/local copies.
  Lookups are deduplicated with bounded caches; HLS chooses a modest AVC rendition
  when available. Decoders pause offscreen/in the background/compact lyrics row,
  and motion stays suppressed for exclusive/bit-perfect output.
- Home computes desktop's paired headline/subheader rules, including the latest
  eight-play repeat window. Flow track circles show artwork.
- Installed, enabled playable add-ons stay visible in Search and source priority
  when verification expires. Selecting one opens verification; automatic lookup
  skips it until renewed. Source ordering is retained. Search and pending playback
  publish a single updating progress message.
- Amazon's validated `ffmpeg.mov_key` descriptor follows desktop's decrypt → probe
  flow. Only 32-digit hexadecimal keys and allowed output containers are accepted;
  supplied-key processing is cancellable and bounded. Tests exercise the descriptor
  and output validation through an injected decryptor; Android FFmpeg was not run.
- Data shows saved-cookie state, update/remove actions and an opt-in Spotify likes
  sync toggle; the redundant Spotify library connection page is removed. Discovery
  uses desktop Pathfinder Home mixes/playlist tracks/liked songs rather than
  OAuth-only REST shelves. Like sync adds strict matches to local Favorites and
  retains its cursor; it does not download files or add streamed-only placeholders.
  Pathfinder/Canvas fixtures pass, but no real account was used here.
- Discord retains its SDK session across track loading, updates track changes
  promptly and resolves public artwork for local covers. No local artwork is
  uploaded and LAN/private/signed image URLs are rejected. Method-channel tests
  cover next/previous, loading and public-art updates; live Discord rendering
  remains an Android check.

Validation: 131 focused Dart/widget tests passed, with no Dart analysis errors.
No APK/CI build was run. Provider credentials, Android FFmpeg decoding, device
frame pacing and live Discord rendering remain device/account checks.

## Mobile 1.0 release channels and presentation (2026-10-22)

- Prepared pubspec 1.0.0 and independent manual stable/nightly entry points.
  Merge-triggered beta publication is removed. Stable defaults to a draft;
  published stable builds are latest, nightlies are prereleases. Both reuse the
  permanent signing identity and one serialized time-based versionCode clock.
- Shared signed builds reuse toolchain/Cargo caches and retain signature, APK
  package/version/ABI/native-library/notices/checksum verification. No duplicate
  debug-build/test workflow is called by the release workflow.
- Mobile banners are generated from checked-in branding/fonts with teal stable
  and coral nightly palettes; immutable banner URLs work in draft previews.
  README Home/Library images render actual widgets with fictional local fixtures.
- Validation: 30 release-helper tests, actionlint on all three release workflows,
  local banner rendering and README widget renders pass. No APK/Actions build,
  version tag, public release or secret changes were performed for this PR.
  The first intentional workflow run still validates hosted signing/publication.


### Copy lifetime and account/release follow-up (October 2026)

- Explicit phone/desktop file copies now request a separate Android `dataSync`
  foreground service before sending bytes. Its notification reports progress;
  timed CPU and Wi-Fi locks release on completion, failure, task removal or stale
  progress. Launcher icon changes defer during copies. This supports Home/app
  switching and screen locking, not force-stop or a persistent queue after process
  death. Retry rechecks both catalogues to skip completed files.
- Mobile preserves the desktop receiver's bounded HTTP 400 reason and rejects
  empty files locally. Streaming checks cover exact original bytes, content length,
  Unicode metadata and SHA-256. The reported device-specific 400 has not been
  reproduced: its underlying server reason is needed; this is not a claim that
  every desktop rejection is fixed.
- Spotify session harvesting attaches its temporary WebView behind Flutter,
  removes a conflicting host-only cookie before installing the replacement, and
  resolves the JS bridge at report time. Specific native session/network errors
  reach the account UI rather than a blanket invalid-cookie message.
- Onboarding uses the canonical YouTube Music sign-in tile directly; Last.fm
  opens Data › Accounts instead of the removed Online sources account section.
- Stable releases offer patch/minor/major or exact versions and explicit existing
  release replacement, including 1.0.0 with a newer Android versionCode.

Validation: focused Flutter tests, release metadata tests, the exact JS hook
fixture and actionlint. No APK/CI build, native compilation, live Spotify login,
physical background-transfer test or actual release replacement was performed.


### Missing-file preview identity follow-up

Copy previews use a copied song's original desktop identity scoped to the paired
server, and fresh metadata for independently scanned songs, rather than cached
journal keys. If the bulk resolver still reports missing, matching catalogue
candidates are verified via the paired-original HEAD route (no audio body). A
missing original stays eligible; auth/network failures abort verification rather
than classifying files as absent. The same retained IDs prevent downloading
already-present phone copies after tag edits. Journal aliases for history/likes
remain intact. Focused identity, HEAD status and upload tests pass; no physical
PC/phone transfer or APK build was performed.


### Lyrics return gestures and Artist/Album saves

The lyrics thumbnail returns to the full player on tap or upward swipe using
its existing artwork/layout transition. Its hit target stays on the compact
cover so lyric scrolling remains independent; queue tap/downward drag behavior
is retained. Permanent online saves and desktop-to-phone copies now use the
selected root / Album Artist (or Artist) / Album hierarchy. Missing tags use
Unknown Artist / Unknown Album. Folder segments are sanitized individually;
SAF desktop copies create each nested directory under the saved grant. Stored
relative paths reflect the hierarchy. Existing shared-storage files are not
moved by this update; new saves and explicit private-copy recovery use it.

Focused filesystem/SAF bridge fixtures, folder-name safety checks and widget
checks cover tap/up/down gestures, stable single artwork and retained scroll.
No APK build, native compilation or physical Android SAF/gesture test was run.

### Amazon empty-container descriptor compatibility

Amazon add-on 2.3.14 returns empty `output_extension` fields for FLAC, meaning
use the host default, and an empty `decryption_key` for clear audio. Mobile now
uses the first nonblank declared extension or `.flac`, matching desktop's
fallback semantics, and does not synthesize a decryption request for an empty
key. Extensions are normalized but still checked against the fixed audio
container allowlist; key/strategy validation remains in place.

The 39 package-manager tests pass, including the observed Amazon descriptor
shape, descriptor fallback, normalized extensions, clear audio and rejected path
injection. Targeted Dart analysis has no errors/warnings. The fixture injects the
decryptor; no live Amazon stream, physical Android playback or APK build was run.


### Existing-library organizer and Spotify cookie entry

Library settings › Maintenance now contains **Organize existing library**. It
previews relocations beneath each selected root as Album Artist (or Artist) /
Album, requires an explicit confirmation, avoids overwriting collisions, and
updates existing Isar row IDs and queued file locations. A foreground progress
notification protects the job during app switching. A durable one-file journal
recovers a rename interrupted before database commit; failed commits roll the
rename back. The current loaded song, CUE audio, document-only/inaccessible files
and files outside saved roots are skipped. Existing artwork/lyrics sidecars are
left in place. Scoped-storage fallback uses the persisted ExternalStorage tree
move grant where the destination keeps its filename; unsupported permission or
collision cases are reported for retry, without copying/deleting originals.

Spotify cookie login no longer requires public Web API `/v1/me` acceptance for
a first-party WebPlayer bearer. It still requires real browser-captured access
and client tokens and rejects explicitly anonymous responses. Failed connection
attempts keep the entered cookie in the obscured dialog for retry; cancelling
invalidates the attempt. This does not prove a live Spotify account/device test.

Validation: focused organizer filesystem/journal/rollback/collision/skip tests,
cookie-dialog retry/cancel tests, session migration and copy-notification tests
pass. Targeted Dart analysis has no errors/warnings. No APK/CI build, native
compilation, physical Android move/grant test or live Spotify login was run.

### Discovery provider stability and YouTube mix continuations

Spotify selection no longer falls through the shared Discovery loader's Last.fm
branch: Spotify shelves remain owned by their separate provider, and selection
survives refresh, restoration and an older in-flight Last.fm response.

YouTube personal-mix parsing now recognizes playlist navigation on artwork play
buttons and responsive title runs. Named/personal mix shelves expand their own
continuations even when the response omits its original header; command-executor
continuations are recognized. More-page continuations preserve their browse
parameters. Expansion is bounded and independent shelf requests run in parallel.
Ordinary song-radio shortcuts are not relabeled as personal playlist cards.

Validation: 14 focused provider-state, account/parser and fetch-fixture tests
pass. Targeted Dart analysis has no errors/warnings. No APK/CI build or live
Spotify/YouTube account request was run; actual returned personal mixes still
require account/device verification.

### Library location/quality filters, folders and desktop copy integrity

Shared library song lists now combine a location filter (All, Mobile, PC, other
sources) with one grouped quality/format menu. Format entries come from known
bit-depth/sample-rate pairs; search, sort, Play and Shuffle use the filtered
list. Unknown audio details remain distinct. Desktop's spectral `Suspect` tier
is not offered because mobile has no stored spectrum verdict.

Both folders views and sorting sheets use solid Lokal surfaces and common
headers, retaining grid/tree, folder grouping, sorting and playback behavior.

Desktop catalogue imports resolve preserved PC identities before metadata
matching, keeping copied/organized local originals local. Successful uploads
retain the receiver's track ID. A capable desktop advertises content matching:
metadata misses get a size/SHA-256 comparison before upload, with original IDs
retained and excluded from the reverse download preview. Older desktops keep
the existing ID/metadata checks; the exact-content fallback requires the paired
desktop update. No songs are deleted or reorganized by these checks.

Validation: 28 focused Dart tests pass (including filter menu interactions,
file fingerprints, uploads, identity and organizer/folder regressions). Targeted
analysis has no errors/warnings; existing style infos remain. No APK/CI build,
physical phone transfer, live account or launcher test was run.

### Bounded missing-file preview

Missing-file checking now reports its current stage and counts, offers Cancel
check, and has a 90-second overall limit. Cancel/timeout invalidate late work
before further progress is published. Catalogue pages fetch up to 500 rows;
reverse-copy matching uses an ID index instead of rescanning the whole song list
for each desktop track. A capable desktop provides a size preflight, so phone
files without any same-size PC candidate are not read in full for SHA-256.
Exact-content comparison remains required before treating a candidate as a copy;
a shared size alone never hides a missing song. Older desktop versions retain
the previous comparison path within the same cancellation/time bounds.

Focused guard cancellation/timeout, fingerprint and identity tests pass. No APK
build or physical large-library/background-storage test was run.

### Discovery artwork, YouTube refresh and player output action

Discovery uses cached library artist portraits and can fall back to the existing
Apple Music artist portrait service when Deezer has no matching picture. It no
longer substitutes an album cover for an artist portrait. Track artwork accepts
same-recording remaster/featured-credit differences while keeping remixes/live
versions distinct. These lookups change images only, not recommended recordings.

Selecting/reselecting a Discovery source forces refresh. YouTube refresh clears
playlist cache entries, refreshes browser client/visitor context, reads personal
mix cards from the signed-in page's initial home data as well as API shelves,
and does not cache incomplete/missing-mix responses for five minutes. Independent
mix expansion runs concurrently. Account fetching and optional playlist picks
have time bounds. Fixtures cover current page context/embedded mixes and repeat
refresh; real account-specific mixes still need device verification.

The player output popup's previous device row only dismissed the dialog. Its
Choose output action now opens Android's system media output chooser (API 34+),
with inline failure feedback. USB/DSD engines are unchanged. Older Android
versions direct users to Quick Settings; no physical route-switch or native APK
build has been validated. Routine provider searches use inline loading without
searching-source snackbars; selected-song preparation/download feedback remains.

Validation: 24 focused discovery artwork/account/parser/source tests and 10 copy
preview guard/fingerprint/identity tests pass. Targeted Dart analysis has no
errors/warnings. Android API availability was checked against the SDK; native
compilation, live source accounts and physical audio routing remain unverified.

### Motion artwork in the minimized player

The dock thumbnail now uses the same moving-cover/Canvas settings and per-song
opt-out as full player. Both views share a muted looping decoder keyed by song
and clip URL, retaining its playback position across the minimize/open handoff.
One hidden view cannot pause another active view. App backgrounding pauses
motion, and exclusive-output suppression releases it immediately when unused.
Reduced-motion/settings fallbacks remain static.

Validation: 26 focused shared-playback, motion gating/suppression/loading and
dock/component tests pass, including same-resource/frame handoff and active-view
ownership. No physical video-decoder/performance test or APK build was run.
Targeted analysis has no errors; the full-player's pre-existing unused
`_favForSongId` field warning remains.

### Discovery desktop parity and motion artwork entry (October 22)

Compared mobile against current desktop `electron/discoveryArtwork.js` and
`electron/online/youtube.js`. Discovery now uses desktop's final YouTube song
thumbnail fallback after catalogue misses, accepting only matching recordings.
YouTube personal mixes accept dimensionless native thumbnails, retain the full
current WEB_REMIX client context, and page home/shelf continuations separately
with desktop's 20-token limit and existing time budget.

A ticker-disabled player drag preview can synchronously borrow an already loaded
motion frame without a lookup or second decoder. Both Hero flights retain motion
artwork; reduced motion, background and exclusive-output suppression still apply.

Validation: 54 focused discovery, parser, shared decoder and motion widget checks
pass, including a desktop-style 19-mix continuation fixture and a warm video drag
preview. Targeted analysis has no errors/warnings (style/deprecation notices
remain). No APK build, live account or physical-device validation was run.

### Discovery storefronts and personal-mix recovery

A live public iTunes search reproduced the reported Plastic Love miss: the US
storefront returned other artists, while GB returned Mariya Takeuchi's original.
Artwork lookup now tries GB after a US miss, preserving exact normalized artist
and recording checks so a cover version cannot supply the image.

YouTube traversal now budgets pages independently with a larger per-page limit;
an earlier response cannot consume the budget for later continuation pages.
Empty personal-mix headers no longer stop home pagination. Native RDTMAK cards
are accepted in grids/flat responses and the signed-in playlist library, and
provider-supplied personal-mix chips can provide browse IDs/parameters. Homepage
bootstrap includes the selected authuser. A shared 30-second fetch deadline
returns partial results instead of letting optional expansion discard all cards
at the outer timeout. Empty results report a reason, and app logs include only
request/page/shelf/card counts, never cookies, account IDs or response payloads.

Validation: 50 focused discovery checks pass, including the reported recording,
large earlier responses, empty headers, supplied chip routes and an optional
request that hangs after valid cards loaded. Targeted analysis has no errors or
warnings. Public storefront behavior was verified live; authenticated YouTube
mixes still require confirmation with the user's own profile. No APK/CI build
was run.


### Idle desktop sync, background playback and settings

Automatic journal sync now runs quietly once a minute, or after a local journal
change. It skips full metadata/lyrics maintenance and profile refresh; those run
when connecting or explicitly refreshing. Empty pulls no longer load every song
or emit milestone updates. Keeping an unchanged paired server no longer rewrites
the database and wakes library watchers. Outbox flushing and sync share one
in-flight guard. Initial/manual merges retain progress notifications.

The supplied logs show timed-out just_audio proxy connections to the desktop,
source-readiness timeouts, and an online source resume error. Android now sends
HTTP headers through ExoPlayer directly rather than the Dart loopback proxy
(including the crossfade player). Queued song taps coalesce to the newest choice
after a blocked request clears. Existing source failure invalidation and readiness
time bounds remain; background/device reproduction still needs verification.

Home Local supports pull-to-refresh even on a short page. It explicitly reseeds
Your Mixes and their Cover Flow picks without altering the playback queue.
Battery optimization lives in Data and an optional onboarding step, with status
refresh on return from Android settings. Prepare audio, automatic post-scan
preparation and ReplayGain scanning moved from Library to Data. Audio preparation
remains an optional waveform/loudness analysis job, not a playback requirement.

Published APK names are `Lokal-<version>-universal.apk` (full) and
`Lokal-<version>-Play-universal.apk`; each still contains ARM64 and ARMv7, while
versionCode, signing certificate and checksums remain in release metadata.
Validation: 30 focused player/mix/onboarding/settings checks and 23 packaging
checks pass. Settings search's stale account-location expectation was updated.
Targeted analysis has no errors/warnings; existing style notices remain. No
APK/CI build, live paired-device sync or physical background-playback test ran.

### GitHub startup updates

The legacy Play-first/Flick updater is replaced with Lokal GitHub release checks
using installed APK build numbers and matching full/play metadata/assets. Stable
installs use GitHub's latest stable release; nightly installs also consider
published nightlies. Replaced stable releases with unchanged marketing versions
are detected through their higher versionCode. Drafts, older/equal builds and
invalid checksums are excluded. Requests are bounded and automatic checks have a
30-minute cooldown. A single offer per release/build/checksum is shown per shell
session after onboarding, coordinated with What's new. Later dismisses it;
About › Updates provides a manual check and release-notes link.

Full APKs use Android DownloadManager for user-requested downloads, including
system notification progress and continuation outside the app. Reopening Updates
recovers the stored download status. Install verifies SHA-256 and APK package/build
on a worker thread before handing off to Android; Android verifies the signing
identity and requires user confirmation. First install requests Android's unknown
sources permission for Lokal, then the user can tap Install again. Downloads can
be retried. Only full builds declare REQUEST_INSTALL_PACKAGES and the narrowly
scoped APK FileProvider. Play variants open their matching GitHub APK externally.
No silent installation or automatic download is performed. Launcher alias updates
are held while installer/permission UI is open.

Validation: release selection/replacement/channel/checksum and explicit
user-download/install/permission sheet checks plus existing Settings checks pass
(16 checks). Dart analysis has no errors/warnings; XML/diff checks pass. No APK/CI
build, native compilation or physical DownloadManager/install test was performed.

### Unified settings navigation

Home, Library and You header gears all open the same searchable Settings main
page. Home's logo shortcut opens only Theme & accent; the complete Appearance
page remains a main Settings category. You › More no longer duplicates Online
sources. About remains in You and is omitted from main Settings categories,
while help/licence search results and existing direct links remain available.
The quick appearance page shares the full page's controls and is omitted from
search indexing to avoid duplicate results.

Validation: 39 existing navigation/settings widget checks pass after updating
route/category expectations. Targeted analysis has no errors; an existing
unnecessary-null-assertion warning in the appearance language selector remains.
No APK or CI build was run.

### Full / Performance / Ultra rendering budget

Appearance now has a three-segment performance selector. Legacy false/true
preferences remain Full/Performance, and Performance stays the default. Ultra is
explicitly opt-in and persisted across launches and theme changes. It inherits
Performance's solid surfaces and adds a shared route-wide rendering budget:
- suppress moving-cover/Canvas lookup and decoding, Ken Burns loops and automatic
  vinyl rotation, retaining the saved motion preferences for when Ultra is off;
- use flat cover flow with at most two neighbours per side, no mirrored covers
  or broad cover shadows, retaining gesture/spring navigation;
- cap cached/player artwork decode width to 768 physical pixels;
- cap flowing-lyrics repaint work to about 30 Hz, remove line blur and syllable
  lifts/feathered saveLayers, retaining word timing and clipped highlight progress;
- yield automatic local metadata repairs during scrolling and pace background
  reads more slowly; explicitly requested repairs keep priority.

Album-art animation controllers now stop when animation is disabled or hidden,
instead of ticking behind static art. Lyric timestamp/visible-line searches use
binary lookup so every repaint does not scan the entire lyric document. Regular
navigation and player sheet transitions remain animated, and audio paths are not
changed. Turning Ultra off restores the other modes' artwork and rendering.

Validation: 29 focused mode migration/persistence/pill, decoder gating/restore,
idle ticker, cover flow, lyric layout and Settings checks pass. Targeted analysis
has no errors; existing unused-field/non-null warnings and style notices remain.
No APK/CI build, Samsung M06 trace, physical frame timings, thermal or battery
measurement was performed; reduced work is not a quantified speedup claim.

### Spotify mix cards and optional fullscreen artwork

Spotify Discovery retains the native Home playlists already fetched through the
saved-cookie WebPlayer/Pathfinder flow. Mixed for you renders first as horizontal
cover cards, using desktop's personal-first ordering and first-occurrence dedupe.
Tapping a card fetches that playlist's metadata with the same cookie session,
then matches phone songs and queues unresolved entries through existing playback
sources. Cards remain usable when optional song recommendation shelves fail.
Desktop reference: `electron/artwork/spotify.js` (`homeMixes`, `madeForYou`,
`playlistTracks`) and `scripts/spotify-discovery.test.mjs` on sipbuu/lokal main.

Appearance › Now Playing › Fullscreen cover is an opt-in, persisted setting for
the standard full player. Album artwork expands behind the header as a top
banner, dissolving into the player palette before the controls. Spotify Canvas
retains the full viewport with a contrast gradient under safe-area controls. It uses the existing carousel, one active artwork Hero
and shared moving-cover/Canvas decoder. Lyrics and queue reveal their compact
cover while the poster recedes. The default layout and classic player are kept;
no new blur pass is introduced. Theme/accent changes preserve the option.

Validation: 30 focused Spotify API/discovery/widget, appearance persistence,
settings and lyrics-panel checks pass. Tests cover card order/layout and tapping
a mix into local-plus-pending queue entries, and retaining cards after optional
track requests fail. Targeted analysis has no errors; pre-existing unused-field,
unused-parameter and unnecessary-null-assertion warnings remain. No APK/CI build,
live Spotify account or on-device fullscreen/Hero/decoder validation was run.

### Player actions, session-stable Discovery and artist credits

Both full-player headers now open Android's system output chooser directly.
The now-playing song menu includes Start radio, and artist/album song rows use
Library's shared action sheet for long-press and overflow (with download retained
for online entries). Music-video and metadata jobs publish silent, throttled
Android progress notifications on a separate channel/ID from desktop sync;
notification denial does not interrupt work. This reports jobs, not a new
background execution guarantee.

Discovery retains loaded shelves for the app session across tab navigation.
Changing provider or explicitly refreshing reloads them; selecting the active
provider does not. Spotify account changes still invalidate cached account data.

Artist grouping, lookups, metadata warmup and player links use desktop's built-in
credit splitting rules, including protected names such as Tyler, The Creator.
Each artist in the standard and classic player can be opened independently.
Original tags are retained; desktop custom separator settings are not added.
The Videos page groups existing associations by actual video ID, preferring a
local song representative, without deleting songs or per-song video matches.

The shared Theme grid disables inherited scroll padding, removing the repeated
bottom inset between Theme and Accent in both full and quick Appearance.
Validation: 18 focused checks pass, covering desktop parser fixtures, individual
artist taps, video dedupe, Discovery cache lifetime, job notification completion,
and theme grid sizing with a large inherited bottom inset. Targeted analysis has
no errors; existing unused-field/parameter warnings and style notices remain.
No APK/CI build, native compilation or physical Android output/notification test
was run.


### Correct full-bleed album cover presentation

Reference: BitChord's enabled `fullBleedArt` / `heroMode` path in
`sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/player/NowPlayingScreen.kt`
(`bannerBottom`, `heroHeight`, `spotifyCanvasOnPhone`). Mobile now distinguishes
Spotify Canvas from still/other moving covers using the resolved source metadata,
not video aspect ratio. Source identity follows the shared video controller
through mini/full-player handoffs. Album covers occupy an edge-to-edge top banner
behind the status/header, with a bottom alpha fade into the existing palette
backdrop. Its bottom is measured from the expanded artwork/title layout and held
while lyrics/queue are open. Spotify Canvas retains its full-viewport frame.
The square Hero thumbnail is unmasked; no extra decoder, network request or blur
pass is introduced. The existing lyrics/queue transition remains in use; this is
not a port of BitChord's complete player motion system.

Validation: focused frame geometry/fallback, warm preview, suppression, loading
and motion gating checks pass. Targeted analysis reports no errors; an existing
unused field and style notices remain. No APK/CI build or physical device/video
rendering validation was performed.

### First-run folder picker lifecycle

Opening DocumentsUI stops MainActivity, which previously applied any queued
launcher-icon alias change. OEM launchers can restart the process despite
DONT_KILL_APP, losing the pending folder result. First-run accent synchronization
can queue an alias even without a manual theme change. MainActivity now defers
icon application while a document picker, overlay-permission or Spotify auth
result is pending, and during configuration changes. The queued icon still
applies on a later idle background exit.

Document picker launches share a pending-operation guard and translate missing
or denied picker activities into a recoverable channel error. A failed launch
clears pending state so another attempt works. Folder selection uses SAF's
chosen-tree grant directly, without first requiring broad media permission.
Onboarding resets its Opening state in finally, and folder errors avoid disposed
ScaffoldMessengers. Folder persistence and the shared Settings scan path remain.

Validation: 18 focused onboarding/folder-service checks pass, including picker
launch failure followed by cancellation/retry without a broad permission request.
Targeted Dart analysis has no issues. No native compilation/APK/CI run or Samsung
M06 reproduction was performed; the OEM restart mechanism is a concrete code
hazard consistent with the report, not a device-confirmed crash diagnosis.

