# ListenBrainz Fresh Releases — Version History

Split out of `CLAUDE.md` (2026-09-10) so the Review Ledger is not buried behind 1,280 lines
of changelog. Nothing reads this file automatically. Append new entries at the END;
user-facing release notes still go in `CHANGELOG.md` on a main merge.

- **0.9.160** — **the ListenBrainz token is now OPTIONAL. `fresh_releases` — the flagship feed — had
  been gated on a credential the endpoint has never required.** This is §3.1 of
  `docs/token-free-refactor.md`; §3.2/§3.3 remain open and §4 was dropped.
  - **RE-VERIFIED LIVE BEFORE ANY CODE, against the real configured account** (the 2026-07-31 scoping
    pass used borrowed test users). Each endpoint fetched twice, anonymous and authenticated, and
    compared: `fresh_releases` came back **byte-identical** (same sha1 over `payload.releases`, same
    count, same 13 fields per release), as did createdfor + `/1/playlist/<mbid>`, `cf/recommendation`,
    `following`, `listens`, both `stats/user/…` ranges, `metadata/recording` and
    `popularity/top-recordings-for-artist`. **`/1/user/<u>/feed/events` returned the only 401 in the
    entire plugin.** Six individual followers' weekly stats compared identical too — which also
    settles that a token could never have unlocked a *follower's* private stats (it authenticates you,
    not them), so the Trending fan-out was never in question.
  - **CHANGED — two gates, both on the same feed:** `API::getFreshReleasesForUser` now returns early
    only `unless ($username)` and pushes `Authorization` only when a token is set (the
    `getFollowing`/`_getUserStats` shape); `Browse::topLevel` gates the New Releases for You tile on
    `$username` alone. The error string no longer blames the token — it used to send a tokenless user
    to fix the wrong field.
  - **DELIBERATELY NOT CHANGED — all four follow-feed gates** (`getFollowFeed`, `_followTile`,
    `_warmFollow`, the unmatched-debug entry). **These gates are CORRECT and must stay.** They are
    what turns "no token" into a tile that is simply absent; strip them and a tokenless user gets an
    opaque runtime 401 instead. This is the likeliest way a future "finish the token-free work" pass
    goes wrong, which is why it is pinned by a test rather than a comment.
  - **An empty `Authorization: Token ` header is worse than none** — a malformed credential rather
    than an anonymous request — so the header is omitted entirely rather than sent empty. Asserted.
  - **NO CACHE BUMPS.** Nothing about any cached shape or any cached *decision* changed — the same
    URL returns the same payload either way, which is the whole finding. Bumping would force a
    pointless full re-resolve; the standing dev-build "invalidate everything" habit does not apply.
  - **`tools/t_tokenfree.pl` — 23 assertions.** Sections 1-3 are BEHAVIOURAL: `API.pm` is loaded for
    real and `getFreshReleasesForUser` driven through a recording HTTP stub, so they assert what the
    sub *does* (does it request, with which headers), not how its source reads. Section 4 is
    source-level, for the 0.9.145 reason — there is no return value to inspect when the point is that
    a sub was NOT reached. **Anti-tested three ways** via `LBF_API=`/`LBF_BROWSE=`: restoring the old
    gate = 7 red, unconditional auth header = 2 red, dropping `_followTile`'s `if $token` = 1 red.
  - **THE TEST LESSON, and it is the 0.9.149 trap again, caught only by the anti-test run.** Two of
    my own assertions used a bare `m//` in `ok()`'s LIST-context argument slot, so the match returned
    a match LIST, the args shifted, and the label became the condition — they PASSED against any
    truthy string. The baseline was green and meaningless for those two. The mutation run is what
    exposed it, then exposed a third. `ok()` now **dies** on a missing message rather than printing a
    blank label, so a recurrence is loud instead of silent. **Wrap every match and grep in
    `scalar()`** — this has now cost two suites in this repo.
- **0.9.159** — **`MB_PROBE_MBID` was never a real artist, so `autodetectMirror` has NEVER adopted a
  mirror since 0.9.94. Found by 0.9.158's diagnostic on its FIRST real run — which is the whole
  argument for having built it.**
  - **THE REPORT:** Simon's own box, a working mirror at `plex:5000`, returned
    `MusicBrainz (local mirror)  Check  HTTP 404` while the row beneath it,
    `artist/?query=Radiohead` against the SAME base, returned 29 results. Browse dead + search alive
    is the inverse of the usual mirror gotcha, which is what made it obviously not a mirror problem.
  - **VERIFIED against public MusicBrainz before changing anything** (the mirror was never the
    suspect once both ids were checked):
    ```
    a74b1b7f-06a0-4672-a641-eb3353aa608d -> 404   (mirror AND musicbrainz.org)
    a74b1b7f-71a5-4011-9441-d0b5e4122711 -> 200   Radiohead
    ```
    A fabricated UUID that copies Radiohead's FIRST BLOCK and diverges — which is exactly why it
    survives review: it looks like a real id, and it looks like the right one.
  - **THE IMPACT is not the diagnostic row, it is the feature.** `autodetectMirror` validates a
    candidate by fetching this artist and comparing `name`. It could never validate, so no mirror was
    ever adopted and **every install with a blank `mb_base_url` and a same-host mirror has run the
    whole plugin against the public API at 1 req/s since 0.9.94**, re-probing daily. Simon's own box
    is unaffected — his base is set by hand, which is also why nobody noticed.
  - **WHY NO EXISTING TEST COULD HAVE CAUGHT IT: the failure is INVISIBLE BY CONSTRUCTION.** A 404 on
    the probe artist is indistinguishable from "nothing is running on :5000" — the correct, silent,
    overwhelmingly common outcome. Every stubbed test passes with a bogus id because the stub supplies
    the reply. Only MusicBrainz can be asked.
  - **`tools/t_diag.pl` section 7 asks it**, and fails the suite unless `MB_PROBE_MBID` really is
    `MB_PROBE_NAME`. **Skipped cleanly when offline.** **Its first cut was itself broken and the
    anti-test is what exposed it:** it keyed "offline" on an EMPTY BODY, and MusicBrainz answers a 404
    with an empty body — so the bogus id SKIPPED rather than failing, making the gate decorative
    against the one bug it exists to catch. It now reads `%{http_code}` separately: `000` = skip,
    non-200 = fail, 200 = compare the name. **Anti-tested both directions** (old constant -> 1 red,
    new -> green). Don't collapse the status and the body again.
  - **FLEET: this is a PORT, not a discovery — Discography hit the identical bug and fixed it in
    0.30.2**, with the same reasoning and a live gate in its `tools/syntax_check.sh`. LBF carried the
    bad constant the whole time because the fix was never ported. `MB_PROBE_MBID` is NOT part of the
    shared matcher, so `matcher_sync_check.py` says nothing about it — worth remembering that the sync
    rule covers the matcher and nothing else, and constants like this can drift indefinitely.
  - **No cache bump.** `lbf:mbmirror:v1` holds `''` (probed, none found) at a 1-day TTL, so every
    poisoned entry self-heals within 24h of the update.
  - Also: the CAA row's note no longer quotes "HTTP 404" back at the user. The 404 is the deliberate,
    data-independent design of that probe (an ARTIST mbid on a RELEASE endpoint, so no album's art can
    ever be removed and turn the row red for everyone); it now says so. Prompted by the same report
    asking whether the 404s were expected — one was, one very much was not.
- **0.9.158** — **the credential check moved OFF the user's browser and became a server-side
  connectivity report (`Diag.pm`). The bug report that prompted it is worth keeping, because the
  message was accurate about its own failure and useless about the plugin's.**
  - **THE REPORT (0.9.149, from the field):** *"Could not reach ListenBrainz to check the token."*
    **THE FACT THAT SETTLED IT:** that string is `PLUGIN_LBF_TOKEN_NET_ERROR`, painted by the
    `.catch()` of a `fetch()` in `settings.html` — **running in the USER'S BROWSER**, straight to
    `api.listenbrainz.org`. **The LMS server never made a request**, so there was nothing in log.txt
    to ask for, and the message said nothing whatsoever about whether the plugin worked. Verified
    byte-identical in `v0.9.149` and dev, so it was never a regression.
  - **What that catch actually catches**, none of which involves the server: a Pi-hole/NextDNS/uBlock
    rule on the browsing DEVICE (a cross-origin request to a third-party domain from an intranet page
    is exactly the shape blockers kill); a `connect-src` CSP from a reverse proxy (nginx/Caddy/
    Cloudflare Tunnel/HA ingress with hardened headers); and — the one that looks least like a network
    problem — **a captive portal or intercepting proxy returning HTML, because `r.json()` rejecting
    lands in the same `.catch()` as a dead socket**. Ruled OUT and not worth chasing: mixed content
    (an http page fetching https is allowed), and a missing `fetch` (that throws before the promise
    chain, so the status would stick on "Checking token…", not show this).
  - **THE SCOPE DECISION, and it is the reason this is not dead code under the token-free work.**
    A better token check would have been thrown away by `docs/token-free-refactor.md`. What survives
    the token going away is "the feed is empty and I cannot tell which of seven upstream dependencies
    is unreachable" — so the token became ONE ROW of a connectivity report covering ListenBrainz, LB
    Labs, MusicBrainz **via `_mbBase` so it tests the user's mirror**, the MB **search index**, the
    Cover Art Archive, and Last.fm/MuSpy when configured, plus the server proxy pref and
    `serviceStatus()`.
  - **THREE OUTCOMES, NOT TWO — the actual design content.** `fail` = nothing answered (DNS/TLS/
    network). `warn` = **the host ANSWERED and the answer is wrong** (rejected token, HTTP 500,
    something that is not MusicBrainz on :5000, a search index returning 0). `skip` = not configured.
    Collapsing `warn` into `fail` re-creates the exact ambiguity this replaces, silently — which is
    why `_httpCode` digs a status out of the error STRING when `$resp->code` is unset, rather than
    misreporting an answered request as a network failure, and why anti-test 1 of the suite is that
    collapse.
  - **The MB search-index row earns its place on its own.** A musicbrainz-docker mirror serves browses
    from Postgres and SEARCH from Solr; an unbuilt index returns 0 for everything while every browse
    passes. Both rows come from the same `_mbBase`, so the identity row goes green and the search row
    goes amber — previously diagnosable only by hand ([[mb-mirror-search-index-gotcha]]).
  - **CAA is probed with an ARTIST mbid on purpose**, so it correctly 404s: an HTTP status proves DNS,
    TLS and HTTP all reached it, which is the only claim that row makes, and it avoids hardcoding a
    release mbid whose art could later be removed. Same `answered_ok` flag as the no-token LB probe.
  - **`["lbf","diag"]` is a CLI dispatch, not a private endpoint for the page**, for one reason: it is
    the only surface a REMOTE user can reach (settings pages are LAN-only) and the only one a headless
    run can verify. "Paste this" replaces "send me log.txt".
  - **The page now calls `/jsonrpc.js` SAME-ORIGIN**, so CORS, proxy CSP and blockers are out of the
    loop by construction. **Do not "simplify" it back to a direct fetch of api.listenbrainz.org.** A
    401 renders as "Lyrion is password protected", explicitly — reintroducing a generic unreachable
    message there would rebuild the original bug one layer down.
  - **The report is meant to be pasted into a forum thread, so it must be safe to paste.** The probe
    URL and the DISPLAY url are separate fields (`url` vs `display`); credentials appear only as
    `set (36 chars)`. Asserted, including that the real token IS still sent — a redaction that also
    redacted the wire would test nothing.
  - **Behaviour change worth knowing:** the check reads SAVED prefs, where the browser check read the
    typed field. The page captures each field's rendered value and says "save first" when it differs,
    rather than reporting a stale answer as current.
  - **NO CACHE BUMPS.** Nothing here reads or writes a plugin cache — a diagnostic makes no cached
    decision — so the standing dev-build "invalidate everything" habit would force a full re-resolve
    of every album and playlist for zero benefit. Retired strings: `PLUGIN_LBF_TOKEN_NET_ERROR`,
    `_TOKEN_CHECKING`, `_TOKEN_EMPTY` and the four `_LASTFM_*` browser-check strings (the server-side
    `_TOKEN_CHECK_FAILED`/`_VALID`/`_INVALID` stay — `Settings::handler` still validates on save for
    the classic skin).
  - `tools/t_diag.pl` — **53 assertions** against the REAL `Diag.pm` (loaded, not extracted) over a
    driveable HTTP stub. **Anti-tested twice:** collapsing warn into fail = 6 red, removing the URL
    redaction = 2 red. The settings panel was separately driven through a fake DOM with the strings
    resolved from the real `strings.txt` (27 checks: rendering, the 401 path, note escaping, the
    unsaved-field guard) — worth redoing that way if it changes, since three "failures" on the first
    run were the harness stubbing the strings out, not the code.
- **0.9.157** — **THE ACTUAL CAUSE of "no section titles", found only when Simon sent a screenshot.
  Everything 0.9.152–0.9.156 changed was downstream of it and could never have fixed it.**
  - **THE ONE FACT THAT MATTERED, and I had it backwards for five builds: at RUNTIME MAI RETURNS
    HTML, NOT PLAIN TEXT.** `MusicArtistInfo::Plugin::isWebBrowser` is true for a Material client
    (`$client->controllerUA`), so `getBiography` yields `$bio->{bio}` — `<p>`/`<h2>`/`<b>` markup with
    a `<link rel=stylesheet>` prepended. **The same call over the CLI returns `bioText`, the plain
    hard-wrapped render with setext underlines.** Every fixture I built came from the CLI, so my whole
    corpus was the wrong string. Reproduce the REAL one with
    `musicartistinfo biography html:1 artist:<n>` (3200 chars for Lambchop vs 1730 plain).
  - **THE TELL I SAW AND DISMISSED:** the live log says `MAI bio len=1727` while the CLI returns
    **1730**. Three characters apart, so I read it as the same string. It was not.
  - **THE BUG:** `API::_cleanBio` broke paragraphs only on `</p>\s*<p>` ADJACENCY, and replaced every
    other tag with a SPACE. So `</p><h2>Description and history</h2><p>` matched nothing and the
    heading dissolved mid-sentence — "…Tennessee. Description and history Initially formed…". **There
    was never a heading block for Browse to detect, style, or embolden.** The stray "Lambchop ,
    originally Posterchild ," spacing in the screenshot is the same rule eating `<b>`.
  - **THE FIX, all in `_cleanBio`, structure BEFORE tag-stripping:** `<h1-6>` becomes a SETEXT block
    (`title\n----------`) — deliberately reusing the shape `_bioBlocks` already detects and is tested
    for, so MAI's HTML and plain-text renders share one code path; `<li>` becomes `\n* ` (the marker
    `_bioBullet` knows); block closers become blank lines; inline tags are removed rather than spaced.
  - **`<li\b` — the `\b` IS LOAD-BEARING.** Without it `<li[^>]*>` also matches MAI's prepended
    `<link rel="stylesheet"…>`, which became a stray bullet that swallowed the opening paragraph.
  - Empty `<li>`/`<p>` left behind by the `<a>` strip are dropped (MAI's "More online sources" link
    list), and `_bioParagraphs` pops trailing headings so that section's now-empty title is not shown.
  - **`lbf:bio:2:`→`:3:` — REQUIRED.** The cache stores the CLEANED text, so every existing entry
    holds the flattened version and would keep serving it for the 30d TTL; without the bump the fix
    would look like it had not shipped.
  - **METHOD, and the lesson of the whole episode:** I verified the parser, the CSS cascade, the
    computed font-weight and the row markup — all correct, all downstream. The defect was in the INPUT,
    and one screenshot showed it instantly ("Description and history" mid-paragraph, spaces before
    commas). **When output is wrong and every stage checks out, the fixture is wrong — go get the real
    input the running code sees, not the one a convenient CLI hands you.**
  - `tools/t_bioreveal.pl` **106 assertions**; new section 14 drives the REAL MAI HTML shape through
    `_cleanBio` (now grabbed from API.pm — half the pipeline was previously untested) into the row
    builder. `LBF_API=` points it at a mutated copy; removing the `<h>` rule = 6 red.
- **0.9.156** — **NEVER BOLD A PROSE ROW WITH A BARE `<b>`. Use an explicit `font-weight`.** This is
  the actual cause of "headings bold on iOS, nothing in Chrome", after three builds of wrong theories.
  - **MEASURED in headless Chrome, inside Material's own row markup:**
    | markup | computed weight |
    |---|---|
    | `.v-list__tile__title` (the parent) | **200** (`font-weight:200!important`) |
    | body prose div | 200 |
    | **`<b>` tag** | **400** |
    | **`font-weight:bold`** | **700** |
  - **WHY.** A `<b>` gets only the UA stylesheet's `font-weight:bolder`, and CSS resolves `bolder`
    RELATIVE to the inherited weight — from 200 it lands on **400**, not 700. So the heading is 400
    against body 200. On iOS, where the font has a genuine 200 thin face, that reads as bold. In a
    desktop browser whose font stack has NO 200 face, the body already renders at 400 — heading and
    body become **byte-identical** and the bold vanishes entirely. Same markup, same bytes, opposite
    result, purely from which font faces the client has.
  - **This was documented as a hazard in 0.9.152 and then reintroduced in 0.9.155**, when the `<b>`
    was copied from Discography's meta-title row and the explicit weight dropped at the same time.
    Discography's rows that actually render bold everywhere use `style='font-weight:bold'`
    (`Browse.pm` ~2594); its `<b>` sits on a row where the surrounding weight differs. **Copying a tag
    without copying the declaration that makes it work is what cost the build.**
  - **METHOD NOTE — the measurement that settled it took two minutes and could have been made on day
    one:** render the plugin's REAL emitted markup inside the live `style.min.css` in headless Chrome
    and print `getComputedStyle(...).fontWeight` for each row. `--headless --dump-dom` with a `<pre>`
    the page fills in. Do that BEFORE reasoning about the cascade; a computed value is evidence, a
    specificity argument is not.
  - Live rows verified over the LMS CLI on **port 9090** (`nc plex 9090`) — the JSON-RPC endpoint was
    closing plugin `items` requests instantly (0.02s, empty body) while core commands answered, so the
    CLI is the reliable way to read what a plugin actually emits. Worth remembering.
  - `tools/t_bioreveal.pl` **94 assertions**; the heading test now keys on the explicit weight and
    asserts the absence of a bare `<b>`. Anti-tested by restoring the 0.9.155 `<b>` = 7 red.
