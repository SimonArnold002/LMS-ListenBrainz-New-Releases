#!/usr/bin/env python3
"""
match_check.py — faithful port of Browse.pm's local-track matcher.

Ports _norm / _artistMatch / _trackMatches so you can paste a ListenBrainz
playlist track (what the plugin is trying to match) against a local library
file (how the user actually tagged it) and see the EXACT verdict — and, on a
MISS, which rule rejected it.

This is the same comparison _findLocalTrack does in Tier 2 (the artist+title
fallback used when there's no MBID match). It is NOT a streaming-service test.

Input (one comparison per line, blank lines / #comments ignored):

    LB_artist | LB_title  ||  file_artist | file_title

Example:
    Caribou | Volume  ||  Caribou | Volume (Four Tet Remix)
    Floating Points feat. Pharoah Sanders | Movement 1  ||  Floating Points | Movement 1

Run with no input to execute the built-in demonstration cases:
    python3 match_check.py

Read pairs from a file:
    python3 match_check.py pairs.txt

Or pipe them in:
    pbpaste | python3 match_check.py
"""

import re, sys

# --- faithful ports of Browse.pm -------------------------------------------

# Perl: $s =~ s/[\(\[].*?[\)\]]//g;  (non-greedy, drops (...) and [...])
_BRACKET = re.compile(r'[\(\[].*?[\)\]]')
# Perl: $s =~ s/[^\p{Alnum}]+/ /g;  (keep Unicode alphanumerics only)
#   Python \w is Unicode and includes '_', which Perl \p{Alnum} excludes,
#   so strip underscore too: [\W_]+ == [^\p{Alnum}]+ for our purposes.
_NONALNUM = re.compile(r'[\W_]+', re.UNICODE)

# Diacritic folding. SHIPPED in Browse.pm _norm as of 0.9.57 (é->e, ñ->n, ø->o,
# Turkish ı->i, ß->ss…) so accented tags match plain-ASCII spellings. Default ON to
# stay a faithful port; --fold turns it into a compare mode (folded vs the pre-0.9.57
# unfolded behaviour) so you can see which misses folding rescues.
FOLD = True

# Atomic Latin letters with no combining-mark decomposition (NFD can't split them),
# mapped to their ASCII base. Lower-case only — norm() lc()s before folding, matching
# Browse.pm's %FOLD.
_FOLD_MAP = str.maketrans({
    'ı': 'i', 'ł': 'l', 'ø': 'o', 'ð': 'd', 'đ': 'd',
    'þ': 'th', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'ħ': 'h',
})

def _fold(s):
    """Port of _norm's diacritic fold: NFD, drop ONLY the Latin combining-mark block
    (U+0300–036F), re-compose (NFC) so non-Latin base+mark is restored (e.g. Japanese
    voiced kana ば = は+U+3099 stays ば), then map the atomic Latin letters. Expects
    already-lowercased input, as Browse.pm does (lc before fold)."""
    import unicodedata
    s = unicodedata.normalize('NFD', s)
    s = ''.join(c for c in s if not ('\u0300' <= c <= '\u036f'))
    s = unicodedata.normalize('NFC', s)
    return s.translate(_FOLD_MAP)

def norm(s):
    """Port of _norm: lowercase, FOLD diacritics, drop bracketed qualifiers +
    punctuation, collapse whitespace. (Python strings are already real Unicode, so
    the Perl utf8::decode octet-guard isn't needed here.)"""
    if s is None:
        s = ''
    s = s.lower()
    if FOLD:
        s = _fold(s)
    s = _BRACKET.sub('', s)
    s = _NONALNUM.sub(' ', s)
    return s.strip()

def artist_match(a, b):
    """Port of _artistMatch: every token of the SMALLER set must appear in
    the bigger set (order-independent, tolerates feat./& vs , and partial
    credits). a, b are already normalised."""
    if a == '' or b == '':
        return False
    at = set(a.split())
    bt = set(b.split())
    small, big = (at, bt) if len(at) <= len(bt) else (bt, at)
    return small.issubset(big)

def track_matches(pl_artist_norm, pl_title_norm, file_artist, file_title):
    """Port of _trackMatches($artistNorm,$titleNorm,$candArtist,$candTitle).
    First two args are the PLAYLIST track (already normalised); last two are
    the candidate LOCAL FILE (raw, normalised inside). Returns (bool, reason)."""
    if len(pl_title_norm) < 2:
        return False, f"playlist title too short after norm ({pl_title_norm!r} < 2 chars)"
    t = norm(file_title)
    if t == '':
        return False, "file title normalised to empty"
    # t must EQUAL or be a word-prefixed-by the playlist title.
    # Perl: $t eq $titleNorm || index($t, "$titleNorm ") == 0
    if not (t == pl_title_norm or t.startswith(pl_title_norm + ' ')):
        why = "title mismatch"
        if pl_title_norm.startswith(t + ' ') or pl_title_norm == t:
            why = ("title mismatch — the FILE title is SHORTER than the playlist "
                   "title; the rule requires the file title to start WITH the "
                   "playlist title, not the other way round")
        return False, (f"{why}: file {t!r} vs playlist {pl_title_norm!r}")
    if pl_artist_norm == '':
        ok = (t == pl_title_norm)
        return ok, ("playlist artist empty; exact-title-only required "
                    + ("(equal → OK)" if ok else "(only a prefix, not equal → MISS)"))
    fa = norm(file_artist)
    if artist_match(pl_artist_norm, fa):
        return True, "title + artist both matched"
    return False, (f"artist mismatch: playlist {pl_artist_norm!r} vs file {fa!r} "
                   f"(tokens {set(pl_artist_norm.split())} not a subset/superset "
                   f"of {set(fa.split())})")

