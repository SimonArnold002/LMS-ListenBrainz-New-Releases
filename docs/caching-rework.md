# LBF — caching rework and the MusicBrainz retreat

**Status: IN BUILD.** Investigated and designed 2026-08-12/13; build started 2026-08-13.

| stage | state |
|---|---|
| 1 — `DB.pm`, schema, `kv`, sweep, `retirePrefixes`, `["lbf","cachestats"]` | **DONE** (0.9.164) — nothing read it yet, behaviour byte-identical |
| C — **hosted artist genres** (§2.4.1) | **DONE** (0.9.165) — reached stage 4 early: stage 1 already shipped the `artist` table, so this tier persists there (`genres_src='hosted'`) without waiting for the rest of the FACTS migration |
| B — **429 backoff + warm pacing** (§2.4.2) | **DONE** (0.9.165) — brought forward from stage 5; the widened warm is 66 batches, so exhausting the window went from possible to certain |
| 2 — derived layer → `kv` | **DONE** — done as ONE move, not one prefix family per commit; see below |
| 3 — the durable three rescued | **DONE** — `bandcamp_pin` + `follow_item` tables, sort-names onto `artist`, and a LAZY legacy import (also below) |
| 4 — FACTS tables | **DONE** — `release_group` + `recording` live, one shared implementation with `artist` |
| A — the two over-boundary TTLs (§2.4.6) | **DONE, properly.** 0.9.164 capped both at `30 * 86400`; they are now `RECMETA_AGE` / `AGEN_FOUND_AGE` compared against `fetched_at` in Perl, so the defect is **inexpressible** rather than corrected, and 90 days means 90 days again |
| 5 — feed **ingest** | **DONE** — `release`/`feed_member`/`feed_day`/`feed_meta` fill on every fetch, with `BASE_VERSION`, window-scoped rotation and the refuse-an-empty-ingest branch |
| 6 — **flip the read** | **DONE** — done in the SAME build as 5, deliberately; the `…fb:` twins are gone from the release feeds. See correction 4 |
| 7 — dev-build wipe, warm ahead of the username gate | **DONE** — `_buildChanged` (marker in a PREF, not in `kv`), `Browse::warmFeeds`, `DB::feedSweep` on the warm tick |
| 8 | deferred, as planned — gated on `bench_walk.pl` numbers |
| D, E, F | not started |

**MuSpy was absent from this plan entirely, and it does not fit the model in §2.2.**
Recorded here because the omission was not obvious: `getMuSpyReleases` fetches
`?limit=100` — a **top-N slice, not a window**. So `feed_day` coverage for it would be a
LIE (a day inside the range can hold releases that simply fell outside the 100), and
§2.2's window-scoped rotation would **delete rows that are still perfectly valid**, merely
pushed past the limit. That is this repo's "an empty result is never a fact" rule
(0.9.119, 0.9.149) arriving from a third direction: *a truncated list is not proof of
absence either*. MuSpy is therefore stored as a feed with `rotate => 0` whose freshness is
the age of the last answering fetch alone, and whose rows age out on `seen_at` in the
sweep. It earns a place in the store rather than staying in `kv` because its window is the
`muspy_future_months` pref — up to **24 months**, against the LB feed's 90-day maximum —
so it is the case where a window change most needs to be free.

**Corrections from the build, worth carrying.**

1. **Stage 2 was not done "one prefix family per commit", and the plan's reason for that
   sequencing did not survive contact.** The staging exists so each family can be verified
   alone — but the moment ANY read moves off `Slim::Utils::Cache`, every family it did not
   move is still being written to a store nothing reads. A half-moved plugin is not a
   bisectable state, it is two stores with one set of keys. So the handle moved instead:
   `DB::store()` returns an object answering `get`/`set`/`remove`, and the ~120 call sites
   were **deliberately not touched**. A 120-site mechanical rewrite is exactly where a
   transposed argument hides, and the call sites were never what was wrong.

2. **The legacy import has to be LAZY, and that is a property of the source rather than a
   convenience.** `Slim::Utils::Cache` **cannot be enumerated**. There is no way to ask it
   for every `lbf:bcmatch:` key it holds, so an eager import must guess the ids — which
   means the ids in the current feed window, which is precisely the set that does NOT
   include the old hand-pinned Bandcamp-only album somebody cares about. Asking for a
   specific id at the moment something wants it has no such blind spot. It is bounded by a
   DEADLINE (`IMPORT_WINDOW`, 180d) rather than a "done" flag, because a lazy import is
   never finished. The deadline itself is a **pref**, not a `kv` row: the dev-build wipe is
   one unconditional `DELETE FROM kv`, so a deadline kept there is deleted by every build
   and re-minted 180 days out on the next miss — a window that can never elapse, and so an
   extra `Slim::Utils::Cache` read on every store miss for ever.

3. **§2.3's "`lbf:rggenres:` is deleted, one caller remains and it is superseded" is WRONG,
   and the plan pre-dates the code.** `getReleaseGroupGenres` is the detail page's
   unconditional MusicBrainz last resort *behind* the hosted tier, added in 0.9.163 — it is
   the only tier that can answer for a release too new for the hosted dataset. Deleting it
   would be a regression. It is now a properly versioned family instead (it had no version
   at all), and its natural home is the `release_group` table in a later pass.

**Three more, from the 0.9.166 genre regression. All of them mine, and the first cost two
installs and a day.** (NB: the corrections numbered 4–7 here after the stage 5/6/7 build —
the fresh_releases day-range finding, the stage-5/6-must-be-one-build note, the Refresh
change and the vacuous-rotation-assertion note — are **no longer in this file**; it was
rewritten on disk 2026-08-13 19:52 and they went with it. They are recoverable from that
session if wanted.)

