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
    # LL's fold table lives in DB.pm, not beside its matcher (LL 0.1.112): DB::_norm
    # builds the dedupe_key, a UNIQUE column on every stored row, and a ->can fallback
    # there would write a WRONG KEY permanently, where the same fallback on the live
    # matching path is only a worse match. The authority sits with the irreversible
    # consumer, and Sources reaches it through ->can.
    #
    # Scanned as its own tag so %FOLD stays under this alarm — without it LL's copy of
    # the ~90-entry table would be the one place in the fleet nothing watches. The
    # _norm it also finds here is DB::_norm, a genuinely different sub that happens to
    # share the name (it KEEPS "(Deluxe)" so editions dedupe apart), so it is pinned as
    # a variant rather than being expected to match.
    'LLDB': 'LMS-Listen-to-Later/ListenLater/DB.pm',
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
    # LL's matcher is deliberately LENIENT: it re-finds a SAVED item (exact saved
    # title, artist metadata may be EMPTY on streaming Now-Playing adds - LL 0.1.66),
    # so an empty artist must match. That leniency is the pin; it is NOT drift.
    #
    # THE FOLD IS NO LONGER BEHIND THE FLEET (LL 0.1.112). _norm took the apostrophe
    # elision and the ~90-entry %FOLD, so it agrees with DSC/PFR/LBF about what a NAME
    # is; what stays different is the punctuation pass and the lenient gates. The
    # compound-word tier was deliberately NOT taken - it only reaches LL's replay gate,
    # where _bestMatches re-ranks afterwards.
    #
    # LL's fold lives in DB.pm, not beside the matcher, because DB::_norm builds the
    # dedupe_key - a UNIQUE column on every stored row. That is also why a fold change
    # there is a MIGRATION rather than a cache bump; see LL's _migrateRefold.
    ('_norm', 'LL'):         ('a054575b2b5b', 'LL lenient variant: fleet fold (0.1.112) + LL punctuation pass; strips (...) for the fuzzy gate, unlike DB::_norm'),
    ('_albumMatches', 'LL'): ('2bf38f346e0f', 'LL lenient: empty artist accepts (saved-item replay, LL 0.1.66) + self-titled exact rule (fleet sync from DSC 0.11.1)'),
    ('_artistMatch', 'LL'):  ('ac8401597520', 'LL lenient: empty side matches; length-based short/long split'),

    # NOT the matcher's _norm — a DIFFERENT sub that shares the name. DB::_norm builds
    # LL's dedupe_key and must KEEP "(Deluxe)"/"(LP4)" so editions dedupe apart, which
    # is the exact opposite of what the fuzzy match gate needs. It IS folded the same
    # way (it calls foldLatin, whose %FOLD is compared above and must match the fleet);
    # only the punctuation pass differs. Pinned so that shared fold cannot drift
    # unnoticed while the two subs stay legitimately different.
    ('_norm', 'LLDB'):       ('451b0041d305', 'LL dedupe-key normaliser (not the matcher): folds like the fleet, KEEPS bracketed qualifiers'),

    # SEARCH HUB IS FROZEN BEHIND THE FLEET, DELIBERATELY — Simon, 2026-08-29:
    # "ignore Search Hub from any changes, it's on hold with no development."
    # So it keeps the pre-sync _norm (no apostrophe elision) and the 10-entry
    # %FOLD, while DSC/PFR/LBF carry the DSC-origin rules.
    #
    # PINNED rather than removed from REPOS, and that distinction is the point:
    # dropping SH from the comparison would silence the alarm for good, so a
    # future edit there could drift unnoticed and search would start disagreeing
    # with the matcher about what "the same name" means — the exact failure SH
    # was added to this rule to prevent. A pin keeps SH compared; it just says
    # "this difference is a decision". If SH is ever unfrozen, take the fleet
    # copy and DELETE these two lines rather than re-pinning them.
    ('_norm', 'SH'):  ('cad4e0da7af2', 'Search Hub on hold 2026-08-29, deliberately behind the fleet (no apostrophe rule)'),
    ('%FOLD', 'SH'):  ('293c91ea0e59', 'Search Hub on hold 2026-08-29, deliberately behind the fleet (10-entry table)'),
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
