#!/usr/bin/env python3
"""Cross-repo drift check for the SHARED artist/album/track matching engine.

Four plugins carry copies of the same matcher (ported from this repo, the
engine's origin):

    LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm   (LBF)
    LMS-Pitchfork-Reviews/PitchforkReviews/Browse.pm                    (PFR)
    LMS-Discography/Discography/Sources.pm                              (DSC)
    LMS-Listen-to-Later/ListenLater/Sources.pm                          (LL)

THE RULE (fleet-wide, 2026-07-10): a matching fix in ONE repo must be applied
to ALL repos that carry the affected sub, in the SAME change session. This
script is the enforcement: it extracts every engine sub from every repo,
strips comments/whitespace, and compares the CODE. Run it after ANY matcher
edit and before calling the work done:

    python3 tools/matcher_sync_check.py

Exit 0 = every copy is either canonical or a hash-pinned documented variant.
Exit 1 = drift — fix it (or consciously re-pin a variant) before moving on.

VARIANTS: a repo may keep a deliberately different copy (LL's matcher is
LENIENT: empty-artist saved items must still replay). Each variant is pinned
below by the sha1 of its normalised body + a reason. If the variant's code
changes, the pin no longer matches and the check FAILS — so even variants
can't drift silently. To re-pin after a conscious variant change, run with
--print-hashes and update VARIANTS.
"""

import hashlib
import os
import re
import sys
from difflib import unified_diff
from itertools import combinations

HERE = os.path.dirname(os.path.abspath(__file__))
GITHUB = os.path.dirname(os.path.dirname(HERE))

REPOS = {
    'LBF': 'LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm',
    'PFR': 'LMS-Pitchfork-Reviews/PitchforkReviews/Browse.pm',
    'DSC': 'LMS-Discography/Discography/Sources.pm',
    'LL':  'LMS-Listen-to-Later/ListenLater/Sources.pm',
    # Search Hub (added 2026-07-18) carries ONLY the normaliser subs — _norm,
    # %FOLD, _artistMatch, _asciiNorm, _punctNorm — and none of the
    # match-verification ones (_albumMatches/_trackMatches/_stripFmt/
    # _stripArtistPrefix). Those belong to the matcher's "is THIS the right
    # release?" job; Search Hub only ranks what a search returned. Subs it
    # does not carry are simply absent from its file and drop out of the
    # comparison, which this script already handles.
    #
    # It is in the rule because search and the matcher MUST agree on what "the
    # same name" means: if they diverge, search hands a consumer an artist the
    # matcher then refuses to match.
    'SH':  'LMS-Search-Hub/SearchHub/Text.pm',
}

# The engine's parts. Order = report order. %FOLD is the diacritic map used
# by _norm; it is compared like a sub.
SUBS = [
    '_norm', '%FOLD', '_artistMatch', '_albumMatches', '_trackMatches',
    '_stripFmt', '_asciiNorm', '_punctNorm', '_stripArtistPrefix',
]

# (sub, repo) -> (sha1-of-normalised-body, reason). A pinned copy passing its
# hash is reported as a documented variant, not drift. A pinned copy whose
# hash STOPPED matching = drift (the variant changed without re-pinning).
VARIANTS = {
    # LL's matcher predates the folding work AND is deliberately lenient:
    # it re-finds a SAVED item (exact saved title, artist metadata may be
    # EMPTY on streaming Now-Playing adds - LL 0.1.66), so empty artist must
    # match, and the primitive ASCII _norm has never bitten there. Candidate
    # for a dedicated modernisation - align _norm, keep the lenient gates.
    ('_norm', 'LL'):         ('92c2a19a0832', 'LL legacy ASCII norm (pre-folding); modernisation candidate'),
    ('_albumMatches', 'LL'): ('2bf38f346e0f', 'LL lenient: empty artist accepts (saved-item replay, LL 0.1.66) + self-titled exact rule (fleet sync from DSC 0.11.1)'),
    ('_artistMatch', 'LL'):  ('ac8401597520', 'LL lenient: empty side matches; length-based short/long split'),
}


