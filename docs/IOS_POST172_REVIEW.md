# iPhone review of mobile PRs after #172

Reviewed 26 October 2026 (Europe/Paris), through merged PR #196. The iPhone
branch now merges main `b705c10e37ea606a5154253413f82b3ebf7f846a` directly
(merge `b26d8b9e08a8acc4d60b8aa2e2b7e3c4b521fdb1`). All 20 PRs below are
included by ancestry, including stacked #180/#181; none is copied as a divergent
iPhone-only implementation. Rust, bridge dependencies and package locks are
unchanged by this main integration.

The shared Flutter screens are the iPhone screens. Android native widgets remain
Android implementations; their revised product design feeds the WidgetKit work
below. Inclusion in source is distinct from passing iPhone acceptance.

| PR | Relevant behavior carried into iPhone | Validation / remaining platform work |
| --- | --- | --- |
| [173](https://github.com/lokal-music/lokal-mobile/pull/173) | Bounded metadata backfill and startup repair; responsive large libraries. | CPU budget and metadata warmup regressions; large physical-phone libraries still need profiling. |
| [174](https://github.com/lokal-music/lokal-mobile/pull/174) | Artwork anchor recovery after queue/lyrics, full-art dismissal, compact queue design. | Artwork/morph and queue tests; native repeated panel visits and return screenshots added. |
| [175](https://github.com/lokal-music/lokal-mobile/pull/175) | Profile editor above persistent dock; wrapping Save/Cancel footer. | Existing profile widget tests plus native editor hit-testing/screenshot added. |
| [176](https://github.com/lokal-music/lokal-mobile/pull/176) | Autoplay preview and repeat-all without rebuilding active playback. | Autoplay/queue and failed-source regressions; preserve iOS system/Rust codec handoff. |
| [177](https://github.com/lokal-music/lokal-mobile/pull/177) | Faster critically damped opening and stable quality-badge geometry. | Route spring and identity-row layout tests; native full-player screenshot. |
| [179](https://github.com/lokal-music/lokal-mobile/pull/179) | Canvas chrome paint order, sharper YouTube art, source/size metadata. | Pixel assertions and artwork/metadata-sheet tests; real Canvas video still requires native acceptance. |
| [180](https://github.com/lokal-music/lokal-mobile/pull/180) | Discovery recovery, Tidal/Amazon sources and artwork; early widget iteration. | Shared discovery/source tests. Android widget code supplies design history, not an iOS extension. |
| [181](https://github.com/lokal-music/lokal-mobile/pull/181) | Large-library scheduling, compound artist/album lookup and search selection. | Warmup, album lookup, performance and search regressions. |
| [184](https://github.com/lokal-music/lokal-mobile/pull/184) | Canonical Deezer enrichment and measured byte-progress streaming. | Morneye streaming tests; opaque progressive handles retain the iOS system-engine processing guard. Live accounts remain unqualified. |
| [185](https://github.com/lokal-music/lokal-mobile/pull/185) | Online-first Flow/autoplay, global catalogue search, durable online playlist references. | Flow, radio, catalogue, playlist reference/import tests; preserve opt-in sources and manual-queue priority. |
| [186](https://github.com/lokal-music/lokal-mobile/pull/186) | Themed Discord community link on Home/Library/You. | Shared button/localization tests; external URL launch is separate from Discord rich presence. |
| [188](https://github.com/lokal-music/lokal-mobile/pull/188) | Songs filter restricts global results and corrects empty state. | Category/result filtering regressions. |
| [189](https://github.com/lokal-music/lokal-mobile/pull/189) | Themed global catalogue selector and provider-choice sheet; Amazon artwork. | Catalogue selector, provider/category and artwork tests. |
| [190](https://github.com/lokal-music/lokal-mobile/pull/190) | Live Now Playing, Flow/Radio and Cover Flow widget behavior. | Shared snapshot/recommendation contract carried forward; native WidgetKit still pending. |
| [191](https://github.com/lokal-music/lokal-mobile/pull/191) | Consistent Online songs section heading and spacing. | Online result layout/localization tests. |
| [192](https://github.com/lokal-music/lokal-mobile/pull/192) | Exactly Library/Online scopes, exclusive default-Songs categories, provider headings/artist portraits. | Narrow-phone filter tests and native scope/category interactions added. |
| [193](https://github.com/lokal-music/lokal-mobile/pull/193) | Songs/Artists/Albums/Lyrics in both scopes; retired-filter migration; incremental saved/embedded lyrics scanning and online LRCLIB. | Search migration, lyrics review/scanning tests; native filter coverage does not claim a live LRCLIB account/network test. |
| [194](https://github.com/lokal-music/lokal-mobile/pull/194) | Exactly three responsive artwork-led widgets; last-good cover while loading. | Adopt the three-family WidgetKit specification below; do not expose retired duplicate variants. |
| [195](https://github.com/lokal-music/lokal-mobile/pull/195) | Common local/online lyrics card: title, credits, matching excerpt without LRC timestamps, accent Play. | Lyrics result layout and matching/excerpt tests. |
| [196](https://github.com/lokal-music/lokal-mobile/pull/196) | Signed ARGB transport and compatible numeric preferences prevent Android widget fallback crashes. | Preserve upstream Kotlin and Dart regressions; use an explicit fixed-width color contract for future iOS snapshots. Android CI remains manually disabled. |

## WidgetKit design and implementation gates

Expose exactly three widget configurations, each responsive to the supported
small, medium and large iPhone families. The family controls density, not which
product it is. Album artwork remains visible at every size; reserve the sleeve
when empty and retain the last verified cover during replacement. Use theme and
album-derived surfaces, readable contrast and Dynamic Type; honor Reduce Motion.

| Configuration | Small | Medium / large | Empty / offline behavior |
| --- | --- | --- | --- |
| Now Playing | Cover, title, artist and play/pause when supported. | Cover, transport and system-driven progress; queue entry opens the app. | Last valid cover or branded sleeve; Open Lokal when there is no track. |
| Flow / Radio | Cover and active Flow/radio identity with primary action. | Current cover, station/context and supported transport. | Explain unavailable recommendations and open the app; no silent playback command. |
| Cover Flow | Cover-led recommendation with title and open/play entry. | A bounded strip of verified covers and current selection. | Keep available local recommendations, otherwise offer Open Lokal. |

```mermaid
flowchart LR
  Flutter[Shared player / Flow / recommendations] --> Snapshot[Versioned validated snapshot]
  Snapshot --> Assets[Bounded local artwork + last-good cover]
  Snapshot --> Group[App Group atomic persistence]
  Assets --> Group
  Group --> Timeline[WidgetKit timeline / system progress]
  Timeline --> Views[Now Playing · Flow/Radio · Cover Flow]
  Views --> Action[AppIntent on iOS 17+ / deep link on older OS]
  Action --> Inbox[Validated durable command inbox]
  Inbox --> Player[Existing app playback coordinator]
```

Implementation must validate IDs, bounded strings/arrays, finite nonnegative
position/duration, timestamps and a signed Int32 ARGB value (decode color as its
UInt32 bit pattern). Readers accept compatible legacy numeric widths without
trapping; corrupt fields fall back independently rather than replacing every
widget with one emergency layout. Never put credentials or transient stream URLs
in the App Group. Extension code reads snapshots and owned artwork; it must not
start a second Flutter/Rust audio engine or download arbitrary art at render time.

Apple's current [supported-capabilities table](https://developer.apple.com/help/account/reference/supported-capabilities-ios)
includes App Groups for the free Apple Developer account column as well as paid
memberships (checked 26 October 2026; the HTML table uses checkmark figures).
Do not assume a paid membership is necessary from older guidance. The actual
provisioning profile, matching host/extension group and Windows re-signing behavior
still require a signed-device test. [WidgetKit updates](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
are scheduled by the system; use timeline entries and system progress rather
than periodic app wakeups.

The base app retains its iOS 15 floor. Gate AppIntent interactive controls at iOS
17 and later; older widgets use deep links. WidgetKit schedules updates; do not
promise an unrestricted live refresh loop. Test stale timelines, artwork churn,
missing data, signed colors, cold-start command replay, offline behavior and text
scaling. Verify entitlements and extension re-signing with the Windows sideload
path before enabling this optional extension. A free-account re-sign that cannot
retain the App Group must still allow ordinary app playback, with a clear widget
availability explanation. Native widgets are not yet implemented or accepted.

## Validation record

All 20 PR merge commits are reachable from the integrated iPhone branch.
The pass enumerated 41 changed Dart test files. **All 248 cases in the 40
completable files now pass**, including search, lyrics-card layouts, catalogue
settings, Flow/autoplay, artwork/Canvas, profile editing, route motion, streaming,
playlist references and Android widget contracts.

The initial pass found seven failures. Two visual-test failures were resolved
by the compositing/harness fixes below. The other five search/Cover Flow failures
reproduced on untouched main `b705c10` before their fixtures were reconciled:
UI tests now override the current global catalogue interface instead of the
retired Apple-only provider; the narrow filter test scrolls and lays out Lyrics
before tapping it; Cover Flow expects the intended middle initial item. Stale
query protection, entity isolation, no library work in Online scope and the real
queued recommendation order remain asserted. The three corrected fixture files
also pass static analysis without findings.

The remaining failed-source fixture stalls on untouched main under an external
45-second bound. Its unresolved-source Repeat All case passes independently; its
asynchronous-retirement assertion also fails on both branches. This file is
excluded from the 248-pass selection, and decoder retirement is not claimed green.

A separate post-merge iPhone regression selection passes all 41 cases, including
the actual host Rust metadata/QuickJS bridge (with `LOKAL_NATIVE_LIBRARY` set),
iOS storage/document handling, processing selection, codec routing, ReplayGain
and Desktop Link errors. These host checks do not replace the hosted iOS run.
Build 19 compiled/packaged the updated release IPA, but attempt 1 failed the
minimal Flutter control-app VM gate before Lokal could execute. Attempt 2 retries
on a fresh hosted Mac. The newly added native UI interactions are still pending. The native Android widget regression passes all five cases (including the real
SharedPreferences numeric boundary), and application/integration analysis finds
no errors (555 existing warning/info findings). Six focused player tests pass.

The Canvas pixel test now awaits raster work outside Flutter's fake clock,
retaining its actual pixel assertions. This exposed a real rendering defect:
chrome's OpacityLayer was positioned using a canvas-only transform when its child
had no repaint boundary. The portal now declares its compositing requirement,
so both boundary and non-boundary cases retain their transformed foreground
position. The identity-layout test also disposes/drains its marquee pause timer.

Build 17 passed the complete native suite on iOS 18.6 and 26.0, but its merge
checkout only included upstream PRs through #186. Build 18 passed the native suite
and real Bonjour/HTTP discovery on iOS 18.6 at source
`d345edb3dae4b3a41c4524d163d44bdb83fd5309`, with main parent
`63bba250dcfd67d97d3165cf61cecbe7fb6a8431` (through #194). Its iOS 26 simulator failed to boot,
so that runtime did not execute the newer suite. Neither run establishes complete
#196 UI coverage, physical iPhone acceptance or signed installation.


Build 19 / attempt 1 package metadata identifies source
`e66c0dfaf079f21954d67536643c080278258106`, tree
`3bc937d41e6ed94e55e3aaf2d65b4718d0fee7d2`, and SHA-256
`6092b2d934cc6f9d26f012aa5cdc8ae0bf2457b89639a086e28208a0c7c62550`.
All 33 device binaries passed CI inspection; the downloaded IPA and checksum
were verified locally. This package has the updated UI, but its new simulator
acceptance remains pending, and it has no physical-device qualification.
