# Year in Music — feature scope

**Status:** SCOPED, NOT STARTED. Investigated 2026-07-31. No code written.
**Idea:** a Spotify-Wrapped-style yearly review inside LMS, built on ListenBrainz's Year in Music.

**Headline: this is the cheapest big feature on the board.** One public request returns the whole
thing, pre-computed, and most of it maps onto machinery the plugin already has.

---

## 1. The endpoint

```
GET /1/stats/user/<user_name>/year-in-music            # defaults to 2025
GET /1/stats/user/<user_name>/year-in-music/<year>
GET /1/stats/user/<user_name>/year-in-music/legacy/<year>
```

`stats_api.py` line ~1750. **No `validate_auth_header`** — public, verified 200 anon for three
users. **No token needed** (consistent with `token-free-refactor.md`).

Response: `{ "payload": { "user_name", "year", "data": { …20 sections… } } }`

### Year bounds — the one real trap

```python
# listenbrainz/db/year_in_music.py
LAST_FM_FOUNDING_YEAR = 2002
MAX_YEAR_IN_MUSIC_YEAR = 2025
```

**2026 returns 404.** A hardcoded "current year" would break the feature every January until
MetaBrainz bumps that constant and runs the pipeline. The plugin must **probe downward from the
current year** (or cache a discovered "latest available year") rather than assume.

Verified live for `mr_monkey`: 2022, 2023, 2024, 2025 all return 200 with 20 sections each (the
non-legacy pipeline has backfilled older years); 2026 and 2027 → 404. So **a year picker is viable**,
not just "last year".

A user with no computed data gets 200 with `data: {}` (the route does `db_year_in_music.get(...) or {}`);
docs also mention 204. **Handle both as "not calculated yet"** — don't cache either as a real answer
(the standing empty-result rule, cf. 0.9.149).

The separate `/legacy/<year>` endpoint is explicitly documented as *"not stable across years and
should be treated as archival"* — **ignore it**.

---

## 2. What's in the payload

Verified against `mr_monkey` 2025 — 20 sections:

| Section | Type/size | Shape | LBF fit |
|---|---|---|---|
| `top_recordings` | list 50 | `artist_name`, `track_name`, `recording_mbid`, `release_name`, `caa_id`, `caa_release_mbid`, `listen_count` | **Play-all track list** — exact shape `_resolveTracks` wants |
| `top_release_groups` | list 50 | `artist_name`, `release_group_name`, `release_group_mbid`, `caa_*`, `listen_count` | **Album list** — `_releaseDetail` already resolves from an RG mbid alone (trending albums does this) |
| `new_releases_of_top_artists` | list 45 | `artist_credit_name`, `title`, `release_group_mbid`, `caa_*` | Near-identical to a fresh-releases row — reuse `_buildReleaseItem` |
| `top_artists` | list 50 | `artist_mbid`, `artist_name`, `listen_count` | Display list; could hand off to the Discography plugin |
| `top_genres` | list 25 | `genre`, `genre_count`, `genre_count_percent` | Display |
| `playlist-top-discoveries-for-year` | dict | Full JSPF inline + `identifier` = playlist mbid | **Playlist** — same as createdfor; `getPlaylistTracks($mbid)` |
| `playlist-top-missed-recordings-for-year` | dict | ditto | ditto |
| `total_listen_count` | int | 5182 | Stat row |
| `total_listening_time` | float | 1512620.07 (seconds ≈ 420 h) | Stat row |
| `total_artists_count` | int | 1181 | Stat row |
| `total_new_artists_discovered` | int | 635 | Stat row |
| `total_recordings_count` | int | 3378 | Stat row |
| `total_release_groups_count` | int | 1230 | Stat row |
| `day_of_week` | str | "Sunday" | Stat row |
| `most_listened_year` | dict 65 | year → count | Stat row (pick max) |
| `listens_per_day` | list 365 | daily counts | Not renderable as a list — skip |
| `artist_map` | list 22 | country → artist/listen counts | Possible "your music came from N countries" stat |
| `similar_users` | dict 25 | username → similarity | Could feed People You Follow |
| `genre_activity` | list 175 | | Skip |
| `artist_evolution_activity` | list 1950 | | Skip — far too big for a browse list |

---

