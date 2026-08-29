# The genre ladder — rework, root causes and the standing plan

**Status as of 2026-08-13, end of session. Read this before touching anything
genre-related. It exists because this work has now been half-lost twice: once when
`docs/caching-rework.md` was rewritten on disk mid-session and took a set of
corrections with it, and once when a build shipped a design that had been agreed
and only half-implemented without that being flagged.**

| | state |
|---|---|
| shipped | **0.9.169** — installed on the live server, schema 3 |
| installed | **0.9.170** — steps 1–4 of §7, schema 4 |
| superseded, never installed | **0.9.171** (warm ORDERING fix, §11) and **0.9.172** (cache ages + Trending empty-cache) |
| superseded, never installed | **0.9.173** — schema 5; hosted ARTIST rung removed, detail page files its answer |
| **built, not yet installed** | **0.9.174** — the pre-release review's three ladder fixes (below) |
| nothing is committed or pushed | `dev` is still at the pre-0.9.166 commit |

> **THREE LADDER GAPS FIXED IN 0.9.174, all found by review of the 0.9.173 tree, and
> all the same failure mode: the ladder was correct and something upstream of it
> meant a rung was never consulted.** A bare view is a bug, not the design — so when
> a row is blank, ask whether the tier was *reached* before concluding it had no
> answer.
> 1. **`_withGenres` dropped every release with no `release_group_mbid`** before the
>    merge ran, so the two ARTIST-KEYED rungs (LB artist tags, Last.fm) were
>    unreachable for exactly the rows — Trending, no MBID — they exist to answer.
>    They now travel in a separate list on their own budget.
> 2. **The top-up gate counted rows present, not genres present.** The detail page's
>    `rgPut($rg, detail_genres => …)` creates a row with `n_genres` still at its -1
>    "never asked" default, so a feed whose albums had each been opened once looked
>    fully covered and never got a top-up — bare for ever, however many times opened.
> 3. **For You filled 150 (`GENRE_FETCH_MAX`) and then filtered the whole list**,
>    so everything past the cap bucketed as `GENRE_NONE` and was dropped by any
>    ticked family — while the picker counted over 600 and promised rows the view
>    then refused to show.

> **THE LADDER CHANGED IN 0.9.173 — this document predates it.** The hosted ARTIST
> rung is GONE (~2% on the residue across two measurements a week apart, for one
> HTTP request per artist), and a new tier sits between the album's own genres and
> the artist proxies: `release_group.detail_genres`, what the RELEASE DETAIL PAGE
> learns. The current ladder is
> **LB release-group tags → detail-page answer → LB artist tags → inline
> `release_tags` → Last.fm.**
> Two things this document says that are now WRONG: that the hosted artist tier is
> what makes the feed presentable (it never was — Last.fm carries it at ~63%), and
> §12's framing of the hosted question as parked (resolved 2026-08-21; the ARTIST
> route is out, the ALBUM route stays). See `feed-findings-2026-08-14.md` §8 step 4
> for the measurements and for the MB-mirror trap that nearly cost a live feature.

**Steps 1–4 of §7 are BUILT in 0.9.170.** What that build contains, and the
deviations from the approved shape it does NOT contain:
- `lb_genres` and `lastfm_genres` on `artist` — the two columns 0.9.169 skipped.
- **No migration back-fill for either, deliberately** — see `_migrate_4`'s comment.
  Both sources are keyed in a space `DB.pm` does not own (`release_group.agenres`
  records no artist at all; `lastfm_tags` keys are `lc("artist|album")` where the
  artist row uses `'n:' . Browse::_norm($name)`). Reconstructing the key there would
  need Browse loaded from DB, inverting the layering that made 0.9.166 unloadable,
  and approximating it with `lc` would file answers under keys nothing reads. They
  refill from the next warm at no extra request cost.
- `HAGEN_CONCURRENCY` 4 → **1**, matching MAI.
- 429 backoff on `_hostedGet`: 5s doubling to 30s, **shared** deadline, reset on
  success, and a 429 is a RETRY not a miss.
- The per-pass caps lifted to `HOSTED_WARM_ALL` / `LFM_WARM_ALL` — safe *only*
  because the two above landed with it.
- `_warmReport` logs `warm: <feed> PREPARED — N of M releases have a genre (P%)`,
  which is the number that says whether a view will open complete.

---

## 1. What the ladder actually is

