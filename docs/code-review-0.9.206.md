# Code review — 0.9.206 (indexed week identity and overlapping Last.fm tails)

**Reviewed and fixed 2026-09-09.** The two findings from the uncommitted
0.9.198–0.9.206 source review are closed in the source tree on top of the built
0.9.206 package. There is deliberately no version bump, zip rebuild or `repo.xml`
SHA change yet.

## 1. Week folders were still addressed by a live numeric position

The 0.9.199 release-card fix added explicit `lbf_release` actions, but 0.9.202
introduced a new week-folder level above those cards. `_buildAllWeekItems` left
that parent on its default XMLBrowser action. A summary revalidation could insert
or remove a week between render and tap; the rebuilt root then resolved the held
`item_id` against the adjacent week.

**Fixed.** Every week row carries an explicit `lbf_week=<week_start>` action using
the registered `listenbrainzfreshreleases items` command. `topLevel` dispatches
that parameter before rebuilding the dynamic root, validates the key, and invokes
the existing exact-week implementation. The returned root query retains
`lbf_week`, so paging re-walks the same week. The original row coderef remains as
the legacy-client path.

**Carrier audit.** `_buildAllWeekItems` is the single row builder reached by the
indexed plugin root, `_buildAllLanding`'s full-feed/cold fallback and the
`LBFAllReleases` Material home shelf through `_buildAllSummaryLanding`. Release
rows inside the folder continue to use their existing explicit `lbf_release`
actions. No carrier is left on a new positional week action.

**Guard.** `t_release_target.pl` verifies the registered command, absence of an
`item_id`, exact natural-key routing, retained root query and fail-closed invalid
target. `t_weeksummary.pl` verifies that both landing builders converge on the
guarded row builder. The empty-string natural key used by the dateless folder is
also exercised explicitly, including its retained root query.

## 2. Concurrent Last.fm passes could buy the same artist twice

For You and All Releases deliberately start independent Last.fm tails, and browse
top-ups use the same worker. Each `_warmLastfm` call bulk-classified its candidates
before queueing. Two calls could therefore snapshot the same artist as missing;
the global busy flag serialized their requests but did not deduplicate them. The
duplicate also occupied one of the second pass's capped slots, deferring a unique
artist behind it.

**Fixed.** A successful durable artist write records a same-process checkpoint for
the shortest durable TTL (one day). Each queued job rechecks that shared checkpoint
at dispatch, after the single request lane has allowed the earlier writer to land.
The candidate queue is no longer truncated before dispatch: the cap is enforced
against the actual `requested` count, so a skipped duplicate frees the slot for
the next unique artist. Failed requests and failed writes record nothing and stay
retryable. The map is pruned when a pass starts.

**Producer audit.** Both `_warmGenres` branches and `_kickGenreFill` converge on
`_warmLastfm`, so daily For You, daily All Releases and page-triggered top-ups use
the same dispatch guard. The one-request global lane, one-second courtesy gap,
browse/artwork priority gates and positive/negative durable TTLs are unchanged.

**Guard.** `t_lastfm_priority.pl` starts two simultaneous passes whose queues are
`[shared]` and `[shared, unique]`, each with a one-request allowance. It proves the
network sees `[shared, unique]`, never `[shared, shared]`, both callbacks finish,
and the second pass reports one fresh checkpoint, one request and zero false
deferral. A companion case proves that a failed shared request creates no
checkpoint and is retried by the overlapping pass.

## Validation

- `perl tools/t_loads.pl`: 20 passed, 0 failed.
- Native `tools/t_*.pl` loop: all 31 scripts passed.
- `perl tools/bench_walk.pl`: cold filter/sort remained millisecond-scale and the
  processed-view memo remained a 0.01 ms hit.
- `git diff --check`: clean.

No schema, cache-family, request pacing, feed ordering or artwork/detail priority
changed.

---

# Round two — the 0.9.206 review of the built tree (fixed in 0.9.207)

A second review of the same tree reported two findings. Both are confirmed and
fixed. **Sweeping the tree for other carriers of each concept found a third site
the review had not reported**, which is recorded here as well.

## Finding 1 — the artwork focus addressed the wrong releases on For You

**Confirmed, and reproduced mechanically before any code changed.**

`_focusReleaseCovers` received the pre-render release list plus a single scalar
offset for the Options block. The level it describes is drawn by `_buildWeekly`,
which inserts a divider before every week and applies `_sortWithin` inside each one.
So Material's row index and the release position drift apart:

| request | rendered at that row | promoted by the old code |
|---|---|---|
| index 5 | the week divider | the first release |
| index 6 | the first release | the second release |
| index 12 | the seventh release | the eighth |

That is the default date sort with a single week, already off by one and drifting a
further row per divider crossed. Under the artist or album sort the within-week
reorder breaks the mapping outright, so no scalar offset could have been correct.

**The sibling call site was always right**, and that is why the defect survived: an
All Releases week draws its releases flat under the Options block with no dividers
among them, so one offset genuinely was sufficient there.

**Impact is bounded and worth stating precisely.** The whole list is still queued —
the focus rotates the queue rather than filtering it — so no cover is ever lost.
What was wrong is the ORDER, which is the entire purpose of a focus pass: the rows
on screen were not the ones warmed first.

