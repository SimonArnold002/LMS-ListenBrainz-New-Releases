# Spotify via Spotty — PR #17 review findings & merge plan

**Status:** **DONE — applied, committed and built.** Hand-applied into the working tree and
committed as **`c68cbb1`** on `dev` (2026-08-29), with honzup credited as `Co-Authored-By`; built
into **0.9.187**. **Not pushed, not installed, NOT tested** — Spotty is still absent from the test
server, so everything below remains source-verified only.

**Still owed:** the PR stays OPEN (its `Closes #17` only fires on the default branch, `main`) —
Simon is closing it by hand once `dev` is pushed, and has already replied to honzup. **A CHANGELOG
credit line for honzup is owed at the main merge**, since the PR's own CHANGELOG hunk was
deliberately not taken.

**How it was applied, and the rule that came out of it:** hand-applying was right on 2026-08-21
(the tree was uncommitted) but NOT on 2026-08-29, once the tree was committed as `cab9450`. A
`git merge-tree` simulation showed `Browse.pm` and `Plugin.pm` would have merged CLEANLY, with
conflicts only in `CHANGELOG.md`, `CLAUDE.md` and `Settings.pm` — so push-then-merge was available
and would have preserved honzup's authorship natively and auto-closed the PR. **The rule going
forward: if the working tree is COMMITTED, push first and merge on GitHub; only hand-apply when
uncommitted work sits in the same files.**

