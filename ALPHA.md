# `alpha` — PARKED WORK. Do not merge, do not release from here.

**Status: parked 2026-07-29 at 0.9.140. Blocked on a backend decision, not on bugs.**

This branch holds the **genre-labels** feature and everything built on top of it. It is
*not* a release line and it is *not* ahead of `dev` in any way a maintainer should act
on. If you are fixing something in the shipping plugin, work on `dev` — see
"Relationship to dev" below, because parts of this branch were deliberately taken to
`dev` and parts were deliberately left here.

## Why it is parked

The genre labels need a genre source for every release in a feed. Measured against the
live All Releases feed on 2026-07-29 (381 releases):

| Source | Cost | Notes |
|---|---|---|
| ListenBrainz `/1/metadata/release_group/` | **0.25 s – 24 s per 50 releases**, wildly variable | 8 calls for one feed; one measured full fill took **125 s**. Not rate limiting — `x-ratelimit-remaining` was 26–29 of 30 throughout. 502s above ~90 mbids, so bigger batches are not available. |
| Local MusicBrainz mirror `artist/<mbid>?inc=genres` | **40–120 ms per artist**, unthrottled, no variance | Same data: over 50 artists both sources had genres for exactly the same 16, **zero disagreement in either direction**. |

So the feature is only comfortable for users who run a local MusicBrainz mirror. That is
a small minority, and shipping a feature whose default path is a remote lottery was
judged the wrong trade for the shipping plugin.

**The open question this branch is waiting on: whether the plugin adopts a Lyrion API
server as a metadata backend.** If it does, that becomes the fast path for everyone and
this work can be unparked and finished. Until that decision is made, none of it ships.

## What is on this branch that is NOT on `dev`

Everything genre-related, and only that:

- **Genre labels on list rows** (0.9.129–0.9.135) — the tier ladder (release genres →
  artist genres → the feed's own `release_tags` → gated Last.fm), the 2,177-name
  MusicBrainz genre vocabulary and family rollup table (`genre-families.txt`, generated
  by `tools/make_genre_families.py`), the async batched fill, the daily warm.
- **The genre picker** (0.9.136–0.9.138) — the tick-list, its apply row, per-level scoping.
- **The mirror-first rework** (0.9.140) — `API::getArtistGenres` (artist-keyed, mirror
  only, 6 concurrent), `Browse::_genreLookupMode` (`auto` | `always` | `off`), the
  `genre_lookup` pref, peek-only renders with a bounded background top-up, and
  `getReleaseGroupGenres` un-orphaned for the release detail page.

Supporting assets that exist ONLY here: `genre-families.txt`, `tools/make_genre_families.py`,
`tools/genre_freq.json`, and the genre/checkbox Material icons (`lbf-genre_*`,
`lbf-check-on_*`, `lbf-check-off_*`, `lbf-apply_*`).

## Relationship to `dev` — read this before assuming a fix is missing

`dev` **does** carry the non-genre work that was developed alongside the genre feature:

- **Albums / Singles & EPs per-feed view toggle** (0.9.126–0.9.128) — `_viewFilter`,
  `_familyAvail`, `_effectiveView`, `_viewToggle` and the `foryou_view` / `all_view` prefs.
- **The All Releases Refresh row** restored to the week drill (0.9.127).
- **The per-walk performance pass** (0.9.139) — `API::%FEED_MEMO`, `Browse::%SECTION_MEMO`
  (`_allSection` / `_forYouSection`), the `_weekStart` memo, `_stashSummary` write elision,
  the `_orderedAdapters` and trending-count memos, plus `tools/bench_walk.pl`.

So: a genre bug belongs here. Anything else almost certainly belongs on `dev`, and a
fix made on `dev` will need re-applying here whenever this branch is unparked.

## If you unpark this

1. Rebase or merge `dev` in first — `dev` has moved on and the two share a lot of code.
2. Re-run `perl tools/bench_walk.pl`; the perf assertions there still apply.
3. Re-verify the mirror-vs-ListenBrainz coverage claim before trusting the swap. It was
   true on 2026-07-29 over 50 artists; it is the fact the whole design rests on.
4. Note the genre lookup defaults to **off** without a mirror. If a Lyrion API backend
   lands, that default is the thing to revisit.

## Known gaps carried by this branch

- **CHANGELOG has no entries for 0.9.120–0.9.125.** The working history jumps
  `0.9.126 → 0.9.119`. 0.9.120 shipped as a commit (fleet matcher sync) without a
  changelog block; 121–125 have none at all. Not reconstructed — the record is simply
  missing for those.
- **`artist-sort cache set failed: Wide character in subroutine entry`** appears in live
  server logs (`API::warmArtistSorts`, the cache write dies on non-Latin artist names, so
  those sort-names never cache and re-fetch from MusicBrainz every time). Diagnosed but
  **not fixed** on either branch. Same class as the Last.fm key bug fixed in 0.6.15.
- `tools/matcher_sync_check.py` exits 1 on a **pre-existing** drift: DSC carries an
  apostrophe/`'n'` fold in `_norm` that never reached LBF/PFR/SH. Unrelated to this
  branch; wants its own fleet-sync session.