4. **A FACT ROW CAN BE FRESH FOR ONE QUESTION AND EMPTY FOR ANOTHER, and §2.3's genre wipe
   collided with exactly that.** `getReleaseGroupMetadata` carries `inc=release_group tag`,
   so one request answers the DATE and the GENRES — but freshness was judged on the date
   alone (`length(year) && _factFresh(…, RECMETA_AGE)`). `wipeGenres` nulls the genre columns
   and deliberately leaves `fetched_at`/`year` alone, because otherwise a parser change would
   re-inflict a date refetch across the whole feed. Put together: every wiped row still
   looked fresh, so its genres could not be re-asked for **ninety days**. Live store after
   two 0.9.166 installs: **0 of 1034 release groups holding a genre, 1033 marked never-asked,
   and no ListenBrainz traffic attempting to repair it** — while the hosted tier, whose
   freshness check reads the genre column itself, refilled normally. Fixed by treating "no
   genre answer on record" as a miss: `_factGet` returns a NULL blob as `undef` and a stored
   empty list as an arrayref, and `_mergeReleaseGroupMetadata` always sets `genres`, so
   "asked, and LB had no tags" is recorded and never re-asked. **The general rule for
   anything reached by a multi-answer request: judge freshness per ANSWER, not per ROW.**
   `artist.sort_name` rides the same shape — and `sort_at` is now READ, not merely written
   (that was the bug: `fetched_at` moved whenever any tier touched the row, so a recorded
   "MB has no sort-name" had its clock reset nightly and was never re-asked).
5. **§2.4.1's "it fills the same background top-up `_kickGenreFill` already runs" was never
   implemented.** That sub called `_withGenres` alone — the ListenBrainz tier — and never
   reached the hosted one, so between nightly warms the top-up could only repair the source
   covering ~48% and left the ~43% of the remainder waiting. Now chained in ladder order,
   hosted second, so it asks only about what LB could not answer.
6. **`cachestats` was measuring a column with no writer.** `rg_genres` counted
   `release_group.genres_src <> ''`, and **nothing in the plugin writes that column** — the
   figure was 0 by construction, not by coverage. On `artist` only the hosted tier and the
   mirror path set it, so ListenBrainz's own artist tags were invisible there too. For most
   of a day it read as evidence about the store when it was only evidence about the schema,
   and it is why the regression was misdiagnosed twice before the counters were replaced with
   have/none/never per tier. **An instrument gets its own assertion, or it is decorative.**

**One correction to a claim made in that session, not to this doc.** The Community API does
**not** answer for more of a fresh-releases feed than ListenBrainz does; §2.4.1's measurement
stands (LB ~48%, hosted ~43% **of the remainder**), and the live warm agrees — 400 artists
asked, 177 answered. Related, and worth stating plainly because it keeps being misread:
**there is no MusicBrainz tier in the default genre ladder at all.** `_genreLookupMode` takes
the mirror path only when `hasMirror()` is true, so on any install without a local mirror the
ladder is LB → Community API → Last.fm, and MusicBrainz is only what the hosted routes fall
back to when they cannot be reached.

**A defect the new tests caught that review did not**, and it is the reason the FACTS
tables share one implementation rather than being written three times: the alias mapping
that lets a caller read `release_group_mbid` where the column is `rg_mbid` was inverted on
the read side, so it **clobbered the real column with `undef`** — silently emptying the
track→album join the whole Trending path depends on. `perl -c` cannot see it, and neither
could a reader. One round-trip assertion per table found it immediately.

**The 0.9.165 build did not follow the plan's order, and the reason is worth keeping.**
The plan sequences C and B behind stages 4 and 5. What forced them forward was a field
report — "genres only show after going in and out of a release" — and the diagnosis has
three parts, only one of which was in the doc:

1. the TTL bug meant nothing the warm found ever persisted (§1.1, fixed 0.9.164);
2. **`GENRE_WARM_MAX` = 600 against a 3,255-release feed**, so ~80% of All Releases was
   never warmed at all and could only fill from a background top-up, two minutes at a
   time. The cap was *concealing* the TTL bug rather than protecting anything — before
   persistence worked, warming more just re-fetched more;
3. **the For You genre warm still demanded a TOKEN**, four releases after 0.9.160
   established `fresh_releases` never needed one.

Widening the warm makes B mandatory (66 batches into a 30-per-10s window) and makes C
worth having (at ~52% LB coverage, a fully warmed feed still leaves half the rows bare).
So the three are one build, not three.

**A measurement that corrects §1.3 and §2.4.1.** Taken against the live API 2026-08-13:
LB answers **6% release-group + 46% artist** (the doc says 5% / ~48%), and the hosted
artist route has a **median of 0.08s, not 160ms**. Also, `genres => []` (Panda Bear) is a
DIFFERENT answer from an absent key (Radiohead) — the doc treats absence as the only miss
shape. Both are stored, or the warm re-asks for the ~half of artists that will never
answer.

**A hazard the plan did not anticipate, caught by `bench_walk.pl` rather than by review.**
The obvious implementation of a name-keyed tier reads the store per release. That is one
synchronous SELECT per row — ~2,900 on the genre picker's whole-feed pass — i.e. exactly
the blocking work 0.9.130 moved off the render path. The tier now arrives through the
render's existing `$meta` map from ONE bulk read, and `_genresFor` reads no store at all.
Any future per-row tier must do the same.

**Landed in stage 1, beyond the plan.** `wipeGenres` (the FACTS half of the dev-build
wipe, §2.1 decision 3) is written and tested now rather than at stage 4 — it is one
`UPDATE` per table and testing it beside `wipeDerived` is what pins decision 3's
property (that a genre change must NOT cost the sort-names).

**Two things the plan asserted that the build measured differently**, both recorded at
their sites:

- **The `SQL_BLOB` bind (§2.2) is not the silent-corruption guard the plan said it
  was.** Measured on DBD::SQLite 1.64: an untyped bind returns the same BYTES but with
  the **utf8 flag set**, and a typed bind of an unfrozen wide string **dies** where an
  untyped one accepts it quietly. So the guard buys flag-provenance and a loud failure,
  not byte integrity. `t_db.pl` asserts the flag, because that is the only part
  observable — the first version of that section passed against a mutant with the bind
  removed, which is exactly the vacuous coverage this work exists to stop.
