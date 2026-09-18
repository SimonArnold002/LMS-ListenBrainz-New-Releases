#!/usr/bin/env python3
"""Cross-repo drift check for the SHARED single-flight registry.

    python3 tools/singleflight_sync_check.py

WHY THIS EXISTS. Thirteen hand-rolled coalescing guards had grown across four
plugins (counted 2026-08-26): LBF's %BUILDING, %INFLIGHT, %coverQueued,
%sortInFlight and %agenInFlight; LL's %counting and %trackPending; PFR's %PENDING
and %RESOLVING; DSC's %nameRefetched, %candWaiting, %bandsInFlight and
%officialInFlight. Each coalesces duplicate async work behind a single flight,
each was written fresh, and each therefore got a different subset of the four
properties that make one correct. The code reviews then found the missing subset
one site at a time, for weeks -- the same defect reported as new, in a different
file each round. That is what this file and SingleFlight.pm exist to end.

THE RULE (fleet-wide, 2026-08-26), the same one the matcher already lives under:
a fix to the registry in ONE repo must be applied to ALL repos that carry it, in
the SAME change session. This script is the enforcement.

    Exit 0 = every copy present is byte-identical (modulo `package`) to the
             canonical one, or is a hash-pinned documented variant.
    Exit 1 = drift -- align every copy (or consciously re-pin a variant) before
             calling the work done.

ADOPTION IS STAGED AND THAT IS NOT DRIFT. A repo with no copy yet is reported as
NOT ADOPTED and does not fail the check -- the sites are converted repo by repo,
and a half-migrated fleet must still be able to prove the copies it DOES have
agree. Once a repo is listed in ADOPTED below, a missing file IS a failure.

VARIANTS: a repo may keep a deliberately different copy, pinned by the sha1 of
its normalised body plus a reason. If a variant's code changes, its pin stops
matching and the check FAILS -- so even a documented variant cannot drift
silently. Re-pin with --print-hashes after a conscious change.
"""

import hashlib
import os
import re
import sys
from difflib import unified_diff

HERE = os.path.dirname(os.path.abspath(__file__))
GITHUB = os.path.dirname(os.path.dirname(HERE))

CANON = 'LBF'

REPOS = {
    'LBF': 'LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/SingleFlight.pm',
    'PFR': 'LMS-Pitchfork-Reviews/PitchforkReviews/SingleFlight.pm',
    'DSC': 'LMS-Discography/Discography/SingleFlight.pm',
    'LL':  'LMS-Listen-to-Later/ListenLater/SingleFlight.pm',
    'SH':  'LMS-Search-Hub/SearchHub/SingleFlight.pm',
}

# Repos that have finished converting. A missing file here is a FAILURE (the copy
# was deleted or the plugin dir was renamed); a missing file anywhere else is just
# "not adopted yet". Move a repo in here as its last hand-rolled guard is retired.
ADOPTED = {'LBF'}

# (repo) -> (sha1-of-normalised-body, reason)
VARIANTS = {}


def norm_lines(src):
    """Comment-free, whitespace-collapsed lines (for diff display).

    The `package` line is dropped, not rewritten: it is the ONE line every copy is
    required to differ on, since each plugin owns its own namespace.
    """
    out = []
    for line in src.splitlines():
        if re.match(r'\s*#', line):
            continue
        if re.match(r'\s*package\s+Plugins::', line):
            continue
        line = re.sub(r'\s+# .*$', '', line)      # trailing "# comment"
        line = line.strip()
        if not line:
            continue
        # The default log category names the plugin, so it differs per repo by
        # design and is compared as a placeholder rather than verbatim.
        line = re.sub(r"logger\('plugin\.[a-z0-9]+'\)", "logger('plugin.PLUGIN')", line)
        out.append(re.sub(r'\s+', ' ', line))
    return out


def norm_key(src):
    return re.sub(r'\s+', ' ', ' '.join(norm_lines(src))).strip()


def body_hash(src):
    return hashlib.sha1(norm_key(src).encode('utf-8')).hexdigest()[:12]


def read(rel):
    path = os.path.join(GITHUB, rel)
    if not os.path.exists(path):
        return None
    with open(path, encoding='utf-8') as fh:
        return fh.read()


def main():
    sources = {repo: read(rel) for repo, rel in REPOS.items()}

    canon_src = sources.get(CANON)
    if canon_src is None:
        print(f"FATAL: the canonical copy ({REPOS[CANON]}) is missing.")
        return 1

    if '--print-hashes' in sys.argv:
        for repo, src in sorted(sources.items()):
            if src is not None:
                print(f"{repo:5s} {body_hash(src)}")
        return 0

    canon_key = norm_key(canon_src)
    present = {r: s for r, s in sources.items() if s is not None}
    missing = [r for r, s in sources.items() if s is None]

    in_sync, drift, variants = [], [], []

    for repo, src in sorted(present.items()):
        if repo == CANON:
            continue
        h = body_hash(src)
        pin = VARIANTS.get(repo)
        if pin and pin[0] == h:
            variants.append((repo, pin[1]))
        elif norm_key(src) == canon_key:
            in_sync.append(repo)
        else:
            drift.append((repo, src, h, pin))

    print(f"canonical: {CANON}  ({body_hash(canon_src)})\n")

    if in_sync:
        print(f"IN SYNC with {CANON}: {', '.join(in_sync)}")
    for repo, why in variants:
        print(f"VARIANT   {repo}: {why}")
    for repo in sorted(missing):
        tag = "MISSING — ADOPTED repo has no copy!" if repo in ADOPTED \
              else "not adopted yet (staged rollout, not drift)"
        print(f"{'ABSENT':9s} {repo}: {tag}")

    failed = repo_missing = False

    for repo in missing:
        if repo in ADOPTED:
            repo_missing = True

    for repo, src, h, pin in drift:
        failed = True
        print(f"\nDRIFT     {repo}  ({h})")
        if pin:
            print(f"  a pinned VARIANT whose code CHANGED — pin was {pin[0]} ({pin[1]})")
            print("  re-pin with --print-hashes only if the change was conscious.")
        for line in unified_diff(norm_lines(canon_src), norm_lines(src),
                                 fromfile=CANON, tofile=repo, lineterm='', n=2):
            print("  " + line)

    if failed or repo_missing:
        print("\nDRIFT FOUND — align every copy (same session!), bump each touched")
        print("repo's version, then re-run.")
        return 1

    print("\nOK — every copy present agrees with the canonical one.")
    if missing:
        print(f"({len(missing)} repo(s) still to convert: {', '.join(sorted(missing))})")
    return 0


if __name__ == '__main__':
    sys.exit(main())
