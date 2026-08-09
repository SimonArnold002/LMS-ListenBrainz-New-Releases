# Hosted LMS-Community API (`mai-api`) — integration scope for LBF

**Status:** SCOPED, NOT STARTED. Investigated 2026-08-01. No code written.
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
but `score>=90` didn't disambiguate those either, so it's not a regression); keep it behind a pref so
users can opt out. `getArtistMbidByName` is a shared port source (DSC has a copy) but is NOT part of
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
  the MAI / Last.fm bio path (`_fetchArtistInfo`).
- **`relatedArtists`** is last.fm-similar, not MB "member of band".

---

## 5. Suggested build order (all behind the one request helper + header)

1. **Resolver refactor (§1)** — biggest win, no freshness dependency, works with the API as-is.
2. **Detail-page genres/cover via `/album` (§2)** with the MB fallback (§3) — lower-stakes, revives
   what `genre-sources-investigation.md` had parked. Gate on the daily-update rollout if we want the
   fallback to be genuinely rare.

No cache-shape changes are forced by any of this; bump the relevant keys only if a stored value's
content changes. Follow the repo's usual gates (`perl -c`, the relevant `tools/t_*.pl`) and the fleet
rules (no matcher change here, so `matcher_sync_check.py` is N/A).
