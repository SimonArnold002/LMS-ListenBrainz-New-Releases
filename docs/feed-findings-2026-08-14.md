# Feed findings — 2026-08-14

Everything established in the 2026-08-13/14 investigation, so none of it has to be
re-derived. Companion to `genre-ladder-rework.md` (which owns the genre store's
design and the parked hosted-coverage question in its §12).

Every number here was **measured live** — against `http://plex:9000` (log.txt +
`lbf cachestats` over jsonrpc) or by querying the upstream APIs directly. Nothing
in this document is inferred from code reading alone. Where something is NOT
established, it says so.

> **Picking this up after a break? Read §9 (STATE AT PAUSE) first** — it has the
> current version and the ordered list of what to do next. Note that the large
> uncommitted tree there is DELIBERATE: it is Simon's review diff, and asking him
> to commit is explicitly unwanted.

---

## 1. THE GENRE SOURCES ARE ONE WELL, NOT THREE

**The finding that drives everything else.** ListenBrainz, MusicBrainz and the
hosted LMS-community API are not three independent genre sources. LB mirrors MB's
tags; the hosted API is MB-derived too. So they succeed together and **fail
together**, and stacking them as ladder rungs buys far less than the rung count
suggests.

Measured on the residue — the artists that actually reach the lower rungs, i.e.
the ones LB could not answer:

| source | coverage on the residue |
| --- | --- |
| ListenBrainz artist tags | 2 of 60 — and both junk (`special purpose artist`, `doujin`) |
| ListenBrainz release-group tags | 0 of 60 |
| MusicBrainz artist genres | 0 of 14 |
| MusicBrainz release-group genres | 0 of 14 |
| hosted API artist genres | 4 of 120 (and 11 of 411 in the live store) |
| **Last.fm** | **242 have / 158 none — 60%** |

**Last.fm is the only rung that is genuinely independent**, because it is
crowd-tagged rather than MB-derived. It is carrying this population single-handed.

**Judge any artist-genre source by its hit rate on the RESIDUE, never on the whole
feed.** A random sample of the whole feed answers ~50% from the hosted API — but
those artists are ones LB already covered, so they never reach that rung. That
distinction is what made the rung look broken when it was merely redundant.

### Speed: LB wins outright

* **LB is bulk** — one request returned tags for 60 release groups.
* **Hosted is one request per artist** — ~160ms each, so 400 artists ≈ 64s serial
  at `HAGEN_CONCURRENCY => 1`.

So there is no speed argument for keeping hosted either. It is slower *and*
thinner.

### The endpoint we were not using

```
GET /1/metadata/artist/?artist_mbids=<csv>&inc=tag
```

**Bulk, MBID-keyed, artist-level.** Today the plugin only gets artist tags as a
side-block of the *release-group* metadata call, which is why an artist with no
release-group MBID falls through entirely. This endpoint fixes that, and it is
what makes dropping the hosted rung safe: hosted's one unique property was being
name-keyed (able to answer for rows with no release-group MBID). Trending rows
carry `artist_mbid` (Browse.pm ~2321), so this endpoint covers them.

### `genre_mbid` is an authoritative genre flag

Each tag in that payload carries `genre_mbid` when — and only when — the tag is a
real MusicBrainz genre. Verified:

| artist | with `genre_mbid` | without |
| --- | --- | --- |
| Radiohead | chamber pop, ambient pop, art pop, idm, alternative rock, crossover prog … (18) | uk, oxford, british, britrock, english, `vyrzukhisuc-artiest` (9) |
| Taylor Swift | country pop, synth-pop, americana, dance-pop, teen pop, chamber pop … (17) | 2020s, millennial, `relic inn`, female vocals, re-recording (15) |

**This is better than `genre-families.txt`.** The vocabulary file can silently
drop a real genre it has not heard of; `genre_mbid` cannot. Use it as the gate.

### DECISION (Simon, 2026-08-13)

**Remove genre filling from the hosted API and from MusicBrainz. Keep ListenBrainz
and Last.fm.** The ladder becomes:

```
LB release-group tags  →  LB artist tags (bulk, by artist MBID)
                       →  inline release_tags  →  Last.fm
```

