#!/usr/bin/env python3
"""
fetch_trending.py — prototype + debug tool for the "People You Follow → What's
Trending" list. It implements the SAME aggregation the plugin's
Browse::_buildTrending will use, against the live ListenBrainz API, so the ranking
can be validated on real data before (and after) the Perl is wired up.

All three endpoints are PUBLIC — no token needed:
    GET /1/user/<user>/following
    GET /1/stats/user/<follower>/recordings?range=<range>   (204 if none/private)
    GET /1/metadata/recording/?recording_mbids=<csv>&inc=release   (track -> album)

Usage:
    python3 fetch_trending.py <listenbrainz-username> [range] [max-tracks]
    # range defaults to 'week' (rolling 7 days); try 'month'/'year' if a week is thin.

Algorithm (one-follower-one-vote / equal weight — "what are they ALL listening to"):
  1. list who <user> follows;
  2. per follower, pull their top recordings for <range> (capped equally);
  3. map every recording -> release_group_mbid (its ALBUM, editions collapsed);
  4. tally per album:  album breadth = # DISTINCT followers who played ANY of its
     tracks;  per-track breadth = # distinct followers who played that track;
  5. rank albums by breadth (tie-break: rep-track breadth, then total plays) — a
     heavy/single-track listener still counts once per album, so they can't skew it;
  6. represent each album by its highest-breadth track (the one the circle converges
     on); singles/EPs are 1-track albums, captured the same way;
  7. artist-diversify (one album per artist first; top up with repeats only if a lean
     range leaves < max), cap at <max-tracks>.
Read-only. Owned-track exclusion is the plugin's job (needs the local library).
"""

import json, sys, urllib.request, urllib.error, urllib.parse
from collections import defaultdict

BASE = "https://api.listenbrainz.org"
UA = "LBF-debug/1.0 ( simon.arnold@unionvfx.com )"
PER_FOLLOWER_CAP = 100   # equal cap per follower so a mega-listener can't dominate
METADATA_CHUNK = 50


def _get(url):
    """GET url -> (status, parsed-json-or-None). 204/empty -> (status, None)."""
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=25) as f:
            body = f.read()
            if not body:
                return f.status, None
            return f.status, json.loads(body)
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception as e:
        print(f"  ! {url}: {e}", file=sys.stderr)
        return 0, None


def get_following(user):
    _, d = _get(f"{BASE}/1/user/{urllib.parse.quote(user)}/following")
    if not d:
        return []
    lst = d.get("following") or d.get("payload", {}).get("following") or []
    out = []
    for u in lst:
        out.append(u if isinstance(u, str) else (u.get("musicbrainz_id") or u.get("user_name")))
    return [u for u in out if u]


def get_top_recordings(user, rng):
    st, d = _get(f"{BASE}/1/stats/user/{urllib.parse.quote(user)}/recordings?range={rng}&count={PER_FOLLOWER_CAP}")
    if st == 204 or not d:
        return []
    return d.get("payload", {}).get("recordings", []) or []


def primary_artist(row):
    a = row.get("artists")
    if isinstance(a, list) and a and a[0].get("artist_mbid"):
        return a[0]["artist_mbid"]
    am = row.get("artist_mbids")
    return am[0] if isinstance(am, list) and am else None