- **`RECMETA_TTL`'s blast radius was understated.** §1.1 records it as the recording
  cache; the same constant is applied by `getReleaseGroupMetadata`, which is where the
  genre damage actually came from.

**Two defects in the built store, found by the 0.9.174 pre-release review** — both in
stage 5 (§2.2 ingest), both invisible to every existing test because neither is a
compile break and neither raises:

- **The window widening was driven by UNVALIDATED payload dates, and `_dayRange`
  refuses SILENTLY.** `_ingestFeed` widened `from`/`to` from each release's
  `release_date` with only a format check — which `2099-01-01` passes. One such row
  pushes the span past `WINDOW_MAX_DAYS` (800), where `_dayRange` returns an **empty
  list** rather than raising, so **no `feed_day` row is written for any day**. Coverage
  can then never complete, every open sees a gap and revalidates, and the whole point of
  §2.2 — "stored and fresh → serve from the store, NO HTTP AT ALL" — is lost for that
  feed, permanently and with nothing in the log. The same widened window is also the
  **rotation scope** of RULE 2, so an outlier widens what may be deleted. Bounded in
  0.9.174 by `WINDOW_SLACK_DAYS` (180) plus a hard fallback to the requested window;
  outliers are still stored, they just cannot define the day range. **The general
  lesson for this store: a bound that fails by returning nothing needs a caller that
  checks, or it is a silent data-loss path rather than a guard.**
- **`_execBlob` prepared a statement per call.** `ingestFeed` calls it once per release
  inside one synchronous transaction — **~3,255 prepare/execute cycles blocking the
  event loop inside an HTTP callback**, which is the same class of hazard as the
  per-release SELECT caught by `bench_walk.pl` above, at twenty times the scale that
  prompted `GENRE_FETCH_MAX`. Now `prepare_cached`. The ingest path was reviewed for
  bind positions and merge rules and not for **statement lifetime**, which is the gap
  worth remembering: the plan's per-row concerns were all about correctness of the
  value, none about the cost of getting it there.
**What it is:** replace `Slim::Utils::Cache` with a plugin-owned SQLite store modelled on
LMS-Pitchfork-Reviews' `DB.pm`, so the All Releases base stops being re-minted at every local
midnight — and, in the same build, retreat from MusicBrainz on the paths that no longer need it.
**Why now:** two silent bugs found live (§1.1, §1.2) that between them explain both "the latest
build is sluggish" and "artist genres aren't populating".

Session record. Everything below was verified live against the running server
(`http://plex:9000`), the ListenBrainz and LMS-community APIs, and the working tree at 0.9.163
(uncommitted). Part 1 is what was found; part 2 is what to build.

---

# PART 1 — FINDINGS

## 1.1 Genres have never worked, and the cause is a silent LMS storage bug

`RECMETA_TTL => 90 * 86400` (`API.pm:1079`) is 7,776,000 seconds. LMS's
`DbCache::_canonicalize_expiration_time` treats any TTL over **2,592,000** as an *absolute Unix
epoch*, not a duration:

```perl
# "If value is less than 60*60*24*30 (30 days), time is assumed to be
# relative from the present. If larger, it's considered an absolute Unix time."
if ( $expiry <= 2592000 && $expiry > -1 ) { $expiry += time(); }
```

So the entry is written expiring **1 April 1970** and every read returns `undef`. `set` returns 1,
nothing dies, nothing warns.

`lbf:rgmeta:` applies that TTL to any release group **with a date**, and 1 day to dateless ones —
so the entries worth keeping are precisely the ones discarded. Verified on three live rows:

| row | release-group date | TTL applied | readable |
|---|---|---|---|
| NCT 127 – BLINGY | 2026-08-24 | 90d | never |
| Davenki Pi Wiart – Trama De Luz | 2026-08-25 | 90d | never |
| Jonathan Bree – Don't Call It Love | 2026-08-26 | 90d | never |

Consequences, all observed: the ListenBrainz genre tiers (album genres, artist genres) have never
once served a dated release; every genre label seen on screen came from the feed's inline
`release_tags` or from Last.fm; the background top-up re-fetched the same releases on every single
visit because nothing ever persisted; and "Pop (k-pop)" appeared on NCT 127 only *after* opening
its detail page, which warmed the separate Last.fm cache.

`AGEN_FOUND_TTL => 90 * 86400` (`API.pm:1978`), added by the 0.9.162 genre work, has the identical
bug — so the mirror artist-genre path is also 100% broken. `docs/cache-ttl-30-day-boundary.md`
documents the mechanism and flags the first constant as "FOUND, NOT FIXED"; the second post-dates
its audit table.

Earlier in this session I proposed a fix for a "dated-but-tagless entry pinned for 90 days". That
diagnosis was the wrong way round and is superseded by this one.

## 1.2 The sluggishness is mostly one server pref

`mb_base_url` on the live server is set to `https://musicbrainz.org/ws/2/`. A non-blank value makes
`autodetectMirror` (`API.pm:262`) return early, so the local mirror at `plex:5000` is never
adopted. Every MusicBrainz call then runs against the throttled public API:

- **45 × `artist-sort fetch error … 503 Service Temporarily Unavailable`** in one six-minute
  window, all from the artist-sort warm on an artist-sorted All Releases view.
- Each release page open pays a throttled `release?inc=recordings` *and* a throttled
  `release-group?inc=genres`.
- The mirror itself is healthy — 20 rapid `ws/2/artist` lookups returned 200 with no throttling.

Fix needs no build: clear the pref, or set it to `http://localhost:5000/ws/2/`.

## 1.3 Genre coverage — what the data actually supports

Measured on the live feeds:

| source | coverage | notes |
|---|---|---|
| album-level MB genres | ~5% (8/150 All Releases, 2/11 For You) | fresh releases are rarely tagged yet |
| artist-level, ListenBrainz | ~48% | `inc=release_group tag` → `tag.artist[]`, gated on `genre_mbid` |
| artist-level, hosted API | **43%** of 60 distinct artists, median **160ms** | name-keyed, unthrottled |

