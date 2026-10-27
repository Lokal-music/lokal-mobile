# AutoMix analysis cache (mobile)

## What is cached

`AutoMixAnalysisCache` derives a small, versioned `AutoMixProfile` from the
**already-persisted waveform/LUFS results** produced by
`AudioPreloadService` (Rust `analyzeAudioFile` → Isar `SongAudioCacheEntity`).
It does **not** decode audio on the playback thread and does not start a
network request. The derived profile records:

- near-digital leading silence and the last audible waveform bucket;
- a conservative fade-out hint and loudness-derived energy score;
- low-resolution energy-rise/drop candidates that a later, optional
  structural model could refine.

It does **not** currently provide beat grids, accurate tempo, vocal presence,
CUE-DETR output, or Demucs stems. Do not expose these amplitude-change cues
as proven phrase or vocal boundaries.

## Lifecycle and safety

- Flow warms up to four nearby *local* songs asynchronously, without blocking
  Play or the online recommendation lookup.
- The Android system player requests a profile when loading a track; when one
  is already present it may start a crossfade before **3–15 seconds of near-digital
  trailing silence** and seek over up to three seconds of digital lead-in.
  Missing or uncertain profiles preserve existing transitions.
- Identity is SHA-256 of the analyzer schema version, local path, file length,
  modification timestamp, track duration, and optional sidecar size and timestamp. Adding or replacing a sidecar creates a new cache identity. Replacing a track invalidates
  its derived profile, even if its library ID is unchanged.
- The JSON records live under application support
  `automix_profiles/`, written with a flushed temporary file and atomic
  rename. The directory is capped at 512 profiles, pruned every 32 inserts.
  The existing Isar waveform cache remains the authoritative source.
- Remote/signed URLs, CUE slices and inaccessible files are skipped. A missing or unknown local song ID only skips Isar waveform lookup; a separately validated CUE-DETR sidecar remains usable even without a fresh waveform. Bit-perfect/native Atmos
  sources keep the current non-mixing output path.
- A corrupt JSON entry is discarded and regenerated from Isar; it never causes
  playback failure. Cache exhaustion and storage errors fall back to ordinary
  crossfade instead of holding up playback.

## Optional offline CUE-DETR tier (imported sidecars)

Lokal Mobile now accepts the same `<audio-filename>.lokal-automix.json`
sidecar exported by the desktop
`scripts/automix-import-cues.mjs` helper. The helper can run a separately
installed CUE-DETR detector, validate original MP3 SHA-256 content and publish
model-selected overlap start positions. The Android process does **not**
execute Python models or embed PyTorch/Demucs.

When a source-matched sidecar exists, the player combines model entrances
and exits with the cached waveform profile. If the audio was copied from a
desktop computer and its modification timestamp changed, Android performs
asynchronous SHA-256 validation of the local file **only for that sidecar**.
The next-track lookup is capped by a short deadline; an unavailable report
never blocks an otherwise playable stream. Once a model sidecar has been
validated against a specific source and sidecar revision, its cue profile is
persisted in the derived cache, avoiding repeated SHA-256 of large unchanged
files on subsequent app launches.

When both roles have usable model cues, Android may move the fade to a
source-validated structural overlap, capped to the last 30 seconds. When the
model BPMs agree within 1%, a full **32-beat** equal-power native transition
is available without tempo correction; otherwise the configured short fade
remains. This still uses the existing two-decoder crossfader; it is **not
stem mixing**. Files with missing or invalid cues use the previous crossfade
behavior.

## Prepared stem clips on Android (opt-in)

After preparing a pair on desktop, use the desktop exporter with
`--clip-output auto` to produce an offline Demucs transition WAV and its
adjacent `.json` manifest. Copy the **two original local audio files**, the
mixed WAV and its manifest to the phone, keeping the generated WAV beside
its outgoing source recording. The mobile reader matches and SHA-validates
both original files and the clip even when Android paths differ from desktop.
The separate `.lokal-automix.json` model cue sidecars are optional: a
validated stem clip includes the authoritative transition timeline itself.

Enable **Playback → Song transitions → Prepared stem mixes (experimental)**
with crossfade on. Android prepares the incoming song and a third Media3
player in the background, plays the mixed clip starting at the manifest's
outgoing timestamp, retires the now-silent outgoing decoder and resumes the
incoming song at the exact source timestamp. Pause, seek and stop invalidate
or suspend the handoff; clip failure preserves normal crossfade. This is
**playback of externally rendered Demucs audio**, not on-device separation.
No large model or PyTorch runtime is bundled. The option is off by default;
CPU, device compatibility and physical listening validation remain required.

See the desktop guide `docs/AUTOMIX_MODEL_PREPARATION.md` for offline
preparation and export commands.

## Future high-quality pipeline

Integrating the upstream `VertexSelection/automix-engine` would introduce a
second, opt-in quality tier. Cue reports should be keyed by source-content
fingerprint plus model version/settings; stem windows should be separately
content-addressed and bounded by a user-configurable storage budget. Run
CUE-DETR/Demucs on isolated background workers, with cancellation, CPU/thermal
and battery controls. **Do not bundle the Python models or their weights** in
the base Android APK. Review LGPL-2.1 and each model's license before shipping
a model provider. In the absence of a prepared high-quality report, keep the
lightweight cue hints and standard crossfade path.