# --- driver ----------------------------------------------------------------

def _eval(lb_artist, lb_title, file_artist, file_title):
    """Run the matcher under the CURRENT global FOLD setting."""
    pa, pt = norm(lb_artist), norm(lb_title)
    ok, reason = track_matches(pa, pt, file_artist, file_title)
    return ok, reason, pa, pt, norm(file_artist), norm(file_title)

def check(lb_artist, lb_title, file_artist, file_title, compare=False):
    """Print the verdict. Plain run = SHIPPED behaviour (folding on since 0.9.57).
    With compare=True, evaluate under BOTH the pre-0.9.57 UNFOLDED _norm and the
    shipped FOLDED _norm, and flag misses the folding rescues. Returns
    (shipped_ok, unfolded_ok_or_None)."""
    global FOLD
    saved = FOLD

    if not compare:
        FOLD = True   # faithful pass = shipped _norm (folding on)
        ok, reason, pa, pt, fa, ft = _eval(lb_artist, lb_title, file_artist, file_title)
        FOLD = saved
        flag = "MATCH" if ok else "MISS "
        print(f"[{flag}] LB:  {lb_artist!r} — {lb_title!r}")
        print(f"        file: {file_artist!r} — {file_title!r}")
        print(f"        norm  LB   : artist={pa!r}  title={pt!r}")
        print(f"        norm  file : artist={fa!r}  title={ft!r}")
        print(f"        -> {reason}\n")
        return ok, None

    # Compare: pre-0.9.57 unfolded pass vs the shipped folded pass.
    FOLD = False
    uok, ureason, upa, upt, ufa, uft = _eval(lb_artist, lb_title, file_artist, file_title)
    FOLD = True
    ok, reason, pa, pt, fa, ft = _eval(lb_artist, lb_title, file_artist, file_title)
    FOLD = saved

    rescued = (not uok) and ok
    uflag = "MATCH" if uok else "MISS "
    flag  = "MATCH" if ok  else "MISS "
    tag = "  <== RESCUED BY FOLDING" if rescued else ""
    print(f"[unfolded:{uflag} | shipped:{flag}]{tag}")
    print(f"        LB:  {lb_artist!r} — {lb_title!r}")
    print(f"        file: {file_artist!r} — {file_title!r}")
    print(f"        unfolded norm : LB({upa!r},{upt!r})  file({ufa!r},{uft!r})")
    if rescued or (pa, pt, fa, ft) != (upa, upt, ufa, uft):
        print(f"        shipped  norm : LB({pa!r},{pt!r})  file({fa!r},{ft!r})")
    print(f"        -> unfolded: {ureason}")
    if ok != uok:
        print(f"        -> shipped : {reason}")
    print()
    return ok, uok

DEMO = [
    # (lb_artist, lb_title, file_artist, file_title)  -- illustrative cases
    ("Caribou", "Volume", "Caribou", "Volume"),                       # exact
    ("Caribou", "Volume", "Caribou", "Volume (Four Tet Remix)"),      # file has extra qualifier -> OK
    ("Floating Points feat. Pharoah Sanders", "Movement 1",
     "Floating Points", "Movement 1"),                                # feat. on LB only -> token subset OK
    ("Beyoncé", "Cuff It", "Beyonce", "Cuff It"),                     # accent -> norm differs? (é vs e)
    ("Sufjan Stevens", "Should Have Known Better",
     "Sufjan Stevens", "Should Have Known"),                          # file title SHORTER -> MISS
    ("P!nk", "So What", "Pink", "So What"),                          # stylised punctuation
    ("The Beatles", "Come Together", "Beatles", "Come Together"),     # missing 'The' -> subset OK
]

def main():
    args = [a for a in sys.argv[1:]]
    compare = '--fold' in args
    args = [a for a in args if a != '--fold']

    lines = None
    if args:
        with open(args[0], encoding='utf-8') as f:
            lines = f.readlines()
    elif not sys.stdin.isatty():
        lines = sys.stdin.readlines()

    if compare:
        print("--fold: comparing the pre-0.9.57 unfolded _norm vs the shipped folded _norm.\n")

    if not lines:
        print("No input — running built-in demonstration cases.\n"
              "(Pipe in real pairs or pass a file to test actual data.)\n")
        cases = DEMO
    else:
        cases = []
        for raw in lines:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if '||' not in line:
                print(f"!! skipped (no '||'): {line}")
                continue
            lb, fl = line.split('||', 1)
            la, lt = (lb.split('|', 1) + [''])[:2] if '|' in lb else (lb, '')
            fa, ft = (fl.split('|', 1) + [''])[:2] if '|' in fl else (fl, '')
            cases.append((la.strip(), lt.strip(), fa.strip(), ft.strip()))

    n = shipped_ok = unfolded_ok = rescued = 0
    for c in cases:
        n += 1
        sok, uok = check(*c, compare=compare)
        shipped_ok += 1 if sok else 0
        if compare:
            unfolded_ok += 1 if uok else 0
            if sok and not uok:
                rescued += 1

    if compare:
        print(f"=== unfolded: {unfolded_ok}/{n} matched | shipped(folded): {shipped_ok}/{n} matched "
              f"| folding rescues {rescued} miss(es) ===")
    else:
        print(f"=== {shipped_ok}/{n} matched ===")

if __name__ == '__main__':
    main()
