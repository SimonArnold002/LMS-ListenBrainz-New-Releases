# Cache TTLs over 30 days are silently never read back — `RECMETA_TTL` is affected

**Status:** FOUND, NOT FIXED. Root-caused 2026-08-07 in the sibling Pitchfork Reviews
plugin, where it cost five releases of misdiagnosis. LBF has **one** instance.
**Goal:** fix `RECMETA_TTL`, and add a guard so no TTL in this repo can ever exceed the
boundary again.

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
| **`RECMETA_TTL`** | **7,776,000** | **90** | **BROKEN — never read back** |
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