The artist tier is where essentially all the coverage lives, so its reliability is the whole game.

## 1.4 The hosted LMS-community API — the real route surface

From the dev's own reference (`~/Downloads/mai-api.md`), confirmed live:

```
/music/artist/:artist          + /picture /aliases /biography /discography /mbid /relatedArtists
/music/album/:album/:artist    + /cover /genres /mbid /review
/music/track/:title/:artist    + /cover /review /lyrics
/music/work/:work/:artist      + /aliases /mbid /review
/music/metadata/killwords|lyricsProviders     /health  /geoip  /time…
```

**Every route is name-keyed. There is no MBID lookup anywhere** — `/music/artist/<mbid>/discography`
returns a bare `{}`.

Two traps that cost time this session, both real:

1. An unrecognised path answers **HTTP 200 with a fixed `{"picture": …}` payload**, never a 404.
   So `/artist/<name>/genres` "works" while not existing.
2. **Artist genres are a field on the parent artist route, not a sub-route** — and the field is
   *absent for Radiohead*, the obvious artist to test. One sample proved the opposite of the truth.
   NCT 127 → `['K-Pop']`; Lambchop → `['Country','Alternative Country','Chamber Pop']`, matching
   ListenBrainz's artist tags exactly.

`/artist/:artist/discography[?withReleases=1]` is rich — release-group mbid, title, cover,
`primary_type`, `secondary_types`, `release_date`, `releases{}`, `status` — and is the right
replacement for a name-keyed release-group *search*. It carries **no genres**.

## 1.5 ListenBrainz already serves two things we were about to ask the dev for

On `GET /1/metadata/release_group/?release_group_mbids=<csv>&inc=…` — the endpoint LBF already
calls — `inc` is a space-separated list, and `recording` returns **the full tracklist** in
MusicBrainz's own shape:

```json
"mediums": [ { "format": "CD", "position": 1, "name": "",
  "tracks": [ { "position": 1, "name": "Airbag", "length": 284400,
                "recording_mbid": "4a7fea2e-…", "artists": [ … ] } ] } ]
```

Only `mediums`/`name` differ from ws/2's `media`/`title`. It is **release-group-keyed**, so it
answers for rows with no release MBID — which today get no tracklist at all. Cost: a 50-release
batch goes from 29.6 KB to 116.8 KB, so it belongs on the detail page, one group at a time.

`GET /1/metadata/artist/?artist_mbids=<csv>&inc=artist` returns `name`, **`type`** (Person/Group),
`area`, `begin_year`, `rels{}` — but **no `sort_name`**. `type` is the piece that decides whether
to invert a sort key. It is not full parity: a two-word stage name is still `Person`, so a naive
invert files **Panda Bear as "Bear, Panda"** where MB's curated sort-name keeps it natural.

## 1.6 What still needs MusicBrainz, and what doesn't

| call | today | after |
|---|---|---|
| artist sort-name (`warmArtistSorts`) | `ws/2/artist/<mbid>`, 1/s, 503s | ~~LB bulk `type` + article strip~~ **STAYS ON MB** (§2.4.3, and `hosted-lms-community-api.md` §7) — already lazy and off the render path; **0.9.180** added the 503 backoff it lacked |
| tracklist (`getReleaseDetails`) | `ws/2/release?inc=recordings` | ~~LB `inc=recording`~~ **STAYS ON MB** — §7 probed it live: no release-keyed tracklist route on LB or hosted, and LB's own site fetches tracklists from MB |
| release-group by name (`getReleaseGroupByName`) | MB *search* — the most expensive MB call | **DONE 0.9.179** — hosted `/discography` first, MB fallback unconditional |
| release-group genres (`getReleaseGroupGenres`) | MB | unchanged; hosted album-genres already sits in front |

`sortname` on the hosted artist route has been requested from the LMS dev. **Re-checked live
2026-08-22: it has NOT landed** — there is no sort field of any kind on `/music/artist/<name>`.
It matters more than it did, because the local-key plan that would have made it optional is now
dropped (§2.4.3): it is the ONLY thing that would take artist sort off MusicBrainz without
mis-filing stage names, and it would slot in as `sort_src='hosted'` with no schema change. Worth
chasing. The tracklist half of that request is **not needed** — see 1.5.

## 1.7 The caching model is the deeper problem

`getFreshReleasesAll` (`API.pm:398`) stores the whole feed as one blob under
`'lbf:feed:all:' . join('|',$sort,$past,$future,$days,$today)`. The local date is in the key, so
the entire ~2,900-release structure is re-minted **at every local midnight**, and again whenever
the window or past/future prefs change. Most of those releases are unchanged for weeks. Two
5-second in-process memos (`%FEED_MEMO`, `%SECTION_MEMO`) exist purely to blunt the cost of
deserialising that blob on every XMLBrowser walk — and XMLBrowser walks from the root 3+ times per
tap, across both sections.

---

# PART 2 — THE BUILD

## 2.1 Decisions taken — do not re-open

1. **Everything** moves out of `Slim::Utils::Cache` into a plugin-owned SQLite database, as PFR
   did. PFR's own notes call its half-move a second mistake: it left the most expensive layer in
   the store that had just been proved to eat data silently.
2. The **durable base is exempt** from the fleet rule that every dev build clears all caches;
   it is invalidated only by an explicit version bump.
3. **Genres only** clear on a dev build among the durable facts — years, types, MBIDs and
   sort-names survive, so a genre change never re-inflicts a multi-day artist-sort reconvergence.
4. **Tracklists live in `kv`** with a 30-day absolute expiry, not a durable table.
5. **Scoped per-week SQL is deferred** to a measured stage 8, gated on `bench_walk.pl`.
6. One build, containing both the store rework and the MusicBrainz retreat.

A correction to carry into implementation: a naive per-row port of PFR would likely be **slower to
read** than today's single blob — 2,900 DBI fetches and thaws against one `Storable::thaw` in C.
The win is that the base stops being re-minted and the window becomes queryable. If that
distinction is lost, this ships a regression.

