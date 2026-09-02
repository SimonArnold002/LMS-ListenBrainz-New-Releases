# Streaming adapter spec — requirements for adding a service

**What this is.** The contract a streaming-service adapter must meet in these plugins, and
the acceptance criteria it is reviewed against. Read it before writing code; it should be
enough on its own, without reading the rest of the plugin first.

**Applies to:** ListenBrainz Fresh Releases (LBF), Pitchfork Reviews (PFR), Listen to
Later (LL).

**Copies of this file.** Each plugin carries its own copy, so the paths in it resolve from
inside the repo you are working in:

    LMS-ListenBrainz-New-Releases/docs/streaming-adapter-spec.md   (canonical)
    LMS-Pitchfork-Reviews/docs/streaming-adapter-spec.md
    LMS-Listen-to-Later/docs/streaming-adapter-spec.md

They are **verbatim** copies. Edit the canonical one and re-copy over the others in the same
session — the same rule the shared matcher follows. To check for drift, compare the three
files' checksums; they must agree.

**Terms used throughout.**

- **Adapter** — one entry in a plugin's adapter table, plus the search functions it points at.
- **Service plugin** — the third-party LMS plugin that actually talks to the service
  (Qobuz, TIDAL, Deezer, Spotty, …). We never talk to a streaming API directly; the adapter
  calls the service plugin.
- **Leg** — one capability of an adapter, such as album search or track search.
- **Item** — an XMLBrowser menu node produced by the service plugin's own renderer.

## How to use this document

Sections 2 to 6 are the contract; everything else is context or process. If you are writing
an adapter, work through them in order and then use section 10 as the checklist.

| Section | What it does | Read it when |
|---|---|---|
| **1. The rule** | States the boundary: an adapter is three edits, and what must never be changed alongside it | Before starting, and again before opening a pull request |
| **2. What the service plugin must expose** | Eight requirements (R1-R8) the third-party service plugin has to satisfy, plus three optional fields. A service failing R1-R3 cannot be adapted | First. It decides whether the work is possible at all |
| **3. The adapter table entry** | The shape of the registry entry, what `name` controls, and where the table lives in each plugin | When writing the entry |
| **4. Album leg** | The album search function: signature, what to send a service versus what to validate locally, the three ways to return a result and the cache TTL each picks, and the fields to stamp on a matched item | When writing the album search |
| **5. Track leg** | The same for track search, including the plain-string url requirement and when it is acceptable to return nothing | When writing the track search, or deciding not to |
| **6. Caching and rebuilds** | Why items are serialised without their url, and what an item may therefore contain | Alongside sections 4 and 5 — it constrains both |
| **7. Summary: what not to do** | The prohibitions from sections 1 to 6 in one list | As a quick pass before review |
| **8. Adapter-table fields still to be added** | Sites that currently force an edit outside the table, per plugin, and the field that would remove each | When a required edit falls outside the table — the fix belongs here, not in a new branch |
| **9. Per-plugin status** | Which plugins are ready, what a new service costs in each, and which need work first | When choosing where to add a service |
| **10. Definition of done** | Code checks and the tests to run on a server with the service installed | Before declaring the adapter finished |
| **11. What the pull request must contain** | The four things a reviewer needs in order to accept it | When opening the pull request |
| **Appendix** | A completed section 2 assessment for one candidate service, as a template for the next one | As an example of the expected output of section 2 |

---

## 1. The rule

> **Adding a service is: one entry in one adapter table, one pref default, one settings row.**

If a service cannot be added within those three edits, the adapter table is missing a field.
Section 8 lists the fields that are still missing and where they are needed. Adding a
per-service `if ($svc eq '…')` branch anywhere else is not an acceptable substitute.

Two rules follow directly, and both matter on day one:

- **MUST NOT bump any cache key.** Every stream, track, playlist and trending cache key
  already includes the ordered list of enabled services (`_streamKey`,
  `ListenBrainzFreshReleases/Browse.pm:5829`). Registering an adapter changes that list, so
  every affected entry is invalidated automatically. An extra bump only forces a second,
  redundant re-resolve.
