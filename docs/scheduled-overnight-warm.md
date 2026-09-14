# A fixed overnight clock for the warm — design, before any code

**Status: DESIGNED, NOT BUILT. 2026-09-11.** This closes the last unbuilt item of the
overnight-preparation direction — *"a fixed overnight clock; the timer is still 24 hours
relative to STARTUP"* (CLAUDE.md, and `docs/overnight-detail-prewarm.md` "Still open").
Nothing here changes what the warm *does*; it changes **when it starts** and **how often a
restart re-runs it**.

**`docs/cache-priority-refactor.md` IS THE AUTHORITY** for anything about warm order or
priority. `artwork-and-event-loop-rework.md` and `warm-ordering-and-follower-latency.md` were
superseded by it and are kept for their measurements only — do not take a stage list from
either. This document does not re-open the adopted plan; it builds the one item that plan
explicitly left out, its **Remaining implementation #2**:

> *"A fixed overnight schedule and incremental regular-update policy using that queue. The
> current timer remains 24 hours relative to startup."*

Both halves are in scope here: the fixed schedule (§4A/§4B) and the incremental
regular-update policy (§4E). `docs/overnight-detail-prewarm.md` holds the original
requirement capture; its "Still open: a fixed overnight clock" line is what this closes.

Three things in the adopted plan constrain this design before it starts, and all three were
checked against the code rather than taken from the older docs:

- **Detail preparation is the REMAINDER phase** (sixth implementation, 0.9.204). Dispatch
  stays closed from the start of a feed warm through both ListenBrainz metadata passes and
  both Last.fm tails. The 0.9.200 text describing Last.fm yielding to detail was reversed by
  that build; `_detailPriorityBusy` and `DetailWarm::busy`'s own comment are the current
  contract.
- **Artwork has priority by agreed direction**, not by accident — *"show cached release lists
  quickly and give artwork priority"*. In-flight downloads outrank Last.fm and detail; only an
  unchecked (not-yet-scanned) queue entry does not. §5 depends on this.
- **Stated assertion counts are load-bearing** in that document, and were corrected on
  2026-09-10 with the note that a drifting count *"reads as a checksum and is not one"*. Any
  suite this work extends must have its count updated there in the same commit — §6.

---

## 1. The premise, corrected — and the evidence

The requirement was raised as: *"For You updates only once a week on a Monday at 00:00 UTC,
the global All Releases daily — so we are wasting calls pulling For You daily."*

**That is not what ListenBrainz does, and a weekly For You pull would make the plugin
staler, not cheaper.** Checked against the ListenBrainz server's own production crontab
(`docker/services/cron/crontab`, metabrainz/listenbrainz-server, read 2026-09-11):

```
# Request user fresh releases daily
0 3 * * * root ... manage.py spark request_fresh_releases --threshold 10
```

Three facts follow, and they decide the whole design:

| feed | how ListenBrainz produces it | real cadence |
|---|---|---|
| **For You** — `/1/user/<user>/fresh_releases` | a Spark job requested by cron, written to CouchDB | **daily, requested 03:00 UTC** |
| **All Releases** — `/1/explore/fresh-releases/` | `get_sitewide_fresh_releases` — **live SQL against the MusicBrainz database** per request, plus listen counts from Timescale | **continuous; no batch job at all** |
| Created for You playlists | `request_troi_playlists --slug weekly-jams` / `weekly-exploration` | weekly, requested hourly on Sun+Mon, generated per the user's own timezone |

- **For You is daily.** `request_fresh_releases` defaults its CouchDB database name to
  `fresh_releases_<YYYYMMDD>` — a new database per day, which is the same fact from the other
  side. Pulling it weekly would serve up to six-day-old personalised recommendations.
- **All Releases has no update time to sync to.** It is computed from MusicBrainz on every
  request, so it changes whenever MusicBrainz changes. There is no 00:00 batch to wait for.
  Our daily pull plus the existing 24h `FEED_STALE_AFTER` revalidation is already the right
  shape for it.
- **The Monday 00:00 cadence is real, but it belongs to the playlists**, and the plugin
  already aligns to it: `API::_secsUntilNextWeeklyRefresh` expires the created-for listing at
  Monday `PLAYLIST_REFRESH_HOUR` (03:00) UTC. That is not in scope here and must not be
  disturbed.

**So: no change to WHICH feeds are pulled daily. Both stay daily.** One further reason not to
stretch the interval: MetaBrainz's own 2026-08-19 status post reports the Spark cluster
failing "every other week", so statistics and playlists do not generate for anyone. A daily
pull rides that out; a weekly pull would sit on a failed generation for a week.

### What a For You pull actually costs

Measured on the live rig (`["lbf","warmstats"]`, 0.9.212, tick of 2026-09-11 08:58:46 UTC):

| stage | elapsed | result |
|---|---|---|
| `foryou_feed` | 0.21s | 40 releases |
| `all_feed` | 1.30s | 2,716 releases |
| `muspy_feed` | 0.00s | 0 releases |

