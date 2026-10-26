# Native music videos — Lokal Mobile (Prism-inspired)

Reference architecture: [Yigder/Prism](https://github.com/Yigder/Prism) uses Media3 with separate video/audio tracks. Lokal now uses its **existing InnerTubeX v0.7 extractor**, rather than copying Prism's Java/Kotlin source or deploying another extractor.

## Playback engine

1. Existing YouTube Music catalogue/index identifies an official music video for a song.
2. Android's `YoutubeNativeResolver.resolveVideo` requests `ContentHints(wantVideo=true)`, retrieves the separate video and audio URLs from **the same video ID**, and preflights both. Both must be playable HTTPS googlevideo URLs.
3. `LokalMusicVideoView` hosts a `PlayerView` with a `TextureView` through Flutter `AndroidView`. Media3's `MergingMediaSource` shares **one clock** for the video's audio and visual streams. The native surface uses no YouTube UI or controls.
4. Flutter owns the play/pause, seek, fit/fill, title, back, and fullscreen chrome. Fullscreen resizes the same native platform view rather than recreating the playback session.
5. If the extractor cannot provide a compatible paired stream, or Media3 fails, the **official YouTube iframe** remains available as fallback, subject to the normal embed restrictions.

## Contextual Video action

- **Video** appears in the normal full-player footer only when music videos are enabled and the current song has a positive official match in `musicVideoIndexProvider`.
- The existing index can look up a current track on demand and updates the UI when it finds a match. A no-match or disabled setting never shows the button.
- Video toggles to the native stage **inside the same full-player route**. The playing album recording is paused before opening its video, and resumes if it had been playing when leaving.
- Videos selected from Library > Videos or **Watch video** open directly in the same full-player video presentation. Library's audio queue remains intact and does not auto-start when that separate route is closed.

## Limitations

- A song and its music video can have different intro/outro offsets or even different edits. This PR deliberately does **not** pretend that album-track lyrics or positions are synchronized with the video's sound.
- YouTube can rotate or restrict signed media URLs, require special range headers or enforce embedding restrictions. The fallback is not optional reliability debt; it is a user-facing recovery path.
- Native Media3 and Flutter platform views require device testing on the project’s Android 14–17 devices and low-end hardware. This implementation has not been proven by device tests yet.
- Device/system audio focus must be checked when video and local/Rust playback alternate; no new global playback engine replaces Lokal's song queue.

## Acceptance checklist

1. Start a playing local track, tap **Video** in footer; confirm it appears only for a verified match and local audio pauses before the video starts.
2. Seek/play/pause from Lokal's custom video controls; confirm picture and sound share the same clock.
3. Toggle fit/fill and fullscreen several times; verify the stream doesn't restart, especially on Samsung/OneUI.
4. Return to song audio with Android Back or the top-left button. Confirm native audio is stopped and the previous song resumes at its original position.
5. Enter from Library > Videos and Watch video; confirm original queue remains intact without unrequested restart.
6. Trigger expired URLs, no stream, forbidden/age-gated video and offline. Expect graceful official YouTube fallback rather than a blank surface.
7. Inspect native decoder and audio-focus lifecycle on navigation, app background, rotation, Bluetooth handoff and Android back.
8. Confirm the app remains usable when the source reports a partial video without compatible audio/video pair.

The companion #200 branch provides **Space** immersive lyrics for verified synchronized song lyrics, not video overlays. Merge #199 before #200.