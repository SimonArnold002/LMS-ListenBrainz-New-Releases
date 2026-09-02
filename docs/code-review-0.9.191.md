# Code review — 0.9.191 (the forced warm, the Spotty adapter, the cover-warm rework)

**Reviewed 2026-09-02. ALL THREE FINDINGS ARE FIXED**, in the same session — each carries a
**FIXED** note recording what was done, what the guard is and what the anti-test counted.
Finding 3 was first recorded as accepted-but-deferred and then taken, on Simon's call, in the
form that removes the second code path rather than repairing it.

**Scope.** `@{upstream}...HEAD` is empty (`dev` == `origin/dev` at `3cb96f0`), so the diff taken
was `main...HEAD`: 65 files, ~30,500 insertions, of which ~11,800 lines are Perl across
`API.pm`, `Browse.pm`, `DB.pm`, `Plugin.pm`, `Settings.pm`, `DSTM.pm`, `Diag.pm` and
`SingleFlight.pm`.

Per the Review Ledger (sections A–C) the full diff was read but effort was **weighted onto the
five commits since `cab9450` (0.9.186)**, which is where `docs/code-review-0.9.184.md` stops:
the Spotify/Spotty adapter, the CAA `.jpg` switch, the cover-warm rework, the `force => 1` warm
fetch, and the People-You-Follow cover warm. Nothing already recorded in ledger A/B/C is
re-reported.

**Both findings that were fixed are in the SAME feature**, and that is the shape worth
remembering rather than either bug: 0.9.190 changed the warm from a background revalidation
into a **foreground caller**, and both defects are consequences of that role change landing in
code whose guards were written around the old one. Neither is visible from the warm's own call
site; both are two frames down, in decisions made about `$bg`.

---

## Verified clean (recorded so the next review does not re-derive it)

- **Spotify/Spotty adapter.** `run`/`runTrack` signatures match the `_findPlayable` /
  `_findPlayableTrack` call sites; `_albumMatches` arity is correct; `_attachFavUrl`'s early
  return skips only `favorites_url` and nothing else on the item; `_rebuildStreamItems` and
  `_streamingAdapters` guard the same OPML symbols; `svc_priority_spotify` is initialised in
  `Plugin.pm`, listed in `Settings::prefs`, handled in `Settings::handler`, and rendered by
  `settings.html` through `serviceStatus`'s `lbf_services` loop.
- **`_candReleaseType`'s `album_type` insertion** and the `total_tracks > 3` guard are inert for
  Qobuz/Tidal/Deezer (the field is absent, so the count reads 0) — no regression to the existing
  single/EP filter.
- **The CAA `.jpg` change is consistent across all four sites**: `coverArtUrl`, `Plugin.pm`'s
  size-ladder regex (`s{/front-\d+(\.\w+)?$}{…}e`, whose `$1 // ''` handles the non-participating
  group), `_warmCovers`' spec splice, and the `lbf:imgwarm:` version bump reaching
  `retirePrefixes`. `Diag.pm`'s extensionless probe URL is unaffected.
- **`_coverTick` / `_coverLaunch`.** The `$coverPumping` re-entrancy guard and the once-only
  `$fired` guard are both correct, and `_coverMaybeEnd` cannot close the stage while requests
  are outstanding.
- **Completion-hook coverage.** Every terminal in `_resolveTrending` reaches `$finish`
  (including the overridden `getFollowing` `onError`); `_buildAlbumsData`'s wrapper covers all
  twelve early returns; `warmFeeds`' chain advances on both `onDone` and `onError` and is
  watchdogged.

---

## 1. `force => 1` does not reach MuSpy's store short-circuit — the nightly warm still warms yesterday

**FIXED.** The store read is now gated `if ($stored && !$stale && !$force)`, and the block
comment that asserted the opposite has been replaced with one stating that this sub has **two**
short-circuits and that `force` must gate both.

`getMuSpyReleases` applied `force` to the memo only:

```perl
if (!$force && (my $memo = _memoGet($memoKey))) { ... }     # gated
...
my ($stored, $stale) = _feedFromStore($feed, undef, undef, 0);
if ($stored && !$stale) { $args{onDone}->(...); return }    # NOT gated
```

The comment above the sub said *"MuSpy has no store short-circuit (it always fetches), so gating
the memo is the whole of it."* That is untrue — the block quoted above is one, differing from the
LB feeds' only in that it has no day-coverage test.

**Why it bites every night rather than occasionally.** `WARM_INTERVAL` and `FEED_STALE_AFTER`
are both 24h. So any browse inside the window leaves a store that is populated and **not**
stale, and the nightly forced warm returns those rows and issues no request at all. That is
exactly the defect `force` was introduced to fix for the other two feeds, reached through the
other door — and it is invisible in `warmstats` for the same reason the original was: the stage
completes, quickly, having done nothing.

