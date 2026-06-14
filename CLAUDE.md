# ListenBrainz Fresh Releases — LMS Plugin

## Project Overview
A plugin for Lyrion Music Server (LMS) that browses ListenBrainz Fresh Releases. It provides a personalised "For You" feed and a global "All Releases" feed. Filtering is controlled via settings, and the browse menu stays intentionally simple. The current build targets LMS v9.x and has been tested with Material Skin.

## Server Details
- **LMS Server**: 192.168.1.234:9000
- **OS**: DietPi (Debian Bookworm)
- **Service**: `lyrionmusicserver`
- **Plugin location (manual install)**: `/var/lib/squeezeboxserver/Plugins/ListenBrainzFreshReleases/`
- **Plugin location (repo install)**: `/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/ListenBrainzFreshReleases/`
- **Log**: `/var/log/squeezeboxserver/server.log`
- **Material Skin**: `/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/MaterialSkin/` (moved from manual to repo install)

## Install Commands
```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/ListenBrainzFreshReleases
sudo unzip ListenBrainzFreshReleases.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/ListenBrainzFreshReleases
sudo systemctl restart lyrionmusicserver

# Check logs
grep -i "listenbrainz" /var/log/squeezeboxserver/server.log | grep -v "Artwork\|50x50" | tail -20
```

## File Structure
```
ListenBrainzFreshReleases/
├── Plugin.pm                          # OPMLBased entry point, image proxy registration
├── Browse.pm                          # Simple two-option feed (For You / All Releases), no in-menu filters
├── API.pm                             # Async ListenBrainz HTTP, payload.releases parsing
├── Settings.pm                        # CSRF-protected, three-section settings page
├── install.xml                        # <extension> format, v0.3.2, icon_svg.png
├── strings.txt                        # All localisation strings (EN)
└── HTML/EN/plugins/ListenBrainzFreshReleases/
    ├── settings.html                  # Three-section settings page (General/For You/All Releases)
    └── html/images/
        ├── ListenBrainzFreshReleasesIcon.png
        ├── ListenBrainzFreshReleasesIcon.svg
        └── ListenBrainzFreshReleasesIcon_svg.png
```

## Current Version
0.4.1

## Settings Structure (v0.3.2)

Three sections in the settings page:

### General Settings
- `username` — ListenBrainz username
- `token` — ListenBrainz API token
- `days` — days window (1-90, default 14)
- `sort` — default sort (release_date / artist_credit_name / release_name / confidence)
- `group_by_artist` — collapse multi-release artists into one tappable entry (default ON)
- `play_via` — show a "Find on streaming services" link on the detail page (default ON)

### For You Settings
- `foryou_albums` — albums-only filter (default ON)
- `foryou_past` — include past releases (default ON)
- `foryou_future` — include upcoming releases (default OFF)
- `foryou_artwork_only` — hide releases without artwork (default ON)
- `foryou_various` — include Various Artists releases (default ON)

### All Releases Settings
- `all_past` — include past releases (default ON)
- `all_future` — include upcoming releases (default OFF)
- `all_artwork_only` — hide releases without artwork (default ON)
- `all_various` — include Various Artists releases (default ON)
- Type checkboxes — default ON: Album, Compilation, Soundtrack. Default OFF: Single, EP, Broadcast, Other, Live, Remix, Demo
- All types stored as `all_type_<name>` prefs

## Browse Menu (v0.3.2)

```
ListenBrainz Fresh Releases
├── For You (requires username + token)  ← filtered by For You prefs
└── All Releases                          ← filtered by All Releases prefs
```

No in-menu filter sub-menus. All filtering driven entirely by settings prefs.

## Key Technical Decisions

### Plugin Base Class
- Uses `Slim::Plugin::OPMLBased` — correct base for browsable content plugins
- `is_app => 1` puts it in the **Apps** section of Material Skin
- `menu => 'radios'` required by OPMLBased even when is_app is set

