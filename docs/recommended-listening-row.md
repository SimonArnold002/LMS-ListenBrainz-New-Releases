# "Recommended Listening" — Material home row

**Status:** SCOPED, NOT STARTED. Investigated 2026-07-31. No code written.

**Spec (Simon):** a **Material home row only** — no browse-menu entry — offering recommended
listening albums derived from the user's listening history. Algorithm picks from **artists already
in the library whose releases the user does NOT own**, choosing the **most regarded** ones, plus
albums from **similar/related artists** not in the library. **Max 30** (fewer is fine), **refreshed
monthly**, **no repeated artists within any one month**.

**ListenBrainz popularity is explicitly out of scope** (Simon's call, and independently justified —
see §3.4). The regard signal is deliberately **wider** than one source.

---

## 1. Where it lives — and the one hard constraint

A 4th `HomeExtraBase` subclass in `HomeExtras.pm` (alongside `LBFForYou` / `LBFPlaylists` /
`LBFAllReleases`), new tag e.g. `LBFRecommended` → `Browse::homeRecommended`. Not registered in
`topLevel`, so it never appears in the browse menu.

> **THE 0.6.11 RULE — non-negotiable.** Anything reachable by a play/drill `item_id` must be
> **quantity-stable**: the home shelf is invoked with the carousel quantity (10) *and* the click-in
> quantity (25000), and a structure that differs between them breaks playback silently. So this feed
> returns a **flat, capped list of ≤30 album rows for both** — no dividers, no per-section sub-feeds,
> no quantity branching. The 30-album cap fits this perfectly; do not "improve" it into a grouped view.

Also required: `cachetime => 0` on the returned hash (0.9.25), so Material re-requests rather than
serving a stale per-player copy — which matters more here than anywhere else given a monthly cadence.

---

## 2. Candidate pools

**Pool A — gaps in owned artists.** Library artists → each artist's MB discography → release groups
the user does **not** own.

**Pool B — similar/related artists.** Similar artists to the user's library/most-listened artists,
**excluding any artist already in the library**, → their release groups (all of which are
un-owned by definition).

Pool B reuses `API::getSimilarArtists` (LB labs `similar-artists` dataset) which already exists for
the DSTM radio, plus `getArtistMbidByName` for name→MBID where needed. Note DSTM's hard-won lesson:
bound the MB name→MBID resolution (`MBID_RESOLVE_CONCURRENCY`=4) or the anonymous ~1 req/s limit
throttles the burst.

Suggested mix: roughly **2/3 Pool A, 1/3 Pool B** — Pool A is "you clearly like this artist, you're
missing their best record", which is the higher-confidence recommendation; Pool B is the discovery
half. Tunable, not load-bearing.

---

## 3. The "most regarded" signal — multi-source

### 3.1 Type filter first — this does most of the work

Verified on Radiohead's MB discography: **385 release groups, 100 returned, of which only 10 are
`primary-type=Album` with no secondary types.** The other 90 are compilations, live recordings,
bootleg-ish odds and ends.

Filtering to primary Album + **no** secondary type is the single highest-value step, and LBF already
has the logic (`_secondaryType`, `_typeMatches`, `_allowedTypes`). Do it **before** ranking, not after.

### 3.2 MB rating, weighted by vote count — free, no extra request

The whole discography **plus ratings** comes back in **one** call per artist:

```
GET /ws/2/release-group?artist=<artist_mbid>&type=album&inc=ratings&limit=100&fmt=json
→ each release-group carries  "rating": { "value": 4.55, "votes-count": 87 }
```

**A raw rating sort is actively wrong.** Measured on the unfiltered Radiohead set, the top-rated
entries are all `5.00` from a **single vote** — *5 Album Set*, *B-Sides*, *Rarities*, *Uncut*, a 2013
bootleg — every one of them ranked **above** *OK Computer* (4.55 from 87 votes). Two independent
guards, use both:

1. The §3.1 type filter (removes nearly all of that noise by itself).
2. A **Bayesian vote weight**: `score = (v/(v+m))·R + (m/(v+m))·C`, with `C` ≈ the global mean (3.5)
   and `m` ≈ 10 votes. Verified output on the filtered set — the canonical order falls straight out:

```
4.44  [raw 4.55  87v]  OK Computer
4.38  [raw 4.50  71v]  Kid A
4.28  [raw 4.40  63v]  In Rainbows
4.08  [raw 4.25  33v]  A Moon Shaped Pool
4.06  [raw 4.15  66v]  The Bends
3.80  [raw 3.85  58v]  Amnesiac
```

Coverage caveat: ratings are **canon-heavy**. *OK Computer* has 87 votes; Mildlife's *Chorus* has
`votes-count: 0`. So MB ratings alone will bias recommendations toward well-known records — which is
arguably correct for "most regarded", but means Pool B discovery needs the extra signals below or it
will surface nothing for smaller artists.