One HTTP request per feed per day. **There are no wasted calls in the daily For You pull.**
The waste is somewhere else entirely — §3.

---

## 2. How the warm works today — the parts that must not break

Reviewed in full before designing, because the ask was explicitly "don't break this".

**The timer.** `Plugin::initPlugin` arms `_warmTick` at startup + `WARM_DELAY` (60s).
`_warmTick` re-arms itself at `time() + WARM_INTERVAL` (24h) at the END of the sub,
synchronously — so the interval is measured from tick START, not completion, and does not
drift. A library scan defers the whole tick by `WARM_SCAN_RETRY` (120s) and re-arms only the
retry, which is correct.

**The chain.** `Browse::warmFeeds` runs For You → All Releases → MuSpy, each starting when
the previous lands, each with `force => 1` so the warm sees what arrived rather than what a
browse left in the memo. A `WARM_FEED_CHAIN_MAX` (120s) watchdog guarantees the callback
fires once whatever happens. Each feed fans out, fire-and-forget, into `_warmCovers` and
`_queueReleaseDetails` — both filtered through `_filterForYou`/`_filterAll` first. The
callback then runs `_warmPlaylistsWhenReady`, which waits up to `WARM_SVC_MAX_WAIT` (300s)
for the streaming plugins, then `warmCache` (genres → playlists → follow → trending).

**The priority ladder already exists, and it already does most of what was asked for.**
This is the important finding: *"pause ongoing background requests, resume when finished,
and keep user interaction first"* is largely built.

| mechanism | what it holds off | where |
|---|---|---|
| `_holdLastfm()` taken for the whole feed chain | the Last.fm genre ladder's per-request `step`, and the detail queue | `Browse::warmFeeds`, `warmCache` |
| `$detailMainReady = 0` at chain start, set 1 only after **both** genre tails | the whole `DetailWarm` queue | `Browse::_warmGenres` |
| `$coverRunning` | Last.fm, and the detail queue beneath it | `_lastfmPriorityBusy` |
| `$lastBrowseAt` + `COVER_BROWSE_QUIET` (20s) | Last.fm and detail entirely; cover width drops 8 → 2 | `_noteBrowse`, `_coverLimit` |
| `DetailWarm::pause` re-checked every `_tick`, re-armed at 5s | the detail queue, per job | `DetailWarm::_tick` |

So a tick that fires while yesterday's enrichment is still draining **already** pauses that
backlog for the duration of the feed pull and resumes it afterwards, and a user who picks up
the remote **already** pre-empts every background tier. The live numbers say the same:
`detail_pending 43`, `detail_active 0`, `cache_checks 1448 / cache_hits 1411 / fetches 37`.

**A warm job is nearly free.** 97% of detail-warm jobs are answered from cache without
touching the network. That kills the obvious "give tonight's new releases a queue boost"
idea before it is written — see §5.

---

## 3. What actually wastes calls

Two things, neither of them the daily For You pull.

**(a) Every LMS restart runs a complete warm 60 seconds later.** Unconditionally. Three
forced feed fetches, the genre ladder (up to its 400-artist Last.fm cap, one request per
second), the playlist listing with `force => 1`, the follower builds. Restart the server five
times over an evening — a build test, a settings change, a crash — and that is five complete
warms, of which only the first can have found anything.

**READ §3.1 BEFORE TOUCHING THIS. The startup tick has three reasons to exist, two of them
still valid, and removing it would be a serious regression.** Only the REPEAT is waste.

### 3.1 Why the startup tick exists — checked, not assumed

It arrived in one commit, `68272fc` (0.8.7, 2026-06-19, the Created-for-You Playlists
feature), whose message states the reason: *"Background warm (startup + daily) pre-resolves
playlists so the view and each playlist open instantly."* Three distinct jobs have
accumulated on it since, and they have to be separated because only one has expired.

**Reason 1 — populate cold caches after a restart. EXPIRED.** The plugin no longer keeps
anything in a tier a restart can empty. `DB::store` is a drop-in over the plugin's own `kv`
table in its own SQLite file (`DB.pm`, "THE `kv` DROP-IN"), the feed data lives in
`release`/`feed_member`/`feed_day`/`feed_meta`, and **since 0.9.203 even an ordinary dev build
preserves both tiers** — where the old `_buildChanged` policy emptied Playlists and Followers
every time. So after an ordinary restart the views are already instant with no warm at all.
This is the reason that has gone, and it is the reason the commit message actually gives.

**Reason 2 — the schedule has no existence outside the process. STILL VALID, and it is the
one that matters.** The daily timer is armed by `Slim::Utils::Timers` in memory. Nothing on
disk remembers that a tick is due. A machine that is powered down at the scheduled hour, or
that restarts more often than the interval, would **never warm at all** if the startup tick
were simply deleted. A fixed clock makes this worse, not better: 24h-from-startup at least
fires on any machine with 24h of uptime, whereas a fixed 05:00 never fires on a server its
owner switches off overnight. **The startup tick is the catch-up, and the fixed clock makes
it load-bearing.**

