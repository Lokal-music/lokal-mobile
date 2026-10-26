# AutoMix analysis cache (mobile)

## What is cached

`AutoMixAnalysisCache` derives a small, versioned `AutoMixProfile` from the
**already-persisted waveform/LUFS results** produced by
`AudioPreloadService` (Rust `analyzeAudioFile` → Isar `SongAudioCacheEntity`).
It does **not** decode audio on the playback thread and does not start a
network request. The derived profile records:

- leading digital silence and the last audible waveform bucket;
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
  is already present it may start a crossfade before **3–15 seconds of proven
  trailing silence** and seek over up to three seconds of digital lead-in.
  Missing or uncertain profiles preserve existing transitions.
- Identity is SHA-256 of the analyzer schema version, local path, file length,
  modification timestamp and track duration. Replacing a track invalidates
  its derived profile, even if its library ID is unchanged.
- The JSON records live under application support
  `automix_profiles/`, written with a flushed temporary file and atomic
  rename. The directory is capped at 512 profiles, pruned every 32 inserts.
  The existing Isar waveform cache remains the authoritative source.
- Remote/signed URLs, unknown IDs, CUE slices, inaccessible files and tracks
  without a fresh Isar waveform are skipped. Bit-perfect/native Atmos
  sources keep the current non-mixing output path.
- A corrupt JSON entry is discarded and regenerated from Isar; it never causes
  playback failure. Cache exhaustion and storage errors fall back to ordinary
  crossfade instead of holding up playback.

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
