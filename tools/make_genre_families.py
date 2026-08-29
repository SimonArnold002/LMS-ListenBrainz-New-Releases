#!/usr/bin/env python3
"""Generate ListenBrainzFreshReleases/genre-families.txt — the genre -> top-level
family rollup shipped with the plugin.

WHY THIS EXISTS
---------------
MusicBrainz has no genre hierarchy. Verified 2026-07-26 against a mirror:
`genre/<mbid>?inc=genre-rels` -> "Not Found", and genre search -> "This hasn't been
implemented yet". What MB *does* publish is the full curated genre vocabulary via
`genre/all` (2177 names as of this writing). So a parent/child rollup has to be a
table we ship, and this script builds it.

The plugin shows the top-level FAMILY on the release lists (front page) and the
full, specific genres on the release detail page. This file feeds the first half.

HOW IT WORKS
------------
1. Pull the whole MB genre vocabulary from `genre/all`.
2. Assign a family by RULE: normalise separators, then match a family keyword as a
   whole word at the end or start ("progressive house" -> Electronic,
   "instrumental hip hop" -> Hip Hop). Measured to resolve ~52% of real genre
   occurrences on a live feed.
3. Apply OVERRIDES for everything the rule can't see -- the names that ARE a genre
   in their own right ("boom bap", "chillwave", "shoegaze"). Curated by frequency:
   only 244 distinct genres appeared across 400 live releases, and the top 100
   cover 84% of all occurrences, so a couple of hundred entries is effectively
   complete.
4. MODIFIERS are deliberately given NO family. Words like "instrumental" or
   "lo-fi" describe a treatment, not a family -- "instrumental" was the 5th most
   common genre in the sample. Leaving them unclassified lets the plugin fall
   through to the next genre on the release, so "instrumental, lo-fi hip hop"
   resolves to Hip Hop instead of to a meaningless bucket.

Run from the repo root:  python3 tools/make_genre_families.py
Then rebuild the zip. Genres with no family are omitted from the file; the plugin
falls back to displaying the genre itself, which is still better than nothing.
"""

import json
import re
import sys
import urllib.request

MB_BASES = [
    "http://plex:5000/ws/2/",              # local mirror: no rate limit
    "https://musicbrainz.org/ws/2/",       # fallback
]

OUT = "ListenBrainzFreshReleases/genre-families.txt"

# Top-level families, each with the keywords that imply it when they appear as a
# whole word at the start or end of a genre name.
FAMILIES = {
    "Rock":        ["rock", "grunge", "shoegaze", "britpop"],
    "Pop":         ["pop"],
    "Electronic":  ["electronic", "electronica", "house", "techno", "trance", "electro",
                    "ambient", "idm", "dubstep", "garage", "breakbeat", "breaks", "jungle",
                    "drum and bass", "dnb", "edm", "synthwave", "hardcore techno", "gabber",
                    "downtempo", "trip hop", "chiptune", "industrial", "ebm"],
    "Hip Hop":     ["hip hop", "hip-hop", "rap", "trap", "grime", "drill"],
    "Jazz":        ["jazz", "bebop", "swing"],
    "Classical":   ["classical", "opera", "baroque", "symphony", "chamber music"],
    "Folk":        ["folk", "bluegrass", "americana"],
    "Country":     ["country"],
    "Blues":       ["blues"],
    "Metal":       ["metal", "metalcore", "grindcore", "deathcore"],
    "Punk":        ["punk", "hardcore", "emo", "ska"],
    "R&B":         ["r&b", "rnb", "contemporary r&b"],
    "Soul":        ["soul", "motown"],
    "Funk":        ["funk"],
    "Reggae":      ["reggae", "dub", "dancehall", "ragga"],
    "Latin":       ["latin", "salsa", "samba", "bossa nova", "tango", "cumbia", "reggaeton"],
    "Experimental": ["experimental", "noise", "avant-garde", "musique concrete"],
    "Soundtrack":  ["soundtrack", "film score", "video game music"],
    "Gospel":      ["gospel", "worship"],
    "Spoken Word": ["spoken word", "poetry", "audiobook"],
}

