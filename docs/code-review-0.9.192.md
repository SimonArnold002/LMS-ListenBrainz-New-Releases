# Code review — 0.9.192 (the 0.9.191 fixes, reviewed)

**Reviewed 2026-09-02. BOTH FINDINGS ARE FIXED**, in the same session, each with its mechanism,
its guard and its anti-test count.

**Scope.** `dev` at `47ecb28` (0.9.192 — "the three findings of the 0.9.191 code review"), plus
the one uncommitted working-tree change (`docs/streaming-adapter-spec.md`, doc-only). Per the
Review Ledger (sections A–C) the full diff was read but effort was weighted onto what 0.9.192
itself changed: the two `API.pm` feed-path fixes and the `Browse.pm` trending cover-warm rework.

**BOTH FINDINGS ARE IN 0.9.192's OWN FIXES, and that is the thing worth carrying — not either
bug.** Neither is a regression from older code. Each is a *second-order* consequence of a
correct fix: 0.9.192 widened who claims a guard without revisiting who releases it, and it
un-gated a fetch without revisiting what that fetch's caller is then handed. **A fix that
changes WHO participates in a mechanism has to be re-read from the other end of that
mechanism** — the release, the caller, the consumer. Both of these were one frame away from
the line that changed.

**What was verified as correct and is NOT a finding** (recorded so the next review does not
re-derive it): the `coverArtUrl` consolidation in `Browse.pm` is behaviour-identical for mapped,
unmapped and id-less trending aggregates, and `_warmCovers` skips an undef URL without spending
a `COVER_WARM_MAX` slot; every completion path in `_fetchReleaseFeed` reaches `$fanout`, so a
background fetch carrying foreground waiters always drains them; `$INFLIGHT{$ikey} = []` is
reached only when unclaimed; `_handleError` tolerates the absent `$p{onError}` a background
fetch has; and build hygiene is consistent (install.xml and repo.xml both 0.9.192, the repo.xml
sha matches the zip, the zip contents match the working tree).

---

## 1. `%REVALIDATING` was a flag where the key it uses demands a count

**FIXED.** It now holds a **count**, released by an idempotent per-fetch `$unclaim` closure
rather than by an unconditional `delete` at each of the three exits.

0.9.191 made **every** fetch claim `$REVALIDATING{$feed}` — the right call, and the reasoning in
`docs/code-review-0.9.191.md` §2 still stands. But the guard is keyed on the **FEED** while the
release was per **FETCH**, unconditional:

```perl
$REVALIDATING{$feed} = 1;       # claimed by every fetch, on a coarse key
...
delete $REVALIDATING{$feed};    # released by whichever fetch finishes FIRST
```

So two foreground fetches of one feed on **different `$ikey`s** — a browse and a forced warm on
another sort, which is *exactly* the overlap 0.9.192 opened by letting the warm take the
`onDone` branch — both claimed the one entry, and the first one out deleted it. The survivor
then ran **unguarded**, and the next background revalidation sailed straight through
`return if $REVALIDATING{$feed}`: a duplicate ListenBrainz request and a duplicate
~3,000-release chunked ingest of one payload — the single thing on this path that must not
happen twice ([[lbf-ingest-event-loop-stall]]), and the thing the 0.9.191 fix exists to prevent.

**`%INFLIGHT` cannot cover this and never could.** It is per-REQUEST, so it says nothing about
two fetches asking *different* questions of the same feed — which is the entire reason the
coarse guard exists alongside it. The 0.9.191 review recorded that asymmetry as deliberate and
correct; what it did not do was carry the consequence through to the release.

The same hole ran in reverse through the leak watchdog: one fetch expiring cleared a healthy
sibling's claim.

**The fix keeps the coarse key** — the argument for it is unchanged (two revalidations of one
feed differing only by sort are still two requests, and ListenBrainz's rate limit is per-user,
not per-question). Only the release changes:

```perl
$REVALIDATING{$feed}++;
my $claimed = 1;
my $unclaim = sub {
    return unless $claimed;
    $claimed = 0;
    delete $REVALIDATING{$feed} unless --$REVALIDATING{$feed} > 0;
};
```

**`$claimed` is load-bearing, not defensive.** A bare `delete` was idempotent for free; a
decrement is not. The watchdog can fire and the real callback arrive afterwards, and `$done` /
`$failed` are each written as though they were the only exit — so without the flag a second
release would free a **sibling's** claim, which is the original bug arriving by another door.