- **MUST NOT change the shared matcher.** `_albumMatches`, `_trackMatches` and `_norm` are
  one engine kept in step across the plugins. An adapter that appears to need the matcher
  loosened is normally sending a mis-encoded query or reading the wrong field from a
  candidate; fix that instead.

---

## 2. What the service plugin must expose

Verify each of these against the service plugin's **deployed source**, and record the
`file:line` you verified it at. Never infer a signature from another service's plugin, and
never rely on a README.

| # | Requirement | Purpose | Symptom if unmet |
|---|---|---|---|
| **R1** | An album search entry point callable from outside the plugin: takes a query string, calls back with candidates | The album leg | Without it there is no adapter |
| **R2** | An album renderer that produces a playable item (`url` coderef plus `passthrough`, or a plain string `play` url) | Items must come from the service plugin's own renderer so they stay correct across its updates | A hand-built item breaks silently when the service plugin changes |
| **R3** | The renderer's `url` coderef must be reachable by name, e.g. `\&Plugins::X::Plugin::getAlbum` | Coderefs cannot be serialised, so cached matches are rebuilt on read (section 6) | The match plays once, then disappears on the next page open, with no error logged |
| **R4** | A track search whose rendered item carries a **plain string** url | Coderef urls cannot survive the resolved-playlist cache, so the track leg rejects them | Playlist rows silently drop out when the list is revisited |
| **R5** | A way to tell "could not query" apart from "queried, no results" | Chooses the cache TTL: a transient failure must retry soon, a real miss must not | A permanently unavailable service makes every genuine miss retry hourly, indefinitely |
| **R6** | Whether the plugin's URL layer wants **characters** or **octets** | Encoding is picked per adapter at the call site | Silent: accented names return nothing. Check this first on empty results |
| **R7** | An `<icon>` entry in the service plugin's `install.xml` | Used as the row thumbnail so the user can see which service matched | Rows render without an icon. Cosmetic |
| **R8** | The exact methods the adapter will call, testable with `->can` | `->can` on an absent package is safe, and is how "installed and enabled" is detected | Probing methods you don't call means the service stops registering if any of them is renamed upstream |

Optional; each degrades cleanly when absent:

| Field | Used for | If absent |
|---|---|---|
| Release type (`release_type`, `record_type`, `album_type`, `type`) or a track count | Classifying a candidate as album / single / EP, so a same-named single doesn't stand in for an album | Candidate is classified unknown and is never dropped |
| Release date or year on the search payload | Last-resort release year for date-ordered lists | Falls back to whatever date the source data carried |
| A native album id | Building a favourites url for the Listen to Later handshake | The row still plays; it just can't be saved with full metadata |

The service plugin does **not** have to resemble the others. A different calling convention
(class methods, renderers in a separate module, pre-normalised results) is fine. R1–R8 are
the requirements; family resemblance is not.

---

## 3. The adapter table entry

Reference shape (`ListenBrainzFreshReleases/Browse.pm:5688`):

```perl
push @adapters, {
    name      => 'Spotify',                       # display name, and the key for svc_priority_<lc name>
    icon      => _pluginIcon('Plugins::Spotty::Plugin'),
    run       => \&_searchSpotify,                # album leg  (section 4)
    runTrack  => \&_searchSpotifyTrack,           # track leg  (section 5) — omit if unsupported
    query_enc => 'chars',                         # 'chars' | 'bytes'  (R6)
} if Plugins::Spotty::Plugin->can('getAPIHandler')  # R8 — exactly the methods used, no others
  && Plugins::Spotty::OPML->can('_albumItem')
  && Plugins::Spotty::OPML->can('trackList')
  && Plugins::Spotty::OPML->can('album');
```

`name` is the adapter's identity: it keys the priority pref, the cache tag, the settings row
and the cached-item rebuild. It **MUST** stay stable once shipped — renaming it resets every
user's configured priority for that service.