# Genres that ARE a family member but share no keyword with it. Curated from the
# live-feed frequency list first, then filled out with the well-known names.
OVERRIDES = {
    # --- Electronic
    "chillwave": "Electronic", "vaporwave": "Electronic", "drone": "Electronic",
    "barber beats": "Electronic", "plunderphonics": "Electronic", "future bass": "Electronic",
    "hyperpop": "Electronic", "glitch": "Electronic", "witch house": "Electronic",
    "dark electro": "Electronic", "electro-industrial": "Electronic", "aggrotech": "Electronic",
    "footwork": "Electronic", "juke": "Electronic", "bassline": "Electronic",
    "hardstyle": "Electronic", "hands up": "Electronic", "psytrance": "Electronic",
    "goa": "Electronic", "acid": "Electronic", "acidcore": "Electronic",
    "big beat": "Electronic", "nu jazz": "Electronic", "illbient": "Electronic",
    "dance": "Electronic", "eurodance": "Electronic", "italo disco": "Electronic",
    "disco": "Electronic", "nu-disco": "Electronic", "hi-nrg": "Electronic",
    "new age": "Electronic", "berlin school": "Electronic", "dark ambient": "Electronic",
    "lounge": "Electronic", "chillout": "Electronic", "balearic": "Electronic",
    "wonky": "Electronic", "future garage": "Electronic", "2-step": "Electronic",
    "3-step": "Electronic", "2 tone": "Punk",
    # --- Hip Hop
    "boom bap": "Hip Hop", "turntablism": "Hip Hop", "g-funk": "Hip Hop",
    "crunk": "Hip Hop", "horrorcore": "Hip Hop", "phonk": "Hip Hop",
    "cloud rap": "Hip Hop", "afroswing": "Hip Hop", "afro trap": "Hip Hop",
    # --- Rock
    "post-rock": "Rock", "math rock": "Rock", "krautrock": "Rock", "psychedelia": "Rock",
    "new wave": "Rock", "no wave": "Rock", "grunge": "Rock", "surf": "Rock",
    "rockabilly": "Rock", "power pop": "Rock", "jam band": "Rock", "stoner": "Rock",
    "sludge": "Metal", "doom": "Metal", "djent": "Metal", "nu metal": "Metal",
    # --- Pop
    "j-pop": "Pop", "k-pop": "Pop", "c-pop": "Pop", "cantopop": "Pop", "mandopop": "Pop",
    "city pop": "Pop", "schlager": "Pop", "chanson": "Pop", "yacht rock": "Pop",
    "bubblegum": "Pop", "teen pop": "Pop", "europop": "Pop",
    # --- Folk / Country / Blues
    "singer-songwriter": "Folk", "celtic": "Folk", "sea shanty": "Folk",
    "old-time": "Folk", "outlaw country": "Country", "honky tonk": "Country",
    "delta blues": "Blues", "boogie-woogie": "Blues",
    # --- Jazz / Soul
    "fusion": "Jazz", "ragtime": "Jazz", "dixieland": "Jazz",
    "neo soul": "Soul", "doo-wop": "Soul", "new jack swing": "R&B",
    # --- World / other
    "afrobeat": "World", "afrobeats": "World", "highlife": "World", "soukous": "World",
    "flamenco": "World", "fado": "World", "klezmer": "World", "qawwali": "World",
    "raga": "World", "gamelan": "World", "enka": "World", "bhangra": "World",
    "zouk": "World", "kizomba": "World", "mbalax": "World", "rai": "World",
    "throat singing": "World", "gagaku": "World",
    "musical theatre": "Soundtrack", "library music": "Soundtrack",
    "field recording": "Experimental", "harsh noise wall": "Experimental",
    "power electronics": "Experimental", "lowercase": "Experimental",
    # --- second pass: the unmapped tail the first generated run reported
    "breakcore": "Electronic", "speedcore": "Electronic", "club": "Electronic",
    "wave": "Electronic", "dariacore": "Electronic", "neurofunk": "Electronic",
    "funktronica": "Electronic", "chillsynth": "Electronic", "dreampunk": "Electronic",
    "cyberpunk": "Electronic", "darkwave": "Electronic", "minimal wave": "Electronic",
    "coldwave": "Rock", "crossover prog": "Rock", "blackgaze": "Metal",
    "brazilian phonk": "Hip Hop", "orchestral": "Classical", "filmi": "World",
}

# Deliberately NO family: these describe a treatment or era, not a family. Leaving
# them out lets the plugin fall through to the next genre on the release.
MODIFIERS = {
    "instrumental", "lo-fi", "hi-fi", "acoustic", "live", "remix", "cover",
    "demo", "a cappella", "vocal", "minimal", "maximal", "contemporary",
    "traditional", "modern", "classic", "alternative", "indie", "underground",
    "progressive", "experimental music", "christmas", "holiday", "novelty",
    "soundtrack music", "background music", "easy listening",
}


def fetch_vocabulary():
    for base in MB_BASES:
        names, off = [], 0
        try:
            while True:
                url = f"{base}genre/all?fmt=json&limit=100&offset={off}"
                with urllib.request.urlopen(url, timeout=25) as f:
                    d = json.load(f)
                names += [g["name"] for g in d.get("genres", [])]
                off += 100
                if off >= d.get("genre-count", 0):
                    break
            if names:
                print(f"  vocabulary: {len(names)} genres from {base}")
                return names
        except Exception as e:
            print(f"  {base} failed ({e}); trying next")
    sys.exit("could not fetch the MusicBrainz genre vocabulary from any base")


