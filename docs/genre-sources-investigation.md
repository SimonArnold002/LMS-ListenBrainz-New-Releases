# Genre sources — is MAI a better backend than LB/Last.fm?

**Status:** INVESTIGATION ONLY, 2026-07-31. **OUTCOME, added 2026-08-22: this doc's
conclusion held.** The detail-page enricher shipped (`getAlbumGenresHosted`); the list-row
idea was built anyway as a hosted ARTIST tier in 0.9.162 and removed again in 0.9.173 on
the numbers. Current shape: `genre-ladder-current.md`.
**Question:** the genre-labels feature is parked on `alpha` because ListenBrainz's bulk metadata
endpoint is too slow. Would **MusicArtistInfo (MAI)** populate genres without harming performance,
compared with the LB/Last.fm ladder we shelved?

**Short answer: no, not for list rows — but it's a good detail-page enricher, and it removes the
Last.fm key requirement.** Measured numbers below; don't re-derive them.

---

## 1. Recap — why the feature is parked

From `ALPHA.md` / CLAUDE.md, measured over 400 releases of the live All Releases feed:

| source | coverage |
|---|---|
| MB **release-group** genres | 5% |
| inline `release_tags` in the feed payload | 8% |
| MB **artist** genres | 47% |
| release-group ∪ artist | **49%** |
| + Last.fm artist tags on the remainder | **~71%** |

The blocker was never coverage — it was **latency**: LB's `/1/metadata/release_group/` answers a
50-release batch in **0.25s to 24s**, 502s above ~90 mbids, and took a measured **125s** to fill one
381-release feed. Not rate limiting (`x-ratelimit-remaining` stayed 26–29 of 30 throughout).

So the bar any replacement has to clear is: **fill a few hundred list rows fast enough to render.**

---

## 2. What MAI actually offers

MAI has **two** genre-ish paths, and they are very different things.

### 2a. `Plugins::MusicArtistInfo::API->getAlbumGenres` — the hosted LMS-community API

```perl
use constant BASE_URL      => 'https://api.lms-community.org/music';
use constant ALBUMGENRES_URL => BASE_URL . '/album/%s/%s/genres';
# _prepareAlbumUrl: sprintf($url, $args->{album}, $args->{artist})  <-- ALBUM FIRST
```

`GET https://api.lms-community.org/music/album/<ALBUM>/<ARTIST>/genres` →
`{"genres": ["Jazz-Funk", "Neo-Progressive Rock", "Progressive Rock"]}`

- **No API key.** Sends identification headers only (`x-mai-cfg`, `X-LMS-Plugin-ID`).
- Optional `?mbid=<release-group-mbid>` override (verified: same answer for Mildlife *Chorus*).
- MAI caches 30d and watches for 429 (`hasHitRateLimit`) — so there **is** a rate limit, unspecified.
- **Argument order is album-then-artist.** Reversing it still returns plausible-looking results,
  which is exactly how you'd ship a subtly wrong integration. Verified both ways.

**Speed: fine.** 30 calls in **4.8s** (~160ms each), sequential, cold. 5 sequential in 0.73s.

**Coverage: measured on two real populations —**

| population | coverage |
|---|---|
| 30 random **Album**-type releases from the live global fresh-releases feed (30d window) | **5/30 = 16%** |
| 30 albums from a real user's YIM `top_release_groups` (i.e. albums people actually listen to) | **17/30 = 57%** |

That gap is the whole finding. The dataset is Discogs-flavoured and lags brand-new releases badly —
which is precisely the population this plugin's feeds consist of. Misses in the fresh-release sample
were the obscure/self-released end (`sonnov – wodem`, `Wavy Bagels`, `CWEL Community`); hits were the
already-established names.

Caveat on the measurement: the fresh sample came from the **global** All Releases feed, which skews
obscure. A personalised For You feed would land somewhere between 16% and 57%. Worth re-measuring on
a real For You feed before any decision.

