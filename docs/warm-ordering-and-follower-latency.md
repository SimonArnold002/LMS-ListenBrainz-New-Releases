# LBF — warm ordering, follower latency, and a "still building" state

**Status: STAGE 1 BUILT (0.9.175) — instrumentation only. THE EVENT-LOOP STALL IS
FIXED (0.9.176) — see §4. THE FOLLOWER STATS BURST IS FIXED (0.9.177) — see §5,
which is why People You Follow was empty. The rest of stage 2 (warm reordering,
the building state) is designed and NOT started.**

The field report (2026-08-22): *"Followers seems to hang for a very long time and
load times seem excessive. These sections also used to display a message they were
not ready — this seems to have stopped and just gets the Material loading icon of
3 dots. I feel perhaps Genres have slowed things down more than I had hoped."*

Plus a direct question — *"why do Playlists and Followers not have their own cache
like For You? I only see entries in the log for caching for all or my user"* — and
a requested order: **New Releases → All Releases → Playlists → Followers**, with a
clicked-into view taking priority and returning to the normal schedule afterwards.

**The decision that shapes this document: MEASURE BEFORE COMMITTING.** Both design
questions below were put to Simon with a recommendation and both came back "let's
test to see if these proposals give us the gains before committing". So stage 1 is
an instrument, and the redesign waits on what it reads.

---

## 1. What the code actually does today (read this before changing anything)

### 1.1 Playlists and Followers ARE cached — in a different store, on a different log channel

This is the answer to the question, and the premise in it is the interesting part.
Only the three **release feeds** live in the durable SQLite feed store, and only
that store emits the line that is being recognised in the log (`API.pm`, `_feedFromStore`):

```
feed 'all' served from the store: 3255 releases, 14/14 days, 812s old
feed 'user:<name>' served from the store: …
```

Registered feeds are exactly `all`, `user:<username>` and `muspy`. Everything else
— the created-for playlist listing, playlist tracks, the follow feed, the following
list, per-user listen stats, the trending resolved list and both album aggregates —
lives in the **`kv` table** on plain TTLs, and logs much quieter lines
(`Created-for playlists cache hit`, `Follow-feed cache hit`, `Following cache hit`),
while the trending resolved list logs only through `_dbg`.

**So nothing is missing a cache. What Playlists and Followers lack is day-coverage
tracking and a recognisable log line.** The distinction that matters operationally:

| | release feeds | playlists / followers |
|---|---|---|
| store | `release` / `feed_member` / `feed_day` / `feed_meta` tables | `kv` rows |
| freshness | a COVERAGE QUERY over `feed_day` — partial windows serve + revalidate | a flat TTL — hit or miss |
| survives a dev build | **yes** | **no** — the wipe is `DELETE FROM kv` |
| logs a served-from-store line | yes, at info | no |

**The last row is the one that bites this machine specifically.** `_buildChanged`'s
dev-build wipe is one unconditional `DELETE FROM kv`, so **every installed dev build
empties Playlists and Followers completely** while the release feeds survive intact
in the feed store. Followers is therefore cold far more often here than it ever
would be for a release user — and a cold Followers is the slow case described below.

### 1.2 The warm is barely ordered

`Plugin::_warmTick`, on startup + `WARM_DELAY` (60s) and then every 24h:

1. `Browse::warmFeeds()` — fires **three feed fetches at once, unchained**: All
   Releases *issued first*, then For You, then MuSpy. Each queues covers into one
   shared serial queue on completion.
2. `Browse::warmCache()` — called **immediately, without waiting for step 1**. Inside
   it, `_warmGenres()` is started **first and in parallel** with everything below
   (For You LB genres → Last.fm at one request per second → All Releases LB genres →
   Last.fm), then the created-for playlists resolve serially. **Since 0.9.186 it is
   started ahead of the USERNAME GATE as well**, not merely ahead of the work below it:
   All Releases needs no account, `_warmGenres` makes that distinction internally, and
   with the call sitting below the gate its own no-username branch was dead code — so an
   account-less user had All Releases fetched by `warmFeeds` but never got its genres
   pre-warmed. Everything still under the gate (playlists, follow feed, trending)
   genuinely does need an account. See `code-review-0.9.184.md` findings 2 and 5.
3. Only when the playlist queue drains: `_warmFollow` **and** `_warmTrending` fire
   together, and `_warmTrending` launches **all three follower builds at once**
   (Weekly Tracks, Albums·Month, Albums·Year).
4. `kvSweep` + `feedSweep`.

So against the requested order: **Followers is already last, which is correct** —
the problem is that everything above it runs concurrently rather than in sequence,
and All Releases is issued ahead of For You.

The genre placement is **deliberate and documented** (`Browse.pm`, in `warmCache`):
it was moved to the front because genres are the one thing that must be ready before
a view opens, everything queued ahead of them only matters once the user presses
play, and the ladder's own tail is paced at one request per second. That reasoning
is sound and must not be casually reversed — see §3.1 for how it reconciles with the
requested order.

### 1.3 Why Followers hangs, and it is not the tiles

The tiles are cheap: `_trendingTile` reads a memoised count and `_trendingAlbumsTile`
likewise. **The cost is entirely on drilling in with a cold cache**, where the whole
build runs on the open path with no interim response (`_resolveTrending`):

```
getFollowing                      (up to FOLLOWER_MAX = 250)
  -> _activeFollowers fan-out     FANOUT_DEADLINE = 30s
  -> per-follower stats fan-out   FANOUT_DEADLINE = 30s   (another one)
  -> recording -> album metadata
  -> year fills (rg metadata, then MB name resolution, bounded 25)
  -> _resolveTracks / streaming gate — one search per candidate, pool = 60
```

