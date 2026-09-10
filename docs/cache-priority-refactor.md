# Cache and warm-up priority refactor

## Agreed direction (2026-09-07)

Show cached release lists quickly and give artwork priority. Retain ListenBrainz
metadata/genres in the early pass. Only the slow Last.fm fallback belongs after
core work. Scheduled updates must eventually prepare new releases' artwork,
tracklists, streaming matches and genres without needing a first visit.

## Build cache policy (2026-09-08)

Ordinary plugin-version changes preserve the whole cache, including derived
views, feeds, artwork/detail results, streaming matches and all genre/Last.fm
answers. A plugin version is not a cache-family version: stored shapes invalidate
through their own key, schema or parser versions. `RESET_CACHE_ON_BUILD` is 0 by
default and is set to 1 only when deliberately building a clean-load test; a real
fresh installation already has an empty store. This replaces the former rule that
every dev build implicitly cleared derived rows and genres.

## First implementation: Last.fm priority

Packaged as development build **0.9.198** on 2026-09-07 for local testing; not deployed:

- Feed and playlist/follower warm chains reserve priority over Last.fm.
- Follow warming now has a completion hook for the resolve, rather than treating
  dispatch as completion. Both follower branches must finish before releasing
  the playlist warm's reservation. Existing in-progress builds also hold priority.
- Both ListenBrainz metadata passes run early. All Releases no longer waits for
  For You's Last.fm tail.
- Every `_warmLastfm` caller, including browse top-ups, checks priority before
  consuming the next queued artist. Pending or running cover work and the existing
  20-second browse activity window defer Last.fm. In-flight HTTP is allowed to
  finish; subsequent calls wait.
- Last.fm warm passes share one request slot and a one-second interval after
  completion. Errors release the slot; a 90-second watchdog handles missing
  callbacks, and late callbacks cannot release a newer request's slot.
- Core reservations expire independently after one hour as recovery from a lost
  callback. This is a recovery limit, not a guarantee that failed work completed.
- Cache schemas, existing artwork warming and release refresh cadence are unchanged.
  Queued Last.fm jobs remain in memory in this first implementation.

`warmstats` Last.fm stage elapsed time currently includes time waiting for priority.
It must not be interpreted as upstream request latency. Follow-feed timing now
includes newly started resolution; an already-running resolve is protected by the
existing building registry rather than joined by the new completion hook.

## Second implementation: adaptive artwork and stable release taps

Packaged as **0.9.199** for local testing, not deployed.

Artwork already waiting in the shared queue can now be promoted without duplicating
requests. The active requested range wins; newly revealed rows win on Show more or
Show all. Changing weeks replaces the old focus. Unfinished work then resumes with
For You first, followed by All Releases (current week, earlier weeks newest-first,
future weeks, then undated releases). Running downloads finish normally. Warm-marker
checks and the existing per-turn scan budget remain in the pump; queue promotion
performs no database reads.

The browse callbacks use LMS's requested index/quantity when available. These are
request ranges, **not exact viewport visibility**: Material can scroll through
already loaded rows without notifying the server. No Material Skin changes are
required. This stage prioritises artwork; the existing ListenBrainz metadata pass
remains early and Last.fm remains deferred. It does not add the durable detail-data
queue described below.

The wrong-album report is addressed independently of sorting: Material release rows
now use XMLBrowser `itemActions.items` to open an explicit release target through
the existing plugin command. The target bypasses the changing week/list hierarchy.
Nested detail browsing, playback, add and insert retain that target, while existing
service-specific actions are preserved. Binding copies display structures rather
than mutating cached items. The old frozen order remains for visual continuity and
clients using the positional fallback.

Targets are held in memory for 24 hours since use, capped at 10,000. After restart,
expiry or eviction, a stale action asks the user to refresh the list; it never falls
back to the album now occupying the old position. This fixes the explicit-action
path used by Material; legacy clients that ignore itemActions retain the existing
positional behaviour and need live verification.

Protocol checked against LMS Community's `public/9.0` XMLBrowser.pm: item-level
`items` actions become `go`; root `query` parameters flow to default actions; explicit
playback actions also carry the target because context-menu `_makePlayAction` does
not automatically copy those root parameters.

