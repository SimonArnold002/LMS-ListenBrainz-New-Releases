# The genre ladder and the hosted API — WHAT SHIPS TODAY

**Status:** current state of the code at **0.9.186**, verified by reading the source on
2026-08-23 (not from the earlier plans). **This is the "what it does" doc.** The other
genre documents are records of how we got here and several of their conclusions were
later reversed — see §7 before trusting a line in any of them.

> **Updated for 0.9.179 / 0.9.180 / 0.9.185 / 0.9.186.** 0.9.179 added the
> `/artist/<name>/discography` release-group resolver (§4); 0.9.180 added the MusicBrainz 503
> backoff on the artist-sort warm; **0.9.185 removed TWO of the detail page's three on-demand
> genre fetches** — the hosted album route and the MusicBrainz release-group call behind it —
> and **0.9.186 removed the third, the Last.fm one**. The detail page now reads the store and
> asks nobody at all. The ladder in §2 is otherwise unchanged since 0.9.173, but tier 1b is
> now write-once history: still read, never written. **0.9.186 also made the mirror path read
> the release-group tiers**, which it never could before (§2).

> **0.9.186 changed what a MIRROR user SEES.** `_mergeRgGenres` folds tiers 1 and 1b into the
> mirror path, so a row that showed the artist's genre can now show the album's own. That is
> the ladder behaving as specified — an answer about the record outranks a proxy for it — but
> it is a visible change, and mirror mode is the DEFAULT wherever `hasMirror()` is true.

Written because the plan and the implementation diverged: tiers were designed,
built, measured and then discarded, and the docs kept describing the design.

---

## 1. The short version

- **Genres come from ListenBrainz.** That is the backend, for the whole feed.
- **Last.fm is the only other rung that answers at any scale**, and it is the only
  genuinely independent source we have.
- **The hosted LMS-community API is NOT a genre backend, and as of 0.9.185 it plays no
  part in genres at all.** It was tried twice — an artist tier (removed 0.9.173) and an
  album tier on the detail page (removed 0.9.185). What remains of it has nothing to do
  with genres: the release-group resolver and two radio calls.
- **MusicBrainz is not in the default ladder either.** It runs only for users who
  have a local mirror, and for them it replaces the ListenBrainz path entirely.

Both hosted and MB were dropped from the New Releases path for the same reason:
ListenBrainz answers the same question in bulk, in fewer calls, without a throttle.

---

## 2. The ladder as implemented

