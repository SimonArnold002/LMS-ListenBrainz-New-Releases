# Album-title search leg — a second query when the artist search finds nothing

**Status:** SCOPED, NOT STARTED here. Investigated 2026-07-31 against the live server.
**Already SHIPPED in the sibling Pitchfork Reviews plugin as 0.7.12** — this is a port, not a
design exercise. Read `LMS-Pitchfork-Reviews/PitchforkReviews/Browse.pm::_findPlayable` and its
`tools/t_searchlegs.pl` before writing anything here.

**Idea:** when a streaming service's album search for the ARTIST comes back empty, re-query that
same service with the ALBUM TITLE before declaring a miss.

---

## 1. The problem, measured

`_findPlayable` sends the raw ARTIST to each service's ALBUM search and filters the results locally
with `_albumMatches`. That is the right default and the reason is recorded in the sub's own comment:
searching `"artist album"` as one string made the services' own fuzzy search rank or drop the
target (Tidal missed *Sweating Someone Else's Fever*, Qobuz missed *Placebo RE:CREATED*), whereas an
artist search returns the discography and we pick the album ourselves.

**It fails completely when the artist's name is a common word**, because the artist search never
returns the release at all.

Field case (found via Pitchfork Reviews, but the mechanism is identical here) — **Leo –
*Cicada Burnt***, a Mancunian producer on Peak Oil:

| query to Qobuz's album search | result |
|---|---|
| `cicada burnt` | 17 releases, **`Leo - Cicada Burnt` at position #1** |
| `leo` | **200 releases, not among them** — Leo Sayer, Léo Ferré, Leo Dan, Leo Kottke, LiSA's *LEO-NiNE*, plus fuzzy hits like Ludovico Einaudi and Brian Eno |

So the album is on the service, and the matcher was never the problem — **the release never entered
the candidate pool**. This is a RECALL gap, not a matching gap.

**Raising the search limit does not fix it.** Discography measured the same cliff from the other
direction and recorded it as NOT fixed: a search for "madness" (limit 25) does not return "Tony
Madness" — 8 fans against the ska band's 260,000 — and raising the limit moves the cliff rather than
removing it. Here the album was absent at a depth of 200.

### How to reproduce the measurement

Via the LMS CLI against the Qobuz plugin's own search, no plugin build needed:

```bash
# 1. run a search (item_id:0.0 is "New search"; the term becomes part of the child ids)
curl -s -m 45 -X POST http://plex:9000/jsonrpc.js -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["<player-mac>",
       ["qobuz","items",0,25,"item_id:0.0","search:leo"]]}'
# -> 0.0_leo.0 Releases / .1 Artists / .2 Songs / .3 Playlists

# 2. read the Releases leg
curl -s -m 60 -X POST http://plex:9000/jsonrpc.js -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["<player-mac>",
       ["qobuz","items",0,200,"item_id:0.0_leo.0"]]}'
```

Note `item_id:0` + `search:` does NOT create a search — it only lists history, and a term already in
the history looks like a fresh result. Use `item_id:0.0`.

---

## 2. The change

`_findPlayable` runs up to **two legs per service**. Leg 1 is the artist, unchanged. If a service
comes back **DEFINED but EMPTY** — "searched fine, found nothing" — leg 2 re-queries that same
service with the album title.

The rules, each of which exists for a reason and each of which PFR pins with a test:

- **`undef` is NOT retried.** undef means the service could not be queried at all (no API handler,
  timeout, error, renderer die) and is already treated as *inconclusive* with a short TTL. A second
  query would spend another `STREAM_SVC_TIMEOUT` reaching the same non-answer. Only a real empty
  result is a recall answer worth retrying.
- **One retry, ever.** Two legs maximum, per service.
- **Each leg arms its OWN fresh watchdog** (leg 1's killed first), so leg 2 gets a full budget rather
  than the remains of leg 1's. Worst case per service becomes 2 × `STREAM_SVC_TIMEOUT`.
- **Skip the leg when it cannot help:** no album title, or the title equal to the artist under
  `_norm` (a self-titled release) — leg 2 would just repeat leg 1's query.
- **The album query needs BOTH spellings**, exactly like the artist query: `$qaChars`/`$qaBytes`,
  picked by the adapter's `query_enc`. Qobuz/Tidal want characters, Deezer wants octets; feeding
  octets to Qobuz/Tidal double-encodes accents into junk.

Precision is unaffected: `_albumMatches`' artist gate is mandatory, so a generic title still has to
come back credited to the right act.

---

## 3. LBF-specific notes (this is where it differs from PFR)

- **`$dropSingles` lives INSIDE `$settle`.** The new collector must intercept the adapter's *raw*
  result before that filter runs. This is safe: the filter cannot manufacture an empty set (it keeps
  the whole set when dropping would empty it), so "defined but empty" still means only one thing.
- **Bandcamp is already excluded** from `@adapters`, so the fallback leg can never trigger its
  loop-blocking synchronous search. Nothing to guard.
- **`_bcMatchItems`** (the persisted manual Bandcamp match) is appended after the resolve and is
  unaffected.
- **The album title we would search with is MB's/LB's release name**, not the service's. That is
  fine for a *search* (fuzzy, and `_albumMatches` validates the result), and is a different question
  from the `&al=` handshake, where the service's own spelling is mandatory — see 0.9.144–0.9.148.
  Worth knowing that MB keeps a release's distinguisher out of the title (all four American Football
  albums are titled `American Football`), so leg 2 for those is a generic query the artist gate has
  to carry.
- **NO `lbf:stream` bump.** The "bump on any change" rule protects FOUND matches, which cache 7d with
  the favurl frozen in. What is stale here is a **no-match**, `STREAM_NOMATCH_TTL` = 1 day — misses
  retry on their own within a day, and the detail page has its own Refresh for an instant retry. A
  found result cannot change, because leg 2 only runs where a service returned zero matches. Bumping
  would re-resolve every healthy album to save a 24h wait.
- Not a matcher change — this is adapter/call-site logic, so `matcher_sync_check.py` is unaffected
  and the fleet sync hold does not block it.

---

## 4. Tests

Mirror PFR's `tools/t_searchlegs.pl`: drive the REAL `_findPlayable` with scripted adapters (a `run`
that records its query and replies from a script), asserting match-settles-on-one-leg,
empty-retries-on-the-title-and-that-leg-wins, undef-never-retries, never-a-third-leg, the three skip
conditions, per-adapter chars-vs-octets on the leg-2 query, priority still decides, and a service
that matched runs one leg. Anti-test by forcing the skip flag off (`LBF_BROWSE=` at a mutated copy,
the house convention).