**One caveat recorded rather than buried:** the hosted *album* route measured 57%
on established albums (the Trending Albums population), which is a different
population from fresh releases and was NOT re-measured. Check it before removing
that specific call; everything else is confidently redundant.

---

## 2. NO CACHE MAY GO STALE FOR A LONG PERIOD

**Simon's rule, flagged more than once and re-broken by the genre work.** The file
already contained the correct pattern, and the genre rungs deviated from it:

```perl
SORT_FOUND_AGE => 30 * 86400;   # a sort-name does not move
SORT_NONE_AGE  =>  1 * 86400;   # "MB had none" — retry tomorrow, not in a month
```

Audit of every genre-related age as found:

| constant | found | empty |
| --- | --- | --- |
| `AGEN_*` (MB artist) | 90d | 7d |
| `HAGEN_*` (hosted artist) | 90d | 7d |
| `RG_GENRE_*` (release group) | 90d | **14d** |
| `LFM_*` | 30d | 7d |
| `RECMETA_AGE` | 90d | — |

**The empty ages are the harmful ones** — they pin "no answer" precisely while an
upstream dataset is filling, which is exactly the situation the hosted API was in
on 2026-08-13.

**Policy: every EMPTY age → 1 day. Every FOUND age → 30 days.** Matching `SORT_*`.

**Separately verified: nothing exceeds the 30-day `Slim::Utils::Cache` ceiling.**
`MB_FOUND_TTL`, `LFM_FOUND_TTL`, `FEED_FALLBACK_TTL`, `TRACK_FOUND_TTL` and
`TREND_ALBUMS_YEAR_TTL` all sit at exactly `30 * 86400` = 2,592,000s — at the
boundary, not over it. See `cache-ttl-30-day-boundary.md` and
[[lms-cache-30day-ttl-boundary]]: anything **over** 2,592,000 is read as an
absolute epoch and expires in 1970. The 90-day values are safe only because they
are age comparisons in our own SQLite store, never passed to `Slim::Utils::Cache`.
**Anything moved from a store age to a cache TTL must be re-checked against that
ceiling.**

---

## 3. BUG — a transient empty Trending result is cached for an hour

**This is why the Followers feeds needed a manual Refresh.** Live log:

```
trending cache hit (0 tracks)                  ×5
trending: no candidate tracks                  ×3
trending timing: mapped 0 recordings in 0ms    ×3
trending: 50 tracks (9 owned excluded) — resolve 19609ms
```

At `Browse.pm` ~1773 the "no candidate tracks" outcome passes `$cacheEmpty = 1`,
and ~1716 then pins `{ items => [], total => 0 }` for
`PLAYLIST_INCONCLUSIVE_TTL` — **one hour**.

**The outcome is not the one the comment intends to cache.** The comment reserves
the empty-cache for a genuine "nobody followed / all stale" state. But the same
tick later produced 50 tracks, so the emptiness was transient — the stats fan-out
comes back thin (it takes ~10s and is a per-follower fan-out). An intermittent
empty is being recorded as a definitive one.

Refresh works because it sets `force`, which bypasses the read.

**Fix (shipped):** `$sawListens = scalar keys %recFol` is computed from the fan-out
result, and the "no candidate tracks" branch caches only when listens were actually
seen. With no listens at all we learned nothing, so we record nothing — the same
rule the genre store already follows: **an empty result is not a fact.**

The two outcomes that ARE facts still cache, so this is not a blanket downgrade:
"not following anyone", and "no active followed users" (`_activeFollowers` fails
OPEN — a failed `getLatestListenTs` leaves the follower in the active list, so an
empty there is real).

### CORRECTION — the error path was already right

An earlier reading of this claimed the `getFollowing` call passed no `onError`, so
that its default (`sub { $onDone->([]) }`, API.pm ~2012) would launder a network
failure into "not following anyone" and cache it. **That was wrong.** The override
is there — at the END of the argument list (`Browse.pm` ~1923), after `onDone`,
which is why a scan of the call's opening lines misses it:

```perl
onError => sub { $empty->("following fetch failed: " . (shift // '')); },
```