Verified in code and against the live server on 2026-08-13. Do not re-derive, and
do not restate it from the coverage percentages in `caching-rework.md` §2.4.1
without checking which install you are talking about.

`Browse::_genresFor`, strongest first:

> **SUPERSEDED — the list below is the 0.9.170 ladder, kept for the reasoning that
> follows it. For the shipping ladder read `genre-ladder-current.md` §2.** Rung 3 is
> GONE (removed 0.9.173), and two rungs have been added since: `detail_genres` between
> 1 and 2, and the artist-row copy of the LB artist tags below 2.

1. **ListenBrainz release-group tags** — `release_group.genres`. The album's own.
2. **ListenBrainz artist tags** — `release_group.agenres`. The credited artist's.
3. ~~**Community API artist genres** — `artist.hosted_genres`~~ **REMOVED 0.9.173.**
   MusicBrainz-derived, so it failed wherever ListenBrainz failed; ~2% on the residue
   for one request per artist.
4. **The feed's own inline `release_tags`** — free, no request.
5. **Last.fm artist/album tags** — the `lastfm_tags` table.

Tiers 1 and 2 arrive **on one request** (`inc=release_group tag`), which also
carries the release date. That shared request is the source of the §3 defect.

**THERE IS NO MUSICBRAINZ TIER IN THE DEFAULT LADDER.** Simon, 2026-08-13: *"we
don't have a musicbrainz tier, the community API replaced all its bits completely
and some went to LB itself… it only falls back to MB if the API is not
contactable."* Confirmed: `_genreLookupMode` takes the mirror path **only** when
`API::hasMirror()` is true, and `["lbf","diag"]` on the live box reports
`MusicBrainz (public MusicBrainz)` — no mirror. So on that server, and on any
install without a local mirror, the MB rung never runs.

`artist.mb_genres` exists anyway (the mirror path is still live code for anyone
who runs one) but it is **not** part of the ladder above, and adding it to the
schema was a mistake of mine — see §4.

---

## 2. THE LOCKOUT (0.9.166) — root cause, fixed in 0.9.169

**Symptom:** *"Genres stopped populating again major regression"*, then *"I am
seeing very little genres populating with a release where before they had some."*

**Evidence, from the live store rather than from reasoning:** `["lbf","cachestats"]`
reported **0 of 1034 release groups holding a genre**, 1033 marked never-asked, and
`log.txt` showed no ListenBrainz genre traffic at all attempting to repair it.

**Cause — TWO correct-looking things that are wrong together:**

- `wipeGenres` cleared the genre columns and deliberately left `fetched_at` and
  `year` alone. That part is right: a genre-parser change must not re-inflict a
  date refetch across the whole feed.
- `getReleaseGroupMetadata` judged freshness from the **date** alone:
  `length($c->{year}) && _factFresh($c, RECMETA_AGE)`.

The request answers two questions; freshness was judged on one of them. So every
wiped row still looked freshly fetched and its genres could not be re-asked for
`RECMETA_AGE` — **ninety days**. The store was not slow to refill. It was locked.

**THE GENERAL RULE, and it is the transferable one:** *anything reached by a
multi-answer request must have freshness judged **per answer**, not per row.*
`artist.sort_name` rides the same shape and is now stamped separately for the same
reason.

**Fixed** by `_genresFresh` / `_answerFresh` reading a per-answer count and stamp,
and by `wipeGenres` zeroing an answer's stamp **whenever it clears that answer**.
Clearing a value and leaving its clock running is the bug; the two always move
together.

**Guarded by** `tools/t_genrefill.pl` §10 (anti-tested: 2 red against the pre-fix
source) and `tools/t_db.pl` §6f/§6g (anti-tested: 8 red against a wipe that leaves
the stamps running).

---

## 3. Three more defects of the same shape — a write touching what it does not own

All found by auditing after Simon's instruction: *"nothing should be overwriting
itself… study from what we learned on PFR."*

1. **One `fetched_at` served a row holding several independent answers.** The
   `artist` row is written by the sort warm and by two genre tiers, and `_factPut`
   stamped `fetched_at` on every write — so the sort warm refreshing a sort-name
   declared the genres beside it freshly fetched, and could hold an empty answer
   alive indefinitely without ever asking about genres.