## 3. Proposed browse structure

New top-level section, present only when data exists for some year:

```
── Your Year in Music ──                     ← section header (_sectionHeader)
└── 2025                                     ← year tile (branded cover, tools/make_covers.py)
    ├── Your Year in Numbers                 ← stat rows (text), no resolution needed
    ├── Top Tracks (50)                      ← Play-all, _resolveTracks, library-first
    ├── Top Albums (50)                      ← tap-through → _releaseDetail (RG mbid)
    ├── Top Artists (50)                     ← display / Discography hand-off
    ├── Top Genres                           ← display
    ├── New Releases from Your Top Artists   ← _buildReleaseItem rows
    ├── Top Discoveries (playlist)           ← getPlaylistTracks by mbid
    └── Top Missed Recordings (playlist)     ← getPlaylistTracks by mbid
    (+ a year picker row if >1 year has data)
```

---

## 4. What's genuinely new vs reused

**Reused as-is** — this is why it's cheap:
- `_resolveTracks` (+ library-first, service order, owned handling) for the two track lists
- `_releaseDetail` from a bare `release_group_mbid` — already proven by Trending Albums
- `_buildReleaseItem` for `new_releases_of_top_artists`
- `getPlaylistTracks` for the two JSPF playlists
- `_sectionHeader`, tiles, `cachetime => 0`, `_refreshItem`, `_trendBlocked`, Play-all

**New:**
- `API::getYearInMusic($user, $year)` — one request, parse + normalise, cache `lbf:yim:1:<user>|<year>`
- **Long TTL**, this is the whole point: a completed year is immutable. **30d** for a populated
  year; **short (1h)** for empty/404 so it self-heals when the pipeline runs. (Do not cache empty
  long — the 0.9.149 lesson.)
- `API::latestYearInMusicYear($user)` — probe downward from the current year, cache the answer
- A stats-row renderer (formatting listening time, picking `most_listened_year`'s max)
- `Browse::fetchYearInMusic` + per-section coderefs
- Branded cover + strings; a `year_in_music` master on/off pref, mirroring `people_follow`
- Warm: pre-resolve the two track lists in `warmCache` — but see §5

---

## 5. Risks / decisions

1. **Seasonality.** For most of the year this shows *last* year's data. Fine — it's an archive — but
   the tile should say which year it's showing, and the section shouldn't imply freshness.
2. **`MAX_YEAR_IN_MUSIC_YEAR` is a MetaBrainz constant, not a date.** 2026 data appears only when
   they bump it and run the pipeline. Probe, never assume. This is the single most likely source of
   "the feature broke".
3. **Warm cost.** Two 50-track lists + two playlists = up to ~150 track resolves. That's the same
   order as one createdfor playlist week, but it's pure once-a-year work. Suggest warming **only the
   two `top_*` lists**, lazily resolving the playlists on open, and only warming at all when the
   section is enabled.
4. **Testing.** Simon's account is too new for meaningful data — hence "get someone else to test".
   `mr_monkey`, `rob` and `lucifer` all have populated 2022–2025 data and are usable as **read-only
   fixtures** for development. Write `tools/fetch_yim.py` (sibling of `fetch_trending.py`) so the
   whole thing can be prototyped against the live public API with no LMS.
5. **Not a Wrapped clone.** No animation, no shareable cards, no story UI — an OPML feed can't do
   that. This is a browsable archive of the same data. Set expectations in the release post.
6. **`similar_users`** is an interesting side-door into People You Follow (users LB thinks you match,
   independent of who you actually follow). Out of scope here; note it as a future idea.

---

## 6. Verification commands

```bash
# whole payload, section sizes
curl -s "https://api.listenbrainz.org/1/stats/user/mr_monkey/year-in-music/2025" \
 | python3 -c "import sys,json;d=json.load(sys.stdin)['payload']['data'];[print(f'{k:40s}{type(v).__name__:6s}{len(v) if isinstance(v,(list,dict)) else v}') for k in sorted(d) for v in [d[k]]]"

# which years have data
for y in 2022 2023 2024 2025 2026; do printf "%s " $y; \
  curl -s -o /dev/null -w "%{http_code}\n" "https://api.listenbrainz.org/1/stats/user/mr_monkey/year-in-music/$y"; done
```
