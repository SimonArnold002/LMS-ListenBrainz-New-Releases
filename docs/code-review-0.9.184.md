# Code review — 0.9.184 (the week window, the single-flight open path, the genre ladder)

**Reviewed 2026-08-23. ALL SEVEN FINDINGS ARE NOW FIXED AND SHIPPED IN 0.9.186** — each one
carries a **FIXED** note recording what was actually done, what the guard is, and what the
anti-test counted. The finding text below each note is the ORIGINAL, kept as written: it holds
the mechanism and the reproduction, so none of it has to be re-derived.

Two things landed alongside the seven and are **not** findings here — they were Simon's calls,
taken during the fixing: the removal of the detail page's **Last.fm bio** fallback
(`API::getArtistBio`, with the `lbf:bio:` keys and `_setText`/`_getText`) and of its **Last.fm
genre tags** call. See CLAUDE.md's 0.9.186 entry.

**A note on the version this file is named for.** The stamp said 0.9.184 while the code dated
itself 0.9.185 (below); the fixes then shipped as 0.9.186. The file keeps its original name.

**Scope:** the **uncommitted working tree** on `dev` at `3b10989`. The range diff vs `origin/dev`
is empty, so every line reviewed is unstaged:

    git -C /Users/simona/Documents/GitHub/LMS-ListenBrainz-New-Releases diff HEAD

24 files changed, 7,300 insertions / 776 deletions, **plus** the untracked
`ListenBrainzFreshReleases/DB.pm` (the SQLite store). The modules carrying the change are
`API.pm`, `Browse.pm`, `Plugin.pm`, `DB.pm`, `DSTM.pm`, `Diag.pm`, `Settings.pm` and
`settings.html`.

**Excluded by request:** the zip and the `repo.xml` `<sha>` are not checked here. Note the
same applies to the version stamp — `install.xml` reads **0.9.184** while the code and
`CLAUDE.md` date the week-window work **0.9.185**; this file is named for `install.xml`.

**Method.** No LMS on this machine, so `perl -c` cannot load any module — every check below is
static, or executed against a standalone harness. Finding 1 carries a runnable repro that was
actually run; the rest are traced by reading both ends of the call.

---

## Verified clean

- **Called-vs-defined sweep — 0 missing subs.** Every sub removed in this change
  (`_bcMatchKey`, `_cacheFeed`, `_dateShift`, `_followStoreKey`, `RECMETA_PFX`,
  `SORT_CACHE_PFX`, `MUSPY_FUTURE_MONTHS_*`) is fully swept from every module; no private sub is
  called that is not defined. This is the [[perl-c-misses-renamed-subs]] gate.
- **Strings.** Every new token used by `Browse.pm`/`Settings.pm`/`settings.html` exists in
  `strings.txt`, with sprintf arity matching each call site.
- **Schema migrations.** `_migrate_2` … `_migrate_5` are all eval-guarded per statement, so a
  fresh DB — whose `_migrate_1` already creates the modern columns — runs the later migrations
  as no-ops rather than dying on `duplicate column name`.
- **Blob binds.** `_factPut`'s bind positions line up with `_execBlob`'s argument order.
- **Artist-row key namespace.** `n:<norm>` is used consistently across `_persistLbArtistTags`,
  `_warmLastfm`, `_mergeHostedGenres` and `_artistTierGenres` — the fill side and the read side
  agree.
- **The week window.** The new whole-week prefs are read through the single
  `sectionWeeks`/`_feedMemoKey` pair on both the fetch side and the `clearFeedCache` side, so a
  window change invalidates exactly the keys it creates.
- **Single-flight terminals.** `_buildingStart`/`_buildingEnd` ownership, and the `$finish` /
  `$fanout` terminals in `_resolveTrending`, `_resolveFollow`, `_buildAlbumsData` and
  `resolvePlaylist`, fire exactly once on every exit path — including the error paths.

---

## 1. `_cleanBio`'s link-only `<li>` rule eats whole list items — and everything between them

