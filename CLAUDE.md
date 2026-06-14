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
├── HomeExtras.pm                       # Material Skin home-page scrollable row (For You)
├── Settings.pm                        # CSRF-protected, three-section settings page
├── install.xml                        # <extension> format, v0.3.2, icon_svg.png
├── strings.txt                        # All localisation strings (EN)
└── HTML/EN/plugins/ListenBrainzFreshReleases/
    ├── settings.html                  # Three-section settings page (General/For You/All Releases)
    └── html/images/
        ├── ListenBrainzFreshReleasesIcon.png       # black silhouette (Material recolours)
        ├── ListenBrainzFreshReleasesIcon.svg       # black SVG source for Material recolour
        ├── ListenBrainzFreshReleasesIcon_svg.png   # _svg.png trigger for Material menu icon
        └── ListenBrainzFreshReleasesIcon-tile.svg  # colour tile (install.xml <icon>; visible in Manage Plugins)
```

## Current Version
0.5.1

## Settings Structure (v0.3.2)

Three sections in the settings page:

### General Settings
- `username` — ListenBrainz username
- `token` — ListenBrainz API token
- `days` — days window (1-90, default 14)
- `sort` — default sort (release_date / artist_credit_name / release_name / confidence)
- `group_by_artist` — collapse multi-release artists into one tappable entry (default ON)
- `week_dividers` — when sorted by release date, insert a divider per week; takes precedence over group_by_artist for the date sort (default ON)
- `play_via` — show inline playable streaming matches on the detail page (default ON)

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
- `<homepageURL>` points to the GitHub repo so a "more info" link shows in Manage Plugins (NOT `<link>` — that's ignored; Qobuz/Bandcamp use `homepageURL`)
- `<icon>` points to `ListenBrainzFreshReleasesIcon-tile.svg` — a **self-contained colour tile** (orange bg + white art). The old `_svg.png`/black icons are silhouettes meant for Material's recolour step, so they render **blank** in core Manage Plugins; the tile renders visibly there (browser draws the SVG). The browse-menu/app icon still uses the black `_svg.png` via the `ICON` constant in Browse.pm (Material recolours it)

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
- Cover art: `https://coverartarchive.org/release/<caa_release_mbid>/front-250`
  - Requires `caa_release_mbid` (the authoritative "has art" signal); returns undef when absent. Do NOT fall back to `release_mbid` — it's always present, which 404s for art-less releases and defeats the artwork-only filter (fixed in 0.4.4)
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
- Pagination: handled natively by LMS/Material — `_buildItems` returns the whole filtered+sorted list as one level and the client windows/scrolls it (no manual paging; see 0.4.7). Keeps Material's in-list filter working across the full list
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
- **0.4.1** — "Find on streaming services" link on the detail page (`play_via` pref, default ON): lazily fans the "artist album" query out to installed streaming plugins via their registered `Slim::Menu::GlobalSearch` providers, so results are playable through each plugin's own protocol handler. Confirmed on the target server that both Qobuz (v3.7.0) and Bandcamp (v1.12.0) register GlobalSearch providers, so no per-service code is needed. `GlobalSearch->menu($client, {search=>...})` confirmed working by live test.
- **0.4.2** — Play-via now resolves to **direct playable albums** via each service's **own search API** (dropped the GlobalSearch approach — it only produced a search drill-down). Per-service adapters in `_findPlayable` / `_streamingAdapters`:
  - **Qobuz**: `Plugins::Qobuz::Plugin::getAPIHandler($client)->search($cb, lc($query), 'albums')`; results in `$res->{albums}{items}`; each title-matched album is rendered with the plugin's own `Plugins::Qobuz::Plugin::_albumItem($client, $album)` (a `type=>'playlist'` node → playable).
  - **Bandcamp**: `Plugins::Bandcamp::Search::search($client, $cb, {search=>$query})`; keep result items whose `passthrough->[0]{album_id}` is set (already-playable album nodes from `album_list`).
  - Adapter availability is detected with `Plugins::<Svc>::Plugin->can(...)` (safe when absent); the detail link is hidden when no supported service is installed. Async fan-out with a pending-counter barrier; title matching via `_titleMatch`/`_norm` (lowercase, strip bracketed qualifiers + punctuation), so it can occasionally miss/mismatch. Adding a new service = one more adapter sub + `_streamingAdapters` entry.