Vocabulary sample (rich, and clearly not MusicBrainz's):
`Jazz-Funk`, `Neo-Progressive Rock`, `Anatolian Rock`, `Hypnagogic Pop`, `Desert Rock`,
`Space Rock Revival`, `Post-Britpop`, `Abstract Hip Hop`, `Avant-Folk`.

#### There is NO artist-level genre route — and the API hides that fact

The obvious improvement is to mirror our own ladder: **album genres, falling back to the artist's
genres when the release is unknown** (that fallback is what lifts the LB ladder from 5% to 47%, so
it's where the coverage would come from). Probed 2026-07-31 — **it isn't available here:**

- MAI declares only `/artist/%s/picture` and `/artist/%s/biography`. No artist-genre constant.
- `GET /music/artist/<name>/genres` returns **200** with `{"picture": "https://…"}`.
  So does `/genre`, `/info`, `/tags`, and `/thisisnotaroute`. **Anything unrecognised under
  `/artist/<name>/` falls through to the picture handler.** It never 404s.
- **This is a real trap.** An integration written against a guessed artist-genre route would return
  200, parse a valid JSON body, find no `genres` key, and silently yield nothing forever — looking
  like poor coverage rather than a wrong URL. Only `/picture` and `/biography` behave distinctly
  (biography returns link data — bandcamp, rateyourmusic — not prose).
- The **album route does not fall back to the artist either**: an unknown album returns
  `{"genres":[]}` even for a well-known artist (tested `NoSuchAlbumXYZ123/Radiohead` and
  `…/King Gizzard & the Lizard Wizard`).

So the album endpoint's **16% / 57%** is the ceiling for this source, not a floor to be improved by
adding a fallback tier. That strengthens the conclusion in §3 rather than softening it.

**What can serve the artist tier keylessly: what we already use.** ListenBrainz's
`/1/metadata/release_group/?inc=release_group tag` returns `tag.artist[]` alongside
`tag.release_group[]` — that IS the 47% artist tier, it is **bulk** (50 per request), free, and in
**MusicBrainz vocabulary** so it maps cleanly onto `genre-families.txt`. `_genresFor` already
implements exactly the album→artist fallback described above. There is no better artist source
available, and nothing in MAI improves on it.

**Small upstream ask worth logging:** Last.fm's `artist.getInfo` — which MAI already fetches and
caches — carries a `tags` block, but MAI throws it away in both accessors (`getBiography` returns
only `{bio}`, `getRelatedArtists` only `{items}`), and `_getArtistInfo` is private. Exposing artist
tags from the response MAI has already paid for would be a near-zero-cost change on their side and
would give us a keyless artist-tag tier. Add it to the parked upstream list alongside the Material
asks in `[[material-custom-action-visibility-upstream]]`.

### 2b. `Plugins::MusicArtistInfo::LFM` — Last.fm, using **MAI's own key**

MAI embeds a Last.fm key (`Common.pm` `__DATA__`, base64:
`api_key=c6abc51e847b91aba0de2ede33875e24`) and scrubs it from logs.

| MAI method | Underlying call | Useful to us? |
|---|---|---|
| `LFM->getAlbum($cb, {artist, album})` | `album.getinfo` | **Yes** — returns the **raw** response, which includes `toptags`. So we can get Last.fm album tags **with no user key**. |
| `LFM->getBiography(...)` | `artist.getInfo` | Bio only — it **discards** the `tags` block. No artist-tag accessor exists. |
| `LFM->getRelatedArtists(...)` | `artist.getInfo` → `similar` | Weaker than it looks: that block is ~5–6 artists, **not** `artist.getsimilar`'s 100. Poor substitute for `API::getSimilarArtistsLastfm` in the DSTM radio. |

---

## 3. Comparison against the shelved ladder

| | LB bulk metadata | Last.fm (our key) | LMS-community via MAI |
|---|---|---|---|
| Requests for 400 albums | ~8 (50/req) | ~400, per **artist** (dedupes down) | **~400, per album** |
| Latency | 0.25–24s **per batch**; 125s for 381 | ~1 req/s pacing, warmed 40/tick | ~160ms each → ~58s sequential, ~6s at conc. 10 |
| Coverage on fresh releases | 49% (∪ artist tier) | → ~71% | **16%** |
| Coverage on established albums | high | high | 57% |
| Key required | no | **yes** (today) | no |
| Vocabulary | MusicBrainz (matches `genre-families.txt`) | free tags, gated by MB vocab | **Discogs-ish — does NOT match our rollup table** |
| Bulk-capable | yes | no | no |
| Dependency | LB (already) | Last.fm | third-party host + MAI installed |

### The four things that rule it out as the list-row source

0. **No artist tier to fall back to** (§2a) — so 16% on fresh releases is the ceiling, and the
   album→artist ladder that makes our existing source work can't be built on it.

1. **16% on the actual population.** Worse than the 49% we already get for free from data the feed
   partly carries anyway.
2. **One request per album, no bulk form.** Phase 1 of the genre work exists specifically to avoid
   per-item fan-out; this reintroduces it. Faster per call than LB, but 400 requests at an unspecified
   rate limit against someone else's hosted service is not something to point a feed fill at.
3. **Vocabulary mismatch.** `genre-families.txt` is generated from MB's 2177-name vocabulary
   (`tools/make_genre_families.py`) and doubles as the "is this a real genre?" gate for the Last.fm
   tier. Names like `Neo-Progressive Rock`, `Space Rock Revival`, `Hypnagogic Pop` don't exist in it,
   so every one would fall through `_genreKnown` and be discarded — or the whole rollup table would
   need regenerating against a second vocabulary. That's a large hidden cost.

**And it doesn't address why the feature is parked.** The blocker is per-item cost at list scale;
every alternative here is per-item. MAI changes the *credential* story, not the *performance* story.

---

## 4. Where MAI genuinely helps

1. **Detail page.** 57% on albums a user cares about, ~160ms, no key, 30d cached, richer vocabulary
   than MB. As a **detail-page-only** enricher (one album, on demand, on tap) it's strictly better
   than what the page does today. This matches the existing rule already in CLAUDE.md — *"streaming/
   external genre is a DETAIL-PAGE enricher only, never a list source"* — the LMS-community API just
   belongs in that same bucket. Low risk, self-contained, no rollup-table work if shown verbatim
   under the existing `Tags:`-style line rather than folded into `_familyFor`.
2. **Killing the Last.fm key.** `LFM->getAlbum` returns raw `album.getinfo` incl. `toptags` on MAI's
   key. If MAI is installed, the album-tag tier works with no user credential. Note the limits: no
   artist-tag accessor, and it's gated on MAI being installed — so it's a *fallback ladder rung*, not
   a replacement for `API::getLastfmTags`. See `token-free-refactor.md` §4; shipping our own key is
   the simpler answer and works without MAI.
3. **Not for DSTM.** `getRelatedArtists` gives ~5–6 artists vs `artist.getsimilar`'s 100. Keep
   `API::getSimilarArtistsLastfm`.

---

## 5. Recommendation

- **Do not** adopt the LMS-community API as the list-row genre source. It measures worse than what
  we have, on the population we have, and drags in a vocabulary mismatch.
- **Do** consider it as a **detail-page** enricher, independent of the parked `alpha` work, shown
  verbatim. Small, safe, no rollup dependency.
- **Keep the genre-labels feature parked.** Nothing found here changes the parking reason. The real
  unlock is still a bulk, low-latency, MB-vocabulary genre source — which today only LB's metadata
  endpoint is, and it's too slow. Revisit if MetaBrainz speeds it up, or if the LMS-community API ever
  grows a **batch** endpoint (worth asking the LMS dev — see `[[dsc-lms-community-api-migration]]`,
  which is already blocked on him adding fields to `/discography`; a batch genre lookup could go on
  the same ask list).
- **Re-measure on a For You feed** before acting on any of this — 16% is the pessimistic bound.

---

## 6. Reproduce the measurements

```bash
# the artist-route catch-all — all of these return {"picture": …}, none 404
for p in genres genre info tags thisisnotaroute; do
  printf "%-16s " "$p"; curl -s "https://api.lms-community.org/music/artist/Radiohead/$p" | head -c 80; echo
done

# coverage on brand-new releases (global feed)
curl -s "https://api.listenbrainz.org/1/explore/fresh-releases/?days=30&past=true&future=false" -o /tmp/fresh.json
# then sample Album-type rows and hit:
#   https://api.lms-community.org/music/album/<ALBUM>/<ARTIST>/genres?mbid=<rg-mbid>
# NB: ALBUM first, ARTIST second.

# coverage on established albums
curl -s "https://api.listenbrainz.org/1/stats/user/mr_monkey/year-in-music/2025" \
 | python3 -c "import sys,json;[print(r['release_group_name'],'|',r['artist_name']) for r in json.load(sys.stdin)['payload']['data']['top_release_groups']]"
```