def map_to_release_groups(mbids):
    """recording_mbid -> {'rg': release_group_mbid, 'album': name} via inc=release."""
    out = {}
    mbids = [m for m in mbids if m]
    for i in range(0, len(mbids), METADATA_CHUNK):
        chunk = ",".join(mbids[i:i + METADATA_CHUNK])
        _, d = _get(f"{BASE}/1/metadata/recording/?inc=release&recording_mbids={urllib.parse.quote(chunk)}")
        if not isinstance(d, dict):
            continue
        for mbid, entry in d.items():
            rel = (entry or {}).get("release") or {}
            out[mbid.lower()] = {"rg": (rel.get("release_group_mbid") or "").lower(),
                                 "album": rel.get("name") or ""}
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    user = sys.argv[1]
    rng = sys.argv[2] if len(sys.argv) > 2 else "week"
    maxn = int(sys.argv[3]) if len(sys.argv) > 3 else 50

    print(f"# Trending for what {user}'s follows are playing — range={rng}\n")
    followers = get_following(user)
    print(f"following: {len(followers)} user(s)")
    if not followers:
        return

    # rg -> {followers:set, plays:int, artist, artist_mbid, album,
    #        tracks: {recording_mbid: {followers:set, plays:int, title, artist}}}
    rg_agg = defaultdict(lambda: {"followers": set(), "plays": 0, "artist": "",
                                  "artist_mbid": "", "album": "", "tracks": {}})
    contributing = 0
    all_recs = {}          # recording_mbid -> a sample row (for the RG map)
    per_follower = {}      # fetch each follower's stats ONCE, reuse below

    for fu in followers:
        recs = get_top_recordings(fu, rng)
        per_follower[fu] = recs
        if recs:
            contributing += 1
        for r in recs:
            rm = (r.get("recording_mbid") or "").lower()
            if rm:
                all_recs.setdefault(rm, r)

    print(f"followers with {rng} stats: {contributing}/{len(followers)}   "
          f"distinct recordings: {len(all_recs)}")

    rgmap = map_to_release_groups(list(all_recs.keys()))
    mapped = sum(1 for v in rgmap.values() if v["rg"])
    print(f"recording->release-group map: {mapped}/{len(all_recs)} resolved to an album\n")

    # Attribute each follower's plays to albums/tracks (one vote per follower).
    for fu in followers:
        for r in per_follower[fu]:
            rm = (r.get("recording_mbid") or "").lower()
            title = r.get("track_name") or ""
            artist = r.get("artist_name") or ""
            plays = int(r.get("listen_count") or 0)
            info = rgmap.get(rm, {})
            rg = info.get("rg") or ("t:" + (artist + "|" + title).lower())  # fallback key
            tkey = rm or ("t:" + (artist + "|" + title).lower())

            a = rg_agg[rg]
            a["followers"].add(fu)
            a["plays"] += plays
            a["artist"] = a["artist"] or artist
            a["artist_mbid"] = a["artist_mbid"] or (primary_artist(r) or "")
            a["album"] = a["album"] or info.get("album") or r.get("release_name") or ""
            t = a["tracks"].setdefault(tkey, {"followers": set(), "plays": 0,
                                              "title": title, "artist": artist})
            t["followers"].add(fu)
            t["plays"] += plays

    # Rank albums by breadth; represent each by its highest-breadth track.
    ranked = []
    for rg, a in rg_agg.items():
        rep = max(a["tracks"].values(),
                  key=lambda t: (len(t["followers"]), t["plays"]))
        ranked.append((len(a["followers"]), len(rep["followers"]), a["plays"], a, rep))
    ranked.sort(key=lambda x: (x[0], x[1], x[2]), reverse=True)

    # Artist-diversify: one album per primary artist first, then top up.
    picked, seen_artist, leftovers = [], set(), []
    for breadth, rbreadth, plays, a, rep in ranked:
        am = a["artist_mbid"] or ("name:" + a["artist"].lower())
        if am in seen_artist:
            leftovers.append((breadth, rbreadth, plays, a, rep))
            continue
        seen_artist.add(am)
        picked.append((breadth, rbreadth, plays, a, rep))
        if len(picked) >= maxn:
            break
    for row in leftovers:
        if len(picked) >= maxn:
            break
        picked.append(row)

    print(f"== What's Trending — top {min(maxn, len(picked))} "
          f"(of {len(ranked)} albums across your circle) ==")
    print(f"{'#':>2}  {'flwrs':>5} {'plays':>6}  Artist — Track  (album)")
    for i, (breadth, rbreadth, plays, a, rep) in enumerate(picked, 1):
        print(f"{i:>2}  {breadth:>5} {plays:>6}  {rep['artist']} — {rep['title']}"
              f"  ({a['album']})")


if __name__ == "__main__":
    main()