## 2.2 The store

One SQLite file, `ListenBrainzFreshReleases/DB.pm`, modelled on
`LMS-Pitchfork-Reviews/PitchforkReviews/DB.pm` — same `dbh` shape, `sqlite_unicode => 1`,
`RaiseError`, `journal_mode=WAL`, `$broken` latch, degrade-never-die. Three tiers, with one rule
that makes them self-enforcing: **if it is in `kv` it is disposable; if it must survive, it needs a
table.** That is what lets the dev-build wipe be a single unconditional `DELETE FROM kv` with no
allowlist to get wrong.

| tier | contents | invalidated by | dev wipe |
|---|---|---|---|
| BASE | `release`, `feed_member`, `feed_day`, `feed_meta`, `bandcamp_pin`, `follow_item` | `BASE_VERSION` bump only | never |
| FACTS | `release_group`, `recording`, `artist` | per-table `*_FACT_VERSION` | genres columns only |
| DERIVED | `kv` — match decisions, resolved lists, text, markers | key version or absolute expiry | wiped wholesale |

**Three things currently in the cache are not caches** and must become tables *before* the wipe is
switched on, or that rule destroys user data: `lbf:bcmatch:6:` (hand-curated Bandcamp pins, no
automatic repopulation — `Browse.pm:4907`), `lbf:follow:accum:1:` (builds forward from first
capture; cannot be re-derived once events leave LB's 75-event window), and `lbf:artistsort:1:`
(re-derivable only at 100 artists per pass, serially, with an MB courtesy gap).

### Schema notes that matter

- **`release`** keyed by a `rel_id` identity ladder reusing `_streamId` (`Browse.pm:4883`):
  `release_mbid`, else `rg:<release_group_mbid>` (the MuSpy case), else `t:<norm artist> <norm
  title>`. Reusing the ladder means the release key and the stream key can never disagree about
  what "the same album" is. Store the **whole upstream hash frozen in a `payload` blob** and mirror
  into typed columns only what must be queried (`rel_date`, `week_start`, `rg_mbid`,
  `artist_mbids`, `caa_rel_mbid`, `dedupe_key`). LBF passes third-party JSON around whole —
  enumerating columns guarantees that the day ListenBrainz adds a field, it is silently dropped.
  Upsert must **merge, never blank** (`COALESCE(NULLIF(excluded.x,''), x)`): LB and MuSpy describe
  the same release with different completeness.
- **`feed_member`** keyed `(feed, rel_id)` — deliberately *not* `(feed, position)` as PFR does.
  LBF's order is re-derived per walk by `_sortReleases`/`_sortWithin`, so position is provenance,
  not data; keying on it would rewrite every row whenever one insertion shifts the rest.
- **`feed_day`** has no PFR counterpart and is what makes a window change free: coverage becomes a
  query instead of something encoded in a cache key.
- **`release_group` stays separate from `release`** — several releases share a group, so genres on
  the release row would duplicate N ways and could disagree; and the Trending path looks up groups
  that never appeared in any feed. Readers still see one merged hash.
- **`fetched_at` replaces every TTL on the facts tables.** Staleness becomes a policy applied in
  Perl, preserving 0.9.113's dated/dateless soft-hit rule exactly. Nothing hands a duration to LMS,
  so **no value can mean 1970**. This is the structural fix for 1.1.
- **`kv`** copied from PFR: `{ v => $value }` wrapper so `0` and `undef` stay distinguishable from
  a miss, absolute `expires_at`, `kvGet/kvSet/kvDel/kvForgetPrefix/kvSweep`.
- **Migrations via `PRAGMA user_version`**, not PFR's `CREATE TABLE IF NOT EXISTS`-only `_migrate`,
  which cannot add a column later. A throwing migration leaves the version untouched and latches
  `$broken`.
- **Bind blobs as `SQL_BLOB` explicitly.** PFR passes `nfreeze` output with no bind type; frozen
  bytes are often not valid UTF-8 and `sqlite_unicode => 1` decodes text on read. It works there,
  but the failure mode is silent corruption, which is the whole thing this work exists to stop.

### How the feed works afterwards

`getFreshReleasesAll` asks `DB::feedCoverage('all', $from, $to)` and takes one of three paths: full
and fresh → serve from the DB, no HTTP; full but stale → **serve immediately and revalidate in the
background** (safe because every feed callback is already `cachetime => 0`); days missing → fetch
only the uncovered days and upsert onto what exists. At 00:01 the window shifts by one day, which
`feed_day` usually already covers, so **midnight typically costs nothing** where today it
guarantees a full re-fetch and re-freeze.

`ingestFeed` runs as one transaction and **refuses an empty ingest when rows already exist for the
window** — recording `fetched_at` but not `ok_at`, deleting nothing. That is this repo's
twice-learned "an empty result is never a fact" rule (0.9.149, 0.9.119), and it is where the 429
backoff plugs in. Rotation (`DELETE … WHERE seen_at < $now`) is scoped to the **requested** window,
passed in and never inferred from the response — infer it and a day that legitimately went empty
can never be cleaned.

The `…fb:` twins disappear as storage: rows do not expire, so `_feedError` serves stored rows and
logs their age from `feed_meta.ok_at`. The one behaviour that genuinely changes is that a
permanently dead feed would otherwise show months-old releases forever — guarded by the existing
date-span subtitle in `_categoryTile` (`Browse.pm:387`) plus a sweep pruning members older than 120
days, comfortably beyond the `days` pref's 90 maximum.

`%FEED_MEMO` and `%SECTION_MEMO` both stay, with better validity: keyed on `feed_meta.generation`
— which only moves when content actually moved — instead of a 5-second expiry, so they can hold
for minutes without masking anything.

## 2.3 Invalidation

- `BASE_VERSION` on `release.base_version` is the `PARSE_VERSION` analogue, bumped only when the
  shape stored in `payload` changes. **The LBF-specific cost, stated plainly:** unlike PFR, where a
  bump re-downloads an always-available article, LB only re-serves releases inside the `days`
  window, so a bump *loses* older rows. Prefer additive changes with a back-fill migration; reserve
  the bump for genuine incompatibility.
- `*_FACT_VERSION` per facts table, bumped when the parser changes (e.g. `_genreTags`,
  `API.pm:1346`). Rows read as absent and refetch individually. Retires the hand-maintained
  `:1:`→`:2:` prefix suffixes.
- **Key versions declared once** in a `KEY_VERSIONS` constant, retired at startup by
  `DB::retirePrefixes` — replacing versions scattered across `_streamKey`, `_bcMarkerKey`,
  `_followResolvedKey`, `_trendingResolvedKey`, `_albumsDataKey` and three separate literal
  `'lbf:pl:resolved:8:'` strings (`Browse.pm:825, 893, 2640`).
- **The layered relationship becomes structural, not documented.** Outer resolved-list keys embed
  the inner `lbf:track:` version, so bumping the inner necessarily invalidates every list wrapping
  it. This rule has been written down three times and broken anyway. `lbf:bcmatch:` stays
  explicitly outside it — as a table with no version in its identity at all.
- `lbf:rggenres:` is **deleted**: one caller remains (`Browse.pm:4380`) and it is recorded as
  superseded by `_withGenres`.

## 2.4 The MusicBrainz retreat

Half of this build. Each item below is specified to the call site, because the stated goal is to
avoid the round trips the PFR migration took.

### 2.4.1 Artist genres from the hosted API

**Today.** `_genresFor` (`Browse.pm:7038`) is a four-tier ladder: the album's own genres, then the
artist's (`agenres`), then the feed's inline `release_tags`, then vocabulary-gated Last.fm.
`_genreLookupMode` picks `mirror` (per-artist `ws/2/artist/<mbid>?inc=genres`, `AGEN_CONCURRENCY`=6)
or `lb` (bulk `inc=release_group tag`). Both tiers 1 and 2 have been dead — §1.1.

**Change.** Add a hosted tier that fills `agenres` when ListenBrainz has none: one
`GET /music/artist/<name>` per distinct artist, through the existing `_hostedGet` (`API.pm:172`) so
it carries `X-LMS-Plugin-ID` and inherits the auth slot. Store in `artist.genres` with
`genres_src='hosted'`, so it can be re-run or fact-versioned independently of the MB tier.

**Traps.** The payload is **Title-Cased** ("Alternative Rock") — lowercase on the way in or
`_genreFamily` will not match `genre-families.txt` and every row silently falls through to the raw
genre. The `genres` key is **absent** for some artists (Radiohead among them), which is a miss, not
an error. De-duplicate per render: a 150-row page is ~120 distinct artists, not 150 lookups. It is
**name-keyed**, so unlike every other genre tier it also answers for Trending rows that arrive with
no MBID at all — those can gain a genre for the first time.

**Order.** LB bulk first (already batched, 50 per request, covers ~48%), hosted for the remainder
(~43% of what is left), then the existing inline/Last.fm tiers. Never on the synchronous render
path — it fills the same background top-up `_kickGenreFill` already runs.

**Verify.** NCT 127 → `k-pop` and Davenki Pi Wiart → `deep techno` on the row, both of which are
blank today; a Trending album with no release-group MBID showing a genre; `cachestats` showing
`artist` rows with `genres_src='hosted'` surviving a restart.

### 2.4.2 ListenBrainz 429 backoff and warm pacing

**Today.** `getReleaseGroupMetadata` (`API.pm:1249`) logs `RG metadata chunk failed: 429 TOO MANY
REQUESTS` and moves on — no retry, no backoff. Observed five times in one boot window, because the
genre warm fires 4 concurrent chunks into the same rate-limit bucket the feed, playlist and follow
fetches are already using. The endpoint itself is fine: the identical 7-chunk burst from a machine
with a clean bucket returned all 200s with 23-29 of 30 remaining.

**Change.** Honour `X-RateLimit-Reset-In` on a 429 and retry with backoff; record the deadline in
`kv` with an absolute expiry so concurrent callers back off together rather than each discovering
the limit. In the feed path a 429 is a **failed attempt** — it takes the ingest's refuse branch
(§2.2), setting `fetched_at` but not `ok_at`, and deleting nothing. Sequence the boot warm so the
genre stage does not overlap the feed stage.

**Verify.** Restart and confirm no `RG metadata chunk failed` lines; `cachestats` shows the genre
rows filling on the first warm rather than over days of top-ups.

### 2.4.3 Artist sort without MusicBrainz

> **OUTCOME 2026-08-22: STAGE D IS NOT BEING BUILT. The local key below was REJECTED,
> and MusicBrainz stays as the sort-name source.** The "known limit, accepted" three
> paragraphs down is the reason — Simon: *"artists like Sonic Boom and Panda Bear are
> classed as person but would not want artist sort of Bear, Panda"*. It was not an
> acceptable limit, and it cannot be engineered around: verified live 2026-08-22, LB's
> `inc=artist` payload returns `type=Person`, `gender=Male` and near-identical `rels`
> for **Panda Bear, Sonic Boom and Jack White alike**, while MB's curated sort-names
> are `'Panda Bear'`, `'Sonic Boom'` and `'White, Jack'`. There is no signal in LB's
> data that separates a stage name from a legal name, so any `type`-driven inversion
> mis-files the first two. `type` is also absent for 22% of a real feed, and the
> Hatsune Miku entity came back `None` rather than `Character` — so Character cannot
> be excluded by type either.
>
> **What was already true, and made stage D unnecessary anyway:** `warmArtistSorts` is
> ALREADY lazy and off the critical path — fire-and-forget, only on the Artist sort,
> 100 per pass, per-answer staleness against `sort_at`, empty answers recorded, and a
> whole-batch in-flight reservation. The render never waits on it. Most of what §2.4.3
> was written to fix had been fixed by other means since.
>
> **What DID land instead (0.9.180):** the one thing genuinely missing — a MusicBrainz
> 503/429 backoff on that pump (`_mbWait` / `_mbIsRateLimited` / `_mbNoteLimit` /
> `_mbNoteOk`), shared deadline, 5s doubling to 30s, reset on success, outward-only.
> A rate limit now ends the pass and hands the whole reservation back rather than
> burning 100 artists against a limit that had already refused them. Measured on the
> public API that day: **two 503s inside eight requests paced at 1.2s — wider than the
> 1.1s courtesy gap this code uses.** Guarded by `t_genrefill.pl` §13 (4 source
> assertions, all anti-tested red against the pre-fix source).
>
> **Still open, and the clean fix if it ever lands:** `sortname` on the hosted artist
> route. Re-checked 2026-08-22 — it has NOT appeared; no sort field of any kind on
> `/music/artist/<name>`. If the LMS dev adds it, it slots in ahead of MB as
> `sort_src='hosted'` with no schema change and fixes Panda Bear properly, because it
> would carry MB's curated value. Worth asking him for.
>
> `artist.artist_type` remains written by nothing and read by nothing — it was added
> for this plan. Leave it; a SQLite column drop is a table rebuild.

**Today.** `_artistSortKey` (`Browse.pm:3017`) prefers `$rel->{artist_sort_name}` (MuSpy supplies
it), else `peekArtistSort` (`API.pm:2135`), else the display credit. `warmArtistSorts`
(`API.pm:2146`) fetches `ws/2/artist/<mbid>` one at a time, `SORT_WARM_MAX`=100 per pass, 1.1s
courtesy gap on public MB. This is the 503 storm.

**Change.** Build the key locally: strip a leading article, and invert on **`type`** from the bulk
`GET /1/metadata/artist/?artist_mbids=<csv>&inc=artist` — one call for the whole page, cached in
`artist` with `sort_src='local'`. Keep the exact MB sort-name path but run it **only when a mirror
is configured** (`sort_src='mb'`, free and instant there). Ladder unchanged: feed-supplied →
exact → local → display credit.

**Known limit, accepted.** `type` cannot distinguish a legal name from a two-word stage name, so
Panda Bear files under B where MB's curated sort-name keeps it natural. Verified correct for Jack
White, Phoebe Bridgers, Ludwig van Beethoven, Lambchop, NCT 127. If the hosted `sortname` field
lands (requested from the LMS dev) it slots in ahead of the local key with no schema change —
`sort_src='hosted'`.

**Verify.** Sort All Releases by artist with `mb_base_url` blank: correct ordering, and **zero**
`artist-sort fetch error` lines in the log.

### 2.4.4 Tracklists from ListenBrainz

**Today.** `getReleaseDetails` (`API.pm:2359`) fetches `ws/2/release/<mbid>?inc=recordings`, and the
consumer (`Browse.pm:4421-4445`) walks `$info->{media}` → `{tracks}` for `position`, `title`,
`length`. It is gated `my $wantTracks = $mbid ? 1 : 0` (`Browse.pm:4234`) — a **release** MBID — so
rows without one show no tracklist at all.

**Change.** `inc=recording` on the release-group metadata endpoint already in use. Same shape as
ws/2 apart from `mediums`/`name` where MB says `media`/`title`, so the consumer changes by a
rename. Gate becomes the release-**group** MBID, which is what widens coverage to MuSpy and
Trending rows. Detail page only, one release group at a time: adding `recording` to a 50-release
batch takes the payload from 29.6 KB to 116.8 KB, so it must never join the feed-wide calls. Store
in `kv`, 30-day absolute expiry, version in `KEY_VERSIONS`. MB stays as the fallback.

**Verify.** A release page shows its tracklist with no `musicbrainz.org` line in the log; a MuSpy
row (no release MBID) now shows one; the 50-batch feed call is unchanged in size.

### 2.4.5 `getReleaseGroupByName` → `/artist/:artist/discography`

**Today.** `getReleaseGroupByName` (`API.pm:1401`, callers `Browse.pm:1765` and `2061`) runs a
fielded MB **search** — the most expensive kind of MB call — with a score≥90 gate, a
mirror-0-results→public retry, and a collab-split artist ladder capped at 3 terms. Returns
`{ mbid, date, year, type }`.

**Change.** `GET /music/artist/<name>/discography` returns every release group for that artist with
`mbid`, `title`, `primary_type`, `secondary_types`, `release_date` — the whole return shape, in one
unthrottled call, and **release-group** ids rather than the release id the `/album` route gives.
Cache per artist in `kv`; both callers are trending paths that look up several albums by the same
artist, so one fetch serves many lookups.

**Traps.** The title must be matched **through the shared matcher's `_norm`**, never a new
comparison — that is a fleet-sync rule, and a private title comparison here would be a fifth copy.
Keep the collab-split ladder for the artist name. Keep the MB search as the unconditional fallback:
the hosted dataset rebuilds weekly, and this plugin is about brand-new releases.

**Verify.** A Trending album resolves with no MB search in the log; an artist the hosted API does
not know still resolves via the MB fallback.

### 2.4.6 The two over-boundary TTLs

`RECMETA_TTL` (`API.pm:1079`) and `AGEN_FOUND_TTL` (`API.pm:1978`) become `fetched_at` age policies
on `recording` and `artist` (§2.2), so the defect becomes inexpressible rather than corrected. Any
`Slim::Utils::Cache` TTL still standing when the dust settles is pinned by `t_ttlceiling.pl` at
2,592,000 exactly. Expect a **visible jump in genre coverage** the first time this runs — that is
the tier working for the first time, not a new bug.

## 2.5 Staging

One release, ordered so each stage is installable and verifiable alone, riskiest last.

| # | stage | verified by | risk |
|---|---|---|---|
| 1 | `DB.pm`, schema, `kv`, sweep, `retirePrefixes`, `["lbf","cachestats"]` CLI. Nothing reads it. | `t_db.pl` green; restart; behaviour byte-identical | ~zero |
| 2 | Derived layer → `kv`, one prefix family per commit | per family: use the feature, `cachestats` shows rows, restart, still instant | low |
| 3 | Rescue the durable three (`bandcamp_pin`, `follow_item`, lazy legacy import) | pin a match, `DELETE FROM kv` by hand, pin still there | low, high value |
| 4 | FACTS tables | open a release page → row appears with genres; **first ever proof artist genres persist** | medium |
| 5 | Feed **ingest only**; reads still from the old path | `cachestats` shows ~2,900 releases, 15 `feed_day` rows; a bug here cannot break browsing | isolated |
| 6 | **Flip the read**; delete the `fb:` twins | clock forward past midnight → **no fetch in the log, same releases**; `days` 14→7 no fetch, 14→30 one additive fetch; pull the network, feed still renders | highest |
| 7 | Dev-build wipe, `BASE_VERSION`/`*_FACT_VERSION`, `_warmFeeds` ahead of the username gate | install a dev build: `kv` empties, pins/follow/releases survive, first browse instant | low |
| 8 | *(gated on numbers)* scoped week queries | `bench_walk.pl` before/after; identical row counts | defer if unjustified |

Stage 5→6 is the only dangerous seam and is bisected by design.

Also in stage 7: `warmCache` returns early without a username (`Browse.pm:2593`), so **All
Releases — which needs no account — has never been warmed for anyone.** A feed-ingest stage goes
ahead of that gate.

### The MusicBrainz retreat, staged against the above

Each of these is independently installable and reversible, and each has a hard dependency on a
store stage — which is why they interleave rather than follow.

| # | stage | depends on | verified by |
|---|---|---|---|
| A | **TTL fix + `t_ttlceiling.pl`** (§2.4.6) — as the facts tables land | stage 4 | genre labels appear on the LB tier for dated releases, which has never happened |
| B | **429 backoff + warm pacing** (§2.4.2) | stage 5 (ingest refuse branch) | no `RG metadata chunk failed` after a restart |
| C | **Hosted artist genres** (§2.4.1) | stage 4 (`artist.genres_src`) | NCT 127 and Davenki show genres; a Trending row with no MBID shows one |
| D | ~~**Artist sort** (§2.4.3)~~ **DROPPED 2026-08-22** — the local key mis-files stage names (Panda Bear → "Bear, Panda"); MB stays, now with a 503 backoff | — | `t_genrefill.pl` §13 |
| E | **LB tracklists** (§2.4.4) | stage 2 (`kv`) | tracklist with no MB call; a MuSpy row gains one |
| F | **`/discography`** (§2.4.5) | stage 2 (`kv`) | a Trending album resolves with no MB search; unknown artist still resolves via fallback |

A is the one to land first regardless of everything else: it is the fix for the reported symptom,
and until it is in, no genre work downstream of it can be observed at all.

## 2.6 Verification

- **Persistence proved three ways**, because a silently failing write is indistinguishable from a
  fix not being installed: cross-process (`tools/t_db.pl` writes in one interpreter, reads in a
  fresh one — an in-process reset proves nothing against a file-lexical handle); on the live server
  via `["lbf","cachestats"]` before and after a restart; and an **anti-test** against a mutated
  `kvSet` that returns 1 without writing, which must turn the suite red.
- **`tools/t_ttlceiling.pl`**: assert `API.pm`, `Browse.pm`, `DSTM.pm`, `Diag.pm` contain **no**
  `Slim::Utils::Cache` use at all — once that passes, the boundary is unreachable. While any
  remain, sweep every `use constant \w*TTL\w*` and fail above **2,592,000 exactly** (PFR ran this
  guard set at 90 days throughout its investigation, so it passed while the bug was live — a guard
  with the wrong number looks like coverage). Plus the positive: `kvSet($k,$v,90*86400)` must store
  `now + 7776000`, proving the defect is inexpressible.
- **`tools/t_db.pl`** against a real file in a tempdir: full-fidelity release round-trip against a
  captured LB hash; unicode in payload, columns and keys; a frozen blob whose bytes are not valid
  UTF-8; merge-not-blank; window-scoped rotation; empty response deletes nothing; coverage
  arithmetic; **clock advanced a day → zero fetches**; `generation` moves only on real change;
  broken-DB degrade without re-fetching per walk.
- **Layering test**: every resolved-list key builder must emit a key containing the current
  `lbf:track:` version; anti-test by bumping the inner alone.
- **Existing suites**: `t_genrefill.pl`, `t_cache_widechar.pl` (premise changes — add a section
  showing the new path is safe by construction), `t_trending_empty.pl` (re-point to `kv`),
  `t_review_fixes.pl` (its `lbf:bcmatch:` assertion becomes "pins survive a wipe", the property it
  was really protecting), `t_ll_handshake.pl` and `matcher_sync_check.py` untouched.
- **Live end-to-end** over HTTP to `http://plex:9000`: browse All Releases and confirm genre labels
  appear on the ListenBrainz tier for dated releases (they never have); confirm no
  `artist-sort fetch error … 503`; confirm a release page shows a tracklist with no MB call in the
  log; `cachestats` across a restart.
- **Server-side, needs no build**: clear `mb_base_url` or point it at `http://localhost:5000/ws/2/`.

## 2.7 Critical files

- `ListenBrainzFreshReleases/DB.pm` *(new — modelled on PFR's, diverging on payload+columns,
  membership key, `user_version` migrations, blob binding and degrade behaviour)*
- `ListenBrainzFreshReleases/API.pm` — feeds, facts, all TTL constants
- `ListenBrainzFreshReleases/Browse.pm` — derived keys, pins, resolved lists, render paths
- `ListenBrainzFreshReleases/Plugin.pm` — init, warm tick, sweep, dev-build wipe
- `LMS-Pitchfork-Reviews/PitchforkReviews/DB.pm` and `tools/t_db.pl` — the reference, read together
- `docs/cache-ttl-30-day-boundary.md` — update from "FOUND, NOT FIXED" to fixed, and add
  `AGEN_FOUND_TTL` to its audit table
- `docs/hosted-lms-community-api.md` — correct the "no artist genres" conclusion (1.4) and record
  the full route surface