### Settings Registration
- Uses `Slim::Web::HTTP::CSRF->protectName()` and `->protectURI()` — required for settings to appear in Material Skin's settings menu
- `Settings->new()` called inside `if (main::WEBUI)` **before** `$class->SUPER::initPlugin()`
- `Browse` and `API` modules explicitly `require`d in `initPlugin` before `SUPER::initPlugin`
- Settings template uses LMS TT2 format: `[% PROCESS settings/header.html %]`, `[% WRAPPER setting %]`, `[% PROCESS settings/footer.html %]`
- Prefs accessed in template as `[% prefs.username %]` (not `pref_username`) — the base handler populates these automatically

### install.xml Format
- Uses `<extension>` (singular) root element — matches manually installed plugins like NowPlayingShare
- `<extensions>` (plural) format is for repo-installed plugins — DO NOT use for manual plugins
- `<optionsURL>` points to `plugins/ListenBrainzFreshReleases/settings.html`
- `<icon>` points to `ListenBrainzFreshReleasesIcon_svg.png` (the `_svg.png` form, NOT plain `.svg`)

### Icon System (Material Skin)
- Per Material Skin docs: `_svg.png` suffix tells Material to find and use the matching `.svg` file
- SVG must have all fills/strokes set to `#000` — Material replaces with theme colour
- SVG size: 24x24px with 2px border minimum
- Three icon files required:
  - `ListenBrainzFreshReleasesIcon.png` — fallback PNG
  - `ListenBrainzFreshReleasesIcon_svg.png` — SVG content as PNG, triggers Material's icon mapping
  - `ListenBrainzFreshReleasesIcon.svg` — actual SVG source with `fill="#000"`

### Image Proxy Caching
- Registered via `Slim::Web::ImageProxy->registerHandler` matching `coverartarchive\.org`
- Only active when LMS server pref `useLocalImageproxy` is enabled
- LMS caches CAA images locally, avoids repeated external fetches

### API
- Personalised feed: `GET /1/user/<username>/fresh_releases` (requires token)
- Global feed: `GET /1/explore/fresh-releases/`
- Response structure: `payload.releases` (NOT `payload.fresh_releases`)
- Cover art: `https://coverartarchive.org/release/<mbid>/front-250`
  - Uses `caa_release_mbid` first, falls back to `release_mbid`
- Token validation: `GET /1/validate-token?token=<t>`
- No hard cap is applied to the API payload; filtering runs on the full result set so artwork and type filters can behave correctly
- Release detail enrichment: `GET https://musicbrainz.org/ws/2/release/<mbid>?inc=recordings+genres&fmt=json`
  - Fetched on-demand when a release is opened (one at a time, so the anonymous MusicBrainz 1 req/sec limit is fine)
  - Requires a descriptive `User-Agent` (set in `API::USER_AGENT`) or MusicBrainz returns 403
  - `API::getReleaseDetails` returns `{ genres => [names], media => [{ position, format, tracks => [{position,title,length}] }] }`
  - Detail page degrades gracefully to base metadata if the lookup fails

