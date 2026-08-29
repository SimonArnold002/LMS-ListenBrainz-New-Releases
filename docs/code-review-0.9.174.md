# Code review — 0.9.169–0.9.174 (the SQLite store, genre ladder, hosted API tier)

**Reviewed 2026-08-22.** Nothing here is fixed yet — this is the finding list, with the
mechanism and a reproduction for each so none of it has to be re-derived.

**Scope:** the **uncommitted working tree** on `dev` at 3b10989. The range diff vs
`origin/dev` is empty, so every line reviewed is unstaged:

    git -C . diff HEAD -- ListenBrainzFreshReleases/ tools/

4,333 insertions / 456 deletions across 23 tracked files, **plus** the untracked
`ListenBrainzFreshReleases/DB.pm` (2,211 lines, 100% new) and
`ListenBrainzFreshReleases/genre-families.txt` (2,224 lines, generated data).

The change is: genre labels + a genre picker; the LMS-community hosted metadata tier; the
plugin's own SQLite store replacing `Slim::Utils::Cache` for durable facts; the release feeds
moved from one-blob-per-day cache entries to per-release rows with day-coverage tracking;
per-tier genre columns with per-answer timestamps (schema 3); Last.fm genres moved into their
own table; the dev-build cache wipe.

**Method.** No LMS on this machine, so `perl -c` cannot load any module — every check below is
static or executed against a standalone harness. The called-vs-defined sweep, the TTL-ceiling
sweep, the string-token sweep and the matcher sync check were all run; where a finding rests on
runtime behaviour I could not observe, it says so.

---

## Verified clean

- **Called-vs-defined sweep — 0 missing subs.** Both fully-qualified
  (`Plugins::ListenBrainzFreshReleases::<Mod>::<sub>`) and bare `_private` calls, across all
  eight modules. This is the sweep that matters because `perl -c` passes on calls to
  non-existent subs, and there were renames in this diff.
- **The 30-day TTL ceiling.** Every TTL constant in the plugin is `<= 30 * 86400`
  (= 2,592,000, the boundary itself, not over it). `Slim::Utils::Cache` is now referenced from
  exactly one live site — [`DB.pm:1965`](../ListenBrainzFreshReleases/DB.pm#L1965), the legacy
  import — every other mention is a comment. The invariant `tools/t_ttlceiling.pl` asserts
  genuinely holds.
- **Migration re-runnability.** Each `ALTER` is individually guarded, so a step that has already
  run is a no-op rather than an abort that strands the back-fill behind it. `_migrate_1` creates
  the *final* schema, so a fresh DB converges through steps 2–5 as no-ops; a DB predating
  `PRAGMA user_version` re-enters at 0 and converges through the `ALTER`s. Both paths land on
  the same schema.
- **The artist-row key builders agree.** `_persistLbArtistTags`, `_warmLastfm` and
  `_mergeHostedGenres` all key through `API->artistKeyForName` with a consistent `a:` add/strip.
  This is precisely the hazard `_migrate_4`'s "NO BACK-FILL" comment identifies (two key spaces,
  `lc("artist|album")` vs `'n:' . _norm($name)`), and the live code is on the right side of it.
- **No load-order trap.** `DB.pm` pulls in only DBI, Storable, `Slim::Utils::Log` and
  `Slim::Utils::Prefs` — no plugin module, so there is no cycle back through `Browse::_norm`.
  `DB::store()` blesses an empty hashref and touches no handle, so the file-scope
  `my $cache = ...::DB::store()` in API/Browse/DSTM is safe at load time.
- **Material traps.** Every checkbox in `settings.html` is wrapped in `<label>`. Prose bold uses
  an explicit `font-weight`, never a bare `<b>`. The four new icons follow the `_MTL_icon_*`
  convention, so divider/header rows will draw them. Genre picker row labels cannot collide —
  no family in `genre-families.txt` is named `Other`, which is what `PLUGIN_LBF_GENRE_NONE`
  renders as.
