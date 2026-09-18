# ListenBrainz Fresh Releases — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** built around [ListenBrainz](https://listenbrainz.org). It browses newly released albums (a personalised feed plus the global feed), turns your ListenBrainz playlists and recommendations into playable music, and adds rich release detail pages with artist bios and one-tap streaming. **No ListenBrainz API token needed** — your username unlocks every personalised feature; a token only adds the **Recommended** list under People You Follow.

Tested on LMS 9.x with the **Material Skin**; also works in the **Default** and **Classic** web skins.

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **New Releases for You** | Fresh releases from artists you listen to | ListenBrainz username |
| **MuSpy artists** *(optional)* | Fold releases — especially **upcoming** ones — from the artists you follow on MuSpy into New Releases for You | MuSpy user ID (public) |
| **All Releases** | The global ListenBrainz fresh-releases feed | Nothing |
| **Release detail pages** | Streaming matches, artist photo + biography, tracklist, genres, MusicBrainz link | — |
| **Created-for-You Playlists** | Your Weekly Jams / Exploration / Daily Jams as Play-all lists | ListenBrainz username |
| **People You Follow** *(optional)* | What the people you follow are playing — trending tracks & albums — plus their recommendations | ListenBrainz username (token only for the Recommended list) |
| **Don't Stop The Music** | Two auto-DJ mixers (Radio + Recommended) | ListenBrainz username |
| **Streaming playback** | Play matched albums/tracks on your services | Qobuz / Tidal / Bandcamp / Deezer / Spotify (Spotty) plugin |
| **Artist bios + photos** | On the detail page and behind "Read more" | MAI plugin |
| **Albums / Singles & EPs** | Flip either feed between full releases and singles/EPs, from the list itself | — |
| **Block artists** | Hide an artist from every feed | — |
| **Material home shelves** | Three home-screen rows | Material Skin |
| **Connection check** | Tests every service the plugin uses, from the server, and gives you a report you can copy | — |

---

## Requirements

