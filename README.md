# ListenBrainz Fresh Releases — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** that browses [ListenBrainz](https://listenbrainz.org) *Fresh Releases* — newly released albums from MusicBrainz, including a personalised feed based on your own listening history.

Tested on LMS 9.x with the **Material Skin**.

---

## What it does

The plugin's menu is grouped under three headings — **Created for You** (New Releases for You + Playlists), **All Releases**, and **Settings**.

- **New Releases for You** — a personalised feed of fresh releases from artists you listen to (requires a ListenBrainz account + token).
- **Created-for-You Playlists** — your ListenBrainz algorithmic playlists (Weekly Jams, Weekly Exploration, Daily Jams, …), turned into fully-streaming, **Play-all** playlists. Every track is matched to a playable version — from your own library first, then your streaming services — so you can play them straight from LMS (see [Playlists](#created-for-you-playlists) below).
- **All Releases** — the global ListenBrainz fresh-releases feed (no account needed). Tapping it opens a **by-week landing page**: an "All releases" entry plus one entry per week, so you can jump to a single week without scrolling the whole list.
- **Weekly view** — when sorted by release date, releases are grouped under a divider per week (`Week of 9 Jun 2026`), newest first. In Material these render as proper section headers (tap a week to focus just that week), and the list supports Material's grid/list view toggle.
- **Genre tags in the list** — where ListenBrainz supplies tags, up to three are shown next to each title (coverage is partial, so many rows won't have any).
- **Rich detail pages** — tap a release to see its tracklist (with durations), genres, folksonomy tags, and a clickable **View on MusicBrainz** link. Genres come from MusicBrainz, with an optional **Last.fm** fallback (see below) that fills the gap for brand-new releases MusicBrainz hasn't tagged yet.
- **One-tap streaming playback** — if you have the **Qobuz**, **Bandcamp**, and/or **Tidal** plugins installed, each release detail page shows the matching album on those services (with their logos), playable directly. Matching is by artist + title, and you choose the order services are searched (see [Streaming Services](#streaming-services)).
- **Material home shelves** — adds optional **New Releases for You**, **Playlists**, and **All Releases** scrollable rows to the Material Skin home screen (see below).
- **Refresh on demand** — the feeds refresh automatically once a day; a **Refresh** row at the top of each feed forces an immediate update when you don't want to wait.
- **Fast & cached** — streaming matches, resolved playlists, and MusicBrainz lookups are cached, and playlists are pre-resolved in the background shortly after startup, so opening anything is instant.

---

## Requirements

| Feature | Requirement |
|---|---|
| **All Releases** feed | None — works out of the box |
| **New Releases for You** feed | An **active ListenBrainz account** with listening history, plus your **ListenBrainz API token** |
| **Created-for-You Playlists** | Your **ListenBrainz username** set; a streaming plugin (below) and/or tracks in your own LMS library for tracks to resolve against |
| **Streaming playback** | The **Qobuz**, **Bandcamp**, and/or **Tidal** LMS plugins installed and signed in |
| **Last.fm genre fallback** | A free **Last.fm API key** (optional — see Setup) |
| **Home shelf rows** | **Material Skin** |
| Server | LMS / Lyrion Music Server **9.0.0+** |

Your ListenBrainz API token is on your [ListenBrainz settings page](https://listenbrainz.org/settings/). The "For You" feed only reflects artists you've actually submitted listens for.

---

## Installation

### Via repository (recommended)

In LMS: **Settings → Plugins → Additional Repositories**, add:

```
https://simonarnold002.github.io/LMS-ListenBrainz-New-Releases/repo.xml
```

Then install **ListenBrainz Fresh Releases** from the plugin list and restart.

### Manual

Download `ListenBrainzFreshReleases.zip` from the [latest release](https://github.com/SimonArnold002/LMS-ListenBrainz-New-Releases), unzip into your LMS `Plugins/` directory so it sits as `Plugins/ListenBrainzFreshReleases/`, and restart the server.

---

## Setup

1. Open **Settings → Advanced → ListenBrainz Fresh Releases** (also linked from the plugin's own menu as **Plugin Settings**).
2. Enter your **ListenBrainz username** and **API token** (needed for *New Releases for You* and *Playlists*). Use **Check token** to validate it on the spot — green means it's accepted (and shows your username), red means it was rejected.
3. *(Optional)* Paste a free **Last.fm API key** to enable the detail-page genre fallback. Create one at [last.fm/api/account/create](https://www.last.fm/api/account/create); **Check key** validates it. Leave blank to disable.
4. *(Optional)* Under **Streaming Services**, set the search order for Qobuz / Bandcamp / Tidal (lower number = searched first; **0 = never use that service**). Only installed services are offered.
5. Adjust the filters to taste and save.

---

## Settings & defaults

### General

| Setting | Default | Notes |
|---|---|---|
| ListenBrainz Username | *(empty)* | Needed for *New Releases for You* |
| User Token | *(empty)* | From listenbrainz.org/settings/ |
| Last.fm API Key | *(empty)* | Optional — enables the detail-page genre fallback. From last.fm/api/account/create |
| Days window | **14** | 1–90 days of releases to show |
| Default sort | **Release Date** | Date (newest first), Artist, Album, or Confidence |
| Group by Artist | **On** | Collapse artists with several new releases into one entry |
| Weekly Dividers | **On** | Date-sorted view gets a divider per week (takes precedence over Group by Artist for the date sort) |
| Find on Streaming Services | **On** | Show playable Qobuz / Bandcamp / Tidal matches on detail pages |
| Prefer Tracks from My Library | **On** | When building a playlist, use a track from your own LMS library (matched by MusicBrainz ID, then artist + title) before searching streaming services |

### Streaming Services

| Setting | Default | Notes |
|---|---|---|
| Search Priority (per service) | Qobuz / Bandcamp / Tidal enabled | Services are searched in order of priority (**lower number = first**); the search stops at the first service that has a match. Set a service to **0** to never search it. Drives both album playback and playlist track matching. Only installed services are listed. |

The release-filter sections below (*New Releases for You* and *All Releases*) share the same set of filters and the same defaults; you can tune each independently.

### New Releases for You

| Setting | Default |
|---|---|
| Include Past Releases | **On** |
| Include Upcoming Releases | **Off** |
| Only Releases with Artwork | **On** |
| Include Various Artists | **On** |
| Release types | **Album, Compilation** on; Single, EP, Broadcast, Other, Soundtrack, Live, Remix, Demo off |

### All Releases

| Setting | Default |
|---|---|
| Include Past Releases | **On** |
| Include Upcoming Releases | **Off** |
| Only Releases with Artwork | **On** |
| Include Various Artists | **On** |
| Release types | **Album, Compilation** on; Single, EP, Broadcast, Other, Soundtrack, Live, Remix, Demo off |

---

## Created-for-You Playlists

ListenBrainz builds algorithmic playlists for you each week — **Weekly Jams**, **Weekly Exploration**, **Daily Jams**, and so on. This plugin turns each one into a playlist you can actually play in LMS.

**How to use it:**

1. Make sure your **ListenBrainz username** is set in Settings (a token isn't strictly required to read these, but set it anyway for *New Releases for You*).
2. Open **Created for You → Playlists**. You'll see one tile per playlist, labelled with the week/day it covers and how many of its tracks were matched (e.g. `W/C 9 June 2026 · 47 of 50 tracks matched`).
3. Tap a playlist to open the resolved track list, or use **Play / Add** straight from the tile to queue the whole thing.

**How tracks are resolved:** for each track, the plugin looks in **your own LMS library first** (by MusicBrainz ID, then artist + title) when *Prefer Tracks from My Library* is on, then searches your streaming services in the priority order you set. Tracks it can't match anywhere are dropped, so what you get is a clean, playable list. Because these playlists only change weekly, a resolved playlist is cached and re-used (including last week's), and the whole set is pre-resolved in the background shortly after the server starts — so opening Playlists and each playlist is instant.

> **Note:** track matching is most complete on **Qobuz** today; Tidal/Bandcamp track support depends on what those plugins expose on your server. A track that isn't available on any of your services (or in your library) simply won't appear in the playlist.

---

## Material home shelves

The plugin registers three scrollable rows for the Material Skin home screen: **New Releases for You**, **Playlists**, and **All Releases**.

To enable them: in Material, edit the home screen / **Customize home menu** and turn on the rows you want.

> **Tip:** Material caches the list of available home rows in your browser. If a newly added row doesn't appear, do a hard refresh (**Ctrl/Cmd-Shift-R**) and look again.

Each row shows cards you can tap to open (a release detail page, or a playlist); the **New Releases for You** and **Playlists** rows are playable directly, and **All Releases** jumps into its by-week list. (The weekly dividers live in the main menus — the home shelves are kept as flat lists so streaming playback works from them.)

---

## Notes & limitations

- **Genre coverage** on brand-new releases is sparse — MusicBrainz often hasn't tagged them yet, and only a minority of releases carry ListenBrainz tags. Genres are therefore shown *when available* rather than used as a browse filter. Adding a **Last.fm API key** improves this a lot: the detail page falls back to Last.fm's album tags, then the artist's tags (which are usually populated even when a new album isn't).
- **Streaming matches** are found by searching each service for the artist + album, so an album not yet on a service won't appear, and very occasionally a close title may mismatch.
- **Playlist track matching** is partial by nature — a track is included only if it's in your library or on one of your enabled services. Matches are cached for the week, so a track that *later* appears on a service won't be picked up until the playlist regenerates the following week.
- Streaming playback requires the respective service plugin to be installed and signed in; the feature simply hides itself if no supported service is present.

---

## Credits

- Release data from [ListenBrainz](https://listenbrainz.org) / [MusicBrainz](https://musicbrainz.org), cover art from the [Cover Art Archive](https://coverartarchive.org). All part of the [MetaBrainz](https://metabrainz.org) project.
- Streaming playback via the community **Qobuz** and **Bandcamp** LMS plugins.

See [LICENSE](LICENSE) for licensing.