It correctly omits the cache flag. A handler added higher up in the same call would
be **silently dead**, because these arguments become a hash and the last key wins —
which is exactly what happened when one was added before this was spotted.

Guarded now by `t_trending_empty.pl` §6, which asserts there is **exactly one**
onError and that it does not pass the flag.

### The slowness is separate and real

```
trending timing: stats fan-out in 9940ms
trending: 50 tracks (9 owned excluded) — resolve 19609ms
```

≈30s for a cold build. Not a bug on its own, but it is why a thin first answer is
so visible.

### RULED OUT: the 0.9.171 warm reorder

Simon's hypothesis was that moving `_warmGenres()` to the front of `warmCache`
starved the streaming-dependent feeds. **It did not.** From the 21:45 tick:

```
21:45:49  warm: genres — For You / all releases stored / 4 playlist(s)
21:46:04–21:46:31  warm: resolved …  (4 playlists, 49–50 tracks each)
21:46:31  warm: playlists done
```

Playlists completed 42s into the tick, and `_warmFollow`/`_warmTrending` are still
chained after them exactly as before the reorder. The genre ladder touches none of
the streaming APIs.

**Open, and worth checking:** `_warmFollow`/`_warmTrending` emitted **no log lines
at all** in that tick — not even `warm: follow feed empty` or `follow feed
unchanged — skip`. They therefore returned before logging, which means either the
`people_follow` pref is off or the `token` pref is empty (`_warmFollow` returns
early on an empty token, Browse.pm ~1405). Confirm the setting before treating
this as code.

---

## 4. Artwork — the has-art signal is a CLAIM, and it goes stale

Measured against Cover Art Archive:

```
2425 of 3061 releases claim artwork (caa_release_mbid present)
random sample of 30 → 27 fetched OK, 3 hard 404
```

**~10% of rows that pass the artwork-only filter have no artwork.**

`coverArtUrl` (API.pm ~3798) requires `caa_release_mbid` and treats its presence as
authoritative — the comment calls it "the authoritative *has cover art* signal".
It is authoritative about what ListenBrainz indexed, not about what CAA serves
now. The filter at `Browse.pm` ~2903 cannot know the difference without fetching.

Two further documented holes in the same function:

* **MuSpy items** carry only a release-GROUP MBID and fall to `CAA_RG_BASE_URL`,
  for which *no has-art signal exists at all* — those can 404 freely. (Not the
  cause of the current sighting: the live log shows `warm: muspy — 0 stored`.)
* **Trending rows built from unmapped listens** carry no CAA ids and rely on a
  separate artwork fallback.

**Fix direction:** remember a 404 (short TTL, per the §2 rule) and drop the row on
the next render. Do not add a pre-fetch to the render path — that is the 0.9.130
hazard.

---

## 5. Bare rows on a newly-added week

**Expected under the current design, not a new defect.** Increasing the days-to-show
pref admits releases the warm has never seen. The render path is peek-only
(deliberately — see `genre-ladder-rework.md` on the ~2,900 synchronous SELECTs
0.9.130 removed), so those rows come up bare while the detail page, which fetches
live, shows a genre.

It nonetheless violates the settled spec: **a view must open WITH genres resolved.**

Two contributing causes, both fixable:

1. **The detail page throws its answer away.** Both of its genre sources write only
   to `Slim::Utils::Cache`, never to the store — `getAlbumGenresHosted` under
   `lbf:hgenres:`, `getReleaseGroupGenres` under `lbf:rggenres:<mbid>`. The MB one
   is *already keyed by `release_group_mbid`*, which is the row's own key. So
   opening an album discovers a genre and discards it as far as the list is
   concerned.
2. **A days-change does not kick a fill** for the newly admitted releases.

**A rendering caveat that is NOT the plugin:** Material replays a history page
without re-fetching, so backing out and returning shows the labels as they were.
The view must be entered fresh. See [[material-history-stale-labels]].

---

## 6. PLANNED — genres on the Trending feeds

Not currently shown there (new releases only). Simon: *"might be useful to add for
sorting — test it out and see if it pans out."*

