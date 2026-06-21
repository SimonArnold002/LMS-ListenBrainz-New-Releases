# ListenBrainz Fresh Releases — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** built around [ListenBrainz](https://listenbrainz.org). It browses newly released albums (a personalised feed plus the global feed), turns your ListenBrainz playlists and recommendations into playable music, and adds rich release detail pages with artist bios and one-tap streaming.

Tested on LMS 9.x with the **Material Skin**.

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **New Releases for You** | Fresh releases from artists you listen to | ListenBrainz username + token |
| **All Releases** | The global ListenBrainz fresh-releases feed | Nothing |
| **Release detail pages** | Streaming matches, artist photo + biography, tracklist, genres, MusicBrainz link | — |
| **Created-for-You Playlists** | Your Weekly Jams / Exploration / Daily Jams as Play-all lists | ListenBrainz username |
| **Don't Stop The Music** | Two auto-DJ mixers (Radio + Recommended) | ListenBrainz username |
| **Streaming playback** | Play matched albums/tracks on your services | Qobuz / Tidal / Bandcamp plugin |
| **Artist bios + photos** | On the detail page and behind "Read more" | MAI plugin, or a Last.fm key (bio only) |
| **Block artists** | Hide an artist from every feed | — |
| **Material home shelves** | Three home-screen rows | Material Skin |

---

## Requirements