**Reason 3 — `kvSweep` and `feedSweep` run from `_warmTick` and from nowhere else.**
Verified: those are their only call sites in the plugin. No tick means the `kv` table grows
without bound. `_warmTick`'s own comment already names this trap from the other side — *"the
table grows with UPTIME, a defect that is invisible on any machine that happens to reboot
nightly"* — and the mirror image, a machine that never reaches a tick, is the same defect
wearing the other hat.

**And one recorded reason the +60s timing is actively bad, which is worth keeping in view.**
The 0.9.195 diagnosis (CLAUDE.md): an update cleared every cache, the warm fired
`WARM_DELAY` (60s) later, and the first resolve of the four created-for playlists **pinned 8
tracks as unmatched** — all 8 of which matched on a forced retry seventeen minutes later.
Nothing was missing from any catalogue. The cold pass had run while the box was saturated by
its own boot. That was fixed at the caching layer, so the misses are no longer pinned, but
the underlying fact stands: **60 seconds after startup is the worst moment on the machine to
start a warm.** See §8 question 2.

**(b) The daily tick lands at an arbitrary hour.** `WARM_INTERVAL` is 24h *relative to
startup*. On the live rig right now, the server restarted at 08:57 UTC, so the one tick of
this uptime ran at 08:58:46 UTC and the next will be at 08:58 tomorrow — the middle of the
day, competing with listening, and ~6 hours adrift of ListenBrainz's 03:00 UTC job purely by
coincidence. A server restarted at 21:00 pulls at 21:00 every day, 18 hours after the job.
Neither honours *"the user wakes up to find new material ready and waiting"*.

### 3.2 Verified inventory — what EXISTS, what is only LOGGED, what is ABSENT

Every mechanism this design leans on, read in the source on 2026-09-11 rather than taken from
a doc. Greppable phrases, not line numbers, because line numbers rot. **The middle rows are
the ones that decide the size of this job**: a signal that exists at its site but is only
logged still has to be plumbed, and my first draft called two of those "already reported".

| what | state | where / the phrase to grep |
|---|---|---|
| daily re-arm at 24h from startup | **EXISTS** | `_warmTick`, `time() + WARM_INTERVAL` at the bottom of the sub |
| startup arm at +60s | **EXISTS** | `initPlugin`, `time() + WARM_DELAY` |
| scan defer, re-arms only the retry | **EXISTS** | `_warmTick`, `WARM_SCAN_RETRY` |
| a Monday-aligned UTC clock helper to copy | **EXISTS** | `API::_secsUntilNextWeeklyRefresh`, `PLAYLIST_REFRESH_HOUR` |
| `kvSweep` / `feedSweep` have no other caller | **EXISTS (confirmed)** | both called only inside `_warmTick` |
| caches survive a restart | **EXISTS** | `DB::store`, "THE `kv` DROP-IN"; `RESET_CACHE_ON_BUILD => 0` |
| feed chain holds off Last.fm + detail | **EXISTS** | `warmFeeds`, `my $releaseLastfm = _holdLastfm()` |
| detail is the remainder phase | **EXISTS** | `_detailPriorityBusy`, "the remainder phase" |
| browsing pre-empts everything | **EXISTS** | `_noteBrowse`, `COVER_BROWSE_QUIET`, `_coverLimit` |
| both genre branches settle on success AND error | **EXISTS** | `_warmGenres`, `$branchDone->()` on each `onError` |
| Last.fm per-request watchdog | **EXISTS** | `_warmLastfm`, `setTimer(undef, time() + 90, $failed)` |
| playlist revisit when short | **EXISTS** | `($have->{matched} // 0) >= ($have->{total} // 0)`, "CACHED" IS NOT "FINISHED" |
| retry ladder 1h/6h/24h | **EXISTS** | `MISS_RETRY_SCHEDULE` |
| `detail_pending` readable as a field | **EXISTS** | `detailWarmStats`, surfaced by `_cliWarmStats` |
| **playlist shortfall, per pass** | **LOGGED ONLY** | computed at the grep above, sent to `_dbg` as "revisiting the shortfall"; the stage note is only `"$nPl playlist(s)"` |
| **Last.fm `deferred`, per pass** | **LOGGED ONLY** | `$stats->{deferred}` is structured at the callback but is flattened into text by `_lastfmWarmNote` and then discarded |
| a persisted "when did a tick last run" | **ABSENT** | nothing on disk; `$WARM_TICK_AT` is a package lexical, reset by a restart |
| a scheduled-instant helper | **ABSENT** | — |
| `next_tick_at` in `warmstats` | **ABSENT** | `_cliWarmStats` reports `ticks` and `tick_at` only |
| any follow-up / convergence tick | **ABSENT** | — |

**So the build is: three ABSENT pieces, two LOGGED-ONLY signals to promote to fields, and no
change at all to any EXISTS row.** §4C is the one exception and it is argued separately.

