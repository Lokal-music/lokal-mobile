# Android source reliability incident — 27 October 2026

Source: user-exported `lokal_logs_2026-10-27T14-03-54.txt` (Xiaomi
25113PN0EG, Android SDK 37). The file is a rolling log, not a complete
network/HTTP trace. The user had **not installed** the separate battery PR
#257 when reporting source failures.

## Observations supported by logs

- Repeated `[Spotify] fetchLibraryTracks HTTP 401` entries (e.g. 05:30,
  07:39, 09:30, 11:28). There are corresponding successful
  `WebPlayer session refreshed; client=true` messages, but query hashes
  are sometimes zero. A 401 remains after a token refresh. This does
  **not** prove the account's cookie is valid; a user reauthentication may
  be required. Do not silently delete saved credentials or claim the
  entire Spotify API is down.
- Uncaught Dart `_HttpClient._returnConnection` null-check exceptions occur
  in pairs around 18:21, 05:33 and 13:54, near repeated public
  artwork-provider request failures. Dart internals are at the top of
  the stack; the originating caller is not established.
- Repeated iTunes/Deezer **Discord cover** request failures are separate
  from audio availability; logs also show successful artwork resolutions.
- Occasional `[Playback] Android source failed` entries affect a local
  FLAC and a network Opus track. They do not prove Qobuz/Tidal/Amazon
  failures across all sources.
- Some Android process exits are signal 9; these reports have no native
  stack trace to prove an OOM or which component caused termination.
- Log sharing fails after Android's save picker returns
  `/document/primary:Music/...`: this is a document identifier, not an
  accessible local file.

## Scoped mitigation

1. **Do not abort completed requests.** Both DiscoveryHttp and SpotifyHttp
   previously completed their AbortableRequest abort trigger in `finally`,
   including after successful response consumption. This is unnecessary,
   creates a socket-lifecycle race, and could plausibly contribute to
   `_HttpClient._returnConnection` exceptions. Continue to abort on
   actual timeout, cancellation, and failed/incomplete requests.
2. **Graceful client close.** Use the existing `GracefulHttpClient`
   (non-forceful socket-pool close) for Search, discovery playback,
   public artwork, and Spotify API defaults to avoid killing in-flight
   response/connection return during navigation.
3. **Source visibility.** Retain the prior source list if a transient
   refresh fails; log which source/phase failed using sanitized categories
   or exception classes, never signed URLs, cookies, HTTP bodies or tokens.
4. **Diagnostic export.** Share the original exported bytes via
   `XFile.fromData` with explicit filename regardless of the SAF
   document URI returned by the save picker.

This patch is a defensive lifecycle correction, **not** verified proof
that the Dart runtime exception is eliminated. Spotify 401 cannot be
resolved safely by client code without a verified valid session.

## Device validation before considering the issue closed

- Alternate Search sources among native YouTube Music and installed HTTP
  add-ons, run repeated search/preview/play/next operations and return
  between Home, Search, Library and the full player.
- Run Qobuz, Amazon, Tidal and Deezer separately and through automatic
  fallback (including during network interruptions and after a failed
  request), with four-ahead queue prefetch.
- Stress repeated navigation away from an in-flight media/artwork search;
  check no new `_HttpClient._returnConnection` zone errors.
- Recheck Spotify Library after reauth with a valid session if 401 persists.
- Save logs to Android Music and confirm **Share** delivers a readable
  `.txt` file without `NoSuchFileException`.
- Capture a new log with `[OnlineSource]` entries and playback outcomes
  for any continuing failure; include source, operation, and whether it
  occurred on Wi-Fi/cellular. Never collect credentials.

Recommended CI: `flutter test
test/discovery/source_transport_success_abort_test.dart`, the existing
Discovery/Spotify/Search tests, Flutter analysis and a release APK build.
No device battery or provider availability result should be inferred
from static checks alone.
