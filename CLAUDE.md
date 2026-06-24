# ListenBrainz Fresh Releases — LMS Plugin

## Project Overview
A plugin for Lyrion Music Server (LMS) that browses ListenBrainz Fresh Releases. It provides a personalised "For You" feed and a global "All Releases" feed. Filtering is controlled via settings, and the browse menu stays intentionally simple. The current build targets LMS v9.x and has been tested with Material Skin.

## Feature Summary & Release Posts (social media)

**Maintain this section.** Two living artefacts for announcing the plugin:
1. **Overall feature summary** (below) — the social-media / GitHub Pages "drop page" copy. **Update it whenever a key feature is added, changed or removed** (not for bug fixes). Keep it key-features-only, user-facing, no internals.
2. **Per-release post** — when cutting a release, generate a short social post from the new **CHANGELOG.md** entries since the last main release: lead with new **features**, then a short "Fixes & polish" line for the notable bug fixes. Install line is the Pages repo URL. Hashtags: `#LyrionMusicServer #ListenBrainz #Squeezebox #SelfHosted`.

### Overall feature summary (keep current)

> **ListenBrainz Fresh Releases — for Lyrion Music Server.** Turn your ListenBrainz listening into a living, playable music feed inside LMS.

- **New Releases for You** — personalised feed of fresh releases from artists in your ListenBrainz history (needs username + token). Newest-first, grouped by week, tap-through detail pages.
- **All Releases** — the global ListenBrainz fresh-releases feed (no account). By-week landing page to jump to any week.
- **Created-for-You Playlists** — your **Weekly Jams / Weekly Exploration / Daily Jams** as fully-streaming **Play-all** lists; every track matched **library-first**, then streaming.
- **Don't Stop The Music — two auto-DJ mixers** — **ListenBrainz Radio** (seeds from what's playing and evolves through similar artists) + **Recommended for You** (personalised CF picks, shuffled). Owned copies first, no per-session repeats, varied artists.
- **Rich release detail pages** — artist **photo + biography**, **tracklist** with durations, **genres**, tags, **View on MusicBrainz**, and inline **one-tap streaming matches**.
- **Direct streaming playback** — matched albums/tracks play from **Qobuz / Tidal / Bandcamp**; you choose the per-service search order.
- **Block artists** — one tap hides an artist from every feed.
- **Material home shelves** — optional New Releases for You / Playlists / All Releases home rows.
- **Your taste** — filter by type / artwork-only / Various Artists; sort by date / artist / album / confidence; release-window, weekly dividers, group-by-artist. Cached & pre-warmed (instant), **no extra server software**.

**Requirements:** LMS 9.0.0+ (Material Skin); ListenBrainz account + token for personalised features (All Releases needs nothing); optional Qobuz/Tidal/Bandcamp (playback), MAI plugin (artist photos+bios), free Last.fm key (genre/bio fallbacks). Every optional add-on degrades gracefully.

**Install:** add `https://simonarnold002.github.io/LMS-ListenBrainz-New-Releases/repo.xml` in LMS → Settings → Plugins.

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
├── Plugin.pm                          # OPMLBased entry point; image-proxy + home-extra registration; schedules the background warm
├── Browse.pm                          # ALL browse feeds: top-level sections, For You / All Releases (+ by-week landing), Created-for-You Playlists (streaming + local-library track matching), the Material home-shelf feeds, branded tiles
├── API.pm                             # Async ListenBrainz HTTP: fresh_releases + createdfor/playlist endpoints, feed caching, MusicBrainz/Last.fm enrichment
├── HomeExtras.pm                      # Material home-page shelves — three HomeExtraBase subclasses (New Releases for You / Playlists / All Releases)
├── DSTM.pm                            # Don't Stop The Music propagators — 2 mixers: Radio (seeds from last-played artist → similar-artists → top-recordings, evolves) + Recommended (CF pool); streaming-first resolution via Browse::_resolveTracks
├── Settings.pm                        # CSRF-protected settings page (General / Streaming Services / For You / All Releases)
├── install.xml                        # <extension> format, icon_svg.png (version in <version>)
├── strings.txt                        # All localisation strings (EN)
└── HTML/EN/plugins/ListenBrainzFreshReleases/
    ├── settings.html                  # Settings page (General / Streaming Services / For You / All Releases)
    └── html/images/
        ├── ListenBrainzFreshReleasesIcon.{svg,_svg.png,.png}  # app icon — see "Icon System" (svg = #000 source, _svg.png = install.xml ref/fallback, .png = generic)
        ├── menu-*.png / playlist-*.png / allrel-*.png         # branded covers + week badges (generated by tools/make_covers.py)
        └── lbf-*_MTL_icon_*.png                               # Material font-icon convention (settings cog / feed refresh)

tools/
├── make_covers.py                     # Pillow generator for ALL branded covers/badges (see "Branded cover images")
└── make_readme_html.py                # Zero-dep Markdown→HTML generator: README.md → README.html (styled) + index.html (Pages redirect)
```

## Project docs / GitHub Pages

`README.md` is the source of truth for user docs. `README.html` is a **generated**, styled,
self-contained HTML version (ListenBrainz brand palette, hero with Download/Installation buttons,
the "Features at a glance" table rendered as a card grid, every other table styled). It is built by
`tools/make_readme_html.py` (stdlib only — a focused converter for the Markdown subset README.md
uses). The hero's **version badge is read live from `install.xml`** (`read_version`), so a regen
always reflects the current release — bump the version, then re-run the script. `index.html` (the
GitHub Pages landing, served from the repo root) is emitted by the same
script as a `<meta refresh>` redirect to `README.html`. **Don't hand-edit `README.html`/`index.html`**
— edit `README.md`, then re-run `python3 tools/make_readme_html.py`. These are repo docs only, NOT
part of the plugin zip, so no zip rebuild / sha bump is needed when they change.

## Current Version
0.9.39

## Created-for-You Playlists (0.8.0)

New **Playlists** browse section (`Browse::fetchPlaylists` → `resolvePlaylist`), gated on
`username` being set. Surfaces the ListenBrainz algorithmic playlists and turns each into a
fully-streaming, Play-all-able playlist.

- **API** (`API.pm`): `getCreatedForPlaylists` → `GET /1/user/<user>/playlists/createdfor`
  (no token needed to read; sent if present), parsed by `_parsePlaylistList` into
  `{ mbid, title, annotation, source_patch, last_modified }` (mbid from the `…/playlist/<mbid>`
  identifier). `getPlaylistTracks($mbid,$lastMod,…)` → `GET /1/playlist/<mbid>`, parsed by
  `_parsePlaylistTracks` into `{ title, artist(=creator), album, duration_ms, recording_mbid,
  caa_id, caa_release_mbid }`. The createdfor *listing* has empty `track` arrays and no track
  count — count is only known after fetching the playlist. Playlist-list cache mirrors the
  feed's dual short/fallback TTL; track cache is immutable-per-`last_modified` (30d/1d).
  `coverArtUrl` now accepts a bare `caa_release_mbid` string too (playlist tracks carry it).
- **Track matching** (`Browse.pm`): `_findPlayableTrack` is the track-level analogue of
  `_findPlayable` — same ordered-adapter / per-service-timeout / first-priority-wins /
  versioned-cache shape, but returns ONE item and **only accepts a match with a plain string
  protocol url** (e.g. `qobuz://<id>.flac`). That rule keeps the resolved playlist fully
  Storable AND quantity-stable (the 0.6.11 home-shelf lesson — a coderef url would be stripped
  on cache and the item would vanish on revisit, shifting item_ids and breaking deep play).
  `_trackMatches` mirrors `_albumMatches` (title equals/prefix + `_artistMatch`). Adapters gained
  a `runTrack` coderef: `_searchQobuzTrack` (search type `tracks` → `tracks.items`, builds the
  `qobuz://<id>.flac` audio item — **the one fully-working service today**), `_searchTidalTrack`
  (search `type=>tracks`, adopts a `_renderTrack` result only if it has a string url — confirm on
  server), `_searchBandcampTrack` (no-op for now; album-oriented). Same `svc_priority_*` prefs
  drive album and track search.
- **resolvePlaylist**: fetch tracks → `_resolveTracks` (bounded `PLAYLIST_CONCURRENCY`=6, ordered
  by index so playlist order is preserved, unmatched dropped, `PLAYLIST_TIMEOUT`=45s watchdog) →
  `_playlistResult` returns a PURE track list (no "no match" placeholder rows) with the match count
  in the page TITLE rather than a leading row — a mixed menu (text row + tracks) suppresses Material's
  Play-all, so the level must be tracks only. Whole result cached under
  `lbf:pl:resolved:4:<mbid>|<last_modified>|<svc-order>` (per-track results under `lbf:track:4:…`;
  versions/TTLs current as of 0.9.39 — see "Streaming matching & playlist robustness" below),
  so revisits and play-by-item_id are instant and stable.
