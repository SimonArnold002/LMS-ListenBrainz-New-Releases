# Changelog

All notable changes to **ListenBrainz Fresh Releases** are listed here.
Versions follow `MAJOR.MINOR.PATCH`.

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