2. **Two tiers shared `artist.genres`** behind a `genres_src` discriminator, and
   `_artistGenresFresh` returned 0 whenever the src did not match. With both tiers
   live: hosted sees `'mb'` → stale → refetch → writes `'hosted'`; the mirror sees
   `'hosted'` → stale → refetch → writes `'mb'`. **Every pass, for ever, each
   destroying the other's answer.** Dormant only where no mirror exists.
3. **Last.fm was not in the store at all** — `lbf:lfm:` in `Slim::Utils::Cache`,
   evictable and TTL-bound, for an answer that costs a deliberately paced
   one-request-per-second background pass.

All three fixed in schema 3: **one column per tier, one timestamp per answer**, so
the failures are inexpressible rather than avoided.

**Also fixed: `cachestats` was measuring a column with no writer.** `rg_genres`
counted `release_group.genres_src <> ''`, and *nothing in the plugin writes that
column* — the figure was 0 by construction. On `artist` only the hosted and mirror
tiers set it, so ListenBrainz's own artist tags were invisible there too. **An
instrument gets its own assertion, or it is decorative** — this one is why the
regression was misdiagnosed twice.

---

## 4. WHAT WAS APPROVED vs WHAT SHIPPED — the gap, and it is mine

Simon approved a specific shape. Its preview, verbatim:

```
artist
  genres      lb_genres    hosted_genres   lastfm_genres
  n_*         *_at         *_at            *_at
  sort_name   sort_at

release_group
  genres  agenres  genres_at

freshness(answer) = now - <answer>_at < (n > 0 ? FOUND_AGE : EMPTY_AGE)

- no shared fetched_at -> a sort write cannot re-age a genre
- no shared column     -> two tiers cannot overwrite each other
- ladder reads columns in order, writes only its own
```

**Four tier columns on `artist`.** 0.9.169 shipped two, and the deviations were
never flagged:

| approved | shipped in 0.9.169 |
|---|---|
| `lb_genres` on `artist` | **NOT BUILT** — LB artist tags still on `release_group.agenres` |
| `hosted_genres` | built |
| `lastfm_genres` on `artist` | built as a separate `lastfm_tags` table |
| — | `mb_genres` — a column added for a tier Simon had just said is not in the ladder |

The Last.fm relocation was deliberate (its answer is artist **+ album**, since the
rung asks `album.gettoptags` before falling back to the artist, so an artist column
would discard the album-specific answer) — but deliberate or not, an approved design
was changed silently and there was no way to see it from outside.

**`lb_genres` is the substantive omission**, and §5 is why.

---

## 5. THE ARTIST-KEYING DEFECT — why the feed cannot be prepared

**Both artist-level rungs file artist-level answers under release-specific keys, so
the same artist is asked about once per release instead of once.**

**ListenBrainz.** `_mergeReleaseGroupMetadata` writes `agenres => _genreTags($tag->{artist})`
onto the **release-group** row, and `_genresFor` reads `$meta->{lc rg_mbid}{agenres}`.
So an artist's tags learned from one release do nothing for that artist's other
releases; every release group must be fetched separately to learn the same answer
again, and any release whose group LB answered nothing for gets no artist tags even
when a sibling release already told us.

**Last.fm — the same bug, and here the code's own comment claims otherwise.**
`Browse.pm` says:

> • Deduped by ARTIST, because the tags fetched are artist-level anyway. **One call
>   covers every release by that artist in the feed.**

It does not. `_warmLastfm` dedupes by artist and then stores under the **first
release's** album:

```perl
next if $seenArtist{ lc $artist }++;
push @queue, [ $artist, _pickValue($rel, 'release_name', 'title', 'name') // '' ];
```

while `_lastfmGenres` reads back with **each release's own** album:

```perl
my $tags = ...->peekLastfmTags($artist, $album);
```

So for an artist with three releases in the feed, the warm spends one of its 40
calls and **only the release that happened to seed it can read the answer back**.
The other two stay bare and consume the allowance again next night. `getLastfmTags`
falls back to `artist.gettoptags`, so the stored value is usually artist-level tags
— filed under one album.

**This is why the caps bite.** The allowance is not small; it is being spent
re-buying answers the store already owns.

---

## 6. THE CAPS — their documented reason, and the MAI precedent that settles it

### 6.1 What the caps say

`LFM_WARM_MAX => 40`:

> • Deduped by ARTIST… One call covers every release by that artist in the feed.
> • Hard-capped at LFM_WARM_MAX per tick. It's per-artist (not bulk), so this is the
>   expensive tier; the cache holds 30 days, so a small daily allowance still
>   converges — it just doesn't try to do it all in one night.
> • ONE call in flight at a time, each behind an idle tick.

`HOSTED_WARM_MAX => 400`:

> Bounded rather than unlimited per tick: this is a shared community service and the
> plugin is one of several clients. HOSTED_WARM_MAX per pass, the surplus picked up
> by the next warm or by a background top-up.

Both rest on one stated premise — *one request per artist covers every release by
that artist, so a small allowance converges.* **§5 shows that premise is false in
the code.**

### 6.2 What MAI does against the SAME API — read from source, 2026-08-13

`michaelherger/MusicArtistInfo`, `Importer2.pm` + `Common.pm` (master). This is the
right precedent because it is the same community API doing the same job at library
scale, and Simon's point was explicitly *"we obviously don't want to cripple it."*

- **No cap.** `_scanArtistPhotos` opens a DB cursor over every artist in the library
  and runs `while ( _getArtistPhotoURL({...}) ) {}` to completion, with a progress
  bar. However many artists there are, it does all of them.
- **One request in flight.** In scanner mode `Common::call` is a **synchronous**
  `$ua->get($url)` — the next artist cannot start until this one returns. The
  round-trip time *is* the pacing. No concurrency at all.
- **Adaptive backoff when the server pushes back:**
  ```perl
  if ($response->code == 429) {
      $delay = $delay ? min($delay*2, MAX_DELAY) : 5;   # MAX_DELAY = 30
      sleep $delay;
  }
  else { $cache->set(...); $delay = 0; }
  ```
  Plus a `hasHitRateLimit` flag exposed to the rest of the plugin.
- **Coalesces duplicate in-flight URLs** (`%queryQueue`), caches responses 30 days,
  and identifies itself with `X-LMS-Plugin-ID` plus an `x-mai-cfg` header encoding
  `main::SCANNER ? 1 : 0`, so the server can tell a bulk scan from interactive use.

### 6.3 The comparison, and the conclusion

| | MAI | LBF before this work |
|---|---|---|
| total per run | uncapped, runs to completion | **400/night** (hosted), 40 (Last.fm) |
| in flight at once | **1** | **4** (`HAGEN_CONCURRENCY`) |
| on HTTP 429 | 5s → ×2 → 30s, reset on success | **nothing — no 429 handling on `_hostedGet`** |
| response cache | 30 days | 90 days found / 7 days empty |

**We are four times more aggressive per second than the precedent, blind to the
server telling us to stop, and simultaneously so quota-limited we can never finish
the job.** Both wrong, in opposite directions. The cap was doing the politeness work
that pacing and backoff should do, and doing it in the one way that also breaks the
feature.

**Two of my own claims, corrected here so they are not repeated:**

- I said the cap *"was limiting how much of the job got done per night, not how hard
  it was pushed in any second — only the second one is politeness."* **Wrong.** Daily
  request volume against a community-run server is politeness too.
- I then proposed `HOSTED_WARM_ALL => 4000` as the fix. That would have been 4,000
  requests a night, four at a time, with no 429 handling — the worst of the three
  options. **Withdrawn**, and it must not be reinstated on its own.

---

## 7. THE PLAN — agreed 2026-08-13, in this order

The order matters: each step reduces load before the next one raises throughput.

1. **Artist-key the two rungs.** `lb_genres` and `lastfm_genres` on the `artist`
   row, as approved in §4, with a migration back-filling from `release_group.agenres`
   and the existing `lastfm_tags`. The ladder reads them in order and each rung
   writes only its own column. This cuts the **number of requests needed** rather
   than rationing them.
2. **Concurrency 4 → 1** on the hosted tier, matching MAI. Round-trip time becomes
   the pace.
3. **429 backoff on `_hostedGet`** — MAI's shape (5s, doubling, capped, reset on
   success) with a **shared** deadline, exactly like the ListenBrainz machinery that
   already exists (`_lbWait` / `_lbNoteLimit` / `_lbIsRateLimited`). A sibling of
   existing code, not new invention.
4. **Then drop the per-pass cap** and let the warm run to completion. Safe **only**
   once 2 and 3 are in.

**Possible 5th, not agreed:** send something like MAI's scanner flag so the API can
distinguish our nightly warm from a user browsing. Ask the API's author what header
they want rather than inventing one.