**Two traps that bit the PFR suite, both worth copying rather than rediscovering:**

1. Do NOT assert that a title differing from the artist only by stylisation skips the leg — `P!nk`
   folds to `pink` but a spaced-out `p ! n k` does not, so those are genuinely different queries.
   The skip is decided under `_norm`; test it with a pair that really is equal under `_norm`.
2. The encoding assertions need a title with a codepoint **above Latin-1**. A string whose every
   codepoint fits in a byte can sit in Perl WITHOUT the UTF8 flag, and then the character and octet
   spellings are byte-identical — the assertion passes while proving nothing.

---

## 5. Deliberately OUT of scope: the track path

`_findPlayableTrack` has the same artist-only query and the same recall gap, but **do not just copy
the patch into it.** Two things differ:

1. **Leg 2 would search the TRACK title**, and track titles are far more generic than album titles
   (*Home*, *Stay*, *1*). `_trackMatches`' artist gate still guards precision, but the recall gain is
   much less certain than the album case, where the title was distinctive.
2. **The layering breaks the no-bump argument.** `lbf:track` no-matches cache for
   `TRACK_NOMATCH_TTL` = **7 days**, and they sit inside `lbf:pl:resolved` at **14 days**. An outer
   hit never reaches the inner key, so a track miss is not retried for up to a fortnight — it does
   NOT self-heal within a day the way an album miss does. So on the track path a cache bump WOULD be
   needed, and that means re-resolving whole playlists (up to 250 tracks each).

**What to do first if the track path is ever picked up:** measure the recall gain, the way section 1
did for the album case. The "Unmatched tracks (debug)" view already lists exactly the tracks that
resolved to nothing — take a sample, query each service for the track TITLE via the CLI recipe above,
and count how many would have been found. If the answer is a handful out of hundreds, it is not worth
the playlist-wide re-resolve.