- **Strings.** Every `PLUGIN_LBF_*` token used in any `.pm` or in `settings.html` is defined in
  `strings.txt`; zero undefined. The new `genre_lookup` pref is wired end to end: default at
  `Plugin.pm:88` → `Settings::prefs` list → the three radios at `settings.html:43-45` →
  `Browse.pm:7006`.
- **Build integrity.** `repo.xml` `<sha>` matches `shasum ListenBrainzFreshReleases.zip`
  (`39bc489…`), version is 0.9.174 in both `install.xml` and `repo.xml`, and the zip's member
  mtimes for `Browse.pm` (16:24) and `API.pm` (16:17) match the working tree. The zip is current
  with the source.

---

## Findings

Ranked most-severe first.

### 1. The genre wipe is unconditional — the release-build gate does not exist

> **FIXED 2026-08-22 (working tree, not yet built).** `_buildChanged` now wipes genres
> when `DEV_BUILD` is on **or** `last_genre_fact ne GENRE_FACT_VERSION`, and stamps the
> pref only when it actually cleared. `DEV_BUILD` is a new `Plugin.pm` constant — 1 on
> `dev`, 0 on `main` — because nothing else in the zip can tell a dev build from a
> release; it is now a merge-to-main reconciliation step beside `repo.xml`'s `<url>`
> (recorded in `CLAUDE.md` under *Current Version*). The `kv` wipe is untouched and
> still unconditional. Guarded by the new `tools/t_buildwipe.pl` (27 assertions, run
> against the verbatim sub body): a released build with an unchanged parser keeps its
> genres; a changed parser clears and re-stamps; a never-stamped store clears once and
> not again; a dev build clears regardless; a restart at the same version touches
> nothing. Anti-tested twice — the pre-fix code goes 5 red, and a gate written without
> the dev trigger goes 2 red.

**`ListenBrainzFreshReleases/Plugin.pm:501`**

```perl
my $gv = Plugins::ListenBrainzFreshReleases::DB->GENRE_FACT_VERSION;
my $g  = Plugins::ListenBrainzFreshReleases::DB::wipeGenres();
$prefs->set('last_genre_fact', $gv);
```

`$gv` is read, stored, and **never compared against anything**. `wipeGenres()` is called
unconditionally on every version change. The block comment immediately above says the opposite:

> `GENRE_FACT_VERSION` is still the PRODUCTION trigger — a released build must not throw a
> user's genres away for nothing

