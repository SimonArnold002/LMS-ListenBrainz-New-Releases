# Hosted LMS-Community API (`mai-api`) — integration scope for LBF

**Status: SHIPPED — and partly REVERSED. Updated 2026-08-22.** Scoped 2026-08-01, built
0.9.162, artist-genre tier removed again 0.9.173. **For what the plugin actually calls
today, read `genre-ladder-current.md` §4 — not this document's §1/§2/§5, which are the
original plan.** In short: the resolver (§1) and `relatedArtists` shipped as designed;
of §2 only the *genres* half was taken, detail-page only; the hosted ARTIST genre tier
was built, measured at ~2% on the population that reached it, and removed.

**Then 0.9.179 added the release-group resolver (§6), and §7 SETTLED the rest: the
remaining MusicBrainz features STAY on MusicBrainz.** No local mirror is assumed
anywhere — Simon's was for development only and is not going forward, so every
judgement is made against public MB at ~1 req/s. Read §7 before proposing any further
migration; the alternatives for sort names and tracklists have already been probed
live and ruled out.

**NOTE THE `/music` PREFIX.** Every route below is written without it and is wrong on
that point — the live paths are `/music/artist/<name>/mbid`, `/music/album/<t>/<a>/genres`,
`/music/artist/<name>/relatedArtists`. That error cost a planning cycle.
**What it is:** `https://api.lms-community.org` — the LMS core dev's hosted MusicBrainz /
MusicArtistInfo REST API (the `mai-api` service). Cloudflare-cached (`max-age` 30d), ~90ms warm.
It can back-end the artist→MBID resolution and fresh-release metadata this plugin currently gets
from public MusicBrainz (throttled) or a local `musicbrainz-docker` mirror (which most users don't
run).

Everything below was verified with **live HTTP calls** against the running service and read against
**this plugin's own source** (`API.pm` / `DSTM.pm`). It supersedes part of
`genre-sources-investigation.md`: that doc concluded the hosted API was too stale/sparse for
fresh-release genres — the dev has since fixed the freshness (see §3), so the fresh-release-metadata
option is back on the table, **with a fallback**.

---

## 0. Two hard requirements before any call is written