### 3.3 Every carrier that can start or invalidate a warm — enumerated

Asked late and it changed the design, so it is recorded rather than left as a checked box.

| carrier | what it actually does | does it start a feed warm? |
|---|---|---|
| `initPlugin` startup timer | `_warmTick` at +`WARM_DELAY` | **yes** — the only unconditional one |
| `_warmTick` self re-arm | `_warmTick` at +`WARM_INTERVAL` | **yes** |
| `_warmTick` scan defer | `_warmTick` at +`WARM_SCAN_RETRY` | yes, the same tick retried |
| `Browse::refreshPlaylists` — *Refresh playlist matches* in Settings | `warmCache($client, force => 1)` **directly** | **no** — playlists/genres/followers only, no feeds, no sweeps |
| `_refreshItem` — *Refresh (force update now)* on each section | `API->clearFeedCache($w)`, drops the trending keys and the order freeze, returns | **no** — it INVALIDATES; the next browse re-fetches in the foreground |
| `Settings.pm` save | coerces and clamps prefs | **no** — checked, no warm and no timer anywhere in the module |
| `HomeExtras.pm` | routes the three Material home rows to `Browse::home*` | no |
| `DSTM.pm` | registers propagators | no |
| `["lbf","diag"]`, `["lbf","cachestats"]`, `["lbf","warmstats"]` | all three are queries | no |

Two consequences, both of which the design has to honour:

- **`refreshPlaylists` and `_refreshItem` must NOT touch `warm_last_at`.** Neither runs the
  feeds or the sweeps, so neither is "today's warm". A manual refresh at 22:00 must still
  leave the 05:00 tick armed.
- **`_warmTick` is the only feed carrier**, which is what makes §4F below necessary.

### 3.4 THE ONE THAT BREAKS §4B — the detail queue is seeded by the feed warm alone

`_queueReleaseDetails` has **exactly four call sites, and all four are inside `warmFeeds`**.
The browse-side focus path promotes artwork only — that is the 0.9.204 change, *"requested/
revealed list ranges now promote artwork only"*, and the code matches it. `$detailWarmer` is
a lazily-created file lexical whose jobs live in a hash **in memory**, which the adopted plan
states plainly:

> *"The stored feeds are the durable work inventory, and the stored results are the
> checkpoints: after restart, the normal startup feed pass reconstructs the queue and skips
> already cached results."*

**So the adopted plan explicitly depends on the startup feed pass to rebuild that queue, and
§4B was about to delete it.** A restart at 20:00 under the gate as first written would leave
the detail queue empty until 05:00 the next morning — no tracklist or streaming pre-warm at
all for nine hours, on a plugin whose stated requirement is that the user never waits for
one. That is a regression, not a saving, and nothing in §6's tests as first written would
have caught it. §4F is the fix.

---

## 4. The change

Four parts. A and B are the substance; C and D are guards that the fixed clock makes
necessary.

### A. Fire on a fixed local clock, not 24h after startup

**It goes in `Plugin.pm`, not `API.pm`** — modelled on `API::_secsUntilNextWeeklyRefresh`
but not placed beside it. That one lives in `API.pm` because its consumer, the created-for
listing TTL, is in `API.pm`. This one's only consumer is `_warmTick`, so putting it in
`API.pm` would mean Plugin.pm reaching across for a private sub it alone uses. Same style,
same arithmetic-only discipline:

```perl
use constant WARM_HOUR => 5;      # LOCAL hour to start the overnight warm

sub _secsUntilNextWarm {
    my @t = localtime(time);
    my $secsIntoDay = $t[2]*3600 + $t[1]*60 + $t[0];
    my $secs = WARM_HOUR*3600 + _warmJitter() - $secsIntoDay;
    $secs += 86400 if $secs <= 0;
    return $secs;
}
```

`_warmTick`'s re-arm becomes `time() + _secsUntilNextWarm()`. `WARM_INTERVAL` stays as the
documented ceiling and as the fallback if the helper ever returns something non-sensical.

**Why LOCAL and not UTC.** The release window arithmetic is local throughout —
`API::_today` and `DB::_weekStart` both use `localtime` — so a UTC schedule would roll the
warm and the window on different clocks. And the requirement is about the user's night, not
ListenBrainz's. A fixed UTC hour would put the warm at 16:00 in Sydney.

**Why 05:00 and not 03:00 or 04:00.** Two constraints. It must be after ListenBrainz's
03:00 UTC Spark job has actually landed (the job is *requested* at 03:00; the cluster then
takes its time), and it must be outside 00:00–03:00 so the daylight-saving transition can
never make the target hour ambiguous or non-existent. 05:00 local satisfies both for every
zone from UTC−12 to UTC+2. East of that the tick lands before that day's job and picks up
the previous run — the same freshness any fixed schedule gives, and the existing
stale-while-revalidate still corrects it on the first browse.