and the CHANGELOG entry for 0.9.169 promises the same to users ("A *released* build still only
clears genres when the code that parses them changes"). Neither is what ships.

`grep -rn last_genre_fact ListenBrainzFreshReleases/` returns exactly two hits — the pref
default at `Plugin.pm:124` and the write at `Plugin.pm:503`. Nothing reads it. The pref was
clearly created to *be* this gate and was never wired to one.

**Reproduction.** A user on released 0.9.174 upgrades to 0.9.175 with no change to the genre
parser. `_buildChanged` sees `$seen ne $version` and calls `wipeGenres()`, which clears all four
artist genre tiers (`lb_genres`, `hosted_genres`, `lastfm_genres`, `mb_genres`),
`release_group.genres` + `.agenres` + `.detail_genres`, **and** `DELETE FROM lastfm_tags` — each
with its stamp zeroed. Every row draws bare and refills over days, including the deliberately
paced one-request-per-second Last.fm pass.

**Fix.** One condition: only call `wipeGenres()` when `$prefs->get('last_genre_fact') ne $gv`,
*or* when the build is a dev build. The dev-every-build rule and the production gate are two
different triggers and the code currently implements only the first.

---

### 2. The shared matcher has drifted — `_norm`, `%FOLD`, `_albumMatches`

**`ListenBrainzFreshReleases/Browse.pm:6840` (`_norm`), `:6822` (`%FOLD`), `:6695`
(`_albumMatches`)**

`python3 tools/matcher_sync_check.py` **exits 1**. Three of the shared functions have drifted;
LBF is behind LMS-Discography on all three.

`_norm` — DSC folds apostrophes before the non-alnum collapse, LBF has neither line:

```perl
my $apos = qr/['\x{2019}\x{2018}\x{02bc}\x{00b4}\x{2032}`]/;
$s =~ s/(?<=\w)${apos}n${apos}(?=\w)/ n /g;
$s =~ s/$apos//g;
```

**Reproduction.** `"Don't Look Back"` normalises to `dont look back` in DSC and
`don t look back` in LBF. A Qobuz/Tidal candidate titled `"Dont Look Back"` matches in
Discography and misses in Fresh Releases. Same class of miss for every possessive and
contraction in the feed.

`%FOLD` — LBF is missing ~35 entries DSC carries (`æ→ae`, `ø→o`, `ß→ss`, `đ→d`, `ł→l`, `ħ→h`,
`œ→oe`, `þ→th`, and the whole IPA/hook block).

`_albumMatches` — LBF and PFR lack DSC's whitespace-collapse exact rule:

```perl
if (!$ok) {
    (my $as = $albumNorm) =~ s/\s+//g;
    (my $ts = $t)         =~ s/\s+//g;
    $ok = 1 if length($as) >= 6 && $ts eq $as;
}
```

LL already has this one (noted in the checker output as "fleet sync from DSC 0.11.1"), so LBF
and PFR are the two behind.

**Not introduced by this diff.** DSC advanced on 2026-07-23 (commit `2300507`) and the other
repos never caught up; nothing in this working tree touches these subs. But 0.9.174 would ship
the drift, and per the standing rule the alignment lands in **all** repos in one session, then
`matcher_sync_check.py` must exit 0, then each touched repo bumps its version and its match
caches. That is separate work from this build, not something to fold into it.

---

### 3. `_hostedNoteLimit` can shorten a backoff deadline already in force

> **FIXED 2026-08-22 (working tree, not yet built).** `_hostedNoteLimit` now mirrors the
> ListenBrainz guard — `$hostedBusyUntil = $until if $until > $hostedBusyUntil;` — so the
> shared deadline only ever moves out. The 429 call site also schedules its retry off
> `_hostedWait()` (the deadline in force) rather than off its own freshly-computed backoff,
> which could otherwise be shorter than a deadline another caller is holding and would
> spend a `waits` slot rediscovering it. Guarded by two new assertions in
> `tools/t_genrefill.pl` (cap the curve → succeed → 429 again: the deadline does not move
> back), both verified to fail against the pre-fix body.

**`ListenBrainzFreshReleases/API.pm:404`**

```perl
sub _hostedNoteLimit {
    $hostedDelay = $hostedDelay ? $hostedDelay * 2 : HOSTED_BACKOFF_START;
    $hostedDelay = HOSTED_BACKOFF_MAX if $hostedDelay > HOSTED_BACKOFF_MAX;
    $hostedBusyUntil = time() + $hostedDelay;      # <-- unconditional assign
```

The ListenBrainz twin guards the same assignment ([`API.pm:1720`](../ListenBrainzFreshReleases/API.pm#L1720)):

```perl
$_lbBusyUntil = $until if $until > $_lbBusyUntil;
```

The hosted side does not. Combined with `_hostedNoteOk` zeroing `$hostedDelay` on any success,
a later 429 can move the shared deadline **backwards**.

**Reproduction.** `GENRE_CONCURRENCY` is 4 ([`Browse.pm:7146`](../ListenBrainzFreshReleases/Browse.pm#L7146)),
so four `_hostedGet` calls share one deadline.

1. Caller A 429s at `T` with `$hostedDelay` already at `HOSTED_BACKOFF_MAX` (30) →
   `$hostedBusyUntil = T+30`.
2. Caller B's request succeeds at `T+1` → `_hostedNoteOk` sets `$hostedDelay = 0`, leaving
   `$hostedBusyUntil` at `T+30`.
3. Caller C 429s at `T+2` → `$hostedDelay` restarts at `HOSTED_BACKOFF_START` (5) →
   `$hostedBusyUntil = T+7`.

Every waiting caller's `_hostedWait()` now clears **23 seconds early** and they resume straight
into the live rate limit — the exact "back off together" property the block comment at
`API.pm:365` says the shared deadline exists to provide.

**Fix.** Mirror the LB guard: `$hostedBusyUntil = $until if $until > $hostedBusyUntil;`

---

### 4. `wipeDerived` deletes the legacy-import deadline, so the import window never ends

> **FIXED 2026-08-22 (working tree, not yet built).** The deadline moved out of `kv` to a
> **pref** — `IMPORT_DEADLINE_KEY` → `IMPORT_DEADLINE_PREF` (`legacy_import_until`), read
> and written through the plugin prefs namespace, which is the same place `_buildChanged`
> keeps its build marker and for the same stated reason. `wipeDerived` stays one
> unconditional `DELETE FROM kv` with no allowlist. Guarded in `tools/t_db.pl`: the first
> import stamps the deadline, a `wipeDerived()` between stamp and read leaves it untouched,
> and past it the old cache is not consulted — all three fail against the pre-fix body.

**`ListenBrainzFreshReleases/DB.pm:1834`** (and the consumer at
[`DB.pm:1954`](../ListenBrainzFreshReleases/DB.pm#L1954))

`IMPORT_DEADLINE_KEY` is `'lbf:legacy:until'` — a **kv row**. `wipeDerived` is one unconditional
`DELETE FROM kv`, so it takes the deadline with everything else. `_legacy` then re-mints it:

```perl
my $until = kvGet(IMPORT_DEADLINE_KEY);
unless (defined $until) {
    $until = time() + IMPORT_WINDOW;      # 180 days, from scratch
    kvSet(IMPORT_DEADLINE_KEY, $until);
}
```

This also breaks the module's own stated invariant, set out in its header:

> **IF IT IS IN `kv` IT IS DISPOSABLE. IF IT MUST SURVIVE, IT NEEDS A TABLE.**

The deadline is not disposable — it is the only thing bounding the legacy import.

**Reproduction.** A dev machine takes a build every few days. Each `_buildChanged` →
`wipeDerived()` → the deadline is gone → the next `_legacy()` call sets `time() + 180*86400`.
The deadline therefore never elapses, and the extra `Slim::Utils::Cache` read on every store
miss — the cost `IMPORT_WINDOW` exists to stop paying — runs indefinitely.

**Fix.** Move the deadline somewhere the wipe cannot reach: a pref, or a one-row table. A
carve-out inside `wipeDerived` would work but is exactly the allowlist the header argues against.

---

### 5. The CHANGELOG stops at 0.9.169; the built zip is 0.9.174

**`CHANGELOG.md:6`**

`install.xml` and `repo.xml` both say **0.9.174**. The newest CHANGELOG entry is **0.9.169**.
Five versions are undocumented, and they are not empty ones — the code dates them itself:

- `_migrate_5` is headed *"THE RELEASE DETAIL PAGE STOPS THROWING ITS ANSWER AWAY (0.9.173)"* —
  schema migration 5, a new `detail_genres` tier on `release_group`.
- `_mergeHostedGenres` notes *"It was THREE rungs until 0.9.173 dropped the hosted artist tier"*.

Separately, the 0.9.169 entry states *"A released build still only clears genres when the code
that parses them changes"* — which finding #1 shows is not what ships. Whichever way #1 is
resolved, this line needs to match it.

Per the repo convention the CHANGELOG is written at merge to main, so this is a merge-gate item
rather than something blocking the dev build — but the gap is five versions wide and the
detail is easier to recover now than later.

---

## Not raised as findings

- **`CHANGELOG.md` is modified on `dev`**, against the "dev builds update CLAUDE.md + docs only"
  convention. Flagged here rather than as a finding because it may be a deliberate change of
  approach.
- **~20 `store: migration N column already present` info lines on every fresh install**, because
  `_migrate_1` creates the final schema and steps 2–5 then re-`ALTER` it. Cosmetic, and the
  guarded-`ALTER` design that causes it is right.
- **`followAdd` does one `SELECT` per item** inside its transaction to detect novelty.
  `INSERT OR IGNORE` plus `$sth->rows` would give the same count in one statement, but the
  volumes here (a 75-event feed window) do not justify the change.