1. **`X-LMS-Plugin-ID` header is MANDATORY on every call** (dev's explicit request). Send the
   calling plugin's package name. Use the guarded form — `apiHeaders` is a new `Slim::Utils::Misc`
   helper that may not exist on older LMS:

   ```perl
   # from Plugin.pm:
   my %headers = Slim::Utils::Misc->can('apiHeaders')
       ? Slim::Utils::Misc::apiHeaders(__PACKAGE__)
       : ('X-LMS-Plugin-ID' => __PACKAGE__);
   $http->get($apiUrl, %headers);

   # from API.pm / DSTM.pm (not the Plugin package) — derive it once:
   use constant PLUGIN_PACKAGE => __PACKAGE__ =~ s/\b(?:\w+)$/Plugin/r;
   # ...then apiHeaders(PLUGIN_PACKAGE) with the same guard.
   ```

2. **Auth may be added later** (dev heads-up; currently open, no key/token). So funnel EVERY hosted
   call through **one request helper** (in `API.pm`) that adds the header today and has a slot for a
   token/key pref + `Authorization` header + a graceful 401/403 fallback tomorrow. Do not scatter the
   base URL. One helper is also where §0.1's header lives.

3. **THE RETRY MUST BE BOUNDED, AND THE MISS BRANCH IS LOAD-BEARING** (added 0.9.174, after
   `_hostedGet` shipped without a cap). A 429 is correctly treated as "not tried yet" rather than
   as "this artist has no genres" — caching a rate limit as an answer would be a lie the store then
   honours for the full found-age. But an *uncapped* retry is a hang, not politeness: `$onMiss` is
   the **MusicBrainz fallback** in `getArtistMbidByName`, and `DSTM::_resolveArtistMbids` pumps one
   artist at a time waiting on that callback, so a single wedged lookup stalls a radio seed instead
   of degrading to the slower source. Cap it the way the ListenBrainz side always has
   (`LB_RETRY_MAX`) — now `HOSTED_RETRY_MAX` — and note two things the first implementation got
   wrong by omission:
   - **The shared-deadline stand-down needs its OWN, looser budget.** Waiting out a deadline another
     caller triggered is not this caller's 429; one shared counter spends a caller's budget on other
     callers' rate limiting and misses to MusicBrainz under ordinary concurrency.
   - **The budget must be threaded through the reschedule.** Re-entering the helper without carrying
     it resets the count on every retry, so the cap reads as present and behaves exactly as if it
     were absent. `t_genrefill.pl` §9 asserts the threading specifically, for that reason.

---

## 1. The main win — a two-tier name→MBID resolver

**Where:** `getArtistMbidByName` (`API.pm:939`). Today it queries public MB
`artist?query=artist:"<name>"&limit=1`, accepts the top hit **only if `score >= 90`**, and has a
mirror→public fallback for the Solr-index gotcha. It's called per DSTM/Radio seed and per Last.fm
similar-artist (`DSTM.pm:145`, `DSTM.pm:289`) — i.e. in **loops**.

**Why the hosted API helps against PUBLIC MB (the majority's backend):** no 1 req/s throttle, and a
globally shared Cloudflare cache (popular artists usually already warm). The DSTM/similar-artist
loops are the real payoff — resolving ~30 names is ~30s of enforced throttle on public MB vs mostly
instant here.

**The catch:** hosted `/artist/<name>/mbid` returns one `{name, mbid}` picked by **popularity**,
with **no score**. LBF's `score >= 90` gate exists on purpose — these MBIDs seed radio / similar-
artist chains that resolve **unattended**, so a wrong artist silently pollutes the output. We can't
lose that.

**The refactor** — replace the single MB query with:
1. Hit hosted `/artist/<name>/mbid` first (cached, unthrottled).
2. **Gate on NAME-FOLD equality** (lowercase + strip diacritics) between the query name and the
   returned `name`. This replaces `score >= 90`: fold-compare correctly **accepts** the API's
   diacritic picks (`beyonce`→`Beyoncé`, `motorhead`→`Motörhead`) and **rejects** a fuzzy mapping to
   a differently-named popular namesake.
3. On `{}` (unknown) OR a non-fold-match → **fall back to today's public-MB scored search** (the
   existing code path, byte-for-byte). No precision regression; the Solr gotcha is moot for public-MB
   users. **This fallback must stay unconditional** so an API outage degrades to current behaviour.
4. Cache as today (`lbf:artistmbid:` key).

**Caveats:** single third-party dependency (mitigated by the unconditional MB fallback); the fold
gate is not collision-proof (two artists both exactly "Nirvana" → API returns only the popular one —
but `score>=90` didn't disambiguate those either, so it's not a regression).
~~keep it behind a pref so users can opt out~~ — **DECIDED 2026-08-12 (Simon): there is NO opt-out
pref for the hosted API, anywhere.** Every hosted tier is unconditional and its fallback is what makes
that safe: a user who dislikes the service, or whom it cannot reach, already gets the previous
behaviour automatically. A pref would only add a setting nobody can reason about. Don't add one.
`getArtistMbidByName` is a shared port source (DSC has a copy) but is NOT part of
the fleet **matcher**-sync rule — decide fleet-wide vs LBF-only before shipping.

Verified the resolver copes with our hard cases: Better Oblivion Community Center, boygenius,
Danger Mouse & Jemini, and octet-encoded Motörhead / Sigur Rós / Beyoncé all resolve cleanly (it's
more robust than the local Solr mirror, which returns 0 for some of these when its index is unbuilt).

---

## 2. Fresh-release metadata — the rich `/album` endpoint

`GET /music/album/<title>/<artist>` (name-keyed) returns, for a release group:
`primary_type`, `secondary_types` (null if none), `release_date` (precision varies:
`"1985"` / `"1971-04"` / `"2026-07-24"`), `status` + `other_status` (status→count map),
`genres`, and discogs/allmusic/rateyourmusic/wikipedia/musicbrainz links.

So one call gives genres + type + date for a fresh release — this can replace the per-release
throttled `release-group/<mbid>?inc=genres` MB call (`API.pm:1233`) used on the detail page.

**Two caveats:**
- It's **name-keyed** — near-match risk on same-title albums / edition suffixes.
- The endpoint's own `mbid` is a **release** id (or `?mbid=<release>` drills to one release's
  status), and it does **NOT** equal our `release_group_mbid` from the LB feed. Fine for
  display/genres/cover; **do not** treat it as an identity match.

