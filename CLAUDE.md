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
- **Albums or Singles & EPs, from the list** — a "Showing Albums (tap for Singles & EPs)" row flips either feed between the two and back, with the icon changing to match, so singles and EPs can stay switched on without burying the albums. Sticks across visits and restarts; only appears when a section has both kinds ticked.
- **Your taste** — filter by type / artwork-only / Various Artists; **per-view sort** (a "Sorted by…" toggle in each list's Options section — Release Date / Artist / Album Title, kept within the weekly W/C headers); release-window; cached & pre-warmed (instant), **no extra server software**.
- **Plays nicely with Listen Later** — adding a release passes the real MusicBrainz release type (album / EP / single) across, which the streaming services mostly don't expose, so the saved row is labelled and play-tracked correctly rather than guessed from a track count.

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
0.9.150

### State of play (2026-07-30) — read this before starting anything

**PLANNED WORK — scoped 2026-07-31, none of it started. Read the doc before opening the code:**
- **`docs/token-free-refactor.md`** — the plugin can drop the ListenBrainz token AND the Last.fm key
  entirely. Verified against LB server source + live anon calls: **the token is needed for exactly one
  thing**, `recording_recommendation` events. `fresh_releases` (the flagship feed!) is public and is
  gated on a token it never needed. Public replacements found for the rest (loved tracks, pins). Scope,
  code changes, cache bumps and the one open design question (volume) are all in the doc.
- **`docs/year-in-music.md`** — Spotify-Wrapped-style yearly review from LB's public Year in Music
  endpoint. One request, 20 pre-computed sections, most of it reuses existing machinery. Cheapest big
  feature on the board. Needs a tester with a longer listening history.
- **`docs/recommended-listening-row.md`** — Material **home-row-only** "Recommended Listening": ≤30
  most-regarded albums the user *doesn't* own, from library artists + similar artists, monthly, one
  album per artist. Regard signal is deliberately multi-source; **LB popularity is excluded** (verified
  500/disabled again 2026-07-31, same outage as 0.9.77). Key findings: the primary-Album/no-secondary
  type filter does most of the work (Radiohead 100 RGs → 10), a **raw MB rating sort is actively wrong**
  (1-vote bootlegs outrank *OK Computer*), and the regard signal is a 6-tier blend whose spine is a
  **shipped acclaim data file** (3,476 albums × 58 critic lists, zero API calls). Ownership filtering
  **adapts the existing `'exclude'` libMode** — verified the `albums` CLI takes `search:` like
  `titles` — but there is **no album MBID tier** (not in `albums_loop`, and our MBIDs are
  release-GROUP vs LMS's release), so it's text-matching only: bias uncertain toward "owned".
- **`docs/genre-sources-investigation.md`** — investigated MAI / the hosted LMS-community API as a
  genre backend. **Conclusion: not for list rows** (16% coverage on real fresh releases vs our
  existing 49%, per-album not bulk, non-MB vocabulary, and **no artist-genre route to fall back to** —
  `/artist/<n>/genres` silently returns the *picture* payload with a 200, it never 404s). Good
  detail-page enricher. **Does not change why the genre work is parked on `alpha`.**

**Branches.** `dev` (this one) is the working line at **0.9.149**, committed and pushed
(0.9.147–0.9.148 landed as `a7e1ac4`; 0.9.149 is the Trending Albums empty-cache fix, tagged
`v0.9.149`). `alpha` holds the parked
genre work at 0.9.140 — pushed, see `ALPHA.md` there, do not merge it. `main` is still at
**0.9.98**: everything from 0.9.99 on (People You Follow, Trending, the matcher fleet sync,
0.9.126–0.9.128 and 0.9.141) has never been promoted, so "what users have" is far behind
`dev`. `beta` is untouched and stale.

**Fleet holds — both deliberate, don't try to tidy them up:**
- **Matcher sync is ON HOLD** until Discography's rework lands. `matcher_sync_check.py`
  exits 1 by design; see the banner on the Shared Matching Engine rule below.
- **Search Hub is ON HOLD.** No work on `LMS-Search-Hub` and nothing here should start
  depending on it.

**Known open items on this repo, none of them started:**
- **CHANGELOG has no entries for 0.9.120–0.9.125.** 0.9.120 shipped as a commit (the fleet
  matcher sync) with no changelog block; 121–125 have none at all. Not reconstructed — the
  record is genuinely missing, so don't invent it, and don't be surprised by the gap.
- **Discography carries the same wide-character cache bug fixed here in 0.9.141**, in FOUR
  places: `Discography/Browse.pm` ~1159 (`$text`, artist bio), ~3240 (`$desc`, review
  description), ~3270 (`$text`, MAI album review) and `Discography/API.pm` ~705
  (`$canonName`, MB canonical artist name). All bare-string `$cache->set` calls. Port
  `API::_setText`/`_getText` — it is NOT the shared matcher, so the hold above doesn't apply.
- **0.9.141 VERIFIED ON THE REAL SERVER (2026-07-29).** Installed build fingerprinted via the log's
  `Sub::Name (LINE)` numbers (`_fetchArtistInfo (4074)`, MAI bio `(4108)`). Confirmed live:
  - **The `&rt=` handshake works through Material.** Added *3OH!3 – MY FRIENDS* (MB **Single**, 3
    tracks — so LL's count fallback would say **EP**) from a Qobuz match row. Log:
    `LL: add -> qobuz / MY FRIENDS (id=189, already=0, list=later, rel=single)`, reached via
    **`_finishAlbumAdd` 2.3 ms after** `LL: addctx params ->`. That path is only taken when
    `$relType` is already set, which for a non-library source can ONLY come from `&rt=` — without it
    LL would have gone through `_classifyThenAdd` + a Qobuz `getAlbum` round trip. The list row
    renders `♪` (GLYPH_SINGLE) vs `♫` on every other row. **`&a=` and `&y=` proved too**: Material
    sent `artist=` empty and `year=(undef)`, yet the stored row shows `3OH!3 … (2026)`.
    (NB the log prints the favurl AFTER LL strips its private params in place, so a bare
    `favurl=qobuz://album:<id>` there is expected and proves nothing either way.)
  - **The Albums / Singles & EPs selector** renders on the real server once both families are ticked
    (`Showing Singles & EPs (tap for Albums)`), and is correctly ABSENT under the default
    Album+Compilation types.
  - **The `lbf:bcmatch:` revert matters in the field**: two For You releases (*Phoebe Bridgers – Lost
    Weekend*, *The Mountain Goats – Days*) resolve to **Bandcamp only** from pinned `:6:` matches —
    the `:7:` bump would have left both with no playable entry.
- **`_effectiveView`'s clamp is DRILL-IN ONLY** (noticed live): it runs inside the `_buildAllLanding`
  week coderef, so a bad stored `all_view` is only corrected when a week is actually opened. Simon's
  `all_view` was sitting at `singles_eps` and surfaced the moment Single/EP were ticked — the exact
  0.9.127 symptom. Residue from before that fix rather than a new bug (the clamp persists correctly
  once a week is opened), but if it recurs, the fix is to clamp at the landing level too.
- ~~**THE INDEX IS STALE — `git add` before any commit.**~~ **RESOLVED — verified clean 2026-07-31**
  (`git status --porcelain` on `dev` reports nothing but untracked files). The staging area had held
  the **alpha genre snapshot** (staged `Browse.pm` with the genre subs, staged `install.xml` saying
  0.9.120) against a genre-free 0.9.141 working tree, so a plain `git commit` would have landed the
  parked genre work on `dev`. It no longer does. Kept here because the failure mode is worth
  recognising — see [[git-selective-restore-poisons-index]].

**0.9.141 pre-release review (2026-07-29) — three defects found and fixed, no version bump**
(nothing had shipped; guarded by `tools/t_review_fixes.pl`, which reproduced all three first):
- `lbf:bcmatch:` had been bumped `:6:`→`:7:` for the `&rt=` favurl — see the rule under the
  Listen Later section above; reverted to `:6:`.
- `API::clearFeedCache('user')` dropped MuSpy's cache key but not its **memo**, and
  `getMuSpyReleases` checks the memo FIRST — so Refresh re-served the very MuSpy copy it was
  meant to replace whenever the LB re-fetch landed inside `FEED_MEMO_TTL` (5s). Now drops both,
  like the two feed keys beside it.
- An All Releases week whose releases are all filtered out by the active family lens opened
  showing its Options rows and nothing else: the week ROWS are built from the section list
  *before* `_viewFilter` (the landing can't know the lens — it's re-read per walk inside the
  coderef). Now emits `PLUGIN_LBF_NO_RESULTS`, like an empty landing.

**Repo test scripts** (all exit 0 on `dev`; run the relevant one after touching that area):
`tools/bench_walk.pl` (per-walk render cost + the memo assertions), `tools/t_cache_widechar.pl`
(the DbCache bare-string bug, reproduced against real DBD::SQLite),
`tools/t_ll_handshake.pl` (the `&rt=` release-type handshake, driven from BOTH repos' live
source), `tools/t_review_fixes.pl` (the three 0.9.141 pre-release review defects — bcmatch bump,
MuSpy memo on Refresh, empty week under the family lens), `tools/t_trending_empty.pl` (the
0.9.149 empty-aggregate TTL + the Refresh row on the empty Trending Albums view;
`LBF_BROWSE=` points it at a mutated copy for anti-testing), `tools/matcher_sync_check.py`
(currently exits 1 — see the hold).

- **Listen Later release-type handshake — `&rt=` on the favurl (0.9.141).** LL 0.1.86 stores a
  release type per row (`album|ep|single`) and drives its glyph, its Played thresholds (single = 1
  play, EP = 2) and its single-vs-single dedupe off it. LL cannot determine it itself for a streaming
  add — **only Qobuz exposes a release_type; Tidal and the rest expose none on the track coderefs** —
  so it falls back to guessing from the resolved TRACK COUNT (1 → single, ≤6 → EP). That guess is
  wrong for a 3-track album, a 1-track album and an 8-track EP, all of which occur.
  - We have the authoritative answer (the MusicBrainz release group in the feed), so `_attachFavUrl`
    now packs it as **`&rt=`**, the channel LL documents for exactly this
    (`Sources::relTypeFor(service => …)`, which **wins over** the count guess; `Plugin.pm` strips the
    param like the existing `&a=` / `&y=` / `&al=` handshakes).
  - `_llRelType` sends ONLY `album|ep|single` and **omits the param** for MusicBrainz primary types
    Broadcast/Other/blank — better LL's heuristic than a confident wrong answer. Compilations,
    soundtracks and live albums are primary type Album with a SECONDARY type, so they map to `album`
    correctly.
  - **The AUTO cache bumped, `lbf:stream:20:`→`:21:`** — `favorites_url` is part of the cached item
    (`_cacheStream` stores everything but `url`), so without the bump every already-resolved album
    would keep serving a typeless favurl and the handshake would look broken for weeks.
  - **`lbf:bcmatch:` stays at `:6:`.** 0.9.141 first bumped it to `:7:` "same reason `_streamKey`
    bumped" — which is the 0.9.42 mistake 0.9.47 reverted, caught in the pre-release review and
    reverted again. `_streamKey` re-resolves itself so bumping it is free; a pinned Bandcamp match
    comes back ONLY from a manual "Search Bandcamp" tap, so a bump silently deletes every
    hand-curated Bandcamp-only match (its sole playable entry) — and because `lbf:bcdone:6:` is NOT
    bumped alongside it, those albums then read "not found — tap to retry". So the "bump EVERY cache
    layer" rule does NOT extend to this key; the standing rule above wins.
  - **`tools/t_ll_handshake.pl` tests BOTH ENDS** — it extracts LBF's `_attachFavUrl`/`_llRelType` and
    LL's `relTypeFor`/`_normRelType`/`_stripPrivateParams` from their live source files and checks the
    round trip, so a change to either repo's half will fail it. Run it after touching either side. Its
    three source paths are env-overridable (`LBF_BROWSE`/`LL_SOURCES`/`LL_PLUGIN`) so it can be pointed
    at a mutated copy and **anti-tested** — do that for any new assertion here.

- **Listen Later album-title handshake — `&al=` on the favurl (0.9.144).** The favurl now also carries
  the CLEAN album title, because Material hands LL the row's display LABEL as `$ALBUMNAME` and that
  label is whatever the streaming plugin's renderer printed. Full reasoning, the correction to my first
  (overstated) justification, the deliberate edition-collapse consequence, the encoding contract and the
  test/anti-test numbers are in the **0.9.144** Version History entry — read that before touching this.
  Two things to carry in your head: **LL already strips a known suffix list** (so this is about the
  qualifiers NOT on it, not about `(Album)`), and **`_streamKey` had to bump** (`:22`→`:23`) because the
  favurl is part of the cached item — and has bumped on every subsequent change to this value, now
  `:27:`.
  - **What `&al=` carries, in one line (0.9.148):** the RAW `title` from the service's own album hash
    (`_svctitle`), verbatim for Qobuz/Tidal/Deezer, and `_stripArtistAffix`'d for Bandcamp ALONE,
    whose passthrough joins the artist on. Read 0.9.144→0.9.148 as one sequence: five builds, four of
    them correcting the previous one, every wrong value silently un-matchable at playback. **Both
    directions are the same bug** — a title with something extra in it, and a title with something
    taken out of it — so any future transform here needs live evidence from the service it's applied
    to, not symmetry with another service.

- **NEVER `$cache->set($key, $a_plain_string)` (0.9.141).** `Slim::Utils::DbCache::set` Storable-freezes
  a value only `if (ref $data)`; a plain scalar goes STRAIGHT to a DBI `SQL_BLOB` bind, and binding a
  Perl string with any codepoint above 255 dies **"Wide character in subroutine entry at
  .../Slim/Utils/DbCache.pm line 78"**. Reproduced against real DBD::SQLite in
  `tools/t_cache_widechar.pl` (run it — 3 of its 5 cases die before the fix, 0 after).
  - Every OTHER cache write in this plugin has always been safe by accident: they all store
    hashrefs/arrayrefs, so `freeze` does the encoding. The only two that stored a BARE string were
    `warmArtistSorts` (the MB sort-name — the `artist-sort cache set failed` spam in live logs, once
    per non-Latin artist) and `getArtistBio` (a Last.fm bio, where **one curly quote or em-dash is
    enough**, so almost no bio was ever cached and every release-page open re-fetched it).
  - Fixed at the boundary with **`API::_setText` / `_getText`**, which wrap in a hashref so Storable
    handles any codepoint and hands the string back with its utf8 flag intact. Chosen over
    encode-on-write/decode-on-read: one place to get right, no mojibake risk, and `_getText` reads a
    legacy bare string unchanged so **no cache prefix needed bumping**.
  - **Distinct from the 0.6.15 bug**, which was the same die from the KEY side (`_key` md5's the key).
    Keys built from free text are encoded to octets at the point of use — see `getLastfmTags` /
    `getArtistBio`. Both halves have now bitten; check both when adding a cache.
  - **FLEET (audited 2026-07-29, NOT fixed):** Discography has the same latent bug in two places —
    `Discography/Browse.pm` (~3270, the MAI album-review `$text`, free prose so it fails routinely)
    and `Discography/API.pm` (~705, `$canonName`, the MB canonical artist name, fails for non-Latin
    artists). PFR, Listen Later, Search Hub and Album Booklet are clean (all ref-valued).

- **BRANCH SPLIT (2026-07-29) — genre work lives on `alpha`, not here.** The genre-labels feature
  (0.9.129–0.9.140: list-row genres, the family rollup table, the genre picker, the mirror-first
  artist-genre fetcher) is **parked on the `alpha` branch** pending a decision on whether the plugin
  adopts a Lyrion API server as a metadata backend. **Read `ALPHA.md` on that branch before reviving
  any of it.** Short version of why: genre labels need a genre source for every release in a feed, and
  the only source available without a local MusicBrainz mirror is ListenBrainz's metadata endpoint,
  which answers a 50-release batch in **anywhere from 0.25s to 24s** (not rate limiting —
  `x-ratelimit-remaining` was 26–29 of 30 throughout), 502s above ~90 mbids, and took a measured
  **125s** to fill one 381-release feed. `dev` therefore keeps the pre-0.9.129 genre behaviour: list
  rows show the feed's own `release_tags`, and the release detail page does its own per-album
  `release-group?inc=genres` lookup (mirror-aware) with Last.fm as the fallback.
  - **`dev` DOES carry the non-genre work built alongside it** — the Albums / Singles & EPs view
    toggle (0.9.126–0.9.128) and the whole per-walk performance pass (below). A fix made here will
    need re-applying to `alpha` whenever that branch is unparked.
  - Versions **0.9.129–0.9.140 are burned** — they exist only on `alpha` and were never released.
    `dev` continues at **0.9.141** so a version number never means two different things.

- **Per-walk work elimination (shipped as 0.9.141; developed as 0.9.139) — the sequel to 0.9.138, and the half that memo left
  undone.** `%FEED_MEMO` stopped the re-walks RE-READING the feed; they were still RE-DERIVING it.
  Measured, don't guess: `tools/bench_walk.pl` extracts the real sub bodies from `Browse.pm` (the
  `matcher_sync_check.py` trick) and runs them against a live feed with no LMS. On 2902 raw releases
  (14-day default window) on a dev Mac, one walk of the All Releases pipeline was **1.1ms filter +
  3.7ms dedupe/sort + 2.8ms week grouping ≈ 7.6ms**, ×3+ walks per tap, ×2 sections — and a Pi is an
  order of magnitude slower. Rerun the script after any change to that pipeline.
  - **`%SECTION_MEMO` + `_allSection`/`_forYouSection`** — the derived (filtered, deduped, sorted)
    list per section, held `SECTION_MEMO_TTL`=5s. Validity is by **IDENTITY of the source
    arrayref(s)**, not a content hash: the feed memo returns the same ref for its TTL, and a Refresh
    (`clearFeedCache` → `_memoDrop`) necessarily produces a NEW ref, so a refresh can't be masked.
    The memo holds those refs itself, which is what makes `==` sound (an address can't be recycled
    while we point at it). Everything else that shapes the result is prefs → `_sectionSig`. **For You
    needs TWO sources** (`_mergeMuSpy` builds a fresh arrayref every call), which is why
    `getMuSpyReleases` is memoed too — not for its own cache read, but to make its ref stable.
    Callers must keep treating the returned list as READ-ONLY; it is shared across walks (as the raw
    feed already was).
  - **`_weekStart` memoed** — pure function of a date string, called once per release by BOTH
    `_buildAllLanding` and `_buildWeekly`, resolving to ~15 distinct dates. 2.7ms → 0.2ms. Never
    expires: the answer for a date can't change and the key space is what the feed carries.
  - **`_stashSummary` / `_stashPlaylistSummary` write elision** (`_summaryChanged`) — these were
    SQLite WRITES on every walk of every render path, storing bytes identical to what was there.
    Watch the trap: a skipped write is a skipped TTL RENEWAL, so it rewrites unconditionally every
    `SUMMARY_REWRITE`=6h, well inside the 25h TTL. `_stashSummary` also scans for min/max instead of
    sorting the whole list.
  - **`_orderedAdapters` memoed** (`ADAPTER_MEMO_TTL`=5s) — ~10 `->can` probes + a `_pluginDataFor`
    icon lookup per service, built TWICE per root walk by `_trendingTile` alone (once inside
    `_trendingResolvedKey`) and on the per-item path via `_cachedSvcUsable`. Adapters are read-only
    to every consumer (checked), so sharing the hashrefs is safe.
  - **`_trendingTile` count memoed** — it deserialised the whole resolved track list out of SQLite on
    every root walk purely to count what survives the service filter. Keyed on the resolved key (so a
    user/service-order change re-counts), dropped by the Refresh row via `_dropTrendingCount`.
- **Picker scope + the feed memo (0.9.138) — two fixes to one report ("counts don't match, and it's
  sluggish").**
  - **Scope.** `genrePicker` called `_feedFor` and counted the WHOLE feed, so an All Releases week
    showed feed-wide counts. `_genresRow($client, $prefix, $rels)` now hands the picker the level's
    own releases via `passthrough` (rebuilt every walk, so never stale); `_feedFor` survives only as a
    defensive fallback. This is also most of the speed-up: no second full-feed decode, and the genre
    fill covers one week instead of up to `GENRE_WARM_MAX` across all of them. The apply row can now
    count honestly (`Show 12 releases`), which it couldn't at feed scope.
  - **`API::%FEED_MEMO`** — the last decoded copy of each feed key, held `FEED_MEMO_TTL`=5s.
    `Slim::Utils::Cache` is SQLite: a feed "cache hit" is a disk read plus a full deserialise of
    thousands of releases, and **XMLBrowser re-walks from the ROOT on every drill-in, in-place refresh
    and paging tap** — the root builds both sections, so one tap decoded the same feeds 3+ times and a
    genre tick (toggle request + `refreshList`) did it twice over. Confirmed in the live log: bursts of
    `All + ForYou + ForYou` repeating every ~0.5s. 5s covers one interaction and nothing more;
    `clearFeedCache` calls `_memoDrop` so Refresh can't be masked, and every pref that shapes a feed is
    already in the cache key so a settings change can't be served a stale copy. `our`, not `my`, so
    `t_memo.pl` can age it.
  - **If browsing feels slow again, look here first**: the cost is almost never the network (feeds are
    cached) — it's re-walk × deserialise × per-release work. Measure by counting `$cache->get` calls,
    not by timing HTTP. Since 0.9.139 the per-release half of that has a harness:
    `perl tools/bench_walk.pl`.

- **Genre picker needs an explicit apply row — plain Back can NEVER work (0.9.137).** 0.9.136 shipped
  the picker with immediate apply and no return path; the ticks saved fine (verified live: the pref
  held `["Electronic"]`) but Back showed the unfiltered list. **Verified in Material's own bundle**
  (`http://plex:9000/material/html/js/material-deferred.min.js` — fetch and grep it, it's the fastest
  way to settle a navigation question):
  - `browseGoBack()` **restores the history entry's cached `items`** (`a.items=g.items; a.listSize=…`).
    It re-fetches ONLY if `b || g.needsRefresh`.
  - `needsRefresh` is set **exclusively by Material's own internals** — podcasts `addshow`/`delshow`,
    search, playlist drag-moves. **There is no server-driven way to mark a parent level stale.** So a
    plugin can never make plain Back re-render. Any "change a setting on a drill-in level" flow needs
    an explicit apply row.
  - `browseHandleNextWindow(a,b,c,e,d,g)` runs only when the response has **0 items**, and from the
    normal drill-in path is called as `(…,d=false,g=true)`. With those args:
    **`refresh`** → `browseGoBack(a,true)` = pop the empty window, restore the row's OWN level, refresh it.
    **`parent`** → `a.history.pop(); browseGoBack(a,true)` = pop this level too, land one BELOW, refresh it.
    Both also `bus.$emit("showMessage", <row title>)`, so every tap toasts its own label.
  - So: ticks use `refresh` (flip in place), the apply row uses **`parent`** (return + rebuild).
  The apply row **names the selection** ("Show Rock, Electronic", `GENRE_APPLY_NAMES`=2 then "+N more")
  rather than counting results — the picker is opened from an All Releases **week** but reads the whole
  feed, so any count would be feed-wide and wouldn't match the week it returns to. (The per-genre counts
  are feed-wide for the same reason; there they're wanted, as a view of the feed's shape.)

- **Genre picker — multi-select filter (0.9.136).** Modelled on the genre-selection menu in
  **SvenInNdh's Qobuz fork** (`https://github.com/Sveninndh/SqueezeboxRepo`, `Qobuz-30.7.3.6`,
  `Plugin.pm::QobuzGenreSelection/QobuzGenreToggle/QobuzGenreStore`) — worth reading if this area is
  revisited. **Taken:** checkbox rows + a Select-all row + the count on the entry row
  ("Genres (3)" / "Genres (All)"). **Deliberately diverged, three ways:**
  1. **IMMEDIATE APPLY — no staging buffer, no Store row.** Sven's stages toggles in memory and commits
     on save, which forces a `refreshing` flag plus a `$params->{index} eq 0` heuristic to tell an
     internal refresh from a fresh entry. Our picker is its own drill-in level rendering off cached
     data, so the pref is written directly and all that state disappears.
  2. **Material's own `_MTL_icon_check_box` / `_check_box_outline_blank`** font icons — no custom
     checkbox artwork (Sven ships `checkbox-checked_svg.png`).
  3. **ARRAYREF pref**, not a `#id#id#` delimited string — no regex membership tests, and a family name
     can't corrupt the separator. Matches the existing `blocked_artists` shape.
  - Prefs `foryou_genres` / `all_genres` (arrayrefs, EMPTY = show everything — same convention as the
    release-type checkboxes). `_bucketFor` is the FILING key: a real family only, or `GENRE_NONE`
    (`_none`) — distinct from `_familyFor`, which is for DISPLAY and falls back to the raw genre.
    Without that split an obscure genre would sprout its own singleton bucket in the picker.
  - Picker lists **only families present in the feed**, busiest first, `Other` forced last.
  - **ORDERING CONSTRAINT:** the genre filter must be applied BEFORE `_pageSection`, or a 30-row page
    is mostly filtered away and the "Show more (N)" counts lie. That needs genres for the WHOLE week,
    so the All Releases week coderef does the wider `GENRE_WARM_MAX` fill **only when a filter is
    actually set**; unfiltered keeps the cheap one-request-per-page path.
  - **COMPILE-TIME GOTCHA:** `use constant` is BEGIN-time, so a constant must appear EARLIER IN THE FILE
    than any use of it. `GENRE_WARM_MAX` was defined next to `_warmGenres` (line ~5800) but is now used
    by the picker and the week coderef (line ~3360) → "Bareword not allowed while strict subs". Moved up
    with the other constants. Subs don't have this problem, only constants.

- **PHASE 3 DONE — gated Last.fm tier (0.9.135). 49% → ~71% coverage.**
  - **THE TIER LADDER now lives entirely in `_genresFor`** — one source of genres, one producer of a
    row label: **(1)** the album's own LB genres → **(2)** the artist's LB genres → **(3)** the feed
    payload's inline `release_tags` (free, release-specific, proven independent of LB's tag block) →
    **(4)** Last.fm, gated. Nothing may append a source anywhere else; that was the 0.9.132 bug.
  - **The gate is MusicBrainz's vocabulary.** `genre-families.txt` now carries the WHOLE 2177-name
    vocabulary (2216 rows: 855 in 21 families, 27 modifiers `-`, 1334 family-less `?`), so it is both
    the rollup table AND the "is this actually a genre?" list. `_genreKnown` = in the vocabulary AND not
    a modifier. Measured raw Last.fm noise it rejects: japanese, Colombia, anime, Dreamy, zzz, brainrot,
    seen live, 90s. **`?` vs `-` matters:** a family-less genre is still shown; a modifier never is.
  - **The render path NEVER fetches.** Last.fm is per-ARTIST, not bulk — filling on render would be
    ~15 HTTP calls per 30-row page, the exact opposite of phase 1. `API::peekLastfmTags` is a
    cache-ONLY read (mirrors `peekArtistSort`); `_lastfmGenres` uses only that. Asserted by test.
  - **`_warmLastfm` does the filling**, chained inside `_warmGenres` after each feed's bulk pass:
    only releases no cheaper tier answered, **deduped by ARTIST** (the tags are artist-level anyway),
    hard-capped at `LFM_WARM_MAX`=40 per tick, ONE call in flight behind a 1s idle tick (paced for
    Last.fm, never holds the event loop). 30-day cache, so a small nightly allowance converges over a
    few days. No API key → the whole tier is inert.
  - Side benefit: because tier 3 moved into `_genresFor`, the detail page's Genres line now shows inline
    `release_tags` too — closing the "sub-genres appear under Tags: not Genres:" gap noted in 0.9.132.

- **PHASE 1b DONE — `_warmGenres` (0.9.134).** Chained LAST in `warmCache` (after playlists, follow and
  trending): it's the cheapest stage and the least urgent, so it queues behind the streaming resolves
  rather than competing with them. Warms **For You first, then All Releases, strictly chained** so the
  two never fan out together. Filters each feed through `_filterForYou`/`_filterAll` first — no point
  warming genres for releases the user's own type/artwork/VA settings would hide. All Releases needs no
  account so it's warmed for everyone; For You is skipped without username+token.
  `_withGenres` gained an optional `$max` (default `GENRE_FETCH_MAX`=150 for a render);
  the warm passes **`GENRE_WARM_MAX`=600** (~12 bulk requests). Entries live 90 days, so a steady-state
  tick only fetches what's newly released. Reuses the same batched idle-tick `_withGenres`, so the warm
  is no more able to hold the event loop than a render is.
  - **Why it matters beyond convenience:** without it the first open of a week renders before the fill
    lands and labels only show on the second visit. It's also the prerequisite that makes the phase-3
    Last.fm tier affordable — that one is per-artist, not bulk.
  - Test note: `t_warm` must `require Plugins::…::Plugin` — `Browse::_dbg` calls `Plugin::dbg` directly
    and Browse never requires it (the real plugin loads it at init), so a suite that reaches a `_dbg`
    call dies without the stub.

- **List label is now `Family (sub, genres)` (0.9.133).** Spec: *"we have the group shown as it is and
  next to it in brackets the sub genres if we have them; sorting is by the main genre as planned."*
  `_familyFor` returns `($family, @subs)`; `_buildReleaseItem` renders
  `Album · Funk (funk rock, funk soul)`. `GENRE_SUBS_MAX`=2. Sorting (phase 4) keys on the family only,
  so brackets are display-only.
- **TWO wrong cuts at "what goes in the brackets" — don't repeat either:**
  1. **Same-family only.** Emptied the brackets on the very release that prompted the feature:
     `funk rock`/`funk soul` roll up to **Rock**/**Soul** under the whole-word suffix rule, not Funk.
     The brackets mean "what else this release is tagged", NOT a claim of descent.
  2. **Must be a known genre (`_genreFamily($g)` true).** Dropped `funk soul`, which isn't in MB's
     vocabulary at all — it reached us as a free tag in the feed's `release_tags`.
  The correct test is **"not a MODIFIER"**: unknown genre = still worth showing; known modifier =
  never. That distinction is why `genre-families.txt` now ships modifiers explicitly as `name<TAB>-`
  instead of just omitting them, and why `Browse` keeps `%_GENRE_MODIFIER` separate from
  `%_GENRE_FAMILY` (`_genreModifier`). Regenerate with `tools/make_genre_families.py`.
- Verified across the real genre sets: `Funk (funk rock, funk soul)`, `Electronic (downtempo,
  chillwave)`, `Hip Hop (lo-fi hip hop, boom bap)`, `Electronic (jazz, experimental)`, plain `Rock`
  (genre only restates the family → no brackets), `Rock (alternative rock)`, `yakousei` (nothing
  rolls up → strongest genre, no brackets).

- **Inline `release_tags` now go through the rollup too (0.9.132).** Field report: *André Cymone – "The
  Resurrection of Funk"* rendered `Album · funk, funk rock, funk soul` instead of `Album · Funk`.
  `_buildReleaseItem` had TWO paths to a row label — `_familyFor` (rolled up) and a separate
  `@tags = _releaseTags($rel) unless @tags` fallback that joined up to 3 RAW tags. The fallback was the
  one path bypassing the rollup. Fixed by giving `_familyFor` ownership of **every** source
  (`push @g, _releaseTags($rel) unless @g`) and reducing the caller to a single scalar
  `my ($family) = _familyFor(...)`. **RULE: a list row's genre label has exactly ONE producer —
  `_familyFor`. Never join a genre source onto `line2` directly.**
  - Verified live for that release: LB returns **no tags at all** for its release group AND its artist,
    so the inline `release_tags` are a genuinely INDEPENDENT source, not a duplicate of the `tag` block
    — worth keeping as the last tier, not deleting.
  - **Known gap (not fixed):** `_releaseDetail`'s Genres line comes from `_genresFor`, which is empty
    for exactly these releases, so their sub-genres appear on the detail page's separate **Tags:** line
    (`_albumRows` → `_releaseTags`) rather than under Genres. Visible, but inconsistent — fold inline
    tags into the detail Genres line as a fallback in a later pass.

- **PHASE 2 DONE — genre rollup + the list/detail split (0.9.131).** Spec from Simon: *"downtempo rolls
  into electronic. On front page we keep it to top levels where possible and when we drill in give more
  of the sub genre details."*
  - **`tools/make_genre_families.py` → `ListenBrainzFreshReleases/genre-families.txt`** (857 lines,
    `genre<TAB>Family`, 21 families). Pulls MB's whole `genre/all` vocabulary (2177), assigns a family
    by whole-word suffix/prefix rule, then a curated OVERRIDES table for names that are a genre in their
    own right (boom bap, chillwave, shoegaze…). **Rerun the script to regenerate; never hand-edit the
    .txt.** Coverage on real feed occurrences: **88% mapped, 10% modifiers, 2% unmapped tail.**
  - **MODIFIERS get NO family ON PURPOSE.** "instrumental" was the 5th most common genre in the live
    sample; "lo-fi" the 2nd. They describe a treatment, not a family, so they're omitted from the table
    and `_familyFor` falls through to the next genre — "instrumental, lo-fi hip hop" → **Hip Hop**.
  - **Perl side:** `_loadGenreFamilies` (lazy, one read, path derived from `%INC` so manual and repo
    installs both work; a missing file is NOT an error — genres just show unrolled), `_genreKey`
    (same normalisation as the generator — flattens hyphens so `synth-pop` finds `synth pop`),
    `_genreFamily`, `_familyFor` (first genre that resolves to a family; else the strongest genre as-is).
  - **`_buildReleaseItem` shows `_familyFor` (ONE label); `_releaseDetail` shows the full `_genresFor`
    list.** That's the whole list/detail split — don't "fix" a list row to show sub-genres.
  - **GENERATOR GOTCHA (cost a regenerate):** OVERRIDES/MODIFIERS are written the way humans spell
    genres ("lo-fi", "post-rock") but every lookup goes through `norm()`, which flattens hyphens — so
    the hyphenated keys silently never matched. The tables are now normalised once at import. Symptom
    was "lo-fi" (52 occurrences) appearing in the UNMAPPED report despite being listed as a MODIFIER.
- **Detail page consolidated onto the shared bulk data (0.9.131).** `_releaseDetail` no longer calls
  `API::getReleaseGroupGenres` (~5% coverage) and no longer falls through to raw, ungated Last.fm for
  the other 95% — a row reading "post-punk" could open a page reading "japanese, 90s, seen live". It now
  calls `_withGenres([$rel])`, normally a pure cache hit filled by the list that got you there, so the
  page makes **one MB call FEWER** than before and the two views cannot disagree.
  **`API::getReleaseGroupGenres` now has NO callers** — dead code, left in place for now; remove it in
  the next cleanup pass along with its comment references.

- **Genre fill moved OFF the render path (0.9.130) — event-loop safety.** `_withGenres` collected mbids
  then called `getReleaseGroupMetadata` INLINE in the browse callback. That sub opens with a
  SYNCHRONOUS cache scan (one `$cache->get` per mbid) and writes one `$cache->set` per fetched entry —
  up to `GENRE_FETCH_MAX`(150) blocking SQLite round-trips per render, on EVERY feed render including
  every sort/view tap, and all of them misses right after the `:2:` prefix bump. Same hazard class that
  got Bandcamp pulled from the auto-search and moved the library probe behind an idle tick in 0.9.48.
  Now the collect loop touches no cache, then the work is handed to `Slim::Utils::Timers` and run
  `GENRE_BATCH`(50) at a time with a **yield between batches** — the yield is required, not cosmetic:
  a fully-cached batch calls back synchronously, so without it the whole fill would still collapse into
  one uninterrupted block. `$step` is passed to ITSELF as a timer arg, never captured in its own
  closure — that's the uncollectable reference cycle fixed in `getArtistMbidByName` in 0.9.95.
  Verified: zero cache reads before the first yield, callback not fired on the render path, 120 mbids =
  3 batches, bound still holds at 150, and no timer scheduled at all when there's nothing to fill.
  **Triggered by a field report** ("changing sort stopped playback") whose log timeline actually showed
  a server restart from the install, with the player's Tidal stream failing to reopen 4s later and the
  first browse 23s after that — i.e. not proven to be this code, but the hazard was real and latent.

## GENRES — measured coverage & the plan (0.9.129 = phase 1 of 4)

**Measured 2026-07-26** over 400 releases of the LIVE All Releases feed, with the plugin's own
type/artwork filters applied. Don't re-derive these:

| source | coverage |
|---|---|
| MB **release-group** genres (`getReleaseGroupGenres`, detail page) | **5%** |
| inline `release_tags` in the feed payload | 8% |
| MB **artist** genres | **47%** |
| release-group ∪ artist | **49%** |
| + Last.fm artist tags on the remainder (44% of the 51% miss) | **~71%** |

- **`inc=tag` is THE source.** `/1/metadata/release_group/` accepts `inc=release_group tag` and returns
  BOTH `tag.release_group[]` and `tag.artist[]`. Each tag has a **`genre_mbid` iff it is a real MB
  genre** — that flag is the quality gate (drops "seen live"/country/mood noise). Bulk, ≤50 per request.
- **DO NOT add a per-artist MB lookup.** Tested `artist/<mbid>?inc=genres` against the mirror on the 206
  releases LB had no genre for: **0/80**. LB's artist tag block IS that same MB data. A fan-out would be
  pure cost for zero gain.
- **MB has NO genre hierarchy.** `genre/<mbid>?inc=genre-rels` → *Not Found*; genre search → *"hasn't
  been implemented"*. `genre/all` DOES return the full curated vocabulary (**2177** names) — that's the
  gate list for Last.fm and the seed for the rollup table. Rollup must be a table WE ship.
- **Rollup is tractable:** a plain suffix/prefix rule (`… hip hop` → Hip Hop) covers **52% of real
  occurrences**; only 244 distinct genres appeared across 400 releases, top 100 = 84% of occurrences,
  top 200 = 96%. So rule + ~150–200 curated overrides ≈ complete.
- **Streaming-service genre is a DETAIL-PAGE enricher only, never a list source.** List-level would be
  ~3 searches × N releases (≈860 requests for one week, ≈10,500 for the feed) vs 1-per-50 here; and its
  coverage correlates with MB's (obscure releases are missing from both). Deezer's album *search*
  response already carries `genre_id` (free, but only **23** broad buckets); Qobuz's genre is
  **hierarchical** (`genre.path`) and is the one genuinely useful extra — harvest opportunistically on
  albums the user opens. Tidal album objects carry no genre.

**Phase 1 (0.9.129) — DONE.** `API::_genreTags` (the `genre_mbid` gate) + `genres`/`agenres` on every
`getReleaseGroupMetadata` entry; `RGMETA_PFX` `:1:`→`:2:`. `Browse::_withGenres` (bounded
`GENRE_FETCH_MAX`=150, cache-first so a warm feed makes NO request) + `Browse::_genresFor` (album's own
genres preferred; artist genres are only a PROXY fallback — a jazz artist's ambient side project would
otherwise inherit "jazz"). `_buildReleaseItem` takes an optional `$meta` and shows genres on line2,
falling back to `_releaseTags`. Threaded through `_buildItems`/`_buildWeekly`. **The All Releases week
coderef now pages on RELEASES, not finished tiles** (`_pageSection` only slices/counts, so it's
equivalent) so the genre fill covers only the visible 30.
- **Ordering lesson:** `_genreTags` sorts by `count` DESC **only**, no name tie-break. Most real tags
  tie at count 1, so an alphabetical tie-break silently becomes "show the alphabetically first genres" —
  it labelled a drum-and-bass artist "ambient, breakcore". Perl's stable sort keeps LB's own order on
  ties, which tracks the primary genre. Caught by a test against a real captured response.

**Still outstanding on phase 1's cost story:** the detail page still makes its own per-album
`getReleaseGroupGenres` MB call ([Browse.pm](ListenBrainzFreshReleases/Browse.pm) `_releaseDetail`) — it
should read the bulk data instead, making that path one call cheaper; and `warmCache` should pre-fill
the feed's genre cache so a browse is always a pure cache hit.
**Phases 2–4 not started:** rollup table (`tools/` generator + shipped data file), Last.fm gated by the
MB vocabulary, and "Group by genre" as a fourth mode on the per-view sort toggle.

- **Family selector collapsed back to ONE cycling row — `_viewToggle` (0.9.128).** Replaces
  `_viewRows` (the 0.9.125–0.9.127 two-row radio pair). Same signature
  (`$client,$pref,$mode,$hasAlbums,$hasSingles`), still returns a LIST so the call sites spread it,
  still EMPTY when only one family is available. Label = `PLUGIN_LBF_SHOWING`
  ("Showing %s (tap for %s)") built from `PLUGIN_LBF_VIEW_ALBUMS`/`_SINGLES`, mirroring
  `_sortToggle`'s state+hint wording. **The icon reflects the CURRENT family** —
  `lbf-view-albums_MTL_icon_album.png` / `lbf-view-singles_MTL_icon_music_note.png` (Material renders
  its own themed `album`/`music_note` font-icons) — which is what carries the at-a-glance state the
  radio marks used to. Retired `VIEW_ON`/`VIEW_OFF` + the two `lbf-radio-*` PNGs. Flips from the LIVE
  pref, not the render-time `$mode` (the `_sortToggle` rule).
- **WHY NOT TWO BUTTONS SIDE BY SIDE — asked twice now, don't re-derive.** A plugin feed has NO way to
  lay rows out horizontally in Material. Re-verified 2026-07-26 against the server's own
  `material-deferred.min.js`: the header toolbar's `currentActions` is filled by `browseActions(...)`
  from native-library `stdItem` shapes or `getCustomActions(...)` keyed on a media item's
  `favorites_url`; rows flagged `isListItemInMenu` are pushed to `d.actionItems` (the ⋮ overflow) and
  that flag is only set on those same native-menu paths. A plain OPML `type=>'link'` row always lands
  in `d.items` as a full-width `v-list-tile`. `"choice"` in the bundle is `lms-choice-dialog`, not a
  browse item type. Grid view is the only horizontal layout and applies to the WHOLE list. **One row is
  the floor** — that's why this is a cycling toggle, not buttons.
- Render-only; **no cache bumps**, matcher untouched. `perl -c` clean; 40 behavioural assertions
  (label text from the REAL strings.txt in both states, correct icon per state, flip both directions,
  flip-from-live-pref, hidden on each single-family case, exactly one row when both, and the in-situ
  All Releases week Options block = header / Showing / Sorted by / Refresh).

- **All Releases Refresh restored to the week drill (0.9.127).** `_refreshItem($c,'all')` is now the
  third Options row in the per-week coderef in `_buildAllLanding`, after `_viewRows` + `_sortToggle`.
  **The regression:** `_refreshItem($client,'all')` lives only in `fetchAll`, and since the top-level
  menu began inlining the weeks (0.9.99–0.9.119) `fetchAll` is reached ONLY via the `TOPLEVEL_ALL_WAIT`
  watchdog / `onError` fallback tile — so in normal browsing the All Releases feed had **no reachable
  Refresh at all**. Diagnosed while chasing a "feed is stuck / showing very little" report that turned
  out to be `all_past=0` (see below), but the missing row was real and independent. `topLevel`'s "each
  week drill has its own controls" comment was true of sort, not refresh — corrected.
- **`_effectiveView` now PERSISTS its clamp (0.9.127).** It clamped the applied view to an available
  family but left the pref alone. Since `_viewRows` HIDES the selector when only one family is ticked,
  a stored value the section can't show is unreachable from the UI — it sits invisible and then bites
  the moment the user ticks the other family in Settings (verified live: `foryou_view` was stored
  `singles_eps` on a For You section with Single/EP unticked). `$prefs->set` is guarded on an actual
  change, so it's a no-op in the normal case.
- **`_stashSummary('user', …)` moved ABOVE `_viewFilter` (0.9.127).** 0.9.126 stashed the summary from
  the view-filtered list, so the New Releases for You tile's "*span · N releases*" described the active
  lens and changed when the user switched families. The tile describes the section; the list follows
  the lens. (All Releases was already correct — `fetchAll`/`homeAllReleases`/`topLevel` stash pre-filter,
  since its filter runs inside the per-week coderef.)
- Render/pref-state only — **no API change, no cache-version bumps** (`lbf:summary:*` is rewritten on
  every fetch at a 25h TTL, so it self-heals immediately); matcher untouched (`matcher_sync_check` N/A).
  `perl -c` clean; 36 behavioural assertions against the real subs (clamp persistence both directions,
  nothing-ticked case, `_viewFilter` partition, week-drill row order + Refresh wiring + `which=>'all'`,
  selector hidden on default prefs with Refresh still present, summary unaffected by the lens).

- **FIELD DIAGNOSIS (0.9.127 session) — "All Releases is stuck / showing very little" was `all_past=0`,
  not a cache.** Live prefs read over JSON-RPC showed `all_past=0`/`all_future=1`, and the log showed
  `Fetching all releases: …past=false&future=true…` → **342 releases** where `past=true` returns 4502.
  Root cause is the 0.9.122 `@CHECKBOX_PREFS` coercion finally making a long-unticked box bite (it had
  been overridden by the `// 1` default). **The tell:** with `past=false` the feed only ever holds
  today→+21d, so the *This Week* bucket **decays through the week** — the full week on Monday (90+
  albums), only that day's releases by Sunday (7) — which reads exactly like a cache that stopped
  updating. `lbf:feed:all:` keys on `sort|past|future|days|TODAY`, so it cannot serve stale data; check
  the pref and the fetch URL first. See [[material-bare-checkbox-invisible]].

- **Selector shown only when both families are available (0.9.126).** `_viewRows` now returns an
  EMPTY list unless the section has BOTH album-family AND single/EP types ticked — so the default
  (Album + Compilation) shows NO selector, and a Singles & EPs row never appears for a section that
  can't populate it. Backed by **`_familyAvail($prefix)`** (→ `($hasAlbums,$hasSingles)` from
  `_allowedTypes`; empty allowed-set = all types = both true) and **`_effectiveView($prefix,$pref)`**,
  which also CLAMPS the applied view to an available family — fixing a latent bug where a section with
  only Single/EP ticked would render EMPTY under the default `albums` view (and vice versa). Both call
  sites (For You top of `fetchForYou`; All Releases inside the per-week coderef) now take
  `($view,$hasAlb,$hasSing) = _effectiveView(...)` and pass the flags to `_viewRows`. Verified across
  all cases (default→no selector, both→both rows, single-only→clamped+no selector, all→both rows).

- **In-view "Albums / Singles & EPs" family selector (0.9.124 cycling toggle → 0.9.125 two-row).**
  New Releases for You and each All Releases week show a release-family selector in their Options
  section (next to the sort toggle), backed by durable prefs **`foryou_view`** / **`all_view`**
  (default `'albums'`; selector-only, NOT on the settings page — like `foryou_sort`/`all_sort`).
  **`_viewFilter`** partitions by PRIMARY type — `singles_eps` keeps primary Single/EP, `albums`
  keeps everything else (Album, Broadcast, Other + the secondary-typed album variants
  Compilation/Soundtrack/Live/…). Applied **AFTER** `_filterSection`, so it only narrows WITHIN the
  user's ticked type checkboxes (nothing ticked is lost — non-single/EP types all fall into the
  `albums` bucket); to see anything in the Singles & EPs view the section must have Single/EP ticked
  in Settings.
  - **UI = two rows, not header lozenges (0.9.125).** Simon asked for two Material "lozenge"
    buttons (Albums / Singles) like the Play/Append pills on a drilled-in album. **Not possible from
    a plugin feed** — verified against the server's `material-deferred.min.js`: the header toolbar
    (`currentActions`) is filled only from items flagged `isListItemInMenu`, and that flag is set
    ONLY for native-library menu shapes (`metadata`/`STD_ITEM_*`, or a level whose `items[0].menu[0]
    ==PLAY_ACTION` with trailing `itemNoAction` rows) or `getCustomActions(...favorites_url)`; a plain
    OPML `type=>'link'` row always lands in `d.items` (the list), never in `currentActions`. So the
    closest plugin-owned "two buttons" is **`_viewRows`** — two always-visible rows (**Albums** /
    **Singles & EPs**) with the active one carrying a filled radio icon (`VIEW_ON`) and the other an
    empty one (`VIEW_OFF`); tapping a row sets the pref and refreshes in place. Replaced the 0.9.124
    single cycling `_viewToggle` row.
  - **Wiring.** For You: `_viewFilter` in the `$render` sub after `_filterForYou`; `_viewRows`
    spread into `@opt`. All Releases: `_viewFilter` + `_viewRows` INSIDE the per-week coderef
    (`_buildAllLanding`), re-read from the pref each walk so `nextWindow=>'refresh'` re-filters —
    same mechanism as `all_sort`; the shared coderef also serves the top-level inlined weeks. Home
    shelves (`homeForYou`/`homeAllReleases`) deliberately left UNFILTERED (no selector there,
    glanceable carousel). Strings `PLUGIN_LBF_VIEW_ALBUMS`/`_SINGLES`; icons
    `lbf-radio-on_MTL_icon_radio_button_checked.png` / `lbf-radio-off_MTL_icon_radio_button_unchecked.png`
    (Material renders its own radio font-icons; PNGs are placeholder copies of the sort icon).
  - Render-only — **no API calls, no cache-version bumps, no matcher change** (`matcher_sync_check`
    N/A). `perl -c` clean (Browse via scratchpad stublib; Plugin's only error is the LMS
    `main::WEBUI` constant, past the edit).

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
- **Bio display — KEY Material fact, and the 0.9.150 correction.** A `type=>'text'` row renders its
  `name` IN FULL; Material has NO auto-collapse / "more" for plain text. So the preview must be
  **pre-trimmed** (`BIO_PREVIEW`=150 chars) — that part still stands, and don't "fix" it by putting
  the whole bio in one text row, which is the bug the preview replaced.
  - **What was WRONG here until 0.9.150:** this section used to claim "compact preview + expand MUST
    be a drill-in". It doesn't. **`nextWindow => 'refresh'` + an EMPTY response re-renders the
    current level**, which is all an in-place expand needs — the same mechanism the All Releases
    paging rows have used since 0.9.86, and which Discography uses for both its bio and its review.
    The drill-in was a limitation of the first implementation, not of Material.
  - **Now:** collapsed = preview + **Read more**; expanded = the full bio, one text row per
    PARAGRAPH (split on blank lines, single newlines collapsed so rows wrap), + **Show less**. Both
    toggles are `_bioToggleRow`, a boolean sibling of `_pageRow` sharing the same `%pageState` store
    (key `bio:<lc artist>`; expanding writes the flag, collapsing DELETES it so nothing is left
    behind). Reuses `PLUGIN_LBF_READ_MORE` / `PLUGIN_LBF_SHOW_LESS` and the `PAGE_MORE`/`PAGE_LESS`
    unfold icons — no new strings or assets.
  - **ROW-COUNT SAFETY (read before reordering the detail page).** Expanding changes the number of
    rows, which shifts every item_id below it. This is only safe because `_releaseDetail` emits the
    **Streaming section FIRST** — so the playable rows keep their ids and deep play is unaffected
    (the 0.6.11 quantity/id rule). Everything the expand shifts is non-playable: the rest of the
    artist block, album metadata, genres, the tracklist text rows and the MB weblink.
  - The flag is keyed on the **ARTIST**, not the release (matching Discography), so another release
    by the same artist opens with the bio already expanded. Deliberate. Per-player, in-memory, lost
    on restart. Note `%pageState` never clears — a pre-existing deferred cleanup item that this
    feature adds a few more keys to.
  - Tested by **`tools/t_bioreveal.pl`** (29 assertions against the real subs; anti-tested three
    ways — non-empty toggle payload, collapse-without-delete, expanded branch disabled).

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
- **Release-family view is per-view too (0.9.124–0.9.128).** Each list has an **Albums / Singles & EPs toggle** — ONE cycling row, "Showing Albums (tap for Singles & EPs)", icon reflecting the current family (`_viewToggle`) — in its Options section (next to Sorted-by), backed by a durable pref set only via the in-view toggle (not on the settings page — like `foryou_sort`):
  - **For You** → `foryou_view`; **All Releases** per-week views → shared `all_view`. Both default `albums`.
  - `_viewFilter` partitions by PRIMARY type: `singles_eps` = primary Single/EP; `albums` = everything else. Applied AFTER `_filterSection`, so it NARROWS within the ticked type checkboxes. Nothing ticked is lost (non-single/EP types fall into `albums`). Home shelves are deliberately unfiltered.
  - **The toggle row appears only when the section has BOTH families ticked** (`_familyAvail`/`_effectiveView`, 0.9.126) — default Album+Compilation shows no toggle; a single-only section is clamped so it never renders empty, and since 0.9.127 the clamp is PERSISTED so a hidden pref can't lie in wait.
  - **One cycling row, not two rows and not header lozenges:** Material gives plugin feeds no way to lay rows out horizontally OR to add pill buttons to the header toolbar (`currentActions`/`isListItemInMenu` is native-library-menu or favorites_url-custom-action only — re-verified in `material-deferred.min.js` 2026-07-26). Two stacked rows cost a line of screen, so 0.9.128 collapsed them into one. See the Current Version note — **don't re-derive this**.
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
│   │   │   ├── Showing <family> (tap for <other>) ← ONE cycling row, icon = current family (foryou_view pref, default albums)
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
│       ├── W/C <date>  [This/Last/Earlier badge]  ← that week's releases (Options: Showing-family toggle (all_view) + Sorted-by toggle (all_sort), both shared+durable, + Refresh (0.9.127); first 30, then "Show more" / "Show all")
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

> ### ⏸ SYNC IS ON HOLD (2026-07-29) — `matcher_sync_check.py` exits 1 BY DESIGN
>
> **Discography's matcher is mid-rework and very much WIP, so nothing is being pushed across
> the fleet until DSC settles.** Right now the check reports drift on `_norm`: DSC carries an
> apostrophe / `'n'` fold (`rock 'n' roll` → `rock n roll`, and a bare apostrophe strip) that
> LBF, PFR and Search Hub do not.
>
> **This is expected. Do NOT "fix" it by porting DSC's `_norm` outward**, and do not treat a
> non-zero exit as a blocker on unrelated work — it is currently the normal state. What the
> rule below still means while the hold is on:
> - Do not make the drift WORSE. A new matching change of your own still has to land in every
>   repo that carries the affected sub, in the same session, exactly as written below.
> - When DSC lands, the apostrophe rule (and anything else DSC has grown meanwhile) gets
>   synced outward in ONE dedicated session, and the check must exit 0 again before that
>   session is called done.
> - The separate, older `_norm` "!"-fold gap (a decorative "!" makes *Panic! At The Disco* /
>   *Godspeed You!* unfindable when typed without it — Search Hub patched at its own gate in
>   0.2.1) is ALSO waiting on that session. Don't do it piecemeal.


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
- **0.9.150** — **the artist bio expands IN PLACE; the "Read more" drill-in is gone — and the
  CLAUDE.md rule that said it had to be a drill-in was simply wrong.** Tapping Read more opened a
  separate view containing only the bio, which you then had to back out of to reach the tracklist or
  the streaming matches. Discography has done this inline for both its bio and its review all along
  — and its own comment credits "LBF's full-bio recipe", so this is that recipe coming home improved.
  - **The mechanism was already in this file.** `nextWindow => 'refresh'` plus an **EMPTY** response
    (the only shape `browseHandleNextWindow` acts on — 0.9.137) pops the toggle's own window and
    re-renders the level beneath it. The All Releases paging rows have used it since 0.9.86. So
    **no Material limitation ever required the drill-in**; the old "MUST be a drill-in" note has been
    corrected in place rather than deleted, since it would otherwise keep being believed.
  - `_bioToggleRow` is a BOOLEAN sibling of `_pageRow` sharing `%pageState` — one store per player
    for transient view state. Key `bio:<lc artist>`; expand writes the flag, collapse **deletes** it,
    so a never-expanded bio leaves no residue (the `_pageRow` convention).
  - Expanded text is one row per **PARAGRAPH** (split on blank lines, empty chunks dropped, single
    newlines collapsed so Material wraps the row instead of honouring the source's hard breaks) —
    the old drill-in did none of that and could emit blank rows.
  - **Keyed on the ARTIST, not the release** (matching Discography), so another release by the same
    artist opens already expanded. Deliberate.
  - **ROW-COUNT SAFETY:** expanding shifts item_ids, and that is only safe because `_releaseDetail`
    emits the **Streaming section first** — the playable rows keep their ids (0.6.11). Commented at
    the call site; revisit if the sections are ever reordered.
  - **No new strings, no new assets, NO CACHE BUMPS** — pure view state, nothing cached changed shape.
  - `tools/t_bioreveal.pl`: 29 assertions against the real `_artistRows`/`_bioToggleRow` lifted from
    source, with the real `strings.txt` values. **Anti-tested three ways** (`LBF_BROWSE=` at a mutated
    copy): toggle returning a non-empty payload → 2 fail, collapse storing 0 instead of deleting →
    1 fail, expanded branch disabled → multiple fail.
- **0.9.149** — **a transient LB blip pinned "No trending data yet" on Trending Albums for a WEEK
  (This Month) or a MONTH (This Year) — the empty-aggregate cache-poison class, one the rest of this
  file already gets right.** Field report: both album lists empty, "all ok until recently".
  **Diagnosed without touching the box:** replayed the plugin's own pipeline against the live API
  (following → 13 users, all with listens that day, `stats/user/<u>/release-groups` 200 for every one
  of them, **650 rows / 558 distinct albums** for `this_month`, same for `this_year`), then opened
  This Month over the CLI (`listenbrainzfreshreleases items 0 10 item_id:5`) and read `log.txt`: the
  message came back with **zero new log lines**. No build ran → `_buildAlbumsData` was serving a
  cache hit, and **`$cache->get` is truthy for an empty arrayref**, which is the whole bug.
  - **`_buildAlbumsData`'s gate settled an EMPTY aggregate with `$short = 0`** — full
    `TREND_ALBUMS_MONTH_TTL`/`_YEAR_TTL`. Every other inconclusive settle in that same sub already
    uses `PLAYLIST_INCONCLUSIVE_TTL` (no client/services, gate keeps zero, watchdog truncation —
    that last one was itself a 0.9.117 review fix); the empty branch was the one that slipped
    through. Now `$settle->($data, 1)`. **The rule this belongs to: an empty result is never a fact.
    It is the shape a transient failure takes** — and the further up the pipeline the failure
    happens, the more it looks like a legitimate "nothing to show".
  - **`lbf:trending:albums:6:`→`:7:`, NOT a shape change** — purely to abandon the empties already
    pinned on users' servers. Worth knowing: the key carries the calendar period, so This Month
    would have self-healed at the month rollover and only **This Year was stuck until January**.
  - **The empty view now renders the Refresh row** (`_refreshItem('trending_albums', $range)`; no
    sort toggle — nothing to sort). It previously emitted the message ALONE, which made a bad build
    a **dead end**: the aggregate cache is the only way back and the user had no way to drop it.
    **Any "nothing here" view that is served from a cache must carry its own Refresh** — check this
    when adding one.
  - **`tools/t_trending_empty.pl`** (18 assertions, real sub bodies via the `grab` trick): empty →
    1h on BOTH ranges, healthy → still 7d/30d (the fix must not become a blanket downgrade),
    gate-keeps-zero unchanged, the empty view's Refresh row present AND its tap dropping *that*
    range's key only, and the `:7:` bump. `LBF_BROWSE=` points it at a mutated copy —
    anti-tested against a pre-fix Browse.pm: **7 failures**.
  - **Test-writing trap worth remembering, since it bit this suite:** `ok($k =~ /…/, "msg")` — a
    bare `m//` or `grep` in a LIST-context argument returns the match list, so on failure the args
    shift, the message becomes the condition, and the assertion PASSES on any truthy label. Three
    assertions here did exactly that and the anti-test run is what exposed them (`5. PASS` with a
    blank label against a `:6:` key). Wrap every match/grep in `scalar()`.
- **0.9.148** — **…and that strip belongs to BANDCAMP ALONE — correcting 0.9.147, which applied it
  to all four services.** Qobuz/Tidal/Deezer hand back a bare `title` in the raw album hash 0.9.146
  moved to; only Bandcamp's search PASSTHROUGH joins the artist on. On the other three the strip had
  no wart to remove and could therefore only misfire: a catalogue title that genuinely ends in its
  own artist — `"Goldberg Variations - Glenn Gould"` by Glenn Gould — clears BOTH guards (the
  separator is space-padded, the discarded side `_norm`-EQUALS the artist) and reaches LL as
  `"Goldberg Variations"`, a name the service never reports at playback. **That is the identical
  failure mode 0.9.144–0.9.147 exist to fix, arrived at from the opposite direction**, and it is the
  general lesson: this handshake's failures are silent (the album plays fine, it just never reaches
  *Played*), so a defensive transform applied where the defect isn't evidenced is not free — it is a
  new instance of the same bug. `_searchBandcamp` is now the sub's only caller; the other three
  assign `$album->{title}` verbatim.
  **`_streamKey` :26→:27** — a FIFTH bump, same rule as ever: `:26:` can hold a Q/T/D title truncated
  at a dash the service really uses.
  **`_bcMatchKey` STILL `:6:`** (a pin is often an album's only playable entry) — but its comment now
  states the residual cost correctly and, importantly, that **the usual remedy does not apply**:
  `_bcMatchItems` replays the cached `favorites_url` verbatim, so removing and re-adding in LL just
  re-sends the stale favurl. Only **Re-search Bandcamp** rewrites a pin. Same wording in the CHANGELOG.
  **`tools/t_svctitle.pl` grown to 22 checks**: `%FOLD` is now LIFTED from `Browse.pm` (it was
  hand-copied, so a `%FOLD` edit drifted without failing), the Goldberg case is kept as a live
  demonstration that the guards CANNOT save it, and the four search subs are pinned at source level —
  Bandcamp calls the strip, the other three must not and must assign the raw title. Anti-tested:
  restoring the 0.9.147 call sites fails 6.
- **0.9.147** — **…and the raw title needs the ARTIST AFFIX stripped, because Bandcamp's carries one
  too (`_stripArtistAffix`) — but it applied the strip to ALL FOUR services, which 0.9.148 narrows to
  Bandcamp. Read this entry with that one.** 0.9.146 moved to the raw album hash and fixed
  Qobuz/Tidal/Deezer, but
  Bandcamp's search PASSTHROUGH title is itself `"<album> - <artist>"` — confirmed live: an add stored
  `Radio: Journey Beat (Original Music from Big Walk) - aksfx`, and Simon confirmed Bandcamp's Now
  Playing reports artist `aksfx` with album `Radio: Journey Beat (Original Music from Big Walk)`, so
  the stored name could never match at playback.
  **Why no field is trustworthy here, which is the thing to remember:** `_albumMatches` accepts a
  candidate that STARTS WITH our album, so a trailing `" - artist"` sails through matching untouched.
  Every field in the chain therefore looks fine to the matcher while being wrong as a title. There is
  no field to switch to — the affix has to be removed explicitly.
  **`_stripArtistAffix` is deliberately conservative**, following LL's own 0.1.72 hardening: the
  separator must be SPACE-PADDED (so `Jay-Z` is untouched), the discarded side must EQUAL the artist
  under `_norm` (not contain or start with it, so `Album - aksfx remixes` is left alone), and anything
  failing either test is returned VERBATIM. Prefix is tested at the FIRST separator, suffix at the
  LAST, so a title containing its own `" - "` still resolves. Compared against the SERVICE's artist
  spelling (`$pt->{artist}`; also `$candArtist` until 0.9.148 narrowed the call to Bandcamp) — the
  value that service would actually have joined. **Conservative is not the same as safe**: the guards
  stop a wrong strip only where the artist ISN'T what got joined on, and 0.9.148 is what happens when
  it is.
  **LBF-ONLY, outside the shared matcher.** Do not confuse it with `_stripArtistPrefix`, which IS a
  fleet-synced shared-engine sub; this one doesn't trip `matcher_sync_check`.
  **`_streamKey` :25→:26** — a FOURTH bump for a fourth wrong `&al=` value.
  **New suite `tools/t_svctitle.pl`**, using the real sub and the real `_norm`/`%FOLD` chain, 14
  checks split into "must strip" and **"must not strip"** — the second half is the point, since a
  wrong strip corrupts the title LL matches and dedupes on, which is worse than the wart it removes.
  Anti-tested: neutering the strip fails 7.
- **0.9.146** — **`&al=` takes the service's RAW ALBUM TITLE (`_svctitle`), not its rendered row
  label — correcting 0.9.145, which also shipped. Completed by 0.9.147, which strips the artist affix
  Bandcamp's raw title turned out to carry.** Reported by Simon from two live rows: rec 207
  (Qobuz) stored `aksfx - Radio: Fourth Space (…)`, rec 208 (Bandcamp) stored
  `Radio: Journey Beat (…) - aksfx`. **Artist-first on one service, artist-last on the other** — the
  unmistakable signature of a DISPLAY LABEL rather than a title, which is exactly what
  `$it->{name}`/`{line1}` are: each streaming plugin's own renderer composes them, and they differ per
  plugin. A label can never match at playback, and it poisons LL's `artist|album|year` dedupe key with
  the artist on both ends. Worse than 0.9.144 in one respect: MB's name was at least a real title.
  **Fix:** stash the title from the RAW album hash at match time — `$item->{_svctitle} =
  $album->{title}` for Qobuz/Tidal/Deezer, `$it->{_svctitle} = $pt->{title}` for Bandcamp (which also
  serves the manual picker, since it calls this sub through the adapter's `run`). That is the SAME
  field `_albumMatches` already validates against, so it is the album title alone by construction —
  the artist is a separate argument there. **No fallback at the call site:** if a service ever yields
  no title we send nothing and LL reads Material's label, which is what happened before 0.9.144 and is
  merely imperfect, whereas either wrong string is silently destructive.
  **`_streamKey` :24→:25.** Third consecutive bump of this key for a different wrong `&al=` value.
  **THE RULE: bump it on ANY change to what `&al=` carries, even when the field keeps its shape** —
  one re-resolve versus a week of silent misses aged out of a 7d TTL.
  **THE REAL LESSON, and it is a method failure, not a typo.** Three builds in one session each put a
  different wrong string in this one field. The first two passed every behavioural check in
  `t_ll_handshake.pl` because they all SUPPLY the album themselves; section 4 (added in 0.9.145) then
  caught only the MB-name spelling, because I wrote the assertion to accept `{name}` — encoding my own
  assumption that the rendered node held a title. **I never verified what `name` actually contains for
  any service; Simon's two live rows did.** The assertion now accepts ONLY `_svctitle` and names all
  three known-wrong forms, anti-tested against each. When a field feeds another plugin's matching,
  read a REAL value out of a REAL row before believing what it holds.
- **0.9.145** — **`&al=` carries the MATCHED SERVICE'S naming, not MusicBrainz's — correcting 0.9.144,
  which SHIPPED and was installed. SUPERSEDED BY 0.9.146 — this build read the service's rendered ROW
  LABEL, which bakes the artist in; the principle below is right, the field it used was not.** Reported by Simon, from a real row: LB has aksfx
  `Radio: Fourth Space (Original Music from Big Walk)` where Qobuz has
  `…(Original Music from the Game "Big Walk")`, and the release never reached Played.
  **THE RULE: once a favurl exists the release has been RESOLVED to a specific service album, and from
  that point the SERVICE's spelling is the only one that works.** Two independent consumers demand it,
  both title-keyed: LL's Played auto-detection matches the PLAYING track's album title (reported by the
  service), and LL's `artist|album|year` dedupe key must agree with a direct add from that same
  service. MB and the services disagree constantly, and NOT only over edition qualifiers — see the
  aksfx case above. MB additionally keeps a release's distinguisher OUT of the title (all four American
  Football LPs are titled `American Football`, with `LP2`/`LP3` in `disambiguation`) where the services
  put it IN. Sending MB's name loses on both counts, **silently**: the album plays perfectly and just
  never leaves the list.
  **Why 0.9.144 got it wrong** — it reasoned that an "authoritative" catalogue title beat a renderer's
  display label. That mistakes WHICH QUESTION the param answers. It is not "what is this release
  really called", it is "what will the thing playing call itself".
  **Contrast PFR, which sends the same param for a different reason:** its rows read "Artist - Album",
  so its `&al=` undoes ITS OWN renderer's prefix. That is not licence to substitute a different naming
  authority. Do not "improve" this back to MB's name.
  **Changes:** both call sites now pass the service candidate's own title (`$it->{name} //
  $it->{line1}`); at the Bandcamp site deliberately NOT the `$name` local, whose `// $album` fallback
  would smuggle the MB name back in. **`_streamKey` :23→:24** — the field didn't change shape, only its
  value, and a `:23:` entry cached by the installed 0.9.144 would keep handing LL the MB name for the
  full 7d TTL.
  **THE TEST LESSON, and it is the same one as `&tc=` below.** `t_ll_handshake.pl` passed throughout
  0.9.144 because every case SUPPLIES the album itself — it proved the param is built and parsed
  correctly and could not say a word about WHICH NAME the plugin chooses. New **section 4** asserts on
  the CALL SITES in source (crude, but there is no return value to inspect); anti-tested by reverting a
  site to `$album`, which fails it. **A behavioural test of a handshake cannot check the choice of what
  goes into it — test the call site too.**
  **Rows added under 0.9.144 keep the wrong stored name**; only a remove + re-add fixes those.
- **0.9.144** — **`&al=` — an ALBUM TITLE joins the Listen Later handshake.** Material gives a plugin no
  structured album name for an online row: `$ALBUMNAME`/`$TITLE` is the row's DISPLAY LABEL verbatim,
  and these rows are labelled by each streaming plugin's own renderer, qualifier and all. So the album
  name reaching LL depended on skin plumbing. `_attachFavUrl` takes the name as a 7th arg
  (`uri_escape_utf8`, pushed next to `&a=`).
  **SHIPPED WITH THE WRONG NAME — see 0.9.145 above; it sent the MB/LB release name.** The reasoning
  below is kept for its method notes only; **where it describes sending the MB name it is describing
  the bug.** Both call sites pass it —
  the `_findPlayable` settle loop and the manual Bandcamp pin. Receiver has existed since **LL 0.1.71**
  (`Plugin.pm::_stripPrivateParams`; 0.1.72 hardened its migration, which is why the user-facing floor
  was quoted as 0.1.72), so older LLs simply ignore it. Idiom copied from **PFR**, which
  has sent the identical param since its own "Artist - Album" labels needed it.
  **REAL FLOOR IS LL 0.1.92 — see the Played trade-off below.**
  - **THE OTHER CONSEQUENCE, missed on the first pass and found by code review: this BREAKS Played
    on LL 0.1.72–0.1.91.** MB deliberately keeps a release's distinguisher OUTSIDE the title — all four
    American Football LPs are titled exactly `American Football`, with `LP2`/`LP3` in MB's
    `disambiguation` (verified against the MB API and Simon's mirror), while the service prints
    `American Football (LP2)`. `Played::_matchRecord`'s streaming branch matches on the album TITLE
    alone (no album-id anchor), and LL's `DB::_norm` deliberately KEEPS the qualifier — so the bare
    name we now send never matches the qualified name the playing track reports, and the row never
    leaves the list. Silent: it plays perfectly. **Replay is NOT affected** — LL prefers the captured
    album id (`hasDirectAlbumRef`), which our favurl always carries, so its `(LP4)`-preserving
    `_bestMatches` ranking never runs for our rows. Display degrades (rows reading `American Football`
    separated only by year) — accepted, not fixed.
    **Fixed on the LL side in 0.1.92**, which keeps the service's label as `ref.svc_title` and matches
    on either. Nothing to change here: the name we send is the right one, LL just needed to stop
    throwing the other one away.
    **Do NOT "fix" this by appending MB's `disambiguation`** — that was the first plan and it is wrong.
    Sampling 120 release-groups from a live LB fresh-releases feed: exactly ONE has a disambiguation,
    and it reads `The Vampire Lestat OST` — editorial prose, not a service-style qualifier, so
    appending it would match nothing anywhere. The LB feed carries no such field either (12 keys, none
    of them disambiguation), so it would need one MB lookup per release-group — and the trending path
    resolves in bulk. `LP2` happening to be exactly Qobuz's spelling is a coincidence.
  - **BE PRECISE ABOUT THE GAIN — I overstated it first time and the verification caught it.** I cited
    two live rows (*Fruit Bats – The Landfill (Album)*, *Walrus Ghost – … (Album)*) as proof of a
    current bug. They are NOT: LL has stripped a trailing `(Album)`/`(Track)`/`(Hi-Res …)`/`(Explicit)`/
    `(Mono)`/`(Stereo)` and a trailing `(YYYY)` since **0.1.35** (2026-06-27), so a Bandcamp add TODAY
    already stores the clean title without this param. Those rows are residue from before that. What
    `&al=` actually replaces is **the blocklist itself**: anything not on that fixed list —
    `(Deluxe Edition)`, `(Bonus Track Version)`, `(Remastered)` — still reaches the stored title and the
    dedupe key. Authoritative name instead of a guess at what to strip. **Method note:** the first cut
    of the test modelled LL's fallback as the row label ALONE, which made the `(Album)` cases look like
    they proved something; the anti-test passed them either way and exposed it. Model the FULL fallback
    or a suite flatters the feature.
  - **DELIBERATE BEHAVIOUR CHANGE, not pure cleanup:** an edition qualifier that is genuinely part of
    the service's album title is replaced by MB's plain release name, so a deluxe edition and the
    standard one now key alike and collapse into ONE row. Correct here (LBF matched both to the SAME MB
    release), but it is a change — pinned in LL's `tools/t_addpath.pl` with that reasoning attached.
  - **`_streamKey` :22→:23.** `favorites_url` is part of the cached item, so without it every
    already-resolved album keeps handing LL the old favurl for the 7d TTL. Note this is the OPPOSITE
    case to the 0.9.143 no-op: that DROPPED a field (orphan, never read → no bump); this ADDS one a
    reader depends on. **`_bcMatchKey` stays `:6:`** per the standing rule — with a cost stated in the
    comment: an already-pinned Bandcamp match keeps its old favurl until re-searched by hand. Accepted;
    bumping would delete every hand-curated pin, which is strictly worse.
  - **Encoding contract, verified not assumed:** `uri_escape_utf8` out, `uri_unescape` back = **OCTETS**,
    never a utf8-flagged string. Identical to `&a=` since 0.9.58 and consistent all the way through LL,
    so the round trip is lossless. `t_ll_handshake.pl` asserts the octet-ness explicitly so a future
    change on either side fails loudly rather than quietly re-keying LL's rows.
  - **Tests: `tools/t_ll_handshake.pl` gained section 3**, driving LL's REAL `_stripPrivateParams`
    (grabbed from `ListenLater/Plugin.pm`) over what `_attachFavUrl` actually emitted — clean case,
    on/off-blocklist qualifiers, punctuation-only `( )`, a title full of `&`/`=`/`?`, wide chars, empty
    album, and `al=` as the LONE param (the ordering case: each strip takes its own leading delimiter,
    so the residue must still be a bare `scheme://album:<id>`). The file paths are now env-overridable
    (`LBF_BROWSE`/`LL_SOURCES`/`LL_PLUGIN`) **so it can be anti-tested** — 13 failures with the sender's
    `al=` push deleted, 13 with the receiver's strip deleted. LL's `tools/t_addpath.pl` gained the
    DB-level half: the verbatim favurl this version emits for Qobuz and Bandcamp, asserted on the
    stored row, its dedupe key, and that a later plain-labelled add of the same record now dedupes
    (5 failures without the receiver).
- **0.9.143** — **`&tc=` REMOVED — 0.9.142's plumbing was measurably inert, so it's gone.** Read the
  0.9.142 entry below for the full trace and the verification that killed it. Summary: the count
  fields are real but live on each service's per-ALBUM endpoint and are ABSENT from the SEARCH
  responses `_searchQobuz`/`_searchTidal`/`_searchDeezer` iterate, so `_candTrackCount` returned undef
  every time and no `tc=` was ever emitted, on any service. **Removed:** `_candTrackCount`, the three
  `$item->{_tracks}` stashes, and the `tc=` block in `_attachFavUrl` (which now carries a comment
  saying why, and what evidence would be needed to re-add it).
  **`_streamKey` deliberately STAYS at `:22:`** — reverting it to `:21:` would resurrect pre-0.9.142
  entries and bumping to `:23:` would force a third pointless re-resolve, whereas DROPPING a field
  from the cached item needs neither: an orphaned `_tracks` key is simply never read. (Earlier in that
  session I argued a revert would cost a `:22→:23` bump; that was wrong, and it was the main reason I
  recommended keeping dead code — a sunk-cost argument, not a technical one.)
  **Version goes FORWARD to 0.9.143, not back to 0.9.141:** 0.9.142 was already installed, and LMS
  offers no update for a same-or-lower version. **`tools/t_ll_handshake.pl` rewritten again** — it now
  tests the `&rt=` wire (including that an unmappable MB type asserts nothing) and LL's own
  type×count decision, and **asserts no count param is emitted**, so re-adding one fails the test.
  It also lost a reference to a non-existent `LL verify_favurl_params.pl` that I had invented.
- **0.9.142** — **`&tc=` — the release's TRACK COUNT joins the Listen Later handshake, completing
  0.9.141.** 0.9.141 sent MB's primary type as `&rt=` and asserted it as authoritative; but LL reads
  `single` as "exactly ONE track" (`Played::_totalTracks` returns 1 → its played-through mark), so a
  MB Single with B-sides was marked Played after track one. The count that disproves it was **already
  on the same item**: `_candReleaseType` has read it off the service's album hash since 0.9.89 (for
  the single-drop filter) — computed ~11 lines before `_attachFavUrl` builds the favurl, and unused
  by it. Fixed properly in LL 0.1.88 (it resolves the release to check); this sends the number so LL
  needs no lookup at all and the row is right at INSERT time. **Changes:** new `_candTrackCount`
  (same three verified fields: Qobuz `tracks_count`, Deezer `nb_tracks`, TIDAL `numberOfTracks`;
  1-3 digits, non-zero) — DELIBERATELY a separate sub, NOT a refactor of `_candReleaseType`, which
  treats a count of 0 as 'single' (`$tc <= 2`) and feeds the single-drop filter: folding them would
  silently change which candidates that filter drops. Stashed as `_tracks` in `_searchQobuz` /
  `_searchTidal` / `_searchDeezer` beside `_ctype`/`_year` (plain scalar → survives the Storable
  stream cache). `_attachFavUrl` reads `$it->{_tracks}` rather than taking a new arg, so the OTHER
  call site (the manual Bandcamp picker, ~4958, which has no album hash) sends nothing and needs no
  change — Bandcamp has no count before its page is fetched, so LL resolves there as before.
  **Cache: `_streamKey` :21→:22** for the same reason as :20→:21 — `favorites_url` is part of the
  cached item, so without it every already-resolved album would keep handing LL a favurl with no
  count. `_bcMatchKey` **stays at :6:** (no auto-repopulation — bumping it discards hand-curated
  Bandcamp-only matches; the 0.9.42 mistake reverted in 0.9.47 and re-attempted in 0.9.141).
  **Ordering rule: LL 0.1.89 (the receiver) MUST ship first** — an LL that can't strip `tc=` leaves
  it in the favurl. **`tools/t_ll_handshake.pl` rewritten** (it had FAILED after LL 0.1.88 added
  `singleIsWrong`, which it didn't grab — and it encoded the bug as expected behaviour, asserting
  Single+3 tracks → 'single'). It now evals the real subs from both repos and covers 13 type/count
  combinations plus sender-side validation; `t_cache_widechar.pl`, `t_review_fixes.pl` and
  `matcher_sync_check.py` all still pass unchanged.
  **VERIFIED LIVE 2026-07-29 — and the optimisation does NOT pay off where it was expected.**
  Adding *3OH!3 – MY FRIENDS* (MB **Single**, 3 tracks) from LBF match rows, per service, from
  `curl http://plex:9000/log.txt`:
  - **Tidal** (rec 199): `add -> tidal … rel=single` then `reclassified as ep` **150 ms** later.
  - **Deezer** (recs 198, 200): `rel=single` then `reclassified as ep` after **277 ms** / **2 ms**
    (the 2 ms one hit an already-cached tracklist).
  - **Qobuz** (rec 201): `rel=single` then `reclassified as ep` **1.5 ms** later — SAME as the others.

  **So `&tc=` delivers on NO service. 0.9.142 is inert plumbing.** The count is absent from all three
  SEARCH payloads, which is where LBF gets its album hashes.

  `rel=single` on the INSERT line is the proof: had `&tc=3` arrived, `relTypeFor(service=>'single',
  count=>3)` would have settled it to `ep` at insert with no correction line at all. So **neither
  Tidal's `numberOfTracks` nor Deezer's `nb_tracks` is present in their SEARCH responses** — those
  fields exist on the per-album endpoint (which is what the earlier probe recorded), not on search
  results. The count LBF sends is therefore absent for both, and LL's background `_verifyRelease`
  does the work — invisibly, in 2–150 ms, which is why it LOOKS instant to the user (Simon reported
  "showed up straight away, no delay" for both services; that observation and the log agree — the
  fallback is imperceptible, not absent).

  **Consequence for `_candReleaseType` (PRE-EXISTING, since 0.9.89, worth its own look):** its
  count fallback reads the same absent fields, so for Tidal and Deezer it can only ever answer from
  `record_type`/`type`. If those are absent from search results too, `_ctype` is always `''` there
  and the single-drop filter has never dropped a Tidal or Deezer candidate. Untested — but this
  finding makes it likely.

  **DO NOT conflate this with LL's own Qobuz shortcut.** `Sources::classifyRelType` reads
  `tracks_count` off `getAPIHandler->getAlbum` — the per-album ENDPOINT, which is exactly where these
  fields are documented to live, and a different call from the search LBF uses. The Qobuz result
  above says nothing about it either way: the correction line appears whether the count came from the
  album object or from the tracklist. Still unverified — don't credit it, don't dismiss it. (Its 1.5 ms
  turnaround is suggestive but proves nothing; a cached tracklist is equally fast.)

  **Keep or revert?** KEEP, purely on cost: the `:21→:22` bump has already taken its one re-resolve,
  and reverting needs `:22→:23` — a SECOND re-resolve — to buy back nothing. The plumbing is inert
  where the field is missing and would start working with no code change if a payload ever carried it.

  **The lesson worth more than the feature:** every test written for this (`t_ll_handshake.pl`,
  LL's `verify_qobuz_path.pl`) SUPPLIED the field itself — a stubbed `{tracks_count=>4}` — so they
  could only ever confirm that our code reads a count when one is present, never that one IS present.
  The "field names verified per plugin" comment was verified against PLUGIN SOURCE (where the fields
  appear in album-endpoint handling); that true statement about NAMES silently became an assumed
  statement about AVAILABILITY in a different payload. A sender-side handshake needs one real
  end-to-end observation before it is believed, not a synthetic round trip.
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