- **0.9.155** — **the bio renders EXACTLY as Discography's does, because that one works on desktop and
  iOS and three of my attempts did not. COMPARE THE TWO OUTPUTS BEFORE TOUCHING THIS.**
  - **The comparison that ended it** (`tools/` has no runner; it was a scratch script running BOTH
    plugins' real subs over the SAME MAI bio). Discography: `_stripHtml` -> `split /\n{2,}/` ->
    **one `_proseRow` per paragraph**, each `<div style='margin-left:72px'>text</div>`, bold via a
    plain `<b>` (its meta-title row, `Browse.pm` ~3396). Ours at 0.9.154: **ONE row** holding a
    wrapper div with `max-width:1000px;margin:0 auto;line-height:1.5;font-weight:400` and
    `<h3>`/`<p>`/`<ul>` inside. Same bio, completely different shape.
  - **THE MISTAKE THAT COST THREE BUILDS.** 0.9.152 collapsed the bio to ONE row to stop the iPad
    overlap. That treated the symptom. The overlap came from **92 rows**, and those came from the
    broken paragraph detection (a hard-wrapped MAI bio split at every wrapped LINE) — NOT from having
    a row per paragraph. Once `_bioBlocks` parses correctly the same bio is **10 rows**, exactly what
    Discography emits, nowhere near the 100-item scroller threshold. **Row-per-paragraph was never the
    hazard; bad parsing was.** Verified: LBF and DSC now emit 10 rows for Lambchop and 15 for Dean De
    Benedictis — identical counts.
  - **What we keep over Discography** (the parsing, which is genuinely better): setext underlines are
    consumed instead of being collapsed onto the end of the title — DSC renders
    `Description and history -----------------------`, we render a bold `Description and history`;
    bullets are detected and never emboldened; headings survive in bios that fail the wrap test.
  - **DO NOT reintroduce a single-row wrapper with its own typography.** Measured in headless Chrome it
    computes perfectly (1000px centred, weight 400, `<h3>` 700) and it still did not render as intended
    on every client. The lesson is that measuring a component in isolation is not evidence about the
    app; the only evidence that counted was the side-by-side against a plugin known to work.
  - No cache bumps (render only). `tools/t_bioreveal.pl` **93 assertions**; anti-tested three ways —
    backwards underline-marking removed = 3 red, `_bioBullet` disabled = 9 red, the heading `<b>`
    removed = 6 red.
- **0.9.154** — **the bio is typeset by US, not by the list row. This is the fix for "bold headings on
  iOS, nothing on desktop", and the reason the previous three builds missed it is worth reading.**
  - **WHAT I KEPT GETTING WRONG:** I verified the SERVER output (which blocks are headings) and the
    CSS cascade, and both were correct — Chrome computes `font-weight:700` on our heading div, measured
    in headless Chrome against the live stylesheet. So the markup and the styling were never the bug.
    **The container was.** We render into `.browse-text`, a LIST ROW, whose typography is the skin's
    and varies by platform; MAI renders into `.browse-html`, a prose renderer.
  - **WHAT MAI DOES (the answer Simon pointed at).** It emits the bio as ONE `type=>'textarea'` item;
    Material turns that into a level of exactly one `html` item, and `browse-page.js` renders THAT via
    `.browse-html`: `line-height:1.5; padding:12px 16px; max-width:var(--dialog-list-max-width)` (=
    **1000px**) with `margin-left/right:auto`, and no per-row height floor. **That path needs a level
    of exactly ONE item, so an inline expand can never reach it** — which is why we cannot simply
    switch to it without giving up the in-place reveal.
  - **THE FIX: rebuild that typography inside our own wrapper div, in the row.** The row's
    `font-weight:200!important` / `font-size:…!important` are declarations on the
    `.v-list__tile__title` ELEMENT — they cannot match elements we create inside it, so our own values
    win with no `!important` needed. MEASURED in headless Chrome at a 1600px viewport: wrapper width
    **1000 centred (300px each side)**, computed weight **400**, `<h3>` **700**, `<ul>` markers `disc`,
    row height 182px (it grows — `.browse-text .v-list__tile` has `height:unset!important`).
  - **`width:100%` on the wrapper is REQUIRED, not cosmetic.** The title element is `display:flex;
    flex-direction:column; align-items:flex-start`, so without it the wrapper shrinks to its content
    and `margin:0 auto` has nothing to centre within.
  - **Semantic tags, and `<b>` inside the `<h3>`.** `<b>` is the bold idiom Discography has shipped in
    its meta-title row all along (`Browse.pm` ~3396) and which Simon confirms renders on both desktop
    and iOS, so it is carried as well as — not instead of — the explicit weight. A `<b>` ALONE is not
    enough (UA `bolder` against the inherited 200 lands near 400); the two together are.
  - `<p>` per paragraph, `<ul>`/`<li>` for a run of bullets so the browser supplies the marker and the
    hanging indent, and the LAST block carries no bottom margin so the row ends flush.
  - No cache bumps (render only). `tools/t_bioreveal.pl` 93 → **96 assertions**.
- **0.9.153** — **the bio's STRUCTURE parser, and the two ways 0.9.152's first cut of it was wrong.
  Both were found by reading the LIVE row off the server, not by reasoning about the code.**
  - **THE METHOD THAT FOUND BOTH, use it first next time.** Fetch the emitted row over JSON-RPC
    (`listenbrainzfreshreleases items 0 12 item_id:<rel>`, expanding the bio by hitting the toggle's
    item_id first) and read the `name` field, then fetch the SOURCE the same way
    (`musicartistinfo biography html:0 artist:<n>`). That took minutes and settled what several rounds
    of reasoning about Material's CSS could not: the server was emitting exactly the markup intended,
    the client was rendering it faithfully, and **the defects were in which blocks we had classified**.
    `tools/` has no runner for this; the recipe is in [[lms-server-http-testing]].
  - **BUG 1 — headings were gated on the WRAP TEST, so most bios had none.** 0.9.152 ran the whole
    structure parser only inside the `_bioHardWrapped` branch. That test is a WRAP detector; it says
    nothing about whether a document has sections, and it correctly returns false for any bio whose
    lines end on full stops. In those the headings stayed body text **and the setext underline was
    never consumed**, so it rendered as a row of literal dashes. **A setext underline is unambiguous
    in ANY source** — it must always be consumed and must always mark what it underlines.
    - `_bioUnwrap` is now **`_bioBlocks($bio, $wrapped)`**, the single parser for both shapes.
      `$wrapped` changes EXACTLY TWO things and nothing else may be made conditional on it: whether a
      lone newline is a wrap artefact to rejoin or a real break, and whether `_bioLooksLikeHeading`
      (the BARE-line test) may run at all. That test stays gated because it is only sound on a wrapped
      document, where a body paragraph is multi-line by construction — ungated it would promote
      ordinary short sentences wholesale.
    - `$underlined` can now reach BACKWARDS to `$out[-1]`, because when a lone newline is a break the
      heading has already been closed by the time its underline is read.
  - **BUG 2 — every BULLET was rendered as a heading.** A list entry (`  * Dean De Benedictis`) is one
    short line with no terminal punctuation — precisely the bare-heading signature. Measured on the
    live row: the Dean De Benedictis bio emitted **8 bold divs**, of which 5 were roster entries, which
    is what buried the 3 real titles and is what Simon meant by "showing no title/headers".
    New `_bioBullet` (marker + REQUIRED whitespace, so a hyphenated word can't open a list) tags those
    blocks `bullet`; a bullet is never a heading, keeps its marker, and gets a hanging indent.
  - **`_proseBlock` now gives a heading THREE cues, deliberately.** `font-weight:700` does the work
    (Material's `font-weight:200!important` is on `.v-list__tile__title`, so a declaration on our child
    div wins). A `<b>` INSIDE it is semantics plus a floor if the inline style is ever lost — note
    `<b>` ALONE still doesn't work, for the reason 0.9.152 recorded (UA `bolder` resolves relative to
    the inherited 200 → ~400), so this is belt AND braces, not a replacement. `font-size:1.08em` is the
    third cue, for where a bold face is unavailable and the browser won't synthesise one.
  - **VERIFIED on five real live bios through the real subs:** Dean De Benedictis 3 headings + 5
    bullets (was 8 bold), Radiohead **21** headings all genuine Wikipedia sections, Becky G 17 likewise,
    Tyondai Braxton 5, Brama 0 (a 3-paragraph Last.fm bio, correctly left alone).
  - No cache bumps — `lbf:bio:2:` stores the RAW bio and the parse happens per render, so nothing
    cached can serve stale structure.
  - `tools/t_bioreveal.pl` 75 → **93 assertions**; new sections 12 (a setext heading in a NOT-wrapped
    bio) and 13 (bullets). **Anti-tested per defect**, and the split is the point: removing the
    backwards underline-marking fails ONLY section 12's 3 assertions, disabling `_bioBullet` fails ONLY
    section 13's 7 — so the two fixes are independently covered rather than jointly.
- **0.9.152** — **prose rows and Material's list layout: the field report was "empty space on iPad
  landscape, renders over itself on iOS, fine on PC/Mac". Both symptoms are ONE cause of ours, and
  0.9.151's measurement is what missed it.**
  - **MEASURE THE SOURCE — AGAIN, AND THIS TIME ALL OF IT.** 0.9.151's table was built from **Last.fm**
    bios and concluded "a lone `\n` is a deliberate break, they are not column-wrapped". True of
    Last.fm. **The MAI path was never sampled**, and MAI hands us a plain-text render (Wikipedia-derived)
    that is **hard-wrapped at ~72 columns with setext headings**. Measured live on the server
    (`musicartistinfo biography html:0 artist:Tyondai Braxton`, 5805 chars, 113 lines): max line **78**
    chars, 74 of the 92 non-blank lines between 60 and 78, `Early life` followed by `----------`.
    Under rule 1 that became **92 one-line "paragraphs"**. Both sources go through `API::_cleanBio`,
    which is exactly why 0.9.151 believed one measurement covered both.
  - **WHY IT LOOKED LIKE A RESPONSIVE/PWA BUG AND ISN'T.** Verified against the LIVE Material 6.4.5
    `material.min.js` + `style.min.css` (not the 6.4.4 source copy):
    - every prose row's title carries `min-height: var(--list-elem-height)` = **48px**. A fragment that
      wraps to ONE display line on a wide screen still occupies a full row → **the iPad-landscape gaps**;
    - `useRecyclerForLists(){return !this.isTop && this.items.length>LMS_MAX_NON_SCROLLER_ITEMS && ...}`
      with `LMS_MAX_NON_SCROLLER_ITEMS=100`. **The expanded detail page measured 122 items**, so it
      crossed into the virtual scroller: `:item-size="LMS_LIST_ELEMENT_SIZE"` (**fixed 48**) and every
      row `position:absolute` (vue-virtual-scroller). In that path text rows get `browse-text-inrecycler`,
      which — unlike `browse-text` — has **NO `height:unset`** rule, so a row taller than 48px is
      **drawn over the row below**. On a narrow column those 72-char fragments wrap to 2-3 lines →
      **the iOS overlap**. On a wide desktop they fit inside 48px, which is why PC/Mac looked merely loose.
    So Material's limit is real, but we were the ones feeding it 92 rows and tipping it past 100.
  - **FIX 1 — `_bioHardWrapped` + `_bioUnwrap`, a rule 0 ahead of 0.9.151's rules.** Detection needs
    **TWO signals, both required**, because each alone has a real false positive: (a) no line exceeds
    `BIO_WRAP_MAX_COL`=100 — a wrap column is a ceiling, real paragraphs run past it; alone it admits
    any bio of short deliberate lines; (b) **more than half the non-final lines end MID-SENTENCE** — a
    wrap cuts where the column falls, a deliberate break lands on a full stop; alone it admits a long
    unpunctuated run. Plus a `BIO_WRAP_MIN_LINES`=4 floor. A false positive costs one joined paragraph,
    never a broken render, which is why the gates are set to prefer leaving 0.9.151 alone.
    Setext underlines (`^[-=_~*]{3,}$`) are dropped AND **close the current paragraph**, so a heading
    cannot run into the body beneath it.
  - **FIX 2 — `_proseRow` -> `_proseBlock`: the whole bio is ONE row, paragraphs as inner `<div>`s.**
    One 48px floor instead of N, spacing from `PROSE_GAP` (a typographic measure, not a row height),
    trailing paragraph deliberately gap-less, and an item count that **cannot** tip the page into the
    scroller. Deliberately NOT width-capped: Material's own `browse-html` centres at
    `--dialog-list-max-width`, but that path needs a level holding exactly ONE item, and centring just
    this row would misalign it against the tracklist and metadata rows beside it.
  - **FIX 3 — SECTION HEADINGS ARE KEPT AND RENDERED AS HEADINGS** (Simon's follow-up: they survived
    0.9.152's first cut but looked identical to body text). **TWO shapes in the SAME document, which
    is why the underline cannot be the only signal** — measured in the Braxton bio: `Early life` and
    `Career` are setext-underlined, while `Early solo work and Battles (2000-2009)` and two more are
    BARE short lines with a blank line either side. So:
    - the underline is consumed by `_bioUnwrap` but taken as EVIDENCE (`$underlined` closes the block
      AND marks it a heading, whatever it looks like);
    - `_bioLooksLikeHeading` catches the bare ones: a block that is ONE source line, under
      `BIO_HEADING_MAX_COL`(80), not ending in `.!?;,`. In a hard-wrapped document a body paragraph is
      by construction multi-line and ends on a full stop, so it is the PAIR that does the work. `:` is
      deliberately not disqualifying ("Discography:").
    - **`_bioParagraphs` now returns `{ text, heading }` entries on every path** — the structure is
      carried rather than re-derived in the renderer, because the underline is gone by then.
    - `_proseBlock` renders a heading `font-weight:700` + `margin-top:`PROSE_HEAD_ABOVE +
      `margin-bottom:`PROSE_HEAD_BELOW (more air above than below, so a title binds to its body).
      **`font-weight:700`, NOT a `<b>` tag** — Material sets `font-weight:200!important` on the row's
      title element and `<b>` only gets the UA `bolder`, which resolves RELATIVE to that inherited 200
      and lands on a near-invisible 400. An explicit weight is a declaration on the child, so the
      parent's `!important` never enters into it.
  - **RESULT, on the real bio through the real subs: 92 rows -> 1 row / 16 paragraphs (5 of them
    headings, all correctly marked); detail page 122 items -> 31** (16 fixed rows + 15 tracks, for the
    measured release).
  - ~~**THE PROPERTY THAT MATTERS MOST, and it is not the row count itself: expanding the bio now costs
    the SAME two rows as collapsing it** (text + toggle, either way) … **So the bio can no longer push a
    page into the scroller at all** — page size is now purely a function of tracklist length.~~
    **NO LONGER TRUE — SUPERSEDED BY 0.9.155, corrected here 0.9.161.** 0.9.155 deliberately went back
    to **one row per paragraph** (matching Discography) once `_bioBlocks` parsed correctly and the same
    bio came out ~10 rows instead of 92 — the hazard was bad parsing, never row-per-paragraph. So
    **expanding adds N rows again** and the bio DOES contribute to `LMS_MAX_NON_SCROLLER_ITEMS` (100)
    alongside the tracklist. Read the residual below with that in mind: the ~85-track figure assumed a
    fixed-cost bio, and the real threshold is ~10 rows lower for an artist with a long biography. The
    call-site comment in `_artistRows` claimed the old property until 0.9.161 too.
  - **KNOWN RESIDUAL — OPEN, Simon's call 2026-08-05 ("leave it open, may address later"), do NOT
    silently close it.** The detail page emits one text row per TRACK, so ~16 fixed rows + N tracks
    means a release needs roughly **85+ tracks** (box set / big compilation) to cross
    `LMS_MAX_NON_SCROLLER_ITEMS` on its own. Above it every row is pinned to 48px and the tall bio row
    is drawn over the tracks below — the same field bug, confined to very long releases. Note it is
    not only the bio: in that mode ANY row wrapping past one line overlaps (a long track title or
    Genres line on a phone). **Fix when it bites:** page the tracklist with the existing
    `_pageSection`/`_pageRow` + `%pageState` (as All Releases weeks do), which also caps the page size
    permanently so nothing added later can drift back over 100. ~1 hour with tests. Deferred because
    no such release has been reported AND the paging rows shift item_ids — safe only because
    `_releaseDetail` emits the Streaming section FIRST (the 0.6.11 rule), which is worth re-checking
    before building it.
  - **FLEET: Discography has the same class of bug, opposite symptom.** `Browse.pm` ~1806 and ~3432
    split on `/\n{2,}/` only, so a hard-wrapped source with no blank lines collapses into ONE giant
    row — harmless in the normal path (`browse-text` has `height:unset`) but DSC artist views routinely
    exceed 100 items, so it lands in the scroller and clips/overlaps. Its `PROSE_INDENT => '72px'` is
    also a fixed pixel gutter — a fifth of a 375px phone. Not touched here (LBF first, Simon's call).
  - No cache bumps (view state only). `tools/t_bioreveal.pl` 43 -> **75 assertions**; **anti-tested
    both halves separately** against mutated copies via `LBF_BROWSE=` — detection disabled = 5 red,
    one-row-per-paragraph restored = 8 red, and every control (sections 7 and 10) green in both states.
- **0.9.151** — **the expanded bio rendered as one blob. Two causes, and the interesting one is that
  the paragraph data we assumed exists mostly doesn't.** **SUPERSEDED IN PART BY 0.9.152** — its rule
  "ANY run of newlines is a paragraph break" is right for Last.fm and WRONG for MAI, whose bios are
  hard-wrapped; the table below is a Last.fm-only measurement. Read 0.9.152 before touching this area.
  - **MEASURE THE SOURCE BEFORE TRUSTING A FORMAT.** 0.9.150 split on `/\n{2,}/` because
    `API::_cleanBio` converts `</p><p>` to a blank line. Checked against the live Last.fm bios that
    actually reach us — **none of them contain a single `<p>` tag**, so that rule almost never fires
    and the breaks are whatever the prose happens to carry:
    | | blank-line breaks | single newlines |
    |---|---|---|
    | Sigur Rós | 15 | 3 |
    | Radiohead | 4 | **9** |
    | Mildlife | **0** | **0** — 685 chars, one unbroken run |
    So blank-line-only splitting threw away **9 of Radiohead's 13** breaks, and for a Mildlife-shaped
    bio there is nothing to split on at all. `_cleanBio` is the ONLY path (both the MAI and the direct
    Last.fm branch go through it), so this applies to every bio the plugin shows.
    **^ THAT LAST SENTENCE IS THE 0.9.152 BUG, IN ONE LINE.** A shared CODE path was taken as proof of
    a shared DATA shape, and all three rows above are Last.fm bios. MAI's are hard-wrapped at ~72
    columns, where rule 1 below is exactly wrong. Sampling one source and generalising on "they all go
    through the same sub" is the mistake to recognise, not the split rule itself.
  - **`_bioParagraphs`** now applies two rules: (1) **any run of newlines is a break** — a lone `\n`
    in a Last.fm bio is deliberate, they are not column-wrapped; (2) if that still yields ONE long
    chunk the source genuinely has no structure, so sentences are grouped
    `BIO_SENTENCES_PER_PARA`=3 at a time. Rule 2 is a **presentation** decision — asserted in the
    tests to not alter a single character of the text. Sentence boundary is `.!?` followed by a
    capital or opening quote, so abbreviations mid-sentence survive; a stray split shifts a group
    boundary rather than producing a visibly wrong paragraph.
  - **Rows also needed real spacing.** Consecutive `type=>'text'` rows render flush in Material, so
    even correctly split paragraphs ran together. New **`_proseRow`** wraps each in
    `<div style='margin-bottom:0.7em'>` — the same inline-style-in-a-row-name technique Discography
    uses and which is proven to render through the OPML feed path.
  - **`_escHtml` is REQUIRED, not defensive.** This is the plugin's first HTML-emitting row, and
    `_cleanBio` **decodes** entities (`&amp;`→`&`, `&lt;`→`<`), so a bio quoting a band name with an
    ampersand arrives as raw markup and would break the row. Escaping is asserted, including that no
    raw tag can leak.
  - Still **no cache bumps** (view state only). `tools/t_bioreveal.pl` grew to **43 assertions**;
    anti-tested three more ways — blank-line-only split (the 0.9.150 bug) → 1 fail, no escaping →
    3 fails, no sentence grouping → 1 fail.
  - **Test-fixture lesson:** the section-3 fixture had a single newline *inside* a paragraph, which
    under the new rule is a break — so the fixture was asserting the opposite of the intended
    behaviour and failed. Fixtures encode assumptions; when a rule changes, re-read them rather than
    "fixing" the count.
- **0.9.150** — **the artist bio expands IN PLACE; the "Read more" drill-in is gone — and the
  CLAUDE.md rule that said it had to be a drill-in was simply wrong.** Tapping Read more opened a
  separate view containing only the bio, which you then had to back out of to reach the tracklist or
  the streaming matches. Discography has done this inline for both its bio and its review all along
  — and its own comment credits "LBF's full-bio recipe", so this is that recipe coming home improved.
  - **The mechanism was already in this file.** `nextWindow => 'refresh'` plus an **EMPTY** response
    (the only shape `browseHandleNextWindow` acts on — 0.9.137) pops the toggle's own window and
    re-renders the level beneath it. The All Releases paging rows have used it since 0.9.86. So
    **no Material limitation ever required the drill-in**; the old "MUST be a drill-in" note has been
    corrected in place rather than deleted, since it would otherwise keep being believed.
  - `_bioToggleRow` is a BOOLEAN sibling of `_pageRow` sharing `%pageState` — one store per player
    for transient view state. Key `bio:<lc artist>`; expand writes the flag, collapse **deletes** it,
    so a never-expanded bio leaves no residue (the `_pageRow` convention).
  - Expanded text is one row per **PARAGRAPH** (split on blank lines, empty chunks dropped, single
    newlines collapsed so Material wraps the row instead of honouring the source's hard breaks) —
    the old drill-in did none of that and could emit blank rows.
  - **Keyed on the ARTIST, not the release** (matching Discography), so another release by the same
    artist opens already expanded. Deliberate.
  - **ROW-COUNT SAFETY:** expanding shifts item_ids, and that is only safe because `_releaseDetail`
    emits the **Streaming section first** — the playable rows keep their ids (0.6.11). Commented at
    the call site; revisit if the sections are ever reordered.
  - **No new strings, no new assets, NO CACHE BUMPS** — pure view state, nothing cached changed shape.
  - `tools/t_bioreveal.pl`: 29 assertions against the real `_artistRows`/`_bioToggleRow` lifted from
    source, with the real `strings.txt` values. **Anti-tested three ways** (`LBF_BROWSE=` at a mutated
    copy): toggle returning a non-empty payload → 2 fail, collapse storing 0 instead of deleting →
    1 fail, expanded branch disabled → multiple fail.
- **0.9.149** — **a transient LB blip pinned "No trending data yet" on Trending Albums for a WEEK
  (This Month) or a MONTH (This Year) — the empty-aggregate cache-poison class, one the rest of this
  file already gets right.** Field report: both album lists empty, "all ok until recently".
  **Diagnosed without touching the box:** replayed the plugin's own pipeline against the live API
  (following → 13 users, all with listens that day, `stats/user/<u>/release-groups` 200 for every one
  of them, **650 rows / 558 distinct albums** for `this_month`, same for `this_year`), then opened
  This Month over the CLI (`listenbrainzfreshreleases items 0 10 item_id:5`) and read `log.txt`: the
  message came back with **zero new log lines**. No build ran → `_buildAlbumsData` was serving a
  cache hit, and **`$cache->get` is truthy for an empty arrayref**, which is the whole bug.
  - **`_buildAlbumsData`'s gate settled an EMPTY aggregate with `$short = 0`** — full
    `TREND_ALBUMS_MONTH_TTL`/`_YEAR_TTL`. Every other inconclusive settle in that same sub already
    uses `PLAYLIST_INCONCLUSIVE_TTL` (no client/services, gate keeps zero, watchdog truncation —
    that last one was itself a 0.9.117 review fix); the empty branch was the one that slipped
    through. Now `$settle->($data, 1)`. **The rule this belongs to: an empty result is never a fact.
    It is the shape a transient failure takes** — and the further up the pipeline the failure
    happens, the more it looks like a legitimate "nothing to show".
  - **`lbf:trending:albums:6:`→`:7:`, NOT a shape change** — purely to abandon the empties already
    pinned on users' servers. Worth knowing: the key carries the calendar period, so This Month
    would have self-healed at the month rollover and only **This Year was stuck until January**.
  - **The empty view now renders the Refresh row** (`_refreshItem('trending_albums', $range)`; no
    sort toggle — nothing to sort). It previously emitted the message ALONE, which made a bad build
    a **dead end**: the aggregate cache is the only way back and the user had no way to drop it.
    **Any "nothing here" view that is served from a cache must carry its own Refresh** — check this
    when adding one.
  - **`tools/t_trending_empty.pl`** (18 assertions, real sub bodies via the `grab` trick): empty →
    1h on BOTH ranges, healthy → still 7d/30d (the fix must not become a blanket downgrade),
    gate-keeps-zero unchanged, the empty view's Refresh row present AND its tap dropping *that*
    range's key only, and the `:7:` bump. `LBF_BROWSE=` points it at a mutated copy —
    anti-tested against a pre-fix Browse.pm: **7 failures**.
  - **Test-writing trap worth remembering, since it bit this suite:** `ok($k =~ /…/, "msg")` — a
    bare `m//` or `grep` in a LIST-context argument returns the match list, so on failure the args
    shift, the message becomes the condition, and the assertion PASSES on any truthy label. Three
    assertions here did exactly that and the anti-test run is what exposed them (`5. PASS` with a
    blank label against a `:6:` key). Wrap every match/grep in `scalar()`.
- **0.9.148** — **…and that strip belongs to BANDCAMP ALONE — correcting 0.9.147, which applied it
  to all four services.** Qobuz/Tidal/Deezer hand back a bare `title` in the raw album hash 0.9.146
  moved to; only Bandcamp's search PASSTHROUGH joins the artist on. On the other three the strip had
  no wart to remove and could therefore only misfire: a catalogue title that genuinely ends in its
  own artist — `"Goldberg Variations - Glenn Gould"` by Glenn Gould — clears BOTH guards (the
  separator is space-padded, the discarded side `_norm`-EQUALS the artist) and reaches LL as
  `"Goldberg Variations"`, a name the service never reports at playback. **That is the identical
  failure mode 0.9.144–0.9.147 exist to fix, arrived at from the opposite direction**, and it is the
  general lesson: this handshake's failures are silent (the album plays fine, it just never reaches
  *Played*), so a defensive transform applied where the defect isn't evidenced is not free — it is a
  new instance of the same bug. `_searchBandcamp` is now the sub's only caller; the other three
  assign `$album->{title}` verbatim.
  **`_streamKey` :26→:27** — a FIFTH bump, same rule as ever: `:26:` can hold a Q/T/D title truncated
  at a dash the service really uses.
  **`_bcMatchKey` STILL `:6:`** (a pin is often an album's only playable entry) — but its comment now
  states the residual cost correctly and, importantly, that **the usual remedy does not apply**:
  `_bcMatchItems` replays the cached `favorites_url` verbatim, so removing and re-adding in LL just
  re-sends the stale favurl. Only **Re-search Bandcamp** rewrites a pin. Same wording in the CHANGELOG.
  **`tools/t_svctitle.pl` grown to 22 checks**: `%FOLD` is now LIFTED from `Browse.pm` (it was
  hand-copied, so a `%FOLD` edit drifted without failing), the Goldberg case is kept as a live
  demonstration that the guards CANNOT save it, and the four search subs are pinned at source level —
  Bandcamp calls the strip, the other three must not and must assign the raw title. Anti-tested:
  restoring the 0.9.147 call sites fails 6.
- **0.9.147** — **…and the raw title needs the ARTIST AFFIX stripped, because Bandcamp's carries one
  too (`_stripArtistAffix`) — but it applied the strip to ALL FOUR services, which 0.9.148 narrows to
  Bandcamp. Read this entry with that one.** 0.9.146 moved to the raw album hash and fixed
  Qobuz/Tidal/Deezer, but
  Bandcamp's search PASSTHROUGH title is itself `"<album> - <artist>"` — confirmed live: an add stored
  `Radio: Journey Beat (Original Music from Big Walk) - aksfx`, and Simon confirmed Bandcamp's Now
  Playing reports artist `aksfx` with album `Radio: Journey Beat (Original Music from Big Walk)`, so
  the stored name could never match at playback.
  **Why no field is trustworthy here, which is the thing to remember:** `_albumMatches` accepts a
  candidate that STARTS WITH our album, so a trailing `" - artist"` sails through matching untouched.
  Every field in the chain therefore looks fine to the matcher while being wrong as a title. There is
  no field to switch to — the affix has to be removed explicitly.
  **`_stripArtistAffix` is deliberately conservative**, following LL's own 0.1.72 hardening: the
  separator must be SPACE-PADDED (so `Jay-Z` is untouched), the discarded side must EQUAL the artist
  under `_norm` (not contain or start with it, so `Album - aksfx remixes` is left alone), and anything
  failing either test is returned VERBATIM. Prefix is tested at the FIRST separator, suffix at the
  LAST, so a title containing its own `" - "` still resolves. Compared against the SERVICE's artist
  spelling (`$pt->{artist}`; also `$candArtist` until 0.9.148 narrowed the call to Bandcamp) — the
  value that service would actually have joined. **Conservative is not the same as safe**: the guards
  stop a wrong strip only where the artist ISN'T what got joined on, and 0.9.148 is what happens when
  it is.
  **LBF-ONLY, outside the shared matcher.** Do not confuse it with `_stripArtistPrefix`, which IS a
  fleet-synced shared-engine sub; this one doesn't trip `matcher_sync_check`.
  **`_streamKey` :25→:26** — a FOURTH bump for a fourth wrong `&al=` value.
  **New suite `tools/t_svctitle.pl`**, using the real sub and the real `_norm`/`%FOLD` chain, 14
  checks split into "must strip" and **"must not strip"** — the second half is the point, since a
  wrong strip corrupts the title LL matches and dedupes on, which is worse than the wart it removes.
  Anti-tested: neutering the strip fails 7.
- **0.9.146** — **`&al=` takes the service's RAW ALBUM TITLE (`_svctitle`), not its rendered row
  label — correcting 0.9.145, which also shipped. Completed by 0.9.147, which strips the artist affix
  Bandcamp's raw title turned out to carry.** Reported by Simon from two live rows: rec 207
  (Qobuz) stored `aksfx - Radio: Fourth Space (…)`, rec 208 (Bandcamp) stored
  `Radio: Journey Beat (…) - aksfx`. **Artist-first on one service, artist-last on the other** — the
  unmistakable signature of a DISPLAY LABEL rather than a title, which is exactly what
  `$it->{name}`/`{line1}` are: each streaming plugin's own renderer composes them, and they differ per
  plugin. A label can never match at playback, and it poisons LL's `artist|album|year` dedupe key with
  the artist on both ends. Worse than 0.9.144 in one respect: MB's name was at least a real title.
  **Fix:** stash the title from the RAW album hash at match time — `$item->{_svctitle} =
  $album->{title}` for Qobuz/Tidal/Deezer, `$it->{_svctitle} = $pt->{title}` for Bandcamp (which also
  serves the manual picker, since it calls this sub through the adapter's `run`). That is the SAME
  field `_albumMatches` already validates against, so it is the album title alone by construction —
  the artist is a separate argument there. **No fallback at the call site:** if a service ever yields
  no title we send nothing and LL reads Material's label, which is what happened before 0.9.144 and is
  merely imperfect, whereas either wrong string is silently destructive.
  **`_streamKey` :24→:25.** Third consecutive bump of this key for a different wrong `&al=` value.
  **THE RULE: bump it on ANY change to what `&al=` carries, even when the field keeps its shape** —
  one re-resolve versus a week of silent misses aged out of a 7d TTL.
  **THE REAL LESSON, and it is a method failure, not a typo.** Three builds in one session each put a
  different wrong string in this one field. The first two passed every behavioural check in
  `t_ll_handshake.pl` because they all SUPPLY the album themselves; section 4 (added in 0.9.145) then
  caught only the MB-name spelling, because I wrote the assertion to accept `{name}` — encoding my own
  assumption that the rendered node held a title. **I never verified what `name` actually contains for
  any service; Simon's two live rows did.** The assertion now accepts ONLY `_svctitle` and names all
  three known-wrong forms, anti-tested against each. When a field feeds another plugin's matching,
  read a REAL value out of a REAL row before believing what it holds.
- **0.9.145** — **`&al=` carries the MATCHED SERVICE'S naming, not MusicBrainz's — correcting 0.9.144,
  which SHIPPED and was installed. SUPERSEDED BY 0.9.146 — this build read the service's rendered ROW
  LABEL, which bakes the artist in; the principle below is right, the field it used was not.** Reported by Simon, from a real row: LB has aksfx
  `Radio: Fourth Space (Original Music from Big Walk)` where Qobuz has
  `…(Original Music from the Game "Big Walk")`, and the release never reached Played.
  **THE RULE: once a favurl exists the release has been RESOLVED to a specific service album, and from
  that point the SERVICE's spelling is the only one that works.** Two independent consumers demand it,
  both title-keyed: LL's Played auto-detection matches the PLAYING track's album title (reported by the
  service), and LL's `artist|album|year` dedupe key must agree with a direct add from that same
  service. MB and the services disagree constantly, and NOT only over edition qualifiers — see the
  aksfx case above. MB additionally keeps a release's distinguisher OUT of the title (all four American
  Football LPs are titled `American Football`, with `LP2`/`LP3` in `disambiguation`) where the services
  put it IN. Sending MB's name loses on both counts, **silently**: the album plays perfectly and just
  never leaves the list.
  **Why 0.9.144 got it wrong** — it reasoned that an "authoritative" catalogue title beat a renderer's
  display label. That mistakes WHICH QUESTION the param answers. It is not "what is this release
  really called", it is "what will the thing playing call itself".
  **Contrast PFR, which sends the same param for a different reason:** its rows read "Artist - Album",
  so its `&al=` undoes ITS OWN renderer's prefix. That is not licence to substitute a different naming
  authority. Do not "improve" this back to MB's name.
  **Changes:** both call sites now pass the service candidate's own title (`$it->{name} //
  $it->{line1}`); at the Bandcamp site deliberately NOT the `$name` local, whose `// $album` fallback
  would smuggle the MB name back in. **`_streamKey` :23→:24** — the field didn't change shape, only its
  value, and a `:23:` entry cached by the installed 0.9.144 would keep handing LL the MB name for the
  full 7d TTL.
  **THE TEST LESSON, and it is the same one as `&tc=` below.** `t_ll_handshake.pl` passed throughout
  0.9.144 because every case SUPPLIES the album itself — it proved the param is built and parsed
  correctly and could not say a word about WHICH NAME the plugin chooses. New **section 4** asserts on
  the CALL SITES in source (crude, but there is no return value to inspect); anti-tested by reverting a
  site to `$album`, which fails it. **A behavioural test of a handshake cannot check the choice of what
  goes into it — test the call site too.**
  **Rows added under 0.9.144 keep the wrong stored name**; only a remove + re-add fixes those.
- **0.9.144** — **`&al=` — an ALBUM TITLE joins the Listen Later handshake.** Material gives a plugin no
  structured album name for an online row: `$ALBUMNAME`/`$TITLE` is the row's DISPLAY LABEL verbatim,
  and these rows are labelled by each streaming plugin's own renderer, qualifier and all. So the album
  name reaching LL depended on skin plumbing. `_attachFavUrl` takes the name as a 7th arg
  (`uri_escape_utf8`, pushed next to `&a=`).
  **SHIPPED WITH THE WRONG NAME — see 0.9.145 above; it sent the MB/LB release name.** The reasoning
  below is kept for its method notes only; **where it describes sending the MB name it is describing
  the bug.** Both call sites pass it —
  the `_findPlayable` settle loop and the manual Bandcamp pin. Receiver has existed since **LL 0.1.71**
  (`Plugin.pm::_stripPrivateParams`; 0.1.72 hardened its migration, which is why the user-facing floor
  was quoted as 0.1.72), so older LLs simply ignore it. Idiom copied from **PFR**, which
  has sent the identical param since its own "Artist - Album" labels needed it.
  **REAL FLOOR IS LL 0.1.92 — see the Played trade-off below.**
  - **THE OTHER CONSEQUENCE, missed on the first pass and found by code review: this BREAKS Played
    on LL 0.1.72–0.1.91.** MB deliberately keeps a release's distinguisher OUTSIDE the title — all four
    American Football LPs are titled exactly `American Football`, with `LP2`/`LP3` in MB's
    `disambiguation` (verified against the MB API and Simon's mirror), while the service prints
    `American Football (LP2)`. `Played::_matchRecord`'s streaming branch matches on the album TITLE
    alone (no album-id anchor), and LL's `DB::_norm` deliberately KEEPS the qualifier — so the bare
    name we now send never matches the qualified name the playing track reports, and the row never
    leaves the list. Silent: it plays perfectly. **Replay is NOT affected** — LL prefers the captured
    album id (`hasDirectAlbumRef`), which our favurl always carries, so its `(LP4)`-preserving
    `_bestMatches` ranking never runs for our rows. Display degrades (rows reading `American Football`
    separated only by year) — accepted, not fixed.
    **Fixed on the LL side in 0.1.92**, which keeps the service's label as `ref.svc_title` and matches
    on either. Nothing to change here: the name we send is the right one, LL just needed to stop
    throwing the other one away.
    **Do NOT "fix" this by appending MB's `disambiguation`** — that was the first plan and it is wrong.
    Sampling 120 release-groups from a live LB fresh-releases feed: exactly ONE has a disambiguation,
    and it reads `The Vampire Lestat OST` — editorial prose, not a service-style qualifier, so
    appending it would match nothing anywhere. The LB feed carries no such field either (12 keys, none
    of them disambiguation), so it would need one MB lookup per release-group — and the trending path
    resolves in bulk. `LP2` happening to be exactly Qobuz's spelling is a coincidence.
  - **BE PRECISE ABOUT THE GAIN — I overstated it first time and the verification caught it.** I cited
    two live rows (*Fruit Bats – The Landfill (Album)*, *Walrus Ghost – … (Album)*) as proof of a
    current bug. They are NOT: LL has stripped a trailing `(Album)`/`(Track)`/`(Hi-Res …)`/`(Explicit)`/
    `(Mono)`/`(Stereo)` and a trailing `(YYYY)` since **0.1.35** (2026-06-27), so a Bandcamp add TODAY
    already stores the clean title without this param. Those rows are residue from before that. What
    `&al=` actually replaces is **the blocklist itself**: anything not on that fixed list —
    `(Deluxe Edition)`, `(Bonus Track Version)`, `(Remastered)` — still reaches the stored title and the
    dedupe key. Authoritative name instead of a guess at what to strip. **Method note:** the first cut
    of the test modelled LL's fallback as the row label ALONE, which made the `(Album)` cases look like
    they proved something; the anti-test passed them either way and exposed it. Model the FULL fallback
    or a suite flatters the feature.
  - **DELIBERATE BEHAVIOUR CHANGE, not pure cleanup:** an edition qualifier that is genuinely part of
    the service's album title is replaced by MB's plain release name, so a deluxe edition and the
    standard one now key alike and collapse into ONE row. Correct here (LBF matched both to the SAME MB
    release), but it is a change — pinned in LL's `tools/t_addpath.pl` with that reasoning attached.
  - **`_streamKey` :22→:23.** `favorites_url` is part of the cached item, so without it every
    already-resolved album keeps handing LL the old favurl for the 7d TTL. Note this is the OPPOSITE
    case to the 0.9.143 no-op: that DROPPED a field (orphan, never read → no bump); this ADDS one a
    reader depends on. **`_bcMatchKey` stays `:6:`** per the standing rule — with a cost stated in the
    comment: an already-pinned Bandcamp match keeps its old favurl until re-searched by hand. Accepted;
    bumping would delete every hand-curated pin, which is strictly worse.
  - **Encoding contract, verified not assumed:** `uri_escape_utf8` out, `uri_unescape` back = **OCTETS**,
    never a utf8-flagged string. Identical to `&a=` since 0.9.58 and consistent all the way through LL,
    so the round trip is lossless. `t_ll_handshake.pl` asserts the octet-ness explicitly so a future
    change on either side fails loudly rather than quietly re-keying LL's rows.
  - **Tests: `tools/t_ll_handshake.pl` gained section 3**, driving LL's REAL `_stripPrivateParams`
    (grabbed from `ListenLater/Plugin.pm`) over what `_attachFavUrl` actually emitted — clean case,
    on/off-blocklist qualifiers, punctuation-only `( )`, a title full of `&`/`=`/`?`, wide chars, empty
    album, and `al=` as the LONE param (the ordering case: each strip takes its own leading delimiter,
    so the residue must still be a bare `scheme://album:<id>`). The file paths are now env-overridable
    (`LBF_BROWSE`/`LL_SOURCES`/`LL_PLUGIN`) **so it can be anti-tested** — 13 failures with the sender's
    `al=` push deleted, 13 with the receiver's strip deleted. LL's `tools/t_addpath.pl` gained the
    DB-level half: the verbatim favurl this version emits for Qobuz and Bandcamp, asserted on the
    stored row, its dedupe key, and that a later plain-labelled add of the same record now dedupes
    (5 failures without the receiver).
- **0.9.143** — **`&tc=` REMOVED — 0.9.142's plumbing was measurably inert, so it's gone.** Read the
  0.9.142 entry below for the full trace and the verification that killed it. Summary: the count
  fields are real but live on each service's per-ALBUM endpoint and are ABSENT from the SEARCH
  responses `_searchQobuz`/`_searchTidal`/`_searchDeezer` iterate, so `_candTrackCount` returned undef
  every time and no `tc=` was ever emitted, on any service. **Removed:** `_candTrackCount`, the three
  `$item->{_tracks}` stashes, and the `tc=` block in `_attachFavUrl` (which now carries a comment
  saying why, and what evidence would be needed to re-add it).
  **`_streamKey` deliberately STAYS at `:22:`** — reverting it to `:21:` would resurrect pre-0.9.142
  entries and bumping to `:23:` would force a third pointless re-resolve, whereas DROPPING a field
  from the cached item needs neither: an orphaned `_tracks` key is simply never read. (Earlier in that
  session I argued a revert would cost a `:22→:23` bump; that was wrong, and it was the main reason I
  recommended keeping dead code — a sunk-cost argument, not a technical one.)
  **Version goes FORWARD to 0.9.143, not back to 0.9.141:** 0.9.142 was already installed, and LMS
  offers no update for a same-or-lower version. **`tools/t_ll_handshake.pl` rewritten again** — it now
  tests the `&rt=` wire (including that an unmappable MB type asserts nothing) and LL's own
  type×count decision, and **asserts no count param is emitted**, so re-adding one fails the test.
  It also lost a reference to a non-existent `LL verify_favurl_params.pl` that I had invented.
- **0.9.142** — **`&tc=` — the release's TRACK COUNT joins the Listen Later handshake, completing
  0.9.141.** 0.9.141 sent MB's primary type as `&rt=` and asserted it as authoritative; but LL reads
  `single` as "exactly ONE track" (`Played::_totalTracks` returns 1 → its played-through mark), so a
  MB Single with B-sides was marked Played after track one. The count that disproves it was **already
  on the same item**: `_candReleaseType` has read it off the service's album hash since 0.9.89 (for
  the single-drop filter) — computed ~11 lines before `_attachFavUrl` builds the favurl, and unused
  by it. Fixed properly in LL 0.1.88 (it resolves the release to check); this sends the number so LL
  needs no lookup at all and the row is right at INSERT time. **Changes:** new `_candTrackCount`
  (same three verified fields: Qobuz `tracks_count`, Deezer `nb_tracks`, TIDAL `numberOfTracks`;
  1-3 digits, non-zero) — DELIBERATELY a separate sub, NOT a refactor of `_candReleaseType`, which
  treats a count of 0 as 'single' (`$tc <= 2`) and feeds the single-drop filter: folding them would
  silently change which candidates that filter drops. Stashed as `_tracks` in `_searchQobuz` /
  `_searchTidal` / `_searchDeezer` beside `_ctype`/`_year` (plain scalar → survives the Storable
  stream cache). `_attachFavUrl` reads `$it->{_tracks}` rather than taking a new arg, so the OTHER
  call site (the manual Bandcamp picker, ~4958, which has no album hash) sends nothing and needs no
  change — Bandcamp has no count before its page is fetched, so LL resolves there as before.
  **Cache: `_streamKey` :21→:22** for the same reason as :20→:21 — `favorites_url` is part of the
  cached item, so without it every already-resolved album would keep handing LL a favurl with no
  count. `_bcMatchKey` **stays at :6:** (no auto-repopulation — bumping it discards hand-curated
  Bandcamp-only matches; the 0.9.42 mistake reverted in 0.9.47 and re-attempted in 0.9.141).
  **Ordering rule: LL 0.1.89 (the receiver) MUST ship first** — an LL that can't strip `tc=` leaves
  it in the favurl. **`tools/t_ll_handshake.pl` rewritten** (it had FAILED after LL 0.1.88 added
  `singleIsWrong`, which it didn't grab — and it encoded the bug as expected behaviour, asserting
  Single+3 tracks → 'single'). It now evals the real subs from both repos and covers 13 type/count
  combinations plus sender-side validation; `t_cache_widechar.pl`, `t_review_fixes.pl` and
  `matcher_sync_check.py` all still pass unchanged.
  **VERIFIED LIVE 2026-07-29 — and the optimisation does NOT pay off where it was expected.**
  Adding *3OH!3 – MY FRIENDS* (MB **Single**, 3 tracks) from LBF match rows, per service, from
  `curl http://plex:9000/log.txt`:
  - **Tidal** (rec 199): `add -> tidal … rel=single` then `reclassified as ep` **150 ms** later.
  - **Deezer** (recs 198, 200): `rel=single` then `reclassified as ep` after **277 ms** / **2 ms**
    (the 2 ms one hit an already-cached tracklist).
  - **Qobuz** (rec 201): `rel=single` then `reclassified as ep` **1.5 ms** later — SAME as the others.

  **So `&tc=` delivers on NO service. 0.9.142 is inert plumbing.** The count is absent from all three
  SEARCH payloads, which is where LBF gets its album hashes.

  `rel=single` on the INSERT line is the proof: had `&tc=3` arrived, `relTypeFor(service=>'single',
  count=>3)` would have settled it to `ep` at insert with no correction line at all. So **neither
  Tidal's `numberOfTracks` nor Deezer's `nb_tracks` is present in their SEARCH responses** — those
  fields exist on the per-album endpoint (which is what the earlier probe recorded), not on search
  results. The count LBF sends is therefore absent for both, and LL's background `_verifyRelease`
  does the work — invisibly, in 2–150 ms, which is why it LOOKS instant to the user (Simon reported
  "showed up straight away, no delay" for both services; that observation and the log agree — the
  fallback is imperceptible, not absent).

  **Consequence for `_candReleaseType` (PRE-EXISTING, since 0.9.89, worth its own look):** its
  count fallback reads the same absent fields, so for Tidal and Deezer it can only ever answer from
  `record_type`/`type`. If those are absent from search results too, `_ctype` is always `''` there
  and the single-drop filter has never dropped a Tidal or Deezer candidate. Untested — but this
  finding makes it likely.

  **DO NOT conflate this with LL's own Qobuz shortcut.** `Sources::classifyRelType` reads
  `tracks_count` off `getAPIHandler->getAlbum` — the per-album ENDPOINT, which is exactly where these
  fields are documented to live, and a different call from the search LBF uses. The Qobuz result
  above says nothing about it either way: the correction line appears whether the count came from the
  album object or from the tracklist. Still unverified — don't credit it, don't dismiss it. (Its 1.5 ms
  turnaround is suggestive but proves nothing; a cached tracklist is equally fast.)

  **Keep or revert?** KEEP, purely on cost: the `:21→:22` bump has already taken its one re-resolve,
  and reverting needs `:22→:23` — a SECOND re-resolve — to buy back nothing. The plumbing is inert
  where the field is missing and would start working with no code change if a payload ever carried it.

  **The lesson worth more than the feature:** every test written for this (`t_ll_handshake.pl`,
  LL's `verify_qobuz_path.pl`) SUPPLIED the field itself — a stubbed `{tracks_count=>4}` — so they
  could only ever confirm that our code reads a count when one is present, never that one IS present.
  The "field names verified per plugin" comment was verified against PLUGIN SOURCE (where the fields
  appear in album-endpoint handling); that true statement about NAMES silently became an assumed
  statement about AVAILABILITY in a different payload. A sender-side handshake needs one real
  end-to-end observation before it is believed, not a synthetic round trip.
- **0.9.96** — **alias-field fallback in `getArtistMbidByName` (ported from Discography 0.32.0).** The
  fielded query `artist:"<name>"` searches the artist NAME only, so a name existing solely as an MB
  **alias** ("The Oh Sees" → Osees `194272cc-…`) returned 0 results and cached a miss — verified live on
  public MB AND a mirror (`alias:"The Oh Sees"` scores 100 on both). `$run` gained a `$field` arg
  (query built per-field by `$mkQuery`); when the `artist` field yields nothing acceptable (0 results
  after the mirror→public fallback, or top score <90), it retries ONCE with `alias:"name"` — same
  escaping, same ≥90 gate, same mirror-0-results→public retry within the stage. Runs only where a miss
  would have been cached, so no working resolution changes. Matters for the DSTM radio's Last.fm
  similar-artist names (alias-era spellings are common there). NOT a matcher change (resolver is outside
  the fleet-sync set; `matcher_sync_check.py` N/A); no cache bump (`lbf:artistmbid:` now fills correctly;
  existing misses self-heal on their TTL). `perl -c` clean.
- **0.9.95** — **code-review fixes: make the 0.9.94 mirror auto-detect actually run + plug a resolver leak.**
  From a pre-build review of 0.9.82–0.9.94. (1) **`mb_base_url` defaulted to the public URL, which made the
  whole 0.9.94 auto-detect feature dead code.** `autodetectMirror` returns early on a non-blank base and
  `_mbBase` only consults the auto-detected-mirror cache (`MB_AUTO_KEY`) when the pref is blank — but the
  init default was `'https://musicbrainz.org/ws/2/'` AND `Settings::handler` reset a blank field back to
  that URL, so the pref was **never** blank and the probe never fired on any install. Fixed: init default is
  now `''` and a cleared field stays `''` (the settings.html placeholder communicates the default in the
  empty box). Existing installs that already saved the public URL must clear the field once. (2) **Reference-
  cycle leak in `getArtistMbidByName`.** The 0.9.93 mirror-search fallback used a self-capturing closure
  (`my $run; $run = sub {…$run…}`) — a cycle Perl never collects — created once per artist-name resolution
  (DSTM Radio seeds, Last.fm similar-artist resolution). Rewritten to pass the sub to itself (`$self`), so
  it's freed when the async chain ends (portable — no `__SUB__`/`weaken`). Settings/lifecycle only —
  **no matcher change, no cache-version bump**; `matcher_sync_check.py` still exits 0.
- **0.9.94** — **auto-detect a same-host MusicBrainz mirror + de-personalise the settings text.** New
  `API::autodetectMirror($cb)` runs from `postinitPlugin` ONLY when `mb_base_url` is blank: probes a
  FIXED same-host list (`http://localhost:5000/ws/2/`, `http://127.0.0.1:5000/ws/2/`) and, for the first
  that answers, validates it is really MusicBrainz by fetching a known MBID (Radiohead `a74b1b7f…`) and
  checking `name eq 'Radiohead'` — so another `:5000` service can't be mistaken for a mirror. The
  discovered base is cached under `lbf:mbmirror:v1` (URL=found, `''`=probed-none, TTL 1 day); `_mbBase`
  consults it when the pref is blank (a manual URL still wins and skips the probe). `_mbThrottled` is
  unchanged, so a discovered localhost mirror is treated as un-throttled + eligible for the empty-search
  →public fallback, exactly like a manual mirror. **The LAN is never scanned** — localhost only. Covers
  the common musicbrainz-docker-alongside-LMS case with no config. Also: the tooltip + all code comments
  no longer reference a personal host (now `http://your-server:5000/ws/2/`) and the tooltip documents the
  auto-detect. Ported identically to Discography 0.30.0 the same session. `perl -c` clean; no cache bump.
- **0.9.93** — **mirror search fallback (ported from Discography 0.23.0).** `getArtistMbidByName` now
  retries the public MusicBrainz API ONCE when the configured base is a **mirror** and its `?query=`
  search returns zero results (or is unreachable). A musicbrainz-docker mirror serves entity BROWSES
  from Postgres but SEARCH via Solr — a mirror whose search index was never built returns count:0 for
  everything while browses work, which would silently fail every name→MBID resolution (the DSTM Radio
  seed and the Last.fm similar-artist resolution). New `_mbThrottled` (public-host test) gates the
  fallback; `$isFb` guards the single retry; the public-resolved MBID still browses fine against the
  mirror. Public API and fully-built mirrors are unaffected. NOT a matcher change (sync N/A); no cache
  bump (the fallback just fills the same `lbf:artistmbid:` cache correctly instead of caching a
  spurious miss). See [[mb-mirror-search-index-gotcha]] and [[service-search-and-debug]]. `perl -c`
  clean; `lbf:stream`/`lbf:track`/`lbf:pl:resolved` untouched.
- **0.9.92** — **code-review fixes (release-type filter EP edge + mb_base_url scheme guard).** From the
  0.9.82–0.9.90 pre-commit review. (1) **`_findPlayable` single-drop no longer applies to EP targets.**
  `$dropSingles` was `$tnorm ne '' && $tnorm ne 'single'` — so an EP release dropped `single`-classified
  candidates, but `_candReleaseType` classifies a real 2-track EP (no explicit service type field) as
  `single` by track-count, so the correct EP could be discarded for a like-named rival. Now
  `... && $tnorm ne 'ep'` — album/compilation targets still shed a same-named single (the 0.9.89 case),
  EP targets don't. Filter output is cached, so **`lbf:stream:17→18`** (album path only — `_findPlayableTrack`
  tags `_ctype` but never filters on it, so track/playlist caches unchanged). (2) **`mb_base_url` scheme
  guard.** A scheme-less entry (bare mirror host like `plex:5000/ws/2`) was stored verbatim and made every
  MB lookup fail silently (tracklist/genres/DSTM resolve); `Settings::handler` now prepends `http://` to a
  scheme-less non-blank value (type `https://` yourself for a TLS mirror). (3) **Default URL made
  discoverable** — settings.html placeholder `https://musicbrainz.org/ws/2/` + the desc string spells it
  out and notes blank resets to it (so an accidental clear is recoverable). `perl -c` clean (Browse +
  Settings). NOTE (verified in review, NOT bugs, left as-is): the `_streamId`/`lbf:bcmatch` "type/norm not
  in the key" concerns only bite MBID-less releases, which the 0.4.4 invariant says never happens on the
  feed path (release_mbid always present → album/single get distinct mbid keys); reuse/altitude cleanup
  (`_recommenderDivider`≈`_dayDivider`, dual-encode ×4, `_norm` €/£/¥ outside `%FOLD`, `%pageState` never
  clears, `lbf:pl:resolved:6:` key triplicated) deferred.
- **0.9.91** — **People You Follow inline sort toggle: state+hint labels (Discography style).** The
  toggle row now names the CURRENT ordering with a tap hint — `PLUGIN_LBF_FOLLOW_SORT_DATE` = "Sorted by
  date (tap for recommender)", `PLUGIN_LBF_FOLLOW_SORT_REC` = "Sorted by recommender (tap for date)" — and
  `_followSortToggle` picks the string by current state (`$byRec ? REC : DATE`, flipped from the old
  action-named `$byRec ? DATE : REC`). Mirrors Discography's `_sortToggleItem`
  ("Sorted newest first (tap for oldest)"). Strings-only + one ternary; no matcher, no cache bump.
  (Also this session, diagnosed but NOT a code bug: a user reported the follow list "can't view as list /
  shows as a grid of covers". Verified live over HTTP against the server's own 6.4.4 `material-deferred.min.js`
  that the feed forces LIST — the sort `link` row + `header-basic` divider + `audio` rows make `types.size==3`,
  so Material's `1==types.size` grid-enable never fires (`canUseGrid=false`). It was a STALE Material client
  view cached from an older pure-audio build; a hard-refresh/incognito reopen restored the list AND the ⋮
  List/Grid toggle. No plugin change — the current feed already can't be gridded.)
- **0.9.90** — **matcher: self-titled-album rule (fleet sync from Discography 0.11.1).** When the album
  title normalises to the ARTIST name ("The Beatles", "Weezer"), `_albumMatches` now matches on the
  EXACT normalised title only — skipping the prefix/format/ascii/artist-prefix fallbacks that otherwise
  read "<album> <extra>" as an edition of the same album. Without it, "The Beatles" swallowed "The
  Beatles 1962-1966" (Red), "…1967-1970" (Blue), "…Anthology 1". `_norm` still strips brackets, so "The
  Beatles (White Album)"/"(Remastered)" still match; a wrong artist on an exact title still fails.
  **Fleet sync:** applied byte-identical to LBF + PFR + DSC (checker `_albumMatches` hash `7462b60e053d`
  across all three) and, adapted, to LL's pinned lenient variant (empty-artist replay path untouched;
  re-pinned `5d270440af5a→2bf38f346e0f`); `matcher_sync_check.py` exits 0. Album-path only, so **only
  `lbf:stream:16→17`** bumps (track/playlist caches use `_trackMatches`, unchanged). Gates: `perl -c`
  clean on all four; 14/14 assertions (Red/Blue/Anthology rejected, exact/White-Album/Remastered
  accepted, wrong-artist rejected, normal albums unaffected, LL empty-artist leniency preserved);
  checker exit 0. (Sibling bumps this session: PFR 0.7.5 `pfr:stream:5→6`, LL 0.1.70.)
- **0.9.89** — **streaming match honours release type: an album no longer resolves to a like-named
  single.** Field bug — a release (e.g. an Album) matched a same-named **single** on a service, which
  title+year can't separate (a single usually shares the album's year). Fix is a type-consistency
  filter in `_findPlayable`, **outside the shared matcher** (LBF-only — no fleet sync; Discography
  untouched, and it has no candidate type-matching to copy anyway — it disambiguates by year+ownership,
  which needs the whole discography). New `_candReleaseType($album)` classifies a candidate as
  `album`/`single`/`ep`/`''` from the service's OWN data — explicit type field first (Qobuz
  `release_type`, Deezer `record_type`, TIDAL `type`), else a conservative track-count rule (≤2 tracks →
  single; a real album never has 1–2 tracks; 3+/unknown → `''` = keep). Each adapter tags matched items
  `_ctype`; `_findPlayable` drops `single`-typed candidates **only when the opened release's type is
  KNOWN and is not itself a single** (so a Single release still matches a single — LBF lets users
  include singles — and an unknown/blank type is never filtered), and **keeps the whole set if the drop
  would empty a service's matches** (a service that only lists the single, or a flaky type field, still
  yields a match). Target type is `$rel->{release_group_primary_type}`, threaded as a new trailing
  `_findPlayable` arg. Cache bump `lbf:stream:15→16` so cached albums re-resolve once and shed the
  single. **KNOWN RESIDUAL:** a mistyped single with 3+ tracks and no type field slips through (rare;
  the conservative rule errs toward keeping matches). Reusable/portable to Discography later (would fix
  its same-year album/single gap). Gates: `perl -c` clean; 19/19 assertions on `_candReleaseType`
  (all three services' field shapes, explicit-type precedence, track-count fallback, guards) + the
  drop/fallback filter.
- **0.9.88** — **People You Follow: inline sort toggle — by date OR by recommender.** The list can
  now be grouped by the follower who recommended each track, not just by day. A top-of-list toggle row
  (`_followSortToggle`, `MENU_SORT` icon) flips the durable `follow_sort` pref (default `date`) and
  refreshes in place (`nextWindow=>'refresh'` → the re-walk re-reads the pref, so the choice sticks
  across visits — like the feed Sort setting). `_followResult` branches: `date` = the existing day
  dividers; `recommender` = a `_recommenderDivider` ("Recommended by <user>") per follower. Both
  iterate the already-newest-first list and bucket in first-seen order, so **recommender groups come
  out most-recent-activity-first**, tracks newest-first within each. Each matched item is tagged
  `_recommender` in `_resolveTracks` (mirroring `_created`; harmless to the playlist/DSTM paths), and
  the resolved-cache key bumped `lbf:follow:resolved:3→4` so existing resolves re-run once and bake it
  in (the source store already carries it — free re-tag). Dedup means a track shows under a single
  person (whoever recommended it most recently). New strings `PLUGIN_LBF_FOLLOW_SORT_REC` /
  `_SORT_DATE` / `_FOLLOW_BY` / `_FOLLOW_BY_UNKNOWN`; new icon `lbf-sort_MTL_icon_sort.png`. New pref
  `follow_sort`. No matcher change. Gates: `perl -c` clean; 10/10 behavioural assertions against the
  real `_followResult`/`_followSortToggle` (toggle-first + correct label per mode, date order + single
  day group, recommender order most-recent-first + one divider per person, pref flips both ways).
- **0.9.87** — **removed the "Show all" entry from the All Releases landing.** It was the first row
  of `_buildAllLanding` and dumped the entire weekly/grouped list unpaged (via `_buildItems`) —
  duplicating the same releases the dated week rows already cover, and it was the path that still
  flooded once the per-week lists were paged (0.9.86). The landing is now just the dated week
  drill-ins, each capped 30-at-a-time with "Show more". `_buildAllLanding`'s `$headers` param and the
  `PLUGIN_LBF_VIEW_ALL` string are now unused (left in place; harmless). No matcher change, no cache
  bump. (New Releases for You is unchanged — full native windowing.) `perl -c` clean.
- **0.9.86** — **"Show more" reveal on the All Releases per-week lists (30 at a time).** A single
  week of the GLOBAL All Releases feed can list hundreds of releases; opening a week now renders
  **PAGE_SIZE = 30** rows followed by a **"Show more (N)"** row that grows the week by another 30, and
  — once grown — a **"Show less"** row that collapses back to 30. Ported from the Discography plugin's
  `_pageSection`/`_pageRow`: the tap is a `nextWindow => 'refresh'` toggle that stores an **absolute**
  target in a module-level `%pageState` (per player, per `arweek:<week>` key), which survives the
  `cachetime => 0` re-walk the refresh triggers; collapsing deletes the key (no residue); a shrunk feed
  clamps rather than slicing past the end. **Scoped to All Releases ONLY** — `_pageSection` is called
  solely from the per-week drill-in coderefs in `_buildAllLanding`. **New Releases for You is untouched**
  (its native full-list windowing — Material's in-list filter spanning every item — works well and is
  the deliberate 0.4.7 behaviour); **"Show all"** likewise stays the full native list (it's the
  everything/escape-hatch view), and the shared `_buildItems`/`_buildWeekly`/`_buildGrouped` are
  unchanged, so nothing else moves. New strings `PLUGIN_LBF_SHOW_MORE` / `PLUGIN_LBF_SHOW_LESS`; two
  placeholder icons `lbf-more_MTL_icon_unfold_more.png` / `lbf-less_MTL_icon_unfold_less.png` (Material
  renders its own themed unfold_more/less font-icon from the filename). No matcher change, **no cache
  bump** — pure view state. Gates: `perl -c` clean; 22/22 behavioural assertions against the real
  `_pageSection`/`_pageRow` (cap/no-cap, remainder counts, more→more→less full cycle, absolute+clamped
  targets, collapse-clears-residue, section independence, shrunk-feed clamp with no undef tiles).
- **0.9.85** — **fix: the settings page rendered STALE service priorities after a save.**
  `lbf_services` (which carries each service's CURRENT priority into the template) was built
  in `_render()` **before** `SUPER::handler` persists the POST, so saving a new priority
  re-rendered the page with the old number still in its input — the save HAD applied, but only
  a reload showed it. Moved (with `lbf_blocked`) into **`beforeRender`**, the platform's
  documented post-save hook: `Slim::Web::Settings::handler` persists each `prefs()` pref from
  `$paramRef->{pref_*}`, refreshes its own `prefs` template var from the store, and only then
  calls `beforeRender($paramRef, $client)` immediately before `filltemplatefile`. (`lbf_blocked`
  was already correct — `handler` mutates `blocked_artists` directly before rendering — but it
  belongs in the same hook.) **RULE (fleet-wide): any Settings template variable derived from a
  pref MUST be built in `beforeRender`, never before `SUPER::handler`;** sanitising the incoming
  `$paramRef->{pref_*}` still belongs in `handler`. Surfaced by a code review of the sibling
  Discography plugin, which had inherited the same shape via PFR; fixed in all three the same
  session (DSC 0.10.4, PFR 0.7.4). Settings-render only — no matcher, no cache, **no key bumps**.
- **0.9.84** — **matcher aligned to the fleet-canonical engine** (see the Shared Matching
  Engine section + `tools/matcher_sync_check.py`, both NEW in this version — the checker
  cross-diffs all four repos' copies and hash-pins documented variants). LBF's copy had
  quietly lagged: `_norm` was missing the stylised-punctuation substitutions ($->s, euro/
  pound/yen, !->i, @->a) that PFR/Discography had — so the "P!nk"/"L.U.C.K.Y" class
  (long-open gap 3) is NOW FIXED here, for albums AND tracks (`_trackMatches` shares
  `_norm`); `_albumMatches` was missing the EP/LP-strip and ascii-glyph fallbacks
  (+ their `_stripFmt`/`_asciiNorm` helpers, now added). `_norm` output feeds matching and
  norm-keyed caches, so ALL layers bump: `lbf:stream:14→15`, `lbf:track:5→6`,
  `lbf:pl:resolved:5→6`. Verified via the real module (P!nk, EP-strip, "( )", artist-prefix,
  plus must-not-match controls).
- **0.9.83** — **matcher: two fallbacks ported from the Discography plugin** (both were
  deliberate divergences waiting to come upstream). (1) **All-punctuation / single-char
  album titles** (Sigur Rós "( )", "X"): `_norm` erases them and the <2-char gate rejected
  before comparing — new branch compares `_punctNorm` (lowercase, whitespace stripped,
  punctuation KEPT: "( )" == "()") of the RAW titles, exact equality only + mandatory
  artist gate. The raw album title is threaded to the matcher as a new trailing
  `$albumRaw` arg through all four `run` adapter signatures (auto + manual-Bandcamp call
  sites pass `$album`). (2) **Artist-name-PREFIXED titles** ("Belle and Sebastian Write
  About Love" vs "Write About Love"): strip a leading "<artistNorm> " from both sides and
  re-compare, >=3-char remainder gate. Album matcher only — `_trackMatches` untouched.
  `lbf:stream:13→14` flushes cached album no-matches (track/playlist caches unaffected).
  Verified via the real module: 8/8 incl. must-not-match controls (live edition, wrong
  artist, x-vs-xx, Prism-of-Doom).
- **0.9.82** — **fix: accented artists/titles got junk or empty Qobuz+Tidal search results
  while Deezer worked** (found as the Sigur Rós failure in the Discography plugin, 2026-07-10,
  and ported back here). Root cause: both the album (`_findPlayable`) and track
  (`_findPlayableTrack`) resolvers octet-encoded the outgoing query for EVERY adapter, but the
  service plugins' own URL layers differ — Qobuz escapes query params with `uri_escape_utf8`
  and Tidal transliterates them with `Text::Unidecode`, both of which expect CHARACTER strings,
  so octets double-encoded ("Sigur Rós" was searched as "Sigur RÃ³s"); Deezer's
  `complex_to_query` (and Bandcamp) want octets, which is why they were unaffected. Fix:
  adapters carry `query_enc => 'chars'|'bytes'` (Qobuz/Tidal chars, Deezer/Bandcamp bytes);
  both resolvers build both spellings (`utf8::decode` fails safe on non-UTF-8 input) and pick
  per adapter at the call site. Cache bumps — decisions resolved via mangled queries must
  flush, and per the layered-cache rule the outer layer bumps with the inner:
  `lbf:stream:12→13`, `lbf:track:4→5`, `lbf:pl:resolved:4→5`. Likely retro-fixes part of the
  long-standing "accents" unmatched-tracks gap class (the STREAMING side of it; the local-side
  `_norm` fold shipped in 0.9.57). NOTE (not done): service album searches are relevance-capped
  (Qobuz 200, our Tidal/Deezer calls 50) — the Discography plugin moved to artist-first
  fetching (resolve artist, pull their album list) for that reason; candidate here if deep
  discography misses ever show up in LBF resolution.
- **0.9.77** — **fix: DSTM Radio dropped to random library tracks during a ListenBrainz
  Popularity-API outage.** Diagnosed live (player BackGardenSpeaker): the seed resolved and
  `getSimilarArtists` returned 100 artists, but every `getTopRecordingsForArtist` fan-out call
  returned `500 "Popularity API currently disabled due to high load on the server"` — a
  ListenBrainz **server-side** shutdown of `/1/popularity/top-recordings-for-artist`, not our
  bug. EVERY radio sub-path (similar-artists, seed-only, AND the Last.fm fallback) funnels
  through that one endpoint to turn artists into tracks, so none could produce candidates; the
  handler returned `[]` and core DSTM fell through to random library albums. The Last.fm fallback
  couldn't help (it shares the dead endpoint) — the fallbacks were also only wired to the
  *empty/error* branches of `getSimilarArtists`, not to a similar-succeeds-but-pool-empty
  outcome. Fix: `_resolveAndReturn` now, when a **radio** pool is empty, falls back once to the
  **Recommended CF pool** (`/1/cf/recommendation/...` — a DIFFERENT endpoint, confirmed up during
  the outage), instead of returning `[]`. Centralised there so it covers all three radio sites
  (similar-success, seed-only, Last.fm-success); `'recommended'` is guarded from recursing, so an
  all-endpoints-down case still terminates cleanly. **Known follow-up (not done):** during an
  extended outage each top-up still fires ~24 doomed 500s at the disabled endpoint — a short
  negative-cache of the "Popularity disabled" state would let `_collectArtistTracks` skip the
  fan-out and go straight to the CF fallback (be a better API citizen). No cache-version bump.
- **0.9.76** — **fix: cached Deezer album matches silently vanished on re-read.**
  `_rebuildStreamItems` reattaches each service's browse coderef by `_svc` but only had
  Qobuz/Bandcamp/Tidal branches — a Deezer match hit the `else { next }` and was dropped
  on every cache-hit re-open (it only rendered live on first search). Deezer's album node
  is the SAME shape as Tidal's — `_renderAlbum` sets `url => \&getAlbum` (a coderef,
  stripped by `_cacheStream`) with the album id in `passthrough` (plain data, survives the
  cache), so the fix is a one-line Tidal-style branch: `$item{url} = \&…Deezer::…getAlbum`.
  Also added `getAlbum` to the Deezer adapter-registration `->can` guard so Deezer only
  registers when the full album round-trip is possible (mirrors Tidal), and corrected the
  adapter comment that had loosely described the album url as a "string deezer:// url" (that
  string is the `play`/favourites value; the browse url is the coderef). No cache-version
  bump — existing cached Deezer entries (id in passthrough) now rebuild correctly instead of
  dropping. Verified `_renderAlbum`/`getAlbum` against michaelherger/lms-deezer. (Surfaced
  while porting this engine to the Album Reviews plugin, which had the same gap.)
- **0.9.75** — **code-review fixes: follow "Play what's new" + Deezer robustness (no cache bump).**
  (1) The "Play what's new" row was a `type=>'playlist'` container nested inside the People-You-Follow
  list; the follow level is the tile's Play-all source, so Play-all re-expanded the container and
  **queued the new tracks twice**. It's now a `type=>'link'` DRILL row that opens a **pure track list**
  (no dividers) — itself a proper Play-all container. (2) Its resolved, service-filtered items are
  **threaded through the passthrough** (the follow level is live/`cachetime=>0`, always fresh), so
  `playFollowNew` no longer re-reads a resolved cache that may have been **evicted between render and
  tap** (the cache read is now only a fallback) — count and contents can't disagree. (3) `_searchDeezer`/
  `_searchDeezerTrack` now tolerate a bare-arrayref OR hash-wrapped (`{data}`/`{albums}`/`{tracks}`)
  search response and bail to a clean miss on any other shape, so a shape mismatch degrades to a
  no-match instead of dying inside the async callback (outside `_findPlayable`'s eval) and leaving the
  service un-settled until its timeout. Matching/caching otherwise unchanged. See
  [[lbf-action-rows-placement]].
- **0.9.64** — **"Search Bandcamp" is a tap-to-choose picker; choosing pins the match and re-opens the album armed.** The manual Bandcamp search no longer refreshes the detail page in place — that showed the match but left it un-armed for Material's custom actions when Bandcamp was the **sole** source (Material sets `view.itemCustomActions` only on a fresh drill-in / `browseHandleListResponse`, **never** on the in-place `refreshList` — browse-page.js:1568), so "Add to Listen Later / Wish List" was missing until you backed out and re-entered. Now the one `nextWindow => 'refresh'` search row drives **both** outcomes because Material only honours `nextWindow` on an **empty** response (browse-functions.js:834): a **match** returns a picker sub-page (a "Tap an album to use it as this release's match" prompt + one **non-playable** `type=>'link'` row per candidate, real cover + `Album / Artist`); a **miss** returns an empty list → inline refresh, row flips to "…tap to retry" (no dead-end). Tapping a candidate **pins** it (`_bcMatchKey`; nothing pinned until chosen) and calls **`_releaseDetail($rel, …)` to re-render the album page as a fresh drill** — which shows the match inline AND arms Add. The pinned item is byte-for-byte the old persisted form (logo image; cover/page-URL/artist/year on the favurl), so inline render, replay and the Listen Later handshake are unchanged; **no cache bump**. `$rel` is threaded `_releaseDetail → _bandcampSearchRow → _searchBandcampOnly → the choose coderef`. Supersedes the abandoned **0.9.61** (choose-then-auto-pop-to-`parent`) and **0.9.62–0.9.63** (drill-in of *playable* rows — tapping played/opened the album instead of choosing) iterations. Verified live. **KEY Material fact for this family of bugs:** `refreshList` never re-arms `itemCustomActions`; only a fresh drill does — so any flow that must expose a custom action has to land the user on a freshly-drilled view, not an in-place refresh.
- **0.9.60** — **code-review fix: manual Bandcamp watchdog re-entry.** `_searchBandcampOnly` runs its
  ordered queries (`_bandcampArtists` full/collab/album-only) sequentially under ONE overall watchdog.
  `$tryNext` had no `$done` check, so if a search hung past the watchdog (`min(STREAM_SVC_TIMEOUT*queries,
  30)`s), fired `$finish->([])`, and *then* returned empty, its callback re-entered `$tryNext` and started
  the next query's search — a heavy synchronous Bandcamp parse *after* the row already re-rendered (the
  loop-stall class Bandcamp was made manual to avoid). Added `return if $done;` at the top of `$tryNext`
  (mirrors `$finish`'s idempotency). Control-flow only — no cache bump, matching/caching unchanged.
- **0.9.59** — **Favurl also carries the release year (`&y=`) so Listen Later can dedupe by year.**
  Extends the 0.9.58 handshake: `_attachFavUrl` now appends `&y=<year>` next to `&a=`. Listen Later
  0.1.43 keys its duplicate check on `artist|album|year`, so two same-titled releases from different
  years (Chanel Beads' 2024 vs 2026 "Your Day Will Come") save as two entries instead of the second
  being dropped. Year is derived from `$rel->{release_date}` in `_releaseDetail` and threaded through
  `_findPlayable` (new trailing `$year` param, after `$force`) and `_searchBandcampOnly`/
  `_bandcampSearchRow` to `_attachFavUrl`. Cache `lbf:stream:11:`→`:12:` so albums re-resolve once and
  bake in the year; `lbf:bcmatch:` still not bumped.
- **0.9.58** — **Matched streaming albums carry the artist to Listen Later (`&a=` favurl handshake).**
  The detail-page Add-to-Listen-Later / Wish List rows sent no artist — Material exposes no
  `$ARTISTNAME` for them (thumbnail = service logo, subtitle unmapped) — so the sibling plugin
  stored an artist-less record that never auto-moved to Played (Played matching keys on
  source+artist+album). `_attachFavUrl` now appends a private `&a=<URI-escaped artist>` to the
  favurl next to the existing `?cover=`/`?b=` payload (both callers — the `_findPlayable` settle
  loop and `_searchBandcampOnly` — pass the raw release artist); Listen Later 0.1.42+ reads it as a
  fallback when `$ARTISTNAME` is empty, then strips it so the `album:<id>` logic sees a clean URL.
  Native streaming-plugin favurls (no query string) never trigger it. Cache `lbf:stream:10:`→`:11:`
  so Qobuz/Tidal albums re-resolve once and bake in the artist (free — they self-resolve);
  `lbf:bcmatch:` deliberately NOT bumped (Bandcamp rows already surface an artist; no auto-repopulation).
- **0.9.57** — **Diacritic/accent folding in `_norm` (no cache-version bump).** The matcher normaliser
  now folds Latin diacritics to base ASCII so accented names match a catalogue/library that spells them
  plainly, or with a different Unicode form of the same accent — fixing `Altın Gün — Neredesin Sen`
  (dotless `ı`, `ü`) missing on Qobuz despite being there. Algorithm: `lc` → NFD → strip ONLY the Latin
  combining-mark block `U+0300–036F` → NFC (re-compose, so non-Latin base+mark like Japanese voiced
  kana `ば`=`は`+`U+3099` survives) → map the atomic Latin letters NFD can't split (`%FOLD`: `ı ł ø ð þ
  ß æ œ ħ …`). Gated on `utf8::is_utf8` + `Unicode::Normalize` present (core module; guarded require, so
  a stripped Perl degrades to no-fold). Feeds streaming album/track matching (`_albumMatches`/
  `_trackMatches`), the local-library matcher and de-dupe. ASCII names produce byte-identical output →
  their caches are untouched; only accented-name albums re-key and re-resolve once (self-healing, free) —
  hence no version bump. `tools/match_check.py` updated to the same algorithm (was NFKD + strip-all-marks,
  which mangles Japanese and missed Turkish `ı`); folding is now its default, `--fold` = pre-fold vs
  shipped compare.
- **0.9.56** — **Bandcamp collab-search fallback (no cache bump).** The manual "Search Bandcamp"
  (`_searchBandcampOnly`) now tries an ordered list of RAW queries — full `artist album`, then **each
  collaborator + album** (`_bandcampArtists` splits `&`/`+`/`feat`/`ft`/`with`/`x`/`vs`), then
  album-only — stopping at the first `_albumMatches` hit, instead of a single combined query. Fixes a
  two-artist release that Bandcamp's search only surfaces under one of the artists (*Panda Bear & Sonic
  Boom – A ? of WHEN*). We still do NOT drill an artist's discography (`album_list`); this is
  search-recall only. Extra searches run only on a miss and only on a user tap.
- **0.9.55** — **code-review fixes (no cache bump).** (1) A **persisted manual Bandcamp match** is no
  longer truncated off the detail page: `_streamResult` now caps only the auto (Qobuz/Tidal) matches at
  `STREAM_MAX_RESULTS` and appends the pinned Bandcamp match *after* the cap (deduped), so a 12+-match
  generic title can't drop the Bandcamp-only entry that's meant to be primary. (2) `_parseLastfmTags`
  reads a tag's `count` through a ref guard (was an unconditional deref in both the sort and the
  low-weight filter — a strict-refs die if Last.fm ever returned a bare-string tag). (3) The DSTM
  per-session no-repeat set (`$state{cid}{played}`, never reset by design) is **FIFO-capped at
  `PLAYED_MAX`=5000** so a marathon session can't grow it unbounded. Reviewed but intentionally left:
  DSTM marks all *attempted* candidates (not just returned) as `served` — that prevents re-searching the
  same over-fetched pool next top-up and self-corrects on exhaustion, so it's a deliberate tradeoff, not
  a bug.
- **0.9.54** — **Warm defers during a library scan; manual "Refresh playlist matches"; opt-in debug log.**
  (1) **Fix:** `Plugin::_warmTick` now defers while `Slim::Music::Import->stillScanning()` (re-checking
  every `WARM_SCAN_RETRY`=120s) instead of resolving against a half-scanned library — which had made the
  startup warm resolve **every** owned track to streaming and cache that all-streaming result for the
  resolved-playlist TTL, with later warms skipping the already-cached playlist (diagnosed live: 50/50
  Qobuz, zero library hits, for a user who owned the tracks; "worked on dev" because a dev library is
  already scanned when the warm fires). (2) **Add: "Refresh playlist matches"** row at the **top of the
  Playlists view** (mirrors the feed refresh; not in Settings) → `Browse::refreshPlaylists` →
  `warmCache(force=>1)`; a `$force` flag threaded through `warmCache`→`_resolveTracks`→`_findPlayableTrack`
  re-resolves past **both** cache layers, library-first (async, needs a connected player). (3) **Add:**
  opt-in `debug_log` pref → `Plugin::dbg` writes the warm/resolve timeline (incl. per-playlist
  **library-match count** + scan-defers) to `lbf-debug.log` beside `server.log` (size-capped, one
  rotation; also mirrored to `server.log` at INFO). (4) Debug utilities `tools/match_check.py` (+`--fold`)
  and `tools/fetch_playlist.py` for reproducing the local artist/title matcher off-box. NB: a
  library-first user's playlists take the 1-day `LIBRARY_TTL`, so they re-resolve on each **daily** warm
  — intended (a file URL can go stale on rescan), not the "only-weekly" cheap case.
- **0.9.53** — **Bandcamp page URL now rides the favurl for exact replay (`?b=<art>|<url>`).**
  Bandcamp's `get_album` resolves a tracklist from the album **page URL**, not the `album:<id>`
  in the favurl, so handing a Bandcamp match to Listen Later produced no tracks. `_attachFavUrl`
  now packs the cover art **and** the page URL into one escaped `?b=<art>|<url>` param (Bandcamp
  only — it sets `_albumurl` from the search passthrough; Qobuz/Tidal keep the plain `?cover=`
  and replay by id). Listen Later 0.1.39+ unpacks both → exact `get_album` replay + one-tap
  Buy-on-Bandcamp. **Corrected a wrong conclusion from the 0.9.49–0.9.52 iterations:** the belief
  that "Material drops a favurl > ~150 chars" was an artifact of a **stale repo-installed LBF
  shadowing the manual dev build** (the new favurl code never ran, so the add arrived with no
  favurl). With the right build loaded, the full ~164-char favurl arrives intact — verified by
  the saved record keeping the real cover *and* the page URL. The discarded
  `docs/material-favurl-length-issue.md` (written for the Material dev about the non-existent
  limit) was removed. No cache bump: `lbf:bcmatch:` is never bumped (a fresh manual "Search
  Bandcamp" bakes the new favurl in; older cached matches play without the `?b=` URL until
  re-searched — same rule as 0.9.47). 0.9.49–0.9.52 were the intermediate favurl attempts,
  superseded by this.
- **0.9.48** — **library track matching no longer blocks the event loop (low-power / Raspberry Pi friendliness).**
  `_findPlayableTrack`'s local-library probe (`_findLocalTrack` → `Slim::Schema` / the `titles` request) is the
  one SYNCHRONOUS step in the otherwise-async track resolver, and LMS's DB layer has no non-blocking form (single
  SQLite connection, single thread — can't be made to `await` or run off-thread). Previously, a playlist that matched
  mostly from the library completed each probe synchronously and re-entered `_resolveTracks`' pump in the **same**
  event-loop pass — up to ~50 blocking DB queries with no yield, starving audio on a Pi (the background warm and a
  cold new-week open were the worst cases, exactly the loop-stall class that got Bandcamp pulled from the auto-search).
  Fix: every library probe now runs via `Slim::Utils::Timers::setTimer(undef, time(), …)` (an idle tick), so the loop
  services audio/UI **between** probes. To do this `_findPlayableTrack` was restructured — a `$deferLocal` helper wraps
  the probe and the streaming phase is factored into a `$runStreaming` closure so the `first`/`fallback`/no-adapter
  tiers can run it after their deferred probe. **Same total work, no contiguous freeze; matching/caching/behaviour
  unchanged** (the probe is reached only on a cache MISS — the warm pre-resolves, so normal opens are cache hits that
  never get here), so **no cache bump**. NB: the DB query itself still blocks for its own (short) duration — deferral
  isolates each one; it can't make a single query async. If a single `titles` search is ever slow enough to matter on a
  huge library, the next lever (not taken here, has cache-poisoning subtlety) is MBID-only library lookup during the warm.
  Also folded in three no-behaviour-change cleanups: trimmed a stale cache-version list in `_findPlayable`'s comment
  (named `:7:` while the key is `:10:` — authoritative history is on `_streamKey`); dropped two unused strings
  (`PLUGIN_LBF_PLAY_VIA`, `PLUGIN_LBF_NO_SERVICES`); and `_parsePlaylistTracks` stopped parsing three never-read JSPF
  fields (`duration_ms`, `caa_id`, `caa_release_mbid`).
- **0.9.47** — **code-review fix: stop the favurl cache bump from discarding manual Bandcamp matches.**
  The 0.9.42 favurl work bumped the persisted-Bandcamp-match key `lbf:bcmatch:6:`→`:7:`. Unlike the auto
  play-via cache (`lbf:stream:*`, which re-resolves itself on the next detail-page open), `lbf:bcmatch:`
  has **no automatic repopulation** — a match only returns via a manual "Search Bandcamp" tap — so the bump
  silently dropped every hand-curated Bandcamp-only match on update, leaving those releases with no playable
  entry until each was re-searched by hand. Reverted the key to `:6:`: existing matches survive the upgrade
  and keep playing; a *fresh* search still bakes the favurl in (`_searchBandcampOnly` → `_attachFavUrl`), an
  older cached match just plays without the favurl until it's next re-searched. Qobuz/Tidal are unaffected —
  their `lbf:stream:10:` bump stands (that cache re-resolves on its own, so bumping it is free). **Rule: never
  bump `lbf:bcmatch:` for a change the auto path already handles via `lbf:stream:`.**
- **0.9.46** — **code-review fix: utf8-safe cover encoding in the favurl.** `_attachFavUrl` now
  encodes the `?cover=` album-art URL with `URI::Escape::uri_escape_utf8` instead of `uri_escape`,
  which `carp`s + emits a malformed escape on code points > 255. Art URLs are ASCII in practice, so
  no behaviour change and **no cache bump** — just removes the one new spot that fed a possibly
  utf8-flagged string to a non-utf8-safe escaper (the file otherwise `utf8::encode`s before every
  wide-char-sensitive call).
- **0.9.45** — **Finalise the Qobuz-duplicate fix + favurl guard tidy.** Removed the temporary
  `QOBUZ-DIAG` log from 0.9.44 (the live box confirmed the bogus *Beth Orton – The Ground Above*
  entry is flagged non-streamable, so `streamable`-only is enough). Also hardened `_attachFavUrl`:
  the `?cover=` guard is now `!ref $art` instead of `$art !~ /^CODE/`, so any ref (not just a
  coderef) is rejected before it can be stringified into the favurl. No cache bump (neither change
  alters which results match or what gets cached).
- **0.9.44** — **Dismiss the bogus Qobuz duplicate by the `streamable` flag alone.** Replaced
  0.9.43's non-streamable-and/or-`*`-prefixed-title test with the **non-streamable** check only
  (`defined $album->{streamable} && !$album->{streamable}`) in `_searchQobuz` — the `*` heuristic
  never actually distinguished the two duplicates (`_norm` strips a leading `*`) and risked dropping
  a real `*`-titled album. Cache `lbf:stream:9:`→`:10:` so albums re-resolve once. (Shipped with a
  temporary `QOBUZ-DIAG` log to confirm on the live box; removed in 0.9.45.)
- **0.9.43** — **Skip bogus Qobuz partial/orphaned album duplicates.** Qobuz's catalogue
  can list a release twice: the real playable album plus a non-streamable partial/orphaned
  entry whose title is `*`-prefixed (e.g. *Beth Orton – The Ground Above* → two matches, one
  dead). `_norm` strips the leading `*`, so `_albumMatches` passed the bogus one and it
  showed as a second streaming row. `_searchQobuz` now drops a candidate when
  `defined $album->{streamable} && !$album->{streamable}`, or its raw title `=~ /^\s*\*/`,
  or (belt-and-braces, after rendering) the display `name`/`line1` starts with `*`. Scoped
  to the Qobuz **album** path; the track path (`_searchQobuzTrack`) is unchanged — revisit
  if a bogus entry ever surfaces in a playlist. Cache `lbf:stream:8:`→`:9:` so cached albums
  re-resolve once and drop the dead entry.
- **0.9.42** — **Listen Later interop for matched streaming albums.** Each matched
  Qobuz/Tidal/Bandcamp album on the detail page now gets an explicit
  `favorites_url => "<scheme>://album:<nativeId>"` (`_attachFavUrl`, called from the
  `_findPlayable` settle loop and the manual-Bandcamp `finish`; the native id is stashed
  as `$item->{_albumid}` in `_searchQobuz`/`_searchTidal`/`_searchBandcamp`). XMLBrowser
  copies an explicit `favorites_url` into `presetParams.favorites_url`
  (`= $item->{favorites_url} || $item->{play} || $item->{url}`) which Material exposes as
  `$FAVURL` — previously the rows had none, so the coderef `url` leaked through as the
  favurl (the sibling Listen Later plugin saw a "broken link", couldn't tell the service,
  and stored the logo as the cover). **Cover-vs-logo trick:** the row's `image` stays the
  **service logo** (the detail-page indicator), so the album art can't ride `$IMAGE`;
  instead `_attachFavUrl` appends `?cover=<URI::Escape-d native album art>` to the favurl.
  Listen Later 0.1.30+ parses `?cover=` off the favurl, prefers it over `$IMAGE`, then
  strips it so its source/`album:<id>` logic sees a clean URL — a private convention
  between the two plugins, opaque to Material (which just forwards the favurl). The
  decorated favurl survives the play-via cache (`_cacheStream`/`_rebuildStreamItems` keep
  `favorites_url`+`_albumid`). **Cache bumped** `lbf:stream:7:`→`:8:` and `lbf:bcmatch:6:`→`:7:`
  so every album re-resolves once on update and gains the favurl — old cached matches lacked
  it, so without the bump a recently-opened album would serve a stale (favurl-less) match for
  up to its 7d TTL. NB: the "Add to Listen Later" action only renders on a
  Material build with PR #1235's online-custom-actions support. Side effect: native LMS
  "Add to Favourites" on these rows would now save the decorated URL (was a broken coderef
  before, so no regression).
- **0.9.41** — **code-review fixes: streaming robustness + dead-code cleanup.**
  (1) **Album streaming search guards the foreign renderer.** `_searchQobuz`/`_searchTidal` now wrap
  the service's own album renderer (`Qobuz::_albumItem` / `TIDAL::_renderAlbum`) in an eval INSIDE the
  async search callback — where `_findPlayable`'s invocation-time eval doesn't reach. A broken/changed
  renderer now skips that item instead of leaving the service un-settled until its 8s timeout (matching
  the track path's long-standing `_renderTrack` guard). One bad item is skipped, not the whole service.
  (2) **Album play-via gained the track path's "inconclusive" concept.** A service that couldn't be
  QUERIED (no API handler at search time, a timeout, an error, or a renderer that produced nothing from
  a real match) signals `undef` (not `[]`) and is cached as a no-match only `STREAM_INCONCLUSIVE_TTL` =
  1h, so it retries soon. A genuine "searched fine, not there" miss still caches 1 day
  (`STREAM_NOMATCH_TTL`); a found match still 7 days. So a transient outage or a just-released album
  recovers within the hour (or instantly via Refresh) instead of being pinned for a day — the album path
  now mirrors `_findPlayableTrack` exactly. **Verified against the live `/cf/recommendation` API** that
  `artist_type` similar/raw/top return the identical payload and that omitting it returns the same data.
  (3) **Cleanup, no behaviour change.** Removed the dead `annotation`/`track_count` fields and the now-
  orphaned `_stripHtml` from `_parsePlaylistList` (neither was ever read — the tile shows the period +
  resolved match count, not the annotation); dropped the unused DSTM recommendation `flavour`/`artist_type`
  parameter (request unchanged, fixed at `similar`; the endpoint feeds both the Recommended mixer and
  Radio's cold-start fallback); and removed a redundant double-`_norm` in `_streamId` (proven byte-
  identical, so cache keys are unchanged). Matching logic (`_albumMatches`/`_trackMatches`/`_norm`) untouched.
- **0.9.40** — **code-review housekeeping (no behaviour change beyond one bugfix).**
  (1) **Bugfix:** a dead `//` fallback (`_pickValue` returns `''`, never undef) meant a release with
  no artist/album credit rendered as `" — Album"` with no name — the `// 'Unknown Artist'` /
  `'Unknown Album'` fallbacks are now `||` so they actually apply. (2) **`USER_AGENT` no longer
  hardcodes the version** — `API::USER_AGENT` is now a memoised sub that reads the version from the
  plugin manifest (`Slim::Utils::PluginManager->dataForPlugin(...)->{version}`); it had silently
  lagged 17 releases (stuck at 0.9.22). **Rule: never restate the version in code — derive it from
  install.xml via the manifest.** (3) **`_cachedSvcUsable($svc, $enabled?)`** takes an optional
  precomputed `{ lc-name => 1 }` enabled-set; `_playlistResult` / `_playlistTile` build it once per
  render instead of rebuilding the whole adapter set (3 `->can` probes + prefs reads) once per track.
  (4) **Watchdog timers cancelled on normal completion** (`Slim::Utils::Timers::killSpecific`) in
  `_resolveTracks`, `_releaseDetail`, `_searchBandcampOnly` and the per-service timeouts in
  `_findPlayable` / `_findPlayableTrack` — they were harmless idempotent no-ops but lingered holding
  closures for their TTL. (5) **`dstm_batch` fallback** `|| 10` → `|| 15` to match the init default.
- **0.9.20 → 0.9.39** — **streaming-match & playlist robustness, Bandcamp rework, diagnostics.**
  `header-basic` dividers on Material 6.4.3+; **artist-only** album search and a **RAW (un-normalised)
  query** to every service search — fixing stylised names/titles (`L.U.C.K.Y`, `P!nk`) the services'
  own search couldn't match; **Bandcamp** moved to a manual, **persistent** "Search Bandcamp" (own
  long-lived match key, primary when it's the sole source) + "Re-search"; **service-aware**
  per-track/resolved-playlist caches so disabling/uninstalling a service **drops AND re-matches**
  (parity with Releases); transient-outage resolves cached **short (inconclusive)** instead of
  poisoning for weeks; resolved-playlist TTL cut **30d→14d**; **layered-cache** version bumps
  (`lbf:pl:resolved:4:`, `lbf:track:4:`, `lbf:stream:7:`); and a browsable **"Unmatched tracks
  (debug)"** view. Architecture in **Created-for-You Playlists** above; per-version detail in
  **CHANGELOG.md**.
- **0.9.0 → 0.9.19** — the **Don't Stop The Music propagators** (ListenBrainz Radio + Recommended;
  seed/evolve, library-first, no-repeat, artist diversity, Qobuz multi-artist matching, batch=15) and the
  **release detail page restructure** (three Material sections Streaming/Artist/Album, artist photo +
  biography via MAI or Last.fm, Read-more drill-in, logo-free section headers + action links, MB link
  moved after the tracklist). Architecture in the topical sections above (**Don't Stop The Music
  propagators**, **Release detail page**); per-version detail in **CHANGELOG.md**.
- **0.8.0 → 0.8.15** — the **Created-for-You Playlists** feature plus the surrounding polish
  (track matching incl. local-library preference, weekly-cadence caching, background warm, branded
  bundled covers/badges, the section-header menu, date-span tiles + W/C labels, manual feed refresh +
  daily TTL, and the three Material home shelves). The architecture and the hard-won lessons live in
  the topical sections above (**Created-for-You Playlists**, **Branded cover images**, **Top-level
  menu, tiles & home shelves**); the per-version blow-by-blow is in **CHANGELOG.md**.
- **0.7.2** — **All Releases by-week landing menu.** Tapping All Releases no longer drops straight into the full list; `fetchAll` now returns `_buildAllLanding` (the For You path is unchanged). The landing menu's first item, "All releases" (`PLUGIN_LBF_VIEW_ALL`), is a coderef that returns the previous full view via `_buildItems` (so the weekly-divider/group-by-artist behaviour is preserved under it); below it is one drill-in per week-commencing, labelled with `_weekLabel` + a `(count)`, each coderef returning just that week's `_buildReleaseItem`s. Weeks are grouped with the same `_weekStart`/newest-first logic as `_buildWeekly` (input is already `_sortReleases(_filterAll(...))`). All coderefs are live feed nodes (not cached/serialised), matching `_buildWeekly`/`_buildGrouped`. NB: this is a browse-only navigation split — no new prefs, and the week grouping always runs regardless of the `week_dividers`/sort prefs (those still govern what "All releases" shows).
- **0.7.1** — **Non-Latin artist match fix (real root cause of the "Prism" 48→still-many hits).** The 0.7.0 `_norm` made the regex Unicode-aware (`\p{Alnum}`), but that only works on a utf8-*flagged* string. Artist/album names actually reach `_findPlayable` as raw **UTF-8 octets** (no flag) — via the Storable stream cache and the play passthrough. On the server's Perl (no `unicode_strings` in scope), `\p{Alnum}` on those bytes stripped the whole non-Latin name → `artistNorm eq ''` → `_albumMatches` fell to its "exact-title-only, no artist" branch → every album literally titled "Prism" matched (was 48; capped to 12 by `STREAM_MAX_RESULTS`, which is the "lots" the user still saw). Verified locally: byte-string `_norm("踊って…")` empties/garbles on the no-`unicode_strings` path, decoded `_norm` yields `踊ってばかりの国`. Fix: `_norm` now `utf8::decode`s octet input (guarded — only adopts the result if it's valid UTF-8, and only when the string has a high byte) before lowercasing, so the name survives as real codepoints and the artist again acts as the disambiguator (simulated: Katy Perry/Prism + Roxette/Prism → reject, real band → match). Also: the search query sent to the streaming services is now an explicit octet copy (`$queryEnc`, `utf8::encode`) so a wide-char query can't warn/break in the URI layer, while `artistNorm`/`albumNorm` stay characters for matching. Stream cache key bumped `:3:`→`:4:` (and the manual-refresh `$cache->remove` follows) so the stale wrong matches from 0.7.0 invalidate automatically — no manual refresh needed.
- 0.0.x — Initial development, plugin loading fixes, API parsing fix
- 0.1.0 — PNG icon
- 0.1.1 — Lyrion-spec icons
- 0.1.2 — Image proxy caching, Browse by Type
- 0.1.3 — Full MusicBrainz type support, removed Release Type filter
- 0.1.4 — Past/Future toggles in top-level menu (later removed due to odd behaviour)
- 0.1.5 — Moved past/future to settings
- 0.1.6 — Icons restored on menu items, settings link added (later removed as broken)
- 0.1.7 — Material Skin release type icons for Browse by Type
- 0.1.8 — Removed broken settings link
- 0.1.9 — install.xml icon switched to .svg
- 0.2.0 — future default to 0, filter out releases without artwork
- 0.2.1 — install.xml icon reverted back to _svg.png
- **0.3.0** — Full restructure: three settings sections, simplified browse menu (no in-menu filters), per-section prefs (For You vs All Releases), Various Artists toggle, comprehensive type checkboxes with Album/Compilation/Soundtrack defaults
- **0.3.1** — Repository metadata and package version alignment; filtering now evaluates the full API response payload
- **0.3.2** — All Releases items now display the actual release title and release type from the ListenBrainz payload
- **0.3.3** — Both feeds paginate in pages of 50 via a "Next page (n/total)" link; the filtered list is captured in-closure so paging never re-hits the API, and the LMS back button returns to the previous page
- **0.4.0** — New Music Tracker–inspired presentation: release detail page now fetches genres + per-disc tracklist (durations) from MusicBrainz on demand (graceful fallback on failure); shows folksonomy tags carried in the fresh_releases payload (cleaned/deduped, no extra call); optional group-by-artist layout (default ON) collapsing multi-release artists; pagination generalised to window any item list. NB: a data probe found MusicBrainz/ListenBrainz genre coverage on fresh releases is ~8–9% (too sparse for genre *filtering* without Discogs), so only on-demand genre/tag *display* was added.
- **0.4.1** — "Find on streaming services" link on the detail page (`play_via` pref, default ON): lazily fans the "artist album" query out to installed streaming plugins via their registered `Slim::Menu::GlobalSearch` providers, so results are playable through each plugin's own protocol handler. Confirmed on the target server that both Qobuz (v3.7.0) and Bandcamp (v1.12.0) register GlobalSearch providers, so no per-service code is needed. `GlobalSearch->menu($client, {search=>...})` confirmed working by live test.
- **0.4.2** — Play-via now resolves to **direct playable albums** via each service's **own search API** (dropped the GlobalSearch approach — it only produced a search drill-down). Per-service adapters in `_findPlayable` / `_streamingAdapters`:
  - **Qobuz**: `Plugins::Qobuz::Plugin::getAPIHandler($client)->search($cb, lc($query), 'albums')`; results in `$res->{albums}{items}`; each title-matched album is rendered with the plugin's own `Plugins::Qobuz::Plugin::_albumItem($client, $album)` (a `type=>'playlist'` node → playable).
  - **Bandcamp**: `Plugins::Bandcamp::Search::search($client, $cb, {search=>$query})`; keep result items whose `passthrough->[0]{album_id}` is set (already-playable album nodes from `album_list`).
  - Adapter availability is detected with `Plugins::<Svc>::Plugin->can(...)` (safe when absent); the detail link is hidden when no supported service is installed. Async fan-out with a pending-counter barrier; title matching via `_titleMatch`/`_norm` (lowercase, strip bracketed qualifiers + punctuation), so it can occasionally miss/mismatch. Adding a new service = one more adapter sub + `_streamingAdapters` entry.
- **0.6.15** — **Icon fix (real root cause found).** Two defects, both fixed: (1) the `.svg` used `#000000`, but Material string-replaces `#000` with the theme colour, corrupting `#000000` → `<colour>000` (invalid) so Material rendered the icon **blank** — changed all 18 `#000000` → `#000` and set the canvas to 24×24 per Material's spec. (2) `…Icon.png` / `…Icon_svg.png` were **JPEGs misnamed `.png`** (opaque 256² black blocks), so non-Material/Manage-Plugins contexts showed a black square — regenerated as genuine transparent RGBA PNGs (centred, 8% pad) via qlmanage→Pillow. `install.xml <icon>` set to `…Icon_svg.png` (the standard two-file Material convention; abandoned the earlier colour-tile and white-SVG detours). Confirmed `OPMLBased` always takes the app icon from `install.xml <icon>` (`_pluginDataFor('icon')`, lines 62/185) and ignores any `icon =>` arg. **Genres bug fix.** Genres were fetched from the *release* (`release/<mbid>?inc=genres`), where they're almost always empty — verified against MusicBrainz: a release-group had 13 genres, its release had 1. Now genres come from the **release-group** via a new `API::getReleaseGroupGenres` (cached by release-group MBID); `getReleaseDetails` drops `+genres` and just returns the tracklist. `_releaseDetail` runs genres (RG) and tracklist (release) as separate parallel tasks (so a detail open can do 2 MB calls, both cached). Genre parsing refactored into `API::_parseGenres`. **But MB genres are empty for most fresh releases** (too new to be tagged — verified a today's-feed release-group returned `[]`), so this rarely shows anything. The practical genre source is the payload's inline `release_tags` (no API call). 0.6.15 now shows up to 3 of these tags on each **list** row's `line2` (via `_releaseTags` in `_buildReleaseItem`, separated by `\x{00B7}`), in addition to the existing detail-page "Tags:" line. Coverage is partial (~20% of releases carry tags), so many rows legitimately show none. **Last.fm genre fallback (detail page):** new optional `lastfm_api_key` pref. When set, the detail page runs `API::getLastfmTags($artist,$album)` in parallel — tries `album.gettoptags`, falls back to `artist.gettoptags` (artist tags are populated even when a brand-new album isn't, so this is what actually fills the gap). `_releaseDetail` now stores `$mbGenres`/`$lfmGenres` and builds ONE "Genres:" line in `$finish`, preferring MB then Last.fm. Tags cleaned/weight-sorted via `_parseLastfmTags` (handles Last.fm's single-tag-as-hash quirk), cached `lbf:lfm:<artist>|<album>` (30d found / 7d empty). No key = graceful no-op; never blocks the page (all Last.fm failures resolve to empty). List rows are deliberately NOT enriched (would be 50+ API calls/page). **Unified section filtering:** For You used to have only a single "Show Albums" toggle (`foryou_albums`); it now has the **same per-type checkboxes** as All Releases (independent `foryou_type_<name>` prefs). Both sections' type/various/artwork filters now go through one shared `_filterSection($releases,$prefix)` + `_allowedTypes`/`_typeMatches` (replacing the duplicated `_filterForYou`/`_filterAll` bodies; both are now thin wrappers). **Default selected types are now Album + Compilation for both sections** — Soundtrack was dropped from the defaults (`all_type_soundtrack` 1→0). NOTE: default changes only affect prefs that were never persisted; an existing install still has `all_type_soundtrack=1` saved, so that box must be unticked once manually (For You is new prefs, so it picks up the new defaults immediately). **Secondary-type filtering bug fixed:** the API field is `release_group_secondary_type` (SINGULAR, a scalar string e.g. `'Live'`) — the code was reading `release_group_secondary_types` (plural/array), so secondary types were never seen and live/soundtrack albums (which are `primary=Album` + `secondary=Live/Soundtrack`) slipped through. Verified against the API: only two type fields exist, both singular scalar strings, never arrays. New `_secondaryType($rel)` helper reads the singular field (array-tolerant for safety) and is used by `_typeMatches`, `_displayType`, list `line2`, and the detail page. `_typeMatches` now uses **allowlist** semantics: primary type must be ticked AND the secondary type (if present) must also be ticked. The API's secondary set is larger than the offered checkboxes (DJ-mix, Audiobook, Interview, Spokenword, Mixtape/Street, Field recording, Audio drama) so any untickable secondary correctly fails the filter. Simulated on the live feed with Album+Compilation: 19,709→6,413 kept, all primary=Album, secondaries only None+Compilation, zero Live/Soundtrack. `_displayType` now shows `primary / secondary` (e.g. "Album / Live"); the redundant separate `PLUGIN_LBF_SEC_TYPES` detail line was removed. **Week dividers as real Material headers:** Material advertises `features:hi` in its browse requests ('h' = it supports the `header` item type, which renders bold/accent and enables grid view). XMLBrowser passes the item `type` straight through (`Slim::Control::XMLBrowser` line ~1050: `$hash{type} = $item->{type}`), and Material's `browse-resp.js` sets `item.header=true` for `type=='header'`. When the client supports it, week-divider rows are emitted as `type => 'header'` instead of `type => 'text'`; non-supporting skins still get plain text. **Gotcha (cost a debug cycle):** `features` is a request param only available to the TOP feed (XMLBrowser builds the coderef sub-feed's `$args->{params}` from `$feed->{query}`, line 491 — NOT the request params — so `fetchForYou`/`fetchAll` never see it). Fix: `topLevel` reads `features` via `_featuresOf($args)` and forwards it through each menu item's `passthrough` (which XMLBrowser DOES pass to the coderef, line 521); `fetchForYou`/`fetchAll` read `$passDict->{features}` and call `_wantHeaders()`. Diagnosed via JSON-RPC: `listenbrainzfreshreleases items 0 N item_id:1 features:hi` returned `type:'text'` for dividers (proving the broken detection); after the passthrough fix it returns `type:'header'`. **Header "More" gotcha (0.6.15):** in menu mode XMLBrowser forces a `go` (drill) action onto EVERY non-`text` item — only `type:'text'` gets `itemNoAction` (line ~1174), and `$item->{style}` only sets `$windowStyle`, while the `jive` override runs too late and gets stripped (line ~1372). So a `header` item always carries `actions.go`, and Material renders a "More" link for any header with actions (`item.slimbrowse && item.header && item.actions`) — which drilled to `item_id:X` returning `count:0` ("reveals nothing"). There is NO way to keep `type:'header'` AND suppress the action. Resolution (user choice): instead of fighting it, `_buildWeekly` now gives each week header a `url` coderef (+`passthrough`) that returns just that week's releases (same pattern as `_buildGrouped`), so tapping a week header / its "More" shows that week rather than an empty page. `_buildWeekly` groups by week up-front to build the per-week coderef. Verified the full server response (with `menu:1 useContextMenu:1`) to confirm the forced `go`/`addAction`. **Home-page click-in dividers (0.6.15):** the Material home shelf is itself `LBFForYou items …` (our `homeForYou`, registered via `HomeExtraBase`). The carousel and the expanded "show all" view run the SAME command — only the requested quantity differs (`HomeExtraBase`/Material don't forward `ismore` to the feed): carousel = `NUM_HOME_ITEMS` (10), expand = `LMS_BATCH_SIZE` (25000). So `homeForYou` now reads `$args->{params}{_quantity}` and, when `>50` (the click-in), returns `_buildItems($releases,$client,1)` (week dividers/headers + per-week drill coderefs) instead of the flat capped card strip; the carousel path is unchanged. Headers are forced on (1) because `LBFForYou` is only ever invoked by Material. Material's `browse-resp.js` re-parses the click-in (`ismore`) results through the main `parseBrowseResp`, so `type:'header'` renders identically to the For You menu. **CRITICAL fix — feed caching (0.6.15):** the ListenBrainz feeds (`getFreshReleasesForUser`/`getFreshReleasesAll`) were NEVER cached, so every Material home-row load re-fired a slow (2–15s) API call. Diagnosed from the live server log (fetched over HTTP at `http://<lms>:9000/log.txt`): 9 `Fetching for-you releases` in ~3 min, **0 cache hits**, `Server closed connection` (ListenBrainz rate-limiting the flood), and `Slim::Web::JSONRPC::requestWrite Context not found` (response arrived after Material gave up) → home carousels never loaded / Material appeared hung. Fix: cache the parsed feed under `lbf:feed:user:<username|sort|past|future|days>` and `lbf:feed:all:<…|date>` for `FEED_TTL` (6h); first view fetches, the rest are instant, killing the flood. The menu browse and the home row share the same key (same prefs). Lazy refresh was chosen over a scheduled daily fetch (a "fresh" feed wants intra-day freshness; the plugin is global so there's no per-listener timezone; All Releases also auto-rolls at local midnight via the date in its key). **Settings dropdown fix:** the **Default sort order** was a native `<select>`, whose option popup drew over / bled through the rows below it in Material's settings view (native `<option>` popups can't be reliably restyled). Replaced with a radio-button group (same `pref_sort` name/values) — no popup, no overlap, consistent with the page's existing checkbox blocks. `settings.html` now has no `<select>` elements. **Streaming-link fixes (0.6.10):** (1) `_albumMatches` now requires the candidate title to *equal* or *start with* (`index($t,"$albumNorm ")==0`, word-boundary) the album, not merely contain it — fixed "Apollo" by Gene matching "Friendship 7 to Apollo 11…". (2) `_dedupeStreamItems` (called from `_streamResult`, so both fresh and cached paths) collapses duplicate matches keyed on `_svc`+name+line2 — e.g. Bandcamp returning the same album twice — while different editions (which differ in name, "(Hi-Res)" vs "(Album)") are kept. Duplicate albums in the *feed itself* (ListenBrainz/MusicBrainz listing one release twice, sometimes as two release-groups) are collapsed by `_dedupeReleases` in `_sortReleases`, keyed on normalised artist+album+date (rg-MBID differs, so can't key on that). **Home-shelf playback fix (0.6.11) — IMPORTANT:** `homeForYou` must return a structure that does NOT vary by request quantity. The 0.6.3–0.6.10 version returned flat cards for the carousel (qty≤50) but `_buildItems` (week headers + per-week sub-feeds) for the "show all" (qty 25000). Play commands re-traverse the feed by `item_id` with a *different* quantity than the view used, so the path landed on the wrong node and no play command was sent — streaming playback from the home shelf silently failed (browse worked because it used the carousel quantity). Reverted `homeForYou` to ALWAYS flat (capped 50) for both carousel and click-in; week dividers stay only in the main menus. **Rule: anything reachable by a play/drill `item_id` must be quantity-stable.** **Grid view (0.6.15):** week-divider headers now get `image => ICON`. Material's grid detection counts headers; an image-less item set `haveWithoutIcons` and disabled the grid/list toggle for the whole page. With every item carrying an image the grid view stays available (same trick as the Listen to Later plugin's `_header`). **Wide-character crash fix (0.6.15):** detail pages for releases with CJK/emoji titles returned an EMPTY response (no data) — only when a Last.fm key is set. `getLastfmTags` built its cache key from the RAW `$artist`/`$album` (the only one of our cache keys that does), and those JSON strings carry the utf8 flag; `Slim::Utils::Cache`→`DbCache::_key` runs `Digest::MD5::md5_hex($key)`, which dies "Wide character in subroutine entry" for code points >255 (Latin-1 titles ≤255 silently downgrade, which is why only CJK/emoji crashed). The die aborts the whole `items` dispatch → `Bad dispatch!` → empty JSON-RPC body → Material shows nothing. Diagnosed from `http://<lms>:9000/log.txt`. Fix: `utf8::encode($artist/$album) if utf8::is_utf8(...)` at the top of `getLastfmTags` (guarded so plain Latin-1 octets aren't double-encoded) — makes the cache key octets (md5-safe) and also fixes the per-byte percent-encoding in `_lastfmCall`. NB: when off-network, the LMS box is reachable as `http://plex:9000` (not the 192.168.1.234 LAN IP).
- **0.5.2** — Hardening from a code review: (1) **detail-page watchdog** — `_releaseDetail` sets a `Slim::Utils::Timers` timer (`DETAIL_TIMEOUT` 15s) that forces the merge/render if a streaming or MusicBrainz callback never fires (a hung/partial-failure search previously hung the whole page, including the already-fetched tracklist); `$finish` is idempotent so normal completion makes it a no-op. (2) **guarded cache write** — `$cache->set` in `_findPlayable` wrapped in eval so a Storable serialisation failure can't stop the `$callback` (another hang path). (3) **MBID validation** — the "View on MusicBrainz" `weblink` is only built for a well-formed UUID (it lands in a Material-rendered href).
- **0.5.1** — Better streaming match recall for awkward credits: (1) the service search query is now built from **normalised terms** (`$artistNorm $albumNorm`) so quotes/`&`/commas in multi-artist names don't make the search miss the album (e.g. `Lee "Scratch" Perry & Mouse on Mars`); (2) artist matching switched from bidirectional substring to **token-subset** (`_artistMatch`: every word of the shorter credit must appear in the longer), tolerating word order, `&` vs `,`, and partial credits — while title-contains-album still gates precision. (3) **Home-row icon fix:** the Material home extra now uses the recolourable `_svg.png` icon (as the browse menu does) instead of the install.xml colour tile, which rendered blank in the home row while other plugins showed theirs.
- **0.5.0** — **Material Skin home-page scrollable row** for the For You feed. New `HomeExtras.pm` subclasses `Plugins::MaterialSkin::HomeExtraBase` and registers a home "extra" (`tag => 'LBFForYou'`, `title => PLUGIN_LBF_FOR_YOU`, plugin icon); its feed → `Browse::homeForYou` returns a flat, 50-capped list of release cards (For You filters/sort, no weekly dividers/grouping — unsuited to a carousel). Registered in `Plugin::postinitPlugin`, gated on `MaterialSkin->can('registerHomeExtra')` (mirrors Qobuz/Bandcamp). Also **renamed "For You" → "New Releases for You"** (the `PLUGIN_LBF_FOR_YOU` string drives the browse menu item and the home row; the settings section header `PLUGIN_LBF_SECTION_FORYOU` was renamed to match). Pattern reference: Bandcamp `HomeExtras.pm`. Also added: **README.md** (GitHub docs — features, requirements/ListenBrainz account, defaults, home shelf), an install.xml **`<homepageURL>`** to the repo (shows as the "more info" link in Manage Plugins), and a colour **tile SVG** icon for install.xml so the Manage Plugins icon isn't blank (the existing icons are black silhouettes for Material's recolour and render blank in core Manage Plugins).
- **0.4.9** — The MusicBrainz line on the detail page is now a clickable `weblink` (**View on MusicBrainz**) that opens the release page in the browser, instead of plain text showing the URL. (Same `weblink` mechanism as the top-level Plugin Settings entry.)
- **0.4.8** — **Caching** so revisits don't re-search (uses `Slim::Utils::Cache`, persistent across restarts). Streaming matches keyed by `lbf:stream:<release_mbid>` (TTL 7 days found / 1 day no-match); MusicBrainz tracklist+genres keyed by `lbf:mb:<mbid>` (30 days found / 1 day empty). OPML item `url` coderefs can't be Storable-serialised, so streaming items are cached with `url` stripped + a `_svc` tag and the play coderef is **reattached on read** (`_rebuildStreamItems`: Qobuz→`QobuzGetTracks`, Bandcamp→`get_album`; items whose service is gone are dropped). Note: Qobuz's own API also caches ~5 min internally; this is our durable layer on top. **Barrier fix:** `_releaseDetail` now counts both async tasks (streaming + MB) up front — a cache hit fires its callback *synchronously*, so the old per-task `$pending++` let the barrier complete after the first finished and drop the other's data (symptom: tracklist missing on cached revisits).
- **0.4.7** — Replaced manual drill-in pagination with **native XMLBrowser windowing**: `_buildItems` (and the artist-group drill-in) now return the full filtered+sorted list as one level; LMS/Material window/scroll it. Removed `_paginate`, `PAGE_SIZE`, and the next/prev page strings. Reason: manual pages were separate menu nodes, so Material's in-list search/filter only saw the current page — a single level lets the filter span every item, and gives Material's native scroll + prev/next pager. (Settings filters — artwork/type/VA — were already global, applied in `_filter*` before building items.)
- **0.4.6** — UI polish: (1) fixed mojibake in the week divider — it used a **literal em-dash** in the Perl source (rendered as `â€"`); all non-ASCII must use `\x{}` escapes (as the rest of the file does), decorative dashes dropped; (2) list rows now show **year only** `(YYYY)` instead of the full release date (the week divider carries the date) — matches LMS album-year convention; (3) pagination gained a **Previous page** link (top of page 2+) alongside Next, both using arrow glyphs (`\x{25C0}`/`\x{25B6}`) instead of the plugin logo. NB: pagination is drill-in, so Previous pushes a new level rather than popping — the back button still works; revisit with native XMLBrowser windowing if the stacking becomes annoying.
- **0.4.5** — Streaming match disambiguation: `_albumMatches` (replaces `_titleMatch`) now requires the candidate **title to contain our album title AND the artist to match** (bidirectional substring to tolerate "feat."/credit variants). Fixes wrong-artist results like "Bending Light" pulling in unrelated same-titled albums. Artist is passed through `_findPlayable` → adapters as `$artistNorm`; falls back to title-only when our artist is empty.
- **0.4.4** — Fixes + view options: (1) **sort** is now applied client-side in `_sortReleases` — release date is **newest-first** (the API returned oldest-first), confidence highest-first, artist/album A–Z; (2) **weekly dividers** (`week_dividers`, default ON) add a "— Week of D Mon YYYY —" divider per week in the date-sorted view (`_buildWeekly`/`_weekStart`, Monday-based, via `Time::Local`), taking precedence over group-by-artist for the date sort; (3) top-level menu now has a **Plugin Settings** entry (`weblink` to settings.html) → For You / All Releases / Plugin Settings; (4) **artwork-only filter fix** — `coverArtUrl` now requires `caa_release_mbid` (it used to fall back to the always-present `release_mbid`, so the filter never excluded art-less releases and thumbnails 404'd).
- **0.4.3** — Streaming matches are now shown **inline on the detail page** (no "Find on streaming services" tap): `_releaseDetail` runs the streaming search and the MusicBrainz lookup in parallel and merges both into one callback (base meta → streaming matches → genres → tracklist). Each result uses the **service's own logo** as its thumbnail (`_pluginIcon` → `_pluginDataFor('icon')`) so the source is obvious; dropped the `"Svc:"` name prefix. Trade-off: the detail page now waits on the streaming search(es) before rendering, so it can be a touch slower (Bandcamp scraping is the slowest).