**Guard.** `t_feedsingleflight.pl`, new section *MUSPY HAS TWO SHORT-CIRCUITS, AND force MUST
GATE BOTH* (9 assertions). It installs a store that ANSWERS and is FRESH — the state in which
the short-circuit exists at all — then pins: unforced makes no request and answers from the
store; forced goes to the network **and answers with what the fetch returned, not the stored
copy**; and a forced fetch that FAILS still answers, degrading to the stored list, so the
best-effort contract is unchanged. The memo assertion alone could never have caught this: the
memo is a 5-second window.

**Anti-test.** Reverting the store gate to `if ($stored && !$stale)` → **4 red**, all inside the
new section.

---

## 2. The two dedupe guards became mutually invisible when the warm moved to the foreground

**FIXED.** `%REVALIDATING` is now claimed by **every** fetch (it still suppresses background
refreshes only), `%INFLIGHT` is claimed by **every** fetch (so a background revalidation can be
parked on), `$fanout` and the leak watchdog run for both roles, and `$done` / `$failed` release
the claim unconditionally.

`_fetchReleaseFeed` had one guard per role, and each was set only in its own role:

```perl
my $bg = !$p{onDone};
if ($bg) { return if $REVALIDATING{$feed}; $REVALIDATING{$feed} = 1 }
...
unless ($bg) { ...park on $INFLIGHT{$ikey}...; $INFLIGHT{$ikey} = [] }
```

So a background fetch could not see a foreground one and vice versa. **That was harmless right
up until 0.9.190**, because until then the warm's fetch *was* the background revalidation — it
set `%REVALIDATING`, and the overlap was impossible by construction. `force => 1` made the warm
take the `onDone` branch, and from that build a browse-triggered revalidation could run
concurrently with the nightly warm: two ListenBrainz requests and **two ~3,000-release chunked
ingests of the same payload**, which is the one thing on this path that must not happen twice
([[lbf-ingest-event-loop-stall]]).

**Both guards are kept, with one job each**, rather than collapsing them:

| | keyed on | claimed by | blocks |
|---|---|---|---|
| `%REVALIDATING` | the **feed** | every fetch | background refreshes only |
| `%INFLIGHT` | the **request** (memo key + headers) | every fetch | nobody — foreground callers PARK on it |

The asymmetry is the point. A background refresh has an answer on screen already, so skipping is
free and the coarse key is right: two revalidations of one feed differing only by sort are still
two requests, and ListenBrainz's rate limit is per-user, not per-question. A foreground caller
**owes an answer** and can never simply return, so it parks — and only on an *identical* request,
because fanning one result out to a caller that asked a different question would be worse than
the duplicate fetch.

**Three consequences of letting a background fetch hold `%INFLIGHT`, all handled:**

- `$fanout` lost its `return if $bg`. It is the only thing that releases the claim, and a
  background fetch may now be carrying foreground waiters.
- **The leak watchdog is armed for a background fetch too.** This is not belt-and-braces: a
  background callback that never arrives would otherwise strand every later cold open of that
  feed on a list nothing drains — the permanent failure `%INFLIGHT_TIMER` exists to prevent,
  newly reachable from the one role that used to be exempt. It also clears `%REVALIDATING`, or
  one dead background fetch would suppress every future revalidation of that feed for the life
  of the process.
- `$failed` keeps its early exit for a background fetch **with no waiters** (release the claim
  and stop, exactly as before), so the log line and the memo refresh still belong to answering
  someone rather than to a silent revalidation.

**Guard.** `t_feedsingleflight.pl`, new section *THE TWO GUARDS CAN SEE EACH OTHER*
(13 assertions), driven against a **stale but populated** store — the state both roles meet in.
It pins both directions: a browse arriving during a forced warm renders instantly and does not
revalidate; a forced warm arriving during a revalidation parks and is answered by it; the claim
is released so a later browse can revalidate again; and a **failed** background fetch still
answers the caller parked on it.

**Anti-test — three separate mutants, deliberately.** The two guards close the overlap from
opposite directions and each is invisible to the other's assertions:

| mutation | red |
|---|---|
| only `$bg` claims `%REVALIDATING` | 1 |
| only `!$bg` claims `%INFLIGHT` | 5 |
| restore `return if $bg` in `$fanout` | 3 |

**The first mutant is the one that matters as a lesson.** The first cut of this section asserted
only the same-question case, which `%INFLIGHT` satisfies on its own — so it passed with the
per-feed guard removed entirely. The case that distinguishes them is a browse asking a
**different** question (another sort) of the **same** feed. Two guards need two cases.

---

## 3. Trending Albums warms release-group covers that no row will ever request

