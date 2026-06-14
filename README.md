# ListenBrainz Fresh Releases — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** that browses [ListenBrainz](https://listenbrainz.org) *Fresh Releases* — newly released albums from MusicBrainz, including a personalised feed based on your own listening history.

Tested on LMS 9.x with the **Material Skin**.

---

## What it does

- **New Releases for You** — a personalised feed of fresh releases from artists you listen to (requires a ListenBrainz account + token).
- **All Releases** — the global ListenBrainz fresh-releases feed (no account needed).
- **Weekly view** — when sorted by release date, releases are grouped under a divider per week (`Week of 9 Jun 2026`), newest first.
- **Rich detail pages** — tap a release to see its tracklist (with durations) and genres pulled from MusicBrainz, folksonomy tags, and a clickable **View on MusicBrainz** link.
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
3. Adjust the filters to taste and save.

---

## Settings & defaults

### General

| Setting | Default | Notes |
|---|---|---|
| ListenBrainz Username | *(empty)* | Needed for *New Releases for You* |
| User Token | *(empty)* | From listenbrainz.org/settings/ |
| Days window | **14** | 1–90 days of releases to show |
| Default sort | **Release Date** | Date (newest first), Artist, Album, or Confidence |
| Group by Artist | **On** | Collapse artists with several new releases into one entry |
| Weekly Dividers | **On** | Date-sorted view gets a divider per week (takes precedence over Group by Artist for the date sort) |
| Find on Streaming Services | **On** | Show playable Qobuz/Bandcamp matches on detail pages |

### New Releases for You

| Setting | Default |
|---|---|
| Show Albums (albums-only) | **On** |
| Include Past Releases | **On** |
| Include Upcoming Releases | **Off** |
| Only Releases with Artwork | **On** |
| Include Various Artists | **On** |

### All Releases

| Setting | Default |
|---|---|
| Include Past Releases | **On** |
| Include Upcoming Releases | **Off** |
| Only Releases with Artwork | **On** |
| Include Various Artists | **On** |
| Release types | **Album, Compilation, Soundtrack** on; Single, EP, Broadcast, Other, Live, Remix, Demo off |

---

## Material home shelf

The plugin registers a **New Releases for You** scrollable row for the Material Skin home screen.

To enable it: in Material, edit the home screen / **Customize home menu** and turn on **New Releases for You**.

> **Tip:** Material caches the list of available home rows in your browser. If a newly added row doesn't appear, do a hard refresh (**Ctrl/Cmd-Shift-R**) and look again.

The row shows your latest personalised releases as cards; tapping a card opens the full detail page (tracklist, genres, streaming playback).

---

## Notes & limitations

- **Genre coverage** on brand-new releases is sparse in MusicBrainz/ListenBrainz (often under ~10%), so genres are shown on the detail page *when available* rather than used as a browse filter.
- **Streaming matches** are found by searching each service for the artist + album, so an album not yet on a service won't appear, and very occasionally a close title may mismatch.
- Streaming playback requires the respective service plugin to be installed and signed in; the feature simply hides itself if no supported service is present.

---

## Credits

- Release data from [ListenBrainz](https://listenbrainz.org) / [MusicBrainz](https://musicbrainz.org), cover art from the [Cover Art Archive](https://coverartarchive.org). All part of the [MetaBrainz](https://metabrainz.org) project.
- Streaming playback via the community **Qobuz** and **Bandcamp** LMS plugins.

See [LICENSE](LICENSE) for licensing.
