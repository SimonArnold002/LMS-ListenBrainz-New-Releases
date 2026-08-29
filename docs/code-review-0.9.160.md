# Code review — 0.9.158–0.9.160 (bio render rework, Diag.pm, token-free)

**Reviewed 2026-08-12.** Nothing here is fixed yet — this is the finding list, with the
mechanism and a reproduction for each so none of it has to be re-derived.

**Scope:** `git diff @{upstream}...HEAD` on `dev` — the two commits carrying 0.9.158/0.9.159
(the connectivity diagnostic) and the bio-render rework — plus the **uncommitted 0.9.160
token-free changes** in the working tree.

**Deliberately out of scope:** the zip and the `repo.xml` `<sha>` are not rebuilt, and
`install.xml`/`repo.xml` still say 0.9.159 while the CHANGELOG and code comments say 0.9.160.
Known, excluded from this review by request.

**Method.** The bio findings were exercised by lifting the shipped subs the same way
`tools/t_bioreveal.pl` does and running real bio shapes through them; the Diag findings were
read against `Diag.pm`'s actual probe loop. Where a finding depends on something I could not
observe from here, it says so — see #7.

---

## Verified clean

- **The token-free change itself (0.9.160)** — `API.pm` / `Browse.pm` / `strings.txt`. Every
  `token` gate in the plugin was traced. The two changed gates are the right two, and **all four
  follow-feed gates are correctly left in place** (`getFollowFeed`, `_followTile`, `_warmFollow`,
  the unmatched-debug entry) — removing those is what would turn a missing tile into a runtime
  401, and they are pinned by test rather than by comment.
- `tools/t_tokenfree.pl` — 23/23.
- `tools/t_bioreveal.pl` — 106/106.

---

## Findings

Ranked most-severe first.

### 1. `pop @paras while` has no floor — a heading-only bio renders as nothing

**`ListenBrainzFreshReleases/Browse.pm:3650`**

```perl
pop @paras while @paras && $paras[-1]{heading};
```