**One change was made beyond the PR** (§4 housekeeping, done in the same commit): `_attachFavUrl`'s
`&tc=` comment claimed count fields are absent from EVERY service's search response, which the new
`_candReleaseType` note contradicts for Spotify. A clause now records the exception so the two
notes don't fight.
**PR:** [#17 "Add Spotify streaming adapter via the Spotty plugin"](https://github.com/SimonArnold002/LMS-ListenBrainz-New-Releases/pull/17)
— `honzup:spotify-adapter` → `dev`, opened 2026-07-19, 1 commit, 7 files, +194/−26. Closes #16.
**Reviewed:** 2026-08-21, against Spotty **v4.62.2** master source (`Plugin.pm`, `OPML.pm`,
`API.pm`, `API/Pipeline.pm`, `API/Cache.pm`, `AccountHelper.pm`) — not against the PR description.

**Reply drafted and ready to post: `docs/spotify-spotty-pr17-reply.md`.**

**Verdict: accept, with two code changes (§2) and one housekeeping revert (§3).** The adapter
follows the house pattern closely and the non-obvious details are right for the right reasons.

---

## 1. What was verified (don't re-derive)

Everything below was checked against real Spotty source, not assumed.

| Claim | Verified |
|---|---|
| `getAPIHandler` is a CLASS method `($class, $client)` | ✅ `Plugin.pm:317`. PR calls it with `->`, correctly — unlike Qobuz/Tidal, which LBF calls in function form |
| `search($cb, {query, type, limit})`, **singular** `type` | ✅ `API.pm:229`. Key is `query`, not `search` (Deezer/Tidal use `search`) |
| No runaway pagination at `limit => 50` | ✅ Pipeline sets `params{limit} = min($limit, SPOTIFY_LIMIT=50)`, then `$self->limit <= $params->{limit}` short-circuits → exactly **one** API call. Same for `limit => 20` on tracks |
| Pipeline swallows API/auth errors into `[]` | ✅ token failure → `_call` does `$cb->({name=>…, type=>'text'})`; the extractor's `$_[0]->{albums}{items}` yields nothing → `cb->([])`. **The PR's caveat is exact** — an outage is genuinely indistinguishable from a clean miss at this layer |
| `normalize()` keeps `album_type`, `total_tracks`, `id`, `uri`, `release_date`, `name`, `artist`, `artists` | ✅ `API/Cache.pm:106-138` |
| `normalize()` deletes raw `type` unconditionally | ✅ `_removeUnused` (`API/Cache.pm:233`) — so the PR's defensive `album_type`-before-`type` ordering note is accurate |
| `_albumItem` is the Tidal/Deezer shape | ✅ `OPML.pm:1246-1251` — coderef `url => \&album`, `passthrough => [{uri}]` (plain data, survives the cache), `favorites_url => $album->{uri}` |
| `OPML::album` matches the XMLBrowser coderef signature | ✅ `($client, $cb, $params, $args)`, `$args` = the passthrough hash |
| `query_enc => 'chars'` | ✅ `uri_escape_utf8` in `API.pm::_prepareCall` (line 1293) |
| Icon resolves via `_pluginIcon` | ✅ Spotty's `install.xml` carries `<icon>` |
| Both new subs parse | ✅ `perl -c` clean in isolation |

Two things the PR got right that are easy to get wrong:

- **Resetting the track item's `name` to `line1` is load-bearing, not cosmetic.** Spotty's
  `trackList` builds `"Title BY Artist FROM Album"`. The year-append at `Browse.pm:2662` guards
  on `!~ /\(\d{4}\)\s*$/`, so without the reset every trending/follow row would get a year glued
  onto a spoken-form label, and `_dedupeStreamItems` would key off it.
- **No cache bumps — correctly.** Every layer (`lbf:stream:`, `lbf:pl:resolved:`,
  `lbf:follow:resolved:`, `lbf:trending:resolved:`, `lbf:trending:albums:`, `lbf:track:`)
  already keys on `svcOrder`, so registering a fifth adapter invalidates all of them by
  construction. Adding a bump would have been the mistake.

**Enumeration coverage is complete.** Grepping every `deezer` site returns exactly the five the
PR touched (`_streamingAdapters`, `serviceStatus`, `Settings.pm` prefs + handler, `Plugin.pm`
init). `settings.html` iterates `serviceStatus` generically, so no template or strings change is
needed. `DSTM.pm` needs nothing — it goes through `_findPlayableTrack`.

**Shared-matcher sync rule is NOT triggered.** `_albumMatches` / `_trackMatches` are untouched;
`_candReleaseType` is deliberately LBF-only (see the `lbf-release-type-filter-not-synced` note).
No PFR / DSC / LL changes required.

**Spotty is NOT installed on the test server** (verified 2026-08-21 via
`pref plugin.state:Spotty` over http://plex:9000 — unset, while Qobuz/TIDAL/Deezer are
`enabled`). Nothing in §2 can be reproduced or verified locally.

---

## 1a. Who does what

| Item | Owner | Why |
|---|---|---|
| §2.1 signed-out Spotty pins the 1h TTL | **honzup (PR author)** | needs a Spotty install that is *signed out* to repro; derived from source here, never observed |
| §2.2 `album_type` classifies EPs as single | **honzup** | needs a real Spotify EP to confirm the classification |
| §4 minor items | **honzup**, same comment | all one-liners, no reason to split the round trip |
| §3 CHANGELOG/README revert | **us, at merge** | faster to drop the three files than round-trip it |
| §5 hand-applying the `Browse.pm` hunks | **us**, once `dev` is stable | the tree is ~1700 lines ahead of `origin/dev` |

Ask honzup explicitly for a **repro of §2.1 with Spotty installed but not signed in** — that is
the one finding derived purely from reading `AccountHelper`/`Plugin.pm`, not observed, and they
own the only rig that can confirm the handler really stays undef indefinitely.

---

## 2. Code changes to make before or at merge — FOR THE PR AUTHOR

### 2.1 (should fix) Spotty installed but never signed in pins every miss to the 1-hour TTL, for ever

`->can('getAPIHandler')` is true the moment the plugin loads, regardless of accounts. With **zero
credentials on the server**, `AccountHelper->getAccount` returns undef for *every* client, so
`getAPIHandler` returns undef on *every* search — permanently, not transiently.

The adapter reports `undef` → `$inconclusive++` → `Browse.pm:5276` picks
`STREAM_INCONCLUSIVE_TTL` (1h) instead of `STREAM_NOMATCH_TTL` (24h) for **every genuine
no-match**. That's 24× the re-search rate against Qobuz/Tidal/Deezer/Bandcamp for a user who is
getting nothing from Spotify at all.

This failure mode is new to Spotify: the other three plugins' handlers are server-wide.
(Note `AccountHelper::getAccount` *does* fall back to any configured credentials and assign them
to the client, so a per-player "no account" is self-healing — it is only the **no accounts at
all** case that is permanent.)

Fix, in **both** `_searchSpotify` and `_searchSpotifyTrack`:

```perl
unless ($api) {
    # A missing handler is only INCONCLUSIVE when Spotty could have answered.
    # With no credentials on the server at all it is PERMANENT, and reporting it
    # inconclusive pins every real miss to STREAM_INCONCLUSIVE_TTL (1h instead of
    # 24h) for ever — 24x the re-search load on the other four services.
    my $signedIn = eval { Plugins::Spotty::AccountHelper->hasCredentials() };
    $collect->($signedIn ? undef : []);
    return;
}
```

Keep this at the search site, **not** in `_streamingAdapters`: that sub is memoised for only
`ADAPTER_MEMO_TTL` (5s), and `AccountHelper::getAllCredentials` re-scans the cache folders on
every call while the result is empty — i.e. exactly in the signed-out case.

### 2.2 (should fix) `album_type` classifies EPs as "single"

Spotify has **no EP class** — EPs come back as `album_type: "single"`. Adding the field to
`_candReleaseType`'s trusted list means a Spotify EP is classified `single`, and for an MB
**album/compilation** target `$dropSingles` will discard it whenever another Spotify candidate
survives the filter (`Browse.pm:5309` only falls back to the full set when *nothing* survives).

Blast radius is small — EP targets are already exempt at `Browse.pm:5196` — but the field is not
as trustworthy as Qobuz's `release_type`. Keep it, but guard the single case on the count:

```perl
return 'single' if $t eq 'single' && !(($album->{total_tracks} // 0) > 3);
```

An EP (5 tracks) then falls through to the count chain and returns `''`; a real 3-track single
still classifies. Keeping the field beats dropping it, because it catches the 0.9.89 case (a
like-named 3+-track single) that `total_tracks` alone can't.

**Worth recording, because it contradicts the general rule:** `total_tracks` here is **not**
inert the way `&tc=` was (see the `streaming-search-no-track-count` finding). Spotify's search
response really does carry it and `normalize()` doesn't strip it — Spotify is **the one service
whose SEARCH payload has a usable track count**.

---

## 3. Housekeeping — revert before merge

The PR edits `CHANGELOG.md`, `README.md` and `README.html`. Those are **main-merge artifacts**,
not dev-branch ones (house rule: dev builds touch `CLAUDE.md` + `docs/*.md` only). Drop all three
at merge — the CHANGELOG prose is good, keep it for the release pass.

Version deliberately not bumped is the right call; `install.xml` + `repo.xml` + the `<sha>` all
happen in the normal build pass.

---

## 4. Minor / optional

- **`_svctitle` is not set in `_searchSpotify`.** All three other album adapters set it. Currently
  unreachable because `_attachFavUrl` returns early for Spotify, but if that exemption is ever
  revisited it fails silently. One line: `$item->{_svctitle} = $album->{name};`
- **The favurl exemption is right and costs nothing.** Spotty's `album()` does `/album:(.*)/`
  greedily and would swallow `?cover=…` into the id, breaking natively-saved favourites, so
  keeping Spotty's own `spotify:album:<id>` is correct. (An earlier draft of this review counted
  a forfeited Material service badge against it — **there is none**: the favurl-scheme emblem
  patch was prototyped and never adopted, so nothing draws badges from the scheme. Corrected
  2026-08-21 by Simon.)