Ordering and enablement are not the adapter's concern. A separate function sorts adapters by
`svc_priority_<name>` and drops any set to 0.

Where the table lives, and the legs each plugin defines:

| Plugin | Table | Legs |
|---|---|---|
| LBF | `ListenBrainzFreshReleases/Browse.pm:5688` | `run`, `runTrack` |
| PFR | `PitchforkReviews/Browse.pm:2124` | `run` |
| LL | none — see section 9 | — |

Where a plugin grows a third leg, prefer collecting them into a named sub-hash
(`legs => { albums => …, tracks => … }`, `undef` for one that isn't built yet) rather than
adding another top-level key, so adding a leg later never changes an adapter's arity.

---

## 4. Album leg (`run`)

```perl
sub _searchX {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;
```

Called once per enabled adapter, in parallel. The highest-priority service that matched wins
as soon as every service ahead of it has settled.

**Inputs.** `$query` is the raw artist name, already spelled per the adapter's `query_enc`.
`$artistNorm` and `$albumNorm` are normalised forms for validation only — never send them to
a service, because normalisation replaces punctuation with spaces and the service's own
search then fails to find stylised names. Validate every candidate with
`_albumMatches($artistNorm, $albumNorm, $candArtist, $candTitle, $albumRaw)`.

The search is deliberately wide and the filtering is local: search the **artist** and select
the album yourself. Searching "artist album" as one string makes services rank or drop the
target.

**Output — call `$collect` exactly once:**

| Call | Meaning | Cache TTL |
|---|---|---|
| `$collect->([$item, …])` | Matches found | 7 days |
| `$collect->([])` | Queried successfully, nothing matched | 24 hours |
| `$collect->(undef)` | Could not query: no handler, unexpected response shape, renderer failed | 1 hour |

`undef` means "ask again soon". Use it only for states that can clear on their own. A
**permanent** condition — for example, the service plugin is installed but has no account
configured at all — **MUST** report `[]`, because reporting it as inconclusive makes every
genuine miss re-search hourly for as long as that state lasts.

**MUST**

- Use asynchronous HTTP only. A leg that parses a large response synchronously blocks the
  server's event loop for every user, not just the caller.
- Wrap every call into the service plugin's renderer in `eval`. The leg runs inside an async
  callback, so a die there is not caught by the caller. Skip the bad item; if that leaves no
  items and a renderer failed, report `undef` rather than `[]`.
- Let the per-service timeout (8 seconds) settle the leg as inconclusive. Do not add an
  internal retry loop.

**MUST NOT**

- Set `image`. The caller replaces it with the service icon and passes the original artwork
  on to the favourites-url builder.
- Set `favorites_url`, unless the service plugin's own value is already correct and
  replayable. See `native_favurl` in section 8.
- Build a playable item by hand instead of calling the service plugin's renderer (R2).

**Fields to stamp on each matched item.** All plain scalars, so they survive caching:

| Field | Value | Used by |
|---|---|---|
| `_albumid` | Native album id — parse it from the item's uri if there is no bare id field | Favourites url / Listen to Later handshake |
| `_svctitle` | The service's own raw album title. Not the rendered row label (which usually has the artist baked in) and not the MusicBrainz title | The album name sent in the handshake |
| `_ctype` | `_candReleaseType($rawAlbum)` — `album`, `single`, `ep`, or `''` | Dropping a same-named single for an album target |
| `_year` | `_svcYear($rawAlbum)` | Release-year fallback in date-ordered lists |

The caller stamps the service name itself; the adapter does not.

---

## 5. Track leg (`runTrack`)

```perl
sub _searchXTrack {
    my ($client, $query, $artistNorm, $titleNorm, $album, $collect) = @_;
```

`$collect` behaves exactly as in section 4. Differences:

- **The url MUST be a plain string.** Items with a coderef url are filtered out, because a
  resolved playlist has to stay cacheable and stable in length. Set `url`, `play` and
  `type => 'audio'` to the same string.
- If the service plugin's renderer builds a composite label ("Title BY Artist FROM Album"),
  reset the item's `name` to the bare title. Downstream display and de-duplication both key
  on `name`.
- Validate with `_trackMatches`, accepting a match against **any** credited artist.
- Stamp `_year`.
- A leg that immediately calls `$collect->([])` is acceptable where per-track streaming isn't
  reliable, provided the reason is stated in a comment. Omitting `runTrack` entirely is also
  fine: the adapter is then simply skipped for tracks.

---

## 6. Caching and rebuilds

Matched items are serialised. The `url` coderef is stripped when an item is cached and
reattached, per service, when it is read back. Therefore:

- everything else on the item **MUST** be plain data, including the `passthrough` the service
  plugin's renderer set — that is where the album id has to live for the rebuild to work;
- no blessed references, no closures, and never the client object;
- **the rebuild path (R3) is mandatory.** An adapter with search and rendering but no rebuild
  will match, play, and then lose the match on the next page open without logging anything.

---

## 7. Summary: what not to do

- Do not add a per-service branch outside the adapter table.
- Do not bump a cache key when registering an adapter.
- Do not modify the shared matcher (`_albumMatches`, `_trackMatches`, `_norm`).
- Do not send normalised text to a service's search.
- Do not report a permanent failure as inconclusive.
- Do not return an item with a coderef url from a track leg.
- Do not construct playable items by hand.
- Do not probe methods with `->can` that the adapter does not call.
- Do not overwrite `image` or a working `favorites_url`.
- Do not perform synchronous network or parsing work in a leg.

---

## 8. Adapter-table fields still to be added

These sites currently need an edit when a service is added. Each is a one-off improvement to
the registry, not work for an adapter author; close them as they come up.

### LBF

| Site | What it does today | Field that removes it |
|---|---|---|
| `Browse.pm:6394` `_rebuildStreamItems` | Per-service branch chain mapping a service to its rebuild coderef | `rebuild => sub { … }` on the entry, resolved by name |
| `Browse.pm:6244` `_attachFavUrl` | Early return for the one service whose own favourites url is already correct | `native_favurl => 1` |
| `Browse.pm:6479` `_candReleaseType` | Reads a fixed list of type and count field names | Generic by field name already; a service using a new field name needs `type_fields` / `count_field` |
| `Browse.pm:6510` `_svcYear` | Reads a fixed list of date field names | `date_fields` |
| `Browse.pm:5985`, `:5192`, `:5239`, `:6705` | One service is excluded from automatic search and offered as a manual action instead | `auto_search => 0` and `manual_action => 1` |
| `Settings.pm:43` and `:121`, `Plugin.pm:262-266`, `Browse.pm:5794` | Four hand-maintained lists of service names | A single services table all four read. The settings template already iterates generically and needs no change |

### Other plugins

| Plugin | Sites | Field that removes it |
|---|---|---|
| PFR | `Browse.pm:3696` rebuild chain; `Browse.pm:2174`, where the adapter-list memo key is built from a fixed list of service names | `rebuild`; build the memo key from the table. **Do the memo key before adding a fourth service** — otherwise that service's priority changes will not invalidate the memo |
| LL | See section 9 | — |

---

## 9. Per-plugin status

| Plugin | Adapters | Cost of a new service today | Status |
|---|---|---|---|
| **LBF** | Qobuz, Bandcamp, TIDAL, Deezer, Spotify | About 200 lines: two legs, one pref default, one settings entry, one rebuild branch | Ready |
| **PFR** | Qobuz, TIDAL, Deezer | About 100 lines (album leg only), plus a rebuild branch, plus the memo-key fix | Ready once the memo key is table-driven |
| **LL** | qobuz, bandcamp, tidal, deezer, via a url-scheme map (`Sources.pm:26`) | Not a table entry — capability is expressed across roughly fifteen per-source branches in `Sources.pm` and `Plugin.pm` | Refactor first |

LL works differently by design: it does not search a service, it **recognises** one from the
url scheme of a row the user acted on, then replays it. Its contract is "recognise and
replay" rather than "search and render". Partial support (recognising a new scheme and
classifying album versus track) is a small change; full support (replay, playlist expansion,
track counts) requires the branches to be collected into a sources table of coderefs first.