---

## 8. Live measurements — 2026-08-13, against the real server

Keep these; they are what the next diagnosis should be compared against.

**Store, after 0.9.169 installed (schema 3):**

| | |
|---|---|
| `artist` rows | 1431 |
| `artist_hosted_have` / `_none` / `_never` | 11 / 390 / 1030 |
| `artist_mb_*` | 0 / 0 / 1431 (no mirror — the rung never runs) |
| `rg_genres_have` | **127** (was 0 before the fix) |
| `rg_agenres_have` | **476** (was 1) |
| `rg_genres_never` | 57 (was 1033) |
| `lastfm_tags` rows / `lastfm_have` | 6 / 3 |
| feed `all` | 3337 releases, 29/29 days covered |

**Rendered coverage, counted by walking the actual rows over JSON-RPC:**

| week | rows | with a genre |
|---|---|---|
| W/C 17 Aug | 30 | 97% |
| W/C 24 Aug | 9 | 67% |
| W/C 27 Jul | 30 | 57% |
| W/C 10 Aug | 30 | 53% |
| W/C 3 Aug | 30 | 47% |

**Why hosted fell 177 → 11:** the 0.9.169 dev wipe cleared the 177, and the single
400-artist refill pass was spent almost entirely on the long tail — 390 of 400 came
back "no genres". `_warmHosted` walks the feed in order taking the first N releases
no cheaper tier answered, and now that the LB rung works, everything still uncovered
*is* the untagged tail. Not a bug on its own; a consequence of the cap plus §5.

**How to reproduce any of this** — the plugin is testable entirely over HTTP, no
shell on the server:

```
curl -s -X POST http://plex:9000/jsonrpc.js -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["lbf","cachestats"]]}'
curl -s -X POST http://plex:9000/jsonrpc.js -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["lbf","diag"]]}'
curl -s http://plex:9000/log.txt
```
Row-level coverage needs a player MAC from `["players",0,20]`, then
`["listenbrainzfreshreleases","items",0,40,"menu:1","item_id:<n>"]`. **`log.txt` is a
rolling snapshot — absence of a line proves nothing.**

---

## 9. Settled — do not re-open

- **A view must open WITH genres already resolved.** Rendering bare and filling
  behind the user is the bug 0.9.165 fixed, not the design. The mechanism is the
  **whole-feed pre-fill**, not fetching on the render path — the render path stays
  peek-only (`0.9.130`), and a proposal to make it wait was raised and dropped.
- **Nothing stored is immutable.** Every answer is re-checked eventually, on **two
  ages**: populated = long, empty = short (`RG_GENRE_FOUND_AGE` 90d /
  `RG_GENRE_EMPTY_AGE` 14d, declared once in `DB.pm` so `cachestats` reports
  staleness from the same constants the fetchers obey). This is what makes
  re-checking a trickle rather than a stampede.
- **Every build clears every cache while in dev.** Gating that in 0.9.168 was the
  wrong fix — the harm was never the clearing, it was §2. A released build still
  clears genres only on a `GENRE_FACT_VERSION` change.
- **No opt-out pref for the hosted API** (decided 2026-08-12). Every hosted tier is
  unconditional; the fallback behind each one is what makes that safe.

## 10. Tests

| suite | covers |
|---|---|
| `tools/t_loads.pl` | **run before every build, and against the ZIP** — each module compiles in its own fresh interpreter; catches the cross-package bareword that made 0.9.166 unloadable |
| `tools/t_db.pl` | the store: per-answer stamps, per-tier columns, the wipe zeroing stamps, the migration back-fills, the two-age staleness figure |
| `tools/t_genrefill.pl` | the ladder: lookup mode, the `genre_mbid` gate, tier order, rate limiting, and §10 — the wipe × refetch interaction |

**Run the mutants. The count of red assertions is the only evidence a suite is doing
anything.** Both files take an env override (`LBF_DB=`, `LBF_API=`, `LBF_BROWSE=`)
pointing at a mutated copy. Mutants already used, with their scores:

| mutation | red |
|---|---|
| a write stamps every answer, not just what it wrote | 1 |
| the wipe leaves the clocks running (the §2 lockout) | 8 |
| the pre-schema-3 shared column + `genres_src` discriminator | 3 |
| empty answers held as long as populated ones | 1 |
| the pre-fix release-group hit test (date only) | 2 |
| LB artist tags filed once per RELEASE again (pre-schema-4) | 1 |
| a 429 treated as a miss instead of a retry | 2 |
| `HAGEN_CONCURRENCY` back to 4 | 1 |
| the backoff never resetting on success | 1 |