Tests cover existing queue promotion, switching weeks, resuming For You, reveal
boundaries, requested ranges, week ordering, saved taps after reordered/removed
rows, nested playback, Unicode identities, expired targets, and cache immutability.
Live validation should cover Show more, Show all, switching weeks, tapping rows
30/60 and beyond, and playback from the resulting detail pages.

## Third implementation: pre-warm release details (0.9.200)

The user reports improved behaviour with 0.9.199. This next development build is
packaged for testing; it has not been measured on the server.

`DetailWarm.pm` adds a deduplicated background queue seeded from each successful
feed warm and from the requested/revealed rows. Active rows win, then For You,
then All Releases in the same week order as artwork. One release is processed at
a time. Core warm work, artwork and browsing pause dispatch; Last.fm yields to
ready detail jobs but can proceed while all detail jobs are waiting on retries.

Each job uses **the existing detail-page caches and fetchers**: MusicBrainz
tracklists and automatic streaming matches. No duplicate cache or completion
marker was introduced. The stored feeds are the durable work inventory, and the
stored results are the checkpoints: after restart, the normal startup feed pass
reconstructs the queue and skips already cached results. This deliberately avoids
a second durable job table needing reconciliation with cache expiry. Pending
ordering and transient retry delays themselves are in memory; failed work is
rediscovered after restart. Repeated core warm passes also rediscover expired data.

Missing player/service readiness, failed fetches or failed cache writes remain
queued. Existing streaming retry deadlines are honoured; confirmed empty results
are cached according to the normal policy. Tracklists can progress without a
streaming player. Work is rechecked against current type/artwork filters and date
windows before dispatch. Jobs not seen by any queue seed for 48 hours retire.
Manual Bandcamp searches remain manual; artist biographies are not part of this
stage. Releases without release MBIDs cannot pre-warm MusicBrainz tracklists.

Foreground/background requests for the same tracklist or album search coalesce
through the existing shared SingleFlight module. Album flights include player,
year, type and force mode in addition to the existing cache key. A foreground
match may render immediately; the background worker waits for the remaining
service callbacks/timeouts so successive warm fan-outs do not accumulate.

Tracklist misses use a 1.1-second public-MusicBrainz courtesy gap and the existing
shared 429/503 backoff. Mirrors bypass public throttling. The worker's 120-second
watchdog preserves a lost job for retry; late callbacks cannot release a newer
job or answer a replacement flight.

`["lbf","warmstats"]` now includes `detail_pending`, `detail_active`,
`detail_completed`, `detail_deferred` and `detail_failed`. Completed counts jobs
processed in this server session, including cache hits; deferred/failed are event
counts, not distinct releases. A future retry may be pending while active is zero.
The queue runs after startup and existing regular warm ticks, not at a newly
introduced overnight clock time. Upstream availability and volume still determine
whether a first cold pass finishes before morning.

Validation: `t_detailwarm.pl` (26 checks) exercises queue ordering, active-work
coalescing, pause/resume, retries, checkpoint reuse, unavailable players, cache
write failures, stale windows and watchdog recovery. `t_detailflight.pl` (15)
exercises real fetcher bodies and SingleFlight for request coalescing, public
pacing, shared backoff, mirror bypass, late replies and slow-service completion.
Thirteen suites pass, 776 checks in total. Live server verification remains.

## Fourth implementation: generation-backed feed/view reuse (0.9.201)

The decoded-feed and processed-section memos now live for 30 minutes instead of
five seconds. Time is only the memory bound; validity comes from the durable
store's feed generation. A memo hit performs one indexed scalar generation read
instead of `feedReleases`' full SELECT plus one Storable thaw per release.
The latest `bench_store.pl` run measured that check at about 0.017ms on the
development machine, against about 20ms to read and thaw the measured
3,255-release feed (roughly 200ms projected on the target Pi).

Feed generations now move for the whole canonical payload, not just the mirrored
SQL columns. A payload-only update therefore invalidates the memo too. Because a
release row can belong to several feeds, an update also increments every other
feed that references it; the ingesting feed is not the only owner invalidated.
Byte-stable canonical freezing keeps an identical re-ingest generation-neutral.
Existing non-canonical rows move once on their first re-ingest, then settle.