---

## 10. Definition of done

Code:

- [ ] `perl -c` is clean — and note that it does **not** catch calls to subs that don't
      exist, so every new sub must be exercised at least once by a test or a manual run.
- [ ] Tests do not assert with a bare `ok($src =~ /re/, '…')`; in list context that passes
      when the match fails. Bind the match result first.
- [ ] No cache-key bumps, no shared-matcher changes, no new per-service branches.

On a server with the service plugin installed:

- [ ] The settings page lists the service, shows the correct installed state, and a changed
      priority takes effect on the next browse.
- [ ] A known album resolves to the service, and the log names the winning service.
- [ ] **Re-open the same page.** The match must still be present and still play. This is the
      rebuild test and it is the one most likely to be skipped.
- [ ] Setting the service's priority to 0 hides its cached matches immediately, without a
      re-search.
- [ ] With the service made to fail, the chosen TTL matches R5: a transient failure retries
      within the hour, a permanent one does not.
- [ ] An accented artist name returns results, confirming `query_enc`.
- [ ] If the adapter emits a favourites url, save a row in Listen to Later and confirm the
      artist, album, year and type all arrived intact.

State plainly in the commit and the pull request whether the adapter was **verified against
source only** or **run against a live install**. Both are acceptable; leaving it unstated
is not.