- **0.5.1** — Better streaming match recall for awkward credits: (1) the service search query is now built from **normalised terms** (`$artistNorm $albumNorm`) so quotes/`&`/commas in multi-artist names don't make the search miss the album (e.g. `Lee "Scratch" Perry & Mouse on Mars`); (2) artist matching switched from bidirectional substring to **token-subset** (`_artistMatch`: every word of the shorter credit must appear in the longer), tolerating word order, `&` vs `,`, and partial credits — while title-contains-album still gates precision. (3) **Home-row icon fix:** the Material home extra now uses the recolourable `_svg.png` icon (as the browse menu does) instead of the install.xml colour tile, which rendered blank in the home row while other plugins showed theirs.
- **0.5.0** — **Material Skin home-page scrollable row** for the For You feed. New `HomeExtras.pm` subclasses `Plugins::MaterialSkin::HomeExtraBase` and registers a home "extra" (`tag => 'LBFForYou'`, `title => PLUGIN_LBF_FOR_YOU`, plugin icon); its feed → `Browse::homeForYou` returns a flat, 50-capped list of release cards (For You filters/sort, no weekly dividers/grouping — unsuited to a carousel). Registered in `Plugin::postinitPlugin`, gated on `MaterialSkin->can('registerHomeExtra')` (mirrors Qobuz/Bandcamp). Also **renamed "For You" → "New Releases for You"** (the `PLUGIN_LBF_FOR_YOU` string drives the browse menu item and the home row; the settings section header `PLUGIN_LBF_SECTION_FORYOU` was renamed to match). Pattern reference: Bandcamp `HomeExtras.pm`. Also added: **README.md** (GitHub docs — features, requirements/ListenBrainz account, defaults, home shelf), an install.xml **`<homepageURL>`** to the repo (shows as the "more info" link in Manage Plugins), and a colour **tile SVG** icon for install.xml so the Manage Plugins icon isn't blank (the existing icons are black silhouettes for Material's recolour and render blank in core Manage Plugins).
- **0.4.9** — The MusicBrainz line on the detail page is now a clickable `weblink` (**View on MusicBrainz**) that opens the release page in the browser, instead of plain text showing the URL. (Same `weblink` mechanism as the top-level Plugin Settings entry.)
- **0.4.8** — **Caching** so revisits don't re-search (uses `Slim::Utils::Cache`, persistent across restarts). Streaming matches keyed by `lbf:stream:<release_mbid>` (TTL 7 days found / 1 day no-match); MusicBrainz tracklist+genres keyed by `lbf:mb:<mbid>` (30 days found / 1 day empty). OPML item `url` coderefs can't be Storable-serialised, so streaming items are cached with `url` stripped + a `_svc` tag and the play coderef is **reattached on read** (`_rebuildStreamItems`: Qobuz→`QobuzGetTracks`, Bandcamp→`get_album`; items whose service is gone are dropped). Note: Qobuz's own API also caches ~5 min internally; this is our durable layer on top. **Barrier fix:** `_releaseDetail` now counts both async tasks (streaming + MB) up front — a cache hit fires its callback *synchronously*, so the old per-task `$pending++` let the barrier complete after the first finished and drop the other's data (symptom: tracklist missing on cached revisits).
- **0.4.7** — Replaced manual drill-in pagination with **native XMLBrowser windowing**: `_buildItems` (and the artist-group drill-in) now return the full filtered+sorted list as one level; LMS/Material window/scroll it. Removed `_paginate`, `PAGE_SIZE`, and the next/prev page strings. Reason: manual pages were separate menu nodes, so Material's in-list search/filter only saw the current page — a single level lets the filter span every item, and gives Material's native scroll + prev/next pager. (Settings filters — artwork/type/VA — were already global, applied in `_filter*` before building items.)
- **0.4.6** — UI polish: (1) fixed mojibake in the week divider — it used a **literal em-dash** in the Perl source (rendered as `â€"`); all non-ASCII must use `\x{}` escapes (as the rest of the file does), decorative dashes dropped; (2) list rows now show **year only** `(YYYY)` instead of the full release date (the week divider carries the date) — matches LMS album-year convention; (3) pagination gained a **Previous page** link (top of page 2+) alongside Next, both using arrow glyphs (`\x{25C0}`/`\x{25B6}`) instead of the plugin logo. NB: pagination is drill-in, so Previous pushes a new level rather than popping — the back button still works; revisit with native XMLBrowser windowing if the stacking becomes annoying.
- **0.4.5** — Streaming match disambiguation: `_albumMatches` (replaces `_titleMatch`) now requires the candidate **title to contain our album title AND the artist to match** (bidirectional substring to tolerate "feat."/credit variants). Fixes wrong-artist results like "Bending Light" pulling in unrelated same-titled albums. Artist is passed through `_findPlayable` → adapters as `$artistNorm`; falls back to title-only when our artist is empty.
- **0.4.4** — Fixes + view options: (1) **sort** is now applied client-side in `_sortReleases` — release date is **newest-first** (the API returned oldest-first), confidence highest-first, artist/album A–Z; (2) **weekly dividers** (`week_dividers`, default ON) add a "— Week of D Mon YYYY —" divider per week in the date-sorted view (`_buildWeekly`/`_weekStart`, Monday-based, via `Time::Local`), taking precedence over group-by-artist for the date sort; (3) top-level menu now has a **Plugin Settings** entry (`weblink` to settings.html) → For You / All Releases / Plugin Settings; (4) **artwork-only filter fix** — `coverArtUrl` now requires `caa_release_mbid` (it used to fall back to the always-present `release_mbid`, so the filter never excluded art-less releases and thumbnails 404'd).
- **0.4.3** — Streaming matches are now shown **inline on the detail page** (no "Find on streaming services" tap): `_releaseDetail` runs the streaming search and the MusicBrainz lookup in parallel and merges both into one callback (base meta → streaming matches → genres → tracklist). Each result uses the **service's own logo** as its thumbnail (`_pluginIcon` → `_pluginDataFor('icon')`) so the source is obvious; dropped the `"Svc:"` name prefix. Trade-off: the detail page now waits on the streaming search(es) before rendering, so it can be a touch slower (Bandcamp scraping is the slowest).
