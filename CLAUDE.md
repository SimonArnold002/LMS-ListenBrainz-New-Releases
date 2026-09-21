# ListenBrainz Fresh Releases — LMS Plugin

## Project Overview
A plugin for Lyrion Music Server (LMS) that browses ListenBrainz Fresh Releases. It provides a personalised "For You" feed and a global "All Releases" feed. Filtering is controlled via settings, and the browse menu stays intentionally simple. The current build targets LMS v9.x and has been tested with Material Skin.

## Cache priority refactor — working tree, 2026-09-08

Current user direction: artwork and core cached data first; **only Last.fm** genre
retrieval moves behind core work. ListenBrainz metadata stays early. This supersedes
the historical rationale for running the Last.fm tail alongside playlist/follower
processing. The first patch separates the two feeds' ListenBrainz passes from the
Last.fm tails and gates all Last.fm warm/top-up calls on core work, cover work and
browse activity. See [cache-priority-refactor.md](docs/cache-priority-refactor.md)
for implementation, recovery limits, tests and outstanding live scheduling work.
**As of 0.9.218 (0.9.216 plus two rounds of review fixes; carried unchanged into 0.9.219) the fixed overnight clock is PARTLY BUILT** — §4A (a fixed 05:00 local
tick), §4B (the startup gate) and §4F (the store re-seed) are in; §4C-§4E are not, and
§4G is DECLINED (2026-09-14 — the MusicBrainz sort-name was dropped). See `docs/scheduled-overnight-warm.md`.

## Per-section release window — 0.9.215, built 2026-09-14 (carried into 0.9.216-0.9.218; installed as part of 0.9.217, 2026-09-14)

**The release window is now two number boxes per section, and the current week is week 1.**
`<section>_weeks` (total shown, 1-4) + `<section>_upcoming` (how many are ahead, 0..weeks-1),
for `foryou` and `all` independently. It replaces seven controls — `weeks_past`, `weeks_future`
and the `foryou_past`/`foryou_future`/`all_past`/`all_future`/`muspy_future` gates — none of which
are migrated (they stop being read; only the four gates and `days` were ever on `main`).
Defaults are `2`/`1` for BOTH sections — this week + next week (Simon, 2026-09-15; it was For You
`4`/`2`, All Releases `2`/`0`, reproducing 0.9.185). Not migrated, so every user updating from
`main` lands on `2`/`1`; an install that already stored the dev values keeps them (`$prefs->init`).

**MuSpy has no window of its own** — Simon's call: it must never show past four weeks and must
roll over like the LB feed. `_mergeMuSpy` windows on `sectionWindow('foryou')`, the `'muspy'`
prefix and `%WEEK_GATES` are gone, `_sectionBounds` unions nothing (0.9.207's union is moot, not
reverted), and the nightly MuSpy warm prepares only the rows inside the window.

Read `docs/week-based-release-window.md` "As changed" before touching any of it. Guards:
`t_weekwindow.pl` (71, incl. §8 which RUNS `Settings::handler`), `t_detailwarm.pl` §8; both
anti-tested. Built and versioned as 0.9.215; not yet installed.

## MusicBrainz 503s — built 0.9.219, 2026-09-14 (review CLOSED, pushed to dev; installed 2026-09-14; no refusals live 2026-09-15)

**Diagnosed on the rig from `log.txt`:** ~80 MusicBrainz 503s in ten minutes after the 06:31
restart, smaller bursts after every restart. MusicBrainz refuses EVERY request from an IP whose
average rate is over ~1/s, and five LBF paths called it with no shared pacing — the Trending album
search (unpaced, no backoff) the worst. The server was NOT being refused when idle. Three changes,
all decided by Simon the same day — Ledger §A2 `ONE MUSICBRAINZ QUEUE, ONE COMMUNITY-API QUEUE`:
1. **`API::_mbGet` is the one MusicBrainz queue** (one in flight, `MB_GAP` 1.1s between sends, the
   shared 503 backoff); **`_hostedGet` is a one-in-flight queue** (MAI's own precedent). Diag's MB
   probes go through the MB queue and report a backoff instead of timing out.
2. **Trending's album search uses the community API only** — no MusicBrainz leg; collaborations
   are split on the community API instead.
3. **Tracklists come from ListenBrainz by release group** (`API::getTracklist` / `peekTracklist`),
   MusicBrainz for the exact release only when ListenBrainz has none. ~1 album in 10 may show
   another edition's track list — accepted.
Guards: new `tools/t_mbqueue.pl` (67), `t_rgresolver.pl` §5/5b, `t_diag.pl` §9, `t_detailflight.pl`,
`t_detailwarm.pl`, `t_genrefill.pl` §11B/§13 re-pointed. 35 suites exit 0; 11 anti-test mutants each
red. The artist sort was decided later the same day — next section.

## Artist sort A–Z, radio lookup, streaming aliases — built 0.9.219, 2026-09-14 (review CLOSED, pushed to dev; installed 2026-09-14)

Three more changes, all Simon's call the same day — Ledger §A2 `ARTIST SORT IS A–Z ON THE DISPLAY
NAME` and `STREAMING ALIAS PASS`:
1. **The Artist sort is A–Z on the display name**, a leading article skipped with LMS's own
   `ignoredarticles` list (`Slim::Utils::Text::ignoreArticles`). Gone: the MusicBrainz sort-name warm
   (`warmArtistSorts`, `peekArtistSort(s)`, `SORT_*`), the store API (`artistSortGet/Put`,
   `importSorts`), the `artist_sorts` stat and the `sort_name`/`sort_src`/`sort_at` columns. MuSpy's
   inline `sort_name` is ignored. No migration — `main` ships no `DB.pm`. §4G is DECLINED.
2. **The radio's name → MBID lookup is community API only** (`getArtistMbidByName` → new
   `getArtistAliases`, `/artist/<name>/aliases`), accepted on the canonical name OR an alias.
   `lbf:artistmbid:` retired, `lbf:aliases:` 1 added.
3. **A streaming album miss retries the artist's other names** — `_albumMatchesAlt` (joint-credit
   parts, then aliases) at all five album adapters; `_findPlayable` runs ONE alias pass on a clean
   miss. Outside the shared matcher; no `lbf:stream:` bump.
Guards: new `tools/t_aliasmatch.pl` (61), `t_orderfreeze.pl` rewritten (32; §9 is the sort key),
`t_db.pl` (250), `t_genrefill.pl` §5/§13, `t_detailflight.pl`, `t_review_fixes.pl`, `bench_walk.pl`,
`t_diag.pl` §6 (79 — the community-API probe is on `/aliases` and its amber note no longer promises a
MusicBrainz fallback). 36 suites exit 0, both sync checks 0; 11 mutants each red, plus 2 on the Diag
row. **UNPROVEN LIVE.**

## Round of 2026-09-15 — built 0.9.220, 2026-09-15 (NOT installed, NOT reviewed)

Four changes on top of 0.9.219, all Simon's call the same day:
1. **Week window defaults are `2`/`1` for BOTH sections** — this week + next week (`API::%WEEK_PREFS`,
   `Plugin.pm` `$prefs->init`). Not migrated, so every user updating from `main` lands on them.
   Guard: `t_weekwindow.pl` §5 (71).
2. **Diag's MusicBrainz probes join the FRONT of the one MusicBrainz queue** — `API::_mbGet(...,
   front => 1)`: ahead of ordinary jobs, FIFO among front jobs, and still behind the request in
   flight, `MB_GAP` and the 503 backoff. Simon asked whether other queries should be PAUSED during
   the check; front-of-queue was chosen because the queue already makes an overlap unable to cause
   a 503, so the only cost is waiting. A queued probe the 12s deadline catches UNSENT now reads
   `warn` / "not probed", never `fail` / "timed out" (it was seen live 2026-09-14: `mb_search`
   "0 ms, timed out" behind an 11s identity probe). Guards: `t_mbqueue.pl` §4b, `t_diag.pl` §10;
   six mutants, each red.
3. **`PLUGIN_LBF_DIAG_DESC`** names ListenBrainz Labs, the MusicBrainz search index and the
   LMS-community API.
4. **README.md / README.html** rewritten for the current settings page (Simon asked for it before the
   main merge). `tools/make_readme_html.py` keeps only the FIRST intro paragraph (for the page
   header), gives anchors to H2 sections only, and ends a numbered list at an indented follow-on
   line — so keep the intro to one paragraph, link only to H2s, and keep each step on one line.

**Live checks of 0.9.219 on 2026-09-15:** Artist sort A–Z PROVEN (132 releases, 0 out of order,
all nine "The …" artists filed under the next word; sort and paging restored afterwards). No
MusicBrainz refusal in the whole log since its midnight rotation (10,735 lines; the refusal line is
WARN) and 175 detail fetches / 0 failed after the 08:09 restart. **SETTLED: the 05:00 overnight warm ran
on 0.9.219 inside that log.** Proof: after the 08:09 restart (build unchanged) `warmstats` showed
`ticks=0`, and `_armWarm` arms a catch-up tick at boot+`WARM_DELAY` whenever `warm_last_at` is older
than `_lastWarmInstant` (05:00 today) — so `warm_last_at` was already past 05:00. A full warm plus the
post-restart detail work, zero refusals. Waiting for another 05:00 warm adds nothing: it is the same
traffic. The one thing not measured is HOW MANY of those requests reached MusicBrainz. Radio lookup and the streaming alias pass remain UNPROVEN
LIVE: their only traces are INFO lines and the plugin does not log at INFO on the rig.

## Spotify back-off — built 1.0.1, review fixes built 1.0.2 and INSTALLED 2026-09-16; second review's fix built 1.0.3 and INSTALLED 2026-09-16; third review's three fixes built 1.0.4 + 1.0.5, 1.0.5 INSTALLED 2026-09-16

**Full working, measurements and the live evidence: `docs/spotify-rate-limits.md`.** The
adapter-level rule went into the canonical `docs/streaming-adapter-spec.md` (§6) and was
re-copied to PFR and LL in the same session, per that file's own rule — all three checksums
agree. (2026-09-16: §4 gained the handshake-carrier and playback-title notes, re-copied the same
way; later that day §4 was updated for LL's Spotify release-id Played door and display title (and §8's `_backfillStreamingArtist` condition), sha1 `b3597f82…`. **Later still, after the third back-off review, §6's rate-limit rules gained three points — tag the refusal on the answer, every search loop checks the back-off itself (LBF has THREE consumers, not the "two" §6 used to list), and a refusal can answer SYNCHRONOUSLY — and its pointer to `docs/spotify-rate-limits.md` now says that file lives in LBF only; §7 gained the matching line. Re-copied to PFR and LL; sha1 now `504f722a…` in all three.** **Then, with the PFR port (0.9.39), §6 named PFR's implementation — the 6th `_svcCantAnswer` argument, `_refused` forwarded by the review wrappers and to joined callers, ONE consumer (home shelves resolve on request) — and gained "keep the gap to ONE wakeup, re-armed". Re-copied; sha1 `f43421aa…` in all three.** **Then, the same day, every `Browse.pm:NNNN` / `Settings.pm:NN` / `Sources.pm:NN` line reference was replaced by the sub or variable it points at (they had drifted — e.g. LBF's adapter table cited at 5688, now ~7069), §8's sites re-checked against current code, and §3's reference shape gained LBF's optional `ready` probe. Re-copied; sha1 `fccba6c4…` in all three.**)

**Spotify rate-limits a warm, and the limit is not this server's alone.** Spotify's Web API
counts calls per APP over a rolling 30-second window
(developer.spotify.com/documentation/web-api/concepts/rate-limits), and Spotty ships ONE
built-in Client ID that every install shares unless the user sets their own. Over the limit
Spotify answers **429 with a Retry-After** and Spotty sets `spotty_rate_limit_exceeded` for
that long, then refuses **every** call server-wide before sending anything — the user's own
Spotify browsing included. **MEASURED on plex, 2026-09-15: 20 `error429` lines (Retry-After
2-7s) and 191 `502 Bad Gateway`s in one day's log, all on `api.spotify.com/v1/search`.**
Spotty IS installed on the rig; any doc here still saying otherwise is stale.

**The sibling Pitchfork plugin already fixed its half** (PFR 0.9.35-0.9.38, feature closed
2026-09-15). This is LBF's, and it is NOT a copy — LBF has a retry budget PFR does not.

1. **The adapters stamp a refusal.** `_searchSpotify` / `_searchSpotifyTrack`: an EMPTY answer
   while `Plugins::Spotty::API::hasError429` is set records `$SPOTIFY_REFUSED_AT`. The OUTCOME
   is unchanged — `_emptyResultIsError` already called every empty answer inconclusive — so
   no TTL moves; what the stamp adds is that the warm can SEE it. A list with results in it is
   an answer whatever the flag says.
2. **The warm narrows and waits; a view never does.** `_resolveTracks` takes `paced => 1`. **Three
   warm resolves pass it** — the playlist warm (`paced => 1`), and `_resolveFollow` /
   `_resolveTrending` (`paced => $warm`, since 1.0.3); the view paths do not. **`$warm` is read at
   ENTRY (`!$callback`)**, because both subs detach `$callback` on a view's cold build before the
   resolve — a test of `$callback` at the call would pace the view too: while backing off it runs ONE resolve at a
   time with `PACED_TRACK_GAP`(2s) after each LIVE one, then returns to full width.
   `SPOTIFY_BACKOFF_WINDOW` is 30s. The width is read FRESH on every pump (the rule
   `_coverLimit` already follows), so a refusal mid-pass bites at the next slot. A cache hit
   answers synchronously and is never slowed — and, since the 2026-09-16 review, arms nothing:
   `$pumping` guards re-entry, and `$gapTimer` is ONE wakeup re-armed by each live completion.
   **THREE PUMPS TOUCH SPOTIFY, NOT TWO** (corrected in 1.0.4 — this entry said "the album side is
   `_detailPriorityBusy`", and that sentence hid a pump for two rounds): `_resolveTracks`'s
   `paced` option; `_detailPriorityBusy`, which is the **DetailWarm queue's `pause` hook and
   nothing else consults it**; and **`_buildAlbumsData`'s trending-albums streaming gate**, paced
   since 1.0.4 off `$warm` (`ref $onPending eq 'CODE' ? 0 : 1`, read at entry). A fourth pump
   would need its own read of `_spotifyBackingOff` — nothing inherits the back-off.
   **A SYNCHRONOUS REFUSAL HOLDS THE PUMP (1.0.5).** Spotty refuses in the same call stack, so on
   libMode `never` a Spotify-only refusal looked like a cache hit and the pass ran straight
   through the lockout. The resolvers now say so (`_findPlayableTrack` 4th arg, `_refused` on
   `_findPlayable`'s result); both pumps arm the gap on it and stop launching via `$holding`.
   **ALWAYS-ON PACING IS NOT ON THE TABLE** — PFR built it, Simon rejected it as far too slow
   (its 0.9.36), and it is not proposed here either.
3. **OUR OWN CLOCK, not Spotty's flag** — `hasError429` clears on the next SUCCESSFUL response,
   and at Spotify's default priority 5 that can be many albums away.
4. **A REFUSED SEARCH DOES NOT SPEND A RETRY ATTEMPT (`SPOTIFY_FREE_PASSES`, 3).** This is the
   part PFR has no equivalent of and the reason this is not a straight port. A refusal is a
   search that was NEVER SENT, so counting it against `MISS_RETRY_SCHEDULE` retires a track the
   service actually carries — and for a **Spotify-ONLY user** every attempt during a storm is a
   refusal, so that is the ordinary case, not an edge. The attempt is given back at the SAME
   rung, in both the track and album paths, and **capped at three**. **The pass keys on THAT
   search's refusal** — the adapters answer `$collect->(undef, 'refused')` and each resolver counts
   the tag into `$refused` — never on `_spotifyBackingOff()` (the first build did, and gave the pass
   to every inconclusive miss inside the 30s window; fixed in the review). Capped at three: past the cap a refusal
   spends a real attempt like any other, so the miss still converges. Simon's call, 2026-09-16;
   uncapped was offered and declined for the loop it reopens.

**No cache bump, and it is checked rather than assumed:** no stored shape changes (`free` is a
new optional key on an entry that is re-written on the next attempt either way), no TTL moves,
and the whole change is observable against a warm store the moment Spotify 429s. **No matcher
change** — `matcher_sync_check.py` exits 0.

**Tests: `tools/t_spotifybackoff.pl` (new, 37 assertions); 37 suites green, 1,702 assertions.**
Sub bodies lifted verbatim, driven over a fake clock with no LMS and no Spotty. **Anti-tested
five ways, each failing ONLY its own checks:** the stamp removed 1; the paced width ignored 4;
the gap removed 2; the free passes uncapped 2 (including the convergence assertion); the free
passes removed entirely 7; the detail-warm pause removed 1.
**Harness traps worth keeping** (both cost a debugging pass): a `use constant X => $lifted`
inside a package block resolves at COMPILE time, when the lifted value is still undef, so the
constant becomes undef and every comparison against it is quietly false; and SingleFlight pulls
in the REAL `Time::HiRes`, which overwrites a `sub time` compiled into that package earlier —
leaving the paced gap measured against the wall clock, where it never comes due.

**KNOWN AND DELIBERATELY NOT DONE: PFR's `empty_unverified` is NOT ported.** When a
higher-priority Spotify is refused and a LOWER service matches, that match is still cached at
the full `STREAM_FOUND_TTL`(7d) / `TRACK_FOUND_TTL`(30d) — PFR measured this live (17 rows
pinned to Qobuz) and capped it at a day. It only bites when Spotify is ranked ABOVE another
service; LBF's default is `svc_priority_spotify => 5`, LAST, where nothing can win beneath it.
Simon, 2026-09-16: "for me it's not a problem" — his rig leaves Spotify last, and the users this
work is for have Spotify ONLY, where there is no lower service to pin. **Re-raise only with a
user who ranks Spotify above another service**, not as a symmetry argument with PFR.

**THIRD REVIEW OF 2026-09-16 (the 1.0.3 tree) — three findings, all fixed; built as 1.0.4 (finding 1)
and 1.0.5 (findings 2 and 3), committed on `dev` as `7e5bf4e`, `189ee58` and `199b6b9`; a fourth
review of those builds found NOTHING (§C `CLOSED IN THE 1.0.5 REVIEW —`). ROUND CLOSED BY SIMON AND
PUSHED TO `dev`, 2026-09-16. 1.0.5 INSTALLED 2026-09-16, not yet seen refusing live (Ledger §C `CLOSED IN THE 1.0.3 REVIEW —`, which carries
the mechanisms, anti-tests and both build notes).** (1) The trending-albums streaming gate is a THIRD Spotify pump and was unpaced — now
paced off `$onPending`, with the re-entrancy guard ported. (2) A pass that outlived its in-flight
flag could release the NEXT pass's flag — the flag is now a token. (3) A synchronous Spotify refusal
looked like a cache hit and skipped the gap — the resolvers now signal it and both pumps hold on it.
**CURRENT BUILD: 1.0.5 (rebuilt once, same version)**, `repo.xml <sha>`
`9659e0fd21f60bcd041f83dde1287db905574995`, 54 entries, 710,605 bytes, caches preserved; the zip
diffs identical to the tree. `t_spotifybackoff.pl` 62 -> **100**, `t_buildingstate.pl` 77 ->
**87**; all 37 suites exit 0.

**REVIEW OF 2026-09-16 — two findings, both fixed; round CLOSED by Simon (Ledger §C `CLOSED IN THE 1.0.1 REVIEW —`).** (1) Cached
tracks each armed a paced timer, so strays launched live searches back to back — `$pumping` +
the single re-armed `$gapTimer` in `_resolveTracks`. (2) The free pass keyed on the window, not on
the refusal — the `'refused'` tag above. `t_spotifybackoff.pl` 37 -> **57**; all 37 suites exit 0,
both sync checks 0. Mechanism and anti-test counts: `docs/spotify-rate-limits.md` §4.3/§4.4/§6.
**SECOND REVIEW OF 2026-09-16 (the 1.0.2 tree) — one finding, fixed, built as 1.0.3, INSTALLED 2026-09-16
(Ledger §C `CLOSED IN THE 1.0.2 REVIEW —`).** The follow-feed and trending warms resolved unpaced, so
they kept pushing at full width through a refusal — trending is the widest resolve in the plugin
(80 candidates at width 10). Both now pass `paced => $warm`. `t_spotifybackoff.pl` 57 -> **62** (§4b).
**BUILT AS 1.0.3, 2026-09-16; INSTALLED the same day** (log 13:46:14 `Build changed (1.0.2 -> 1.0.3): derived cache KEPT`, no LBF errors after it). `install.xml` / `repo.xml` 1.0.3, zip rebuilt (54
entries, 707,021 bytes), `repo.xml <sha>` `2ee4780e2223f04ef864c89020df884d90a9685c`; the unzipped
archive diffs identical to the tree, carries `paced => $warm` at both sites, and `t_loads.pl` passes
20/20 against it. `DEV_BUILD` 0, `RESET_CACHE_ON_BUILD` 0, no key version bumped — caches preserved.
`README.html`/`index.html` regenerated; `CHANGELOG.md` untouched (merge to main).

**BUILT AS 1.0.2, 2026-09-16; INSTALLED the same day** (`plugin_version` 1.0.2, log `Build changed (1.0.1 -> 1.0.2): derived cache KEPT`). `install.xml` / `repo.xml` 1.0.2, zip rebuilt
(54 entries), `repo.xml <sha>` `d2d36cb748c7a733c0f4059b6082e44ad3c4d4e9`; the unzipped archive
diffs identical to the tree, and `t_loads.pl` passes 20/20 against the extracted zip.
`DEV_BUILD` 0, `RESET_CACHE_ON_BUILD` 0 — caches preserved. The 1.0.1 figures below are history.

**BUILT AND PACKAGED at 1.0.1.** `install.xml` and `repo.xml` both say 1.0.1; the zip is rebuilt
(54 files, 706,232 bytes) and `repo.xml <sha>` recomputed to
`fbf6522e392b7d8141113b3d2e3e7e90bd84e3a3`. Verified against the zip on disk rather than assumed:
`diff -r` of the unzipped archive against the tree is identical, its `Browse.pm` carries the
back-off and its `install.xml` reads 1.0.1. `README.html`/`index.html` regenerated so the version
badge (read live from `install.xml`) is not left lying. **`CHANGELOG.md` deliberately untouched** —
that is written at the merge to main, where the user-facing line belongs.

**INSTALLED (as 1.0.5, 2026-09-16), NOT VERIFIED LIVE.** What to look for: Spotty's `error429` lines
should be followed by LBF's `Spotify search refused (Spotify is rate-limiting)` and a visibly
slower warm for ~30s, then recovery; and a track missed during a storm should carry `free` rather
than a spent attempt. Read the log as `log.txt?lines=20000` — the bare `log.txt` returns a tiny
window. To provoke a storm: set every other service's priority to 0 and force a cold re-resolve.

## Cover re-walk memo — 1.0.15, 2026-09-21 (INSTALLED + VERIFIED LIVE, reviewed twice, pushed to dev d7f39d4)

**The report (Monday 2026-09-21, the week rollover):** views appeared to rebuild, a red Material
error on a sort change, players vanished — "it is loading the entire cache". With `debug_log` on,
the one LBF behaviour that matched was **`_warmCovers` re-queuing EVERY release on EVERY walk**:
`covers — all releases queued 322 release(s) of 322` five times in six seconds on a Show-all W/C
14 Sep week, each re-reading all 966 `lbf:imgwarm:` markers. Nothing was downloaded (stage note
`0 request(s) … 966 already warm`); the re-asking was the waste.

**The fix (`Browse.pm`):** `%coverWarm`, keyed by the full marker KEY (so a `lbf:imgwarm:` family
bump misses it like the store does), filled only on evidence — a marker read that answers
(`_coverLaunch`) or a completed download — never on a failure. `_coverGroupsFor` and the focus
loop in `_warmCovers` skip known-warm keys via `_coverKnownWarm` (a hash lookup, so the builder
stays allocation-only). `COVER_WARM_MEMO` = 1 day, and it MUST stay inside the proxy-vs-marker
gap (30d − `COVER_WARM_TTL` 25d = 5d): a marker answering at t guarantees the rendition until
t+5d. Hourly sweep in `_coverNoteWarm`. The runtime `wipeDerived` only runs at startup on a build
change, before the memo holds anything. Carriers: every warm goes through `_warmCovers` →
`_coverGroupsFor` (`_focusReleaseCovers` for For You + All Releases weeks — so Material home
shelves and web skins too — `_fanOutFeed`, `_warmTrendingCovers`). No stored shape changed, so
no key-family bump. **Visible side effect:** a fully known-warm walk no longer opens the `covers`
stage, so warmstats keeps the LAST real pass's note; "already warm" now counts marker reads only.

**Tests:** `t_coverwarm.pl` §4f (136 → 155): second walk queues 0, reads 0 (builder AND pump
counted), control cold release still fetched, a download is remembered, a failure is not, expiry,
family bump, sweep, TTL-gap bound. **Anti-tested by nine mutated copies** (`LBF_BROWSE=`): no
builder skip, no note on hit, no note on fetch, note on failure, never expires, path-keyed, focus
ranks warm, no sweep, memo 30d — each fails its own assertion. All 38 suites exit 0 with baseline
counts; `singleflight_sync_check` 0.

**Review of 1.0.15 (2026-09-21): ONE finding, PROSE — fixed as prose only, on Simon's call.**
`COVER_WARM_TTL`'s and `COVER_WARM_MEMO`'s comments claimed a marker "can never outlive the entry
it describes". FALSE for a marker written on a proxy cache HIT: `Slim::Utils::DbCache::get` never
extends an entry's expiry (verified in the 9.1 source), so a warm that hits an entry stored earlier
writes a fresh 25d marker that can outlive the entry by up to 25d (cold fetch on next render, not a
broken image; pre-dates 1.0.15). Comments and the §4f test label now say so. **The behaviour is
OPEN, deliberately not fixed here** — it belongs to the slow-artwork round that follows this
review. No code line changed (non-comment diff against the 1.0.15 zip is empty); 38 suites exit 0.
**Second review (2026-09-21): NO findings.** Checked and cleared: no runtime path clears the markers
(`wipeDerived`/`retirePrefixes` are startup-only, nothing in `Settings.pm`), so the memo cannot
outlive a wiped marker; `DB::kver` is a constant-hash lookup, so the focus-loop check reads no store;
failures incl. the 401/403 abort never record warm; the memo is keyed by the versioned marker key;
a known-warm path is skipped before it is queued or ranked; `COVER_WARM_MAX` counts releases as
before. The open marker-outlives-entry item was correctly left unreported. Not a suppression.

**Measured on the live server the same morning, recorded so it is not re-derived:** warm walks
0.01–0.8s; ten PARALLEL Show-all walks of the 322-release week 0.53s wall, worst `version` ping
0.25s — no event-loop stall reproduced. Both red errors (08:18:58 iPhone, 08:43:15 Mac) were
logged by LMS as `Request in error, returning`, which `Slim::Control::Request::execute` emits
when `validate()` fails BEFORE dispatch — status 103, the request named a player not in
`clientHash` — followed 0.25s later by `errorNeedsClient` for that player id. The live build
was 1.0.14, an abandoned xTune experiment never committed; this fix is built on 1.0.13.
**The behaviour WAS captured with `debug_log` on** (Simon reproduced it on the Mac, 08:43): LBF's
logged activity was For You served from the store, a playlist cache hit, then the 322-release
cover re-queue five times in 6s — the loop this fix removes. Limit of that capture: `dbg` records
the warm/resolve timeline only, not per-walk render timings. The 08:15 iPhone episode predates
debug and is not captured.

## Slow artwork / server freezes — investigation 2026-09-21 (NO code changed, fix NOT designed)

**Why this is here:** after 1.0.15, covers that are NOT yet in the proxy cache still load slowly
and each one briefly freezes the whole server. Simon: find the cause before designing anything,
and redesign this part of the code **very carefully**. **Standing constraint (Simon): the fix must
work on DEFAULT LMS settings — we cannot expect users to change server settings.**

**Measured live (http://192.168.1.234:9000, the same morning):**
- Cached renditions serve fast: 322 `_600x600_f` covers in 0.32s wall, median 6ms, worst `version`
  ping 5ms.
- **Every UNCACHED Cover Art Archive / archive.org fetch freezes the event loop ~0.4–0.6s**
  (range 5–680ms), seen as a `version` ping stalled for the same window. Uncached renditions in
  bulk stack these up: one `_150x150_f` pass had a worst image of 16.6s and a worst ping of 4.8s.
- Stall START is ~one round trip after the TLS connect completes; stall END is when the response
  headers are read.

**Root cause — strongly supported by source + timing, NOT directly observed (UNVERIFIED):** an
LMS core bug on its HTTPS read path, not in LBF. `SimpleAsyncHTTP` → `Net::HTTPS::NB` →
`Net::HTTP::Methods::my_readline` (LMS `CPAN/Net/HTTP/Methods.pm`). When the first `sysread`
after the handshake consumes a NON-application TLS record (most likely a TLS 1.3 post-handshake
session ticket, which archive.org sends), it returns EAGAIN; `my_readline` does `redo READ`,
which calls `can_read`, a **blocking `select($fbits, undef, undef, $timeout)`** with the socket
timeout. The whole single-threaded server then waits there until the response arrives. The
`Net::HTTPS::NB` "Multi-read" guard that is meant to keep the read non-blocking only trips on the
SECOND read of a turn, so this first-read path escapes it. Any LMS HTTPS fetch to such a host is
exposed; LBF is the one that makes many of them in a row. **Direct proof still to get** (Simon
runs it; we do not ssh): `strace -tt -e trace=select,pselect6 -p <LMS pid>` during a cold cover
fetch should show a long single `select` on the archive.org socket.

**§A3-style: DISPROVEN during this investigation — do not re-derive:**
| belief | killed by |
|---|---|
| HQPlayer / another plugin causes the freezes | Simon: not connected to that player; freezes track CAA fetches only |
| LMS resizes in-process, decoding the 1200px source | `useLocalImageproxy=2`; the `gdresized` daemon is running and resizes in 4–40ms, async |
| source image size drives the stall | small and large sources stall alike |
| DNS lookups | stall starts after connect, not before |
| TLS in general | other TLS 1.3 hosts (e.g. postman-echo) do not stall; hosts that send a post-handshake record (archive.org, httpbingo) do |
| "loading from cache isn't optimised" | cached renditions: median 6ms, no stall |
| the Monday episodes were not captured with debug | they were: Mac, 08:43 (see the cover re-walk memo section) |

**How the others do artwork (checked 2026-09-21):**
- **Community API** (api.lms-community.org) hosts NO images. `/album/<t>/<a>/cover` and
  `/discography` `cover` fields are full-size `http://archive.org/download/mbid-…` originals
  (which redirect to https); `/artist/<n>/picture` is a Deezer CDN URL. So any plugin proxying its
  album covers has the same archive.org exposure.
- **MusicArtistInfo (MAI)** never bulk-downloads images inside the server:
  - Pre-caching lives in the **scanner process** (`Importer2.pm`), with **synchronous**
    `LWP::UserAgent` (`Common::getUA` is scanner-only), gated on the server pref
    `precacheArtwork`, library artists only.
  - It writes the finished renditions **straight into the image-proxy cache** for every
    `Slim::Music::Artwork::getResizeSpecs()` size:
    `Slim::Utils::ImageResizer->resize($file, "imageproxy/mai/artist/$id/image_", $specs, undef, $imgProxyCache)`,
    with its own `DbArtworkCache(undef,'imgproxy', time()+86400*90)`, and skips an artist whose
    last spec is already cached.
  - In the server it only registers an image-proxy handler (`mai/artist/…` → `_artworkUrl`) that
    resolves a URL asynchronously (local file, else the cached `getArtistPhoto`, mostly Deezer)
    and lets the proxy fetch lazily when a client asks.
  - Its sources are mostly fast CDNs; the Cover Art Archive appears only in the user-opened
    album-covers list.
- This is the pattern the Lyrion music-service-plugin guide describes: async HTTP in the server,
  sync HTTP only in the importer/scanner, be kind to services, cache without being aggressive.
- **LBF is the outlier.** `_warmCovers` does bulk cover downloads INSIDE the server, via a local
  GET to its own image proxy, which fetches from archive.org on the event loop. That is exactly
  the path the LMS bug freezes. The page-focused warm (`_focusReleaseCovers`) does the same while
  the user is browsing.

**LBF-side items that are OPEN (pre-date 1.0.15; belong to the redesign):**
1. A marker is written when the proxy answers 200 with its `radio.png` placeholder
   (`_artworkError` answers 200 + `Cache-Control: no-cache`, a real image gets `max-age=31536000`),
   so a failed cover can be recorded as warm.
2. A marker written on a proxy cache HIT can outlive the proxy entry by up to 25d
   (`DbCache::get` never extends expiry; see the 1.0.15 review above).
3. Uncached fetches run while the user is browsing, which is when a freeze hurts most.

**Carry-over ideas, NOT agreed (listed so a redesign starts from them, not from scratch):**
- keep bulk downloads OFF the server event loop entirely. The scanner route MAI uses does not fit
  as-is: LBF's content is a daily feed, not the library, and the scanner only runs on rescans.
- write renditions directly into the image-proxy cache instead of HTTP-to-self + markers, so there
  is no marker to lie (removes items 1 and 2);
- prefer a fast-CDN cover where one is already known (a matched streaming album), CAA as fallback;
- report the `my_readline` blocking-`select` bug upstream to Lyrion.

**Step 0 of the rework — built 1.0.16, 2026-09-21 (DIAGNOSTIC ONLY, NOT installed, NOT reviewed).**
Plan: `~/.claude/plans/gleaming-growing-dusk.md` (Step 0 proves the premise, Step 1 makes the warm
truthful via the proxy's own cache, Step 2 keeps cold fetches off the browse path). 1.0.16 adds
`["lbf","coverstats"]` (Plugin.pm `_cliCoverStats`, Browse.pm `coverStats`): per label and spec,
`marker` / `proxy` / `proxy_slash` / `proxy_bare` / `lie` (marker, no proxy entry) /
`proxy_no_marker` / `memo`, up to 10 lying paths, and proxy read timing. It walks the last list each
non-focus `_warmCovers` was handed (`%coverDiagSource`, by reference), 25 releases per turn, and
changes no warm state: no queue, no memo, no store write, no fetch. Tests: `t_coverwarm.pl` §4g (155 → 173),
anti-tested by five mutants (memoises, slash-only key, no chunking, focus overwrites the source,
lie inverted), each failing its own assertion. `t_review_fixes.pl`'s CLI-reports-name-the-build count
went 3 → 4 on purpose. All 38 suites exit 0; `singleflight_sync_check` 0. **Gate before Step 1:** a
non-zero `lie` on a warmed view, and the key form pinned (`proxy_bare` vs `proxy_slash`).
**Review 1 of 1.0.16 (2026-09-21, commit 437d343): NO findings.** Checked and cleared against the
LMS 9.1 source, so the next round need not re-derive them:
- ~~**Key form.** `proxy_bare` is the form expected to hit.~~ **WRONG, and live-disproved on
  install:** 1.0.16 read 0 proxy hits of 4,362 reads in both forms. `Slim::Web::HTTP` also
  URL-DECODES the path (`$params->{path} = Slim::Utils::Misc::unescape($path)`) before
  `Slim::Web::Graphics::artworkRequest` → `getImage`, which caches under that path. The real key is
  `imageproxy/https://coverartarchive.org/…/image_150x150_f.jpg` (no slash, decoded). This review
  read `Graphics.pm` but not the line in `HTTP.pm` that builds the path. **1.0.17** adds
  `proxy_decoded`, using LMS's own `Slim::Utils::Misc::unescape`; §4g now stores under the decoded
  key (175), with a sixth mutant (`no_decoded`) failing its own assertion.
- **The proxy read means what `getImage` sees.** `Slim::Web::ImageProxy::Cache` is a
  `DbArtworkCache(…, 'imgproxy', 86400*30)`. Its `get` goes through `DbCache::get`, which returns
  undef for an expired row, which is the same answer `getImage` acts on. `->new` returns the proxy's
  own singleton, so there is no second handle and no root change.
- **LIVE RESULT, 1.0.17 (2026-09-21 afternoon, after the startup re-seed):** 6,543 reads in
  0.39s, mean 0.047ms, max 2.1ms, so a direct proxy-cache read is cheap. **Key form PINNED: decoded.**
  Every hit was under `proxy_decoded`; `proxy_bare` and `proxy_slash` were both 0.
  | label | paths/spec | proxy present | LIE |
  |---|---|---|---|
  | all releases | 611 | 602 / 605 / 605 (150/300/600) | 9 / 6 / 6 |
  | for you | 17 | 16 each | 1 each |
  | trending month + year | 49 + 50 | all | 0 |

  24 lying paths of ~2,200 (~1%), about 9 releases, 0 `proxy_no_marker`. All six sampled lying
  releases answer **200** at CAA today (front-1200, ~2.5s via two redirects), so they are not "no
  art": the marker was written on a failed fetch (placeholder) or outlived its entry. **Caveat: this
  is the cache AFTER a day of browsing and the imgload probes, which fetched the cold covers.
  Monday 05:00's state is not measurable now.** To measure it, re-run `coverstats` tomorrow
  morning BEFORE anyone browses.
- **The cap population.** `coverStats` caps each label at `COVER_WARM_MAX` raw releases in input
  order. The warm caps on releases WITH a cover URL, after `_coverWeekOrder`. These differ only past
  2,000 releases, and the largest filtered feed live is 1,776 (All Releases, warmstats 2026-09-21).
  No writer reaches it. `lie` is unaffected either way, since an unwarmed release has no marker.
- **The callback's timer context.** A die inside `$cb` after the first chunk would leave the request
  processing. The callback only calls `addResult`/`addResultLoop`, so it has no failing path.
- **Not unit-tested:** the `_cliCoverStats` response shape (diagnostic only; checked live on install).


**Care points for the redesign (Simon: "be very careful"):** the carriers are every caller of
`_warmCovers` / `_coverGroupsFor` (For You, All Releases weeks, Material home shelves, web skins,
`_fanOutFeed`, `_warmTrendingCovers`); the proxy cache key is the WHOLE PATH including the spec
suffix; the rendition specs a client asks for vary by skin and device; `t_coverwarm.pl` (155) pins
the current contract and must be rewritten deliberately, not patched to pass; nothing here may
depend on a non-default server pref.

## Review Ledger — READ THIS BEFORE REPORTING ANY FINDING

**Why this exists.** Reviews kept re-reporting things that had already been
decided — deliberate conventions read as defects, and verdicts that lived only in
a chat transcript. Review and fix happen in separate sessions, so nothing carries
a decision forward. Everything below has already been settled; re-raising it costs
a round trip and teaches the next review nothing.

*Measured 2026-08-26, and worth recording because the obvious explanation is
WRONG: this is not caused by the uncommitted baseline. Pitchfork Reviews ran five
review rounds against a single uncommitted tree of 13,227 insertions, with a
baseline frozen for 13 days, and converged 4 → 4 → 4 → 2 → 1 → clean on one
commit. Diff size and commit cadence are not the variable. An undecided verdict
with nowhere to live is.*

**If you are reviewing:** read sections A and B first, and report an item from
them only if you have genuinely NEW information — a case the recorded reasoning
does not cover. Say which ledger entry you are challenging and what changed.

### DECLINED / SETTLED INDEX — GREP THIS FIRST

**One grep before reporting any finding.** Search this table for the symbol or subject the
finding is about, then grep the phrase in the last column to jump to the entry. A hit means it
is already decided: read the entry and either drop the finding, or answer its stated reason
with new evidence. Do not re-report it as new. Phrases are used instead of line numbers
because line numbers rot on the next edit.

| already decided | § | find it with |
|---|---|---|
| THE FLEET FOLD ROLLOUT IS CLOSED — 2026-09-10. NO WORK IS OUTSTANDING IN THIS REPO | A2 | `THE FLEET FOLD ROLLOUT IS CLOSED —` |
| The zip is not rebuilt and `repo.xml <sha>` is not recomputed in the working | A2 | `The zip is not rebuilt and `repo.xml <sha>`` |
| `CHANGELOG.md` and `README` are written at the MERGE TO MAIN, not on dev | A2 | ``CHANGELOG.md` and `README` are written at` |
| The working tree's commit state is never a finding, in EITHER direction | A2 | `The working tree's commit state is never a` |
| `install.xml` / `repo.xml` being ahead of the docs on `dev` | A2 | ``install.xml` / `repo.xml` being ahead of the` |
| Created for You showing two rows with the SAME name for one week is CORRECT | A2 | `Created for You showing two rows with the` |
| `darkwave` AND `dark wave` are BOTH Rock, and the duplicate override is | A2 | ``darkwave` AND `dark wave` are BOTH Rock, and` |
| `ListenBrainzFreshReleases/genre-families.txt` WAS EDITED BY HAND, on purpose | A2 | ``ListenBrainzFreshReleases/genre-families.txt`` |
| `indie` is DELIBERATELY family-less | A2 | ``indie` is DELIBERATELY family-less` |
| `ethereal wave`, `neoclassical dark wave` and `dreamwave` are left family-less | A2 | ``ethereal wave`, `neoclassical dark wave` and` |
| The album→single release-type filter is deliberately LBF-only | A2 | `The album→single release-type filter is` |
| Artist sort is A–Z on the display name (LMS article list); MusicBrainz sort-names, their columns and §4G are GONE — reverses "Artist sort names stay on MusicBrainz" | A2 | `ARTIST SORT IS A–Z ON THE DISPLAY NAME` |
| The hosted API is not a genre backend | A2 | `The hosted API is not a genre backend` |
| LB / MB / hosted genre sources are all MB-derived and fail together | A2 | `LB / MB / hosted genre sources are all` |
| The bio parser is end-of-life | A2 | `The bio parser is end-of-life` |
| The 45s `PLAYLIST_TIMEOUT` default is NOT an oversight left behind by | A2 | `The 45s `PLAYLIST_TIMEOUT` default is NOT an` |
| The two unmatched-tracks diagnostic views over-reporting on a cold, cut-short | A2 | `The two unmatched-tracks diagnostic views` |
| `_playlistTtl`'s `$timedOut` ranking ABOVE the partial/found split is the point | A2 | ``_playlistTtl`'s `$timedOut` ranking ABOVE` |
| The BUILT-IN Last.fm API key in `API.pm` is DELIBERATE, not a leaked secret | A2 | `The BUILT-IN Last.fm API key in `API.pm` is` |
| `GENRE_FACT_VERSION` is NOT bumped for the 0.9.194 `_norm` change — deliberate | B | ``GENRE_FACT_VERSION` is NOT bumped for the` |
| TWO 0.9.207 FIXES ARE STILL UNPROVEN LIVE, and that is known, not missed | B | `TWO 0.9.207 FIXES ARE STILL UNPROVEN LIVE,` |
| Last.fm error 6 is an ANSWER; latched key ends the warm pass; error-6 + latch UNPROVEN LIVE | C | `CLOSED IN 0.9.214 —` |
| Diag's Last.fm row says "HTTP 403", not "rejected the built-in API key" — cosmetic, pre-0.9.213 | B | `Diag's Last.fm row shows "HTTP 403"` |
| ~~Sort-names not converging~~ — MOOT 2026-09-14, the MusicBrainz sort-name was dropped; history only | B | `The artist sort-name backfill does not converge` |
| The 0.9.215 week-window review: both findings were PROSE, the code was clean | C | `CLOSED IN 0.9.215 —` |
| 0.9.216 review: re-seed labels, autumn DST double warm, re-seed vs clock race — fixed in 0.9.217, installed, round CLOSED. Closes the three ORIGINAL defects only; the fix code is open to review | C | `CLOSED IN THE 0.9.216 REVIEW —` |
| 0.9.217 review: a catch-up landing just before 05:xx ran a second, overlapping warm — `_catchUpFold` in `_warmTick`, built 0.9.218, NOT installed. Closes that defect only; the fold code is open to review. Two fixes that did NOT work are recorded there | C | `CLOSED IN THE 0.9.217 REVIEW —` |
| 0.9.218 review: NO findings — records what was checked (gate, clock helpers, fold, skip path, re-seed, fan-out) and one ruled-out candidate. Not a suppression | C | `CLOSED IN THE 0.9.218 REVIEW —` |
| 0.9.219 review: NO findings — records what was checked (both queues, callers, alias pass, tracklists, Diag) and one ruled-out candidate (`$live` before a queued send). Not a suppression | C | `CLOSED IN THE 0.9.219 REVIEW —` |
| `WARM_HOUR` stays 05:00 local — 03:30 (and "N hours after restart") asked for, costed, declined | A2 | `WARM_HOUR STAYS AT 05:00 LOCAL` |
| One MusicBrainz queue + one community-API queue; Trending album search community-API ONLY; tracklists ListenBrainz-first (edition may differ ~1 in 10, accepted) | A2 | `ONE MUSICBRAINZ QUEUE, ONE COMMUNITY-API QUEUE` |
| Streaming album match retries joint-credit parts and community-API aliases (ONE pass, clean misses only, tracks not covered); radio name lookup community API only, no MB fallback | A2 | `STREAMING ALIAS PASS` |
| Connection Check failing ~3 min after a restart, and the server being slow then — NOT reproduced; the slowdown is server-wide and NOT attributable to LBF | B | `CONNECTION CHECK RIGHT AFTER A RESTART` |
| 1.0.1 review: cached tracks arming paced timers, and the free pass keyed on the window instead of the refusal — both fixed in 1.0.2, installed. Closes those two defects only; `$pumping`, `$gapTimer` and the `'refused'` tag are open to review | C | `CLOSED IN THE 1.0.1 REVIEW —` |
| 1.0.2 review: the follow-feed and trending warms were unpaced — `paced => $warm` (read at entry, before the detach), built and INSTALLED 1.0.3. Closes that defect only; the `$warm` reads are open to review | C | `CLOSED IN THE 1.0.2 REVIEW —` |
| Spotify back-off: the WARM narrows only while Spotify refuses (always-on pacing rejected in PFR, not proposed here); a refused search does not spend a retry attempt, capped at 3 | A2 | `## Spotify back-off —` |
| THREE pumps touch Spotify — `_resolveTracks`(`paced`), `_detailPriorityBusy` (DetailWarm queue ONLY), and `_buildAlbumsData`'s trending-albums gate (paced 1.0.4). "The album side is `_detailPriorityBusy`" was WRONG and hid the third for two rounds | A2 | `THREE PUMPS TOUCH SPOTIFY, NOT TWO` |
| 1.0.3 review — THREE findings. (1) the trending-albums streaming gate was unpaced — `$warm` off `$onPending`, plus `$pumping`/`$gapTimer`, built 1.0.4; a paced gate times out into the 1h TTL: ACCEPTED, Simon's call. (2) `_buildingEnd` freed a NEWER pass's flag after the backstop expired — the flag is now a token. (3) a synchronous Spotify refusal skipped the paced gap — the resolvers signal it, `$holding` stops the loop. (2)+(3) built 1.0.5. **Round CLOSED by Simon 2026-09-16.** Closes those defects only | C | `CLOSED IN THE 1.0.3 REVIEW —` |
| 1.0.5 review (round four on the back-off): NO findings — records what was checked across all three fixes, and one PRE-1.0.4 observation deliberately not reported (the albums gate files a refused album as a drop). Round CLOSED by Simon; pushed to `dev`. Not a suppression of the fix code | C | `CLOSED IN THE 1.0.5 REVIEW —` |
| Slow artwork / server freezes: cold archive.org cover fetch freezes LMS ~0.5s. Cause = LMS `Net::HTTP::Methods::my_readline` blocking `select` (UNVERIFIED, strace pending), NOT resizing/size/DNS/TLS-in-general/HQPlayer. Markers-on-placeholder + marker-outlives-entry are OPEN, owned by the artwork redesign | B | `SLOW ARTWORK / SERVER FREEZES` |
| Web-skin dividers: Default/Classic get `type=>'textarea'` with NO image (`_webSkin`/`_divType`/`_divImage`); Classic losing row covers is the ACCEPTED cost; Material untouched. 1.0.8: `_webify` pass (feedMode = web on the itemActions CLI route, text rows -> textarea, `_webBounce` for nextWindow) | A2 | `WEB-SKIN DIVIDERS ARE TEXTAREA` |

**Two standing rules that kill most repeat findings:**

1. **Name the WRITER, not just the branch.** A hand-built input proves the branch, never the
   population. If nothing upstream can reach a guarded branch, say so in the finding instead
   of reporting it as live.
2. **A comment is not the contract.** Where a comment claims an invariant the code does not
   enforce, the comment is the defect. Fix the prose and pin the behaviour in a suite.

### HOW TO LOG A VERDICT so the next round finds it

Every new decision goes in §A2 (declined), §B (accepted/open) or §C (closed) as a bullet whose
FIRST LINE names the **symbols** a future review would grep for, then the verdict, then the
date and who decided. Add a row to the index above in the same edit. State the reason as a
fact that can be DISPROVEN ("no service returns X"), never as "unlikely" — a rarity claim
invites the next round to find one counter-example and reopen the whole entry.

**CLOSING A ROUND IS NOT A SUPPRESSION** (Simon, 2026-09-14). A §C entry records that a defect,
as described, was fixed. Never head it "Do not re-report" — that wording is for a DECISION Simon
asked for (declined, by design, a stated residual, null behaviour that keeps being mis-reported),
always with its reason, and those stay suppressed. The code a fix added is new and open to review.

### A. NOT FINDINGS — deliberate, fleet-wide

- **THE FLEET FOLD ROLLOUT IS CLOSED — 2026-09-10. NO WORK IS OUTSTANDING IN THIS REPO.**
  Listen to Later 0.1.143 fixed a fold that ERASED non-Latin names, and the obvious next step
  looked like porting it here. **It was not.** THIS REPO WAS ALREADY CORRECT — measured by
  extracting the shipped `_norm` and running it: 米津玄師, 아이유 and Кино all survive, and two
  different CJK artists correctly fail to match. LL was the only repo with the defect, and the
  fix brought LL UP to this repo rather than the reverse. The plan and every measurement behind
  it are in LL's `docs/fleet-fold-rollout.md`, now a RECORD rather than a work order.
  - **`_asciiNorm`'s `s/[^a-z0-9]+/ /g` is NOT that bug and must not be "fixed".** Being
    ASCII-only is its job. The real `_norm` uses `\p{Alnum}` on a DECODED string. A grep for
    the old pattern hits `_asciiNorm` in every repo and produced exactly this false finding
    once already.
  - **LL's matcher came INTO line at 0.1.145 and the old divergence note here is withdrawn.**
    It took the stylised-letter fold (`P!nk` → `pink`) and `_punctNorm` verbatim, so nothing is
    behind any more. Two differences remain and BOTH are deliberate: LL keeps an all-marks
    fallback this repo does not have (see the next bullet, where LL is the better one), and
    LL's dedupe KEY carries none of these rules at all, which is a DECLINED scope decision in
    that repo and not a gap. **Do not report either, in either direction, as drift.**
  - **CHANGING `_norm` IS DECLINED — Simon, 2026-09-10 — but the TRACK PATH WAS BUILT, and
    the two halves must not be confused.** This entry originally closed the whole `†††` residue
    unbuilt on the grounds that it is "a MISS, not a wrong answer". **That is true of the ALBUM
    path and false of the TRACK path**, which the same session then measured; both verdicts are
    recorded here so neither is rediscovered as the other.
    - **DECLINED, and do not re-propose it: the all-marks fallback in `_norm`.** LL has one in
      `_punctPass`; porting it here was prototyped and MEASURED. On the normaliser it is a
      clean split (67 names byte-identical, 10 rescued from empty, 0 moved) and all 32 suites
      stay green — but through `_albumMatches` it flips four cases and only one flip is
      wanted, because it moves an all-marks artist OUT of the lenient empty-artist branch and
      INTO the strict artist gate. A release MusicBrainz credits to `†††` that Qobuz spells
      "Crosses" goes MATCH → **reject**. **The asymmetry is the gates, and it runs the OTHER
      WAY in LL**: LL's `_artistMatch` returns 1 on an empty side, so an erased name there is a
      total free pass and the fallback can only tighten it; ours returns 0, and our empty-artist
      branch already demands an exact title. LL also replays a saved item to the SAME source, so
      both spellings agree by construction, where this plugin exists to match a MusicBrainz
      credit against a differently-spelled catalogue. **LL having it is not evidence we should.**
    - **BUILT: `_trackMatches` gained the short-title `_punctNorm` hatch** that `_albumMatches`
      has carried since 0.9.83, plus the two sites it is dead code without — `_findPlayableTrack`
      no longer refuses an all-marks title, and `_findLocalTrack` no longer refuses to look. It
      was NOT merely a miss there: the refusal answered `undef`, which this plugin reads as
      INCONCLUSIVE, so the track burned all three rungs of `MISS_RETRY_SCHEDULE` **without one
      request ever being made** and then settled as a durable no-match — reaching the
      Created-for-You playlists, the follow feed, Trending Tracks and both DSTM mixers. The
      per-track cache key and `_relKey` also collapsed every such name onto one shared string.
      **No fleet obligation**: `_trackMatches` and `_findPlayableTrack` are single-copy LBF, so
      `matcher_sync_check.py` says nothing about them and PFR carries no `_trackMatches` at all.
    - **Re-raise the `_norm` half ONLY with a real artist that actually failed**, naming it —
      not with the `†††` example, which is this entry.

- **The zip is not rebuilt and `repo.xml <sha>` is not recomputed in the working
  tree.** Both happen at build time, together with the version bump. A stale zip
  or sha on `dev` is the normal state, not a defect.
- **`CHANGELOG.md` and `README` are written at the MERGE TO MAIN, not on dev
  builds.** A CHANGELOG whose newest entry is many versions behind `install.xml`
  is CORRECT on `dev`. Dev builds update `CLAUDE.md`, `docs/*.md` and the memory
  notes only. *(This was reported as "docs drift" in the 0.9.174 review; it was
  never a defect.)*
- **The working tree's commit state is never a finding, in EITHER direction.**
  When the tree is large and uncommitted, that is deliberate — it is the review
  diff. When it is clean with commits unpushed, that is also deliberate: an
  uncommitted tree means "under review", an unpushed commit means "review not
  passed yet", and a push to `dev` IS the pass signal. Do not report either state,
  and do not prompt to commit **or** push as a fix for anything.
  *(As of 2026-09-10 the tree is clean at 0.9.210 with commits unpushed on `dev`.
  Do not treat that as the standing state either — check, don't assume.)*
- **`install.xml` / `repo.xml` being ahead of the docs on `dev`** follows from the
  two rules above.

### A2. NOT FINDINGS — LBF-specific

- **Created for You showing two rows with the SAME name for one week is CORRECT.**
  ListenBrainz publishes two playlists per week, Weekly Exploration and Weekly Jams,
  and the distinguishing name is carried **on the tile image**, not in the text
  underneath, which is the week. It has always looked like this. *(Raised as a
  possible duplicate-title hazard in the 2026-09-10 live test and closed by Simon
  the same day. The rows do open to different content — verified, 50 tracks each,
  different first track — so nothing is conflated.)* Do not "fix" it by putting the
  playlist name in the row text.

- **`darkwave` AND `dark wave` are BOTH Rock, and the duplicate override is
  DELIBERATE.** Simon's call, 2026-09-10. MusicBrainz carries the two spellings as
  SEPARATE vocabulary entries and `norm()` flattens hyphens, slashes and underscores
  but **not the space**, so they never share a lookup — which is exactly how they
  drifted into different families unnoticed. **Do not "tidy up" the pair into one
  entry**, and do not move either back to Electronic: the lineage it belongs with
  (`coldwave`, `new wave`, `no wave`) was already Rock. Pinned together, with those
  two as controls, in `tools/t_lastfm_priority.pl`.
- **`ListenBrainzFreshReleases/genre-families.txt` WAS EDITED BY HAND, on purpose,
  despite its own "do not hand-edit" header — this is not a defect.** The header is
  right as a default. It was overridden once, for the two darkwave lines, because a
  regeneration re-pulls the WHOLE MusicBrainz vocabulary and would fold every
  unrelated upstream change since the last build into a one-line fix. The generator
  (`tools/make_genre_families.py`) was updated FIRST and run in-process to confirm it
  emits the same two values, so the file and its source still agree. **A surgical edit
  is only legitimate when the generator is changed to match; a bare file edit is
  still a defect.**
- **`indie` is DELIBERATELY family-less.** Simon's call, 2026-09-10: it is broad
  enough to sit under Rock, Electronic or almost anything, so it is a genuine
  sub-genre with no well-formed parent. It stays valid vocabulary and displays as its
  own label. **Do not propose a family for it**, and do not read its `?` as an
  unfinished mapping.
- **`ethereal wave`, `neoclassical dark wave` and `dreamwave` are left family-less
  DELIBERATELY, not missed.** They are darkwave-adjacent and were considered during
  the 0.9.210 fix. They were not asked for, they still display their own names, and
  deciding them silently is how the darkwave split got in. Raising them is fine;
  raising them as an *oversight* is not.
- **The BUILT-IN Last.fm API key in `API.pm` is DELIBERATE, not a leaked secret.**
  Simon, 2026-09-14: ship a key so every user gets the genre ladder's tier 5 (the only
  rung not derived from MusicBrainz). `LFM_BUILTIN_HEX` is XOR-masked on purpose;
  a key the plugin decodes at runtime cannot be secret, and **proposing encryption, a
  remote key fetch or per-install keys is out of scope** — see
  `docs/lastfm-key-bundling.md` §2 and "As built". What IS guarded, and is a real
  finding if broken: the key travels ONLY in a POST body (LMS core logs a failed GET's
  URI at WARN), is never logged/displayed, a rejected key latches off after one request,
  and the per-second pacing is unchanged. `tools/t_lastfmkey.pl` pins all of it.
  **There is NO manual override** — the settings field and `lastfm_api_key` pref were
  removed the same day on Simon's call ("not needed"); do not report the missing field
  or propose restoring it.
- **The album→single release-type filter is deliberately LBF-only**, outside the
  shared matcher. It is not matcher drift.
- **ARTIST SORT IS A–Z ON THE DISPLAY NAME — `Browse::_artistSortKey`, `_sortWithin`. Simon,
  2026-09-14 ("return A-Z, it will make it all work quicker"; ignore "The").** Reverses "Artist sort
  names stay on MusicBrainz" (2026-08-22). The key is the display credit, lowercased, with a leading
  article removed by LMS's own `Slim::Utils::Text::ignoreArticles` (server pref `ignoredarticles`,
  default "The El La Los Las Le Les" — server-wide, not library-only). Only the first word goes:
  "The The" keys as "the". Each part, with a disprovable reason:
  - **No MusicBrainz sort-name, and nothing replaces it.** ListenBrainz, the community API and MuSpy's
    public lookup carry no usable field (probed 2026-09-14: MuSpy knew 11 of 40 feed artists); a
    `type`-driven name inversion files stage names wrongly (Panda Bear → "Bear, Panda"). MuSpy's
    inline `sort_name` is IGNORED so both feeds sort alike. **Do not re-propose a sort-name source or
    a name-inversion heuristic.**
  - **The columns went too** (`sort_name`/`sort_src`/`sort_at` from the `artist` CREATE and migration
    3; `artistSortGet/Put`, `importSorts`, the `artist_sorts` stat). NOT a migration finding: `main`
    ships no `DB.pm` (Gate 2). A dev store keeps the dead columns and nothing reads them.
  - **The order freeze STAYS** (`_frozenOrder`) — the genre filter is still a warm-filled peek.
  - **§4G of `docs/scheduled-overnight-warm.md` (the nightly sort stage) is DECLINED**, not parked.
- **STREAMING ALIAS PASS, AND THE RADIO LOOKUP ON THE COMMUNITY API ONLY — `Browse::_albumMatchesAlt`,
  `_artistAltNames`, `_findPlayable`; `API::getArtistAliases`, `getArtistMbidByName`. Simon,
  2026-09-14.** Field case: Dexys Midnight Runners – LOVE did not match in All Releases and Refresh did
  not help; Qobuz credits several Dexys releases "Dexys, Kevin Rowland".
  - **`_albumMatchesAlt` is LBF-only and OUTSIDE the shared matcher** — it CALLS `_albumMatches` and
    never changes it, so `matcher_sync_check.py` has nothing to say and no other repo owes a port.
    Order: the shared matcher; each part of the service's joint credit (`splitArtistCredits`); the
    artist's other names. The TITLE must match every time.
  - **ONE alias pass, clean misses only.** `_findPlayable` fetches aliases (`/artist/<name>/aliases`,
    `?mbid=` when the release carries an artist MBID; 30d found / 1d none) only when EVERY service
    answered and none matched, then searches once more. An inconclusive miss keeps its retry schedule;
    a FAILED lookup makes the miss inconclusive; a Various Artists credit is never alias-searched.
  - **No `lbf:stream:` bump.** Only misses change, and a miss is cached a day (retries within ~31h) —
    the 0.9.212 false-miss-not-false-hit reasoning.
  - **Radio: no MusicBrainz fallback** ("if it fails in the API it will fail via MB too"). What the
    fallback really rescued was renamed artists, which the alias accept now covers ("Oh Sees" →
    Osees). `lbf:artistmbid:` is retired (orphan rows age out); `lbf:aliases:` is the family.
    **Known gap, accepted:** "The Oh Sees" gets no community-API answer at all (MusicBrainz's alias
    search found it), so the radio skips it.
  - **Not covered, known:** the TRACK path (`_findPlayableTrack` — playlists, DSTM) has no alias pass.
    Raise it only with a real track that failed.
  - **UNPROVEN LIVE.** Guard `tools/t_aliasmatch.pl` (61, anti-tested seven ways).
- **The hosted API is not a genre backend.** The ARTIST tier was built in 0.9.162
  and REMOVED in 0.9.173 at ~2% coverage. Only the ALBUM route survives, detail
  page only. Do not propose reinstating the artist tier.
- **LB / MB / hosted genre sources are all MB-derived and fail together** (2–4%
  measured). Only Last.fm is independent (60%). A proposal to "add another
  source" that is one of the first three is not an improvement.
- **The bio parser is end-of-life** — the bio path moves to the hosted
  LMS-community API. Fix narrowly; do NOT re-architect `_bioBlocks` & co., and do
  not propose heuristics that re-derive structure a source already states.

- **The 45s `PLAYLIST_TIMEOUT` default is NOT an oversight left behind by
  `PLAYLIST_RESOLVE_TIMEOUT`(150s).** The long one goes to resolves nobody waits on
  — the playlist open (building row), the playlist warm, the follow feed and the
  trending tracks build. The 45s default is CORRECT and deliberate for DSTM (LMS is
  waiting on it to queue tracks) and for the two unmatched-tracks views (no building
  row, the user is at the screen). Sized by who is waiting, not by uniformity.
  *(0.9.211.)*
- **The two unmatched-tracks diagnostic views over-reporting on a cold, cut-short
  pass is KNOWN and accepted.** They render `cachetime => 0` and write no cache, so
  there is no wrong answer to persist; a track the watchdog never launched is listed
  beside one searched and missed, and re-opening fixes it. Surfacing it in the
  heading needs a new localised string and was left out of 0.9.211 on purpose. Raise
  it only with a proposal for the string, not as a defect.
- **`_playlistTtl`'s `$timedOut` ranking ABOVE the partial/found split is the point,
  not a bug.** A pass the watchdog ended is an answer about how busy the box was, not
  about the playlist. `tools/t_playlistresolve.pl` §2 pins both directions: truncated
  → 1h, and a resolve that COMPLETED short → still the full partial TTL. Do not
  "simplify" it into the `$inconclusive` term; they mean different things and the
  anti-test catches a blanket downgrade. *(0.9.211.)*
- **ONE MUSICBRAINZ QUEUE, ONE COMMUNITY-API QUEUE — `API::_mbGet`/`_mbPump`/`_mbSend`,
  `_hostedGet`/`_hostedPump`/`_hostedSend`, `getReleaseGroupByName`, `getTracklist`/`peekTracklist`.
  Simon, 2026-09-14 ("we just cannot go over its rate"; "if it fails in the API it will fail via MB
  too"; "happy with doing what's suggested").** Decisions, each with its disprovable reason:
  - **No MusicBrainz request may bypass `_mbGet`** (the mirror-only `getArtistGenres` is the one
    direct call, and never reaches the public host). MusicBrainz's limit is on the SUM per IP; five
    paths each pacing themselves put the rig over it after every restart (log, 2026-09-14 06:35-06:45).
    A request to a MIRROR is not queued; the decision is on the URL, because the mirror paths retry
    the PUBLIC host. Callers must not call `_mbNoteLimit`/`_mbNoteOk` — the queue does.
  - **The community API is one request at a time.** MAI (the API author's plugin) sends synchronously;
    the dev publishes no rate. Do not reintroduce concurrency against it.
  - **`getReleaseGroupByName` has NO MusicBrainz fallback.** The community API is built from
    MusicBrainz, so its miss is a MusicBrainz miss bar same-week additions. Do not re-propose the MB
    leg. Collaborations are split on the community API (live: "Panda Bear & Sonic Boom" = 0 albums,
    "Reset" is under Panda Bear); `artist_mbid` rides with the full credit only. A FAILED request is
    not cached; an answered miss is cached 1 day.
  - **Tracklists: ListenBrainz by release group first**, MusicBrainz for the exact release only when LB
    has none; an exact MB answer already stored is served first. **The edition can differ** (measured
    2026-08-22: LB's representative = the feed's release 38/43) — accepted, NOT a finding. Trending and
    MuSpy rows now get a tracklist too.
  - **NOT covered, known:** other plugins on the same IP (Discography's public-MB fallbacks) are not
    in LBF's queue. Raise it only with a log showing the other plugin's requests in a 503 window.
- **WARM_HOUR STAYS AT 05:00 LOCAL — `WARM_HOUR`, `_warmInstantOn`, `_secsUntilNextWarm`. Simon,
  2026-09-14, having asked for 03:30 and been shown what it costs.** Two reasons, both measured:
  1. **For You would sit a day behind, all year, in Europe.** ListenBrainz's For You job is DAILY at
     03:00 UTC (their crontab — see memory `listenbrainz-update-cadences`). 03:30 BST is 02:30 UTC,
     before it starts; 03:30 GMT is 30 minutes after it is merely requested. The warm stamps the
     feed fresh and `FEED_STALE_AFTER` (= `FEED_TTL`, 24h) lets no browse revalidate it before the
     next warm (`getFreshReleasesForUser` serves a fresh store without a fetch), so the stored list
     would be the previous day's job until the following morning. All Releases (live SQL) and the
     weekly playlists (land ~00:15-00:30 UTC) are unaffected.
  2. **03:30 sits inside the DST change hour in ~20 zones** — all of EET (Helsinki, Athens, Kyiv,
     Riga, Tallinn, Vilnius, Sofia, Bucharest, Chisinau, Nicosia) and Pacific/Chatham. On the
     spring day 03:30 does not exist and `mktime` lands the warm at 04:30; `t_warmclock.pl` §3's
     "exactly on target" goes red there. Measured by sweeping every zone's 2026 transitions with
     `zdump`; 05:00-05:30 hits none.
  **"Why a fixed time and not N hours after a restart?" was asked the same day and answered:** the
  interval put the warm at whatever o'clock LMS last restarted (08:58 on the rig) and every restart
  re-ran a complete warm. Simon's server stops all services for a 06:30 backup — the 05:00-05:30
  warm lands before it and the restart skips through the gate. If margin before a backup is ever
  wanted, shrink `WARM_JITTER_MAX`; do not move the hour ahead of ListenBrainz's job.

- **WEB-SKIN DIVIDERS ARE TEXTAREA, WITH NO IMAGE — `_webSkin`, `_divType`, `_divImage`, and every divider
  constructor (`_sectionHeader`, `_buildWeekly`, `_dayDivider`, `_recommenderDivider`). Simon, 2026-09-16
  (BUILT as 1.0.7, sha `06f010d6…`, NOT installed, not verified live; 1.0.6 carried the divider type only).** On Default and Classic a divider used to be `type=>'text'` + the `_svg.png`:
  Default's `xmlbrowser.html` turns a text row with an image into a thumbnail whose label LINKS TO THE PNG,
  and Classic (EN template) flips the WHOLE PAGE into gallery mode on one such row. `textarea` renders as a
  bare line ahead of the row wrapper in both. Decisions, each with a disprovable reason:
  - **Gated on `isWeb` alone.** `Slim::Web::XMLBrowser` passes it at every level (top feed and every coderef
    sub-feed); `Slim::Control::XMLBrowser` (Material, Jive, iPeng, home shelves) passes `isControl` and has
    zero occurrences of `isWeb` (9.1 source). So Material cannot reach the change and non-web controllers keep
    `text` + image. No passthrough is needed — unlike `features`, `isWeb` reaches sub-feeds.
  - **Not plain `text` without the image.** Default's list mode then substitutes `music/0/cover.jpg`, a
    placeholder cover on every divider.
  - **CLASSIC LOSES ITS ROW COVERS, AND THAT IS ACCEPTED.** The divider was the ONLY thing setting Classic's
    `hasArtwork` (its test is `item.image && item.type == 'text'`), and Classic's list mode draws no per-row
    artwork (checked against another plugin's Classic feed). Do not report the missing covers as a regression,
    and do not "fix" it by putting an image back on a divider.
  - **The setup-required message row** follows the same rule (it had the same text+image shape).
  - **Web dividers are STYLED headings (1.0.7).** A textarea's name is printed through Template Toolkit's
    `html_line_break` alone (no `| html`), so `_divName` wraps the ESCAPED label in a bold ListenBrainz-navy
    block over an orange rule (`WEB_DIV_STYLE`). Ordinary rows are `| html`-escaped, so the Options ACTION rows
    cannot be bolded without a custom `web.type => 'htmltemplate'` that re-implements each skin's link — not
    done; they are told apart by their icons instead. A recommender name is ListenBrainz data: `_escHtml` is
    REQUIRED, not defensive.
  - **The 11 `lbf-*_MTL_icon_*.png` files are real icons now (1.0.7)** — Google Material SVGs rendered in
    `#353070` on transparent. They were opaque grey/white squares or pale-grey glyphs that vanished on the old
    skins' light backgrounds. Material never shows them: its bundle drops `image` for any `MTL_icon_` name
    (`a.image=a.svg=void 0,a.icon=…`, verified in the live `material.min.js`).
  - **Pilot for the fleet:** PFR, LL and Discography get the same pattern once this is verified live; Search
    Hub is excluded (on hold). Guard: `tools/t_webskin.pl` (50; anti-tested four ways, each mutant failing only
    its own checks). `t_coverwarm.pl` / `t_release_target.pl` now lift the new helpers.
  - **1.0.7 LIVE TEST (Simon, 2026-09-16): only the top level and New Releases for You were right.** Measured
    over HTTP the same day, three causes, all fixed in **1.0.8** (sha `81f7a964…`, BUILT, NOT installed):
    1. **A web skin does not always come through `Slim::Web::XMLBrowser`'s own path.** A row with an
       `itemActions => { items => … }` command (every All Releases week, every release tile) is fetched as a
       CLI request through `Slim::Control::XMLBrowser` — `isControl`, no `isWeb` — so the week's Options
       divider and the whole release page rendered the Material fallback. That request carries `feedMode:1`
       (the web renderer wants the RAW feed; Material sends it only for its own favourites list), so
       `_webSkin` now accepts it; below the top of such a request sub-feeds get `params => $feed->{query}`
       and lose even that, so `_webify` re-stamps `isWeb` on every coderef it wraps.
       **"`isWeb` reaches every level" above is TRUE ONLY for the coderef route.**
    2. **Plain `type=>'text'` rows are wrong on the web skins too:** `| html`-escaped (the expanded bio showed
       its `<div style=…>` as code) and, in Default, each given a placeholder cover (25 blank album icons on
       one release page). `_webify` turns them into `textarea` — escaped text, or our own prose markup minus
       Material's 72px indent, with a text row's image drawn INLINE via the image proxy.
    3. **The web skins have no `nextWindow`.** Read more / Show more / sort / family / genre / Refresh opened a
       sub-page repeating the unchanged list. An EMPTY answer from a `refresh`/`parent` row is replaced by
       `_webBounce`: a textarea whose script `location.replace`s the index with its last 1 (or 2) segments
       dropped, plus a `lbfr` cache-buster the feed never reads. Both skins browse in a FRAME, so the script
       runs. A NON-empty answer (the Bandcamp picker) is shown as before.
    **One pass, one place:** `topLevel` wraps its callback in `_webify` only when `_webSkin` is true, and
    every child `url` is wrapped recursively, so no feed builder knows about it. Material is untouched by
    construction (no `isWeb`, no `feedMode`). `t_webskin.pl` 63 -> **91**, §6; anti-tested six ways
    (feedMode ignored 1, isWeb not re-stamped 2, no bounce 4, topLevel not wrapped 2, no escaping 2,
    parent bounced one level 1). All 38 suites exit 0; both sync checks 0; zip diffs identical to the tree.
    **Still ACCEPTED:** Options action rows are told apart by icon only; link rows with no image still get
    Default's placeholder cover (only TEXT rows are converted).
  - **1.0.9 (sha `c2886d35…`, BUILT, NOT installed) — a web heading CLOSES an Options block** (`_webListHead`):
    on Classic (no row covers) the Options rows ran straight into the releases. An All Releases week gets its
    `W/C` label, Trending Albums its own title, between Options and the list; For You already has week headings
    there. Web only — Material and plain controllers get no extra row, so item positions do not move; the
    week's cover-focus slot map counts the row. `t_webskin.pl` 91 -> **96**, anti-tested 2 ways.
  - **1.0.10 (sha `fe044979…`, BUILT, NOT installed) — NO Show more / Show all / Show less on a web skin**
    (`_pageSection`'s 4th arg). Measured live on 1.0.9: the tap worked (the week grew 37 -> 68 rows) but Default
    pages every list at 50 (`itemsPerPage`), so the new releases AND the next paging rows landed on the skin's
    page 2 and the tap read as dead. A web skin now gets the whole week and the skin's own pager; the week's genre
    peek is widened to `GENRE_WARM_MAX` to match (rows past 150 would otherwise lose their genre). Material is
    unchanged, and a Material page state does not shorten the web list. **Do not re-add paging rows for the web
    skins** — their pager is the paging. `t_webskin.pl` 96 -> **101**, anti-tested.
  - **1.0.11 (sha `73af8ae0…`, BUILT, NOT installed) — the release page on a web skin.** (1) **The artist bio
    is shown IN FULL with no Read more / Show less** (`_artistRows` 5th arg) — Simon: the reveal has the same
    reload problem as paging, and the Streaming rows (the point of the page) sit above it, so full text costs
    nothing. (2) **Refresh streaming matches** and **View on MusicBrainz** had no image, so Default drew its
    placeholder album cover; on a web skin they now carry `MENU_REFRESH` and the new `MENU_WEBLINK`
    (`lbf-weblink_MTL_icon_open_in_new.png`, drawn like the other eleven). Material is unchanged — no toggle
    change, no new images there. `t_bioreveal.pl` 135 -> **145**, anti-tested three ways.
  - **1.0.12 (sha `25b6018a…`) — INSTALLED 2026-09-16 (`plugin_version` 1.0.12) and SIGNED OFF by Simon on
    Default/Classic ("caught them all in this repo"). The LBF pilot is DONE; the port to PFR / LL / DSC is next.** (1) **Block this artist** gets `MENU_BLOCK`
    (`lbf-block_MTL_icon_block.png`) on a web skin, closing the last placeholder-cover row on the release page.
    (2) **The Settings row opened a Material-styled page from Default/Classic**: `/plugins/…/settings.html` is served
    in the SERVER's default skin. The skins print a weblink verbatim and Classic's (EN) template has no
    webroot-prefixed `link`, so the web row uses the RELATIVE `WEB_SETTINGS_LINK`
    (`../ListenBrainzFreshReleases/settings.html`), which resolves inside whichever skin's browse page is open
    (verified: `/Default/…` and `/Classic/…` serve that skin's CSS). Material keeps the absolute path.
    `t_bioreveal.pl` 145 -> **147**, `t_webskin.pl` 101 -> **104**; both anti-tested.
  - **1.0.13 (sha `5a40a972…`) — BUILT, NOT installed.** `_releaseDetail`'s remaining call sites now
    pass `_webSkin($a)` (they had been left on the old positional arg, so a web skin reaching those
    routes fell back to the Material rendering). `_proseBlock` now tags every row it emits with
    `_lbfProse => 1`, and `_webifyItem` checks that tag rather than sniffing the row's `name` for a
    leading `"<div style='"` — the sniff broke the moment a prose block's own text happened to start
    with that string. Dev build: version-only bump, no cache family touched (this is render-shape
    only, not a stored decision), `README.html`/`CHANGELOG.md` deliberately untouched per the standing
    rule. `t_loads.pl` 20/20 against the working tree; `perl -c` clean via that harness.

### B. KNOWN-OPEN AND ACCEPTED — do not re-report as new

- **SLOW ARTWORK / SERVER FREEZES — `_warmCovers`, `_focusReleaseCovers`, `_coverLaunch`, `lbf:imgwarm:`, `COVER_WARM_TTL`.** OPEN, under investigation 2026-09-21 (Simon). A marker can be written on the proxy's 200 placeholder, a marker written on a cache hit can outlive the proxy entry by up to 25d, and uncached archive.org fetches run on the event loop while the user browses (each freezes LMS ~0.5s via an LMS core HTTPS read bug). Known, not missed: the fix is a deliberate redesign, not a patch. Full write-up: the "Slow artwork / server freezes — investigation" section above the ledger.
- ~~**`matcher_sync_check.py` exits 1.**~~ **CLOSED in 0.9.194** — the hold was
  lifted 2026-08-29 and the sync is done (PFR 0.9.33, LBF 0.9.194). **The check
  now exits 0, and a non-zero exit is a real finding again.** Search Hub is
  pinned in `VARIANTS` as a deliberate frozen variant, not removed from the
  comparison. See the Shared Matching Engine section.
- **`GENRE_FACT_VERSION` is NOT bumped for the 0.9.194 `_norm` change — deliberate,
  and it is a MERGE-GATE item, not a defect.** The `artist` table keys rows
  `n:<_norm(name)>`, so the names whose fold changed (apostrophes, the ~80 new
  `%FOLD` letters) have their old rows orphaned. Weighed and left: the ladder
  already re-asks and re-files a missing artist on the next warm — the store's own
  comment says refilling is the correct answer because the tags ride a bulk request
  the plugin already makes — so a global genre wipe would clear EVERY user's store
  to fix a subset. Ordinary dev builds now preserve all caches too, so this remains
  an explicit parser-version decision; do not hide it behind a plugin-version bump.

- **TWO 0.9.207 FIXES ARE STILL UNPROVEN LIVE, and that is known, not missed
  (2026-09-10).** Both were verified by test and by source reading; neither has been
  observed on the server. Do not re-report them as untested, and do not "fix" them
  speculatively.
  - **The artwork focus slot map.** Needs INFO on `plugin.listenbrainzfreshreleases`
    to see which covers a given row range promotes. The CLI reports cannot show it.
  - **The MuSpy detail-prewarm union.** Could not be exercised AT ALL: `muspy_feed`
    returns 0 releases on the test rig, so it needs a MuSpy user id with something
    upcoming before it can be observed either way.

- **Diag's Last.fm row shows "HTTP 403" for a rejected key, never its own "Last.fm rejected
  the built-in API key" note — `Diag.pm` probe runner, `check` vs the error callback. Cosmetic,
  accepted open, 2026-09-14 (Simon closed the round).** Last.fm answers an invalid key with HTTP
  403 + a JSON error body. `SimpleAsyncHTTP` sends any non-2xx to the ERROR callback, and that
  callback settles on `_httpCode` alone (`warn`, `"HTTP $code"`). It never runs the target's
  `check` on the body, so `check`'s "rejected" branch is reached only by an HTTP 200 error body,
  which `auth.gettoken` does not produce for a bad key. **The mechanism is NOT a wrong
  argument:** the callback's first argument is the `SimpleAsyncHTTP` object, which carries
  `->code` and `->error`, and `_httpCode` digs the status out of `->error` as its comment
  documents. The row is still `warn`, so no fault is hidden. Pre-dates 0.9.213 (runner from
  0.9.158; the GET probe behaved the same). A fix would pass the error body to `check` when
  the target opts in. Not a regression, and it is not scheduled.

- **~~The artist sort-name backfill does not converge~~ — MOOT, 2026-09-14: the MusicBrainz sort-name was
  dropped (§A2 `ARTIST SORT IS A–Z ON THE DISPLAY NAME`) and §4G is DECLINED. History below.** The nightly `sorts` stage was
  PARKED — Simon, 2026-09-14: "leave the artist sort for now, it feels like we need more work
  to get this to work better, we should not be hitting 503's."** Do not report "sort names are
  missing / MusicBrainz is being hammered / why is this not cached" as a new finding: it is
  known, measured and planned. **It is not a caching defect** — sort names live in the
  `artist` table on a 30d-found / 1d-none age policy, survive an ordinary build AND an
  explicit clean-load reset, and nothing wipes them; `cachestats` on the rig showed
  `artist_sorts` CLIMBING (2,199 → 2,200) while `release` and `kv` stayed flat. The gap is
  that `warmArtistSorts` is reached only from `Browse::_warmArtistSorts` (`$mode eq 'artist'`),
  is capped at `SORT_WARM_MAX` 100 a pass, and a 503 ends the pass — against ~2,889 artists
  without a name on a box whose `mb_base_url` is PUBLIC MusicBrainz (confirmed in `lbf diag`;
  no mirror is assumed going forward, §7 of `hosted-lms-community-api.md`). `API.pm`'s own
  comment already called it *"a multi-day reconvergence on a 2,900-release feed"*.
  - **THE 503 RATE IS ANSWERED — 2026-09-14.** It was not the sort warm's own pacing and not
    another plugin: LBF's OTHER MusicBrainz callers (the Trending album search above all) sent
    unpaced beside it after every restart, pushing the IP over MusicBrainz's per-IP average so every
    request was refused. Fixed structurally by the one MusicBrainz queue (§A2 `ONE MUSICBRAINZ QUEUE`).
    Whether the sort stays on MusicBrainz at all is now Simon's open decision, not a parked build.
  - **WHY IT IS PARKED, and it is NOT the budget question.** The design (§4G of
    `docs/scheduled-overnight-warm.md`) is sound and reviewed; what stopped it is that the
    box is being 503'd at a pace WIDER than the courtesy gap the code applies — measured
    2026-08-22, two 503s inside eight requests paced at 1.2s against the 1.1s `warmArtistSorts`
    sends. So the throttling is not explained by our own pacing, and a nightly stage would meet
    the same wall unattended, in the dark, on a schedule. **The 503 rate is the open question,
    not `SORT_WARM_NIGHT`.** Diagnose that first — who else on the box talks to public
    MusicBrainz (Discography is a live candidate), and whether the limit is per-IP shared.
    Do not build the stage until that is answered, and do not re-raise the stage as the fix
    for slow sort-names: it was considered, designed and deliberately held.
  - **Two numbers are STILL UNMEASURED and gate any later build:** `DB::stats` counts `artist_sorts`
    (`sort_name <> ''`) and has no counter for recorded nones, so the 2,889 is "artists
    without a name", NOT "artists still to try". `artist_sort_none` / `artist_sort_never` are
    to be added and read off the rig BEFORE `SORT_WARM_NIGHT` is chosen.
  - ~~**Do not re-propose moving sort-names off MusicBrainz.**~~ Superseded 2026-09-14: the sort no
    longer uses a sort-name. Neither ListenBrainz nor the hosted API carries the field, probed live.
  - **Do not re-propose raising `SORT_WARM_MAX`** as the fix. The browse cap is correct for a
    foreground open; the stage takes its own constant. And do not propose simply raising
    `SORT_NONE_AGE` — one day is the 0.9.186 `fetched_at` fix and is still right for the
    browse path; §4G.1 splits it per caller instead.

- **CONNECTION CHECK RIGHT AFTER A RESTART — `Diag::run`, `OVERALL_DEADLINE`, `WARM_DELAY`. Closed
  as NOT REPRODUCED, Simon 2026-09-15.** On 2026-09-14 at ~boot+3min the check showed Labs, Cover
  Art Archive and Last.fm `fail` at ~8.2s each and `mb_search` "0 ms, timed out", while every
  streaming track-match timed out in the same millisecond (the same burst sat at 16:58:07 on
  0.9.217). ListenBrainz had known upstream problems that day. Re-run 2026-09-15 idle AND at
  boot+185s: every row green both times. The one row that could falsely read "timed out" is fixed
  (`mb_search` "not probed", round of 2026-09-15 above).
  - **The post-boot slowdown is server-wide, not an LBF finding.** Measured 2026-09-15 with a 0.5s
    `serverstatus` poller through a restart: ~35ms until exactly boot+180s, then 0.25-1.8s for
    between 2.5 and 5 minutes, longest single stall ~2s, nothing timed out. The onset coincides with
    `WARM_DELAY`, but the rig runs other server plugins that do their own start-up work, so the
    load cannot be pinned on LBF without per-plugin evidence. Re-raise ONLY with that evidence, or
    with a Connection Check that fails again on a healthy upstream day.

### C. CLOSED FINDINGS

Fixed findings are recorded per review in `docs/code-review-<version>.md`, each
with its mechanism, its guard and its test. Check there before reporting: the
**0.9.160, 0.9.174, 0.9.184, 0.9.191, 0.9.192 and 0.9.206** findings are all fixed
and verified. A finding that is one of those defects as described is a repeat; a finding about
the code those fixes added is not. Suppression applies only to recorded decisions, below and in
§A2/§B.

**CLOSED IN THE 2026-09-10 HYGIENE PASS — the two review docs that still said
"nothing here is fixed yet".** Both had been closed in code for weeks; only the
documents were stale, which is the failure mode this whole ledger exists to stop.
- **All ten 0.9.160 findings** (the bio render rework and `Diag.pm`), verified
  against the source rather than inferred from a build note — they were absorbed
  across 0.9.161–0.9.186 and no single version closed them. The doc now carries a
  finding-to-mechanism table. **Three of the ten (2, 3 and 10) were closed by
  rewriting wrong prose and nothing guards them** — that is stated there, not
  hidden.
- **The last two 0.9.174 findings.** The matcher drift closed in 0.9.194 (the
  checker exits 0, re-run 2026-09-10); the CHANGELOG gap was never a defect and is
  now section A's first entry.

**CLOSED IN 0.9.197 — two field bugs, both fixed, both pinned.** Closes the two defects as
described; the stated residual below is a recorded decision and stays suppressed. The fix code is
not thereby settled:
- **An All Releases week's row order moving between render and click** (the
  wrong-row-on-tap report). Fixed by `_frozenOrder`; `tools/t_orderfreeze.pl`,
  23 assertions, five anti-tests. **The residual is STATED, not missed:** a row that
  LEAVES the set still shifts the rows after it. Not fixable without rendering a
  release the filter excluded, and not the live case — a warm ADDS to a filtered set,
  it does not remove. Do not re-report that as an incomplete fix.
- **`_coverTick` scanning an all-warm queue end-to-end in one turn.** Fixed by
  `COVER_SCAN_BUDGET`; `t_coverwarm.pl` §4d, three anti-tests. **This is the 0.9.196
  claim corrected, not a new mechanism** — see the ⚠️ blocks in
  `docs/artwork-and-event-loop-rework.md`.

**CLOSED IN 0.9.207 — both 0.9.206 findings, plus a third carrier the review missed.**
Closes the three defects as described; the by-design residual and the declined source id below
are recorded decisions and stay suppressed. The fix code is not thereby settled:
- **The artwork focus addressing the wrong releases on For You.** Fixed by replacing
  the scalar options offset with a SLOT MAP (`_weekGroups` → `_renderSlots`), one entry
  per rendered row. `t_coverwarm.pl` §4e, three anti-tests (3/5/1 red). **The residual
  is STATED, not missed:** the focus still promotes covers for the whole list, rotated —
  it changes the ORDER work is done in, never which covers are eventually warmed. That
  is by design and is not an incomplete fix.
- **An upcoming MuSpy release losing its detail prewarm.** Fixed by `_sectionBounds`,
  the one carrier for a section's date bounds, returning the UNION of the For You and
  MuSpy windows. `t_detailwarm.pl` §8, two anti-tests. **The review proposed a separate
  source id instead; that was considered and declined** — both feeds enqueue at
  priority 0, DetailWarm keys sources BY priority, and `$job->{rel}` is last-write-wins,
  so a per-release test loses the prewarm in the mirror-image gate combination. The
  union is order-independent and only over-accepts. Do not re-propose the source id
  without addressing that case.
- **`_windowSpan` understating the For You tile's span** — the same concept drifting in
  a third place, found by sweeping the carriers rather than reported. Now routed through
  `_sectionBounds` with `_sectionSig`.

**CLOSED IN 0.9.214 — the 2026-09-14 review of 0.9.213 (built-in Last.fm key), and its
follow-up sweep. Both rounds closed by Simon 2026-09-14.** Closes the defects as described;
the fix code is not thereby settled:
- **`_lastfmPost` / `getLastfmTags` / `getSimilarArtistsLastfm` treating Last.fm error 6 as
  a failure.** Error 6 is HTTP 200 + `{"error":6}` for an artist Last.fm does not know —
  an ANSWER, ~20% of a sampled week's feed artists (named in the 0.9.214 entry). Fixed:
  `_lastfmPost` hands `onError` the code; both call sites store/cache 6 as empty; every other
  error still stores nothing. `t_lastfmkey.pl` §5, anti-tested 4 red, controls on error 8.
- **`_warmLastfm` spinning the queue after the key latches mid-pass** (10/26/29) — found by
  the sweep, not the review. Fixed: the pass ends with the rest `deferred`, releasing
  `$lastfmWarmPending`. `t_lastfm_priority.pl`, anti-tested 4 red, 2 controls.
- **Stale manual-key prose** in DSTM, Plugin, Diag, API, Browse, Diag's skip note, the warm
  note and `PLUGIN_LBF_DIAG_DESC`. Prose only; nothing guards it beyond `t_lastfmkey.pl` §7.
- **UNPROVEN LIVE, and that is known, not missed:** the error-6 path (0.9.214's first pass
  found 220/220 fresh checkpoints and requested nothing) and the latch (no rejection has
  happened). Proven live: the built-in key and the POST transport (Connection Check ok).
  Evidence to look for: `lbf warmstats` Last.fm note with `requested` > 0 and `failed` near 0.
- **Third round, 2026-09-14, over the two unpushed commits 0.9.213 + 0.9.214: CLEAN, zero
  findings. Closed by Simon 2026-09-14.** Verified: `LFM_BUILTIN_HEX` decodes to a 32-char key;
  nothing reads `lastfm_api_key` except `Plugin.pm`'s one-time cleanup; `getLastfmTags`' only
  caller (the warm) passes an empty album, so its album-tags branch is unreachable; the
  `_warmLastfm` latch check runs before each request; `getSimilarArtistsLastfm` error bodies fall
  back through DSTM and a cached empty list is a hit; the Connection Check POST argument order.
  Its one out-of-diff observation is logged in §B (`Diag's Last.fm row shows "HTTP 403"`).

**CLOSED IN 0.9.215 — the 2026-09-14 review of the per-section release window. Closed by
Simon 2026-09-14. Two findings, BOTH PROSE; the code was clean.** Closes the two prose
defects as described; the two entries in the last bullet are recorded decisions and stay
suppressed:
- **`_sectionSig`'s header comment still called `_sectionBounds` "the For You window unioned
  with MuSpy's".** The union was removed in this same change and every other copy of that
  comment was rewritten; this one was missed. Fixed: it now reads "one window per section;
  MuSpy rows are For You rows and answer to For You's weeks", matching the sibling comments
  at `_warmReleaseDetails` and `_windowSpan`. A comment is not the contract — the comment was
  the defect, per the standing rule.
- **This file and `docs/week-based-release-window.md` both claimed the work was "not built,
  not versioned, not installed" / "working tree, unbuilt"** while `install.xml` and `repo.xml`
  sat at 0.9.215 with a matching sha and the zip unpacked byte-identical to the tree. Fixed:
  both now say built and versioned as 0.9.215, not yet installed. This is the stale-document
  failure the 2026-09-10 hygiene pass closed once already — a doc that describes an earlier
  moment of the same session.
- **The rest of the round was CLEAN, and these are the checks, so a later round need not
  redo them.** `clampSectionWeeks` holds `weeks` 1..4 and `upcoming` 0..weeks-1 and the digit
  regex drops negatives and garbage to the section default, so the derived
  `(weeks-1-upcoming, upcoming)` can never exceed `_clampWeeks`' `WEEKS_MAX_SIDE` budget of 3
  and the backstop never fires against a legal pair. Defaults reproduce 0.9.185 exactly —
  For You (1,2), All Releases (1,0) — with `%WEEK_PREFS` and `Plugin.pm`'s `$prefs->init` in
  agreement. No reader of `weeks_past`, `weeks_future`, `muspy_future` or the four
  `*_past`/`*_future` gates survives in any `.pm`/`.pl`/`.html`/`.txt` outside comments, and
  there is no orphan template field or `strings.txt` key in either direction. The checkbox
  sentinel still works: `pref_foryou_weeks` is a number input the full form always posts (it
  sits in a collapsible div, which still submits), and the sentinel test runs BEFORE the week
  block injects its four params, so a partial POST skips coercion. `_feedRequestDays` walked
  over every legal pair across all seven weekdays peaks at 27, is never 0, and its range
  always contains the window. `_mergeMuSpy`, `_sectionBounds` and `_warmReleaseDetails`'
  source-0 eligibility all answer to the one `sectionWindow('foryou')`, so no path shows a row
  the warm would refuse, and `_mergeMuSpy([], undef)` in `warmFeeds` degrades to `[]`.
- **Two ledger entries were correctly NOT re-reported and must stay that way:** `_padDate`
  dating a year-only MuSpy release 1 January (pre-existing, out of scope) and `bench_walk.pl`
  exiting 255 on a missing `lastfmConfigured` stub (proven not this build).

**CLOSED IN THE 0.9.216 REVIEW — the 2026-09-14 review of the fixed-overnight-clock working
tree. Fixed and built as 0.9.217, INSTALLED on the rig 2026-09-14 16:54; round CLOSED by Simon
2026-09-14.**

> **SCOPE OF THIS ENTRY — READ BEFORE USING IT TO DROP A FINDING.** What is closed is the three
> ORIGINAL defects exactly as described below: the `(re-seed)` label defeating week order, the
> seconds-arithmetic double warm, and the re-seed firing after an imminent clock tick. Re-reporting
> THOSE is a repeat. **The code written to fix them is NEW and is NOT reviewed-and-settled** — a
> grep hit on these symbols is not a reason to drop a finding about them. In scope for any later
> review, as new surface: `_warmInstantOn` and the rewritten `_secsUntilNextWarm` /
> `_lastWarmInstant` (the `POSIX::mktime` call, the widened candidate loops, zones and dates the
> suite does not cover); the `$clockIn <= WARM_DELAY` branch in `_armWarm` (anything it now fails
> to seed); and the plain labels in `reseedFromStore` (any consumer that behaves differently now a
> re-seed is indistinguishable from a warm). A defect a fix INTRODUCED is new information, per
> "A closed finding is not a closed MECHANISM" below.
- **`Browse::reseedFromStore` / `_fanOutFeed` labels.** The re-seed passed `'… (re-seed)'`
  labels; `_warmCovers` and `_queueReleaseDetails` compare `$label eq 'all releases'` to
  week-order (and `_coverGroupsFor` keeps order only then). Fixed: the warm's own labels.
  **The label is an ORDERING KEY, not a log tag** — the old §9 assertion pinned the suffix
  "so warmstats cannot read it as a warm", and no report reads the label at all.
  `t_detailwarm.pl` §9 now reads the labels out of `warmFeeds` (anti-tested: suffix restored, 1 red).
  Regex consumers (`/for you|muspy/` priority, `/all releases/` cover rank) were unaffected.
- **`_secsUntilNextWarm` / `_lastWarmInstant` across DST.** Seconds-into-day arithmetic re-armed
  the autumn tick for 04:10 GMT and then 05:10 GMT: two full warms on 2026-10-25, the second
  zeroing the first's `$detailMainReady`. Spring was only an hour late. Fixed with
  `_warmInstantOn` (`POSIX::mktime`, isdst -1); both loops start a day wide so a date read one
  day off still finds the right instant. `t_warmclock.pl` §3 follows the re-arm CHAIN (the old
  section asked one landing from midnight, which cannot see a second run). Anti-tested: old
  arithmetic 3 red, old `_lastWarmInstant` 1 red, `>=` boundary 4 red, UTC-built instant red.
  Green under seven DST zones via `LBF_TZ=`, including Lord Howe's half hour and Santiago.
  **The design doc's "arithmetic-only, nothing to get wrong" was the defect** — do not
  "simplify" the helper back to seconds arithmetic.
- **`_armWarm` arming the re-seed when the clock is due within `WARM_DELAY`.** The tick zeroed
  `$detailMainReady`, the re-seed released it during the streaming-readiness wait. Fixed: no
  re-seed on that path (the tick seeds the queue). `t_warmclock.pl` §6: clock due in 180s and
  60s → no re-seed; 181s → re-seed (control). Anti-tested 2 red. **The reverse order is safe
  and deliberately unguarded**: a re-seed followed by a later tick is just the tick re-zeroing
  the flag for its own phase.
- **What was checked and is unaffected:** no cache key, TTL, family version or stored shape
  changed; `_warmTick`'s re-arm and scan-defer are untouched; `_warmTick` is `warmFeeds`' only
  caller; all 34 suites exit 0, both sync checks 0, `bench_walk.pl` still 255 for its known
  pre-existing stub (not this change).
- **LIVE CHECK, 2026-09-14, over `jsonrpc.js` — what is PROVEN.** `plugin_version` 0.9.217 in
  `cachestats`, `warmstats` and `diag` (all diag targets ok, MuSpy skipped: no id). The log read
  `Build changed (0.9.215 -> 0.9.217): derived cache KEPT; genre cache KEPT` — 0.9.216 was never
  installed. The gate took the BUILD-CHANGED branch: one catch-up tick at **16:57:53, exactly
  `WARM_DELAY` after load**, and `warm_last_at` equals `tick_at`. The warm completed in ~22s in
  the agreed order — feeds (For You 43, All Releases 1,576), covers (1,698 already warm, 2
  fetched), genres and playlists, `genres_lastfm_all` LAST (220/222 fresh checkpoints, 2
  requested, 0 failed). Detail queue released (`detail_main_ready` 1): 479 completed, 962/966
  cache hits, 4 fetches, 0 failed, 11 pending = 11 deferred.
- **UNPROVEN LIVE, and that is known, not missed:** the SKIP branch and the re-seed under the
  fixed labels (needs a restart after today's warm — expect `ticks` 0, `detail_main_ready` 1 ~3
  minutes after load, pending/completed non-zero, no forced feed fetch); the within-`WARM_DELAY`
  re-seed skip (needs a restart in the three minutes before 05:xx — not practical to stage); the
  DST fix (not observable until 2026-10-25). The first fixed-clock tick is due ~05:04 on
  2026-09-15: `tick_at` should read that time and `ticks` 2 with no restart in between.

**CLOSED IN THE 0.9.217 REVIEW — the 2026-09-14 review of the 0.9.217 working tree. One finding,
fixed and built as 0.9.218, NOT installed.** Closes the defect as described. **The fold code is new
and open to review** — `_catchUpFold`, its placement in `_warmTick` and `WARM_MERGE` are in scope
for any later round.
- **`_armWarm` catch-up branch + `_warmTick` re-arm: a catch-up landing shortly before 05:xx ran a
  second, overlapping warm.** The catch-up arms `_warmTick` at `WARM_DELAY` unconditionally and every
  tick re-arms from `_secsUntilNextWarm`, so LMS started at 05:01 on a 05:04:30 install warmed at
  05:04:00 and again at 05:04:30: three forced feed fetches twice, and the second `warmFeeds`
  zeroing `$detailMainReady` while the first warm's `_warmGenres` `branchDone` set it back to 1
  mid-chain — the 0.9.204 phase inversion through the catch-up branch. Simulated against the real
  helpers for every boot minute: min gap **40s**, 60 boot-minutes a day under 30 minutes apart.
  Reached by any start in the minutes before 05:xx with the last warm missed (a build install, a
  fresh install, a box switched on before 05:00).
- **TWO FIXES THAT DID NOT WORK — do not propose either again.**
  1. **A `$clockIn <= WARM_DELAY` guard on the catch-up branch** (proposed in the round itself).
     It misses the reported case outright — 210s is > 180s — and fires only where the catch-up
     already lands AFTER the instant, which is a single warm anyway.
  2. **A gate-time fold** (arm the clock instead when `clockIn` is within `WARM_DELAY + WARM_MERGE`).
     Correct with no scan, but a boot-time library scan moves the catch-up in `WARM_SCAN_RETRY`
     steps right up to the instant after the gate has answered: still **160s** apart behind a 1h
     scan and **40s** behind a 2h one.
- **Fixed: `_catchUpFold`, asked at the top of `_warmTick`** — after the scan defer, before
  `stageReset` and the `warm_last_at` stamp. A tick with a scheduled instant within `WARM_MERGE`
  (3600s) re-arms for that instant and does not warm. **A clock tick can never fold itself**: from
  its own instant `_secsUntilNextWarm` is strictly future, 23-25h away. `_armWarm` is unchanged.
  Simulated for every boot minute, four store states (missed / today's warm ran / none / build
  changed), scans of 0/1h/2h, London on a normal week and both DST weeks, Lord Howe and Santiago:
  min gap **3640s** everywhere, every boot warms within 26h, no re-seed inside a warm, and the
  today's-warm-ran rows byte-identical to 0.9.217 (the skip path is untouched).
- **Guard: `t_warmclock.pl` §6b, 46 -> 57** — the `WARM_MERGE` boundary both sides, the clock tick at
  and up to 10 minutes past its instant never folding, every instant across both DST weeks, the
  followed CHAIN for every boot minute of two days with scans, and the order inside `_warmTick`.
  Green under London, Helsinki, New York, Lord Howe and Santiago. **Anti-tested three ways:** helper
  deleted **8 red**, `<` for `<=` **1**, the fold block deleted from `_warmTick` **2** — and only the
  two ORDER assertions see that last one, because the chain models the fold through the helper.
  All 34 `tools/t_*.pl` exit 0; both sync checks 0.
- **STATED COSTS — decided, not missed:** a catch-up due within an hour of 05:xx now warms AT
  05:xx, up to `WARM_DELAY + WARM_MERGE` after boot, with **no re-seed in the wait** (the store is
  stale on that path, so a non-forced re-seed would revalidate in the background and duplicate the
  forced fetch minutes later). An hour keeps two warms apart only while a warm's main phase finishes
  inside it — measured ~22s warm, ~10 minutes cold: a wide margin, not a bound. A
  `RESET_CACHE_ON_BUILD` clean-load build started in that hour refills at 05:xx.
- **PRE-EXISTING, NOT CHANGED:** the skip branch arms the clock at `clockIn` even when that is under
  `WARM_DELAY`, so a restart minutes before 05:xx having warmed the day before warms inside the boot
  window (6-12 boot-minutes a day in the simulation). A quality point, not a correctness one.
- **UNPROVEN LIVE, AND DELIBERATELY NOT STAGED (Simon, 2026-09-14 — "I'll be asleep").** The fold
  needs a start in the hour before 05:xx with the last warm missed. The rig never does that in
  routine use — it stops all services for a backup at 06:30 and restarts after — so the fold rests
  on `t_warmclock.pl` §6b and the chain simulation, and that is accepted. Do not list it as owed
  verification. If it ever fires, the line is `warm: scheduled warm due in Ns — folding this tick
  into it`. **What the rig's routine night DOES prove, with no one awake:** the 05:xx clock tick
  (`tick_at` at 05:xx) and, after the 06:30 backup restart, the SKIP branch + re-seed still open from
  the 0.9.216 round (`ticks` unchanged, `detail_main_ready` 1, no forced feed fetch) — read
  `["lbf","warmstats"]` over HTTP the next morning.

**CLOSED IN THE 0.9.218 REVIEW — the 2026-09-14 review of the 0.9.216-0.9.218 working tree. NO
FINDINGS; round CLOSED by Simon 2026-09-14; committed and pushed to `dev` the same day.** This entry
records a clean read, not a decision: it suppresses nothing, and every symbol below stays open to a
later round that brings new evidence. It exists so the next round need not re-derive these checks.
- **`_buildChanged` / `postinitPlugin` / `_armWarm`.** `_buildChanged` returns 0 or 1 and
  `postinitPlugin` hands that answer to `_armWarm`, so the build-changed branch is reachable.
- **`_lastWarmInstant` / `_secsUntilNextWarm`.** Both search a day wide on each side; the first
  returns the latest instant at or before now, the second the earliest strictly after it. The `>`
  keeps the re-arm strictly future, so a tick never re-arms for the instant it fires on.
- **`_catchUpFold` in `_warmTick`.** Runs after the scan defer and before the `warm_last_at` stamp, so
  a folded tick is never recorded as a warm. A scheduled tick cannot fold itself even when a scan
  delays it (its next instant is then ~24h out). A folded tick that later waits behind a scan still
  warms when the scan ends.
- **Skip path.** Always arms the clock; arms no re-seed when the clock is due within `WARM_DELAY`,
  so the flag race closed in the 0.9.216 round stays closed.
- **`Browse::reseedFromStore`.** Uses the warm's own labels (week order kept), calls the getters
  without `force`, and setting `$detailMainReady` directly is safe because `_detailPriorityBusy`
  still waits on Last.fm activity.
- **`_fanOutFeed`.** All four call sites in `warmFeeds` pass the same filtered lists as before.
- **RULED OUT, with the reason:** the re-seed waits for neither a library scan nor streaming
  readiness, and releases the detail queue ~180s after boot. Harmless: `_warmReleaseDetails`
  checks `streamingNotReady()` itself and backs off 300s, and the album resolver `_findPlayable`
  never reads the local library, so a half-scanned library cannot cache a wrong answer there.
  Re-raise only with a consumer of the released queue that DOES read the library.

**CLOSED IN THE 0.9.219 REVIEW — the 2026-09-14 review of the 0.9.219 working tree (MusicBrainz
queue, community-API queue, ListenBrainz-first tracklists, A–Z artist sort, alias pass). NO
FINDINGS; round CLOSED by Simon 2026-09-14; committed and pushed to `dev` the same day.** A clean
read, not a decision: it suppresses nothing, and every symbol below stays open to new evidence.
- **`_mbGet` / `_mbPump` / `_mbSend`.** Re-entrancy guard, timer handling and watchdog hold;
  `LostResponse` answers the `->code` / `->error` that `_mbIsRateLimited` and `_handleError` call.
- **`_hostedGet` / `_hostedPump` / `_hostedSend`.** The slot is released exactly once, a 429 job
  goes back to the queue head BEFORE the release, a callback after the watchdog is ignored.
- **Callers.** Both DSTM `getArtistMbidByName` callers handle the new error callback; every
  `_findPlayable` caller passes the artist MBID as the 9th argument. Three direct MusicBrainz calls
  remain: the mirror-only genre fetch (§A2) and `getReleaseDetails` / Diag, both now queued.
- **`getReleaseGroupByName` / `getArtistAliases`.** A failed lookup is not cached, an answered empty
  one is; by-MBID and by-name cache keys differ; the unknown-artist no-MBID check is kept.
- **Alias pass.** Once, clean misses only, a failed lookup makes the miss inconclusive; the VA check
  works (`VA_MBID` is defined in `Browse.pm`); `_albumMatchesAlt` still requires the title.
- **`peekTracklist` / `getTracklist`.** Every LB-answer × MB-answer × missing-id combination handled;
  `_warmReleaseDetails` retries; `SingleFlight` join/resolve arguments match its API.
- **Diag.** Backoff rows are excluded from the pending count; `$started` is set at the queue's send.
- **RULED OUT, with the reason:** `getReleaseDetails` no longer checks `$live` before a queued send,
  so a send could outlive its 120s single-flight claim. Nothing waits that long today: `DetailWarm`
  has ONE active slot and the MB backoff tops out at 30s. Re-raise if either changes.

**CLOSED IN THE 1.0.1 REVIEW — the 2026-09-16 review of the Spotify back-off working tree. Two
findings, both fixed and built as 1.0.2, INSTALLED 2026-09-16; round CLOSED by Simon the same day.**
Closes the two defects as described. **The fix code is new and open to review** — `$pumping`,
`$gapTimer` in `_resolveTracks`, the `'refused'` tag in `_searchSpotify` / `_searchSpotifyTrack`, and
`$refused` in `_findPlayable` / `_findPlayableTrack` are in scope for any later round.
- **`_resolveTracks` paced gap: cached tracks each armed a timer.** A cache hit answers synchronously
  from inside the pump loop, and the completion had no re-entrancy guard, so while backing off every
  cached track armed its own `PACED_TRACK_GAP` timer; the strays later launched live searches back to
  back (the comment claiming a cache hit "never gets here" was the defect's disguise). Fixed with the
  `$pumping` guard (Pitchfork's shape) plus ONE pending `$gapTimer` that each live completion re-arms,
  which also covers several searches in flight when the back-off begins — a case PFR does not guard.
- **The free pass keyed on `_spotifyBackingOff()`, not on the refusal**, in both `$cacheItem` (track)
  and `$store` (album). Any inconclusive miss inside the 30s window kept its attempt — a search
  Spotify really answered, or another service's timeout. Fixed: the adapters answer
  `$collect->(undef, 'refused')` and each `$settle` counts the tag into a per-resolve `$refused`.
- **Guard:** `t_spotifybackoff.pl` 37 -> 57 (§3 window held ON as the discriminator, §3b the real
  track resolver, §2 the adapter tag, §4 the measured live-launch gap). Anti-tested six ways; the
  original pump fails the measured gap. **Stated, not missed:** with only `$pumping` removed the gap
  still holds (the re-armed wakeup absorbs the strays), so only the timer-count assertion sees it.
- **Not changed, deliberately:** `docs/streaming-adapter-spec.md` §6 — its wording still holds, and an
  edit there must be re-copied to PFR and LL.
- **UNPROVEN LIVE:** installed and loaded, but no Spotify search refusal had occurred on 1.0.2 at
  close. Evidence to look for is in the section at the top (`## Spotify back-off —`).

**CLOSED IN THE 1.0.5 REVIEW — the fourth 2026-09-16 review of the Spotify back-off (commits
`7e5bf4e..199b6b9`, i.e. what 1.0.4 and 1.0.5 ADDED). NO findings. Round CLOSED by Simon; all
three commits PUSHED to `dev` the same day. Not installed.** Recorded so the next round knows
what was checked — **not a suppression**: the fix code stays open to a finding with new evidence.
- **Checked and held:** `$warm` off `$onPending` for all three `_buildAlbumsData` callers (the view
  passes the hook, both warm ranges pass four args); the gate's three-way arm, its `$finish` killing
  `$gapTimer`, and no stall when holding with work in flight or at `TRENDING_MAX`; the token at all
  five release sites, `$owns` read at CALL time where the wrapper is built before the take, a stale
  release leaving the newer pass's timer alone, and the playlist warm/view sharing `playlist:$mbid`;
  the refusal signal at both `_findPlayableTrack` sites (cached returns send none), the stamp written
  before the callback so the back-off read is already true, `$holding` ending the loop, and
  `_refused` reaching the gate through SingleFlight (a joiner is always async). `_resolveTracks`'
  `$finish` not killing `$gapTimer` is harmless (`unless $finished`).
- **OBSERVED, DELIBERATELY NOT REPORTED — pre-1.0.4 (0.9.109):** the albums gate counts an album
  whose streaming check failed — a Spotify refusal included — as a DROP, so a gate that finishes
  inside its 45s watchdog caches the list at the full 7d/30d without it. Pacing makes this rarer (a
  refused gate is slow and usually times out into the 1h TTL). `_refused` on the result hash would
  now let the gate file such a list short. **Re-raise only with a real list seen missing an album
  this way.**
- **PFR port DONE (working tree, 2026-09-16):** the same synchronous-refusal and single-wakeup
  defects were verified in PFR by driving its real `_resolveSection` (10 refused albums in ONE turn,
  no gap; 10 wakeups left pending with a stray launching straight after a completion), and fixed
  there as 0.9.39 — unbuilt at the time of writing. Tracked in PFR (its ledger §C
  `SYNCHRONOUS SPOTIFY REFUSAL AND ONE`), not here.

**CLOSED IN THE 1.0.3 REVIEW — the third 2026-09-16 review of the Spotify back-off (the 1.0.3
working tree). THREE findings, all fixed: finding 1 BUILT AS 1.0.4, findings 2 and 3 BUILT AS
1.0.5; NEITHER INSTALLED at close. ROUND CLOSED BY SIMON 2026-09-16, after the 1.0.5 review
(below) found nothing; pushed to `dev`.** Closes the defects as described.

**Findings 2 and 3 were reported with finding 1 and left out of the 1.0.4 build — that was a
scoping miss, not a decision; nothing about them was declined.**

**BUILT AS 1.0.5, 2026-09-16; REBUILT THE SAME DAY WITHOUT A VERSION BUMP; NOT YET INSTALLED.**
The first 1.0.5 zip (710,519 bytes, sha `23c93020…`) was followed by the post-build doc review, which
corrected one COMMENT in `Browse.pm` (the `$pumping` note in `_resolveTracks` now says a synchronous
refusal DOES arm the wakeup); no code changed. **Rebuilt as 1.0.5 rather than 1.0.6 on Simon's call:
the first zip was never installed or pushed, so no rig or user can hold a different "1.0.5"** — the
bump-every-rebuild rule exists to tell INSTALLED builds apart, and none was. Current zip:
`install.xml` / `repo.xml` 1.0.5, 54 entries, 710,605 bytes, `repo.xml <sha>`
`9659e0fd21f60bcd041f83dde1287db905574995`. The checks below were re-run against the REBUILT zip. `diff -r`
of the unzipped archive against the tree is IDENTICAL; the extracted `Browse.pm` carries the token
counter, all five token releases, both `$holding` loops and both refusal signals; and
`t_spotifybackoff` (100), `t_buildingstate` (87), `t_playlistresolve` (58) and `t_trending_empty`
(27) pass with `LBF_BROWSE` on the EXTRACTED copy, `t_loads` (20) with `LBF_PLUGIN` on it. **All 37
suites exit 0; both sync checks 0.** `DEV_BUILD` 0, `RESET_CACHE_ON_BUILD` 0, no key version
bumped (the result hash gains an in-memory `_refused` key; nothing stores it). `README.html` /
`index.html` regenerated; `CHANGELOG.md` untouched.

- **FINDING 2 — a late release freed a NEWER pass's flag.** `_buildingEnd` deleted
  unconditionally, and `BUILDING_MAX`(180s) is a backstop, so both can hit one key: pass A
  outlives its flag, the backstop frees it, a view starts pass B, then A finishes and frees B's
  flag — and a third opener starts a third fan-out. **Reachable:** `_resolveTrending` takes its
  flag BEFORE a 30s fan-out and a metadata fill, then resolves under `PLAYLIST_RESOLVE_TIMEOUT`
  (150s); 30+150 is past 180 before the network counts, and a paced pass in a sustained refusal
  runs to that watchdog. **The comment "PLAYLIST_RESOLVE_TIMEOUT is deliberately under
  BUILDING_MAX, so the normal path always releases first" is TRUE for the playlist warm only**
  (it takes the flag right before the resolve) — it was read as a file-wide invariant; both it and
  the §`FIX 2` note now say which call site. **Fix:** `_buildingStart` returns a token
  (`$BUILDING_SEQ`), every caller already kept the return in `$owns`, and releases as
  `_buildingEnd($bkey, $owns)`; a stale token is a no-op, and the expiry timer checks its own
  token too. A release with NO token keeps the old free-whatever-is-there contract.
  **Not chosen:** raising `BUILDING_MAX` (moves the edge, does not remove it) or taking the flag
  later in `_resolveTrending` (reopens the duplicate fan-out window it closes).
- **FINDING 3 — a SYNCHRONOUS Spotify refusal skipped the paced gap. PLAUSIBLE at review, now
  VERIFIED against Spotty's `API.pm` (master, 2026-09-16):** `getToken` does
  `return $cb->(-429)` while `spotty_rate_limit_exceeded` stands, and `_call` hands that straight
  to its caller — same stack, no timer. On libMode `never` (`prefer_library` off) there is no
  `$deferLocal` tick, so for a Spotify-ONLY user the whole resolve answered synchronously and hit
  the `$pumping` (cache-hit) arm: the pass ran every track through the lockout in one turn, each
  spending a free pass on a search never sent — where pacing would let Spotty's 2-7s lockout
  lapse after a few. `first` and `exclude` always tick through `$deferLocal` and were never
  exposed; a user with a second service gets an async completion and was never exposed either.
  **The album gate built in 1.0.4 had the same shape.** **Fix:** the resolvers SAY so —
  `_findPlayableTrack`'s 4th callback arg, `_refused` on `_findPlayable`'s result hash (it rides
  through SingleFlight like `_warm_pending`) — and both pumps arm the gap on
  `!$pumping || $refusedNow`. **And both gained `$holding`**, which the arm alone could not
  replace: a wakeup armed from INSIDE the loop does not stop the loop, which at width 1 launches
  the next search straight away. The DetailWarm queue needed nothing — it runs ONE job per
  timer tick and checks `pause` (`_detailPriorityBusy`) before each, so a job that finishes
  synchronously still cannot start the next one inside a refusal.
  **Stated consequence:** while a wakeup is pending, a completion arriving after the window has
  lapsed waits for that wakeup (≤ `PACED_TRACK_GAP`) instead of launching at once. It cannot stall:
  the wakeup always fires, and the watchdog still bounds the pass.
  **The synchronous chain was READ, link by link, not inferred:** `_searchSpotify` /
  `_searchSpotifyTrack` call `$api->search` directly; Spotty's `Pipeline` adds no deferral;
  `_call` and `getToken` answer the refusal in-stack; on our side the adapters' `run` /
  `runTrack` are called inline, the per-service timeout is killed on settle, a refusal is
  inconclusive so the album alias pass never runs, and SingleFlight's `_land` calls its waiters
  directly.
- **Guards.** `t_buildingstate.pl` 77 -> **87**: the race driven step by step (A's late release
  and A's re-entered expiry both leave B's flag and timer alone). `t_spotifybackoff.pl` 81 ->
  **100**: §4d drives a synchronous refusal through BOTH pumps (window closed at start and
  opened by the refusal; cached-then-refused; views never held), and §3b checks the REAL
  resolvers send the signal — 4d's stubs manufacture it, so without 3b a resolver that stopped
  sending it passed. `t_playlistresolve.pl` declares `$BUILDING_SEQ` beside the two hashes it
  lifts. **ANTI-TESTED NINE WAYS, each failing only its own checks:** release ignores token 3;
  expiry ignores token 2; `_resolveTrending` releases without token 2; track pump ignores the
  refusal 6; gate ignores it 5; track loop ignores `$holding` 4; gate loop ignores it 4 (incl.
  its source check); album resolver stops sending `_refused` 2; track resolver stops sending the
  4th arg 2. **The first version of the signal check did not exist and r5 passed against it —
  that is why §3b gained its two loops.**
- **STILL NOT TOUCHED:** `docs/streaming-adapter-spec.md` §6 ("two consumers") — fleet copy,
  cross-repo re-copy, Simon's call.
- **UNPROVEN LIVE.**

**CORRECTION to the 1.0.4 build note below:** `t_loads.pl` reads `LBF_PLUGIN`, not `LBF_BROWSE`,
so the 1.0.4 run said to be "against the EXTRACTED copy" ran against the tree. The `diff -r` was
identical, so the verdict stands; the 1.0.5 run above set `LBF_PLUGIN` and did test the zip.

**BUILT AS 1.0.4, 2026-09-16; NOT YET INSTALLED.** `install.xml` / `repo.xml` 1.0.4, zip rebuilt
(54 entries, 708,749 bytes), `repo.xml <sha>` recomputed to
`211daa719f9748ac64e6480ec620e589f5ebe829`. Verified against the zip on disk rather than assumed:
`diff -r` of the unzipped archive against the tree is IDENTICAL, its `install.xml` reads 1.0.4,
its `Browse.pm` carries the `$warm`/`$onPending` read and BOTH `$pumping` guards (the track pump's
and the gate's), and `t_loads.pl` (20/20) and `t_spotifybackoff.pl` (81/81) both pass against the
EXTRACTED copy, not just the tree. `DEV_BUILD` 0, `RESET_CACHE_ON_BUILD` 0, **no key version
bumped — the change is timing only and moves no stored shape, so caches are deliberately
preserved.** `README.html`/`index.html` regenerated (the badge reads live from `install.xml`).
`CHANGELOG.md` untouched — that is written at the merge to main.
- **The trending-albums STREAMING GATE was unpaced, and is the THIRD Spotify pump.** Both earlier
  rounds fixed the track side and recorded that "the album side is `_detailPriorityBusy`". That
  was wrong, and the wrong sentence is why two rounds missed this: `_detailPriorityBusy` is the
  `DetailWarm` queue's `pause` hook and **nothing else consults it**. `_buildAlbumsData`'s gate
  calls `_findPlayable` DIRECTLY rather than through `_resolveTracks`, so it never saw `paced`
  and no grep for that symbol could reach it. It was a **WRITER** of `$SPOTIFY_REFUSED_AT` (via
  `_searchSpotify`) that never read it — 60 pooled albums (`TRENDING_MAX`+10) per range, two
  ranges per `_warmTrending`, five wide, straight back into the quota it had just closed.
- **WHY THE NAME HELPED HIDE IT:** the 1.0.2 entry says "the follow-feed and trending warms".
  "Trending" there is `_resolveTrending` — the TRACKS. The two album builds sit in the SAME sub,
  `_warmTrending`, on the same serial chain, and read as covered by that sentence. They were not.
- **The warm/view flag is `$onPending`, not `$onDone`.** The VIEW passes a pending hook (it needs
  the building row); the warm chain passes four args. Unlike `_resolveTrending`'s `$callback`,
  `$onPending` is **never reassigned** in the sub, so the read is stable — but it is still taken
  at ENTRY, so the next person to add a detach here does not have to rediscover 1.0.2's trap.
- **A WIDTH-ONLY FIX WOULD HAVE BEEN A 1.0.1 REGRESSION, and this is the whole point.**
  `_findPlayable` answers SYNCHRONOUSLY on a play-via cache hit, and the gate's completion
  already re-enters the pump. Without `$pumping` and ONE shared `$gapTimer`, every cached album
  in a backing-off gate arms its own wakeup and the strays later fire live searches back to back
  — the exact 1.0.1 defect, rebuilt on the album side. The three-way arm is ported verbatim.
- **ACCEPTED, and it is Simon's call, not an oversight:** the gate's watchdog is
  `PLAYLIST_TIMEOUT` (45s), a THIRD of the track path's 150s, and a paced gate cannot finish
  under it (60 albums × `PACED_TRACK_GAP` ≈ 120s). A gate held narrow for its whole run times
  out, files at `PLAYLIST_INCONCLUSIVE_TTL` (1h) and rebuilds an hour later. **Chosen over
  exempting the gate after N launches:** a trending list an hour stale costs nobody anything;
  60 more searches into a closed quota locks the user out of their own Spotify. The 30s window
  means the common case never reaches the watchdog at all.
- **Guard:** `t_spotifybackoff.pl` 62 -> **81**, new §4c — the gate DRIVEN, not source-grepped,
  because a width-only fix passes any source check. Full width when healthy; one at a time with
  the gap while refusing; a VIEW never paced; the watchdog fired DIRECTLY (advance() always fires
  the nearer timer first, so it can never observe what `$finish` leaves behind).
  **ANTI-TESTED FIVE WAYS, each failing only its own checks:** re-entry guard removed 1; the
  synchronous arm removed (the 1.0.1 shape) 1; width read reverted to the literal 5 → 7; `$warm`
  forced to 1 (view paced) 2; the finish-time timer kill removed 1.
  **An ALL-cached pass cannot see the 1.0.1 shape** — each stray re-arms the one before it and
  `$finish` kills the last, so every count looks right. It takes a MIXED pass (4 cached then a
  live one) to strand the stray. That absorption is the same one the 1.0.1 round recorded on the
  track side; the first version of §4c missed it and passed against the mutant.
- `t_trending_empty.pl` lifts `_buildAlbumsData` verbatim, so it gained `PACED_TRACK_GAP` and a
  `_spotifyBackingOff` stub held OFF — pacing must not change what an empty build caches (27/27).
- **All 37 suites exit 0**, `t_loads.pl` 20/20, both sync checks 0.
- **STILL WRONG ELSEWHERE, deliberately not touched:** `docs/streaming-adapter-spec.md` §6 says
  "`_resolveTracks`'s `paced` option and `_detailPriorityBusy` are the two consumers". That is
  now three. The spec is the FLEET copy and an edit must be re-copied to PFR and LL with a new
  sha1 in all three — a cross-repo change, not this round's to make unasked.
- **UNPROVEN LIVE**, like the rest of the back-off — and not yet built.

**CLOSED IN THE 1.0.2 REVIEW — the second 2026-09-16 review of the Spotify back-off (the 1.0.2 working
tree). One finding, fixed and built as 1.0.3 (`repo.xml <sha>` `2ee4780e…`); INSTALLED 2026-09-16 13:46; round not yet closed by Simon.** Closes the
defect as described. **The fix code is open to review** — the `$warm` reads in `_resolveFollow` and
`_resolveTrending`.
- **The follow-feed and trending WARMS resolved unpaced.** Only the playlist warm passed `paced => 1`;
  `_warmFollow` -> `_resolveFollow` and `_warmTrending` -> `_resolveTrending($client, undef, ...)` did not,
  though the header comment over `SPOTIFY_BACKOFF_WINDOW` said the warm as a whole narrows. So during a
  refusal both kept searching at full width with no gap — trending at `TREND_RESOLVE_CONC` (10) over
  `TRENDING_CANDIDATES` (80) — and could push the shared Spotty client id straight back over the limit.
  The last round's two fixes did not cover it: they were inside the pump, not at its callers.
- **The first remedy proposed was WRONG, and is recorded so it is not re-proposed:** "pass `paced` when
  `$callback` is undef" at the resolve call. Both subs set `$callback = undef` on a VIEW's cold build
  (the building-row detach) before resolving, so at that point the view and the warm look alike and the
  view would have been paced — against point 2 above. **Fixed instead with `my $warm = !$callback;` at
  ENTRY** in both subs, and `paced => $warm`. The callers bear it out: the views (`resolveFollowFeed`,
  `resolveTrending`) always pass a callback, the warm passes `undef`.
- **Guard:** `t_spotifybackoff.pl` 57 -> 62, §4b: `_resolveFollow` lifted verbatim and CALLED both ways
  (warm paced; view unpaced though detached, and the detach confirmed to have happened);
  `_resolveTrending` sits behind a follower fan-out, so its read-before-detach order and `paced => $warm`
  are checked in source. **Anti-tested five ways, each failing only its own check:** follow `$warm`
  moved below the detach 1; follow `paced` dropped 1; trending `paced` dropped 1; trending `paced => 1` 1;
  trending `$warm` moved below the detach 1. All 37 suites exit 0; both sync checks 0.
  **`t_db.pl` failed ONCE in the full run and passed on six reruns**; neither it nor `DB.pm` is touched
  by this change — intermittent, cause not investigated.
- **Accepted consequence, stated:** a paced trending pass during a long refusal can outrun
  `PLAYLIST_RESOLVE_TIMEOUT` (150s); the watchdog then files it at the short TTL and it re-resolves —
  the same as the playlist warm already does. Full width returns 30s after the last refusal.
- **UNPROVEN LIVE**, like the rest of the back-off.

**A closed finding is not a closed MECHANISM.** Both 0.9.192 findings were
second-order consequences of the 0.9.191 fixes — not regressions of old code, and
not re-reports either. A fix that changes WHO participates in a mechanism (which
roles claim a guard, which callers reach a fetch) is worth re-reading from the
OTHER end of it: the release, the caller, the consumer. That is new information
about a closed entry, and it is exactly what section C wants reported.

### D. ADDING TO THIS LEDGER

When a finding is declined, or accepted-but-deferred, add it here in the same
session — one line, with the reason. A decision that lives only in a chat
transcript will be rediscovered as a finding within days. That is the whole
mechanism this ledger replaces.

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

- **New Releases for You** — personalised feed of fresh releases from artists in your ListenBrainz history (needs a username; **no token** since 0.9.160). Newest-first, grouped by week, tap-through detail pages. **Optional MuSpy** — add a MuSpy user ID (public, no password) to fold in releases from the artists you follow there; more tailored since you pick the artists, and overlaps with ListenBrainz are shown once. MuSpy has no window of its own: its releases follow New Releases for You's **Weeks to show / Upcoming weeks**, and anything announced further ahead appears as the weeks roll forward each Monday.
- **All Releases** — the global ListenBrainz fresh-releases feed (no account). By-week landing page to jump to any week.
- **Created-for-You Playlists** — your **Weekly Jams / Weekly Exploration / Daily Jams** as fully-streaming **Play-all** lists; every track matched **library-first**, then streaming.
- **People You Follow** *(optional; toggle in Settings → General, default on)* — a whole section built from what the people you follow **actually play** (public listen-stats — username only; **one-vote-per-follower** breadth ranking). **Trending Tracks** (weekly, Play-all, owned-excluded, album-level so a full-album play can't flood it) + **Trending Albums · This Month / · This Year** (tap-through album pages with art/date/type). Plus **Recommended** — the tracks they **recommend/pin** (needs a token; the feed is private), one newest-first **new-music-only** Play-all list with **day dividers**, accumulating so recs aren't lost as the feed rolls. Off = nothing here is fetched, cached or warmed.
- **Don't Stop The Music — two auto-DJ mixers** — **ListenBrainz Radio** (seeds from what's playing and evolves through similar artists) + **Recommended for You** (personalised CF picks, shuffled). Owned copies first, no per-session repeats, varied artists.
- **Rich release detail pages** — artist **photo + biography**, **tracklist** with durations, **genres**, tags, **View on MusicBrainz**, and inline **one-tap streaming matches**.
- **Direct streaming playback** — matched albums/tracks play from **Qobuz / Tidal / Bandcamp / Deezer / Spotify** (via Spotty); you choose the per-service search order.
- **Block artists** — one tap hides an artist from every feed.
- **Material home shelves** — optional New Releases for You / Playlists / All Releases home rows.
- **Albums or Singles & EPs, from the list** — a "Showing Albums (tap for Singles & EPs)" row flips either feed between the two and back, with the icon changing to match, so singles and EPs can stay switched on without burying the albums. Sticks across visits and restarts; only appears when a section has both kinds ticked.
- **Your taste** — filter by type / artwork-only / Various Artists; **per-view sort** (a "Sorted by…" toggle in each list's Options section — Release Date / Artist / Album Title, kept within the weekly W/C headers); a **per-section release window** (Weeks to show + Upcoming weeks, the current week counted as week 1; default this week + next week in both sections); the **Artist** sort is A–Z on the name shown, skipping a leading article; cached & pre-warmed (instant), **no extra server software**.
- **Plays nicely with Listen Later** — adding a release passes the real MusicBrainz release type (album / EP / single) across, which the streaming services mostly don't expose, so the saved row is labelled and play-tracked correctly rather than guessed from a track count.

**Requirements:** LMS 9.0.0+ (Material Skin); a ListenBrainz **username** for the personalised features — no API token (All Releases needs nothing). A token is **optional** and adds only the *Recommended* list under People You Follow, whose feed is genuinely private. Optional Qobuz/Tidal/Bandcamp/Deezer/Spotify-via-Spotty (playback), MAI plugin (artist photos+bios — **the only bio source since 0.9.186**), Last.fm is **built in** (the genre ladder's tier 5, and DSTM similar artists — no key to set, and no settings field for one). Every optional add-on degrades gracefully.

**Install:** add `https://simonarnold002.github.io/LMS-ListenBrainz-New-Releases/repo.xml` in LMS → Settings → Plugins.

## Server Details
- **LMS Server**: 192.168.1.234:9000
- **OS**: DietPi (Debian Bookworm)
- **Service**: `lyrionmusicserver`
- **Plugin location (manual install)**: `/var/lib/squeezeboxserver/Plugins/ListenBrainzFreshReleases/`
- **Plugin location (repo install)**: `/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/ListenBrainzFreshReleases/`
- **Log**: `/var/log/squeezeboxserver/server.log`
- **Material Skin**: `/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/MaterialSkin/` (moved from manual to repo install)

## Testing over the CLI — READ THIS BEFORE CONCLUDING ANYTHING FROM A WALK

`http://plex:9000/jsonrpc.js` reaches everything headlessly, off-network, and needs no
log access. Three reports answer most questions without touching `server.log`:
`["lbf","cachestats"]`, `["lbf","warmstats"]` and `["lbf","diag"]`. **All three now
report `plugin_version`** — check it FIRST (see the 0.9.209 entry: a repo-installed copy
shadows a manual install, and nothing else observed is meaningful until you know which
package answered).

**THE TRAP, and it cost a false "genres are completely broken" reading on 2026-09-10:**
- **`["listenbrainzfreshreleases","items",…]` does NOT serialise `line2`.** The genre
  label lives there, so a walk done this way returns rows with no genre on them and
  looks exactly like total genre failure. **Use `menu:menu`**, which returns `text` as
  `"<name>\n<line2>"`.
- **The browse dispatch needs a PLAYER ID.** The plugin registers `is_app => 1`, so a
  request with an empty player returns an EMPTY BODY, not an error. The three `lbf`
  reports above need no player; the browse walk does.
- **A drill by `item_id` is BY POSITION** ([[xmlbrowser-positional-crumb-order]]), and
  some of those positions are ACTIONS, not folders — `item_id:<week>.1.0` is "Show N
  releases", which CLEARS the genre filter. Prefer the natural key: `lbf_week:<date>`
  opens an All Releases week directly and is validated, so a bogus date returns an
  empty shell rather than the wrong week.

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
├── DB.pm                              # The durable SQLite store behind the release feeds. THREE TIERS: BASE (release/feed_member/feed_day/feed_meta/bandcamp_pin/follow_item) invalidates only through BASE_VERSION; FACTS (release_group/recording/artist) through their own *_FACT_VERSION; DERIVED (kv) through per-family key versions. Ordinary version changes preserve all three; `wipeDerived` + `wipeGenres` run only for an explicit clean-load test
├── DetailWarm.pm                      # The overnight/background DETAIL pre-warm queue (0.9.200) — pre-resolves a new release's tracklist and streaming matches so opening it is a store read, not a live fetch. Priority-keyed sources, restart checkpoints, a worker watchdog; section date bounds come from Browse::_sectionBounds (the UNION of the For You and MuSpy windows — see the 0.9.207 entry for why a per-release source tag loses the prewarm)
├── SingleFlight.pm                    # SHARED FLEET MODULE (canonical copy — see tools/singleflight_sync_check.py). The one async coalescing registry: claim / park / fan out / watchdog. Replaces the THIRTEEN hand-rolled guards across four repos (LBF %BUILDING/%INFLIGHT/%coverQueued/%sortInFlight/%agenInFlight, LL %counting/%trackPending, PFR %PENDING/%RESOLVING, DSC %nameRefetched/%candWaiting/%bandsInFlight/%officialInFlight) that between them produced the same four review findings, one site at a time, for weeks
├── Diag.pm                            # Server-side connectivity report — probes every upstream host (LB, LB Labs, MusicBrainz via _mbBase, the MB search index, CAA, Last.fm, MuSpy) in parallel and returns ok/warn/fail/skip per target; driven by the ["lbf","diag"] CLI dispatch in Plugin.pm and by the Settings page's Connection Check section
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
├── singleflight_sync_check.py         # Cross-repo drift check for SingleFlight.pm — same rule and same shape as matcher_sync_check.py (canonical = LBF; hash-pinned variants; a repo with no copy yet is "not adopted", not drift). Run after ANY edit to the registry
├── t_singleflight.pl                  # Behavioural suite for SingleFlight.pm (38 assertions): owner-only work, release on success AND failure, the watchdog releasing BY ANSWERING, a dying owner stranding nobody, idempotent landing. Carries its own anti-test — 4/4 mutants caught
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

**1.0.0** — version-only bump 2026-09-15, code identical to 0.9.220 (committed as 76c1030). Major version for submission to the Lyrion official repo. **NOT installed, NOT reviewed.**
`DEV_BUILD` set to **0 on `dev`** (2026-09-15, Simon) so this zip is the one `main` ships — it is
telemetry only (the `dev_build` stats field) and wipes nothing either way; zip rebuilt and sha
recomputed, version kept at 1.0.0. `RESET_CACHE_ON_BUILD` still 0. The only line still to reconcile
at the merge is `repo.xml` `<url>`.

**0.9.220** — built 2026-09-15. The "Round of
2026-09-15" section at the top of this file:
- **Week window defaults `2`/`1` for both sections** (this week + next week) — `API::%WEEK_PREFS` and
  `Plugin.pm` `$prefs->init`, agreeing as `t_weekwindow.pl` §5 requires. No migration; an install
  that already stored week values keeps them.
- **`API::_mbGet(..., front => 1)`** — joins ahead of ordinary jobs (FIFO among front jobs), still
  behind the request in flight, `MB_GAP` and the 503 backoff. Used ONLY by `Diag`'s two MusicBrainz
  probes. A queued probe the 12s deadline catches unsent reads `warn` / "not probed".
- **`PLUGIN_LBF_DIAG_DESC`** lists Labs, the search index and the LMS-community API.
- **No schema rung, no cache family bumped** — nothing cached changed shape; the window already
  feeds `_sectionSig` and the feed memo keys, so a changed default re-derives on its own.
  `DEV_BUILD => 1`, `RESET_CACHE_ON_BUILD => 0`.
- Guards: `t_mbqueue.pl` §4b (75), `t_diag.pl` §10 (83-84: §7 is a live MusicBrainz call that SKIPs
  when rate-limited), `t_weekwindow.pl` (71). All 36 suites exit 0; `bench_walk.pl` still exits 255
  on its stale `lastfmConfigured` stub (pre-existing, 0.9.213). Six mutants on the queue/Diag fix,
  each red.

**0.9.219** — built 2026-09-14, **INSTALLED on the test rig 2026-09-14 23:05; review CLOSED and pushed
to `dev` (b9f9a69); superseded by 0.9.220.** Artist sort A–Z PROVEN live 2026-09-15; the MusicBrainz
queue PROVEN live 2026-09-15 (no refusal across the 05:00 overnight warm and a restart — see the
"Round of 2026-09-15" section); radio lookup and the streaming alias pass UNPROVEN LIVE (INFO-only
traces). The two working-tree
sections at the top of this file, built together: **MusicBrainz 503s** (one MusicBrainz queue, one
community-API queue, Trending album search community-API only, tracklists ListenBrainz-first) and
**Artist sort A–Z, radio lookup, streaming aliases** (no MusicBrainz sort-name, the sort columns and
store API dropped, `getArtistMbidByName` on `/aliases` only, a one-pass streaming alias retry).
Read those two sections and Ledger §A2 `ONE MUSICBRAINZ QUEUE, ONE COMMUNITY-API QUEUE`,
`ARTIST SORT IS A–Z ON THE DISPLAY NAME`, `STREAMING ALIAS PASS`.
- **No schema rung.** The `artist` CREATE lost `sort_name`/`sort_src`/`sort_at` in place — `main`
  ships no `DB.pm`, so no released db holds them. A dev db built before this keeps the dead columns
  harmlessly; nothing reads them.
- **Cache families:** `lbf:aliases:` 1 added, `lbf:artistmbid:` retired (orphans age out).
  `lbf:stream:` deliberately NOT bumped — the shared matcher is untouched, and a cached miss re-tries
  on the normal miss schedule, which is when the alias pass gets its chance.
- **Stale-reference sweep at build:** Diag's community-API row probed `/mbid` and its amber note said
  "MusicBrainz fallback still applies" — now `/aliases` and "the radio may fall back to generic
  recommendations"; four comments (API.pm ×3, DB.pm) and the `scheduled-overnight-warm.md` EXISTS
  table no longer describe the sort warm as live.

**TESTS.** All 36 `tools/t_*.pl` exit 0; both sync checks 0; `git diff --check` clean; `t_loads.pl`
20/20 against the BUILT ZIP, extracted and diffed byte-identical against the working tree;
`t_buildwipe.pl` 44/44 (`DEV_BUILD` 1, `RESET_CACHE_ON_BUILD` 0 — caches preserved).

**0.9.218** — built 2026-09-14, **NOT installed; reviewed clean and pushed to `dev` 2026-09-14; superseded by 0.9.219**
(Ledger §C `CLOSED IN THE 0.9.218 REVIEW —`). **A TICK THAT LANDS JUST BEFORE THE SCHEDULED
WARM FOLDS INTO IT.** No schema change, no cache-family bump, no stored shape changed; caches are
preserved as on every ordinary build. One mechanism: `Plugin::_catchUpFold`, asked at the top of
`_warmTick` after the scan defer, with `WARM_MERGE` 3600. Everything in the 0.9.217 and 0.9.216
entries below still describes what ships. Full record, including the two fixes that did NOT work:
Ledger §C (`CLOSED IN THE 0.9.217 REVIEW —`).
- **The defect:** a catch-up tick (or a scan-deferred one) that warmed just before 05:xx re-armed for
  seconds later, so two complete warms ran over each other and the second reset the first's detail
  phase. Now a tick whose scheduled instant is within an hour re-arms for it instead of warming.
- **`WARM_HOUR` stays 05:00** — 03:30 was asked for and declined the same day (For You a day behind in
  Europe; inside the EET DST hour). Ledger §A2 `WARM_HOUR STAYS AT 05:00 LOCAL`.

**TESTS.** `t_warmclock.pl` 46 -> **57** (§6b), green in London, Helsinki, New York, Lord Howe and
Santiago; anti-tested three ways (8 / 1 / 2 red). All 34 `tools/t_*.pl` exit 0; both sync checks 0;
`t_loads.pl` 20/20 against the BUILT ZIP, extracted and diffed byte-identical against the working
tree.

**0.9.217** — built 2026-09-14, **INSTALLED on the test rig 2026-09-14 16:54; superseded by 0.9.218
(built, not installed); catch-up warm verified live; review CLOSED — see Ledger §C
(`CLOSED IN THE 0.9.216 REVIEW`).** **THE THREE 0.9.216 REVIEW
FIXES, BUILT.** No schema change, no cache-family bump, no stored shape changed, and caches are
preserved as on every ordinary build (`RESET_CACHE_ON_BUILD` 0, `t_buildwipe.pl` 44/44).
Everything in the 0.9.216 entry below still describes what ships; read it with these three
corrections. Full record: Ledger §C (`CLOSED IN THE 0.9.216 REVIEW —`) and the status block of
`docs/scheduled-overnight-warm.md`.
1. **`reseedFromStore` fans out under the warm's own labels.** The `(re-seed)` suffix defeated
   the `eq 'all releases'` week ordering in `_warmCovers` / `_queueReleaseDetails`, so a restart
   queued covers and details newest-release-date-first.
2. **The overnight clock builds a real local time** (`_warmInstantOn`, `POSIX::mktime` isdst -1).
   The seconds-arithmetic helper ran the warm TWICE on the autumn DST morning (04:10 and 05:10
   GMT, 2026-10-25); `_lastWarmInstant` had the same slop. Both candidate loops start a day wide.
3. **`_armWarm` skips the re-seed when the clock is due within `WARM_DELAY`**, so a restart just
   before 05:00 cannot release `$detailMainReady` mid-warm.

**TESTS.** `t_warmclock.pl` 37 -> **46** (§3 follows the re-arm chain across both DST changes;
§6 pins the `WARM_DELAY` boundary; `LBF_TZ=` runs it in any zone — green in seven DST zones
including Lord Howe and Santiago). `t_detailwarm.pl` 45 -> **46** (§9 reads the labels out of
`warmFeeds`). Anti-tested six ways, each failing only its own property: seconds arithmetic
**3 red**, old `_lastWarmInstant` **1**, `>=` boundary **4**, UTC-built instant **14**,
re-seed armed unconditionally **2**, `(re-seed)` suffix restored **1**. All 34 `tools/t_*.pl`
exit 0; both sync checks 0; `t_loads.pl` 20/20 against the BUILT ZIP, extracted and diffed
byte-identical against the working tree. `bench_walk.pl` still exits 255 on its pre-existing
missing `lastfmConfigured` stub.

**CHECKED LIVE, 2026-09-14:** `plugin_version` 0.9.217; the build-changed catch-up fired at
16:57:53 (exactly `WARM_DELAY` after load), stamped `warm_last_at`, completed in ~22s with
Last.fm last and released the detail queue (479 completed, 0 failed). **Still unproven live:**
the skip branch + re-seed (next restart after today's warm), the within-`WARM_DELAY` skip, the
DST fix (2026-10-25), and the first fixed-clock tick (~05:04 on 2026-09-15). Details in §C.

**0.9.216** — built 2026-09-14, superseded by 0.9.217 the same day; **NOT installed and NOT tested.** **THE OVERNIGHT WARM NOW
RUNS ON A FIXED LOCAL CLOCK, AND A RESTART NO LONGER RE-RUNS IT.** No schema change, no
cache-family bump, nothing stored changes shape. Design and reasoning:
`docs/scheduled-overnight-warm.md` §4A / §4B / §4F.

**WHY.** `WARM_INTERVAL` re-armed 24 hours from STARTUP, so the daily tick landed at
whatever o'clock the server was last restarted at — on the rig 08:58, the middle of the day,
~6 hours adrift of ListenBrainz's own 03:00 UTC job purely by coincidence. And EVERY restart
ran a complete warm 60s later, unconditionally: three forced feed fetches, the genre ladder,
the forced playlist listing, the follower builds. Five restarts in an evening meant five
complete warms, of which only the first could have found anything.

**WHAT SHIPS.**
- **`_secsUntilNextWarm` / `_warmJitter` (§4A).** The tick re-arms at the next `WARM_HOUR`
  (5) LOCAL, recomputed fresh each time, plus a stable per-install jitter of 0-1799s so
  every install in a timezone does not hit `api.listenbrainz.org` in the same second. LOCAL
  because the release-window arithmetic is local throughout; 05:00 because it must clear
  ListenBrainz's 03:00 UTC job AND sit outside the DST-ambiguous 00:00-03:00 band. **DST is
  handled by asking for a LOCAL TIME** (`_warmInstantOn`, `POSIX::mktime` isdst -1) — every run
  lands exactly on target, one per local date, the change days included. *(The first build said
  "recomputation, not arithmetic — the transition day lands an hour off". It ran the warm TWICE
  on the autumn morning; see the review round below.)*
- **The startup gate, `_armWarm` (§4B).** "Has a tick run since the most recent scheduled
  instant?" — derived from the same clock helper as the schedule, so there is no second
  number to tune. `warm_last_at` is stamped at the BOTTOM of `_warmTick`, on the synchronous
  path: it is a SCHEDULE MARKER, not a success record, so a tick whose async chain later
  fails still counts as today's warm. **The startup tick is NOT removed and must never be**
  — the schedule exists only in process memory, and `kvSweep`/`feedSweep` have no other
  caller, so a machine switched off overnight would never warm at all.
- **`Browse::reseedFromStore` (§4F), and the skip branch is NOT a bare return.** It arms the
  clock and rebuilds the in-memory detail queue from the store, because `_queueReleaseDetails`
  has four call sites and all four are inside `warmFeeds`. Non-forced getters, so it reads the
  store and issues no feed request. `_fanOutFeed` is now the ONE carrier both the warm
  callbacks and the re-seed go through (it also removed a real duplicate — the All Releases
  sites each called `_filterAll` twice).
- **`WARM_DELAY` 60 -> 180.** The 0.9.195 diagnosis is direct evidence that 60s after boot is
  the worst moment on the machine — the cold pass ran while the box was saturated by its own
  boot and pinned 8 false no-matches. That damage was fixed at the caching layer, so this is a
  quality call not a correctness one; under the new gate the catch-up fires far less often,
  which is what makes waiting longer cheap. A separate knob from the clock, deliberately.

**TWO REVIEW FINDINGS AGAINST THE PLAN ITSELF, both fixed here. Neither was in the design
document, and each would have shipped a silent defect:**
1. **The re-seed would have filled a queue that could not run.** `$detailMainReady` starts at
   0 and is set to 1 in exactly ONE place — the genre tails inside `warmFeeds` — while
   `_detailPriorityBusy` reports busy until it is. `warmFeeds` does not run on the skip path,
   so the flag would have stayed 0 for the life of the process and the re-seeded queue would
   have sat PAUSED until the next scheduled tick: the same nine-hour hole §4F exists to close,
   moved one layer down. **The plan's own proposed assertion (`detail_pending` non-zero) passes
   against it** — a paused queue has a pending count too. `reseedFromStore` releases the flag
   outright (there is no feed chain or genre tail here to wait for) and `t_detailwarm.pl` §9
   asserts the queue is RUNNABLE, with a control proving it was genuinely paused first.
2. **The gate's build-changed branch would have been dead code.** `_buildChanged` sets
   `last_build` to the running version INSIDE its own eval, so a second call returns early —
   a gate that re-asked would always be told "no change", and a `RESET_CACHE_ON_BUILD`
   clean-load build restarting after its scheduled hour would skip the refill it exists for.
   It now returns 1/0 and `postinitPlugin` passes the answer in.

**THE 2026-09-14 REVIEW OF THIS WORKING TREE — three findings, all fixed and BUILT as 0.9.217**
(see that entry; this 0.9.216 zip never shipped with them). Logged in
Ledger §C (`CLOSED IN THE 0.9.216 REVIEW —`):
1. **`reseedFromStore` fanned out under `'all releases (re-seed)'`**, and `_warmCovers` /
   `_queueReleaseDetails` week-order only on `eq 'all releases'` — a restart queued covers and
   details newest-date-first, upcoming weeks ahead of the current one. Now the warm's labels.
2. **The autumn DST change ran the warm twice** (measured: 04:10 and 05:10 GMT, 2026-10-25). The
   helpers now build a real local time; `_lastWarmInstant` had the same slop and a needless
   catch-up with it.
3. **A restart within `WARM_DELAY` of the scheduled instant** let the re-seed release
   `$detailMainReady` after the clock tick had zeroed it — the 0.9.204 phase inversion for one
   warm. `_armWarm` skips the re-seed when the clock is due that soon.

**TESTS.** New `tools/t_warmclock.pl` (**46**; 37 at build, +9 in the review), driving the real helpers and the real gate
through a timer seam — every row of §4B's table, including the switched-off-overnight machine
asserted explicitly, since a gate that stopped THAT machine warming is the regression this
change could plausibly introduce. `t_detailwarm.pl` 38 -> 45 (§9, the re-seed) -> **46** (review).
`t_coverwarm.pl` 134 -> **136**: its §4c pinned the SOURCE SHAPE of the four `_warmCovers`
call sites and went red on a correct refactor, so it now pins the PROPERTY through
`_fanOutFeed` — **plus the half that makes it mean anything**, since four filtered call sites
routing to a fan-out that warms nothing would otherwise pass. All 34 `tools/t_*.pl` exit 0;
both sync checks 0; `t_loads.pl` 20/20 against the BUILT ZIP, extracted and diffed
byte-identical against the working tree.

**ANTI-TESTED NINE WAYS**, each mutant failing only its own property: the `<= 0` boundary
dropped to `< 0` **2 red**, `gmtime` for `localtime` **3**, jitter returning a constant
**2**, the re-arm back on `WARM_INTERVAL` **2**, the gate made unconditional in each
direction **5** and **4**, the skip path not arming the clock **2**, not re-seeding **1**,
`warm_last_at` never stamped **3**, `_buildChanged` reverted to a bare return **1**, the
re-seed force-fetching **1**, and finding 1 reverted **1** (assertion 40 alone).

**A HARNESS BUG WAS FOUND BY THE ANTI-TEST AND IS WORTH KEEPING.** One §5 assertion reported
**PASS at the exact moment it detected the regression**: `$body =~ /no captures/` in LIST
context yields the EMPTY LIST on a miss, so the message shifted into `$cond`, where a
non-empty string is true. A defensive "default the message" guard is what hid it through a
full anti-test run. Every binding there is now `scalar()`-wrapped, and `ok()` reports a
missing message as a FAIL naming the harness bug rather than defaulting it.

**`bench_walk.pl` still exits 255 and it is STILL not this build** — verified against a clean
`git archive` extract of HEAD, where it fails identically (the missing `lastfmConfigured`
stub, 0.9.215's entry).

**0.9.215** — built 2026-09-14, superseded by 0.9.216 the same day; **NOT installed and NOT tested.** **THE RELEASE WINDOW IS NOW
TWO NUMBERS PER SECTION, AND THE CURRENT WEEK IS WEEK 1.** Settings only — no schema change, no
cache-family bump, and nothing stored changes shape. See the "Per-section release window" section
at the top of this file for the shape, and `docs/week-based-release-window.md` "As changed" for
the reasoning and the measurements behind the MuSpy half.

**WHY.** Simon, 2026-09-14: the window was "overly complicated and has too many boxes", All
Releases could not be configured differently from For You, and "starting at week 0 feels wrong.
Current week should always be 1." Seven controls (`weeks_past`, `weeks_future` and the four
`*_past`/`*_future` gates plus `muspy_future`) became **two number boxes in each of the For You and
All Releases sections**: `<section>_weeks` (total shown, this week counted as 1, max 4) and
`<section>_upcoming` (how many of those are ahead). The General section now has no week fields.

**THE TOTAL IS WHAT MAKES THE BUDGET SAFE.** `upcoming` is clamped to `weeks - 1`, so the
four-week limit is a property of the input and the old past-first trim — which silently changed
the value the user had not touched — is gone from the user-facing path. The internal
`(past, future)` pair is DERIVED (`past = weeks - 1 - upcoming`), so `_feedWindow`,
`_feedRequestDays`, `_feedMemoKey`, the store and the LB request are untouched.
`API::clampSectionWeeks` is the ONE rule, applied on save and on read.

**MUSPY NO LONGER HAS A WINDOW OF ITS OWN** — Simon: it must never show past four weeks and must
roll over like the LB feed. `%WEEK_GATES` and the `'muspy'` prefix are gone, `_mergeMuSpy` windows
on `sectionWindow('foryou')`, and `_sectionBounds` unions nothing (0.9.207's union is MOOT with one
window for both feeds, not reverted — it stays the single carrier). **Checked before deciding, in
muspy's own source** (`app/models.py` `ReleaseGroup.get`): the per-user query is `ORDER BY date
DESC` with no date bound, so the top of our `?limit=100` slice is the furthest-out announcements —
the one thing MuSpy can show that ListenBrainz cannot. They are still fetched and stored
unwindowed and appear as the edge rolls forward; they are simply never displayed early.
**Also fixed here:** the nightly MuSpy warm used to warm covers and queue detail for EVERY stored
MuSpy row, months-out announcements included; it now prepares only the rows inside the window.

**NO MIGRATION**, the 0.9.185 precedent: the retired prefs stop being read and everyone lands on
the defaults — since 2026-09-15 `2`/`1` for both sections, this week + next week (it was For You 4/2,
All Releases 2/0, reproducing 0.9.185). `main` (0.9.149) never
shipped `weeks_*`, so only the four gates and `days` are orphaned for real users.

**OBSERVED, NOT CHANGED:** `API::_padDate` fills a year-only or month-only MuSpy date with the 1st,
so an album announced for just "2026" is dated 1 January and never falls inside a current window.
Pre-existing, out of scope, and not a regression of this build.

**TESTS.** `tools/t_weekwindow.pl` rewritten, 62 → **71**, including a new **§8 that RUNS
`Settings::handler`** against stubs — there was no test that executed the handler before, and a
handler that dies part way still renders a half-filled settings page. `t_detailwarm.pl` §8
rewritten for the single window. Fixtures moved to the new prefs in `t_feedsingleflight.pl`,
`t_review_fixes.pl`, `t_cachememo.pl`, `t_coverwarm.pl` (its §4c now resolves a filtered variable,
not just an inline call) and `bench_walk.pl`. **Anti-tested six ways, each mutant failing only its
own assertions:** the upcoming clamp removed **4 red**, the sentinel back on `pref_weeks_past`
**1**, the merge on a `'muspy'` window **1**, `_sectionBounds`' union restored **3** (in
`t_detailwarm`), the save path unclamped **2**, and a handler dying before the save **7**.
All 33 `tools/t_*.pl` exit 0; `matcher_sync_check.py` and `singleflight_sync_check.py` exit 0;
`t_loads.pl` 20/20 against the BUILT ZIP, which was extracted and diffed byte-identical against
the working tree.

**`bench_walk.pl` EXITS 255, AND IT IS NOT THIS BUILD** — verified by running it against a clean
`git archive` extract of HEAD, where it fails identically. Its API stub has no `lastfmConfigured`,
which `Browse::_lastfmGenres` has called since **0.9.213** (`ec3b268`). The bench dies part way and
prints a SHORTER LIST rather than failing, so the missing line reads as a quiet run — the exact
trap `bench_walk.pl`'s own comment predicts. **What is lost is the `_bucketFor` measurement**, the
guard that caught the per-release SELECT in 0.9.165. One stub line fixes it; not done here.

**0.9.214** — built 2026-09-14, **INSTALLED on the test rig 2026-09-14 12:34; review CLOSED —
see Ledger §C (`CLOSED IN 0.9.214`); a third review round the same day over both commits was
clean.** The 2026-09-14 review fix on top of 0.9.213's built-in
Last.fm key: **error 6 is now an ANSWER everywhere it can arrive, and a mid-pass latch stops
the warm cleanly instead of spinning it.** No schema change, no cache-family bump — see below
for why.

**FIX 1 — error 6 is an answer, not a failure. 0.9.213 got this wrong at BOTH call sites.**
Last.fm answers an artist it does not know with HTTP 200 + `{"error":6}` (verified live for
`artist.gettoptags`, `album.gettoptags` and `artist.getsimilar`). Before 0.9.213 the GET path
parsed that body into `[]`, which was stored — correct by accident. 0.9.213 routed every
error body through `_lastfmPost` → `$onError`, so `getLastfmTags`' artist step (`$tryArtist`)
made the warm count it `failed` and store nothing, and `getSimilarArtistsLastfm` stopped
caching it. 12 of 60 artists sampled from that week's sitewide feed got error 6 (ZELUATI,
Doll Face Killah, multi-credit classical lines), so ~20% of the queue would have been
re-asked on every pass indefinitely, and the radio on every top-up. `_lastfmPost` now passes
`($msg, $code)` to `onError`; the artist step files code 6 as an empty checkpoint via
`$finish`, and `getSimilarArtistsLastfm` caches it empty at `LFM_EMPTY_TTL`. Every other
error is still not stored.

**FIX 2 — `Browse::_warmLastfm` ends the pass instead of spinning it once the key latches
off.** A rejected/stopped key (error 10/26, or 29's hour backoff) makes every remaining
request in the queue fail identically. The pass used to keep iterating at 1s per artist,
each one failing, incrementing fake `requested`/`failed` counters while `$lastfmWarmPending`
stayed true — which held the detail-prep phase behind it for no reason, since nothing left in
the queue can possibly succeed. It now checks the latch before each request and ends the pass
with the remainder marked `deferred`, releasing `$lastfmWarmPending` immediately.

**NOT A CACHE-SHAPE CHANGE, and nothing to clear.** 0.9.213's bug was that it stored
NOTHING for error 6 — no wrong answer was ever written to `lastfm_tags`, the artist row's
`lastfm_genres`, or `lbf:lfmsimilar:`. The fix only makes a previously-unstored answer get
stored, with the same empty shape and TTL every other empty answer already uses. No family
in `DB::KEY_VERSIONS` is involved; `lbf:lfmsimilar:` is not a versioned family.

**Also fixed:** stale "user key" wording in comments across DSTM, Plugin, Diag, API and
Browse, Diag's Last.fm skip note, the warm note (now "disabled (no Last.fm key in use)") and
`PLUGIN_LBF_DIAG_DESC` in `strings.txt` — all left over from the manual-key era the 0.9.213
built-in key replaced.

**TESTS.** `tools/t_lastfmkey.pl` 58 → 64; `tools/t_lastfm_priority.pl` +6 (67 → 73). All 33
`tools/t_*.pl` suites exit 0 (`t_diag.pl` reports 70, with its MusicBrainz network check
skipped on a live 503 — not a regression). Both new test groups anti-tested, 4 red each.
`t_loads.pl` 20/20 against the BUILT ZIP, which was extracted and diffed byte-identical
against the working tree.

**0.9.213** — built 2026-09-14, superseded the same day by 0.9.214 (its review fixes); review
CLOSED — Ledger §C (`CLOSED IN 0.9.214`). **LAST.FM IS BUILT IN
FOR EVERY USER — and there is no manual key any more.** No schema change, no cache-family
bump, and caches are preserved as usual.

**WHY.** Last.fm is the genre ladder's tier 5 and the only rung not derived from
MusicBrainz; gating it on a key most users never created cost them roughly a third of their
genre labels. Simon reversed the 2026-08-12 "superseded" call and supplied a key. Full record:
`docs/lastfm-key-bundling.md` "As built"; the review verdict is in Ledger §A2 (`The BUILT-IN
Last.fm API key in `API.pm` is`).

**WHAT SHIPS.**
- **The key is XOR-masked + hex-packed** (`LFM_BUILTIN_HEX`/`LFM_BUILTIN_PAD`), not base64 —
  obfuscation only, stated plainly in the code; a clipped constant decodes to NO key.
- **Every Last.fm request is a POST with the key in the BODY** (`API::_lastfmPost`, the one
  funnel for tags, similar artists and Diag's probe). LMS core's `SimpleAsyncHTTP::onError`
  logs a failed request's URI at WARN, so the old GET put the key into `server.log` on any
  timeout or 403. Last.fm serves the read methods over POST — verified live.
- **A rejected key latches off** (`_lfmNoteError`): error 10/26 stop it for the process,
  logged once; 29 backs off 1h and recovers. An invalid key is really HTTP 403 +
  `{"error":10}`, read from the error callback's response argument.
- **A failure is no longer stored as an empty answer.** `getLastfmTags`' artist step used to
  file `[]` on any failure; it now reaches `onError`, so the warm counts `failed` and asks
  again next pass. `getSimilarArtistsLastfm` no longer caches a Last.fm error body.
  **EXCEPT error 6** ("could not be found", HTTP 200) — Last.fm's ANSWER for an artist it
  does not know, not a failure. Review 2026-09-14 caught the first build routing it to
  `onError` too: 12 of 60 artists sampled from that week's sitewide feed (ZELUATI, Doll
  Face Killah, multi-credit classical lines) got it, so ~20% of the queue would have been
  re-asked every pass forever. `_lastfmPost` now hands `onError` the code; the tag artist
  step and the similar-artists call store/cache 6 as empty. Same review: a key stopped
  MID-PASS now ends the pass (`deferred`) instead of spinning the queue at 1/s with no
  requests while `$lastfmWarmPending` held detail prep back.
- **The manual option is GONE** (Simon: "not needed"): the settings field, Check-key button,
  three strings and the `lastfm_api_key` pref. `Plugin.pm` deletes a stored value at startup.
  Every gate reads `API::lastfmKey`; the render path reads `lastfmConfigured`, so stored tags
  stay visible while a key is stopped. `warmstats` reports `lastfm_key`/`lastfm_keys` and Diag
  reports the key's STATE — never its value.

**TESTS.** New `tools/t_lastfmkey.pl` (58) — storage, transport, latch, failures, scrubbing,
wiring — with the HTTP stub modelled on slimserver 9.0's own callback shape. Anti-tested five
ways: latch removed 9 red, scrub removed 1, failure storing empty 3, GET transport 8, a pref
override reinstated 1. `t_diag.pl` 67 → 71. All 33 `tools/t_*.pl` exit 0; `t_loads.pl` 20
passes against the BUILT ZIP, which was extracted and diffed against the working tree.

**CHECKED LIVE on 0.9.214, 2026-09-14:** `lbf warmstats` → `lastfm_key builtin`,
`lastfm_keys builtin: ok`; the Connection Check's Last.fm row is ok, HTTP 200, "The built-in
API key is valid". The POST transport and the key are proven; see §C for what is not.

**0.9.212** — built 2026-09-10. `_trackMatches` gains the short-title `_punctNorm` escape
hatch `_albumMatches` has carried since 0.9.83 (ported from Discography 0.10.3): a track
TITLE made entirely of marks (`\x{2020}\x{2020}\x{2020}`, `\x{2665}`, `"( )"`) normalises to
nothing under `_norm`, and the `<2` gate then rejected it against every source rather than
falling back to the punctuation-preserving form the way `_albumMatches` already does. The
artist gate stays mandatory — a match this thin cannot stand on the title alone. A trailing
`$titleRaw` argument threads the raw string through all five call sites
(`_titlesSearch` × 2 via `_localByText`, `_trackMatches` itself, and the two runTrack
adapter calls in `_findPlayableTrack`) because `_norm` has already discarded the marks by
the time `_trackMatches` runs. `_findPlayableTrack`'s and `_findLocalTrack`'s pre-filters no
longer bail outright on an empty `_norm` form when a `_punctNorm` form exists — the old
refusal answered `undef` (inconclusive), so an all-marks track burned all three rungs of
`MISS_RETRY_SCHEDULE` without a single request ever being sent. `_relKey` falls back to
`_punctNorm` per field, so two all-symbol releases stop sharing one order-freeze slot and one
release-target token. **The per-track cache key is now `_trackKeyName`, with a per-FIELD
fallback on the title** — REVIEW FIX 2026-09-14: the first cut fell back only when
`_norm($query)` was empty, i.e. when artist AND title were BOTH all-marks. With a real artist
the key was just the artist, so "Crosses – †††", "– ♥" and "– ( )" all keyed `crosses` and
served each other's decision (wrong track / false no-match / exclude-mode drop) — reachable
from Trending Tracks, the follow feed and Created-for-You tracks with no recording MBID (DSTM
always has one). Its 4c pin was a source regex that passed with the collision live; 4c now
DRIVES `_trackKeyName`, with a control proving the old form collides. Every title `_norm` leaves
non-empty keys byte-for-byte as before (pinned in 4c; also 582,904 suite-string pairs, 0
moved), so the no-bump reasoning below holds. **`_dedupeReleases` was NOT given the fallback**:
two all-marks albums by one artist on one date still fold there — main's behaviour, uncached,
left alone at that review; do not report it as a missed half of this fix.

**No schema change. No cache-family bump — deliberate, not an oversight.** Nothing in
`DB::KEY_VERSIONS` answers a wrong NON-EMPTY result today: the bug was a false MISS (the old
shared-empty-key entries simply orphan and age out), not a false HIT, so no existing lookup
can be served a stale wrong answer. `_relKey` is per-render and `%ORDER_FREEZE` is
in-process, so neither is cached at all. Bumping `lbf:track:` here would only cost every warm
cache its next cold rebuild for no correctness gain — same reasoning as the 0.9.57 fold.

**Tooling kept in step.** `tools/matcher_sync_check.py` pins `foldLatin` and `_fold` in
VARIANTS, closing a blind spot where Listen Later's apostrophe rule could be deleted with the
check still exiting 0 (see [[shared-matcher-sync]]). `tools/t_matchersync.pl` grew from 46 to
76 assertions (62 at build; +14 net at the 2026-09-14 review fix), new sections 4b and 4c
covering the `_trackMatches` short-title fallback and the driven `_trackKeyName` key.

**0.9.211** — built 2026-09-10, **installed and verified the same day** (see the live check at the
end of this entry — and read its caveat, because the run did NOT exercise the fix). **AN UNFINISHED PASS IS NOT AN
ANSWER, AT ALL FIVE PLACES THAT CACHE ONE.** **One cache family bumps** (`lbf:pl:resolved:` 8→9)
to drop the partial playlist resolves already pinned on the server; `lbf:track:` is deliberately
UNTOUCHED, so a re-resolve reads the expensive layer and is mostly cache hits. New regression
guard `tools/t_playlistresolve.pl` (58 assertions).

**THE FIELD REPORT:** after a full install the four created-for playlists come up short and stay
short, and a manual "Refresh playlist matches" picks up the stragglers. On the released build
(`main`, 0.9.149) the same cold pass always converged.

**WHAT THE main→dev DIFF ACTUALLY SHOWS, and it corrects the obvious reading.** Three things a
review reaches for first are present on `main` TOO, so they are latent bugs, not the regression:
the watchdog with no timed-out signal, `PLAYLIST_PARTIAL_TTL == PLAYLIST_FOUND_TTL`, and a warm
that skips on a merely-PRESENT key. What `main` had that `dev` does not is an **UNBOUNDED retry**:
an inconclusive track miss was cached for an hour (`TRACK_INCONCLUSIVE_TTL`, deleted in 0.9.195)
and the LIST holding it expired on the same hour, so the next look re-searched every straggler,
for ever, until they all matched. **0.9.195 replaced that with a bounded ladder — deliberately,
on Simon's own call — and 0.9.207 stopped every build from wiping the store.** Together those
removed the brute force that had been covering a cold pass that **has never matched in one go**.
The cold pass has always lost tracks under load; that is the 2026-09-02 diagnosis verbatim.

**FIX 1 — `_resolveTracks` SAYS WHETHER THE WORK FINISHED OR THE CLOCK DID** (5th callback arg,
`$timedOut`, set by the watchdog before `$finish`). Tracks the watchdog never LAUNCHED contribute
nothing to `$inconclusive`, so that signal could not cover this. Positional, so the callers that
unpack fewer values are unaffected. **This is the third site of a class already fixed twice** —
the trending-albums gate (0.9.117) and `_buildAlbumsData`'s empty settle — and the shared resolver
was the one that never got it.

**FIX 2 — A WATCHDOG SIZED BY WHO IS WAITING, AND FOR THE PLAYLISTS NOBODY IS.**
`PLAYLIST_TIMEOUT`(45s) was chosen when opening a playlist BLOCKED the user, which is true on
`main` — it has no building row at all (`_isBuilding` does not exist there). Since 0.9.182 the
open renders at once and completes into cache, the warm never had a watcher, and a **fifth adapter
(Spotify) joined every track search after `main` was cut**. New `PLAYLIST_RESOLVE_TIMEOUT`(150s)
for the playlist, follow and trending resolves; **the 45s default is unchanged** for DSTM and the
two unmatched-tracks views, which do have someone waiting. 150 < `BUILDING_MAX`(180) is
load-bearing: the normal path must release the in-flight flag before the expiry backstop does.
**That holds for the PLAYLIST warm only** (it takes the flag right before the resolve).
`_resolveTrending` takes its flag before a 30s fan-out and can outrun 180s — since 1.0.5 the flag
is a TOKEN and a late release cannot free a newer pass's flag (§C `CLOSED IN THE 1.0.3 REVIEW —`, finding 2).

**FIX 3 — THE WARM REVISITS AN INCOMPLETE LIST INSTEAD OF SKIPPING IT.** It skipped on a present
key, so an under-matched list was revisited only when its entry EXPIRED — up to a fortnight. The
per-track misses under it are on `MISS_RETRY_SCHEDULE` (1h/6h/24h), and **the ladder is only ever
consumed by a re-resolve**: with the list pinned, those steps meant "the next few times the user
happens to look", not hours. Cheap by construction — `$force` is NOT passed, so a revisit reads
the per-track cache. A COMPLETE list is still skipped outright (asserted).

**FIX 4 — THE WARM TAKES THE IN-FLIGHT FLAG.** Without it a user opening a playlist mid-warm found
no cache entry, saw no build in progress, and started a SECOND full fan-out at the same services —
doubling exactly the load whose failures produce the misses. `_resolveFollow` has always had this;
the playlist warm inlined its resolve and missed it.

**FIX 5 — THE SAME RULE AT EVERY OTHER SITE THAT PERSISTS AN ANSWER.** Auditing all seven bounded
waits found three more: the **follow feed** resolve and the **trending tracks** resolve both cached
a truncated pass at the full TTL, and **`_fanFollowers`** reported a deadline-cut follower set as
though every follower had answered. That last one is the worst of the three and the least obvious:
ranking there is **one vote per follower**, so a missing follower REORDERS the list rather than
shortening it — an aggregate built from 8 of 13 followers was cached for a week (This Month) or a
month (This Year) as if it were those users' answer. `$fanCut` now joins `$sawListens` on the
empty-trending gate and `$timedOut` on the albums settle. The detail-page watchdog and the
per-service search timeout were checked and need nothing: one forces a render and caches nothing,
the other already settles inconclusive.

**NOT CHANGED, DELIBERATELY, and each was considered:** `RESET_CACHE_ON_BUILD` stays 0 — converging
the playlists by reinstating the build wipe would undo 0.9.207 and clear far more than this needs.
`MISS_RETRY_SCHEDULE` stays `[1h, 6h, 24h]` — the ladder is not re-unbounded. Every TTL constant is
unchanged. The two unmatched-tracks diagnostic views cache nothing, so there is no wrong answer to
persist; they will over-report on a cold cut-short pass (a track never searched is listed beside
one searched and missed) and re-opening fixes it. **`tools/t_playlistresolve.pl` §5 pins all of
this** — 6 key versions, the ladder, 10 TTL/concurrency constants and the build-wipe switch — so a
later fix that converges the playlists by quietly shortening something else FAILS the suite.

**TESTING.** The suite was written and run BEFORE any code changed: 30 passed / 8 failed, every
CONTROL passing, which is what proved the harness drives shipped bodies rather than a paraphrase.
Two controls were then ANTI-TESTED against mutated copies — a `_playlistTtl` returning the short
TTL unconditionally passes the target assertion and fails three controls; a warm that always
re-resolves passes its target and fails the no-extra-traffic control. After the fix: **58/58**, all
32 suites exit 0, `perl -c` clean on Browse/DB/DSTM/API (Plugin's only error is the LMS
`main::WEBUI` constant, as always). `t_trending_empty.pl` needed one assertion **strengthened**,
not relaxed: it pattern-matched the empty-trending gate, which now requires `$sawListens && !$fanCut`,
and the updated assertion requires BOTH terms. `t_lastfm_priority.pl` gained the new constant in
its stub package (it lifts `warmCache`).

**LIVE CHECK, 2026-09-10 11:48 — AND WHAT IT DOES NOT PROVE.** `cachestats` answered
`plugin_version 0.9.211`, so the new module was loaded (the running code reporting itself, not a
template re-read — [[plugin-repo-shadows-manual-install]]). The log shows `Build changed (0.9.209 ->
0.9.211): derived cache KEPT`: the build wipe correctly did NOT run, and the `lbf:pl:resolved:`
8→9 bump is what dropped the old entries, with `lbf:track:` surviving at 417 rows. **All four
playlists read 50 of 50**, agreed by two independent readings — the cached payload's own tile count
and the unmatched-tracks diagnostic ("nothing unmatched" on all four). Because the key bumped there
were ZERO `:9:` entries when the warm ran, so it could not have skipped: it resolved all four from
nothing, in **0.27s**. Diag green on 8 targets, 5 adapters installed (Qobuz 1, Tidal 2,
Bandcamp/Deezer/Spotify 3 — the fifth is the one that made 45s too tight). Trending This Month and
This Year both still render 53 rows, so the follower-aggregate changes disturbed nothing.

**THE CAVEAT, and do not lose it: NOTHING TRUNCATED, so the fix was not exercised.** 200 tracks
resolving in 0.27s means the per-track layer already held every one of them as a MATCH — much of
that from the manual refresh Simon ran before reporting the problem. So this run proves the build is
correct and nothing regressed; it does not show the truncation path firing. **That needs a genuinely
cold pass on a busy box** — the next fresh install, or a week whose new playlists carry tracks
nothing has searched before. The follow-feed half is unverified live for a different reason: the
warm stage is `skipped — no token`, and stays that way until a token is set.

**READ 4.2 OF THE SUITE AS A PAIR WITH 4.3.** "An open during the warm renders the building row"
passed BEFORE the fix too, and for the wrong reason: with no flag held the open found no cache
entry, started its own resolve, took its own flag and rendered the building row from the cold-start
branch. Same row on screen, two fan-outs at the services. 4.3 is what discriminates.

**0.9.210** — built 2026-09-10, from the live test of 0.9.209. **Darkwave is filed
under Rock.** No schema change, no cache-family bump, **and no cache clear is needed** —
`genre-families.txt` is read from disk at render time (`Browse.pm` derives its path from
its own), so the families it defines are recomputed on restart. Nothing stored changes.

**THE BUG WAS A SPLIT SCENE, AND THE SPLIT WAS INVISIBLE BY CONSTRUCTION.**
`"darkwave": "Electronic"` sat in the generator's OVERRIDES on the line **directly
above** `"coldwave": "Rock"`. Two names for one scene, two families, adjacent lines.
It survived because **MusicBrainz carries `dark wave` and `darkwave` as SEPARATE
vocabulary entries**, and `norm()` flattens hyphens, slashes and underscores but NOT
the space — so the two never share a lookup. One was overridden to Electronic; the
other matched no rule (the suffix test needs `" wave"`, with the space) and shipped as
`?`, family-less. Both are now **Rock**, which is where the rest of the lineage already
was: `coldwave`, `new wave` and `no wave`.

**Live evidence this was reachable, not theoretical:** the W/C 31 August list rendered
`-ii- – Ars Erotica, Vol. I` as `Album · dark wave` — a raw family-less label — while
the week's genre picker filed it under `Other (125)`.

**Fixed in BOTH places, deliberately.** `tools/make_genre_families.py` OVERRIDES is the
source of truth, and the shipped `genre-families.txt` got the same two lines applied
surgically **rather than by re-running the generator**: a full regeneration re-pulls the
whole MusicBrainz vocabulary and would fold in every unrelated upstream change since the
file was last built, which is not a thing to do inside a one-line fix. The generator was
run in-process to confirm it now emits `Rock` for both spellings before the file was
touched.

**NOT swept up, deliberately:** `ethereal wave`, `neoclassical dark wave` and `dreamwave`
are darkwave-adjacent and remain family-less. They were not asked for, they still display
their own name, and deciding them silently is how the original inconsistency got in.

**`indie` STAYS family-less, and that is Simon's call, not an oversight** — it is broad
enough to sit under Rock, Electronic or almost anything, so it is a genuine sub-genre
with no well-formed parent. It remains valid vocabulary and displays as its own label.

**TESTS — `t_lastfm_priority.pl` 61 → 67.** The pair is asserted TOGETHER, plus the
`coldwave`/`new wave` lineage as controls, because **testing either spelling alone would
have passed throughout the entire period the two disagreed** — which is exactly how this
shipped. `ethereal wave` is pinned family-less so the "not swept up" decision is explicit
rather than incidental.

### Previous build: 0.9.209

**0.9.209** — built 2026-09-10, installed and live-tested; see the test results folded
into the entries above and below. It carries the
0.9.208 hygiene pass plus **the one thing that pass showed was missing: the plugin can
now say which build is actually running.** No schema change, no cache-family bump, and
**the caches are deliberately NOT cleared** — nothing about a stored shape or a cached
decision changed.

**THE RUNNING BUILD NOW REPORTS ITS OWN VERSION.** New `Plugin::version()`, added to
`["lbf","cachestats"]`, `["lbf","warmstats"]` and `["lbf","diag"]` as `plugin_version`.
**This exists because a repo-installed copy shadows a manual install and nothing could
detect it:** a `.pm` loads once at startup, so a stale package under
`cache/InstalledPlugins` answers every question a fresh manual install was meant to
answer, and a whole verification round can run against the wrong build without one
wrong-looking line anywhere. `cachestats` did already report a `version`, but that is
the **store SCHEMA** version — it does not move on most builds and so could never have
answered "which package is running". Both are now reported, side by side, with a comment
saying they are different questions. The value is read through
`dataForPlugin(__PACKAGE__)` rather than restated, since a hand-maintained constant is
exactly the thing that drifts: the sibling HQPlayer Bridge shipped one stuck at 0.2.3
while its repo was at 0.2.7.

**FIRST THING TO DO AFTER INSTALLING — confirm the right build loaded:**

```
lbf cachestats
```

`plugin_version` must read **0.9.209**. If it says anything else, a shadowing copy is
running and nothing else observed in that session means anything.

**TESTS — `t_review_fixes.pl` 17 → 22**, new §4. **Two of its five assertions were
wrong on the first draft, and the anti-test is the only reason that is known:**
- The "reads install.xml, not a constant" check searched the WHOLE FILE, where
  `_buildChanged` makes the same `dataForPlugin` call for its own reasons — so it passed
  against a mutant whose accessor returned a hardcoded string, which is the exact defect
  it exists to catch. Now scoped to the sub body via `grab`. **A whole-file regex for a
  common idiom is a trap, not a one-off slip.**
- `grab` DIES on a missing sub, so the rename mutant exited 255 partway through and
  printed a **SHORTER LIST rather than a failure** — sections 1–3 looked fine and §4
  simply was not there. That is the `bench_walk` shape this file already warns about: a
  half-dead run reads as a quiet one. The call is now eval'd, so a rename fails as an
  assertion instead of taking the harness down.

**Anti-tested three ways, each mutant failing only its own property:** `version`
renamed **2 red**, its body replaced with a hardcoded literal **1 red**, one of the three
call sites dropped **1 red**. `LBF_PLUGIN` was added to the suite as the seam that makes
this possible at all.

Regression guards: the complete native `tools/t_*.pl` loop (31 scripts) exits 0,
`t_loads.pl` 20 passes against the BUILT ZIP, `bench_walk.pl`, `bench_store.pl`,
`git diff --check`, `matcher_sync_check.py` and `singleflight_sync_check.py` all clean.
The zip was extracted and diffed against the working tree.

### Previous build: 0.9.208

**0.9.208** — built 2026-09-10 for local testing; superseded by 0.9.209 before install.
**A DOCUMENTATION AND ORPHAN-CODE PASS, not a behaviour change.** No schema change, no
cache-family bump, and **the caches are deliberately NOT cleared** — nothing about a
stored shape or a cached decision changed.

**THREE UNREACHABLE SUBS REMOVED**, found by sweeping every `sub` name in the plugin
against every reference to it. Each leaves a tombstone comment saying why it is not
coming back, per the convention `getArtistBio` set in 0.9.186:
- **`DB::bcPinDel`** — a Bandcamp pin is replaced by writing a new one through
  `bcPinPut`, or dropped with the table on a clean-load reset. Nothing has ever deleted
  a single pin, and the row is deliberately durable.
- **`DB::followCount`** — written as a diagnostic beside `followTrim`, but
  `["lbf","cachestats"]` already reports the `follow_item` row count through `stats`'
  `@TABLES` sweep. Nothing ever wanted a per-USERNAME count.
- **`API::peekArtistGenres`** — the single-MBID wrapper over
  `peekArtistGenresBulk`. **Its comment claimed "the render path uses this", and that
  was false** — the render path has only ever called the bulk form. A per-MBID wrapper
  over a bulk statement is one SELECT per row, which is the cost the bulk sub exists to
  prevent, so it was worse than dead: it was an invitation.

Also removed: the orphan string token `PLUGIN_LBF_VIEW_ALL` ("Show all"), left over from
the two-row family selector that 0.9.128 replaced with `_viewToggle`. `PLUGIN_LBF_SHOW_ALL`
carries the same text and is the one in use.

**TESTS.** `tools/t_genrefill.pl` 191 → **198**, with a new §6d pinning all three
removals. **Every "this sub is gone" assertion is PAIRED WITH ITS SURVIVING SIBLING** —
a negative regex passes just as happily against a file the harness failed to load, so
the positive half is the control that proves the source is really there.
**Anti-tested twice:** restoring `peekArtistGenres` in a mutated `API.pm` **1 red**,
restoring both DB subs in a mutated `DB.pm` **2 red**, each failing only its own
property.

**THE REST OF THE PASS IS DOCUMENTATION, and the pattern in it is worth keeping.**
Every stale claim found was a document that had stopped tracking the code weeks
earlier while still reading as authoritative — a "PICK UP HERE" pointing at work that
had shipped, a plan header saying "IN BUILD" after the last stage landed, a review doc
saying "nothing here is fixed yet" about ten findings all closed. **Two of them
contradicted the Review Ledger directly** (the matcher hold, the uncommitted tree),
which is the exact failure the ledger exists to prevent. Closed: both stale review docs
(0.9.160's ten findings and 0.9.174's last two), the three superseded caching/warm
plans, the genre phase status, and the "State of play" section, which was rewritten and
re-dated. **There is now ONE statement of branch state, in that section's header**, so
the two copies cannot drift apart again.

Regression guards: the complete native `tools/t_*.pl` loop (31 scripts) exits 0,
`bench_walk.pl` and `bench_store.pl` exit 0, `matcher_sync_check.py` and
`singleflight_sync_check.py` both exit 0.

### Previous build: 0.9.207

**0.9.207** — built 2026-09-09 for local testing; not installed or live-tested.
Fixes the two 0.9.206-review findings, and **the sweep for other carriers of each
concept found a third site the review had not reported.** No schema change, no
cache-family bump, and **the caches are deliberately NOT cleared** — this build
changes no stored shape and no cached decision, and the caching behaviour is locked
while other work proceeds.

**FINDING 1 — the artwork focus addressed the wrong releases on For You.**
`_focusReleaseCovers` was handed the pre-render list with a single scalar offset for
the Options block, but the level it describes is drawn by `_buildWeekly`, which
**inserts a divider before every week and re-sorts inside each one**. So Material's
row index and the release position drifted apart by one per divider above the
request — off by one from the very first week, growing per week crossed — and under
the artist/album sorts the release at a given row is not the one at that position in
the input list at all. The sibling call site for an All Releases week was always
correct, because that level draws its releases flat with no dividers among them;
that is exactly why one scalar offset looked sufficient.

**FIXED BY GIVING THE MAPPING A SHAPE INSTEAD OF AN OFFSET.** `_weekGroups` is the
one carrier of the weekly render order (the grouping AND the `_sortWithin` call),
`_buildWeekly` consumes it rather than re-deriving it, and `_renderSlots` turns it
into **one entry per RENDERED ROW** — the release drawn there, or undef for a row
that draws none. `_focusReleaseCovers` takes that slot list and counts, so both the
start position and the requested span are exact even across a divider. `fetchForYou`
groups ONCE and hands the same groups to the renderer and the focus map, which is
what makes drift impossible rather than merely unlikely. There is no scalar offset
left to get wrong.

**FINDING 2 — an upcoming MuSpy release lost its detail prewarm.** For You renders
two sources with independent future gates (API's `%WEEK_GATES`: `foryou_future` and
`muspy_future`), but `_warmReleaseDetails` judged every priority-0 job by the For You
window alone. With later weeks off for the feed and on for MuSpy, `_mergeMuSpy` keeps
an upcoming release and puts it on screen while its prewarm job is discarded with
retry 0 — which **deletes it from the queue** rather than deferring it, so it stays
cold until the next nightly warm.

**AND THE SWEEP FOUND A THIRD CARRIER THE REVIEW DID NOT REPORT.** Four places answer
"what dates can this section's rows occupy", and two of them disagreed with the merge
that actually decides visibility: `_warmReleaseDetails` (the reported one) and
`_windowSpan`, whose tile subtitle therefore understated the span whenever MuSpy
reached further. All three non-authority sites now go through one **`_sectionBounds`**,
which returns the UNION of the For You and MuSpy windows.

**THE UNION RATHER THAN THE REVIEW'S SUGGESTED SEPARATE SOURCE ID, deliberately.**
Both feeds enqueue at priority 0 and DetailWarm keys its sources set BY priority, so
the origin is unrecoverable by construction — and `$job->{rel}` is replaced by
whichever enqueue landed last, so testing the release's own `_source` tag would judge
a release carried by BOTH feeds against whichever window arrived last. That loses the
prewarm in the mirror-image case (`foryou_future` on, `muspy_future` off). The union
is order-independent and can only ever over-accept, which costs one prewarm nobody
reads instead of a cold tap on a release that is on screen.

**TESTS.** `t_coverwarm.pl` 131 → **134**, with a new §4e that pairs every "which
release does this row promote" assertion with the item `_buildWeekly` actually drew
at that row, read from the same groups. It carries the control this file's own
0.9.197 entry insists on — *the render really did reorder, else the rest proves
nothing* — and it is the assertion the no-sort mutant fails. **Anti-tested three ways,
each mutant failing only its own property:** the flat pre-fix offset **3 red**,
`_renderSlots` emitting no divider slot **5 red**, `_weekGroups` skipping the
within-week sort **1 red** (the control).
`t_detailwarm.pl` 32 → **38**, gaining `LBF_BROWSE` so it can be anti-tested at all.
**Its `sectionWindow` stub had to become PREFIX-AWARE, and that is a finding about the
test:** a single window for every prefix cannot tell the union apart from the plain
For You window, so the old flat stub would have passed against the very defect being
fixed. `_sectionBounds` is LIFTED from source rather than restated, since a
hand-written copy could agree with a broken shipped one. **Anti-tested twice:**
`_warmReleaseDetails` back on `sectionWindow` **1 red**, `_sectionBounds` returning
the For You window with no union **2 red**.

**THREE SUITES AND A BENCH BROKE ON THIS LANDING, AND IT IS THE `perl -c`-INVISIBLE
CLASS THIS FILE ALREADY WARNS ABOUT — TWICE.** `t_cachememo.pl` lifts `_sectionSig`,
`t_review_fixes.pl` evals the week coderef, and `bench_walk.pl` lifts the section
pipeline; adding a call to a NEW sub from inside code a harness lifts killed all three
with `Undefined subroutine`, while compilation stayed clean everywhere. **`bench_walk`
is the one to note: it exits 255 and prints a SHORTER LIST rather than a failure**, so
a half-dead bench reads as a quiet one — exactly the 0.9.173 lesson. Each now lifts the
real sub rather than stubbing it. **After adding a call from inside code a suite lifts,
run EVERY suite and the bench and check the EXIT CODE, not the last line.**

Regression guards: the complete native `tools/t_*.pl` loop (31 scripts) exits 0,
`t_loads.pl` 20 passes against the BUILT ZIP, `bench_walk.pl`, `git diff --check`,
`matcher_sync_check.py` and `singleflight_sync_check.py` all clean.

### Previous build: 0.9.206

**0.9.206** — built 2026-09-09 for local testing; not installed or live-tested.
Fixes the Last.fm vocabulary/checkpoint defect found during the live 0.9.205
verification. Last.fm tags are classified individually before the artist answer
is stored, so `indie, usa` keeps and displays `indie` rather than blanking the row.
`indie` is now a valid family-less genre, while `usa` and other non-genres remain
rejected. Rejected-only raw arrays use the one-day negative age instead of being
mistaken for 30-day positive answers, and a due retry bypasses the raw response
cache so it really reaches Last.fm. Existing rows are reclassified at read time;
no genre wipe or parser-version bump is needed. See
[cache-priority-refactor.md](docs/cache-priority-refactor.md).

**This version bump preserves the whole cache.** Existing Last.fm rows containing
an accepted tag can contribute immediately under the corrected gate. Rejected-only
rows older than one day become due and are rewritten as proper empty checkpoints;
the ListenBrainz and release-group genre tiers are untouched.

### Also carried into 0.9.207 — the earlier 0.9.206 review fixes (previously unbuilt)

The 0.9.206 review found two second-order gaps; both were fixed in the source tree
and are BUILT for the first time in 0.9.207. All Releases week cards now carry `lbf_week=<week_start>` through the
registered browse command, so root refresh/revalidation cannot redirect a saved
tap to the adjacent week. The shared builder covers the plugin root, the full-feed
fallback and the `LBFAllReleases` Material home shelf; the old row coderef remains
for legacy clients. The explicit route validates the natural key and retains it in
the returned query so nested paging/actions re-walk the same week.

Concurrent Last.fm passes now recheck a shared successful artist checkpoint at
dispatch. The request limit is enforced against actual upstream requests rather
than by truncating the candidate queue, so a duplicate skipped after another pass
lands frees that allowance for the next unique artist. A failed request or failed
store write creates no checkpoint and therefore remains retryable. This covers the
For You and All Releases daily branches plus browse-triggered top-ups because all
three use `_warmLastfm`. No schema, cache-family, ordering, pacing or concurrency
change. See [code-review-0.9.206.md](docs/code-review-0.9.206.md) and
[cache-priority-refactor.md](docs/cache-priority-refactor.md).

Regression guards: `t_release_target.pl` 49 assertions, `t_weeksummary.pl` 16 and
`t_lastfm_priority.pl` 61. The complete native `tools/t_*.pl` loop (31 scripts),
`t_loads.pl`, `bench_walk.pl` and `git diff --check` are green. These shipped
unbuilt at 0.9.206; the 0.9.207 zip and SHA are the first to carry them.

### Previous build: 0.9.205

**0.9.205** — built and installed 2026-09-08; live Last.fm verification completed.
Fixes the Last.fm candidate-cap lockout diagnosed against the live 0.9.204 cache.
The worker used to stop after collecting 400 candidate artists and only then
discard fresh checkpoints. The same already-answered artists therefore occupied
the allowance on every pass: the live All Releases Last.fm stage claimed to finish
in 5.24s while 4,508 artist rows remained never asked. It now bulk-checks every
candidate first and applies the 400 bound only to real upstream requests. Each
Last.fm `warmstats` stage now reports candidates, fresh checkpoints, requests,
displayable genres, empty answers, vocabulary-rejected answers, failures and
genuinely deferred work. The live run examined 302 candidate artists, found 299
fresh checkpoints and made three requests (two accepted genres, one empty, zero
failures or deferred), proving the worker had advanced. W/C 31 August nevertheless
remained at 243/362 labelled rows. Hannah Cole exposed why: Last.fm had `indie, usa`,
but `indie` was still classified as a modifier and the rejected non-empty array was
treated as a 30-day positive checkpoint. That second defect is fixed in 0.9.206.
No schema/cache-family change; the preserved cache can continue filling. See
[cache-priority-refactor.md](docs/cache-priority-refactor.md).

### Previous build: 0.9.204

**0.9.204** — built and installed 2026-09-08; live scheduling/cache diagnosis
completed. Corrects the 0.9.200 detail-prewarm phase inversion found against the
preserved 0.9.203 live cache. General tracklist/streaming preparation now waits
until both main Last.fm tails finish; list opening and expansion reprioritise
artwork only, while opening one release owns an idempotent Last.fm hold for that
foreground lookup. Rebuilt all-warm artwork queues and fresh empty/vocabulary-
rejected Last.fm answers no longer consume or block paced requests, but the live
run exposed the candidate-cap ordering defect fixed in 0.9.205. `warmstats`
separates detail cache checks/hits from actual fetches and exposes whether the
main phase has released the detail remainder phase. No schema, cache-family,
feed-order or artwork-concurrency change.

### Previous build: 0.9.203

**0.9.203** — built 2026-09-08 for local testing; live cache diagnosis completed.
A genre-filtered All Releases week loaded the whole week's genre map before
paging, then discarded it and performed a second render lookup under the
150-release `GENRE_FETCH_MAX`. On W/C 31 August that made known genres after
row 150 render blank in Show All even though the warm was complete. The renderer
now reuses the filter's existing map: no API request, cache write, schema change
or cache-family bump. `tools/t_review_fixes.pl` drives the filtered week and
asserts one wide metadata read plus reuse by the rendered tiles.

### Previous build: 0.9.202

**0.9.202** — built 2026-09-08 for local testing; not installed or live-tested.
The plugin root and Material All Releases shelf now read compact indexed week
summaries rather than selecting and thawing the complete All Releases feed.
Selecting a week loads only that week's payloads, with generation-backed reuse;
fresh, stale and empty stores retain stale-while-revalidate/fallback behaviour.
The measured 3,255-row fixture fell from a ~20ms full read to a ~3ms five-row
root summary, while its 580-release week read took ~4ms. No schema bump: the
existing indexed `week_start` column supplies the summary. See
[cache-priority-refactor.md](docs/cache-priority-refactor.md).

### Previous build: 0.9.201

**0.9.201** — built 2026-09-08 for local testing; not installed or live-tested.
Decoded release feeds and their filtered/deduped section lists now reuse a
generation-validated in-process copy for 30 minutes. Payload-only changes,
releases shared across feeds, settings, Refresh and date-window rollovers all
invalidate correctly; genre and artist-sort enrichment remains live at render
time. The latest measured 3,255-row store read (~20ms here, ~200ms projected on
the Pi) is replaced on memo hits by a ~0.017ms indexed generation query. See
[cache-priority-refactor.md](docs/cache-priority-refactor.md) for the mechanism,
tests and remaining live scheduling work. No schema or cache-family bump.

### Previous build: 0.9.200

**0.9.200** — built 2026-09-07 for local testing; not installed or live-tested.
Release detail pre-warming now fills existing tracklist/streaming caches ahead of
opening albums. Adaptive priority and existing cached results drive the queue;
ready detail work precedes Last.fm. Shared flights coalesce foreground/background
fetches, and public MusicBrainz tracklists use courtesy spacing/shared backoff.
Queue counters are exposed by `lbf warmstats`. See
[cache-priority-refactor.md](docs/cache-priority-refactor.md) for scope, recovery,
776 passing checks and remaining scheduling/view-cache work. No schema or cache
family bump; the normal dev-build wipe still applies.

### Previous build: 0.9.199

**0.9.199** — built 2026-09-07 for local testing; not installed or live-tested.
Adaptive artwork prioritises requested/revealed rows, then resumes For You and
All Releases by week. Material release taps use explicit targets so a changed
list position cannot open a different album; nested detail/playback actions retain
the target. See [cache-priority-refactor.md](docs/cache-priority-refactor.md) for
protocol checks, tests, target expiry and remaining overnight queue work.
No schema or cache-family version change. Existing dev-build invalidation applies.

### Previous build: 0.9.198

**0.9.198** — built 2026-09-07 for local testing; not installed or live-tested.
Last.fm warm/top-up requests yield to core feed/playlist/follower work, artwork,
and active browsing. Both ListenBrainz metadata passes remain early. Shared
Last.fm pacing and watchdog recovery cover deferred and missing callbacks.
See [cache-priority-refactor.md](docs/cache-priority-refactor.md) for scope and
remaining work. No schema or cache-family version change; the existing dev-build
cache wipe still applies on the version change.

### Previous build

**0.9.197** — built 2026-09-05, **NOT installed and NOT tested.** Two field bugs, both
diagnosed from the running server and both fixed with the assertion that was missing.
**No schema change and no cache bump** — nothing here changes the SHAPE of a stored
value; the version bump alone triggers `_buildChanged`, which clears the derived tier
([[dev-builds-clear-caches]]).

**0.9.197 — "SEARCH IN LIST ON AN EXPANDED WEEK OPENS COMPLETELY THE WRONG ROW."**

**Material's "Search within list" is NOT the culprit and does not filter anything.**
`lms-search-list` (read from the shipped bundle) scans `view.items`, emits
`scrollTo(index)` and sets a highlight class; the click still passes the item OBJECT
and drills by that item's own `item_id`. It never re-fetches. So the client is holding
an order the SERVER has already changed — and search is simply the interaction slow
enough (type, 500ms debounce, arrow, tap) for that change to land in between.

**THE CAUSE IS THAT A WEEK'S ROW ORDER IS NOT DETERMINISTIC, and it cannot be.**
`item_id` is a positional crumb (`6.57`), and because the top level is coderef-driven
no session cache is minted, so the whole tree is rebuilt from `topLevel` down on every
click ([[xmlbrowser-no-session-cache]]). `6.57` therefore means *"whatever is 57th when
the click is resolved"*. That is only safe while the list is stable, and **both of its
ordering inputs are cache-only PEEKS that a background warm is actively filling**:
- **artist sort** — `_sortWithin` reads `peekArtistSorts`. An unwarmed name falls back
  to the display credit, so *Panda Bear* sorts under P and, once MB answers, under B.
  *(GONE 2026-09-14: the sort is A–Z on the display name, no peek — the genre filter
  below is now the freeze's only live mover. §A2 `ARTIST SORT IS A–Z ON THE DISPLAY NAME`.)*
- **the genre filter** — `_genreSelectFilter` buckets on peeked genre facts while
  `_kickGenreFill` tops them up. A release with no genre yet is filtered OUT and
  filtered back IN when its genre lands, shifting every row after it.

Both were live on the test server at diagnosis (`Sorted by Artist`, `Genres (7)`), and
the log shows the mechanism plainly: an expanded week walk at 21:18:59 logged
`genres: background top-up for 313 release(s)`, and ten seconds later
`warm: last.fm filled 24 artist(s)`.

**FIXED BY FREEZING THE ORDER, NOT BY CHASING THE WARMS** (`_frozenOrder`, keyed on
week + family lens + sort mode + genre selection, sliding `ORDER_FREEZE_TTL` 15
minutes). It replays the order a rendered page is holding over the CURRENT set:
- a row that reordered goes back where the user last saw it;
- **a row that ARRIVED is APPENDED**, so it cannot shift an index the client already
  holds — and arriving is the only thing a warm does to a filtered set;
- a row that VANISHED is gone and everything after it shifts by one. **Stated, not
  missed**: the alternative is rendering a release the filter has excluded.
The ids are re-stamped every walk, so the order is EXTENDED and never reshuffled.

**IN-PROCESS, NOT `kv`, AND THAT IS THE ARTWORK REWORK'S RULE ARRIVING HERE.** It is
transient view state (the `%pageState` class) and must not outlive a restart — but the
deciding reason is that a store WRITE here would be synchronous SQLite inside the
browse callback, which is exactly what stages 1 and 4 of the rework exist to remove.

**SLIDING, deliberately.** A week you keep looking at stays frozen; one you walk away
from re-derives 15 minutes later. A fixed expiry would drop the freeze mid-session,
which is the one moment it is for.

**WHAT DROPS IT AND WHAT DOES NOT.** Refresh drops it (`_dropOrderFreeze`) — the user
asking for the feed as it is now, and without that Refresh would fetch new releases
and replay them into the old order. The sort toggle, the family lens and the genre
picker need nothing: they are IN the key, so they re-derive by construction.

**Also fixes "the ordering moves when you collapse down again"** — same defect, seen
from the other end. Expand/collapse was never a wrong-row risk (`nextWindow=>'refresh'`
re-fetches, so client and server re-sync) but it did visibly reshuffle; with the freeze
a collapse is a stable prefix of the same order.

**TESTS.** New `tools/t_orderfreeze.pl`, **23 assertions**, and the shape is the point:
every section walks TWICE with the world changed in between, because the sort was never
*wrong* — it was merely *different on the second walk*, which a sorting test cannot see.
**Anti-tested five ways** via `LBF_BROWSE=`: freeze neutered **5 red**, not sliding
**1**, Refresh not dropping **1**, call site reverted to `_sortWithin` **2**, arrivals
sorted home instead of appended **3**.
**A FIXTURE BUG WAS CAUGHT BY ITS OWN CONTROL, and it is worth keeping.** The first cast
(Acua / Panda Bear / Zakè) put the MB sort-name back in the same slot, so the natural
order did not move and every assertion would have passed against a freeze that did
nothing. The control assertion — *"the NATURAL order really did move, else this proves
nothing"* — is what failed. **Any test of "X did not change" needs a live assertion that
X would otherwise have changed.**

**0.9.197 — AND THE STALL 0.9.196 SAID IT HAD REMOVED HAD ONLY MOVED.**

Raised while answering whether the same refactor explained a second report (Material
sitting on its three dots when expanding/collapsing a view). **That report is NOT
confirmed as this** — on a fully-warm box nothing reproduces (browse 0.08s idle, 0.16s
under a 24-connection cover burst, no cover pass in the last 8,000 log lines) — but the
defect underneath is real, measured, and new in 0.9.196.

`_coverLaunch` on an already-warm group increments `$coverRunning`, reads its three
markers, decrements it and returns — **nothing goes in flight**. So `$coverRunning <
$limit` is unchanged and `_coverTick`'s `while` shifts the next group, and the next, to
the end of the queue, in ONE turn. Measured against the shipped code with this repo's
own harness: **900 store reads in one `_coverTick` for 300 all-warm releases**, and
**identical with the brake ON** — a skipped group never occupies a slot, so the
concurrency width has nothing to bind on. Linear in queue length, so at
`COVER_WARM_MAX` it is the same **6,000 reads in one turn** §1.2 says were removed. And
**warm is the steady state**, so that was the normal case, not the edge one.

**WHY THE SUITE STAYED GREEN — the lesson is bigger than the bug.** 0.9.196 pinned the
fix with a counter scoped to the **queue builder** ("reads the store ZERO times").
Nothing counted reads during a **TICK**. The work moved from the measured half of the
mechanism into the unmeasured half, and the 90 reads its anti-test reports for a
30-release fixture are the 90 the pump now performs for it. **Moving work between two
places is new information about BOTH — re-point the counter, or it measures the place
the work left.**

**FIXED by `COVER_SCAN_BUDGET` (25 groups per turn):** the launch loop stops when the
turn is full and re-enters via `_coverArmResume`, a zero-delay timer. **Not foldable
into `_coverArmRestart`** — that one waits out `COVER_BROWSE_QUIET` because the brake is
on and nothing in flight will wake us in time; this must fire on the very next pass,
because there is nothing to wait for. Folding them would drain a warm queue at one
budget per 20 seconds. Own armed-flag, for the reason the restart has one.
**`&&` short-circuits, and that is what makes the stop-reason test exact:** the budget
is decremented only when the first two conditions passed, so it can go negative ONLY
when it is the thing that stopped the loop — a resume is never armed for a turn that
was going to stop anyway.

**STAGE 3 OF THE ARTWORK PLAN WAS THE REAL EXPOSURE, and its `[RESOLVED]` block is
reopened and re-closed in the doc.** Page-aligned warming unshifts ~30 unchecked groups
and pumps **on every page render**; on a warm page every one is a skip, so the pump
scans them and carries on into the nightly queue, with `COVER_NOW_GAP` gating the
unshift but not the scan — on the render path, while the user is browsing, which is
exactly when the brake turns out not to bind. Built on the 0.9.196 pump it would have
reintroduced the 0.9.130 class of blocking while looking like it had a guard.

**TESTS.** `t_coverwarm.pl` 101 → **111**, new §4d asserting reads **per TURN** (the
assertion that was missing), that an all-warm queue is not drained in one turn, that it
still drains across the resumes, that five pumps arm ONE timer, that a short queue arms
none, and that the bound holds with the brake ON. One existing assertion changed
honestly: "the pass still drains completely" now fires the resume timers first, because
a budget that stopped and never came back would stall the queue for ever — worse than
the stall being fixed. **Anti-tested three ways:** budget removed **7 red** (reporting
300 reads against a 75 cap — the defect at test scale), never resuming **4 red**, resume
flag unguarded **1 red**.
**`t_review_fixes.pl` needed a stub, and it is the `perl -c`-invisible class again** —
it evals the week coderef into its own package, so adding a `_frozenOrder` call inside
that coderef killed it with `Undefined subroutine`, exit 255 and **no FAIL line**, which
reads like a pass. Exactly the trap 0.9.196 recorded for `_noteBrowse`. **After adding a
call from inside code a suite lifts, run EVERY suite and check the EXIT CODE, not the
last line.**

All 26 suites exit 0; `matcher_sync_check.py` and `singleflight_sync_check.py` both 0.

**0.9.196** — built 2026-09-02, **INSTALLED AND VERIFIED LIVE 2026-09-03.** **STAGE 1
of the artwork/event-loop rework** (`docs/artwork-and-event-loop-rework.md`): the
Cover Art Archive ladder collapses to one source URL per cover, the warm groups a
release's three specs into one launch, a browsing-aware concurrency brake, and the
warm now filters before it fetches. No schema change, **no cache bump** —
`coverArtUrl`'s output is unchanged, so existing `lbf:imgwarm:` markers and existing
proxy renditions all stay valid.

**LIVE VERIFICATION, 2026-09-03 — WORKS AS DESIGNED, MEASURED, NOT ASSUMED.** First
install after the bump wiped `lbf:imgwarm:` (the dev-build derived-cache wipe on a
version change), so the very first tick warmed essentially the whole catalogue from
empty — the best possible test, nothing to skip. `["lbf","warmstats"]`'s covers
stage, on completion:

```
"3996 request(s) / 1332 release(s), 63 already warm, peak 8 in flight"
```

Three separate facts confirmed by that one line, none assumable from the code alone:
- **`3996 / 1332 = exactly 3.0`** — every release that needed fetching got all three
  specs launched as one atomic group, never a partial split (the 63 "already warm"
  skips are exactly `21 x 3`, i.e. whole releases skipped entirely, not partial
  specs). Proves `_coverLaunch`'s grouping held across a pass of this size, not just
  a handful of releases.
- **`peak 8 in flight`, not ~2-3.** Under the OLD request-counted concurrency, a
  limit of 8 requests would cap out around 2-3 releases in flight (8÷3). A clean 8
  is only possible if the unit genuinely changed to releases, confirming
  `COVER_CONCURRENCY_IDLE` and `_coverLimit()` are bounding by release as designed.
- **`["lbf","cachestats"]` afterwards: `lbf:imgwarm:` 4,065 rows**, matching
  `(1332 + 21) x 3 = 4059` almost exactly (the small gap is `_warmTrendingCovers`
  sharing the same marker family later in the same tick) — the persisted state
  agrees with the in-flight report, not just a snapshot artefact.

**Timing:** the covers stage took **8m47s** for 1,332 genuinely cold releases
(~2.5 releases/sec, with `genres_lastfm_all` competing for the same event loop
throughout); the whole warm tick **~10m6s**. Against the plan's own baseline (~1.1hr
for a single 2,157-release feed at the old per-request concurrency of 8), this
covered a comparable scope in well under a sixth of the time.

**Confirmed §1.4's filtering is why the number is 1,332 and not ~4,000+**: the raw
All Releases feed that tick was 4,099 releases; `_filterAll` (type checkboxes —
default only Album+Compilation ON — plus artwork-only, VA, blocked artists) cut
that down before the covers builder ever saw it, exactly as designed. Excluded
releases are not merely unwarmed, they are **also not rendered** under current
settings — same filter, same population, no visible gap. The one caveat, stated
plainly and not yet fixed: a release that becomes newly visible via a LATER
settings change (ticking a type, widening the genre picker) was never warmed and
renders bare until the sweep or a manual re-warm reaches it — this is exactly what
Stage 3 (page-aligned warming, not yet built) exists to close.

**Cross-checked against Qobuz's own imageproxy handler** (`plugin-Qobuz` `Plugin.pm`
`_imgProxy`, pulled live from `LMS-Community/plugin-Qobuz`): Qobuz uses the *same*
per-spec size-ladder LBF used to have — every Material spec maps to a different
`static.qobuz.com` URL, never collapsed to one. That's fine for Qobuz and was never
fine for LBF because the origins differ by ~30x: `static.qobuz.com` is a real CDN
(~0.05-0.09s/fetch, measured earlier in this project), Cover Art Archive has none
(~2.1s/fetch, 2 redirects through archive.org). Multiplying a 0.07s fetch by three
is free; multiplying a 2.1s fetch by three is six-plus seconds per cover. The
collapse-to-one-URL trick is a lever that only pays off when the origin is slow —
worth remembering before "just do what Qobuz does" is proposed for anything else in
this fleet.

**THE THREE-FETCH FINDING.** `Slim::Web::ImageProxy::getImage` queues by the
REWRITTEN SOURCE URL and resizes every waiting spec from one download — LBF's size
ladder mapped each of Material's three specs to a DIFFERENT CAA size, so a
release's three specs were always three different source URLs and could never
coalesce. A 2,000-release pass issued ~6,000 upstream fetches where it needed
2,000. `Plugin.pm`'s handler now rewrites every spec to `front-1200` (the only CAA
size that never upscales Material's largest ask, `_600x600_f`, and — because the
cost here is latency, not bytes — also the fewest bytes overall); the `getRightSize`
table is gone.

**PROBED BEFORE SHIPPING, because collapsing to one size makes artwork failure
all-or-nothing** — `_gotArtworkError` flushes a release's whole request bucket, so
one missing size would cost a row all three renditions where three independent
requests would not, and this is a fresh-releases plugin, whose population is
disproportionately newly-uploaded, partially-derived art. The newest 24 releases
on the live feed, all three sizes each: **22 answered 200 at every size, 2
answered 404 at every size, ZERO disagreed.** IA derives the thumbnails as one
task; asking only for 1200 cannot lose a cover 250 would have found.

**Browse.pm: the queue holds one GROUP per release, not one entry per spec.**
`_coverGroupsFor` builds them (shared with the page-aligned warm this stage is
designed to unblock); `_coverLaunch` fires a whole group in one synchronous turn
so all three land in the image proxy's `%queue` bucket together, which is what
lets them share the download. `COVER_CONCURRENCY` splits into `_IDLE` (8) and
`_BROWSING` (2), read fresh **per pump** via `_coverLimit()` so a browse arriving
mid-drain takes effect at the next slot without cancelling anything already in
flight — cancelling would waste a download nearly always most of the way through
a ~2s wait. `_noteBrowse()` marks the ten browse entry points (the nine subs plus
the All Releases week drill, a coderef rather than a sub). A restart timer covers
the one case the callbacks cannot — the pass is narrow, the user stops, and the
requests already out are slow — guarded by an armed-flag, since every landing
re-enters the pump and an unguarded arm schedules one timer per request.

**AND A STALL NOBODY HAD COUNTED, found while moving the marker check for the
page-aligned warm's sake.** The queue builder did one `$cache->get` per PATH
inside a feed's `onDone` — up to `COVER_WARM_MAX` x 3 = **6,000 synchronous
SQLite reads in one turn of the event loop**, on the loop that streams audio and
serves the image proxy. Same hazard class as the 16,000-statement ingest
(0.9.176), unnoticed for eight builds because nothing had counted it. The check
now lives in `_coverLaunch` — one read per launch, spread across the pump — and
the builder is asserted to read the store **zero** times.

**THE WARM ALSO NOW FILTERS BEFORE IT FETCHES.** The four `warmFeeds` call sites
were handing `_warmCovers` the RAW feed while every render path applies
`_filterSection` first, so blocked artists, unticked release types and hidden
Various Artists rows were warmed and then never drawn — eating slots out of
`COVER_WARM_MAX` for rows nobody sees. `_warmGenres` has filtered since it was
written; this is the same rule arriving at the covers. MuSpy filters through For
You, whose feed its rows are merged into. **Deliberately NOT applied: the release
FAMILY lens** (`_viewFilter`, Albums vs Singles & EPs) — it is a toggle the user
flips from the list itself, so warming only the active side would make the other
side cold on every flip. One stated consequence: a newly-ticked type stays cold
until the next warm, which the page-aligned warm (stage 3, not yet built) removes
entirely.

**DROPPED FROM THE PLAN, not built: stage 1.5** (warming follower/playlist/
trending-track rows). It would have reversed a measured 0.9.191 finding — those
rows resolve to streaming-CDN or local-library art, ~0.05s origin, "nothing there
worth warming" — and the mechanism was actively wrong for the commonest row:
`prefer_library` defaults ON, and a library row's `image` is a LOCAL
`/music/<id>/cover.jpg` path, which `proxiedImage` (built for remote URLs) turns
into the LMS **no-artwork placeholder**, not the cover. See
[[lms-imageproxy-local-path]].

**THREE TEST-HARNESS DEFECTS, ALL LATENT, ALL FIXED, RECORDED BECAUSE EACH IS A
CLASS.** (1) The suites' shared `grab()` sub-extractor walked source one
`substr($src,$i++,1)` at a time over a `:encoding(UTF-8)` — i.e. CHARACTER —
string, so it was quadratic; at `Browse.pm`'s current size `t_coverwarm.pl` had
grown to **101 seconds** and read as a hang. Replaced with a regex brace-scan in
all eight suites carrying it; `t_coverwarm.pl` is now 0.13s.
[[test-suite-grab-quadratic]]. (2) `ok()` DIED on a missing message — the guard
added for the list-context trap — which took every LATER assertion in the file
with it on a real failure; it now reports and continues. (3) An assertion
autovivified the empty structure it was asserting about
(`$PENDING[0]{when}` with nothing armed), which a snapshot-then-fire timer helper
then called as a coderef. Plus one `perl -c`-invisible gap: adding `_noteBrowse()`
inside a coderef a suite `eval`s into its own package broke that suite with
`Undefined subroutine` — compilation was clean everywhere else.

**TESTS.** `t_coverwarm.pl` 66 → **101** assertions. Section 1 inverted — it used
to assert the ladder picked the right size per spec; it now asserts the table is
gone and all three specs rewrite to ONE url, with the old ladder kept live as a
pinned demonstration that it produces three. New sections for the marker-in-
launcher property, the browsing brake, and the filtered warm. **Anti-tested
seven ways:** ladder reinstated 9 red, marker check moved back into the builder 2
red (reporting 90 store reads on a 30-release fixture — the defect at test
scale), spec-major ordering restored 11 red, brake removed 8 red, one entry point
left unwired 1 red, warm handed the raw feed 3 red, restart timer left unguarded
2 red (arming six timers for one pass). All 26 suites exit 0;
`matcher_sync_check.py` and `singleflight_sync_check.py` both exit 0.

**NOT YET BUILT of stage 1 (the plan is otherwise done): nothing** — 1.1–1.4 are
all in; only 1.5 was dropped.

> **⚠️ THE "PICK UP HERE: Stage 2" INSTRUCTION THAT USED TO SIT HERE IS DEAD —
> corrected 2026-09-10.** It was written at 0.9.196 and went on reading as the live
> next step while the work it pointed at was done by a different plan. **§2.1 (instant
> menu, weeks fill in) SHIPPED in 0.9.202**, on top of 0.9.201's generation-backed
> memos — which is also §2.1a's landing memo, given the real invalidation key the
> review asked for. **§2.3 (Last.fm last in the genre warm) is SUPERSEDED** by the
> 2026-09-07 direction: Last.fm is now gated behind core work, cover work and browse
> activity entirely, which is stronger than merely making it the last rung. **Only §2.2
> (a building row for For You) is still unbuilt** — `_buildingRow` exists but serves the
> playlist and follower paths, not For You.
>
> **Read `docs/cache-priority-refactor.md` FIRST for anything about warm order or
> priority.** It is the adopted plan; `artwork-and-event-loop-rework.md` and
> `warm-ordering-and-follower-latency.md` are the two it overtook, and both are now kept
> for their measurements rather than their stage lists.

**RAISED DURING STAGE 1'S VERIFICATION — `docs/overnight-detail-prewarm.md`, and it
SHIPPED in 0.9.200.** The overnight warm now pre-resolves a new release's tracklist and
streaming matches, not just covers/genres (`DetailWarm.pm` + the prewarm queue). This
paragraph used to say "not yet scoped for build"; what is still owed is live
verification of queue throughput and restart behaviour, plus a fixed overnight clock —
not investigation or design.

**0.9.195** — built 2026-09-02, **NOT installed and NOT tested**. **A FAILED SERVICE SEARCH IS NO
LONGER CACHED AS "THIS TRACK IS ON NO SERVICE".** Diagnosed live the same day, from the field:
an update cleared every cache, the warm fired `WARM_DELAY`(60s) later, and the first resolve of
the four created-for playlists pinned **8 tracks as unmatched**. A forced re-match seventeen
minutes later matched **every one of them** — 4 on Qobuz, 4 on Spotify. Nothing was missing from
any catalogue and `matcher_sync_check.py` was exiting 0 throughout. **TWO cache families bump**
(`lbf:stream:` 28→29, `lbf:track:` 9→10) to clear the misses already pinned on users' servers;
the four resolved-LIST layers re-key themselves off those (`_trackLayerTag`/`_streamLayerTag`),
verified rather than assumed.

**THE MISSES WERE NOT STALE — THEY WERE WRITTEN WRONG, AND THAT DISTINCTION IS THE WHOLE BUILD.**
The caches really were cold: the same warm queued **147 cover requests across 49 releases** at
17:41 and only **3 across 49** at 17:59 once populated, and the durable store was rebuilt at
17:39:27. So nothing survived the clear. What happened is that the cold pass ran while the box
was saturated — LBF's own ingest, the genre top-up, MusicBrainz 503 backoffs, and PFR's backfill
hammering Qobuz at 50 albums a minute — and **at LBF's boundary a service that FAILED to search
is indistinguishable from one that searched and found nothing.**

That is documented in this plugin's own source and was read straight past: `_searchSpotify`'s
CAVEAT records that Spotty's Pipeline **swallows API errors** — `_gotError` feeds the extractor an
error HASH, which extracts to nothing — so a failed search arrives as the SAME empty arrayref as a
genuine zero-hit. `_findPlayableTrack` treats only `undef` as inconclusive, so that empty arrayref
was a confirmed miss at `TRACK_NOMATCH_TTL`: **a week of "not on any service" for a track every
service has.**

**FIX 1 — ZERO RAW RESULTS IS AN ERROR SIGNAL, NOT AN EMPTY CATALOGUE** (`_emptyResultIsError`,
one carrier, called from all eight API-backed adapters — 4 album, 4 track). Every one of these
searches sends "<artist> <title>" to a FUZZY index that answers with up to 20-200 rows; even a
release the service has never carried returns near-misses (the Avalon Emerson miss that prompted
this returned **2 results, 0 matched**, which is the shape of a genuine absence). A completely
empty list almost always means the search never happened. **Spotty makes this the only signal
available** — `undef` never reaches us there.
- **EVERY call site is guarded by `!@out`.** A rule that could discard MATCHES would be far worse
  than the bug being fixed, so it can only ever fire on a no-match.
- **BANDCAMP IS DELIBERATELY EXCLUDED.** The rule rests on the index being dense enough that a
  query always finds SOMETHING; Bandcamp's catalogue is genuinely sparse, so empty is a plausible
  real answer there and gating it would put a permanently-absent album on a retry schedule for ever.

**FIX 2 — THE RETRY IS A BUDGET, NOT A STATE (`MISS_RETRY_SCHEDULE`, and this is the correction
that matters).** The first cut of fix 1 shipped the classic version of this mistake: it made an
inconclusive miss retryable and stopped there. Simon caught it — *"we should not be waiting for
ever for it to match, that will end up in a loop of it trying again and again infinitum"* — and he
was right, because a track genuinely on no service answers inconclusively **every time**, so it
re-searches on every expiry, for ever, and never converges to the durable no-match every other
miss gets. Worse, the resolved LIST cache stays short while any of its tracks is inconclusive, so
the whole playlist re-resolves on the same clock.
- Now `[1h, 6h, 24h]`: three attempts over ~31 hours — long enough to ride out an outage or a
  rate-limit window — and then the miss becomes an **ordinary durable no-match**. `_missRetryAt`
  returns `undef` once the budget is spent, and that `undef` is the exit.
- **THE ENTRY IS STORED AT THE FULL NO-MATCH TTL WITH ITS OWN `retry_at` INSIDE IT, NOT ON A SHORT
  TTL.** This is the load-bearing part: a short TTL would take the attempt count with it when it
  expired, so the budget could never be spent and **the loop would survive the fix meant to bound
  it**. Anti-tested (`Browse_shortttl`).
- **THE CALLER IS TOLD `retryable`, NOT `inconclusive`.** That is what lets the resolved-playlist
  cache stop being short: while a track is still retryable the list re-resolves on the 1h clock,
  and the moment the budget is spent it gets its normal TTL back. Without it every track could
  settle and the LIST would still churn hourly for ever.
- **A CONFIRMED miss never enters the schedule** — every service answered and nothing matched, so
  it is durable immediately, as it always was. Nothing about that answer can change within a day.
- `TRACK_INCONCLUSIVE_TTL` and `STREAM_INCONCLUSIVE_TTL` are **deleted**: they are the first step of
  the schedule now, and two constants nothing reads is exactly what a review flags.
  `PLAYLIST_INCONCLUSIVE_TTL` stays — it is the list layer, and it now converges too.

**FIX 3 — THE WARM WAITS FOR THE STREAMING SERVICES, BUT NEVER FOR EVER.** Installed is not ready:
a service plugin registers as soon as LMS loads it, but its API handler arrives later (account
read, token refresh, Spotty's helper starting), and the playlist resolve runs ~60s into a boot —
squarely in that window. `Browse::streamingNotReady()` probes each enabled adapter's new `ready`
coderef; `Plugin::_warmPlaylistsWhenReady` re-checks every `WARM_SVC_RETRY`(30s) up to
`WARM_SVC_MAX_WAIT`(300s), then **warms anyway with a warning**.
- **SIGNED OUT IS READY, NOT "NOT YET".** Spotty's `getAPIHandler` returns undef both for an
  account that will never exist and for one whose helper is still starting; waiting on the first
  would defer the warm to the cap on **every boot** for a user who simply has no Spotify. The probe
  consults `hasCredentials`, the same reading `_searchSpotifyTrack`'s no-handler branch already
  takes. Bandcamp registers no probe at all (no handler concept) and counts as ready.
- **THE WAIT IS SCOPED TO THE STREAMING STAGE, DELIBERATELY — it is NOT in `_warmTick`'s defer.**
  Holding the whole tick would also hold `warmFeeds` and the genre ladder, which touch no streaming
  API and are the two things a view needs to render at all. The scan defer can hold everything
  because a half-scanned library poisons the library tier the same way; this one cannot.
- **WHAT THE PROBE DOES NOT CATCH, so do not treat it as a guarantee:** a handler that EXISTS but
  whose token is stale reports ready, and nothing here sees a rate limit. Those show up only at
  search time — which is what fix 1 covers. **The two are belt and braces for one failure, not
  alternatives.**

**TESTS.** New `tools/t_coldwarm.pl` — **67 assertions** against the real subs, with
`MISS_RETRY_SCHEDULE` and the two warm constants READ OUT of the sources rather than restated (a
suite that pins its own copy of a cap cannot catch the cap changing). §7 pins TERMINATION directly:
the attempt past the budget schedules nothing, it stays refused however many attempts are claimed,
each retry backs off further than the last, and the read/write cycle terminates after exactly three.
**Anti-tested seven ways** via `LBF_BROWSE=`/`LBF_PLUGIN=`: budget removed → **4 red**; short TTL →
**1**; confirmed misses entering the schedule → **1**; rule neutered → **3**; call sites stripped
(the pre-fix code) → **16**; readiness wait removed → **5**; cap removed → **5**; `!@out` guard
dropped → **1**.

**ONE EXISTING ASSERTION WAS CHANGED, and it is the class this file already warns about.**
`t_buildingstate.pl:262` pinned the SOURCE SHAPE `warmFeeds(sub {…warmCache()` and went red on a
correct change, because the callback now calls `_warmPlaylistsWhenReady`. It pins the PROPERTY in
two halves instead: the playlist warm is reached FROM the callback, **and** `_warmTick` never calls
`warmCache` directly — which is what "the same turn" actually means. Suite 75 → 77.

**THE METHOD NOTE WORTH KEEPING, because it is why this took two passes.** The first diagnosis
called the misses "stale" and attributed them to pre-update state. With the cache cleared that was
impossible, and saying it out loud is what produced the real answer. Then the first fix retried for
ever. **Both errors were caught by being asked "how?" rather than by re-reading the code** — the
cover-warm counts (147 vs 3) settled the first, and one sentence from Simon settled the second.

**0.9.194** — built 2026-09-02, **NOT installed and NOT tested**. **THE FLEET MATCHER SYNC —
the hold is over and `matcher_sync_check.py` exits 0 again.** LBF takes the three
Discography-origin rules that PFR took in 0.9.33, so DSC, PFR and LBF are now byte-identical
on all nine shared subs. **No schema change. FIVE cache families bump** — see below, and the
fifth is the one worth reading.

**THE THREE RULES, each pinned by the field failure that motivated it** (full reasoning lives
at each site in `Browse.pm`, ported verbatim so the copies stay diffable):

1. **Apostrophes ELIDE, they do not become a space** (DSC 0.44.26). Spacing keyed
   "Jane's Addiction" as `jane s addiction` against `janes addiction`; `_artistMatch` is an
   exact-token SUBSET test behind a MANDATORY artist gate, so the act matched **nothing** from
   any source. Same for O'Connor/OConnor, D'Angelo, The B-52's. **The `'n'` contraction is
   guarded** — there the mark joins two WORDS rather than sitting inside one, and all three
   spellings of `Rock'n'Roll` currently agree; eliding blindly would key the first `rocknroll`
   and break a set that works.
2. **`%FOLD` 10 → ~90 entries** (DSC 0.44.26). The short table covered Latin-script BAND names;
   extended-Latin and IPA letters survived NFD as themselves and then met the `[^\p{Alnum}]`
   pass as ordinary alnum characters, keying a name one way from one source and another from
   the next.
3. **Compound-word collapse in `_albumMatches`** (DSC 0.50.6). MB "England's Newest Hit Makers"
   vs the services' "…Hitmakers". **EXACT space-collapsed equality, never a prefix** — collapsing
   spaces destroys the word boundary the prefix tiers rely on, so a prefix rule here would let
   "hitmakers…" swallow an unrelated title. Length-gated at ≥6.

**FIVE CACHE FAMILIES BUMP, AND THE RULE IS NOT "BUMP THE MATCH CACHES".** It is: *a family
moves if `_norm` decided what is stored, OR if `_norm` built the key it is stored under.*
`lbf:stream:` 27→28 and `lbf:track:` 8→9 are the decisions; `lbf:artistmbid:` 2→3 and
`lbf:rgbyname:` 1→2 are decisions one layer out (both accept through `API::_foldEq`, and a
cached MISS is the stale one that matters — a name the new fold accepts would keep answering
"not found" for the whole TTL). **`lbf:hdisco:` 1→2 is the one that is easy to miss:** its
cache KEY is `lc($artist)` and does not move, so the entry still HITS — but its VALUE is a map
**keyed by `_foldKey($title)`**, i.e. by `_norm` output, so every lookup folded the new way
misses inside a map written the old way. Silent, and it would have made the 0.9.179 hosted
resolver fall back to MusicBrainz for exactly the titles this sync fixes. **When `_norm`
changes, grep for `_foldKey` and `_foldEq` as well as for the matcher's own callers** — that
rule is now recorded above `KEY_VERSIONS` in `DB.pm`.

**`lbf:pl:resolved:` and the three resolved-LIST families are NOT bumped by hand, and that is
correct now.** The layered-cache rule became STRUCTURAL: each outer key embeds the inner
version via `_trackLayerTag()` / `_streamLayerTag()`, so bumping `lbf:track:` necessarily
re-keys the playlist, follow and trending-resolved lists, and `lbf:stream:` re-keys the
trending-albums aggregate. Verified all four outer keys carry their tag rather than trusting
it ([[lbf-bump-every-cache-layer]] is the trap this engineered away). **`lbf:bcmatch:` is not
in `KEY_VERSIONS` at all** — a hand-curated Bandcamp pin is a table, not a cache, so the bump
question cannot arise.

**SEARCH HUB IS EXCLUDED AND PINNED** (Simon, 2026-08-29 — on hold, no development). Its
`_norm` and `%FOLD` are pinned in `matcher_sync_check.py`'s `VARIANTS` **rather than removed
from `REPOS`**: pinning keeps SH compared and keeps the alarm if it ever moves without a
conscious re-pin, where deleting it would lose that for good.

**TESTS.** New `tools/t_matchersync.pl` — **46 assertions**, PFR's 41 ported verbatim (same
assertions, same order, only the module path and env override changed, so the two files stay
diffable) plus **an LBF-only section 4**. That section earns its place: `_trackMatches` is
LBF's alone, so the fleet check cannot say a word about it and PFR's copy never exercises it —
it pins that rules 1 and 2 reach the playlists / follow feed / DSTM mixers, and that the
compound tier deliberately does NOT apply to tracks. `%FOLD` and every sub are GRABBED from
`Browse.pm`, never retyped, since a hand-copied table is exactly the drift the suite exists to
catch. **Anti-tested per rule, independently: 7 / 8 / 3 red** — rule 1 is 7 rather than PFR's 6
precisely because the LBF-only track assertion goes red with it. Every mutant fails only its
own rule's assertions.

**ONE HARNESS TRAP, carried from PFR and worth reusing:** Perl sets the UTF8 flag on a literal
only once it carries a codepoint above U+00FF, and `_norm` folds only inside
`if ($HAVE_NFD && utf8::is_utf8($s))` — so a fixture like `"\x{f0}ark"` silently SKIPS the fold
and fails against perfectly good code, while `"\x{283}ine"` passes. The fixtures are
`utf8::upgrade`d, which reproduces production (live input is decoded from service JSON and
always arrives flagged) rather than papering over it.

**0.9.193** — built 2026-09-02, **NOT installed and NOT tested**. Both findings of the 0.9.192
code review (`docs/code-review-0.9.192.md`), each with its mechanism, its guard and its
anti-test count. Both are in `API.pm`'s feed path. **No schema change and no cache bump** —
nothing here changes the SHAPE of a stored value, and the version bump alone triggers
`_buildChanged`, which clears the derived tier and the genre answers on first start
([[dev-builds-clear-caches]]).

**BOTH ARE SECOND-ORDER CONSEQUENCES OF THE 0.9.192 FIXES THEMSELVES — read them that way.**
Neither is a regression of older code and neither is a re-report. Each follows from a *correct*
fix that changed who participates in a mechanism without the other end of that mechanism being
re-read: 0.9.192 widened who CLAIMS a guard without revisiting who RELEASES it, and it un-gated
a fetch without revisiting what that fetch's CALLER is then handed. Both defects sit one frame
from the line that changed.

1. **`%REVALIDATING` was a flag where its own key demands a COUNT.** It is keyed on the FEED
   but was released per FETCH, unconditionally — so two foreground fetches of one feed on
   different `$ikey`s (a browse and a forced warm on another sort, precisely the overlap
   0.9.192 opened) both claimed the single entry and **whichever finished first deleted it**.
   The survivor ran unguarded and the next background revalidation sailed past the guard:
   duplicate request, duplicate ~3,000-release chunked ingest ([[lbf-ingest-event-loop-stall]]).
   The watchdog had the same hole in reverse — one dead fetch cleared a healthy sibling's claim.
   **`%INFLIGHT` could never cover this**: it is per-REQUEST, and two fetches asking different
   questions of one feed is the whole reason the coarse guard exists beside it.
   **The coarse key STAYS** (two revalidations differing only by sort are still two requests,
   and the rate limit is per-user); only the release changed — `$REVALIDATING{$feed}++` plus an
   **idempotent** per-fetch `$unclaim`. **The `$claimed` flag is load-bearing, not defensive**:
   a bare `delete` was idempotent for free, a decrement is not, and a second release would free
   a SIBLING's claim — the original bug by another door.
   **`%REVALIDATING` is now `our`**, for the reason `%FEED_MEMO` is: a suite drives fetches it
   deliberately never answers, all on one feed key, and **the boolean hid that** because any
   single release deleted the entry. A count does not, so the registry has to be resettable or
   each test section asserts about the ones before it.

2. **The forced MuSpy warm answered with the fetched SLICE, not the store.** 0.9.192's `!$force`
   gate is right, but the success path resolved the caller with the raw `?limit=100` payload
   while **every other exit** — cached, refused, unparseable, network failure — answers from the
   UNWINDOWED store (rotation off, 120-day retention), exactly as the comment above the sub
   insists. `warmFeeds` hands that answer straight to `_warmCovers`, so stored rows inside the
   display window that fell outside the 100 **silently lost their nightly cover warm**, and the
   5s memo briefly published the short list to For You. **This is the sub's own rule arriving
   from a new direction** — "a truncated list is not proof of absence" is why rotation is off;
   serving the slice as the answer is the same mistake at the other end. Success and refusal now
   converge on `$serveStored`, deliberately: the caller gets what the STORE holds either way,
   never the raw slice.

**TESTS.** `t_feedsingleflight.pl` 78 → **88**. A new section for finding 1 (*THE FEED GUARD IS
A COUNT, NOT A FLAG*, 9 assertions, behavioural against a stale-but-populated store) pins that
the first fetch landing does not free the second's claim, that the count still reaches zero
(the failure a naive refcount trades for the one being fixed), and that a fired watchdog frees
only its own. For finding 2 **one assertion became two, and the pair is the point**: the answer
must contain the FETCHED row (0.9.190 — the warm acts on what arrived) **and** the stored row
outside the slice (the warm warms what the view renders). Either alone passes against the wrong
behaviour — asserting only the first is how the 0.9.192 assertion read.
**The MuSpy ingest stub had to become STATEFUL**, and that is a finding about the test: with a
no-op ingest the store can never reflect the fetch, so the section could only ever pin a stub
artefact. **Anti-tested per defect:** the unconditional release → **3 red** (one reading 3
requests where 2 were expected — the duplicate fetch itself); serving `$rels` → **1 red**, with
the FETCHED assertion beside it still GREEN, which is the evidence the two are independent.

**0.9.192** — built 2026-09-02, **NOT installed and NOT tested**. All three findings of the
0.9.191 code review (`docs/code-review-0.9.191.md`): two in `API.pm`'s feed path, one in the
Trending Albums cover warm. **No schema change and no cache bump** — nothing here changes the
SHAPE of a stored value, and the version bump alone triggers `_buildChanged`, which clears the
derived tier and the genre answers on first start ([[dev-builds-clear-caches]]).

**0.9.192 — THE FIRST TWO ARE THE SAME EVENT: 0.9.190 CHANGED THE WARM'S ROLE.**

That build turned the nightly warm from a background revalidation into a **foreground caller**
(`force => 1`). Both defects are consequences of that role change landing in code whose guards
were written around the old one, and **neither is visible from the warm's own call site** —
both are two frames down, in decisions made about `$bg`. Worth reading as one thing.

1. **`force` did not reach MuSpy's store short-circuit.** It gated the memo, and the comment
   above the sub asserted that was the whole of it because "MuSpy has no store short-circuit
   (it always fetches)". It has one. With `WARM_INTERVAL` and `FEED_STALE_AFTER` both 24h, any
   browse inside the window leaves a fresh store, so **the nightly forced warm returned
   yesterday's rows and issued no request** — the exact bug `force` exists to fix, arriving
   through the other door, and invisible in `warmstats` for the same reason the original was
   (the stage completes quickly, having done nothing).

2. **The two dedupe guards could no longer see each other.** `%REVALIDATING` was claimed only
   when `$bg` and `%INFLIGHT` only when not. That was harmless while the warm WAS the background
   revalidation — it set `%REVALIDATING`, and an overlap was impossible by construction. Once the
   warm took the `onDone` branch, a browse-triggered revalidation could run alongside it: two
   ListenBrainz requests and **two ~3,000-release chunked ingests of one payload**, which is the
   one thing on this path that must not happen twice ([[lbf-ingest-event-loop-stall]]).

**BOTH GUARDS ARE KEPT, WITH ONE JOB EACH — do not collapse them.** `%REVALIDATING` is now
claimed by every fetch and keyed on the **feed**; it suppresses BACKGROUND refreshes only,
because a background walk has an answer on screen already and skipping is free. `%INFLIGHT` is
now claimed by every fetch and keyed on the **request** (memo key + headers); it blocks nobody —
a foreground caller OWES AN ANSWER, so it parks on an identical in-flight fetch and is answered
from it, while a different question proceeds as it must. The coarse key is deliberate: two
revalidations of one feed differing only by sort are still two requests, and the rate limit is
per-user, not per-question.

**LETTING A BACKGROUND FETCH HOLD `%INFLIGHT` HAS THREE CONSEQUENCES, all handled.** `$fanout`
lost its `return if $bg` (it is the only thing that releases the claim, and a background fetch
may now carry waiters). **The leak watchdog is armed for a background fetch too** — not
belt-and-braces: a background callback that never arrives would otherwise strand every later
cold open of that feed on a list nothing drains, the permanent failure `%INFLIGHT_TIMER` exists
to prevent, newly reachable from the one role that used to be exempt; it clears `%REVALIDATING`
as well, or one dead background fetch would suppress every future revalidation of that feed for
the life of the process. And `$failed` keeps its early exit for a background fetch with **no**
waiters, so the log line and the memo refresh still belong to answering someone.

**TESTS.** `t_feedsingleflight.pl` 55 → 78, in two new sections, both behavioural. The MuSpy one
installs a store that ANSWERS and is FRESH — the state in which the short-circuit exists at all —
and pins that forced answers with **what the fetch returned, not the stored copy**; the memo
assertions could never have seen this, since the memo is a 5s window. The guard one runs against
a **stale but populated** store, the state both roles meet in, and pins both directions plus the
release of the claim and the failure path.

**ANTI-TESTED FOUR WAYS, and the split is the point:** MuSpy's store gate un-gated → 4 red; only
`$bg` claims `%REVALIDATING` → 1 red; only `!$bg` claims `%INFLIGHT` → 5 red; `return if $bg`
restored in `$fanout` → 3 red. **The first cut of the guard section asserted only the
same-question case and passed with the per-feed guard removed entirely** — `%INFLIGHT` satisfies
that case on its own. The case that distinguishes the two guards is a browse asking a DIFFERENT
question (another sort) of the SAME feed. *Two guards need two cases; an anti-test that goes red
on one mutation is not evidence that it covers the other.*

**0.9.192 — AND THE THIRD FINDING: TRENDING NOW GETS ITS COVER THE WAY EVERY OTHER VIEW DOES.**

`_warmTrendingCovers` queued a release-GROUP cover for every aggregate with a
`release_group_mbid`, while the ROW falls back to group art only `unless caa_release_mbid` —
different tests, and uncorrelated, since a mapped aggregate normally has both ids. So every
mapped row warmed 3 Cover Art Archive covers (~2.1s each) and 3 `lbf:imgwarm:` markers that
nothing would ever request: up to **300 wasted requests** per tick
(`TRENDING_MAX` 50 × 2 ranges × 3 specs), ~78s of background work. Once per 25-day marker in
production — but every dev build wipes `kv`, so in development it was every build.

**FIXED BY DELETING THE SECOND PATH, NOT BY REPAIRING IT** (Simon: *"fix it so it works like the
others, we don't want to maintain two different paths to this"*). The right question turned out
to be why trending was different at all:

- **the three feeds each have ONE art shape per row, filed under the key `coverArtUrl` READS** —
  LB rows carry `caa_release_mbid`, MuSpy rows carry `caa_release_group_mbid` (set once in
  `_parseMuSpy`; MuSpy has no release-level mbid). `coverArtUrl($rel)` is therefore total: one
  call, one answer, and `_warmCovers` is right by construction with no branch to duplicate.
- **a trending aggregate can be EITHER**, per row, in one list — the unmapped-listen gap
  `_aggregateAlbums` exists for, which only the stats-derived views have. And
  `_trendingAlbumRel` filed the group id under `release_group_mbid`, a key `coverArtUrl` does not
  read — so the row recovered it in `_trendingAlbumRow` with a hand-built second hashref behind
  an `eq ICON` test. **That made "which URL does this row use" a decision in the renderer rather
  than a property of the rel**, and anything wanting the URL without rendering the row had to
  replay it. The warm replayed it with the wrong condition.

So `_trendingAlbumRel` now carries `caa_release_group_mbid` too, `coverArtUrl`'s own priority
(release → group → undef) makes the choice it was hand-rolling, and
**`_trendingAlbumFallbackRel` and the ICON branch are gone**; `_warmTrendingCovers` is one `map`,
the same shape the feed callers use. Rendering is unchanged in all three cases. **One deliberate
change:** an unmapped row's DETAIL page showed no artwork and now shows the release-group cover,
matching the list row it was opened from.

**A SECOND BUG WENT WITH IT, found while explaining the first.** `_warmCovers` sorts newest-first
and the queue order IS the priority (0.9.189). The fallback hashref had no `release_date`, so
every one sorted to the FLOOR in all three spec passes — the genuinely unmapped rows, which have
no other art source, were queued behind every mapped row. A small rerun of the ordering bug
0.9.189 exists to fix, and it disappears with the hashref.

**TESTS.** `t_coverwarm.pl` 57 → 64. **The old §5 could not have caught this**: it asserted the
warmed path is byte-identical to what the row requests, for a mapped album and an unmapped stats
row, and both were true — it never asked whether the mapped album should have been queued for the
group URL as well. *An assertion that every warmed path is correct says nothing about whether
every warmed path is needed; only COUNTING sees work that is right but unwanted.* §5 now pins the
exact count, that the mapped row does not also warm its group cover, that both shapes resolve
through the SAME builder, and — at source level — that the fallback builder is gone and the row
no longer re-tests for `ICON`. **Anti-tested** by restoring the 0.9.191 shape: **5 red**, the
count reading **9 instead of 6** — the waste itself.

**0.9.191** — built 2026-09-02, **NOT installed and NOT tested**. **People You Follow warmed no
artwork at all.** Trending Albums (This Month / This Year) now warm their covers on the same
queue as the release feeds. No schema change, no cache bump.

**0.9.191 — THE SECTION NOBODY WIRED UP.**

`_warmCovers` had exactly three callers, all inside `warmFeeds`: For You, All Releases and
MuSpy. So every Trending Albums row was cold on first sight, every time, at ~2.1s of Cover Art
Archive latency each — the same "artwork missing, then it populates" symptom as the release
feeds, arriving from a section that had simply never been connected to the warm.

It runs on a **cache hit as well as a fresh build**, and that is the point rather than an
accident: `_buildAlbumsData` answers its callback with the stored aggregates while the data is
inside its TTL (2/7/30 days by range), so the list is in hand either way — and the COVERS
expire on their own schedule, independently of the list. A warm that skipped the cached case
would leave exactly the rows a user is most likely to open still cold.

**ONE BUILDER PER URL, AGAIN.** The warm needs the same `$rel` the row renders from, so
`_trendingAlbumRel` and `_trendingAlbumFallbackRel` are split out of `_trendingAlbumRow` and
used by both. A second copy of that mapping is precisely how the release-group cover URL came
to be built two different ways (fixed in 0.9.188); the fallback matters most, because an
UNMAPPED stats row — no `caa_release_mbid`, cover served from the release GROUP — is the case
most likely to be cold and least likely to be noticed.

**WHAT DELIBERATELY DOES NOT GET A COVER WARM, checked rather than assumed.** `coverArtUrl` is
reachable from only one row builder (`_buildReleaseItem`), so Cover Art Archive covers appear on
RELEASE rows and nowhere else. Trending **Tracks**, the follow feed (Recommended) and the
Created-for-You playlists all render *resolved* rows, whose artwork comes from the streaming
service or the local library — and a service origin is ~0.05s (measured, `static.qobuz.com`)
against CAA's ~2.1s. There is nothing there worth warming.

**AND THE LISTS THEMSELVES ALREADY REFRESH OVERNIGHT.** Worth recording because it looks like a
gap and is not: the nightly tick calls `_warmTrending` unforced, so a range whose TTL has
expired REBUILDS on the tick and one still inside its TTL reports `cache-hit`. That is the TTL
doing its job, not the warm skipping work. The follow feed is separately force-fetched
(`_warmFollow` has passed `force => 1` since it was written). The only thing that was missing
overnight was the artwork, which is what this build adds.

**TESTS.** `t_coverwarm.pl` 50 -> 57, with a section that pins the property that actually
matters: the warmed path is byte-identical to the image `_buildReleaseItem` puts on the row,
asserted for BOTH a mapped album and an unmapped stats row, plus that the covers are JPEG like
every other row. Then the half a unit test of the helper cannot see — that both ranges call it,
counted over comment-stripped source, and that `_buildAlbumsData` really does answer its
callback on the cache-hit path the warm depends on. Anti-tested two ways: dropping a range's
warm, and having the warm guess the fallback URL instead of reusing the row's builder.

**0.9.190** — superseded by 0.9.191. **The nightly warm was
warming yesterday's feed.** Both release feeds (and MuSpy) now take `force => 1`, and
`warmFeeds` passes it. No schema change, no cache bump.

**0.9.190 — "IT ONLY UPDATES WHEN I OPEN IT" WAS NEVER A SCHEDULING PROBLEM.**

The tick fired every night. It warmed the wrong list.

`getFreshReleasesForUser` / `getFreshReleasesAll` both short-circuit on the store:

```perl
my ($stored, $stale) = _feedFromStore($feed, $from, $to, 1);
if ($stored) {
    $args{onDone}->(_memoSet($memoKey, $stored));   # fires NOW, with the OLD list
    _fetchReleaseFeed(...) if $stale;               # revalidates — nobody waits
    return;
}
```

That is right for a BROWSE and is what makes an open instant. It was wrong for the WARM, the
one caller whose entire purpose is to act on what actually arrived. `onDone` fired with the
stored list, so `_warmCovers` and `_warmGenres` never saw a release that landed today; the
revalidation ingested it, and its cover was warmed no earlier than the NEXT night's tick.
Visible in `warmstats` all along and read straight past: **foryou_feed 0.00s, all_feed 0.02s**
— no HTTP on a nightly tick. Neither sub accepted `force` at all; the word appears throughout
the warm for playlists, follow and trending, which is what made its absence here easy to miss.

Forced, the call goes to the fetch path WITH an `onDone`: answered with what came back,
single-flighted like any foreground open, memo refreshed for the browse that follows. Failure
needed no new code — `_fetchReleaseFeed`'s failure path already serves the stored copy to
`onDone` — so an outage still warms the stored list rather than warming nothing. MuSpy takes it
too (it has no store short-circuit, so gating its memo is the whole of it). **Only the warm
passes it.** Every browse path keeps stale-while-revalidate.

**MEASURED, AND THE ANSWER TO TWO OTHER QUESTIONS ASKED AT THE SAME TIME.**

*The 4-week All Releases window, covers probed warm-vs-cold before this build:* W/C 14 Sep 9/10
warm, W/C 7 Sep 9/10, W/C 31 Aug 3/10, **W/C 24 Aug 0/10**. That is the 150-release cap sorted
newest-first against 2,157 releases, and it is what 0.9.189 raises. Re-run it after installing.

*Why Qobuz "seems pre-cached" and we never do:* it isn't cached — **it has a CDN and Cover Art
Archive does not.** Same measurement, origin only: `static.qobuz.com` **0.05-0.09s**, 0
redirects; `coverartarchive.org` **2.2-2.5s**, TTFB 2.08-2.35s, **2 redirects** (CAA ->
archive.org/download -> a `dn*.archive.org` node). Qobuz's COLD fetch is ~30x faster than ours
and is indistinguishable from a cache hit, so the Qobuz plugin does no warming at all. **There
is no strategy there to copy.** Bypassing the redirect chain was checked and rejected: the
final node is itself 1.0-1.3s, so it saves ~45% and the node hostname is not stable. CAA is
simply slow, which is why "an hour" — it is 2.1s x N of origin latency, not our processing.
Parallelism and warming ahead are the only levers, which is what 0.9.189 does.

**TESTS.** `t_feedsingleflight.pl` 37 -> 55, with a new section that installs a store which
ANSWERS (the rest of the file stubs it empty, since "cold" is what the single-flight race needs)
and pins: unforced + fresh store makes NO request and answers from the store; forced goes to the
network and answers with **what the fetch returned, not the stored copy**; a forced fetch that
FAILS still answers, degrading to the stored list; and forced skips the memo. Plus the half a
test of API.pm alone cannot see — that `warmFeeds` actually passes it, counted over
comment-stripped source at every feed call site. `LBF_BROWSE` override added so that check can
be anti-tested. Four mutants, each failing on its own property.

**TWO TRAPS THIS SECTION COST A PASS EACH, worth recording.** `_feedMemoKey` covers
(section, sort, wp, wf) and `WEEKS_MAX_SIDE` is **3** — so the legal week space is ten pairs,
the earlier sections use most of them, and `_clampWeeks` silently folds an out-of-range pair
onto one already taken: `(4,0)` became `(3,0)`, the new section read ANOTHER section's memo, and
it passed for the wrong reason. Vary the **sort** instead; it is part of the key and has no
clamp. And an assertion that fails must not then `die` on the empty `@REQUESTS` it was
asserting about — that took every later assertion in the file with it, so a real regression
reported two failures and hid the rest.

**0.9.189** — superseded by 0.9.190. **The cover warm stops being
the bottleneck.** Three changes to the same pass: it runs 8 requests wide instead of one, it
covers 2,000 releases per feed instead of 150, and it walks the queue SPEC-first so the first
third of the work gives every row its list-row cover. No schema change, no cache bump.

**0.9.189 — WHY A COLD FEED TOOK HOURS, MEASURED RATHER THAN REASONED.**

0.9.188 made each cover ~6x cheaper to CACHE (JPEG, not re-encoded PNG). It did nothing about
how long a cold pass takes, and the report after installing it was still "painfully slow from
scratch, and artwork is missing when I open a view and then populates". Both halves were right,
and they had two different causes.

**THE COST IS ORIGIN LATENCY, NOT WORK.** Cover Art Archive 307s to an archive.org node with no
CDN: ~2.1s to deliver 25-41 KB, measured direct, five samples. That is almost entirely waiting,
and waiting parallelises. Measured through the proxy on the live server, fixed batch, cold
covers:

| in flight | covers/s | vs serial |
|---|---|---|
| 1 (old) | 0.40 | — |
| 4 | 1.20 | 3.0x |
| 8 | 1.62 | 4.1x |
| 16 | 2.77 | 6.9x |

The old runner was one request at a time with a 0.1s gap, and the comment defending it claimed
a parallel burst was "neither faster for us nor kind to them". The first half is simply false.
`COVER_CONCURRENCY` is now 8 — not 16, because these requests go to OUR OWN server and each
occupies an LMS HTTP handler slot a browsing user might want. Still scaling at 16 if that trade
ever looks different.

**THE CAP WAS THE OTHER HALF, AND THE BIGGER ONE.** `COVER_WARM_MAX` was 150 against an `all`
feed holding 2,157 in-window releases — **93% of All Releases rows had no warmed cover at
all**, so opening almost any week showed bare rows filling in front of the user at ~2.1s each.
No amount of speed fixes that while the cap binds. Now 2,000. The old comment's premise
("nobody scrolls that far") was answering the wrong question: this is not about the tail, it is
about whether the row you are looking at has a cover. At concurrency 8 a whole feed is ~1.1
hours of background work rather than ~4.5, and markers hold 25 days, so it is a first-run cost.

**SPEC-MAJOR, NOT RELEASE-MAJOR.** The queue is walked in order, so the order IS the priority,
and it was the wrong way round: each release got all three of its specs before the next got
any. A pass still running therefore left a third of the feed warm at every size and the rest
with nothing — while `_150x150_f`, the size a standard-dpi list row actually asks for, was
still unfetched for most of the rows on screen. Walking spec-first means the first third of the
work leaves EVERY row with its list-row cover. Same paths, same total work; only the order
changed, which is exactly why a set-comparison test could not see it.

**THE PUMP IS RE-ENTRANCY-GUARDED.** `$done` runs INLINE when a request cannot be constructed
at all, so without a guard a run of launch failures recurses one frame per queued path — and
the queue is now thousands deep, not 150.

**STILL NOT FIXED, and it is now the top of the artwork list:** nothing prioritises the page
the user is actually looking at. The warm is strictly background and always races the reader on
a cold store. Page-aligned warming (render page N, queue page N+1) is the remaining piece.

**TESTS.** `t_coverwarm.pl` 44 -> 50 assertions. Section 4 was asserting the runner was SERIAL
— it now pins the BOUND instead (never more than `COVER_CONCURRENCY` in flight, checked at
every step of a full drain, counter back to zero, queue fully drained). Two new properties that
no existing assertion could see: the queue ORDER (both orderings queue the same set, so only
order distinguishes them) and the re-entrancy guard (exercised through a new 'die' HTTP mode
that reproduces a launch failure, observed as the absence of a deep-recursion warning). One
assertion had gone VACUOUS the moment the runner became concurrent — it grepped `@coverQueue`
for the marker key, and a three-request pass is now launched in full before that line runs, so
the array was empty; it now warms past `COVER_CONCURRENCY` and asserts over every queued entry.
Anti-tested four ways: dropping the guard, dropping the counter decrement, reverting the
ordering, and (from 0.9.188) re-anchoring the ladder regex.

**0.9.188** — superseded by 0.9.189. Two user-visible changes,
both small and both measured on the live server first: **cover art is cached as JPEG instead
of re-encoded PNG**, and the **top-level menu is reordered** (All Releases directly under For
You; People You Follow last of the content sections). No schema change, no `BASE_VERSION`
bump. One cache family bump: **`lbf:imgwarm:` -> 2**, which is mandatory here — see below.

**0.9.188 — THE COVERS WERE BEING RE-ENCODED AS PNG, AND NOTHING SAID SO.**

The complaint was "artwork loading from cache can be slow". Measured on the live server, cold
covers deep in All Releases ran **1.4–2.2s each against 0.02s warm** — the cover warm caps at
`COVER_WARM_MAX` (150) per feed while the `all` feed holds ~3,000 in-window releases, so most
rows were simply never warmed. That cap is still there and is still the bigger problem (it is
on the structural list, not fixed here). What IS fixed is what each of those requests costs.

`XMLBrowser` runs every row image through `proxiedImage`, which takes the proxied path's
extension **from the source URL and defaults to `.png` when the URL has none**. CAA's
`/front-250` has none. So every LBF cover shipped as `/imageproxy/<esc>/image.png` and the
proxy re-encoded it as PNG. Same cover, same spec, varying ONLY the extension:

| spec | `.png` | `.jpg` |
|---|---|---|
| `_150x150_f` | 44,000 B | 7,994 B |
| `_300x300_f` | 160,972 B | 25,620 B |
| `_600x600_f` | 648,081 B | 101,100 B |

The 600px PNG was **larger than the full 1200px JPEG source it was scaled down from**
(394,707 B), and PNG-encoding a 600x600 photograph is far more CPU than JPEG — paid on the
event loop, per cover, on first sight. A 150-cover x 3-spec warm cached ~128 MB of PNG; it now
caches ~20 MB.

**WHY THE OTHER PLUGINS NEVER SHOWED THIS.** Their covers come from services whose URLs
already end in `.jpg` (Qobuz `_600.jpg`, Tidal `/640x640.jpg`), so they got JPEG by accident
of the source URL — verified live: a PFR row is `…/j9c95moy56n55_600.jpg/image.jpg`. CAA's
extensionless path was the only one falling through to the default. This is NOT a fleet-wide
defect to go porting; it is specific to a source URL with no extension.

**THREE THINGS HAD TO MOVE TOGETHER, and any one alone is a silent regression:**

- `API::coverArtUrl` names `/front-250.jpg` (CAA serves `front-<n>` and `front-<n>.jpg`
  identically — same bytes, `image/jpeg`; probed live, 14/14 real release covers and both
  release-group covers 200).
- **Plugin.pm's CAA size ladder was anchored `s|/front-\d+$|…|`**, so the moment the URL
  carried an extension it matched nothing and the ladder stopped firing — every spec then
  served from whatever size the row happened to name. Verified live before the fix: a
  `_600x600_f` came back off the 250px source instead of front-1200. It now captures the
  optional extension and puts it back, so an extensionless URL still behaves as before.
- `Browse::_warmCovers` warms the EXACT path the client will request, and its builder splices
  the spec before whatever extension it finds — so it follows automatically. But every marker
  written so far describes a `.png` path no client will ask for again. Without invalidating
  them the warm would skip the whole feed and leave every cover cold, which is the precise
  failure the warm exists to prevent. Hence the bump.

**`lbf:imgwarm:` IS NOW A REGISTERED KEY FAMILY** (`DB::KEY_VERSIONS`, version 2). It was
written as a bare literal, which meant it was invisible to `cachestats` (~950 of 1,570 kv rows
on the live server were unaccounted for), unreachable by `retirePrefixes`, and impossible to
invalidate short of the dev wipe. All three are fixed by declaring it.

Also folded in: the Trending row's artwork fallback built its own release-group CAA URL as a
literal, so it would have been the one row type left on PNG. It goes through `coverArtUrl` now
— one builder for the string, which is what stops this recurring.

**0.9.188 — TOP-LEVEL SECTION ORDER.** Now Created for You -> **All Releases** -> **People You
Follow** -> Settings. Only the first can be assembled synchronously: the All Releases weeks are
inlined from an async feed fetch, so everything below them has to be emitted inside `$finish`.
The People section moved in there for that reason alone — `@people` is still built
synchronously and captured by the closure, so a disabled or empty section is absent exactly as
before, and both fallback paths (the `TOPLEVEL_ALL_WAIT` watchdog and the fetch error) render
through the same `$finish`, so the order holds on a cold or failing feed too.

**TESTS.** `tools/t_coverwarm.pl` is 44 assertions (was 38) and gained the ladder's REWRITE,
which was never covered — section 1 checked which size the handler picks and stopped there,
but picking 1200 is worthless if the substitution that stamps it in doesn't fire, which is
exactly what broke. Two things it was paraphrasing are now extracted verbatim like every other
body in that suite: `coverArtUrl` (a hand-written copy returning `/front-250` sat there while
the shipped sub moved on, which would have kept the whole suite asserting `.png`) and the
marker's key version, read from the real `KEY_VERSIONS`. `LBF_API` / `LBF_DB_SRC` overrides
were added so the anti-test can reach them — without those a mutated `coverArtUrl` went on
passing against the pristine copy. Both mutants now fail behaviourally.

**ONE PRE-EXISTING TEST FAILURE FIXED IN PASSING, unrelated to either change.**
`t_review_fixes.pl` asserted `_bcMatchKey` "DID exist at HEAD" to prove its removal check was
comparing something real. The sub was removed in `cab9450` (0.9.186), so from that commit on
the premise could never hold and the suite failed permanently while the property it guards was
intact. It is now pinned to the last commit that contained the sub, resolved by content rather
than hardcoded. An anti-test that fails for a reason unrelated to the thing it protects
teaches the next reader to ignore it.

**0.9.187** — superseded by 0.9.188. Adds **Spotify as a fifth
streaming service, via the Spotty plugin** — PR #17 by **honzup**, hand-applied (`c68cbb1`,
honzup credited as `Co-Authored-By`). No schema change, no `BASE_VERSION` bump, and **no cache
bumps needed** — every stream/playlist/follow/trending layer already keys on `svcOrder`, so
registering a fifth adapter invalidates them by construction. First build to ship
`SingleFlight.pm`, which **no call site adopts yet** — it loads nowhere and changes nothing.

**0.9.187 — SPOTIFY, VIA SPOTTY. And why this adapter is not shaped like the other four.**

Spotty is an OLDER, INDEPENDENT codebase — not the Michael-Herger Qobuz/Tidal/Deezer family —
and three differences follow from that, all deliberate: `getAPIHandler` is a **CLASS** method
(`->`, not the function form LBF uses for Qobuz/Deezer), the renderers live in **`OPML.pm`**
rather than `Plugin.pm`, and search results arrive **already normalized**. Album nodes are the
Tidal/Deezer shape (coderef `url` + uri in `passthrough`), so `_rebuildStreamItems` reattaches
`\&OPML::album` on re-read exactly as it does for the others.

**TWO SPOTIFY-SPECIFIC TRAPS, both found in review and both now guarded:**

- **Signed-out Spotty reports a REAL no-match, not "inconclusive".** `->can('getAPIHandler')` is
  true the moment the plugin loads, regardless of accounts, but with **zero credentials on the
  server** `AccountHelper::getAccount` returns undef on EVERY call — permanently, not
  transiently (verified against Spotty master: `AccountHelper.pm:40-65` takes its `else` branch,
  sets `$id = undef`, returns undef). Reporting that as `undef` would make `$inconclusive++`
  fire, pinning every genuine miss to `STREAM_INCONCLUSIVE_TTL` (1h) instead of
  `STREAM_NOMATCH_TTL` (24h) **for ever** — 24x the re-search load on the other four. Both
  `_searchSpotify` and `_searchSpotifyTrack` therefore gate on `AccountHelper->hasCredentials()`
  and hand back `[]`. **This is new to Spotify** — the other three plugins' handlers are
  server-wide, so "no handler" there really is transient. The guard lives at the SEARCH SITE, not
  in `_streamingAdapters`: that sub is memoed for only `ADAPTER_MEMO_TTL` (5s), and
  `getAllCredentials` re-scans the cache folders on every call while the result is empty — i.e.
  exactly in the signed-out case.

- **Spotify has NO EP CLASS — EPs come back as `album_type: "single"`.** Adding the field to
  `_candReleaseType`'s trusted list would therefore mis-drop a Spotify EP for an album or
  compilation target (`$dropSingles` only falls back to the full set when NOTHING survives). The
  single verdict is guarded on the count instead: `total_tracks <= 3`. A 4+-track EP falls
  through to `''`; a real 1-3 track single still classifies. Keeping the field beats dropping it —
  it catches the 0.9.89 case (a like-named 3+-track single) that a count alone cannot.

**A CORRECTION TO A RULE STATED ELSEWHERE IN THIS FILE, worth carrying:** `total_tracks` here is
**NOT** inert the way the removed `&tc=` param was. The `_attachFavUrl` note says count fields are
album-ENDPOINT-only and absent from search responses — true for Qobuz/Tidal/Deezer, and **false
for Spotify**, whose search payload genuinely carries `total_tracks` and whose `normalize()` keeps
it. Spotify is **the one service whose SEARCH result feeds the count chain**. Both comment sites
now say so; don't "clean up" that field as dead code.

**Spotty's own `favorites_url` is PRESERVED** — Spotify returns early from `_attachFavUrl`, the
only service that does. Spotty's `album()` extracts the id with a greedy `/album:(.*)/`, so the
decorated `<svc>://album:<id>?cover=…` scheme would capture the query string INTO the id and break
a natively-saved favourite on replay. Nothing is lost: the decorator exists because Qobuz/Tidal/
Deezer leaked a BROKEN coderef favurl, and Listen Later has no spotify source support anyway.

**NOT VERIFIED LIVE. Spotty is not installed on the test server**, so every claim above is
source-verified only — read from real Spotty v4.62.2 source, never observed running. Full review
findings and the merge plan: `docs/spotify-spotty-adapter-pr17.md`. **Owed at the main merge: a
CHANGELOG credit line for honzup** (the PR's own CHANGELOG hunk was deliberately not taken, per
the dev-branch rule).

**ADDING A SERVICE — READ `docs/streaming-adapter-spec.md` FIRST.** Written from this adapter,
it is the fleet-wide contract: what the service's own plugin must expose (R1-R8), the `run` /
`runTrack` semantics (including `undef` = inconclusive vs `[]` = real miss, and the TTLs each
picks), the item fields to stamp, and the acceptance tests. It also lists every site that still
forces an edit OUTSIDE `_streamingAdapters` — the `_rebuildStreamItems` chain, the `_attachFavUrl`
Spotify exemption, the Bandcamp auto-search opt-out and the four hand-maintained service lists —
with the registry field that closes each — registry work, not adapter work.

**THIS REPO HOLDS THE CANONICAL COPY, and the spec is carried VERBATIM in PFR and LL — so an
edit here is only half the job.** Commit 41768bf edited it without re-copying, and the three
repos sat drifted until it was noticed from the LL side on 2026-09-03, in a review round that
was not looking for it. There is no check that catches this; `shasum -a1 */docs/streaming-
adapter-spec.md` across the three repos is the whole test, and it belongs in the same session
as the edit. The file is a STRAIGHT copy with no per-repo sections — section 9's per-plugin
table covers all three plugins in every copy — so the three shasums must match exactly, and
any difference is drift rather than a local customisation. What legitimately differs is each
repo's own CLAUDE.md paragraph pointing AT the spec, which names that plugin's out-of-adapter
sites (LL's ten, PFR's two); keep those in step with section 9 by hand.

**0.9.186** — superseded by 0.9.187. **The seven findings of the 0.9.184 code review,
all fixed** (`docs/code-review-0.9.184.md` — every one carries its mechanism, its guard
and its anti-test), plus **the removal of the detail page's two remaining Last.fm calls**.
No schema change and no `BASE_VERSION` bump; `DEV_BUILD` clears the derived store on first
start as always.

**0.9.186 — THE DETAIL PAGE'S LAST.FM CALLS BOTH GO.** `API::getArtistBio` is deleted,
along with the `lbf:bio:` key family and the `_setText`/`_getText` pair that existed for
it; the page's own `getLastfmTags` call is deleted with `$wantLastfm`.

- **The bio.** It was the fallback for users without MAI, and the call was that it is not
  worth having: **MAI's own bio sources include Last.fm**, so this was a second route to a
  well MAI had already drawn from, and it bought a bio for a population that has never been
  offered an artist **photo** either (MAI-only since the Artist section was written). No MAI
  now means no bio, and the section falls back to the artist name + Block-artist row.
  `$wantArtist` is gated on the new `Browse::_maiEnabled()`, so the task is **absent** from
  the render barrier rather than being a slot that resolves to an empty hash.
- **The genre tags.** 0.9.185 kept this call on the grounds that Last.fm is the one
  genuinely *independent* source — but that is an argument about the **ladder**, not about
  this page. **Last.fm IS the ladder's tier 5** (`_genresFor`: artist tags, then
  `_lastfmGenres`), so the store peek immediately above it has already asked. A second, live
  `album.gettoptags` here could only repeat the rung that just answered or re-ask the one
  that just came up empty — while blocking the render barrier behind up to two chained HTTP
  calls, and rendering tags **ungated by `_genreKnown`** that the lists would have refused
  ("japanese", "Dreamy", "zzz").
- **What STAYS, and don't take it with them next time.** `API::getLastfmTags` stays —
  `_warmLastfm` is the ladder's tier-5 filler and is what puts Last.fm's answer in the store
  in the first place; what went is *this page's own* call to it. `_cleanBio` and `BIO_MAX`
  stay — the MAI path runs its bio through them (`Browse::_fetchArtistInfo`), which is also
  why `_cleanBio`'s HTML handling is tuned for MAI's runtime output rather than Last.fm's
  ([[mai-bio-is-html-at-runtime]]).
- **The "caching FREE TEXT" rule in `API.pm` stays too, with its helpers gone.** Nothing in
  that file writes a bare string to the cache any more (the other `_setText` caller, the
  MusicBrainz sort-name, moved to `DB::artistPut` when the store landed). The comment is kept
  because it is about **the next one**: never `$cache->set($key, $some_string)` with text
  that came from an API — wrap it in a hashref, or put it in the store.
- **`PLUGIN_LBF_LASTFM_KEY_HINT` was corrected**, because it described the key by the role
  that just went: *"fill in genres on the release detail page"*. The key's genre role is the
  **ladder's tier 5**, which fills the LISTS as much as the detail page, and it also feeds the
  DSTM radio's similar-artist fallback. A settings hint naming a removed feature is how the
  next person re-adds it.
- **Guarded by `t_genrefill.pl` §6b/§6c (21 assertions)**, written to the shape §6 already
  used for the 0.9.185 removal — assert the calls are gone, and assert what must SURVIVE.
  **That second half is the point**: §6b pins `API::getLastfmTags`/`peekLastfmTags` as still
  present and still called from `_warmLastfm`, because deleting the tier while deleting the
  duplicate call is a far worse bug than the one being fixed — it would silently empty the
  ladder's last rung. §6c pins `_cleanBio` surviving, the `_maiEnabled` gate, and that the
  bio branch **takes one barrier slot and releases it on BOTH exits** (callback and
  eval-threw) — the hang a careless deletion produces, the same one §6 guards for genres.
  **Anti-tested four ways:** restoring the 0.9.185 call = 3 red; renaming `sub getLastfmTags`
  out of `API.pm` = 1 red; dropping the `_maiEnabled` gate = 1 red; dropping the eval-threw
  `$pending--` = 2 red. Nothing else moved in any of the four runs.

**0.9.186 — THE 0.9.184 REVIEW FIXES.** In the review's order:

1. **`_cleanBio`'s link-only `<li>` rule ate whole list items — and everything between
   them.** `.*?` is lazy, but laziness only sets the *order* the engine tries lengths in; on
   an item that is a link **plus** text (`<li><a>Album One</a> (1994)</li>`) the first `</a>`
   is not followed by `</li>`, so it backtracked, crossed `</li><li>` under `/s`, and matched
   a **later** item's `</a>` — deleting every item in between. A Wikipedia-derived discography
   list collapsed to an empty `<ul>`. Now `[^<]*`, which cannot reach a tag boundary and
   describes a link-only item exactly. A *pattern* fix, not a parser
   ([[lbf-keep-bio-rendering-simple]], [[lbf-bio-parser-end-of-life]]).
2. **`warmCache` returned before `_warmGenres`, so account-less users never got All Releases
   genres.** `_warmGenres()` sat *below* the username gate while its own no-username branch
   warmed All Releases for everyone — dead code. It is now hoisted **above** the gate (nothing
   in the genre path reads `$client`, so running ahead of the `$client ||=` line is safe).
   This was the genre half of exactly the bug `_warmTick`'s comment describes about feeds: All
   Releases was fetched and stored by `warmFeeds` — which runs ahead for that very reason —
   but its genres were never pre-warmed, so the view opened bare and could only fill from the
   `_kickGenreFill` top-up, a page at a time, 120s apart.
3. **A die in the first caller's `onDone` parked every later cold open of that feed for
   ever.** `%INFLIGHT` is released **only** inside `$fanout`, which runs *after* the first
   caller's own callback — and the waiters were eval'd while the first caller was not. An
   XMLBrowser render callback that dies therefore left `$ikey` claimed holding an empty
   arrayref, and every later cold open parked onto a list nothing would ever drain and
   returned **without rendering**, for the life of the process. **There were TWO such
   callbacks, not one:** `$done`'s, and `$failed`'s **stored-copy branch**, which calls
   `$p{onDone}->(_memoSet(...))` ahead of `$fanout` in the same shape. (The error branch below
   it genuinely is safe — `_handleError` runs no user code before `$fanout`.) Both are now
   eval'd with a logged error, and **`%INFLIGHT_TIMER`** is armed at claim time for
   `INFLIGHT_MAX` (3 × `FEED_TIMEOUT`), killed by `$fanout` on every normal exit. It
   **answers** the parked waiters with an error rather than merely dropping the key — a waiter
   freed without a callback is still a browse that never renders. Same shape and same
   reasoning as Browse's `BUILDING_MAX`.
4. **`_withGenresLB` never called back for a list with no release-group MBIDs.** `$starts` is
   0 for an empty `@batches`, so `$step` never ran and `$cb` was never called **at all** — the
   chain just stopped. The all-empty case is guarded upstream; the reachable hole was the
   **mixed** one the ladder deliberately introduced (`@rels` empty, `@artOnly` non-empty — the
   Trending shape the `@artOnly` budget exists for). Every *render* caller passes `peek => 1`
   and the peek branch always calls back, so no browse view could hang on it: the damage was
   the **warm**, where a For You pass that filtered down to artist-only rows left
   `genres_foryou` `running` for ever and **All Releases was never warmed for that tick**.
   Fixed with the guard `_withGenresMirror` has always had.
5. **`warmstats`' skip list named a stage that does not exist.** `genres_lastfm` is recorded
   nowhere — the real stages are `genres_lastfm_all` / `genres_lastfm_foryou` — and because
   `stageEnd` creates a row for any name handed to it, the report showed a phantom line and no
   line for either real stage. It fell out with finding 2: the genre names came off that list
   entirely, since `_warmGenres` now records its own outcomes and re-ending a live stage with
   a wrong outcome would be worse than the missing warm.
6. **⚠️ MIRROR MODE COULD NOT SEE THE RELEASE-GROUP TIERS AT ALL — and this one is
   VISIBLE.** `_genresFor` tiers 1 and 1b read the `release_group` row, but `detail_genres`
   and `genres` reach `$meta` only via `DB::rgGet` — i.e. only on the **ListenBrainz** path.
   Mirror mode builds `$meta` entirely from artist rows through `_metaFromArtists`, which
   hard-codes `genres => []` and never touches the release-group row, so **both** record-level
   tiers were unreachable and the list showed an artist proxy instead. New
   **`Browse::_mergeRgGenres`**, called from **all three** of `_withGenresMirror`'s exits (the
   peek branch, the `getArtistGenres` callback, and the `unless (@artists)` branch — that
   third one was returning `{}`, and the artist rungs having nothing to look up says nothing
   about whether the record has an answer). It reads through
   `API::peekReleaseGroupMetadataBulk` rather than `DB::rgGet` directly so the two paths
   cannot drift on key-casing or row shape, and it is **one bulk read per page, never one per
   row** — that is the ~2,900 synchronous SELECTs `bench_walk` caught in 0.9.165. It
   **creates** a `$meta` entry as well as filling one, seeding `genres`/`agenres` empty so the
   tier walk still falls *through* to the artist rungs below.
   **Tier 1 was included on evidence, not by symmetry:** `getReleaseGroupMetadata` is called
   by the Trending Tracks date fill and the Trending Albums release-group pass **regardless of
   genre mode**, and that request carries `inc=release_group tag` — so a mirror box's store
   *does* hold album-level genres, written where the genre ladder itself never touches them.
   A mirror user who had browsed Trending had answers in the store the list refused to read.
   **`agenres` is deliberately NOT merged** — the artist tiers have their own reader and
   `_metaFromArtists` has already filled them from the mirror's own artist rows. **Note this
   is the DEFAULT path on any server with a local MB mirror**, so an existing mirror user will
   see rows flip from the artist's genre to the album's own. That is the ladder behaving as
   specified: an answer about the *record* outranks a proxy for it.
7. **A failed dev-build wipe was recorded as done and never retried.**
   `$prefs->set('last_build', $version)` sat **outside** the eval, and that pref is what makes
   `_buildChanged` return early next start — so a wipe that died half way (say `wipeDerived`
   hit a locked DB during startup) left a partly-wiped store marked handled and never ran
   again for that version. The one path by which a dev build could silently **not** clear its
   caches ([[dev-builds-clear-caches]]). Moved inside the eval, beside `last_genre_fact`,
   which has always been correct for the same reason: the pref means "the version the store
   was last cleared FOR", not "the version that happened to be running". A permanent failure
   now retries once per start and logs each time — a symptom you can act on, where a half-wiped
   store marked complete is exactly the state the rule exists to prevent. The retry is
   idempotent (`DELETE FROM kv`).

**THE TEST-SUITE LESSON FROM THIS ROUND, and it is a general one.**
`t_feedsingleflight.pl`'s `Slim::Utils::Timers` stub was a generic no-op AUTOLOAD, so a
**timer-based guard could be deleted with the suite still fully green**. It now records
timers and the tests fire them deliberately. Two more of the same class: `t_warmstats.pl` §5
walked a list of expected stages asking "is each one marked?", which cannot see a mark for a
stage that does not exist — it now derives both sets from the source and asserts each way
(a name ended but never started, and a name started but never ended); and `t_genrefill.pl`
§14 had pinned a guard's exact *source line* and went red on a correct change, so it now
pins the property. **Two assertions in this round are documentation, not coverage, and are
recorded as such in the review file** (finding 4's `return`, and finding 6's "an empty
tier-1 column does not erase the tier-1b answer") — both pin contracts whose damage is not
reachable on today's call paths. Every fix was anti-tested by reverting it and counting the
reds; the counts are in `docs/code-review-0.9.184.md`.

**MERGE-GATE ITEMS carried forward** (not done, deliberately —
[[changelog-only-on-main-merge]]): `CHANGELOG.md` and `README.md` still describe *Days
window*, *MuSpy upcoming — how far ahead*, and the Last.fm key as a bio/genre fallback.
All need rewriting at merge to main.

**0.9.185** — superseded by 0.9.186. **The release window is WHOLE MONDAY-TO-SUNDAY
WEEKS.** See `docs/week-based-release-window.md` (design + an "As built" section recording
where the implementation diverged from it), and the full pref/behaviour writeup under
**General Settings** below. Also carries the MusicBrainz 503 backoff on the artist-sort
warm, and **the removal of both on-demand genre fetches from the album detail page**.

**0.9.185 — THE DETAIL PAGE STOPS RE-ASKING FOR GENRES.** Both fallbacks behind its store
peek are deleted: hosted `getAlbumGenresHosted` and the `getReleaseGroupGenres` call behind
it, plus `_hostedGenreNames`, the `HGENRES_*` constants, the `$fileDetail` closure, and the
`lbf:hgenres:`/`lbf:rggenres:` entries in `KEY_VERSIONS`.

**Why, and it is not a coverage judgement — the calls were structurally redundant.** The
page's genre step already peeked the store having walked the WHOLE ladder, so both only
ever ran on the residue where every tier had come up empty. The one population the hosted
route was kept for in 0.9.173 — established albums on Trending Albums — turns out to be
covered before the row is even drawn, because that build stores genres itself (its
rg-metadata pass carries `inc=release_group tag`). And every source involved is
MusicBrainz-derived, so they fail together. **Measured 2026-08-22: hosted 0 of 40 albums
off the live fresh-releases feed; the MB tier 0 of 14 on the same residue.** Two blocking
requests per album open, on the render path, to re-ask a well that had just come up dry.

**What did NOT change** (as of 0.9.185 — **the Last.fm tags and the bio went in 0.9.186**,
see above): the tracklist (MusicBrainz `release?inc=recordings`), streaming resolution,
Last.fm tags and the artist photo/bio all still ran — 0.9.185 removed genre fetching only. `release_group.detail_genres` is now write-once history: **still read as
ladder tier 1b**, never written again. Guarded by `t_genrefill.pl` §6, rewritten from
driving the removed sub to asserting its absence — including that the render barrier is
still decremented exactly once, which is the hang a careless deletion produces.

**0.9.185 — WHOLE WEEKS, NOT A ROLLING DAY COUNT.** The window was `days` (1-90, default
14) measured from today, and it **cut the current week in half**: the UI renders `W/C
<Monday>` rows, but the window's edges landed on arbitrary days, so with *Include earlier
weeks* off the current week held only *today onwards* and **Friday's releases — the week's
main drop — were gone by Saturday**. Turning the past side on was the only workaround, and
it dragged in a ragged 14 days rather than whole weeks. Now `weeks_past` (0-3, default 1) +
**the current week always in full** + `weeks_future` (0-3, default 2), clamped to a
four-week budget.

**IT IS CHEAP BECAUSE OF THE 0.9.166 STORE.** Releases are stored permanently and the
window is only a filter on the READ, so narrowing costs nothing and invalidates nothing.
**NO `BASE_VERSION` BUMP** — that would lose every older row for good, because ListenBrainz
only re-serves releases inside the window it is asked for.

**`API::sectionWeeks($prefix)` IS THE ONLY PLACE THE WEEK PREFS ARE READ.** It replaced ~12
duplicated `$prefs->get('days') // 14` + past/future sites that **disagreed** —
`foryou_future` fell back to `// 0` in four of them and `// 1` in `warmFeeds`, so a warm and
a browse asked ListenBrainz two different questions and stored two different windows. The
four per-section checkboxes survive as pure ON/OFF **gates** (unticked = zero weeks on that
side, that section only).

**THE `Settings.pm` TRAP, and it is the one to remember.** `exists $params->{pref_days}` was
the sentinel that says "this is a real form POST", and it is what makes the checkbox
coercion run at all. It moved to `pref_weeks_past`. Deleting the field without moving the
sentinel breaks **every** checkbox on the page at once, silently: unchecked boxes store
`undef`, which reads back ON through the `// 1` guards, so `all_past`/`foryou_past` become
impossible to turn off.

**TWO DELIBERATE DIVERGENCES FROM THE DESIGN NOTE**, both recorded in its "As built"
section: the memo key got ONE builder (`_feedMemoKey`) rather than two `join`s that had to
stay byte-identical by hand — *that*, not the pref reads, is the actual 0.9.141 Refresh bug;
and the over-budget clamp rule (unspecified in the doc) honours the PAST side first, future
takes the remainder.

**THE VERIFICATION LESSON.** The doc's gates were `perl -c` + a called-vs-defined sweep. Both
ran clean and **both are blind to what actually broke, which was two existing test suites**:
`t_feedsingleflight.pl` varied `days` purely to get distinct memo keys (`%INFLIGHT` is a
file-lexical it cannot reset), so with `days` inert every section collapsed onto one key and
section 2 parked behind section 1's deliberately-outstanding fetch; `t_review_fixes.pl`
spelled its expected feed key out as a literal `join`. Neither is a papering-over — the key
shape genuinely changed — but **a plan listing static gates should list "run the suites that
lift these subs" next to them.**

**MERGE-GATE ITEMS (not done, deliberately):** `CHANGELOG.md` and `README.md` still describe
*Days window* and *MuSpy upcoming — how far ahead*; both need rewriting at merge to main,
per the repo convention.

**0.9.184** — single-flight on the cold feed path; superseded.
See `docs/warm-ordering-and-follower-latency.md` §8.11.

**THE FEEDS DO NOT GET THE BUILDING ROW, deliberately.** They are already
stale-while-revalidate (any populated store renders instantly, however old), a fetch
failure degrades to the stored copy, and the only unready case is a completely empty
store bounded by `FEED_TIMEOUT` (10s). At ≤10s once ever, a building row plus a
"Check again" tap is WORSE than letting it load — the same threshold argument that
justified rendering immediately at 52.8s, pointing the other way.

**0.9.184 — SINGLE-FLIGHT ON THE COLD FEED PATH.** `%REVALIDATING` guards
`if ($bg)`, and `$bg` is `!$p{onDone}`, so an OPEN-path fetch took no flag: on a COLD
store the three-plus XMLBrowser walks one tap produces each fired their own
ListenBrainz request. `%FEED_MEMO` cannot help — it caches COMPLETED results. Now
`%INFLIGHT` parks the rest behind the first. **Both outcomes fan out** (parking and
then answering only the first would turn a duplicate fetch into a hung browse), each
waiter inside its own eval, and `onError` waiters get the same STRING `_handleError`
hands the primary — not the response object.

**The key is the REQUEST, not the feed:** memo key PLUS headers. Without the headers a
token holder arriving second is parked behind an anonymous fetch and their token is
never sent, making the request LBF issues depend on which walk arrived first.

**`t_tokenfree.pl` broke on this landing and that was CORRECT** — its harness never
answered a request, so its later calls were legitimately parked behind its earlier
ones. It now drains each request after recording it, and snapshots `errors`/`done`
BEFORE draining. **The repair then hid the header property** (deleting headers from
the key went 0 red), so it is asserted in `t_feedsingleflight.pl` §6 instead —
3 red. *A test that stops failing after a harness fix has stopped testing something.*

**0.9.183** — Check again + building row on all four resolve views; superseded. Adds the "Check again" row and puts the
building row on EVERY unready view. See `docs/warm-ordering-and-follower-latency.md`
§8.10.

**THERE IS NO SERVER PUSH FOR A BROWSE PAGE — do not look for one.** A plugin cannot
refresh a page the user is on; `needsRefresh` is client-side only. The building row
CANNOT turn itself into the real list. What Material honours is `nextWindow` on a row,
and **only when that row's response is EMPTY** (browse-functions.js:834) — which is
why `_checkAgainItem` returns `{ items => [] }` and does nothing else. Verified on the
live server: the existing Refresh / Sorted-by rows emit `nextWindow: "refresh"` and
are the same mechanism.

Applied to all four unready views: `_resolveTrending`, `_buildAlbumsData`,
`resolvePlaylist` (~12s cold) and `_resolveFollow`.

**`_resolveFollow` releases via its own closure, NOT by wrapping `$callback` —
deliberate, and asserted.** It is also on the warm path, where `$callback` is undef
and the terminal reads `if $callback` to decide whether to build result rows at all;
wrapping would make that always true and render rows the warm never uses.

**`BUILDING_MAX` (180s) now expires any flag whose release path never runs.** A leaked
flag is worse than no guard — in-process registry, no TTL, view stuck for ever.
**Since 1.0.5 the flag is a TOKEN** (`_buildingStart` returns it, every caller keeps it in `$owns`
and releases with `_buildingEnd($bkey, $owns)`): the expiry and a late release can both hit one
key, and an unconditional delete let a pass that outlived its flag free the NEXT pass's flag.

**0.9.182** — field-verified building row; superseded. The building row appears
immediately on a cold open, repeat opens start no second build, and the real list
renders when the build completes. Log evidence and the current cost breakdown are in
`docs/warm-ordering-and-follower-latency.md` §8.9.

**0.9.182 — instrumentation, and the lesson behind it.** 0.9.181's fix was correct but
UNPROVABLE: it logged the TRACKS cold start and not the ALBUMS one, so when the album
view span its dots there was no line saying whether the render hook had fired. **The
only misbehaving path was the only uninstrumented one.** When two paths implement the
same behaviour, instrument BOTH or neither.

**THE COST HAS MOVED — attack the STREAMING GATE next, nothing else.** Measured
2026-08-22: `this_year` 41.1s total of which the gate is 32.4s; `this_month` 50.1s of
which the gate is 27.7s. The ListenBrainz fan-out is now 3.7–6.0s and MusicBrainz is
largely out of the path. The 429 storm, the serial MB searches and the ingest stall are
ALL resolved — do not re-investigate them.

**0.9.181** — the first-opener fix, superseded by 0.9.182.

**0.9.181 — 0.9.180's building row NEVER APPEARED, and the reason is worth keeping.**
The guard was written for the SECOND caller only: on a cold open `_isBuilding` is
false, so the FIRST opener took the flag and then held `$callback` for the whole
~50s build — the exact Material spinner the building state exists to replace, in the
commonest case of all. Reported from the field ("do not get still being built message
just materials loading for too long") against a correctly-installed 0.9.180.

Fixed by rendering the row the moment a COLD build starts and **clearing `$callback`**,
which detaches the render from the build: the fan-out is async and carries on into the
cache (every later render path is already `if $callback`, so nothing fires twice), and
the next open is instant. `_buildAlbumsData` gained an `$onPending` hook for the same
reason, since it is data-only and its view renders in the caller; `resolveTrendingAlbums`
renders at most once. **The warm passes neither** — it wants completions, not placeholders.

**THE TEST LESSON.** `t_buildingstate.pl` was fully green against this. Its 34
assertions checked the guard's BOOKKEEPING — flag taken, flag released, ownership
respected — and never asked what the user sees on a cold open. Section 7 now does,
and reverting to the 0.9.180 code turns it red. *A guard's bookkeeping being correct
is not evidence that the thing it guards behaves correctly.*

**0.9.180** — built, superseded by 0.9.181. Carries 0.9.178's ingest fix, 0.9.179's
hosted `/discography` resolver, and **stage 2 of the warm-ordering work**.

**0.9.180 — ORDERED WARM CHAIN, THE BUILDING STATE, AND AN IN-FLIGHT GUARD.**
Built only once §6 of `docs/warm-ordering-and-follower-latency.md` had the numbers;
full write-up in §8 of that doc.

- **Ordered feed chain.** `warmFeeds` chains For You → All Releases → MuSpy and
  calls back when the last lands; `_warmTick` starts `warmCache` from that callback
  instead of firing both in one turn. **Changes nothing on a warm store** (all three
  measured at <0.01s, served from the store) — it is for a COLD store, which every
  dev build and every new user has. Ordering creates a failure concurrency could
  not: one hung feed strands the rest. So EVERY `onError` advances the chain, and
  `WARM_FEED_CHAIN_MAX` (120s) bounds the whole thing.
- **`PLUGIN_LBF_BUILDING`, rendered IMMEDIATELY, not behind a watchdog.** A cold
  follower open measured **52.8s**, so a watchdog would expire on essentially every
  one. It is DISTINCT from `PLUGIN_LBF_NO_TRENDING` (an affirmative "nobody you
  follow has listened") — conflating them is what made a cold open read as broken.
  `_buildAlbumsData` signals the difference with **undef**, never `[]`.
- **In-flight guard** (`%BUILDING`). Not a cache and not in `kv` — it answers "is
  someone building this RIGHT NOW", true only within one process; a stale flag from
  disk would show the building row for ever. **The flag is released by WRAPPING
  `$onDone` once**, not at each of `_buildAlbumsData`'s 8 exits, and every release is
  `if $owns` so a caller that merely FOUND the flag cannot clear someone else's.

**DELIBERATELY NOT BUILT: the genre and cover demotions**, both proposed this session
and both dropped. `warmCache`'s own comment records genres-first as a measured
reversal ("the ladder did not start until many minutes into the tick, so every view
opened bare") and ends *"do not chain them back onto the end"*; demoting the Last.fm
rung would reintroduce that and contradicts the ladder spec, where a bare view is a
BUG. Covers are what make artwork appear, and cold-start artwork was one of the
original complaints. Do not re-propose either without a new measurement.

- **The MusicBrainz 503 backoff — the third network path finally gets one.** LB had
  `_lbWait` and the hosted API had `_hostedNoteLimit`; `warmArtistSorts` logged a rate
  limit at info level and moved straight to the next artist. **MB throttles with 503,
  not the 429 the other two use**, so a backoff copied from the hosted side would never
  have fired. Now `_mbWait`/`_mbIsRateLimited`/`_mbNoteLimit`/`_mbNoteOk`: shared
  deadline, 5s→30s, reset on success, outward-only. A limit **ends the pass** and hands
  the whole `%sortInFlight` reservation back — miss that release and the queued MBIDs
  stay in flight for the life of the process, which the guard then reads as "MB has no
  sort-name for these", for ever. **The courtesy gap is not a rate limiter:** measured
  2026-08-22, two 503s in eight requests paced at 1.2s — *wider* than the 1.1s this code
  applies. This is the same conclusion §7 reached from the other direction: sort-names
  stay on MB, so the honest fix was to make that path well-behaved rather than to move
  it. Guarded by `t_genrefill.pl` §13 (14 assertions, 4 source checks anti-tested red).

Guarded by `tools/t_buildingstate.pl` (34 assertions, five anti-tests).

**0.9.179 — THE RELEASE-GROUP RESOLVER MOVES TO THE HOSTED API.**
`getReleaseGroupByName` now tries `/artist/<name>/discography` before MusicBrainz:
one call per ARTIST, folded title → answer, instead of one MB search per ALBUM.
Measured cause — a cold People You Follow open spent **22,880ms in 12 serial
MusicBrainz searches**, because `mb_base_url` is unset on the live server so they
went to public musicbrainz.org at ~1 req/s (one came back 503). Hosted answers in
195–358ms cold / ~80ms warm. **The deciding argument is other users, not this
machine**: LBF ships to people with no mirror, whose default is that same 1 req/s.

**DO NOT "simplify" this to `/album/<title>/<artist>` — that route returns a
RELEASE mbid, not a release-group one**, and it would poison the dedupe key, the
CAA `release-group/<id>` art URL, the LB genre lookups and the detail page while
looking like it worked. `/discography` returns release-GROUP ids, verified
identical to MusicBrainz's own. The limitation is per-ROUTE, not API-wide.

The MB fallback is UNCONDITIONAL — unknown artist, title absent, rate-limited past
the budget, service down all reach the old path unchanged. **It buys speed, not
coverage**: the four names public MB missed, the hosted API misses too. `?mbid=` is
passed when the candidate has one and is part of BOTH cache keys — `artist|title`
alone let two same-named artists sharing an album title collide, defeating the
disambiguation one layer below where it was made. New family `lbf:hdisco:` (7d);
`lbf:rgbyname:` keeps its shape so readers cannot tell which tier answered.
Matching reuses `Browse::_norm` at runtime but adds nothing to the shared matcher,
so the four-repo sync rule is NOT triggered. Guarded by `tools/t_rgresolver.pl`
(37 assertions, five anti-tests). See `docs/hosted-lms-community-api.md` §6.

**AND §7 SETTLES THE REST: the remaining MusicBrainz features STAY on MusicBrainz.**
**No mirror is assumed anywhere** — Simon's `mb_base_url` was for development only and
is not going forward, so judge every MB cost against the PUBLIC API at ~1 req/s.
`warmArtistSorts` (sort names) and `getReleaseDetails` (detail-page tracklist) have
**no alternative** — probed live: ListenBrainz has no `sort_name` and no
release-keyed tracklist route, the hosted API has neither field, and **ListenBrainz's
own website fetches release tracklists from MusicBrainz**. `getArtistGenres` is
already inert without a mirror. Do not re-propose migrating these; read §7 first.

**0.9.178** — 0.9.177 was verified on the live server:
`Fetching following` fired ONCE (was three times), zero HTTP 429s, and `warmstats`
showed the follower builds staggered — `trending_month` 48.63→104.63, `trending_year`
starting at 104.63. The burst fix works. `dev` is committed at 0.9.161; everything
from 0.9.162 on lives only in the working tree, deliberately (that diff is Simon's
code-review artifact — do NOT prompt to commit).

0.9.175/0.9.176 carry the two "fixes on top of 0.9.174" below (the genre wipe's
release gate and the cover pre-warm), **stage 1 of the warm-ordering work** (the
warm-stage instrument and `["lbf","warmstats"]` — instrumentation only), and
**the fix for the event-loop stall that was dropping players** (0.9.176).

**THE STALL IS THE ONE TO KNOW ABOUT.** `DB::ingestFeed` was issuing ~16,000
statements in ONE transaction inside an async HTTP callback — ~1.85s on a Pi,
every daily revalidation. Before the caching rework a feed was stored by TWO
`$cache->set` calls; the store replaced that with a per-release upsert loop, so
**two statements became sixteen thousand**. That is the whole of "none of this was
an issue before we switched cache model". It dropped players AND stalled lazily
loaded artwork, because LMS serves the image proxy from the same loop. Now chunked
(`INGEST_CHUNK`, 150, set from measurement) with rotation and coverage running only
on a COMPLETE pass. Longest block 1728ms -> 102ms on a Pi. Read
`docs/warm-ordering-and-follower-latency.md` §4 before touching `ingestFeed`, and
`tools/bench_store.pl` is what re-measures it.

**0.9.177 — THE FOLLOWER STATS BURST.** Found by running 0.9.176's own instrument
against the live server: `warmstats` showed the three People-You-Follow builds
starting within 50ms of each other, `getFollowing` fetched THREE times 25ms apart
(none had cached before the next asked), and **39 of 39 stats requests came back
429 TOO MANY REQUESTS in a 0.88-second burst** — the section rendered empty
("mapped 0 recordings", "aggregate 0 album(s)"). Arithmetic, not luck: 3 builds ×
`FOLLOWER_FANOUT` (10) = 30 concurrent requests, which is ListenBrainz's whole
~30-per-10s budget. Two causes, two fixes, either alone insufficient:
`API::_getUserStats` now uses the SHARED `_lbWait`/`_lbNoteLimit` backoff built in
0.9.165 (it had been wired to `getReleaseGroupMetadata` and nothing else, and
answered a 429 with `[]` — laundering a rate limit into "this follower has no
listens"), and `_warmTrending` chains the three builds instead of racing them.
`_resolveTrending` gained a completion hook that fires at ALL FOUR terminal points,
including the empty one — a chain advancing only on success would stall the section
on its commonest outcome. Guarded by `tools/t_statsratelimit.pl`.

**0.9.178 — THE CHUNKED INGEST NEVER RAN. A regression introduced by 0.9.176's own
fix, live for two builds, found on the server 2026-08-22.** `Slim::Utils::Timers::setTimer($obj, $when, $cb, @args)`
invokes `$cb->($obj, @args)` — **the first argument is handed back, not consumed**.
The chunk driver read its self-reference as `my ($self) = @_`, i.e. from the `$obj`
slot. Turn one runs inline (`$step->($step)`) and works under either signature; turn
two arrives through the timer with `$self` undef, schedules `undef` as the next
callback, and LMS dies inside its own timer loop — **outside any plugin eval, so
nothing is logged and the chain simply stops**. Field signature: rows partially
written, `feed_day` coverage never stamped (`0/15 days`), `ok_at` never set, no
`store: ingested` line, and the feed reads `(revalidating)` on EVERY open for ever —
the feed store doing no work at all. Fixed to `my (undef, $self) = @_` /
`$step->(undef, $step)`, matching the three steppers in `Browse.pm` (which document
the convention at the genre-batch pump).

**The test stub was the actual defect.** `tools/t_ingestchunk.pl` called
`$cb->(@args)`, dropping `$obj`, so 33 assertions stayed green against a driver that
could never work. The stub now replicates LMS's convention, and `step1` counts a
non-coderef callback (`$BROKEN_CHAIN`) instead of dying, so a recurrence reports a
red line rather than aborting at exit 255 with no FAIL — which reads like a pass.
Against the pre-fix driver the suite now goes 16 red, reproducing the field symptom
exactly: 14 of 60 members stored, 0 day-coverage rows, `ok_at` undef. **Any test
stub for a host API must replicate that host's calling convention or it cannot catch
this class of bug.**

No cache shape changed and no cache prefix was bumped by any of this.

**CHANGELOG.md is a MERGE-TO-MAIN artifact.** Do not add an entry for a dev build;
update THIS file, `docs/*.md` and memory instead, and write the changelog once at
merge, folding superseded dev versions together. Same for `README.md`/`README.html`.

**AT MERGE-TO-MAIN, TWO LINES ARE RECONCILED, NOT ONE.** The long-standing one is
`repo.xml`'s `<url>` (dev → main). The second, since 0.9.175, is
`use constant DEV_BUILD` in `Plugin.pm` — **1 on `dev`, 0 on `main`**. It is the only
thing in the plugin that knows which branch it came from (the `(dev)` version-tag
convention is retired and `repo.xml` is not inside the zip). It is telemetry only;
it no longer changes cache policy. Separately verify `RESET_CACHE_ON_BUILD => 0`:
that switch is enabled only for a deliberately built clean-load test and must never
reach a routine dev or release build. `tools/t_buildwipe.pl` asserts the safe value.

### Fixes on top of 0.9.174 (not yet built, no version bump)
- **The genre wipe's release gate did not exist** (0.9.174 review, finding 1). See the
  `_buildChanged` bullet under the caching rework below. New suite
  `tools/t_buildwipe.pl` (27 assertions), anti-tested against both the pre-fix code
  (5 red) and a gate written without the dev trigger (2 red).

- **Cover art: the size table, and a cover PRE-WARM — "images take ages on my other device".**
  Field report, and the diagnosis is the whole of it: **the artwork IS cached, but the proxy's
  cache key is the WHOLE request path** — escaped source url + the size spec the skin spliced in
  + the extension (`Slim::Web::ImageProxy::getImage`, `cachekey => $path`) — **and Material picks
  that spec from the DEVICE.** Read out of the live `material.min.js`: `LMS_LIST_IMAGE_SZ =
  IS_HIGH_DPI ? 300 : 150` (list rows), `LMS_IMAGE_SZ = IS_HIGH_DPI ? 600 : 300` (grid tiles),
  `LMS_CURRENT_IMAGE_SZ = IS_HIGH_DPI ? 2048 : 1024` (now playing), each rendered `_<n>x<n>_f`
  and spliced in before the extension by `resolveImageUrl`. So a cover the desktop warmed is
  still stone cold on the phone.
  - **MEASURED on the live server, same cover, varying ONLY the spec:** 150 → **1.80s**,
    300 → **1.92s**, 400 → **2.05s**, 600 → **2.12s**, then a REPEAT of 150 → **0.03s**. The
    cache is working perfectly and it is per-size. `_400x400_f` was cold at 2.0s even though it
    maps to the same CAA file as `_300x300_f` — **the proxy re-downloads the origin per spec.**
  - **The origin is the cost:** `coverartarchive.org/.../front-250` 307s to archive.org and then
    to an `ia*.us.archive.org` node — 0.11s + 0.63s + ~0.85s, no CDN. Not fixable from here.
  - **FIX 1 — the size table** (the long-open ACTION item below, now closed). `getRightSize`
    returns undef above the table's ceiling, so `|| '250'` served the SMALLEST file on the
    BIGGEST request. Proof from the same run: `_600x600_f` came back **38,248 bytes, smaller
    than the `_400x400_f` beside it at 72,764** — a 250px thumbnail upscaled 2.4× on every
    retina grid tile. Table now reaches `1200 => '1200'` and the fallback is the LARGEST entry.
  - **FIX 2 — `Browse::_warmCovers`**, chained off each feed's `warmFeeds` onDone. It walks the
    feed newest-first, caps at `COVER_WARM_MAX` (150) releases, and fetches the server's OWN
    `/imageproxy/<esc>/image_<spec>.png` for the three specs Material asks for — one request in
    flight, `COVER_WARM_GAP` (0.1s) apart. **The path is built by `proxiedImage`, the SAME sub
    XMLBrowser runs over the row**, so it is byte-identical to what the client will request; a
    path differing by so much as its extension would fill a key nobody reads and the feature
    would look like it worked while doing nothing. Warmed paths are marked in the store
    (`lbf:imgwarm:<path>`, `COVER_WARM_TTL` 25d — deliberately INSIDE the proxy's own 30d life),
    so steady state only pays for genuinely new releases. A 401/403 from our own request (a
    password-protected server) abandons the pass with one info line rather than logging the same
    failure a few hundred times. New pref **`warm_covers`** (default ON, General settings) turns
    all of it off.
  - **The now-playing specs (1024/2048) are deliberately NOT warmed** — no LBF row is ever the
    now-playing artwork and they are the most expensive entries in the table.
  - **No cache bumps.** Nothing about a stored shape or a cached decision changed.
  - `tools/t_coverwarm.pl` (50 assertions as of 0.9.189): the size table driven through
    `getRightSize`'s REAL algorithm against the table PARSED out of `Plugin.pm`, the ladder's
    url REWRITE, the warmed path compared to what Material builds, the queueing rules, and the
    runner's CONCURRENCY BOUND and its queue ORDER. **Anti-tested** via `LBF_PLUGIN=` /
    `LBF_BROWSE=` / `LBF_API=` —
    restoring the old table, re-anchoring the rewrite as `s|/front-\d+$|…|`, dropping the
    `.jpg` from `coverArtUrl`, or splicing the spec after the extension instead of before.

### 0.9.174 — PRE-RELEASE REVIEW OF THE 0.9.173 WORKING TREE. Eight defects, all fixed.

Reviewed the full working-tree diff (~4,700 lines across `API.pm`, `Browse.pm`,
`DSTM.pm`, `Diag.pm`, `Plugin.pm` + the new `DB.pm`). None was a compile break —
`t_loads.pl` passed throughout, which is exactly why they survived. Three produce
user-visible hangs or stalls, three are genre-ladder gaps, two are efficiency.

**THE HANGS**

- **`_hostedGet`'s 429 retry had NO ATTEMPT CAP.** A sustained 429 rescheduled for
  ever, so `$onMiss` never fired — and `$onMiss` is not a cosmetic branch, it is the
  **MusicBrainz fallback** in `getArtistMbidByName`. `DSTM::_resolveArtistMbids` pumps
  one artist at a time waiting on that callback, so one wedged lookup stalls the whole
  radio seed rather than degrading to the slower source. The LB side has capped this at
  `LB_RETRY_MAX` since it was written; this side never did. Now `HOSTED_RETRY_MAX` (3),
  plus a **separate, looser `HOSTED_WAIT_MAX` (6)** for the shared-deadline stand-down.
  **Two counters, not one, on purpose:** standing down on somebody else's deadline is
  not this caller's 429, and sharing a counter would spend a caller's whole budget on
  other callers' rate limiting and miss to MusicBrainz under ordinary concurrency.
- **THE MUSICBRAINZ PATH HAD NO BACKOFF AT ALL — fixed 0.9.180, the last of the three.**
  ListenBrainz had `_lbWait` and the hosted API had `_hostedNoteLimit`; the MB artist-sort
  warm logged a rate limit at info level and moved straight to the next artist. **503, not
  429, is how MusicBrainz throttles** — a backoff copied from the hosted side without that
  line would never fire. Now `_mbWait` / `_mbIsRateLimited` / `_mbNoteLimit` / `_mbNoteOk`:
  shared deadline, 5s doubling to 30s, reset on success, **outward-only** (a fresh limit
  must not shorten a window still running). A rate limit now **ends the pass** and hands
  the whole in-flight reservation back — miss that release and the queued MBIDs stay
  marked in flight for the life of the process, which the in-flight guard then reads as
  "MB has no sort-name for these", for ever. **The courtesy gap is not a rate limiter:**
  measured 2026-08-22, two 503s inside eight requests paced at 1.2s, *wider* than the 1.1s
  gap this code applies. Guarded by `t_genrefill.pl` §13, anti-tested 4 red.
  **Stage D of the MB retreat (`caching-rework.md` §2.4.3) is DROPPED, not deferred** — a
  `type`-driven local sort key files Panda Bear as "Bear, Panda", and LB's payload carries
  no signal that separates a stage name from a legal name. MB stays the sort-name source.
  **The budget is threaded through the reschedule (`$st`)** — re-entering without it
  would reset the count on every retry and the cap would be inert while reading as
  fixed. `t_genrefill.pl` §9 pins all of it, including the threading.
- **`_ingestFeed` widened the recorded window from UNVALIDATED payload dates.** The
  format check passes `2099-01-01` as happily as a real date, and one such row pushed
  the span past `DB::WINDOW_MAX_DAYS` (800) — where **`_dayRange` refuses silently**,
  returning an empty list. No `feed_day` row is then written for **any** day, so
  coverage can never complete, every open sees a gap and revalidates, and the "serve
  from the store, no HTTP at all" case this whole rework exists for never happens again
  for that feed. The same widened window is also the **rotation scope**, so an outlier
  widens what RULE 2 may delete. Fixed with `WINDOW_SLACK_DAYS` (180) — a date only
  gets a vote if it is plausibly part of this window — plus a hard fallback to the
  requested window if the span still exceeds the bound (`days` is a user pref).
  **Outliers are still STORED**; they are simply not allowed to define the day range.
- **`_execBlob` prepared a fresh statement per call**, and `ingestFeed` calls it once
  per release inside one synchronous transaction: **~3,255 prepare/execute cycles
  blocking the event loop inside an HTTP callback**. That is the hazard `_withGenresLB`
  spends a whole block comment avoiding at 150 — twenty times smaller. Now
  `prepare_cached($sql, undef, 3)`; `$if_active = 3` is a guard, not a path, since
  every statement through here is DML and DBD::SQLite does not leave those active.

**THE GENRE-LADDER GAPS** — all three are the same failure mode: *a bare view is a bug*

- **`_withGenres` discarded every release with no `release_group_mbid`.** They never
  reached `_mergeHostedGenres`, so the two **artist-keyed** rungs — LB artist tags and
  Last.fm — were unreachable for them. Those rungs key on the artist, not on a release
  group, and **the Trending rows with no MBID are precisely the case they exist to
  answer**: the rows the ladder was built for were the rows it could never reach. They
  now ride in a separate `@artOnly` list on **their own budget** rather than in
  `@rels` — `@rels` is what the release-group lookups are batched from and `$max`
  bounds that HTTP, so letting artist-only rows in would displace lookups that actually
  fetch something.
- **For You built `$meta` under the 150-release `GENRE_FETCH_MAX` and then filtered the
  FULL list.** Every release past the cap had no entry, bucketed as `GENRE_NONE`, and
  was dropped outright by any ticked family — **while the picker counts over
  `GENRE_WARM_MAX` (600)**, so it promised rows the view then refused to show.
  `_buildAllLanding` already applies the rule (filter-before-paging needs the wider
  fill); For You now does too, and only when a filter is actually set.
- **The top-up gate counted ROWS PRESENT, not GENRES PRESENT.** `rgGet` answers for any
  row that exists, and rows get created by things with nothing to do with the LB genre
  tier — the detail page files its own answer with `rgPut($rg, detail_genres => …)`,
  which leaves `n_genres` at its **-1 "never asked"** default. So a feed whose release
  groups had each had a detail page opened once looked fully covered, the top-up never
  fired, and the rows stayed bare in the list for ever however many times they were
  opened. New `_rgAnswered` gates on a recorded answer or an actual genre.

**THE EFFICIENCY TWO**

- **`warmArtistSorts` aged sort-names against the row-wide `fetched_at`** instead of
  the `sort_at` stamp schema 3 added — which was **written and never read** (the string
  `sort_at` appeared nowhere in `API.pm`). The mirror genre tier rewrites that same
  MBID-keyed artist row daily, so a row recording "MB has no sort-name"
  (`SORT_NONE_AGE`, one day) had its clock reset every night and was never re-asked,
  while a real sort-name was held well past `SORT_FOUND_AGE` for the same reason.
  Falls back to `fetched_at` only for a pre-migration row whose stamp is still 0.
- **`_withGenresMirror`'s peek called `peekArtistGenres` PER ARTIST** — up to ~600
  synchronous SQLite SELECTs inside the browse callback on the picker's whole-feed
  pass, the same hazard 0.9.130 removed from the release-group side and 0.9.165 nearly
  put back. `peekArtistGenresBulk` already existed and is what every other peek uses.

**A TEST WAS CHANGED, NOT JUST CODE.** `t_genrefill.pl` asserted the *old* contract —
"a rate-limited request is retried, NOT reported as a miss" — with a regex requiring no
`$onMiss->(` anywhere in the 429 branch. The cap necessarily violates that, because an
exhausted budget **must** miss for the MusicBrainz fallback to be reachable. Rewritten
to pin the new contract (bounded retry / miss only once spent / budget threaded), 1
assertion → 5. **Cleared by the same review and left alone:** blob bind positions at
every `_execBlob` call site, the `%FACT` alias direction, key-family/`retirePrefixes`
overlaps, the `n:<norm>`-vs-MBID artist key space, the self-passing closures
(`$next`/`$step`/`$pump`) for cycles and missed callbacks, `_releaseDetail`'s `$pending`
barrier on all four genre branches, `_bioBullet`'s list-vs-scalar change and its
callers, and Diag's staggered capture and display redaction.

**No cache-prefix bump was needed** and none was made: nothing here changes the SHAPE
of a stored value, and the two read-side gate fixes are self-healing. The version bump
alone triggers `_buildChanged`, which clears the derived tier and the genre answers.

### THE GENRE LADDER AS OF 0.9.174 — the current shape, read this before the two docs below

> **`docs/genre-ladder-current.md` is now the canonical statement of what ships** — the ladder,
> which views show genres, what the hosted API is called for, and what was built and then
> discarded. This section stays as the summary; that doc is the detail, and the older genre
> docs are history.

```
LB release-group tags  →  the DETAIL PAGE's own answer  →  LB artist tags
                       →  inline release_tags  →  Last.fm
```

- **The hosted ARTIST rung is GONE.** It was removed because the premise that put it
  there was wrong: the hosted API is MusicBrainz-DERIVED, so it is not an independent
  source — it fails wherever ListenBrainz fails. Measured on the RESIDUE (the artists
  that actually reach it, which is the only population that matters): **4 of 120 on
  2026-08-13 and 1 of 67 on 2026-08-21**, ~2%, for ONE HTTP request per artist at a
  concurrency of one (~64s per warm). **Last.fm is the only genuinely independent rung
  and answers ~63% of that same population.** Judging any genre source on a whole-feed
  sample (~50%) is what made this look useful — those artists never reach the rung.
- **~~The hosted ALBUM route STAYS~~ — REMOVED TOO, 0.9.185.** It was kept in 0.9.173
  for the established-album population that shares the release detail page, and that
  reasoning turned out to be wrong for a reason nobody checked at the time: **the
  Trending Albums build already fetches and stores genres itself** — its release-group
  metadata pass carries `inc=release_group tag` — so those genres are in the store
  before a row can be clicked, and the peek that precedes the call already answers.
  What was left firing on the residue where every MB-derived source was empty, which
  both of these are. Measured 2026-08-22: **hosted 0 of 40** albums off the live
  fresh-releases feed; the MB release-group tier behind it 0 of 14 on the same
  residue. **Two blocking requests per album open to re-ask a well that had just come
  up dry.** `getReleaseGroupGenres`, `_hostedGenreNames` and the `HGENRES_*` constants
  went with it; `lbf:hgenres:`/`lbf:rggenres:` are out of `KEY_VERSIONS` (they lived
  in `Slim::Utils::Cache`, not `kv`, so they simply age out).
- **`release_group.detail_genres` (schema 5) is now WRITE-ONCE HISTORY.** The detail
  page filed what it learned so the LIST could read it; with nothing left to learn,
  nothing writes it. **It is still READ as ladder tier 1b and values already stored
  stay valid — do not strip the tier out of `_genresFor`.**
- **If any hosted genre route is ever reinstated it MUST come back with the
  lowercasing** (`_hostedGenreNames`, removed with its last caller). The payload is
  Title-Cased; `_genreFamily`/`_genreKnown`/`_bucketFor` key on the lowercase
  vocabulary in `genre-families.txt`, and a Title-Cased genre does not fail loudly —
  it silently stops rolling up to its family.
- **`genre_mbid` was ALREADY the gate** (`_genreTags`), and it cannot replace
  `genre-families.txt`: that file gates the **Last.fm** rung, and Last.fm tags carry
  no `genre_mbid`. They are not substitutes.
- **The ARTIST-KEYED rungs (LB artist tags, Last.fm) do NOT need a release group**, and
  since 0.9.174 they are actually reachable without one. `_withGenres` used to drop any
  release with no `release_group_mbid` before the merge ran, which silently amputated
  the bottom of the ladder for exactly the rows — Trending, no MBID — those rungs were
  added to answer. If a row is bare, check it reached `_mergeHostedGenres` at all
  before assuming the tier had no answer.

#### ⚠️ THE MB ARTIST RUNG IS LIVE CODE — a zero counter lied about it

`cachestats` reports `artist_mb_have` 0 / `none` 0 / `never` 2191, which reads as
"never called, safe to delete". **It is not.** `mb_base_url` on the live box is set to
the public API, so `hasMirror()` is false, `_genreLookupMode()` returns `'lb'`, and the
mirror path never runs THERE. For a user with a local MusicBrainz mirror it returns
`'mirror'`, and `_withGenresMirror` → `API::getArtistGenres` is their **entire** artist-tier
genre lookup — `_withGenresLB` never runs at all. Removing it would take genres away from
those users completely. **Since 0.9.186 the mirror path is no longer artist-only:**
`_mergeRgGenres` folds the two release-group tiers (1 `genres`, 1b `detail_genres`) in from
the store on all three of its exits, which mirror mode could not see at all before.

**The general rule: a zero counter on ONE box is evidence about that box's prefs, not
about whether code is reachable.** Check what gates the path before reading a zero as
dead. (This box is one pref away from that path — CLAUDE.md's own advice for the
sluggishness is to clear `mb_base_url`.)

#### `bench_walk.pl` was silently half-dead — fixed 0.9.173

`_sortWithin` calls `_firstArtistMbids`, which was never in the bench's sub list, so
the bench **died there and skipped everything after it** — including the `_bucketFor`
line, which is the guard that caught the per-release SELECT in 0.9.165. A harness that
dies half way through reports a SHORTER LIST, not a failure, so a dead guard looked
like a quiet one. If a bench line you expect is missing, check for a die before
concluding the thing it measures is fine.

### WARM ORDERING & FOLLOWER LATENCY — READ `docs/warm-ordering-and-follower-latency.md`

**Stage 1 built in 0.9.175 (instrumentation only). Stage 2 designed, NOT started,
and deliberately gated on the numbers** — Simon's call was "let's test to see if
these proposals give us the gains before committing", so do not start reordering
the warm until `["lbf","warmstats"]` has been read off a real tick.

Three findings from that doc that correct things people assume about this plugin:

- **Playlists and Followers are NOT missing a cache.** They live in `kv` on flat
  TTLs rather than in the feed store, so they log no "served from the store" line.
  **Since 0.9.203 they survive ordinary dev builds too**; only expiry or an explicit
  `RESET_CACHE_ON_BUILD` clean-load build makes them cold.
- **There has NEVER been a "still building" state.** `PLUGIN_LBF_NO_TRENDING` fires
  only from the affirmative empty branch (nobody followed / no active followers / no
  candidates). Nothing was removed from history; a cold Followers open simply blocks
  the whole fan-out with no interim response and Material spins. Don't go looking for
  the regression that removed it.
- **A cold Followers open runs the entire build on the open path with NO in-flight
  guard** — two 30s fan-out deadlines before the streaming work starts, `$callback`
  invoked only at the very end, and each of the three views paying separately. The
  `%REVALIDATING` shape in `API.pm` is the fix pattern and already exists for feeds.

### FEEDS & GENRES — READ `docs/feed-findings-2026-08-14.md` FIRST

**The current record.** It holds the 2026-08-13/14 live measurements and the decisions
that came out of them: that ListenBrainz, MusicBrainz and the hosted API are **one
MB-derived well** (they fail together — only Last.fm is independent), Simon's decision
to **drop genre filling from hosted + MB and keep LB + Last.fm**, LB's unused bulk
`/1/metadata/artist/?artist_mbids=&inc=tag` endpoint and its `genre_mbid` genre gate, the
**cache-age policy (empty → 1 day, found → 30 days)**, the transient-empty Trending cache
bug, the ~10% of rows whose artwork claim is stale, and the work order. It supersedes
parts of the doc below — read it before that one.

### GENRES — READ `docs/genre-ladder-rework.md` BEFORE TOUCHING ANYTHING GENRE-RELATED

**That doc is the record of the 0.9.166–0.9.169 genre work and the standing plan, and it
exists because this work has now been half-lost twice** — once when `docs/caching-rework.md`
was rewritten on disk mid-session and took a set of corrections with it, once when an agreed
design shipped only half-implemented without that being flagged. It carries: the ninety-day
lockout and its root cause (freshness judged per ROW where the request answers TWO questions);
the three same-shaped "a write touching what it does not own" defects that schema 3 makes
inexpressible; **the gap between the approved schema and what 0.9.169 actually shipped**; the
artist-keying defect that makes both artist-level rungs re-buy answers the store already owns;
the MAI precedent read from source (uncapped, ONE request in flight, 5s-doubling 429 backoff)
and what it says about our caps; the live measurements; and the agreed 4-step plan. Don't
re-derive any of it, and don't reinstate `HOSTED_WARM_ALL` on its own.

### THE CACHING REWORK — LANDED. READ `docs/caching-rework.md` FIRST (started 2026-08-13)

**BUILT, VERSIONED AND INSTALLED — this heading said "IN BUILD / not built, not
versioned, not installed" until 2026-09-10, long after it stopped being true.**
Stages 1–7 plus the brought-forward A/B/C are all DONE and shipped (0.9.164–0.9.203);
stage 8 (scoped per-week SQL) is deferred by design, gated on `bench_walk.pl` numbers;
stage D is DROPPED, E is SETTLED on MusicBrainz and F shipped in 0.9.179. **The
cache-WIPE policy this rework shipped with has since been reversed** — ordinary version
changes now preserve every cache; see the section at the top of this file and
`docs/cache-priority-refactor.md`, which is the plan that supersedes this one for
anything about warm ORDER or priority. The plan, the staging and the decisions already
taken (do not re-open them) are in `docs/caching-rework.md`, whose header carries the
stage table. Two things from it that change how you read the rest of this file:

- **GENRES HAVE NEVER WORKED, AND IT WAS NEVER THE GENRE CODE.** `RECMETA_TTL` and
  `AGEN_FOUND_TTL` were both `90 * 86400`, and LMS reads any TTL over **2,592,000** as
  an ABSOLUTE epoch — so every entry was written expiring **1 April 1970** and every
  read returned undef, silently. Because the long TTL is the **dated** branch, the
  entries worth keeping were exactly the ones discarded. `RECMETA_TTL` is applied by
  `getReleaseGroupMetadata` as well as the recording cache, which is where the visible
  damage was: **the ListenBrainz genre tiers have never once served a dated release.**
  Every label seen on screen came from inline `release_tags` or Last.fm, and the
  background top-up re-fetched the same releases on every visit. Both are now `30 *
  86400` and pinned by **`tools/t_ttlceiling.pl`**. **Expect a visible jump in genre
  coverage on the first run — that is the tier working, not a new bug.**
  ([[lms-cache-30day-ttl-boundary]], `docs/cache-ttl-30-day-boundary.md`.)
- **`ListenBrainzFreshReleases/DB.pm` IS NOW THE WHOLE STORE, AND THE FEEDS READ IT.**
  Stages 1–7 are in: schema (BASE / FACTS / `kv`), `PRAGMA user_version` migrations, the
  `kv*` API with an ALWAYS-ABSOLUTE `expires_at`, the durable three as tables, the FACTS
  tables, and — since 0.9.166 — the feed itself. **The rule that makes the tiers work:
  if it is in `kv` it is disposable; if it must survive, it needs a table.**
  Guarded by **`tools/t_db.pl`** (204 assertions, persistence proved CROSS-PROCESS
  because `$dbh` is a file-lexical and an in-process read proves nothing; anti-tested
  four ways — a `kvSet` that returns 1 without writing, a missing `SQL_BLOB` bind, an
  accepted empty ingest, and an ignored `rotate` flag).
- **THE FEED IS STORED, NOT CACHED (0.9.166) — and this is what ends the midnight
  re-mint.** `getFreshReleasesAll` keyed its one big blob on TODAY'S DATE, so the entire
  ~3,255-release structure was re-fetched and re-frozen every local midnight and on any
  window/past/future change. Coverage is now a QUERY over `feed_day`:
  - **narrowing the window (days 14→7) costs nothing; widening costs only the days it
    adds; midnight leaves exactly ONE day uncovered** and every stored row still served.
  - **any stored coverage is served IMMEDIATELY and revalidated behind the render** —
    safe because every feed callback is already `cachetime => 0`. Only a genuinely cold
    store blocks.
  - **`_feedWindow` / `_feedFromStore` / `_fetchReleaseFeed` in API.pm** replace the
    `lbf:feed:*` + `…fb:` twin keys. The date stays in the five-second in-process memo
    key, where it is harmless, and is gone from storage, where it was the bug.
  - **`%REVALIDATING` is load-bearing**: one tap produces 3+ walks from the root, and
    without it each would see the same stale coverage and launch its own fetch.
  - **MUSPY IS STORED WITH ROTATION OFF, and that is not tuning.** `?limit=100` is a
    top-N SLICE, so day coverage would be a lie and window-scoped rotation would delete
    rows that are still valid, merely pushed past the limit. *A truncated list is not
    proof of absence* — the same family as "an empty result is never a fact".
  - **Refresh no longer DELETES a feed**; it marks coverage stale, so the user keeps
    seeing releases while the re-fetch runs and a failed refresh leaves them with what
    they had. Both memo layers are still dropped (the 0.9.141 review bug survives the
    move unchanged).
  - **`_buildChanged` preserves the whole cache on an ordinary build.** Derived
    families own key versions; schema/fact families own their migrations and parser
    versions. `RESET_CACHE_ON_BUILD => 1` is the only full reset and exists solely
    for a deliberately built clean-load test. Its once-only marker is the
    **PREF** `last_build`, not a `kv` row.
  - **Genres clear automatically only when `last_genre_fact` differs from
    `GENRE_FACT_VERSION`**, or as part of that explicit clean-load reset. The pref
    was once write-only, causing released upgrades to discard all artist and
    release-group genres plus `lastfm_tags`; `tools/t_buildwipe.pl` guards the
    parser gate, whole-cache preservation and the explicit reset independently.
  - **`Browse::warmFeeds` runs AHEAD of `warmCache`'s username gate** — All Releases
    needs no account and had therefore never been warmed for anyone.

**0.9.165 — GENRES ON THE ROW FROM THE FIRST OPEN.** The field report was *"genres are
not populating on build of the view, having to go in/out of a release for these to show"*.
Three causes, and only the first was known:
- the TTL bug (0.9.164) meant nothing the warm found ever persisted;
- **`GENRE_WARM_MAX` = 600 against a 3,255-release feed** — ~80% of All Releases was never
  warmed, so most weeks rendered bare and filled only from `_kickGenreFill`, which is
  throttled to one run per `GENRE_KICK_GAP` (120s). **That cap was concealing the TTL bug,
  not protecting anything**: before persistence worked, warming more just re-fetched more.
  New `GENRE_WARM_ALL` (4000) covers the whole feed;
- **the For You genre warm still required a TOKEN** (`unless ($user && $token)`), four
  releases after 0.9.160 established `fresh_releases` never needed one.
- **New tier: hosted artist genres** (`API::getArtistGenresHosted`, `_hostedGenres`),
  because LB alone answers only ~52% and a fully-warmed feed at 52% still looks half
  empty. Ladder is now LB release-group → LB artist → **hosted artist** → inline
  `release_tags` → Last.fm. **Hosted sits BELOW LB's artist tags deliberately** — those
  arrive free on a call already made, and both sources agree where both have one.
- **THE RENDER PATH READS NO STORE.** The hosted tier arrives through the render's
  existing `$meta` map from ONE bulk `DB::artistGet`. The first cut read the store per
  release — ~2,900 synchronous SELECTs on the genre picker's whole-feed walk, the same
  hazard 0.9.130 exists for. **Caught by `tools/bench_walk.pl`, not by review**; pinned by
  a test, and `HOSTED_MARK` short-circuits before any key is built so the empty case is
  free (`_bucketFor` 1.93ms → 1.47ms).
- **Rate limiting is now handled** (`_lbWait`/`_lbNoteLimit`/`_lbIsRateLimited`): measured
  30 requests per ~10s window, and the widened warm is 66 batches, so a 429 went from
  possible to certain. **A 429 is a retry, not a lost chunk** — the chunk stays at the head
  of the queue, `X-RateLimit-Reset-In` is honoured, and the deadline is SHARED so
  concurrent callers back off together.

**MEASURED 2026-08-13 against the live API — don't re-derive:** the All Releases feed is
**3,255 releases / 66 batches**; a batch is **0.23s median**, so the whole feed is **~16s
serial**. Coverage **6% release-group + 46% artist**. Hosted artist route: **median
0.08s**, Title-Cased (must be lowercased or `_genreFamily` silently stops rolling up),
`genres` key ABSENT for Radiohead, and `[]` for Panda Bear — an empty list is a real
answer, distinct from absent, and both are stored.

**Do NOT re-derive the sluggishness.** It is mostly one server pref: `mb_base_url` is
set to the public API on the live box, so `autodetectMirror` returns early and the
local mirror at `plex:5000` is never adopted — 45 × `503` from one artist-sort warm.
Clearing the pref needs no build.

### THE GENRE WORK IS UNPARKED AND LIVES ON `dev` NOW (0.9.162, 2026-08-12)

**Read this before touching anything genre-related, and before believing `ALPHA.md`.**

The genre-labels + genre-picker feature was parked on the **`alpha`** branch at 0.9.140. It is now
**ported onto `dev`** and switched ON by default. Simon's instruction was explicit: *"I want this all
worked on in dev not alpha."*

- **`alpha` IS NOW STALE AND MUST NOT BE MERGED.** Its `ALPHA.md` still says the feature is blocked
  and waiting on "whether the plugin adopts a Lyrion API server as a metadata backend". That question
  is answered and the answer was not the hosted API — see below. Treat `alpha` as history.
- **WHY IT COULD BE UNPARKED — the blocker was fixed upstream, by ListenBrainz.** The feature needed a
  genre for every release in a feed, and `ALPHA.md` records the measurement that killed it:
  `/1/metadata/release_group/` answered a 50-mbid batch in **0.25s–24s**, 502'd above ~90 mbids, and
  took **125s** to fill one 381-release feed. **Re-benchmarked 2026-08-12 against the live
  556-release All Releases week: 2.8s for the WHOLE feed** — 12 batches of 50, worst batch 0.52s, no
  502s. Coverage reproduced exactly (5% release-group tags, 47% artist tags). Don't re-derive these.
- **The unpark itself was ONE LINE.** Both backends were already written. `Browse::_genreLookupMode`
  used to end `return $pref eq 'always' ? 'lb' : 'off'`, so the default `auto` meant **off** for
  everyone without a local MusicBrainz mirror. It now falls through to `'lb'`. `genre_lookup`'s
  `'always'` changed meaning accordingly: it now forces the ListenBrainz path even when a mirror
  exists, rather than opting in to something slow.
- **The genres ride a call the plugin ALREADY makes.** `getReleaseGroupMetadata` fetches years/dates
  for the trending path; adding `tag` to its `inc` returns `tag.release_group` + `tag.artist` in the
  same request. There is no separate genre fetch at feed level.
- **`tools/t_genrefill.pl`** guards all of this — in particular the lookup-mode default, so anyone
  reinstating "off unless a mirror" fails the suite. Anti-tested both ways.

**THE HOSTED LMS-COMMUNITY API IS NOT THE GENRE BACKEND — measured, don't retry it.** It was the
obvious candidate and it does not fit this plugin's population:
- Its `/album/<title>/<artist>/genres` returns **MusicBrainz's own genres** (verified twice: `So` by
  Peter Gabriel and `OK Computer` both come back as MB's exact set, in MB's count order, Title-Cased)
  — so it is a faster route to the 5% release-group tier we already had, not a new source.
- On the actual All Releases population it covered **1 of 60** Album-type releases (~2%).
- **There is NO artist-genre route**, and the artist tier is where 47% of the coverage lives.
  `/music/artist/<n>/genres` answers **HTTP 200 with the PICTURE payload**, as do `/tags`, `/genre`,
  `/info` and any other unrecognised path under `/artist/<n>/` — it never 404s. Confirmed against the
  dev's own route list (`~/Downloads/mai-api.md`), which documents exactly one genre route.
- Where it DOES win is `getArtistMbidByName` and the radio's similar artists — see below — **plus one
  narrow genre use: the RELEASE DETAIL PAGE's last-resort genre lookup.** That path is not the feed's
  genre backend and never sees a list row; it is the single per-page call that used to go straight to
  MusicBrainz — i.e. **one public-API-throttled request per page open** for every user without a
  mirror. The hosted route answers the same data unthrottled (it returns MB's OWN genres, Title-Cased
  — verified on *So*, *OK Computer* and *In Rainbows*), and its hit rate on the **Trending Albums**
  population that also lands on this page was measured at **57%**, versus ~2% on fresh releases. The
  MusicBrainz call stays behind it, unconditionally. Don't read this as licence to try the endpoint on
  list rows again — the ~2% and the missing artist tier are why that cannot work.

**NO OPT-OUT PREF FOR THE HOSTED API — decided 2026-08-12 (Simon), don't add one, don't propose one.**
Every hosted tier is unconditional. What makes that safe is the fallback behind each one, not a
setting: an outage, a rejected answer or a miss all degrade to exactly the pre-hosted behaviour on
their own. `docs/hosted-lms-community-api.md` used to suggest a pref; that line is struck.

### Hosted LMS-community API — what it is used for (current as of 0.9.186)
Adopted for **name→MBID resolution**, **similar artists**, and since 0.9.179 the **release-group
resolver**. **It has nothing to do with genres any more:** the artist tier was built and removed in
0.9.173, the album tier in 0.9.185. All calls go through `API::_hostedGet` (one
funnel, mandatory `X-LMS-Plugin-ID`, auth slot for later). Note the live route prefix is
**`/music/...`** — `docs/hosted-lms-community-api.md`'s route lines omit it and are wrong; its header
now says so.

**THREE ROUTES, and there are no others** — re-verified 2026-08-23 by grepping every construction of
`HOSTED_BASE_URL`/`hostedUrl` in the tree (plus one diagnostics probe):
- `artist/<name>/discography` → **`getReleaseGroupByName`** (0.9.179), so **Followers → Trending**
  and **Trending Albums** resolve unmapped-listen rows without an MB search each. One call per
  ARTIST, not per album. **Never swap this for `/album/<t>/<a>` — that returns a RELEASE mbid.**
- ~~`album/<album>/<artist>/genres`~~ → **REMOVED 0.9.185.** The detail page fetches no genres at
  all now; it reads the store, which the ladder and the trending build have already filled.
- `artist/<name>/aliases` → **DSTM radio** (seed artist, then each similar artist) through
  `getArtistMbidByName`, and the streaming **alias pass** in `_findPlayable` (2026-09-14; replaced `/mbid`).
- `artist/<name>/relatedArtists` → **DSTM radio** only, when LB has no similar artists for the seed.
- `artist/<probe>/mbid` → the **diagnostics page**, once per open.

**What stays on MusicBrainz** (`hosted-lms-community-api.md` §7), **as of 2026-09-14:** only the
tracklist for the exact release when ListenBrainz has none (`getReleaseDetails`, through the one
MusicBrainz queue) and the mirror-only artist genres. The sort-name warm is GONE — the Artist sort is
A–Z on the display name (Ledger §A2 `ARTIST SORT IS A–Z ON THE DISPLAY NAME`).

Full table, with fallbacks and triggers, in `docs/genre-ladder-current.md` §4.
- `getArtistMbidByName` is **community API only since 2026-09-14** (via `getArtistAliases`): accepted
  **only** when the MBID is non-empty **and** the query folds equal to the canonical name OR one of
  its aliases. The length check is load-bearing — an unknown artist returns `{"name":"<query>"}`, so
  the name folds equal to itself. No MusicBrainz fallback (Ledger §A2 `STREAMING ALIAS PASS`).
- `getSimilarArtistsHosted` → `/artist/<n>/relatedArtists`: 25 artists, **100% carrying MBIDs**, no
  API key. Emits the same shape as the Last.fm rung so it drops into `DSTM::_resolveArtistMbids`,
  whose inline-MBID short-circuit then costs **zero** MusicBrainz lookups. Radio ladder is now
  LB similar → hosted → Last.fm → recommendations.

### State of play (re-dated 2026-09-14, current at 0.9.218) — read this before starting anything

*This section was dated 2026-07-30 and had not been rewritten since, so it still
described a 0.9.151 working tree, a matcher hold that closed in 0.9.194 and four plans
that have since shipped. Rewritten in the hygiene pass to describe the repo as it is.
**Re-date it whenever you change it** — a "state of play" that lies is worse than none.*

**BRANCHES.** `dev` is the working line and is at **0.9.218** (built 2026-09-14, **NOT installed** —
the catch-up fold, Ledger §C `CLOSED IN THE 0.9.217 REVIEW`). **0.9.217 is what is INSTALLED on the
rig (2026-09-14 16:54)** — it carries 0.9.215 (the per-section release window, never installed on
its own), 0.9.216 (the fixed overnight clock, never installed) and that clock's review fixes.
The catch-up warm is verified live; the skip branch, the re-seed and the first 05:xx tick are
not yet — see Ledger §C (`CLOSED IN THE 0.9.216 REVIEW`). `plugin_version` is still the first
thing to read.
0.9.218 passed review (no findings, Ledger §C `CLOSED IN THE 0.9.218 REVIEW`) and is committed
and pushed to `dev`, 2026-09-14. When a later tree is uncommitted or unpushed, per the Review
Ledger both states are the deliberate review gate, not a defect. `main` is at **0.9.149** — everything
from 0.9.150 on has never been promoted, so "what users have" is far behind `dev`, and
the CHANGELOG/README debt for that gap is a merge-gate item. `alpha` holds the parked
genre work at 0.9.140 and **must not be merged** — the feature was ported onto `dev` in
0.9.162 and `ALPHA.md` there is wrong about why it was blocked. `beta` is untouched and
stale at 0.8.24.

**FLEET HOLDS.**
- **Matcher sync: the hold is OVER.** It closed with LBF 0.9.194 / PFR 0.9.33 on
  2026-08-29. `matcher_sync_check.py` **exits 0**; a non-zero exit is a real finding
  again. Search Hub is pinned in `VARIANTS` as a deliberate frozen variant.
- **Search Hub is still ON HOLD.** No work on `LMS-Search-Hub`, and nothing here should
  start depending on it.

**PLANNED WORK — genuinely not started. Read the doc before opening the code:**
- ~~**`docs/overnight-detail-prewarm.md`**~~ — **SHIPPED, moved out of planned work
  2026-09-10.** Implemented for testing in **0.9.200** (`DetailWarm.pm` + the prewarm
  queue); the design lives in `docs/cache-priority-refactor.md` under "Third
  implementation". What is still owed is VERIFICATION, not design: live queue
  throughput, restart/checkpoint behaviour, and a fixed overnight clock — see the
  "Open on this repo" list below.
- ~~**`docs/cache-ttl-30-day-boundary.md`**~~ — **FIXED 2026-08-13, and there were TWO
  instances, not one.** Both constants are `30 * 86400`, and the boundary is now
  **inexpressible** rather than merely corrected: the ages are compared against
  `fetched_at` in Perl (`RECMETA_AGE` / `AGEN_FOUND_AGE`), so 90 days means 90 days
  again. `tools/t_ttlceiling.pl` fails any TTL above the boundary in any module,
  including durations written inline into a `$cache->set` call. The doc is kept for its
  §5 — the reasoning is worth reading before diagnosing anything similar — and for the
  lesson that its own §2 audit was written before `AGEN_FOUND_TTL` existed and was
  silently wrong one release later. [[lms-cache-30day-ttl-boundary]]
- **`docs/token-free-refactor.md`** — **§3.1 SHIPPED in 0.9.160**; §3.2/§3.3 still open, §4 dropped.
  Re-verified live 2026-08-12 against the real account: every LB endpoint the plugin calls returns a
  **byte-identical payload anonymous vs authenticated**, and `/1/user/<u>/feed/events` is the **only**
  401 in the whole plugin. So the token is now optional everywhere except the *Recommended* list.
  **The four follow-feed gates are deliberately KEPT** — read §0 of the doc and
  `tools/t_tokenfree.pl` before touching them; removing them turns a missing tile into a runtime 401.
  Still open: rebuilding Recommended on public loved-tracks/pins (§3.2) and the volume decision it
  depends on (§3.3). The Last.fm own-key idea (§4) is **superseded** by the hosted-API refactor.
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
- **`docs/album-title-search-leg.md`** — when a service's ALBUM search for the ARTIST comes back
  empty, re-query that service with the ALBUM TITLE before calling it a miss. **Already shipped in
  the sibling Pitchfork Reviews plugin (0.7.12) — this is a port, not a design exercise.** Measured
  on the live server: Qobuz carries *Leo – Cicada Burnt* and returns it FIRST for `cicada burnt`,
  while its album search for `leo` gives **200 rows without it** (Leo Sayer, Léo Ferré, Leo Dan,
  Leo Kottke…). A RECALL gap, not a matcher gap, and raising the limit only moves the cliff.
  **No `lbf:stream` bump** (what is stale is a 1-day no-match, and a found result cannot change);
  not a matcher sub, so the fleet hold does not block it. **The TRACK path is deliberately out of
  scope** — generic track titles, and `lbf:track` no-matches sit inside `lbf:pl:resolved` for 14d so
  they do NOT self-heal, which would force a playlist-wide re-resolve. Doc carries the LBF-specific
  gotchas (`$dropSingles` ordering, Bandcamp already excluded), the CLI recipe for reproducing the
  measurement, and the two test traps that bit PFR's suite.
- **`docs/genre-ladder-current.md`** — **START HERE for anything genre- or hosted-API-related.**
  What ships (the doc is verified at 0.9.186): the ladder rung by rung with what each is keyed on and stored in, which
  views show a genre line (Trending Albums is a release row that *could* and currently doesn't),
  the three hosted routes and the section each serves, and the two tiers that were built and
  discarded (hosted ARTIST genres, ~2% on the residue; MusicBrainz, now mirror-only) with the
  measurements that killed them. The docs below are the history that led to it.
- **`docs/genre-sources-investigation.md`** — investigated MAI / the hosted LMS-community API as a
  genre backend. **Conclusion: not for list rows** (16% coverage on real fresh releases vs our
  existing 49%, per-album not bulk, non-MB vocabulary, and **no artist-genre route to fall back to** —
  `/artist/<n>/genres` silently returns the *picture* payload with a 200, it never 404s). Good
  detail-page enricher. ~~**Does not change why the genre work is parked on `alpha`.**~~
  **That last clause is DEAD — the genre work was unparked onto `dev` in 0.9.162.** The doc's
  own conclusion held: the detail-page enricher shipped, the list-row idea was built anyway as
  a hosted ARTIST tier in 0.9.162 and removed again in 0.9.173 on the numbers.
- **`docs/hosted-lms-community-api.md`** — scoped 2026-08-01. Adopt the hosted `mai-api`
  (`api.lms-community.org`) as a resolver/metadata backend. **Two hard rules first:** every call sends
  the `X-LMS-Plugin-ID` header, and all calls go through ONE request helper (auth may be added later).
  **Main win:** a two-tier `getArtistMbidByName` — hosted `/artist/<name>/mbid` first + a **name-fold
  gate** (replaces `score>=90`) + unconditional public-MB fallback — beats raw public MB for the
  majority who run no mirror, biggest gain on the DSTM/similar-artist loops. **Secondary:** detail-page
  genres/cover from the rich `/album/<title>/<artist>` endpoint (now that the dev fixed freshness),
  **but** the DB rebuilds WEEKLY (daily WIP), so a new-release plugin MUST keep an MB fallback. Partly
  supersedes `genre-sources-investigation.md`. **SHIPPED 0.9.162, and partly reversed 0.9.173** —
  the resolver and `relatedArtists` landed as scoped, only the *genres* half of the `/album` idea
  was taken (LB already carries type + date on the request that fetches tags), and the hosted ARTIST
  genre tier was removed again. Its route lines omit the live `/music` prefix.

*(The branch and fleet-hold paragraphs that used to sit here were rewritten into this
section's header on 2026-09-10 — they described a 0.9.151 tree and a matcher hold that
had closed. There is now ONE statement of branch state, at the top, so the two cannot
drift apart again.)*

**Known open items on this repo.** *Re-derived from source, tests and git in the
2026-09-10 hygiene pass — everything listed here was checked, not inherited.*

**LIVE TEST OF 0.9.209, 2026-09-10 — what is now PROVEN, and how.** Run entirely over
`jsonrpc.js` against `http://plex:9000`; no log reading was needed for any of it.
- **`plugin_version` reads 0.9.209** — the new report works and no shadowing copy was
  running, which is what makes the rest of this list mean anything.
- **Indexed week identity (the 0.9.206 review finding, built in 0.9.207) — CONFIRMED END
  TO END.** The All Releases week cards carry `{"menu":1,"lbf_week":"2026-09-07"}` and
  `…"2026-08-31"` — a natural key, not a position. Each key resolves to genuinely
  different content, the key route agrees with the positional route for the same week,
  and **a bogus `lbf_week:1999-01-04` returns an empty shell rather than falling through
  to a valid week**, so the key really is validated.
- **The Last.fm candidate-cap fix (0.9.205) — CONFIRMED.** `genres_lastfm_all`: **368
  candidates examined, 365 fresh checkpoints found, 3 upstream requests.** The pre-fix
  worker would have spent its allowance re-asking answered artists.
- **Warm ORDER matches the agreed direction.** foryou_feed 0.00s, all_feed 0.16s, covers
  1.26→6.30s, and `genres_lastfm_all` LAST at 2.01→10.00s. Whole tick 10s.
- **Detail prewarm (0.9.200/0.9.204) — CONFIRMED DRAINING.** `detail_main_ready=1`
  throughout. Across a browsing session: pending **233 → 7**, completed 567 → 793, cache
  hits 1130/1140 → 1295/1308, **0 failures**, 3 new fetches.
- **The Last.fm vocabulary fix (0.9.206) — CONSISTENT, small sample.** 3 requested → 3
  genres, **0 rejected**, and family-less genres render as their own label. The 31 August
  week measures **246 of 371 releases carrying a family**, with 125 in `Other` — some of
  which are family-less labels rather than nothing.
- **A MEASUREMENT TRAP WORTH KEEPING: the plain `items` CLI query does NOT serialise
  `line2`.** The genre line lives there, so a walk done with `["…","items",…]` shows rows
  with no genres and reads as a total genre failure. **Use `menu:menu`**, which returns
  `text` as `"<name>\n<line2>"`. This was briefly mistaken for a defect.

**STILL unproven live.** The **artwork focus slot map** (0.9.207 finding 1) is the one
item that needs INFO logs, since it is about which covers a given row range promotes.
**The MuSpy detail-prewarm union (0.9.207 finding 2) could not be exercised at all** —
`muspy_feed` returned 0 releases, so it needs a MuSpy user id with something upcoming.

**Owed VERIFICATION, not design — the rest of the 0.9.198–0.9.210 run:**
0.9.204 and 0.9.205 were installed; **0.9.206, 0.9.207 and 0.9.208 were built and never
installed**. **0.9.209 is the build going in**, so it is the first observation of
everything below at once — which also means a failure in it does not immediately say
WHICH version introduced it. Check `plugin_version` first; then read the list as
candidates, not as one suspect:
- Detail-prewarm queue throughput and restart/checkpoint behaviour on the real server.
- ~~**A fixed overnight clock.**~~ **PARTLY BUILT in 0.9.216, review fixes in 0.9.217 and 0.9.218** (the latter: a catch-up just before 05:xx folds into it) — the tick now fires at a
  fixed 05:00 LOCAL (plus a stable per-install jitter) rather than 24 hours after startup,
  and a restart no longer re-runs a warm that already ran today. **Unbuilt:** §4C (the
  `$detailMainReady` watchdog), §4D (`next_tick_at` in `warmstats`) and §4E (the convergence
  follow-up tick). **DECLINED:** §4G, the nightly sort-name stage — the MusicBrainz sort-name was dropped 2026-09-14.
  **NOT VERIFIED LIVE**, so `docs/overnight-detail-prewarm.md` keeps its "Still open" line
  until §7 of the plan passes on the real server.
- Adaptive artwork priority, the explicit release actions, generation-backed reuse and
  the indexed week-summary navigation.
- Whole-pass limits, including Last.fm's 400-artist cap, as part of durable queue
  draining. The plan does not yet promise every new release is prepared.

**Designed or scoped, genuinely not started.**
- **A building row for For You** — the only unbuilt part of the artwork plan's Stage 2.
  `_buildingRow` exists and serves the playlist and follower paths.
- **`docs/album-title-search-leg.md`** — a port from PFR 0.7.12, not a design exercise.
  Verified still unbuilt: the auto-resolver searches the ARTIST only.
- **`docs/year-in-music.md`**, **`docs/recommended-listening-row.md`** — both untouched.
- **`docs/token-free-refactor.md` §3.2/§3.3** — rebuilding Recommended on public
  loved-tracks/pins, and the volume decision it depends on.
- ~~**`docs/lastfm-key-bundling.md`**~~ — **BUILT 2026-09-14** on Simon's go-ahead as
  0.9.213, review fixes in 0.9.214 (installed; key + POST proven live, error 6 and the latch
  not yet exercised live — Ledger §C `CLOSED IN 0.9.214`). Read its "As built"
  section: POST-only transport, the rejected-key latch, no manual key, and failures
  (but not error 6) no longer stored as empty answers. Guard: `tools/t_lastfmkey.pl`.

**Merge-gate debt.** `main` is at 0.9.149 and `dev` at 0.9.210. The CHANGELOG and README
are owed for that whole gap, plus **a credit line for honzup** (PR #17's own CHANGELOG
hunk was deliberately not taken) — **README half DONE 2026-09-15** (Credits section, linking
honzup and PR #17, ahead of the 1.0.0 Lyrion submission); the CHANGELOG line is still owed and
goes in the 1.0.0 entry when it is written — and **`GENRE_FACT_VERSION` is deliberately NOT bumped
for the 0.9.194 `_norm` change** — an explicit parser-version decision, recorded in
Review Ledger section B, that must not be hidden behind a plugin-version bump.

**PR #17 (Spotify via Spotty) is CLOSED as work.** The adapter is applied, committed as
`c68cbb1` and built into 0.9.187, and the reply to honzup is posted — Simon confirmed
2026-09-10, settling a disagreement between the two PR docs that could not be resolved
from inside the repo. `docs/spotify-spotty-pr17-reply.md` is now a record, not a task.
Only the CHANGELOG credit line remains, and it belongs to the merge gate above. The PR
stays OPEN on GitHub as a mechanical consequence, since its `Closes #17` only fires on
`main`.

- **Detail-page tracklist paging — OPEN, deliberately deferred (Simon, 2026-08-05: "leave it open,
  may address later").** The release detail page emits one text row per TRACK, so a release with
  roughly **85+ tracks** crosses Material's 100-item threshold on its own and enters the fixed-48px
  virtual scroller, where the tall bio row (and any other row that wraps past one line) is drawn over
  the rows below. Fix = page the tracklist with the existing `_pageSection`/`_pageRow`. Full reasoning
  and the item_id caveat are in the **0.9.152** Version History entry; the Material mechanics are in
  [[material-prose-row-layout]]. Not a regression — 0.9.152 removed the bio's ability to cause this,
  leaving only genuinely huge releases.
- **CHANGELOG has no entries for 0.9.120–0.9.125.** 0.9.120 shipped as a commit (the fleet
  matcher sync) with no changelog block; 121–125 have none at all. Not reconstructed — the
  record is genuinely missing, so don't invent it, and don't be surprised by the gap.
- **DONE (see "Cover art" under Fixes on top of 0.9.174) — the Cover Art Archive image-proxy
  handler asked for the SMALLEST image when the skin asked for the LARGEST.** Kept here for the
  mechanism, which is a fleet-wide trap: `getRightSize` returns the value of the smallest key
  **>=** the requested dimension and **undef when nothing is big enough**, so a
  `|| '<smallest>'` fallback fires precisely on the BIGGEST requests. The table now reaches
  `1200 => '1200'` and falls back to the largest option. CAA serves `front-250` (8.8KB),
  `front-500` (18KB) and `front-1200` (77KB) — measured live. **Still true and still not
  changed:** the block ends `} if preferences('server')->get('useLocalImageproxy');`, which
  reads as "only when local proxying is on". That pref is not a boolean — it is the image-proxy
  SELECTOR behind Settings → Performance (`1` = local, `2` = helper, or an external proxy's id;
  `Slim/Utils/Prefs.pm` defaults it to `main::ISWINDOWS ? 1 : 2`), and a registered `match`
  handler is consulted regardless of it (`ImageProxy::getImage` → `getHandlerFor`; the pref is
  read only when picking an EXTERNAL proxy). So the gate is truthy on every default install and
  the handler does run — it is misleading, not broken.
- **Discography carries the same wide-character cache bug fixed here in 0.9.141**, in FOUR
  places: `Discography/Browse.pm` ~1159 (`$text`, artist bio), ~3240 (`$desc`, review
  description), ~3270 (`$text`, MAI album review) and `Discography/API.pm` ~705
  (`$canonName`, MB canonical artist name). All bare-string `$cache->set` calls. It is NOT the
  shared matcher, so the hold above doesn't apply. **The helpers to port are GONE from LBF as of
  0.9.186** (removed with `getArtistBio`, their last caller) — carry the PATTERN, not the sub
  names: `set` a `{ t => $text }` hashref and read `ref $c eq 'HASH' ? $c->{t} : $c`, which
  Storable-encodes on the way in and still reads a legacy bare string.
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
**`tools/t_loads.pl` — RUN THIS BEFORE EVERY BUILD, and run it against the ZIP**
(`LBF_PLUGIN=<extracted>/ListenBrainzFreshReleases perl tools/t_loads.pl`). It compiles each
module in its OWN fresh interpreter with only LMS stubs present, which is the condition LMS
imposes and the one every other suite hides by loading its subject with the rest of the plugin
already in memory. **0.9.166 shipped a plugin that would not load at all** — a bareword
reference to `DB::KEY_VERSIONS` is resolved at COMPILE time, before the runtime `require`
three lines above it has run, so `use strict subs` killed the whole module: no menu, no feeds,
no settings, and a log line naming a constant. **The failure was seen during that build and
explained away** (`perl -c` failed alone, passed with `DB.pm` preloaded → "production must load
DB first"; it does not). Use `Other::Package->CONSTANT`, never `Other::Package::CONSTANT`.
`tools/bench_walk.pl` (per-walk render cost + the memo assertions), `tools/t_cache_widechar.pl`
(the DbCache bare-string bug, reproduced against real DBD::SQLite),
`tools/t_ll_handshake.pl` (the `&rt=` release-type handshake, driven from BOTH repos' live
source), `tools/t_review_fixes.pl` (the three 0.9.141 pre-release review defects — bcmatch bump,
MuSpy memo on Refresh, empty week under the family lens), `tools/t_trending_empty.pl` (the
0.9.149 empty-aggregate TTL + the Refresh row on the empty Trending Albums view;
`LBF_BROWSE=` points it at a mutated copy for anti-testing), `tools/t_diag.pl` (the connectivity
diagnostic — probe coverage, answered-vs-unreachable, the semantic checks, redaction and the
deadline; `LBF_DIAG=` points it at a mutated copy), `tools/t_db.pl` (the plugin-owned SQLite
store, against a REAL file in a tempdir — persistence proved CROSS-PROCESS, the kv
0/''/undef distinctions, wide chars both sides, non-UTF-8 blob bytes, the 90-day
round-trip, prefix retirement, explicit derived/genre resets leaving durable tables alone, and
degrade-never-die; `LBF_DB=` points it at a mutated copy), `tools/t_ttlceiling.pl` (no
TTL handed to `Slim::Utils::Cache` may exceed 2,592,000 — reproduces LMS's own rule
first, so a guard set to the WRONG number fails before it can pass vacuously),
`tools/t_coverwarm.pl` (the CAA size table, the ladder's url rewrite + the cover pre-warm —
the warmed path must equal what Material requests, down to the EXTENSION, which decides
whether the proxy caches JPEG or re-encodes every cover as PNG;
`LBF_PLUGIN=`/`LBF_BROWSE=`/`LBF_API=`/`LBF_DB_SRC=` point it at mutated copies;
**§4e (0.9.207) is the FOR YOU focus map** — that level draws a divider before every
week and re-sorts inside each, so Material's row index is NOT a release position, and
every assertion there is paired with the item `_buildWeekly` actually drew at that row.
Anti-tested three ways, each mutant failing only its own property),
`tools/t_detailwarm.pl` (the detail-prewarm queue and its job runner — and §8, the one
place that pins `_sectionBounds`: For You carries TWO sources on independent future
gates but both enqueue at priority 0, so eligibility takes the UNION of the For You and
MuSpy windows. **Its `sectionWindow` stub is PREFIX-AWARE on purpose** — a single window
for every prefix cannot tell the union apart from the plain For You window, so a flat
stub passes against the defect. `LBF_BROWSE=` points it at a mutated copy, anti-tested
two ways),
`tools/t_statsratelimit.pl` (the follower stats burst — the shared backoff on `_getUserStats` and the serialised follower chain; `LBF_API=`/`LBF_BROWSE=` point it at mutated copies, anti-tested two ways), `tools/bench_store.pl` (the feed store's blocking cost — ingest and read, against real DBD::SQLite at a real feed size; RUN IT after any change to `ingestFeed`/`feedReleases`, and it is what set `INGEST_CHUNK`), `tools/t_ingestchunk.pl` (the chunked ingest's SAFETY property — rotation and coverage only on a complete pass, identical store either way, merge across a chunk boundary, synchronous refusal; `LBF_DB=` points it at a mutated copy, anti-tested two ways), `tools/t_warmstats.pl` (the warm-stage instrument — that it records the OVERLAP between stages and not merely their durations, and that the warm subs actually CALL it; `LBF_PLUGIN=`/`LBF_BROWSE=` point it at mutated copies, anti-tested five ways), `tools/t_feedsingleflight.pl` (the COLD feed path fetches ONCE however many browse walks arrive, AND — since 0.9.190 — that the WARM's `force => 1` bypasses both the memo and the store short-circuit so it warms what actually arrived rather than the stored copy, degrading to stored only when the fetch fails; `LBF_API=`/`LBF_BROWSE=` point it at mutated copies — behavioural, driven through a suspending HTTP stub because the property is "how many requests went out and who was called back", which no pattern match shows; also that BOTH outcomes fan out, that waiters get the same STRING shape as the primary on error, and that the key is the REQUEST (memo key + headers) so a token holder is never multiplexed onto an anonymous fetch. `LBF_API=` points it at a mutated copy, anti-tested five ways), `tools/t_buildingstate.pl` (the in-flight guard and the building row — that the flag is TAKEN before a fan-out, RELEASED on every exit via a single wrapper rather than at each of 8 returns, never released by a caller that did not take it, and that "building" is signalled as `undef` and never as an empty list; also that the feed chain's error paths all advance it and that `_warmTick` waits on its callback. `LBF_BROWSE=` points it at a mutated copy, anti-tested five ways), `tools/t_rgresolver.pl` (the hosted `/discography` release-group tier — that a hit returns a release-GROUP id and never asks MB, that it is ONE call per artist not per album, that `?mbid=` reaches BOTH cache keys, which of several same-titled groups wins, and that EVERY non-hit falls back to MusicBrainz; `LBF_API=` points it at a mutated copy, anti-tested five ways. **Its cache lever is `DB::store`, not `Slim::Utils::Cache`** — API.pm holds the plugin's own store, and a first cut that stubbed the wrong one failed ten assertions because nothing could be observed or reset between sections; the suite now dies loudly if the override is not in effect rather than running vacuous), `tools/t_weekwindow.pl` (the whole-week release window — that the edges are real Mondays and Sundays on EVERY day of the week and for every legal (past, future) pair; **the Friday test**, run across a real week, that a Friday release is still in scope on Saturday and Sunday with earlier weeks OFF and leaves on the next MONDAY rather than at midnight; that the four-week budget survives a hand-edited 52/52; that the derived LB `days=` never exceeds 27, is never 0, and reports `future=true` with zero later weeks; that the gate fallbacks in `%WEEK_GATES` are DERIVED from Plugin.pm's `$prefs->init` rather than restated; that the feed memo key has ONE builder both fetchers and both halves of `clearFeedCache` go through; and that the checkbox-coercion sentinel names a field `settings.html` actually posts. `LBF_API=`/`LBF_DB=`/`LBF_BROWSE=` point it at mutated copies, anti-tested three ways — a today-relative window, the sentinel left on `pref_days`, and `foryou_future` drifting back to `// 0`), `tools/t_matchersync.pl` (the FLEET MATCHER SYNC gate — the three Discography-origin rules
ported into LBF in 0.9.194: apostrophe elision + its `'n'` guard, the ~90-entry `%FOLD`, and
the compound-word collapse in `_albumMatches`. Every sub AND `%FOLD` are grabbed from the real
`Browse.pm`, never retyped, so a change to either fails here instead of passing against a stale
duplicate; `LBF_BROWSE=` points it at a mutated copy and each rule is anti-tested
independently — 7/8/3 red. Section 4 is LBF-only and covers `_trackMatches`, which no other
repo has and PFR's copy of this file therefore never exercises. It is the BEHAVIOURAL half of
the fleet rule; `matcher_sync_check.py` is the textual half, and both must pass),
`tools/t_coldwarm.pl` (the COLD-WARM NO-MATCH class — that a service answering with ZERO RAW
RESULTS is treated as inconclusive rather than "not in the catalogue", that the rule fires ONLY on
a no-match and never on Bandcamp, that the retry is a BOUNDED BUDGET which terminates, that the
entry keeps the FULL no-match TTL so the count survives to be spent, that a CONFIRMED miss is
durable at once, and that the warm waits for the streaming services without waiting for ever;
`LBF_BROWSE=`/`LBF_PLUGIN=` point it at mutated copies, anti-tested seven ways),
`tools/matcher_sync_check.py` (**exits 0 since 0.9.194** — the hold is over, so a non-zero exit
is real drift again).

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
  - Fixed at the boundary with **`API::_setText` / `_getText`**, which wrapped in a hashref so
    Storable handles any codepoint and hands the string back with its utf8 flag intact. Chosen over
    encode-on-write/decode-on-read: one place to get right, no mojibake risk, and `_getText` read a
    legacy bare string unchanged so **no cache prefix needed bumping**.
  - **BOTH HELPERS WERE REMOVED IN 0.9.186** — `getArtistBio` was their last caller (the sort-name,
    the other one, had moved to `DB::artistPut` when the store landed), so nothing in `API.pm` writes
    a bare string to the cache any more. **THE RULE OUTLIVED THEM and is kept at that spot in the
    file**, because it is about the next one: never `$cache->set($key, $some_string)` with text that
    came from an API — wrap it in a hashref, or put it in the store.
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

## GENRES — measured coverage & the plan (phases 1–3 DONE, phase 4 superseded — see the phase status below)

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

~~**Still outstanding on phase 1's cost story:**~~ **BOTH CLOSED, corrected 2026-09-10.**
`getReleaseGroupGenres` was **deleted outright in 0.9.185**, not made cheaper — the detail
page makes no per-album MB genre call at all now, and only a tombstone comment remains in
`API.pm`. `warmCache` does pre-fill the feed's genre cache, so a browse is a store read.

**PHASE STATUS, corrected 2026-09-10** — this line said "phases 2–4 not started" for six
weeks while two of the three shipped:
- **Phase 2 — the rollup table: DONE.** It ships as the generated data file
  `ListenBrainzFreshReleases/genre-families.txt`, built by `tools/make_genre_families.py`
  and loaded by `Browse.pm` (`$_GENRE_KNOWN`).
- **Phase 3 — Last.fm gated by the MB vocabulary: DONE.** Tier 5 is vocabulary-gated, and
  0.9.206 refined it further so tags are classified INDIVIDUALLY (`indie, usa` keeps
  `indie` instead of blanking the row).
- **Phase 4 — "Group by genre" as a fourth sort mode: NOT BUILT, and effectively
  SUPERSEDED.** `@SORT_MODES` is still `release_date artist album`. The in-view **genre
  picker** (a family FILTER, with its own durable `<prefix>_genres` pref) shipped instead
  and covers the same need from the other direction. Do not build the sort mode without
  first arguing why the picker is not enough.

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
  mbid we pass is honoured for the bio but not the photo) — bio AND photo. **MAI OR NOTHING
  since 0.9.186**: the Last.fm `getArtistBio` fallback is deleted (MAI's own sources already
  include Last.fm, and this population was never offered a photo either), so `$wantArtist` is
  gated on `_maiEnabled()` and the task is ABSENT from the render barrier without MAI rather
  than a slot resolving to an empty hash. Runs inside the detail-page async barrier; fully
  eval-guarded — no MAI = name + Block-artist only. INFO-logs MAI detection + photo count for diagnosis. `API::_cleanBio` uses
  Last.fm's FULL `content` (not the short `summary`), strips HTML/"Read more"/CC boilerplate, keeps
  paragraph breaks; capped only by `BIO_MAX`=20000 (DoS guard, never visibly trims). **`_cleanBio`
  and `BIO_MAX` STAY** — the MAI path runs its bio through them, which is why its HTML handling is
  tuned for MAI's runtime output ([[mai-bio-is-html-at-runtime]]) rather than Last.fm's. The
  `lbf:bio:` cache key family went with `getArtistBio` in 0.9.186; there is no bio cache any more,
  and with it goes the trap that key carried (it stored the CLEANED text, so it had to be bumped on
  ANY change to `_cleanBio`'s output or the old shape kept serving for the full 30d TTL and the fix
  looked unshipped). **If a bio is ever cached again, that rule comes back with it.**
- **Bio display — KEY Material fact, and the 0.9.150 correction.** A `type=>'text'` row renders its
  `name` IN FULL; Material has NO auto-collapse / "more" for plain text. So the preview must be
  **pre-trimmed** (`BIO_PREVIEW`=150 chars) — that part still stands, and don't "fix" it by putting
  the whole bio in one text row, which is the bug the preview replaced.
  - **What was WRONG here until 0.9.150:** this section used to claim "compact preview + expand MUST
    be a drill-in". It doesn't. **`nextWindow => 'refresh'` + an EMPTY response re-renders the
    current level**, which is all an in-place expand needs — the same mechanism the All Releases
    paging rows have used since 0.9.86, and which Discography uses for both its bio and its review.
    The drill-in was a limitation of the first implementation, not of Material.
  - **Now:** collapsed = preview + **Read more**; expanded = the full bio as **ONE `_proseBlock` row**
    with a `<div>` per block, + **Show less**. Read **0.9.152** for why it must be one row, not a row
    each — N prose rows each pay Material's 48px row-height floor AND can tip the level past
    `LMS_MAX_NON_SCROLLER_ITEMS`, into a fixed-height scroller that draws tall rows over each other.
    Read **0.9.153** for the block parser (`_bioBlocks`) — headings, bullets, and the ONE flag
    (`$wrapped`) any of it may depend on. **Before changing either, read the LIVE row and the LIVE
    source over JSON-RPC** — that is what found both 0.9.153 bugs after reasoning about the CSS did
    not. Both
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
    `lbf:summary:{user,all}`; before that, the whole-week window via `_windowSpan`, which asks
    `API::sectionWindow` rather than recomputing one) plus the release count
    (`PLUGIN_LBF_N_RELEASES`). Tracks the *Earlier/Upcoming weeks* settings automatically.
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

Seven sections in the settings page (General / Blocked Artists / Streaming Services / For You / All Releases / MuSpy / Connection Check). MuSpy is kept LAST **of the pref-bearing sections**, in its own section, so its prefs aren't confused with the ListenBrainz ones (0.9.81); Connection Check sits after it and holds NO prefs at all (0.9.158), so it doesn't reopen that confusion. Each is a
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
- `username` — ListenBrainz username. **This is the only required credential** (0.9.160)
- `token` — ListenBrainz API token, **OPTIONAL since 0.9.160**. It gates exactly one feature: the *Recommended* list under People You Follow (`/1/user/<u>/feed/events` is the only endpoint in the plugin that 401s anonymously). Every other LB endpoint returns a byte-identical payload with or without it — verified live, see `docs/token-free-refactor.md` §0. Still SENT on `fresh_releases` when set; `Settings::handler` still validates it on save
- ~~`lastfm_api_key`~~ — **REMOVED 2026-09-14 (working tree).** The field, its Check-key button, its strings and the pref are gone; the plugin uses ONLY its built-in key (`API::lastfmKey`, see `docs/lastfm-key-bundling.md` "As built"), and `Plugin.pm` deletes any stored value at startup. What the key does — **two roles as of 0.9.186** (it had three): the genre ladder's **tier 5** — filled by `_warmLastfm`, and the ONLY rung not derived from MusicBrainz ([[lbf-genre-sources-one-well]]), so it is what fills the lists and the detail page for brand-new releases; and **similar artists for the DSTM radio** when ListenBrainz's dataset has none. The third — the artist biography when MAI isn't installed — was removed in 0.9.186, as was the detail page's own second Last.fm tag call (tier 5 had already answered by then). Default empty = disabled
- **The release window is WHOLE MONDAY-TO-SUNDAY WEEKS (0.9.185).** It replaced a rolling `days`
  count (1-90, default 14) measured from today, which cut the current week in half: the UI renders
  `W/C <Monday>` rows, but the window's edges landed on arbitrary days, so with *Include earlier
  weeks* off the current week held only *today onwards* and **Friday's releases were gone by
  Saturday**.
  **SET PER SECTION SINCE 2026-09-14 (working tree, unbuilt)** — Simon: the old seven controls were
  "overly complicated", couldn't give All Releases a different window from For You, and "starting at
  week 0 feels wrong. Current week should always be 1". Now two number boxes in EACH of the For You
  and All Releases settings sections (the General section has none):
  - `<section>_weeks` — weeks shown **in total, the current week counted as 1** (1-4)
  - `<section>_upcoming` — how many of those are AFTER the current week (0 .. weeks-1)
  - defaults = what 0.9.185 shipped: `foryou_weeks` **4** / `foryou_upcoming` **2** (1 back + this +
    2 ahead), `all_weeks` **2** / `all_upcoming` **0** (1 back + this).
  - Counting the TOTAL makes the four-week budget a property of the input — `upcoming` is held to
    `weeks - 1`, nothing is trimmed off the other side. `API::clampSectionWeeks` is the ONE rule, on
    save (`Settings::handler`, via `->can`) and on read. Internally everything still uses a
    `(past, future)` pair, DERIVED as `past = weeks - 1 - upcoming`, `future = upcoming`, so
    `_feedWindow` / `_feedRequestDays` / `_feedMemoKey` / the store did not change.
  - **Retired, not migrated:** `weeks_past`, `weeks_future`, `foryou_past`, `foryou_future`,
    `all_past`, `all_future`, `muspy_future` (plus 0.9.185's `days`/`muspy_future_months`). They stop
    being read; `t_weekwindow.pl` §5 pins that a stale prefs.yaml value moves nothing.
  - **MuSpy has NO window of its own** — see the MuSpy settings below.
  - **`API::sectionWeeks($prefix)` is the only place these prefs are read** — `'foryou'` or `'all'`
    (there is no `'muspy'` prefix any more). It replaced
    ~12 duplicated `$prefs->get('days') // 14` + past/future sites that **disagreed**: `foryou_future`
    fell back to `// 0` in four of them and `// 1` in `warmFeeds`, so a warm and a browse asked
    ListenBrainz two different questions. `API::sectionWindow($prefix)` is the same thing as
    ('YYYY-MM-DD','YYYY-MM-DD') for `_windowSpan` and `_mergeMuSpy`. It lives in `API.pm` because
    `clearFeedCache` has to rebuild the identical memo key.
  - **`_feedWindow` reuses `DB::_weekStart`** (arithmetic-only, Monday-based, matching
    `Browse::_weekStart`) — there is no third week-start implementation.
  - **The LB `days=` parameter is DERIVED, never configured** (`API::_feedRequestDays`). ListenBrainz
    has no date-range parameter — both `fresh_releases` routes take `days=N&past=&future=` and answer
    SYMMETRICALLY about today — so a week-aligned window asks for the **wider of its two sides** and
    lets `DB::feedReleases` trim the rest on read. Worst case **27** days (3 weeks + 6), against the
    old ceiling of 90. Over-fetched rows on the narrow side are simply stored; nothing shows them.
    **`future` comes back true even when the user's later-weeks box is off**, because the current
    week runs to Sunday — that is intended, and it is the mechanism behind whole weeks.
  - **Migration: none.** Old `days` / `muspy_future_months` values are left in place and stop being
    read; their form fields are gone. **No `BASE_VERSION` bump** — the 0.9.166 store keeps releases
    permanently and the window is only a filter on the READ, so narrowing costs nothing and
    invalidates nothing (a bump would lose every older row for good; see `DB.pm`'s header).
  - **The `Settings.pm` trap.** `exists $params->{pref_days}` was the sentinel that says "this is a
    real form POST" and is what makes the checkbox coercion run at all. It moved to
    `pref_weeks_past`. Removing the field without moving the sentinel breaks **every** checkbox on
    the page silently: unchecked boxes store `undef`, which reads back ON through the `// 1` guards,
    so `all_past`/`foryou_past` become impossible to turn off. `tools/t_weekwindow.pl` §7 ties the
    sentinel to a field the template actually posts.
  - Gates relabelled: *Include Past/Upcoming Releases* → **Include earlier/later weeks** — their
    meaning shifted from "any past release" to "earlier whole weeks", since the current week is
    included either way.
- **Sort is per-view, not a global setting (0.9.97).** The old global `sort` radio (and the `group_by_artist` / `week_dividers` toggles) were removed. Each list has a **"Sorted by …" toggle in an Options section** cycling Release Date / Artist / Album Title:
  - **For You** is now ALWAYS weekly (W/C material headers, newest week first); the toggle sorts the releases *inside* each week and persists to the durable `foryou_sort` pref (default `release_date`; set only via the in-view toggle, not on the settings page — like `follow_sort`).
  - **All Releases** per-week views each carry the toggle, backed by a **single durable `all_sort` pref shared across every week** — set it once and every week honours it, and it survives restarts. (0.9.97 first shipped this as per-week module state; that was changed because opening a *different* week always started at the default, which read as "the sort keeps resetting".) Paging stays per-week module state (`%pageState`); only the sort is a pref now.
  - Feeds are always fetched with `sort=release_date` (stable cache key); all ordering is client-side (`_sortReleases` pre-sorts by date for week-bucketing, `_sortWithin` applies the per-view mode within each week). `group_by_artist`'s collapse was effectively dead anyway (the weekly branch always outranked it) — see the 0.9.97 changelog.
  - **Artist sort is A–Z on the display name (2026-09-14)** — the credit as the row shows it, lowercased, with a leading article skipped via LMS's own `ignoredarticles` list (`Slim::Utils::Text::ignoreArticles`), so "The Cure" files under C and "The The" under T. No MusicBrainz sort-name is fetched or stored, MuSpy's inline one is ignored, and opening an Artist-sorted view sends nothing anywhere. See Ledger §A2 `ARTIST SORT IS A–Z ON THE DISPLAY NAME`.
- **Release-family view is per-view too (0.9.124–0.9.128).** Each list has an **Albums / Singles & EPs toggle** — ONE cycling row, "Showing Albums (tap for Singles & EPs)", icon reflecting the current family (`_viewToggle`) — in its Options section (next to Sorted-by), backed by a durable pref set only via the in-view toggle (not on the settings page — like `foryou_sort`):
  - **For You** → `foryou_view`; **All Releases** per-week views → shared `all_view`. Both default `albums`.
  - `_viewFilter` partitions by PRIMARY type: `singles_eps` = primary Single/EP; `albums` = everything else. Applied AFTER `_filterSection`, so it NARROWS within the ticked type checkboxes. Nothing ticked is lost (non-single/EP types fall into `albums`). Home shelves are deliberately unfiltered.
  - **The toggle row appears only when the section has BOTH families ticked** (`_familyAvail`/`_effectiveView`, 0.9.126) — default Album+Compilation shows no toggle; a single-only section is clamped so it never renders empty, and since 0.9.127 the clamp is PERSISTED so a hidden pref can't lie in wait.
  - **One cycling row, not two rows and not header lozenges:** Material gives plugin feeds no way to lay rows out horizontally OR to add pill buttons to the header toolbar (`currentActions`/`isListItemInMenu` is native-library-menu or favorites_url-custom-action only — re-verified in `material-deferred.min.js` 2026-07-26). Two stacked rows cost a line of screen, so 0.9.128 collapsed them into one. See the Current Version note — **don't re-derive this**.
- `play_via` — show inline playable streaming matches on the detail page (default ON)
- `people_follow` — master on/off for the whole **People You Follow** browse section (What's Trending, both Trending Albums lists, Recommended); default ON (0.9.118). When off the section is absent AND its warm pre-build + unmatched-debug entry are skipped, so nothing there is fetched/cached/warmed
- `follow_sort` — People You Follow list ordering: `date` (day dividers, newest first) or `recommender` (grouped by the follower who recommended each track); default `date`. Flipped in place by the inline toggle at the top of that list, not shown on the settings page (0.9.88; toggle label made state+hint "Sorted by … (tap for …)" in 0.9.91)
- `prefer_library` — when building a Created-for-You playlist, use a track from the user's own LMS library (matched by MusicBrainz ID, then artist + title) before searching streaming services (default ON; see "Prefer local library")
- `warm_covers` — pre-warm the image proxy for each feed's cover art during the daily background
  warm (default ON). The proxy caches per SIZE SPEC, and the spec comes from the device, so without
  this every new device/view pays ~1.5-2s per cover to Cover Art Archive. Off = no background
  artwork traffic at all. See `Browse::_warmCovers` and the 0.9.174 fixes section
- `debug_log` — opt-in dedicated warm/resolve debug log (default OFF, 0.9.54). When on, `Plugin::dbg` appends the playlist warm/match timeline — incl. the per-playlist **library-match count** and scan-defers — to `lbf-debug.log` in the LMS log dir (`Slim::Utils::OSDetect::dirsFor('log')`, cachedir fallback), size-capped ~1 MB with one `.old` rotation. The same lines always also go to `server.log` at INFO. Turn on to diagnose a match/caching problem, off after.

### MuSpy Settings (own section, kept LAST — 0.9.81)
Grouped separately from the ListenBrainz prefs so the two aren't confused. All three drive `API::getMuSpyReleases` → `Browse::_mergeMuSpy` (For You feed only).
- `muspy_userid` — optional MuSpy (muspy.com) public user ID; folds that user's followed-artist releases into the For You feed. Public endpoint, no auth/password stored. Default empty = disabled
- ~~`muspy_future`~~ — **REMOVED 2026-09-14 (working tree), on Simon's call: MuSpy must never show anything past the four-week window, and must roll over exactly as the ListenBrainz feed does.** MuSpy rows are For You rows: they are windowed by `API::sectionWindow('foryou')` in `_mergeMuSpy`, there is no `'muspy'` prefix and `_sectionBounds` unions nothing (0.9.207's union is MOOT, not reverted — with one window for both feeds it IS the For You window). **What MuSpy can still do that ListenBrainz cannot** (checked in muspy's own source, `app/models.py` `ReleaseGroup.get`): its per-user query is `ORDER BY date DESC` with **no date bound**, so the top of our `?limit=100` slice is the furthest-out announcements. Those are still fetched and stored unwindowed (rotation off, 120-day `seen_at` retention) — they are simply never DISPLAYED beyond the window, and appear as the forward edge rolls on each Monday. The nightly MuSpy warm now prepares only the rows inside the window (`_filterForYou(_mergeMuSpy([], …))`); it used to warm covers and detail for every stored row, months-out announcements included
- `muspy_future_months` — **RETIRED in 0.9.185** (was 1-24 months, default 12; 0.9.80). MuSpy now rides the same whole-week window as everything else, so `_mergeMuSpy` carries no month arithmetic and `MUSPY_FUTURE_MONTHS_DEFAULT`/`_MAX` and `Browse::_dateShift` are gone. **This loses no far-out announcements:** MuSpy is fetched `?limit=100` newest-first, stored with `rotate => 0` and read back from the store **unwindowed** (`_feedFromStore($feed, undef, undef, 0)`), so an album announced three months out is fetched and HELD today — the week window only decides whether it is DISPLAYED, and each Monday the forward edge rolls on and it appears. Rows age out on `seen_at` in `DB::feedSweep` at 120 days, and upcoming releases sit at the top of MuSpy's newest-first list, so they keep being refreshed while they wait

### Blocked Artists Settings
- `blocked_artists` — arrayref of `{ mbid, name }`. Releases by these artists are hidden from EVERY feed (For You / All Releases / home shelves via `Browse::_filterSection`, and since 0.9.111 the whole People You Follow section via `_trendBlocked`) by `_isBlocked` (matches any blocked `artist_mbids` OR normalised credit name). No ListenBrainz API exists for this — the `fresh_releases` endpoint takes only date/sort params and the feedback API is per-recording (love/hate, `score 1/-1`) and isn't consumed by the feed — so it's a purely local, render-time filter (takes effect on next browse; no feed-cache clear). Added from a release detail page's **"Block this artist"** link (`Browse::_blockArtist`); VA is never offered (would hide unrelated compilations). The settings section lists each blocked artist with an Unblock checkbox (`lbf_unblock_<i>`); `Settings::handler` removes ticked entries on save (the pref is NOT in the `prefs()` list, so it's mutated directly).

### Streaming Services Settings
- `svc_priority_<qobuz|bandcamp|tidal>` — search priority per service (number 0–9; lower = searched first, **0 = never search it**). Search stops at the first service that matches. Drives BOTH album play-via and playlist track matching. The page lists each known service as detected/not installed via `Browse::serviceStatus`.

### For You Settings
- `foryou_weeks` — weeks shown in total, **the current week counted as 1** (1-4, default **4**); `foryou_upcoming` — how many of those are after the current week (0 .. weeks-1, default **2**). So the default is last week + this week + the next two. Replaced `foryou_past`/`foryou_future` (and the shared `weeks_past`/`weeks_future`) 2026-09-14 — see the release-window bullet under General Settings. MuSpy rows ride this window
- `foryou_artwork_only` — hide releases without artwork (default ON)
- `foryou_various` — include Various Artists releases (default ON)
- Type checkboxes (`foryou_type_<name>`) — same set as All Releases; default ON: Album, Compilation. Default OFF: everything else. (Replaced the old single `foryou_albums` toggle in 0.6.15.)

### All Releases Settings
- `all_weeks` — weeks shown in total, **the current week counted as 1** (1-4, default **2**); `all_upcoming` — how many of those are after the current week (0 .. weeks-1, default **0**). So the default is last week + this week, no upcoming. **This is the point of the 2026-09-14 change: All Releases can now be windowed differently from For You**, which the shared `weeks_past`/`weeks_future` pair made impossible. Replaced `all_past`/`all_future`
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

> ### ✅ THE HOLD IS OVER — `matcher_sync_check.py` EXITS 0 AGAIN (LBF 0.9.194, 2026-09-02)
>
> The 2026-07-29 hold (Discography's matcher mid-rework, DSC deliberately ahead) was **lifted
> by Simon on 2026-08-29** — *"work on Discography is on hold so updates to that have stopped,
> now is a good time to update the fleet"* — and the sync ran **repo by repo** at his
> instruction: **PFR 0.9.33** took the three DSC-origin rules, **LBF 0.9.194** is this one.
> DSC, PFR and LBF are now byte-identical on all nine shared subs.
>
> **A non-zero exit is NO LONGER the normal state. Treat one as real drift again.**
>
> The three rules that came across, each pinned by the field failure that motivated it:
> 1. **Apostrophes ELIDE** rather than becoming a space (DSC 0.44.26) — spacing keyed
>    "Jane's Addiction" as `jane s addiction` against `janes addiction`, and `_artistMatch`
>    is an exact-token SUBSET test behind a MANDATORY artist gate, so the act matched nothing
>    from any source. The `'n'` contraction is guarded (it joins two WORDS) so
>    `Rock'n'Roll` / `Rock 'n' Roll` / `Rock N Roll` keep agreeing.
> 2. **`%FOLD` 10 → ~90 entries** (DSC 0.44.26) — extended-Latin and IPA letters survived NFD
>    as themselves and then met `[^\p{Alnum}]` as ordinary alnum characters.
> 3. **Compound-word collapse in `_albumMatches`** (DSC 0.50.6) — MB "England's Newest Hit
>    Makers" vs the services' "…Hitmakers". EXACT space-collapsed equality, never a prefix.
>
> **SEARCH HUB IS EXCLUDED AND PINNED, DELIBERATELY** — Simon, 2026-08-29: *"ignore Search Hub
> from any changes, it's on hold with no development."* It keeps the pre-sync `_norm` and the
> 10-entry `%FOLD`. It is **pinned in `VARIANTS`, not removed from `REPOS`**, and that
> distinction is load-bearing: dropping it would silence the alarm for good, so a later edit
> there could drift unnoticed and search would start disagreeing with the matcher about what
> "the same name" means — the exact failure SH was added to this rule to prevent. **If SH is
> ever unfrozen, take the fleet copy and DELETE its two pins rather than re-pinning them.**
>
> The old `_norm` "!"-fold gap referenced here is **CLOSED** (fleet-wide, 2026-07-21) — see
> [[norm-exclamation-fold-hole]]. It is not outstanding work.


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
conscious re-pin (`--print-hashes` prints current hashes).

> **THE CHECK ONLY SEES SUBS THAT ARE IN ITS `SUBS` LIST, AND A DELEGATE IS INVISIBLE — this
> cost two separate holes and the second was found on 2026-09-10.** LL's normalisers are
> assembled from parts, so its `_norm` BODY can stay byte-identical while its actual fold
> changes completely. `_punctPass` was added at LL 0.1.145 for exactly that reason; **the same
> pass left `foldLatin` unwatched**, which is where LL keeps the UTF-8 decode, the `lc`, the NFD
> diacritic strip, the loop that APPLIES `%FOLD`, and **both apostrophe rules — fleet rule 1**.
> `%FOLD` (the table) was compared; the code applying it was not.
> **MEASURED, not suspected:** deleting the apostrophe elision from `foldLatin` moved NONE of
> the four pins that could plausibly have caught it (`LLDB::_norm`, `%FOLD`, `LL::_norm`,
> `LL::_punctPass` — all byte-identical before and after) and the check **exited 0**. Both
> `foldLatin` and `Sources::_fold` are now in `SUBS` **and pinned**, because a single copy is
> never compared and so earns its alarm from the PIN, not from being listed. Anti-tested both
> ways: deleting the apostrophe rule → 1 red on `foldLatin`; degrading `_fold`'s `->can` miss
> branch to a bare `lc()` → 1 red on `_fold`; each mutant failing only its own pin.
> **The general rule: if a watched sub DELEGATES, the delegate needs its own entry, or the
> check reports "in sync" about a body that no longer decides anything.** After aligning: bump every touched
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
2. **Query encoding differs** (`query_enc`): Qobuz + Tidal + **Spotify** want a CHARACTER string,
   Deezer + Bandcamp want BYTES. Feeding octets to the character camp double-encodes accents →
   junk/0 results (fixed 2026-07-10; LBF carries `query_enc`/`qChars`/`qBytes` in
   `_findPlayable`/`_findPlayableTrack`). Spotty escapes with `uri_escape_utf8` in
   `API::_prepareCall`, which is what puts it in the character camp.

**SPOTIFY/SPOTTY IS THE EXCEPTION TO MOST OF THIS SECTION** (0.9.187, LBF only). It is an older,
independent codebase: `getAPIHandler` is a **class** method, the renderers live in `OPML.pm`, the
search key is **`query`** (not `search`) with a **singular** `type`, and results come back
**already normalized** as a bare arrayref. Its Pipeline also **swallows API/auth errors into an
empty arrayref**, so an outage is genuinely indistinguishable from a clean miss at that layer —
accepted, with nothing better reachable through Spotty's public surface. Two behaviours that bite
only here — signed-out being PERMANENT, and EPs typed as `single` — are written up in full under
0.9.187 in "Current Version"; read that before touching `_searchSpotify`.

**HOW TO DEBUG A SEARCH (the canonical method — stop trying variants each session):**
1. `["pref","plugin.listenbrainzfreshreleases:debug_log","1"]` (via jsonrpc).
2. Fire the feed once (Material, or a jsonrpc menu query with a player MAC from `["players",0,20]`).
3. **Read the log over HTTP:** `curl -s http://plex:9000/log.txt` and grep the plugin prefix — the
   key line names each service's pool size + samples. Empty pool = service search returned nothing
   (encoding/availability); healthy pool + no match = matcher gap (`tools/match_check.py`).
4. Turn `debug_log` back off. Test the MB mirror directly with a `curl` to `plex:5000/ws/2/…`
   ([[mb-mirror-search-index-gotcha]]); test the library with `["artists",…,"search:NAME"]`.

## Version History → `docs/VERSION-HISTORY.md`

**Moved out of this file 2026-09-10.** It was 1,282 lines and pushed the Review Ledger past
the point where a review could hold this file in context. Nothing reads it automatically.
Append new per-version entries there; user-facing notes still go in `CHANGELOG.md`.