def extract(src, name):
    if name == '%FOLD':
        m = re.search(r'^my %FOLD = \(.*?^\);', src, re.M | re.S)
        return m.group(0) if m else None
    m = re.search(r'^sub %s\b.*?\{' % re.escape(name), src, re.M | re.S)
    if not m:
        return None
    i, depth = m.end(), 1
    while i < len(src) and depth:
        c = src[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        i += 1
    return src[m.start():i]


def norm_lines(code):
    """Comment-free, whitespace-collapsed lines (for diff display)."""
    out = []
    for line in code.splitlines():
        if re.match(r'\s*#', line):
            continue
        line = re.sub(r'\s+# .*$', '', line)   # trailing "# comment" (space after #)
        line = line.strip()
        if line:
            out.append(re.sub(r'\s+', ' ', line))
    return out


def norm_key(code):
    """Line-structure-independent comparison key (and hash input)."""
    return re.sub(r'\s+', ' ', ' '.join(norm_lines(code))).strip()


def body_hash(code):
    return hashlib.sha1(norm_key(code).encode('utf-8')).hexdigest()[:12]


def main():
    print_hashes = '--print-hashes' in sys.argv

    sources = {}
    missing = []
    for tag, rel in REPOS.items():
        path = os.path.join(GITHUB, rel)
        if os.path.exists(path):
            sources[tag] = open(path, encoding='utf-8').read()
        else:
            missing.append(rel)
    if missing:
        print('MISSING FILES (repo moved/renamed? fix REPOS map):')
        for f in missing:
            print('  ' + f)

    drift = False
    for name in SUBS:
        copies = {t: b for t, s in sources.items()
                  if (b := extract(s, name)) is not None}
        if not copies:
            print('%-20s absent everywhere' % name)
            continue

        if print_hashes:
            for t in sorted(copies):
                print('%-20s %s %s' % (name, t, body_hash(copies[t])))
            continue

        # Split copies into variants (pinned) and canonical candidates.
        canon, variant_notes, bad_pins = {}, [], []
        for t in sorted(copies):
            pin = VARIANTS.get((name, t))
            if pin:
                exp, reason = pin
                got = body_hash(copies[t])
                if got == exp:
                    variant_notes.append('%s variant OK (%s)' % (t, reason))
                    continue
                # Variant that now equals the canon is also fine - flag to unpin.
                bad_pins.append((t, got, reason))
                continue
            canon[t] = copies[t]

        status = []
        if len(canon) == 1:
            status.append('single copy: %s' % list(canon)[0])
        elif canon:
            tags = sorted(canon)
            bad = [(a, b) for a, b in combinations(tags, 2)
                   if norm_key(canon[a]) != norm_key(canon[b])]
            if bad:
                drift = True
                print('%-20s *** DRIFT ***' % name)
                for a, b in bad:
                    print('  --- %s vs %s ---' % (a, b))
                    for l in unified_diff(norm_lines(canon[a]), norm_lines(canon[b]),
                                          a, b, lineterm=''):
                        print('  ' + l)
                for n in variant_notes:
                    print('  note: ' + n)
                continue
            status.append('IN SYNC across %s' % ','.join(tags))
        for n in variant_notes:
            status.append(n)
        for t, got, reason in bad_pins:
            drift = True
            status.append('*** %s PIN MISMATCH (got %s) — variant changed without re-pin! (%s)'
                          % (t, got, reason))
        print('%-20s %s' % (name, '; '.join(status)))

    if print_hashes:
        return 0
    print()
    if drift:
        print('DRIFT FOUND — align every copy (same session!), bump each touched')
        print("repo's version + affected match/decision caches, then re-run.")
        return 1
    print('All shared matcher copies in line (variants pinned + documented).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