`Browse::_genresFor` ([`Browse.pm:7845`](../ListenBrainzFreshReleases/Browse.pm#L7845)),
strongest first. The first rung that returns anything wins.

| # | Rung | Source | Keyed on | Stored in |
|---|---|---|---|---|
| 1 | The album's own tags | ListenBrainz | release group | `release_group.genres` |
| 1b | What the detail page learned — **historic, no longer written** (§6) | hosted `/album` route, else MusicBrainz | release group | `release_group.detail_genres` |
| 2 | The credited artist's tags | ListenBrainz | release group | `release_group.agenres` |
| 2b | The same artist tags, on the artist row | ListenBrainz | artist | `artist.lb_genres` |
| 4 | The feed payload's inline `release_tags` | ListenBrainz feed | in hand already | not stored — free |
| 5 | Last.fm artist tags, then album tags | Last.fm | artist / album | `artist.lastfm_genres`, `lastfm_tags` |

Notes that matter:

- **Rungs 1 and 2 arrive on ONE request** (`inc=release_group tag`), which also carries
  the release date. That is why ListenBrainz is cheap and why it is the backend.
- **1b sits above the artist rungs on purpose.** It is an answer about the *record*;
  an artist genre is only ever a proxy for it.
- **2b exists because artist tags learned from one release generalise to that artist's
  other releases.** Before it, the store re-bought the same answer once per release.
- **Rung 5 is gated to MusicBrainz's genre vocabulary** (`genre-families.txt`). Last.fm
  tags are crowd-written and carry no `genre_mbid`, so the file is the only gate available.
- **There is no tier 3.** The numbering has a hole in it because tier 3 was the hosted
  artist rung, removed in 0.9.173 (§5). Left as a hole deliberately — renumbering would
  make every older note about "tier 3" quietly wrong.

**The mirror path is a different ladder.** If `API::hasMirror()` is true,
`_genreLookupMode` returns `'mirror'` and `_withGenresMirror` → `API::getArtistGenres`
runs *instead of* the ListenBrainz path — it is those users' entire **artist-tier** lookup.
Do not delete it on the evidence of a zero counter on a box with no mirror.

**It was artist-tiers-ONLY until 0.9.186, and that was a bug.** Tiers 1 and 1b live on the
`release_group` row, which reaches `$meta` only through `DB::rgGet` — i.e. only on the
ListenBrainz path. Mirror mode built `$meta` entirely from artist rows via
`_metaFromArtists`, which hard-codes `genres => []` and never touches that row, so **both
record-level tiers were unreachable** and the list showed an artist proxy even when the
store held the album's own answer. `Browse::_mergeRgGenres` now folds both in, on **all
three** of `_withGenresMirror`'s exits (peek, the `getArtistGenres` callback, and the
`unless (@artists)` branch, which used to return `{}`). It goes through
`API::peekReleaseGroupMetadataBulk` — **one bulk read per page, never one per row** — and
it *creates* a `$meta` entry as well as filling one, since `_metaFromArtists` only makes a
row where some credited artist had genres.

**Tier 1 was included on evidence, not by symmetry.** The question was whether a mirror
box's store ever holds album tags at all, given the ladder never fetches them there. It
does: `getReleaseGroupMetadata` is called by the Trending Tracks date fill and the Trending
Albums release-group pass **regardless of genre mode**, and that request carries
`inc=release_group tag`. `agenres` is deliberately NOT merged — the artist tiers have their
own reader, already filled from the mirror's own artist rows on this path.

---

## 3. Where genres actually appear

| View | Genre line? | Pre-fills genres? |
|---|---|---|
| New Releases feeds (All Releases, For You, …) | **yes** — one top-level family + sub-genres | yes, `_withGenres` with a `$meta` map |
| Genre picker / genre filtering | **yes** — it is the whole feature | yes, walks the feed through `_bucketFor` |
| Album detail page | **yes** — full sub-genre list | **no** — reads the store only, fetches nothing (§6) |
| Followers → **Trending Albums** | **no** — the line shows "listened to by N followers" instead | no `$meta` passed |
| Followers → Trending **Tracks** | no | no — track rows, no genre code at all |
| Recommended by People You Follow | no | no — track rows, no genre code at all |
| Home shelves | no | no `$meta` by design |

So genres are **collected and stored** more widely than they are **shown**. That is
intentional as far as the store goes — sorting and filtering on them in more views is
future work — but note the specific asymmetry: **Trending Albums rows are release rows**
(`_trendingAlbumRow` → `_buildReleaseItem`) that *could* carry a genre line and currently
do not, because that view overwrites `line2` with the trending signal and passes no
genre map.

---

## 4. What the hosted API is used for TODAY

Exactly **three routes** in the plugin plus **one** diagnostics probe. Verified by
grepping every construction of `HOSTED_BASE_URL` / `hostedUrl` in the tree —
there are no others.

| Route | Section | Fires when | Falls back to |
|---|---|---|---|
| `artist/<name>/discography` | **`getReleaseGroupByName`** — Followers → Trending and Trending Albums | a candidate row has no release-group MBID (an unmapped listen) | the MB *search*, unconditionally |
| `artist/<name>/mbid` | **Don't Stop The Music radio** (the LMS mixer, not a browse section) | the playing track has no artist MBID; and once per similar artist needing resolution | the previous public-MB scored search, byte for byte |
| `artist/<name>/relatedArtists` | **Don't Stop The Music radio** | ListenBrainz has no similar artists for the seed | Last.fm similar, then the seed's own top recordings |
| `artist/<probe>/mbid` | **Diagnostics page** | you open the page | n/a — it is a connectivity row |

**The discography route (0.9.179) is the big latency win**, and it is the one measured
against a real symptom: a cold People You Follow open spent **22,880ms in 12 serial
MusicBrainz searches** because `mb_base_url` is unset, so they went to public MB at
~1 req/s. Hosted answers in 195–358ms cold, ~80ms warm, one call per ARTIST rather than
one search per ALBUM. **It buys speed, not coverage** — the names public MB missed, the
hosted API misses too. **Never "simplify" it to `/album/<title>/<artist>`:** that route
returns a RELEASE mbid, not a release-group one, and it would poison the dedupe key, the
CAA `release-group/<id>` art URL, the LB genre lookups and the detail page while looking
like it worked. The limitation is per-ROUTE, not API-wide.

Everything about how those calls are made — the mandatory `X-LMS-Plugin-ID` header, the
single `_hostedGet` funnel, the auth slot, the shared 429 backoff and its two retry
budgets — is in `hosted-lms-community-api.md` §0 and is still accurate.

**There is no longer a hosted genre call of any kind** — see §6 for why the album route
went in 0.9.185 and what was verified before removing it.

---

## 5. What was tried and discarded

**Hosted ARTIST genres — built, measured, REMOVED in 0.9.173.**
The premise was that ListenBrainz answers only ~52% of a feed, so a second artist tier
from a different dataset was the only thing that could move the number. **The premise was
wrong: the hosted API is MusicBrainz-derived, so it is not a different dataset.** It
succeeds where LB succeeds and fails where LB fails. Measured on the *residue* — the
artists that actually reach the rung, the only population it was ever asked about:

| date | replayed names | live store |
|---|---|---|
| 2026-08-13 | 4 of 120 | 11 of 411 |
| 2026-08-21 | 1 of 67 | 15 of 547 |

~2%, unchanged across a week in which the upstream dataset was believed to be filling —
for **one HTTP request per artist** at a concurrency of one, roughly 64s of serial HTTP
per warm for 400 artists. Last.fm answers ~63% of that same population. Judging a genre
source on a whole-feed sample (~50%) is what made this look useful; those artists never
reach the rung.

Removed with it: `_hagenFresh`, `peekArtistGenresHosted`, `getArtistGenresHosted`,
`HAGEN_*`, `%hagenInFlight`. The `artist` table keeps its `hosted_genres` /
`n_hosted_genres` / `hosted_genres_at` columns — an unread column costs bytes, a SQLite
column drop costs a table rebuild.

**MusicBrainz for New Releases — not in the default ladder.** The hosted API and LB
between them replaced it. MB now runs only on the mirror path (§2), and as the fallback
behind each hosted call.

**Do not reinstate either without new measurements**, and measure on the residue, not on
the whole feed.

---

## 6. The detail page fetches nothing — both on-demand tiers removed (0.9.185)

The page's genre step is a **store peek and nothing else**. It walks the whole of
`_genresFor` against what is already stored and renders. It makes no request.

It used to carry two fallbacks behind that peek — the hosted `/album/<t>/<a>/genres`
route, then MusicBrainz `release-group/<mbid>?inc=genres`. **Both are gone.** Three
things were verified before removing them:

1. **The ladder had already run.** The peek covers every tier, so anything any source
   ever answered was already in hand and neither call fired for it.
2. **The one population they were justified on was already covered.** The hosted route
   was kept in 0.9.173 for established albums — the Trending Albums crowd — but *that
   build stores genres itself*: its release-group metadata pass carries
   `inc=release_group tag`, so those genres are in the store before a row can be clicked.
3. **So they only ever ran on the residue where every MB-derived source was already
   empty** — and both of them are MB-derived, the same well ListenBrainz's tags come
   from. Measured 2026-08-22: hosted answered **0 of 40** albums off the live
   fresh-releases feed; MB's release-group tier previously measured **0 of 14** on the
   same residue.

Two blocking requests per album open, on the render path, to re-ask a well that had just
come up dry.

**AND THE LAST.FM CALL WENT IN 0.9.186 — the page now fetches nothing at all.** 0.9.185
kept it as "the genuinely independent rung", and that is a true statement about the
**ladder** rather than about this page. Last.fm **is** the ladder's tier 5, so the peek
above has already asked it: a second, live `album.gettoptags` could only repeat the rung
that just answered, or re-ask the one that just came up empty — while blocking the render
barrier behind up to two chained HTTP calls and rendering tags **ungated by `_genreKnown`**
that the lists themselves would have refused ("japanese", "Dreamy", "zzz").
**`API::getLastfmTags` STAYS**: `_warmLastfm` is tier 5's filler and is what puts Last.fm's
answer in the store to begin with. What went is this page's own call to it.

**`release_group.detail_genres` (schema 5) is therefore write-once history.** It still has
its own column and its own stamp (`detail_genres_at`) — writing into `genres` would
re-date ListenBrainz's answer beside it, the cross-tier overwrite schema 3 exists to
prevent — and it is **still READ as tier 1b**, so values already stored stay valid. Do not
strip the tier out of `_genresFor`; just don't expect anything new to arrive in it.

**Two traps to carry forward if a hosted genre route is ever reinstated**, both of which
have cost a day before:
1. `/music/artist/<n>/genres` **does not exist** — for artists, `genres` is a field on the
   parent route. An unrecognised path answers HTTP 200 with the *picture* payload rather
   than a 404, so a wrong path "works" while returning nothing for ever. The ALBUM route
   was the exception: `/music/album/<t>/<a>/genres` is real, it simply had nothing useful
   to say for this plugin's population.
2. The payload is **Title-Cased** ("Alternative Rock"). It must be lowercased on the way in
   — that was `_hostedGenreNames`, removed with its last caller — or `_genreFamily` will
   not match `genre-families.txt` and every row silently falls through to the raw genre
   instead of its family.

---

## 7. Where the older docs are wrong

Kept as history. Read them for the reasoning, not for the current shape.

- **`genre-ladder-rework.md`** — §1's ladder listed the Community API as tier 3. Corrected
  in place; the rest of the document predates 0.9.173.
- **`genre-sources-investigation.md`** — investigated MAI/hosted as a genre backend and
  concluded "good detail-page enricher, not for list rows". **That conclusion held**; the
  detail-page half is what shipped. Its coverage tables predate the residue measurements.
- **`hosted-lms-community-api.md`** — was marked "SCOPED, NOT STARTED". It has since
  shipped; header corrected. Its §2 proposed the rich `/album` endpoint for fresh-release
  *metadata* (type + date + genres). Only the **genres** half was taken.
- **`feed-findings-2026-08-14.md`** §8 step 4 carries the measurements and the MB-mirror
  trap that nearly cost a live feature.