### Display / New Music Tracker–inspired presentation
- Release detail page shows base metadata, then genres and a per-disc tracklist (m:ss durations) pulled from MusicBrainz
- `group_by_artist` (default ON): artists with one new release stay inline; artists with several collapse into an `Artist  (N)` entry that expands to their releases
- Pagination (`_paginate`, PAGE_SIZE 50) is generic — it windows whichever item list it's given (flat, grouped top-level, or an artist's expanded releases) with a `Next page (n/total)` link
- Not ported from New Music Tracker (needs a web-app backend the OPML plugin doesn't have): OAuth login, artist following, wishlists, genre/style *filtering*, listener/popularity counts

### Release Type Filtering
- The API does NOT support release type as a query parameter
- Filtering is done client-side in Browse.pm after receiving results
- Matches against both `release_group_primary_type` and `release_group_secondary_types`
- MusicBrainz primary types: Album, Single, EP, Broadcast, Other
- MusicBrainz secondary types tracked: Compilation, Soundtrack, Spokenword, Interview, Audiobook, Audio drama, Live, Remix, Mixtape/Street, Demo
- For You section uses `foryou_albums` (boolean, albums-only when ON)
- All Releases section uses individual `all_type_<name>` checkboxes
- Browse item rendering now uses the actual API title/type fields so All Releases shows the real release title and type rather than falling back to a generic album label

### Various Artists Detection
Detected in `_isVariousArtists()`:
- Artist credit name matches "various artists" (case insensitive)
- OR `artist_mbids` contains the VA MBID `89ad4ac3-39f7-470e-963a-56509c546377`

### Prefs Namespace
`plugin.listenbrainzfreshreleases` — used consistently across all modules

## Known Issues / Notes
- Log level set to INFO in Plugin.pm and API.pm for debugging — can be changed to WARN for production
- `<extensions>` vs `<extension>` in install.xml matters — manually installed plugins must use `<extension>` singular
- File ownership must be `squeezeboxserver:nogroup` on DietPi — NOT `squeezeboxserver:squeezeboxserver`
- The zip must extract directly as `ListenBrainzFreshReleases/` with no extra `Plugins/` wrapper for manual installs
- Material Skin's grouped artist release page layout is NOT achievable from OPML feeds — only via native library `albums_loop` responses. Solved in earlier versions by using Browse by Type sub-menus, removed in v0.3.0 in favour of settings-driven filtering.

## Version History
- 0.0.x — Initial development, plugin loading fixes, API parsing fix
- 0.1.0 — PNG icon
- 0.1.1 — Lyrion-spec icons
- 0.1.2 — Image proxy caching, Browse by Type
- 0.1.3 — Full MusicBrainz type support, removed Release Type filter
- 0.1.4 — Past/Future toggles in top-level menu (later removed due to odd behaviour)
- 0.1.5 — Moved past/future to settings
- 0.1.6 — Icons restored on menu items, settings link added (later removed as broken)
- 0.1.7 — Material Skin release type icons for Browse by Type
- 0.1.8 — Removed broken settings link
- 0.1.9 — install.xml icon switched to .svg
- 0.2.0 — future default to 0, filter out releases without artwork
- 0.2.1 — install.xml icon reverted back to _svg.png
- **0.3.0** — Full restructure: three settings sections, simplified browse menu (no in-menu filters), per-section prefs (For You vs All Releases), Various Artists toggle, comprehensive type checkboxes with Album/Compilation/Soundtrack defaults
- **0.3.1** — Repository metadata and package version alignment; filtering now evaluates the full API response payload
- **0.3.2** — All Releases items now display the actual release title and release type from the ListenBrainz payload
- **0.3.3** — Both feeds paginate in pages of 50 via a "Next page (n/total)" link; the filtered list is captured in-closure so paging never re-hits the API, and the LMS back button returns to the previous page
- **0.4.0** — New Music Tracker–inspired presentation: release detail page now fetches genres + per-disc tracklist (durations) from MusicBrainz on demand (graceful fallback on failure); shows folksonomy tags carried in the fresh_releases payload (cleaned/deduped, no extra call); optional group-by-artist layout (default ON) collapsing multi-release artists; pagination generalised to window any item list. NB: a data probe found MusicBrainz/ListenBrainz genre coverage on fresh releases is ~8–9% (too sparse for genre *filtering* without Discogs), so only on-demand genre/tag *display* was added.
- **0.4.1** — "Find on streaming services" link on the detail page (`play_via` pref, default ON): lazily fans the "artist album" query out to installed streaming plugins via their registered `Slim::Menu::GlobalSearch` providers, so results are playable through each plugin's own protocol handler. Confirmed on the target server that both Qobuz (v3.7.0) and Bandcamp (v1.12.0) register GlobalSearch providers, so no per-service code is needed. The `GlobalSearch->menu($client, {search=>...})` call is eval-guarded; exact contract to be confirmed by live test.