- **Album row labels vary with a server pref.** Spotty's `_albumItem` appends `(Year)` only when
  LMS's `showYear` is on. Consistent enough with Qobuz/Bandcamp's composite labels; just the one
  label in the set that isn't stable across servers.
- `_searchSpotifyTrack` has no `$rendererFailed` → inconclusive path. That matches
  `_searchDeezerTrack`, so it's consistent, not a gap.

---

## 5. Merge mechanics

**GitHub says `mergeable: clean` against `origin/dev`** — but the working tree is **+1728/−147**
on `Browse.pm` vs `origin/dev`, so merging on GitHub and pulling would fight the tree.

**Checked 2026-08-21:** none of the uncommitted local edits fall inside any of the five subs the
PR modifies — `_streamingAdapters`, `serviceStatus`, `_attachFavUrl`, `_rebuildStreamItems`,
`_candReleaseType`. (The one local hunk whose header *names* `_rebuildStreamItems` is actually
inside `_bcMatchItems`, the following sub.) So **applying the PR's `Browse.pm` hunks by hand into
the working copy is mechanical** — that's the safer route than a GitHub merge + pull.

`Plugin.pm`, `Settings.pm` changes are one-liners and conflict-free.

**Re-verify before applying** (the tree will have moved by then):

```
git -C /Users/simona/Documents/GitHub/LMS-ListenBrainz-New-Releases diff origin/dev -- ListenBrainzFreshReleases/Browse.pm | grep "^@@"
```

## 6. Release-time note

Because every cache layer keys on `svcOrder`, the moment this ships **every user with Spotty
installed re-resolves all their stream / playlist / follow / trending caches at once**. That is
correct behaviour (a fifth service genuinely changes every answer), but it is a one-off burst of
streaming-API traffic — worth expecting, and worth a line in the release notes.

Users **without** Spotty see no change to `svcOrder` and no invalidation at all.