Both ListenBrainz memo keys name the current date. This matters for the user feed
as well as All Releases: its `days=` query is relative to today even though the
date is implicit in the URL. The processed-section signature also carries the
effective date window and all section gates, so a Monday rollover or settings
change rebuilds immediately. Refresh still drops the relevant feed memos before
marking their durable rows stale.

Genre and artist-sort facts are deliberately not baked into the processed list.
They are read by `_withGenres` and `_sortWithin` downstream on each render, so a
new enrichment answer remains visible without discarding the reusable
filter/dedupe result. All Releases' existing frozen-order safety can still retain
the order already shown to a client; that is the explicit wrong-row-on-tap guard,
not stale processed data.

No schema or cache-family version changed. `t_cachememo.pl` adds 14 checks for
the longer reuse and each invalidation edge; four new SQLite assertions cover
payload-only changes, shared-feed invalidation, the cheap generation accessor and
stable identical payloads. The existing 13-suite set plus these checks passes as
14 suites / 794 checks. The complete repository Perl harness set and both shared
sync checks also pass. Live server verification remains.

## Fifth implementation: indexed week-summary landing (0.9.202)

The plugin root and Material All Releases shelf no longer decode the complete
All Releases feed merely to discover which week folders exist. `DB::feedWeeks`
groups the existing indexed `week_start` column and returns only week/count rows;
no release payload is selected or thawed. That compact result is itself reused
under the feed generation. On a genuinely empty store the root renders the
existing All Releases drill tile immediately while the first fetch runs detached.
A stale stored summary likewise renders first and revalidates behind the view.

Selecting a week calls `DB::feedWeekReleases`, whose exact `week_start` predicate
decodes only that folder. Its decoded array uses the same generation-backed memo
as the full feeds, and Refresh drops the summary and every exact-week child before
marking the durable feed stale. The week then applies the existing All Releases
type/artwork/Various Artists/block filters, dedupe, sorting, genre selection,
paging, cover focus and frozen-order tap protection. Summary counts remain raw
and are deliberately not displayed: claiming a filtered count would require
decoding the payloads the root path now avoids.

This needs no schema migration because `release.week_start` and its index already
exist. In the 3,255-release store benchmark, the root operation returned five
compact rows in about 3ms instead of decoding the full feed in about 20ms. The
selected 580-release week decoded in about 4ms. All Releases contains only the
ListenBrainz membership, but the release payload table is shared across feeds. The
All path therefore explicitly disables For You's MuSpy-specific cross-date collapse
in both its full-feed and exact-week readers. That prevents a MuSpy source marker on
a shared payload from making the two paths disagree; same-source All editions with
different dates remain intentionally distinct.

`t_weeksummary.pl` adds 14 checks covering fresh/stale/cold summary behaviour,
generation reuse, exact-week loading, invalid input, root/home routing, removal
of the obsolete five-second root watchdog, equal dedupe scope and Refresh
invalidation. Four SQLite assertions cover compact summary shape/counts and
exact/invalid week reads.

## Sixth implementation: restore enrichment before general detail (0.9.204)

Live diagnosis of the preserved 0.9.203 cache showed that detail preparation was
running ahead of the Last.fm genre tail. The correction makes detail an explicit
remainder phase. Feed jobs may be admitted early, but dispatch stays closed from
the start of a feed warm through both ListenBrainz metadata passes and both
Last.fm tails, including their final courtesy intervals. Missing tracklist and
streaming checkpoints resume normally once that boundary opens.

Requested/revealed list ranges now promote artwork only. Opening one release
creates an idempotent Last.fm hold around that release page's foreground fan-out;
normal completion, failure and the detail watchdog all settle the same hold once.
Foreground/background fetch coalescing and all existing detail cache checkpoints
remain unchanged.

An unchecked artwork queue entry no longer blocks Last.fm by itself. The artwork
pump still starts cold groups first, and actual in-flight downloads retain
priority, while an all-warm restart scan cannot masquerade as network work. The
Last.fm queue bulk-checks artist-row freshness before admission, so fresh empty or
vocabulary-rejected answers remain settled until their one-day empty TTL expires
and consume neither a request nor the one-second pacing interval.

