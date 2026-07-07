# Changelog

All notable changes to **ListenBrainz Fresh Releases** are listed here.
Versions follow `MAJOR.MINOR.PATCH`.

## 0.9.77

### Fixed
- **ListenBrainz Radio (Don't Stop The Music) was playing random tracks from your library instead of a proper radio.** ListenBrainz has temporarily disabled the server-side "Popularity" data the radio uses to turn artists into songs, so the radio couldn't build a station and fell back to random. It now falls back to your personalised **Recommended** pool instead — real recommendations rather than random — until ListenBrainz turns that data back on.

### Technical
- Root cause diagnosed live: `getSimilarArtists` succeeds (100 artists) but every `getTopRecordingsForArtist` call returns `500 "Popularity API currently disabled due to high load on the server"`. All radio sub-paths (similar-artists, seed-only, Last.fm) funnel through that one endpoint, so the candidate pool comes back empty and `_resolveAndReturn` returned `[]` → core DSTM random. The Last.fm fallback can't help (same dead endpoint) and was only wired to the empty/error branches of `getSimilarArtists`. Fix: `_resolveAndReturn` now falls back once to `_recommendedFill` (the `/1/cf/recommendation` CF pool — a different endpoint, confirmed up) whenever a `radio` pool is empty; centralised so it covers all three radio sites; `recommended` is guarded from recursing. Follow-up left open: negative-cache the "Popularity disabled" 500 so `_collectArtistTracks` skips ~24 doomed calls per top-up during an extended outage. No cache-version bump.

## 0.9.76

### Fixed
- **A Deezer streaming match on a release detail page disappeared when you re-opened the page.** The match showed the first time (from a live search) but was silently dropped from the cached copy on every later open, so the album looked like it had no Deezer match. Now it's kept and stays playable.

### Technical
- `_rebuildStreamItems` reattaches each service's browse coderef by `_svc` but only handled Qobuz/Bandcamp/Tidal — a Deezer item fell through `else { next }` and was dropped on cache read. Deezer's album node is the same shape as Tidal's (`_renderAlbum` → `url => \&getAlbum` coderef, id in `passthrough`), so a one-line Tidal-style reattach branch (`\&Plugins::Deezer::Plugin::getAlbum`) fixes it. Added `getAlbum` to the Deezer adapter-registration `->can` guard so the service only registers when the album round-trip is possible, and corrected the adapter comment (the `deezer://album:<id>` string is the `play`/favourites value, not the browse url). No cache-version bump — cached Deezer entries carry the id in passthrough and now rebuild correctly. Verified against michaelherger/lms-deezer.

## 0.9.75

### Fixed
- **"Play what's new" could queue its tracks twice, or open empty.** The row was a playable container nested inside the People-You-Follow list, so playing the whole list (from the tile) could enqueue the new tracks a second time. It's now a tap-to-open row that drills into a clean, play-all-able list of just the new tracks. It also no longer depends on a cache that may have expired between showing the count and tapping — so the number on the row and the tracks inside it always match.
- **Deezer matching is more robust.** If the Deezer plugin ever returns search results in an unexpected shape, matching now falls back to "no result found" cleanly instead of risking an error that stalls the search.

### Technical
- `_followResult` "Play what's new" row changed from `type=>'playlist'` to a `type=>'link'` drill row, so the tile's Play-all can't re-expand it and double-queue; its resolved, service-filtered items are threaded through the passthrough (the follow level is live/`cachetime=>0`, always fresh) so `playFollowNew` no longer re-reads a possibly-evicted resolved cache. `playFollowNew` now returns a PURE track list (no dividers) so the drilled level is itself a proper Play-all container. `_searchDeezer`/`_searchDeezerTrack` tolerate a bare-arrayref OR hash-wrapped (`{data}`/`{albums}`/`{tracks}`) response and bail to a clean miss on any other shape, so a mismatch can't die inside the async search callback (outside `_findPlayable`'s eval) and leave the service un-settled until timeout.

## 0.9.74

### Fixed
- **"Play what's new" showed a count but opened empty, and never marked your backlog as played.** Two bugs: the "seen" marker was kept in the cache store and didn't reliably persist (so it never stuck), and the row's count and its contents were derived from two different track sources that could disagree (hence "Play what's new (30)" opening to "Nothing new"). The marker now lives in a durable **pref**; both the count and the contents come from the **same resolved list**; and on first open your existing recs are baselined as already-played, so the card only appears for genuinely newer arrivals.