**DST is handled by recomputation, not by arithmetic.** The helper is arithmetic-only, like
`_secsUntilNextWeeklyRefresh` — no `Time::Local`, nothing to get wrong. On the two days a
year the local day is 23 or 25 hours long the tick lands an hour off target, and the next
tick — computed fresh from the new local time — is back on it. That is the behaviour the
test pins, not an accident to be discovered later.

**Jitter, `_warmJitter()`: 0–1799 seconds, stable per install.** Derived once from a stable
local value (the LMS server UUID, or the configured username) so it survives restarts and
does not change between ticks. Without it, every install of this plugin in a given timezone
hits `api.listenbrainz.org` in the same second. Given that MetaBrainz is publicly asking for
relief from traffic surges, half an hour of spread costs us nothing and is the right thing to
do.

### B. The startup tick STAYS, as the catch-up — it just stops repeating

Per §3.1 this tick is load-bearing and gets more so under a fixed clock. It is not removed
and not delayed into irrelevance. The only change is that it asks one question first.

Record the epoch of each tick (`warm_last_at`, in the same prefs the plugin already uses for
`last_build`). At startup:

- if the build changed (`_buildChanged` fired) → **run the catch-up tick.** A dev build with
  `RESET_CACHE_ON_BUILD` has just emptied the derived tier; it must refill.
- else if **no tick has run since the most recent scheduled warm instant** → run the catch-up
  tick.
- else → **skip the catch-up tick and just arm the clock.**

**The gate is "have you had today's warm?", not a threshold in hours**, and that is
deliberate — it is derived from the same clock helper as the schedule itself, so there is no
second number to tune and no way for the two to disagree. Work it through the cases that
matter:

| the machine | last scheduled instant | behaviour |
|---|---|---|
| always on, restarted 5x in an evening | today 05:0x, tick ran | 1st restart skips, so do the other four — **this is the saving** |
| switched off overnight, on at 09:00 daily | today 05:0x, **no tick** (it was off) | warms at 09:01 every day — **the catch-up still works** |
| always on, no restarts | — | the 05:0x timer does it; startup never involved |
| fresh install, no `warm_last_at` | — | warms, as it must |
| restarted at 04:00, warmed yesterday 05:0x | yesterday 05:0x, tick ran | skips, then the 05:0x timer fires an hour later |

No user-visible behaviour changes in any skipped case: the data is from the same day, and the
feeds' own stale-while-revalidate covers the first browse regardless.

**The skip branch is not a bare `return`.** It still re-seeds the detail queue from the
store, because that queue is in memory and the feed warm is its only seeder — **§3.4 and
§4F, and this gate is wrong without them.**

`warm_last_at` is written when the tick's work is *issued and the sweep has run* — i.e. at
the bottom of `_warmTick`, beside the re-arm — not from an async callback. A tick whose
chain later fails still counts as "the warm ran at this hour"; it is a schedule marker, not a
success record. The `warmstats` table remains the record of what succeeded.

### C. A watchdog on `$detailMainReady`

**This one is a backstop for a narrow path, and the draft overstated it. Corrected here
after reading the branches.** `warmFeeds` sets `$detailMainReady = 0` and only
`_warmGenres`' `branchDone` sets it back to 1, so a `branchDone` that never runs pauses the
detail queue until the next tick. But the obvious routes to that are already closed:

- **both genre branches call `$branchDone` on `onError` as well as `onDone`** — a failed
  ListenBrainz fetch settles the branch, it does not strand it;
- **`_warmLastfm` carries a 90-second per-request watchdog**, so a lost Last.fm callback
  settles too;
- **the feed chain has `WARM_FEED_CHAIN_MAX`**, so `warmCache` is reached whatever the feeds
  do, and `_warmGenres` is the first thing it calls.

What is left uncovered is narrow: `_withGenres` / `_withGenresMirror` failing to invoke its
callback at all, which is not watchdogged on the path `_warmGenres` uses. The live rig shows
`detail_main_ready 1`, so this is **not a fault being observed** — it is an unguarded edge.

The consequence is what makes it worth a few lines anyway: the flag is released only by the
next tick, so under a fixed clock a stall is reliably a **full day**, silently, instead of
being cleared by the next restart. Add a timer armed with the chain watchdog that forces
`$detailMainReady = 1` after a bounded wait and logs at `warn` that it did — same shape and
same reasoning as the chain watchdog, since an `eval` cannot catch a failure inside an async
callback.

**Scope honesty: this is the only part of the design not strictly required by the
requirement.** §8 question 4 asks whether you want it here or as its own change.

### D. `warmstats` reports the schedule

`["lbf","warmstats"]` gains `next_tick_at` (epoch) and `warm_last_at`. An instrument gets
its own assertion or it is decorative — and without these two the whole change is
unobservable on a live server, which is exactly how the current 24h-from-startup behaviour
went unnoticed.

### E. The incremental half — a convergence tick when a pass ends short

**This is the risk §4B creates, and the second half of Remaining implementation #2.** It
would be a real regression to ship A–D without it.