---

## 11. What the pull request must contain

1. A verification table: each claim about the service plugin's API, with the `file:line` in
   that plugin's source where it was verified.
2. Any deviation from the pattern in this document, with the reason.
3. A coverage statement: grep an existing service's name across the repo and confirm every
   site found is either updated or generic.
4. No changelog entry. The changelog is written when the branch is merged.

---

## Appendix — worked example: YouTube Music

Assessment of [`schmij97/lms-ytmusic`](https://github.com/schmij97/lms-ytmusic)
(`Plugins::YouTubeMusic`) against section 2, read from published source on 2026-09-02 and
not yet run.

| Req | Finding | Met |
|---|---|---|
| R1 | `Plugins::YouTubeMusic::API->search($query, 'albums'\|'songs', $cb)` | Yes |
| R2 | `Plugin::_items_to_menu` renders albums with `url => \&_playlist_menu`, `passthrough => [{ browseId }]`, `play => ytmplaylist://<id>` | Yes |
| R3 | `\&Plugins::YouTubeMusic::Plugin::_playlist_menu`, with `browseId` in the passthrough | Yes |
| R4 | Songs render `url => "ytm://<videoId>"`, a plain string | Yes |
| R5 | The API layer calls back `undef` on transport or JSON failure and an arrayref otherwise | Yes |
| R6 | Escapes with `uri_escape_utf8` → `query_enc => 'chars'` | Yes |
| R7 | `<icon>` present in `install.xml` | Yes |
| R8 | Probe `API->can('search')`, `Plugin->can('_items_to_menu')`, `Plugin->can('_playlist_menu')` | Yes |

Two items to settle before or during implementation:

- **Type and year.** No release-type field is exposed, so candidates classify as unknown.
  The `year` field is read from a column that the service often fills with the release type
  instead, so confirm it against live results before stamping `_year`.
- **Availability signal.** Search is served by a local helper process rather than by the Perl
  plugin itself. `->can` confirms the plugin loaded, not that the helper is running, so an
  unreachable helper reports inconclusive. If that state can persist, detect it and report a
  real miss instead, per R5.

Catalogue precision is lower than the subscription services, since the search index includes
re-uploads and alternate versions. A low default priority is appropriate.
