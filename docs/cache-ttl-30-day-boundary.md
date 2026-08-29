# Cache TTLs over 30 days are silently never read back — `RECMETA_TTL` is affected

**Status: FIXED 2026-08-13**, and there were **TWO** instances, not one — see §2.
Root-caused 2026-08-07 in the sibling Pitchfork Reviews plugin, where it cost five
releases of misdiagnosis. Both constants are now `30 * 86400`, and
**`tools/t_ttlceiling.pl`** fails any TTL above the boundary, in any of `API.pm`,
`Browse.pm`, `DSTM.pm`, `Diag.pm`, including durations written inline into a
`$cache->set` call where no constant sweep can see them.

**The audit in §2 below was incomplete when it was written, and the reason is worth
keeping:** it was made before the 0.9.162 genre work added `AGEN_FOUND_TTL`, so the
table was correct on the day and silently wrong a release later. A one-off audit
records a moment; only the guard covers the file. That is why §4 mattered more than
§3 all along.

**The end state** is `DB.pm`, where staleness is a `fetched_at` age policy applied in
Perl and no duration is handed to LMS at all — so the defect stops being *corrected*
and becomes *inexpressible*. `t_ttlceiling.pl` §4 reports how much of the plugin still
uses `Slim::Utils::Cache`; when that list is empty the sweep is redundant. See
`docs/caching-rework.md`.

---

## 1. The mechanism (LMS source, not inference)

`Slim/Utils/DbCache.pm`, `_canonicalize_expiration_time`, LMS 9.1 — the comment is
LMS's own:

```perl
# "If value is less than 60*60*24*30 (30 days), time is assumed to be
# relative from the present. If larger, it's considered an absolute Unix time."
if ( $expiry <= 2592000 && $expiry > -1 ) {
    $expiry += time();
}
```

**Any TTL above 2,592,000 seconds is not a duration — it is read as an absolute Unix
timestamp.** So `90 * 86400` = 7,776,000 is stored as an expiry of **1970-04-01**.

The read side then does:

```perl
sub get {
    ...
    if ($expiry && !$self->{noexpiry} && $expiry >= 0 && $expiry < time()) {
        $data = undef;
    }
```

so the entry is already expired the instant it is written.

**Why it is invisible.** The row IS written. `set` returns 1. Nothing dies, nothing
warns, no error appears in the log. The only symptom is that the cache never hits —
which reads as "the feature is slow", not "the cache is broken".

Other accepted forms, for reference: `'never'` → -1 (never expires, and `purge` skips
negative expiries), `'now'` → 0, and `"<n> <unit>"` strings (`'90 days'`) which ARE
converted correctly — `time() + 86400*90` — because that branch adds `time()` itself.
So `'90 days'` works where `90 * 86400` does not. That trap is worth knowing.

## 2. What is affected in LBF

Audited every `*TTL*` constant in `ListenBrainzFreshReleases/API.pm`:

| constant | value | days | status |
|---|---|---|---|
| **`RECMETA_TTL`** | **7,776,000** | **90** | **WAS BROKEN — fixed 2026-08-13, now 30d** |
| **`AGEN_FOUND_TTL`** | **7,776,000** | **90** | **WAS BROKEN — added by 0.9.162, after this table was written; fixed 2026-08-13** |
| `MB_FOUND_TTL` | 2,592,000 | 30.0 | ok (boundary is `<=`) |
| `FEED_FALLBACK_TTL` | 2,592,000 | 30.0 | ok |
| `LFM_FOUND_TTL` | 2,592,000 | 30.0 | ok |
| `PLAYLIST_LIST_FALLBACK_TTL` | 691,200 | 8.0 | ok |
| `SIMILAR_TTL`, `LFM_EMPTY_TTL` | 604,800 | 7.0 | ok |
| everything else | ≤ 86,400 | ≤ 1 | ok |

**One constant, and it is the worst one to lose.** `RECMETA_TTL` is the *dated* branch:

```perl
my $ttl = length($fresh{$mk}{year} // '') ? RECMETA_TTL : RECMETA_YEARLESS_TTL;
$cache->set(RECMETA_PFX . $mk, $fresh{$mk}, $ttl);
```

