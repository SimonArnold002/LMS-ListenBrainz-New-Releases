# Spotify rate limits, and what LBF does about them

**Status: built 1.0.1, 2026-09-16. Not installed, not verified live.**
Record of what Spotify's limit actually is, what it looked like on the live server, and the
design that came out of it. The decisions are also in the ledger (`CLAUDE.md`, "Spotify
back-off"); this is the working it shows.

---

## 1. The limit, from Spotify's own documentation

<https://developer.spotify.com/documentation/web-api/concepts/rate-limits>

- Calls are counted **per app (client id)** over a **rolling 30-second window**.
- The threshold is **not published**, and is lower for an app in **Development mode** than one
  granted Extended Quota.
- Over the limit the API answers **429** with a **`Retry-After`** header, in seconds.
- Spotify's own advice: honour `Retry-After`, batch where an endpoint allows it, cache, and
  fetch lazily rather than up front.

**The part that matters for a plugin: the quota is not this server's alone.** Spotty's client id
is the `iconCode` pref, and its default (`Plugins::Spotty::Plugin::initIcon`, checked by
`hasDefaultIcon`) is ONE app shared by every Spotty install that has not set its own. So a warm
here spends a window shared with strangers, and a user who has set their own id is in Development
mode on their own — a lower limit, not a higher one.

## 2. What Spotty already does — read from its source, not assumed

`michaelherger/Spotty-Plugin`, master, `API.pm`:

- `_gotResponse` / `_gotError` route any 429 to **`error429`**, which sets the cache flag
  `spotty_rate_limit_exceeded` for `Retry-After` seconds (**5** if the header is missing).
- While that flag stands, **`getToken` returns `-429` and no request is sent at all** — for
  every caller on the server, the user's own Spotify browsing included.
- `hasError429` exposes the state, and is **cleared by the next successful response**.

**So the backoff itself is already Spotty's job, and LBF must not add a second one.** What LBF
has to get right is how it READS a refusal.

**What a refusal looks like from here:** `_gotError` hands back
`{ name => PLUGIN_SPOTTY_ERROR_429, type => 'text' }`, the search extractor reads
`{albums}{items}` out of it, finds nothing, and the Pipeline calls back with **an empty
arrayref — byte-identical to a genuine zero-hit.** There is no error path. `undef` never
reaches us from this adapter.

**Request cost, for the record:** LBF asks for 50 albums (equal to `SPOTIFY_LIMIT`) and 20
tracks, so each search is ONE request with no paging, and Spotty caches a GET for its
`max-age`, minimum 60s.

## 3. What the live server showed (plex, 2026-09-15)

One day of `log.txt`:

| | count |
|---|---|
| `Plugins::Spotty::API::error429` | **20** (`Retry-After` 2-7s) |
| Spotty `502 Bad Gateway` | **191** |

All on `api.spotify.com/v1/search`, in two bursts (15:14, 15:22) plus one on
`browse/featured-playlists`. The sibling Pitchfork plugin measured the same thing from the other
end the same day: 184 search 502s inside a minute on a cold warm with Spotify ranked first.

**Spotty IS installed on the rig.** Several notes in this repo still say it is not; they are
stale and were written before it was.

## 4. The design

### 4.1 A refusal is stamped, not inferred

`_searchSpotify` / `_searchSpotifyTrack`: an **empty** answer while `hasError429` is set records
`$SPOTIFY_REFUSED_AT`. The outcome does not change — `_emptyResultIsError` already treats every
empty answer as inconclusive — so no TTL moves. The stamp is what lets the warm SEE it.

**Only an empty list is doubted.** A list with results in it is an answer whatever the flag says.

### 4.2 Our own clock, not Spotty's flag

`hasError429` clears on the next *successful* response, and at Spotify's default priority (5,
last) that can be many albums away — so the flag reads false while we are still being refused.
`SPOTIFY_BACKOFF_WINDOW` (30s from the last refusal) is ours and expires on its own.

### 4.3 The warm narrows; a view never does