The 0.9.211 correction established that a cold pass **has never matched in one go**, and its
fix is that *"the playlist warm revisits an incomplete list rather than skipping it, which is
what lets the retry ladder run on its own clock instead of on the user's browsing habits."*
The bounded retry ladder is 1h / 6h / 24h. **But a revisit only happens on a warm pass — and
today, most extra passes come from restarts.** §4B removes those. One pass a day would then
be the only revisit, so a list that ends short at 05:00 could not re-attempt its 1h and 6h
rungs at all: the ladder would be sampled once every 24 hours and the fix would quietly stop
working. That is the accidental behaviour the restart warm was providing, and it has to be
replaced deliberately rather than lost.

So: **when a pass ends with work it knows is unfinished, arm one follow-up tick a few hours
later.**

**What that costs, stated exactly — my first draft said "the signals already exist and are
already reported", and per §3.2 that is only true of one of the three:**

| signal | actual state | work needed |
|---|---|---|
| `detail_pending` | a real field on `detailWarmStats`, already surfaced | **none** — read it |
| Last.fm `deferred` | structured in `$stats` at the `_warmLastfm` callback, then flattened into text by `_lastfmWarmNote` and dropped | keep the count at the callback; do not parse the note |
| playlist shortfall | computed per playlist at the `matched`/`total` compare, sent only to `_dbg` | count the short ones in the loop and put the total in the `playlists` stage note |

None of that changes a decision or a TTL. It promotes two values that already exist from log
text to fields, which is the same move 0.9.205 made when it put the Last.fm outcome counts
into the stage note so a stage could not report a content-free `done`.

- Follow-up at **+4h**, which samples the 1h and 6h rungs rather than skipping both.
- **At most two follow-ups between scheduled ticks**, counted in process, so a permanently
  incomplete pass cannot become a 4-hourly poll.
- A follow-up is the **same `_warmTick`**, not a new code path. Feeds are one cheap request
  each, every other tier is checkpointed, and 97% of detail jobs are cache hits — so a
  re-run that finds nothing outstanding costs three HTTP requests and some SQLite reads.
- **No follow-up when the pass ended clean.** That is the whole difference from today's
  restart behaviour, and it is why this is a saving overall rather than a cost.

`warmstats` reports the follow-up count and the reason it was armed, or this is unfalsifiable
in exactly the way 0.9.205's stage notes were added to prevent.

### F. The skip path still re-seeds the detail queue — from the store, not the network

**Without this, §4B is a regression. See §3.4.** The in-memory detail queue is built only by
`warmFeeds`, so a skipped catch-up leaves it empty until the next scheduled tick.

On the skip path, do the fan-out without the fetch: read each feed through the **normal,
non-forced** getters and hand the filtered rows to `_warmCovers` and `_queueReleaseDetails`,
exactly as a feed warm's callbacks do.

**This does no network I/O, and the gate itself is what guarantees that.** The skip only
fires when a tick has already run since the last scheduled instant, so the store is
same-day and `_feedFromStore` returns it as fresh — the stale branch that would kick a
background revalidation cannot be reached. The non-forced getters are the browse path, and on
a fresh store the browse path is a store read. The `force => 1` flag stays exactly where it
is, on the four warm fetches, for the reason its own comment gives.

What the re-seeded queue then does is cheap by construction: it re-verifies checkpoints at
the measured 97% hit rate and fetches only for releases that genuinely never got prepared —
which is the work a restart is supposed to resume. The artwork side is the same story, an
all-warm marker scan that the sixth implementation already made sure cannot masquerade as
network work.

**Do not implement this as a second seeding path.** It is the same two calls the feed
callbacks already make; factor the fan-out into one small sub that both the warm callback
and the skip path call, so a future change to what gets queued cannot apply to only one of
them.

---

## 5. Deliberately NOT changing — do not re-propose these

- **The For You pull does not become weekly.** §1. The premise was wrong; weekly would be a
  regression.
- **No queue boost for tonight's new releases.** `ingestFeed` does return `added`, so it
  could be done — but 1,411 of 1,448 detail-warm jobs are cache hits, so a leftover backlog
  drains in cache reads, not requests, and new arrivals are not meaningfully delayed behind
  it. Measure before revisiting; `detail_pending` on the live rig is 43.
- **The startup tick is NOT removed, and must never be.** §3.1: the schedule exists only in
  process memory, and `kvSweep`/`feedSweep` have no other call site. A future round that
  reads "the fixed clock replaces the startup warm" has misread this document.
- **No new "pause everything" mechanism.** `_holdLastfm` is that mechanism and the feed chain
  already takes one. Adding a second would give two ways to stop the same queues.
- **The cover queue is not paused during the feed fetch, and that is SETTLED, not a gap.**
  My first draft called it a gap to measure. It is not: *"give artwork priority"* is the
  adopted direction's opening line, and the sixth implementation restates it — in-flight
  downloads retain priority over Last.fm and detail, and only an unchecked queue entry stands
  aside. Holding artwork off for a 1.5-second ListenBrainz fetch would invert the one
  ordering the whole refactor exists to establish. Do not propose it again.
