# Overnight pre-warm of detail-page data — tracklist + streaming links

**Status: IMPLEMENTED in 0.9.200 (2026-09-07); LIVE VERIFICATION STILL OWED.**
Investigation and design are recorded in
[cache-priority-refactor.md](cache-priority-refactor.md) under “Third implementation”;
the code is `DetailWarm.pm` plus the prewarm queue. Existing daily/startup scheduling
is retained. **Still open:** a fixed overnight clock (the timer is still 24 hours
relative to startup), live throughput measurement, and restart/checkpoint behaviour on
the real server.

*Corrected 2026-09-10: this file carried BOTH the update above and the original
“NOT INVESTIGATED, NOT DESIGNED” status line directly beneath it, so whichever a reader
saw first decided what they believed. The original status is folded into the historical
note below rather than left standing as a second verdict.*

**Original requirement capture — HISTORICAL, superseded by the status above.** Raised 2026-09-03
during the artwork/event-loop rework's live verification. Needs its own investigation
and design pass before any code is written — do not start implementing from this
document alone.

**The requirement (Simon, verbatim intent):** *"the overnight [pass] needs to pull
artwork and all metadata for any new releases added when it checks, this should not
be down to user opening up the view to find and then wait for the warm to happen...
this should just be so the user wakes up to find new material ready and waiting.
This has never happened so far... they still need to be on demand but would benefit
from overnight warming."*

**In one line:** by default, with no settings changed, opening any release that
matches the user's current filters should never trigger a live fetch — not for its
cover (covered by the artwork rework), not for its tracklist, not for its streaming
matches. All of it should already be resolved by the time the user looks.

---

## Why this is a real, pre-existing gap — not new work invented tonight

Covers and genres already get *some* proactive overnight treatment (`_warmCovers`,
`_warmGenres`, chained inside `warmFeeds`). **Tracklist and streaming links never
have.** `_releaseDetail`'s MusicBrainz tracklist fetch and `_findPlayable`'s
streaming-service search have always been strictly on-demand: fired the first time a
user opens that specific release's detail page, then cached (MB tracklist 30d;
streaming matches 7d found / 1d no-match — see `lbf:stream:`/CLAUDE.md's cache
version history). Confirmed live 2026-09-03: after a full overnight warm tick, a
release's cover and genre were already warm on first open, but nothing in the warm
touches tracklist or streaming resolution at all.

So "wake up and it's all ready" has never been true for this half of the page, even
before this session's artwork work. This document exists so the requirement is not
lost, not because anything regressed.

---

## The design principle already settled in conversation — don't relitigate this part

**On-demand resolution stays exactly as it is, unconditionally.** `_releaseDetail`'s
MB fetch and `_findPlayable`'s streaming search remain the correctness path — for a
release the overnight pass hasn't reached yet (added mid-day, a settings change that
newly reveals it, a cache eviction). **The overnight addition is purely to make the
common case a cache hit** before the on-demand path is ever asked — same shape as the
cover-warm's own relationship to the image proxy's on-demand fetch (Stage 1 of
`docs/artwork-and-event-loop-rework.md`). This is additive, not a replacement, and
not a new architecture — it is the same pattern applied to a different kind of data.

---

## What has to be investigated before a design can be written

Both of these determine whether "warm every new release's detail data overnight" is
a five-minute job or a multi-hour one at the volumes seen in this session's live
tests (over a thousand genuinely new releases in a single tick against a real
account):

1. **MusicBrainz tracklist fetch, rate-limit shape.** The public MB API is
   courtesy-gapped elsewhere in this codebase (`_mbWait`/`_mbNoteLimit`, ~1
   req/sec without a local mirror — see the `warmArtistSorts` 503 backoff,
   0.9.180). The tracklist fetch (`getReleaseDetails`, `release?inc=recordings`)
   does not currently participate in that shared backoff at all, because it has
   never run in bulk. Read `_mbWait`/`_mbIsRateLimited` before designing a bulk
   caller — do not invent a second backoff mechanism.
2. **`_findPlayable`'s per-service concurrency and timeout**, fanned out across
   however many streaming services a given user has enabled, once per NEW release.
   At the volumes measured tonight this is potentially thousands of multi-service
   searches in one overnight pass. Needs its own pacing, almost certainly its own
   concurrency cap (mirroring `COVER_CONCURRENCY_IDLE`/`_BROWSING` — see Stage 1.3
   of the artwork doc for the shape, not the numbers), and — following the same
   rule Stage 1.4 established for covers — must filter through `_filterSection`
   first so effort is never spent on a release the user's current settings would
   never show.

## What is explicitly NOT settled yet, and must not be assumed

- Whether this becomes a new numbered stage of `artwork-and-event-loop-rework.md`
  or its own standalone plan document with its own stage numbering. Given it
  touches entirely different code paths (`_releaseDetail`, `_findPlayable`,
  `getReleaseDetails`) and has entirely different cost drivers (external rate
  limits, not local event-loop stalls), it is more likely to want its own plan —
  decide this at the start of the investigation, not here.
- Batch size / cap per tick (the `COVER_WARM_MAX` equivalent for this data).
- Whether it should be scoped to "genuinely new since last tick" only, or also
  sweep anything discovered-but-never-opened from prior ticks (the same "steady
  state vs first-run cost" question Stage 1 answered for covers via the 25-day
  marker TTL).
- Whether the browsing-brake pattern (Stage 1.3) is needed here too — this work
  competes for the SAME server resources (HTTP handler slots, event loop turns
  for async callbacks) that browsing does, so it plausibly does.

**Do not start implementing from this document.** It exists to hold the requirement
and the two known cost drivers until an investigation pass (mirroring how
`artwork-and-event-loop-rework.md` itself started — measure first, design second,
build third) produces an actual plan.