So a recording that **successfully resolved a year** is cached at 90 days and thrown
away; a **yearless** one is cached at 1 day and kept. Exactly backwards. Every dated
recording is re-fetched from LB on every pass, for ever — `RECMETA_PFX` has never
served a hit for dated data since the 90-day value was introduced.

**`RGMETA_PFX` shares that line**, which is where the user-visible damage was: the
release-group metadata cache applies the same constant, so **the ListenBrainz genre
tiers have never once served a dated release**. Every genre label seen on screen came
from the feed's inline `release_tags` or from Last.fm, and the background top-up
re-fetched the same releases on every single visit because nothing ever persisted.
Verified live on three rows before the fix (NCT 127 – *BLINGY*, Davenki Pi Wiart –
*Trama De Luz*, Jonathan Bree – *Don't Call It Love*: all dated, all 90d, all
unreadable). `AGEN_FOUND_TTL` made the mirror artist-genre path 100% broken in the
same way. **Expect a visible jump in genre coverage the first time the fix runs —
that is the tier working for the first time, not a new bug.**

## 3. Fix

```perl
use constant RECMETA_TTL => 30 * 86400;   # 2_592_000 is the hard ceiling — see below
```

30 days is the largest duration the cache can express. Recording metadata is close to
immutable, so `'never'` is tempting, but 30 days costs one refetch a month and keeps
the door open for LB backfilling a corrected date — the same reason
`RECMETA_YEARLESS_TTL` exists.

**No `RECMETA_PFX` bump.** The stored shape is unchanged, and nothing under the current
prefix is retrievable anyway — there is no stale data to invalidate.

## 4. Guard (the part that matters more than the fix)

Add a sweep to the test suite over **every** `*TTL*` constant in the module, failing on
any value `> 2_592_000`, with the LMS quote in the comment. Pin the class, not the
instance.

The Pitchfork plugin had a ceiling sweep during this investigation and it passed
throughout, because the ceiling was set to **90 days** — a number picked from a wrong
hypothesis. A guard with the wrong constant is worse than none: it looks like coverage.
The only defensible number is 2,592,000, and the comment must say where it comes from.

**Built as `tools/t_ttlceiling.pl`**, and it does four things rather than the one
sketched above:

1. **Reproduces LMS's rule** and asserts the boundary is inclusive — so a guard set to
   the wrong number (the Pitchfork mistake, re-run as an anti-test) fails here first,
   before it can pass a sweep vacuously.
2. **Sweeps four modules**, and inline `$cache->set(…, 25 * 3600)` durations as well as
   named constants. An expression it cannot evaluate is a FAILURE, not a pass:
   "I could not read it" must never render as "it is fine".
3. **Names the two known-bad constants individually**, because a sweep passes the
   moment a constant is renamed away.
4. **Asserts the positive** — `DB::kvSet($k, $v, 90 * 86400)` stores `now + 7776000`
   and reads back — so the fix is proved to be in the storage, not a workaround
   routed around the ceiling.

## 5. Why this took so long to find (worth reading before diagnosing anything similar)

In the sibling plugin the correct hypothesis — "the TTL" — was raised at the first
attempt, then **discarded by a test that never crossed the boundary**: the ceiling was
lowered 365 → 90 days, nothing improved, and TTL was ruled out. Four further releases
went into value size, key names, cache namespaces and chunking, each "disproving" the
previous one while every experiment held the TTL fixed at 90 days.

Three specific false conclusions, all from that one flaw:

- *"a 15-byte value fails, so it is not size"* — true, but it was passed a 90-day TTL
- *"a fresh namespaced cache fails too, so it is not the shared cache.db"* — same TTL
- *"`pfr:stream` works at 90 days, so TTL is innocent"* — it did not. Those hits were
  entries written at **7 days** before the upgrade; as they aged out the hit rate fell
  from 97.6% to 4%, which presented as "it degrades over time"

**Rule that would have caught it:** when a hypothesis is tested, move the variable
*across the suspected boundary*, not just downwards. And when a fix produces no
measurable change, treat the fix as unproven rather than the hypothesis as disproven.
