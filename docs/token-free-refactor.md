# Removing the ListenBrainz token (and the Last.fm key) — findings & scope

**Status:** SCOPED, NOT STARTED. Investigated 2026-07-31. No code written.
**Goal:** the plugin should work fully with a **username only** — no ListenBrainz token, no
Last.fm API key — so a new user types one field and everything works.

Everything below was verified two ways: against the **ListenBrainz server source**
(`metabrainz/listenbrainz-server`, master) and with **live anonymous HTTP calls**. Where the two
could disagree, both are recorded. Don't re-derive this — it took a full session.

---

## 1. What the token is actually needed for

**One thing.** `recording_recommendation` timeline events. That is the entire dependency.

### Verified public — token adds nothing

| Endpoint | Feature | Evidence |
|---|---|---|
| `GET /1/user/<u>/fresh_releases` | **New Releases for You** | 200 anon, full payload (`rob`, `lucifer`, `mr_monkey`) |
| `GET /1/user/<u>/playlists/createdfor` + `/1/playlist/<mbid>` | Created-for-You playlists | 200 anon |
| `GET /1/user/<u>/following` / `/followers` | People You Follow | No `validate_auth_header` in `social_api.py`; only follow/unfollow POSTs are authed |
| `GET /1/stats/user/<u>/{recordings,release-groups}` | Trending | 200/204 anon (204 = not computed/private, same with or without a token) |
| `GET /1/user/<u>/listens?count=1` | Stale-follower filter | 200 anon |
| `GET /1/cf/recommendation/user/<u>/recording` | DSTM Recommended + radio cold-start | 200 anon, real mbids/scores |
| `GET /1/feedback/user/<u>/get-feedback?score=1` | *(new — see §2)* | 200 anon |
| `GET /1/<u>/pins`, `GET /1/<u>/pins/following` | *(new — see §2)* | 200 anon |
| `GET /1/stats/user/<u>/year-in-music/<year>` | *(see `year-in-music.md`)* | 200 anon |

Anonymous rate limit is **30 requests / 10s per IP** (`x-ratelimit-limit: 30`,
`x-ratelimit-reset-in: 10`). Ample for this traffic shape.

### Verified private

`GET /1/user/<u>/feed/events` — **401 anon**, confirmed against a real user, and the route is
strictly self-only:

```python
# listenbrainz/webserver/views/user_timeline_event_api.py :: user_feed()
user = validate_auth_header()
if user_name != user['musicbrainz_id']:
    raise APIForbidden("You don't have permissions to view this user's timeline.")
```

Every route in `user_timeline_event_api.py` calls `validate_auth_header()`.

### Why `recording_recommendation` cannot be reached any other way

The event types are an enum (`listenbrainz/db/model/user_timeline_event.py`):

```python
class UserTimelineEventType(StrEnum):
    RECORDING_RECOMMENDATION = 'recording_recommendation'
    FOLLOW = 'follow'
    LISTEN = 'listen'
    NOTIFICATION = 'notification'
    RECORDING_PIN = 'recording_pin'
    CRITIQUEBRAINZ_REVIEW = 'critiquebrainz_review'
    PERSONAL_RECORDING_RECOMMENDATION = 'personal_recording_recommendation'
    THANKS = 'thanks'
```

`_parseFollowFeed` keeps `recording_recommendation` + `recording_pin` (`%FOLLOW_TRACK_EVENT`,
API.pm ~804).

- `recording_recommendation` is **created** by `POST /1/user/<u>/timeline-event/create/recording`
  ("Make the user recommend a recording to their followers"), authed.
- There is **no GET** that returns it outside the authed feed. `/1/user/<u>/timeline`,
  `/timeline-event`, `/recommendations` all **404**.
- `atom.py` contains a timeline-events Atom feed with a `RECORDING_RECOMMENDATION` branch —
  **entirely commented out** (~lines 1080–1160). Dead code, not a route.

**Conclusion:** it is push-only social content, readable only by authenticating as yourself.

---

## 2. The public replacements

Two public per-follower signals, both richer than the feed in some respects.

### 2a. Loved tracks — the primary replacement

`GET /1/feedback/user/<u>/get-feedback?score=1&metadata=true&count=N`

`feedback_api.py` line ~75: a plain `@feedback_api_bp.get(...)` with **no `validate_auth_header`**.
Live: 200 for all three test users, `total_count` 94 / 35 / 244, and `count=2000` returned all 244
in one request (no low cap enforced).

Record shape is a **superset** of what `_parseFollowFeed` produces:

```json
{ "created": 1776351454,
  "recording_mbid": "e53766ad-b80e-40ab-b28c-a2f0a1aa414e",
  "score": 1,
  "user_id": "mr_monkey",
  "track_metadata": {
    "artist_name": "Seren Saraç",
    "track_name": "Y4R4",
    "release_name": "Y4R4",
    "mbid_mapping": { "caa_id": 44882113718,
                      "caa_release_mbid": "0c114955-f3dc-4183-8f92-8c27b179e447" } } }
```

Maps onto the existing normalised shape with no invention:

| existing field | comes from |
|---|---|
| `artist` | `track_metadata.artist_name` |
| `title` | `track_metadata.track_name` |
| `album` | `track_metadata.release_name` |
| `recording_mbid` | `recording_mbid` (top level) |
| `recommender` | `user_id` |
| `created` | `created` (epoch — drives the day dividers) |

Bonus: `caa_id` / `caa_release_mbid` give **artwork**, which the follow feed never provided.

`score=-1` is "hated" — must be filtered out; always request `score=1`.

### 2b. Pins — secondary

| Route | DB function | Scope |
|---|---|---|
| `GET /1/<u>/pins` | `get_pin_history_for_user` — `WHERE user_id = :id ORDER BY created DESC` | **Full history**, no expiry filter. 1 request per follower. |
| `GET /1/<u>/pins/following` | `get_pins_for_user_following` — joins `user_relationship` on `relationship_type='follow'` **AND `pinned_until >= NOW()`** | **Currently-active pins only.** 1 request total, follower join done server-side. |

Neither calls `validate_auth_header`. Live: `/pins` returned a 2023 pin whose `pinned_until` had
long expired (confirming no expiry filter); `/pins/following` returned 200 with `count: 0` for all
three test users — nobody they follow had an active pin at the time.

Pin duration defaults to **exactly 7 days** (observed `pinned_until - created = 604800`), so a daily
warm polling `/pins/following` catches essentially every pin for one request. Per-follower `/pins`
is the backfill option if history matters.

**Note the path:** pins is `/1/<user>/pins`, **not** `/1/user/<user>/pins` (the latter 404s with
`Cannot find user: user/<name>`). Cost 10 minutes to spot.

---

## 3. Code changes required

### 3.1 Drop the token gates (small, do first — this is the real user-facing win)

| Location | Change |
|---|---|
| `API.pm` ~209 `getFreshReleasesForUser` | `unless ($username && $token)` → `unless ($username)`. Keep sending the `Authorization` header **when a token happens to be set**, like `getFollowing` already does. This is the headline fix: the plugin's flagship feed is gated on a credential it never needed. |
| `Browse.pm` 248 | `push @people, _followTile($client, $feat) if $token;` → gate on `$username` once the tile is rebuilt on public sources |
| `Browse.pm` ~2298 `fetchUnmatchedPlaylists` | token-gated follow-feed append → same treatment |
| `Settings.pm` / `strings.txt` | Token hint becomes "optional — only adds *recommended* tracks to People You Follow"; `PLUGIN_LBF_TOKEN_*` strings reworded. Keep `validateToken` + the Check-token button (still useful when a token *is* entered). |
| `strings.txt` 302 | `"Configure username and token in Settings"` → username only |
| `CLAUDE.md` | The Requirements line and the 0.9.65 section both state token-required; update both |

**No cache-version bumps needed for 3.1** — nothing about the cached shapes changes.

### 3.2 Rebuild "Recommended by People You Follow" on public sources

New in `API.pm`:

- `getLovedTracks($user, %args)` → `/1/feedback/user/<u>/get-feedback?score=1&metadata=true`,
  normalised to the existing 6-field shape, per-user cache `lbf:loved:1:<user>` at `STATS_TTL`
  (24h — same cadence as `lbf:userstats:`, since this gates on the same daily warm).
- `getPinsForFollowing($user)` → `/1/<u>/pins/following`, one request, same normalisation.
- Optionally `getUserPins($user)` → `/1/<u>/pins` for per-follower history backfill.
- Keep `getFollowFeed` **unchanged** — it becomes the optional token path.

In `Browse.pm`:

- `_resolveFollow` gains a source-merge step: public sources always; `getFollowFeed` **additionally**
  when a token is set. Merge before `_mergeFollow` so the accumulating store sees one list.
- Fan-out reuses **`_fanFollowers`** exactly as trending does — it already has
  `FOLLOWER_FANOUT`=6 / `FOLLOWER_MAX`=250 / `FANOUT_DEADLINE`=30s and the 0.9.117 re-entrancy
  guard. Do **not** hand-roll a second pump.