**Looks viable:** trending rows carry `artist_mbid` (Browse.pm ~2321) and the new
LB artist endpoint (§1) is bulk *by artist MBID*, so it needs no release-group
MBID. Prototype and measure coverage before committing.

---

## 7. NOT REPRODUCED — cross-feed contamination

Simon saw one feed's text on another's rows — Trending Albums material appearing
under New Releases, or at least the "listened to by N followers" line
(`PLUGIN_LBF_TREND_BREADTH`, set at `Browse.pm` ~2334).

**Ruled out so far — do not re-check these without new evidence:**

* `%FEED_MEMO` (API.pm ~893) — keyed per feed; the live log shows `all` and
  `user:CrystalGipsy` resolving to distinct keys.
* `%SECTION_MEMO` (Browse.pm ~2939) — keyed by prefix + a settings signature +
  source-ref identity. The identity check compares refs by address, which WOULD be
  unsound if the old refs could be freed and their addresses recycled — but the
  memo holds a copy of the ref list (`[ @$sources ]`), so they cannot be. Sound.
* `@_ADAPTERS_MEMO` (Browse.pm ~4941) — service adapters only, carries no row text.

**No mechanism identified. Do not guess one.** What is needed: which feed, and the
exact row text seen. With that, trace the line2 producer.

---

## 8. Work order

Smallest blast radius first; each step independently testable.

1. **Cache ages** (§2) — **DONE.** Constants only. Every empty age → 1 day, every
   found age → 30 days. Guarded by `t_ttlceiling.pl` §6, which sweeps both API.pm
   and DB.pm and pins the four that were over by name. Anti-tested: reverting
   `HAGEN_EMPTY_AGE`, `RECMETA_AGE` and `RG_GENRE_EMPTY_AGE` scores 6 red.
2. **Trending empty-cache** (§3) — **DONE.** `$sawListens` gates the cache write;
   definitive empties still cache. Guarded by `t_trending_empty.pl` §6. Anti-tested
   with six mutants (hard-coded flag, `$sawListens` forced true, onError removed,
   onError given the flag, a second onError added, `$cacheEmpty` gate removed) —
   all score red.
3. **Detail→store write** (§5.1) — **FOLDED INTO 4, deliberately.** It cannot be
   done cleanly on its own: `release_group` carries only `genres` and `agenres`
   (both LB, sharing one `genres_at` because one request answers both). Filing the
   detail page's MusicBrainz/hosted answer would mean either writing it into
   `genres` — a cross-tier overwrite, the exact defect schema 3 exists to prevent —
   or a schema 5 column that step 4 makes dead on arrival by removing those calls.