The loop exists for a real case (MAI ends its HTML bio with a "More online sources" heading over
a link list that `_cleanBio` strips, leaving a bold title introducing nothing). But it has no
lower bound, so if **every** block is flagged a heading the entire biography is discarded.
`_proseBlock` then returns `()` from its `return () unless @paras` guard, and the expanded
branch at [Browse.pm:4306](../ListenBrainzFreshReleases/Browse.pm#L4306) emits **only the
"Show less" row** — the user taps Read more and gets an empty section.

**Confirmed.** Reproduces on:

```
Anna Meredith is a Scottish composer and producer.
Discography
Varmints (2016)
FIBS (2019)
Bumps Per Minute (2021)
```

Everything after the first sentence is lost. A bio that is a pure list renders zero prose rows.

The trigger is `_bioLooksLikeHeading` — one short source line not ending in `.!?;,` — which
describes every entry in a discography/roster list, so a bio that is mostly such a list ends up
heading-flagged all the way to the top. Note this is reachable *only* in the wrapped branch
(the test is gated on `$wrapped`), which is also finding #2's blast radius.

**Fix direction:** stop popping once nothing but headings would remain — keep the blocks and
render them, or require at least one non-heading block to survive.

---

### 2. A `_bioHardWrapped` false positive costs more than its comment claims

**`ListenBrainzFreshReleases/Browse.pm:3515`**

The comment at [Browse.pm:3511](../ListenBrainzFreshReleases/Browse.pm#L3511) says a false
positive "costs one joined paragraph — never a broken render", and the gates are tuned on that
basis. That understates it. `$wrapped` drives **two** things, as its own header states, and the
second is `_bioLooksLikeHeading` — a test the code itself documents as *unsound* off a wrapped
source ("this would promote prose to headings wholesale",
[Browse.pm:3541](../ListenBrainzFreshReleases/Browse.pm#L3541)).

So a Last.fm bio of short deliberate lines that clears both gates does not merely lose its
breaks: it also becomes eligible for bare-line heading promotion, and every short line in it can
come out bold — or, via #1, vanish entirely.

**Fix direction:** either re-state the risk honestly in the comment and tighten the gates, or
decouple the two effects so a wrap-detection miss can't switch on the unsound heading test.

---

### 3. The collapsed preview shows `_cleanBio`'s synthesised setext underline as literal dashes

**`ListenBrainzFreshReleases/Browse.pm:4311`** (and the short-bio inline row at
[4301](../ListenBrainzFreshReleases/Browse.pm#L4301))

Since 0.9.157, `_cleanBio` rewrites an HTML heading into a setext block:

```perl
$s =~ s{<h[1-6][^>]*>\s*(.*?)\s*</h[1-6]>}{"\n\n$1\n" . ('-' x 10) . "\n\n"}gise;   # API.pm:2163
```

That shape exists for `_bioBlocks` to consume — but the **collapsed** path never goes through
`_bioBlocks`. It collapses the raw cleaned text with `s/\s+/ /g` and truncates at
`BIO_PREVIEW`, so the underline survives as ten literal hyphens in the preview line. Same for a
short bio rendered inline at 4301.

**Confirmed** against the MAI HTML shape the 0.9.157 diff itself documents. A bio whose first
heading falls inside the first 150 characters reads:

```
Lambchop is an American band from Nashville. Description and history ---------- Initially…
```

**Fix direction:** build the preview from the first non-heading `_bioParagraphs` block rather
than from raw text.

---

### 4. `_bioBullet` treats a bare hyphen/en dash as a list marker

**`ListenBrainzFreshReleases/Browse.pm:3557`**

```perl
return undef unless $line =~ /^([*\x{2022}\x{00B7}\-\x{2013}])\s+(\S.*)$/;
```

The required trailing whitespace stops a hyphenated word opening a list, which is what the
comment addresses. It does not stop a **dashed parenthetical** that a hard wrap has pushed to the
start of a line — `… their second album\n– recorded in 1997 –\nwas released …`. That line is
taken as a bullet, which calls `$flush->(0)` and closes the preceding partial paragraph as its
own block; that block is one short line not ending in punctuation, so `_bioLooksLikeHeading`
promotes it and the sentence fragment before the dash renders **bold**.

**Confirmed** through the real subs. Narrow (needs the wrap to land just before the dash) but it
produces visibly wrong output, not just a lost break.

**Fix direction:** require the marker to be `*`/`•`/`·`, or require a dash-marked line to be part
of a run of similarly-marked lines before treating it as a list.

---

### 5. `<a>…</a>` deletes the link *text*, not just the tags

**`ListenBrainzFreshReleases/API.pm:2147`**

```perl
$s =~ s{<a\b[^>]*>.*?</a>}{}gis;   # drop the "Read more on Last.fm" link
```

Correct for the trailing Last.fm link it was written for. But 0.9.157 established that **MAI's
runtime input is Wikipedia-derived HTML**, which is full of inline links inside sentences — so
this now silently removes words mid-sentence. The `<(li|p)[^>]*>\s*</\1>` cleanup on the next
line exists precisely because this rule empties elements, which is the same effect showing up at
block level.

**Fix direction:** unwrap rather than delete (`s{<a\b[^>]*>(.*?)</a>}{$1}gis`), and drop the
Last.fm "Read more" link by matching its text specifically.

---

### 6. The two MusicBrainz probes fire concurrently against a 1 req/s API

**`ListenBrainzFreshReleases/Diag.pm:230`** (identity) and
[Diag.pm:250](../ListenBrainzFreshReleases/Diag.pm#L250) (search index)

`run` launches every non-skipped target in one unpaced loop
([Diag.pm:105-152](../ListenBrainzFreshReleases/Diag.pm#L105-L152)). Both MB rows are built from
the same `_mbBase`, so on a **default install with no mirror** they hit musicbrainz.org
simultaneously, against its ~1 req/s anonymous limit.

Consequences on a perfectly healthy install: the loser settles `warn / HTTP 503` (the error
callback treats any status as answered, so it reports the status back), or the search probe gets
a throttled/empty body and reports **"this mirror's Solr index is probably not built"** — the
one message in the report that has already cost real debugging time.

This matters more than an ordinary flake because a diagnostic that cries wolf is worse than no
diagnostic. Note it does **not** affect Simon's own box (mirror, unthrottled).

**Fix direction:** serialise the two MB probes, or stagger same-host targets, when
`API->mbIsPublic` is true.

---

### 7. `_httpCode`'s error-string fallback matches any 3-digit number

**`ListenBrainzFreshReleases/Diag.pm:385`**

```perl
my $err = eval { $resp->error };
return $1 if defined $err && $err =~ /\b([1-5]\d\d)\b/;
```

The CAA probe URL ends in `front-250`, and `-` gives `250` a word boundary — so **if** the error
string contains the URL, an unreachable CAA yields `$code = 250`, which is truthy, and because
that target sets `answered_ok => 1` it is reported **`ok / reachable`** for a host that never
answered.

**Plausible, not confirmed** — I verified the regex matches `front-250` and that the caller
treats any truthy code as "answered", but I could not confirm from here whether
`SimpleAsyncHTTP` puts the URL into `->error` on this LMS version. That is the one thing to check
before fixing; the fix is worth doing either way.

**Fix direction:** anchor the fallback to a status-like context (`/\b(?:HTTP\/\d\.\d\s+)?([1-5]\d\d)\b/`
against the start of the string, or require it not be preceded by `-`).

---

### 8. The MuSpy probe URL is not redacted

**`ListenBrainzFreshReleases/Diag.pm:318`**

```perl
url => API_PKG->muspyUrl . '/releases/' . $safe . '?limit=1',
```

The Last.fm row beside it carries a `display` key to keep its key out of the report; the MuSpy
row does not, so the user id goes into the copyable report that `README.md` invites users to
paste into a forum thread.

**Low severity** — a MuSpy user id is a public identifier with no password behind it, which is
why it is stored in the first place. Flagged for consistency with the section's own stated rule
("it must be safe to paste", [Diag.pm:342](../ListenBrainzFreshReleases/Diag.pm#L342)) rather
than as a credential leak.

**Fix direction:** add `display => API_PKG->muspyUrl . '/releases/***?limit=1'`.

---

### 9. `_cliDiag` can leave the CLI request hanging forever

**`ListenBrainzFreshReleases/Plugin.pm:218`**

```perl
$request->setStatusProcessing();

require Plugins::ListenBrainzFreshReleases::Diag;
Plugins::ListenBrainzFreshReleases::Diag->run(sub { … });
```

The request is marked processing, then an unguarded `require` and `run` follow. If `Diag.pm`
fails to load, or `run` dies before it schedules any HTTP, nothing ever calls
`setStatusDone` — the `["lbf","diag"]` request stays processing and the caller (the settings
page, or a remote user's `jsonrpc.js` call) hangs with no error.

`Diag::run` is itself well-guarded once it starts — the deadline timer and the pre-filled
`fail` rows mean a probe that never calls back still completes. This is only about the window
before that timer is set.

**Fix direction:** wrap in `eval` and `setStatusDone` (with an error result) on failure.

---

### 10. Documentation drift: the bio no longer costs a fixed number of rows

**`ListenBrainzFreshReleases/Browse.pm:4304`**

The call-site comment reads:

> ONE row holding every paragraph — see `_bioParagraphs` for why the split is what it is, and
> `_proseBlock` for why this must not be a row each.

`_proseBlock` does the opposite: it `push`es **one row per paragraph**
([Browse.pm:3465-3488](../ListenBrainzFreshReleases/Browse.pm#L3465-L3488)). That change was
deliberate in 0.9.155 (matching Discography, after correct parsing brought the count down from
92 rows to ~10) — so the code is right and the comment is stale from 0.9.152/0.9.154.

Worth more than a comment fix, because **CLAUDE.md's 0.9.152 entry still claims the property
that comment is protecting**: *"expanding the bio now costs the SAME two rows as collapsing it
… so the bio can no longer push a page into the scroller at all."* That has not been true since
0.9.155. Expanding adds N rows again, so the bio contributes to the
`LMS_MAX_NON_SCROLLER_ITEMS` (100) threshold alongside the tracklist — which is the open
deferred item recorded under 0.9.152, now reachable with fewer tracks than that entry implies.

**Fix direction:** correct the comment and the CLAUDE.md claim, and re-state the residual row
budget for the deferred tracklist-paging item.

---

## Suggested order

**1** and **6** before anything ships — one can blank a biography entirely, the other reports a
false fault on a healthy default install. **3** and **5** are the next most visible to users.
**7** needs the `->error` question answered first. **2**, **4**, **8**, **9**, **10** are
lower-cost cleanups.
