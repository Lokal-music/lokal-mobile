# Flow integration (T1)

Shell entry point:

```dart
import 'package:flick/features/flow/flow_screen.dart';

const FlowScreen()
```

Use the existing app `ProviderScope`, initialized local library/database, and
player setup. No new dependency, shell registration, or native changes are
required by this feature. The screen includes its own `Scaffold`/app bar and
bottom space for the shell mini-player.

## Behavior

- Unlocks at 16 distinct favorite IDs present in the playable local library.
  Flick has no explicit artist-follow model, so artist affinity never counts
  as artist favorites or unlock progress.
- The local library supplies the initial three playable tracks and taste seeds,
  but online radio (YouTube Music, with Last.fm similar-track fallback) now
  supplies the majority of continuation candidates when available. Streams
  use QueuePreResolver pending entries and inherit provider playback fallback.
  Downloads and remote entries are not required in the local pool.
- Mood, discovery, memory, and genre exclusions are immutable domain settings.
  The tuner (including mood-pill entry) edits drafts. Apply persists/rebuilds a
  preview once; Cancel, back, or dismissal does not commit. Apply does not start
  or restart audio. Play/Shuffle explicitly start the displayed/new mix.
- Weighted seeded recommendations enforce discovery gates at <=15% familiar
  and >=85% unfamiliar, bans, three-skip exclusion, genre exclusion, and ID /
  metadata recording deduplication. Mood/affinity rely on file metadata.
- The temporary session starts with up to 3 tracks, adds batches of up to 10
  when three or fewer remain, and stops growing at 200 or candidate exhaustion.
  Provider ownership keeps growth alive after leaving the screen. Growth yields to a
  different/edited host queue. Starting Flow sets host shuffle/repeat off;
  runtime random queue-end autoplay is suppressed while Flow owns playback,
  and its prior value is restored when another queue takes over.
- Settings, bans, recent/skip signals, seed, track IDs, and current track ID are
  stored in the versioned `konnekted.flow.v1` preferences document. Session
  snapshots expire after 24 hours. Restore resolves IDs against the current
  library; it neither fabricates songs nor autoplays. Unknown storage versions
  fail visibly rather than being overwritten; corrupt JSON recovers defaults.
- Save asks for a name and uses the shared inherited `PlaylistService`, then
  invalidates `playlistsProvider`. The saved playlist is a snapshot; the live
  temporary Flow can continue growing independently.

## Deliberate boundaries / validation gaps

- Online radio is based on the current Flow seed; it is not a learned
  cross-platform preference model. Signed-in YouTube Music stations can be
  personalized, while guest radio and Last.fm are best-effort. Filters with
  missing remote genre metadata cannot be guaranteed; no audio fingerprints.
  Flow saves metadata-only references for online recommendations and re-resolves streams on playlist playback; expired stream URLs are never persisted.
- Only the explicit Flow **Skip** action counts as a skip. The host does not
  expose a reliable natural-end versus notification/mini-player Next reason.
- Current-track selection survives restarts; playback position remains the
  inherited player's responsibility. Re-entering after a process restart does
  not claim ownership of another/restored player queue until Flow Play is used.
- An inherited player adapter is used in production; automated controller
  tests inject a command probe. Native decoding, device playback, SAF access,
  background Android lifecycle, USB, and visual device testing remain for
  integration. No native/audio-quality claims follow from these tests.

Focused checks (run from repository root using the configured Flutter SDK):

```text
flutter test --no-pub test/flow
dart analyze lib/features/flow test/flow
```
