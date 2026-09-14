# Bundling a Last.fm API key — SHIPPED on dev (0.9.213, fixed in 0.9.214)

**Status: BUILT 2026-09-14 on Simon's go-ahead as 0.9.213; the review's fixes are 0.9.214,
installed on the test rig the same day. Both review rounds are CLOSED — Ledger §C.** §4 was
decided as proposed, with three hardening changes found while building it (below). The
rest of this doc is the original proposal, kept for its §2/§3 reasoning.

## As built — read this first

- **NO MANUAL OPTION — removed the same day on Simon's call ("not needed").** The
  settings field, its Check-key button, the three strings and the `lastfm_api_key`
  pref are gone; `Plugin.pm` deletes any stored value at startup. The built-in key is
  the only key. This supersedes §4's "keep the pref as an override" and the §4.5
  settings bullet below; a revoked key is fixed by shipping a new constant in a build.
- **One accessor.** `API::lastfmKey` (the key in use, honouring the latch),
  `lastfmKeySource` (`builtin` / `none` / `latched`), `lastfmConfigured`
  (latch-independent; the render path uses it so stored tags stay visible) and
  `lastfmLatchState` (`builtin: ok` or the reason, never a value). No plugin code reads
  the old pref — pinned by `t_lastfmkey.pl` §7.
- **Storage: XOR-masked + hex-packed** (`LFM_BUILTIN_HEX` / `LFM_BUILTIN_PAD`), not base64
  — a `base64 -d` recovers MAI's key in one command; this needs the pad as well. Still
  obfuscation, not a cipher (§2 stands). A clipped constant decodes to NO key.
- **CHANGE 1 — every Last.fm call is a POST with the key in the BODY** (`_lastfmPost`,
  the one funnel). Not in the proposal, and the most important protection in the build:
  LMS core's `SimpleAsyncHTTP::onError` logs `Failed to connect to <uri>` **at WARN**
  (read from slimserver public/9.0), so under GET a timeout or a 403 wrote the key into
  every user's `server.log`. Last.fm serves read methods over POST — verified live for
  `artist.gettoptags`, `artist.getsimilar` and `auth.gettoken`. Diag's probe POSTs too.
- **§4.3 latch, extended.** Error 10 (invalid) / 26 (suspended) stop that key for the
  process, logged once; **29 (rate limited) backs off `LFM_RATE_BACKOFF` (1h) and
  recovers**. Detected on BOTH paths: an invalid key is really **HTTP 403** carrying
  `{"error":10}` (captured live), which LMS routes to the error callback with the
  response as its third argument.
- ~~**CHANGE 2 — a rejected USER key falls back to the built-in key.**~~ Moot: there is
  no user key any more. A stopped built-in key simply pauses the tier until restart.
- **CHANGE 3 — a failure is not an empty answer.** `getLastfmTags`' artist step used to
  call `$finish->([])` on any failure, filing an empty checkpoint; with a latch that would
  have poisoned the artist whose request tripped it, and a keyless call mid-pass would
  have filed one for every remaining artist. Both now reach `onError` (the warm counts
  `failed`, stores nothing). `getSimilarArtistsLastfm` no longer caches a Last.fm error
  body as "no similar artists". **Except error 6** — Last.fm answers an unknown artist
  with HTTP 200 + `{"error":6}` (verified live for `artist.gettoptags`,
  `album.gettoptags` and `artist.getsimilar`), which is an answer, so it is stored /
  cached as empty; ~20% of a sampled week's feed artists get it. A key that stops
  mid-pass ends the warm pass with the rest `deferred`.
- **§4.4 pacing unchanged.** **§4.5**: no settings field (see the first bullet); Diag
  names the key's state and probes it (`lastfm` in the context, `lastfm_key` / `lastfm_keys` in
  `["lbf","warmstats"]`).
- **§5 open questions:** 1 — the key was supplied by Simon (whether it sits on a
  dedicated account is his to confirm); 2/3 not re-measured; 4 unchanged (LBF-only).
- **Tests:** new `tools/t_lastfmkey.pl` (58, after the manual option was removed),
  anti-tested five ways — latch removed 9 red, scrub removed 1, failure storing empty 3,
  GET transport 8, a pref override reinstated 1. `t_diag.pl` 67 → 71 (built-in probed, no-key skip, key in body not URL,
  context names the source). `t_lastfm_priority.pl` gained a `lastfmKey` stub. All 33
  `tools/t_*.pl` exit 0. 0.9.214 added 6 + 6 (`t_lastfmkey.pl` 64, `t_lastfm_priority.pl` 73).
- **Live, 0.9.214 on the test rig (2026-09-14):** `lastfm_key builtin`, `lastfm_keys builtin:
  ok`; the Connection Check's Last.fm row is ok, HTTP 200, "The built-in API key is valid" — so
  the POST transport and the built-in key are PROVEN live. **Still UNPROVEN live:** the error-6
  path (the first pass found 220/220 fresh checkpoints and requested nothing) and the latch
  (no rejection has occurred).

---