4. **Sources swap** (§1) — **DONE 0.9.173, but NOT as specified. Read this before
   believing §1's plan.** Re-measuring on resumption hollowed out three of its four
   parts:

   | §8 step 4 as written | measured 2026-08-21 |
   | --- | --- |
   | LB bulk artist endpoint **in** | **0 of 300 releases rescued.** The release-group call's `tag.artist` block already carries the identical artist tags, so for anything with an rg MBID it is pure redundancy. On the residue it answers 1 of 38 — the same ~2% hosted gives. **NOT BUILT**; its real value is §6 (Trending rows carry `artist_mbid` and often no rg MBID). |
   | hosted artist rung **out** | **Done.** 1 of 67 on the residue, for ~64s of serial HTTP per warm at `HAGEN_CONCURRENCY => 1`. |
   | MB artist rung **out** | **NOT DONE — and the reasoning for it was WRONG.** See below. |
   | `genre_mbid` as the gate | **Already shipped.** `_genreTags` has gated on it all along, and it cannot replace `genre-families.txt`: that file gates the **Last.fm** rung, and Last.fm tags carry no `genre_mbid`. Not substitutes. |

   **THE MB ARTIST RUNG IS NOT DEAD CODE, and the store said it was.** `cachestats`
   reported `artist_mb_have` 0 / `none` 0 / `never` 2191, which reads as "never
   called, safe to delete". It is not: `mb_base_url` on the live box is
   `https://musicbrainz.org/ws/2/`, so `hasMirror()` is false, `_genreLookupMode()`
   returns `'lb'`, and the mirror path never runs **on that box**. For a user WITH a
   local mirror `_genreLookupMode` returns `'mirror'` and `_withGenresMirror` →
   `getArtistGenres` is their ENTIRE genre lookup — `_withGenresLB` never runs at
   all. Deleting it would have taken genres away from those users completely, and
   CLAUDE.md's own advice for the sluggishness is to clear that pref, which flips
   this box straight into that path.

   **The rule this belongs to: a zero counter on ONE box is evidence about that
   box's prefs, not about whether code is reachable.** Check what gates the path
   before reading a zero as dead.

   Also done in 0.9.173, and NOT in the original plan:
   * **`getAlbumGenresHosted` is KEPT** — ~~and was REMOVED AGAIN in 0.9.185; the
     "rich on established albums" argument below did not survive contact with the
     fact that the Trending Albums build already stores genres itself. See
     `genre-ladder-current.md` §6.~~ §1's caveat resolved the opposite way to
     expectation. 0 of 49 on fresh-release residue, but rich on established albums
     (OK Computer 13, Rumours 8, Kid A 15), and `_releaseDetail` is SHARED between
     Trending Albums (`Browse.pm` ~2370) and New Releases (~4389). It earns its
     place on **latency, not coverage**: MusicBrainz answers the same albums (7 of
     8 identical counts), but for a mirror-less user that is one throttled request
     per page open.
   * **It was not lowercasing.** Harmless while the answer only reached the detail
     page's own line; not harmless now it is stored, because `_genreFamily` keys on
     the lowercase vocabulary and a Title-Cased genre silently stops rolling up.
   * **§5.1 is closed** — schema 5 adds `release_group.detail_genres` with its own
     count and stamp, read as a tier below the album's own genres and above the
     artist proxies. §8 predicted this column would be "dead on arrival"; it is not,
     because both calls that feed it were kept.
   * **`cachestats` no longer reports `artist_hosted_*`** — nothing writes it, and a
     populated-looking tier that cannot be contributing is the exact trap that block
     was rewritten to remove.
   * **`bench_walk.pl` had been silently half-dead** — `_sortWithin` calls
     `_firstArtistMbids`, which was never in its sub list, so the bench died there
     and skipped everything after it, INCLUDING the `_bucketFor` line that caught
     the per-release SELECT in 0.9.165. A harness that dies half way through reports
     a shorter list, not a failure. Fixed; `_bucketFor` runs at 3.22ms over 767
     releases with no store read.

   Verified: 12 files green (t_db 249, t_genrefill 139), **12 mutants all red**. One
   of them (migration 5 skipped) scored FULLY GREEN at first — a fresh install gets
   the column from `CREATE TABLE`, so nothing tested the UPGRADE path; t_db now
   builds a real schema-4 store and runs the real dispatcher against it.

5. **Trending genres** (§6) and **artwork 404 memory** (§4) — after 4 is proven.
   §6 is now the natural home for the bulk LB artist endpoint measured above: it is
   bulk (100 artists in 6.5s, no 502), MBID-keyed, and Trending rows carry
   `artist_mbid`, which is precisely the population the endpoint is good for.

**Standing constraints:** no commit, push, tag or build without approval for that
action ([[no-git-commit-without-ok]]); every dev build must invalidate all plugin
caches ([[dev-builds-clear-caches]]); bump the version AND recompute the repo.xml
sha on every rebuild ([[always-redo-sha-on-zip-rebuild]]).

---

## 9. STATE AT PAUSE — 2026-08-14 (Simon away ~1 week, resumes ~2026-08-21)

### Where the code is

| | |
| --- | --- |
| branch | `dev` |
| last commit | `3b10989` — **0.9.161** |
| working tree | **0.9.171** (`install.xml` + `repo.xml`) |
| built zip | `ListenBrainzFreshReleases.zip` at 0.9.171 — **STALE**, built before this session's edits |
| installed on plex | 0.9.171 (the stale zip) — so steps 1 and 2 are NOT on the server yet |

### The uncommitted tree is DELIBERATE — do not raise it

