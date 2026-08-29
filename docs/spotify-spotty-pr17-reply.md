# PR #17 reply — ready to post

**Status:** DRAFTED 2026-08-21, **not posted.** Post when `dev` reaches a stable point (see
`spotify-spotty-adapter-pr17.md` for the findings this is built from, and §1a there for who owns
which fix).

**Before posting, two judgement calls are yours:**

1. **Finding 1 is flagged as unverified, with an offer to withdraw it.** It's sound from reading
   `AccountHelper`/`Plugin.pm`, but Spotty isn't installed here so it was never observed. Delete
   that paragraph if you'd rather assert it flatly.
2. **The closing paragraph owns the delay** ("the delay is on my side, not on the PR"). A PR open
   since 19 July with a substantive review arriving months later reads better with a reason
   attached — but cut it if you'd rather not.

**Already corrected in this draft:** internal line numbers were replaced with sub names — the
numbers came from the working tree, which is ~1700 lines ahead of `origin/dev`, so they would not
have matched anything honzup could see.

---

Thanks for this — it's a genuinely well-built adapter, and the PR description made the review much easier than it usually is. I checked it against the Spotty v4.62.2 source (`Plugin.pm`, `OPML.pm`, `API.pm`, `API/Pipeline.pm`, `API/Cache.pm`, `AccountHelper.pm`) rather than taking the description on trust, and everything you documented holds up:

- `getAPIHandler` really is a class method, and you're the only adapter here calling it with `->` correctly.
- `search($cb, {query, type, limit})` — right key (`query`, not `search`), right singular `type`.
- The Pipeline genuinely makes **one** call at `limit => 50`: `params{limit} = min($limit, SPOTIFY_LIMIT=50)`, then `$self->limit <= $params->{limit}` short-circuits before `_followOffset`. Same at 20 for tracks. Worth stating because it wasn't obvious from the call site.
- The error-swallowing caveat is exact. A token failure calls `$cb->({name => ..., type => 'text'})`, and the extractor's `$_[0]->{albums}{items}` on that hash yields nothing, so it arrives as the same `[]` as a real zero-hit. Nothing better is reachable through Spotty's public surface — agreed.
- `normalize()` keeps `album_type` / `total_tracks` / `id` / `uri` / `release_date`, and `_removeUnused` does delete raw `type` unconditionally, so your defensive field ordering is correct.
- The `favorites_url` exemption is right, and for the right reason: `album()`'s `/album:(.*)/` is greedy and would capture `?cover=…` into the id.

Two that are easy to miss and you didn't: resetting the track item's `name` to `line1` is load-bearing rather than cosmetic (the year-append guard at `_resolveTracks` matches on a trailing `(\d{4})`, so a spoken-form name would defeat it and poison the dedupe key), and adding no cache bumps is correct — every layer already keys on `svcOrder`, so a fifth adapter invalidates them by construction.

Two changes before I merge, plus a couple of small things.

---

### 1. Spotty installed but never signed in pins every miss to the 1-hour TTL, permanently

`->can('getAPIHandler')` is true as soon as the plugin loads, regardless of whether any account exists. With **zero credentials on the server**, `AccountHelper->getAccount` returns undef for every client, so `getAPIHandler` returns undef on every search — permanently, not transiently.

The adapter reports that as `undef`, which becomes `$inconclusive++`, and `_findPlayable`'s TTL selection then picks `STREAM_INCONCLUSIVE_TTL` (1h) instead of `STREAM_NOMATCH_TTL` (24h) for **every genuine no-match**. That's 24× the re-search rate against Qobuz/Tidal/Deezer/Bandcamp for a user who's getting nothing from Spotify anyway.

This is new to Spotify — the other three plugins' handlers are server-wide, so "no handler" there really is transient. (A per-*player* missing account is fine and self-healing: `getAccount` falls back to any configured credentials and assigns them. It's only the no-accounts-at-all case that's permanent.)

Suggested, in both `_searchSpotify` and `_searchSpotifyTrack`:

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

Worth keeping at the search site rather than in `_streamingAdapters`: that sub is memoised for only 5s, and `getAllCredentials` re-scans the cache folders on every call while the result is empty — i.e. exactly in the signed-out case.

**This is the one finding I derived from reading the source rather than observing** — I don't have Spotty on my server, so I can't repro it. If you can confirm the handler really does stay undef indefinitely with Spotty installed and signed out (rather than something in the account flow papering over it), that would close it out. If it turns out not to reproduce, say so and I'll drop the request.

### 2. `album_type` classifies EPs as "single"

Spotify has no EP class — EPs come back as `album_type: "single"`. With the field in `_candReleaseType`'s trusted list, a Spotify EP classifies as `single`, and for an MB **album** or **compilation** target `$dropSingles` will discard it whenever another Spotify candidate survives; the `$dropSingles` filter in `_findPlayable` only falls back to the full set when *nothing* survives.

The blast radius is small — EP targets are already exempt at where `$dropSingles` is defined — but the field isn't as trustworthy as Qobuz's `release_type`, which does distinguish EPs.

I'd keep it and guard the single case on the count:

```perl
return 'single' if $t eq 'single' && !(($album->{total_tracks} // 0) > 3);
```

A 5-track EP then falls through to the count chain and returns `''`; a real 3-track single still classifies. Keeping the field beats dropping it, because it catches the case `total_tracks` can't — a like-named single with 3+ tracks, which is what that filter exists for.

Also worth a word in the comment: `total_tracks` here is **not** inert the way the old `&tc=` param was. Search responses on the other three services genuinely don't carry a count — it's an album-endpoint-only field there, which is why `&tc=` shipped dead and got removed. Spotify's search payload really does carry it and `normalize()` doesn't strip it, so this is the one service where the count chain fires from a search result. Please note that explicitly, otherwise the next person to read that function will assume it's dead code and remove it.

### 3. Please drop the `CHANGELOG.md` / `README.md` / `README.html` changes

House convention here is that dev-branch work touches `CLAUDE.md` and `docs/` only — the CHANGELOG and README are written at the merge to `main`. The CHANGELOG prose is good and I'll use it in the release pass; it just shouldn't land on `dev`. Leaving the version unbumped was exactly right.

### Minor

- **`_svctitle` isn't set in `_searchSpotify`.** The other three album adapters all set it. It's unreachable today because `_attachFavUrl` returns early for Spotify, so this is purely defensive — but if that exemption is ever revisited it'll fail silently rather than loudly. One line: `$item->{_svctitle} = $album->{name};`
- **No action, just noting it:** `_albumItem` appends `(Year)` only when LMS's `showYear` server pref is on, so Spotify is the one row label in the set that varies by server. Consistent enough with Qobuz's and Bandcamp's composite labels — just noting I've seen it.

`_searchSpotifyTrack` having no `rendererFailed` → inconclusive path matches `_searchDeezerTrack`, so that's consistent, not a gap. Both new subs parse clean.

---

One scheduling note so this isn't sitting open unexplained: my `dev` branch has a large in-flight change set at the moment, and I want it at a stable point before taking this in. It merges cleanly, and none of your hunks collide with what I'm working on — I've checked all five subs you touch. So this is queued rather than stalled, and the delay is on my side, not on the PR. Thanks again for doing this properly rather than bolting it on.
