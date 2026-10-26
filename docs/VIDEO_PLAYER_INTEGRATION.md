# Music video integration (Prism-inspired)

This implementation follows the **presentation** model of [Prism](https://github.com/Yigder/Prism) rather than importing its Kotlin/Media3 code. Prism and Lokal are GPL-licensed, but their playback backends are different.

## Entry points

- Library > Videos tile: `openMusicVideo(song, videoId)`.
- Song menu > Watch video: the existing match/index check resolves the official video and calls the same entry point.
- Both routes open `FullPlayerScreen(videoSong, videoId)`, with regular full-player navigation chrome and an immersive fullscreen toggle.
- The YouTube iframe is a persistent widget in the full-player route, not a separate music-video page; existing external callers of `MusicVideoPlayerPage` still receive the same full-player screen.

## Playback ownership

The currently playing Lokal song is **paused** (and Internet Radio stopped) *before* opening the YouTube iframe. The music video audio and transport controls are owned by YouTube; the original audio queue is retained and **not restarted automatically** on exit. No extraction of YouTube playback URLs, no simultaneous double audio and no false song/video synchronization. YouTube's iframe may require a gesture even when autoplay is requested.

## Manual acceptance

1. Start local audio, open Library > Videos, select a matching video; assert audio pauses before video starts and its original queue remains available afterward.
2. Open Watch video from a song's action sheet and confirm the same full-player video mode.
3. Use embedded play/pause/seek controls. Toggle fullscreen, return with system Back, and confirm the video does not restart on layout change.
4. Confirm the device navigation/status bars return after fullscreen and after leaving the video.
5. Confirm music-video thumbnails with invalid IDs cannot navigate to arbitrary web addresses; test YouTube navigation goes external.
6. Test portrait, landscape, low-memory devices and YouTube unavailable/embedding-disabled cases.

Future parity with Prism's native Media3 video and album-track-to-video offset correction requires a separate, deliberate playback-backend change; this PR does not imply synchronization of separate videos and song lyrics.