`dev` is ten releases behind the working tree and 17 files are untracked
(`DB.pm`, `genre-families.txt`, five `tools/t_*.pl`, all four `docs/`, four
Material icons, `make_genre_families.py`, `genre_freq.json`).

**This is not a problem to flag.** Simon keeps it uncommitted on purpose — the
working-tree diff IS what he reviews against, and committing collapses it. Stated
directly on 2026-08-21: *"Stop telling me to commit — I will when code is in
suitable state as will lose all changes for code review purposes."*

Earlier revisions of this section called it "the most important line in this
document" and told the next session to ask before anything else. **That was wrong
and it has been acted on twice.** Read a long-lived uncommitted tree here as
"review pending", not "work at risk".

The standing rule that still applies is the other one: never commit, push, tag or
ship a build without approval **for that action** ([[no-git-commit-without-ok]]).
That removes the prompting, not the permission requirement.

### What changed THIS SESSION (2026-08-13/14), and why

All of it is steps 1 and 2 of §8. Nothing was built and nothing was committed.

**`ListenBrainzFreshReleases/API.pm`** — the age policy (§2):
* `LFM_EMPTY_TTL` 7d → **1d**
* `AGEN_FOUND_AGE` 90d → **30d**, `AGEN_EMPTY_AGE` 7d → **1d**
* `HAGEN_FOUND_AGE` 90d → **30d**, `HAGEN_EMPTY_AGE` 7d → **1d**
* `RECMETA_AGE` 90d → **30d**
* Rewrote the comment block above `RECMETA_AGE`. It previously ended "and 90 days
  is simply 90 days again", which would have become a lie the moment the value
  changed. A comment that contradicts its own constant is worse than no comment.

**`ListenBrainzFreshReleases/DB.pm`** — same policy:
* `RG_GENRE_FOUND_AGE` 90d → **30d**, `RG_GENRE_EMPTY_AGE` 14d → **1d**

**`ListenBrainzFreshReleases/Browse.pm`** — the Trending fix (§3):
* Added `my $sawListens = scalar keys %recFol;` after the `@mbids` ranking, with a
  comment recording the live evidence.
* The `unless (@$cands)` branch now passes `$sawListens ? 1 : 0` instead of a
  hard-coded `1`, and logs a distinct message when it declines to cache.
* Added a comment at the `getFollowing` call warning that its `onError` lives at
  the END of the argument list and that a second one added higher up is silently
  dead (these arguments become a hash; last key wins).
* **REMOVED a change made earlier in the same session.** An `onError` had been
  added at the top of that call on the belief that the error path was unhandled.
  It was not — see the CORRECTION in §3. The added handler could never fire.

**`tools/t_ttlceiling.pl`** — new §6, the age-policy guard:
* Sweeps `*_EMPTY_*` / `*_NONE_*` (cap 1 day) and `*_FOUND_*` + `RECMETA_AGE`
  (cap 30 days) across API.pm, Browse.pm, DSTM.pm, Diag.pm **and DB.pm**.
* DB.pm is added via a local `%AGESRC` rather than widening the file's `%SRC` —
  sections 2 and 4 sweep for durations handed to `Slim::Utils::Cache`, and the
  store hands over none, so widening `%SRC` would change what they assert.
  **DB.pm being absent from `%SRC` is why `RG_GENRE_*` went unchecked at first.**
* Asserts the sweep found ≥ 8 constants, so a rename cannot silently empty it, and
  pins the four that were over the cap by name.

**`tools/t_trending_empty.pl`** — new §6, the transient-empty guard:
* Asserts `$sawListens` is computed from `%recFol`; that the "no candidate tracks"
  branch is gated on it; that the two definitive empties still cache; that
  `getFollowing` has **exactly one** `onError` and it omits the cache flag; and
  that `$empty` still writes only when `$cacheEmpty` is set.
* Two defects in this test were found by anti-testing and fixed:
  **(a)** a lazy `[^;]*?` regex backtracked catastrophically over the 14KB function
  body and HUNG the suite on one mutant — a test that hangs reports nothing, which
  is worse than one that fails. Both matches are now line-bounded (`[^{}\n]*`).
  **(b)** the first extraction used a hand-rolled regex instead of the file's own
  brace-matching `grab()` helper and captured the wrong span, so an assertion was
  matching a *different* `onError` further down and passed on a mutant.

