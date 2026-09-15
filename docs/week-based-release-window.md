# Week-based release window

Design note for the change that replaces the rolling `days` window with whole Monday-to-Sunday
weeks and caps the scope at four weeks. Written against 0.9.174.

## The problem

The release window was a rolling **day** count: `days` (1–90, default 14) plus four per-section
past/future checkboxes. `API::_feedWindow` turned that into `today − days … today + days`, and
that range was both the coverage window and the read filter on the store.

Two things fell out of it.

**A rolling day window cuts weeks in half.** The UI renders in whole weeks — `W/C <Monday>` rows
built from `Browse::_weekStart` — but the window's edges landed on arbitrary days. With
"Include Past Releases" off, the current week's row contained only *today onwards*, so Friday's
releases (the week's main drop, and the day the user actually browses for) were gone by
Saturday. Turning past releases on was the only workaround, and it dragged in a ragged 14 days
of history rather than whole weeks.

**90 days was too wide.** The ceiling made the feed slow to populate and expensive to keep warm,
over a range nobody browses.

## The shape of the fix

Stop expressing the window in days. Express it in **whole weeks anchored to Monday**, with a
hard budget of four weeks total:

    weeks_past  (0–3)   whole weeks BEFORE the current one
    [current week]      always included, Monday to Sunday, in full
    weeks_future (0–3)  whole weeks AFTER the current one

    clamped so 1 + weeks_past + weeks_future <= 4

The current week always being whole is the entire point: a Friday release stays visible until
the *week* rolls out of scope, not until midnight.

The four per-section checkboxes survive as on/off **gates** — unticked means zero weeks on that
side, *for that section only* — so For You and All Releases keep their independent defaults
(`foryou_future` on, `all_future` off). They are relabelled to talk about weeks, because their
meaning shifts from "any past release" to "earlier whole weeks": the current week is included
either way.

## Why this is cheap

Because of the 0.9.166 store rework. Releases are stored permanently and the window is only a
**filter on the read** (`DB::feedReleases`) — narrowing it costs nothing and invalidates
nothing. No `BASE_VERSION` bump: `DB.pm`'s header warns that one loses every older row for good,
because ListenBrainz only re-serves releases inside the window it is asked for.

## Design

### `_feedWindow` snaps to week boundaries

```perl
use constant WEEKS_MAX_SIDE => 3;   # current week + 3 = the four-week budget

sub _feedWindow {
    my ($wp, $wf) = @_;
    ...
    my $mon = DB::_weekStart(_today());
    return ( _shiftDay($mon, -7 * $wp), _shiftDay($mon, 7 * $wf + 6) );
}
```

It reuses **`DB::_weekStart`** — arithmetic-only, Monday-based, already documented as matching
`Browse::_weekStart`. There is no third week-start implementation.

### The LB `days=` parameter is derived, not configured

ListenBrainz has no date-range parameter. Both fresh-releases routes take `days=N&past=&future=`
and answer symmetrically about today, which is the same constraint that stops a coverage gap
being repaired with a partial fetch. So a week-aligned window asks for the **wider** of its two
sides and lets `feedReleases` trim the rest on read:

```perl
sub _feedRequestDays {
    my ($from, $to) = @_;
    my $today = _today();
    my $back  = _spanDays($from, $today);
    my $fwd   = _spanDays($today, $to);
    return ( ($back > $fwd ? $back : $fwd), ($back > 0 ? 1 : 0), ($fwd > 0 ? 1 : 0) );
}
```

Worst case is 3 whole weeks + 6 days = **27**, against the old pref's 90 ceiling. The
over-fetched rows on the narrower side are simply stored; nothing shows them.

Note that `future` comes back **true even when the user's "later weeks" box is off**, because
the current week runs to Sunday. That is intended, and it is the mechanism behind whole weeks.

### One shared window helper

`API::sectionWeeks($prefix)` — `'foryou'` or `'all'` — is the single place that reads the week
prefs and applies that section's two checkbox gates. It replaces ~12 duplicated
`$prefs->get('days') // 14` + past/future read sites in `Browse.pm` and the second copy inside
`clearFeedCache`. Those sites disagreed: `foryou_future` fell back to `// 0` in four places and
`// 1` in `warmFeeds`.

It lives in `API.pm` rather than `Browse.pm` because `clearFeedCache` has to rebuild the
identical memo key.

### MuSpy rides the same window

`muspy_future_months` (1–24, default 12) is retired. `muspy_future` stays as the future-side
gate, so MuSpy upcoming can still be on when the LB one is off — it is just measured in the same
weeks now.

**This does not lose far-out announcements.** MuSpy is fetched `?limit=100` newest-first, stored
with `rotate => 0`, and read back from the store **unwindowed** (`_feedFromStore($feed, undef,
undef, 0)`). A followed artist's album announced three months out is fetched and held today; the
week window only decides whether it is *displayed*. Each Monday the forward edge rolls on and it
appears. Rows age out on `seen_at` in `DB::feedSweep` at 120 days, and upcoming releases sit at
the top of MuSpy's newest-first list, so they keep being refreshed while they wait.

## Prefs

| Pref | Was | Now |
|---|---|---|
| `days` | 1–90, default 14 | **retired** |
| `weeks_past` | — | 0–3, default 1 |
| `weeks_future` | — | 0–3, default 2 |
| `muspy_future_months` | 1–24, default 12 | **retired** |
| `foryou_past` / `foryou_future` | 1 / 1 | unchanged, relabelled "earlier/later weeks" |
| `all_past` / `all_future` | 1 / 0 | unchanged, relabelled "earlier/later weeks" |
| `muspy_future` | 1 | unchanged (gates MuSpy's future side) |

**Migration: none.** Old `days` / `muspy_future_months` values are left in place and simply stop
being read; their form fields are removed. Everyone lands on 1 week back / 2 ahead.

## The trap in `Settings.pm`

`if (exists $params->{pref_days})` was the sentinel that said "this is a real form POST", and it
is what makes the checkbox coercion run at all. Removing `pref_days` from the template without
moving that sentinel to `pref_weeks_past` silently breaks **every** checkbox on the page:
unchecked boxes store as `undef`, which reads back ON through the `// 1` guards, so `all_past`
and `foryou_past` become impossible to turn off. That is the exact bug the comment above it
documents.

## Verification

1. `perl -c` each changed `.pm`, then sweep called-vs-defined subs. `_feedWindow` changes arity
   and `_dateShift` / the MuSpy month constants go away — `perl -c` does not catch a call to a
   sub that no longer exists.
2. **The Friday test.** On any day Tue–Sun, open All Releases with "Include earlier weeks" *off*.
   The `W/C <this Monday>` row must still list that week's Monday-to-today releases, Friday's
   included. Before this change it listed only today onwards.
3. Week-boundary check: oldest and newest `W/C` rows exactly `weeks_past` back and
   `weeks_future` forward from this Monday, at most four rows total.
4. Log (`debug_log` on): `feed '…' served from the store: N releases, D/D days` — the day count
   is now a multiple of 7. `MuSpy merge: kept N of M within window [lo .. hi]` — `lo` a Monday,
   `hi` a Sunday.
5. Settings round-trip: save, then confirm a previously-ticked `all_past` can be unticked **and
   stays unticked**. That is what proves the sentinel swap landed.
6. Set `weeks_past=3, weeks_future=3` and save; the page must come back clamped, never a
   seven-week window.

---

## As built

Built against 0.9.184 and **shipped as 0.9.185**. The design above holds; four things came out
differently or firmed up, and one thing in the design was wrong about its own scope.

### `sectionWindow` joins `sectionWeeks`

`sectionWeeks($prefix)` returns the gated, clamped week *counts*, which is what a fetcher needs
(they go in the memo key). But `_windowSpan` and `_mergeMuSpy` filter dates and never fetch, so they
want the pair of `YYYY-MM-DD` edges. `API::sectionWindow($prefix)` is `_feedWindow(sectionWeeks(…))`
and exists so neither of those two grows a second copy of the arithmetic. Both are callable as a
method or as a plain sub.

MuSpy is a **third prefix**, not a special case at the call site: `%WEEK_GATES` maps
`muspy => [ 'foryou_past', 1, 'muspy_future', 1 ]` — the For You window with `muspy_future` swapped
in for `foryou_future`. `_mergeMuSpy` is then a single `$d ge $lo && $d le $hi`, because a side whose
box is unticked contributes zero weeks and its edge collapses onto the current week's Monday or
Sunday. The old past/future branch disappears with it.

### The memo key got ONE builder, which the design did not ask for

The design says `sectionWeeks` "lives in `API.pm` rather than `Browse.pm` because `clearFeedCache`
has to rebuild the identical memo key". Writing it that way left two `join`s that had to stay
byte-identical by hand — and *that*, not the pref reads, is the actual 0.9.141 Refresh bug (drop a
key nobody holds, then serve the copy you meant to replace). So there is now `API::_feedMemoKey`,
and both fetchers plus both halves of `clearFeedCache` call it. Four call sites, one builder, and
the literal `lbf:feed:{all,user}:` prefixes appear nowhere else.

### The over-budget clamp rule

The design specifies the budget but not which side loses when a user asks for more. **Past is
honoured first; the future takes the remainder** — 3/3 becomes 3 back / 0 ahead. Earlier weeks are
releases that exist; upcoming ones are announcements. It is applied in *both* places, because the
two guard different things: `Settings::handler` clamps on save so the page comes back showing what
was stored, and `API::_clampWeeks` clamps again at read time because `prefs.yaml` is hand-editable
and the value is multiplied out into a date range.

### `_feedRequestDays` needs a floor

As specified it can return `days => 0` — nothing in the arithmetic prevents it, and a `days=0` fetch
would answer with nothing. It returns at least 1. (In practice the minimum a legal window produces
is 6: the current week alone, opened on a Monday or a Sunday.)

### The verification list was incomplete

Step 1 says `perl -c` each changed `.pm` and sweep called-vs-defined. Both were done — and both are
blind to what actually broke, which was **two existing test suites**:

- `t_feedsingleflight.pl` gave each section its own `days` value purely to get a distinct memo key
  (`%INFLIGHT` is a file-lexical and cannot be reset from a test). With `days` inert, every section
  collapsed onto one key and section 2 parked behind section 1's deliberately-outstanding fetch. It
  now varies `weeks_past`/`weeks_future` through the prefs — which is also how the key varies in
  production. It also had to set `all_future = 1`, or the gate zeroes the very side it is varying.
- `t_review_fixes.pl` finding 2 lifts `clearFeedCache` into a stub package and spelled the expected
  feed key out as a literal `join`. It now asks `_feedMemoKey` for the key the way the fetcher does,
  so it cannot pass on the day the two drift apart.

Neither is a papering-over: the key shape genuinely changed. But a plan that lists `perl -c` and a
sub sweep as its static gates should list "run the suites that lift these subs" next to them.

### Gates run

`perl -c` clean on API / Browse / Settings / DB (scratchpad stublib; Plugin's only error is the
usual stub-env `main::WEBUI` bareword). Called-vs-defined swept — `_feedWindow` changed arity and
`_dateShift`, `MUSPY_FUTURE_MONTHS_DEFAULT`/`_MAX` are gone. All 21 suites green, including the new
`tools/t_weekwindow.pl` (55 assertions, anti-tested three ways: a today-relative window turns 13 red
including the Friday test, the sentinel left on `pref_days` turns 1 red, and `foryou_future` drifting
back to `// 0` turns 4 red).

**Built as 0.9.185**: `install.xml` + `repo.xml` bumped, zip rebuilt (52 files), `repo.xml <sha>`
recomputed, and `t_loads.pl` run **against the extracted zip** — the condition LMS actually imposes,
which every other suite hides by loading its subject with the rest of the plugin already in memory.
`DEV_BUILD` verified as `1` inside the zip.

**NO CACHE BUMP, AND NONE IS WANTED.** The window is a filter on the read, so narrowing it
invalidates nothing; the version bump alone triggers `_buildChanged`, which is the dev-build wipe.
**`BASE_VERSION` MUST NOT BE BUMPED** — see `DB.pm`'s header: it loses every older stored release for
good, because ListenBrainz only re-serves releases inside the window it is asked for, and this change
NARROWS that window.

**README DONE 2026-09-15 (Simon asked for it ahead of the merge).** `README.md` now documents Weeks to
show / Upcoming weeks per section with the `2`/`1` defaults, MuSpy following For You's weeks, and an
upgrade note that the Days window, Include Past/Upcoming and MuSpy's own settings are not carried
over; `README.html` is regenerated. **`CHANGELOG.md` is still a merge-to-main item.**

## As changed — per-section weeks, counted from 1 (2026-09-14, 0.9.215; installed as part of 0.9.217; defaults changed to `2`/`1` in 0.9.220)

Simon: *"overly complicated and has too many boxes. It also doesn't allow for All Releases to be
configured differently to For You … starting at week 0 feels wrong. Current week should always be 1."*

**The settings.** Seven controls (`weeks_past`, `weeks_future`, `foryou_past`, `foryou_future`,
`all_past`, `all_future`, `muspy_future`) became two number boxes per section:

    <section>_weeks     (1-4)            weeks shown IN TOTAL — the current week is week 1
    <section>_upcoming  (0 .. weeks-1)   how many of those are after the current week

Defaults are `2`/`1` for both sections — this week + next week (Simon, 2026-09-15). As first built
they reproduced 0.9.185 — For You `4`/`2` (1 back + this + 2 ahead), All Releases `2`/`0` (1 back +
this). No migration, by the 0.9.185 precedent: the old prefs simply stop being read.
`main` (0.9.149) never shipped `weeks_*`, so only the four gates and `days` are orphaned for real users.

**Why a total rather than "this week + earlier".** The four-week budget becomes a property of the
input: `upcoming` is held to `weeks - 1`, so nothing is ever trimmed off one side to make room for
the other (the old past-first clamp, which silently changed the value the user did not touch, is gone
from the user-facing path). The internal `(past, future)` pair is DERIVED —
`past = weeks - 1 - upcoming`, `future = upcoming` — so `_feedWindow`, `_feedRequestDays`,
`_feedMemoKey` and the store are untouched. `API::clampSectionWeeks` is the one rule, applied on save
(`Settings::handler`, through `->can`) and on read (`sectionWeeks`).

**MuSpy has no window of its own any more.** Simon: MuSpy should never show anything past four weeks,
and should roll over the same way the ListenBrainz feed does. Checked before deciding: MuSpy's per-user
`releases` query is `ORDER BY date DESC` with no date bound (muspy `app/models.py`
`ReleaseGroup.get`), so the top of our `?limit=100` slice is the furthest-out announcements — the one
thing MuSpy can show that ListenBrainz cannot. They are still fetched and stored unwindowed; they are
no longer SHOWN past For You's weeks. So:
- the `'muspy'` prefix and `%WEEK_GATES` are gone; `_mergeMuSpy` windows on `sectionWindow('foryou')`;
- `_sectionBounds` no longer unions a MuSpy window (0.9.207's fix is moot, not reverted — with one
  window for both feeds the union IS the For You window). It stays the single carrier;
- the nightly MuSpy warm now hands `_warmCovers` / `_queueReleaseDetails` only the rows inside the
  window (`_filterForYou(_mergeMuSpy([], …))`). It used to warm covers for every stored MuSpy row,
  months-out announcements included — work for rows nothing draws.

**Observed, not changed:** MuSpy dates with only a year or month are padded to the 1st
(`API::_padDate`), so an album announced for just "2026" is dated 1 January and never falls inside a
current window. Pre-existing; out of scope here.

**Tests.** `t_weekwindow.pl` rewritten (62): the (weeks, upcoming) clamp over the whole input space,
the derived pair, per-section independence, retired prefs inert, MuSpy not a section, the MuSpy warm
windowed, the sentinel moved to `pref_foryou_weeks`. Anti-tested four ways — upcoming clamp removed
4 red, sentinel back on `pref_weeks_past` 1 red, merge on a `'muspy'` window 1 red, and (in
`t_detailwarm.pl` §8, rewritten) the union restored 3 red. `t_feedsingleflight`, `t_review_fixes`,
`t_cachememo`, `t_coverwarm` and `bench_walk` fixtures moved to the new prefs. `bench_walk.pl` exits
255 on a clean extract of HEAD too (its API stub lacks `lastfmConfigured`, from 0.9.213) — not this
change.