- `_mergeFollow` / `lbf:follow:accum:` store, `_followTrackKey` dedup, `_followResult` day dividers,
  `_followSortToggle` (date/recommender), `'exclude'`-mode owned filtering, `_trendBlocked`,
  Play-all — **all unchanged**. They operate on the normalised shape.

Cache bumps required (content shape and provenance change):
- `lbf:follow:accum:1:` → `:2:`
- `lbf:follow:resolved:5:` → `:6:`

Per the standing rule, bump **both** layers — the outer resolved key wraps the inner store.

### 3.3 The volume problem — decide this before building

This is the actual design work; the plumbing is easy.

The current list is **sparse** (a real user had ~35 recs spread ~1/week over months — which is why
the 0.9.70 rolling-4-week layout was abandoned in 0.9.71 for one accumulating list). Loved tracks are
far **denser**: one test follower alone had 244. Across up to `FOLLOWER_MAX`=250 followers this goes
from too-few to tens of thousands, and every survivor costs an owned-check + streaming resolve.

Options to size it (not yet chosen):
1. **Recency window** — only loved entries with `created` within N days (90?). Cheapest, and matches
   the "what are people into lately" framing.
2. **Per-follower cap** — newest K per follower (10?) before merging, so one prolific
   heart-clicker can't dominate. Mirrors the one-follower-one-vote principle the trending ranking
   already uses.
3. **Breadth ranking** — reuse the trending idea: rank by *distinct follower count*, so a track
   several people loved outranks one person's 200. Most consistent with the rest of the section,
   most work.
4. Keep `FOLLOW_KEEP_MAX`=500 as the final backstop regardless.

Recommend **1 + 2 + 4** initially; 3 only if the list still feels arbitrary.

### 3.4 Naming / honesty

The tile currently says "Recommended". With public sources it becomes **"loved or pinned by people
you follow"**. That is a defensible, arguably stronger endorsement signal — it is what LB's own
public profile surfaces — but it is a **different feature wearing the same name**. Retitle the tile,
the cover (`tools/make_covers.py` → `menu-follow.png`), and the strings.

---

## 4. The Last.fm key

Separate credential, same goal. Used in exactly three places:

| Use | Location | Keyless replacement |
|---|---|---|
| Genre/tag fallback | `API::getLastfmTags` ~2145 | See `genre-sources-investigation.md`. Partly replaceable; not a clean win. |
| Artist biography (only when MAI absent) | `API::getArtistBio` ~2060 | MB `artist/<mbid>?inc=url-rels` → Wikidata → Wikipedia TextExtracts. No key. MAI ships `Wikipedia.pm` doing exactly this. |
| DSTM similar-artists fallback | `DSTM.pm` 213 | **No keyless equivalent** of `artist.getsimilar`. Since 0.9.77 an empty radio pool already falls back to the CF pool, so losing it degrades rather than breaks. |

**Alternative worth considering: ship a plugin-owned key.** MusicArtistInfo does exactly this —
`Common.pm` base64-obfuscates `api_key=c6abc51e847b91aba0de2ede33875e24` in `__DATA__` and scrubs it
from debug output (`_debug` strips `api_key=`). Free, non-commercial, and since every user runs their
own server on their own IP a shared key doesn't concentrate rate limits. Keeps all three fallbacks
with zero user setup; keep the settings field as an optional override.

**Recommendation:** own key + keep the field as an override. One small change versus building a
Wikipedia bio path, and it removes the field as a *requirement* immediately.

---

## 5. Suggested order

1. **3.1 token gates** — biggest user-facing win, smallest change, no cache bumps.
2. **4 Last.fm own-key** — one small change, removes the second credential.
3. **3.3 volume decision** — needs a call before any of 3.2 is worth writing.
4. **3.2 public-source rebuild** — the actual work.

Steps 1 and 2 alone mean **no user ever has to enter a credential**, with the only loss being
recommendation events for users who don't set a token. That may be enough on its own.

---

## 6. Test notes

- `tools/fetch_feed.py` needs the token by design — keep it, add a sibling that dumps the public
  sources so the two can be diffed for a real user (that diff is also the honest measure of what
  going token-free costs).
- Anti-test the merge: a token user must not get duplicated tracks when a pin arrives from both
  `feed/events` and `/pins/following`. `_followTrackKey` dedup should handle it — assert it.
- Measure the pin/loved/recommendation split for a real account before committing to §3.3 caps:

```
curl -s -H "Authorization: Token YOUR_TOKEN" \
  "https://api.listenbrainz.org/1/user/YOUR_NAME/feed/events?count=100" \
  | python3 -c "import sys,json,collections; print(collections.Counter(e['event_type'] for e in json.load(sys.stdin)['payload']['events']))"
```