- **LMS / Lyrion Music Server 9.0.0+** (tested with Material Skin).
- A **ListenBrainz account** for anything personalised (For You, Playlists, People You Follow, Don't Stop The Music) — just the **username**, no API token. The global *All Releases* feed needs nothing at all. The For You feed only reflects artists you've actually submitted listens for.
- An **API token is optional** and adds exactly one thing: the **Recommended** list under People You Follow, which reads your private ListenBrainz feed. Everything else uses public endpoints. Your token is on your [ListenBrainz settings page](https://listenbrainz.org/settings/).
- **Optional add-ons** the plugin uses when present:
  - **Qobuz**, **Tidal**, **Bandcamp**, **Deezer** and/or **Spotty** (Spotify) LMS plugins (installed + signed in) → streaming playback.
  - **Music & Artist Information (MAI)** plugin → artist biographies *and* photos.
  - A **local MusicBrainz mirror** → faster, un-throttled lookups (auto-detected on the same machine, or set in Settings).
- **Last.fm is built in** — there's no key to get or enter. It fills in genre labels that MusicBrainz doesn't have yet (common for brand-new releases) and gives the ListenBrainz Radio a second source of similar artists.

Every optional integration degrades gracefully — if it isn't there, that part of the UI simply hides itself.

---

## Installation

**Via repository (recommended).** In LMS go to **Settings → Plugins → Additional Repositories** and add:

```
https://simonarnold002.github.io/LMS-ListenBrainz-New-Releases/repo.xml
```

Then install **ListenBrainz Fresh Releases** from the plugin list and restart.

**Manual.** Download `ListenBrainzFreshReleases.zip` from the [repository](https://github.com/SimonArnold002/LMS-ListenBrainz-New-Releases), unzip into your LMS `Plugins/` directory so it sits as `Plugins/ListenBrainzFreshReleases/`, and restart.

---

## Quick start

1. Open **Settings → Advanced → ListenBrainz Fresh Releases** (also linked from the plugin menu as **Plugin Settings**).
2. Enter your **ListenBrainz username** — that alone enables every personalised feature. No token needed — add your **API token** *(optional)* only if you also want the **Recommended** list under People You Follow; it adds nothing else.
3. *(Optional)* Set **Streaming Services** priorities if you have Qobuz/Tidal/Bandcamp/Deezer/Spotify.
4. *(Optional)* Choose how many **weeks** each feed shows, and how many of them are upcoming, in the **New Releases for You** and **All Releases** sections.
5. *(Optional)* Add your **MuSpy user ID** (in the **MuSpy** section, below the feed settings) to fold your followed artists' releases into New Releases for You.
6. Save. The plugin appears in **Apps → ListenBrainz Fresh Releases**.

---

## Using each feature

### Browsing releases
Open the plugin and you'll see **New Releases for You** and **All Releases** tiles (each tile's subtitle shows the date span and release count).

- **New Releases for You** drops straight into your personalised list.
- **All Releases** opens a by-week landing: one entry per week (badged *This Week / Last Week / Earlier*, and *Next Week / Next Fortnight / Further* for upcoming weeks when that section's **Upcoming weeks** is above 0). A busy week shows 30 releases at a time with **Show more** / **Show all** rows (and **Show less** to collapse).
- **New Releases for You** is grouped under **weekly dividers** (W/C week headers). Each list has a **Sorted by…** row in its Options section that cycles **Release Date / Artist / Album Title** — For You sorts within each week (keeping the headers); All Releases uses one sort shared across every week, set once and remembered (including across restarts). The **Artist** sort is A–Z on the artist name as shown, skipping a leading article from LMS's own ignored-articles list — so "The National" files under **N**.
- Each list also has a **Showing Albums (tap for Singles & EPs)** row that flips the whole feed between the two, and back again — so singles and EPs can stay ticked in Settings without burying the albums. The row's icon changes with the view (a record sleeve for albums, a music note for singles/EPs) so you can see at a glance which you're in, and the choice sticks across visits and restarts. It appears only when that section has **both** kinds ticked in its Release types setting — with just one there's nothing to switch to.
- What appears in each feed (weeks shown, upcoming weeks, release types, artwork-only, Various Artists) is set separately in the **New Releases for You** and **All Releases** settings sections — see **New Releases for You / All Releases** under Settings reference below.
- Use **Refresh (force update now)** at the top of a feed to bypass the cache and reload — it's in the Options section of each All Releases week as well as New Releases for You.

### Following artists on MuSpy (optional)
[MuSpy](https://muspy.com) tracks new releases from artists **you** pick — so it's more tailored than your listening history, and it's mostly about **upcoming** releases. Add your **MuSpy user ID** in the **MuSpy** settings section (public ID only — no password; find it in your MuSpy Settings or your RSS/notification URL as `id=…`) and those releases fold into **New Releases for You**. Duplicates that also come from ListenBrainz are shown once.

MuSpy has **no date settings of its own**: its releases use New Releases for You's **Weeks to show** and **Upcoming weeks**, so they never reach further than that feed does. A release announced further ahead isn't lost — it appears as the weeks roll forward each Monday.

### Release detail pages
Tap any release for a page in three sections:

- **Streaming** — playable matches on your services. Qobuz/Tidal/Deezer/Spotify are matched automatically; **Bandcamp** is a one-tap **Search Bandcamp** button (it's slower/heavier, so it runs only when you ask, and a found match is remembered). A **Refresh** re-searches.
- **Artist Details** — artist photo + a short biography preview with **Read more** for the full text, and **Block this artist**.
- **Album Details** — tracklist (with durations), genres, tags, and **View on MusicBrainz**.

### Works with Listen Later
If you also run the **Listen Later** plugin, adding a release from a detail page passes across what the release actually **is** — album, EP or single — straight from MusicBrainz. Streaming services mostly don't say, so Listen Later would otherwise have to guess from how many tracks it could resolve, which mislabels a short album or a long EP. That label drives the row's icon there and how many plays it takes to count as played. The album is also saved under the name the streaming service itself uses for it, which is the name it reports while playing — so it's recognised when you play it and moves to *Played* on its own.

### Streaming playback
With **Qobuz**, **Tidal**, **Bandcamp**, **Deezer** and/or **Spotty** (Spotify) installed, releases and playlist tracks are matched and made playable. In **Streaming Services** settings, give each service a **search priority** (lower = tried first, **0 = never use it**); matching stops at the first service that has it. Qobuz/Tidal/Deezer/Spotify are searched automatically; **Bandcamp** is searched on demand from the detail page (a found Bandcamp match is remembered, so a Bandcamp-only release stays playable). Change a service's priority — or remove its plugin — and affected tracks **re-match** to your remaining services automatically.

### Created-for-You Playlists
With a username set, the **Playlists** section turns your ListenBrainz **Weekly Jams**, **Weekly Exploration** and **Daily Jams** into Play-all lists. Each track is matched to your **own library first** (then streaming); unmatched tracks are dropped and the page title shows how many matched. A **Refresh playlist matches** row at the top of the Playlists view forces a fresh, library-first re-match of every playlist (handy if the matches were built before your library finished scanning). A **Settings → Unmatched tracks (debug)** view lists, per playlist, any tracks that couldn't be matched — handy for spotting a gap.

### People You Follow
Built from what the people you follow on ListenBrainz **actually play** (public listening stats — a **username** is enough; only the Recommended list needs your token). Ranking is **one vote per follower**, so it reflects what they're *all* into rather than whatever one heavy listener is hammering.

- **Trending Tracks** — the tracks the people you follow are playing **this week**, as a Play-all list. It trends at the album level (a full-album play doesn't flood the list with its tracks) and **hides anything already in your library**, so it's pure discovery.
- **Trending Albums · This Month** and **· This Year** — the albums the most of your followers are playing over each window, as tap-through album pages with cover art, year and type (just like New Releases). Shown as-is — owned albums included, since it's about popularity.
- **Recommended** — the tracks the people you follow **recommend or pin** on ListenBrainz, gathered into one newest-first list with **day dividers**, and **new-music-only** (anything you already own is filtered out). It accumulates, so a rec isn't lost as the feed rolls. *(Needs your token — this feed is private.)*

Not interested? Turn the whole section off with **Show "People You Follow" section** in Settings → General — when it's off, none of it is fetched, cached or pre-warmed, so it costs you nothing.

### Don't Stop The Music
Two auto-DJ mixers keep the queue going when it runs low. Pick one as your player's **Don't Stop The Music** source (LMS/Material player settings):

- **ListenBrainz Radio** — seeds from the track you're playing and evolves outward through similar artists, so the music flows rather than loops. A new album by a different artist reseeds it. (If ListenBrainz has no similar artists for the seed, it falls back to Last.fm's similar artists before anything else.)
- **ListenBrainz Recommended for You** — plays from your personalised recommendations.

Both prefer a copy from **your own library** when you have it (otherwise stream), spread the selection across many artists, and **never repeat a track within a session**.

### Block artists
**Block this artist** on any detail page hides every release by that artist from all feeds. Manage and **Unblock** them in the **Blocked Artists** settings section. (It's a local filter — no ListenBrainz account needed, and it takes effect on the next browse.)

### Material home shelves
The plugin adds **New Releases for You**, **Playlists** and **All Releases** rows to the Material home screen. Enable them via Material's **Customize home menu**. *(Material caches the available rows in your browser — if a new one doesn't show, hard-refresh with Ctrl/Cmd-Shift-R.)*

### Connection check
If a feed is empty or your token doesn't seem to work, open **Settings → Connection Check** and press **Run connection check**. It tries every service the plugin depends on — ListenBrainz and ListenBrainz Labs, MusicBrainz (or your own mirror) and its search index, the LMS-community API, the Cover Art Archive, Last.fm, and MuSpy if you use it — **from the machine running Lyrion**, and reports each one with how long it took and what came back. The **Check token** button next to the token field runs the same check and shows the answer beside the field.

That matters because it tests the connection the plugin actually uses. A check running in your web browser can fail for reasons that have nothing to do with the server — an ad-blocker, a Pi-hole, a proxy, a guest-network sign-in page — and tell you nothing useful.

If MusicBrainz is refusing the server for making too many requests, its rows say so and show how long the plugin is backing off, rather than timing out. Right after a restart the server is busy with its own start-up work for a few minutes, so a check run then can be slow or time out — run it again once things settle.

Use **Copy report** if you're asking for help; it never contains your token. The check reads your **saved** settings, so save the page first if you've just edited one.

---

## Settings reference

The sections below are in the order they appear on the settings page.

### General
| Setting | Default | Notes |
|---|---|---|
| ListenBrainz Username | *(empty)* | Needed for For You, Playlists, People You Follow, Don't Stop The Music |
| User Token *(optional)* | *(empty)* | Only adds the **Recommended** list under People You Follow (private feed). From listenbrainz.org/settings/. **Check token** tests it |
| Find on Streaming Services | **On** | Show playable Qobuz/Tidal/Bandcamp/Deezer/Spotify matches on detail pages |
| Show "People You Follow" section | **On** | Turn the whole People You Follow section (trending tracks & albums, recommendations) off to skip all its calls, caching and warming |
| Prefer Tracks from My Library | **On** | Use your own copy (by MusicBrainz ID, then artist + title) before streaming — for Playlists and Don't Stop The Music |
| MusicBrainz server | *(empty)* | Blank = auto-detect a musicbrainz-docker mirror on the same machine (port 5000), otherwise the public API. Or enter your mirror, e.g. `http://your-server:5000/ws/2/` (a bare host is assumed to be `http://`). Cover art still comes from the public Cover Art Archive |
| Genre labels | **Automatic** | Where the genre shown next to each release (and used by the Genres filter row) comes from. **Automatic** = a local mirror if there is one, otherwise ListenBrainz; **Always use ListenBrainz**; or **Never look genres up**. Genres the feed itself carries are always shown |
| Pre-load cover art | **On** | During the daily background warm, fetch each feed's cover art at the sizes the skin will ask for, so views open with artwork already cached. Off = no background artwork traffic |
| Write a debug log | **Off** | Records the playlist warm/match activity to `lbf-debug.log` (next to the server log) — turn on only to troubleshoot a matching/caching issue |

### Blocked Artists
Lists the artists you've blocked; tick **Unblock** and save to restore them. Various Artists can't be blocked (it would hide unrelated compilations).

### Streaming Services
A **search priority** (0–9) per detected service: lower number = searched first, **0 = never use it**. Drives detail-page matches, Playlists and Don't Stop The Music. Defaults: Qobuz **1**, Bandcamp **2**, Tidal **3**, Deezer **4**, Spotify **5**. Each service shows whether its plugin is detected.

### New Releases for You / All Releases
Each section has its own copy of these settings, so the two feeds can show different spans:

| Setting | New Releases for You | All Releases |
|---|---|---|
| Weeks to show | **2** | **2** |
| Upcoming weeks | **1** | **1** |
| Release Types | **Album** + **Compilation** on; Single, EP, Broadcast, Other, Soundtrack, Live, Remix, Demo off | same |
| Only Releases with Artwork | **On** | **On** |
| Include Various Artists Releases | **On** | **On** |

**How the weeks work.** **Weeks to show** is the total number of weeks (1–4), and the **current week counts as week 1**. **Upcoming weeks** is how many of those come after the current week (0 up to one less than Weeks to show); the rest are earlier weeks. Weeks run Monday to Sunday and the current week is always shown in full, so Friday's releases stay visible all weekend and releases due later this week always appear.

- The defaults: both sections show **this week and next week**. To keep last week's releases in view as well, raise **Weeks to show** to 3.
- A combination that doesn't fit is corrected when you save — for example 2 weeks with 3 upcoming is saved as 2 weeks with 1 upcoming — and the page shows what was actually stored.
- MuSpy releases use the New Releases for You numbers.

> **Upgrading from an earlier version?** The old **Days window**, **Include Past Releases** and **Include Upcoming Releases** settings, and MuSpy's own **upcoming releases** / **how far ahead** settings, have been replaced by the two week boxes above. They aren't carried over, so each section starts at the defaults shown — check them after updating.

Tick **Single** and/or **EP** as well as an album type and the feed gains the **Showing Albums (tap for Singles & EPs)** row described above, so the two don't have to compete for the same list.

### MuSpy
Kept separate from the ListenBrainz options so the two aren't confused.

| Setting | Default | Notes |
|---|---|---|
| MuSpy user ID *(optional)* | *(empty)* | Public ID from muspy.com — folds your followed artists' releases into New Releases for You, within that section's weeks. Empty = off |

### Connection Check
The last section on the page. It holds no settings — just the **Run connection check** and **Copy report** buttons described under **Connection check** in Using each feature above.

> Don't Stop The Music uses sensible built-in defaults (no settings page of its own).

---

## Notes & limitations

- **Genre coverage** on brand-new releases is sparse (MusicBrainz often hasn't tagged them yet). Genres show *when available*; the built-in **Last.fm** lookup fills much of the gap using Last.fm's album/artist tags.
- **Streaming matches** search each service by artist and confirm the album/track title locally, so something not on a service won't appear, and occasionally a close title may mismatch. When an album isn't found under the credited name, the plugin tries once more with the artist's other names — each member of a joint credit, and the artist's known aliases.
- **MuSpy artwork:** MuSpy only tells us a release *group*, not a specific cover, so the **Only Releases with Artwork** filter can't screen its entries — and *upcoming* releases usually have no cover art yet, so some MuSpy rows may show a placeholder until artwork lands. This is expected.
- **Tracklists** come from ListenBrainz for the release group, so occasionally a detail page shows the track list of another edition of the same album (a deluxe or regional version, say).
- Optional integrations (streaming services, MAI) are auto-detected; missing ones just hide their UI.

---

## Credits

- Release data from [ListenBrainz](https://listenbrainz.org) / [MusicBrainz](https://musicbrainz.org); cover art from the [Cover Art Archive](https://coverartarchive.org). All part of the [MetaBrainz](https://metabrainz.org) project.
- Artist name lookups and aliases via the [LMS-community API](https://api.lms-community.org).
- Streaming via the community **Qobuz**, **Tidal**, **Bandcamp**, **Deezer** and **Spotty** LMS plugins.
- Spotify support contributed by [honzup](https://github.com/honzup) ([PR #17](https://github.com/SimonArnold002/LMS-ListenBrainz-New-Releases/pull/17)).
- Artist biographies and photos via the **Music & Artist Information (MAI)** plugin; genre tags and similar artists from **Last.fm**.

See [LICENSE](LICENSE) for licensing.