`$callback` is invoked **only at the very end**. That is 60 seconds of deadline
before the streaming work even starts, and XMLBrowser has nothing to render in the
meantime — hence Material's three dots, indefinitely.

Two things make it worse than the sum of those parts:

- **There is no in-flight guard.** `API.pm` has `%REVALIDATING` for exactly this on
  the feed side ("a single tap produces three or more XMLBrowser walks from the
  root"), but nothing equivalent exists here — so a warm build and a user tap run
  two complete fan-outs against each other.
- **Each of the three views pays separately**, with its own cache key and its own
  `getFollowing` + `_activeFollowers` + stats fan-out.

### 1.4 The "not ready" message was never a building state

`PLUGIN_LBF_NO_TRENDING` — *"No trending data yet — check back once the people you
follow have listened"* — is emitted **only** from `$empty->()`, i.e. an affirmative
*nobody followed / no active followers / no candidates*. Searching the history finds
no removed string and no removed branch.

**There has never been a "still building" state in the code.** Cold-and-building and
finished-and-empty were never distinguishable to the user; what changed is that the
build now runs long enough to reach real data instead of falling out of the empty
branch quickly. The remembered message was the empty path firing fast.

### 1.5 Genres do ride the follower path — but they are not the main cost

The instinct is half right. The follower views never run the genre ladder, but
`_buildAlbumsData` calls `getReleaseGroupMetadata`, which carries
`inc=release_group tag` — **one response answers the date AND the genres**. The date
is what those rows render (art/date/type); the genres are stored rather than wasted,
so this is not pure waste, but the latency lands on a view that displays none.

The larger genre cost is structural, not on this path: the ladder starts at t=0
alongside the feeds and shares the ListenBrainz rate window that has 429 backoff
behind it (measured: 30 requests per ~10s, and a full-feed warm is 66 batches).

---

## 2. Stage 1 — the instrument (0.9.175, BUILT)

No behaviour change. One build that answers *where does the time actually go*,
readable over HTTP off-network.

### 2.1 Per-stage warm timing

`Plugin.pm` gains `stageStart` / `stageEnd` / `stageReset` / `warmStages`, and
`Browse.pm` a one-line eval-guarded `_stage` shim that marks the boundaries.

**Absolute start AND end are recorded, never just an elapsed time, and that is the
whole design.** The question is not "how long did the warm take" but **"what was
running at the same time as what"** — a table of durations alone cannot tell *the
genre ladder is slow* from *the genre ladder is starving the feeds*, which is
precisely the open question. Stages recorded:

`all_feed`, `foryou_feed`, `muspy_feed`, `covers`, `genres_foryou`,
`genres_lastfm_foryou`, `genres_all`, `genres_lastfm_all`, `playlists`,
`follow_feed`, `trending_tracks`, `trending_month`, `trending_year`.

Notes on the shape, each of which was a decision:

- **The Last.fm rung is TWO stages, not one.** It runs once for For You and once for
  All Releases; a shared name would silently overwrite the first.
- **The three follower builds keep separate names** for the same reason — and
  whether their three windows overlap is the single most useful thing in the report.
- **`covers` is ONE stage spanning the shared queue**, from the first path any feed
  queues to the moment it drains. Three rows would imply a parallelism that does not
  exist (the queue is strictly serial, one request in flight).
- **A skipped stage still records**, with its reason (`no username`, `no token`,
  `people_follow off`, `playlist listing failed`). Silently omitting it would read
  as a stage that hung and never recorded an end — a different diagnosis entirely.
- **The table is a package lexical, not `kv`** — the dev-build wipe would eat it, and
  a measurement only has to survive until it is read. A table from before a restart
  describes a different process.
- **`stageReset` runs AFTER the scan-defer check**, not before: a deferred tick has
  not begun, and resetting there would show an empty table for as long as the library
  scan runs.

The shim is eval-guarded at its own level rather than at ~48 call sites, because
these marks sit **inside async HTTP callbacks**, where a die reaches no caller's eval
and simply abandons the rest of the chain. An instrument must not be able to break
the thing it measures.

### 2.2 Open-path phase timing for the albums builds

`_resolveTrending` has carried the `$dt->()` phase-timing idiom since 0.9.108;
`_buildAlbumsData` had **none**, so a slow cold Trending Albums could only be guessed
at. It now marks the same phases — following, active-follower filter, stats fan-out,
aggregate, name-resolution, release-group metadata, streaming gate — reusing that
closure shape verbatim rather than inventing a second one.

### 2.3 `["lbf","warmstats"]`

A CLI dispatch beside `['lbf','diag']` and `['lbf','cachestats']`, for the same
reason those are CLI commands: **the settings pages are LAN-only**, so a timing
question asked from off-network has no other answer, and reading the table from
outside the process that wrote it is the only way to tell a real measurement from a
schema artefact. Each row reports `at` / `until` as offsets from the tick's start
(so the overlap is readable without arithmetic) plus `elapsed`, `outcome` and a note.

`ticks => 0` is reported as data with an empty loop, not as an error: "the tick has
not fired yet" is a real and common answer, and the one worth distinguishing from
"the tick fired and recorded nothing".

### 2.4 `tools/t_warmstats.pl` — 49 assertions

Because **an instrument gets its own assertion, or it is decorative** (the
`cachestats` lesson: it counted a column nothing wrote, so the figure was 0 by
construction and read as evidence about the store for most of a day).

There are two independent ways this instrument can be worthless, and they need
separate tests because either passes while the other fails:

- **the recorder is wrong** — sections 1–4 drive the REAL subs lifted from `Plugin.pm`;
- **the recorder is never called** — section 5 asserts on the CALL SITES in
  `Browse.pm`. Crude, but there is no return value to inspect when the claim is that
  a sub was *reached* (same argument as `t_tokenfree.pl` section 4).

**Anti-tested five ways, all red in the right place:** elapsed-only (3), clobbered
stage order (8), feed marks deleted (3), eval guard removed (1), follower stages
sharing one name (1).

**MUTATION 3 IS WHY THE ANTI-TEST RUN IS NOT OPTIONAL.** Section 5's first cut
accepted `_stage('end', $_, …)` — the bulk-skip form — as an *alternative* to the
literal stage name. That alternative matches for every stage as soon as one bulk call
exists anywhere in the file, so the name was never checked: deleting all three feed
marks left the section **fully green**. Thirteen assertions were meaningless and the
baseline could not show it. Same family as the 0.9.160 and 0.9.149 traps.

### 2.5 Two existing suites needed their harness widened — worth knowing why

`t_coverwarm.pl` and `t_trending_empty.pl` both `grab` sub bodies out of `Browse.pm`
and eval them in a minimal harness, so a new lexical or a new collaborator in those
subs breaks them at eval time (exit 255, **zero FAIL lines** — they die before
asserting, which is easy to misread as passing). Fixed by declaring the two new cover
lexicals, adding `use Time::HiRes ()` to the evals, and stubbing `_stage` as a no-op
in both. Neither suite asserts on the instrumentation; `t_warmstats.pl` owns that.

---

## 3. Stage 2 — designed, NOT started, gated on the numbers

### 3.1 What the measurement decides

| question | decided by |
|---|---|
| Is the genre ladder starving the feeds? | `genres_*` windows vs the feed stages' — do they overlap, and by how much |
| Is serialising the warm worth it? | total tick wall-clock vs the sum of stage elapsed. Close together = little contention to recover |
| Watchdog-then-message, or message immediately? | the cold-open distribution. Routinely under ~8s → the watchdog wins and the message rarely shows. Minutes → the message should be immediate |
| Do the three follower builds really cost 3× ? | `trending_tracks` / `_month` / `_year` elapsed with a cold `kv`, and whether their windows overlap |

### 3.2 Ordered warm chain

For You (+MuSpy) → All Releases → Playlists → Followers, each stage starting when the
previous finishes, with the three follower builds **serialised**. Covers stay
fire-and-forget off each stage (the shared serial queue already exists), so a chain
never waits on ~450 cover fetches.

**Where genres sit is the open question, and the recommendation reconciles rather
than reverses the existing decision:** fold each feed's genre pass into *that feed's
own stage*. That satisfies the requested order AND the documented reason for putting
genres first — For You's genres become ready before Playlists and Followers begin,
instead of after everything. Confirm against the measurement.

### 3.3 An in-flight guard, and a real building state

Reuse the `%REVALIDATING` shape from `API.pm` so a warm build and a user tap cannot
run two fan-outs of the same thing. Add `PLUGIN_LBF_BUILDING` — *"Still being built —
check back in a moment"* — **distinct from `PLUGIN_LBF_NO_TRENDING`**, since the whole
defect in §1.4 is that those two states are indistinguishable.

Cold-open behaviour is the other open question. The recommendation is the watchdog
`topLevel` already uses (`TOPLEVEL_ALL_WAIT`): wait a few seconds, render the real
list if it lands, otherwise render the building row and let the build complete into
cache. Confirm against the cold-open distribution.

### 3.4 A clicked-into view takes priority

A shared last-user-activity stamp; the warm chain checks it before starting the next
stage and defers rather than starting. Cooperative only — no cancellation of in-flight
requests, which is not worth the complexity for a background job.

### 3.5 Apply the building state everywhere, not just Followers

Playlists and any feed openable before it is ready get the same row — that is what
*"in any view that's not ready to render"* asks for.


---

## 4. THE EVENT-LOOP STALL — found while stage 1 was in review, FIXED in 0.9.176

Simon, before installing 0.9.175: *"server losing players when opening an All
Releases feed — this is a sign too many sync requests happening server side, as
this should not happen when async"*, plus *"artwork doesn't always populate fully
on a cold start, it will eventually on a revisit"*, and decisively:
**"none of this was an issue before we switched cache model and adding genres."**

That last sentence was right, and it names the sub.

### 4.1 The regression, exactly

| | storing one feed | statements |
|---|---|---|
| 0.9.161 (pre-rework, committed) | two `$cache->set` — one Storable freeze of the whole array, one row write each | **2** |
| after the rework (`DB::ingestFeed`) | a per-release upsert loop, ~4 statements each × 4,061 | **~16,000** |

**Two statements became sixteen thousand**, in ONE transaction, called from inside
an async HTTP callback where nothing can interleave. The fetch was always async;
what landed in the callback never was.

Measured with `tools/bench_store.pl` (real DBD::SQLite, the live 4,061-release
feed read off `cachestats`):

| stage | Mac | ~Pi (10×) | when |
|---|---|---|---|
| `ingestFeed` cold | 177 ms | ~1.77 s | cold open |
| `ingestFeed` warm (merge) | **185 ms** | **~1.85 s** | **every daily revalidation** |
| `feedReleases` (SELECT + thaw/row) | 32 ms | ~320 ms | **every open** |
| `feedCoverage` | 0.4 ms | ~4 ms | every open |

Note the steady-state case is the WORST one: the warm merge path costs more than
the cold insert path, so this fires on the routine daily revalidation.

### 4.2 Why it explains the artwork too

LMS serves the **image proxy from the same event loop**. Material fires ~30 lazy
image requests as you scroll; while the loop is blocked for ~1.8 s none can be
dispatched or completed, so rows stay blank and fill only on a revisit once the
ingest has finished. One blocked loop, two symptoms.

**Two things ruled OUT, both of which I chased first and neither of which is the
report:** the `COVER_WARM_MAX` 150-of-4,061 pre-warm cap and its ~42-minute serial
drain are real, but **the pre-warm is not in any installed build** — I spent a pass
explaining a feature that was not running. Likewise the image-proxy handler is
pure (a regex and a lookup table, no I/O) and cannot stall anything. *Check what is
actually deployed before explaining its behaviour.*

Separately confirmed from the live server: the installed build is 0.9.173/0.9.174
(schema 5, no `warmstats`), which predates the `getRightSize` size-table fix — so
every hi-dpi grid tile asking `_600x600_f` is being served a **250 px thumbnail
upscaled 2.4×**. That fix has been sitting in the unbuilt tree since 0.9.174.

### 4.3 The fix, and the property it trades on

`ingestFeed` gained `chunk => N` (`INGEST_CHUNK`, **150**, set from measurement not
picked). Row work now runs in chunks, each its own transaction, yielding between
them. **Rotation, `feed_day` and `feed_meta`/`ok_at` run ONCE, at the end, only on a
complete pass.**

That ordering is the entire safety argument, not tidiness:

- mid-pass a reader sees a MIX of old and new rows — both valid, because the upsert
  merges and deletes nothing;
- **coverage is not stamped until the pass completes**, so throughout it the feed
  still reads "stale, revalidating" — the state it was already in;
- a failure part-way leaves extra rows and no `ok_at`, so the next open revalidates.
  It can never leave a feed looking fresh but half-written;
- **rotation only ever runs on a complete pass**, which is rule 1 ("an empty result
  is never a fact") holding from a third direction: a partial pass must not delete
  rows it merely did not reach.

The refusal verdict stays synchronous — it is decided by a COUNT before any row
work, and it is the only field either call site reads.

**Measured after (same 4,061 feed):**

```
before:  ONE block of 173 ms   (~1728 ms on a Pi)
after:   longest block 10.2 ms (~102 ms on a Pi)   — 17x shorter
         28 chunks, total 192 ms (the same work, spread)
```

Total time is essentially unchanged — it is the same statements. What changed is
the longest stretch the event loop cannot run.

### 4.4 `tools/t_ingestchunk.pl` — 33 assertions

Pins the trade, not the chunking (which is visible in the source): a chunked and a
synchronous pass build an **identical** store; rotation and coverage happen only on
a complete pass; the merge rule survives a chunk boundary; the refusal verdict is
still synchronous.

**Anti-tested, both red on the safety property:** letting a failed chunk fall
through to the finish step → the feed went **60 members to 25**, thirty-five rows
deleted merely for not being reached, `ok_at` stamped fresh on top so nothing would
ever put them back. Running the finish step after every chunk → mid-pass the store
already claims to be complete.

**The first cut of that section caught neither**, and the reason generalises: it
made a chunk fail by dropping a table, which breaks the *finish* step too — so the
mutant produced an unstamped feed for the wrong reason and the section passed
against it. **A test that "X is skipped on failure" is vacuous unless X would
otherwise have succeeded.** The fix was to fail one chunk in isolation by putting a
coderef in a release (Storable dies in `_freeze`, which is deliberately unguarded)
while leaving the store perfectly usable.

### 4.5 Still open

`feedReleases` remains ~320 ms on a Pi on **every** open — 55% Storable thaw, 40%
the SELECT. Well under the ingest but not nothing, and unlike the ingest it is on
the path of every single browse. Not addressed here; measure it again once the
chunked ingest is in the field and the noise floor is lower.


---

## 5. THE FOLLOWER STATS BURST — found BY the instrument, fixed in 0.9.177

0.9.175 was installed and `["lbf","warmstats"]` read off a real tick. It earned its
keep immediately:

```
trending_tracks   at 51.03   \
trending_month    at 51.06    >  all three within 50 ms
trending_year     at 51.08   /
```

plus, in the log, `Fetching following` **three times, 25 ms apart** — none had
finished writing its cache before the next asked — and then:

```
13 x stats/recordings      429 TOO MANY REQUESTS
26 x stats/release-groups  429 TOO MANY REQUESTS
   = 39 of 39, inside 0.88 s
-> "mapped 0 recordings", "aggregate 0 album(s)"  -> the section renders EMPTY
```

**It is arithmetic, not bad luck.** Three builds × `FOLLOWER_FANOUT` (10) = thirty
concurrent requests, which is ListenBrainz's entire measured ~30-per-10s budget,
fired at once.

### Two causes, and either one alone still breaks it

**A — the builds raced.** `_warmTrending` started all three together. Now chained:
tracks → month → year. This also restores the point of the per-user caches:
`getFollowing` and `getLatestListenTs` are cached, so builds 2 and 3 are nearly
free — *but only if build 1 has finished writing them*. Racing defeated the caching
that was supposed to make this cheap.

**B — `_getUserStats` had no rate limiting at all.** The backoff built in 0.9.165
was wired to `getReleaseGroupMetadata` and nothing else, and a 429 was answered with
`[]` — laundering a rate limit into "this follower has no listens", which is this
repo's oldest rule (*an empty result is never a fact*) failing on a new path. It now
waits on the SHARED deadline, retries a 429 up to `LB_RETRY_MAX`, and caches nothing
on that branch.

The constant's comment claimed the endpoint was *"cheap — safe to parallelise more
than the streaming resolve"*. Cheap is not the same as exempt; corrected in place.

### The completion hook

Chaining needed `_resolveTrending` to signal completion, which is **not** the same
as its render callback. `$onDone` fires at **all four** terminal points — setup
required, cache hit, the empty branch, and the resolved path — guarded to fire once.
Including the empty branch is the load-bearing part: a chain that advanced only on
success would stall the whole section on its single commonest outcome.

### `tools/t_statsratelimit.pl` — 20 assertions

Anti-tested two ways, both red: dropping the `_lbWait` check (1 red), and firing the
builds in parallel again (1 red).

**Section 3's first cut caught neither.** It used a span match that reached across
the callback's closing brace, so it stayed green against a mutant that moved the
chained call one line *out* of the callback — which is precisely the parallel bug.
Anchored on the callback's own closing punctuation instead. **A test for "X happens
inside Y" must anchor on Y's boundary, or it only tests "X happens somewhere".**

### Not yet verified in the field

0.9.177 has not been installed. The proof will be `warmstats` showing the three
follower stages *staggered* rather than stacked, and no 429s in the log.

### VERIFIED in the field, 2026-08-22

0.9.177 installed; server restarted 16:00:40, tick at 16:01:40. `getFollowing`
fetched **once**, zero HTTP 429s, and the builds ran staggered exactly as designed:

```
trending_tracks   48.62 -> 48.63   cache-hit   50 tracks
trending_month    48.63 -> 104.63  56.00s      50 albums
trending_year    104.63 -> 130.30  25.67s      50 albums
```

People You Follow returns real data instead of an empty section. Fix confirmed.

---

## 6. STAGE 1'S NUMBERS — the measurement the design questions were gated on

The full tick-1 table (0.9.177, cold `kv`, warm feed store):

| stage | window (s) | elapsed | note |
|---|---|---|---|
| all / foryou / muspy feed | 0.00–0.01 | ~0 | served from the store |
| genres_foryou | 0.01–1.77 | 1.75s | 15 release groups |
| genres_lastfm_foryou | 1.77–6.95 | 5.18s | |
| genres_all | 6.95–11.48 | 4.54s | 219 release groups |
| **genres_lastfm_all** | 11.48–197.78 | **186.30s** | |
| playlists | 0.02–48.62 | 48.61s | 4 playlists |
| trending_month / _year | 48.63–130.30 | 81.67s | |
| covers | 0.01–205.58 | 205.57s | 543 requests |

Tick wall-clock ~205s against ~534s of summed stage time — so there IS 2.6x overlap
to recover, but fully serialising would make the *total* worse, not better. The
answer is to order the user-visible stages and leave covers and the Last.fm fill as
background trickle.

**Genres: the suspicion was right, but narrowly.** The ListenBrainz rungs cost 6.3s
combined. The **Last.fm rung on All Releases is 186s** — the longest thing in the
tick, overlapping playlists AND both follower builds. It is paced at 1s/artist so it
is not CPU-bound; it just occupies the whole window. (Note for future readers: the
`genres_foryou`/`genres_all` stages call `getReleaseGroupMetadata`, which is
**ListenBrainz** `/1/metadata/release_group/`. There is no MusicBrainz in the genre
ladder — do not repeat that mistake.)

### 6.1 A cold Followers open is 52.8 seconds, and it is not the ListenBrainz side

```
following                1,263ms
stats fan-out            5,989ms
mapped 250 recordings      934ms
candidate metadata fill    486ms
album years                672ms
name-resolved years     22,880ms   <- 12 serial MusicBrainz searches
streaming resolve       20,542ms   <- 65 Qobuz track-matches
                        ---------
total                   52,768ms
```

**This settles §3.1's question 1.** At 52.8s the watchdog loses: the building state
should render **immediately**, not after a wait. A watchdog only pays when the cold
open is routinely under ~8s, and it is nowhere near.

### 6.2 The 22.9s is public MusicBrainz, and only for a residue LB cannot identify

`getReleaseGroupByName` (API.pm) is the only MusicBrainz call in the followers path.
Two facts, both measured:

- **`mb_base_url` is unset on the live server**, so `diag` reports
  `MusicBrainz (public MusicBrainz)` and the searches go to musicbrainz.org at
  ~1 req/sec. 12 lookups x ~1.9s = the whole 22.9s, plus a `503` in that window.
  Pointing it at the local mirror is a settings change, no build.
- **The residue is irreducible from ListenBrainz.** `stats/release-groups` DOES
  carry `release_group_mbid` and the albums path uses it directly. `stats/recordings`
  has no such field in its schema at all — verified across 100 live rows, the key
  union is `artist_mbids, artist_name, artists, caa_id, caa_release_mbid,
  listen_count, recording_mbid, release_mbid, release_name, track_name`. The code
  already does the best available LB move (`getRecordingMetadata`, recording -> release
  group, the 934ms pass). What is left is **19 of 100 rows carrying neither a
  recording_mbid nor a release_mbid** — bare artist/track text LB never identified.
  Zero rows have a release_mbid without a recording_mbid, so there is no free
  release -> release-group hop to exploit either. A name search is the only route.

### 6.3 The hosted API is the right backend for that name search

Probed against the exact failing names from the log:

| artist / album | hosted `/discography` | public MB said |
|---|---|---|
| The Iron Roses — Molotov Nights | `87c8435b-e948-483a-9b88-c5e81b06d7c1` | **same id** |
| L'Rain — L'Rain | `d1ce5cbf-bc7d-4fdd-aba5-6a59c4bf9d82` | **same id** |
| Tinashe — Popstar | `27a54d93-…` (2026-09-25) | `503` |
| Timon Verbeeck, Pieter Koolwijk, Per Störby Jutbring, Grøn | not found | no match |

**`/discography` returns release-GROUP mbids that match MusicBrainz exactly** — so
the dedupe key, the CAA `release-group/<id>` art URL and the LB genre lookups all
keep working. (`/album/<t>/<a>` returns a RELEASE id and does NOT; that is a
per-route limit, not an API-wide one. Do not generalise it — I did, and was wrong.)

Cost: 195–358ms cold, ~80ms warm, versus ~1.9s for rate-limited public MB, and one
call covers every album by that artist rather than one search per album. `?type=Album`
is NOT worth it — 2.4s on a different cache key, and it only trims 580 entries to
385 because Live/Compilation still count as primary type Album.

**The deciding argument is other users, not this machine.** Setting `mb_base_url`
fixes Simon's latency; LBF ships to people with no mirror, whose default path is
public MB at 1 req/sec — a ~23s stall in a background warm, every time.

Caveats on record before this is built: matching moves in-house (MB's `score >= 90`
gate is doing real work server-side), payloads reach 104KB for prolific artists so
cache the title->mbid map and never the raw JSON, and `/artist/<name>/mbid` picks the
most popular on a name collision — pass `?mbid=` from the candidate's `artist_mbid`
to remove the guess. **It buys speed and removes a rate-limited public dependency; it
does not improve coverage.** The four names MB missed, the hosted API misses too.

---

## 7. THE CHUNKED INGEST NEVER RAN — 0.9.176's fix was broken, FIXED in 0.9.178

Two builds shipped with a chunk driver that could not complete a pass. See CLAUDE.md
for the full write-up; the short version is that
`Slim::Utils::Timers::setTimer($obj, $when, $cb, @args)` invokes `$cb->($obj, @args)`
— it **hands `$obj` back** — and the driver read its self-reference from the `$obj`
slot. Turn one runs inline and works; turn two gets `$self` undef and schedules
`undef` as the next callback, which LMS dies on inside its own timer loop, outside
any plugin eval. Nothing is logged. The chain stops.

Field signature, from the live log:

```
16:01:54.13  feed 'all' — 409 releases, 15/15 days, 34185s old
16:01:54.57  feed 'all' — 409 releases,  0/15 days, 86401s old (revalidating)
16:01:58     Found 429 releases in payload.releases      <- fresh fetch
16:02:10     feed 'all' — 429 releases,  0/15 days       <- rows in, coverage NOT stamped
```

Zero `store: ingested` lines since 0.9.176 went in, and zero errors. The feed store
was doing nothing: every open refetched, ingested two chunks, and stalled.

It only became *visible* on 2026-08-22 because the day rolled and the 24h freshness
check flipped the feed from `15/15 days` to `0/15`; before that the coverage left by
the last pre-0.9.176 synchronous ingest was still being read as fresh.

**The stub was the real defect** — `t_ingestchunk.pl` called `$cb->(@args)`, dropping
`$obj`, so the suite was green against a driver that could never work. It now
replicates LMS's convention, and `step1` counts a non-coderef callback rather than
dying so a recurrence reports a red line instead of aborting at exit 255 with no
FAIL. Against the pre-fix driver: 16 red, reproducing the field symptom exactly
(14 of 60 members stored, 0 day-coverage rows, `ok_at` undef).

**A stub for a host API must replicate that host's calling convention.** The three
steppers in `Browse.pm` had it right all along and document it inline.

---

## 8. STAGE 2 — BUILT in 0.9.180, and what was deliberately NOT built

Stage 2 was gated on §6's numbers from the start. With them in, three of the five
scoped pieces were built and two were dropped **because the measurement said so**.

### 8.1 Ordered feed chain (2a) — BUILT

`warmFeeds` now chains **For You → All Releases → MuSpy**, calling back when the
last lands; `Plugin.pm`'s `_warmTick` starts `warmCache` from that callback instead
of firing both in the same turn. Previously both were fire-and-forget, so "feeds
first" meant only "issued first".

**On a warm store this changes nothing** — §6 measured all three feeds ending within
0.01s, served from the store. It matters on a COLD store, which is what a new user
and every dev build has, and it is what the stated priority actually asks for.

**Ordering creates a failure concurrency could not have:** one hung feed strands
everything queued behind it. Two guards, both asserted:

- every `onError` advances the chain (a silent dead end there would cost the whole
  warm, not just that feed), and
- `WARM_FEED_CHAIN_MAX` (120s) bounds the entire chain, after which `warmCache`
  starts regardless. Deliberately generous: each feed carries its own timeout, so
  this only fires on a genuine wedge, and cutting a slow-but-working feed short
  would lose that feed for the day.

Covers stay fire-and-forget off each feed as it lands. Chaining the next feed behind
~450 cover fetches would make the ordering worse, and prompt artwork is its own
requirement.

### 8.2 The building state (2b/2d) — BUILT

New string `PLUGIN_LBF_BUILDING` ("Still being built — check back in a moment"),
rendered **immediately**, not behind a watchdog. §6.1 settled that: a cold open is
**52.8s**, so a watchdog would expire on essentially every cold open while showing
Material's three dots in the meantime. A watchdog only pays under ~8s.

`PLUGIN_LBF_BUILDING` is deliberately distinct from `PLUGIN_LBF_NO_TRENDING`. The
latter is an affirmative "nobody you follow has listened"; conflating them is what
made a cold open read as a broken feature. `_buildAlbumsData` signals the difference
by handing back **undef** rather than the empty arrayref every other exit uses.

### 8.3 The in-flight guard (2b) — BUILT

A module-level `%BUILDING` registry, one flag per view. Deliberately **not** a cache
and **not** in `kv`: it answers "is someone building this right now", which is only
ever true within one process. A stale flag read from disk would render the building
row for ever with nothing running.

Three properties, each with its own assertions in `tools/t_buildingstate.pl`:

1. **A second caller starts no second build.** The reason this matters is
   [[lbf-lb-rate-limit-shared]] — a warm build and a user tap previously ran two
   complete fan-outs, doubling traffic against the constraint that produced the
   0.9.177 429 incident.
2. **The flag is always released.** A leaked flag is strictly worse than no guard:
   the view says "still being built" for ever, and no TTL can clear an in-process
   registry. `_buildAlbumsData` therefore releases by **wrapping `$onDone` once**
   rather than clearing at each of its 8 exits — the suite asserts the count is
   exactly one, so a new early return cannot reintroduce the leak.
3. **Ownership.** A caller that merely FINDS the flag set must not clear it —
   clearing another build's flag would let a third caller start the duplicate the
   guard exists to prevent. Every release is `if $owns`, asserted as having no
   unguarded `_buildingEnd` in either sub.

### 8.4 NOT BUILT — the genre demotion (deliberate)

The original stage-2 sketch had each feed's genre pass folded into that feed's stage,
and this session's plan went further and proposed demoting the 186s Last.fm rung to
background. **Both were dropped.** `warmCache` carries a documented reversal:
genres were moved to run FIRST, with a measurement — chained behind
playlists/follow/trending, "the ladder did not start until many minutes into the
tick, so every view opened bare in the meantime" — ending with *"do not chain them
back onto the end."* Demoting the Last.fm rung would reintroduce exactly that, and it
contradicts [[lbf-genre-ladder-spec]], where a bare view is a BUG rather than a
degraded state. The ladder is also already For-You-first, so it satisfies the
priority ordering on its own, and it contends for the Last.fm budget rather than the
ListenBrainz one the followers path is bound by.

### 8.5 NOT BUILT — covers demotion (deliberate)

Proposed and dropped for the same class of reason: the covers stage IS what makes
artwork appear, and artwork failing to populate on a cold start was one of the
original complaints. Deferring it pushes the wrong way.

### 8.6 NOT BUILT — user-activity deferral (2c)

Still unbuilt, and now lower value than when scoped: the in-flight guard removes the
specific contention it was aimed at (a warm build racing a user tap), which was the
concrete case behind "a clicked-into view should get priority". Revisit only with a
measurement showing background work still delaying an open.

### 8.7 Scope note — Playlists does not get the building row

2d asked for the building state on *every* unready view. It is applied to the three
follower views, which are the ones with a ~50s cold build. The Playlists open path
resolves per-playlist from `kv` with its own `PLAYLIST_TIMEOUT` watchdog and a
different notion of "unready"; giving it the same treatment needs its own look, and
is not covered by `t_buildingstate.pl`.

### 8.8 THE BUILDING ROW DID NOT APPEAR — 0.9.180 shipped it half-built, fixed 0.9.181

Reported from the field against a verified-installed 0.9.180: *"do not get still being
built message just materials loading for too long."*

**The defect.** The guard was written for the SECOND caller. On a cold open
`_isBuilding` is false, so the first opener took the flag and then carried on into the
fan-out holding `$callback` to the end — ~50s of Material's three dots, in the
commonest case there is. The building row could only ever appear to someone who opened
the view while a build was ALREADY running, which is the rare case.

**The fix.** Render the row the instant a cold build starts, and clear `$callback`.
That detaches the render from the build rather than cancelling it: the fan-out is
async and holds its own closures, so it completes into the cache, and every later
render path is already `if $callback`, so none fires twice into a callback the skin has
finished with. The next open reads the cache and is instant.

`_buildAlbumsData` is data-only — its view renders in the caller — so it gained an
`$onPending` hook fired when a cold build starts, distinct from `$onDone` because the
build genuinely still has to finish. `resolveTrendingAlbums` wraps its callback to
render at most once, so the building row and the real list cannot both fire.

**The warm passes neither** a render callback nor `$onPending`. It wants completions;
handing it a placeholder would advance the chain before the data existed.

**THE TEST LESSON, which is the durable part.** `tools/t_buildingstate.pl` was fully
green against this — 34 assertions, five anti-tests, all passing. Every one of them
checked the guard's BOOKKEEPING: the flag is taken before a fan-out, released on every
exit through a single wrapper, never released by a caller that did not take it. Not one
asked *what the user sees on a cold open*. Section 7 now does, and reverting the source
to 0.9.180 turns it red where the old suite was green.

**A guard's bookkeeping being provably correct is not evidence that the thing it
guards behaves correctly.** When the feature is "the user sees X", at least one
assertion has to be about X.

### 8.9 VERIFIED in the field, 0.9.182 — and where the cost sits now

0.9.181 fixed the first-opener case but 0.9.182 was needed to PROVE it, because
0.9.181 instrumented the tracks cold start and not the albums one — the single path
that misbehaved was the single path with no log line. Lesson worth keeping: when two
paths implement the same behaviour, instrument BOTH or neither; the one you skip is
the one that breaks.

Live log, 2026-08-22 20:07:

```
20:07:20.7290  albums (this_year): cold build started — rendering the building row
20:07:20.7290  albums (this_year): rendering the building row (cold build just started)
20:07:24.55    albums (this_month): a build is already in flight — not starting a second
20:08:01.7984  albums (this_year): dropped a second render (the real list)
20:08:11.6975  albums (this_month): rendering the real list
```

Build-start and render share a millisecond — the row is immediate. Repeat opens during
a build hit the guard and start nothing. The render-once wrapper drops the real list
for a view the user has already left.

**THE DOMINANT COST HAS MOVED, and this is the number to attack next:**

| build | total | of which |
|---|---|---|
| `this_year` | 41.1s | **streaming gate 32.4s** |
| `this_month` | 50.1s | **streaming gate 27.7s** + name-resolve 15.5s |

The ListenBrainz fan-out is down to 3.7–6.0s and MusicBrainz is largely out of the
path. What is left is the **streaming gate** — a Qobuz/Tidal/Deezer search per
candidate over a ~60-album pool. Every earlier suspect (the 429 storm, the serial MB
searches, the ingest stall) is resolved; do not re-investigate those.

Resolver note: `this_month` spent 15.5s on 10 unmapped rows and the window shows 19
hosted calls against 12 MusicBrainz ones — the hosted tier works, but these rows fall
back often. Consistent with §6.3: it buys speed, not coverage.

**Residual, accepted by Simon 2026-08-22:** the result lands in cache but the OPEN view
does not refresh itself — the user backs out and re-enters. Material's `nextWindow`
semantics could auto-update it. Not built; recorded so it is a choice, not an oversight.

### 8.10 "Check again", and the building row on EVERY unready view (0.9.183)

**What `nextWindow` can and cannot do — verified, because the first version of this
note overstated it.** There is NO server push for a browse page. A plugin cannot
refresh a page the user is sitting on; `needsRefresh` is client-side only and a
history entry cannot be invalidated from the server. So the building row **cannot
turn itself into the real list**. Earlier wording in this doc implying it could was
wrong.

What Material does honour is `nextWindow` on a ROW — and **only when that row's
response is EMPTY** (`browseHandleNextWindow`, browse-functions.js:834):

| value | effect |
|---|---|
| `refresh` | re-fetch the page the row lives on |
| `parent` | one extra `history.pop()` first |
| `grandparent` | two pops |

So `_checkAgainItem` returns `{ items => [] }` and does nothing else. Material pops
back and re-walks the view: cache warm by now → the real list; still building → the
building row again. It is `_refreshItem` with the cache-drop removed.

**Verified server-side against the live server**, not assumed: browsing the plugin's
own CLI menu shows `nextWindow: "refresh"` emitted on the existing Refresh and
Sorted-by rows —

```
Sorted by Release Date (tap to change) | nextWindow= "refresh"
Refresh (force update now)             | nextWindow= "refresh"
```

— and those are the rows that demonstrably reload a feed in place in Material today.
The Check again row is structurally identical to them.

**All four unready views now carry it**, which is what "any view that's not ready"
asked for: weekly tracks (`_resolveTrending`), both album ranges
(`_buildAlbumsData`), a cold playlist (`resolvePlaylist`, ~12s — 4 playlists took
48.6s on the warm) and the follow feed (`_resolveFollow`).

**`_resolveFollow` releases through its own closure rather than by wrapping
`$callback`, and that is deliberate.** It is also on the warm path, where `$callback`
is undef and the single terminal reads `if $callback` to decide whether to build the
result rows AT ALL. Wrapping would make that always true and render rows the warm
never uses. Asserted, so a later "tidy-up" cannot unify the two shapes.

**A flag expiry timer now backs every release** (`BUILDING_MAX`, 180s). The test
header has always said a leaked flag is worse than no guard — in-process registry, no
TTL, view stuck on "still being built" for ever — and adding two more views made the
uncovered case real: an async chain that never calls back releases nothing. Every
caller still releases its own flag; the timer is the braces.

**A compile-order trap worth remembering:** `_checkAgainItem` used `MENU_REFRESH`
while defined ABOVE the constant, which is a bareword error under `use strict` — the
subs were moved below the constants. `t_loads.pl` caught it; `perl -c` on a file with
its dependencies stubbed would not necessarily have.

### 8.11 The feeds do NOT get the building row — they get single-flight instead (0.9.184)

Asked whether New Releases / All Releases should carry the building row too. **No**,
and the reasons are structural rather than a judgement call:

1. **They are already stale-while-revalidate.** `_feedFromStore` returns the stored
   rows PLUS a `$stale` flag, so however old the store is the user gets data at once
   and the refresh happens behind them. The follower views have no equivalent.
2. **A fetch failure degrades to the stored copy**, not to an empty view — "a
   ListenBrainz outage degrades to slightly stale data rather than to an empty menu".
3. **The only unready case is a completely empty store** (first open after install,
   or after a wipe), bounded by `FEED_TIMEOUT` at 10s.

Point 3 is the decider, and it is the SAME threshold argument as §6.1 pointing the
other way: the building row won at 52.8s because a watchdog would expire on every
cold open. At ≤10s, once ever, a building row plus a "Check again" tap is WORSE than
letting it load — it adds a tap to something about to finish.

**But the cold path had a real defect.** `%REVALIDATING` guards concurrent fetches
`if ($bg)`, and `$bg` is `!$p{onDone}` — so an OPEN-path fetch takes no flag at all.
On a warm store that is harmless (the extra walks read the store). On a cold store
the three-plus XMLBrowser walks one tap produces each fire their own ListenBrainz
request for the identical URL, and `%FEED_MEMO` cannot help because it caches
COMPLETED results, none of which exists for another 2-10s.

Fixed with a proper single-flight (`%INFLIGHT`): the first caller fetches, the rest
are parked and answered from that one result.

- **Both outcomes fan out.** Parking callers and answering only the first would turn
  a duplicate fetch into a browse that never renders — strictly worse than the race
  it replaces. Each waiter is called inside its own `eval`: they are unrelated browse
  sessions and one dying must not strand the others.
- **Same argument SHAPE as the primary.** `_handleError` hands `onError` a STRING,
  not the response object, so the message is derived once and both get it.
- **The key describes the REQUEST, not the feed** — memo key (sort/past/future/days/
  window) PLUS the headers. Without the headers a token holder arriving second is
  parked behind an anonymous fetch and their token is silently never sent, making the
  request LBF issues depend on which walk arrived first.

**`t_tokenfree.pl` caught this landing, and the way it broke is the lesson.** Its
harness recorded requests and never answered them, so once single-flight existed its
later calls were correctly parked behind its own earlier ones and three assertions
failed. That was the guard working. The harness now DRAINS each request after
recording it, and snapshots `errors`/`done` BEFORE draining so the drain's own
failure is not reported as the call's.

**And the repair hid something:** with the drain in place, deleting the headers from
the key produced ZERO red — `t_tokenfree` no longer covered it. The property is now
asserted where it belongs, in `t_feedsingleflight.pl` §6, which goes 3 red against
that mutation. *A test that stops failing after a harness fix has stopped testing
something — check what it still catches.*
