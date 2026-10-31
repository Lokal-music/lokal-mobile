# Lokal Mobile — editorial UI device QA

This change updates presentation and interaction, not the underlying library, catalogue, player, downloader or audio pipeline.

## Device matrix
- Narrow Android (320–360 logical px), normal and 1.5× / 2× text scale; check long translated genre and album names, safe areas, no horizontal overflow.
- Standard Android (390–430 logical px), portrait and IME keyboard; navigate from Search, Library, Home, Now Playing and online catalogue.
- Tablet / foldable (560, 850 and 1,000 logical px); verify 2/3/4-column responsive genre grid, artwork sizing and scrolling.
- Dark, light, OLED, and accent presets. Genre tile colours stay consistent; text contrast remains >=4.5:1 over both gradient endpoints.
- Reduced-motion and animations-off preferences; no zoom/elasticity when disabled. Haptics-off preference also disables tap feedback.
- Low-memory and high-density libraries: repeatedly fling genre and artist lists; check frame timing and artwork cache churn.

## Functional regression
- Album: local and online-only, missing cover, NAS/WebDAV/SMB artwork; Play, Shuffle, Like All, Download Missing, Share, More, online toggle and refresh.
- Artist: portrait present/missing, local and online-only, follow/unfollow, Top Songs, artist releases, biography and album navigation.
- Genres: Other, No genre, search filters, category mapping, song counts and playing from the destination page.
- Nested navigator: back stack, bottom bar, mini-player, push from full player, swipe gestures, queue actions and long press.
- Accessibility: screen reader labels, 44-point touch controls, OS reduced motion, large fonts and contrast.

## Scope boundaries
- Navigation uses the global Material route transition builder; bespoke player/queue sheets retain their playback-specific gesture transitions.
- Elastic scroll is applied at the app level to Android and iOS only, with native desktop behaviour and reduced-motion clamping.
- Coloured genre tiles use gradients rather than per-card BackdropFilters to limit raster/cache pressure; existing Lokal glass remains on the action chrome.
- CI/static verification and actual device rendering should be checked independently; source updates are not device validation.
