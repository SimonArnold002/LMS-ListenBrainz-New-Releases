# LBF — the artwork pipeline and the event-loop stalls

**Status: REVIEWED; STAGE 1 BUILT, VERSIONED as 0.9.196, INSTALLED AND VERIFIED
LIVE 2026-09-03 — §1.1–§1.4 (1.5 dropped). Session paused here; Stage 2 is next.**
See CLAUDE.md's 0.9.196 entry for the live verification numbers (the `warmstats`
covers-stage ratio, `cachestats` marker count, timing, and the live Qobuz-handler
comparison) — not repeated here to avoid two copies drifting. Measured 2026-09-02 against
`dev` at 0.9.195, live ListenBrainz feeds, and LMS `public/9.0` source. **Re-read
against the source the same day (second pass); nine corrections are folded in below
and each is marked `[review]`** — one of them (§1.2's marker check) is load-bearing
for stage 3, and one stage was dropped outright.

| stage | what | state |
|---|---|---|
| 1 | Artwork: one upstream fetch per cover | **BUILT + VERIFIED LIVE** — 1.1 (gate probed) + 1.2 + 1.3 + 1.4; 1.5 **dropped** |
| 2 | Top level stops blocking; a building row for For You; Last.fm last in the warm | designed + reviewed; 2.1a memo key rebuilt, 2.2 **narrowed to For You** |
| 3 | Page-aligned warming — the "gaps on re-entry" fix | designed; **its dependency (§1.2's marker move) is now BUILT** |
| 4 | Remaining per-row SQLite work off the render path | designed + reviewed |
| 5 | Last.fm album tier becomes a bulk read | designed + reviewed |

Five faster artwork origins were checked and **all five rejected** — see the last
section, which exists so they are not re-proposed.

**Two stages contradicted decisions already recorded in `CLAUDE.md`, and the review
caught both.** Stage 2.2 reversed 0.9.184's *"THE FEEDS DO NOT GET THE BUILDING ROW,
deliberately"*; stage 1.5 reversed 0.9.191's measured *"there is nothing there worth
warming"*. One survives with a stated challenge, one is dropped. **A plan that
proposes work in an area with a ledger entry must name the entry** — see the ledger's
own section D.

## Context

LBF has gone backwards from a user's point of view since the refactor. Artwork
resolves slower than it used to and "gets stuck", first load takes ages even when it
should be cached, moving between views locks the server up, and artwork shows gaps on
re-entering a view. The suspicion was that the architecture took a wrong turn.

It did, in two independent places, and both are now measured rather than guessed:

1. **We pay three archive.org round trips per cover where one would do.** LMS's image
   proxy already coalesces concurrent requests for the same source URL and resizes
   every waiting spec from that single download. LBF's size ladder maps each spec to a
   *different* CAA URL, and the warm walks spec-major so a release's three specs are
   never in flight together. We are defeating a mechanism LMS gives us for free.
2. **Several render paths do heavy synchronous work inside LMS's single-threaded
   event loop** — the top menu alone SELECTs and thaws the whole ~3,000-release feed
   before a single row appears. That is the "locks up when I move views" report, and
   it is not artwork at all.

Stages are ordered by measured win per unit of risk. **No stage in this plan requires
a cache invalidation or a re-warm** — the two candidate changes that would have
(direct archive.org URLs, and an iTunes artwork tier) were both investigated, both
measured, and both dropped. The evidence is recorded at the end so it is not
re-discovered as a proposal.

---

## What was proved — and what was disproved

Measured live today against real ListenBrainz fresh-release MBIDs, plus a read of LMS
`public/9.0` source.

### The three-fetch finding — the headline

`Slim::Web::ImageProxy::getImage` queues by the **rewritten source URL**:

```perl
$queue{$url} ||= [];
push @{ $queue{$url} }, { cachekey => $path, spec => $spec, ... };
return if scalar @{ $queue{$url} } > 1;   # someone else is already fetching it
```

`_resizeFromFile` then walks that whole queue, resizing **each waiting entry to its
own spec** and caching each under its own `cachekey`. `_gotArtworkError` flushes the
queue the same way, so nothing hangs.

So: **N concurrent requests for different specs of one source URL = 1 download + N
resizes.** We get none of it:

| | today | why |
|---|---|---|
| `_150x150_f` | → `front-250` | [Plugin.pm:349-355](../ListenBrainzFreshReleases/Plugin.pm#L349) size ladder |
| `_300x300_f` | → `front-500` | three **different** URLs ⇒ coalescing impossible |
| `_600x600_f` | → `front-1200` | |
| queue order | **spec-major** | [Browse.pm:3467-3483](../ListenBrainzFreshReleases/Browse.pm#L3467) — a release's three specs sit thousands of entries apart, so never concurrent |

A 2,000-release pass issues **~6,000 upstream fetches**. It needs 2,000.

And the obvious alternative fix is closed off: the proxy calls `SimpleAsyncHTTP` with
`{timeout=>30, cache=>1}` but **no `expires`**, and `Slim::Networking::SimpleHTTP::Base`
only caches a response carrying `Cache-Control: max-age` or `Expires`. archive.org
sends neither (only `Last-Modified` + `ETag`). The downloaded original is genuinely
never cached — *concurrency is the only way to share one download*, which is exactly
what the queue above does.

### Source-URL measurements

| route | redirects | wall | verdict |
|---|---|---|---|
| `coverartarchive.org/release/<mbid>/front-250.jpg` | 2 | 2.02–2.44s | today's path |
| `archive.org/download/mbid-<M>/mbid-<M>-<caa_id>_thumb250.jpg` | 1 | 1.57–1.90s | works, 15–20% faster — **dropped**, see below |
| iTunes `is1-ssl.mzstatic.com` (600×600) | 0 | **0.052s** | 40× faster image, but needs a name-based search per release — **dropped**, see below |
| final `dn*.archive.org` node | 0 | 1.01s | ~50% faster, but the node hostname is per-item and unstable — **not proposed** |
| `archive.org/services/img/mbid-<M>` | 0 | **0.68s** | **180×180 only** — cannot serve the 300/600 specs without upscaling. Rejected |
| hosted `api.lms-community.org/music/album/<t>/<a>/cover` (`?mbid=` works) | — | +0.07–0.31s | returns **the same `archive.org/download/…` URL we can already build**, at full size, and hosts no images — **no win** |

### Size choice — front-1200 for everything, no upscale anywhere

Cost is latency-dominated, so a bigger source is nearly free on the wire (20 covers,
8-way): `_thumb250` 5.35s / 24.5 KB · `_thumb500` 5.56s / 72.8 KB · `_thumb1200`
6.33s / 339 KB.

Material's hi-dpi grid tile asks `_600x600_f`, and CAA offers only 250 / 500 / 1200 —
so **1200 is the only source that never upscales.** Now-playing artwork comes from the
streaming service, never from this path, so no ladder is needed above 600 either.
**One source URL for every spec** is simultaneously the best-quality answer, the
maximum-coalescing answer (3 → **1** fetch, not 3 → 2), and the fewest-bytes answer:
one 339 KB fetch beats a 73 KB + 339 KB pair.

### Concurrency headroom

P=1 → 0.52 covers/s · P=8 → 3.98 · P=16 → 7.85 · P=32 → 11.77, still climbing. The
binding constraint is **LMS's own HTTP handler slots** (warm requests go to
`http://127.0.0.1:<httpport>`), not archive.org.

### Are we maximising it?

After Stage 1 the remaining cost is pure Cover Art Archive origin latency, ~2s per
cover, with no CDN in front of it. Every faster origin was checked and every one fails
for a reason recorded at the end of this document. The honest levers that remain are
two, and Stage 1 uses both: **fewer fetches** (3→1) and **more at once when nobody is
looking** (8→16). Stage 3 adds the third that actually changes the felt experience —
**fetch the page in front of the user first**.

---

## Stage 1 — Artwork: one upstream fetch per cover

### 1.0 Why three specs at all, given LMS resizes on demand — verified

Two separate things were tangled together, and only one of them is a defect.

**Three different *source* sizes is the defect.** There is no reason to pull
`front-250`, `front-500` *and* `front-1200` from archive.org when LMS can resize.
Removing it is 1.1, and it is the single biggest win in this plan.

**Three *requests* is not the same thing, and cannot simply be dropped.**
`ImageProxy::getImage` caches only the **finished rendition**, keyed by the whole
path including the spec (`cachekey => $path`). It does **not** cache the downloaded
original: it calls `SimpleAsyncHTTP` with `{cache=>1}` but no `expires`, and
`SimpleHTTP::Base` caches only a response carrying `Cache-Control: max-age` or
`Expires` — archive.org sends neither. So a spec that has never been requested costs
a **fresh ~2s download** the first time a client asks for it, no matter how cheap the
resize is. Pre-requesting the paths is what buys the hit.

After 1.1 + 1.2 the three requests are **1 download + 2 local resizes**, and resizing
runs in a separate `gdresized` daemon process over a unix socket
(`Slim::Utils::ImageResizer::hasDaemon`/`initDaemon`, non-Windows), so it never
touches the LMS event loop and costs no browse latency.

**But one of the three specs is probably dead weight here.** From Material's own
source, `MaterialSkin/HTML/material/html/js/constants.js:51-52`:

```js
const IS_HIGH_DPI       = matchMedia("(-webkit-min-device-pixel-ratio: 2), …").matches;
const LMS_IMAGE_SZ      = IS_HIGH_DPI ? 600 : 300;   // grid tile
const LMS_LIST_IMAGE_SZ = IS_HIGH_DPI ? 300 : 150;   // list row
```

`IS_HIGH_DPI` is a media query fixed **per device**, not per view — so any one client
asks for exactly two specs: hi-dpi 300 + 600, standard 150 + 300. If every client on
this LAN is hi-dpi, `_150x150_f` is warmed for nobody.

**Action:** before implementing, grep the LMS access log for
`/imageproxy/.*image_(\d+)x\1_f` and count which specs real clients actually request.
Then make `COVER_SPECS` reflect that — dropping one spec removes a third of the
remaining resize work and a third of the local request volume for free. Keep it a
constant so it can be widened again if a standard-dpi client appears.

---

**No cache invalidation. No `kver` bump. Ships on its own.**
The proxy's cache key is the *proxy path* — `coverArtUrl`'s output plus the spec. The
handler rewrite happens inside the proxy at fetch time and never reaches the key, so
existing `lbf:imgwarm:` markers and existing renditions stay valid.

### 1.1 Collapse the ladder to one source — `Plugin.pm` handler (Plugin.pm:327-377)

Every spec resolves to `front-1200`. Drop the `getRightSize` table and its
`|| '1200'` fallback; keep the extension-capturing substitution exactly as it is
(`s{/front-\d+(\.\w+)?$}{…}e`) — the `.jpg` is load-bearing for the reason
API.pm:4478's comment gives. Keep the `UNIVERSAL::can('getRightSize')` registration
guard as a version probe.

*Risk:* resizing a 1200px source to 150px costs marginally more CPU on the box than
500→150. Measure it (below); it is milliseconds against a 2s fetch.

> **[review] GATE THIS ON ONE PROBE FIRST, because 1.1 and 1.2 together make artwork
> failure all-or-nothing.** Today the three specs are three independent requests, so a
> release whose `front-1200` is unavailable still gets its `front-250`. After 1.1 every
> spec asks for 1200, and after 1.2 they share one `%queue` bucket that
> `_gotArtworkError` flushes as a unit — so one missing size costs the row *all three*
> renditions rather than one.
>
> That matters here more than it would anywhere else: the rejected-origins section
> below already records a case where "IA holds only the original and has not derived
> `_thumbN` yet", and **a fresh-releases plugin's whole population is newly-uploaded,
> partially-derived art.** Whether IA can have derived 250 but not 1200 is *unverified
> either way*.
>
> **PROBED 2026-09-02, AND THE GATE PASSES — 1.1 SHIPS AS WRITTEN.** The newest 24
> `caa_release_mbid`s off the live feed (all `release_date` 2026-09-02, i.e. the
> least-derived population that exists), each requested at `front-250`, `front-500` and
> `front-1200`:
>
> | outcome | releases |
> |---|---|
> | all three sizes **200** | 22 |
> | all three sizes **404** | 2 |
> | **sizes disagreeing** | **0** |
>
> So IA derives the thumbnails as one task, exactly as assumed, and the two failures
> are the "holds only the original" case this document already records — they fail on
> *every* route and size equally, so grouping costs them nothing they were not already
> losing. **1.2's whole-bucket error flush is therefore safe: a release that loses 1200
> was never going to get 250 either.**
>
> Sample is small and deliberately worst-case rather than representative. If a
> disagreement is ever observed in the field, 1.1 needs a per-release fallback to the
> next size down and 1.2's grouping has to tolerate a partial bucket — a materially
> bigger change than the one written here.

### 1.2 Warm release-major, in triples — `_warmCovers` / `_coverTick` / `_coverLaunch` (Browse.pm:3429-3583)

- Queue elements become **groups**: one release contributes its three spec paths as a
  single unit, all resolving to the same source URL.
- `_coverTick` launches a whole group inside one synchronous turn (so all three land
  in the same `%queue` bucket before any callback can fire) and counts in-flight
  **releases**. `COVER_CONCURRENCY` is redefined as releases-in-flight.
- The current comment's reason for spec-major — two thirds of rows lacking their
  list-row size after a partial pass — **evaporates**: a release now gets all three
  specs for the price of one fetch, so release-major is strictly better.
- Keep `$coverPumping` exactly where it is; the group loop sits *inside* it, because
  `$done` still fires inline when a launch `eval` fails.
- **Named hazard:** `_gotArtworkError` flushes the whole bucket, so a failed download
  now fails all three specs together. Acceptable (the marker is only written on a
  proxy answer, and the next warm retries) — but do **not** add a retry here. See the
  probe gate in 1.1: this is the half of it that makes a missing size expensive.

> **[review] THE MARKER CHECK MOVES INTO `_coverLaunch`, AND IT MOVES HERE, NOT IN
> STAGE 3.** Stage 3 was written asserting that `_coverLaunch` already skips an
> already-marked path. **It does not** — [Browse.pm:3529-3577] only *writes*
> `$cache->set($key, 1, COVER_WARM_TTL)` on success. The one marker read in the whole
> file is `next if $cache->get($key)` inside `_warmCovers`' build loop
> (Browse.pm:3478), which is exactly the line stage 3 says must not run inside a
> browse callback. Left as-is, stage 3 re-queues ~30 rows × 3 specs of already-warm
> covers on every page render — cheap per request (the proxy answers from its own
> cache) but ~90 needless local requests against the very handler pool 1.3 exists to
> protect, and it destroys the "steady state only pays for genuinely new releases"
> property the markers exist for.
>
> So: **`_coverLaunch` gains the `$cache->get($key)` check and returns the slot
> immediately when it hits** (a store read in the pump is a timer context, not a
> render one), and the build loop **drops** it. That is also what makes the shared
> `_coverGroupsFor($rels)` honest — otherwise the two callers cannot share a loop
> without one of them doing ~90 store reads on the render path.
>
> **Two counters change meaning and must be fixed in the same edit, or the
> Verification section below starts asserting on the wrong number:**
> - `$added` becomes "groups queued", not "groups needing work", so `_stage('start',
>   'covers')` and the `_dbg` line would fire on every warm even when nothing is
>   fetched. Gate the stage on work actually launched, or count skips separately.
> - `$coverFetched` currently counts every `$done`. With the skip in `_coverLaunch` it
>   must count *fetches*, not *dequeues*, or `request(s) ≈ 3 × source url(s)` measures
>   nothing.

### 1.3 Browse-aware concurrency — the direct fix for "locks up moving between views"

Warm requests occupy LMS handler slots the browsing user wants; that is why the
constant sits at 8 despite the measured scaling. Replace one compromise number with
two, and let the reader win:

```perl
use constant COVER_CONCURRENCY_IDLE     => 8;    # releases in flight — see [review] below
use constant COVER_CONCURRENCY_BROWSING => 2;
use constant COVER_BROWSE_QUIET         => 20;   # seconds since the last browse tap
```

> **[review] 16 WAS 48, AND 48 WAS NEVER MEASURED.** The limit is redefined as
> *releases*, and a release is three local requests — so `IDLE => 16` is **48
> simultaneous HTTP connections to our own LMS server**. The scaling table above was
> measured in *requests* and tops out at P=32; today's `COVER_CONCURRENCY => 8` is 8
> requests, i.e. ~2.7 releases. Setting 16 puts the pass beyond the top of the measured
> range, against the constraint this document itself names as binding ("LMS's own HTTP
> handler slots"). **Start at 8 releases (24 requests, inside the measured range) and
> raise it only after re-running the concurrency measurement in units of releases.**

A `_noteBrowse()` one-liner at the top of every browse entry point — `topLevel` (442),
`fetchForYou` (730), `fetchAll` (906), `fetchPlaylists` (972), `resolvePlaylist`
(1105), `resolveFollowFeed` (1294), `resolveTrending` (1908), `_releaseDetail` (5259),
and the All Releases week `$render` (4956). `_coverTick` reads the limit each pass;
when it stops *because* of the browsing limit it arms a one-shot timer at
`$lastBrowseAt + COVER_BROWSE_QUIET` so the queue restarts without waiting for a
callback. A dropping limit never kills in-flight requests — the existing `while`
simply stops launching.

**[review] That timer needs an armed-flag or `killSpecific`.** Every landing callback
re-enters `_coverTick`, and with the browsing limit held each re-entry would arm
another one-shot — so a brake applied while 48 requests are draining schedules 48
timers. Keep one, the way `_kickGenreFill` keeps its gap.

### 1.4 Warm only what will be rendered

`_warmCovers` gets the **raw** feed; the render applies `_filterSection`
(Browse.pm:3796-3818). Blocked artists, unticked types and VA rows are warmed and
never drawn, eating `COVER_WARM_MAX = 2000` slots. Wrap the four call sites in
`_filterAll` / `_filterForYou` — `_warmGenres` already does exactly this, and says
why. One consequence to state: newly-ticked types stay cold until the next warm —
fixed entirely by Stage 3.

### 1.5 ~~Warm the follower / playlist / trending-track rows~~ — **DROPPED [review]**

*Proposed: an adapter that proxies each resolved row's `image` directly, called at the
end of each resolve. Dropped on two counts, and the second is a defect rather than a
judgement.*

1. **It reverses a measured decision without new evidence.** `CLAUDE.md` 0.9.191 records
   this as checked, not assumed: *"Trending Tracks, the follow feed (Recommended) and
   the Created-for-You playlists all render resolved rows, whose artwork comes from the
   streaming service or the local library — and a service origin is ~0.05s (measured,
   `static.qobuz.com`) against CAA's ~2.1s. **There is nothing there worth warming.**"*
   The counter-argument — that the *rendition* is cold even when the origin is fast — is
   fair, but it buys ~0.1s × ~50 rows for ~150 local requests. That is not a stage.
2. **The mechanism is wrong for the commonest row.** `prefer_library` defaults ON, so
   most playlist and follow rows are library hits, and `_localItemHash` sets
   `image => "/music/<id>/cover.jpg"` — a **local** path.
   `Slim::Web::ImageProxy::proxiedImage` is for *remote* URLs: handed a local path it
   yields the LMS **no-artwork placeholder** (measured 16,749 B PNG, against 78,946 B
   of real JPEG served direct). So the adapter would fetch and mark placeholders, and
   write `lbf:imgwarm:` entries describing them.

**If it is ever revived** it must (a) fire only on rows whose `image` is a remote URL,
and (b) come with a measurement of the rendition round trip that beats 0.9.191's
origin measurement. Neither is hard; neither is worth stage 1's attention.

**Expected Stage 1 effect:** upstream fetches per cover 3 → **1**; a 2,000-release
first pass from **~27 min** to well under half that, and LBF's load on the handler pool
during browsing from 8 concurrent 2-second requests to 6 (2 releases).

**[review] The drain figures were restated as a range, deliberately.** "3.98 → 7.85
covers/s" read the scaling table at P=8 and P=16 *requests*; with the limit now counting
releases and starting at 8 (24 requests), the honest claim is "fetches per cover fall by
two thirds and the pass runs wider than it does today" — the exact covers/s figure is
what the re-measurement in Verification is for.

---

### As built — §1.1 and §1.2, and the stall nobody had counted

`Plugin.pm`: the `getRightSize` table and its `|| '1200'` fallback are gone; every
spec rewrites to `front-1200`. The registration guard stays as a version probe.

`Browse.pm`: `_coverGroupsFor($rels, $cap)` is the shared, **allocation-only** queue
builder; a queue element is now a group (every spec of one release);
`COVER_CONCURRENCY` keeps its value of 8 but counts **releases**, so the fan-out is 24
local requests and 8 upstream downloads; `_coverLaunch` takes a group, skips the paths
already marked, and completes once per group; the stage note reports four numbers
(requests / releases / skipped / peak) instead of one.

**THE THING THE PLAN DID NOT KNOW, and it changes why §1.2 is worth doing.** The
marker check was moved out of the queue builder because stage 3 needed it moved. It
turns out the builder was **already** a real event-loop stall: it did one
`$cache->get` per PATH, and it runs inside a feed's `onDone` — an async HTTP callback
on the loop that streams audio and serves the image proxy. At `COVER_WARM_MAX` that is
**2,000 × 3 = 6,000 synchronous SQLite reads in a single turn**, every warm, on both
release feeds. Same hazard class as the 16,000-statement ingest
(`DB::ingestFeed`, 0.9.176) and the per-row SELECTs `bench_walk` caught in 0.9.165 —
it had simply never been counted here, and this document's stage 4 was written about
much smaller instances of exactly this.

It is pinned by a counting assertion rather than a comment: `t_coverwarm.pl` now counts
store reads during a build and requires **zero**. The anti-test that moves the check
back into the builder reports **90 reads** for a 30-release fixture — the same defect
at test scale.

**Suite: `t_coverwarm.pl` 66 → 78 assertions**, and section 1 inverted — it used to
assert the ladder picked the right size per spec; it now asserts the table is gone and
that all three specs rewrite to **one** url, with the old ladder kept live as a pinned
demonstration that it produces three. Anti-tested three ways: reinstating the ladder
**9 red**, moving the marker check back into the builder **2 red** (including the 90
reads), restoring spec-major ordering **10 red**.

**One test-hygiene fix went in alongside**, because the first anti-test run tripped the
trap this repo has already recorded once: a reinstated ladder made section 1 **die**
(the extracted rewrite line referenced a `$size` the harness does not have) rather than
fail, which took every later assertion in the file with it. The rewrite is now compiled
defensively and "it compiles depending on `$url` alone" is itself an assertion — which
is the property the collapse actually buys.

### As built — §1.3 and §1.4

`COVER_CONCURRENCY` becomes `COVER_CONCURRENCY_IDLE` (8 releases) /
`COVER_CONCURRENCY_BROWSING` (2) / `COVER_BROWSE_QUIET` (20s). `_noteBrowse()` marks
the browse at **ten** sites — the nine subs the plan named plus the All Releases week
drill, which is a coderef rather than a sub and is the level a user is most often
sitting on while the warm runs. `_coverLimit()` is read **per pump**, never captured,
so a browse arriving mid-drain takes effect at the next slot. `_coverArmRestart` is
guarded by an armed-flag, as the review required.

The four `warmFeeds` cover-warm call sites now filter first — MuSpy through
`_filterForYou`, since its rows are merged into that feed. The release-FAMILY lens
(`_viewFilter`) is deliberately **not** applied: it is a toggle the user flips from
the list itself, so warming one side would make the other cold on every flip.

**Suite: 78 → 101 assertions**, in two new sections. Anti-tested four more ways —
brake removed **8 red**, one entry point unwired **1 red**, warm handed the raw feed
**3 red**, restart timer unguarded **2 red** (arming six timers for one pass). Seven
mutants total across stage 1, none of which abort the run.

### Three test-harness defects surfaced by this work, all fixed

None was caused by the change; all three were latent and this stage made them bite.
Recorded because each is a class, not an incident.

1. **`grab()` was quadratic, and it read as a hang.** Every suite's sub-extractor
   walked the source one `substr($src, $i++, 1)` at a time — and `slurp` reads with
   `:encoding(UTF-8)`, so the source is a *character* string, where `substr` is not
   O(1). At half a megabyte of `Browse.pm` this had grown expensive enough that
   `t_coverwarm.pl` took **101 seconds** and `t_trending_empty.pl` **85**. Replaced
   with a regex brace-scan in **all eight** suites that carried it: `t_coverwarm.pl`
   is now **0.13s**, `t_trending_empty.pl` 0s. *A test suite that is slow enough to
   look hung is a test suite people stop running.*
2. **`ok()` died on a missing message, which hid every later assertion.** The die was
   added deliberately to catch a bare `m//` in the list-context argument slot — the
   trap that has now cost this repo three suites. But dying traded one hidden bug for
   another: an aborted run reports one failure and conceals the rest, which is the
   *other* trap already recorded here. It now reports the missing message as a
   failure and continues. Every bare match in the file was wrapped in `scalar()` at
   the same time.
3. **An assertion autovivified the thing it was asserting about.** Reading
   `$PENDING[0]{when}` when no timer is armed *creates* an empty hashref in the list,
   which `fire_all()` then calls as a coderef — so a failing assertion killed the run.
   Read defensively; never subscript a structure you are asserting is empty.

**And one stub gap, which is the class `perl -c` cannot see.** Adding `_noteBrowse()`
to `_buildAllLanding`'s week coderef broke `t_review_fixes.pl`, which evals that
coderef into its own package: `Undefined subroutine &F3::_noteBrowse`. Compilation was
clean everywhere; only running the suite found it. **After adding a call to any sub
from inside code a suite lifts, run every suite, not the obvious one.**

---

## Stage 2 — The top level stops blocking, and sections reveal in order

### 2.1 Instant menu, weeks fill in — `topLevel` (Browse.pm:442, 536-556)

Today `topLevel` inlines the All Releases week rows, so it blocks on
`getFreshReleasesAll` → `DB::feedReleases` = one SELECT of the whole window (~3,000
rows) **plus a `_thaw` per row**, then `_allSection`, then `_buildAllLanding`. A 5s
memo is all that hides it, and the `TOPLEVEL_ALL_WAIT` watchdog means a cold open
sits for five seconds. Everything the user wants first — the For You tile, Playlists,
People, Settings — is held behind it.

**2.1a — render immediately (small, do first).** Add a long-lived landing memo written
by `_buildAllLanding` and pre-filled by the warm's `all_feed` `onDone`. `topLevel`
renders from it synchronously; on a miss it renders the existing drill-tile fallback
**immediately** and fires the feed detached purely to fill the memo.
`TOPLEVEL_ALL_WAIT` and its watchdog then become dead and should be deleted, not left
as a trap.

> **[review] THE PROPOSED KEY WOULD REINTRODUCE THE 0.9.141 REFRESH BUG.** The key was
> written as `_sectionSig('all')` + view + `all_sort` at a ~6h TTL. Four problems, and
> the first is the serious one:
>
> 1. **A Refresh cannot invalidate it.** `%SECTION_MEMO` is safe *because* validity is
>    the **identity of the source arrayref** plus a 5s TTL — its own comment
>    (Browse.pm:3836) says a refresh necessarily produces a NEW ref, so a refresh cannot
>    be masked. A 6h memo keyed on prefs alone has no such property: press Refresh at
>    10am and the landing stays stale until the nightly warm or the TTL. **The landing
>    memo must be dropped by `clearFeedCache`/`_memoDrop`, and should carry the source
>    ref (or the feed's `ok_at`) in its validity test, not just prefs.**
> 2. **`_sectionSig` does not read `all_past` / `all_future`.** It reads `foryou_past`,
>    `muspy_future`, `weeks_past`, `weeks_future` (Browse.pm:3854-3865) — harmless
>    behind a 5s ref check, silent staleness at 6h. Add them.
> 3. **The memo bakes in one client.** `_buildAllLanding`'s week closures capture
>    `$headers` (`$useH`), and the row names come from `_weekLabel($client, …)`. A memo
>    filled by a Material walk would hand `header-basic` closures to a non-Material
>    skin, and one client's language to another. Either key on `$useH` + language or
>    memo the *releases* and build the rows per walk.
> 4. **If 2.1b is deferred, the memo pins the feed in memory.** Those closures capture
>    each week's release list, so ~3,000 hashrefs stay live for 6h where today they are
>    transient. On a Pi that is worth knowing before choosing the TTL.

**2.1b — stop loading 3,000 rows at all.** `release` already has a `week_start`
column *and* an index on it (DB.pm:454, 464), and `feedReleases` already accepts a
`$from,$to` window. So: new `DB::feedWeeks($feed)` = `SELECT week_start, COUNT(*) …
GROUP BY week_start` (**zero thaws**), and the week drill closure stops capturing the
whole feed and calls `feedReleases($feed, $ws, $ws+6d)` instead.

> **The one real design risk, stated plainly:** `_dedupeReleases` is cross-row and can
> span weeks (an LB/MuSpy duplicate whose two copies carry different dates). A naive
> per-week read could therefore surface a duplicate the whole-feed pass removes. The
> warm must write the *deduped* week index and each week's surviving release ids, and
> the drill intersects against that; the raw `feedWeeks` GROUP BY is the cold
> fallback only. If that machinery looks disproportionate when the code is in front
> of us, 2.1a alone already removes the user-visible stall — 2.1b is the memory and
> steady-state win, and can be deferred.
>
> **[review] AND THE FILTERS ARE THE BIGGER HALF OF THAT RISK, not the dedupe.** A
> `GROUP BY week_start` runs over the raw `release` table, so it cannot apply
> `_filterSection` (Browse.pm:3796) — release type, artwork-only, Various Artists or
> `blocked_artists`, every one of which needs the payload. Today `_buildAllLanding`
> receives the **already-filtered** list, so a week that filters to nothing simply has
> no row. Under the raw GROUP BY it gets a row that opens on `PLUGIN_LBF_NO_RESULTS`.
> So the week index the warm writes has to hold the *filtered, deduped* survivors, and
> **the raw GROUP BY is not an equivalent cold fallback** — it is a different answer.
> If the index is cold, falling back to the existing whole-feed path is honest; falling
> back to the GROUP BY is not.

The week row label carries no count (`_weekLabel`, Browse.pm:5112), so nothing in the
UI changes.

### 2.2 A building row for For You — and **only** For You [review]

> **THE LEDGER ENTRY THIS CHALLENGES, named as section D requires.** `CLAUDE.md`
> 0.9.184: *"THE FEEDS DO NOT GET THE BUILDING ROW, deliberately. They are already
> stale-while-revalidate …, a fetch failure degrades to the stored copy, and the only
> unready case is a completely empty store bounded by `FEED_TIMEOUT` (10s). At ≤10s
> once ever, a building row plus a 'Check again' tap is WORSE than letting it load."*
>
> **What is new: For You is not bounded by one `FEED_TIMEOUT`.** `fetchForYou`
> (Browse.pm:730) chains LB → MuSpy — `getMuSpyReleases` is called from inside
> `getFreshReleasesForUser`'s `onDone` (Browse.pm:746-806) — so a cold open is **two
> sequential** timeout windows, up to ~20s, outside the ≤10s the 0.9.184 argument was
> built on. That is a case the recorded reasoning does not cover.
>
> **What is NOT new, so it does not get the row:** `fetchAll` is a single fetch, and
> 0.9.184's argument applies to it unchanged. **`feed:all` is dropped from this
> stage.** Note too that the MuSpy leg costs nothing when unconfigured
> (`getMuSpyReleases` resolves immediately), so for a user with no MuSpy id For You is
> also a single round trip — the row is right for the two-fetch case and merely
> harmless for the one-fetch case, which is the trade being accepted.

`_buildingRow` (Browse.pm:332) is used by playlist open, follow, trending tracks and
trending albums. Apply the settled pattern to For You: claim `%BUILDING`
(`feed:foryou`), render the row *now*, clear `$callback` (never wrap it), let the fetch
complete into the feed store. The trap the existing comments name twice: **the first
opener must get the row too.**

> **[review] "Apply the pattern verbatim" hides an edit at every callback site.** The
> pattern is quoted from `_resolveFollow`, which reads `$callback->(…) if $callback` at
> every exit (Browse.pm:1320-1341) *because it is also on the warm path*.
> `fetchForYou` calls `$callback->({…})` **unconditionally** (Browse.pm:801). Clearing
> it there is a runtime die inside an async callback — i.e. a blank view, logged
> nowhere useful. Every callback site in the sub needs the `if $callback` guard as part
> of this change, not as a follow-up.

### 2.3 Last.fm becomes the last leg of the genre warm — `_warmGenres` (Browse.pm:8790)

Today: For You LB bulk → **For You Last.fm** → All Releases LB bulk → All Releases
Last.fm. `LFM_WARM_ALL` is 400 artists paced at one request per second, so All
Releases' *cheap bulk* rung waits roughly **seven minutes** behind For You's paced
rung. Restructure to strict ladder order across both feeds:

```
genres_foryou (LB bulk) → genres_all (LB bulk) → genres_lastfm_foryou → genres_lastfm_all
```

Keep the `_stage` names so `warmstats` stays comparable, and keep
`_persistLbArtistTags` at the end of each LB rung *before* its Last.fm rung —
`_warmLastfm` skips releases a cheaper tier already answered.

**Warm order overall becomes, explicitly and serially: New for You → All Releases →
Playlists → Followers**, with Last.fm last within the genre ladder.

*On "progressive reveal":* XMLBrowser hands back one item list per callback, so a
section cannot literally stream rows in. Progressive here means the menu renders
instantly from cheap tiles (2.1) and each section fills on open behind a building row
(2.2) — the behaviour already liked in Followers.

---

## Stage 3 — Page-aligned warming: the fix for "gaps when I re-enter"

There is **no** on-demand cover warm anywhere; all five `_warmCovers` call sites are in
the nightly tick. Genres have `_kickGenreFill` (Browse.pm:8581); covers do not, and
CLAUDE.md:717-719 already names this as the remaining piece.

Add `_warmCoversNow($rels)` — same group-building loop as `_warmCovers`, factored into
a shared `_coverGroupsFor($rels)` so the two cannot drift — which **unshifts** groups
to the *front* of `@coverQueue`, with no cap and no `_stage` (it is not a warm stage).
Rate-gate it like `_kickGenreFill` (`COVER_NOW_GAP => 5`) so paging cannot unshift
faster than the pump drains.

**[review] "No `_stage`" is not the same as "invisible to the stage".** These requests
still run through `_coverLaunch`, so they still increment `$coverFetched` — the counter
the Verification section asserts `request(s) ≈ 3 × source url(s)` on. Count
page-aligned launches separately, or the warmstats assertion measures a mixture.

Wire it to the render sites that already know their visible slice: the All Releases
week `$render` (4956-4959, the `PAGE_SIZE` slice **plus the next page**), `fetchForYou`
(801) and `homeForYou` (846).

**[review] The three resolved-row sites are out, because Stage 1.5 is dropped.**
`_followResult` (1423), `_trendingResult` (2215) and `_playlistResult` (3056) were only
reachable here through the 1.5 adapter, and that adapter would have warmed the LMS
no-artwork placeholder for every library-matched row. Their artwork is a ~0.05s service
origin or a local file; neither wants page-aligned warming. **Stage 3 is release rows
only** — which is also exactly the population `coverArtUrl` and the `lbf:imgwarm:`
markers describe, so the stage keeps one mechanism instead of two.

> **Hazard the Plan pass caught:** the build loop runs inside a *browse callback*, so
> it must stay allocation-only. Do **not** do the `$cache->get` marker check inline —
> that is ~90 store reads for a 30-row page, the exact class of blocking 0.9.130
> removed. Unshift unchecked and let `_coverLaunch` skip an already-marked path.
>
> **[review] THAT LAST SENTENCE WAS FALSE WHEN IT WAS WRITTEN, and it is this stage's
> load-bearing assumption.** `_coverLaunch` (Browse.pm:3529-3577) never reads the
> marker — it only *writes* it on success. The single marker read in the file is inside
> `_warmCovers`' build loop (Browse.pm:3478), the very line this hazard forbids. Left
> uncorrected, this stage re-queues ~30 rows × 3 specs of already-warm covers on every
> page render: cheap per request, ~90 needless local requests per render, and it
> removes the reason the markers exist.
>
> **The fix belongs in §1.2, not here** — move the check into `_coverLaunch` and drop
> it from the build loop, so the shared `_coverGroupsFor` can be shared without one
> caller doing store reads on the render path. **Stage 3 must not ship before that
> lands.** Then this sentence becomes true and the unshift is genuinely free.

---

## Stage 4 — Remaining synchronous work off the render path

**4.1 `_playlistTile` (Browse.pm:1023)** thaws each playlist's *whole resolved
payload* per row just to print "N/M matched". Write a sidecar count row at resolve
time (`lbf:pl:count:`, a few dozen bytes, registered in `KEY_VERSIONS`) and sum the
enabled services from that.

**4.2 `_trendingTile` (Browse.pm:1875)** thaws up to 50 item hashes just to count
them, on every top-level render outside a 5s memo — which matters more once 2.1 makes
the top level otherwise fast. Same sidecar treatment.

**4.3 `resolveFollowFeed` (Browse.pm:1294)** does a network fetch, then `_mergeFollow`
= up to 75 `SELECT`+conditional-`INSERT` pairs, a trim, a 500-row `SELECT` with 500
thaws, and an MD5 over 500 tracks — **all before the resolved cache is consulted** at
1325. Invert it: add `DB::followStamp($user)` (`SELECT COUNT(*), MAX(stored_at)` — one
indexed aggregate, no thaws), memo `stamp => sig`, serve the cached resolve
immediately, then fire the feed fetch + merge detached through the existing
`follow:feed` `%BUILDING` guard. Re-read the stamp every time — the warm's own
`_resolveFollow` also writes the store.

**[review] The `stamp => sig` memo is in-process, so "serve the cached resolve
immediately" is not unconditional.** After every restart the memo is empty, so the first
follow open still computes `_followSig` over the store — the 500-row `SELECT` with 500
thaws this stage exists to avoid. That is acceptable (once per restart, not once per
open) but it should be stated rather than discovered: the win is on repeat opens.

**4.4 Pref writes during render** — `_effectiveView` (4203) and the follow "seen"
marker (1489). Both are already change-guarded; audit only, and defer to a zero-delay
timer if `Slim::Utils::Prefs` turns out to flush synchronously. Lowest value here; do
it only if 4.1–4.3 leave a measurable residue.

---

## Stage 5 — Bulk Last.fm reads

### 5.1 The album-keyed Last.fm tier becomes one bulk read

Tier 5b `_lastfmGenres` (Browse.pm:9070) → `API::peekLastfmTags` (API.pm:4184) →
`DB::lfmGet` is **one SQLite SELECT per release**, and it is the last per-row read on
the render path. Every other genre tier is already bulk. It fires whenever the map has
no entry — and the map is capped at `GENRE_FETCH_MAX = 150` while a For You feed is
381–556, `homeForYou` (846) passes **no map at all**, and `genrePicker` (9284) buckets
the whole list. The 60s `LFM_MEMO` does not help: it is keyed `artist|album`, distinct
per release.

- `DB::lfmGetMany(\@keys)` mirroring `_factGet`'s chunked `IN (…)` idiom.
- `API::peekLastfmTagsBulk` over it, applying the same `_lfmFresh` rule and filling
  `%LFM_MEMO` so single-key peeks stay hot.
- `_mergeLastfmAlbumGenres($rels, $meta)` alongside `_mergeHostedGenres`, called from
  both peek branches. `_lastfmGenres($rel)` then survives only for the detail page's
  single-release peek (5467), where one SELECT is correct.
- Give `homeForYou` a `_withGenres(…, peek => 1)` wrapper matching `fetchForYou`'s.

> **Marker-isolation trap:** `_artistTierGenres` (8956) returns early unless its mark
> is set, precisely so the empty case costs nothing. The album rung needs its **own**
> distinct mark — reusing `LFM_MARK` makes the two rungs read each other's slots.

Then revisit `GENRE_FETCH_MAX` for the peek path (it exists to bound *HTTP* on the
non-peek path) — measure with `bench_walk.pl` first; bulk reads are not free either.

## Verification

Every claim above is falsifiable on the box (`http://plex:9000`). Do these before *and*
after.

**The core 3→1 claim.** Set `artwork.imageproxy` logging to DEBUG, clear the imgwarm
markers, request one cover's three specs concurrently and count `"Get artwork for
URL"` lines against actual outbound fetches. Before: three downloads. After: **one**
download and three `"Resized image should now be in cache"`.

**Throughput.** `["lbf","warmstats"]` — extend `_coverMaybeEnd`'s stage note from
`"$coverFetched request(s)"` to also report source-URL count and peak in-flight, then
assert `request(s) ≈ 3 × source url(s)`. Before the change the ratio is 1.0.
**[review] `$coverFetched` must be redefined to count FETCHES, not dequeues**, once
`_coverLaunch` skips already-marked paths (§1.2) and stage 3 unshifts into the same
queue — otherwise this ratio measures a mixture of warm, skip and page-aligned work.
Report skips and page-aligned launches as their own numbers.

**[review] The `front-1200` availability probe — do this BEFORE writing §1.1.** Take
the newest ~50 `caa_release_mbid`s off the live feed and request all three sizes for
each, comparing status codes. Expected: they agree. If 1200 is ever absent where 250 is
present, §1.1 and §1.2 together turn one missing size into a row with no artwork at
all, and both need rethinking before either is written.

**Browse latency under load.** `time_total` on a jsonrpc top-level POST while a cover
pass runs, before vs after 1.3. This is the number the user is actually feeling.

**Top level cold.** `["lbf","cachestats"]` to confirm an empty `kv`, then time
`["","listenbrainzfreshreleases","items","0","10"]`. Before: ≥5s (watchdog) or a full
feed round trip. After 2.1: <50ms, cold and warm.

**"Gaps".** Open a cold All Releases week, then poll the first row's three proxy paths
with `curl -o /dev/null -w '%{time_total}'`. Before: ~2s each on first sight. After
Stage 3: ~0.03s within seconds of the page render.

**No quality regression.** `file -b` the returned `_600x600_f` rendition — 600×600 off
a 1200 original, byte size comparable to or larger than today's. A *smaller* file means
the ladder rewrite broke. Also confirm the `gdresized` daemon is live
(`Slim::Utils::ImageResizer::hasDaemon`, i.e. the socket is readable) so 1200→150
resizes stay off the event loop; if it is not, resizing happens in-process and the
source-size choice needs re-measuring on this box.

**Which specs are actually requested.** Grep the LMS access log for
`/imageproxy/.*image_(\d+)x\1_f` and count by spec, to decide whether `_150x150_f`
can leave `COVER_SPECS` (see 1.0).

**Tests.** `tools/t_coverwarm.pl` — §1 asserts the size table verbatim (update it, and
keep the anti-test that restoring `250 => '250'` fails); §2 asserts the warmed string
is byte-identical to what the client requests — leave it as-is, since `coverArtUrl`
does not change; §3 add blocked/unticked rows queueing nothing; §4 add "all three
specs of a release appear in one in-flight set" and the browsing/idle limit
transitions; new §5 for `_warmCoversNow` ordering and its gap gate.
**[review] §4 also needs the marker skip asserted behaviourally** — a queued path whose
`lbf:imgwarm:` marker is already set must issue **no** HTTP request and must free its
slot, since that property moved out of the build loop and into `_coverLaunch` and
nothing else in the suite covers it. Anti-test it by deleting the check: the assertion
should go red on request *count*, which is the only thing that sees it. `bench_walk.pl` —
which already caught the `_lbArtistGenres` per-row regression — gains a top-level walk
and a Playlists walk, asserting zero payload deserialisations at the top level.
`t_buildingstate.pl` gains `fetchForYou` — **[review] not `fetchAll`**, which keeps its
0.9.184 behaviour, and the suite should pin that it has *no* building row so the
narrowing cannot be quietly undone. `matcher_sync_check.py` must
still exit 0. `perl -c` every touched module **and actually call** any renamed or moved
sub in a test — `perl -c` passes on calls to subs that no longer exist.

**Build hygiene.** Dev build bumps the version in `install.xml` + `repo.xml`,
recomputes the sha, and clears all plugin caches. Nothing here needs a
`KEY_VERSIONS` bump — `coverArtUrl`'s output is unchanged, so existing
`lbf:imgwarm:` markers and existing proxy renditions all stay valid. If a review
proposes bumping it, that is a signal something changed the proxy path by accident.

---

## Related work, deliberately OUT OF SCOPE for this document

**Overnight pre-warm of detail-page data (tracklist + streaming links) — see
`docs/overnight-detail-prewarm.md`.** Raised 2026-09-03 during Stage 1's live
verification: covers and genres get proactive overnight treatment, but a
release's MusicBrainz tracklist and its streaming matches never have — both are
still strictly on-demand, cached only after a user's first open. The goal (Simon):
"the user wakes up to find new material ready and waiting," not just for covers.
**On-demand stays as the correctness path; this is additive**, the same
relationship the cover warm already has to the image proxy's on-demand fetch. It
touches different code (`_releaseDetail`, `_findPlayable`, `getReleaseDetails`)
and different cost drivers (MusicBrainz rate limits, multi-service search
fan-out, not local event-loop stalls) — it needs its own investigation and design
pass, not a bolt-on to this plan. **Not started.**

## Deferred, and explicitly not doing

### Deferred work

- **`_releaseDetail` (Browse.pm:5259) two-phase render.** It holds its callback behind
  a streaming search + MB tracklist + MAI artist fetch under a 10s watchdog with no
  placeholder. A release with no detail page is useless, so this stays in scope — but
  the right fix is rendering base metadata (title, artist, artwork, genres, date/type)
  immediately and filling tracklist and streaming links as they land, which is a
  bigger change than anything above. Click-in takes priority over the background warm
  via Stage 1.3's brake, which then resumes. Background pre-resolve of never-opened
  releases sits at the very tail of the warm, strictly interruptible.
- **`SingleFlight.pm` adoption.** It is dead code — nothing on the render path uses it;
  guards are the hand-rolled `%BUILDING` (110-137) and `%INFLIGHT` (API.pm:1051).
  Stages 2.2 and 4.3 add new `%BUILDING` claims. Migrating is the obvious follow-up
  but must not ride along: `singleflight_sync_check.py` makes it a cross-repo edit and
  would make every regression here ambiguous.

### Faster artwork origins — all five checked, all five rejected

Record these so they are not re-proposed. Everything here was measured live.

- **Direct `archive.org/download` URLs built from `caa_id`.** *Works* — and it was
  never actually tried before (`git grep` across every revision finds no archive.org
  URL in any shipped code; CLAUDE.md's rejection was about the unstable `dn*` node,
  which is a different thing). Verified: `caa_id` present on **1221/1221** rows that
  have `caa_release_mbid`; constructed URL **byte-identical** to CAA's own `Location`
  on **100/100**; fetch outcomes **identical** to CAA on the same 100 (99 × 200; the
  one 404 fails on *both* routes because IA holds only the original and has not
  derived `_thumbN` yet; one transient 500 was 200 on 5/5 retries). **Dropped anyway:**
  it is the smallest lever (~20%, against 66% for 3→1 fetches), and it is the only
  change that rewrites every proxy path — forcing a `lbf:imgwarm:` version bump and a
  one-off full re-warm for every user. Not worth that price.
- **iTunes / Apple Music artwork.** The image side is superb: `mzstatic` is a real CDN
  at **0.052s** for 600×600, arbitrary sizes by URL rewrite, so resolution is a
  non-issue. It fails on the two things that matter. (1) **It needs a name-based
  search per release** to learn the URL — iTunes has no MBID — where CAA needs *zero*
  lookups because `caa_release_mbid` arrives free in the LB feed; name matching is the
  same fragile surface the shared matcher already fights, and a *wrong* cover is worse
  than a slow one. (2) **Coverage and rate limit:** on 30 live LB rows, **57% matched,
  37% no result, 7% wrong album** — the misses concentrated in exactly LB's long tail
  (Japanese, small-label, pre-release). And a 60-request burst at 8 concurrent
  returned **9 × HTTP 403**; the documented limit is ~20 calls/min, so 2,000 releases
  is **~100 minutes of searching before a single image is fetched** — worse than the
  entire post-Stage-1 cover pass.
- **Hosted `api.lms-community.org` cover route** — returns the same
  `archive.org/download/…` URL we could construct ourselves, at full size, hosts no
  images, and costs +70–310ms to learn it. No win.
- **`archive.org/services/img`** — 0 redirects and 0.68s, but **180×180 only**; cannot
  feed the 300 or 600 spec without the upscaling this plan is removing.
- **The `dn*.archive.org` node** — ~1.0s (50% faster) but the hostname is per-item and
  unstable. The ledger's existing rejection stands.

### Other
- **Another genre source** — settled in the ledger: LB / MB / hosted are all MB-derived
  and fail together at 2–4%; only Last.fm is independent.
