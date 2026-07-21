# ListenBrainz Fresh Releases — LMS Plugin

## Project Overview
A plugin for Lyrion Music Server (LMS) that browses ListenBrainz Fresh Releases. It provides a personalised "For You" feed and a global "All Releases" feed. Filtering is controlled via settings, and the browse menu stays intentionally simple. The current build targets LMS v9.x and has been tested with Material Skin.

## Feature Summary & Release Posts (social media)

**Maintain this section.** Two living artefacts for announcing the plugin:
1. **Overall feature summary** (below) — the social-media / GitHub Pages "drop page" copy. **Update it whenever a key feature is added, changed or removed** (not for bug fixes). Keep it key-features-only, user-facing, no internals.
2. **Per-release "What's new" post** — when cutting a release, generate a social post in the fleet **house layout** — the *same structure* as the launch/"Introducing" post, just scoped to what changed since the last main release (NOT a blockquote, NOT a "Fixes & polish" list). Build the bullet list from the new **CHANGELOG.md** entries. Reproduce this structure:

   ```
   🎵 What's new in <Plugin Name> — for Lyrion Music Server (LMS)

   <Paragraph 1: conversational hook leading with the headline new feature.>

   <Paragraph 2: second angle covering the rest of the changes, in prose.>

   ✨ What's new
   • <Short label> — <plain-English description of a new/changed feature>
   • … (one bullet per notable feature; a single "smarter/tougher matching" bullet may fold in the notable bug fixes)

   Works on LMS 9.x, best with the Material Skin. <optional playback line.> Free and open source.

   👉 Full details & install: https://simonarnold002.github.io/<Repo>/

   #LyrionMusicServer lms squeezebox <space-separated plain service/keyword tags>
   ```

   Key elements: the `🎵 What's new in … (LMS)` header (NOT "Introducing", NO version number in it), TWO prose paragraphs (not bullets), the `✨ What's new` header with `•` bullets scoped to this release, the "Free and open source" line, the `👉 Full details & install:` link to the **bare Pages root** (NOT repo.xml), and the final tag line where ONLY `#LyrionMusicServer` is a hashtag and the rest are plain words.

### Overall feature summary (keep current)

> **ListenBrainz Fresh Releases — for Lyrion Music Server.** Turn your ListenBrainz listening into a living, playable music feed inside LMS.