### Technical
- "Seen" marker moved from the follow store to a pref (`follow_last_seen`). `_followResult` baselines it to the newest matched `_created` on first render and counts `_created > lastSeen`; `playFollowNew` filters the resolved cache by the same predicate, advances the pref, and renders via `_followResult`. Store TTL 90d → 30d (very large TTLs weren't retained by the cache). LESSON: durable per-user state belongs in a pref, not `Slim::Utils::Cache`.

## 0.9.73

### Added
- **"Play what's new" for People You Follow.** A **"Play what's new (N)"** row appears at the top of the list when recommendations have been added since you last caught up — tap to play (or open) just those new tracks. Doing so marks them as seen, so the row clears until more arrive. It baselines on first use, so it won't dump your whole existing list as "new".

### Technical
- Per-user `lastSeen` epoch in the follow store (baselined to the newest rec on first `_mergeFollow`; no play history needed — recs carry `created`). `_followResult` counts matched tracks with `_created > lastSeen` and unshifts a `type=>'playlist'` "Play what's new" row → `playFollowNew`, which resolves just the new recs (owned-excluded, day-divided) and advances `lastSeen` to the newest rec on open/play. Strings `PLUGIN_LBF_PLAY_NEW` / `PLUGIN_LBF_NO_NEW`.

## 0.9.72

### Changed
- **"Recommended by People You Follow" is one day-divided list, not weekly.** The weekly rolling-4 layout from 0.9.70 was abandoned: with recommendations spread ~1 per week across many months, pruning to the newest 4 weeks hid most of them (a real feed of ~35 recs showed only ~4). Now it's a **single Play-all list of all captured recs**, newest-first, with **day dividers** so new additions stand out. Still **new-music-only** (owned tracks excluded). The day dividers now use the **same Material header style as the New Releases week dividers** (was plain dashed text — flagged as inconsistent). The *Unmatched tracks* tracker has a single "Recommended by People You Follow" entry (not per-week).

### Technical
- Replaced the per-week bucket store with a flat accumulating store `lbf:follow:accum:1:<user>` (`_mergeFollow`: dedup, newest-first by `created`, capped at `FOLLOW_KEEP_MAX`=500, 90-day TTL refreshed each merge). Single resolved cache `lbf:follow:resolved:3:<user>|<svc-order>` (retires the weekly `:2:`). `_followResult` groups by day and inserts `_dayDivider` header rows via `_headerType()`/`image`/per-day drill coderef — the same pattern as `_buildWeekly` — with `features` threaded through the passthrough for `_wantHeaders`. `_resolveTracks` tags each matched item with its source `created` so dividers survive the Storable resolved cache. Removed the weekly subs/tiles and the warm serialisation; `_warmFollow` resolves the whole list once on a sig change.

## 0.9.70

### Changed
- **"Recommended by People You Follow" is now weekly, new-music-only.** Instead of one ever-growing list, the recs/pins from the people you follow are bucketed into **Monday-start weeks**. The tile now drills into a rolling window of the **most recent 4 weeks** (each labelled `W/C <date>`); a new week's list is created **lazily** on its first rec (Monday, or whenever the first one lands — no empty placeholders), the current week keeps **accumulating** new recs during the week, and the oldest week **rolls off** when a fifth begins (no archive).
- **Only music you don't already own.** Every track is checked against your LMS library and any you **already have is excluded**, so each weekly list is purely new music to discover. Uses the same library matcher as the rest of the plugin (MusicBrainz ID, then artist/title), so it inherits its known edge cases — a track you own but the matcher narrowly misses can occasionally slip through as "new".
- **Unmatched tracks (debug) now covers the follow weeks too.** The Settings → *Unmatched tracks* tracker lists the People-You-Follow weekly lists alongside the created-for playlists; each unmatched row shows the source list on its second line, so it's clear which list a gap came from.

### Technical
- `API::_parseFollowFeed` now captures each event's `created` epoch. `Browse.pm` accumulates recs into a small persisted per-week store (`lbf:follow:weeks:2:<user>`, dedup + prune to 4 weeks) so a busy week isn't truncated by the feed's 75-event window and history builds forward from first capture. New `'exclude'` library mode in `_findPlayableTrack` (probe → drop if owned, else stream, never falls back to library), with `_resolveTracks` reporting an owned count so the "new tracks" total excludes owned. Per-week resolved cache `lbf:follow:resolved:2:<user>|<svc-order>|<week>`, validated by the week's content signature; the daily warm resolves the active weeks **one at a time (serial, not fanned out)** so a cold/forced warm can't fire 4 weeks of streaming searches at once — current week re-resolves on new material, frozen weeks resolve once. Retires the single-list `lbf:follow:resolved:1:` cache. The *Unmatched tracks* diagnostic gains a `showUnmatchedFollow` level-2 view and a shared `_unmatchedRows` (source name on line2). `_resolveFollowWeekTracks` (the shared open/warm resolver) does **not** gate on `$client` — on the open path it always resolves-and-reports like `resolvePlaylist`, so a follow week opened with no active player renders instead of spinning; only `_warmFollow` gates on the player.

## 0.9.69

### Added
- **Deezer streaming matches.** Deezer joins Qobuz / Tidal / Bandcamp as a service the plugin can match releases and playlist tracks against. If you have the Deezer plugin installed, its albums and tracks now resolve in the release detail pages, the Created-for-You / People-You-Follow playlists and the two Don't-Stop-The-Music mixers — with the same library-first, per-service search-order controls as the other services (Settings → Streaming Services shows Deezer with its own priority). Matched Deezer albums also carry through to the **Listen Later** plugin (0.1.60+) for one-tap saving.

## 0.9.68

### Fixed
- **Owned tracks could still be missed on a library that DOES have full-text search — a common title in a big library fell through to streaming.** The 0.9.67 title-only fallback in `_localByText` only ran when the combined `"artist title"` search returned **zero** candidates (the FTS-off signature). But there's a second way to miss an owned track: with FTS **on**, the fuzzy combined search can return candidates yet rank the owned track **outside** the 20-row window (a common title in a deep library), so pass 1 misses and the old `$n1 == 0` gate skipped the fallback. The title-only pass now runs on **any** pass-1 miss, and its window widened 50 → 100, so a track that ranked out is given a second, order-independent chance and re-verified by artist. Still cheap: the fallback is reached only on a per-track cache miss and the daily warm pre-resolves, so a not-owned track pays one extra title query once, in the background.

### Internal
- Removed an unused `$svcOrder` parameter from `_warmFollow` (the resolved-cache key is rebuilt from current prefs via `_followResolvedKey()`); documented a future **contributor-scoped `Slim::Schema` query** (a tier-2.5, FTS-independent, window-free library lookup) in CLAUDE.md as the deeper fix to revisit later.

## 0.9.67

### Fixed
- **Owned tracks weren't matching a library that has full-text search disabled — every track fell through to streaming.** The local-library matcher's text tier (`_localByText`) searched LMS with a **combined `"artist title"` term** (e.g. `search:Dire Straits Six Blade Knife`). LMS only resolves a multi-field term like that when its **Full-Text Search index is present**; with FTS disabled or broken, `titles search:` degrades to a title-only match, so a term whose artist words aren't in the title matches **nothing** — and a whole playlist resolves 0-from-library while the same tracks match fine on streaming (diagnosed live: 248/250 matched, all streaming, 0 library, for a user who owns the MP3s). Now the matcher runs a **second, title-only pass** when the combined search returns nothing: the bare title always hits the title index regardless of FTS, and `_trackMatches` re-verifies the artist. FTS-healthy libraries are unchanged (they match on the first pass and add no extra query). When the opt-in `debug_log` is on, the fallback logs the candidate count so the FTS-off case is visible. Unrelated to a file's MusicBrainz tags — the MBID tier already falls through correctly.

## 0.9.66

### Fixed
- **"Recommended by People You Follow" hung on open and resolved nothing.** `_followSig` hashed the feed's track set with `Digest::MD5::md5_hex`, which **dies** (`Wide character in subroutine entry`) on any code point > 255 — and the feed is full Unicode (Japanese titles, accented artists, curly quotes). The exception was thrown inside the feed callback, so the tile spun until it gave up with no matches. Fixed by `utf8::encode`-ing the string before hashing (hash the UTF-8 bytes, not the wide string). No other change.

## 0.9.65

### Added
- **"Recommended by People You Follow" — a new playable playlist built from your ListenBrainz social feed.** A tile in the **Created for You** section (shown when both username and token are set) turns the `recording_recommendation` / `recording_pin` events from the people you follow into a fully-streaming, Play-all-able playlist — every track matched **library-first, then streaming**, exactly like the Created-for-You playlists.
  - **API** (`API::getFollowFeed` → `GET /1/user/<user>/feed/events?count=75`, token required): `_parseFollowFeed` keeps only the track-bearing events and normalises them to `{ artist, title, album, recording_mbid, recommender }`, **newest-first**, **de-duplicated** by recording MBID (or `artist|title` when a recommendation carries no MBID — ~1 in 6 don't). The recording MBID is dug out of `additional_info`, the `mbid_mapping`, or the pin wrapper. Dual short/fallback cache (`lbf:follow:feed[fb]:<user>`, `FEED_TTL` / `FEED_FALLBACK_TTL`) like the fresh-releases feed.
  - **Resolve & cache** (`Browse::resolveFollowFeed`): the tile drills straight into the resolved tracks (it's one virtual playlist, not a list). Resolved under `lbf:follow:resolved:1:<user>|<svc-order>` and **validated by a signature of the feed's track set** (`_followSig`) — a cached resolve is reused only while the feed is unchanged; new recommendations bust it. Reuses `_resolveTracks` / `_playlistResult` / `_playlistTtl`, so it inherits service-aware re-matching, the library-1-day TTL, inconclusive-outage handling and the tracks-only Play-all layout.
  - **Daily cadence:** unlike the weekly createdfor listing, this timeline updates continuously — so it's a 24h cache refreshed by the existing **daily background warm** (`_warmFollow`, chained after the playlist warm in `warmCache`; a no-op without a token). The Playlists "Refresh matches" action also refreshes it (it runs the whole warm forced).
  - **Branded cover** `menu-follow.png` ("People You Follow", rose gradient; generated by `tools/make_covers.py`). New debug tool `tools/fetch_feed.py` dumps the raw feed as `match_check`-ready lines (needs the token — pass it as an arg or `LB_TOKEN`).

## 0.9.64

### Changed
- **"Search Bandcamp" now opens a tap-to-choose picker, and the chosen match lands on an album page where "Add to Listen Later / Wish List" actually works.** Previously the manual search re-rendered the detail page in place (`nextWindow => 'refresh'`), which shows the match but leaves it **un-armed** for Material's custom actions when Bandcamp is the sole source — because Material only sets `view.itemCustomActions` on a **fresh drill-in** (`browseHandleListResponse`), never on the in-place `refreshList` (browse-page.js:1568). So Add-to-Listen-Later was missing until you backed out and re-entered the album. Now:
  - **Match →** the search returns a **picker sub-page**: a "Tap an album to use it as this release's match" prompt followed by one **non-playable** row per candidate (real cover + `Album / Artist`). A non-empty response pushes a new view (Material ignores `nextWindow` when there are items — browse-functions.js:834), so the single `nextWindow => 'refresh'` row drives both outcomes.
  - **Tap a candidate →** it's **pinned** as this release's Bandcamp match (`_bcMatchKey`; nothing is pinned until you choose) and the album page is **re-rendered via `_releaseDetail` as a fresh drill** — so it shows the match inline **and arms** the custom actions, giving it Add to Listen Later / Wish List.
  - **No match →** returns an **empty** list, so `nextWindow => 'refresh'` re-renders the album page **inline** and the row flips to "…not found — tap to retry" (no dead-end page).
  - The pinned candidate is baked into the exact same form as before (service logo as the row image; cover + page URL + artist + year on the favurl for Listen Later), so the inline detail render, replay and the Listen Later handshake are unchanged. No cache bump (`lbf:bcmatch:` unchanged). Supersedes the abandoned 0.9.61 (auto-pop-to-parent) and 0.9.62–0.9.63 (playable-row drill-in) iterations of the same fix.

## 0.9.60

### Fixed
- **code-review fix: manual Bandcamp search can't start an extra search after the watchdog gives up.** `_searchBandcampOnly` tries its ordered queries (full `artist album`, each collaborator + album, album-only) one at a time, guarded by a single overall watchdog. If a search hung long enough for the watchdog to fire `$finish->([])` and *then* returned empty, its callback re-entered `$tryNext` and launched the next query's search — a heavy synchronous Bandcamp parse running *after* the row had already re-rendered (exactly the event-loop stall Bandcamp was made manual-only to avoid). `$tryNext` now returns early when `$done` is set (mirroring `$finish`'s idempotency), so a late callback after the watchdog can't start another search. No cache bump (control-flow only; matching/caching unchanged).

## 0.9.59

### Changed
- **Matched streaming albums also carry the release year to Listen Later** (`&y=<year>` on the favurl, alongside the `&a=<artist>` from 0.9.58). Listen Later 0.1.43 folds the year into its duplicate key (`artist|album|year`), so two same-titled releases from different years — added from the detail page — save as two entries instead of the second being dropped as a duplicate. The year is taken from the release's `release_date`; threaded through `_findPlayable`/`_searchBandcampOnly` to `_attachFavUrl`. Stream play-via cache bumped `lbf:stream:11:`→`:12:` so matched albums re-resolve once and bake in the year (free — Qobuz/Tidal self-resolve); `lbf:bcmatch:` still not bumped.

## 0.9.58

### Changed
- **Matched streaming albums now carry the artist to Listen Later.** The Add-to-Listen-Later / Wish List actions on the detail-page match rows sent no artist — Material exposes no `$ARTISTNAME` for these rows (the thumbnail is the service logo and the subtitle isn't mapped), so Listen Later stored an artist-less record that never auto-moved to its Played list. `_attachFavUrl` now packs the release artist into the favurl as a private `&a=<artist>` param, alongside the existing `?cover=` (Qobuz/Tidal) / `?b=<art\|url>` (Bandcamp) handshake; Listen Later 0.1.42+ reads it as a fallback and strips it. Native streaming-plugin favurls (no query string) are unaffected. Stream play-via cache bumped `lbf:stream:10:`→`:11:` so matched Qobuz/Tidal albums re-resolve once and gain the artist param (free — they re-resolve themselves); the manual-Bandcamp match cache (`lbf:bcmatch:`) is deliberately **not** bumped (its rows already surface an artist, and it has no auto-repopulation).

## 0.9.57

### Fixed
- **Accented / diacritic artist & album names now match across spelling variants.** The matcher's normaliser (`_norm`) kept accents as distinct letters, so a name that a streaming catalogue (or a library tag) spells without them — or with a different Unicode form of the same accent — failed to match: `Altın Gün — Neredesin Sen` missed on Qobuz although it's there (dotless `ı` and `ü` vs `Altin Gun`). `_norm` now folds Latin diacritics to their base letter (`é→e`, `ü→u`, `ñ→n`, `ç→c`, and the atomic letters `ı→i`, `ł→l`, `ø→o`, `ð/đ→d`, `þ→th`, `ß→ss`, `æ→ae`, `œ→oe`). Applied to streaming album/track matching, the local-library matcher, and de-dupe. Non-Latin scripts (Japanese, Cyrillic, Arabic, …) are deliberately **not** folded — the fold decomposes, strips only the Latin combining-mark block, then re-composes, so e.g. Japanese voiced kana survives intact. Albums with accented names re-resolve once on next open (their cache key changes); ASCII names are unaffected, so no cache-version bump.
- **`tools/match_check.py` updated to the shipped fold** (it was modelling a slightly different, Japanese-mangling variant) and now folds by default, with `--fold` showing a pre-fold vs shipped comparison.

## 0.9.56

### Added
- **"Search Bandcamp" now falls back to per-artist queries for collaborations.** The manual Bandcamp search used one combined `"<artist> <album>"` query, which Bandcamp's search doesn't return for a two-artist release credited to `A & B` (found with *Panda Bear & Sonic Boom – A ? of WHEN*: it exists on each artist's Bandcamp page but not under the combined search). It now tries, in order and stopping at the first hit: the full `artist album`, then **each individual collaborator + album** (splitting `&`/`+`/`feat`/`ft`/`with`/`x`/`vs`), then the album title alone. `_albumMatches` still validates artist + title on every result, so a broader query can't admit a wrong album. Extra searches run only on a miss (the common combined-query case is still a single search), and only on a deliberate tap. (This is search-recall only — it still does not drill an artist's Bandcamp discography.)

_No cache-version bump._

## 0.9.55

### Fixed
- **A persisted manual Bandcamp match can no longer be truncated off the detail page.** The Streaming section caps auto matches (Qobuz/Tidal) at 12 to keep a generic one-word title sane, but the hand-curated Bandcamp match was appended *before* that cap — so a release with 12+ auto matches could drop the Bandcamp entry, exactly the case where it's meant to be the primary/sole playable row. The cap now applies to the auto matches only; the Bandcamp match is always kept (deduped so it never shows twice).
- **Hardened the Last.fm tag parser against a non-object tag entry.** `_parseLastfmTags` guarded the tag *name* against a bare-string entry but still dereferenced its `count` unconditionally (in both the sort and the low-weight filter), which would fatally `Can't use string as a HASH ref` under strict refs if Last.fm ever returned a string tag. The count is now read through the same guard.

### Changed
- **Bounded the Don't Stop The Music per-session no-repeat set.** The set of already-played track URLs is intentionally never reset for the life of a session (that's the no-repeat guarantee), so it's now FIFO-capped at 5000 — a marathon auto-DJ session can't grow it without limit, and an evicted URL can only recur after 5000 others (no practical repeat).

_No cache-version bumps — none of these change what matches or what's stored._

## 0.9.54

### Fixed
- **The startup warm no longer resolves playlists before the library scan finishes.** If the background warm ran while a library scan was still in progress, the local-library tier was empty, so every owned track fell through to streaming (Qobuz/Tidal) — and that all-streaming result was cached for the resolved-playlist TTL (days), with later warms skipping the already-cached playlist. So a user with the music in their library still saw everything matched to streaming. The warm now **defers while `Slim::Music::Import->stillScanning()` is true** (re-checking every 120s) and only resolves once the scan has completed.

### Added
- **"Refresh playlist matches (re-match now)"** — a Refresh row at the top of the **Playlists** view (mirroring the New Releases / All Releases feed refresh) that forces a fresh, **library-first** re-resolve of every playlist, bypassing both the resolved-playlist and per-track caches. Use it to recover immediately from a stale all-streaming result (e.g. one cached by a pre-scan warm on an older build) without waiting for the weekly rollover. Re-matches in the background (~a minute); needs a connected player (to search the streaming services for anything not owned).
- **Opt-in dedicated debug log.** A new **Write a debug log** setting records the playlist warm/match timeline — including the **library-match count per playlist** and scan-defers — to a dedicated `lbf-debug.log` beside the server log (size-capped, one rotation). Off by default; turn it on to track a matching/caching issue, then off again. (The same lines still go to `server.log` at INFO.)

## 0.9.53

### Changed
- **Pass the Bandcamp album page URL to Listen Later in the favurl, for exact replay.** The cover art **and** the album page URL are packed into a single escaped `?b=<art>|<url>` favurl param, so Listen Later 0.1.39+ replays the exact album via `get_album` with no second lookup (and Buy-on-Bandcamp opens the page directly). Qobuz/Tidal still use the plain `?cover=` (art only — they replay by id).
- **Confirmed the full favurl survives Material (correcting an earlier wrong conclusion).** An earlier theory that "Material drops a favurl longer than ~150 chars" was **invalid**: it was drawn while a stale repo-installed LBF was *shadowing* the manual dev build, so the new favurl code never ran and the add arrived with no favurl at all. With the correct build loaded, the full ~164-char `bandcamp://album:<id>?b=<art>|<url>` favurl arrives intact — the saved record keeps the real cover and the exact page URL. The `album_id`-search fallback on the Listen Later side remains only as a safety net.

### Fixed
- **Bandcamp matches added to Listen Later now play, with their artwork and service intact.** A matched Bandcamp album handed to Listen Later showed its cover and title but played nothing, because Bandcamp's `get_album` resolves a tracklist from the album **page URL**, not the `album:<id>` carried in the favurl. Fixed by carrying the page URL (and the cover) across in the `?b=<art>|<url>` favurl blob, which Listen Later unpacks and replays directly.

## 0.9.49 – 0.9.52

Intermediate iterations of the Bandcamp-favurl work, all **superseded by 0.9.53** (above). These were the in-progress attempts to carry the album page URL across to Listen Later (cover-only `?cover=`, then the `&burl=`/`?burl=`/`?b=` encodings). The conclusion drawn during them — that Material drops long favurls — turned out to be a stale-install artifact (see 0.9.53), so they're consolidated rather than listed individually. If you ran one of these dev builds, no action is needed; 0.9.53 supersedes them.

## 0.9.48

### Changed
- **Library track matching no longer blocks the event loop — gentler on low-power servers (Raspberry Pi).** Resolving a Created-for-You playlist (or a DSTM mix) with *Prefer local library* on probes the LMS database for each track. That probe (`Slim::Schema` / the `titles` request) is the one **synchronous** step in an otherwise fully-async resolver, and LMS's DB layer has no non-blocking form. When a playlist matched mostly from the library, every track's probe completed synchronously and immediately resolved the next one in the **same** event-loop pass — up to ~50 back-to-back blocking queries with no yield, which on a low-power box (Pi / Pi Zero) could starve audio for long enough to stutter or drop players (the background warm ~60s after startup, or opening a brand-new week's playlist cold, were the worst cases). Each library probe now runs on an idle timer tick, so the event loop services audio and the UI **between** probes. The total work is identical — there's just never one long contiguous freeze. Behaviour, matching and caching are unchanged (cached opens never reach this path), so no cache bump.

### Maintenance (no behaviour change)
- Trimmed a stale cache-version list in `_findPlayable`'s comment (it named `:7:` as current while the key is at `:10:`); the authoritative history lives on `_streamKey`.
- Dropped two unused localisation strings (`PLUGIN_LBF_PLAY_VIA`, `PLUGIN_LBF_NO_SERVICES`).
- `_parsePlaylistTracks` no longer parses the three JSPF fields nothing consumed (`duration_ms`, `caa_id`, `caa_release_mbid`) — resolved tracks carry their own art/duration from the matched streaming result.

## 0.9.47

### Fixed
- **Updating to the favurl build no longer drops your manual Bandcamp matches.** The 0.9.42 favurl work bumped the persisted-Bandcamp-match key `lbf:bcmatch:6:`→`:7:`. Unlike the auto play-via cache (`lbf:stream:*`, which re-resolves itself on the next detail-page open), this key has **no automatic repopulation** — a Bandcamp match only comes back via a manual "Search Bandcamp" tap — so the bump silently discarded every hand-curated Bandcamp-only match on update, leaving those releases with no playable entry until each was re-searched by hand. Reverted the key to `:6:`: existing matches survive the upgrade and keep playing. A *fresh* Bandcamp search still bakes the Listen Later favurl in (`_searchBandcampOnly` → `_attachFavUrl`); an older cached match just plays without the favurl until it's next re-searched (the same "manual refresh adds it" path). The auto play-via favurl bumps (`lbf:stream:*`) are unaffected — that cache re-resolves on its own.

## 0.9.46

### Fixed
- **Listen Later favurl now url-encodes the cover with `uri_escape_utf8`.** `_attachFavUrl` appended the album-art URL to the favurl via `URI::Escape::uri_escape`, which `carp`s and emits a malformed escape on any code point > 255. In practice service art URLs are ASCII, but this is the one new spot that handed a possibly utf8-flagged string to a non-utf8-safe escaper (the rest of the file is careful to `utf8::encode` before anything that chokes on wide chars). Switched to `uri_escape_utf8` so a wide-char art URL can't warn or produce a broken `?cover=` param. No behaviour change for the ASCII case, so no cache bump.

## 0.9.45

### Changed
- **Removed the temporary `QOBUZ-DIAG` logging** added in 0.9.44 — the live box confirmed the bogus *Beth Orton – The Ground Above* duplicate is flagged non-streamable, so the `streamable`-only discriminator is sufficient and the diagnostic is no longer needed.

### Fixed
- **`_attachFavUrl` cover guard now rejects any ref, not just coderefs.** The Listen Later favurl's `?cover=` param is only appended when the row's art is a plain URL string; the guard was `$art !~ /^CODE/` (caught a stringified coderef but not a HASH/ARRAY ref), now `!ref $art` (rejects every ref). Edge-case hardening — in practice the art is only ever a string or coderef here.

## 0.9.44

### Changed
- **Bogus Qobuz duplicate now dismissed by the `streamable` flag alone.** The 0.9.43 fix dropped a candidate that was non-streamable **and/or** had a `*`-prefixed title. The `*`-prefix heuristic was risky (a real album can legitimately be `*`-titled, and `_norm` strips a leading `*` so it never actually distinguished the two duplicates anyway), so both `*` checks were removed and the **non-streamable** test (`defined $album->{streamable} && !$album->{streamable}`) is now the sole discriminator in `_searchQobuz`. Play-via cache bumped `lbf:stream:9:`→`:10:` so every album re-resolves once (otherwise the old `*`-filtered cache would mask the change).

## 0.9.43

### Fixed
- **A bogus Qobuz "partial / orphaned" duplicate of a release no longer shows as a dead second streaming match.** Qobuz's catalogue sometimes lists the same album twice — the real, playable one plus a partial/orphaned entry that isn't streamable and whose title is prefixed with `*` (e.g. *Beth Orton – The Ground Above* showed two, only one playable). Because our title normaliser strips the leading `*`, the bogus entry matched too and appeared alongside the real album. The Qobuz album search now skips a candidate that is **non-streamable** and/or whose title (or rendered name) starts with `*`, so only the genuine, playable album shows. (Play-via cache bumped `lbf:stream:8:`→`:9:`, so every album re-resolves once on update and the bogus entry clears automatically — no manual Refresh needed.)

## 0.9.42

### Added
- **Matched streaming albums on the detail page can now be added to Listen Later properly.** Each Qobuz/Tidal/Bandcamp match now carries a real `favorites_url` (`<service>://album:<id>`), so the sibling **Listen Later** plugin captures it with the correct **service**, a **directly-replayable album** (via the native album id), and the real **album artwork** — instead of the previous broken coderef "link", wrong source and missing art. The detail row still shows the **service logo** as its thumbnail; because that means the row image is the logo (not the cover), the album art is carried alongside the favurl as a private `?cover=` param that Listen Later reads and stores. (Listen Later 0.1.30+ understands the `?cover=` param; older versions simply ignore it and fall back to the row image. The "Add to Listen Later" action itself only appears on a Material build with the merged online-custom-actions support.) The album play-via and persisted-Bandcamp caches are version-bumped (`lbf:stream:7:`→`:8:`, `lbf:bcmatch:6:`→`:7:`), so **every album re-resolves once on first open after updating** and picks up the new favurl automatically — no manual per-section/per-album Refresh needed.

## 0.9.41

### Fixed
- **A broken or changed streaming-service album renderer can no longer hang the detail page.** The Qobuz/Tidal album search now guards each service's own album-rendering call; if it ever throws (e.g. after a service-plugin update changes that function), the result is skipped rather than leaving the search unanswered until its 8-second timeout. A single bad result is dropped, not the whole service — any other matches still show. (The playlist/track path already worked this way.)
- **A momentarily-unavailable streaming service no longer hides a release for a day.** When a service can't actually be queried — its plugin isn't authenticated yet, the search times out or errors, or its renderer breaks — the detail page now treats that as *inconclusive* and retries within the hour, instead of caching a false "no match" for a full day. A genuine "searched fine and it's not there" still caches for a day, and a found match for a week. So a just-released album (or a service that was briefly down) shows up within the hour, or instantly via the Refresh row. This brings the Releases page in line with how playlist track-matching already behaved.

### Changed
- **Internal cleanup, no change to what you see.** Removed some unused playlist-listing fields and a dead helper; dropped an unused recommendation parameter that the ListenBrainz API ignores (verified live — the request is unchanged); and removed a redundant text-normalisation pass in a cache-key helper (keys are byte-identical, so nothing re-searches). Streaming match quality is untouched.

## 0.9.40

### Fixed
- **Releases with no artist/album credit no longer render blank.** A dead `//` fallback meant a release missing its artist credit showed as `" — Album"` (no name); the "Unknown Artist"/"Unknown Album" fallback now actually applies.

### Changed
- **Code-review housekeeping (no behaviour change):** per-track service-usability checks no longer rebuild the streaming-adapter set once per track (cheaper Playlists render); the resolve/detail/Bandcamp watchdog timers are now cancelled on normal completion instead of lingering as no-ops; the `dstm_batch` fallback default is aligned to 15; and the MusicBrainz `User-Agent` now reads the version from the plugin manifest at runtime instead of a hardcoded literal, so it can never drift from the actual release again.

## 0.9.39

### Fixed
- **The raw-query fix now also covers album (Releases) matching and the manual Bandcamp search.** 0.9.37 fixed it for playlist/DSTM *track* search; the album auto-search still sent the *normalised* artist (`P!nk` → `p nk`, `will.i.am` → `will i am`) and the manual Bandcamp search sent the normalised `artist album`, so a stylised name/title could be missed the same way `L.U.C.K.Y` was. Both now send the **raw** text to the service search, with normalisation kept for match validation only. (Album play-via cache bumped `:6:`→`:7:`, so albums re-search once on next open. DSTM needed no change — it resolves through the shared track search, already fixed in 0.9.37.)

## 0.9.38

### Added
- **"Unmatched tracks (debug)" diagnostics view** (Settings section). Lists each created-for playlist; opening one shows the source tracks that resolved to **nothing** (not in your library, not on any enabled service), as plain `Artist — Title` rows, with the count in the title. It resolves against the warm cache so it usually opens instantly and reflects exactly what the playlist dropped — making a matcher/recall gap (like the `L.U.C.K.Y` case) visible in the UI, on or off-network (no web settings page needed).

## 0.9.37

### Fixed
- **Stylised track titles (e.g. `L.U.C.K.Y`) now match.** We were sending the *normalised* artist+title to each streaming service's search — and normalisation turns punctuation into spaces (`L.U.C.K.Y` → `l u c k y`), which the service's own search engine can't match, so it returned nothing even though the track is right there. Confirmed against Tidal: the raw query `Fcukers L.U.C.K.Y` returns the track as the top hit; the spaced query returns 100 results without it. The outgoing search query is now the **raw** artist+title; normalisation is still used for our own match validation (so a wrong title/artist can't slip through). With this, the 22 June Weekly Exploration goes from 49/50 to a full match. (Per-track and resolved-playlist cache versions bumped so this re-resolves on update.)

## 0.9.36

### Fixed
- **The 0.9.35 playlist re-resolve now actually takes effect on update.** 0.9.35 bumped the *per-track* cache so a service change re-resolves, but left the **outer resolved-playlist cache** at the old version — so opening a playlist still hit the stale local-only result and the per-track re-resolve never ran (playlists looked unchanged after updating). The resolved-playlist cache version is now bumped too (`lbf:pl:resolved:2:`→`:3:`), so every playlist re-resolves once on this update and picks up streaming matches.

## 0.9.35

### Changed
- **A Bandcamp match you find by hand now sticks and becomes the primary playable version when no other service has the release.** "Search Bandcamp" no longer opens a throwaway sub-page; it uses the same in-place refresh as the streaming Refresh, and the match is **persisted in its own long-lived store** (30 days, separate from the auto Qobuz/Tidal cache). On re-render it shows **inline** in the Streaming section, and `_findPlayable` appends it to every result — so a **Bandcamp-only release** (common for obscure artists) becomes the sole = primary entry, plays from the detail page, and **survives both the auto re-search and the streaming Refresh** instead of vanishing. When other services also have the album, the Bandcamp match is listed after them. Disabling Bandcamp (priority 0) hides it without discarding the stored match; the manual search now also runs even when Bandcamp is your only enabled service.

### Added
- **"Re-search Bandcamp" row.** When a Bandcamp match is already shown, the Streaming section offers a re-search action (refresh icon) to force-refresh a stale match. If the re-search comes back empty the existing match is kept, so you never lose playability. A prior empty search shows a "Search Bandcamp (not found — tap to retry)" prompt instead.

### Fixed
- **Playlists now drop AND re-match a removed service, exactly like the Releases section.** If you set a service to priority 0 or uninstall it (e.g. you stop subscribing to Qobuz), any playlist track that was matched to it is no longer offered as a dead link: the resolved-playlist and per-track caches re-resolve against your remaining services, so those tracks re-match to (say) Tidal — or drop if they're nowhere. A cached list also filters out any now-unusable service's tracks the moment it's served (the belt-and-braces twin of the album section's `_rebuildStreamItems`), and the playlist-grid tile's "X/50" count uses the same filter so it never disagrees with the opened list.
- **Resolved-playlist cache TTL cut from 30 to 14 days.** These Weekly Jams/Exploration lists only exist ~2 weeks (current + previous week) before ListenBrainz drops them, so a 30-day cache just kept dead entries that are never requested again.
- **A momentary streaming outage no longer pins a playlist on "local-only / few matches" for weeks.** A track resolves by trying each streaming service; previously, if a service couldn't even be *queried* (its API handler wasn't ready at resolve time — e.g. the startup warm-cache running before Qobuz/Tidal finished authenticating — or it timed out / errored), that was cached as a genuine "no match" for a week (per-track) and the whole resolved playlist for a month. So a list resolved at a bad moment stayed stuck showing only the handful of tracks owned locally, and even enabling Qobuz didn't recover it. These cases are now treated as **inconclusive**: the per-track and resolved-playlist caches are kept ~1 hour instead, so the list re-resolves and picks up streaming as soon as it's available. (Diagnosis: the 15 June playlists matched 44–45 via Tidal with the same matcher, while the 22 June lists — resolved when streaming wasn't reachable — got 0 streaming; the matcher was never the problem.)
- **Playlist tracks now actually re-resolve when you enable/change a streaming service.** The per-track match cache wasn't keyed by the service set, and a cached "no match" was returned without re-searching — so a track that missed while only Tidal was enabled stayed missed even after Qobuz was turned on (the playlist re-resolved but each track hit the stale miss and never tried Qobuz; the "6 of 50" symptom). The per-track cache key now includes the track-capable services in priority order (consistent with the album play-via and resolved-playlist keys) and its version was bumped, so enabling/adding/reordering a service re-resolves the affected tracks. (Diagnosis note: this means the low match count was the stale cache masking Qobuz, not necessarily the track search itself.)
- **Manual Bandcamp search now uses the combined "artist album" query again.** Bandcamp's recall is the opposite of Qobuz/Tidal: a bare-artist search frequently doesn't surface the album in its item results (it only appears by drilling into the artist page), so the 0.9.34 artist-only model returned nothing for some releases (e.g. *Lost Colossus — protocol://shibuya.rain*). Bandcamp reverts to the combined query (the album shows directly), while Qobuz/Tidal keep the artist-only model where it has better recall. `_albumMatches` still validates album+artist on every result.

## 0.9.34

### Changed
- **Streaming matches now search by artist, then filter by album title — much better recall.** Searching the services with `"artist album"` as one string made their own fuzzy search rank/drop the target (Tidal missed *Sweating Someone Else's Fever*, Qobuz missed *Placebo RE:CREATED*). The detail page now searches the **artist** and matches the album locally with `_albumMatches`, which returns the artist's catalogue and lets us pick the right release — while still guaranteeing the correct album+artist, so a broader search can't admit a wrong album. Tidal's result limit raised to 50 so a prolific artist's target isn't truncated. (Stream cache version bumped → albums re-resolve once after updating.)
- **Bandcamp moved to a manual "Search Bandcamp" action on the detail page.** Bandcamp's plugin search is cookie-dependent/unreliable and does heavy **synchronous** response-parsing that blocks the LMS event loop when it returns data (the 2–7s freeze / players dropping off). It's no longer part of the automatic search; instead a "Search Bandcamp" row runs it only on a deliberate tap (artist-only search + title filter), so the freeze can only happen on explicit user action, never on auto-open. Qobuz/Tidal remain automatic and async.

## 0.9.33

### Changed
- **Streaming matches auto-re-match when you change your streaming services.** The album detail page's play-via cache is now keyed by the current service configuration (enabled+installed services in priority order), not the release alone. So disabling a service (priority 0), reordering priorities, or removing a service plugin makes the next album open **re-resolve against the new set automatically — no manual Refresh** — instead of showing a stale link to a service you no longer use (the 0.9.32 read-filter hid such links but didn't replace them). A stable service config still hits the cache normally; the feed-list refresh is separate and never re-matches. One-time effect: because the cache key format changed, each album re-matches once on its first open after updating (any re-match can hit the known Bandcamp search slowness, to be addressed separately).

### Fixed
- **Section/week-divider headers render as full-width dividers (not grid cards) on Material 6.4.3+.** Newer Material draws an actionable `type => 'header'` item as a grid card mixed into the artwork. Headers now emit `type => 'header-basic'` on Material 6.4.3+ (a non-actionable divider that clears the item's action); Material ≤ 6.4.2 keeps the existing `'header'` behaviour unchanged, and an unknown version stays on the safe `'header'`. Covers the top-level section headers and the weekly "W/C …" dividers. The settings page is unaffected (its section headers are HTML/CSS, a different rendering path).

## 0.9.32

### Fixed
- **Cached streaming matches now respect the enabled-services setting.** The per-album play-via cache is keyed by release mbid only, so a match found while a service was enabled kept showing on the detail page after that service was disabled (`svc_priority_* = 0`) — e.g. a Qobuz link still appearing with Qobuz turned off. `_rebuildStreamItems` now drops cached matches whose service is no longer enabled, filtering on read rather than re-searching (re-searching would re-trigger a service search, which can block the loop). Re-enable the service or use the Streaming section's Refresh to re-search.

## 0.9.31

### Fixed
- **Release detail page now refreshes reliably (no more stale per-player view).** The detail page was returned without `cachetime => 0`, so Material cached it client-side per player — the in-page **Refresh** (which clears the server-side play-via cache) and any settings change wouldn't show until that client cache expired, making Refresh look like it did nothing. The detail render now sends `cachetime => 0` on both paths, so it re-fetches on each open and Refresh takes effect immediately. (Same per-player staleness class fixed for the listing feeds in 0.9.25; the detail page had been deliberately excluded.)

## 0.9.30

### Fixed
- **Streaming match for albums whose title begins with the artist name** (e.g. *Placebo – Placebo RE:CREATED*). The service search query is built as `artist + album`, which for these titles produced a doubled token (`placebo placebo re created`) that some service searches (Qobuz/Tidal/Bandcamp) failed to retrieve, so the detail page showed *No match* even though the album was available. When the album title already begins with the artist name **and has more after it**, the query now searches on the title alone (`placebo re created`). Self-titled releases (album == artist, e.g. *Placebo / Placebo*) and every other release are byte-for-byte unchanged — the artist disambiguation is unaffected because `_albumMatches`/`_artistMatch` still validate against the full, separate artist/album terms.

## 0.9.29

### Fixed
- **Guard the library-first track lookup like the fallback path does.** In `_findPlayableTrack`, the `'fallback'` library modes already wrapped `_findLocalTrack` in `eval`, but the `'first'` mode (the playlist default, `prefer_library` on) called it bare. It was safe in practice — `_findLocalTrack`'s DB access is internally eval-guarded — but the asymmetry was a latent trap: any future un-guarded code in that path would die through the playlist/DSTM resolve instead of falling through to streaming. The `'first'` call now uses the same `eval` guard, so a local-library hiccup always degrades to a streaming search.

## 0.9.28

### Fixed
- **`cachetime => 0` now also on the feeds' error/empty paths.** 0.9.25 added the no-cache hint to the success path of every dynamic feed, but the error and empty returns (a transient "Error" / "No playlists" tile, or an empty home shelf) still had no `cachetime`, so Material could cache *that* per-player and keep showing it after the backend recovered — the same staleness class, in the failure path. The hint is now on every error/empty return of the seven dynamic listing feeds (`topLevel`, `fetchForYou`, `fetchAll`, `fetchPlaylists`, `homeForYou`, `homePlaylists`, `homeAllReleases`). Scoped to those listing feeds only — resolved playlists, the release-detail page, the refresh action, and per-week content sub-feeds are unchanged (they return stable per-key content, not the rolling listing).

## 0.9.27

### Docs
- **Documented that the Material home shelves need no separate cache handling.** `HomeExtraBase` subclasses OPMLBased and dispatches `[<tag>, items, …]` through the same `Slim::Control::XMLBrowser` path as the browse menus, so the `cachetime => 0` on the `home*` feeds is honoured there too — verified in the server log (two home-page loads → two full re-fetches of all three shelves), so the per-player staleness fix covers the carousels as well, with no Material-bundle change required. Captured in CLAUDE.md and a HomeExtras.pm comment so it isn't re-investigated. No functional change.

## 0.9.26

### Fixed
- **Cap the playlist-listing cache at 24h so a sub-weekly playlist stays fresh.** The listing's working cache (0.9.23) expired at the Monday boundary, which is right for the weekly playlists but would freeze a **Daily Jams** playlist (in the same listing whenever ListenBrainz enables it, regenerating daily) for up to a week on the lazy browse path. The working TTL is now `min(_secsUntilNextWeeklyRefresh(), 24h)`: it still lands exactly on the Monday rollover (the smaller boundary value wins as Monday nears) but never holds longer than a day, so sub-weekly content refreshes daily without depending on the background warm running. This is a **listing-metadata** re-check only — playlist track resolution stays gated on `mbid|last_modified` (30‑day cache), so no extra streaming searches.

## 0.9.25

### Fixed
- **Stale-per-player browse views are gone.** Material caches each player's browse/home views independently and wasn't re-requesting after the weekly rollover, so a given player could keep showing last week's playlist/release dates even though the server data was current. The `cachetime => 0` hint trialled on the Playlists feed in 0.9.24 is **confirmed working** (verified in the server log: three opens produced three fresh `Created-for playlists cache hit` fetches instead of one cached render), so it's now applied to **all** the plugin's dynamic feeds — the top-level menu (date-span tiles), New Releases for You, All Releases, the Created-for-You playlists, and the three Material home shelves. Each open now re-fetches (served from the plugin's own server-side caches, so it stays cheap), keeping every view in step with the Monday rollover.

## 0.9.24

### Experimental
- **`cachetime => 0` on the Playlists feed.** The weekly playlist list was found to go stale **per player** in Material — Material caches each player's browse view independently and doesn't re-request after the Monday rollover (the server data is already fresh; the staleness is Material's client cache). This adds a `cachetime => 0` hint to the `fetchPlaylists` feed to test whether it makes the client re-fetch instead of serving its cached per-player copy. Server-side behaviour is unchanged. If the hint has no effect on Material's client cache it will be reverted.

## 0.9.23

### Fixed
- **Created-for-You playlists now refresh on the Monday boundary, not on a rolling timer.** The weekly playlist *listing* was cached for a rolling 24h, so the new week's Weekly Jams / Exploration were only picked up "within a day" of Monday and the exact moment drifted with whenever the cache was first populated (install/first-browse time). The working listing cache (`lbf:pl:list:<user>`) now expires **at** the Monday boundary (`API::_secsUntilNextWeeklyRefresh` → Monday 03:00 **UTC**, a few hours after ListenBrainz regenerates around 00:15–00:27 UTC), so the first browse after the rollover always re-pulls the fresh listing. Each week still mints a new playlist `mbid`, so the per-week resolved/track caches (keyed by `mbid|last_modified`) auto-bust as before.
- **A flaky `createdfor` response can no longer mask the new week for weeks.** The listing's fallback copy (served only on a fetch error) was reusing the feeds' 30-day `FEED_FALLBACK_TTL`; on a persistent outage that could keep showing a >1-week-old listing. It now uses a bounded `PLAYLIST_LIST_FALLBACK_TTL` = 8 days, so a sustained outage degrades to an empty/refresh state rather than a confidently-stale week.
- **The daily background warm now actually discovers Monday's new playlists.** `warmCache` called `getCreatedForPlaylists`, which short-circuited on the still-valid listing cache — so a warm tick running before the cache expired never saw the new week. The list fetch now takes `force => 1` (skips the working-cache read, still writes both keys) and the warm passes it, so each daily run re-pulls the listing and pre-resolves any new week's tracks.

These changes are **scoped to the Created-for-You playlist path only**; the New Releases (For You) and All Releases feeds keep their own `FEED_TTL` / `FEED_FALLBACK_TTL` and the shared `_feedError` behaviour unchanged (verified both feeds still serve current data, incl. this week).

## 0.9.22

### Changed
- **Manage Plugins "more info" link now opens the HTML README, not the raw repo.** `install.xml` `<homepageURL>` changed from the GitHub repo to the styled GitHub Pages page `https://simonarnold002.github.io/LMS-ListenBrainz-New-Releases/README.html`, so choosing "more info" in LMS → Manage Plugins lands the user on a readable page. (Link-only change folded into the 0.9.22 zip; sha refreshed, no version bump.)

### Fixed
- **Restored the artist photo on the release detail page.** A tap-to-enlarge experiment (a `showBigArtwork` + `artwork` action on the artist row) backfired — Material strips the action on a `type=>'text'` row (`itemNoAction`) and, with the action present, stopped rendering the thumbnail at all, so the photo disappeared. Reverted to the plain `image => $img` thumbnail, so the artist photo shows again. (The thumbnail stays Material's fixed size; a genuinely larger inline image needs a skin/CSS change, not an OPML-feed tweak.)

## 0.9.21

### Added
- **Last.fm similar-artist fallback for the DSTM Radio mixer.** When ListenBrainz's similar-artists dataset has nothing for the seed (a real gap for some artists), the radio previously dropped straight to DSTM's own random play. Now, if a **Last.fm API key** is set, it tries Last.fm's `artist.getsimilar` first (`API::getSimilarArtistsLastfm`), resolves up to `LFM_FANOUT`=12 of the returned artist names to MBIDs (inline mbid used when present, else MusicBrainz lookup), and fans out from them. Only if Last.fm is also empty / no key / nothing resolves does it fall back as before (seed's own top recordings, then random; recommendations on an LB request error). Needs the seed's artist name, threaded through `_radioFromArtist` (current-track and resolved-name seeds have it; the drift seed skips it).

### Fixed (QC)
- **Bounded the MusicBrainz name→MBID lookups in the Last.fm fallback.** `_resolveArtistMbids` fired all up to `LFM_FANOUT`=12 lookups at once; against MusicBrainz's anonymous ~1 req/s limit that got the bulk throttled (503) and silently dropped on a cold cache — weakening the fallback exactly when it's first used. It now pumps them `MBID_RESOLVE_CONCURRENCY`=4 at a time (same pattern as the playlist resolver), inline-MBID entries completing without a call.
- **`USER_AGENT` version string** corrected `0.8.22` → `0.9.21` (was stale; only sent to MusicBrainz/Last.fm).
- **Artist photo now actually loads on the release detail page.** `_fetchArtistInfo` read each MAI `getArtistPhotos` item's `url` key, but MAI returns the photo URL in the **`image`** key (it builds `image => $_->{url}` internally) — so `url` was always undef and no artist photo ever appeared. Now reads `image` (with a `url` fallback for older MAI). NB: MAI matches the photo by artist **name** (it ignores the mbid for photos), so the image is name-driven even though we pass the mbid.

## 0.9.20

### Added
- **Future-week covers in All Releases.** With "Include Upcoming Releases" on, the All Releases by-week list previously showed upcoming weeks with the wrong "This Week" badge. Future weeks now get a **"Future Releases"** cover with a **Next Week** (1 week ahead), **Next Fortnight** (2 weeks), or **Further** (3+ weeks) pill — mirroring the existing This Week / Last Week / Earlier past badges. New covers `allrel-next-week`/`-next-fortnight`/`-further` (generated by `tools/make_covers.py`); `Browse::_weekBadgeImage` now maps negative week offsets to them (rounding fixed to handle future weeks). Scoped to All Releases (New Releases for You keeps its plain text week-dividers).

## 0.9.19

### Changed
- **No LB logo on the detail-page action links — text only.** Removed `image => ICON` from the **Refresh**, **Block this artist** and **View on MusicBrainz** links so they render as plain text. The streaming match rows keep their per-service logos (Qobuz/Tidal) as those indicate the source.

## 0.9.18

### Changed
- **Detail-page section order: Streaming first; MusicBrainz link last.** The **Streaming** section now sits at the top of the release detail page (above Artist and Album). The **View on MusicBrainz** link moved to the end of the Album section, after the tracklist (extracted from `_albumRows` into a new `_mbLink` helper, appended after the genre/tracklist rows).

## 0.9.17

### Changed
- **No logo on the detail-page section headers (Artist/Album/Streaming).** Those headers have nothing meaningful to drill into (the rows sit right below them), so the LB-logo thumbnail just added clutter. `_sectionHeader` gained a `$noIcon` flag, passed only by the detail-page sections; the top-level menu headers (Created for You / All Releases / Settings) keep the icon so Material's grid toggle stays enabled there. NB: header **text size** is set by Material's skin CSS for `type=>'header'` items and isn't exposed to plugins via the OPML feed — enlarging it would need a Material/skin change, not something the plugin can set per-item.

## 0.9.16

### Changed
- **Bio: ~2-line preview on the page + "Read more" drill-in to the full text.** Established that Material renders a `type=>'text'` row in full (no auto-collapse/"more" for plain text), so a full-text bio always dominated the page. The Artist Details section now shows a ~150-char preview (`BIO_PREVIEW`) followed by a **Read more** link (`PLUGIN_LBF_READ_MORE`) that drills into the complete biography (all paragraphs, no cap). A short bio still shows inline with no link. The drill page is a live coderef sub-feed (not serialised), so no caching concerns.

## 0.9.15

### Changed
- **No display cap on the bio — "more" shows the complete biography.** Dropped the 2000-char preview cap (and the now-unused `BIO_PREVIEW` constant); the bio row carries the full cleaned text. `_cleanBio`'s `BIO_MAX` raised 8000→20000 so it's purely a DoS guard and never visibly trims even a long MAI/Wikipedia bio. Material keeps the collapsed row compact and "more" expands to the whole thing.

## 0.9.14

### Changed
- **Bio row carries the whole bio so "more" expands to the full text.** 0.9.13 put only the opening paragraph in the row, so Material's "more" had nothing extra to reveal (collapsed and expanded looked identical). The row now holds the entire bio (all paragraphs), still capped at `BIO_PREVIEW` (2000) chars at a word boundary — the collapsed row stays compact and "more" reveals the full text.

## 0.9.13

### Changed
- **Bio shows the opening paragraph as plain text (no link/logo).** Replaced the 0.9.12 single-line link-with-logo treatment (which looked odd) — the bio is now a normal `type=>'text'` row in the Artist Details section showing the **opening paragraph**, capped at `BIO_PREVIEW` (2000) chars at a word boundary. Reading it is just the section's own drill-in; nothing special to tap.

## 0.9.12

### Changed
- **Bio is compact in the section, full text on click-in.** The full biography (0.9.11) dominated the Artist Details page. Now `_artistRows` shows a one-line ~200-char preview that drills in to the complete bio (split into paragraphs) when tapped; a short bio still shows inline with no drill. Keeps the section tidy while the whole bio is one tap away. (Superseded by 0.9.13.)

## 0.9.11

### Fixed
- **Artist biography is now the FULL text, not a short teaser.** Tapping "more" on the Artist Details bio revealed the same short blurb instead of the whole biography. Two causes in `API::getArtistBio`/`_cleanBio`: (1) the Last.fm path read `bio.summary` (the short teaser ending in "Read more on Last.fm") instead of `bio.content` (the full bio); (2) `_cleanBio` then hard-truncated to 600 chars, so there was nothing left for "more" to expand. Now it uses the full `content`, keeps paragraph breaks, decodes common HTML entities, strips the trailing Last.fm CC-licence boilerplate, and only caps at a high 8000-char safety ceiling. Applies to the MAI bio path too (it shares `_cleanBio`). Bio cache key bumped `lbf:bio:`→`lbf:bio:2:` so the old short cached bios re-fetch automatically.

### Added
- **Diagnostics for the missing artist photo.** `_fetchArtistInfo` now logs (INFO) whether MAI is detected (`MAI enabled=`/`bioFn=`/`photoFn=`), how many photos MAI returned, and the chosen image URL — so the no-photo case can be diagnosed from `log.txt` instead of guessed at. (MAI must be installed+enabled for any artist photo; the Last.fm fallback supplies a bio only, no photo.)

## 0.9.10

### Changed
- **Album detail page restructured into Material sections.** The flat, undivided detail list is now split under three Material accent-bar headers — **Artist Details** (artist name, an artist **photo** thumbnail + **biography** when available, Block-artist), **Album Details** (album/date/type/tags, genres, the tracklist, MusicBrainz link), and **Streaming** (the playable matches + Refresh). Reuses `Browse::_sectionHeader`; `_detailMeta` split into `_artistRows`/`_albumRows`.

### Added
- **Artist biography + photo on the detail page.** Prefers the **MAI (Music Artist Info)** plugin when installed (`Plugins::MusicArtistInfo::ArtistInfo` — bio *and* photo), falling back to a **Last.fm** bio (`API::getArtistBio` → `artist.getinfo`, needs `lastfm_api_key`) when MAI isn't present. New `Browse::_fetchArtistInfo` runs in the existing detail-page async barrier (so the watchdog still guarantees the page renders); fully guarded — no MAI and no Last.fm key just means name + Block-artist, no errors. Bio cleaned of HTML/"Read more" and truncated (~600 chars).

## 0.9.9

### Changed
- **Bigger top-ups (15 instead of 10).** `dstm_batch` default 10→15 and `ARTIST_FANOUT` 16→24 so a 15-track batch can fill with the one-track-per-artist cap. It still adds the **maximum it can** for a seed — if too few of the similar artists' tracks resolve, it appends fewer rather than padding or repeating. NB: changing the default does not move an already-saved `dstm_batch`; set the pref to 15 to apply on an existing install.
- **Seed stays on the currently-playing track.** Confirmed current-track seeding (reverted a brief tail-seeding experiment): DSTM only tops up when the queue is nearly empty, so the current track is effectively the tail — it evolves the queue forward either way, and current-track is more responsive when you skip or drop on a new album.

## 0.9.8

### Fixed
- **Qobuz matches more tracks (less falling through to Tidal / dropping tracks).** Qobuz track-matching only checked the track-level `performer` field, which is often a featured/credited name rather than the main artist — so valid Qobuz hits were rejected and resolution fell to the next service (Tidal) or, with Tidal at 0, dropped the track (the "only a few tracks added" symptom). It now matches against **all** of Qobuz's artist fields (`performer`, `artist`, `album.artist`) and tolerates response-shape differences across Qobuz plugin versions. Added INFO diagnostics: `Qobuz/Tidal track-match '<query>': N results, M matched` (raise the plugin log to INFO to see exactly where a track resolves).
- **Radio now actually reseeds when you play a new album.** Playing a new album by a very different artist still produced tracks from a previous session's genre, because a streaming seed track (no MusicBrainz ID) fell straight through to the leftover **drift seed** (`next_seed`) from the last session *before* the new album's artist name was resolved. Reordered `DSTM::radio` so the **current track always wins**: MBID → else resolve its artist name → and only if neither is available fall back to the drift seed, then recommendations. So a brand-new album reseeds the radio immediately instead of following the old neighbourhood.

## 0.9.7

### Fixed
- **Disabling a streaming service (svc_priority 0) now takes effect immediately, even for already-resolved tracks.** Live resolution already skipped a priority-0 service, but per-track results are cached for 30 days, so tracks resolved while a service was enabled kept being served from that service after it was set to 0 (e.g. Tidal tracks still appearing/queued after Tidal was disabled). `_findPlayableTrack` now re-validates a cached streaming match against the current config (`_cachedSvcUsable`): if its service is no longer enabled (priority 0) or installed, the stale entry is ignored and the track re-resolves to an enabled service (or library). Library and no-match cache entries are unaffected. NB: tracks already sitting in the current play queue aren't retro-removed — clear the queue (or let it cycle) to flush ones added before the fix.

## 0.9.6

### Added
- **Block an artist from your feeds.** A release's detail page now has a **"Block this artist"** action. Blocked artists are hidden from every feed — New Releases for You, All Releases, and the Material home shelves. There is no ListenBrainz API for this (the `fresh_releases` endpoint only takes date/sort params, and the feedback API is per-recording, not per-artist, and isn't consumed by the feed), so it's a purely local filter applied at render time in `Browse::_filterSection` — it takes effect immediately, no feed-cache clear needed. Matching hides a release if any of its `artist_mbids` is blocked **or** its normalised artist credit name matches a blocked name (the name catch covers feed rows with a different/missing MBID; the MBID catch covers credit-name variants). The blocklist is stored in the `blocked_artists` pref as `[{ mbid, name }, …]`. Various Artists is never offered for blocking (it would hide unrelated compilations). A new **Blocked Artists** settings section lists every blocked artist with an "Unblock" checkbox (tick + save to remove); the detail page shows "This artist is blocked" instead of the action when already blocked.

## 0.9.5

### Changed
- **Same artist appears less often.** `MAX_PER_ARTIST` 2→1 (at most one track per artist per top-up), `ARTIST_COOLDOWN` 16→24 (an artist waits longer before it can recur), and `ARTIST_FANOUT` 12→16 (more distinct artists per refresh, so a batch can still fill without repeating). For a seed with few streaming-findable neighbours a top-up may add fewer than `dstm_batch` tracks rather than repeat an artist.
- **No track ever repeats within a session.** Each player now keeps a permanent (until server restart) set of every track URL the radio/recommendations have queued; a track is never returned twice, and anything already sitting in the play queue is also excluded. The artist cooldown still resets for variety, but the played-track guard never does.
- **Owned copies are now used when available.** Resolution switched from streaming-first to **library-first** (`LIB_MODE` `fallback`→`first`): if you have the track in your library it plays your copy (better quality, free, instant), otherwise it streams from Qobuz/Tidal/Bandcamp. The selection is already varied, so preferring owned copies no longer hurts discovery.

## 0.9.4

### Changed
- **Deeper track variety per artist.** The radio took each artist's top 8 most-popular recordings — i.e. their greatest hits every refresh. It now samples 8 at random from the artist's top `PER_ARTIST_POOL`=40, so album cuts surface and the same famous songs don't recur. Pairs with the 0.9.3 per-artist cap/cooldown.

## 0.9.3

### Changed
- **Far fewer repeat artists in the radio.** The per-player memory only tracked played *recordings*, not *artists*, and the fan-out was narrow (6 artists × up to 15 tracks each), so the same artist clustered within a top-up and recurred across them. Now: fan-out widened to 12 artists × 8 tracks, a **cap of 2 tracks per artist per top-up** (`MAX_PER_ARTIST`), candidates **round-robin interleaved by artist** so the order alternates rather than clusters, and a per-player **artist cooldown FIFO** (`ARTIST_COOLDOWN`=16) that won't reuse an artist until others have played. Applies to both mixers (the Recommended pool keys diversity on artist name, since it has no artist MBID). New helpers `DSTM::_selectCandidates`/`_artistKey`.

## 0.9.2

### Fixed
- **Radio now follows streaming tracks (Qobuz/Tidal/…), not just MusicBrainz-tagged ones.** The seed was taken only from a track's MusicBrainz artist ID, which streaming tracks don't carry — so after a Qobuz track the radio found no seed and silently fell back to the generic recommendation pool (why it looked identical to the old propagator). Now `_seedArtist` returns the artist *name* too, and when there's no MBID the new `API::getArtistMbidByName` resolves it via MusicBrainz (strong-match only, cached) before running the similar-artists engine. Verified end-to-end: Bonobo → Boards of Canada / Massive Attack / Tycho / Air / Röyksopp.

## 0.9.1

### Fixed
- **No streaming services? The library is now used.** `_findPlayableTrack` previously bailed before the library lookup when no streaming adapters were installed, so with no streaming plugins the DSTM mixers (and the Created-for-You playlists) matched nothing — even tracks you owned. The empty-`@adapters` short-circuit was moved after the library tier: a no-streaming user now gets a **local-library** radio/recommendations (and playlists match owned tracks). No change when streaming services are present.

## 0.9.0

### Added
- **Don't Stop The Music propagators (ListenBrainz).** The plugin now registers **two** mixers with Lyrion's built-in *Don't Stop The Music* (DSTM), so when the play queue runs low it tops up from ListenBrainz. Pick one in Material → player settings → *Don't Stop The Music*. New module `DSTM.pm` (loaded by `Plugin::postinitPlugin`, mirrors `HomeExtras.pm` — **not** a separate plugin).
  - **ListenBrainz Radio (similar to what's playing)** — seeds from the artist of the track you were last playing and **evolves** as it goes, so the music flows. Reads the seed artist via DSTM's `getMixablePropertiesFromTrack`, fetches similar artists (`API::getSimilarArtists`, labs `similar-artists` dataset), fans out across a weighted-random pick of them plus their top recordings (`API::getTopRecordingsForArtist`, `/1/popularity/top-recordings-for-artist/<m>`), and reseeds each top-up toward where the music has drifted. Cold start (nothing MusicBrainz-tagged to seed from) falls back to the Recommended pool.
  - **ListenBrainz Recommended for You** — your personalised collaborative-filtering recommendations (`API::getRecommendations` → `/1/cf/recommendation/.../recording`, names filled via `API::getRecordingMetadata` → `/1/metadata/recording/`), shuffled. Cached a day; a `204` (no recs generated) degrades quietly.
- **Streaming-first resolution for the mixers** so the queue fills with *new* music instead of copies you already own. `Browse::_findPlayableTrack`/`_resolveTracks` gained a library mode — **first** (library→streaming, the playlist default), **fallback** (streaming first, library only if no service has it — what the mixers use), **never** (streaming only). Non-default modes use a separate cache-key suffix so they don't collide with the playlist feature's library-preferring cache. A per-player served-set keeps successive top-ups varied.
- New prefs `dstm_count` (Recommended pool size, default 100) and `dstm_batch` (tracks added per top-up, default 10); reuses `svc_priority_*`.

  Note: ListenBrainz's cf-recommendation `artist_type` (similar/raw/top) is currently **ignored by the live API** (all three return the same list), which is why there's one Recommended mixer rather than three.

## 0.8.24

### Changed
- **Settings section headers now match the rest of the plugin.** The four settings sections (General / Streaming Services / For You / All Releases) used raw `<h2>` tags, which Material Skin doesn't theme, so they looked out of place. Each is now a proper Material settings section: a `prefHead collapsableSection` header (`id="lbf_<section>_Header"`) with the section's settings wrapped in a matching `<div id="lbf_<section>">` panel. Material renders these as its themed bold accent-bar headers — consistent with the section dividers on the browse pages — and they collapse/expand like the native LMS settings sections (a bare `prefHead` only gets Material's faint per-setting label style, so the panel + `_Header` id is what makes the accent header and the expander appear).

## 0.8.22

### Internal
- Removed 6 unused localisation strings left over from earlier features (`PLUGIN_LBF_FORYOU_ALBUMS`/`_DESC`, `PLUGIN_LBF_PLAYLISTS_DESC`, `PLUGIN_LBF_PL_TRACKS`, `PLUGIN_LBF_SEC_TYPES`, `PLUGIN_LBF_WEEK_OF`). No user-visible change.

## 0.8.21

### Fixed
- **Playlist dates now use local time, not UTC.** ListenBrainz sends a playlist's `last_modified` as a UTC instant; the "W/C …" and Daily-Jams date labels derived from it now convert that to the server's local calendar date, so they match the user's day instead of being a day (or week) off near midnight — notably in the UK during BST. The week helpers were also moved from `timegm`/`gmtime` to `timelocal`/`localtime` so the whole date path is consistently local (behaviour-preserving for the date-only release feed; `timegm` is now used only where the input is explicitly UTC).

## 0.8.20

### Added
- **Inline check for the Last.fm API key**, matching the ListenBrainz token check. The settings page validates the key client-side against Last.fm's `auth.getToken` (Last.fm allows CORS) and shows the result inline next to the field — on page open (if a key is set), on field blur, and via a "Check key" button. Green = valid, red = rejected, amber = couldn't reach Last.fm; an empty key shows a neutral "optional" note.

## 0.8.19

### Fixed
- **A partial settings save can no longer disable a streaming service.** The service-priority handler used to force any missing `svc_priority_*` field to 0 (= never search). On a normal full-form save every field is present so this was harmless, but an incomplete/non-form POST would silently zero the priorities. It now keeps the current saved value when a field is absent, so priorities are only changed when actually submitted.

## 0.8.18

### Fixed
- **Token validation result is now actually visible in Material Skin.** 0.8.17 validated the token on save and returned the result via LMS's `warning` field, but Material loads plugin settings in an iframe and never surfaces that field, so the message was invisible (it worked only in the classic web UI). The settings page now also checks the token **client-side** — directly from the browser against `/1/validate-token` (ListenBrainz allows CORS) — and shows the result inline next to the token field: on page open (if a token is set), when the field loses focus, and via a "Check token" button. Green = valid (with your username), red = rejected, amber = couldn't reach ListenBrainz. The server-side on-save validation from 0.8.17 is kept for the classic skin.

## 0.8.17

### Added
- **The ListenBrainz token is now validated on save.** Saving the settings with a token set checks it against `/1/validate-token` and shows the result on the page — success (with your username), a rejection message if the token is wrong, or a "couldn't reach ListenBrainz" note if the check itself failed (the settings are still saved). Previously a wrong token failed silently with no feedback. (Wires up the existing, previously-unused `API::validateToken`.)

## 0.8.16

### Fixed
- **Settings validation is no longer bypassed.** The Days window (1–90) and the streaming-service priorities (0–9) are now clamped into the submitted form values *before* the base settings handler stores them. Previously the handler set the clamped pref and then the base class immediately re-set it from the raw posted value, so an out-of-range or non-numeric `days` / priority could be persisted from a crafted or non-browser POST.
- **A bad HTTP 200 from ListenBrainz no longer blanks the feed for a day.** If a feed response parsed as JSON but had an unexpected shape (or didn't parse at all), the empty result was cached under both the working (24h) and fallback (30d) keys, blanking the menu/home rows until it expired. Such responses are now treated like a transport error: the last good cached copy is served and nothing is overwritten.

### Internal
- Default log level lowered to WARN (was INFO) so production `server.log` isn't filled with per-request response/cache lines; raise it via Settings → Logging when diagnosing.
- The release-detail cache write is now `eval`-guarded like every other cache write, and the unused genre parse on the recordings-only release lookup was removed (genres come from the release-group path).

## 0.8.15

### Fixed
- **Playlists tile no longer disappears.** 0.8.14 left the Playlists menu row with an empty name until the covered-date span had been fetched, and Material drops a row with no title — so the tile vanished. It now always shows a date span: the real one once the playlist list is known, otherwise a synchronously-computed fallback (last week's Monday → today, matching how New Releases for You / All Releases compute theirs), so the row is always present.

## 0.8.14

### Changed
- **Playlist tiles drop the repeated title.** The branded cover already shows the playlist name, so the row's first line is now the period it covers — `W/C 8 June 2026` for the weekly playlists, or the day for Daily Jams — with the match count (`47 of 50 tracks matched`) on the line beneath it (was: title on line 1, date + count combined on line 2).
- **Playlists menu tile drops the repeated "Playlists" text.** The main-page Playlists row now shows the date span the playlists inside cover (earliest week-commencing / day → today) instead of the word "Playlists" (which is already on the thumbnail); no text until that span is known (after the first playlist-list fetch / background warm).

## 0.8.13

### Changed
- **Top-level tiles show dates + counts, not a repeated title.** The New Releases for You and All Releases rows no longer repeat their title as text under the thumbnail (it's already on the branded cover). Instead the subtitle is the date span actually being viewed — the real earliest/latest release date of the loaded feed, or the window implied by the *Days window* / past / future settings before it loads — plus the release count (e.g. `8 – 20 June 2026` · `42 releases`). Updates automatically when the *Days window* changes. Counts/spans are stashed by the feed builders (`_stashSummary`) so the tiles render instantly without an extra fetch.
- **All Releases Material home shelf now shows the flattened first level** — the "All releases" entry plus the weeks available (This/Last/Earlier) — rather than drilling into the full (large) release list, so the carousel is a jump-off into a section. (The shelf is a small fixed list, so it stays drill-stable at any request quantity.)
- **Simplified row text.** All Releases week rows now read `W/C 8 June 2026` (Week Commencing; the count is dropped). Playlist tiles now read `W/C 8 June 2026 · 47 of 50 tracks matched` for the weekly playlists (or the day itself for Daily Jams), derived from the playlist's generation date; the match count comes from the pre-resolved cache. Dates use full month names, no abbreviations.

### Fixed
- **Playlist cover pills now align.** The This Week / Last Week pill sits at a fixed vertical position regardless of whether the title is one line (Weekly Jams) or two (Weekly Exploration) — the title block is centred in the area above the pill, and the pill + LISTENBRAINZ wordmark no longer shift.

### Internal
- **All branded cover/badge images are now generated by one committed script, `tools/make_covers.py`** (previously only ad-hoc), covering the menu tiles, playlist tiles and All Releases week badges from one shared design system — so the set is reproducible and consistent if it ever needs changing. Documented in CLAUDE.md.

## 0.8.12

### Added
- **Material home shelves for Playlists and All Releases** — alongside the existing New Releases for You shelf, the Material home page now has scrollable rows for your Created-for-You Playlists and for All Releases. Each is a flat, playable card row.

## 0.8.11

### Changed
- **All Releases week rows now use the playlist-style cover** with a relative-week badge (This Week / Last Week / Earlier). The exact date remains in the row label (literal dates can't be drawn onto the image without a server-side image library, so the badge is relative).

## 0.8.10

### Changed
- **Polished icons inside All Releases** — the "All releases" entry and each per-week row now use the branded All Releases cover instead of the plain plugin icon, matching the main page and Playlists.
- **Refresh row uses a Material refresh icon** (circular arrow) instead of the plugin icon.

## 0.8.9

### Changed
- **Feeds now refresh once a day** (was every 6 hours) — New Releases for You and All Releases. Less API traffic; the data only changes ~daily anyway.

### Added
- **Manual "Refresh" row** at the top of New Releases for You and All Releases — forces an immediate update (clears that feed's cache and reloads) when you don't want to wait for the daily refresh.

## 0.8.8

### Fixed
- **Local-library matching now actually applies** — playlists resolved before the library feature existed were cached (streaming-only) and kept being served, so local files were never substituted. The track and resolved-playlist caches are versioned so they re-resolve once, now checking your library first.

## 0.8.7

### Added
- **Prefer tracks from your own library** — when building a playlist, the plugin now checks your local LMS library first (by MusicBrainz ID, then artist + title) and uses your own copy if you have it, before searching streaming services. Faster, free, and uses your preferred quality. New setting **Prefer Tracks from My Library** (default on).

## 0.8.6

### Changed
- **Top-level menu reorganised with Material section headers** — the plugin menu is now grouped under **Created for You** (New Releases for You + Playlists), **All Releases**, and **Settings**.
- **Branded menu artwork** — New Releases for You, Playlists and All Releases use cover-style images matching the playlist look; Plugin Settings uses a Material cog.
- **Weekly cover badge aligned** — the This Week/Last Week pill now sits at the same position on the one-line (Weekly Jams) and two-line (Weekly Exploration) covers.

## 0.8.5

### Changed
- **Weekly playlist covers now show the week** — the two Weekly Jams (and two Weekly Exploration) playlists no longer look identical: the current week shows a "This Week" badge and the previous week a "Last Week" badge on the cover. (The exact date stays in the row title.)

## 0.8.4

### Changed
- **Playlist covers are now per-category artwork** — since a true 2×2 track-art grid can only be stitched with a server-side image library (GD/Imager/ImageMagick), none of which are present and which we won't require (cross-platform, no installs), each playlist now shows a clean bundled cover for its category (Weekly Jams / Weekly Exploration / Daily Jams / generic). These are instant and stable — no more single-cover redirect or the artwork vanishing/repopulating when you return to the list. The dynamic grid compositor was removed.

## 0.8.3

### Added
- **Background pre-caching (warm)** — shortly after startup and then once a day, the plugin pre-fetches the playlist list, pre-resolves every playlist's streaming matches, and pre-builds the grid covers. Opening the Playlists view and any individual playlist is now **instant** (no waiting for ~50 tracks to match on open), and the tile artwork is already cached so it no longer **vanishes/repopulates** when you return to the list. The daily run is cheap — it only does real work when a new week's playlist appears.
- **Grid compositing fallback to ImageMagick** — if Perl GD/Imager aren't installed, the 2×2 cover is now built via the `montage` binary (ImageMagick is commonly present), so the tiled grid can render with no Perl-module install. (Still falls back to a single cover if none of GD/Imager/ImageMagick is available.)

## 0.8.2

### Changed
- **Playlist rows are now playable containers** — each playlist in the Playlists list carries Play / Add actions (queue the whole resolved playlist) as well as tapping to open it, like a native playlist row.
- **Grid covers need an image library** — the 2×2 tiled cover is composited server-side and requires Perl **GD** (or **Imager**), which this LMS build doesn't include. Install one (Debian: `sudo apt-get install -y libgd-perl`) to get the tiled grid; without it, the tile falls back to a single cover.

## 0.8.1

### Fixed
- **Playlists now play like a playlist** — the resolved track list is a clean list of playable tracks only, so the standard Play / Play-all option is available. The "N of M matched" line (an unplayable row that was suppressing play-all) is gone; the match count is shown in the page title instead.
- **Playlist grid covers now render** — the cover route is registered with the current LMS API and its request path is matched correctly (leading-slash fix), and the image response now sends headers. Playlist thumbnails show the 2×2 grid (or fall back to a single cover).

## 0.8.0

### Added
- **Playlists section — your ListenBrainz "Created for You" playlists, as streaming playlists.** A new **Playlists** entry lists the algorithmic playlists ListenBrainz builds for you (Weekly Jams, Weekly Exploration, Daily Jams, …). Opening one matches **every track** to a playable version on your streaming services (in your configured priority order), drops any track that can't be matched, and presents the result as a fully-streaming playlist you can **Play all**. A *"N of M tracks matched"* line shows how many resolved. Each playlist shows a **2×2 grid cover** stitched from its tracks' artwork (Qobuz/Spotify style). (Track matching currently resolves on Qobuz; Tidal/Bandcamp track support is scaffolded and finished once their track APIs are confirmed on the server.)
- **Caching tuned to the weekly update cadence** — these playlists only regenerate weekly (and ListenBrainz keeps the current *and* previous week), so a resolved playlist is cached for 30 days instead of being re-matched daily. Reopening a playlist — including last week's — is instant rather than re-running ~50 streaming searches each time. The playlist *list* refreshes once a day (enough to catch Monday's new playlists) instead of every few hours.

## 0.7.2

### Added
- **All Releases → by-week landing page** — tapping **All Releases** now opens a menu instead of dropping straight into the full list. The first entry, **All releases**, shows the complete list as before; below it is one entry per week-commencing (newest first, e.g. *Week of 16 Jun 2026  (42)*) that drills into just that week's releases. Lets you narrow the feed to a single week without scrolling the whole thing.

## 0.7.1

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