**A vacuous assertion caught by that run, and worth keeping as the example.** The
first cut of the artist-keying fixture gave only ONE of three release groups any
`agenres`, so the other two returned early and the per-artist dedupe was never
exercised — the assertion passed against a mutant that deleted it. The fixture now
gives all three tags, which is what an LB response actually looks like. Separately,
the 429 assertion first read `$limitBlock !~ /\$onMiss/` and failed on CORRECT code:
the branch legitimately *passes* `$onMiss` through to the retry closure. What must
not happen is CALLING it, so it now asserts on `$onMiss->(`.

Three vacuous assertions have been caught in this repo by mutation and none by
review. A green baseline means nothing on its own.

---

## 11. THE ORDERING — why it kept looking unfixed (0.9.171)

**Symptom, after the ladder itself was correct:** *"it has got them albeit very
slowly and still is rendering when it has none."*

**`_warmGenres()` ran LAST in `warmCache`**, chained behind:

1. `getCreatedForPlaylists` and the resolution of **every track** in every
   created-for playlist against the streaming services;
2. `_warmFollow` — the follow feed and its resolve;
3. `_warmTrending` — follower fan-out, per-user stats, and a streaming gate over
   50 albums.

…and the tick itself does not start until `WARM_DELAY` = 60s after startup. The
comment justifying that order called genres *"the least urgent"*. **That is exactly
backwards now:** genres are the one thing that must be ready before a view opens,
and everything queued ahead of them only matters once the user presses play.

**Measured on the live server, which is what settled it.** After the 0.9.170
install the ladder's own tail was still working through its queue while views were
being opened — `artist_lastfm_have` climbed **8 → 97 within a few minutes**, at the
one-request-per-second pace Last.fm is deliberately held to. Full rung state at that
point:

| rung | have | asked, none | never asked |
|---|---|---|---|
| ListenBrainz artist (`lb_genres`) | 376 | 466 | 840 |
| Community API (`hosted_genres`) | 11 | 401 | 1270 |
| Last.fm (`lastfm_genres`) | 97 → climbing | 56 | 1529 |

Two things that table says plainly:

- **Last.fm is the most productive remaining rung** — 97 hits from ~153 asked, a
  ~65% rate on precisely the releases the rungs above could not answer — **and it is
  the slowest and it ran last.**
- **The community API genuinely has nothing for 401 of them.** Those rows render
  bare correctly; that is the spec's *"unless there isn't one"*. Last.fm is what
  rescues most of that residue, which is why its position in the chain matters more
  than its hit rate suggests.

**Fix:** `_warmGenres()` is started at the TOP of `warmCache`, alongside the
streaming work rather than after it. That does **not** undo the original concern —
which was that the playlist/follow/trending stages must not hit the STREAMING APIs
all at once — because the genre ladder touches none of them (ListenBrainz bulk
metadata, then the community API, then Last.fm), and their order relative to each
other is unchanged. Every rung runs on idle ticks and yields, so it cannot hold the
event loop while the resolves run.

**Pinned by** `t_genrefill.pl` §12 — source-level, because the property is *where in
the chain the call sits* and the failure is silent. Anti-tested: putting it back at
the end fails it.

**A rendering caveat that is NOT the plugin:** Material replays a history page
without re-fetching it, so backing out of a view and returning shows the labels as
they were. The view has to be entered fresh to show what the store now holds. See
[[material-history-stale-labels]].

---

## 12. PARKED — hosted artist-genre coverage (2026-08-13)

**Status: deliberately parked by Simon, not resolved.** The suspicion is that the
hosted API's artist-genre dataset was only populated the afternoon of 2026-08-13
and its cache has not caught up. Re-test in a few days before changing any code.

### What was verified, so it is not re-derived

**The route and the call are CORRECT.** `getArtistGenresHosted` (API.pm ~2767)
calls the bare `artist/<name>` route and reads `$data->{genres}` off the base
artist object. That is right — the genres ride on the base object; there is no
`/genres` suffix route. Confirmed live: The Cure, Björk, Wet Leg, black midi and
Taylor Swift all return a populated `genres` key from `/music/artist/<name>`.