- **New Releases for You** — personalised feed of fresh releases from artists in your ListenBrainz history (needs username + token). Newest-first, grouped by week, tap-through detail pages. **Optional MuSpy** — add a MuSpy user ID (public, no password) to fold in releases from the artists you follow there; more tailored since you pick the artists, and overlaps with ListenBrainz are shown once. MuSpy is upcoming-heavy, so it has its own **upcoming** switch (on by default, independent of the feed's Include-Upcoming) and a **how-far-ahead** limit (default 12 months).
- **All Releases** — the global ListenBrainz fresh-releases feed (no account). By-week landing page to jump to any week.
- **Created-for-You Playlists** — your **Weekly Jams / Weekly Exploration / Daily Jams** as fully-streaming **Play-all** lists; every track matched **library-first**, then streaming.
- **People You Follow** *(optional; toggle in Settings → General, default on)* — a whole section built from what the people you follow **actually play** (public listen-stats — username only; **one-vote-per-follower** breadth ranking). **Trending Tracks** (weekly, Play-all, owned-excluded, album-level so a full-album play can't flood it) + **Trending Albums · This Month / · This Year** (tap-through album pages with art/date/type). Plus **Recommended** — the tracks they **recommend/pin** (needs a token; the feed is private), one newest-first **new-music-only** Play-all list with **day dividers**, accumulating so recs aren't lost as the feed rolls. Off = nothing here is fetched, cached or warmed.
- **Don't Stop The Music — two auto-DJ mixers** — **ListenBrainz Radio** (seeds from what's playing and evolves through similar artists) + **Recommended for You** (personalised CF picks, shuffled). Owned copies first, no per-session repeats, varied artists.
- **Rich release detail pages** — artist **photo + biography**, **tracklist** with durations, **genres**, tags, **View on MusicBrainz**, and inline **one-tap streaming matches**.
- **Direct streaming playback** — matched albums/tracks play from **Qobuz / Tidal / Bandcamp / Deezer**; you choose the per-service search order.
- **Block artists** — one tap hides an artist from every feed.
- **Material home shelves** — optional New Releases for You / Playlists / All Releases home rows.
- **Your taste** — filter by type / artwork-only / Various Artists; **per-view sort** (a "Sorted by…" toggle in each list's Options section — Release Date / Artist / Album Title, kept within the weekly W/C headers); release-window; cached & pre-warmed (instant), **no extra server software**.

**Requirements:** LMS 9.0.0+ (Material Skin); ListenBrainz account + token for personalised features (All Releases needs nothing); optional Qobuz/Tidal/Bandcamp/Deezer (playback), MAI plugin (artist photos+bios), free Last.fm key (genre/bio fallbacks). Every optional add-on degrades gracefully.

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
├── make_readme_html.py                # Zero-dep Markdown→HTML generator: README.md → README.html (styled) + index.html (Pages redirect)
├── match_check.py                     # Faithful port of _norm/_artistMatch/_trackMatches — paste "LB_artist | LB_title || file_artist | file_title" pairs to see MATCH/MISS + which rule fired; folds diacritics by default (matches shipped 0.9.57 _norm), --fold shows pre-fold vs shipped compare (local-match debug)
├── fetch_playlist.py                  # Dumps a user's created-for playlists from the public ListenBrainz API as match_check-ready lines (local-match debug)
└── fetch_feed.py                      # Dumps a user's SOCIAL FEED (recommendations/pins from followed users) as match_check-ready lines; needs the token (arg 2 or LB_TOKEN) — the follow-feed analogue of fetch_playlist.py
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
0.9.120

- **FLEET MATCHER SYNC: a decorative `!` is punctuation, not the letter i; `&`/`+` fold to "and" (0.9.120).**
  Ported from Discography 0.44.19/0.44.23, where the bug was found in the field. Landed across
  **DSC / LBF / PFR / SH in one session**; `matcher_sync_check.py` exits **0**. LL untouched (its `_norm`
  is the pinned legacy ASCII variant and carries none of these substitutions).
  - **`!` folds to a letter only when TOKEN-INTERNAL** (`s/(?<=\w)!(?=\w)/i/g`): `P!nk` -> `pink`, while
    `Wham!`, `Panic! At The Disco` and `Godspeed You! Black Emperor` shed the mark. Previously the
    unconditional fold made a name spelled WITH the mark disagree with the same name spelled WITHOUT
    it, and `_albumMatches`' artist gate is MANDATORY — so on Discography every streaming candidate was
    rejected and the page read "No releases found" for a correctly resolved artist.
  - **`$` and `@` stay UNCONDITIONAL, deliberately.** Scoping them too broke `$uicideboy$` -> `suicideboy`
    (that trailing `$` is an *s*). Caught by a cross-repo BEHAVIOURAL harness, not by the sync check —
    which compares text and would have reported four identical copies of the bug.
  - **A name of nothing but marks keeps the old fold**, so `!!!` still keys `iii`. Letting it empty would
    make `_artistMatch` (which returns 0 on an empty side) reject every candidate — the same bug again.
  - **`&` and `+` -> "and"**, the same "symbol becomes the word it stands for" family as `$`->s. Without it
    one act arriving from two services as "X & Y" and "X and Y" became two rows.
- **ALL match-decision caches bumped** — `lbf:stream` 19->20, `lbf:track` 7->8, `lbf:pl:resolved` 7->8.
  The keys are only partly `_norm`-derived, but every one of them stores a DECISION computed with the old
  normaliser, and the outer `lbf:pl:resolved` wraps the inner `lbf:track` — bumping the inner alone does
  nothing, because an outer hit never reaches it.

- **Code-review fixes: two transient-failure cache-poison paths (0.9.119) — no cache-version bump.**
  Pre-commit review of the People You Follow / DSTM work. Both are the "never cache a network
  failure" class; logic-only, `perl -c` clean (Browse + API + DSTM via scratchpad stublib), matcher
  untouched (`matcher_sync_check.py` N/A). Verified in-process against the REAL subs with a driveable
  HTTP/cache/prefs harness (all cases pass).
  - **`DSTM::_recommendedFill` no longer caches an EMPTY recommended pool.** `getRecordingMetadata`
    is onDone-ALWAYS (0.9.113/0.9.117), so a transient metadata outage resolves onDone with `{}` →
    empty `@pool`. That empty pool was cached at `RECS_TTL` (1d), pinning the Recommended DSTM mixer
    empty for a day. Now `$cache->set` is guarded on `@pool`; an empty result is still SERVED (so the
    mixer falls through / retries next top-up) but not persisted. **This completes the 0.9.117
    "dropped the dead `$onError` call-site args" refactor** — that pass claimed "no behaviour change"
    but MISSED this DSTM call site (it still passed a 4th arg, which the new onDone-always signature
    silently ignored, routing failures through onDone → the poisoned cache). The dead 4th arg is now
    removed too.
  - **`API::getLatestListenTs` caches ONLY a genuine answer.** The success handler unconditionally
    cached `$ts` (24h) even on a 204 No Content / empty / odd-shape 2xx — which reaches the SUCCESS
    callback (as `_getUserStats`' explicit 204 handling proves), pinning a follower as `ts=0`/unknown
    for a day. A `$got` flag now gates the `$cache->set` on a valid `payload`; a real `0` is still
    cached, but 204/empty/parse-error/network-error are treated as transient-unknown and not cached
    (unknown keeps the follower active — the stale-filter's safe default). Error-callback comment
    corrected (204 lands in the success path, not the error path).
  - **Stale-comment fix in `_findPlayableTrack`** (comment-only): the note claimed the outer
    `lbf:pl:resolved` key is "deliberately NOT bumped" and "playlists don't render years", but since
    0.9.114 playlists ARE year-enriched and that key WAS bumped to `:7:`. Rewritten to match reality.

- **"People You Follow" section is now optional (0.9.118).** New boolean pref `people_follow`
  (default **1** — the pref is new, so ON applies to every install on update; no behaviour change
  unless switched off). ONE master switch gating THREE places, so a disabled section does zero
  work: (1) `topLevel` — the `@people` block is built only `if ($username && $prefs->get('people_follow'))`,
  so the section header + all four tiles are absent and their resolve coderefs (`resolveTrending`/
  `resolveTrendingAlbums`/`resolveFollowFeed`) are unreachable; (2) `warmCache` — `_warmFollow` +
  `_warmTrending` are skipped, so no following/stats/feed calls, resolves or cache writes on the
  startup/daily/forced warm; (3) `fetchUnmatchedPlaylists` — the token-gated follow-feed append is
  also gated on the pref (no `getFollowFeed` for it). Settings: General checkbox
  `pref_people_follow` (`PLUGIN_LBF_PEOPLE_FOLLOW_SETTING`), added to `Settings::prefs()` and
  `Plugin.pm` init. No cache-version bump (pure gating; nothing about the cached shapes changed).
  `perl -c` clean (Browse + Settings; Plugin's only stub-env error is the LMS `main::WEBUI`
  constant, past the edit).

- **Code-review fixes on the People You Follow build (0.9.117) — no cache-version bump.** Pre-commit
  review of the 0.9.99–0.9.116 trending work. All logic-only; `matcher_sync_check.py` still exits 0
  (nothing touched the shared matcher); `perl -c` clean on Browse + API (scratchpad stublib).
  - **Trending Albums streaming gate: watchdog-truncated build now caches SHORT.** The gate's
    `$finish` called `$settle(\@keep, 0)` (full 7d/30d TTL) whether it fired from normal completion
    OR the `PLAYLIST_TIMEOUT` watchdog — so a cold build that timed out mid-gate pinned a partial
    album list for weeks. Added a `$timedOut` flag the watchdog sets before `$finish`; a timed-out
    finish now settles at `PLAYLIST_INCONCLUSIVE_TTL` (1h) so a healthy build replaces it soon.
  - **`_resolveTrending` `$empty` now caches the "no data" outcome SHORT.** The success path already
    caches an empty resolve, but the `$empty` short-circuits (not following anyone / all stale / no
    candidates) rendered text and returned without writing `$rkey` — so every browse re-ran the whole
    follower aggregation. `$empty` gained a `$cacheEmpty` flag: the three genuine no-data callers pass
    it (writes `{items=>[],total=>0}` at 1h TTL); the network-error `onError` caller does NOT (a
    transient failure must never pin the list empty).
  - **`topLevel` no longer holds the whole menu on the All Releases fetch.** The menu inlines the
    All Releases weeks from `getFreshReleasesAll` (usually a synchronous cache hit); on a cold miss a
    slow LB delayed the ENTIRE menu incl. Settings until `FEED_TIMEOUT` (10s). Added a
    `TOPLEVEL_ALL_WAIT`(5s) local watchdog + idempotent `$finish` (guard + `killSpecific`): if the
    feed is slow the menu renders with the drill-tile fallback first, inlined weeks appear next open.
  - **`_fanFollowers` re-entrancy guard.** With warm-cached per-user stats `$fetch` calls back
    synchronously, so the completion's `$pump->()` recursed one level per follower (≤FOLLOWER_MAX
    deep, whole downstream build on that stack). A `$pumping` flag makes a synchronous re-entry a
    no-op and lets the outer `while` keep launching iteratively — same work, flat stack.
  - **Dead `$onError` removed from `getRecordingMetadata`/`getReleaseGroupMetadata`.** Both are
    onDone-ALWAYS (best-effort enrichment: chunk failures fall through to onDone with whatever was
    gathered, cached soft-hits included). The `$onError` default was never invoked and callers'
    error subs were dead (onDone already continues the chain) — param + the 5 dead call-site args
    dropped. No behaviour change.

- **Stale-follower filter (0.9.116).** `_activeFollowers` (reuses `_fanFollowers`) drops followers
  whose `API::getLatestListenTs` (GET /1/user/<u>/listens?count=1 → `payload.latest_listen_ts`,
  cached `lbf:lastlisten:1:` 24h; errors NOT cached) is older than `FOLLOWER_STALE_DAYS`(183) —
  wired into `_resolveTrending` + `_buildAlbumsData` between getFollowing and the stats fan-out.
  Unknown activity (0) always KEEPS the follower (private feed/transient error can't empty the
  lists). Bumps: trending resolved `:8:`, albums `:6:`. Tile-label pass was 0.9.115 (covers retitled
  Trending Tracks/Recommended Tracks via make_covers.py, row texts Weekly/Your Followers, follow
  tile's matched-count line2 removed; PLUGIN_LBF_FOLLOW_TILE new).

- **Playlist years (0.9.114).** The Created-for-You playlists now show " (YYYY)" — `resolvePlaylist`
  AND the warm both run `_enrichYears` before `_resolveTracks` (same pass as the follow feed).
  **`_enrichYears` is now the year GATE:** every enriched track leaves with a `year` KEY (possibly
  ''), which is what lets `_resolveTracks` apply the item-`_year` fallbacks; un-enriched sources
  (DSTM pools, unmatched-debug) still have no key → no years (DSTM unaffected). Library items now
  carry `_year` from the LMS tag year (`_localItemHash` 6th arg, `_titlesSearch` tags `ulay` — the
  piece parked in 0.9.110; no lbf:track bump needed, library entries live 1d). `lbf:pl:resolved:7:`
  (years bake into cached names; tiles show no count until the warm/open re-resolve — transient).

- **Yearless metadata = SOFT cache hit (0.9.113) — the poisoned-cache class.** `getRecordingMetadata`
  and `getReleaseGroupMetadata` cached whatever LB/MB returned for 90d "immutable" — but a missing
  date is NOT immutable (LB backfills first_release_date; MB RG dates land post-release), so a lag-
  window fetch pinned `year=''` for 3 months and defeated the whole date ladder (proven live: the
  server rebuilt through ALL the 0.9.112 code — line-number-fingerprinted — and still served dateless
  Rennicks/Suede rows while the API returned their dates). Both subs now treat a cached entry without
  a year as a soft hit (kept as fallback, mbid refetched) and write yearless results at
  `RECMETA_YEARLESS_TTL` (1d). Self-heals existing poisoned entries — no key bump; dated entries keep
  90d (no extra traffic in the normal case). Trending resolved key `:7:` (rebake names on install).
  **Repro/testing lessons:** scratchpad stublib now has STATEFUL Cache (get/set/TTL recorded) + Prefs;
  `rlib/` overlays REAL curl-backed SimpleAsyncHTTP + REAL JSON::PP `from_json` — the stub's no-op
  `from_json` produced a false "plugin code broken" repro. Fingerprint the deployed build via the
  log's `Sub::Name (LINE)` numbers vs the local source.

- **Targeted candidate metadata fill (0.9.112).** The pre-grouping recording→album map is capped at
  TREND_MAP_CAP(250) by breadth and breadth-1 ties fall outside it ARBITRARILY — a chosen candidate
  could reach the final 50 with NO metadata (year/rg never fetched; the Stephen Rennicks case — its
  `first_release_date` existed all along). `_resolveTrending` now runs `$fillMeta` after candidate
  selection: getRecordingMetadata for exactly the chosen candidates missing year/rg (≤80 mbids,
  recmeta-cached, 0–2 requests), then `$fillDates` (RG pass, moved into a sub since fillMeta can add
  rg mbids) → name-search → resolve. Trending resolved key `:6:`.

## People You Follow — 0.9.100–0.9.111 addenda (supplements the 0.9.99 section below)

- **Blocked artists apply to the whole section (0.9.111).** `_trendBlocked($artist,$ambid,$set)`
  shims a row into the shared `_isBlocked`. Applied BOTH at build (trending candidates +
  album aggregate — no wasted resolves/gate searches) and at RENDER (`_trendingResult`,
  `_trendingAlbumsResult`, `_followResult` — immediate effect, the NRFY render-time rule).
  Resolved items are tagged `_artist`/`_amb` in `_resolveTracks` (like `_created`) so cached
  lists filter too; keys bumped `lbf:trending:resolved:5:` / `lbf:follow:resolved:5:` to bake
  the tags (pre-tag cached items pass through unfiltered until re-resolve — deliberate). This
  is THE answer to unblockable functional-audio uploads ("10 Hours of Ocean Waves…"): they're
  on streaming (gate keeps them) and NOT in MB (no genre/mood data exists to filter on) — so
  the user blocks the uploader once from the album's detail page (name-only block works).

- **Service-year fallback (0.9.110) — the LAST date source.** Unmapped-on-LB + absent-from-MB items
  can still get a date from the STREAMING catalogue: every matched item is tagged `_year` by the six
  adapters via `_svcYear` (probes Qobuz `release_date_original`/`released_at`, Tidal `releaseDate`,
  Deezer `release_date` — field names VERIFIED against lms-plugin-tidal/lms-deezer sources; plain
  scalar, survives `_cacheStream`/track caches). Consumers: `_resolveTracks`' year-append (gated on
  `exists $tr->{year}` — since 0.9.114 the playlists are enriched too, so the gate now distinguishes
  enriched lists from DSTM pools rather than keeping playlists dateless) and the albums gate (fills
  `$a->{year}` from the first match). Date-source ladder is
  now: LB stats/recording metadata → MB release-group date → MB name-search → **service catalogue**.
  Bumps: `lbf:stream:19`, `lbf:track:7`, trending resolved `:4:`, albums `:5:`; `lbf:pl:resolved:6:`
  deliberately NOT bumped (playlists render no years — avoid a pointless 250-track re-match).

- **Streaming gate on Trending Albums (0.9.109).** `_buildAlbumsData` (now takes `$client`) resolves
  each ranked album via `_findPlayable` (same call + cache as the detail page — gated albums open
  instantly) and DROPS albums with no streaming match anywhere (Simon: "any without streaming matches
  should be ignored" — kills 10-hour-noise/off-catalogue rows). Pool = TRENDING_MAX+10 head-room;
  slots keep rank order; early-stop at 50 kept; conc 5; PLAYLIST_TIMEOUT watchdog. Degrades safely:
  no client/adapters OR gate-keeps-zero → UNGATED result at PLAYLIST_INCONCLUSIVE_TTL (1h). Key
  `lbf:trending:albums:4:` now carries the service order.
- **Collab credits & MB search (0.9.109).** MB fielded artist search returns 0 for a JOINED credit
  ("Julianna Barwick & Mary Lattimore") while either name alone scores 100 (verified live) — and some
  collabs are entered in MB as ONE unique artist. `getReleaseGroupByName` tries the full credit, then
  each collaborator (≤3 terms). **`API::splitArtistCredits` is THE one collab splitter**
  (& + , ; x vs feat ft featuring with; deliberately NOT bare "and" — real band names);
  `Browse::_bandcampArtists` (the original 0.9.56 Panda Bear & Sonic Boom fix) now delegates to it.
  LBF-local, not in the fleet matcher-sync set — but a port candidate for Discography's artist-first
  fetch if collab discographies ever miss there.

- **Refresh = the shared `_refreshItem` ONLY** (0.9.107). The bespoke `refreshTrending`/`refreshTrendingAlbums`
  subs (drilled into a new page — no `nextWindow`) are GONE; `_refreshItem` gained `$which` values
  `trending` (clears `_trendingResolvedKey`) and `trending_albums` (clears `_albumsDataKey($range)`),
  reloading in place like every other feed. **Rule: never hand-roll a per-feature refresh row.**
- **Unmapped-listen gap — THE key data lesson (0.9.108).** LB listen-stats rows are only as good as
  each follower's LISTEN MAPPING: unmapped listens return `release_group_mbid`/`caa_id` = null (the
  same album can arrive both mapped and unmapped from different followers). NRFY never sees this (its
  feed is MB-derived). Fixes: `_aggregateAlbums` merges mapped+unmapped rows of one album (two-pass
  text-key index + per-field `||=` backfill); rows still mbid-less after aggregation are resolved via
  **`API::getReleaseGroupByName`** (fielded ws/2 release-group search, `_mbBase()` mirror-aware,
  score≥90, mirror-0-results→public retry, cache `lbf:rgbyname:1:` 30d/1d) → mbid+date+type;
  artwork falls back to `coverartarchive.org/release-group/<mbid>/front-250` when there's no
  caa_release_mbid; Weekly Tracks candidates missing a year get the same name-lookup (bounded 25/build).
  Track years also read `recording.first_release_date` (0.9.107 — the `release` object in LB recording
  metadata is often EMPTY).
- **Trending Albums sort (0.9.108):** NRFY-style Options section on both album lists —
  `_trendingSortToggle`, durable `trending_sort` pref shared by month/year, modes
  Trending (breadth, default) / Release Date / Artist / Album Title, `nextWindow=>'refresh'`.
- **Cache keys current:** `lbf:trending:resolved:3:`, `lbf:trending:albums:3:` (bump BOTH the shape
  and the baked-name layers when year/date sources change — the 0.9.106 miss), `lbf:recmeta:2:`,
  `lbf:rgmeta:1:`, `lbf:rgbyname:1:`.

## People You Follow — Trending (0.9.99)

A new top-level **"People You Follow"** browse section (`Browse::topLevel`) built from what the
users you follow **actually PLAY** (public listen-stats) — distinct from *Recommended by People You
Follow* (the social FEED). The Recommended tile is **relocated into this section**. Gated on
**`username` only** (all endpoints public — no token).

- **API** (`API.pm`): `getFollowing` (`GET /1/user/<u>/following` → bare username strings, cached
  `lbf:following:` 12h); `getUserTopRecordings`/`getUserTopReleaseGroups` (shared `_getUserStats` →
  `GET /1/stats/user/<u>/{recordings,release-groups}?range=…` — **`release-groups` is HYPHEN, NO
  trailing slash**; **204 = empty/private**, cached-empty, never an error; per-user cache
  `lbf:userstats:{rec,rg}:<range>:<user>` 24h ≈ LB's recompute cadence). `getRecordingMetadata`
  extended to `inc=artist release` so it returns `release_group_mbid` (the track→album join,
  editions collapsed) — additive, older callers unaffected.
- **What's Trending (this week)** — a Play-all playlist tile (`_trendingTile` → `resolveTrending` →
  `_resolveTrending`). Fans out each follower's weekly top recordings (`_fanFollowers`, bounded
  `FOLLOWER_FANOUT`=6, `FOLLOWER_MAX`=250 cap, `FANOUT_DEADLINE`=30s watchdog so a slow LB never
  hangs the browse), maps recordings→albums, then `_buildTrendingCandidates` ranks. **Ranking is
  one-follower-one-vote / equal weight:** every signal is *distinct-follower breadth*, never play
  volume — a repeat/heavy or single-track-spammer listener counts once per album. Trends at the
  **release-group (album)** level and represents each album by its **highest-follower-breadth
  track** (so a full-album play doesn't flood the list; singles/EPs are 1-track albums). Candidates
  ordered unique-artist-first then repeats (lean-week fallback), owned tracks dropped via
  `_resolveTracks(…, 'exclude')`, capped `TRENDING_MAX`=50. Resolved cache
  `lbf:trending:resolved:1:<user>|<svc-order>` (`TREND_RESOLVED_TTL` 24h; svc-order re-keys on a
  service change; refreshed by the daily warm). **LESSON:** never name a lexical `my $a`/`$b` in a
  scope containing a `sort` block — it shadows sort's package `$a`/`$b` and silently broke the
  representative-track pick (caught by a unit test, `tools/` prototype below).
- **Trending Albums · This Month / This Year** — two browse lists (`_trendingAlbumsTile` →
  `resolveTrendingAlbums` → `_buildAlbumsData`/`_aggregateAlbums`), same breadth ranking straight
  from `release-groups` stats (`range=this_month`/`this_year`). **Show-all** (owned NOT filtered —
  trending is about popularity). Rows (`_trendingAlbumRow`) reuse `_releaseDetail`, which resolves an
  album to streaming from just its `release_group_mbid` (no tracklist needed) — so no pre-resolution;
  each album resolves on tap like a fresh release. Ranked aggregate cached `lbf:trending:albums:1:…`
  (`TREND_ALBUMS_TTL` 6h; plain hashes only — rows with their coderef `url` are rebuilt each open).
- **Warm**: `_warmTrending` (chained in `warmCache` after `_warmFollow`) pre-resolves the tracks
  list (needs a player) and pre-builds both album aggregates (no player needed).
- **Covers**: `menu-trending.png` (FIRE) + `menu-trending-albums.png` (MAGENTA) via
  `tools/make_covers.py`. **Debug/prototype tool**: `tools/fetch_trending.py` implements the identical
  breadth algorithm against the live public API (username [range] [max]) — the reference for the
  aggregation, runnable without LMS.

## Recommended by People You Follow (0.9.65; **new-music-only + single day-divided list in 0.9.71–0.9.72**)

**ONE** new-music list built from the ListenBrainz **social feed** — the
`recording_recommendation` / `recording_pin` events from the users you follow. Playable
container tile in the **Created for You** section, gated on `username` AND `token` (the
feed endpoint is private). The tile drills into a single newest-first track list with
**day-divider rows**; every track the user **already owns is excluded** (the point of the
feature — pure discovery). **History note:** a weekly rolling-4 layout was tried in 0.9.70
but abandoned — a real user had ~35 recs spread ~1/week across many months, so pruning to
the newest 4 weeks hid ~31 of them. 0.9.71 keeps them all in one accumulating list.

- **API** (`API.pm`): `getFollowFeed` → `GET /1/user/<user>/feed/events?count=75`
  (token required). `_parseFollowFeed` keeps only the track-bearing event types
  (`%FOLLOW_TRACK_EVENT`) and normalises to `{ artist, title, album, recording_mbid,
  recommender, created }` (the **`created` epoch** drives the day dividers),
  **newest-first**, **deduped** by `m:<mbid>` else `t:<lc artist|title>`.
  `recording_mbid` pulled from `additional_info` / `mbid_mapping` / the pin wrapper via
  `_firstRecMbid` (~1 in 6 recommendations carry none — still usable, they match by
  artist/title). Dual short/fallback cache `lbf:follow:feed[fb]:<user>` (`FEED_TTL` /
  `FEED_FALLBACK_TTL`). `force => 1` skips the working-READ (the warm passes it).
- **Accumulating source store (`Browse.pm`).** `_mergeFollow` merges each fetched track
  into a persisted flat store `lbf:follow:accum:1:<user>` = `{ tracks => [newest-first] }`
  (`FOLLOW_STORE_TTL` = 90d, refreshed every merge), **add-if-new** (dedup via
  `_followTrackKey`) so a rec that later scrolls out of the 75-event feed window isn't
  lost, sorted by `created` desc, **capped at `FOLLOW_KEEP_MAX` (500)**. So the list can
  exceed the feed window — but it **builds forward from first capture** (can't backfill
  pre-install recs beyond whatever's in the current 75-event window). NB: the 75-event
  feed is mostly non-rec events, so the rec slice is small; a sparse follower set yields a
  short list.
- **Browse UI**: `_followTile` (playable `type=>'playlist'` container — Play/Add queues
  the whole list — `MENU_FOLLOW` cover, match count on line2 from the resolved cache) →
  `resolveFollowFeed` → `_resolveFollow` → `_followResult`. Single resolved cache
  `lbf:follow:resolved:3:<user>|<svc-order>` (`_followResolvedKey`, no per-week key now),
  **content-validated by `_followSig`** (md5 of the ordered track set). **`_followSig`
  MUST `utf8::encode` before `md5_hex`** — the feed is full Unicode and `md5_hex` dies on
  any code point > 255 ("Wide character in subroutine entry"), which hung the whole open
  (0.9.66). **No-player invariant:** `_resolveFollow` is shared by the open path and the
  warm but **must NOT** gate on `$client` — on a cache miss it always resolves-and-reports
  (like createdfor `resolvePlaylist`), so the browse level renders even with no player;
  only `_warmFollow` gates on `$client` before calling it. Retires the `:1:` (old single)
  and `:2:` (weekly) resolved keys and the weekly subs.
- **Day dividers (0.9.72).** `_followResult` groups the owned-excluded matched tracks by
  day (`_dayOf($created)`, already newest-first) and inserts a **day-divider header** before
  each day, styled **exactly like the New Releases week dividers** for consistency (the user
  called out the earlier plain-text dashes as inconsistent): `_dayDivider` uses
  `_headerType()` (→ `header-basic` on Material ≥6.4.3, a clean non-actionable full-width
  divider; else `header`) with `image => ICON` (keeps the grid toggle enabled), plain text
  on non-header skins. Header support is detected via `_wantHeaders($feat)` — the `features`
  string is threaded from the tile's passthrough through `resolveFollowFeed` → `_resolveFollow`
  → `_followResult` (XMLBrowser doesn't forward request params to coderef sub-feeds — the
  0.6.15 gotcha). As in `_buildWeekly`, the older actionable `header` gets a per-day drill
  coderef (returns that day's tracks) so its forced "More" isn't an empty page; `header-basic`
  ignores it. **Play-all:** confirmed present in-view with these divider rows (the tile is
  also a `type=>'playlist'` container, so Play/Add there queues the whole list regardless).
  Each matched item carries its source `created` because `_resolveTracks` tags
  `$item->{_created} = $tr->{created}` (only the follow feed sets `created`; harmless
  elsewhere), which survives the Storable resolved cache.
- **Exclude-owned resolution.** Resolves via `_resolveTracks(..., 'exclude')` — a
  `_findPlayableTrack` libMode that **inverts `first`**: it probes the library (deferred
  idle-tick) and, if the track is **owned**, **drops it** — signalled as a 3rd `owned`
  callback arg (cached `{ owned => 1 }`, `LIBRARY_TTL`), NOT a stream miss; not-owned
  tracks stream (never falls back to the library). `_resolveTracks` counts owned and
  returns it as a 4th `$done` arg (older callers ignore it), so the page/tile **total =
  new tracks** (`scalar(@tracks) − owned`). Same matcher as the rest of the plugin, so it
  inherits the accent/punctuation/short-title edge cases (a narrowly-missed owned track
  can slip through as "new").
- **Daily cadence.** `_warmFollow` refreshes the store then resolves the whole list once
  if its sig changed (no-op when unchanged). Chained after the playlist queue drains in
  `warmCache`, no-op without a token, needs a player for the streaming API context.
- **"Play what's new" (0.9.73; reworked 0.9.74; row-type + freshness fix 0.9.75).** The "seen"
  marker (`lastSeen`, a newest-rec
  epoch) lives in a **PREF** (`FOLLOW_SEEN_PREF` = `follow_last_seen`), NOT the cache store — the
  0.9.73 version kept it in the store and it didn't reliably persist (the marker never stuck, so
  the row always showed the whole list AND its count/content disagreed). No play history needed —
  recs carry `created`, tagged onto matched items as `_created`. **Both the row's COUNT and its
  CONTENTS derive "new" from the SAME resolved items** (`_created > lastSeen`) — the earlier
  split (count from resolved `_created`, contents re-derived from the source store's `created`)
  was the bug where the card said "(30)" but opened empty. `_followResult` **baselines the pref to
  the newest matched `_created` on first render** (so the existing backlog is marked already-played
  and the card doesn't flood), then counts `_created > lastSeen` and, when any, **unshifts a "Play
  what's new (N)" row at the top** (per [[lbf-action-rows-placement]]) → `playFollowNew`.
  **0.9.75 — the row is a `type=>'link'` DRILL row, NOT a `type=>'playlist'` container:** the follow
  level is the tile's Play-all source, and a nested playable container there gets **re-expanded by
  Play-all and queues the new tracks a SECOND time**. The row's already-resolved, service-filtered
  items are **threaded through its passthrough** (`items => \@tracks`; the follow level is live/
  `cachetime=>0`, rebuilt each open, so passthrough is always fresh) — so `playFollowNew` reads them
  directly and the count↔content agreement no longer depends on a resolved cache that may have been
  **evicted between render and tap** (the resolved-cache read is now only a fallback). `playFollowNew`
  filters by `_created > lastSeen`, advances the pref to the newest matched `_created` (marks caught up
  → row clears), and returns a **PURE track list (no dividers/action rows)** so the drilled level is
  itself a proper Play-all container (the plugin's "a Play-all level must be tracks-only" rule).
  Strings `PLUGIN_LBF_PLAY_NEW` / `PLUGIN_LBF_NO_NEW`. LESSON: durable per-user state (a "last seen"
  marker) belongs in a **pref**, not `Slim::Utils::Cache` — the cache can evict and very large TTLs (the 90d
  used here) weren't retained; store TTL cut to 30d to match the proven `FEED_FALLBACK_TTL`.
- **Cover**: `menu-follow.png` ("People You Follow", `ROSE` gradient) via
  `tools/make_covers.py`. **Debug tool**: `tools/fetch_feed.py` dumps the raw feed as
  `match_check`-ready lines (needs the token: arg 2 or `LB_TOKEN`).
- **Inline sort toggle (0.9.88): by date OR by recommender.** A top-of-list toggle row
  (`_followSortToggle`, `MENU_SORT`) flips the durable `follow_sort` pref (default `date`) and refreshes
  in place (`nextWindow=>'refresh'`, so the choice sticks across visits). `_followResult` branches on it:
  `date` keeps the day dividers; `recommender` groups under a `_recommenderDivider` ("Recommended by
  <user>") per follower, **most-recent-activity-first** (both modes bucket the already-newest-first list
  in first-seen order). Matched items are tagged `_recommender` in `_resolveTracks` (like `_created`);
  resolved-cache bumped `:3:`→`:4:` to bake it in. A track shows under ONE person (dedup keeps the most
  recent recommender). Strings `PLUGIN_LBF_FOLLOW_SORT_REC`/`_SORT_DATE`/`_FOLLOW_BY`/`_FOLLOW_BY_UNKNOWN`.

## Created-for-You Playlists (0.8.0)

New **Playlists** browse section (`Browse::fetchPlaylists` → `resolvePlaylist`), gated on
`username` being set. Surfaces the ListenBrainz algorithmic playlists and turns each into a
fully-streaming, Play-all-able playlist.

- **API** (`API.pm`): `getCreatedForPlaylists` → `GET /1/user/<user>/playlists/createdfor`
  (no token needed to read; sent if present), parsed by `_parsePlaylistList` into
  `{ mbid, title, source_patch, last_modified }` (mbid from the `…/playlist/<mbid>`
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
  search (`_localByText` → `_titlesSearch` → `Slim::Control::Request::executeRequest(undef, ['titles', …])`)
  gated by `_trackMatches`. A hit returns a string `url` (the file URL) → playable + cacheable like
  a streaming item, tagged `_svc => 'Library'`. Because a file URL can go stale on a rescan, library
  hits (and any resolved playlist containing one, via `_playlistTtl`) cache only `LIBRARY_TTL` (1d).
  All DB access is eval-guarded → falls through to streaming on any hiccup.
  - **Two-pass text search — full-text-index-independent (0.9.67; pass-2 gate widened 0.9.68).**
    `_localByText` first searches the combined `"artist title"` term (selective; best recall when LMS's
    **Full-Text Search** index is present, since FTS spans artist/album/title). **But `titles search:`
    only resolves a multi-field term when FTS is enabled** — with FTS off/broken it degrades to a
    title-only `titlesearch LIKE`, so the combined term (artist words absent from the title) matches
    NOTHING and a whole playlist resolves **0-from-library** while the same tracks match on streaming
    (diagnosed live for a user with FTS disabled: 248/250 matched, all streaming, 0 library, owning the
    MP3s). So on a pass-1 miss, `_localByText` runs a **second, title-only pass**
    (`_titlesSearch($title, …, 100)`) — the bare title hits the title index regardless of FTS, and
    `_trackMatches` re-verifies the artist. **Pass 2 now runs on ANY pass-1 miss, not only `$n1 == 0`**
    (0.9.68): there are TWO ways pass 1 misses an owned track and only one gives zero candidates —
    (a) **FTS off** → combined term matches nothing → `$n1 == 0`; (b) **FTS on** → the fuzzy combined
    query returns candidates (`$n1 > 0`) but ranks the owned track outside pass 1's 20-row window
    (common title / deep library) → the wider, order-independent title-only pass rescues it. The old
    `$n1 == 0` gate silently missed case (b). Cheap despite the wider trigger: pass 2 is reached only
    on a **per-track cache MISS** and the daily warm pre-resolves, so a not-owned track pays one extra
    title query **once, in the background** (not per open). Skipped only when there's no separate title
    to try — artist empty (combined term already == title) or no title. NOT an MBID issue — bogus
    `MUSICBRAINZ_TRACKID` tags just miss tier 1, which already falls through correctly.
  - **FUTURE WORK — contributor-scoped `Slim::Schema` query (a tier 2.5, not yet built).** Both text
    passes above still go through the `titles … search:` **relevance** command, which ranks + windows
    (so a hit ranked past the window is simply absent — the reason pass 2 widened to 100) and is fuzzy
    (you can't ask it "title == X AND artist == Y"). The structural fix is to stop using the search
    command for tier 2 and instead run a **direct relational query** — the same idiom tier 1 already
    uses for MBID (`Slim::Schema->search('Track', { musicbrainz_id => … })`), extended to join `Track`
    → `Contributor` and filter on title **and** artist name in SQL: `->search('Track', { title match,
    'contributor.name' match }, { join => …contributor… })->all`. Properties that make it strictly more
    robust: **no window / no ranking** (you get every row satisfying both predicates, then `_trackMatches`
    picks the winner — a common title in a huge library can't rank the owned track out), and **FTS-
    independent** (a plain indexed WHERE on the normalised title/name columns behaves the same whether
    the full-text index is on, off, or corrupt). Slot it as tier 2.5 (after MBID, before the fuzzy text
    search, which stays as a backstop). **Why it's deferred, not done now — the real traps:** (1)
    **Normalisation mismatch** — our `_norm` folds diacritics/punctuation (0.9.57) but LMS's own
    `titlesearch`/`namesearch` columns use LMS's rules (no Turkish `ı`/curly-quote folding), so a raw
    equality can silently miss the accented/stylised catalogue this plugin exists to handle well — a
    `LIKE` + in-Perl `_trackMatches` re-verify is still needed, so you don't fully escape fuzziness.
    (2) **Contributor roles** — ARTIST vs ALBUMARTIST vs TRACKARTIST vs BAND: join too narrowly and you
    miss featured/compilation cases, too broadly and noise returns. (3) **Exact schema relationship/
    column names must be VERIFIED against the running LMS 9.x `Slim::Schema`** (they've drifted across
    versions) — a wrong DBIx join throws at runtime and the eval-guard would swallow it into a silent
    miss (worse than the current behaviour). (4) Same synchronous-DB-blocking class as tier 2, so it
    must sit behind the existing idle-tick defer (0.9.48) + per-track cache + warm. Prototype against
    the live server's schema before trusting the join. See [[lbf-local-match-debug-tools]].
- **Background warm (0.8.3):** `Plugin::postinitPlugin` schedules `Browse::warmCache` ~60s after
  startup, re-armed daily (`Slim::Utils::Timers`). It pre-fetches the playlist list and pre-resolves
  every playlist's track matches into `lbf:pl:resolved:*` (using the first connected player for the
  streaming-service API context), so the Playlists view and each playlist open instantly. Cheap
  daily: keyed by `last_modified`, real work only when a new week's playlist appears. The list fetch
  uses `force => 1` (0.9.23) so it always re-pulls rather than short-circuiting on a still-valid
  listing cache — required for the daily tick to actually discover Monday's new playlists.
- **Warm defers during a library scan (0.9.54).** `Plugin::_warmTick` now checks
  `Slim::Music::Import->stillScanning()` and defers (re-checking every `WARM_SCAN_RETRY` = 120s) rather
  than resolving against a half-scanned library. Without this, a warm that ran mid-scan found the
  local-library tier empty, resolved **every** owned track to streaming, and cached that all-streaming
  result for the resolved-playlist TTL — and later warms **skip** an already-cached playlist (the
  `$cache->get($rkey)` guard), so it stayed wrong until the weekly mbid change. (Symptom seen live:
  50/50 Qobuz, zero library hits, for a user who owned the tracks. It "worked on dev" because a
  dev library is already scanned when the warm fires.) NB: because a playlist containing any Library
  track takes the 1-day `LIBRARY_TTL` (a file URL can go stale on rescan), a library-first user's
  playlists re-resolve on each **daily** warm — intended, not the "only-weekly" cheap case.
- **Manual "Refresh playlist matches" (0.9.54).** A Refresh row at the **top of the Playlists view**
  (`Browse::fetchPlaylists`, `image => MENU_REFRESH`; NOT in Settings — matches the feed-refresh
  placement) → `Browse::refreshPlaylists` → `warmCache($client, force => 1)`. A `$force` flag is
  threaded through `warmCache` → `_resolveTracks` → `_findPlayableTrack` so it re-resolves past **both**
  the resolved-playlist AND per-track caches (the layered-cache trap), library-first. Async (~a minute,
  needs a connected player for the streaming API context); the tap confirms and re-matches in the
  background. Recovers immediately from a stale all-streaming result without waiting for the weekly
  rollover.
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
    `lbf:stream:10:` (7d found / 1d no-match / **1h inconclusive** since 0.9.41 — see the 0.9.41 note;
    `:7:`→`:8:` in 0.9.42 to add the ListenLater favurl, `:8:`→`:9:` in 0.9.43 to drop bogus Qobuz duplicates,
    `:9:`→`:10:` in 0.9.44 to finalise the streamable-only Qobuz dedup — Qobuz/Tidal re-resolve themselves on
    next open so these bumps are free; **0.9.53 changed Bandcamp's favurl to `?b=<art|url>` (was `?cover=`)
    WITHOUT a bump** — a fresh manual "Search Bandcamp" re-bakes it, same rationale as `lbf:bcmatch:` below);
    persisted Bandcamp match `lbf:bcmatch:6:` (30d) — **deliberately NOT
    bumped for the favurl**: it has no auto-repopulation (manual "Search Bandcamp" only), so a bump silently
    drops every hand-curated Bandcamp-only match. 0.9.42 wrongly bumped it `:6:`→`:7:`; 0.9.47 reverted to `:6:`
    so existing matches survive an update (a fresh search bakes the favurl in; an older match plays without it
    until re-searched). **Rule: never bump `lbf:bcmatch:` for a change the auto path handles via `lbf:stream:`.**
  - **"Unmatched tracks (debug)" view (0.9.38; extended to the follow list in 0.9.71).** Settings → a
    browsable diagnostic (`fetchUnmatchedPlaylists` → `showUnmatched` / `showUnmatchedFollow`): level 1
    lists **each created-for playlist AND the People-You-Follow list** (the follow entry is token-gated +
    appended after the playlists); opening one shows the **source** tracks that resolved to nothing (not
    library, not any enabled service) as plain `Artist — Title` rows via the shared `_unmatchedRows`,
    **with the source list name on line2** (so it's clear which list a gap came from now the tracker
    mixes both), count in the title. The follow path resolves in `'exclude'` mode, so owned tracks are
    dropped (not shown as unmatched) and the count is unmatched / new-track total. `_resolveTracks`
    returns the unmatched source tracks; the view resolves against the warm cache so it's usually instant
    and reflects exactly what the list dropped. Read-only. (Used live to find the `L.U.C.K.Y` miss — see
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

Six sections in the settings page (General / Blocked Artists / Streaming Services / For You / All Releases / MuSpy). MuSpy is kept LAST, in its own section, so its prefs aren't confused with the ListenBrainz ones (0.9.81). Each is a
proper Material settings section (0.8.24): the header is `<div class="prefHead collapsableSection"
id="lbf_<section>_Header">` and the section's settings are wrapped in a matching `<div
id="lbf_<section>">` panel. Material's `addExpanders` (iframe-dialog.js) finds `.collapsableSection`
divs, styles them as the themed bold accent-bar header (matching the browse `type=>'header'`
dividers), adds an expander, and on click toggles the panel whose id is the header id **minus
`_Header`** — so the `id="lbf_X_Header"` ↔ `<div id="lbf_X">` pairing is required. **Don't** use a
bare `<h2>` (Material doesn't theme it) or a standalone `<div class="prefHead">` (that's the faint
per-setting *label* style, positioned right-aligned/narrow inside a `settingGroup` — not a section
divider, and it gives no accent bar). The panels also collapse/expand like native LMS settings.

**Settings template vars go in `beforeRender`, not `handler`/`_render` (0.9.85).**
`Slim::Web::Settings::handler` persists each `prefs()` pref from `$paramRef->{pref_*}`, refreshes
`$paramRef->{prefs}` from the store, and THEN calls `beforeRender($paramRef, $client)` right before
`filltemplatefile`. Build a pref-derived template var (e.g. `lbf_services`, `lbf_blocked`) any earlier
and it is read PRE-save, so a save re-renders the OLD values while the base's `prefs.*` rows on the same
page show the new ones. Sanitising the incoming `$paramRef->{pref_*}` (the priority/enum guards) still
belongs in `handler`, before `SUPER::handler`. Fleet-wide rule — LBF, PFR and Discography all had it.

### General Settings
- `username` — ListenBrainz username
- `token` — ListenBrainz API token
- `lastfm_api_key` — optional Last.fm API key; enables three fallbacks: detail-page genres when MusicBrainz has none, the artist biography when MAI isn't installed (bio only, no photo), and similar artists for the DSTM radio when ListenBrainz has none (default empty = disabled)
- `days` — days window (1-90, default 14)
- **Sort is per-view, not a global setting (0.9.97).** The old global `sort` radio (and the `group_by_artist` / `week_dividers` toggles) were removed. Each list has a **"Sorted by …" toggle in an Options section** cycling Release Date / Artist / Album Title:
  - **For You** is now ALWAYS weekly (W/C material headers, newest week first); the toggle sorts the releases *inside* each week and persists to the durable `foryou_sort` pref (default `release_date`; set only via the in-view toggle, not on the settings page — like `follow_sort`).
  - **All Releases** per-week views each carry the toggle, backed by a **single durable `all_sort` pref shared across every week** — set it once and every week honours it, and it survives restarts. (0.9.97 first shipped this as per-week module state; that was changed because opening a *different* week always started at the default, which read as "the sort keeps resetting".) Paging stays per-week module state (`%pageState`); only the sort is a pref now.
  - Feeds are always fetched with `sort=release_date` (stable cache key); all ordering is client-side (`_sortReleases` pre-sorts by date for week-bucketing, `_sortWithin` applies the per-view mode within each week). `group_by_artist`'s collapse was effectively dead anyway (the weekly branch always outranked it) — see the 0.9.97 changelog.
  - **Artist sort keys on the MusicBrainz sort-name** ("White, Jack"; a stage name like "Panda Bear" keeps its natural order), not the display credit. The LB feed sends only the display credit, so the sort-name comes from MB by artist MBID: `API::warmArtistSorts(\@mbids)` fetches `artist/<mbid>` → `sort-name` serially (MB courtesy gap on public, none on a mirror; capped `SORT_WARM_MAX`=100/pass, in-flight-guarded), cached `lbf:artistsort:1:<mbid>` (30d found / 1d none); `API::peekArtistSort($mbid)` is the sync render-path read. `Browse::_artistSortKey` = `artist_sort_name` (MuSpy supplies it inline) → `peekArtistSort` → display credit. The warm fires **only from the Artist-sort code paths** (`_warmArtistSorts`, gated on `$mode eq 'artist'` in `fetchForYou` and the All-Releases week coderef), so a user who never picks Artist sort triggers no MB traffic; a cold artist sorts by display credit on the first Artist-sorted render and corrects on re-entry (second-load, like bios/emblems).
- `play_via` — show inline playable streaming matches on the detail page (default ON)
- `people_follow` — master on/off for the whole **People You Follow** browse section (What's Trending, both Trending Albums lists, Recommended); default ON (0.9.118). When off the section is absent AND its warm pre-build + unmatched-debug entry are skipped, so nothing there is fetched/cached/warmed
- `follow_sort` — People You Follow list ordering: `date` (day dividers, newest first) or `recommender` (grouped by the follower who recommended each track); default `date`. Flipped in place by the inline toggle at the top of that list, not shown on the settings page (0.9.88; toggle label made state+hint "Sorted by … (tap for …)" in 0.9.91)
- `prefer_library` — when building a Created-for-You playlist, use a track from the user's own LMS library (matched by MusicBrainz ID, then artist + title) before searching streaming services (default ON; see "Prefer local library")
- `debug_log` — opt-in dedicated warm/resolve debug log (default OFF, 0.9.54). When on, `Plugin::dbg` appends the playlist warm/match timeline — incl. the per-playlist **library-match count** and scan-defers — to `lbf-debug.log` in the LMS log dir (`Slim::Utils::OSDetect::dirsFor('log')`, cachedir fallback), size-capped ~1 MB with one `.old` rotation. The same lines always also go to `server.log` at INFO. Turn on to diagnose a match/caching problem, off after.

### MuSpy Settings (own section, kept LAST — 0.9.81)
Grouped separately from the ListenBrainz prefs so the two aren't confused. All three drive `API::getMuSpyReleases` → `Browse::_mergeMuSpy` (For You feed only).
- `muspy_userid` — optional MuSpy (muspy.com) public user ID; folds that user's followed-artist releases into the For You feed. Public endpoint, no auth/password stored. Default empty = disabled
- `muspy_future` — include MuSpy **upcoming** releases (default ON, 0.9.79). MuSpy is upcoming-heavy, so its future side has its own toggle instead of riding `foryou_future`. MuSpy's past side still honours `foryou_past` + `days`. Turn off for already-released MuSpy titles only
- `muspy_future_months` — how far ahead the MuSpy upcoming side reaches (1-24 months, default 12; 0.9.80). Kept separate from the LB feed's narrow `days` window; `_mergeMuSpy` caps the future side at `months * 30` days, clamped by `MUSPY_FUTURE_MONTHS_DEFAULT`/`_MAX` so a garbage pref can't blow the window open. Only applies when `muspy_future` is on

### Blocked Artists Settings
- `blocked_artists` — arrayref of `{ mbid, name }`. Releases by these artists are hidden from EVERY feed (For You / All Releases / home shelves via `Browse::_filterSection`, and since 0.9.111 the whole People You Follow section via `_trendBlocked`) by `_isBlocked` (matches any blocked `artist_mbids` OR normalised credit name). No ListenBrainz API exists for this — the `fresh_releases` endpoint takes only date/sort params and the feedback API is per-recording (love/hate, `score 1/-1`) and isn't consumed by the feed — so it's a purely local, render-time filter (takes effect on next browse; no feed-cache clear). Added from a release detail page's **"Block this artist"** link (`Browse::_blockArtist`); VA is never offered (would hide unrelated compilations). The settings section lists each blocked artist with an Unblock checkbox (`lbf_unblock_<i>`); `Settings::handler` removes ticked entries on save (the pref is NOT in the `prefs()` list, so it's mutated directly).

### Streaming Services Settings
- `svc_priority_<qobuz|bandcamp|tidal>` — search priority per service (number 0–9; lower = searched first, **0 = never search it**). Search stops at the first service that matches. Drives BOTH album play-via and playlist track matching. The page lists each known service as detected/not installed via `Browse::serviceStatus`.

### For You Settings
- `foryou_past` — include past releases (default ON)
- `foryou_future` — include upcoming releases (default ON since 0.9.79; was OFF — new installs only, existing prefs win)
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
│   │   ├── ── Options ──                        ← Material section header
│   │   │   ├── Sorted by <mode> (tap to change) ← cycles Release Date / Artist / Album Title (foryou_sort pref)
│   │   │   └── Refresh (force update now)       ← clears the feed cache, reloads in place
│   │   └── … For You feed (ALWAYS weekly W/C headers; releases sorted within each week per the toggle)
│   └── <date span>                            ← Playlists tile (covered span; title on cover)
│       ├── Refresh playlist matches            ← forces a library-first re-resolve of every playlist (0.9.54; background, username-gated)
│       ├── W/C <date> / <day>                  ← one playlist per category (Weekly Jams / Exploration / Daily Jams)
│       │   └── matched streaming/library tracks (Play-all; unmatched dropped; count in page title;
│       │       a disabled/uninstalled service's tracks drop + re-match on re-resolve)
│       └── …
├── ── All Releases ──                         ← Material section header
│   └── <date span> · N releases               ← All Releases tile
│       ├── Refresh (force update now)
│       ├── W/C <date>  [This/Last/Earlier badge]  ← that week's releases (Options: Sorted-by toggle, shared+durable all_sort; first 30, then "Show more" / "Show all")
│       └── …                                  ← one entry per week-commencing
└── ── Settings ──                             ← Material section header
    ├── Plugin Settings                         ← weblink to settings.html
    └── Unmatched tracks (debug)                ← per-playlist list of tracks that matched nothing (0.9.38; username-gated)
```

All section filtering (artwork/type/VA) is still driven entirely by settings prefs. The All Releases
by-week split (`_buildAllLanding`) groups the already-filtered+sorted list by `_weekStart` and offers
one per-week drill-in per week-commencing (each paged 30-at-a-time, each with a
Sorted-by toggle backed by the shared durable `all_sort` pref; the standalone "Show all" landing entry was
removed in 0.9.87); For You drops straight into its always-weekly list (Options sort toggle + Refresh
on top). The Playlists section is gated on `username` being set. See
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
  - Requires a descriptive `User-Agent` or MusicBrainz returns 403. `API::USER_AGENT` is a memoised sub (NOT a constant) that derives the version from the plugin manifest at runtime, so it never drifts from the release (0.9.40) — don't reintroduce a hardcoded version string
  - `API::getReleaseDetails` returns `{ genres => [names], media => [{ position, format, tracks => [{position,title,length}] }] }`
  - Detail page degrades gracefully to base metadata if the lookup fails

### Display / New Music Tracker–inspired presentation
- Release detail page shows base metadata, then genres and a per-disc tracklist (m:ss durations) pulled from MusicBrainz
- ~~`group_by_artist`~~ **removed in 0.9.97.** It collapsed an artist's multiple releases into one `Artist (N)` row, but was reachable only when week dividers were off or the sort wasn't Release Date — under the default (weekly + date sort) the weekly branch always outranked it, so it was effectively dead. For You is now unconditionally weekly; the per-view **Artist** sort covers the "see an artist's releases together" use-case.
- Pagination: handled natively by LMS/Material — `_buildItems` returns the whole filtered+sorted list as one level and the client windows/scrolls it (no manual paging; see 0.4.7). Keeps Material's in-list filter working across the full list. **Exception (0.9.86): the All Releases per-week drill-ins page 30-at-a-time** via `_pageSection`/`_pageRow` (a global-feed week can be hundreds of releases) — with a **"Show more (30)"** row plus a **"Show all (total)"** row (0.9.97; jumps straight to the whole week, offered only when it reveals more than "Show more" would) and a "Show less" once expanded. For You keeps the native full-list windowing; the standalone All Releases "Show all" landing entry was removed in 0.9.87 (it duplicated the dated weeks unpaged — this new "Show all" is a per-week reveal, not that)
- Not ported from New Music Tracker (needs a web-app backend the OPML plugin doesn't have): OAuth login, artist following, wishlists, genre/style *filtering*, listener/popularity counts

### Release Type Filtering
- The API does NOT support release type as a query parameter
- Filtering is done client-side in Browse.pm after receiving results
- Matches against both `release_group_primary_type` and `release_group_secondary_types`
- MusicBrainz primary types: Album, Single, EP, Broadcast, Other
- MusicBrainz secondary types tracked: Compilation, Soundtrack, Spokenword, Interview, Audiobook, Audio drama, Live, Remix, Mixtape/Street, Demo
- For You section uses individual `foryou_type_<name>` checkboxes (since 0.6.15 — replaced the old single `foryou_albums` toggle)
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

## Shared Matching Engine — FLEET SYNC RULE (2026-07-10)

The artist/album/track matcher (`_norm`, `%FOLD`, `_artistMatch`, `_albumMatches`,
fallback helpers `_stripFmt`/`_asciiNorm`/`_punctNorm`/`_stripArtistPrefix`; LBF also
`_trackMatches`) is ONE engine with a copy in each of these four repos:

- `LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm` (origin, canonical)
- `LMS-Pitchfork-Reviews/PitchforkReviews/Browse.pm`
- `LMS-Discography/Discography/Sources.pm`
- `LMS-Listen-to-Later/ListenLater/Sources.pm` (hash-pinned LENIENT variant — empty-artist
  saved-item replay must still match; do NOT blindly align it)

**THE RULE: a matching fix in ANY of these repos must be applied to ALL repos carrying the
affected sub, in the SAME work session.** Enforcement — this must exit 0 before any matcher
change is called done:

    python3 LMS-ListenBrainz-New-Releases/tools/matcher_sync_check.py

It diffs the comment-stripped CODE of every copy across all four repos. Deliberate variants
are sha1-pinned inside the script with a reason, and FAIL the check if they change without a
conscious re-pin (`--print-hashes` prints current hashes). After aligning: bump every touched
repo's plugin version AND its match/decision cache versions (LBF: `lbf:stream` + `lbf:track` +
`lbf:pl:resolved` — ALL layers; PFR: `pfr:stream`; DSC: `dsc:cand` only if the cached candidate
shape changed — matching runs live there; LL: none — matching is live), rebuild zips + repo.xml
sha. Never leave a matcher fix in one repo "to port later" — that is exactly how the 2026-07
drift happened (LBF missed the P!nk/EP/ascii rules for months).

**NOT part of this shared engine — do NOT sync (0.9.89):** the release-type consistency filter
(`_candReleaseType` + the `_ctype` tags + the single-drop in `_findPlayable`) is a **deliberate
LBF-only** layer that sits OUTSIDE `_norm`/`_albumMatches`. It must **not** be replicated to PFR/DSC/LL
and it does **not** trigger `matcher_sync_check.py`. Discography already handles types its own way
(per-type sections + the year/ownership rival rule) and has no candidate type-matching to align with;
putting a type gate inside the shared matcher would risk breaking Discography's deliberate EP/single
matching. `_candReleaseType` is a portable building block if we ever choose to fix Discography's
same-year album/single gap — but that would be a separate, conscious port, not a sync obligation. See
[[lbf-release-type-filter-not-synced]].

## Streaming service search & debugging — CANONICAL REFERENCE (don't re-derive)

The Qobuz/Tidal/Deezer search API is the SAME across the four streaming-resolver plugins (LBF, PFR,
Discography, Listen-to-Later). **Full verified signatures live in `LMS-Discography/CLAUDE.md`
("Service Plugin APIs — VERIFIED SIGNATURES") and the `[[service-search-and-debug]]` memory** — the
authoritative table, kept from upstream source. Don't guess these; they break silently. Two gotchas
that cause empty/junk pools:
1. **Envelope: ONLY Qobuz hands back the whole result hash** (`{artists}{items}`/`{albums}{items}`);
   Tidal & Deezer unwrap `{data}` themselves → plain ARRAY.
2. **Query encoding differs** (`query_enc`): Qobuz + Tidal want a CHARACTER string, Deezer wants
   BYTES. Feeding octets to Qobuz/Tidal double-encodes accents → junk/0 results (fixed 2026-07-10;
   LBF carries `query_enc`/`qChars`/`qBytes` in `_findPlayable`/`_findPlayableTrack`).

**HOW TO DEBUG A SEARCH (the canonical method — stop trying variants each session):**
1. `["pref","plugin.listenbrainzfreshreleases:debug_log","1"]` (via jsonrpc).
2. Fire the feed once (Material, or a jsonrpc menu query with a player MAC from `["players",0,20]`).
3. **Read the log over HTTP:** `curl -s http://plex:9000/log.txt` and grep the plugin prefix — the
   key line names each service's pool size + samples. Empty pool = service search returned nothing
   (encoding/availability); healthy pool + no match = matcher gap (`tools/match_check.py`).
4. Turn `debug_log` back off. Test the MB mirror directly with a `curl` to `plex:5000/ws/2/…`
   ([[mb-mirror-search-index-gotcha]]); test the library with `["artists",…,"search:NAME"]`.

## Version History
- **0.9.96** — **alias-field fallback in `getArtistMbidByName` (ported from Discography 0.32.0).** The
  fielded query `artist:"<name>"` searches the artist NAME only, so a name existing solely as an MB
  **alias** ("The Oh Sees" → Osees `194272cc-…`) returned 0 results and cached a miss — verified live on
  public MB AND a mirror (`alias:"The Oh Sees"` scores 100 on both). `$run` gained a `$field` arg
  (query built per-field by `$mkQuery`); when the `artist` field yields nothing acceptable (0 results
  after the mirror→public fallback, or top score <90), it retries ONCE with `alias:"name"` — same
  escaping, same ≥90 gate, same mirror-0-results→public retry within the stage. Runs only where a miss
  would have been cached, so no working resolution changes. Matters for the DSTM radio's Last.fm
  similar-artist names (alias-era spellings are common there). NOT a matcher change (resolver is outside
  the fleet-sync set; `matcher_sync_check.py` N/A); no cache bump (`lbf:artistmbid:` now fills correctly;
  existing misses self-heal on their TTL). `perl -c` clean.
- **0.9.95** — **code-review fixes: make the 0.9.94 mirror auto-detect actually run + plug a resolver leak.**
  From a pre-build review of 0.9.82–0.9.94. (1) **`mb_base_url` defaulted to the public URL, which made the
  whole 0.9.94 auto-detect feature dead code.** `autodetectMirror` returns early on a non-blank base and
  `_mbBase` only consults the auto-detected-mirror cache (`MB_AUTO_KEY`) when the pref is blank — but the
  init default was `'https://musicbrainz.org/ws/2/'` AND `Settings::handler` reset a blank field back to
  that URL, so the pref was **never** blank and the probe never fired on any install. Fixed: init default is
  now `''` and a cleared field stays `''` (the settings.html placeholder communicates the default in the
  empty box). Existing installs that already saved the public URL must clear the field once. (2) **Reference-
  cycle leak in `getArtistMbidByName`.** The 0.9.93 mirror-search fallback used a self-capturing closure
  (`my $run; $run = sub {…$run…}`) — a cycle Perl never collects — created once per artist-name resolution
  (DSTM Radio seeds, Last.fm similar-artist resolution). Rewritten to pass the sub to itself (`$self`), so
  it's freed when the async chain ends (portable — no `__SUB__`/`weaken`). Settings/lifecycle only —
  **no matcher change, no cache-version bump**; `matcher_sync_check.py` still exits 0.
- **0.9.94** — **auto-detect a same-host MusicBrainz mirror + de-personalise the settings text.** New
  `API::autodetectMirror($cb)` runs from `postinitPlugin` ONLY when `mb_base_url` is blank: probes a
  FIXED same-host list (`http://localhost:5000/ws/2/`, `http://127.0.0.1:5000/ws/2/`) and, for the first
  that answers, validates it is really MusicBrainz by fetching a known MBID (Radiohead `a74b1b7f…`) and
  checking `name eq 'Radiohead'` — so another `:5000` service can't be mistaken for a mirror. The
  discovered base is cached under `lbf:mbmirror:v1` (URL=found, `''`=probed-none, TTL 1 day); `_mbBase`
  consults it when the pref is blank (a manual URL still wins and skips the probe). `_mbThrottled` is
  unchanged, so a discovered localhost mirror is treated as un-throttled + eligible for the empty-search
  →public fallback, exactly like a manual mirror. **The LAN is never scanned** — localhost only. Covers
  the common musicbrainz-docker-alongside-LMS case with no config. Also: the tooltip + all code comments
  no longer reference a personal host (now `http://your-server:5000/ws/2/`) and the tooltip documents the
  auto-detect. Ported identically to Discography 0.30.0 the same session. `perl -c` clean; no cache bump.
- **0.9.93** — **mirror search fallback (ported from Discography 0.23.0).** `getArtistMbidByName` now
  retries the public MusicBrainz API ONCE when the configured base is a **mirror** and its `?query=`
  search returns zero results (or is unreachable). A musicbrainz-docker mirror serves entity BROWSES
  from Postgres but SEARCH via Solr — a mirror whose search index was never built returns count:0 for
  everything while browses work, which would silently fail every name→MBID resolution (the DSTM Radio
  seed and the Last.fm similar-artist resolution). New `_mbThrottled` (public-host test) gates the
  fallback; `$isFb` guards the single retry; the public-resolved MBID still browses fine against the
  mirror. Public API and fully-built mirrors are unaffected. NOT a matcher change (sync N/A); no cache
  bump (the fallback just fills the same `lbf:artistmbid:` cache correctly instead of caching a
  spurious miss). See [[mb-mirror-search-index-gotcha]] and [[service-search-and-debug]]. `perl -c`
  clean; `lbf:stream`/`lbf:track`/`lbf:pl:resolved` untouched.
- **0.9.92** — **code-review fixes (release-type filter EP edge + mb_base_url scheme guard).** From the
  0.9.82–0.9.90 pre-commit review. (1) **`_findPlayable` single-drop no longer applies to EP targets.**
  `$dropSingles` was `$tnorm ne '' && $tnorm ne 'single'` — so an EP release dropped `single`-classified
  candidates, but `_candReleaseType` classifies a real 2-track EP (no explicit service type field) as
  `single` by track-count, so the correct EP could be discarded for a like-named rival. Now
  `... && $tnorm ne 'ep'` — album/compilation targets still shed a same-named single (the 0.9.89 case),
  EP targets don't. Filter output is cached, so **`lbf:stream:17→18`** (album path only — `_findPlayableTrack`
  tags `_ctype` but never filters on it, so track/playlist caches unchanged). (2) **`mb_base_url` scheme
  guard.** A scheme-less entry (bare mirror host like `plex:5000/ws/2`) was stored verbatim and made every
  MB lookup fail silently (tracklist/genres/DSTM resolve); `Settings::handler` now prepends `http://` to a
  scheme-less non-blank value (type `https://` yourself for a TLS mirror). (3) **Default URL made
  discoverable** — settings.html placeholder `https://musicbrainz.org/ws/2/` + the desc string spells it
  out and notes blank resets to it (so an accidental clear is recoverable). `perl -c` clean (Browse +
  Settings). NOTE (verified in review, NOT bugs, left as-is): the `_streamId`/`lbf:bcmatch` "type/norm not
  in the key" concerns only bite MBID-less releases, which the 0.4.4 invariant says never happens on the
  feed path (release_mbid always present → album/single get distinct mbid keys); reuse/altitude cleanup
  (`_recommenderDivider`≈`_dayDivider`, dual-encode ×4, `_norm` €/£/¥ outside `%FOLD`, `%pageState` never
  clears, `lbf:pl:resolved:6:` key triplicated) deferred.
- **0.9.91** — **People You Follow inline sort toggle: state+hint labels (Discography style).** The
  toggle row now names the CURRENT ordering with a tap hint — `PLUGIN_LBF_FOLLOW_SORT_DATE` = "Sorted by
  date (tap for recommender)", `PLUGIN_LBF_FOLLOW_SORT_REC` = "Sorted by recommender (tap for date)" — and
  `_followSortToggle` picks the string by current state (`$byRec ? REC : DATE`, flipped from the old
  action-named `$byRec ? DATE : REC`). Mirrors Discography's `_sortToggleItem`
  ("Sorted newest first (tap for oldest)"). Strings-only + one ternary; no matcher, no cache bump.
  (Also this session, diagnosed but NOT a code bug: a user reported the follow list "can't view as list /
  shows as a grid of covers". Verified live over HTTP against the server's own 6.4.4 `material-deferred.min.js`
  that the feed forces LIST — the sort `link` row + `header-basic` divider + `audio` rows make `types.size==3`,
  so Material's `1==types.size` grid-enable never fires (`canUseGrid=false`). It was a STALE Material client
  view cached from an older pure-audio build; a hard-refresh/incognito reopen restored the list AND the ⋮
  List/Grid toggle. No plugin change — the current feed already can't be gridded.)
- **0.9.90** — **matcher: self-titled-album rule (fleet sync from Discography 0.11.1).** When the album
  title normalises to the ARTIST name ("The Beatles", "Weezer"), `_albumMatches` now matches on the
  EXACT normalised title only — skipping the prefix/format/ascii/artist-prefix fallbacks that otherwise
  read "<album> <extra>" as an edition of the same album. Without it, "The Beatles" swallowed "The
  Beatles 1962-1966" (Red), "…1967-1970" (Blue), "…Anthology 1". `_norm` still strips brackets, so "The
  Beatles (White Album)"/"(Remastered)" still match; a wrong artist on an exact title still fails.
  **Fleet sync:** applied byte-identical to LBF + PFR + DSC (checker `_albumMatches` hash `7462b60e053d`
  across all three) and, adapted, to LL's pinned lenient variant (empty-artist replay path untouched;
  re-pinned `5d270440af5a→2bf38f346e0f`); `matcher_sync_check.py` exits 0. Album-path only, so **only
  `lbf:stream:16→17`** bumps (track/playlist caches use `_trackMatches`, unchanged). Gates: `perl -c`
  clean on all four; 14/14 assertions (Red/Blue/Anthology rejected, exact/White-Album/Remastered
  accepted, wrong-artist rejected, normal albums unaffected, LL empty-artist leniency preserved);
  checker exit 0. (Sibling bumps this session: PFR 0.7.5 `pfr:stream:5→6`, LL 0.1.70.)
- **0.9.89** — **streaming match honours release type: an album no longer resolves to a like-named
  single.** Field bug — a release (e.g. an Album) matched a same-named **single** on a service, which
  title+year can't separate (a single usually shares the album's year). Fix is a type-consistency
  filter in `_findPlayable`, **outside the shared matcher** (LBF-only — no fleet sync; Discography
  untouched, and it has no candidate type-matching to copy anyway — it disambiguates by year+ownership,
  which needs the whole discography). New `_candReleaseType($album)` classifies a candidate as
  `album`/`single`/`ep`/`''` from the service's OWN data — explicit type field first (Qobuz
  `release_type`, Deezer `record_type`, TIDAL `type`), else a conservative track-count rule (≤2 tracks →
  single; a real album never has 1–2 tracks; 3+/unknown → `''` = keep). Each adapter tags matched items
  `_ctype`; `_findPlayable` drops `single`-typed candidates **only when the opened release's type is
  KNOWN and is not itself a single** (so a Single release still matches a single — LBF lets users
  include singles — and an unknown/blank type is never filtered), and **keeps the whole set if the drop
  would empty a service's matches** (a service that only lists the single, or a flaky type field, still
  yields a match). Target type is `$rel->{release_group_primary_type}`, threaded as a new trailing
  `_findPlayable` arg. Cache bump `lbf:stream:15→16` so cached albums re-resolve once and shed the
  single. **KNOWN RESIDUAL:** a mistyped single with 3+ tracks and no type field slips through (rare;
  the conservative rule errs toward keeping matches). Reusable/portable to Discography later (would fix
  its same-year album/single gap). Gates: `perl -c` clean; 19/19 assertions on `_candReleaseType`
  (all three services' field shapes, explicit-type precedence, track-count fallback, guards) + the
  drop/fallback filter.
- **0.9.88** — **People You Follow: inline sort toggle — by date OR by recommender.** The list can
  now be grouped by the follower who recommended each track, not just by day. A top-of-list toggle row
  (`_followSortToggle`, `MENU_SORT` icon) flips the durable `follow_sort` pref (default `date`) and
  refreshes in place (`nextWindow=>'refresh'` → the re-walk re-reads the pref, so the choice sticks
  across visits — like the feed Sort setting). `_followResult` branches: `date` = the existing day
  dividers; `recommender` = a `_recommenderDivider` ("Recommended by <user>") per follower. Both
  iterate the already-newest-first list and bucket in first-seen order, so **recommender groups come
  out most-recent-activity-first**, tracks newest-first within each. Each matched item is tagged
  `_recommender` in `_resolveTracks` (mirroring `_created`; harmless to the playlist/DSTM paths), and
  the resolved-cache key bumped `lbf:follow:resolved:3→4` so existing resolves re-run once and bake it
  in (the source store already carries it — free re-tag). Dedup means a track shows under a single
  person (whoever recommended it most recently). New strings `PLUGIN_LBF_FOLLOW_SORT_REC` /
  `_SORT_DATE` / `_FOLLOW_BY` / `_FOLLOW_BY_UNKNOWN`; new icon `lbf-sort_MTL_icon_sort.png`. New pref
  `follow_sort`. No matcher change. Gates: `perl -c` clean; 10/10 behavioural assertions against the
  real `_followResult`/`_followSortToggle` (toggle-first + correct label per mode, date order + single
  day group, recommender order most-recent-first + one divider per person, pref flips both ways).
- **0.9.87** — **removed the "Show all" entry from the All Releases landing.** It was the first row
  of `_buildAllLanding` and dumped the entire weekly/grouped list unpaged (via `_buildItems`) —
  duplicating the same releases the dated week rows already cover, and it was the path that still
  flooded once the per-week lists were paged (0.9.86). The landing is now just the dated week
  drill-ins, each capped 30-at-a-time with "Show more". `_buildAllLanding`'s `$headers` param and the
  `PLUGIN_LBF_VIEW_ALL` string are now unused (left in place; harmless). No matcher change, no cache
  bump. (New Releases for You is unchanged — full native windowing.) `perl -c` clean.
- **0.9.86** — **"Show more" reveal on the All Releases per-week lists (30 at a time).** A single
  week of the GLOBAL All Releases feed can list hundreds of releases; opening a week now renders
  **PAGE_SIZE = 30** rows followed by a **"Show more (N)"** row that grows the week by another 30, and
  — once grown — a **"Show less"** row that collapses back to 30. Ported from the Discography plugin's
  `_pageSection`/`_pageRow`: the tap is a `nextWindow => 'refresh'` toggle that stores an **absolute**
  target in a module-level `%pageState` (per player, per `arweek:<week>` key), which survives the
  `cachetime => 0` re-walk the refresh triggers; collapsing deletes the key (no residue); a shrunk feed
  clamps rather than slicing past the end. **Scoped to All Releases ONLY** — `_pageSection` is called
  solely from the per-week drill-in coderefs in `_buildAllLanding`. **New Releases for You is untouched**
  (its native full-list windowing — Material's in-list filter spanning every item — works well and is
  the deliberate 0.4.7 behaviour); **"Show all"** likewise stays the full native list (it's the
  everything/escape-hatch view), and the shared `_buildItems`/`_buildWeekly`/`_buildGrouped` are
  unchanged, so nothing else moves. New strings `PLUGIN_LBF_SHOW_MORE` / `PLUGIN_LBF_SHOW_LESS`; two
  placeholder icons `lbf-more_MTL_icon_unfold_more.png` / `lbf-less_MTL_icon_unfold_less.png` (Material
  renders its own themed unfold_more/less font-icon from the filename). No matcher change, **no cache
  bump** — pure view state. Gates: `perl -c` clean; 22/22 behavioural assertions against the real
  `_pageSection`/`_pageRow` (cap/no-cap, remainder counts, more→more→less full cycle, absolute+clamped
  targets, collapse-clears-residue, section independence, shrunk-feed clamp with no undef tiles).
- **0.9.85** — **fix: the settings page rendered STALE service priorities after a save.**
  `lbf_services` (which carries each service's CURRENT priority into the template) was built
  in `_render()` **before** `SUPER::handler` persists the POST, so saving a new priority
  re-rendered the page with the old number still in its input — the save HAD applied, but only
  a reload showed it. Moved (with `lbf_blocked`) into **`beforeRender`**, the platform's
  documented post-save hook: `Slim::Web::Settings::handler` persists each `prefs()` pref from
  `$paramRef->{pref_*}`, refreshes its own `prefs` template var from the store, and only then
  calls `beforeRender($paramRef, $client)` immediately before `filltemplatefile`. (`lbf_blocked`
  was already correct — `handler` mutates `blocked_artists` directly before rendering — but it
  belongs in the same hook.) **RULE (fleet-wide): any Settings template variable derived from a
  pref MUST be built in `beforeRender`, never before `SUPER::handler`;** sanitising the incoming
  `$paramRef->{pref_*}` still belongs in `handler`. Surfaced by a code review of the sibling
  Discography plugin, which had inherited the same shape via PFR; fixed in all three the same
  session (DSC 0.10.4, PFR 0.7.4). Settings-render only — no matcher, no cache, **no key bumps**.
- **0.9.84** — **matcher aligned to the fleet-canonical engine** (see the Shared Matching
  Engine section + `tools/matcher_sync_check.py`, both NEW in this version — the checker
  cross-diffs all four repos' copies and hash-pins documented variants). LBF's copy had
  quietly lagged: `_norm` was missing the stylised-punctuation substitutions ($->s, euro/
  pound/yen, !->i, @->a) that PFR/Discography had — so the "P!nk"/"L.U.C.K.Y" class
  (long-open gap 3) is NOW FIXED here, for albums AND tracks (`_trackMatches` shares
  `_norm`); `_albumMatches` was missing the EP/LP-strip and ascii-glyph fallbacks
  (+ their `_stripFmt`/`_asciiNorm` helpers, now added). `_norm` output feeds matching and
  norm-keyed caches, so ALL layers bump: `lbf:stream:14→15`, `lbf:track:5→6`,
  `lbf:pl:resolved:5→6`. Verified via the real module (P!nk, EP-strip, "( )", artist-prefix,
  plus must-not-match controls).
- **0.9.83** — **matcher: two fallbacks ported from the Discography plugin** (both were
  deliberate divergences waiting to come upstream). (1) **All-punctuation / single-char
  album titles** (Sigur Rós "( )", "X"): `_norm` erases them and the <2-char gate rejected
  before comparing — new branch compares `_punctNorm` (lowercase, whitespace stripped,
  punctuation KEPT: "( )" == "()") of the RAW titles, exact equality only + mandatory
  artist gate. The raw album title is threaded to the matcher as a new trailing
  `$albumRaw` arg through all four `run` adapter signatures (auto + manual-Bandcamp call
  sites pass `$album`). (2) **Artist-name-PREFIXED titles** ("Belle and Sebastian Write
  About Love" vs "Write About Love"): strip a leading "<artistNorm> " from both sides and
  re-compare, >=3-char remainder gate. Album matcher only — `_trackMatches` untouched.
  `lbf:stream:13→14` flushes cached album no-matches (track/playlist caches unaffected).
  Verified via the real module: 8/8 incl. must-not-match controls (live edition, wrong
  artist, x-vs-xx, Prism-of-Doom).
- **0.9.82** — **fix: accented artists/titles got junk or empty Qobuz+Tidal search results
  while Deezer worked** (found as the Sigur Rós failure in the Discography plugin, 2026-07-10,
  and ported back here). Root cause: both the album (`_findPlayable`) and track
  (`_findPlayableTrack`) resolvers octet-encoded the outgoing query for EVERY adapter, but the
  service plugins' own URL layers differ — Qobuz escapes query params with `uri_escape_utf8`
  and Tidal transliterates them with `Text::Unidecode`, both of which expect CHARACTER strings,
  so octets double-encoded ("Sigur Rós" was searched as "Sigur RÃ³s"); Deezer's
  `complex_to_query` (and Bandcamp) want octets, which is why they were unaffected. Fix:
  adapters carry `query_enc => 'chars'|'bytes'` (Qobuz/Tidal chars, Deezer/Bandcamp bytes);
  both resolvers build both spellings (`utf8::decode` fails safe on non-UTF-8 input) and pick
  per adapter at the call site. Cache bumps — decisions resolved via mangled queries must
  flush, and per the layered-cache rule the outer layer bumps with the inner:
  `lbf:stream:12→13`, `lbf:track:4→5`, `lbf:pl:resolved:4→5`. Likely retro-fixes part of the
  long-standing "accents" unmatched-tracks gap class (the STREAMING side of it; the local-side
  `_norm` fold shipped in 0.9.57). NOTE (not done): service album searches are relevance-capped
  (Qobuz 200, our Tidal/Deezer calls 50) — the Discography plugin moved to artist-first
  fetching (resolve artist, pull their album list) for that reason; candidate here if deep
  discography misses ever show up in LBF resolution.
- **0.9.77** — **fix: DSTM Radio dropped to random library tracks during a ListenBrainz
  Popularity-API outage.** Diagnosed live (player BackGardenSpeaker): the seed resolved and
  `getSimilarArtists` returned 100 artists, but every `getTopRecordingsForArtist` fan-out call
  returned `500 "Popularity API currently disabled due to high load on the server"` — a
  ListenBrainz **server-side** shutdown of `/1/popularity/top-recordings-for-artist`, not our
  bug. EVERY radio sub-path (similar-artists, seed-only, AND the Last.fm fallback) funnels
  through that one endpoint to turn artists into tracks, so none could produce candidates; the
  handler returned `[]` and core DSTM fell through to random library albums. The Last.fm fallback
  couldn't help (it shares the dead endpoint) — the fallbacks were also only wired to the
  *empty/error* branches of `getSimilarArtists`, not to a similar-succeeds-but-pool-empty
  outcome. Fix: `_resolveAndReturn` now, when a **radio** pool is empty, falls back once to the
  **Recommended CF pool** (`/1/cf/recommendation/...` — a DIFFERENT endpoint, confirmed up during
  the outage), instead of returning `[]`. Centralised there so it covers all three radio sites
  (similar-success, seed-only, Last.fm-success); `'recommended'` is guarded from recursing, so an
  all-endpoints-down case still terminates cleanly. **Known follow-up (not done):** during an
  extended outage each top-up still fires ~24 doomed 500s at the disabled endpoint — a short
  negative-cache of the "Popularity disabled" state would let `_collectArtistTracks` skip the
  fan-out and go straight to the CF fallback (be a better API citizen). No cache-version bump.
- **0.9.76** — **fix: cached Deezer album matches silently vanished on re-read.**
  `_rebuildStreamItems` reattaches each service's browse coderef by `_svc` but only had
  Qobuz/Bandcamp/Tidal branches — a Deezer match hit the `else { next }` and was dropped
  on every cache-hit re-open (it only rendered live on first search). Deezer's album node
  is the SAME shape as Tidal's — `_renderAlbum` sets `url => \&getAlbum` (a coderef,
  stripped by `_cacheStream`) with the album id in `passthrough` (plain data, survives the
  cache), so the fix is a one-line Tidal-style branch: `$item{url} = \&…Deezer::…getAlbum`.
  Also added `getAlbum` to the Deezer adapter-registration `->can` guard so Deezer only
  registers when the full album round-trip is possible (mirrors Tidal), and corrected the
  adapter comment that had loosely described the album url as a "string deezer:// url" (that
  string is the `play`/favourites value; the browse url is the coderef). No cache-version
  bump — existing cached Deezer entries (id in passthrough) now rebuild correctly instead of
  dropping. Verified `_renderAlbum`/`getAlbum` against michaelherger/lms-deezer. (Surfaced
  while porting this engine to the Album Reviews plugin, which had the same gap.)
- **0.9.75** — **code-review fixes: follow "Play what's new" + Deezer robustness (no cache bump).**
  (1) The "Play what's new" row was a `type=>'playlist'` container nested inside the People-You-Follow
  list; the follow level is the tile's Play-all source, so Play-all re-expanded the container and
  **queued the new tracks twice**. It's now a `type=>'link'` DRILL row that opens a **pure track list**
  (no dividers) — itself a proper Play-all container. (2) Its resolved, service-filtered items are
  **threaded through the passthrough** (the follow level is live/`cachetime=>0`, always fresh), so
  `playFollowNew` no longer re-reads a resolved cache that may have been **evicted between render and
  tap** (the cache read is now only a fallback) — count and contents can't disagree. (3) `_searchDeezer`/
  `_searchDeezerTrack` now tolerate a bare-arrayref OR hash-wrapped (`{data}`/`{albums}`/`{tracks}`)
  search response and bail to a clean miss on any other shape, so a shape mismatch degrades to a
  no-match instead of dying inside the async callback (outside `_findPlayable`'s eval) and leaving the
  service un-settled until its timeout. Matching/caching otherwise unchanged. See
  [[lbf-action-rows-placement]].
- **0.9.64** — **"Search Bandcamp" is a tap-to-choose picker; choosing pins the match and re-opens the album armed.** The manual Bandcamp search no longer refreshes the detail page in place — that showed the match but left it un-armed for Material's custom actions when Bandcamp was the **sole** source (Material sets `view.itemCustomActions` only on a fresh drill-in / `browseHandleListResponse`, **never** on the in-place `refreshList` — browse-page.js:1568), so "Add to Listen Later / Wish List" was missing until you backed out and re-entered. Now the one `nextWindow => 'refresh'` search row drives **both** outcomes because Material only honours `nextWindow` on an **empty** response (browse-functions.js:834): a **match** returns a picker sub-page (a "Tap an album to use it as this release's match" prompt + one **non-playable** `type=>'link'` row per candidate, real cover + `Album / Artist`); a **miss** returns an empty list → inline refresh, row flips to "…tap to retry" (no dead-end). Tapping a candidate **pins** it (`_bcMatchKey`; nothing pinned until chosen) and calls **`_releaseDetail($rel, …)` to re-render the album page as a fresh drill** — which shows the match inline AND arms Add. The pinned item is byte-for-byte the old persisted form (logo image; cover/page-URL/artist/year on the favurl), so inline render, replay and the Listen Later handshake are unchanged; **no cache bump**. `$rel` is threaded `_releaseDetail → _bandcampSearchRow → _searchBandcampOnly → the choose coderef`. Supersedes the abandoned **0.9.61** (choose-then-auto-pop-to-`parent`) and **0.9.62–0.9.63** (drill-in of *playable* rows — tapping played/opened the album instead of choosing) iterations. Verified live. **KEY Material fact for this family of bugs:** `refreshList` never re-arms `itemCustomActions`; only a fresh drill does — so any flow that must expose a custom action has to land the user on a freshly-drilled view, not an in-place refresh.
- **0.9.60** — **code-review fix: manual Bandcamp watchdog re-entry.** `_searchBandcampOnly` runs its
  ordered queries (`_bandcampArtists` full/collab/album-only) sequentially under ONE overall watchdog.
  `$tryNext` had no `$done` check, so if a search hung past the watchdog (`min(STREAM_SVC_TIMEOUT*queries,
  30)`s), fired `$finish->([])`, and *then* returned empty, its callback re-entered `$tryNext` and started
  the next query's search — a heavy synchronous Bandcamp parse *after* the row already re-rendered (the
  loop-stall class Bandcamp was made manual to avoid). Added `return if $done;` at the top of `$tryNext`
  (mirrors `$finish`'s idempotency). Control-flow only — no cache bump, matching/caching unchanged.
- **0.9.59** — **Favurl also carries the release year (`&y=`) so Listen Later can dedupe by year.**
  Extends the 0.9.58 handshake: `_attachFavUrl` now appends `&y=<year>` next to `&a=`. Listen Later
  0.1.43 keys its duplicate check on `artist|album|year`, so two same-titled releases from different
  years (Chanel Beads' 2024 vs 2026 "Your Day Will Come") save as two entries instead of the second
  being dropped. Year is derived from `$rel->{release_date}` in `_releaseDetail` and threaded through
  `_findPlayable` (new trailing `$year` param, after `$force`) and `_searchBandcampOnly`/
  `_bandcampSearchRow` to `_attachFavUrl`. Cache `lbf:stream:11:`→`:12:` so albums re-resolve once and
  bake in the year; `lbf:bcmatch:` still not bumped.
- **0.9.58** — **Matched streaming albums carry the artist to Listen Later (`&a=` favurl handshake).**
  The detail-page Add-to-Listen-Later / Wish List rows sent no artist — Material exposes no
  `$ARTISTNAME` for them (thumbnail = service logo, subtitle unmapped) — so the sibling plugin
  stored an artist-less record that never auto-moved to Played (Played matching keys on
  source+artist+album). `_attachFavUrl` now appends a private `&a=<URI-escaped artist>` to the
  favurl next to the existing `?cover=`/`?b=` payload (both callers — the `_findPlayable` settle
  loop and `_searchBandcampOnly` — pass the raw release artist); Listen Later 0.1.42+ reads it as a
  fallback when `$ARTISTNAME` is empty, then strips it so the `album:<id>` logic sees a clean URL.
  Native streaming-plugin favurls (no query string) never trigger it. Cache `lbf:stream:10:`→`:11:`
  so Qobuz/Tidal albums re-resolve once and bake in the artist (free — they self-resolve);
  `lbf:bcmatch:` deliberately NOT bumped (Bandcamp rows already surface an artist; no auto-repopulation).
- **0.9.57** — **Diacritic/accent folding in `_norm` (no cache-version bump).** The matcher normaliser
  now folds Latin diacritics to base ASCII so accented names match a catalogue/library that spells them
  plainly, or with a different Unicode form of the same accent — fixing `Altın Gün — Neredesin Sen`
  (dotless `ı`, `ü`) missing on Qobuz despite being there. Algorithm: `lc` → NFD → strip ONLY the Latin
  combining-mark block `U+0300–036F` → NFC (re-compose, so non-Latin base+mark like Japanese voiced
  kana `ば`=`は`+`U+3099` survives) → map the atomic Latin letters NFD can't split (`%FOLD`: `ı ł ø ð þ
  ß æ œ ħ …`). Gated on `utf8::is_utf8` + `Unicode::Normalize` present (core module; guarded require, so
  a stripped Perl degrades to no-fold). Feeds streaming album/track matching (`_albumMatches`/
  `_trackMatches`), the local-library matcher and de-dupe. ASCII names produce byte-identical output →
  their caches are untouched; only accented-name albums re-key and re-resolve once (self-healing, free) —
  hence no version bump. `tools/match_check.py` updated to the same algorithm (was NFKD + strip-all-marks,
  which mangles Japanese and missed Turkish `ı`); folding is now its default, `--fold` = pre-fold vs
  shipped compare.
- **0.9.56** — **Bandcamp collab-search fallback (no cache bump).** The manual "Search Bandcamp"
  (`_searchBandcampOnly`) now tries an ordered list of RAW queries — full `artist album`, then **each
  collaborator + album** (`_bandcampArtists` splits `&`/`+`/`feat`/`ft`/`with`/`x`/`vs`), then
  album-only — stopping at the first `_albumMatches` hit, instead of a single combined query. Fixes a
  two-artist release that Bandcamp's search only surfaces under one of the artists (*Panda Bear & Sonic
  Boom – A ? of WHEN*). We still do NOT drill an artist's discography (`album_list`); this is
  search-recall only. Extra searches run only on a miss and only on a user tap.
- **0.9.55** — **code-review fixes (no cache bump).** (1) A **persisted manual Bandcamp match** is no
  longer truncated off the detail page: `_streamResult` now caps only the auto (Qobuz/Tidal) matches at
  `STREAM_MAX_RESULTS` and appends the pinned Bandcamp match *after* the cap (deduped), so a 12+-match
  generic title can't drop the Bandcamp-only entry that's meant to be primary. (2) `_parseLastfmTags`
  reads a tag's `count` through a ref guard (was an unconditional deref in both the sort and the
  low-weight filter — a strict-refs die if Last.fm ever returned a bare-string tag). (3) The DSTM
  per-session no-repeat set (`$state{cid}{played}`, never reset by design) is **FIFO-capped at
  `PLAYED_MAX`=5000** so a marathon session can't grow it unbounded. Reviewed but intentionally left:
  DSTM marks all *attempted* candidates (not just returned) as `served` — that prevents re-searching the
  same over-fetched pool next top-up and self-corrects on exhaustion, so it's a deliberate tradeoff, not
  a bug.
- **0.9.54** — **Warm defers during a library scan; manual "Refresh playlist matches"; opt-in debug log.**
  (1) **Fix:** `Plugin::_warmTick` now defers while `Slim::Music::Import->stillScanning()` (re-checking
  every `WARM_SCAN_RETRY`=120s) instead of resolving against a half-scanned library — which had made the
  startup warm resolve **every** owned track to streaming and cache that all-streaming result for the
  resolved-playlist TTL, with later warms skipping the already-cached playlist (diagnosed live: 50/50
  Qobuz, zero library hits, for a user who owned the tracks; "worked on dev" because a dev library is
  already scanned when the warm fires). (2) **Add: "Refresh playlist matches"** row at the **top of the
  Playlists view** (mirrors the feed refresh; not in Settings) → `Browse::refreshPlaylists` →
  `warmCache(force=>1)`; a `$force` flag threaded through `warmCache`→`_resolveTracks`→`_findPlayableTrack`
  re-resolves past **both** cache layers, library-first (async, needs a connected player). (3) **Add:**
  opt-in `debug_log` pref → `Plugin::dbg` writes the warm/resolve timeline (incl. per-playlist
  **library-match count** + scan-defers) to `lbf-debug.log` beside `server.log` (size-capped, one
  rotation; also mirrored to `server.log` at INFO). (4) Debug utilities `tools/match_check.py` (+`--fold`)
  and `tools/fetch_playlist.py` for reproducing the local artist/title matcher off-box. NB: a
  library-first user's playlists take the 1-day `LIBRARY_TTL`, so they re-resolve on each **daily** warm
  — intended (a file URL can go stale on rescan), not the "only-weekly" cheap case.
- **0.9.53** — **Bandcamp page URL now rides the favurl for exact replay (`?b=<art>|<url>`).**
  Bandcamp's `get_album` resolves a tracklist from the album **page URL**, not the `album:<id>`
  in the favurl, so handing a Bandcamp match to Listen Later produced no tracks. `_attachFavUrl`
  now packs the cover art **and** the page URL into one escaped `?b=<art>|<url>` param (Bandcamp
  only — it sets `_albumurl` from the search passthrough; Qobuz/Tidal keep the plain `?cover=`
  and replay by id). Listen Later 0.1.39+ unpacks both → exact `get_album` replay + one-tap
  Buy-on-Bandcamp. **Corrected a wrong conclusion from the 0.9.49–0.9.52 iterations:** the belief
  that "Material drops a favurl > ~150 chars" was an artifact of a **stale repo-installed LBF
  shadowing the manual dev build** (the new favurl code never ran, so the add arrived with no
  favurl). With the right build loaded, the full ~164-char favurl arrives intact — verified by
  the saved record keeping the real cover *and* the page URL. The discarded
  `docs/material-favurl-length-issue.md` (written for the Material dev about the non-existent
  limit) was removed. No cache bump: `lbf:bcmatch:` is never bumped (a fresh manual "Search
  Bandcamp" bakes the new favurl in; older cached matches play without the `?b=` URL until
  re-searched — same rule as 0.9.47). 0.9.49–0.9.52 were the intermediate favurl attempts,
  superseded by this.
- **0.9.48** — **library track matching no longer blocks the event loop (low-power / Raspberry Pi friendliness).**
  `_findPlayableTrack`'s local-library probe (`_findLocalTrack` → `Slim::Schema` / the `titles` request) is the
  one SYNCHRONOUS step in the otherwise-async track resolver, and LMS's DB layer has no non-blocking form (single
  SQLite connection, single thread — can't be made to `await` or run off-thread). Previously, a playlist that matched
  mostly from the library completed each probe synchronously and re-entered `_resolveTracks`' pump in the **same**
  event-loop pass — up to ~50 blocking DB queries with no yield, starving audio on a Pi (the background warm and a
  cold new-week open were the worst cases, exactly the loop-stall class that got Bandcamp pulled from the auto-search).
  Fix: every library probe now runs via `Slim::Utils::Timers::setTimer(undef, time(), …)` (an idle tick), so the loop
  services audio/UI **between** probes. To do this `_findPlayableTrack` was restructured — a `$deferLocal` helper wraps
  the probe and the streaming phase is factored into a `$runStreaming` closure so the `first`/`fallback`/no-adapter
  tiers can run it after their deferred probe. **Same total work, no contiguous freeze; matching/caching/behaviour
  unchanged** (the probe is reached only on a cache MISS — the warm pre-resolves, so normal opens are cache hits that
  never get here), so **no cache bump**. NB: the DB query itself still blocks for its own (short) duration — deferral
  isolates each one; it can't make a single query async. If a single `titles` search is ever slow enough to matter on a
  huge library, the next lever (not taken here, has cache-poisoning subtlety) is MBID-only library lookup during the warm.
  Also folded in three no-behaviour-change cleanups: trimmed a stale cache-version list in `_findPlayable`'s comment
  (named `:7:` while the key is `:10:` — authoritative history is on `_streamKey`); dropped two unused strings
  (`PLUGIN_LBF_PLAY_VIA`, `PLUGIN_LBF_NO_SERVICES`); and `_parsePlaylistTracks` stopped parsing three never-read JSPF
  fields (`duration_ms`, `caa_id`, `caa_release_mbid`).
- **0.9.47** — **code-review fix: stop the favurl cache bump from discarding manual Bandcamp matches.**
  The 0.9.42 favurl work bumped the persisted-Bandcamp-match key `lbf:bcmatch:6:`→`:7:`. Unlike the auto
  play-via cache (`lbf:stream:*`, which re-resolves itself on the next detail-page open), `lbf:bcmatch:`
  has **no automatic repopulation** — a match only returns via a manual "Search Bandcamp" tap — so the bump
  silently dropped every hand-curated Bandcamp-only match on update, leaving those releases with no playable
  entry until each was re-searched by hand. Reverted the key to `:6:`: existing matches survive the upgrade
  and keep playing; a *fresh* search still bakes the favurl in (`_searchBandcampOnly` → `_attachFavUrl`), an
  older cached match just plays without the favurl until it's next re-searched. Qobuz/Tidal are unaffected —
  their `lbf:stream:10:` bump stands (that cache re-resolves on its own, so bumping it is free). **Rule: never
  bump `lbf:bcmatch:` for a change the auto path already handles via `lbf:stream:`.**
- **0.9.46** — **code-review fix: utf8-safe cover encoding in the favurl.** `_attachFavUrl` now
  encodes the `?cover=` album-art URL with `URI::Escape::uri_escape_utf8` instead of `uri_escape`,
  which `carp`s + emits a malformed escape on code points > 255. Art URLs are ASCII in practice, so
  no behaviour change and **no cache bump** — just removes the one new spot that fed a possibly
  utf8-flagged string to a non-utf8-safe escaper (the file otherwise `utf8::encode`s before every
  wide-char-sensitive call).
- **0.9.45** — **Finalise the Qobuz-duplicate fix + favurl guard tidy.** Removed the temporary
  `QOBUZ-DIAG` log from 0.9.44 (the live box confirmed the bogus *Beth Orton – The Ground Above*
  entry is flagged non-streamable, so `streamable`-only is enough). Also hardened `_attachFavUrl`:
  the `?cover=` guard is now `!ref $art` instead of `$art !~ /^CODE/`, so any ref (not just a
  coderef) is rejected before it can be stringified into the favurl. No cache bump (neither change
  alters which results match or what gets cached).
- **0.9.44** — **Dismiss the bogus Qobuz duplicate by the `streamable` flag alone.** Replaced
  0.9.43's non-streamable-and/or-`*`-prefixed-title test with the **non-streamable** check only
  (`defined $album->{streamable} && !$album->{streamable}`) in `_searchQobuz` — the `*` heuristic
  never actually distinguished the two duplicates (`_norm` strips a leading `*`) and risked dropping
  a real `*`-titled album. Cache `lbf:stream:9:`→`:10:` so albums re-resolve once. (Shipped with a
  temporary `QOBUZ-DIAG` log to confirm on the live box; removed in 0.9.45.)
- **0.9.43** — **Skip bogus Qobuz partial/orphaned album duplicates.** Qobuz's catalogue
  can list a release twice: the real playable album plus a non-streamable partial/orphaned
  entry whose title is `*`-prefixed (e.g. *Beth Orton – The Ground Above* → two matches, one
  dead). `_norm` strips the leading `*`, so `_albumMatches` passed the bogus one and it
  showed as a second streaming row. `_searchQobuz` now drops a candidate when
  `defined $album->{streamable} && !$album->{streamable}`, or its raw title `=~ /^\s*\*/`,
  or (belt-and-braces, after rendering) the display `name`/`line1` starts with `*`. Scoped
  to the Qobuz **album** path; the track path (`_searchQobuzTrack`) is unchanged — revisit
  if a bogus entry ever surfaces in a playlist. Cache `lbf:stream:8:`→`:9:` so cached albums
  re-resolve once and drop the dead entry.
- **0.9.42** — **Listen Later interop for matched streaming albums.** Each matched
  Qobuz/Tidal/Bandcamp album on the detail page now gets an explicit
  `favorites_url => "<scheme>://album:<nativeId>"` (`_attachFavUrl`, called from the
  `_findPlayable` settle loop and the manual-Bandcamp `finish`; the native id is stashed
  as `$item->{_albumid}` in `_searchQobuz`/`_searchTidal`/`_searchBandcamp`). XMLBrowser
  copies an explicit `favorites_url` into `presetParams.favorites_url`
  (`= $item->{favorites_url} || $item->{play} || $item->{url}`) which Material exposes as
  `$FAVURL` — previously the rows had none, so the coderef `url` leaked through as the
  favurl (the sibling Listen Later plugin saw a "broken link", couldn't tell the service,
  and stored the logo as the cover). **Cover-vs-logo trick:** the row's `image` stays the
  **service logo** (the detail-page indicator), so the album art can't ride `$IMAGE`;
  instead `_attachFavUrl` appends `?cover=<URI::Escape-d native album art>` to the favurl.
  Listen Later 0.1.30+ parses `?cover=` off the favurl, prefers it over `$IMAGE`, then
  strips it so its source/`album:<id>` logic sees a clean URL — a private convention
  between the two plugins, opaque to Material (which just forwards the favurl). The
  decorated favurl survives the play-via cache (`_cacheStream`/`_rebuildStreamItems` keep
  `favorites_url`+`_albumid`). **Cache bumped** `lbf:stream:7:`→`:8:` and `lbf:bcmatch:6:`→`:7:`
  so every album re-resolves once on update and gains the favurl — old cached matches lacked
  it, so without the bump a recently-opened album would serve a stale (favurl-less) match for
  up to its 7d TTL. NB: the "Add to Listen Later" action only renders on a
  Material build with PR #1235's online-custom-actions support. Side effect: native LMS
  "Add to Favourites" on these rows would now save the decorated URL (was a broken coderef
  before, so no regression).
- **0.9.41** — **code-review fixes: streaming robustness + dead-code cleanup.**
  (1) **Album streaming search guards the foreign renderer.** `_searchQobuz`/`_searchTidal` now wrap
  the service's own album renderer (`Qobuz::_albumItem` / `TIDAL::_renderAlbum`) in an eval INSIDE the
  async search callback — where `_findPlayable`'s invocation-time eval doesn't reach. A broken/changed
  renderer now skips that item instead of leaving the service un-settled until its 8s timeout (matching
  the track path's long-standing `_renderTrack` guard). One bad item is skipped, not the whole service.
  (2) **Album play-via gained the track path's "inconclusive" concept.** A service that couldn't be
  QUERIED (no API handler at search time, a timeout, an error, or a renderer that produced nothing from
  a real match) signals `undef` (not `[]`) and is cached as a no-match only `STREAM_INCONCLUSIVE_TTL` =
  1h, so it retries soon. A genuine "searched fine, not there" miss still caches 1 day
  (`STREAM_NOMATCH_TTL`); a found match still 7 days. So a transient outage or a just-released album
  recovers within the hour (or instantly via Refresh) instead of being pinned for a day — the album path
  now mirrors `_findPlayableTrack` exactly. **Verified against the live `/cf/recommendation` API** that
  `artist_type` similar/raw/top return the identical payload and that omitting it returns the same data.
  (3) **Cleanup, no behaviour change.** Removed the dead `annotation`/`track_count` fields and the now-
  orphaned `_stripHtml` from `_parsePlaylistList` (neither was ever read — the tile shows the period +
  resolved match count, not the annotation); dropped the unused DSTM recommendation `flavour`/`artist_type`
  parameter (request unchanged, fixed at `similar`; the endpoint feeds both the Recommended mixer and
  Radio's cold-start fallback); and removed a redundant double-`_norm` in `_streamId` (proven byte-
  identical, so cache keys are unchanged). Matching logic (`_albumMatches`/`_trackMatches`/`_norm`) untouched.
- **0.9.40** — **code-review housekeeping (no behaviour change beyond one bugfix).**
  (1) **Bugfix:** a dead `//` fallback (`_pickValue` returns `''`, never undef) meant a release with
  no artist/album credit rendered as `" — Album"` with no name — the `// 'Unknown Artist'` /
  `'Unknown Album'` fallbacks are now `||` so they actually apply. (2) **`USER_AGENT` no longer
  hardcodes the version** — `API::USER_AGENT` is now a memoised sub that reads the version from the
  plugin manifest (`Slim::Utils::PluginManager->dataForPlugin(...)->{version}`); it had silently
  lagged 17 releases (stuck at 0.9.22). **Rule: never restate the version in code — derive it from
  install.xml via the manifest.** (3) **`_cachedSvcUsable($svc, $enabled?)`** takes an optional
  precomputed `{ lc-name => 1 }` enabled-set; `_playlistResult` / `_playlistTile` build it once per
  render instead of rebuilding the whole adapter set (3 `->can` probes + prefs reads) once per track.
  (4) **Watchdog timers cancelled on normal completion** (`Slim::Utils::Timers::killSpecific`) in
  `_resolveTracks`, `_releaseDetail`, `_searchBandcampOnly` and the per-service timeouts in
  `_findPlayable` / `_findPlayableTrack` — they were harmless idempotent no-ops but lingered holding
  closures for their TTL. (5) **`dstm_batch` fallback** `|| 10` → `|| 15` to match the init default.
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