**FIXED 2026-08-23** — `.*?` → `[^<]*` in `API.pm`, with the mechanism written into the
comment above it. Regression locked in by `tools/t_bioreveal.pl` §18 ("a link-PLUS-TEXT item
survives" / "...including one after it" / "...while the link-only item still goes"), anti-tested
against a mutated copy carrying the old pattern: those two survival assertions fail there and
nothing else does.

**`ListenBrainzFreshReleases/API.pm:3923`**

```perl
$s =~ s{<li\b[^>]*>\s*<a\b[^>]*>.*?</a>\s*</li>}{}gis;
```

The rule is meant to delete a list item that is *nothing but* a link (MAI's "More online
sources"). `.*?` is lazy, but laziness only sets the *order* the engine tries lengths in — it
does not stop it. When the first `</a>` is not followed by `\s*</li>` (the item has a link
**plus** text), the engine backtracks and grows `.*?` — under `/s` it crosses `</li><li>`
freely — until it finds *some later* `</a>` that is followed by `</li>`. Everything in between
is deleted.

Run repro (executed, not reasoned):

```perl
my $s = q{<ul><li><a href="x">Album One</a> (1994)</li><li><a href="y">Album Two</a> (1996)</li><li><a href="z">Album Three</a></li></ul>};
$s =~ s{<li\b[^>]*>\s*<a\b[^>]*>.*?</a>\s*</li>}{}gis;
# OUT: <ul></ul>
```

A three-item discography list becomes an empty `<ul>`. Only the *last* item is genuinely
link-only; the first two are collateral. Wikipedia-derived MAI bios — the runtime input
0.9.157 established, per [[mai-bio-is-html-at-runtime]] — are full of exactly this shape
(a linked album title followed by a year, a linked label followed by a date).

**Fix.** Forbid the crossing rather than narrowing the intent: make the middle unable to
contain a tag boundary — `<li\b[^>]*>\s*<a\b[^>]*>[^<]*</a>\s*</li>`. A link-only item has no
inner markup by definition, so `[^<]*` describes it exactly and cannot reach the next item.
Note this is a *pattern* fix, not a parser: it keeps to [[lbf-keep-bio-rendering-simple]] and
touches nothing else in the path ([[lbf-bio-parser-end-of-life]]).

---

## 2. `warmCache` returns before `_warmGenres`, so account-less users never get All Releases genres

**FIXED 2026-08-23** — `_warmGenres()` hoisted above the username gate in `Browse.pm`, so its own
no-username branch (`$warmAll->()`) is live rather than dead. The gate's `_stage('end', …, 'skipped')`
list no longer names `genres_foryou`/`genres_all`/`genres_lastfm`: `_warmGenres` has just recorded
those itself, correctly, and re-ending a live stage with a wrong outcome would be worse than the
missing warm. The stale `genres_lastfm` name (emitted nowhere — the real stages are
`genres_lastfm_all`/`_foryou`) went with it. Nothing in the genre path reads `$client`, so running
ahead of the `$client ||=` line is safe. Guarded by `tools/t_genrefill.pl` §8 (4 assertions),
anti-tested against a copy with the pre-fix ordering restored: 2 red.

**`ListenBrainzFreshReleases/Browse.pm:3388`** (the early return) vs **`:3420`** (the call)

```perl
unless (($prefs->get('username') // '') ne '') {
    _stage('end', $_, 'skipped', 'no username') for qw(...);
    return;                       # <- returns here
}
...
_warmGenres();                    # <- line 3420, never reached without a username
```

`_warmGenres` opens by saying the opposite, and handles the case itself:

```perl
# All Releases needs no account, so it's warmed for everyone.
...
unless ($user) {
    _stage('end', 'genres_foryou',        'skipped', 'no username');
    _stage('end', 'genres_lastfm_foryou', 'skipped', 'no username');
    $warmAll->();                 # <- unreachable from the warm
    return;
}
```

`_warmGenres` has exactly one caller (`Browse.pm:3420`), so that `$warmAll->()` branch is dead
code today. The consequence for an account-less user: All Releases is fetched and stored by
`warmFeeds` (which `Plugin.pm:_warmTick` deliberately runs *ahead* of `warmCache` for this very
reason), but its genres are never pre-warmed — so the view opens bare and can only fill from
the `_kickGenreFill` background top-up, 120 s apart, a page at a time.

This is the same class of thing the `_warmTick` comment already calls out about feeds
("`warmCache` returns early without a username … All Releases HAS NEVER BEEN WARMED FOR
ANYONE"); the feed half was fixed and the genre half was not.

**Fix.** Hoist `_warmGenres()` above the username guard — it already makes the distinction
internally — and drop the genre names from the skip list, since the stages now record their own
outcomes.

---

## 3. A die in the first caller's `onDone` parks every later cold open of that feed for ever

**FIXED 2026-08-23**, and there were **two** unguarded first-caller callbacks, not one. `$done`'s
`$p{onDone}` is the one described here; `$failed`'s **stored-copy branch** calls
`$p{onDone}->(_memoSet(...))` ahead of `$fanout` in exactly the same shape and strands the claim
identically. (The finding is right that the *error* branch is safe — `_handleError` runs no user
code before `$fanout` — but that argument does not extend to the branch above it.) Both are now
eval'd with a logged error, like the waiters.

The watchdog is in too: `%INFLIGHT_TIMER` armed at claim time for `INFLIGHT_MAX` (3 × `FEED_TIMEOUT`),
killed by `$fanout` on every normal exit. It **answers** the parked waiters with an error rather than
just dropping the key — a waiter freed without a callback is still a browse that never renders.

Guarded by `tools/t_feedsingleflight.pl` §7 (the die) and §8 (the watchdog), both behavioural.
§8 needed the suite's `Slim::Utils::Timers` stub replaced: it was the generic no-op AUTOLOAD, so a
timer-based guard could be deleted with the suite still fully green — it now records timers and the
test fires them deliberately. Anti-tested three ways: first-caller eval removed → 4 red, watchdog
removed → 4 red, watchdog dropping the key without answering → 1 red. §7's final assertion is
guarded against a missing request, because the failure it tests for is "no request went out" and an
unguarded `answer_ok` aborts the run at exit 255 with no totals line — which reads like a pass.

**`ListenBrainzFreshReleases/API.pm:946`** (claim) / **`:953`** ($fanout) / **`:962-968`** ($done)

The single-flight registry is claimed with `$INFLIGHT{$ikey} = []` and released **only** inside
`$fanout`, which is reached after the first caller's own callback has already run:

```perl
my $done = sub {
    delete $REVALIDATING{$feed} if $bg;
    return unless $p{onDone};
    $p{onDone}->($_[0]);           # NOT eval'd
    $fanout->('onDone', $_[0]);    # the only `delete $INFLIGHT{$ikey}`
};
```

The waiters are each eval'd — deliberately, and the comment says why — but the *first* caller
is not. `$p{onDone}` is an XMLBrowser render callback: if it dies, `$fanout` never runs, the
`$ikey` entry is never deleted, and it holds an empty arrayref. From then on every later
non-background caller with the same memo key + headers takes the park branch at `:940`, pushes
itself onto a list nothing will ever drain, and returns without rendering. There is no
watchdog on `%INFLIGHT` (unlike `_kickGenreFill`'s `GENRE_KICK_MAXRUN` and the building
registry's leaked-flag timer), and the registry is in-process by design, so nothing clears it
short of a server restart.

`$failed` has the same shape but is safe by construction — `_handleError` is called *before*
`$fanout` and does not run user code between the two.

**Fix.** Two lines, matching the belt-and-braces pattern already used elsewhere in this file:
wrap the first caller's `onDone` in the same `eval { … } or $log->error(…)` the waiters get, and
arm a watchdog timer at claim time that deletes `$INFLIGHT{$ikey}` unconditionally after the
fetch timeout, so no path can leave the key claimed.

---

## 4. `_withGenresLB` never calls back for a list with no release-group MBIDs

**FIXED 2026-08-23** — `unless (@batches) { $cb->({}); return }` after the splice loop, exactly as
scoped, with the mechanism and the warm consequence written into the comment above it.

Reproduced behaviourally before the change, driving the real sub over stubbed timers: release-group
list → callback fires; mixed list → fires; **artist-only → 0 calls**. After: 1, 1, 1.

Confirmed the blast radius while verifying: every RENDER call site passes `peek => 1`, and the peek
branch always calls back, so no browse view could hang on this. The only non-peek callers are the
two in `_warmGenres` (the reported case) and `_kickGenreFill` — the latter would also strand
`$_genreKicking`, but its `GENRE_KICK_MAXRUN` watchdog already covers that, so the warm is the real
damage.

Guarded by `tools/t_genrefill.pl` §14 (8 assertions, behavioural — "the chain simply stops" is not
something a pattern match can show), including the mirror path's `unless (@artists)` guard so the
precedent cannot quietly go the same way. Anti-tested: guard removed → 2 red; the mirror guard
removed → 1 red. **The `return` itself is NOT pinned** — dropping it leaves the code correct anyway,
because `$starts` is 0 for an empty `@batches` so `$step` never runs and no second answer is
reachable. The "answers once, never twice" assertion documents the contract rather than catching
that mutation, and is recorded here as such rather than claimed as coverage.

**`ListenBrainzFreshReleases/Browse.pm:7801-7804`**

```perl
my $starts = @batches < GENRE_CONCURRENCY ? scalar @batches : GENRE_CONCURRENCY;
for my $i (1 .. $starts) {
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.05 * $i, $step, $step);
}
```

`@batches` is built from `@mbids`, which is `grep { defined && length }` over
`release_group_mbid`. When it is empty, `$starts` is 0, the loop runs zero times, `$step` never
runs, and `$cb` is never called at all — the chain simply stops.

The all-empty case is guarded upstream (`_withGenres:7642`, `unless (@rels || @artOnly)`). The
reachable hole is the *mixed* case the same commit deliberately introduced: **`@rels` empty,
`@artOnly` non-empty** — a list whose rows carry an artist credit but no release group. That is
precisely the Trending shape the `@artOnly` budget was added for ("the Trending rows with no
MBID are precisely the case they exist to answer").

Consequence in the warm: `_warmGenres` chains For You → Last.fm → `$warmAll`. A For You pass
that filters down to artist-only rows never reaches its own callback, so `genres_foryou` stays
`running` in `warmstats` and **All Releases is never warmed at all** for that tick.

`_withGenresMirror` is not affected — it guards with `unless (@artists) { $cb->({}); return }`
at `:7688`. This is the guard the LB path is missing.

**Fix.** Mirror it: `unless (@batches) { $cb->({}); return }` immediately after the splice loop.

---

## 5. `warmstats`' skip list names a stage that does not exist

**FIXED 2026-08-23**, as predicted — the genre names came off that list with finding 2, and
`genres_lastfm` went with them. Verified rather than assumed: extracting every name handed to
`_stage` (direct and bulk `qw()` forms) and every name started gives **two identical sets** —
no phantom, no orphan.

The finding stops at the one name, but the reason it survived is that **nothing checked this
direction**. `t_warmstats.pl` §5 walks a list of expected stages and asks "is each one marked?",
which cannot see a mark for a stage that does not exist. It now also derives both sets from the
source and asserts each way: a name ended but never started (the phantom), and a name started but
never ended — the mirror hazard, which reads as a stage stuck `running` for ever rather than as a
missing mark. Both messages name the offending stage. Derived from source rather than from a list
restated in the test, because a hand-kept list of valid names is the same class of thing that
produced the phantom.

Anti-tested: the exact 0.9.184 skip list reinstated → 1 red, naming `genres_lastfm`; a stage's only
`_stage('end', …)` deleted → 1 red, naming `covers`.

**`ListenBrainzFreshReleases/Browse.pm:3389`**

```perl
for qw(genres_foryou genres_all genres_lastfm playlists
       follow_feed trending_tracks trending_month trending_year);
```

`genres_lastfm` is recorded nowhere else. The real stage names are `genres_lastfm_all`
(`:8045`, `:8054`) and `genres_lastfm_foryou` (`:8073`, `:8086`, `:8092`).

Because `stageEnd` creates a row for any name it is handed (deliberately — "a stage that was
never started still records"), the `["lbf","warmstats"]` report for an account-less user shows
a phantom `genres_lastfm` line and no line for either real Last.fm stage. Instrumentation only,
but it is the instrument being read to judge the warm ordering work.

**Fix.** Falls out of finding 2 — once `_warmGenres` runs unconditionally, the genre names come
off this list entirely and each stage reports its own real outcome.

---

## 6. Mirror mode can't see `detail_genres`, so the 0.9.173 fix is half-applied

**FIXED 2026-08-23** — new `Browse::_mergeRgGenres`, called from **all three** of
`_withGenresMirror`'s exits: the peek branch, the `getArtistGenres` callback, and the
`unless (@artists)` branch. That third one is not in the finding but is the same defect — the
artist rungs having nothing to look up says nothing about whether the RECORD has an answer, and it
was returning `{}`.

It reads through `API->peekReleaseGroupMetadataBulk` rather than `DB::rgGet` directly, so the two
paths cannot drift on key-casing or row shape, and it is **one bulk read per page** — asserted, not
assumed, because a per-row read here is the ~2,900 synchronous SELECTs `bench_walk` caught in
0.9.165. It **creates** a `$meta` entry as well as filling one: `_metaFromArtists` only makes a row
where some credited artist had genres, so a release group whose only answer is the detail page's
had nowhere to put it — that is the half of the bug a naive merge would miss, and it is anti-tested
separately.

**Then extended to tier 1 as well, on Simon's go-ahead (2026-08-23).** The same row's `genres`
column — the album's own ListenBrainz tags — was being ignored by mirror mode for exactly the same
reason. It was raised separately rather than folded in because it is a VISIBLE change for existing
mirror users: a row reading as the artist's genre can flip to the album's own.

**What settled it was checking whether a mirror box's store ever holds one — it does.**
`getReleaseGroupMetadata` is called by the Trending Tracks date fill (`Browse.pm:2139`) and the
Trending Albums release-group pass (`:2486`) **regardless of genre lookup mode**, and that request
carries `inc=release_group tag`. So it writes the `genres` column on a mirror box where the genre
ladder itself never touches it: a mirror user who had browsed Trending had album-level genres in
the store that the list refused to read. `agenres` is still NOT merged here — the artist tiers have
their own reader, already filled from the mirror's own artist rows on this path.

The sub is therefore `_mergeRgGenres`, not `_mergeDetailGenres` — it now merges both release-group
tiers, and a name that describes only one of them would be the kind of thing this file's comments
exist to prevent. Renamed with a called-vs-defined sweep after it ([[perl-c-misses-renamed-subs]]):
0 missing.

Guarded by `tools/t_genrefill.pl` §15 (11 assertions), driven end to end through the real
`_withGenresMirror` **and** the real `_genresFor`, because the property is "which tier answers" —
asserting on the map alone would not show an artist proxy still outranking the record. It pins the
full order: tier 1 over tier 1b over the artist, and the artist rung unchanged where the record
says nothing. Anti-tested: the mirror path reverted to 0.9.184 → **5 red**; the merge filling only
pre-existing entries → **3 red**; tier 1 not merged → **1 red**.

**One assertion is documentation, not coverage, and is recorded as such.** "an empty tier-1 column
does not erase the tier-1b answer" pins the `if @$own` / `if @$det` guards, but replacing them with
blanket assignment goes **0 red** — nothing on this path can put a non-empty value in either slot
before the merge runs (`_metaFromArtists` always seeds `genres => []`), so the damage is not
reachable today. Same shape as finding 4's `return`. Kept because it would catch a future caller
that merges into an already-populated map.

One test was changed, not just code: §14's mirror assertion had pinned that guard's exact source
line and went red on this correct change. It now pins the property (the branch calls back and
returns) rather than one spelling of it.

**`ListenBrainzFreshReleases/Browse.pm:7654`** (`_withGenresMirror`) / **`:7700`**
(`_metaFromArtists`)

`_genresFor` tier 1b reads `$m->{detail_genres}` out of the `$meta` map — the release detail
page's own answer about *this record*, ranked above the artist tiers on purpose. `detail_genres`
reaches `$meta` only from `DB::rgGet`, called by `peekReleaseGroupMetadataBulk` and
`getReleaseGroupMetadata` — **both on the LB path only**.

Mirror mode builds `$meta` entirely from artist rows:

- peek: `peekArtistGenresBulk` → `_metaFromArtists`;
- non-peek: `getArtistGenres` → `_metaFromArtists`;
- `_metaFromArtists` hard-codes `{ genres => [], agenres => $g }` and never touches the
  `release_group` row.

So in mirror mode, tier 1b is unreachable and opening an album still throws its answer away as
far as the list is concerned — the exact defect `_migrate_5` and the 0.9.173 note describe as
fixed. Note this is the **default** path on any server with a local MB mirror
(`_genreLookupMode` returns `mirror` under `auto` when `hasMirror()`), which includes the
development server ([[mb-mirror-no-auto-replication]]).

Related, and cheap to do at the same time: `_rgAnswered` counts `detail_genres` as an answer,
so a release group holding only a detail answer is correctly excluded from the top-up — but in
mirror mode nothing ever reads that column to notice.

**Fix.** In `_withGenresMirror`, do the one bulk `rgGet` over the release-group MBIDs that the
LB peek path already does, and merge `detail_genres` (and `n_genres`) into the map
`_metaFromArtists` returns. It is one bulk read per render, not one per row, so it does not
reintroduce the 0.9.130 hazard the comments guard against.

---

## 7. A failed dev-build wipe is recorded as done and never retried

**FIXED 2026-08-23** — `$prefs->set('last_build', $version)` moved inside the eval, immediately
before the `1;`, exactly as scoped. A failed wipe now retries on the next server start.

The trade is stated in the comment rather than left implicit: a permanent failure retries once per
start and logs each time, which is a symptom you can act on, where a half-wiped store marked
complete is precisely the state [[dev-builds-clear-caches]] exists to prevent. The retry is
idempotent (`DELETE FROM kv`).

Guarded by `tools/t_buildwipe.pl` §2b (9 assertions, behavioural — the suite already runs the real
`_buildChanged` against stub prefs, so it only needed a `wipeDerived` that can die, modelling the
locked-DB-at-startup case the finding names). It asserts the half-wiped state explicitly (kv
attempted, genre half never reached, neither stamp advanced), then models the NEXT SERVER START by
carrying the pref state forward: the retry wipes both halves and only then records the build.
Anti-tested by moving the `set` back outside the eval → **3 red**.

**`ListenBrainzFreshReleases/Plugin.pm:721`**

```perl
    ...
    1;
} or $log->error("Dev-build wipe failed: $@");

$prefs->set('last_build', $version);      # <- outside the eval
```

`_buildChanged` returns early when `last_build` already equals the running version (`:666`).
Setting it after the eval regardless of outcome means a wipe that died half-way — say
`wipeDerived` threw on a locked DB during startup — leaves the store in a partly-wiped state,
records the build as handled, and never runs again for that version. The standing dev rule is
that every build clears every cache ([[dev-builds-clear-caches]]); this is the one path where a
build can silently not.

Note `last_genre_fact` is set *inside* the eval and is correct for the same reason — the pref
means "the version the store was last cleared FOR". `last_build` is the odd one out.

**Fix.** Move the `set` inside the eval, immediately before the `1;`. A failed wipe then retries
on the next start, which is the desired behaviour: the retry is idempotent (`DELETE FROM kv`),
and the alternative — a permanently half-wiped store — is the state the rule exists to prevent.

---

## Not reviewed

Per the repo convention the CHANGELOG is written at merge to main
([[changelog-only-on-main-merge]]), so the gap between the newest CHANGELOG entry and the built
version is a merge-gate item, not a dev-build blocker. It is now wider than it was at the
0.9.174 review (newest entry **0.9.169**, sixteen versions back) — the whole-week window is the
largest user-visible item sitting in the gap.
