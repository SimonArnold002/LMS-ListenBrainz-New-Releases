#!/usr/bin/env python3
"""
fetch_feed.py — dump a user's SOCIAL FEED (the timeline of events from the people
they follow) from the ListenBrainz API, so we can lock down the JSON shape before
writing the plugin's API::getFollowFeed parser against it.

Unlike fetch_playlist.py, the feed endpoint is PRIVATE — it needs the user's
ListenBrainz token (same one in the plugin's settings). Pass it as an argument or
in the LB_TOKEN environment variable:

    python3 fetch_feed.py <listenbrainz-username> <token>
    LB_TOKEN=xxxx python3 fetch_feed.py <listenbrainz-username>

It hits:  GET /1/user/<user>/feed/events?count=<n>
and reports:
  * a breakdown of how many of each event_type came back,
  * for the track-bearing events (recording_recommendation + recording_pin) —
    the recommender, artist, title and recording_mbid, as match_check-ready
    left-hand sides:  Artist | Title  ||

That last block is EXACTLY what the plugin's matcher would receive for a
"Recommended by People You Follow" playlist. Read-only.
"""

import json, os, sys, urllib.request
from collections import Counter

BASE = "https://api.listenbrainz.org"

# event_types that carry a single recommended/pinned recording (the ones we'd
# turn into playlist tracks). Everything else in the feed (listens, follows,
# notifications, reviews) is ignored for playlist purposes.
TRACK_EVENTS = ("recording_recommendation", "recording_pin")


def get(url, token):
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Token {token}",
            "User-Agent": "LBF-debug/1.0 ( simon )",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as f:
        return json.load(f)


def feed_events(user, token, count=75):
    # GET /1/user/<user>/feed/events?count=<n>
    data = get(f"{BASE}/1/user/{user}/feed/events?count={count}", token)
    payload = data.get("payload", data)   # events live under payload.events
    return payload.get("events", [])


def _first_mbid(*candidates):
    """Return the first candidate that looks like a bare recording_mbid."""
    for c in candidates:
        if isinstance(c, list):
            c = c[0] if c else ""
        if isinstance(c, str) and len(c) == 36 and c.count("-") == 4:
            return c.lower()
    return ""


def track_from_event(ev):
    """Pull (recommender, artist, title, recording_mbid) out of a track event.

    ListenBrainz stashes the recording under metadata.track_metadata for
    recommendations, and the SAME shape (sometimes nested under a pin) for pins.
    The recording_mbid can be in additional_info OR in the mbid_mapping, so we
    look in both.
    """
    meta = ev.get("metadata", {}) or {}
    # A pin event wraps the recording one level deeper in some API versions.
    tm = meta.get("track_metadata") or (meta.get("pin", {}) or {}).get("track_metadata") or {}
    ai = tm.get("additional_info", {}) or {}
    mapping = tm.get("mbid_mapping", {}) or {}

    artist = tm.get("artist_name", "") or ""
    title = tm.get("track_name", "") or ""
    rec = _first_mbid(
        ai.get("recording_mbid"),
        mapping.get("recording_mbid"),
        meta.get("recording_mbid"),
        (meta.get("pin", {}) or {}).get("recording_mbid"),
    )
    recommender = ev.get("user_name", "") or ""
    return recommender, artist, title, rec


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: python3 fetch_feed.py <listenbrainz-username> [<token>]  "
                 "(or set LB_TOKEN)")
    user = sys.argv[1]
    token = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("LB_TOKEN", "")
    if not token:
        sys.exit("A token is required for the feed endpoint — pass it as arg 2 "
                 "or set LB_TOKEN.")

    try:
        events = feed_events(user, token)
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} from feed endpoint: {e.reason} "
                 f"(401/403 => bad/expired token or wrong username)")

    if not events:
        print(f"No feed events for {user!r} — are you following anyone who has "
              "recommended/pinned tracks?")
        return

    kinds = Counter(ev.get("event_type", "?") for ev in events)
    print(f"# {len(events)} feed event(s) for {user}")
    for k, n in kinds.most_common():
        print(f"#   {n:>3}  {k}")
    print()

    track_evs = [ev for ev in events if ev.get("event_type") in TRACK_EVENTS]
    if not track_evs:
        print("# No recording_recommendation / recording_pin events in this window "
              "— nothing to build a playlist from right now.")
        return

    print(f"## {len(track_evs)} recommended/pinned track(s) "
          "(match_check-ready — fill in the local file tags after each '||')\n")
    seen = set()
    for ev in track_evs:
        who, artist, title, rec = track_from_event(ev)
        dup = "  (dup mbid)" if rec and rec in seen else ""
        if rec:
            seen.add(rec)
        norec = "" if rec else "  (no recording_mbid)"
        etype = ev.get("event_type", "")
        print(f"{artist} | {title}  ||    "
              f"# via {who} [{etype}]{norec}{dup}")


if __name__ == "__main__":
    main()
