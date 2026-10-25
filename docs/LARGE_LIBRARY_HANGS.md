# Large-library hangs: issue #109 follow-up

The supplied Galaxy S25 Ultra (SM-S938B, Android 17) recording shows ordinary
You-tab scrolling stopping while the dock is collapsed. The reporter describes
occasional hangs after scanning 5,500 songs; 2.1.3 improved CPU/heat but did not
eliminate them. The exported log has a 60-second gap between its normally
15-second performance samples (23:12:52 to 23:13:52), with the last sample at
1.86 CPU cores in Ultra mode. Earlier runs approach 1 GB RSS. These are process
observations, not a stack trace proving a single cause. The HTTP-client null
assertions are separate errors and are not evidence of the scrolling cause.

## Remaining work after the first CPU fix

- LocalMetadataRepair.warm queued every local song on startup, even when the
  scanner had already completed its metadata. Its delay reduced duty cycle but
  did not eliminate thousands of redundant probes.
- SAF documents were also owned by BackgroundMetadataService. The second
  repair path could stage whole audio documents (up to its 256 MB cap) into the
  playback cache just to read headers. Native metadata extraction already uses
  a content URI without that full-file copy.
- ArtistMetadata.warm parsed every song synchronously inside the library
  listener, including on artwork/sample-rate refreshes with unchanged credits.
- The preferred-library index normalized every local recording even when no
  desktop stream rows existed to deduplicate.

## Changes

Complete scanner rows skip automatic header repair. Old desktop_music copies
remain eligible for codec-label corrections; incomplete accessible files are
still repaired. SAF documents use their existing single-file native backfill
worker. Automatic repair of inaccessible file paths does not stage a fallback;
explicit desktop copy/repair retains the fallback and existing size cap.

Artist warmup parses new artist/album-artist pairs only, yields every 64 songs,
coalesces incoming snapshots, and stops on provider disposal. Existing portrait
fetch ordering and serial fetches remain. Phone-only libraries build the same
visible/ID index without recording normalization; mixed desktop libraries keep
the existing conservative matching rules and playlist aliases.

Local repair start/finish summaries are exported without Developer Mode and
contain counts/timing only. Performance collection continues in the foreground
after the two-minute suggestion window. Samples include actual window length
and worst UI/raster frame times, so a long stall cannot disappear behind an
average FPS or miss count. No private log files or song tags are committed.

## Validation and remaining device check

Regression tests exercise 5,500 complete rows, 5,500 SAF rows, cooperative artist
warmup, unchanged-credit refreshes, superseding/disposed warmup, inaccessible
paths, incomplete/desktop repair, and local/desktop playlist identity behavior.
Existing serial backfill/checkpoint and artist-credit parity tests also apply.

38 focused tests passed across backfill, identity, artist credits/warmup, library
revision/Home data, Ultra behavior, and diagnostics lifetime. Focused Dart
analysis reports no errors or warnings (two existing style infos in the advisor).
`git diff --check` passed. No APK/native build was needed for these Dart changes.
A temporary host comparison of the old/new index on 5,500 synthetic phone songs
(eight runs, matching visible rows and ID lookups) measured a median 47.99 ms
before and 0.455 ms after. This is a host microbenchmark, not an S25 frame result.

No S25 Ultra hardware or the reporter's music files are available here. After
installing the fix, scan once, allow background work to finish, restart, then
scroll You/Home/Library with playback in Ultra and normal modes. Export logs if
a stall remains; compare metadata job counts, sample windowMs and maxUiMs /
maxRasterMs. Do not close #109 solely on host tests or describe this as a proven
fix for every device stall.
