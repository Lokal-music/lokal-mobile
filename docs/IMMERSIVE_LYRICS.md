# Immersive lyrics (Prism-inspired)

Reference: [Yigder/Prism](https://github.com/Yigder/Prism), especially its `ImmersivePlayer`. This implementation is independently written in Flutter using Lokal's existing lyrics and media services; no Kotlin or protected Prism assets are copied.

## User experience

- Enter with **Immersive** in the full-player horizontal action strip, or the expand icon in the regular Lyrics header.
- Full-screen cover backdrop plus a clearly visible cover; ordinary player chrome and metadata are replaced with **one active line and the upcoming line**, styled as subtitles.
- Accurate line timing from `PlayerService.positionNotifier`; existing `LyricMotionLine` preserves word timings. Seeking, pausing and next/previous use the same queue/clock as the regular player.
- Tap the cover to reveal short-lived controls (close, lyrics source, translation, romanization, transport).
- The **Translate** and **Romanize** buttons use Lokal's existing `LyricsTranslationService.convert` and retain source line timestamps. Translations/romaji appear directly beneath the active line. The controls remain mutually exclusive just as in the ordinary player.
- Missing synced lyrics show the normal no-lyrics state; plain lyrics display as readable, scrollable text rather than inventing timing.
- Back/close returns to regular Full Player, not Library. Exiting does not stop or replace the playing track.

## Merge ordering

This is a stacked PR based on the companion music-video full-player PR. Merge music video first, then retarget this PR to `main` and merge immersive lyrics. Video and immersive lyrics are independent presentations; immersive mode does not overlay the separately timed YouTube video, so no false sync is implied.

## Manual QA

1. Test regular synced, word-timed, unsynced, missing-lyrics, and instrumental cases.
2. Enter/leave via actions and Android Back; verify transport, queue and artwork remain intact.
3. Select a Japanese/Korean lyric source; choose Romanize; confirm a subline under the current lyric and correct position after forward/back seek.
4. Choose Translate and change source during playback; reject stale results when the song changes.
5. Verify previous/next, pause, buffering and autoplay transitions do not show the previous track's lyrics.
6. Test large text, RTL, dark/light themes, performance mode, low-end devices, Canvas enabled/disabled, phone rotation and layout under system bars.
7. Confirm the full-player regular Lyrics view still works and its bottom-sheets persist.

This PR adds focused clock and subline tests; on-device presentation and performance still require verification.