- **`PLAYLIST_REFRESH_HOUR` and `_secsUntilNextWeeklyRefresh` are untouched.** Different
  cadence, different upstream job, already correct.
- **Whole-pass limits stay as they are** — `LFM_WARM_ALL` 400, `GENRE_WARM_ALL` 4000,
  `COVER_WARM_MAX` 2000, all confirmed in the source. Reviewing them is **Remaining
  implementation #4** in the adopted plan, a separate item from the #2 this closes, and that
  plan says in terms that it *"does not promise every new release is prepared yet"*. A
  scheduling change cannot make that promise either, and must not be reported as having
  failed to.

---

## 6. Tests — written and run BEFORE the code

House rule: assert at the layer the fix lives, anti-test every suite, and never let a suite
pass against a fix that does nothing.

### New: `tools/t_warmclock.pl`

Drives the real `_secsUntilNextWarm` / `_warmJitter` / startup gate out of mutated copies via
`LBF_API=` / `LBF_PLUGIN=`, the same way `t_weekwindow.pl` and `t_warmstats.pl` do.

1. **The instant is always strictly future**, for all 86,400 seconds-into-day, and never more
   than `86400 + max jitter` away.
2. **It lands on the target hour**, checked by converting the answer back through `localtime`
   — for every hour of the day, on an ordinary day.
3. **The DST days are asserted as designed, not as accidents.** Across the UK spring-forward
   and autumn-back boundaries the answer is within one hour of target, and the *following*
   day's answer is exactly on target. A suite that demanded exactness here would be pinning a
   behaviour the arithmetic-only helper does not have.
4. **The jitter is stable and bounded** — two calls in one process give the same offset, it
   lies in `[0, 1800)`, and it is not zero for every install (a constant-zero implementation
   must go red).
5. **`_warmTick` re-arms from the helper, not from `WARM_INTERVAL`.** Body assertion on
   `Plugin.pm`, the `t_buildingstate.pl` pattern — there is no return value to inspect.
6. **The startup gate**, every row of the §4B table, with the switched-off-overnight machine
   asserted explicitly — **a gate that stopped that machine warming is the regression this
   whole change could plausibly introduce**, and §3.1 reason 2 is why. Plus: build changed →
   tick armed; no `warm_last_at` at all → tick armed; tick already run since the last
   scheduled instant → **no catch-up tick, but the clock IS armed.** That last clause is its
   own assertion: a gate that skipped the catch-up *and* forgot the schedule would stop the
   plugin warming at all, and would pass a test that only checked "no tick ran".
7. **`warm_last_at` is written at the bottom of `_warmTick`**, on the path a failed chain also
   takes.

**Anti-tests (run them, record which assertions go red):** re-arm hardcoded back to
`WARM_INTERVAL`; jitter returns a constant; `_secsUntilNextWarm` allowed to return a past or
zero value; the startup gate made unconditional in each direction; `warm_last_at` written
only from the success callback.

### Extended: `tools/t_detailwarm.pl` and `tools/t_lastfm_priority.pl`