- **Caching tuned to the weekly cadence (0.8.0):** the Created-for-You playlists only regenerate
  weekly (Mon, user TZ; ListenBrainz keeps current + previous week). The JSPF content is IMMUTABLE
  for a given `mbid|last_modified`, and a new week brings a new mbid (fresh key) that re-resolves
  once — so resolved playlists AND per-track results are cached **30d for both full and partial**
  matches (was 7d/1d). 30d matters: a Weekly Jams playlist lives ~2 weeks, so the cache must
  survive into its SECOND week or the "previous week" entry would re-resolve all 50 tracks
  needlessly. No-match tracks keep 7d (recur across weeks). Trade-off: a track that only later lands
  on a service isn't picked up until next week's playlist — intentional, to avoid the slow
  re-resolve. Items are string-url `type=>audio` nodes (no coderef rebuild needed, unlike the album
  play-via cache).
- **Monday-aligned listing refresh (0.9.23):** the createdfor LISTING (`lbf:pl:list:<user>`) was a
  rolling 24h TTL, so the new week was only picked up "within a day" of Monday and the exact moment
  drifted with whenever the cache was first populated (install/browse time). It now expires AT the
  Monday boundary via `API::_secsUntilNextWeeklyRefresh` (Monday `PLAYLIST_REFRESH_HOUR` = 03:00
  **UTC** — LB regenerates ~00:15–00:27 UTC, so this gives a buffer), so the first browse after the
  rollover always re-pulls the fresh listing. Three coordinated parts: (1) working key expires at the
  boundary, **capped at 24h** (0.9.26) so a sub-weekly playlist still refreshes daily on the lazy path —
  Daily Jams is in the same listing whenever LB enables it, and the cap also stops the warm being a
  single point of failure; (2) the fallback copy (`lbf:pl:listfb:`) is bounded to `PLAYLIST_LIST_FALLBACK_TTL` = 8d
  (NOT the feeds' shared 30d `FEED_FALLBACK_TTL`) so a persistent createdfor outage degrades to an
  empty/refresh state rather than masking the new week with a >1-week-old listing; (3) `getCreatedForPlaylists`
  takes `force => 1` (skips the working-cache READ, still writes both keys) and the background warm
  passes it, so a warm tick that runs while the listing cache is still valid can't short-circuit on
  the old listing and miss the new week. Each week still mints a new `mbid` (confirmed live), so the
  per-week resolved/track caches auto-bust regardless. **Scoped to the playlist path only — the For
  You / All Releases feeds (own `FEED_TTL`/`FEED_FALLBACK_TTL`, shared `_feedError`) are untouched.**
- **Stale-per-player browse views — `cachetime => 0` (0.9.25):** even with the server data correct,
  the playlists/releases could still show a *previous* week **on a given player** — because **Material
  caches each player's browse/home views client-side and doesn't re-request after the weekly
  rollover** (it's a per-player client cache, NOT the plugin or the server). Confirmed it's the
  client: direct JSON-RPC queries returned the current week to every player, and navigating out/back
  on a stale player refreshed it. Fix: every dynamic feed callback now returns `cachetime => 0`
  (`topLevel`, `fetchForYou`, `fetchAll`, `fetchPlaylists`, `homeForYou`, `homePlaylists`,
  `homeAllReleases`), which makes Material re-fetch on each open instead of rendering its cached copy.
  **Verified in the server log**: three Playlists opens produced three fresh
  `Created-for playlists cache hit` fetches rather than one. The re-fetch is cheap (served from the
  plugin's own server-side caches — `lbf:pl:list`, `lbf:feed:*` — not ListenBrainz). NB: a plugin
  **reinstall resets its log category to the default WARN**, so the INFO diagnostic lines
  (`Created-for playlists cache hit`, `warm:`) stop until you re-set `plugin.listenbrainzfreshreleases`
  to INFO in Settings → Logging. Also: the LMS log-over-HTTP (`log.txt`) lags/snapshots badly — it can
  freeze at `Server done init` for minutes — so trust the live in-LMS log viewer over an HTTP pull.
- **Home-shelf `cachetime` — same XMLBrowser path, so the plugin side is complete (don't re-investigate).**
  The three Material home shelves are NOT a separate dispatch: `Plugins::MaterialSkin::HomeExtraBase`
  subclasses `Slim::Plugin::OPMLBased`, and its `handleExtra` just runs
  `executeRequest($client, [<tag>, 'items', $index, $quantity, 'menu:1'])` — i.e. the **same
  `Slim::Control::XMLBrowser` `items` query** as the browse menu, calling our `homeForYou`/
  `homePlaylists`/`homeAllReleases` feeds. So `cachetime => 0` sits on the right hash and XMLBrowser
  honours it identically; **there is no extra plugin lever for the home carousels.** **Verified
  (0.9.26):** two consecutive home-page loads produced two full re-fetches of all three shelves in the
  log (`For-you` + `All releases` + `Created-for playlists` each time), so Material re-requests the
  home extras on each load rather than serving a cached carousel — the home shelves are fixed too, no
  Material-bundle change required. (If a home carousel ever DID go stale per-player again, it would be
  Material's client-side home-page cache, i.e. a Material-bundle fix, not a plugin one — but that is
  not the case today.)
- **Cover art — per-category bundled images (0.8.4):** a real 2×2 track-art grid needs
  server-side compositing (GD/Imager/ImageMagick). The target DietPi box has **none** of those and
  LMS bundles only `Image::Scale` (resize, can't composite), and per [[no-extra-server-installs]] we
  won't require an install. So the agreed fallback is used: each playlist tile shows a **bundled,
  per-category cover** keyed by `source_patch` (`Browse::_categoryCover` → static
  `html/images/playlist-{weekly-jams,weekly-exploration,daily-jams,default}.png`, generated with
  Pillow in ListenBrainz brand colours). Cross-platform (LMS static-served), instant, and stable —
  no compositing, no redirect, so no flicker on return. (The earlier dynamic `Grid.pm` raw-route
  compositor was removed in 0.8.4 once it was clear no image lib would be available; history below.)
  Playlist tiles are `type => 'playlist'` (playable containers: Play/Add the whole resolved
  playlist, plus tap-to-open).
- **Prefer local library (0.8.7):** `_findPlayableTrack` first tries the user's own LMS library
  (`prefer_library` pref, default on) before any streaming adapter — `_findLocalTrack`: tier 1 =
  exact `tracks.musicbrainz_id` via `Slim::Schema->search('Track', …)`, tier 2 = LMS `titles`
  search (`Slim::Control::Request::executeRequest(undef, ['titles', …, "search:$artist $title"])`)
  gated by `_trackMatches`. A hit returns a string `url` (the file URL) → playable + cacheable like
  a streaming item, tagged `_svc => 'Library'`. Because a file URL can go stale on a rescan, library
  hits (and any resolved playlist containing one, via `_playlistTtl`) cache only `LIBRARY_TTL` (1d).
  All DB access is eval-guarded → falls through to streaming on any hiccup.
- **Background warm (0.8.3):** `Plugin::postinitPlugin` schedules `Browse::warmCache` ~60s after
  startup, re-armed daily (`Slim::Utils::Timers`). It pre-fetches the playlist list and pre-resolves
  every playlist's track matches into `lbf:pl:resolved:*` (using the first connected player for the
  streaming-service API context), so the Playlists view and each playlist open instantly. Cheap
  daily: keyed by `last_modified`, real work only when a new week's playlist appears. The list fetch
  uses `force => 1` (0.9.23) so it always re-pulls rather than short-circuiting on a still-valid
  listing cache — required for the daily tick to actually discover Monday's new playlists.
- **Streaming matching & playlist robustness (0.9.34–0.9.39).** A cluster of matching/caching fixes
  shared by album play-via, playlist track resolution and DSTM. **Supersedes the cache versions/TTLs
  and the "Qobuz is the only fully-working service" notes above.**
  - **Artist-only album search + RAW query to every service (0.9.34 / 0.9.37 / 0.9.39).** Album
    auto-search now queries the **artist only** and filters by title locally (`_albumMatches`) — far
    better recall than "artist album" as one string (which made the services' own fuzzy search
    rank/drop the target; Qobuz missed *Placebo RE:CREATED*, Tidal missed *Sweating Someone Else's
    Fever*). Crucially, the query **sent to a service** is the **RAW** artist/title, not the normalised
    form: normalisation turns punctuation into spaces (`L.U.C.K.Y` → `l u c k y`, `P!nk` → `p nk`),
    which the services' own search can't match — confirmed live on Tidal (raw query returns the track,
    spaced query returns 100 results without it). Normalisation is kept for **our** validation
    (`_trackMatches` / `_albumMatches`) only. Applies to track search (`_findPlayableTrack`, so DSTM
    too), album auto-search (`_findPlayable`, raw artist) and the manual Bandcamp search (raw
    artist+album). Both **Tidal and Qobuz** are fully-working track/album services now.
  - **Bandcamp is manual + persistent (0.9.34 / 0.9.35).** Bandcamp is **not** auto-searched — its
    plugin search does heavy **synchronous** response-parsing that blocks the event loop when it
    returns data (confirmed by external loop-stall probing; the 2–7s freeze / players dropping off).
    It's a deliberate one-tap **"Search Bandcamp"** row on the detail page (`_searchBandcampOnly`,
    combined "artist album" query — Bandcamp recall is the *opposite* of Qobuz/Tidal: a bare-artist
    search doesn't surface the album). A found match is **persisted in its own long-lived key**
    (`lbf:bcmatch:6:`, 30d) and appended to every render (`_bcMatchItems`), so a Bandcamp-only release
    becomes the **primary (sole) playable entry**, shows **inline** via the in-place `nextWindow =>
    'refresh'` mechanism, and **survives auto re-search and the Refresh**. A **"Re-search Bandcamp"**
    row force-refreshes (keeps the old match if the re-search is empty); a miss shows a "not found —
    retry" prompt (`lbf:bcdone:6:` marker). Bandcamp manual is gated on the plugin being installed.
  - **Service-aware caches → drop AND re-match on a service change (0.9.33 / 0.9.35 / 0.9.36).** The
    per-track cache (`lbf:track:N:`) and the resolved-playlist cache (`lbf:pl:resolved:N:`) now both
    include the **service set in priority order** (like the album `_streamKey`). So setting a service
    to priority 0, reordering, or uninstalling it **re-resolves** the affected tracks against the
    remaining services — a Qobuz track re-matches to Tidal, or drops if it's nowhere — exactly like the
    Releases section. `_playlistResult` also filters cached tracks via `_cachedSvcUsable` on read (the
    playlist twin of `_rebuildStreamItems`), and the playlist-tile count uses the same filter. **LESSON
    (cost a release): these caches are LAYERED — bumping the inner (per-track) key alone does nothing
    if the outer (resolved-playlist) key still hits and serves stale; bump BOTH. The file cache
    persists across plugin updates/restarts.**
  - **Transient outage no longer poisons (0.9.35).** A no-match where a service couldn't even be
    *queried* (no API handler at resolve time — e.g. the startup warm running before Qobuz/Tidal
    authenticated — or a timeout/error, signalled by `$collect->(undef)`) is treated as **inconclusive**,
    not a real miss: the per-track and resolved-playlist caches keep it only ~1h
    (`TRACK_INCONCLUSIVE_TTL` / `PLAYLIST_INCONCLUSIVE_TTL`) so it retries soon, instead of pinning a
    whole playlist on "local-only / few matches" for a week/month. `_resolveTracks` propagates the
    inconclusive count up to `_playlistTtl`.
  - **Current cache versions / TTLs.** Resolved playlist `lbf:pl:resolved:4:` (TTL **14d** — these
    playlists only live ~2 weeks; was 30d); per-track `lbf:track:4:` (30d found / 7d no-match / 1h
    inconclusive; key = `:4:` + svc-order + the non-`first` libMode suffix); album play-via
    `lbf:stream:7:`; persisted Bandcamp match `lbf:bcmatch:6:` (30d).
  - **"Unmatched tracks (debug)" view (0.9.38).** Settings → a browsable diagnostic
    (`fetchUnmatchedPlaylists` → `showUnmatched`): lists each created-for playlist; opening one shows
    the **source** tracks that resolved to nothing (not library, not any enabled service) as plain
    `Artist — Title` rows, count in the title. `_resolveTracks` now also returns the unmatched source
    tracks; the view resolves against the warm cache so it's usually instant and reflects exactly what
    the playlist dropped. Read-only. (Used live to find the `L.U.C.K.Y` miss — see
    [[lbf-find-unmatched-tracks]] for the manual HTTP version of the same diff.)

## Don't Stop The Music propagators (0.9.0)

**Two** DSTM mixers backed by ListenBrainz — when the play queue runs low, DSTM tops it up.
Registered in `DSTM.pm` (a module of this plugin, loaded by `Plugin::postinitPlugin` — **not** a
separate LMS plugin; mirrors `HomeExtras.pm`). Gated on `username`. Each mixer's handler is
`($client, $cb)` and MUST call `$cb->($client, \@urls)` — plain track URLs (streaming protocol urls
**or** library file urls); `[]` if nothing.

- **ListenBrainz Radio** (`PLUGIN_LBF_DSTM_RADIO` → `DSTM::radio`) — **seeds from what you were
  playing and evolves**. Reads the artist MBID of the current/last queue track via DSTM's own
  `getMixablePropertiesFromTrack` (`_seedArtist`, scans back ≤3 tracks for the most-recent track
  with artist info). **Streaming seed tracks (Qobuz/Tidal/…) carry no MusicBrainz ID**, so when
  there's no artist MBID the artist *name* is resolved to one via `API::getArtistMbidByName`
  (MusicBrainz search, strong-match≥90 only, cached) — without this the radio fell back to generic
  recommendations after every streaming track (the 0.9.2 fix). Then: `API::getSimilarArtists`
  (labs `similar-artists` dataset) → a
  weighted-random pick of similar artists (`_pickSimilar`: score-biased top-slice, then shuffled,
  so it varies) → `API::getTopRecordingsForArtist` (`/1/popularity/top-recordings-for-artist/<m>`)
  fanned out across `ARTIST_FANOUT`=24 artists, `PER_ARTIST_TRACKS`=8 each → a candidate pool. It
  **evolves** because each top-up stashes a random served artist MBID as `$state{cid}{next_seed}`,
  used when the live queue offers no fresh MB-tagged seed (e.g. our own streaming adds aren't
  tagged). Cold start / no seed at all → falls back to the Recommended pool so it still plays.
- **Last.fm similar-artist fallback (0.9.21).** When ListenBrainz's `similar-artists` dataset returns
  **nothing** for the seed (a known gap for some artists) and the user has a `lastfm_api_key`, the
  radio tries `API::getSimilarArtistsLastfm` (Last.fm `artist.getsimilar`) before giving up
  (`DSTM::_radioViaLastfm`). Last.fm returns artist NAMES (mbids are spotty), so up to `LFM_FANOUT`=12
  are resolved to MBIDs via `getArtistMbidByName` (inline mbid used when present; `_resolveArtistMbids`,
  which bounds the MusicBrainz name→MBID lookups to `MBID_RESOLVE_CONCURRENCY`=4 at a time via a pump
  — MB's anonymous ~1 req/s limit means an unbounded burst of all 12 gets the bulk throttled/dropped on
  a cold cache, defeating the fallback) then fanned out with the seed. If Last.fm is also empty / no key / nothing
  resolves, it falls back exactly as before (empty-LB-similar → the seed's own top recordings
  `_radioSeedOnly`; LB request error → the Recommended pool). Needs the seed's NAME, so it's threaded
  through `_radioFromArtist` (the current-track and resolved-name seed paths have it; the drift seed
  doesn't and skips Last.fm).
- **Artist diversity (`_selectCandidates`/`_artistKey`, 0.9.3).** To stop the same artist clustering
  or recurring: candidates are grouped by artist, capped at `MAX_PER_ARTIST`=1 per top-up, artists
  not on a per-player cooldown FIFO (`ARTIST_COOLDOWN`=24) are preferred, and the short-list is
  **round-robin interleaved by artist** so the returned order alternates. `$state{cid}` holds
  `served` (recording_mbids), `recent` (the artist FIFO) and `next_seed`. Both mixers use this — the
  Recommended pool keys on artist *name* (`n:<name>`) since CF recs carry no artist MBID.
- **ListenBrainz Recommended for You** (`PLUGIN_LBF_DSTM_RECOMMENDED` → `DSTM::recommended`) — your
  personalised collaborative-filtering pool, shuffled. `API::getRecommendations` →
  `GET /1/cf/recommendation/user/<user>/recording` (the `artist_type` param is **ignored by the
  live API** — similar/raw/top all return the same list, which is why there's one mixer, not three)
  → `API::getRecordingMetadata` (`/1/metadata/recording/?inc=artist`, chunked ≤50) to fill
  artist/title. Pool cached `lbf:dstm:recs:<user>` for `RECS_TTL` (1 day). A 204 (no recs generated)
  degrades quietly.
- **Resolution & no-repeat (`_resolveAndReturn`).** Both mixers resolve via
  `Browse::_resolveTracks(..., $libMode)`. `_findPlayableTrack`'s `$libMode`: **first**
  (library→streaming), **fallback** (streaming first, library only if no service matched), **never**
  (streaming only). The mixers use **`first`** (0.9.5 — library-first: play an owned copy when the
  user has it, else stream; the selection is varied enough that preferring owned copies no longer
  hurts). Non-`first` modes use a `:<mode>`-suffixed cache key so they don't collide with the
  playlist feature's `lbf:track:*` cache. **Per-session no-repeat (0.9.5):** `$state{cid}{played}`
  is a permanent (until restart) set of every track URL ever queued — a track is never returned
  twice, and anything currently in the play queue is also excluded (`%blocked`). The artist `recent`
  FIFO still resets for variety; `played` never does. The resettable `served`/`recent` only drive
  artist variety. **No streaming services installed?** The empty-`@adapters` guard in
  `_findPlayableTrack` runs *after* the library tier (0.9.0), so a no-streaming user gets a
  local-library radio (and playlists match owned tracks). ('never' mode is the only one that returns
  nothing without streaming.)
- **Prefs:** `dstm_count` (recs pulled into the Recommended pool, default 100), `dstm_batch` (tracks
  added per top-up, default 15 — adds the max it can for a seed, fewer if too few resolve). Reuses
  `svc_priority_*`. No settings UI yet (defaults work).
- **Why not LB Radio?** ListenBrainz's `/1/explore/lb-radio` prompt engine is the obvious "radio",
  but it was returning `503` during development; the similar-artists + top-recordings-for-artist
  combo gives the same flow from endpoints that are up and is cacheable.

## Release detail page (0.9.10–0.9.19)

`Browse::_releaseDetail` builds the album detail page as **three Material sections** via
`_sectionHeader`, in this order: **Streaming** (playable matches + Refresh), **Artist Details**
(photo + bio + Block-artist), **Album Details** (album/date/type/tags → genres → tracklist →
**View on MusicBrainz** last). Each section is emitted only if it has rows; on non-Material skins
`_sectionHeader` falls back to a plain text divider. The page is a live feed returned straight to the
callback (never serialised), so `url` coderefs (Read-more, Block, Refresh) are safe here.

- **Streaming section.** Auto-matched Qobuz/Tidal albums (`_findPlayable`: raw artist search +
  `_albumMatches`), plus a manual **"Search Bandcamp"** action and, when Bandcamp matched before, its
  **persisted** result inline (it's the primary entry when no other service has the release); a
  **Refresh** re-searches. Full matching/caching detail is under **Created-for-You Playlists →
  "Streaming matching & playlist robustness (0.9.34–0.9.39)"** (album play-via, Bandcamp persistence,
  raw query, service-aware caches all live there).
- **Section headers (`_sectionHeader($client, $token, $useH, $children, $noIcon)`).** Detail-page
  sections pass `$noIcon=1` (no LB-logo thumbnail — there's nothing to drill into, the rows sit right
  below). List-page headers (top menu) keep the icon so Material's grid toggle stays enabled. Header
  **text size** is set by Material's skin CSS for `type=>'header'` and is NOT settable from the OPML
  feed — enlarging it needs a Material/skin change.
- **Row builders.** `_artistRows($rel,$client,$img,$bio)` = artist name (with the artist photo as a
  small thumbnail when present) + bio + Block-artist. The inline thumbnail is **fixed-size by
  Material's skin CSS** (not settable from the feed). NB: a `jive => { showBigArtwork => 1, actions =>
  { do => { cmd => ['artwork', $img] } } }` tap-to-enlarge was tried and **reverted** — on a
  `type=>'text'` row Material strips the action (`itemNoAction`) and the photo stopped rendering
  entirely, so the row keeps a plain `image => $img` thumbnail. `_albumRows` = album/date/type/tags only;
  genres + tracklist are appended by `_releaseDetail`, and `_mbLink` (the MusicBrainz weblink, UUID-
  validated) is appended LAST.
- **Biography (`_fetchArtistInfo`).** Prefers the **MAI** plugin (`Plugins::MusicArtistInfo::ArtistInfo`
  `getBiography`/`getArtistPhotos`, signature `($client,$cb,$params,$args)`, `$args={artist,mbid}`;
  bio text in each item's `name`, photo url in each item's **`image`** key — MAI renders
  `image => $_->{url}` internally, so the photo arrives as `image`, NOT `url` (reading `url`
  silently yielded no photo until the 0.9.21 fix). NB: MAI's `getArtistPhotos` looks photos up by
  artist **name** only — it passes `undef` for the artist_id and ignores `$args->{mbid}`, so the
  mbid we pass is honoured for the bio but not the photo) — bio AND photo. Falls back to
  `API::getArtistBio` (Last.fm `artist.getinfo`, needs `lastfm_api_key`) for a bio only (no photo).
  Runs inside the detail-page async barrier; fully eval-guarded — no MAI and no key = name +
  Block-artist only. INFO-logs MAI detection + photo count for diagnosis. `API::_cleanBio` uses
  Last.fm's FULL `content` (not the short `summary`), strips HTML/"Read more"/CC boilerplate, keeps
  paragraph breaks; capped only by `BIO_MAX`=20000 (DoS guard, never visibly trims). Bio cache key
  `lbf:bio:2:*`.
- **Bio display — KEY Material fact.** A `type=>'text'` row renders its `name` IN FULL; Material has
  NO auto-collapse / "more" for plain text. So "compact preview + expand" MUST be a drill-in: the
  Artist section shows a `BIO_PREVIEW`=150-char text preview, then a **Read more** (`PLUGIN_LBF_READ_MORE`)
  link whose `url` coderef returns the full bio split into paragraph rows. (Don't "fix" this by
  putting the whole bio in a text row — it dominates the page, which is the bug this replaced.)

## Branded cover images (`tools/make_covers.py`)

All the flat, bundled cover/badge PNGs under `html/images/` are generated by a single committed
script, **`tools/make_covers.py`** (Pillow on a Mac; LMS itself has no image library, so these are
built ahead of time — see [[no-extra-server-installs]]). It is the source of truth: edit the script
and re-run `python3 tools/make_covers.py` from the repo root, then rebuild the zip. Don't hand-edit
the PNGs — they'd be lost on the next regenerate.

All covers share one **design system** (500×500): a vertical gradient, a centred white bold title
(Arial Bold, auto-wrapped to ≤2 lines, `MAXW=460`), an optional white "week" pill with
category-coloured text, and a `LISTENBRAINZ` wordmark along the bottom. **Layout rule (keep stable):**
the wordmark (`WORD_CY`) and, when present, the pill (`PILL_CY`) sit at **fixed** y positions; only
the title block re-centres above the pill (`TITLE_CY_PILL` vs `TITLE_CY_PLAIN`). This is what makes a
one-line title (Weekly Jams) and a two-line title (Weekly Exploration) line their pills up — the
0.8.13 fix. Per-category gradients are sampled constants in the script (`GREEN`/`BLUE`/`AMBER`/
`ORANGE`/`TEAL`/`PURPLE`/`INDIGO`); the gradient's darker end doubles as the pill text colour.

Produces: the menu tiles (`menu-new-releases`, `menu-playlists`, `menu-all-releases`), the playlist
tiles (`playlist-weekly-jams[-prev]`, `playlist-weekly-exploration[-prev]`, `playlist-daily-jams`,
`playlist-default`), and the All Releases week badges — past `allrel-this-week`/`-last-week`/`-earlier`
("All Releases" title) and future `allrel-next-week`/`-next-fortnight`/`-further` ("Future Releases"
title, shown for upcoming weeks when "Include Upcoming" is on; selected by `Browse::_weekBadgeImage`).
**Not** generated: the Material font-icon PNGs (`lbf-cog_MTL_icon_settings.png`,
`lbf-refresh_MTL_icon_refresh.png`) use Material's `_MTL_icon_<name>` filename convention so Material
renders its own themed font icon — the PNG is only a minimal non-Material fallback; and the app icon
(`ListenBrainzFreshReleasesIcon*.{svg,png}`), which follows the separate `_svg.png` recolour
convention documented under "Icon System".

## Top-level menu, tiles & home shelves (0.8.8–0.8.15)

- **Section structure (`topLevel`/`_sectionHeader`):** the main menu is grouped under Material
  section headers — **Created for You** (New Releases for You + Playlists), **All Releases**, and
  **Settings**. Material forces a drill action onto `type=>'header'` items (can't be suppressed), so
  each header carries a `url` coderef returning its own children (same trick as the week dividers);
  non-Material skins get a plain text divider. `features:h` (header support) is read by the top feed
  via `_featuresOf` and forwarded through passthrough (XMLBrowser doesn't forward request params to
  coderef sub-feeds — see the 0.6.15 gotcha).
- **Tiles show dates, not repeated titles.** The branded cover already carries each category's title,
  so the row text is informational instead:
  - **New Releases for You / All Releases** (`_categoryTile`): subtitle = the date span actually being
    viewed (real earliest/latest release date of the loaded feed, stashed by `_stashSummary` under
    `lbf:summary:{user,all}`; before that, the window implied by `days`/past/future via `_windowSpan`)
    plus the release count (`PLUGIN_LBF_N_RELEASES`). Tracks the *Days window* setting automatically.
  - **Playlists** (`_playlistsTile`): subtitle = the date span the playlists inside cover (earliest
    week-commencing/day → today; real span stashed by `_stashPlaylistSummary` under
    `lbf:summary:playlists`, else a synchronous fallback of last week's Monday → today).
  - **Playlist tiles** (`_playlistTile`): first line = the period the playlist covers — `W/C <Monday>`
    for the weekly playlists, the day for Daily Jams (derived from `last_modified`) — second line = the
    match count read from the pre-resolved `lbf:pl:resolved:*` cache (only still-usable tracks counted,
    via `_cachedSvcUsable`, so the tile agrees with the opened list after a service change).
  - **All Releases week rows / `_weekLabel`:** `W/C 8 June 2026` (full month, no abbreviations); date
    helpers `_fmtDate`/`_dateSpan`/`_ymd` live in `Browse.pm`.
  - **CRITICAL lesson (0.8.14→0.8.15 regression):** a top-level menu row with an **empty `name`** is
    dropped by Material (the whole tile vanishes). Always emit a non-empty name — hence the synchronous
    date-span fallbacks rather than "" while a stash is still cold.
- **Manual feed refresh (`_refreshItem` / `API::clearFeedCache`):** the For You and All Releases feeds
  cache for **24h** (`FEED_TTL`, daily); a "Refresh (force update now)" row at the top of each clears
  that feed's working cache key and reloads in place via `nextWindow => 'refresh'` (same mechanism as
  the detail-page streaming refresh). The key built by `clearFeedCache` MUST match the one in
  `getFreshReleases*` (same prefs, same format); the long-lived fallback copy is left intact.
- **Material home shelves (`HomeExtras.pm`, 0.8.12):** three `HomeExtraBase` subclasses, each its own
  tag → own CLI dispatch → own feed: `LBFForYou`→`homeForYou`, `LBFPlaylists`→`homePlaylists`,
  `LBFAllReleases`→`homeAllReleases`. For You and Playlists are flat, quantity-stable card rows.
  **All Releases shows the flattened first level** (the "All releases" entry + the weeks available),
  not the full list — a small fixed list, so it stays drill-stable at any request quantity (the 0.6.11
  rule). Registered in `Plugin::postinitPlugin`.

## Settings Structure

Five sections in the settings page (General / Blocked Artists / Streaming Services / For You / All Releases). Each is a
proper Material settings section (0.8.24): the header is `<div class="prefHead collapsableSection"
id="lbf_<section>_Header">` and the section's settings are wrapped in a matching `<div
id="lbf_<section>">` panel. Material's `addExpanders` (iframe-dialog.js) finds `.collapsableSection`
divs, styles them as the themed bold accent-bar header (matching the browse `type=>'header'`
dividers), adds an expander, and on click toggles the panel whose id is the header id **minus
`_Header`** — so the `id="lbf_X_Header"` ↔ `<div id="lbf_X">` pairing is required. **Don't** use a
bare `<h2>` (Material doesn't theme it) or a standalone `<div class="prefHead">` (that's the faint
per-setting *label* style, positioned right-aligned/narrow inside a `settingGroup` — not a section
divider, and it gives no accent bar). The panels also collapse/expand like native LMS settings.

### General Settings
- `username` — ListenBrainz username
- `token` — ListenBrainz API token
- `lastfm_api_key` — optional Last.fm API key; enables three fallbacks: detail-page genres when MusicBrainz has none, the artist biography when MAI isn't installed (bio only, no photo), and similar artists for the DSTM radio when ListenBrainz has none (default empty = disabled)
- `days` — days window (1-90, default 14)
- `sort` — default sort (release_date / artist_credit_name / release_name / confidence)
- `group_by_artist` — collapse multi-release artists into one tappable entry (default ON)
- `week_dividers` — when sorted by release date, insert a divider per week; takes precedence over group_by_artist for the date sort (default ON)
- `play_via` — show inline playable streaming matches on the detail page (default ON)
- `prefer_library` — when building a Created-for-You playlist, use a track from the user's own LMS library (matched by MusicBrainz ID, then artist + title) before searching streaming services (default ON; see "Prefer local library")

### Blocked Artists Settings
- `blocked_artists` — arrayref of `{ mbid, name }`. Releases by these artists are hidden from EVERY feed (For You / All Releases / home shelves) by `Browse::_filterSection` → `_isBlocked` (matches any blocked `artist_mbids` OR normalised credit name). No ListenBrainz API exists for this — the `fresh_releases` endpoint takes only date/sort params and the feedback API is per-recording (love/hate, `score 1/-1`) and isn't consumed by the feed — so it's a purely local, render-time filter (takes effect on next browse; no feed-cache clear). Added from a release detail page's **"Block this artist"** link (`Browse::_blockArtist`); VA is never offered (would hide unrelated compilations). The settings section lists each blocked artist with an Unblock checkbox (`lbf_unblock_<i>`); `Settings::handler` removes ticked entries on save (the pref is NOT in the `prefs()` list, so it's mutated directly).

### Streaming Services Settings
- `svc_priority_<qobuz|bandcamp|tidal>` — search priority per service (number 0–9; lower = searched first, **0 = never search it**). Search stops at the first service that matches. Drives BOTH album play-via and playlist track matching. The page lists each known service as detected/not installed via `Browse::serviceStatus`.

### For You Settings
- `foryou_past` — include past releases (default ON)
- `foryou_future` — include upcoming releases (default OFF)
- `foryou_artwork_only` — hide releases without artwork (default ON)
- `foryou_various` — include Various Artists releases (default ON)
- Type checkboxes (`foryou_type_<name>`) — same set as All Releases; default ON: Album, Compilation. Default OFF: everything else. (Replaced the old single `foryou_albums` toggle in 0.6.15.)

### All Releases Settings
- `all_past` — include past releases (default ON)
- `all_future` — include upcoming releases (default OFF)
- `all_artwork_only` — hide releases without artwork (default ON)
- `all_various` — include Various Artists releases (default ON)
- Type checkboxes — default ON: Album, Compilation. Default OFF: Single, EP, Broadcast, Other, Soundtrack, Live, Remix, Demo (Soundtrack dropped from defaults in 0.6.15)
- All types stored as `all_type_<name>` prefs

## Browse Menu (current)

```
ListenBrainz Fresh Releases
├── ── Created for You ──                      ← Material section header
│   ├── <date span> · N releases               ← New Releases for You tile (title is on the cover)
│   │   ├── Refresh (force update now)          ← clears the feed cache, reloads in place
│   │   └── … For You feed (weekly dividers / grouping per prefs)
│   └── <date span>                            ← Playlists tile (covered span; title on cover)
│       ├── W/C <date> / <day>                  ← one playlist per category (Weekly Jams / Exploration / Daily Jams)
│       │   └── matched streaming/library tracks (Play-all; unmatched dropped; count in page title;
│       │       a disabled/uninstalled service's tracks drop + re-match on re-resolve)
│       └── …
├── ── All Releases ──                         ← Material section header
│   └── <date span> · N releases               ← All Releases tile
│       ├── Refresh (force update now)
│       ├── Show all                            ← complete list (weekly/grouped view)
│       ├── W/C <date>  [This/Last/Earlier badge]  ← that week's releases only
│       └── …                                  ← one entry per week-commencing
└── ── Settings ──                             ← Material section header
    ├── Plugin Settings                         ← weblink to settings.html
    └── Unmatched tracks (debug)                ← per-playlist list of tracks that matched nothing (0.9.38; username-gated)
```

All section filtering (artwork/type/VA) is still driven entirely by settings prefs. The All Releases
by-week split (`_buildAllLanding`) groups the already-filtered+sorted list by `_weekStart` and offers
a per-week drill-in plus a "Show all" entry; For You drops straight into its list (with the weekly
dividers / group-by-artist per prefs). The Playlists section is gated on `username` being set. See
"Top-level menu, tiles & home shelves" above for the tile-text and home-shelf details.

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
- `<homepageURL>` is the Manage Plugins **"more info"** link (NOT `<link>` — that's ignored; Qobuz/Bandcamp use `homepageURL`). Points to the styled GitHub Pages README `https://simonarnold002.github.io/LMS-ListenBrainz-New-Releases/README.html` (the in-git `README.html` served by Pages; `index.html` redirects to it) so users land on a readable page rather than the raw GitHub repo. Shipped in the 0.9.22 zip (link-only change, no version bump)
- `<icon>` points to `ListenBrainzFreshReleasesIcon_svg.png` — the Material `_svg.png` convention. **OPMLBased uses `_pluginDataFor('icon')` (i.e. install.xml) for the app icon and ignores any `icon =>` arg** (confirmed in `OPMLBased.pm` lines 62/185), so this single ref serves the Material app/menu tile, Material's Manage Plugins, AND non-Material skins. Material sees the `_svg.png` name, loads the sibling `.svg`, and recolours it per theme (white on dark, black on light). Non-Material skins show the real transparent PNG fallback.

### Icon System (Material Skin) — authoritative rules from Material's developer
- `_svg.png` suffix → Material loads the matching `.svg` and recolours it. (Other naming: `*_MTL_icon_<name>.png` uses a Material **font** icon; `*_MTL_svg_<name>.png` uses a Material **bundled** SVG.)
- **CRITICAL: the SVG must use `#000` (3-digit), NOT `#000000`.** Material does a literal string replace of `#000` with the theme colour; `#000000` becomes `<colour>000` (invalid) → the icon renders **blank**. This was the real cause of the long-running "blank/black icon" bug, fixed in 0.6.15 (18 `#000000` → `#000`).
- SVG size should be 24×24px with ≥2px border (set `width="24" height="24"`; viewBox `0 0 48 48` with content inset gives the border). Optimise with `scour` if available (not installed locally).
- Three icon files: `…Icon.svg` (source, all `#000`), `…Icon_svg.png` (install.xml ref + non-Material fallback), `…Icon.png` (generic fallback). The two PNGs must be **real transparent PNGs** — earlier they were JPEGs misnamed `.png` (opaque black blocks), which is why Manage Plugins went black. Regenerated via `qlmanage` → Pillow (luminance→alpha, centre, 8% pad).

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
- Release detail enrichment (two MusicBrainz lookups, in parallel, both cached):
  - Tracklist: `GET …/release/<mbid>?inc=recordings&fmt=json` (`getReleaseDetails`)
  - Genres: `GET …/release-group/<release_group_mbid>?inc=genres&fmt=json` (`getReleaseGroupGenres`) — genres live on the **release-group**, not the release; release-level genres are nearly always empty (this was a bug fixed in 0.6.15). Cached by release-group MBID so releases sharing a group reuse it
  - Fetched on-demand when a release is opened (so the anonymous MusicBrainz 1 req/sec limit is generally fine; two near-simultaneous calls degrade gracefully if one is throttled)
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
- Log category default level is WARN (0.8.16; was INFO). The INFO lines (per-request response code/length/URL, cache hits) are still there — raise the level via Settings → Logging when diagnosing
- `<extensions>` vs `<extension>` in install.xml matters — manually installed plugins must use `<extension>` singular
- File ownership must be `squeezeboxserver:nogroup` on DietPi — NOT `squeezeboxserver:squeezeboxserver`
- The zip must extract directly as `ListenBrainzFreshReleases/` with no extra `Plugins/` wrapper for manual installs
- Material Skin's grouped artist release page layout is NOT achievable from OPML feeds — only via native library `albums_loop` responses. Solved in earlier versions by using Browse by Type sub-menus, removed in v0.3.0 in favour of settings-driven filtering.

## Version History
- **0.9.20 → 0.9.39** — **streaming-match & playlist robustness, Bandcamp rework, diagnostics.**
  `header-basic` dividers on Material 6.4.3+; **artist-only** album search and a **RAW (un-normalised)
  query** to every service search — fixing stylised names/titles (`L.U.C.K.Y`, `P!nk`) the services'
  own search couldn't match; **Bandcamp** moved to a manual, **persistent** "Search Bandcamp" (own
  long-lived match key, primary when it's the sole source) + "Re-search"; **service-aware**
  per-track/resolved-playlist caches so disabling/uninstalling a service **drops AND re-matches**
  (parity with Releases); transient-outage resolves cached **short (inconclusive)** instead of
  poisoning for weeks; resolved-playlist TTL cut **30d→14d**; **layered-cache** version bumps
  (`lbf:pl:resolved:4:`, `lbf:track:4:`, `lbf:stream:7:`); and a browsable **"Unmatched tracks
  (debug)"** view. Architecture in **Created-for-You Playlists** above; per-version detail in
  **CHANGELOG.md**.
- **0.9.0 → 0.9.19** — the **Don't Stop The Music propagators** (ListenBrainz Radio + Recommended;
  seed/evolve, library-first, no-repeat, artist diversity, Qobuz multi-artist matching, batch=15) and the
  **release detail page restructure** (three Material sections Streaming/Artist/Album, artist photo +
  biography via MAI or Last.fm, Read-more drill-in, logo-free section headers + action links, MB link
  moved after the tracklist). Architecture in the topical sections above (**Don't Stop The Music
  propagators**, **Release detail page**); per-version detail in **CHANGELOG.md**.
- **0.8.0 → 0.8.15** — the **Created-for-You Playlists** feature plus the surrounding polish
  (track matching incl. local-library preference, weekly-cadence caching, background warm, branded
  bundled covers/badges, the section-header menu, date-span tiles + W/C labels, manual feed refresh +
  daily TTL, and the three Material home shelves). The architecture and the hard-won lessons live in
  the topical sections above (**Created-for-You Playlists**, **Branded cover images**, **Top-level
  menu, tiles & home shelves**); the per-version blow-by-blow is in **CHANGELOG.md**.
- **0.7.2** — **All Releases by-week landing menu.** Tapping All Releases no longer drops straight into the full list; `fetchAll` now returns `_buildAllLanding` (the For You path is unchanged). The landing menu's first item, "All releases" (`PLUGIN_LBF_VIEW_ALL`), is a coderef that returns the previous full view via `_buildItems` (so the weekly-divider/group-by-artist behaviour is preserved under it); below it is one drill-in per week-commencing, labelled with `_weekLabel` + a `(count)`, each coderef returning just that week's `_buildReleaseItem`s. Weeks are grouped with the same `_weekStart`/newest-first logic as `_buildWeekly` (input is already `_sortReleases(_filterAll(...))`). All coderefs are live feed nodes (not cached/serialised), matching `_buildWeekly`/`_buildGrouped`. NB: this is a browse-only navigation split — no new prefs, and the week grouping always runs regardless of the `week_dividers`/sort prefs (those still govern what "All releases" shows).
- **0.7.1** — **Non-Latin artist match fix (real root cause of the "Prism" 48→still-many hits).** The 0.7.0 `_norm` made the regex Unicode-aware (`\p{Alnum}`), but that only works on a utf8-*flagged* string. Artist/album names actually reach `_findPlayable` as raw **UTF-8 octets** (no flag) — via the Storable stream cache and the play passthrough. On the server's Perl (no `unicode_strings` in scope), `\p{Alnum}` on those bytes stripped the whole non-Latin name → `artistNorm eq ''` → `_albumMatches` fell to its "exact-title-only, no artist" branch → every album literally titled "Prism" matched (was 48; capped to 12 by `STREAM_MAX_RESULTS`, which is the "lots" the user still saw). Verified locally: byte-string `_norm("踊って…")` empties/garbles on the no-`unicode_strings` path, decoded `_norm` yields `踊ってばかりの国`. Fix: `_norm` now `utf8::decode`s octet input (guarded — only adopts the result if it's valid UTF-8, and only when the string has a high byte) before lowercasing, so the name survives as real codepoints and the artist again acts as the disambiguator (simulated: Katy Perry/Prism + Roxette/Prism → reject, real band → match). Also: the search query sent to the streaming services is now an explicit octet copy (`$queryEnc`, `utf8::encode`) so a wide-char query can't warn/break in the URI layer, while `artistNorm`/`albumNorm` stay characters for matching. Stream cache key bumped `:3:`→`:4:` (and the manual-refresh `$cache->remove` follows) so the stale wrong matches from 0.7.0 invalidate automatically — no manual refresh needed.
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
- **0.6.15** — **Icon fix (real root cause found).** Two defects, both fixed: (1) the `.svg` used `#000000`, but Material string-replaces `#000` with the theme colour, corrupting `#000000` → `<colour>000` (invalid) so Material rendered the icon **blank** — changed all 18 `#000000` → `#000` and set the canvas to 24×24 per Material's spec. (2) `…Icon.png` / `…Icon_svg.png` were **JPEGs misnamed `.png`** (opaque 256² black blocks), so non-Material/Manage-Plugins contexts showed a black square — regenerated as genuine transparent RGBA PNGs (centred, 8% pad) via qlmanage→Pillow. `install.xml <icon>` set to `…Icon_svg.png` (the standard two-file Material convention; abandoned the earlier colour-tile and white-SVG detours). Confirmed `OPMLBased` always takes the app icon from `install.xml <icon>` (`_pluginDataFor('icon')`, lines 62/185) and ignores any `icon =>` arg. **Genres bug fix.** Genres were fetched from the *release* (`release/<mbid>?inc=genres`), where they're almost always empty — verified against MusicBrainz: a release-group had 13 genres, its release had 1. Now genres come from the **release-group** via a new `API::getReleaseGroupGenres` (cached by release-group MBID); `getReleaseDetails` drops `+genres` and just returns the tracklist. `_releaseDetail` runs genres (RG) and tracklist (release) as separate parallel tasks (so a detail open can do 2 MB calls, both cached). Genre parsing refactored into `API::_parseGenres`. **But MB genres are empty for most fresh releases** (too new to be tagged — verified a today's-feed release-group returned `[]`), so this rarely shows anything. The practical genre source is the payload's inline `release_tags` (no API call). 0.6.15 now shows up to 3 of these tags on each **list** row's `line2` (via `_releaseTags` in `_buildReleaseItem`, separated by `\x{00B7}`), in addition to the existing detail-page "Tags:" line. Coverage is partial (~20% of releases carry tags), so many rows legitimately show none. **Last.fm genre fallback (detail page):** new optional `lastfm_api_key` pref. When set, the detail page runs `API::getLastfmTags($artist,$album)` in parallel — tries `album.gettoptags`, falls back to `artist.gettoptags` (artist tags are populated even when a brand-new album isn't, so this is what actually fills the gap). `_releaseDetail` now stores `$mbGenres`/`$lfmGenres` and builds ONE "Genres:" line in `$finish`, preferring MB then Last.fm. Tags cleaned/weight-sorted via `_parseLastfmTags` (handles Last.fm's single-tag-as-hash quirk), cached `lbf:lfm:<artist>|<album>` (30d found / 7d empty). No key = graceful no-op; never blocks the page (all Last.fm failures resolve to empty). List rows are deliberately NOT enriched (would be 50+ API calls/page). **Unified section filtering:** For You used to have only a single "Show Albums" toggle (`foryou_albums`); it now has the **same per-type checkboxes** as All Releases (independent `foryou_type_<name>` prefs). Both sections' type/various/artwork filters now go through one shared `_filterSection($releases,$prefix)` + `_allowedTypes`/`_typeMatches` (replacing the duplicated `_filterForYou`/`_filterAll` bodies; both are now thin wrappers). **Default selected types are now Album + Compilation for both sections** — Soundtrack was dropped from the defaults (`all_type_soundtrack` 1→0). NOTE: default changes only affect prefs that were never persisted; an existing install still has `all_type_soundtrack=1` saved, so that box must be unticked once manually (For You is new prefs, so it picks up the new defaults immediately). **Secondary-type filtering bug fixed:** the API field is `release_group_secondary_type` (SINGULAR, a scalar string e.g. `'Live'`) — the code was reading `release_group_secondary_types` (plural/array), so secondary types were never seen and live/soundtrack albums (which are `primary=Album` + `secondary=Live/Soundtrack`) slipped through. Verified against the API: only two type fields exist, both singular scalar strings, never arrays. New `_secondaryType($rel)` helper reads the singular field (array-tolerant for safety) and is used by `_typeMatches`, `_displayType`, list `line2`, and the detail page. `_typeMatches` now uses **allowlist** semantics: primary type must be ticked AND the secondary type (if present) must also be ticked. The API's secondary set is larger than the offered checkboxes (DJ-mix, Audiobook, Interview, Spokenword, Mixtape/Street, Field recording, Audio drama) so any untickable secondary correctly fails the filter. Simulated on the live feed with Album+Compilation: 19,709→6,413 kept, all primary=Album, secondaries only None+Compilation, zero Live/Soundtrack. `_displayType` now shows `primary / secondary` (e.g. "Album / Live"); the redundant separate `PLUGIN_LBF_SEC_TYPES` detail line was removed. **Week dividers as real Material headers:** Material advertises `features:hi` in its browse requests ('h' = it supports the `header` item type, which renders bold/accent and enables grid view). XMLBrowser passes the item `type` straight through (`Slim::Control::XMLBrowser` line ~1050: `$hash{type} = $item->{type}`), and Material's `browse-resp.js` sets `item.header=true` for `type=='header'`. When the client supports it, week-divider rows are emitted as `type => 'header'` instead of `type => 'text'`; non-supporting skins still get plain text. **Gotcha (cost a debug cycle):** `features` is a request param only available to the TOP feed (XMLBrowser builds the coderef sub-feed's `$args->{params}` from `$feed->{query}`, line 491 — NOT the request params — so `fetchForYou`/`fetchAll` never see it). Fix: `topLevel` reads `features` via `_featuresOf($args)` and forwards it through each menu item's `passthrough` (which XMLBrowser DOES pass to the coderef, line 521); `fetchForYou`/`fetchAll` read `$passDict->{features}` and call `_wantHeaders()`. Diagnosed via JSON-RPC: `listenbrainzfreshreleases items 0 N item_id:1 features:hi` returned `type:'text'` for dividers (proving the broken detection); after the passthrough fix it returns `type:'header'`. **Header "More" gotcha (0.6.15):** in menu mode XMLBrowser forces a `go` (drill) action onto EVERY non-`text` item — only `type:'text'` gets `itemNoAction` (line ~1174), and `$item->{style}` only sets `$windowStyle`, while the `jive` override runs too late and gets stripped (line ~1372). So a `header` item always carries `actions.go`, and Material renders a "More" link for any header with actions (`item.slimbrowse && item.header && item.actions`) — which drilled to `item_id:X` returning `count:0` ("reveals nothing"). There is NO way to keep `type:'header'` AND suppress the action. Resolution (user choice): instead of fighting it, `_buildWeekly` now gives each week header a `url` coderef (+`passthrough`) that returns just that week's releases (same pattern as `_buildGrouped`), so tapping a week header / its "More" shows that week rather than an empty page. `_buildWeekly` groups by week up-front to build the per-week coderef. Verified the full server response (with `menu:1 useContextMenu:1`) to confirm the forced `go`/`addAction`. **Home-page click-in dividers (0.6.15):** the Material home shelf is itself `LBFForYou items …` (our `homeForYou`, registered via `HomeExtraBase`). The carousel and the expanded "show all" view run the SAME command — only the requested quantity differs (`HomeExtraBase`/Material don't forward `ismore` to the feed): carousel = `NUM_HOME_ITEMS` (10), expand = `LMS_BATCH_SIZE` (25000). So `homeForYou` now reads `$args->{params}{_quantity}` and, when `>50` (the click-in), returns `_buildItems($releases,$client,1)` (week dividers/headers + per-week drill coderefs) instead of the flat capped card strip; the carousel path is unchanged. Headers are forced on (1) because `LBFForYou` is only ever invoked by Material. Material's `browse-resp.js` re-parses the click-in (`ismore`) results through the main `parseBrowseResp`, so `type:'header'` renders identically to the For You menu. **CRITICAL fix — feed caching (0.6.15):** the ListenBrainz feeds (`getFreshReleasesForUser`/`getFreshReleasesAll`) were NEVER cached, so every Material home-row load re-fired a slow (2–15s) API call. Diagnosed from the live server log (fetched over HTTP at `http://<lms>:9000/log.txt`): 9 `Fetching for-you releases` in ~3 min, **0 cache hits**, `Server closed connection` (ListenBrainz rate-limiting the flood), and `Slim::Web::JSONRPC::requestWrite Context not found` (response arrived after Material gave up) → home carousels never loaded / Material appeared hung. Fix: cache the parsed feed under `lbf:feed:user:<username|sort|past|future|days>` and `lbf:feed:all:<…|date>` for `FEED_TTL` (6h); first view fetches, the rest are instant, killing the flood. The menu browse and the home row share the same key (same prefs). Lazy refresh was chosen over a scheduled daily fetch (a "fresh" feed wants intra-day freshness; the plugin is global so there's no per-listener timezone; All Releases also auto-rolls at local midnight via the date in its key). **Settings dropdown fix:** the **Default sort order** was a native `<select>`, whose option popup drew over / bled through the rows below it in Material's settings view (native `<option>` popups can't be reliably restyled). Replaced with a radio-button group (same `pref_sort` name/values) — no popup, no overlap, consistent with the page's existing checkbox blocks. `settings.html` now has no `<select>` elements. **Streaming-link fixes (0.6.10):** (1) `_albumMatches` now requires the candidate title to *equal* or *start with* (`index($t,"$albumNorm ")==0`, word-boundary) the album, not merely contain it — fixed "Apollo" by Gene matching "Friendship 7 to Apollo 11…". (2) `_dedupeStreamItems` (called from `_streamResult`, so both fresh and cached paths) collapses duplicate matches keyed on `_svc`+name+line2 — e.g. Bandcamp returning the same album twice — while different editions (which differ in name, "(Hi-Res)" vs "(Album)") are kept. Duplicate albums in the *feed itself* (ListenBrainz/MusicBrainz listing one release twice, sometimes as two release-groups) are collapsed by `_dedupeReleases` in `_sortReleases`, keyed on normalised artist+album+date (rg-MBID differs, so can't key on that). **Home-shelf playback fix (0.6.11) — IMPORTANT:** `homeForYou` must return a structure that does NOT vary by request quantity. The 0.6.3–0.6.10 version returned flat cards for the carousel (qty≤50) but `_buildItems` (week headers + per-week sub-feeds) for the "show all" (qty 25000). Play commands re-traverse the feed by `item_id` with a *different* quantity than the view used, so the path landed on the wrong node and no play command was sent — streaming playback from the home shelf silently failed (browse worked because it used the carousel quantity). Reverted `homeForYou` to ALWAYS flat (capped 50) for both carousel and click-in; week dividers stay only in the main menus. **Rule: anything reachable by a play/drill `item_id` must be quantity-stable.** **Grid view (0.6.15):** week-divider headers now get `image => ICON`. Material's grid detection counts headers; an image-less item set `haveWithoutIcons` and disabled the grid/list toggle for the whole page. With every item carrying an image the grid view stays available (same trick as the Listen to Later plugin's `_header`). **Wide-character crash fix (0.6.15):** detail pages for releases with CJK/emoji titles returned an EMPTY response (no data) — only when a Last.fm key is set. `getLastfmTags` built its cache key from the RAW `$artist`/`$album` (the only one of our cache keys that does), and those JSON strings carry the utf8 flag; `Slim::Utils::Cache`→`DbCache::_key` runs `Digest::MD5::md5_hex($key)`, which dies "Wide character in subroutine entry" for code points >255 (Latin-1 titles ≤255 silently downgrade, which is why only CJK/emoji crashed). The die aborts the whole `items` dispatch → `Bad dispatch!` → empty JSON-RPC body → Material shows nothing. Diagnosed from `http://<lms>:9000/log.txt`. Fix: `utf8::encode($artist/$album) if utf8::is_utf8(...)` at the top of `getLastfmTags` (guarded so plain Latin-1 octets aren't double-encoded) — makes the cache key octets (md5-safe) and also fixes the per-byte percent-encoding in `_lastfmCall`. NB: when off-network, the LMS box is reachable as `http://plex:9000` (not the 192.168.1.234 LAN IP).
- **0.5.2** — Hardening from a code review: (1) **detail-page watchdog** — `_releaseDetail` sets a `Slim::Utils::Timers` timer (`DETAIL_TIMEOUT` 15s) that forces the merge/render if a streaming or MusicBrainz callback never fires (a hung/partial-failure search previously hung the whole page, including the already-fetched tracklist); `$finish` is idempotent so normal completion makes it a no-op. (2) **guarded cache write** — `$cache->set` in `_findPlayable` wrapped in eval so a Storable serialisation failure can't stop the `$callback` (another hang path). (3) **MBID validation** — the "View on MusicBrainz" `weblink` is only built for a well-formed UUID (it lands in a Material-rendered href).
- **0.5.1** — Better streaming match recall for awkward credits: (1) the service search query is now built from **normalised terms** (`$artistNorm $albumNorm`) so quotes/`&`/commas in multi-artist names don't make the search miss the album (e.g. `Lee "Scratch" Perry & Mouse on Mars`); (2) artist matching switched from bidirectional substring to **token-subset** (`_artistMatch`: every word of the shorter credit must appear in the longer), tolerating word order, `&` vs `,`, and partial credits — while title-contains-album still gates precision. (3) **Home-row icon fix:** the Material home extra now uses the recolourable `_svg.png` icon (as the browse menu does) instead of the install.xml colour tile, which rendered blank in the home row while other plugins showed theirs.
- **0.5.0** — **Material Skin home-page scrollable row** for the For You feed. New `HomeExtras.pm` subclasses `Plugins::MaterialSkin::HomeExtraBase` and registers a home "extra" (`tag => 'LBFForYou'`, `title => PLUGIN_LBF_FOR_YOU`, plugin icon); its feed → `Browse::homeForYou` returns a flat, 50-capped list of release cards (For You filters/sort, no weekly dividers/grouping — unsuited to a carousel). Registered in `Plugin::postinitPlugin`, gated on `MaterialSkin->can('registerHomeExtra')` (mirrors Qobuz/Bandcamp). Also **renamed "For You" → "New Releases for You"** (the `PLUGIN_LBF_FOR_YOU` string drives the browse menu item and the home row; the settings section header `PLUGIN_LBF_SECTION_FORYOU` was renamed to match). Pattern reference: Bandcamp `HomeExtras.pm`. Also added: **README.md** (GitHub docs — features, requirements/ListenBrainz account, defaults, home shelf), an install.xml **`<homepageURL>`** to the repo (shows as the "more info" link in Manage Plugins), and a colour **tile SVG** icon for install.xml so the Manage Plugins icon isn't blank (the existing icons are black silhouettes for Material's recolour and render blank in core Manage Plugins).
- **0.4.9** — The MusicBrainz line on the detail page is now a clickable `weblink` (**View on MusicBrainz**) that opens the release page in the browser, instead of plain text showing the URL. (Same `weblink` mechanism as the top-level Plugin Settings entry.)
- **0.4.8** — **Caching** so revisits don't re-search (uses `Slim::Utils::Cache`, persistent across restarts). Streaming matches keyed by `lbf:stream:<release_mbid>` (TTL 7 days found / 1 day no-match); MusicBrainz tracklist+genres keyed by `lbf:mb:<mbid>` (30 days found / 1 day empty). OPML item `url` coderefs can't be Storable-serialised, so streaming items are cached with `url` stripped + a `_svc` tag and the play coderef is **reattached on read** (`_rebuildStreamItems`: Qobuz→`QobuzGetTracks`, Bandcamp→`get_album`; items whose service is gone are dropped). Note: Qobuz's own API also caches ~5 min internally; this is our durable layer on top. **Barrier fix:** `_releaseDetail` now counts both async tasks (streaming + MB) up front — a cache hit fires its callback *synchronously*, so the old per-task `$pending++` let the barrier complete after the first finished and drop the other's data (symptom: tracklist missing on cached revisits).
- **0.4.7** — Replaced manual drill-in pagination with **native XMLBrowser windowing**: `_buildItems` (and the artist-group drill-in) now return the full filtered+sorted list as one level; LMS/Material window/scroll it. Removed `_paginate`, `PAGE_SIZE`, and the next/prev page strings. Reason: manual pages were separate menu nodes, so Material's in-list search/filter only saw the current page — a single level lets the filter span every item, and gives Material's native scroll + prev/next pager. (Settings filters — artwork/type/VA — were already global, applied in `_filter*` before building items.)
- **0.4.6** — UI polish: (1) fixed mojibake in the week divider — it used a **literal em-dash** in the Perl source (rendered as `â€"`); all non-ASCII must use `\x{}` escapes (as the rest of the file does), decorative dashes dropped; (2) list rows now show **year only** `(YYYY)` instead of the full release date (the week divider carries the date) — matches LMS album-year convention; (3) pagination gained a **Previous page** link (top of page 2+) alongside Next, both using arrow glyphs (`\x{25C0}`/`\x{25B6}`) instead of the plugin logo. NB: pagination is drill-in, so Previous pushes a new level rather than popping — the back button still works; revisit with native XMLBrowser windowing if the stacking becomes annoying.
- **0.4.5** — Streaming match disambiguation: `_albumMatches` (replaces `_titleMatch`) now requires the candidate **title to contain our album title AND the artist to match** (bidirectional substring to tolerate "feat."/credit variants). Fixes wrong-artist results like "Bending Light" pulling in unrelated same-titled albums. Artist is passed through `_findPlayable` → adapters as `$artistNorm`; falls back to title-only when our artist is empty.
- **0.4.4** — Fixes + view options: (1) **sort** is now applied client-side in `_sortReleases` — release date is **newest-first** (the API returned oldest-first), confidence highest-first, artist/album A–Z; (2) **weekly dividers** (`week_dividers`, default ON) add a "— Week of D Mon YYYY —" divider per week in the date-sorted view (`_buildWeekly`/`_weekStart`, Monday-based, via `Time::Local`), taking precedence over group-by-artist for the date sort; (3) top-level menu now has a **Plugin Settings** entry (`weblink` to settings.html) → For You / All Releases / Plugin Settings; (4) **artwork-only filter fix** — `coverArtUrl` now requires `caa_release_mbid` (it used to fall back to the always-present `release_mbid`, so the filter never excluded art-less releases and thumbnails 404'd).
- **0.4.3** — Streaming matches are now shown **inline on the detail page** (no "Find on streaming services" tap): `_releaseDetail` runs the streaming search and the MusicBrainz lookup in parallel and merges both into one callback (base meta → streaming matches → genres → tracklist). Each result uses the **service's own logo** as its thumbnail (`_pluginIcon` → `_pluginDataFor('icon')`) so the source is obvious; dropped the `"Svc:"` name prefix. Trade-off: the detail page now waits on the streaming search(es) before rendering, so it can be a touch slower (Bandcamp scraping is the slowest).
