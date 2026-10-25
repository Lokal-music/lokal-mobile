<p align="center"><img src="docs/images/hero.png" alt="Lokal Mobile — Your music. Everywhere you go." width="100%"></p>

<p align="center">
  <a href="https://github.com/Lokal-Konnekt/lokal-mobile/releases"><img alt="Version 1.0.0" src="https://img.shields.io/badge/next_stable-1.0.0-65e2ce?style=flat-square&labelColor=0b1318"></a>
  <img alt="Android 8.0 and later" src="https://img.shields.io/badge/Android-8.0%2B-65e2ce?style=flat-square&labelColor=0b1318">
  <img alt="64-bit ARM phones" src="https://img.shields.io/badge/Phones-64--bit_ARM-65e2ce?style=flat-square&labelColor=0b1318">
  <a href="LICENSE"><img alt="GPL-3.0 license" src="https://img.shields.io/badge/license-GPL--3.0-65e2ce?style=flat-square&labelColor=0b1318"></a>
</p>

**Your music, your files, a modern player. Now on Android.** Lokal Mobile brings the artwork-led library, personal mixes and synced lyrics of [Lokal desktop](https://github.com/sipbuu/lokal) to your pocket. Play the collection you already own, discover something new through sources you choose, and keep your phone and desktop connected.

No Lokal account is needed to play local files. Your library and listening history live on your device; online discovery, lyrics, artwork and account integrations are optional.

<p align="center">
  <a href="https://github.com/Lokal-Konnekt/lokal-mobile/releases"><b>Download</b></a> ·
  <a href="https://github.com/Lokal-Konnekt/lokal-mobile/actions/workflows/android-nightly.yml">Nightly builds</a> ·
  <a href="https://github.com/Lokal-Konnekt/lokal-mobile/issues">Report an issue</a> ·
  <a href="docs/BUILD.md">Build from source</a> ·
  <a href="https://github.com/sipbuu/lokal">Lokal for desktop</a>
</p>

**1.0.0 is the next stable mobile release.** Until it is published, preview APKs are available on the Releases page. Stable releases and nightlies have separate, manually triggered build flows; merging a pull request does not publish another beta.

An experimental iPhone port is in progress. See the [architecture and evidence](docs/IOS_PORT.md) and [Windows IPA signing guide](docs/IOS_SIDELOADING.md). Engineering IPAs still require physical-iPhone and installation qualification.

---

## A collection that feels like yours

<p align="center">
  <img src="docs/images/home.png" alt="Home: a personalized greeting, Cover Flow, mixes and the compact player" width="320">
  &nbsp;&nbsp;
  <img src="docs/images/library.png" alt="Library: albums, artists, recently added covers and music browsing" width="320">
</p>

<sub>Rendered from the current Home and Library widgets using a fictional demo collection. The artists, songs and cover artwork above are made up.</sub>

- **Home built around your listening:** personal mixes, recent plays, favorites and paired greetings that follow the same rules as desktop.
- **Cover Flow and Flow:** browse your covers and explore a listening session drawn from your music.
- **A proper local library:** songs, albums, artists, genres, folders and playlists, with recently added music close at hand.
- **A player that stays with you:** a floating mini player, full-screen artwork, a queue and timed lyrics, plus the nostalgic Classipod view.
- **Your look:** themes, accents, launcher icons and a performance mode that is enabled by default.

## Lyrics that move with the music

Read synced lyrics line by line, word by word or syllable by syllable when the source provides those timings. Switch sources from the player, refresh a search, or search manually by title and artist when a match is wrong.

| Lyrics | Options |
| --- | --- |
| Local lyrics | Embedded lyrics and supported sidecar/imported lyric files |
| Word and syllable timing | BiniLyrics, BetterLyrics, Portato, LyricsPlus and Unison, where available |
| More catalog coverage | LRCLIB, KuGou and lyrics.ovh |
| Language | Translation and romanization toggles, animated alongside the original text |
| Desktop copies | Import saved lyric timing from a compatible paired desktop, including existing copied tracks |

Choose your source order and timing preferences in Playback settings. Providers vary in availability and coverage; Lokal can only show word timing when that recording has it.

## Find, play and keep

Search your own library first, then search online sources and installed add-ons. Play a result, queue it, or save it to your music library. Search and song preparation show progress; an add-on that needs verification stays listed so you can renew its session without rebuilding your source order.

Discovery can use Last.fm, YouTube Music or your Spotify web session. Spotify cookies are managed in **You → Data → Accounts**, alongside the optional matching-library liked-song sync toggle. Streaming a song does not make it an owned local file.

Moving covers support Apple Music, Tidal, community artwork, m8tec and Spotify Canvas. Select providers in Appearance, prioritize Canvas if you prefer it, and disable motion for individual songs from their menu. Added online providers are opt-in; Spotify Canvas needs your Spotify session.

## Take your desktop library with you

Pair with [Lokal desktop](https://github.com/sipbuu/lokal) over Wi-Fi from **You → Data → Accounts → Desktop link**.

- Control desktop playback from the phone, including the Android notification.
- Merge supported library records, likes, playlists, listening history and profile data.
- **Copy missing song files both ways**, with a preview before copying.
- Save PC-to-phone originals under **Lokal Desktop** in a selected music folder.
- Recover older app-private desktop copies through **Copy missing song files**, without downloading them again or changing their library identity.

A library merge and a file copy are separate actions. Keep both apps open while copying. See [desktop file storage](docs/DESKTOP_FILE_STORAGE.md) for folder permissions and recovery behavior.

## Built for your headphones, too

Lokal Mobile combines a Flutter interface with Flick's Rust decoding/audio engine, Android background playback and MediaSession controls. Supported devices can use native PCM/DSD paths and direct USB UAC2 output.

EQ, DSP, software gain, crossfade and Android-mixed playback alter samples. Bit-perfect output depends on the selected output path, hardware and settings; it is not a label applied to every playback mode. File quality labels use audio metadata rather than treating every FLAC as hi-res.

Optional integrations include Last.fm and ListenBrainz scrobbling, network music sources and Discord Rich Presence. Availability can depend on your build, service account or connected hardware. The [feature ledger](docs/FEATURE_PARITY.md) records implementation details and remaining device checks.

---

## Install and update

1. Open [Releases](https://github.com/Lokal-Konnekt/lokal-mobile/releases) and choose stable or nightly.
2. Download **`Lokal-<version>-arm64.apk`** (the full build). The optional Play variant adds `-Play` to its name. Each APK is built for **64-bit ARM phones** to reduce download size. 32-bit-only phones and x86 Android emulators are not supported; existing compatible installations can update in place with the same signing key.
3. Allow your browser/file manager to install the APK, then choose your music folders from Library settings.

**Requires Android 8.0 or newer and a 64-bit ARM device.** Android 14 is **not** required. The `play` flavor is an alternative distribution variant; most people sideloading from GitHub should use `full`.

Stable and nightly APKs use the same package and permanent signing key, so they can update in place when the new APK has a higher versionCode. They share app data and cannot be installed side by side. Returning from a newer nightly may require waiting for a newer stable build. Very old debug-signed betas need a one-time migration; [read the update notes before uninstalling](docs/RELEASING.md#beta-updates).

## Stable releases and nightlies

| Stable | Nightly |
| --- | --- |
| <img src="docs/images/release-preview.png" alt="Teal mobile stable-release banner" width="460"> | <img src="docs/images/nightly-preview.png" alt="Coral mobile nightly-release banner" width="460"> |
| **Actions → Release Lokal Mobile → Run workflow** | **Actions → Build Lokal Mobile Nightly → Run workflow** |
| Choose **patch**, **minor** or **major**, or an exact version. The prepared first release stays **1.0.0**. Creates a reviewable draft by default. | Builds main as `1.0.0-nightly.N` before 1.0.0, then the next patch of the latest stable tag. |
| Publishing a stable release makes it the latest stable download. Matching `v*` stable tags also work. | Always a prerelease; never replaces GitHub's latest stable download. |

Both flows generate their own mobile banner, changelog, signed APKs, certificate metadata and SHA-256 checksums. Merges run normal CI but **do not publish APK releases**. [Release maintainer guide →](docs/RELEASING.md)

## Build, contribute and report problems

Start with [BUILD.md](docs/BUILD.md) for the pinned Flutter, Rust and Android toolchain. The internal Dart package (`flick`) and Android application ID remain stable for compatibility and existing installations; the product is **Lokal Mobile**.

When reporting playback or UI problems, include your phone, Android version, installed build, source/file format and relevant in-app logs. Remove cookies, tokens and pairing secrets before sharing logs. [Open an issue](https://github.com/Lokal-Konnekt/lokal-mobile/issues) or send a pull request with a focused explanation of the change.

## License and credits

Lokal Mobile is **GPL-3.0**. It builds on Lokal's music experience and Flick's audio architecture. MIT-derived material retains its attribution; see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Bundled fonts and third-party SDKs retain their own notices.
