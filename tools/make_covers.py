#!/usr/bin/env python3
"""Generate ALL of the plugin's branded cover/badge images.

These are flat, cross-platform PNGs (no server-side compositing — LMS has no
GD/Imager/ImageMagick on the target box, and we won't require an install; see
CLAUDE.md / the no-extra-server-installs note). They share one design system:

    vertical gradient  +  centred white bold title (1-2 lines, auto-wrapped)
    +  optional white "week" pill (category-coloured text)
    +  a LISTENBRAINZ wordmark along the bottom.

The whole set is produced here so it can be regenerated/tweaked later without
reverse-engineering the originals. Run from the repo root:

    python3 tools/make_covers.py

Covers produced (500x500):
  - menu tiles (main page / section): New Releases for You, Playlists, All Releases
  - playlist tiles: Weekly Jams / Weekly Exploration (+ -prev = Last Week),
    Daily Jams, and a generic default
  - All Releases week badges: This Week / Last Week / Earlier

Design rules (keep these stable so tiles line up across the plugin):
  * The wordmark and (when present) the pill sit at FIXED y positions, so a
    one-line title (Weekly Jams) and a two-line title (Weekly Exploration) line
    their pills up identically — only the title block re-centres above the pill.

NOTE: the Material font-icon PNGs (lbf-cog_MTL_icon_settings.png,
lbf-refresh_MTL_icon_refresh.png) are NOT generated here — their filename uses
Material's `_MTL_icon_<name>` convention so Material renders its own themed font
icon; the bundled PNG is only a minimal fallback for non-Material skins.
"""

from PIL import Image, ImageDraw, ImageFont

OUT = "ListenBrainzFreshReleases/HTML/EN/plugins/ListenBrainzFreshReleases/html/images"
SIZE = 500
MAXW = 460             # title wrap width (fits "New Releases" on one line)
TITLE_SZE = 66
PILL_CY = 350          # FIXED pill centre y (decoupled from title line count)
TITLE_CY_PILL = 200    # title block centre y when a pill is present (room below)
TITLE_CY_PLAIN = 245   # title block centre y when there's no pill (lower / centred)
WORD_CY = 452          # LISTENBRAINZ wordmark centre y

FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

# (top, bottom) gradient per category. The bottom (darker) colour doubles as the
# pill text colour on the white pill. Sampled from the original images.
GREEN  = ((51, 159, 97),  (28, 104, 60))    # New Releases for You
BLUE   = ((89, 106, 191), (53, 64, 128))    # Playlists (menu tile)
AMBER  = ((213, 149, 39), (150, 96, 20))    # All Releases
ORANGE = ((236, 117, 57), (176, 66, 30))    # Weekly Jams
TEAL   = ((37, 149, 167), (20, 80, 108))    # Weekly Exploration
PURPLE = ((121, 85, 167), (64, 44, 104))    # Daily Jams
INDIGO = ((69, 63, 127),  (40, 36, 80))     # default playlist

# name -> (title, gradient, pill text or None)
COVERS = {
    # main-page / section menu tiles (no pill)
    "menu-new-releases":                ("New Releases for You", GREEN,  None),
    "menu-playlists":                   ("Playlists",            BLUE,   None),
    "menu-all-releases":                ("All Releases",         AMBER,  None),
    # Created-for-You playlist tiles
    "playlist-weekly-jams":             ("Weekly Jams",          ORANGE, "THIS WEEK"),
    "playlist-weekly-jams-prev":        ("Weekly Jams",          ORANGE, "LAST WEEK"),
    "playlist-weekly-exploration":      ("Weekly Exploration",   TEAL,   "THIS WEEK"),
    "playlist-weekly-exploration-prev": ("Weekly Exploration",   TEAL,   "LAST WEEK"),
    "playlist-daily-jams":              ("Daily Jams",           PURPLE, None),
    "playlist-default":                 ("Playlist",             INDIGO, None),
    # All Releases per-week badges
    "allrel-this-week":                 ("All Releases",         AMBER,  "THIS WEEK"),
    "allrel-last-week":                 ("All Releases",         AMBER,  "LAST WEEK"),
    "allrel-earlier":                   ("All Releases",         AMBER,  "EARLIER"),
}


def gradient(top, bot):
    img = Image.new("RGB", (SIZE, SIZE))
    px = img.load()
    for y in range(SIZE):
        t = y / (SIZE - 1)
        row = (round(top[0] + (bot[0] - top[0]) * t),
               round(top[1] + (bot[1] - top[1]) * t),
               round(top[2] + (bot[2] - top[2]) * t))
        for x in range(SIZE):
            px[x, y] = row
    return img


def text_w(draw, s, font, spacing=0):
    w = draw.textlength(s, font=font)
    if spacing and len(s) > 1:
        w += spacing * (len(s) - 1)
    return w


def draw_spaced(draw, cx, y, s, font, fill, spacing):
    """Letter-spaced text, centred on cx, top at y."""
    total = text_w(draw, s, font, spacing)
    x = cx - total / 2
    for ch in s:
        draw.text((x, y), ch, font=font, fill=fill)
        x += draw.textlength(ch, font=font) + spacing


def wrap(draw, words, font):
    lines, cur = [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if cur and text_w(draw, trial, font) > MAXW:
            lines.append(cur)
            cur = w
        else:
            cur = trial
    if cur:
        lines.append(cur)
    return lines


def make(name, title, palette, pill):
    (top, bot) = palette
    img = gradient(top, bot)
    d = ImageDraw.Draw(img)

    tfont = ImageFont.truetype(FONT, TITLE_SZE)
    lines = wrap(d, title.split(), tfont)
    asc, desc = tfont.getmetrics()
    step = round((asc + desc) * 1.02)
    block_h = step * len(lines)
    cy = TITLE_CY_PILL if pill else TITLE_CY_PLAIN
    y = round(cy - block_h / 2)
    for ln in lines:
        w = d.textlength(ln, font=tfont)
        d.text(((SIZE - w) / 2, y), ln, font=tfont, fill=(255, 255, 255))
        y += step

    if pill:
        pf = ImageFont.truetype(FONT, 30)
        sp = 3
        tw = text_w(d, pill, pf, sp)
        pa, pdsc = pf.getmetrics()
        padx, pady = 34, 14
        pw, ph = tw + padx * 2, (pa + pdsc) + pady * 2
        x0, y0 = (SIZE - pw) / 2, PILL_CY - ph / 2
        d.rounded_rectangle([x0, y0, x0 + pw, y0 + ph], radius=ph / 2,
                            fill=(255, 255, 255))
        draw_spaced(d, SIZE / 2, y0 + pady, pill, pf, bot, sp)

    wf = ImageFont.truetype(FONT, 26)
    draw_spaced(d, SIZE / 2, WORD_CY - wf.getmetrics()[0] / 2 - 4,
                "LISTENBRAINZ", wf, (255, 255, 255), 8)

    img.save(f"{OUT}/{name}.png")
    print("wrote", name, "lines=", len(lines))


if __name__ == "__main__":
    for n, (t, pal, p) in COVERS.items():
        make(n, t, pal, p)