---

## 3. Freshness — WEEKLY today, daily WIP → LBF needs an MB fallback

The hosted DB was a stale snapshot; the dev fixed it. Re-benchmarked against the live For-You feed:
**7/7 current fresh albums found, including future-dated ones** (e.g. Phoebe Bridgers 2026-08-14),
all present in `/discography` too. Genres/cover resolve for them (a brand-new album may return empty
genres — untagged).

**But the rebuild cadence is currently WEEKLY.** Future-dated releases show only because MusicBrainz
**pre-announces** them; a genuinely brand-new addition made *after* the last weekly rebuild is
**absent** until the next one. This plugin is a **new-release** plugin, so that gap matters here (it
doesn't for the catalogue-oriented Discography plugin).

**Therefore: if we use the hosted API for fresh-release metadata, LBF MUST fall back to the MB API
when the hosted API can't find a release.** The dev confirmed this is the right approach.

**The dev is building daily incremental updates (WIP).** Once live, the gap shrinks to ~1 day and the
fallback is rarely hit — but **keep it** for same-day additions and as a safety net. (Simon thinks
daily needs no extra fields from us; to confirm when it ships.)

---

## 4. What the hosted API does NOT change

- **The streaming matcher.** LBF's core job (resolve fresh-release/playlist *tracks* to
  Qobuz/Tidal/Deezer + library) is track-level streaming search — the hosted API doesn't do it. This
  is a metadata/resolver aid only, never a matcher replacement.