**`%REVALIDATING` is now `our`, not `my`.** Same reason `%FEED_MEMO` is: a test has to reset it
between sections. That is not cosmetic here — the suite drives fetches it deliberately never
answers (claims that in production are always released by `$done`, `$failed` or the watchdog),
and every section shares one feed key. **The boolean hid that**, because any single release
deleted the entry; a count does not, so an un-resettable registry would make each section's
result depend on what the sections before it left dangling. Two sections were failing on
exactly that before the reset was added — a real property of the change, surfaced as a test
artefact.

**Guard.** `t_feedsingleflight.pl`, new section *THE FEED GUARD IS A COUNT, NOT A FLAG* (9
assertions), behavioural against a stale-but-populated store: two forced fetches of one feed on
different sorts both go out; the first landing does **not** free the second's claim, so a browse
on a *third* sort still renders from the store and does not revalidate; once both are out a
later browse **can** revalidate again (the count reaching zero — the failure a naive refcount
trades for the one being fixed); and a fired watchdog frees only its own fetch's claim.

**Anti-tested** by restoring the 0.9.192 unconditional release: **3 red**, one of them reading
**3 requests where 2 were expected** — the duplicate fetch itself.

---

## 2. The forced MuSpy warm answered with the fetched slice, not the store

**FIXED.** The success path now serves the store, through the same `$serveStored` every other
exit uses, with the fetched rows as a fallback.

0.9.192's `&& !$force` gate on the store short-circuit is right — a forced warm must refetch.
But the success path then resolved the caller with the raw payload:

```perl
my $res = _ingestFeed($feed, $rels, undef, undef, 0);
if ($res->{refused}) { $serveStored->(); return }
$args{onDone}->(_memoSet($memoKey, $rels));   # the ?limit=100 slice
```

while **every other exit** — cached, refused, unparseable, network failure — answers from
`_feedFromStore($feed, undef, undef, 0)`: unwindowed, rotation off, 120-day retention, exactly
as the block comment immediately above the sub insists it must be.

`?limit=100` is a **top-N slice**, not a window. So the forced warm handed `warmFeeds` a
**shorter list than any browse renders**, and `warmFeeds` feeds that answer straight to
`_warmCovers` — stored rows inside the display window that fell outside the 100 silently lost
their nightly cover warm, which is the one thing the warm exists to do. The 5s memo also briefly
published the short list to For You.

**This is the ladder's own rule arriving from a new direction.** The comment above this sub
already says a truncated list is not proof of absence — that is why rotation is off and why day
coverage would be a lie. Serving the slice as the answer is the same mistake at the other end:
treating the top-N as if it described the feed.

**The fix converges success and refusal on one answer**, deliberately: the caller gets what the
store holds either way — with today's rows merged in when the ingest took them, without when it
refused — and never the raw slice. `$fallback` covers a store that somehow reads back empty;
better a short answer than none.

**BOTH properties are now asserted, and the pair is the point** — they pull in opposite
directions and either alone passes against the wrong behaviour:

| assertion | pins | breaks if |
|---|---|---|
| the answer contains `FETCHED` | 0.9.190 — the warm acts on what ARRIVED | the store short-circuit is un-gated (the stale-store bug) |
| the answer contains `STORED-MUSPY` | the 0.9.192 review — the warm warms what the VIEW renders | the raw slice is served |

Asserting only the first is how the 0.9.192 assertion read, and it passes against serving the
slice.

**The MuSpy section's ingest stub had to become stateful**, and that is a finding about the test
rather than the code: with a no-op ingest the store can never reflect the fetch, so the section
could only ever have pinned a stub artefact. Appending is also what the real store does — MuSpy
is stored with rotation **off**, so today's slice merges with the retained rows rather than
replacing them.

**Guard.** `t_feedsingleflight.pl`, the existing MuSpy section, one assertion replaced by two.
**Anti-tested** by restoring `$args{onDone}->(_memoSet($memoKey, $rels))`: **1 red** — and the
`FETCHED` assertion beside it stays **green**, which is the evidence that the two are
independent rather than two spellings of one check.

---

## Test suite

`t_feedsingleflight.pl` 78 → **88 assertions**. Every other suite in `tools/` re-run and green
(22 files, no failures) — `t_db.pl` 250, `t_genrefill.pl` 191, `t_bioreveal.pl` 135,
`t_buildingstate.pl` 76, `t_coverwarm.pl` 64, `t_diag.pl` 64, `t_weekwindow.pl` 55,
`t_warmstats.pl` 51, and the rest.

**No schema change, no cache bump, no `BASE_VERSION` bump.** Nothing here changes the SHAPE of a
stored value: finding 1 is an in-process registry, and finding 2 changes which already-stored
rows are handed to a caller, not what is stored.
