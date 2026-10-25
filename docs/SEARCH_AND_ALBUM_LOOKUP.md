# Album catalogue lookup and search filters

## Dude soundtrack lookup

The supplied screenshot shows Dude (Original Motion Picture Soundtrack), with
Sai Abhyankar, Paal Dabba, Bhumi and Deepthi Suresh credited together. The old
lookup searched the combined credit as a single artist, required an artist ID,
and then required the returned album artist string to equal the whole credit.
A soundtrack credited to its composer could therefore be discarded twice.

A live public iTunes album search returned collection 1848715390 under Sai
Abhyankkar. Telugu collection 1849410150 and Original Score releases also appear
in the results. Choosing the first search hit would select the wrong edition.
The matching tests include this ordering and reject unrelated composers,
language variants, live/deluxe editions and score releases.

Release search now precedes artist discography lookup. It uses the album title
and leading credited artist, then bounded title/storefront fallbacks. Matching
recognizes credited performers and generic soundtrack wording; a narrowly
bounded doubled-letter tolerance handles long multiword transliterations such
as Abhyankar/Abhyankkar. This does not alter saved tags. Album lookups use a new
cache key so older negative matches do not survive the fix. The matched
storefront is retained for the track lookup.

Editorial notes, tracks and cover availability are independent. A failed notes
request does not hide a valid track list; a missing track list does not discard
a verified cover. Authoritative album art is preferred; missing art can fall
back through the existing Deezer/iTunes resolver with the same identity checks.
iTunes album fallback art requests 1500px; ordinary track art retains its prior
600px behavior. Online album headers prefer the verified catalogue cover and
reuse the existing failed-image resolver if that URL cannot load, with local
art retained as a fallback. Local album matching shares the credit/title rules. The empty
state no longer tells users to enable Online while it is already enabled.

## Search interaction

Result type is now one category or All. Tapping Albums immediately selects
Albums; tapping it again leaves it selected; All always restores every category.
The old persisted exclusion mask is replaced with a single-choice preference.
Delayed preference hydration cannot overwrite a newer tap. Storage failure
leaves Search usable.

All sources / Library / Online is a separate control. Library-only categories
(folders, years, album artists, playlists) do not show unfiltered online songs.
Online scope offers songs, artists and albums. Selecting a local-only category
from Online switches to Library; choosing Online from a local-only category
restores All. Counts in Library scope describe local results only.

Online artist and album categories call their respective metadata endpoints and
open the existing detail pages. All includes previews with See all actions.
Online-only search does not wait for or query the local library. Playback still
uses the configured playback providers; catalogue metadata is not an audio URL.
Old in-flight query results do not replace a new query.

An isolated local category shows every matching row instead of the four-row
preview. Local search refreshes on library and playlist changes, reuses an
already loaded library, splits collaboration credits into individual artist
results, and keeps same-named albums from different artists separate. A local
query failure does not suppress available online results.

## Validation

108 focused tests pass across large-library work, filters, full-screen search,
live data revisions, catalogue/artwork matching, online playback/queue/download,
and localization guards. All shipped non-English locales have the new fixed
search phrases; a French widget test checks scope, catalogue, retry and empty
states. Localization uses the existing Lokal presentation-phrase dictionaries.
The no-results hint retains the single-category/All wording in every locale.

Identical generic credits (Various Artists / Unknown Artist) match themselves
without acting as wildcards. Album pages compare a precomputed title key before
parsing artist credits. The shared soundtrack qualifier expression is reused.

The prior online_search_section_test.dart failures are resolved. The action
sheet is scrollable on a short display, download confirmation names the actual
library folder, and fixtures explicitly control source memory, native stream
inspection, pending-song creation and toast lifetime. Measured audio details
are still shown; uninspected YouTube results do not invent codec/bitrate badges.
Legacy locale-switch assertions now use the current Lokal branding.

Focused analysis reports no errors or warnings; style infos remain.
git diff --check passes. No Android device/APK validation is claimed. The public
metadata response was checked, while release selection, provider errors and
fallback behavior use deterministic HTTP fixtures.