**FIXED — and fixed by removing the second path rather than repairing it, on Simon's call:
"fix it so it works like the others, we don't want to maintain two different paths to this."**

`_warmTrendingCovers` (0.9.191) queued the **release-group** cover for every aggregate carrying
a `release_group_mbid`. But `_trendingAlbumRow` used that URL only on its ICON-fallback path, so
an aggregate with a `caa_release_mbid` rendered the **release** cover instead. The two conditions
are not the same test and are not even correlated — a mapped aggregate normally has both ids:

| | row asks | warm asked |
|---|---|---|
| release-group cover | `unless caa_release_mbid` | `if release_group_mbid` |

So every mapped row paid 3 Cover Art Archive fetches (~2.1s each at the measured origin latency)
and 3 `lbf:imgwarm:` markers that nothing would ever read. Bounded at
`TRENDING_MAX` (50) × 2 ranges × 3 specs = **up to 300 wasted requests**, ~78s of background work
at `COVER_CONCURRENCY` 8. The 25-day marker means it is paid once per cycle rather than nightly —
but every dev build wipes `kv`, so in development it was every build.

**A second consequence, found while explaining the first.** `_warmCovers` sorts newest-first and
**the queue order is the priority** — that is the whole of 0.9.189's spec-major rework.
`_trendingAlbumFallbackRel` returned a hashref with no `release_date`, so `('' cmp ...)` sorted
every fallback to the **floor** of the queue in all three spec passes. The genuinely unmapped
rows — the ones with no other art source, most likely to be cold — had their covers queued behind
every mapped row's. A small rerun of the ordering bug 0.9.189 exists to fix.

### Why this view had the problem and no other did

The three feeds each have exactly **one** art shape per row, and — this is the part that matters —
each files its id under the key `coverArtUrl` actually reads:

- LB `fresh_releases` rows carry `caa_release_mbid`, the authoritative has-art signal (absent
  means no art exists, and the artwork-only filter usually drops the row);
- MuSpy rows carry `caa_release_group_mbid`, set once at parse time in `_parseMuSpy` — MuSpy has
  no release-level mbid, so the group is its only art signal.

So `coverArtUrl($rel)` is total for them: one call, one answer. `_warmCovers` is handed the same
rels the view renders and is right by construction; there is no branch to duplicate.

A trending aggregate is the one row shape that can be **either**, per row, in one list — a mapped
listen yields a release mbid, an unmapped one only a release group (the gap `_aggregateAlbums`
exists for, unique to the stats-derived views because LB's fresh-releases payload is MB-derived
and never has it). And `_trendingAlbumRel` filed the group id under `release_group_mbid`, which
`coverArtUrl` does **not** read — so the id was on the rel but invisible to the resolver, and the
row recovered it in Browse.pm with a hand-built second hashref behind an `eq ICON` test. **That
made "which URL does this row use" a decision in the renderer rather than a property of the rel**,
and anything wanting the row's URL without rendering the row had to replay it.

### The fix

- `_trendingAlbumRel` now also carries `caa_release_group_mbid`, exactly as `_parseMuSpy` does.
- `coverArtUrl`'s existing priority — release, then group, then `undef` — makes the choice. That
  ladder *is* the branch that was being hand-rolled.
- `_trendingAlbumFallbackRel` and the `eq ICON` re-test are **deleted**, and
  `_warmTrendingCovers` collapses to one `map` over `_trendingAlbumRel` — the same shape the
  three feed callers use.

Row rendering is unchanged in all three cases (mapped → release art; unmapped with a group →
group art; neither → icon). **One deliberate behaviour change:** `_trendingAlbumRow` also passes
`$rel` to `_releaseDetail`, so an unmapped row's detail page previously showed no artwork and now
shows the release-group cover — consistent with the list row it was opened from.

### Why it survived the 0.9.191 tests, which is the lesson

`t_coverwarm.pl` asserted that the warmed path is byte-identical to what `_buildReleaseItem` puts
on the row, for a mapped album **and** an unmapped stats row. Both were true. It never asked
whether the mapped album should have been queued for the release-group URL **as well**.
**An assertion that every warmed path is correct says nothing about whether every warmed path is
needed** — only counting can see work that is right but unwanted.

**Guard.** §5 now asserts the exact count (one cover URL per row with art × the spec ladder,
nothing spare), that the mapped row does not also warm its group cover, that both shapes resolve
through the *same* builder, that an aggregate with neither id resolves to nothing, and — at
source level — that `_trendingAlbumFallbackRel` is gone and the row no longer re-tests for `ICON`.

**Anti-test.** Restoring the 0.9.191 shape (drop the art key from the rel, put the ICON branch
back in the row, re-add the conditional second rel in the warm) → **5 red**, including the count
reading **9 instead of 6** — the waste itself, which is what nothing measured before.