`warmstats` adds `detail_cache_checks`, `detail_cache_hits`, `detail_fetches` and
`detail_main_ready`. This separates reconstructed cache verification from actual
tracklist/streaming fetches. Targeted tests cover phase ordering, preserved-marker
scans, negative Last.fm checkpoints, artwork-only list focus, foreground hold
settlement, checkpoint reuse and post-enrichment detail resumption. No cache
schema/family, feed ordering, artwork concurrency or fresh-install core priority
changed.

## Seventh implementation: make the Last.fm request bound advance (0.9.205)

Live 0.9.204 evidence showed the Last.fm tail was being entered but was not
advancing through the feed. `warmstats` recorded All Releases as complete after
only 5.24 seconds, while `cachestats` still showed 4,508 artist rows never asked
(185 positive and 117 negative Last.fm artist answers). The rendered W/C 31
August week had genres on 243 of 362 rows, including 138 rows after row 150, so
the 0.9.203 full-map render fix was working; the remaining gap was upstream of
the renderer.

This was not explained by the remaining releases simply having no Last.fm data.
One live blank row was Hannah Cole; Last.fm's artist page lists `indie`, which is
in the shipped MusicBrainz vocabulary but was deliberately marked as a modifier
and therefore rejected by `_genreKnown`. That second issue was not part of the
candidate-cap fix and is corrected in 0.9.206.

The worker's 400-artist bound was applied while collecting candidates, before a
bulk store read removed fresh positive, empty and vocabulary-rejected Last.fm
checkpoints. On a preserved cache, those same settled artists occupied almost
all 400 slots every day and were then discarded, leaving only about five real
requests. Artists after that prefix were never admitted on any later pass. The
bound now applies after the full cheap checkpoint scan, so it limits actual
upstream requests and each new pass advances to never-asked artists.

The completion callback now carries observable outcome counts. Both
`genres_lastfm_foryou` and `genres_lastfm_all` put candidates, fresh checkpoints,
requests, displayable genre answers, empty answers, vocabulary-rejected answers,
failures and deferred work in the `warmstats` stage note. A stage can therefore
no longer report a content-free `done` while doing only a handful of work.
`t_lastfm_priority.pl` drives the former lockout shape directly: two fresh
checkpoint artists precede three never-asked artists under a two-request bound,
and the worker must request the later two and report the third as deferred.
No cache wipe or schema/family bump is needed.

## Eighth implementation: classify Last.fm tags before caching (0.9.206)

The first live 0.9.205 run proved that the candidate-cap fix executed, but also
exposed a second independent defect. The All Releases stage examined 302 candidate
artists, skipped 299 fresh checkpoints, requested three, accepted two answers and
recorded one empty answer. Nevertheless W/C 31 August remained at 243 genre-labelled
rows out of 362. Hannah Cole was still blank although Last.fm listed `indie, usa`.

The discrepancy was in the meaning of a Last.fm checkpoint. `_genreKnown` correctly
examined tags individually, but the worker stored the complete raw array. A response
containing only rejected tags therefore had `n_lastfm_genres > 0` and received the
30-day positive age, even though the renderer filtered the same array back to nothing.
Both `artist_lastfm_have` and `warmstats`' fresh-checkpoint count consequently included
answers that could not display a genre. The raw `lastfm_tags` cache repeated the same
mistake: a due one-day artist retry could be satisfied from that 30-day raw cache without
asking Last.fm again.

The artist worker now stores only the accepted subset, making the existing per-tag gate
explicit in the durable answer. Reclassifying `indie` as displayable means the live
`indie, usa` shape stores `indie` and ignores `usa`. Rejected-only answers are stored as
empty and use the one-day negative age; when that checkpoint is due,
the request bypasses the raw cache and reaches Last.fm. Existing preserved rows are
classified by their displayable subset while checking freshness, so old rejected-only
arrays age out under the short rule without a genre wipe. `indie` itself is now a valid,
family-less genre rather than a modifier, while obvious non-genres such as `usa` remain
rejected.