**`CLAUDE.md`** — new "FEEDS & GENRES" section pointing at this doc first.
**`docs/genre-ladder-rework.md`** — new §12 (parked hosted coverage, with the
reproduce recipe) and §13 (what this doc supersedes).

### Verification status

* Full suite green: 12 files. `t_ttlceiling` 37 pass, `t_trending_empty` 27 pass.
* Age policy anti-tested: reverting `HAGEN_EMPTY_AGE`→7d, `RECMETA_AGE`→90d,
  `RG_GENRE_EMPTY_AGE`→14d scores **6 red**.
* Trending anti-tested with six mutants — hard-coded flag, `$sawListens` forced
  true, `onError` removed, `onError` given the flag, a second `onError` added,
  `$cacheEmpty` gate removed — **all red**.
* `t_trending_empty.pl` takes ~31s. ~18s of that predates this session; the rest
  was investigated and is not in the new section (slurp 10ms, grab 3ms, every
  regex <1ms). Not chased further.

### FIRST THINGS ON RESUMPTION, in order

1. **Re-test the parked hosted-genre coverage** (`genre-ladder-rework.md` §12).
   **DONE 2026-08-21 — unchanged, so step 4 proceeds.** Replaying the exact 67
   names from the live log answered **1** (Dead Horse); the store agrees
   (`artist_hosted_have` 15 / `none` 532) and so do the last two warms
   (`asked 138, 5 answered`, `asked 161, 6 answered`). Last.fm is now 334/194
   = 63%, LB 534/610 = 47%.
   **The album caveat resolved the OTHER way — keep that call.** The hosted
   *album* route measured **0 of 49** on fresh-release residue but is rich on
   established albums (OK Computer 13, Rumours 8, Kid A 15, 1989 7), and
   `_releaseDetail` is SHARED — `Browse.pm` ~2370 is the Trending Albums row's
   detail link, ~4389 the New Releases one. So `getAlbumGenresHosted` earns its
   keep on Trending Albums and contributes nothing on New Releases.
   **SUPERSEDED 0.9.185:** it does not earn its keep there either — that population's
   genres are already in the store when the row is drawn (the trending build's
   rg-metadata pass carries `inc=release_group tag`), so the call only ever ran where
   every MB-derived source was already empty. Removed, with the MB tier behind it.
   **Also found:** `artist_mb_have` 0 / `none` 0 / `never` 2191 — the MusicBrainz
   artist rung has never been asked for a single artist, so removing it is a
   no-op on behaviour, not a coverage loss.
2. **Build and install** so steps 1 and 2 reach the server, then confirm the
   Followers feeds populate without a manual Refresh.
   **BUILT 2026-08-21 as 0.9.172** — sha `85a1df698382e6c528ac4f23aba871b5899936b1`,
   suite green (12 files; `t_loads` run against the EXTRACTED ZIP, 16/16). The
   version bump alone triggers `_buildChanged`, so caches wipe on install.
   Awaiting Simon's manual install + the Followers check.
3. Then **step 4** (§8) — the sources swap, scoped by 1 above: drop the hosted
   ARTIST rung and the MB artist rung, KEEP the hosted ALBUM call, bring in LB's
   bulk `/1/metadata/artist/?artist_mbids=&inc=tag` with `genre_mbid` as the gate.
   Measure coverage before/after.

### STILL OPEN — needs Simon, not code

* **`people_follow` / `token` prefs** — `_warmFollow`/`_warmTrending` logged nothing
  at all in the 21:45 tick, meaning they returned early. Confirm those settings
  before treating it as a bug (§3).
* **Cross-feed contamination** (§7) — not reproduced, no mechanism found, three memo
  layers ruled out. Needs a concrete sighting: which feed, and the exact row text.
* **The hosted *album* route** — measured 57% on established albums (Trending
  Albums), never re-measured. Check before removing that specific call in step 4.