- **LMS / Lyrion Music Server 9.0.0+** (tested with Material Skin).
- A **ListenBrainz account + API token** for anything personalised (For You, Playlists, Don't Stop The Music). The global *All Releases* feed needs nothing. Your token is on your [ListenBrainz settings page](https://listenbrainz.org/settings/); the For You feed only reflects artists you've actually submitted listens for.
- **Optional add-ons** the plugin uses when present:
  - **Qobuz**, **Tidal** and/or **Bandcamp** LMS plugins (installed + signed in) → streaming playback.
  - **Music & Artist Information (MAI)** plugin → artist biographies *and* photos.
  - A free **Last.fm API key** → genre fallback, artist-bio fallback (no photo), and a similar-artist fallback for the radio. Get one at [last.fm/api/account/create](https://www.last.fm/api/account/create).

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
2. Enter your **ListenBrainz username** and **API token** (needed for the personalised features).
3. *(Optional)* Paste a **Last.fm API key** and set **Streaming Services** priorities if you have Qobuz/Tidal/Bandcamp.
4. Save. The plugin appears in **Apps → ListenBrainz Fresh Releases**.

---

## Using each feature

### Browsing releases
Open the plugin and you'll see **New Releases for You** and **All Releases** tiles (each tile's subtitle shows the date span and release count).

- **New Releases for You** drops straight into your personalised list.
- **All Releases** opens a by-week landing: **Show all**, plus one entry per week (badged *This Week / Last Week / Earlier*, and *Next Week / Next Fortnight / Further* for upcoming weeks when you've enabled future releases).
- When sorted by date, releases are grouped under a **weekly divider** (tap a week header to focus just that week). **Group by Artist** collapses an artist's multiple new releases into one expandable entry. Both are toggles in settings.
- What appears in each feed (date window, past/future, artwork-only, Various Artists, release types) is controlled in the **New Releases for You** and **All Releases** settings sections.
- Use **Refresh (force update now)** at the top of a feed to bypass the cache and reload.

### Release detail pages
Tap any release for a page in three sections:

- **Streaming** — playable matches on your services (and a Refresh to re-search).
- **Artist Details** — artist photo + a short biography preview with **Read more** for the full text, and **Block this artist**.
- **Album Details** — tracklist (with durations), genres, tags, and **View on MusicBrainz**.

### Streaming playback
With **Qobuz**, **Tidal** and/or **Bandcamp** installed, releases and playlist tracks are matched (by artist + title) and made playable. In **Streaming Services** settings, give each service a **search priority** (lower = tried first, **0 = never use it**); matching stops at the first service that has it.

### Created-for-You Playlists
With a username set, the **Playlists** section turns your ListenBrainz **Weekly Jams**, **Weekly Exploration** and **Daily Jams** into Play-all lists. Each track is matched to your **own library first** (then streaming); unmatched tracks are dropped and the page title shows how many matched.

### Don't Stop The Music
Two auto-DJ mixers keep the queue going when it runs low. Pick one as your player's **Don't Stop The Music** source (LMS/Material player settings):

- **ListenBrainz Radio** — seeds from the track you're playing and evolves outward through similar artists, so the music flows rather than loops. A new album by a different artist reseeds it. (If ListenBrainz has no similar artists for the seed and you have a Last.fm key, it falls back to Last.fm's similar artists before anything else.)
- **ListenBrainz Recommended for You** — plays from your personalised recommendations.

Both prefer a copy from **your own library** when you have it (otherwise stream), spread the selection across many artists, and **never repeat a track within a session**.

### Block artists
**Block this artist** on any detail page hides every release by that artist from all feeds. Manage and **Unblock** them in the **Blocked Artists** settings section. (It's a local filter — no ListenBrainz account needed, and it takes effect on the next browse.)

### Material home shelves
The plugin adds **New Releases for You**, **Playlists** and **All Releases** rows to the Material home screen. Enable them via Material's **Customize home menu**. *(Material caches the available rows in your browser — if a new one doesn't show, hard-refresh with Ctrl/Cmd-Shift-R.)*

---

## Settings reference

### General
| Setting | Default | Notes |
|---|---|---|
| ListenBrainz Username | *(empty)* | Needed for For You, Playlists, Don't Stop The Music |
| User Token | *(empty)* | From listenbrainz.org/settings/ |
| Last.fm API Key | *(empty)* | Optional — enables genre + artist-bio + radio similar-artist fallbacks |
| Days window | **14** | 1–90 days of releases to show |
| Default sort | **Release Date** | Date (newest first), Artist, Album, or Confidence |
| Group by Artist | **On** | Collapse an artist's multiple new releases into one entry |
| Weekly Dividers | **On** | Per-week divider in the date-sorted view (wins over Group by Artist for that sort) |
| Find on Streaming Services | **On** | Show playable Qobuz/Tidal/Bandcamp matches on detail pages |
| Prefer Tracks from My Library | **On** | Use your own copy (by MusicBrainz ID, then artist + title) before streaming — for Playlists and Don't Stop The Music |

### Streaming Services
A **search priority** per detected service (Qobuz / Tidal / Bandcamp): lower number = searched first, **0 = never use it**. Drives detail-page matches, Playlists and Don't Stop The Music.

### Blocked Artists
Lists the artists you've blocked; tick **Unblock** and save to restore them. Various Artists can't be blocked (it would hide unrelated compilations).

### New Releases for You / All Releases
Each section has its own copy of these filters:

| Setting | Default |
|---|---|
| Include Past Releases | **On** |
| Include Upcoming Releases | **Off** |
| Only Releases with Artwork | **On** |
| Include Various Artists | **On** |
| Release types | **Album** + **Compilation** on; Single, EP, Broadcast, Other, Soundtrack, Live, Remix, Demo off |

> Don't Stop The Music uses sensible built-in defaults (no settings page of its own).

---

## Notes & limitations

- **Genre coverage** on brand-new releases is sparse (MusicBrainz often hasn't tagged them yet). Genres show *when available*. A **Last.fm API key** fills the gap using Last.fm's album/artist tags.
- **Streaming matches** are by artist + album search, so an album not yet on a service won't appear, and occasionally a close title may mismatch.
- Optional integrations (streaming services, MAI, Last.fm) are auto-detected; missing ones just hide their UI.

---

## Credits

- Release data from [ListenBrainz](https://listenbrainz.org) / [MusicBrainz](https://musicbrainz.org); cover art from the [Cover Art Archive](https://coverartarchive.org). All part of the [MetaBrainz](https://metabrainz.org) project.
- Streaming via the community **Qobuz**, **Tidal** and **Bandcamp** LMS plugins.
- Artist biographies and photos via the **Music & Artist Information (MAI)** plugin, with **Last.fm** fallbacks.

See [LICENSE](LICENSE) for licensing.