We are NOT in the no-404 trap, though it is real and worth restating: **every
unrecognised segment under `/artist/<name>/` answers HTTP 200 with the PICTURE
payload** — `/genres`, `/tags`, `/thisisnotaroute` all do. Code written against a
guessed route would parse valid JSON, find no `genres` key, and store "asked,
none" forever, for every artist, with no error and nothing in the log. The only
symptom would be a coverage number that looks low — i.e. indistinguishable from
what we are actually seeing. This is compounded by the API's own route doc
listing paths WITHOUT the `/music` prefix. See the header notes in API.pm.

### The measurements

Taken 2026-08-13 against the live store (`lbf cachestats`) and the live API:

| rung | have | none | hit rate on what it was asked |
| --- | --- | --- | --- |
| `artist_lb` | 376 | 467 | 45% |
| `artist_hosted` | 11 | 400 | **2.7%** |
| `artist_lastfm` | 242 | 158 | 60% |

Replaying the **exact 410 names the 21:46 warm sent** (pulled from the live log,
see the recipe below): 4 of the first 120 returned genres — 3.3%, matching the
store's own 2.7%. So the plugin records what the API returns.

Cross-checks on the same residue: **MusicBrainz artist genres 0 of 14**;
**MusicBrainz release-group genres 0 of 14**. Nobody has tagged these artists
anywhere. A random long-tail sample from the WHOLE feed answers 50%, but those
are artists ListenBrainz already covers, so they never reach the hosted rung —
the two sources fail together because they draw on the same MB-derived pool.

### The evidence the dataset is still filling

* **Taylor Swift changed within one day.** An earlier probe found no `genres` key;
  a probe hours later returned 17 genres.
* **Radiohead** returns no `genres` key from the hosted API while MusicBrainz has
  24 for the same artist. Sparseness that skips a top-tier artist while answering
  for his peers is a dataset mid-populate, not a sampling effect.

### Operational consequence to revisit when un-parking

`HAGEN_EMPTY_AGE` is 7 days (API.pm ~2666). Artists recorded "asked, none" while
the upstream dataset was still filling are not re-asked for a week. In DEV this is
harmless — `_buildChanged` wipes every genre stamp on each build, so every install
re-asks (§ the dev-build rule). In PRODUCTION a user waits up to 7 days per artist.
If the dataset is confirmed to be filling, consider a shorter empty age until it
settles. Do NOT shorten it as a reflex — the two-ages design exists so re-checks
trickle rather than stampede.

### Reproduce recipe — the whole loop, no ssh needed

```
# 1. the store's own per-rung counts
curl -s -X POST http://plex:9000/jsonrpc.js -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["lbf","cachestats"]]}'

# 2. the warm's own report + the names it actually sent
curl -s 'http://plex:9000/log.txt?lines=5000' -o big.txt
grep -o 'warm: hosted[^<]*' big.txt
grep -o 'Hosted API: https://api.lms-community.org/music/artist/[^ <]*' big.txt

# 3. replay those names by hand — the ONLY test that separates
#    "our bug" from "the rung is thin"
#    (percent-decode the segments, then GET each with the plugin-id header)
curl -s -H 'X-LMS-Plugin-ID: Plugins::ListenBrainzFreshReleases::Plugin' \
  https://api.lms-community.org/music/artist/<name>
```

**The decision rule:** if the API returns genres for names we recorded as empty,
it is our bug. If it returns no `genres` key for them too, the rung is thin and
Last.fm is carrying that population. On 2026-08-13 it was the latter.

---

## 13. SUPERSEDED IN PART — see `feed-findings-2026-08-14.md`

The 2026-08-13/14 investigation established that **ListenBrainz, MusicBrainz and
the hosted API are one MB-derived well, not three sources** — they fail together,
and only Last.fm is genuinely independent. Simon's decision: **drop genre filling
from the hosted API and MusicBrainz; keep LB + Last.fm**, and add LB's bulk
`/1/metadata/artist/?artist_mbids=&inc=tag` endpoint (which also supplies
`genre_mbid` as an authoritative genre gate, better than `genre-families.txt`).

The age policy in this document is also superseded: **every empty age → 1 day,
every found age → 30 days.** The 90d/14d/7d values here broke Simon's standing
"no cache may go stale for a long period" rule.

Everything else in this document — the store's tier design, per-answer stamps,
artist-keying, the peek-only render contract — still stands.
