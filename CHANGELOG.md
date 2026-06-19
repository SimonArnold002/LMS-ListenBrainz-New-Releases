# Changelog

All notable changes to **ListenBrainz Fresh Releases** are listed here.
Versions follow `MAJOR.MINOR.PATCH`.

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