- `_resolveTracks` takes **`paced => 1`**. Three warm resolves pass it — the playlist warm, and
  (since 1.0.3) `_resolveFollow` / `_resolveTrending` as `paced => $warm`; every view path does not.
  **`$warm` is `!$callback` read at ENTRY**: on a view's cold build both subs detach `$callback`
  (render the building row, then clear it) before resolving, so testing `$callback` at the resolve
  call would pace the view too. Until 1.0.3 the follow-feed and trending warms ran unpaced — trending
  at width 10 over 80 candidates, the widest resolve in the plugin (second review, 2026-09-16).
- While paced AND backing off: **one resolve at a time**, with **`PACED_TRACK_GAP` (2s)** after
  each LIVE one. A cache hit answers synchronously from inside the pump and is never slowed.
- **Two guards make "after each LIVE one" true (review, 2026-09-16).** `$pumping` is a
  re-entrancy guard: a synchronous (cached) completion neither recurses into the pump nor arms a
  timer — the loop that launched it carries on. `$gapTimer` is the ONE pending paced wakeup, and
  every live completion re-arms it (`killSpecific` + `setTimer`), so the next launch is always the
  gap after the LAST completion — including when several were in flight as the back-off began.
  Before this, every cached track armed its own 2s timer, and those strays later launched live
  searches straight after one another (40 cached + 10 live: a launch 0.2s after the previous
  search finished).
- The width is read **fresh on every pump**, the rule `_coverLimit` already follows, so a refusal
  arriving mid-pass bites at the next slot rather than the next pass. A dropping width never
  cancels anything in flight.
- **THREE pumps touch Spotify, not two.** This said "the album side is `_detailPriorityBusy`"
  until 1.0.3, and that sentence hid a whole pump for two review rounds:
  - `_resolveTracks` — the track side, via its `paced` option.
  - `_detailPriorityBusy` — the **`DetailWarm` queue's `pause` hook and nothing else**. It
    re-arms every 5s, well inside the window. It is one album-side consumer, not "the" one.
  - **`_buildAlbumsData`'s streaming gate** — the trending-albums pump, paced since 1.0.3. It
    calls `_findPlayable` directly rather than through `_resolveTracks`, so it never saw
    `paced`, and it never passes through the `DetailWarm` queue, so `_detailPriorityBusy`
    never gated it. It was a **writer** of `$SPOTIFY_REFUSED_AT` (through `_searchSpotify`)
    that never read it: 60 pooled albums per range, two ranges per warm, five wide.

  A fourth pump would need its own read of `_spotifyBackingOff` — the back-off is not
  something a new caller inherits.

**Always-on pacing is not on the table.** PFR built exactly that (its 0.9.36) and Simon rejected
it as far too slow: a cold pass went from about a minute to twenty or more. A healthy run must
pay nothing.

### 4.4 A refused search does not spend a retry attempt

This is the half PFR has no equivalent of, and the reason this is not a port.

LBF bounds an inconclusive miss with `MISS_RETRY_SCHEDULE` — three attempts at 1h / 6h / 24h,
then the miss becomes an ordinary durable no-match (`TRACK_NOMATCH_TTL` 7d,
`STREAM_NOMATCH_TTL` 1d). **A refusal is a search that was never sent**, so counting it retires a
track the service actually carries. For a **Spotify-only user** there is no other service to
answer instead, so during a storm *every* attempt is a refusal — the ordinary case, not an edge.