The investigation note was corrected at the same time: `Neo-Progressive Rock`,
`Hypnagogic Pop` and `Space Rock Revival` are all in the current shipped vocabulary and
already survive case/separator normalisation. `t_lastfm_priority.pl` now covers the live
mixed-tag case, accepted-subset storage, forced upstream retry, positive/negative ages and
those vocabulary examples.

## Post-0.9.206 review fixes: stable week targets and cross-pass Last.fm dedupe

The indexed week-summary landing introduced one new positional parent above the
release rows. Release cards already carried an explicit `lbf_release` action, but
week cards still relied on XMLBrowser re-walking the live root by `item_id`. A
background summary refresh that inserted or removed a week between render and tap
could therefore open an adjacent folder before release identity had a chance to
help. Week rows now carry the durable natural key as `lbf_week=<week_start>` through
the registered plugin command. The explicit route validates the key, opens only
that exact stored week, and retains the key as the root query for paging. The one
shared row builder supplies all carriers: main root, full-feed fallback and
Material's All Releases home shelf. Legacy clients retain the original coderef.

The two daily Last.fm tails are intentionally admitted independently so All
Releases metadata does not wait for For You's optional paced work. That allowed
both passes, or a browse top-up, to snapshot the same artist as missing before the
first response was stored. The global request slot serialized the duplicate but
did not remove it. `_warmLastfm` now records only successfully stored artist
checkpoints in a bounded one-day in-process map and rechecks it at dispatch. The
candidate tail is kept until dispatch and the cap is applied to `requested`, so a
skipped duplicate does not consume an allowance or falsely defer the next unique
artist. Failures are not recorded and remain eligible for retry. Request pacing,
the one-request global lane and durable positive/negative TTLs are unchanged.

`t_release_target.pl` drives the natural-key route and fail-closed validation;
`t_weeksummary.pl` pins all shared week carriers; `t_lastfm_priority.pl` starts two
passes with one overlapping artist under a one-request cap and proves that only
the shared artist and the later unique artist are requested. No schema or cache
version changes are required.

## Remaining implementation

1. Validate detail queue throughput and restart/checkpoint behaviour on the live server;
   adjust pacing from measurements if necessary.
2. A fixed overnight schedule and incremental regular-update policy using that
   queue. The current timer remains 24 hours relative to startup.
3. Verify adaptive artwork priority, explicit release actions, generation-backed
   reuse and indexed week-summary navigation on the live server.
4. Review whole-pass limits (including Last.fm's 400-artist cap) as part of durable
   queue draining. This patch does not promise every new release is prepared yet.

## Validation

`tools/t_lastfm_priority.pl` executes the real priority, Last.fm worker, metadata
warm and core warm functions with controlled timers and upstream callbacks. Its
**61** checks cover checkpoint-aware request bounds, mixed accepted/rejected answers,
positive/negative checkpoint ages, forced upstream retries, observable answer counts,
main-before-detail phase ownership, preserved artwork-marker
scans, fresh negative Last.fm checkpoints, shared pacing, watchdog/late-callback
recovery, independent reservations and foreground release holds. The **38**-check
`tools/t_detailwarm.pl` suite covers artwork-only list focus, cache/fetch
diagnostics, restart checkpoint reuse, post-main resumption, retries and worker
watchdog recovery — including §8's `_sectionBounds` union, whose stub had to be made
PREFIX-AWARE before it could tell the union apart from the plain For You window.

*Counts re-run and corrected 2026-09-10 (was 55 and 32). A stated assertion count that
drifts is worse than none: it reads as a checksum and is not one.*

Existing load, genre, artwork, feed coalescing, building-state, warm statistics,
cold-start and follower rate-limit suites also pass. The genre test's detail-barrier
assertion now searches `_releaseDetail`, rather than whichever `$pending` variable
happens to appear first in the entire file.

`tools/bench_walk.pl` remains healthy on the 3,365-release fixture: a repeated All
Releases section walk is a 0.01ms memo hit, and the cold filtered/deduped/date-sorted
walk remains about 15ms on the development machine.

Live server timing, overnight completion and deployment have not been performed.
