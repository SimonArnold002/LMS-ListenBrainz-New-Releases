# Changelog

All notable changes to **ListenBrainz Fresh Releases** are listed here.
Versions follow `MAJOR.MINOR.PATCH`.

## 0.8.24 (dev)

### Changed
- **Settings section headers now match the rest of the plugin.** The four settings sections (General / Streaming Services / For You / All Releases) used raw `<h2>` tags, which Material Skin doesn't theme, so they looked out of place. Each is now a proper Material settings section: a `prefHead collapsableSection` header (`id="lbf_<section>_Header"`) with the section's settings wrapped in a matching `<div id="lbf_<section>">` panel. Material renders these as its themed bold accent-bar headers — consistent with the section dividers on the browse pages — and they collapse/expand like the native LMS settings sections (a bare `prefHead` only gets Material's faint per-setting label style, so the panel + `_Header` id is what makes the accent header and the expander appear).

## 0.8.22 (dev)

### Internal
- Removed 6 unused localisation strings left over from earlier features (`PLUGIN_LBF_FORYOU_ALBUMS`/`_DESC`, `PLUGIN_LBF_PLAYLISTS_DESC`, `PLUGIN_LBF_PL_TRACKS`, `PLUGIN_LBF_SEC_TYPES`, `PLUGIN_LBF_WEEK_OF`). No user-visible change.

## 0.8.21 (dev)

### Fixed
- **Playlist dates now use local time, not UTC.** ListenBrainz sends a playlist's `last_modified` as a UTC instant; the "W/C …" and Daily-Jams date labels derived from it now convert that to the server's local calendar date, so they match the user's day instead of being a day (or week) off near midnight — notably in the UK during BST. The week helpers were also moved from `timegm`/`gmtime` to `timelocal`/`localtime` so the whole date path is consistently local (behaviour-preserving for the date-only release feed; `timegm` is now used only where the input is explicitly UTC).

## 0.8.20 (dev)

### Added
- **Inline check for the Last.fm API key**, matching the ListenBrainz token check. The settings page validates the key client-side against Last.fm's `auth.getToken` (Last.fm allows CORS) and shows the result inline next to the field — on page open (if a key is set), on field blur, and via a "Check key" button. Green = valid, red = rejected, amber = couldn't reach Last.fm; an empty key shows a neutral "optional" note.

## 0.8.19 (dev)

### Fixed
- **A partial settings save can no longer disable a streaming service.** The service-priority handler used to force any missing `svc_priority_*` field to 0 (= never search). On a normal full-form save every field is present so this was harmless, but an incomplete/non-form POST would silently zero the priorities. It now keeps the current saved value when a field is absent, so priorities are only changed when actually submitted.

## 0.8.18 (dev)

### Fixed
- **Token validation result is now actually visible in Material Skin.** 0.8.17 validated the token on save and returned the result via LMS's `warning` field, but Material loads plugin settings in an iframe and never surfaces that field, so the message was invisible (it worked only in the classic web UI). The settings page now also checks the token **client-side** — directly from the browser against `/1/validate-token` (ListenBrainz allows CORS) — and shows the result inline next to the token field: on page open (if a token is set), when the field loses focus, and via a "Check token" button. Green = valid (with your username), red = rejected, amber = couldn't reach ListenBrainz. The server-side on-save validation from 0.8.17 is kept for the classic skin.

## 0.8.17 (dev)

### Added
- **The ListenBrainz token is now validated on save.** Saving the settings with a token set checks it against `/1/validate-token` and shows the result on the page — success (with your username), a rejection message if the token is wrong, or a "couldn't reach ListenBrainz" note if the check itself failed (the settings are still saved). Previously a wrong token failed silently with no feedback. (Wires up the existing, previously-unused `API::validateToken`.)

## 0.8.16 (dev)

### Fixed
- **Settings validation is no longer bypassed.** The Days window (1–90) and the streaming-service priorities (0–9) are now clamped into the submitted form values *before* the base settings handler stores them. Previously the handler set the clamped pref and then the base class immediately re-set it from the raw posted value, so an out-of-range or non-numeric `days` / priority could be persisted from a crafted or non-browser POST.
- **A bad HTTP 200 from ListenBrainz no longer blanks the feed for a day.** If a feed response parsed as JSON but had an unexpected shape (or didn't parse at all), the empty result was cached under both the working (24h) and fallback (30d) keys, blanking the menu/home rows until it expired. Such responses are now treated like a transport error: the last good cached copy is served and nothing is overwritten.

### Internal
- Default log level lowered to WARN (was INFO) so production `server.log` isn't filled with per-request response/cache lines; raise it via Settings → Logging when diagnosing.
- The release-detail cache write is now `eval`-guarded like every other cache write, and the unused genre parse on the recordings-only release lookup was removed (genres come from the release-group path).

## 0.8.15 (dev)

### Fixed
- **Playlists tile no longer disappears.** 0.8.14 left the Playlists menu row with an empty name until the covered-date span had been fetched, and Material drops a row with no title — so the tile vanished. It now always shows a date span: the real one once the playlist list is known, otherwise a synchronously-computed fallback (last week's Monday → today, matching how New Releases for You / All Releases compute theirs), so the row is always present.

## 0.8.14 (dev)

### Changed
- **Playlist tiles drop the repeated title.** The branded cover already shows the playlist name, so the row's first line is now the period it covers — `W/C 8 June 2026` for the weekly playlists, or the day for Daily Jams — with the match count (`47 of 50 tracks matched`) on the line beneath it (was: title on line 1, date + count combined on line 2).
- **Playlists menu tile drops the repeated "Playlists" text.** The main-page Playlists row now shows the date span the playlists inside cover (earliest week-commencing / day → today) instead of the word "Playlists" (which is already on the thumbnail); no text until that span is known (after the first playlist-list fetch / background warm).

## 0.8.13 (dev)

### Changed
- **Top-level tiles show dates + counts, not a repeated title.** The New Releases for You and All Releases rows no longer repeat their title as text under the thumbnail (it's already on the branded cover). Instead the subtitle is the date span actually being viewed — the real earliest/latest release date of the loaded feed, or the window implied by the *Days window* / past / future settings before it loads — plus the release count (e.g. `8 – 20 June 2026` · `42 releases`). Updates automatically when the *Days window* changes. Counts/spans are stashed by the feed builders (`_stashSummary`) so the tiles render instantly without an extra fetch.
- **All Releases Material home shelf now shows the flattened first level** — the "All releases" entry plus the weeks available (This/Last/Earlier) — rather than drilling into the full (large) release list, so the carousel is a jump-off into a section. (The shelf is a small fixed list, so it stays drill-stable at any request quantity.)
- **Simplified row text.** All Releases week rows now read `W/C 8 June 2026` (Week Commencing; the count is dropped). Playlist tiles now read `W/C 8 June 2026 · 47 of 50 tracks matched` for the weekly playlists (or the day itself for Daily Jams), derived from the playlist's generation date; the match count comes from the pre-resolved cache. Dates use full month names, no abbreviations.

### Fixed
- **Playlist cover pills now align.** The This Week / Last Week pill sits at a fixed vertical position regardless of whether the title is one line (Weekly Jams) or two (Weekly Exploration) — the title block is centred in the area above the pill, and the pill + LISTENBRAINZ wordmark no longer shift.

### Internal
- **All branded cover/badge images are now generated by one committed script, `tools/make_covers.py`** (previously only ad-hoc), covering the menu tiles, playlist tiles and All Releases week badges from one shared design system — so the set is reproducible and consistent if it ever needs changing. Documented in CLAUDE.md.

## 0.8.12 (dev)

### Added
- **Material home shelves for Playlists and All Releases** — alongside the existing New Releases for You shelf, the Material home page now has scrollable rows for your Created-for-You Playlists and for All Releases. Each is a flat, playable card row.

## 0.8.11 (dev)

### Changed
- **All Releases week rows now use the playlist-style cover** with a relative-week badge (This Week / Last Week / Earlier). The exact date remains in the row label (literal dates can't be drawn onto the image without a server-side image library, so the badge is relative).

## 0.8.10 (dev)

### Changed
- **Polished icons inside All Releases** — the "All releases" entry and each per-week row now use the branded All Releases cover instead of the plain plugin icon, matching the main page and Playlists.
- **Refresh row uses a Material refresh icon** (circular arrow) instead of the plugin icon.

## 0.8.9 (dev)

### Changed
- **Feeds now refresh once a day** (was every 6 hours) — New Releases for You and All Releases. Less API traffic; the data only changes ~daily anyway.

### Added
- **Manual "Refresh" row** at the top of New Releases for You and All Releases — forces an immediate update (clears that feed's cache and reloads) when you don't want to wait for the daily refresh.

## 0.8.8 (dev)

### Fixed
- **Local-library matching now actually applies** — playlists resolved before the library feature existed were cached (streaming-only) and kept being served, so local files were never substituted. The track and resolved-playlist caches are versioned so they re-resolve once, now checking your library first.

## 0.8.7 (dev)

### Added
- **Prefer tracks from your own library** — when building a playlist, the plugin now checks your local LMS library first (by MusicBrainz ID, then artist + title) and uses your own copy if you have it, before searching streaming services. Faster, free, and uses your preferred quality. New setting **Prefer Tracks from My Library** (default on).

## 0.8.6 (dev)

### Changed
- **Top-level menu reorganised with Material section headers** — the plugin menu is now grouped under **Created for You** (New Releases for You + Playlists), **All Releases**, and **Settings**.
- **Branded menu artwork** — New Releases for You, Playlists and All Releases use cover-style images matching the playlist look; Plugin Settings uses a Material cog.
- **Weekly cover badge aligned** — the This Week/Last Week pill now sits at the same position on the one-line (Weekly Jams) and two-line (Weekly Exploration) covers.

## 0.8.5 (dev)

### Changed
- **Weekly playlist covers now show the week** — the two Weekly Jams (and two Weekly Exploration) playlists no longer look identical: the current week shows a "This Week" badge and the previous week a "Last Week" badge on the cover. (The exact date stays in the row title.)

## 0.8.4 (dev)

### Changed
- **Playlist covers are now per-category artwork** — since a true 2×2 track-art grid can only be stitched with a server-side image library (GD/Imager/ImageMagick), none of which are present and which we won't require (cross-platform, no installs), each playlist now shows a clean bundled cover for its category (Weekly Jams / Weekly Exploration / Daily Jams / generic). These are instant and stable — no more single-cover redirect or the artwork vanishing/repopulating when you return to the list. The dynamic grid compositor was removed.

## 0.8.3 (dev)

### Added
- **Background pre-caching (warm)** — shortly after startup and then once a day, the plugin pre-fetches the playlist list, pre-resolves every playlist's streaming matches, and pre-builds the grid covers. Opening the Playlists view and any individual playlist is now **instant** (no waiting for ~50 tracks to match on open), and the tile artwork is already cached so it no longer **vanishes/repopulates** when you return to the list. The daily run is cheap — it only does real work when a new week's playlist appears.
- **Grid compositing fallback to ImageMagick** — if Perl GD/Imager aren't installed, the 2×2 cover is now built via the `montage` binary (ImageMagick is commonly present), so the tiled grid can render with no Perl-module install. (Still falls back to a single cover if none of GD/Imager/ImageMagick is available.)

## 0.8.2 (dev)

### Changed
- **Playlist rows are now playable containers** — each playlist in the Playlists list carries Play / Add actions (queue the whole resolved playlist) as well as tapping to open it, like a native playlist row.
- **Grid covers need an image library** — the 2×2 tiled cover is composited server-side and requires Perl **GD** (or **Imager**), which this LMS build doesn't include. Install one (Debian: `sudo apt-get install -y libgd-perl`) to get the tiled grid; without it, the tile falls back to a single cover.

## 0.8.1 (dev)

### Fixed
- **Playlists now play like a playlist** — the resolved track list is a clean list of playable tracks only, so the standard Play / Play-all option is available. The "N of M matched" line (an unplayable row that was suppressing play-all) is gone; the match count is shown in the page title instead.
- **Playlist grid covers now render** — the cover route is registered with the current LMS API and its request path is matched correctly (leading-slash fix), and the image response now sends headers. Playlist thumbnails show the 2×2 grid (or fall back to a single cover).

## 0.8.0 (dev)

### Added
- **Playlists section — your ListenBrainz "Created for You" playlists, as streaming playlists.** A new **Playlists** entry lists the algorithmic playlists ListenBrainz builds for you (Weekly Jams, Weekly Exploration, Daily Jams, …). Opening one matches **every track** to a playable version on your streaming services (in your configured priority order), drops any track that can't be matched, and presents the result as a fully-streaming playlist you can **Play all**. A *"N of M tracks matched"* line shows how many resolved. Each playlist shows a **2×2 grid cover** stitched from its tracks' artwork (Qobuz/Spotify style). (Track matching currently resolves on Qobuz; Tidal/Bandcamp track support is scaffolded and finished once their track APIs are confirmed on the server.)
- **Caching tuned to the weekly update cadence** — these playlists only regenerate weekly (and ListenBrainz keeps the current *and* previous week), so a resolved playlist is cached for 30 days instead of being re-matched daily. Reopening a playlist — including last week's — is instant rather than re-running ~50 streaming searches each time. The playlist *list* refreshes once a day (enough to catch Monday's new playlists) instead of every few hours.

## 0.7.2 (dev)

### Added
- **All Releases → by-week landing page** — tapping **All Releases** now opens a menu instead of dropping straight into the full list. The first entry, **All releases**, shows the complete list as before; below it is one entry per week-commencing (newest first, e.g. *Week of 16 Jun 2026  (42)*) that drills into just that week's releases. Lets you narrow the feed to a single week without scrolling the whole thing.

## 0.7.1 (dev)

### Fixed
- **Non-Latin artist names → wrong streaming matches** — albums by artists with Japanese/Korean/Chinese (etc.) names (e.g. *踊ってばかりの国 – PRISM*) were matching lots of unrelated streaming albums that merely shared the title ("Prism"). The artist name was being stripped to nothing before matching, so there was no artist left to tell the right album from the wrong ones. Those names are now preserved, so the artist is used to reject unrelated results. (Stale wrong matches clear automatically — no manual refresh needed.)

## 0.6.15

### Fixed
- **Detail page blank for non-Latin titles** — opening a release whose title contains Japanese/Korean/Chinese characters, emoji, etc. showed no data when a Last.fm API key was configured. Those characters crashed the Last.fm cache lookup (and aborted the whole request); the lookup now handles them correctly.

## 0.6.12

### Changed
- **Grid view in Material** — the week-divider headers now carry the plugin icon, which keeps Material's grid/list view toggle available on the For You and All Releases lists (an icon-less header otherwise disabled it).

## 0.6.11

### Fixed
- **Streaming playback from the Material home shelf** — tapping play on a Qobuz/Bandcamp link now works. The home-page week-divider feature had made the feed's structure change with the request size, which broke the play command's item lookup.

### Changed
- The Material home shelf and its "show all" view are a flat card list again (no week dividers) — required to keep home-shelf playback working. Week dividers remain in the For You and All Releases menus.

## 0.6.10

### Fixed
- **Streaming links — wrong-album matches:** the album title now has to *be* the match or *start* with it, instead of just appearing somewhere in the candidate's title. Stops cases like "Apollo" by Gene wrongly matching "Friendship 7 To Apollo 11…".
- **Streaming links — duplicates:** identical entries from the same service are collapsed (e.g. Bandcamp sometimes returns the same album twice). Genuinely different editions (Hi-Res vs standard) are still shown.

## 0.6.8

A big update focused on genres, filtering, Material Skin polish, and reliability.

### New
- **Genres in the list** — where ListenBrainz provides tags, up to three now show next to each album title.
- **Genre fallback via Last.fm (optional)** — brand-new releases often aren't tagged in MusicBrainz yet. Add a free Last.fm API key in the plugin settings and the detail page fills in genres from Last.fm (album tags, falling back to the artist's). Leave it blank to keep it off.
- **"New Releases for You" filters** — this section now has the same per-release-type checkboxes as All Releases.
- **Weekly headers in Material** — per-week dividers render as proper bold section headers; tap a week to view just that week's releases.
- **Home-shelf click-in** — opening the Material home row in full now shows the same weekly dividers as the menu.

### Improved
- **Much smoother / faster** — the ListenBrainz feeds are now cached (6 hours), so the home screen and menus load instantly instead of re-fetching every time.
- **Better defaults** — release types now default to **Album + Compilation** (Soundtrack is no longer on by default).
- **Tidier settings page** — the sort option is now a simple list instead of a drop-down that overlapped the other settings.
- **No more duplicate albums** — releases that ListenBrainz/MusicBrainz occasionally list twice are now collapsed into one.

### Fixed
- The plugin icon now displays correctly in Material and in Manage Plugins (was showing blank/black).
- Live and soundtrack albums no longer slip past the filters.
- The Material home page no longer hangs / fails to load its scrollable lists (caused by the old feed over-fetching and getting rate-limited).

> **Updating:** the new defaults only apply to fresh settings. If you'd previously left Soundtrack ticked under All Releases, untick it once if you don't want soundtracks.

## 0.5.2
- Reliability hardening: detail pages no longer hang if a streaming or MusicBrainz lookup stalls, safer caching, and the "View on MusicBrainz" link is validated before use.

## 0.5.1
- Better streaming-match accuracy for awkward multi-artist album credits.
- Fixed the missing plugin logo on the Material home row.

## 0.5.0
- Added the optional **New Releases for You** scrollable row on the Material Skin home screen.
- Renamed the personalised feed to **New Releases for You**.
- Added README documentation, a repository "more info" link, and a visible Manage Plugins icon.