So a refusal gives the attempt back, at the **same rung**, in both the track and album paths, and
is **capped at `SPOTIFY_FREE_PASSES` (3)**. Past the cap it spends a real attempt like any other,
so a permanently rate-limited account still converges instead of re-searching for ever — which is
the loop the budget was written to bound (Simon's call; uncapped was offered and declined).

**The pass follows THAT search's refusal, never the back-off window (review, 2026-09-16).** The
Spotify adapters answer a refusal as `$collect->(undef, 'refused')`; each resolver's `$settle`
counts the tag into its own `$refused`, and `$cacheItem` / `$store` test that. The first build
tested `_spotifyBackingOff()` instead, so ANY inconclusive miss inside the 30s window — a search
Spotify really answered, or another service timing out — kept its attempt, giving up to three
extra searches per miss in a storm's wake. The window still drives the warm's pacing; it no longer
decides what a miss costs.

The count lives in the cached entry as `free`, beside `tries`, and the entry is still stored at
the **full** no-match TTL with its own `retry_at`: a short TTL would take the counts with it when
it expired, and the budget could never be spent.

## 5. What is deliberately NOT done

**PFR's `empty_unverified` is not ported.** When a higher-priority Spotify is refused and a lower
service matches, LBF still caches that match at the full `STREAM_FOUND_TTL` (7d) /
`TRACK_FOUND_TTL` (30d). PFR measured the cost live (17 rows pinned to Qobuz that Spotify
carries) and capped that case at a day.

It only bites when **Spotify is ranked above another service**. LBF defaults
`svc_priority_spotify => 5`, last, where nothing can win beneath it; Simon's rig leaves it there;
and the users this work is for have Spotify **only**, where there is no lower service to pin.
Re-raise with a user who ranks Spotify above another service — not as a symmetry argument.

## 6. Tests

`tools/t_spotifybackoff.pl` — 62 assertions (37 at build, +20 in the first 2026-09-16 review, +5 in
the second), sub bodies lifted verbatim and driven over a fake
clock, no LMS and no Spotty needed. Five sections: the refusal clock; the adapters stamping a
refusal and only a refusal; the retry budget (free passes, the cap, and that it still converges);
the paced pump (narrow while refused, full width otherwise, a view never narrowing, a refusal
biting mid-pass); and the prewarm pause. The review added §3b (the TRACK path's free pass, driving
the real `_findPlayableTrack`), the free pass keyed on the refusal tag in both paths with the
window held ON as the discriminator, the adapter's tag itself, and three pump properties: cached
answers arm no wakeup, the MEASURED gap between live launches across a 40-cached/10-live pass, and
one wakeup re-armed across several completions.

**Anti-tested five ways, each failing only its own checks:** the stamp removed 1; the paced width
ignored 4; the gap removed 2; the cap removed 2; the free passes removed entirely 7; the prewarm
pause removed 1. **Review fixes, anti-tested six ways:** the re-entrancy guard removed 1 (the
single re-armed wakeup absorbs the strays on its own, so only the timer count sees it); the re-arm
removed 2; both removed — the original code — 5, including the measured gap; the track free pass
back on the window 2; the album one 3; the adapter's tag dropped 1.

**Second review (1.0.3), §4b:** `_resolveFollow` is lifted and CALLED as the warm (paced) and as a
view (unpaced, although its callback is detached first); `_resolveTrending` is behind a follower
fan-out, so its read-before-detach order and `paced => $warm` are checked in source. Anti-tested five
ways, one failing check each: follow `$warm` read after the detach; follow `paced` dropped; trending
`paced` dropped; trending `paced => 1`; trending `$warm` read after the detach.

**Two harness traps, both of which cost a debugging pass:**

- `use constant X => $lifted` inside a package block resolves at **compile** time, when the value
  lifted from the source at runtime is still `undef` — so the constant becomes undef and every
  comparison against it is quietly false. Install such constants at runtime instead.
- `SingleFlight.pm` pulls in the **real `Time::HiRes`**, which overwrites a `sub time` compiled
  into that package earlier. The paced gap was then measured against the wall clock, where a 2s
  timer never comes due inside a suite. Override the glob *after* the require.

## 7. Verifying it live (owed)

Nothing here has been seen running. Once 1.0.3 is installed:

1. Watch `curl -s 'http://plex:9000/log.txt?lines=20000'` during a cold warm — the bare
   `log.txt` returns a tiny window.
2. Spotty's own `Plugins::Spotty::API::error429 … Access Rate limit exceeded` lines should now be
   followed by LBF's `Spotify search refused (Spotify is rate-limiting)`.
3. The warm should visibly slow for ~30s after one, then return to full width — in the playlist,
   follow-feed AND trending-tracks stages (the last two only from 1.0.3).
4. A track missed during a storm should carry `free` in its cache entry rather than a spent
   attempt — so it is still retried afterwards rather than held for a week.

To reproduce a storm deliberately: set every other service's priority to 0 (Spotify only) and
force a cold playlist re-resolve.