## 1. The problem

Last.fm artist tags are the genre ladder's **tier 5** (`Browse::_genresFor`), and they are
gated on a `lastfm_api_key` pref the user has to create a Last.fm API account to fill in.
Most users won't.

**It is not a marginal rung.** From `genre-ladder-current.md` §5, measured on the residue:

- ListenBrainz answers **~52%** of a feed.
- Last.fm answers **~63% of the population that falls through** — i.e. roughly **30% of
  the whole feed**, and it is the only genuinely independent source in the ladder.

So a keyless user loses about a third of their genre labels. That is the cost of the
current friction, and it is why the hosted artist tier (~2% on the same residue) was never
a substitute for it.

### What else the key gates

| Consumer | File | Impact without a key |
|---|---|---|
| Genre ladder tier 5 | `Browse::_warmLastfm` ([Browse.pm:8863](../ListenBrainzFreshReleases/Browse.pm#L8863)), `API::getLastfmTags` ([API.pm:4209](../ListenBrainzFreshReleases/API.pm#L4209)) | **~30% of feed genres lost** |
| DSTM similar-artist rung | `DSTM::_radioViaNames` with `$src eq 'lastfm'` ([DSTM.pm:238](../ListenBrainzFreshReleases/DSTM.pm#L238)) | Minor — see below |

The DSTM case is **weak on its own**. `_radioViaNames` already tries `'hosted'` first
([DSTM.pm:193-206](../ListenBrainzFreshReleases/DSTM.pm#L193-L206)) and the hosted rung is
the *better* one — every entry carries an inline MBID, so it costs zero MusicBrainz
lookups, where Last.fm's spotty MBIDs cost one throttled MB lookup per miss. A bundled key
adds fallback depth to the mixer; it does not unblock it. **The genre number is the case.**

---

## 2. Precedent — what MusicArtistInfo does

MAI ships live keys for **both** Last.fm and Discogs, base64-encoded in the `__DATA__`
section of `Common.pm`:

```perl
use constant CAN_DISCOGS => 0;
use constant CAN_LFM => 1;

my @HEADER_DATA = map { MIME::Base64::decode_base64($_) }
    <Plugins::MusicArtistInfo::Common::DATA>;

sub getHeaders {
    return $HEADER_DATA[{'discogs' => CAN_DISCOGS, 'lfm' => CAN_LFM}->{$_[1]}]
}

__DATA__
eyJBdXRob3JpemF0aW9uIjoiRGlzY29ncyBrZXk9…   # Discogs key + secret, as JSON
YXBpX2tleT1jNmFiYzUxZTg0N2I5MWFiYTBkZTJl…   # api_key=<the Last.fm key>
```

`LFM::_call` then appends `getHeaders('lfm')` to the query string on every
`ws.audioscrobbler.com/2.0/` request (cached, `expires => 86400`).

**The security is nil, and that has to be stated plainly.** Base64 is an encoding, not a
cipher — `base64 -d` on those two lines recovers a live Last.fm key and a live Discogs
key+secret from a public repository, in one command. The only adjacent hardening is
cosmetic: `Common::_debug` strips `api_key=…` out of log lines
(`$msg =~ s/api_key=.*?(&|$)//gi;`) so keys don't leak into a user's `log.txt`. There is no
per-install key, no remote key fetch, no signing.

**Do not try to beat this.** Anything the plugin can decode at runtime, a user can decode
with the same three lines. Encryption buys minutes and costs maintenance. The protection is
not the encoding — it is that the key is **disposable** and the plugin **degrades cleanly**
when it dies (§4.2, §4.3).

---

## 3. Why there is no upstream alternative

All three were considered and all three are closed. Recorded here so they aren't
rediscovered.

**3.1 Hosted LMS-community API genres — MusicBrainz-derived, already measured and removed.**
Not a second dataset. From `genre-ladder-current.md` §5: "the hosted API is
MusicBrainz-derived, so it is not a different dataset. It succeeds where LB succeeds and
fails where LB fails" — ~2% on the residue across two measurements a week apart, for one
HTTP request per artist. Removed in 0.9.173. Last.fm answers ~63% of that same population.

**3.2 A new hosted Last.fm tags route — a much bigger ask than it looks.**
The dev *does* hold a Last.fm key server-side — `relatedArtists` is Last.fm-similar
(`hosted-lms-community-api.md` §4) — but he exposes it only as similar-artists.
`MusicArtistInfo::API`'s route list is picture / biography / album review / album genres /
track review / lyrics / lyricsProviders / killwords: **no artist tags or genres route
exists**. So this is not "surface a field you already serve", it is "open a new Last.fm
passthrough and carry our traffic on your key".

**3.3 Reading tags through MAI's CLI — no command, and the call is off the hot path.**
`MusicArtistInfo::ArtistInfo` registers only `musicartistinfo artistphoto`,
`artistphotos`, and `biography` — nothing for tags or genres. And `LFM.pm` only ever reads
`$artistInfo->{artist}{bio}{content}` from its `artist.getInfo` response; the `tags` field
in that same response is discarded.

The tempting version of this — "PR MAI to return the tags it already fetches" — **does not
hold**, and this is the correction that closed the option. `ArtistInfo::getBiography`
resolves bios as: hosted `API::getArtistBioId` (which returns a **pointer** — a wikidata id
or a URL, *not* prose) → Wikipedia → an AI-generated markdown file on
`music-metadata.lms-community…` → and **only then** `LFM->getBiography`. Last.fm is the
**tail** of that chain, not its source, so `artist.getInfo` is not being called per artist
today. A tags PR would therefore *provoke* a new `artist.getInfo` request per artist, on
the dev's key, driven by LBF warming ~400 artists a night. That is handing him our traffic,
not reading a spare field.

Note also, if this is ever revisited: `artist.getInfo` returns the top ~5 tags **by name
with no weights**, whereas LBF calls `artist.getTopTags` and sorts by weight
(`API::_parseLastfmTags`, [API.pm:4298](../ListenBrainzFreshReleases/API.pm#L4298)). Tier 5
gates everything through `genre-families.txt` anyway, so unweighted names would probably
survive — but it is a difference, not a drop-in.

---

## 4. The proposal

Ship a bundled default key, keep the pref as an override, and make revocation a
non-event.

### 4.1 One accessor, `API::_lastfmKey()`

User pref if non-empty, else the bundled default. Four call sites read the pref
**directly** today and all four must route through it, so that the existing "no key" path
survives untouched as the degradation branch:

- [Browse.pm:8867](../ListenBrainzFreshReleases/Browse.pm#L8867) — `_warmLastfm`'s gate
- [Browse.pm:9262](../ListenBrainzFreshReleases/Browse.pm#L9262)
- [DSTM.pm:238](../ListenBrainzFreshReleases/DSTM.pm#L238) — the `'lastfm'` rung's gate
- [API.pm:4212](../ListenBrainzFreshReleases/API.pm#L4212) (`getLastfmTags`) and
  [API.pm:4398](../ListenBrainzFreshReleases/API.pm#L4398) (`getSimilarArtistsLastfm`)

Storage: base64 in `__DATA__`, as MAI does. Not because it is secure (§2) but because it
keeps a plain `api_key=` string out of casual repo greps and out of anything that scrapes
GitHub for exposed keys.

### 4.2 The key goes on a DEDICATED Last.fm account

**Not Simon's own account.** Revocation, rate-limit correspondence and any ToS question
land on whichever account owns the key; that account should be disposable and hold nothing
else.

On rate limits: Last.fm throttles per **originating IP**, not per key, so thousands of
installs sharing one key do not throttle one another — each user calls from their own
address. The real exposure is **single-point revocation**: one key, and if it dies it dies
for every user at once. Hence §4.3.

### 4.3 A latching invalid-key guard — this is what makes bundling safe

Today the code only handles *"no key configured"*. A **revoked or invalid** key returns a
Last.fm error (10 = invalid API key, 26 = suspended) with HTTP 200, per call, forever — so
the warm would pay a failed request per artist, every night, indefinitely.

`_lastfmCall` ([API.pm:4268](../ListenBrainzFreshReleases/API.pm#L4268)) must detect that
error code, log it **once**, and latch the tier off for the session. Worst case then equals
today's keyless behaviour — a missing rung — instead of a wedged warm.

### 4.4 Keep `_warmLastfm`'s per-night quota exactly as it is

Unchanged, and worth saying why: under a shared key all traffic is *attributable* to one
key even though it arrives from many IPs. The quota is what keeps the aggregate looking
like a well-behaved application rather than something worth revoking. **Do not raise it
because the key is now "free" to the user.**

### 4.5 Settings and Diag

- `settings.html` ([line 17](../ListenBrainzFreshReleases/HTML/EN/plugins/ListenBrainzFreshReleases/settings.html#L17))
  — relabel to "optional — overrides the built-in key". Field stays (power users, and an
  escape hatch if the bundled key is ever revoked or rate-limited).
- `Diag.pm` ([line 199](../ListenBrainzFreshReleases/Diag.pm#L199)) — report **which** key
  is in use (`built-in` / `user` / `none`) and whether the §4.3 latch has tripped. **Never
  print the value.**

---

## 5. Open questions before building

1. **Generate the key.** Fresh Last.fm account → last.fm/api/account/create. It does not
   exist yet; nothing here can be built without it. The value should be dropped in locally,
   not pasted into a chat or an issue.
2. **Confirm the ~63%/~30% figures still hold** on a current feed before spending the
   effort — they date from the 0.9.173 measurements.
3. **Does the DSTM `'lastfm'` rung still earn its place** once the key is free? It sits
   below `'hosted'` and costs a throttled MB lookup per MBID-less name. Worth measuring
   how often it actually fires and produces usable seeds; it may be deletable regardless of
   this proposal.
4. **Fleet question.** DSC and PFR do not use Last.fm today. If either ever wants tags, the
   accessor should be the shared port — decide before a second copy of the key exists.