### Fix — a slot map, not an offset

- **`_weekGroups($releases, $mode)`** becomes the one carrier of the weekly render
  order: the grouping and the `_sortWithin` call, returning `[{ ws, rels }, ...]`.
  `_buildWeekly` now consumes that instead of re-deriving it.
- **`_renderSlots($lead, $groups)`** produces one entry per RENDERED ROW — the
  release drawn there, or `undef` for a row that draws none (the Options block, and
  every week divider). A level that draws no dividers passes a single group with no
  `ws`, which is how the All Releases week site expresses "flat" explicitly.
- **`_focusReleaseCovers` takes that slot list** and counts defined entries, so both
  the start position and the requested span are exact even when the window spans a
  divider (four rows across a divider cover three releases, not four).
- **`fetchForYou` groups ONCE** and hands the same groups to the renderer and to the
  focus map. Drift is impossible by construction rather than merely unlikely.

### Guard

`t_coverwarm.pl` 131 → 134, new §4e. Every "which release does this row promote"
assertion is paired with the item `_buildWeekly` actually drew at that row, both read
from the same groups. It carries the control this project's 0.9.197 entry insists on —
*the render really did reorder, else the rest proves nothing*.

**Anti-tested three ways, each mutant failing only its own property:**

| mutant | red |
|---|---|
| the flat pre-fix offset | 3 |
| `_renderSlots` emitting no divider slot | 5 |
| `_weekGroups` skipping the within-week sort | 1 (the control) |

## Finding 2 — an upcoming MuSpy release lost its detail prewarm

**Confirmed.** For You renders two sources with independent future gates — API's
`%WEEK_GATES` gives the LB feed `foryou_future` and MuSpy its own `muspy_future`,
sharing only the past gate. `_warmReleaseDetails` judged every priority-0 job against
the For You window alone.

With later weeks off for the feed and on for MuSpy, `_mergeMuSpy` keeps an upcoming
release and renders it, while its prewarm job is discarded. The discard passes retry
0, which **deletes the job from the queue** rather than deferring it, so the release
stays cold until the next nightly warm.

### The third carrier, not in the review

Four sites answer "what dates can this section's rows occupy". Two disagreed with the
merge that actually decides visibility:

| site | mapped For You to | verdict |
|---|---|---|
| `_mergeMuSpy` | `muspy` | the authority |
| `_sectionSig` | `muspy` | agreed |
| `_warmReleaseDetails` | `foryou` | the reported finding |
| `_windowSpan` | `foryou` | **not reported** — the tile subtitle understated its own span |

### Fix — one `_sectionBounds`, returning the union

All three non-authority sites now call `_sectionBounds`, which returns the union of
the For You and MuSpy windows. The past gate is shared, so only the far edge moves.

**Why the union rather than the review's suggested separate source id.** Both feeds
enqueue at priority 0, and DetailWarm keys its sources set BY priority, so a job
cannot say which feed it came from. `$job->{rel}` is replaced by whichever enqueue
landed last, so testing the release's own `_source` tag would judge a release carried
by BOTH feeds against whichever window arrived last — which loses the prewarm in the
mirror-image combination (`foryou_future` on, `muspy_future` off). The union is
order-independent and can only ever over-accept: one prewarm nobody reads, against a
cold tap on a release that is on screen.

### Guard

`t_detailwarm.pl` 32 → 38, new §8, and the suite gained `LBF_BROWSE` so it can be
anti-tested at all.

**Its `sectionWindow` stub had to become prefix-aware, and that is a finding about the
test:** a single window for every prefix cannot distinguish the union from the plain
For You window, so the previous flat stub would have passed against the very defect
being fixed. `_sectionBounds` is lifted from source rather than restated, since a
hand-written copy could agree with a broken shipped one.

**Anti-tested twice:** `_warmReleaseDetails` back on `sectionWindow` → 1 red;
`_sectionBounds` returning the For You window with no union → 2 red.

## The harness lesson from this round

Three suites and a bench broke on landing, all with `Undefined subroutine` while
compilation stayed clean everywhere: `t_cachememo.pl` lifts `_sectionSig`,
`t_review_fixes.pl` evals the week coderef, and `bench_walk.pl` lifts the section
pipeline. Adding a call to a NEW sub from inside code a harness lifts is invisible to
`perl -c`.

**`bench_walk.pl` is the one to note.** It exits 255 and prints a SHORTER LIST rather
than reporting a failure, so a half-dead bench reads as a quiet one — the same trap
recorded in 0.9.173. Each now lifts the real sub rather than stubbing it.

*After adding a call from inside code a suite lifts, run EVERY suite and the bench and
check the EXIT CODE, not the last line.*

## Validation

- Native `tools/t_*.pl` loop: all 31 scripts exit 0.
- `perl tools/t_loads.pl`: 20 passed, 0 failed — run against the BUILT ZIP.
- `perl tools/bench_walk.pl`: exit 0.
- `git diff --check`, `matcher_sync_check.py`, `singleflight_sync_check.py`: clean.

**No schema change, no cache-family bump, and the caches are deliberately NOT
cleared** — this build changes no stored shape and no cached decision, and caching
behaviour is locked while other work proceeds.
