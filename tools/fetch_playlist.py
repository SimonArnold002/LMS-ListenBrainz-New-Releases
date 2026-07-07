#!/usr/bin/env python3
"""
fetch_playlist.py — dump a user's created-for weekly playlists from the PUBLIC
ListenBrainz API, the same way API.pm does (getCreatedForPlaylists ->
getPlaylistTracks -> _parsePlaylistTracks).

Shows, per playlist, every track's artist (= JSPF creator), title and
recording_mbid — i.e. EXACTLY what the plugin's matcher receives on the
ListenBrainz side. Read-only; needs only a username (no token to read).

    python3 fetch_playlist.py <listenbrainz-username>

Output is also written as `match_check`-ready left-hand sides so you can paste
the file tags after each '||':

    Artist | Title  ||  <fill in the local file's artist | title>
"""

import json, sys, urllib.request

BASE = "https://api.listenbrainz.org"

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "LBF-debug/1.0 ( simon )"})
    with urllib.request.urlopen(req, timeout=20) as f:
        return json.load(f)

def playlist_list(user):
    # GET /1/user/<user>/playlists/createdfor
    data = get(f"{BASE}/1/user/{user}/playlists/createdfor")
    out = []
    for entry in data.get("playlists", []):
        pl = entry.get("playlist", {})
        ident = pl.get("identifier", "") or ""
        mbid = ident.rstrip("/").rsplit("/", 1)[-1] if "/playlist/" in ident else ""
        if mbid:
            out.append((mbid, pl.get("title", "(untitled)")))
    return out

def playlist_tracks(mbid):
    # GET /1/playlist/<mbid>
    data = get(f"{BASE}/1/playlist/{mbid}")
    pl = data.get("playlist", {})
    tracks = []
    for t in pl.get("track", []):
        artist = t.get("creator", "")
        title = t.get("title", "")
        ident = t.get("identifier", "")
        if isinstance(ident, list):
            ident = ident[0] if ident else ""
        rec = ident.rstrip("/").rsplit("/", 1)[-1] if "/recording/" in ident else ""
        tracks.append((artist, title, rec))
    return pl.get("title", "(untitled)"), tracks

def main():
    if len(sys.argv) < 2:
        sys.exit("usage: python3 fetch_playlist.py <listenbrainz-username>")
    user = sys.argv[1]
    pls = playlist_list(user)
    if not pls:
        print(f"No created-for playlists found for {user!r} "
              "(check the username; these are the Weekly Jams/Exploration/Daily Jams lists).")
        return
    print(f"# {len(pls)} created-for playlist(s) for {user}\n")
    for mbid, title in pls:
        ptitle, tracks = playlist_tracks(mbid)
        print(f"## {ptitle}  [{mbid}]  — {len(tracks)} tracks")
        for artist, ttl, rec in tracks:
            tag = "" if rec else "  (no recording_mbid)"
            print(f"{artist} | {ttl}  ||  {tag}")
        print()

if __name__ == "__main__":
    main()