def norm(name):
    """Lowercase and flatten separators so 'synth-pop' can match the 'pop' keyword."""
    return re.sub(r"[\s\-_/]+", " ", name.lower()).strip()


# The tables above are written the way humans spell genres ("lo-fi", "post-rock"),
# but every lookup goes through norm(), which flattens hyphens. Normalise the keys
# once here or the hyphenated entries never match — "lo-fi" normalises to "lo fi"
# and silently missed its own MODIFIERS entry (it was the 2nd most common genre in
# the sample, so this was worth catching).
OVERRIDES = {norm(k): v for k, v in OVERRIDES.items()}
MODIFIERS = {norm(k) for k in MODIFIERS}


def family_for(name):
    n = norm(name)
    if n in MODIFIERS:
        return None
    if n in OVERRIDES:
        return OVERRIDES[n]
    # exact family-keyword match, then whole-word suffix, then whole-word prefix
    for fam, keys in FAMILIES.items():
        for k in keys:
            kn = norm(k)
            if n == kn:
                return fam
    for fam, keys in FAMILIES.items():
        for k in keys:
            kn = norm(k)
            if n.endswith(" " + kn) or n.startswith(kn + " "):
                return fam
    return None


def main():
    print("Fetching the MusicBrainz genre vocabulary...")
    names = fetch_vocabulary()

    mapped = {}
    for n in names:
        fam = family_for(n)
        if fam:
            mapped[norm(n)] = fam
    # OVERRIDES may name genres MB spells differently (or that only reach us via
    # Last.fm later) — keep them all, they cost one line each.
    for k, v in OVERRIDES.items():
        mapped.setdefault(norm(k), v)

    # Emit the WHOLE vocabulary, not just what rolled up. The file is two things at
    # once: the rollup table, and the authoritative list of "is this string actually
    # a genre?" -- which is what gates the Last.fm tier (phase 3). Last.fm tags are
    # full of languages, countries, moods and junk ("japanese", "seen live",
    # "brainrot"); accepting only names MusicBrainz recognises is what makes them
    # usable. A genre we have no family for is still a genre, hence '?'.
    rows = dict(mapped)
    for m in MODIFIERS:
        rows.setdefault(m, "-")
    unknown = 0
    for n in names:
        if norm(n) not in rows:
            rows[norm(n)] = "?"
            unknown += 1

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("# genre<TAB>family — GENERATED by tools/make_genre_families.py, do not hand-edit.\n")
        f.write("# Every name MusicBrainz recognises as a genre is listed, so this file doubles as the\n")
        f.write("# vocabulary that gates Last.fm tags. Family values:\n")
        f.write("#   <Name>  a top-level family\n")
        f.write("#   -       a MODIFIER: describes a treatment, not a style (instrumental, lo-fi).\n")
        f.write("#           Skipped when choosing a family AND when listing sub-genres.\n")
        f.write("#   ?       a real genre with no family yet. Still worth showing to the user --\n")
        f.write("#           that is the whole reason '-' and '?' are different values.\n")
        for g in sorted(rows):
            f.write(f"{g}\t{rows[g]}\n")
    print(f"  wrote {OUT}: {len(rows)} vocabulary entries — "
          f"{len(mapped)} in {len(set(mapped.values()))} families, "
          f"{len(MODIFIERS)} modifiers, {unknown} family-less")

    # Report coverage against what a real feed actually contains, if available.
    try:
        freq = json.load(open("tools/genre_freq.json"))
    except Exception:
        print("  (no tools/genre_freq.json — skipping the coverage report)")
        return
    total = sum(c for _, c in freq)
    hit = sum(c for g, c in freq if norm(g) in mapped)
    mods = sum(c for g, c in freq if norm(g) in MODIFIERS)
    print(f"\nCoverage against {total} real genre occurrences:")
    print(f"  mapped to a family : {hit} ({100*hit/total:.0f}%)")
    print(f"  modifiers (no family, fall through) : {mods} ({100*mods/total:.0f}%)")
    miss = [(g, c) for g, c in freq if norm(g) not in mapped and norm(g) not in MODIFIERS]
    print(f"  unmapped : {sum(c for _, c in miss)} ({100*sum(c for _, c in miss)/total:.0f}%)")
    if miss:
        print("  top unmapped (add to OVERRIDES if they matter):")
        for g, c in miss[:20]:
            print(f"     {c:4d}  {g}")


if __name__ == "__main__":
    main()