### 3.3 A SHIPPED ACCLAIM LIST — the best answer, and it costs nothing

There is **no official "1001 Greatest Albums" API**, but that turns out to be an advantage: the lists
are static, so they can be **shipped as a data file** like `genre-families.txt` — zero requests, zero
third-party dependency, instant synchronous lookup, works offline.

Two candidates, both verified:

| Dataset | Size | Columns |
|---|---|---|
| [`arcctgx/1001-albums`](https://github.com/arcctgx/1001-albums) `2008-edition.tsv` | 1001 rows, **36K** | `year`, `album`, `artist` |
| [`purarue/albums`](https://github.com/purarue/albums) `csv_data/all.csv` | **3,476 rows**, 604K | `album`, `artist`, `year`, **`reasons`**, `discogs_master_url`, `discogs_artist_id`, `genres`, `styles` |

**Use the second one.** It aggregates **58 acclaim lists** — 1001 Albums, Rolling Stone's 500, NME's
500, Grammy Album of the Year, Brit Awards, AMA, Fantano's Top 200, /mu/ Essentials… — and the
`reasons` column is a **ready-made regard score: count the lists an album appears on.**

```
"In The Wee Small Hours","Frank Sinatra","1955",
  "1001 Albums You Must Hear Before You Die; Rolling Stone's 500 Greatest Albums of All Time;
   NME's 500 Greatest Albums of All Time; /mu/ Essentials",
  "https://www.discogs.com/master/96471","52833","Jazz; Pop","Ballad; Swing; Vocal"
```

Four lists → strongly regarded. One list → merely acclaimed. That is **critical consensus across 58
sources for one shipped file and no network calls**, which is exactly what "most regarded" should
mean and what no single API here provides.

- **No MBIDs** — match via the fleet `_albumMatches`, same as everywhere else in this plugin.
- Trim to the columns we need (album / artist / year / list-count) and it's well under 100K.
- Bonus: the Discogs master URL gives a free mapping into §3.5, and `genres`/`styles` are a free
  side-input for `genre-sources-investigation.md`.
- **Limitation, and it's the important one:** it is canon-heavy by construction — 3,476 albums,
  almost all pre-2020 and Anglo-American. It will fire for Pool A (established artists the user
  owns) and almost never for Pool B (similar-artist discovery). It needs §3.4 beside it.
- Ship a pinned copy with a regeneration script in `tools/` (the `genre-families.txt` pattern);
  don't fetch it at runtime.

### 3.4 Last.fm `artist.gettopalbums` — the long-tail spine

**One call per artist**, returns that artist's albums ranked by listening, with mbids. This is a
direct replacement for LB's dead `top-release-groups-for-artist`, and — crucially — **it works where
both MB ratings and the acclaim list are empty**:

```
Radiohead        263,446,607  OK Computer  /  254,938,849  In Rainbows  /  181,866,554  The Bends
Mildlife             645,830  Phase        /      393,529  Automatic    /      175,811  Chorus
The Diasonics         74,119  Origin of Forms  /   14,530  Ornithology  /        8,835  Gradients
Lalalar              314,228  Bi Cinnete Bakar /   82,124  İsyanlar
```

Real, differentiated signal for exactly the small artists where MB gave `votes-count: 0`. That makes
it the **Pool B enabler**.

**Two gotchas, both verified:**
1. **The response is NOT sorted by playcount.** Radiohead came back OK Computer (263M) → Pablo Honey
   (95M) → In Rainbows (254M). It's Last.fm's own internal "top" rank. **Sort by `playcount`
   yourself** — trusting the array order would put *Pablo Honey* second.
2. It measures **popularity, not acclaim**. Pair it with §3.3, don't substitute it.

Needs an API key — which is already the plan (`token-free-refactor.md` §4: ship our own, MAI
precedent). *Verified above using MAI's public key for read-only checks only; we would ship our own.*

Also available on the same key: `album.getinfo` → `listeners` / `playcount` per album, if a
per-album number is ever wanted over a per-artist ranking.

### 3.5 Discogs — usable unauthenticated, and the search result already has the signal

Verified 2026-07-31, **no auth, no key**:

```
GET https://api.discogs.com/database/search?q=Radiohead+OK+Computer&type=master
→ results[0] = { id: 21491, title: "Radiohead - OK Computer",
                 community: { want: 213681, have: 262678 }, genre: [...], style: [...] }
```

- **`community.have` / `.want` arrive in the SEARCH response** — no second call needed. The
  **want/have ratio** is the classic collector-desirability metric and a genuinely independent
  signal from playcount or critics.
- The *release* endpoint additionally carries `community.rating {count: 1262, average: 4.71}`; the
  *master* endpoint carries neither (only `num_for_sale`) — so use search, or search → release.
- **Rate limit is the constraint: `x-discogs-ratelimit: 25` per minute unauthenticated** (60
  authenticated). At ~2.4s per album this is **shortlist-only** — never point it at a candidate pool.
- Note MAI ships Discogs credentials but has them **disabled** (`CAN_DISCOGS => 0` in `Common.pm`).
  Worth understanding why before taking a dependency — likely rate limits or terms.

### 3.6 The remaining signals

| Signal | Access | Verdict |
|---|---|---|
| **Pitchfork BNM** | **Our own `LMS-Pitchfork-Reviews` plugin** already scrapes Best New Music | Cheap win, and the one source here that covers **recent** releases the acclaim file never will. Cross-plugin read, no new API or credential. Use as a **boost**. |
| **CritiqueBrainz** | `GET https://critiquebrainz.org/ws/1/review/?entity_id=<rg_mbid>&entity_type=release_group` — public, keyless, verified 200; `average_rating: {count, rating}` | Real ratings, **very sparse** (*OK Computer*: 2 reviews, 1 rating). Shortlist only. |
| **LMS-community `/album/<a>/<b>/review`** | keyless, verified | Returns **links only** (discogs / rateyourmusic / allmusic), no score. Weak "has editorial presence" flag. Don't build on it. |
| **Streaming popularity** | Qobuz/Tidal/Deezer | **Not in search payloads** — verified, Deezer album search has no `rank`/`fans` (same class as `[[streaming-search-no-track-count]]`). 1 extra call per album. Skip. |

### 3.7 Recommended composition

Each tier covers the previous one's blind spot:

1. **Type filter** (§3.1) — free, removes ~90% of the noise.
2. **Shipped acclaim list-count** (§3.3) — free, offline, 58-source consensus. *Canon.*
3. **Last.fm `artist.gettopalbums`** (§3.4) — 1 call/artist. *Long tail, Pool B.*
4. **MB Bayesian rating** (§3.2) — free, arrives with the discography call. *Tie-break.*
5. **Pitchfork BNM boost** (§3.6) — free, in-fleet. *Recent releases.*
6. **Discogs want/have** (§3.5) — shortlist only, 25/min. *Optional colour.*

Normalise each to 0–1 and take a weighted sum, so a missing source degrades instead of disqualifying.
Steps 1, 2 and 4 need **no new credential and no per-album network cost at all** — that alone is a
usable v1.

### 3.8 Why ListenBrainz popularity is excluded

Beyond Simon's call, it's independently unsafe as a dependency. Verified **2026-07-31**:

```
GET /1/popularity/top-release-groups-for-artist/<mbid>  → 500
GET /1/popularity/top-recordings-for-artist/<mbid>      → 500
{"code":500,"error":"Popularity API currently disabled due to high load on the server."}
```

Same outage recorded in CLAUDE.md's **0.9.77** entry (which is why the DSTM radio gained its CF-pool
fallback) — so this endpoint has been unreliable for an extended period. The bulk `POST
/1/popularity/release-group` *does* still work (returns `total_listen_count` / `total_user_count`),
but building a monthly feature's core ranking on a service that returns 500 for months is a bad trade.
Recorded here so nobody re-proposes it.

---

## 4. "Do I already own it?" — mostly an adaptation, with one real gap

**This is largely existing machinery.** The Created-for-You playlists and the People You Follow list
already do exactly this job, and the parts that matter are **unit-agnostic**:

| Existing | Reuse |
|---|---|
| **`'exclude'` libMode** (0.9.65) — probe the library, DROP if owned, signal via the 3rd `owned` callback arg, cache the `{owned=>1}` decision at `LIBRARY_TTL` | **Wholesale, no shape change.** This IS "remove owned ones from candidates". |
| `_resolveTracks(..., 'exclude')` — counts owned, returns it as the 4th `$done` arg | Wholesale |
| The idle-tick defer around every library probe (0.9.48) | Wholesale |
| The **two-pass FTS defence** in `_localByText` (combined term → bare term, re-verified) | Same structure, album terms |
| `_localByMbid` / `_titlesSearch` | Sibling functions — see below |

So the control flow is settled. What's actually new is **one sibling function pair**, near
line-for-line ports: `Slim::Schema->search('Track'…)` → `'Album'`, `['titles', …]` → `['albums', …]`,
`_trackMatches` → `_albumMatches`.

**Verified against the live server (`plex:9000`, JSON-RPC) 2026-07-31** — the `albums` command takes
`search:` exactly like `titles`, and both passes of the FTS defence work:

```
["albums",0,4,"search:radiohead ok computer","tags:layMSS"]   → count=1  OK Computer / Radiohead / 1997
["albums",0,4,"search:ok computer","tags:layMSS"]             → count=1  OK Computer / Radiohead / 1997
```

`search:` also spans contributors (a bare `search:radiohead` returned compilations Radiohead appears
on), so candidates need `_albumMatches` verification exactly as the track path needs `_trackMatches`.

### The one thing that does NOT transfer: the MBID tier

`_findLocalTrack`'s tier 1 is an exact `musicbrainz_id` hit. **There is no album equivalent:**

1. The `albums_loop` returns **no `musicbrainz_id`** even when asked for it (`tags:layMSS` above —
   the loop carries `id`, `album`, `artist`, `year`, `artist_id`, `favorites_url`, nothing else).
2. More fundamentally, our candidates carry **release-GROUP** MBIDs (from MB / the acclaim pool),
   whereas LMS tags carry **release** MBIDs (`MUSICBRAINZ_ALBUMID`). Different entities — an RG MBID
   would not match even if the column were exposed, without an extra MB lookup to expand
   release-group → its releases.

**Consequence: album ownership is text-matching only, with no exact-match backstop.** That's the
one place this is genuinely weaker than the track path, and it sharpens the failure-mode rule:

> Being wrong in the "already owned" direction is this feature's worst outcome — a row full of records
> the user already owns is worse than an empty row. With no MBID tier to fall back on, **bias toward
> treating uncertain as owned** (drop the candidate). A missed recommendation is invisible; a
> recommendation of something on the user's own shelf is the bug they report.

Optional later hardening if text matching proves too loose: expand RG → release MBIDs via one MB
call per shortlisted album and match those against the library's `MUSICBRAINZ_ALBUMID` tags. Only
worth it on the ≤30 shortlist, never the pool.

Discography's Local-candidate artist-gate is related but **deliberately DSC-only**
(`[[dsc-local-gate-not-synced]]`) — don't port it; adapt LBF's own `'exclude'` path as above.

---

## 5. Monthly cadence + no repeated artists

- Build key `lbf:reclisten:1:<user>|<YYYY-MM>` — the month is **in the key**, so the list is
  immutable within a month and rebuilds on rollover with no expiry logic. TTL ~40d.
- **One album per artist within the list** — group candidates by artist mbid, take that artist's
  best-scoring album, then rank across artists. Same one-vote-per-entity principle the trending
  breadth ranking already uses.
- **No repeat across a month**: persist the chosen artist mbids for the month
  (`lbf:reclisten:artists:<YYYY-MM>`) and exclude them from any mid-month rebuild (e.g. after a
  library scan). Optionally carry an N-month exclusion so consecutive months don't repeat either —
  **worth deciding**; a 3-month artist cooldown would keep it feeling fresh, mirroring DSTM's
  `ARTIST_COOLDOWN` FIFO.
- Build in the existing **`warmCache`** chain, last (cheapest, least urgent), gated on the section
  being enabled and on `Slim::Music::Import->stillScanning()` being false — a build against a
  half-scanned library would think the user owns nothing and recommend their entire collection back
  to them (exactly the 0.9.54 failure mode).
- An explicit **Refresh** must exist somewhere reachable — per 0.9.149, any cache-served view needs a
  way out. A home row can't carry an action row, so put it in Settings or accept the monthly key
  rollover as the only escape. **Open question.**

---

## 6. Cost

One MB browse call per library artist (discography **+** ratings together). Public MB is ~1 req/s, so
a 500-artist library ≈ **8 minutes** of background work, once a month. Entirely affordable at this
cadence — and free for users on a mirror (`mb_base_url`, or the 0.9.94 localhost auto-detect;
verified reachable at `plex:5000` on Simon's box).

Cache the per-artist discography (`lbf:artistrg:1:<mbid>`, 30d) so consecutive months and any future
per-artist feature reuse it.

---

## 7. Open questions

1. **"This needs to be wider"** — read as *the regard signal* needs more than one source, which §3
   addresses (six tiers, 58 acclaim lists in one of them). If it meant a wider **candidate pool**
   (beyond library + similar artists — e.g. the user's ListenBrainz history for artists never in the
   library, or `similar_users` from Year in Music), say so and Pool B expands.
2. **Which of §3.7's six tiers ship in v1?** Tiers 1+2+4 need no credential and no per-album network
   call, so they're a complete v1 on their own; 3 needs the Last.fm key decision; 5 needs a
   cross-plugin read; 6 is optional. Recommend v1 = 1+2+4, then add 3 with the key work.
3. **Artist cooldown across months** — 1 month, or 3?
4. **Pool A / Pool B ratio** — 2:1 suggested, unvalidated.
5. **Refresh route** for a home-row-only feature (§5).
6. Should it honour `blocked_artists` (`_isBlocked`)? Assume **yes**.
7. Does "listening history" mean **library** artists only, or LB-listened artists too? The spec says
   library; LB history would widen Pool A meaningfully for users who stream more than they own.