8. **A new tick pauses an in-flight backlog and the backlog resumes.** **Checked first:
   pause/resume at the QUEUE level is already covered** — `t_detailwarm.pl` drives the real
   `pause` callback (*"core/artwork/browse priority pauses detail work"*, then resumption),
   and `t_lastfm_priority.pl` pins the phase boundary (*"general detail warming resumes after
   main enrichment"*). **So do not re-assert those.** What is uncovered is the property one
   level up: a **second `_warmTick` arriving while a backlog drains** takes a `_holdLastfm`
   for its feed chain, clears `$detailMainReady`, and the backlog resumes after the genre
   tails — with a control assertion that the backlog was actually mid-drain, or the test
   passes against a queue that was already empty.
9. **The `$detailMainReady` watchdog fires.** With the genre tails never called, the queue is
   released after the bounded wait — and a control assertion that it is *not* released before
   it. A bounded wait must report firing (`t_test-suite-traps` rule), so the suite asserts the
   `warn` line too.
10. **Browsing still wins.** Already covered — `t_lastfm_priority.pl` asserts *"browsing
    pauses Last.fm"* and *"Last.fm resumes after browsing is quiet"*. **Re-run it as a
    regression guard; do not add a second copy.**
11. **The convergence tick (§4E), all four properties:** armed when the pass reports
    partial/deferred/pending work; **not armed when the pass ended clean** (the control
    assertion — without it the suite passes against a tick that always re-arms); capped at
    two between scheduled ticks; and the follow-up leaves the next scheduled instant
    unchanged. Anti-tests: make it always arm, never arm, and drop the cap.

### Extended: `tools/t_warmstats.pl`

12. `next_tick_at`, `warm_last_at` and the §4E follow-up count/reason are present and sane,
    and a report produced before any tick does not claim a schedule it does not have.

### The §4F assertion, which is the one that would have caught the §3.4 regression

13. **A skipped catch-up still leaves a populated detail queue.** Drive the startup gate into
    its skip branch with a populated store, then assert `detail_pending` is **non-zero** —
    and, as the control, that **no feed HTTP request was issued**, through the same suspending
    stub `t_feedsingleflight.pl` uses. Both halves are required: asserting only "no request"
    passes against a skip that seeds nothing, and asserting only "queue populated" passes
    against a skip that quietly fetched.
14. **Neither refresh carrier is mistaken for a warm.** `refreshPlaylists` and `_refreshItem`
    leave `warm_last_at` and `next_tick_at` untouched — §3.3. Without this a manual refresh at
    22:00 could suppress the following morning's tick, which is the same class of bug as §3.4
    and just as invisible.

### Housekeeping that is part of the work, not after it

`docs/cache-priority-refactor.md`'s Validation section states suite counts — currently **61**
for `t_lastfm_priority.pl` and **38** for `t_detailwarm.pl`. Those were corrected on
2026-09-10 with the standing note that a drifting count *"reads as a checksum and is not
one"*. **Any suite this work extends has its count updated there in the same commit**, and
Remaining implementation #2 is struck from that document's list when §7 passes live.

---

## 7. Live verification on the rig — before this is called done

Over HTTP at `http://plex:9000`, no ssh:

1. Install, restart, read `["lbf","warmstats"]`. **Expect** `next_tick_at` to convert to
   tomorrow at 05:0x local, and `ticks` to reach 1 (first install after a build change is a
   catch-up tick by rule B).
2. Restart again within the hour. **Expect** `ticks` to stay at its value, `warm_last_at`
   unchanged, `next_tick_at` unchanged, and **no feed request in `lbf-debug.log`** — this is
   the call saving, and it is the one assertion the unit tests cannot make.
   **In the same reading, `detail_pending` must be non-zero.** A skipped catch-up that leaves
   the queue at zero is §3.4 happening on the real server, and the two figures have to be read
   together or the saving looks like a success while the pre-warm has silently stopped.
2b. Open a release detail page that the store knows about but nobody has opened. **Expect a
   cache hit, not a live fetch** — this is the requirement in its original words, and it is
   what proves §4F re-seeded something real rather than an empty list.
3. Let the 05:0x tick run. **Expect** `foryou_feed` / `all_feed` / `muspy_feed` to record
   real elapsed times (not 0.00s, which would mean the store answered and `force` regressed),
   and the detail queue to drain after the genre tails.
4. Browse during a drain and confirm the response is not held up, then confirm from the next
   `warmstats` that the background tiers resumed.
5. **Confirm the convergence tick both ways** — this is the step that proves §4E is not
   decorative. A pass that ends with playlist partials or `detail_pending` above zero must
   show a follow-up armed in `warmstats` with its reason, and a clean pass must show none.
   The created-for playlists are the case that matters, since 0.9.211's fix depends on the
   revisit happening at all.
6. Only after 1–6 pass on the real server does `docs/overnight-detail-prewarm.md` lose its
   "Still open: a fixed overnight clock" line, `docs/cache-priority-refactor.md` lose
   Remaining implementation #2, and the CLAUDE.md entry move to done.

---

## 8. Open for Simon, before code

1. **`WARM_HOUR` = 5 local** — agreed, or do you want it earlier (03:00/04:00, closer to
   ListenBrainz's job but inside the DST-ambiguous band) or later?
2. **Does `WARM_DELAY` stay at 60s for the catch-up tick?** The 0.9.195 diagnosis (§3.1) is
   direct evidence that 60 seconds after startup is the worst moment on the machine — the
   cold pass ran while the box was saturated by its own boot and pinned 8 false no-matches.
   The caching fix means a bad pass is no longer *durable*, so this is now a quality question
   rather than a correctness one. Under the new gate the catch-up fires far less often, which
   makes a longer delay (180–300s) cheaper than it used to be. **Recommend raising it; it is
   your call, and it is a separate knob from the clock.**
3. **Jitter at all?** It is the polite thing to do given MetaBrainz's load problems, but it
   makes the tick time unpredictable to within half an hour, which is slightly harder to
   verify by eye on the rig. A logged `next_tick_at` answers that, which is why §4D exists.
4. **Is the `$detailMainReady` watchdog (§4C) in scope for this build**, or does it want to
   be its own small change so a failure in it is not confused with the clock?
5. **§4E's two numbers: a +4h follow-up, capped at two per scheduled tick.** The 4h is picked
   to sample the retry ladder's 1h and 6h rungs rather than skipping both; the cap of two
   stops a permanently short pass becoming a poll. Both are the only genuinely arbitrary
   values in the design — if you would rather the follow-up ran at +2h and +6h explicitly,
   mirroring the ladder instead of approximating it, say so now rather than after the tests
   are written around it.
