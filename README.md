# ListenBrainz Fresh Releases — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** that browses [ListenBrainz](https://listenbrainz.org) *Fresh Releases* — newly released albums from MusicBrainz, including a personalised feed based on your own listening history.

Tested on LMS 9.x with the **Material Skin**.

---

## What it does

- **New Releases for You** — a personalised feed of fresh releases from artists you listen to (requires a ListenBrainz account + token).
- **All Releases** — the global ListenBrainz fresh-releases feed (no account needed).
- **Weekly view** — when sorted by release date, releases are grouped under a divider per week (`Week of 9 Jun 2026`), newest first. In Material these render as proper section headers (tap a week to focus just that week), and the list supports Material's grid/list view toggle.
- **Genre tags in the list** — where ListenBrainz supplies tags, up to three are shown next to each title (coverage is partial, so many rows won't have any).
- **Rich detail pages** — tap a release to see its tracklist (with durations), genres, folksonomy tags, and a clickable **View on MusicBrainz** link. Genres come from MusicBrainz, with an optional **Last.fm** fallback (see below) that fills the gap for brand-new releases MusicBrainz hasn't tagged yet.
- **Block artists you don't want** — a **Block this artist** action on any release detail page hides every release by that artist from all feeds (New Releases for You, All Releases, and the home shelf). Manage and unblock them in the **Blocked Artists** settings section.
- **One-tap streaming playback** — if you have the **Qobuz** and/or **Bandcamp** plugins installed, each release detail page shows the matching album on those services (with their logos), playable directly. Matching is by artist + title.
- **Material home shelf** — adds an optional **New Releases for You** scrollable row to the Material Skin home screen (see below).
- **Caching** — streaming matches and MusicBrainz lookups are cached so revisiting an album is instant.

---

## Requirements

| Feature | Requirement |
|---|---|
| **All Releases** feed | None — works out of the box |
| **New Releases for You** feed | An **active ListenBrainz account** with listening history, plus your **ListenBrainz API token** |
| **Streaming playback** | The **Qobuz** and/or **Bandcamp** LMS plugins installed and signed in |
| **Last.fm genre fallback** | A free **Last.fm API key** (optional — see Setup) |
| **Home shelf row** | **Material Skin** |
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
2. Enter your **ListenBrainz username** and **API token** (only needed for *New Releases for You*).
3. *(Optional)* Paste a free **Last.fm API key** to enable the detail-page genre fallback. Create one at [last.fm/api/account/create](https://www.last.fm/api/account/create); leave blank to disable.
4. Adjust the filters to taste and save.

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
| Find on Streaming Services | **On** | Show playable Qobuz/Bandcamp matches on detail pages |

Both sections share the same set of filters and the same defaults; you can tune each independently.

### Blocked Artists

Artists you've blocked (via **Block this artist** on a release detail page) are listed here, and their releases are hidden from every feed. There is no ListenBrainz API for this — it's a purely local filter, so it takes effect immediately the next time you open a feed. Tick an artist's **Unblock** box and save to start seeing their releases again. Various Artists can't be blocked (it would hide unrelated compilations).

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

## Material home shelf

The plugin registers a **New Releases for You** scrollable row for the Material Skin home screen.

To enable it: in Material, edit the home screen / **Customize home menu** and turn on **New Releases for You**.

> **Tip:** Material caches the list of available home rows in your browser. If a newly added row doesn't appear, do a hard refresh (**Ctrl/Cmd-Shift-R**) and look again.

The row shows your latest personalised releases as cards; tapping a card opens the full detail page (tracklist, genres, streaming playback). Clicking into the row opens the full list of cards. (The weekly dividers live in the main *New Releases for You* / *All Releases* menus — the home shelf is kept as a flat list so streaming playback works from it.)

---

## Notes & limitations

- **Genre coverage** on brand-new releases is sparse — MusicBrainz often hasn't tagged them yet, and only a minority of releases carry ListenBrainz tags. Genres are therefore shown *when available* rather than used as a browse filter. Adding a **Last.fm API key** improves this a lot: the detail page falls back to Last.fm's album tags, then the artist's tags (which are usually populated even when a new album isn't).
- **Streaming matches** are found by searching each service for the artist + album, so an album not yet on a service won't appear, and very occasionally a close title may mismatch.
- Streaming playback requires the respective service plugin to be installed and signed in; the feature simply hides itself if no supported service is present.

---

## Credits

- Release data from [ListenBrainz](https://listenbrainz.org) / [MusicBrainz](https://musicbrainz.org), cover art from the [Cover Art Archive](https://coverartarchive.org). All part of the [MetaBrainz](https://metabrainz.org) project.
- Streaming playback via the community **Qobuz** and **Bandcamp** LMS plugins.

See [LICENSE](LICENSE) for licensing.