- **Prose bio.** The `/biography` (and bare `/artist/<name>`) endpoints are **link directories**, not
  prose; the "review" endpoints are links too. The dev confirmed prose bio will NOT be added. Keep
  the MAI bio path (`_fetchArtistInfo`) — **MAI-only since 0.9.186**, when the Last.fm
  `getArtistBio` fallback beside it was removed (MAI's own sources already include Last.fm). That
  makes MAI the plugin's single bio source, so this endpoint family is the only alternative there
  might have been, and there isn't one.
- **`relatedArtists`** is last.fm-similar, not MB "member of band".
- **The remaining MusicBrainz features stay on MusicBrainz.** Decided 2026-08-22 — see §7.

---

## 5. Build order — DONE, with one deviation

1. **Resolver refactor (§1)** — shipped 0.9.162 as `getArtistMbidByName`, hosted-first with the
   name-fold gate and the unconditional MB fallback, exactly as scoped.
2. **Detail-page genres via `/album` (§2)** — shipped, but **genres only**. The type/date half was
   not taken: ListenBrainz already carries both on the request that fetches the genre tags, so the
   hosted call would have bought a second request for data in hand.
3. **NOT IN THIS PLAN, built and then removed:** a hosted ARTIST genre tier for list rows
   (0.9.162 → removed 0.9.173). See `genre-ladder-current.md` §5 for the measurements. Do not
   reinstate it without new ones, taken on the residue rather than on a whole feed.

No cache-shape changes are forced by any of this; bump the relevant keys only if a stored value's
content changes. Follow the repo's usual gates (`perl -c`, the relevant `tools/t_*.pl`) and the fleet
rules (no matcher change here, so `matcher_sync_check.py` is N/A).

---

## 6. `/discography` as the release-group resolver — shipped 0.9.179

The second tier the resolver plan (§1) scoped for artist names, now applied to
artist **+ album** in `getReleaseGroupByName`.

**The measurement that forced it.** Live server 2026-08-22: a cold People You
Follow open spent **22,880ms in 12 serial MusicBrainz searches** — `mb_base_url`
was unset, so they went to public musicbrainz.org at ~1 req/s, and one returned
503. Hosted: 195–358ms cold, ~80ms warm, and one call per ARTIST covers every
album by that artist instead of one search per album.

**Why this is not merely a local optimisation.** Pointing `mb_base_url` at a
mirror fixes latency for people who have one. LBF ships to people who do not, and
their default is the public API at 1 req/s — a ~23s stall inside a background
warm, every time.

**The route matters, and the obvious one is wrong.** `/album/<title>/<artist>`
returns a **RELEASE** mbid. `/artist/<name>/discography` returns a
**release-GROUP** mbid, which is the id LBF stores and keys on — the dedupe key
when one album arrives from two followers, the CAA `release-group/<id>` art URL,
the LB genre lookups and the detail page. Verified identical to MusicBrainz's own
answers both ways: The Iron Roses "Molotov Nights" →
`87c8435b-e948-483a-9b88-c5e81b06d7c1`, L'Rain "L'Rain" →
`d1ce5cbf-bc7d-4fdd-aba5-6a59c4bf9d82`. **That per-route limit is not an API-wide
one** — do not generalise it in either direction.

Not `?type=Album` either: measured 2.4s (a separate, always-cold cache key) to
trim 580 entries to 385, because Live and Compilation are *secondary* types and
still carry primary type Album.

**`?mbid=` is load-bearing here**, more than it was for `getArtistMbidByName`.
That sub can gate on the echoed artist name; this one sees only titles, so a
popularity-picked namesake would return a plausible-looking catalogue with no
tell. Verified live: bare `Nirvana` and the grunge mbid both give 784 entries, the
UK Nirvana mbid gives a different 19. The candidates in this path already carry
`artist_mbid`, so it is always passed when present — **and it is part of BOTH
cache keys**, the per-artist map and the per-album answer. Keying the album on
`artist|title` alone let two same-named artists sharing an album title collide,
defeating the disambiguation one layer below where it was made (caught by
`tools/t_rgresolver.pl`, not by review).

**It buys speed, not coverage.** The four names public MB could not resolve in
that window, the hosted API does not resolve either.

Cache families: `lbf:hdisco:` (per artist, folded title → answer, 7d — one weekly
rebuild, well under the 30-day absolute-epoch ceiling) and the existing
`lbf:rgbyname:` (per album, unchanged shape, so readers cannot tell which tier
answered). An unknown artist is cached at `MB_EMPTY_TTL` (1d), not 30d: absent
from this week's snapshot does not mean absent from next week's.

The matching reuses `Browse::_norm` through `->can` at runtime but adds nothing to
the shared matcher, so **the four-repo sync rule is not triggered** by this change.

---

## 7. SETTLED — what stays on MusicBrainz, and why

Decided 2026-08-22 after auditing every remaining MB call site. **No local mirror is
assumed anywhere in this decision.** Simon's `mb_base_url` was set for development
only and is not going forward; under 1% of users would ever host a mirror, so every
judgement below is made against the PUBLIC MusicBrainz API at its ~1 req/s throttle.

### Migrated — done, do not revisit

| sub | now |
|---|---|
| `getArtistMbidByName` | hosted `/artist/<name>/mbid` first (0.9.162), MB fallback only |
| `getReleaseGroupByName` | hosted `/discography` first (0.9.179), MB fallback only — §6 |
| `getAlbumGenresHosted` | **DELETED 0.9.185** — with `getReleaseGroupGenres` behind it |

Those first two were the whole of the measured cost: 22,880ms of a cold People You Follow
open, in 12 serial public-MB searches.

**The third row is a removal, not a migration**, and it is the counterpart to the resolver
work: the detail page's two on-demand genre fetches were deleted outright rather than moved
anywhere. Both were MB-derived and sat behind a store peek that had already walked the whole
ladder, so they only ran where every MB-derived source was already empty — hosted measured
0 of 40 on the live feed. **So the hosted API is now used for no genre purpose at all**, at
either artist (0.9.173) or album (0.9.185) level. Full reasoning in
`genre-ladder-current.md` §6; do not reinstate either without a measurement taken on the
RESIDUE rather than on a whole feed.

### Inert without a mirror — nothing to do

**`getArtistGenres`** (`artist/<mbid>?inc=genres`). `API.pm` opens with
`unless (hasMirror()) { $onDone->({}); return }` — it never fans out at public MB, so
for effectively every user it does not execute at all. `_genreLookupMode` routes to
the `'lb'` bulk path instead, benchmarked at 2.8s for a 556-release feed with
coverage reproduced exactly. Leaving this alone is not a compromise: the LB bulk path
is the better route, and `genre_lookup => 'always'` already means "use it even if a
mirror exists".

### STAYING ON MUSICBRAINZ — deliberate, with the alternatives ruled out

**`warmArtistSorts`** (`artist/<mbid>?fmt=json`) — artist **sort names**
("Beatles, The"). No alternative exists:

- ListenBrainz gives artist `type` (Person/Group, which decides whether to invert)
  but **no `sort_name`**. Artist block keys: `area`, `begin_year`, `rels`, `name`,
  `join_phrase`.
- Hosted `/artist/<name>` returns `aliases`, `genres`, `mbid`, `name` and a pile of
  external links — **nothing sortable**. Verified 2026-08-22.

Cost is acceptable because of WHERE it is called, which the name misleads about:
**this is not the background warm.** Its only two call sites are `fetchForYou` and
`_buildAllLanding`, both guarded `if ($mode eq 'artist')` — so it fires on a list
open, and only when that list is sorted by artist. A user who never sorts by artist
never triggers an MB lookup. It takes **no callback**: fire-and-forget, nothing
blocks on it, the list renders immediately and sort names fill in for next time.
Paced at 1.1s/artist on public MB, capped at `SORT_WARM_MAX` (100) per pass.

**`getReleaseDetails`** (`release/<mbid>?inc=recordings`) — the detail-page
**tracklist**. Stays on MB for two independent reasons:

1. **The hosted API has no tracklist at all.** `/album/<t>/<a>/{tracks,tracklist,
   recordings,tracklisting,songs}` ALL answer HTTP 200 with the `{"picture":...}`
   payload — the same "unrecognised route returns the picture" behaviour documented
   for `/artist/<n>/`, now confirmed to be service-wide. Never infer an endpoint
   exists from a 200; check the keys.
2. **ListenBrainz cannot be asked for a specific release.** It has the data
   (`/1/metadata/release_group/?inc=recording` → `recording.mediums[].tracks[]`) but
   only RELEASE-GROUP-keyed; `/1/metadata/release/<mbid>`, `/1/release/<mbid>` and
   `/1/metadata/release/?release_mbids=` all 404. So the `release_mbid` the feed
   hands us — present on all 43 rows of a live `fresh_releases` sample — cannot be
   used as the key. LB picks its own representative, which matched the feed's release
   only **38/43 (88%)**: 4 returned a different edition with a real tracklist
   (17/11/12 tracks) and 1 returned none.

   **And ListenBrainz's own website uses MusicBrainz for this.** Their frontend
   defines `lookupMBReleaseGroup` as
   `${MBBaseURI}/release-group/${mbid}?fmt=json&inc=releases+artists+media`. The full
   tracklist on a listenbrainz.org release page is MB data fetched client-side — so
   seeing one there is NOT evidence the LB API can supply it.

MB's `release/<mbid>?inc=recordings` is keyed on the exact id we already hold and is
100% exact. Worth stealing from LB's approach if detail pages ever need edition
choice: `inc=releases+artists+media` on the release GROUP returns every edition with
its media in ONE call.

**`getReleaseGroupGenres`** (`release-group/<mbid>?inc=genres`) — was the detail page's
THIRD genre attempt, after LB rg-tags and hosted `/album/<t>/<a>/genres`. **DELETED in
0.9.185, along with the hosted attempt in front of it** — which is what "if it ever needs
to go it is a deletion, not a replacement" turned into. The detail page now reads the
store and fetches no genres at all; see `genre-ladder-current.md` §6.

### The one thing worth asking upstream

`sort-name` on the hosted `/artist/<name>`. It is the only field blocking
`warmArtistSorts`, and with it MusicBrainz would be reduced to fallback legs alone.
Not urgent — the call is non-blocking and artist-sort-only.

### Latency note, for whoever tunes the detail page next

`getReleaseDetails` and `getReleaseGroupGenres` are **not** background work. Both sit
inside `_releaseDetail`'s render barrier
(`$pending = $wantStream + $wantGenres + $wantLastfm + $wantTracks + $wantArtist`),
so the page waits on them — ~1.9s each on public MB. `DETAIL_TIMEOUT` (10s) forces a
render with whatever arrived, so it degrades but never hangs. If detail-page latency
needs cutting, the slack is `getReleaseGroupGenres` (usually redundant behind two
earlier tiers), not the tracklist.
