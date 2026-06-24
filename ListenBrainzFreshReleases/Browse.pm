package Plugins::ListenBrainzFreshReleases::Browse;

use strict;
use warnings;

use Time::Local ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Utils::Timers;
use Slim::Utils::Strings qw(cstring string);

use Plugins::ListenBrainzFreshReleases::API;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');
my $cache = Slim::Utils::Cache->new();

# How long to remember a streaming-match result before searching again.
# A found match rarely changes (albums don't vanish) → keep a week. A "no match"
# on a brand-new release is likely to change soon (it may land on the service in
# a few days) → recheck daily.
use constant STREAM_FOUND_TTL   => 7 * 86400;
use constant STREAM_NOMATCH_TTL => 1 * 86400;
# Per-service streaming-search timeout: a slow/hung service is treated as "no
# match" after this so it can't hold up the (parallel) lookup.
use constant STREAM_SVC_TIMEOUT => 8;
# Cap on streaming matches shown — a generic single-word album ("Prism") can
# prefix-match dozens of unrelated albums on a service (one search returned 48);
# bound the detail page so it stays fast and sane.
use constant STREAM_MAX_RESULTS => 12;

# Safety net (seconds): if a streaming/MusicBrainz callback never fires (network
# hang, partial failure), render the detail page anyway rather than hang.
use constant DETAIL_TIMEOUT => 10;

# Length of the artist-bio preview shown on the detail page (~2 lines); the full
# bio is behind a "Read more" drill-in.
use constant BIO_PREVIEW => 150;

# A local-library match points at a file URL that could disappear on a rescan, so
# cache library hits (and any resolved playlist that contains one) for only a day.
use constant LIBRARY_TTL => 1 * 86400;
# Per-track streaming-match cache TTLs. A found track persists; a no-match is also
# kept a good while (a week) — these algorithmic playlists only change weekly and
# the same track recurs across weeks/playlists, so re-searching a known miss daily
# is wasted API calls for no real benefit.
use constant TRACK_FOUND_TTL   => 30 * 86400;
use constant TRACK_NOMATCH_TTL =>  7 * 86400;
# Resolved whole-playlist cache. The JSPF content is IMMUTABLE for a given
# mbid|last_modified, so there's no correctness reason to expire early — a new
# week brings a new mbid (a fresh key) which re-resolves once. We keep BOTH full
# and partial results long: the Weekly Jams/Exploration playlists live ~2 weeks
# (current + previous week), so the cache must survive into the playlist's SECOND
# week or the "previous week" entry would re-resolve all 50 tracks needlessly.
# (Trade-off: a track that only later appears on a service isn't picked up until
# next week's playlist — an intentional choice to avoid the slow re-resolve.)
use constant PLAYLIST_FOUND_TTL   => 30 * 86400;
use constant PLAYLIST_PARTIAL_TTL => 30 * 86400;
# Max tracks resolved in parallel — bounds the burst of service searches a 50-track
# playlist would otherwise fire all at once (rate-limit friendliness).
use constant PLAYLIST_CONCURRENCY => 6;
# Overall watchdog for resolving a playlist, so a hung service search can't leave
# the playlist page spinning forever.
use constant PLAYLIST_TIMEOUT => 45;

use constant ICON => 'plugins/ListenBrainzFreshReleases/html/images/ListenBrainzFreshReleasesIcon_svg.png';

# Branded cover-style images for the top-level menu rows (same look as the
# playlist covers). The settings cog uses Material's "_MTL_icon_<name>" filename
# convention so Material renders its own themed cog font-icon; the file itself is
# a flat gear PNG fallback for non-Material skins.
use constant IMG_BASE      => 'plugins/ListenBrainzFreshReleases/html/images/';
use constant MENU_NEW      => IMG_BASE . 'menu-new-releases.png';
use constant MENU_PLAYLISTS=> IMG_BASE . 'menu-playlists.png';
use constant MENU_ALL      => IMG_BASE . 'menu-all-releases.png';
use constant MENU_COG      => IMG_BASE . 'lbf-cog_MTL_icon_settings.png';
use constant MENU_REFRESH  => IMG_BASE . 'lbf-refresh_MTL_icon_refresh.png';
# All Releases per-week covers — branded cover + a relative-week badge. Past weeks
# (This Week / Last Week / Earlier) and, when "Include Upcoming" is on, future weeks
# (Next Week / Next Fortnight / Further, on a "Future Releases" cover). Literal dates
# can't be drawn server-side (no image lib), so the badge is relative; the exact date
# is in the row label.
use constant AR_THIS      => IMG_BASE . 'allrel-this-week.png';
use constant AR_LAST      => IMG_BASE . 'allrel-last-week.png';
use constant AR_EARLIER   => IMG_BASE . 'allrel-earlier.png';
use constant AR_NEXT      => IMG_BASE . 'allrel-next-week.png';
use constant AR_FORTNIGHT => IMG_BASE . 'allrel-next-fortnight.png';
use constant AR_FURTHER   => IMG_BASE . 'allrel-further.png';

# Various Artists MBID — used to detect VA releases
use constant VA_MBID => '89ad4ac3-39f7-470e-963a-56509c546377';

# ---------------------------------------------------------------------------
# Top-level feed
# ---------------------------------------------------------------------------
sub topLevel {
    my ($client, $callback, $args) = @_;

    my $username = $prefs->get('username') // '';
    my $token    = $prefs->get('token')    // '';

    # The requesting client's "features" string is only available here (the top
    # feed gets the request params); XMLBrowser does NOT forward request params
    # to drilled coderef sub-feeds. So capture it now and pass it down to
    # fetchForYou/fetchAll via passthrough (which IS forwarded).
    my $feat = _featuresOf($args);

    my $useH = _wantHeaders($feat);

    # --- section child items ---------------------------------------------
    my $newReleases = ($username && $token)
        ? _categoryTile($client, 'user', MENU_NEW, \&fetchForYou, $feat)
        : { name => cstring($client, 'PLUGIN_LBF_SETUP_REQUIRED'), type => 'text', image => ICON };

    my @createdFor = ($newReleases);
    push @createdFor, _playlistsTile($client, $feat) if $username;

    my @allReleases = ( _categoryTile($client, 'all', MENU_ALL, \&fetchAll, $feat) );

    my @settings = ({
        name => cstring($client, 'PLUGIN_LBF_SETTINGS'), type => 'link',
        weblink => '/plugins/ListenBrainzFreshReleases/settings.html', image => MENU_COG,
    });

    # --- assemble with Material section headers --------------------------
    my @items;
    push @items, _sectionHeader($client, 'PLUGIN_LBF_SECTION_CREATED_FOR_YOU', $useH, \@createdFor), @createdFor;
    push @items, _sectionHeader($client, 'PLUGIN_LBF_ALL_RELEASES',           $useH, \@allReleases), @allReleases;
    push @items, _sectionHeader($client, 'PLUGIN_LBF_SECTION_SETTINGS',       $useH, \@settings),    @settings;

    # cachetime => 0 so Material doesn't cache the top menu per-player — keeps the
    # date-span tiles in step with the weekly rollover (same rationale as the feeds).
    $callback->({ items => \@items, cachetime => 0 });
}

# A Material section-divider header. Material renders type=>'header' bold/accented
# but forces a drill action onto it (can't be suppressed), so — as with the week
# dividers — give it a url returning its own child items, so tapping the header
# (or its "More") shows that section rather than an empty page. Non-Material skins
# get a plain text divider.
sub _sectionHeader {
    my ($client, $stringToken, $useH, $children, $noIcon) = @_;
    # $noIcon: drop the logo thumbnail (detail-page section headers — there's
    # nothing to drill into, the rows sit right below, so the icon just adds
    # clutter). List pages keep the icon so Material's grid toggle stays enabled.
    my $hdr = {
        name  => cstring($client, $stringToken),
        type  => $useH ? 'header' : 'text',
        ($noIcon ? () : (image => ICON)),
    };
    if ($useH) {
        my @kids = @$children;
        $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
        $hdr->{passthrough} = [{}];
    }
    return $hdr;
}

# A top-level category tile (New Releases for You / All Releases). The branded
# cover image already carries the category title, so the row's text is the date
# span actually being shown — the real min/max of the cached feed once loaded,
# else the window implied by the user's days/past/future settings — plus the
# release count, rather than repeating the title under the thumbnail.
sub _categoryTile {
    my ($client, $which, $img, $urlSub, $feat) = @_;

    my $s    = $cache->get('lbf:summary:' . $which);
    my $span = ($s && $s->{max}) ? _dateSpan($s->{min}, $s->{max}) : _windowSpan($which);

    my %tile = (
        name        => $span,
        type        => 'link',
        url         => $urlSub,
        passthrough => [{ features => $feat }],
        image       => $img,
    );
    $tile{line2} = sprintf(cstring($client, 'PLUGIN_LBF_N_RELEASES'), $s->{count})
        if $s && defined $s->{count};
    return \%tile;
}

# The Playlists menu tile. The branded cover already says "Playlists", so the row
# text is the date span the playlists inside actually cover (earliest week-start /
# day → today), stashed from the playlist list. No text until that's known.
sub _playlistsTile {
    my ($client, $feat) = @_;

    # Always a date span (never an empty name — that would make Material drop the
    # row). Prefer the real span stashed from the playlist list; otherwise compute
    # it synchronously like _categoryTile does: ListenBrainz keeps the current +
    # previous week, so the covered span is last week's Monday → today.
    my $s    = $cache->get('lbf:summary:playlists');
    my $name = ($s && $s->{min})
        ? _dateSpan($s->{min}, _ymd(time))
        : _dateSpan(_weekStart(_ymd(time - 7 * 86400)), _ymd(time));

    return {
        name        => $name,
        type        => 'link',
        url         => \&fetchPlaylists,
        passthrough => [{ features => $feat }],
        image       => MENU_PLAYLISTS,
    };
}

# Stash the earliest period the Created-for-You playlists cover (weekly → the
# week-commencing Monday, else the day), so _playlistsTile can show the span
# without re-fetching. Called wherever the playlist list is fetched.
sub _stashPlaylistSummary {
    my ($playlists) = @_;
    return unless ref $playlists eq 'ARRAY' && @$playlists;
    my @starts;
    for my $pl (@$playlists) {
        my $lm    = _isoToLocalDate($pl->{last_modified} // '');   # UTC instant → local date
        my $start = (lc($pl->{source_patch} // '') =~ /^weekly-/)
            ? _weekStart($lm)
            : $lm;
        push @starts, $start if $start;
    }
    return unless @starts;
    my ($min) = sort @starts;
    eval { $cache->set('lbf:summary:playlists', { min => $min }, 25 * 3600); 1 };
}

# Cache a section feed's summary (release count + actual earliest/latest release
# date) so _categoryTile can render its subtitle instantly without re-fetching.
# Keyed by section ('user' | 'all'); rewritten each time the feed is built.
sub _stashSummary {
    my ($which, $releases) = @_;
    return unless ref $releases eq 'ARRAY';
    my @d = sort grep { length } map { $_->{release_date} // '' } @$releases;
    eval { $cache->set('lbf:summary:' . $which, {
        count => scalar(@$releases),
        min   => ($d[0]  // ''),
        max   => ($d[-1] // ''),
    }, 25 * 3600); 1 };
}

# ---------------------------------------------------------------------------
# Fetch For You — applies For You prefs
# ---------------------------------------------------------------------------
sub fetchForYou {
    my ($client, $callback, $args, $passDict) = @_;

    my $headers = _wantHeaders(ref $passDict eq 'HASH' ? $passDict->{features} : undef);
    my $sort   = $prefs->get('sort')          // 'release_date';
    my $past   = $prefs->get('foryou_past')   // 1;
    my $future = $prefs->get('foryou_future') // 0;

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => $sort,
        past    => $past,
        future  => $future,
        days    => $prefs->get('days') // 14,
        onDone  => sub {
            my $releases = _sortReleases(_filterForYou(shift));
            _stashSummary('user', $releases);
            # cachetime => 0: don't let Material cache this dynamic feed per-player
            # (proven for Playlists in 0.9.24 — forces a re-fetch on each open so the
            # weekly rollover shows immediately rather than a stale cached copy).
            $callback->({ items => [ _refreshItem($client, 'user'), @{ _buildItems($releases, $client, $headers) } ], cachetime => 0 });
        },
        onError => sub {
            $log->error("For You fetch error: " . (shift // ''));
            # cachetime => 0 on the error path too, so a transient failure tile isn't
            # cached per-player and left stuck after the backend recovers.
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }], cachetime => 0 });
        },
    );
}

# ---------------------------------------------------------------------------
# For You feed for the Material Skin home-page row (carousel + "show all"
# click-in). Same structure as the main For You menu (week dividers / grouping).
# ---------------------------------------------------------------------------
sub homeForYou {
    my ($client, $cb, $args) = @_;

    # Flat list of release cards — NO week-divider headers. The Material carousel
    # and its "show all" click-in are the SAME feed (Material exposes no way to
    # give the click-in a different command), so they must share one structure.
    # A header item sits at index 0 and shifts every card's item_id; play commands
    # re-traverse the feed by item_id at quantity 1, so that shift makes deep
    # streaming playback resolve the wrong item and fail (verified via JSON-RPC:
    # headered item_id:1 = a card, flat item_id:1 = a different card). It must
    # also not vary by request quantity for the same reason. So: always flat, for
    # every quantity. Week dividers live in the main For You / All Releases menus.
    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => $prefs->get('sort')          // 'release_date',
        past    => $prefs->get('foryou_past')   // 1,
        future  => $prefs->get('foryou_future') // 0,
        days    => $prefs->get('days')          // 14,
        onDone  => sub {
            my $releases = _sortReleases(_filterForYou(shift));
            _stashSummary('user', $releases);
            $cb->({ items => [ map { _buildReleaseItem($_, $client) } @$releases ], cachetime => 0 });
        },
        onError => sub {
            $log->error("Home For You fetch error: " . (shift // ''));
            $cb->({ items => [], cachetime => 0 });
        },
    );
}

# Material home-page row for the Created-for-You playlists. Flat list of playlist
# tiles (one per playlist), quantity-stable. Tapping opens the resolved playlist;
# play queues it (the tiles are playable containers).
sub homePlaylists {
    my ($client, $cb, $args) = @_;

    Plugins::ListenBrainzFreshReleases::API->getCreatedForPlaylists(
        onDone => sub {
            my $playlists = shift // [];
            _stashPlaylistSummary($playlists);
            my %n;
            for my $pl (@$playlists) {
                $pl->{_variant} = $n{ lc($pl->{source_patch} // '') }++ ? 'previous' : 'current';
            }
            $cb->({ items => [ map { _playlistTile($_, $client) } @$playlists ], cachetime => 0 });
        },
        onError => sub {
            $log->error("Home Playlists fetch error: " . (shift // ''));
            $cb->({ items => [], cachetime => 0 });
        },
    );
}

# Material home-page row for All Releases. Shows the FLATTENED first level — the
# "All releases" entry plus one card per week-commencing (This/Last/Earlier) — so
# the carousel is a jump-off into a section rather than the full (large) release
# list. The landing is a small fixed list (well under 50) so it's the same at
# every request quantity (carousel vs "show all"), keeping deep drill-in stable.
sub homeAllReleases {
    my ($client, $cb, $args) = @_;

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
        sort    => $prefs->get('sort')     // 'release_date',
        past    => $prefs->get('all_past')   // 1,
        future  => $prefs->get('all_future') // 0,
        days    => $prefs->get('days')       // 14,
        onDone  => sub {
            my $releases = _sortReleases(_filterAll(shift));
            _stashSummary('all', $releases);
            $cb->({ items => _buildAllLanding($releases, $client, 0), cachetime => 0 });
        },
        onError => sub {
            $log->error("Home All Releases fetch error: " . (shift // ''));
            $cb->({ items => [], cachetime => 0 });
        },
    );
}

# ---------------------------------------------------------------------------
# Fetch All Releases — applies All Releases prefs
# ---------------------------------------------------------------------------
sub fetchAll {
    my ($client, $callback, $args, $passDict) = @_;

    my $headers = _wantHeaders(ref $passDict eq 'HASH' ? $passDict->{features} : undef);
    my $sort   = $prefs->get('sort')       // 'release_date';
    my $past   = $prefs->get('all_past')   // 1;
    my $future = $prefs->get('all_future') // 0;

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
        sort    => $sort,
        past    => $past,
        future  => $future,
        days    => $prefs->get('days') // 14,
        onDone  => sub {
            my $releases = _sortReleases(_filterAll(shift));
            _stashSummary('all', $releases);
            $callback->({ items => [ _refreshItem($client, 'all'), @{ _buildAllLanding($releases, $client, $headers) } ], cachetime => 0 });
        },
        onError => sub {
            $log->error("All releases fetch error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }], cachetime => 0 });
        },
    );
}

# A "Refresh" row for the feed lists. The feeds cache for a day; tapping this
# clears that feed's working cache key (API::clearFeedCache) and reloads the list
# in place via nextWindow 'refresh' (same mechanism as the detail-page streaming
# refresh), so the next render cache-misses and re-fetches fresh data. $which is
# 'user' (New Releases for You) or 'all' (All Releases).
sub _refreshItem {
    my ($client, $which) = @_;
    return {
        name        => cstring($client, 'PLUGIN_LBF_REFRESH_FEED'),
        type        => 'link',
        image       => MENU_REFRESH,
        nextWindow  => 'refresh',
        passthrough => [{ which => $which }],
        url         => sub {
            my ($c, $cb, $a, $pass) = @_;
            my $w = (ref $pass eq 'HASH' && $pass->{which}) ? $pass->{which} : 'user';
            Plugins::ListenBrainzFreshReleases::API->clearFeedCache($w);
            $cb->({ items => [] });
        },
    };
}

# ===========================================================================
# Created-for-You Playlists section. Lists the ListenBrainz algorithmic
# playlists (Weekly Jams, Weekly Exploration, Daily Jams, …); opening one
# resolves every track to a streaming track (preferred-service order), drops the
# unmatched, and presents a fully-streaming, Play-all-able playlist with a 2x2
# grid cover tile.
# ===========================================================================
sub fetchPlaylists {
    my ($client, $callback, $args, $pass) = @_;

    Plugins::ListenBrainzFreshReleases::API->getCreatedForPlaylists(
        onDone => sub {
            my $playlists = shift // [];
            _stashPlaylistSummary($playlists);
            unless (@$playlists) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_PLAYLISTS'), type => 'text' }], cachetime => 0 });
                return;
            }
            # Mark each playlist current/previous within its category (list is
            # already newest-first), so the weekly tiles get the right week cover.
            my %n;
            for my $pl (@$playlists) {
                $pl->{_variant} = $n{ lc($pl->{source_patch} // '') }++ ? 'previous' : 'current';
            }
            # cachetime => 0: experiment (0.9.24) — ask the client not to cache this
            # dynamic weekly list, to see if it stops Material serving a stale
            # per-player browse copy after the Monday rollover. The data is already
            # fresh server-side; this only tests whether the hint forces a re-fetch.
            $callback->({
                items     => [ map { _playlistTile($_, $client) } @$playlists ],
                cachetime => 0,
            });
        },
        onError => sub {
            $log->error("Playlists fetch error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }], cachetime => 0 });
        },
    );
}

# One browse tile for a playlist: title, a trimmed annotation as line2, and the
# 2x2 grid cover (a real server-served PNG, so every skin shows it).
sub _playlistTile {
    my ($pl, $client) = @_;

    # line2 = the period the playlist covers, then the streaming-match count.
    # Weekly playlists → "W/C <Monday>"; daily → the day itself; both derived
    # from last_modified (its generation date). The match count is read from the
    # resolved-playlist cache (warm pre-resolves it) so it's shown without doing
    # the resolve here; omitted until that cache is populated.
    my $patch = lc($pl->{source_patch} // '');
    my $lastMod = $pl->{last_modified} // '';
    # The displayed period uses the LOCAL calendar date of the (UTC) last_modified
    # instant; $lastMod itself stays raw below for the cache key / passthrough.
    my $lastModLocal = _isoToLocalDate($lastMod);

    my $period;
    if ($patch =~ /^weekly-/) {
        my $ws = _weekStart($lastModLocal);
        $period = $ws ? cstring($client, 'PLUGIN_LBF_WEEK_COMMENCING') . ' ' . _fmtDate($ws) : '';
    }
    else {
        $period = $lastModLocal ? _fmtDate($lastModLocal) : '';
    }

    my $matched = '';
    my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());
    my $rkey = 'lbf:pl:resolved:2:' . join('|', ($pl->{mbid} // ''), $lastMod, $svcOrder);
    if (my $c = $cache->get($rkey)) {
        $matched = sprintf(cstring($client, 'PLUGIN_LBF_PL_MATCHED'), $c->{matched}, $c->{total});
    }

    # The branded cover already carries the playlist name, so the row's first line
    # is the period it covers (W/C date / day), with the match count beneath it.
    # Fall back to the title only if the date couldn't be derived.
    return {
        name  => ($period ne '' ? $period : ($pl->{title} // 'Playlist')),
        ($matched ne '' ? (line2 => $matched) : ()),
        # 'playlist' (not 'link') makes the row a playable container: tapping still
        # drills in (go), but it now also carries Play/Add actions that resolve the
        # feed and queue all its streaming tracks — like a native playlist row.
        type        => 'playlist',
        # Per-category cover (bundled static image, keyed by source_patch). A real
        # 2x2 track-art grid needs server-side compositing (GD/Imager/ImageMagick),
        # none of which are present and which we won't require — so we use a fixed,
        # cross-platform branded cover per playlist type (no flicker, instant).
        image       => _categoryCover($pl->{source_patch}, $pl->{_variant}),
        url         => \&resolvePlaylist,
        passthrough => [{
            mbid          => $pl->{mbid},
            title         => $pl->{title},
            last_modified => $pl->{last_modified},
        }],
    };
}

# Per-category bundled cover image, keyed by the playlist's source_patch. These
# are static plugin images (cross-platform, no server-side compositing needed).
# The weekly playlists exist as current + previous week; ListenBrainz keeps both,
# so they'd otherwise share one cover. We pick a "This Week"/"Last Week" variant
# ($variant eq 'previous' → the -prev image) so the two are distinguishable. The
# exact week date is in the row title — drawing it onto the image would need a
# server-side image lib we deliberately don't require (see no-extra-server-installs).
my %PL_COVER = (
    'weekly-jams'        => 'playlist-weekly-jams.png',
    'weekly-exploration' => 'playlist-weekly-exploration.png',
    'daily-jams'         => 'playlist-daily-jams.png',
);
sub _categoryCover {
    my ($patch, $variant) = @_;
    $patch = lc($patch // '');
    my $file = $PL_COVER{$patch} // 'playlist-default.png';
    $file =~ s/\.png$/-prev.png/ if ($variant // '') eq 'previous' && $patch =~ /^weekly-/;
    return 'plugins/ListenBrainzFreshReleases/html/images/' . $file;
}

# Open a playlist → resolved, fully-streaming track list (cached as a unit so
# revisits and play-by-item_id re-traversals are instant and quantity-stable).
sub resolvePlaylist {
    my ($client, $callback, $args, $pass) = @_;

    my $mbid    = ref $pass eq 'HASH' ? $pass->{mbid}          : undef;
    my $lastMod = ref $pass eq 'HASH' ? $pass->{last_modified} : '';
    unless ($mbid) {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        return;
    }

    # Key includes the service order so changing priorities re-resolves.
    my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());
    my $rkey = 'lbf:pl:resolved:2:' . join('|', $mbid, ($lastMod // ''), $svcOrder);

    my $title = ref $pass eq 'HASH' ? $pass->{title} : undef;

    if (my $c = $cache->get($rkey)) {
        $log->info("resolved playlist cache hit: $mbid ($c->{matched}/$c->{total})");
        $callback->(_playlistResult($client, $c, $title));
        return;
    }

    Plugins::ListenBrainzFreshReleases::API->getPlaylistTracks(
        $mbid, $lastMod,
        sub {
            my $tracks = shift // [];

            unless (@$tracks) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }] });
                return;
            }

            _resolveTracks($client, $tracks, sub {
                my $items   = shift // [];
                my $payload = { items => $items, matched => scalar(@$items), total => scalar(@$tracks) };
                my $ttl     = _playlistTtl($items, scalar @$tracks);
                eval { $cache->set($rkey, $payload, $ttl); 1 }
                    or $log->warn("resolved playlist cache set failed: $@");
                $log->info("resolved playlist $mbid: $payload->{matched}/$payload->{total} matched");
                $callback->(_playlistResult($client, $payload, $title));
            });
        },
        sub {
            $log->error("Playlist resolve error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        },
    );
}

# Build the resolved-playlist feed result: a PURE list of playable track items
# (unmatched tracks are dropped — no unplayable rows), so the level is a proper
# track list with a Play/Play-all option. The matched count goes in the page
# TITLE rather than as a list row. A stable structure at every request quantity
# keeps deep play-by-item_id correct (the 0.6.11 rule).
sub _playlistResult {
    my ($client, $payload, $title) = @_;

    my @items   = @{ $payload->{items} || [] };
    my $matched = $payload->{matched} // scalar(@items);
    my $total   = $payload->{total}   // scalar(@items);

    # Page title carries the match count, e.g. "Weekly Exploration … (47/50)".
    my $heading = defined $title && length $title ? $title : cstring($client, 'PLUGIN_LBF_PLAYLISTS');
    $heading .= " ($matched/$total)";

    return {
        title => $heading,
        items => @items ? \@items : [{ name => cstring($client, 'PLUGIN_LBF_NO_MATCH'), type => 'text' }],
    };
}

# Cache TTL for a resolved playlist. A playlist containing any local-library track
# is kept only a day (the file URL can go stale on a rescan/delete); otherwise it
# follows the long full/partial streaming TTLs.
sub _playlistTtl {
    my ($items, $total) = @_;
    return LIBRARY_TTL if grep { ($_->{_svc} // '') eq 'Library' } @$items;
    return (scalar(@$items) == $total) ? PLAYLIST_FOUND_TTL : PLAYLIST_PARTIAL_TTL;
}

# Resolve every track to a streaming track with bounded concurrency, preserving
# playlist order. Matched items only are returned (unmatched are dropped). A
# watchdog guarantees the page renders even if a service search hangs.
sub _resolveTracks {
    my ($client, $tracks, $done, $libMode) = @_;

    my $total     = scalar @$tracks;
    my @slots     = (undef) x $total;   # per-index: hashref (match) / 0 (miss) / undef (pending)
    my $next      = 0;
    my $active    = 0;
    my $completed = 0;
    my $finished  = 0;

    my $finish = sub {
        return if $finished;
        $finished = 1;
        $done->([ grep { ref $_ } @slots ]);   # matched items, in order
    };

    Slim::Utils::Timers::setTimer(undef, time() + PLAYLIST_TIMEOUT, sub { $finish->() });

    my $pump;
    $pump = sub {
        return if $finished;
        while ($active < PLAYLIST_CONCURRENCY && $next < $total) {
            my $i  = $next++;
            my $tr = $tracks->[$i];
            $active++;
            _findPlayableTrack($client, sub {
                my $item = shift;
                $slots[$i] = (ref $item eq 'HASH') ? $item : 0;
                $active--;
                $completed++;
                ($completed >= $total) ? $finish->() : $pump->();
            }, $tr->{artist}, $tr->{title}, $tr->{album}, $tr->{recording_mbid}, undef, $libMode);
        }
    };

    $total ? $pump->() : $finish->();
}

# ---------------------------------------------------------------------------
# Background warm: pre-fetch the playlist list, pre-resolve every playlist's
# track matches, and pre-build the grid covers — so opening the Playlists view
# and any playlist is INSTANT, and the tile art is already cached (no flicker on
# return). Runs on startup and daily (Plugin::postinitPlugin schedules it). The
# per-playlist tracks/resolved/grid caches are keyed by mbid|last_modified, so a
# daily run is cheap: it only does real work when a new week's playlist appears.
# Playlists are processed one at a time to stay gentle on the streaming APIs.
# ---------------------------------------------------------------------------
sub warmCache {
    my ($client) = @_;

    return unless ($prefs->get('username') // '') ne '';

    # Need a player for the streaming-service API context (Qobuz/Tidal handlers
    # are fetched per-client). Use any connected player; if none, we still warm
    # the list + grid covers, and track resolution happens on first open.
    $client ||= (Slim::Player::Client::clients())[0];

    Plugins::ListenBrainzFreshReleases::API->getCreatedForPlaylists(
        # force => 1: bypass the working-cache READ so the warm always re-pulls the
        # listing from ListenBrainz. Without this, a warm tick that ran while the
        # (Monday-aligned) listing cache was still valid would short-circuit on the
        # old listing and never discover/resolve the new week's playlists.
        force  => 1,
        onDone => sub {
            my @queue = @{ shift // [] };
            _stashPlaylistSummary(\@queue);
            $log->info("warm: " . scalar(@queue) . " playlist(s)");

            my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());

            my $next;
            $next = sub {
                my $pl = shift @queue or do { $log->info("warm: done"); return; };

                Plugins::ListenBrainzFreshReleases::API->getPlaylistTracks(
                    $pl->{mbid}, $pl->{last_modified},
                    sub {
                        my $tracks = shift // [];

                        my $rkey = 'lbf:pl:resolved:2:'
                            . join('|', $pl->{mbid}, ($pl->{last_modified} // ''), $svcOrder);

                        # Already resolved (same week) or no client → move on.
                        if ($cache->get($rkey) || !$client || !@$tracks) {
                            $next->();
                            return;
                        }

                        _resolveTracks($client, $tracks, sub {
                            my $items = shift // [];
                            my $payload = { items => $items, matched => scalar(@$items), total => scalar(@$tracks) };
                            my $ttl = _playlistTtl($items, scalar @$tracks);
                            eval { $cache->set($rkey, $payload, $ttl); 1 }
                                or $log->warn("warm resolved cache set failed: $@");
                            $log->info("warm: resolved $pl->{mbid} $payload->{matched}/$payload->{total}");
                            $next->();
                        });
                    },
                    sub { $next->() },
                );
            };
            $next->();
        },
        onError => sub { $log->info("warm: playlist list fetch failed: " . (shift // '')) },
    );
}

# ---------------------------------------------------------------------------
# Filter for For You section
# ---------------------------------------------------------------------------
# All release types offered as per-section filter checkboxes.
my @RELEASE_TYPES = qw(album single ep broadcast other compilation soundtrack live remix demo);

# Build the allowed-type set for a section from its <prefix>_type_* prefs.
sub _allowedTypes {
    my ($prefix) = @_;
    my %allowed;
    $allowed{$_} = 1 for grep { $prefs->get("${prefix}_type_$_") } @RELEASE_TYPES;
    return \%allowed;
}

# A release's secondary type, lower-cased ('' if none). ListenBrainz sends this
# as a single scalar string (release_group_secondary_type) — NOT an array — but
# accept the plural/array form defensively in case the API ever changes.
sub _secondaryType {
    my ($rel) = @_;
    my $s = $rel->{release_group_secondary_type}
         // $rel->{release_group_secondary_types}
         // $rel->{secondary_types};
    $s = $s->[0] if ref $s eq 'ARRAY';
    return (defined $s && lc($s) ne 'none') ? lc($s) : '';
}

# Does a release pass the type filter? Allowlist semantics: the primary type
# must be ticked AND any secondary type must also be ticked. This is what
# excludes live/soundtrack/audiobook/etc. releases whose primary is "Album".
# The secondary list in the API is larger than the offered checkboxes (DJ-mix,
# Audiobook, Interview…), so an untickable secondary correctly fails the list.
# An empty allowed-set means "nothing selected" → show everything (safety net).
sub _typeMatches {
    my ($rel, $allowed) = @_;
    return 1 unless %$allowed;

    return 0 unless $allowed->{ lc($rel->{release_group_primary_type} // '') };

    my $sec = _secondaryType($rel);
    return 0 if length $sec && !$allowed->{$sec};

    return 1;
}

# Shared per-section filter: release type (by prefix), Various Artists, artwork.
sub _filterSection {
    my ($releases, $prefix) = @_;
    $releases //= [];

    my $artwork_only = $prefs->get("${prefix}_artwork_only") // 1;
    my $various      = $prefs->get("${prefix}_various")      // 1;
    my $allowed      = _allowedTypes($prefix);
    my $blocked      = _blockedSet();

    my @out;
    for my $rel (@$releases) {
        next unless _typeMatches($rel, $allowed);
        next if !$various && _isVariousArtists($rel);
        next if _isBlocked($rel, $blocked);
        next if $artwork_only && !Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel);
        push @out, $rel;
    }
    return \@out;
}

sub _filterForYou { _filterSection(shift, 'foryou') }
sub _filterAll    { _filterSection(shift, 'all') }

# ---------------------------------------------------------------------------
# Sort releases by the configured order. Release date is newest-first and
# confidence highest-first; artist/album are A–Z. (The API's own ordering is
# unreliable — e.g. date comes back oldest-first — so we sort here.)
# ---------------------------------------------------------------------------
# Collapse duplicate editions of the same album. ListenBrainz/MusicBrainz often
# list a fresh release twice — sometimes as two different release-groups — so key
# on normalised artist + album + date rather than MBID. Keep the copy with cover
# art where one of the pair has it.
sub _dedupeReleases {
    my ($releases) = @_;
    return $releases unless ref $releases eq 'ARRAY';

    my %idx;
    my @out;
    for my $rel (@$releases) {
        my $key = join('|',
            _norm(_pickValue($rel, 'artist_credit_name', 'artist_name', 'artist')),
            _norm(_pickValue($rel, 'release_name', 'title', 'name')),
            ($rel->{release_date} // ''));

        if (defined(my $i = $idx{$key})) {
            $out[$i] = $rel
                if !Plugins::ListenBrainzFreshReleases::API->coverArtUrl($out[$i])
                &&  Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel);
            next;
        }
        $idx{$key} = scalar @out;
        push @out, $rel;
    }
    return \@out;
}

sub _sortReleases {
    my ($releases) = @_;
    return $releases unless ref $releases eq 'ARRAY';

    $releases = _dedupeReleases($releases);

    my $sort = $prefs->get('sort') // 'release_date';

    if ($sort eq 'artist_credit_name') {
        return [ sort { lc($a->{artist_credit_name} // '') cmp lc($b->{artist_credit_name} // '') } @$releases ];
    }
    elsif ($sort eq 'release_name') {
        return [ sort { lc($a->{release_name} // '') cmp lc($b->{release_name} // '') } @$releases ];
    }
    elsif ($sort eq 'confidence') {
        return [ sort { ($b->{confidence} // 0) <=> ($a->{confidence} // 0) } @$releases ];
    }

    # default: release_date, newest first
    return [ sort { ($b->{release_date} // '') cmp ($a->{release_date} // '') } @$releases ];
}

# ---------------------------------------------------------------------------
# Helper to pick the first available value from a list of candidate keys
# ---------------------------------------------------------------------------
sub _pickValue {
    my ($rel, @keys) = @_;

    for my $key (@keys) {
        my $value = $rel->{$key};
        return $value if defined $value && $value ne '';
    }

    return '';
}

sub _displayType {
    my ($rel) = @_;

    my @parts;
    my $primary = _pickValue($rel, 'release_group_primary_type', 'release_type', 'type');
    $primary = _formatTypeName($primary) if $primary ne '';
    push @parts, $primary if $primary ne '';

    my $secondary = _secondaryType($rel);
    if ($secondary ne '') {
        my $formatted = _formatTypeName($secondary);
        push @parts, $formatted if $formatted ne '';
    }

    return join(' / ', @parts);
}

sub _formatTypeName {
    my ($value) = @_;
    return '' unless defined $value;
    $value =~ s/^\s+//;
    $value =~ s/\s+$//;
    return '' if $value eq '';
    return ucfirst(lc($value));
}

# ---------------------------------------------------------------------------
# Detect Various Artists releases
# ---------------------------------------------------------------------------
sub _isVariousArtists {
    my $rel = shift;

    # Check artist credit name
    my $artist = lc($rel->{artist_credit_name} // '');
    return 1 if $artist eq 'various artists';

    # Check artist MBIDs if present
    my $mbids = $rel->{artist_mbids} // [];
    if (ref $mbids eq 'ARRAY') {
        for my $mbid (@$mbids) {
            return 1 if lc($mbid) eq VA_MBID;
        }
    }

    return 0;
}

# ---------------------------------------------------------------------------
# Blocked artists — a purely local filter (no ListenBrainz API exists for it).
# The pref is an arrayref of { mbid => '<artist MBID or ''>', name => '<display>' }.
# A release is hidden if ANY of its artist_mbids is blocked OR its normalised
# artist credit name matches a blocked name (the name catch covers feed rows
# that carry a different/no MBID; the MBID catch covers credit-name variants).
# ---------------------------------------------------------------------------

# Read the pref once and split into fast lookup sets of blocked MBIDs and names.
sub _blockedSet {
    my $list = $prefs->get('blocked_artists');
    $list = [] unless ref $list eq 'ARRAY';

    my (%mbids, %names);
    for my $e (@$list) {
        next unless ref $e eq 'HASH';
        $mbids{ lc $e->{mbid} } = 1 if $e->{mbid};
        $names{ _norm($e->{name}) } = 1 if defined $e->{name} && length $e->{name};
    }
    return { mbids => \%mbids, names => \%names };
}

# Is this release by a blocked artist? $set is a _blockedSet() result.
sub _isBlocked {
    my ($rel, $set) = @_;
    return 0 unless $set && (%{ $set->{mbids} } || %{ $set->{names} });

    my $mbids = $rel->{artist_mbids};
    if (ref $mbids eq 'ARRAY') {
        for my $m (@$mbids) {
            return 1 if $m && $set->{mbids}{ lc $m };
        }
    }

    my $name = _norm(_pickValue($rel, 'artist_credit_name', 'artist_name', 'artist'));
    return 1 if length $name && $set->{names}{$name};

    return 0;
}

# Add the release's artist to the blocklist (idempotent). Records the first
# non-Various-Artists MBID (when present) plus the display name. Returns the
# display name for the confirmation message.
sub _blockArtist {
    my ($rel) = @_;

    my $name = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist');
    my $mbid = '';
    my $mbids = $rel->{artist_mbids};
    if (ref $mbids eq 'ARRAY') {
        for my $m (@$mbids) {
            next if !$m || lc($m) eq VA_MBID;
            $mbid = $m;
            last;
        }
    }

    my $list = $prefs->get('blocked_artists');
    $list = [] unless ref $list eq 'ARRAY';

    my $norm = _norm($name);
    for my $e (@$list) {
        next unless ref $e eq 'HASH';
        return $name if $mbid && $e->{mbid} && lc($e->{mbid}) eq lc($mbid);
        return $name if !$mbid && length $norm && _norm($e->{name}) eq $norm;
    }

    push @$list, { mbid => $mbid, name => $name };
    $prefs->set('blocked_artists', $list);
    $log->info("blocked artist: $name" . ($mbid ? " ($mbid)" : ''));

    return $name;
}

# ---------------------------------------------------------------------------
# Build OPML items from release array
# ---------------------------------------------------------------------------
# The requesting client's "features" string, read from the top feed's request
# params (e.g. Material sends "features:hi").
sub _featuresOf {
    my ($args) = @_;
    return (ref $args->{params} eq 'HASH') ? ($args->{params}{features} // '') : '';
}

# True when the client advertises support for the "header" item type ('h' in
# features). Material renders such items bold/accent-coloured (and can use a grid
# view); other skins get plain text dividers instead.
sub _wantHeaders {
    my ($features) = @_;
    return (defined $features && $features =~ /h/) ? 1 : 0;
}

sub _buildItems {
    my ($releases, $client, $headers) = @_;

    unless ($releases && scalar @$releases) {
        return [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }];
    }

    my $sort = $prefs->get('sort') // 'release_date';

    # Return the whole (already filtered + sorted) list as a single level and let
    # LMS/Material window it natively — so Material's in-list filter spans every
    # item, not just one page, and we get the native scroll/prev-next pager.
    if ($prefs->get('week_dividers') && $sort eq 'release_date') {
        # weekly view takes precedence for the date sort (it's the chronological read)
        return _buildWeekly($releases, $client, $headers);
    }
    elsif ($prefs->get('group_by_artist')) {
        return _buildGrouped($releases, $client);
    }

    return [ map { _buildReleaseItem($_, $client) } @$releases ];
}

# ---------------------------------------------------------------------------
# All Releases landing menu: instead of dropping straight into the full list,
# offer "All releases" (the complete weekly/grouped view) plus one entry per
# week-commencing, so the feed can be narrowed to a single week. Each week entry
# drills into just that week's releases. Weeks run newest-first (the input is
# already date-sorted) and carry a release count.
# ---------------------------------------------------------------------------
sub _buildAllLanding {
    my ($releases, $client, $headers) = @_;

    unless ($releases && scalar @$releases) {
        return [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }];
    }

    # "All releases" → the full list with the user's usual weekly/grouped view.
    my @items = ({
        name        => cstring($client, 'PLUGIN_LBF_VIEW_ALL'),
        type        => 'link',
        image       => MENU_ALL,
        passthrough => [{}],
        url         => sub {
            my ($c, $cb) = @_;
            $cb->({ items => _buildItems($releases, $c, $headers) });
        },
    });

    # Group into weeks (input already date-sorted → same-week rows are adjacent
    # and week order is preserved).
    my @order;
    my %bucket;
    for my $rel (@$releases) {
        my $ws = _weekStart($rel->{release_date} // '');
        push @order, $ws unless exists $bucket{$ws};
        push @{ $bucket{$ws} }, $rel;
    }

    for my $ws (@order) {
        my $rels  = $bucket{$ws};
        push @items, {
            name        => _weekLabel($client, $ws),
            type        => 'link',
            image       => _weekBadgeImage($ws),
            passthrough => [{}],
            url         => sub {
                my ($c, $cb) = @_;
                $cb->({ items => [ map { _buildReleaseItem($_, $c) } @$rels ] });
            },
        };
    }

    return \@items;
}

# ---------------------------------------------------------------------------
# Flat date-sorted list with a divider row at the start of each week, so the
# chronological feed is easier to scan. Assumes releases are already sorted
# newest-first; weeks run Monday–Sunday.
# ---------------------------------------------------------------------------
sub _buildWeekly {
    my ($releases, $client, $headers) = @_;

    # Real header item for Material (bold, accent colour); plain text elsewhere.
    my $divType = $headers ? 'header' : 'text';

    # Group into weeks (input is already date-sorted, so same-week rows are
    # adjacent and week order is preserved).
    my @order;
    my %bucket;
    for my $rel (@$releases) {
        my $ws = _weekStart($rel->{release_date} // '');
        push @order, $ws unless exists $bucket{$ws};
        push @{ $bucket{$ws} }, $rel;
    }

    my @items;
    for my $ws (@order) {
        my $rels = $bucket{$ws};

        # Give the header an image. Material's grid detection counts headers too
        # (older versions: image-less item → haveWithoutIcons → grid/list toggle
        # disabled for the whole page). With every item carrying an image the grid
        # view stays available, and the header still renders as a divider. (Same
        # approach as the Listen to Later plugin.)
        my $hdr = { name => _weekLabel($client, $ws), type => $divType, image => ICON };
        if ($headers) {
            # Material renders header items with a drill action that XMLBrowser
            # forces on (can't be suppressed); rather than lead nowhere, point it
            # at this week's releases (same coderef pattern as _buildGrouped).
            $hdr->{url} = sub {
                my ($c, $cb) = @_;
                $cb->({ items => [ map { _buildReleaseItem($_, $c) } @$rels ] });
            };
            $hdr->{passthrough} = [{}];
        }

        push @items, $hdr;
        push @items, map { _buildReleaseItem($_, $client) } @$rels;
    }

    return \@items;
}

# Monday (YYYY-MM-DD) of the week containing $date, or '' if unparseable. Works
# on a local calendar date (use noon so a whole-day subtraction can't cross a date
# boundary even across a DST change). The result is the same regardless of zone for
# a date-only input — the weekday of a calendar date is timezone-independent — but
# computing it in local time keeps the whole date path consistent with "today".
sub _weekStart {
    my ($date) = @_;
    return '' unless $date && $date =~ /^(\d{4})-(\d{2})-(\d{2})/;

    my $epoch = eval { Time::Local::timelocal(0, 0, 12, $3, $2 - 1, $1) };
    return '' unless defined $epoch;

    my $wday = (localtime $epoch)[6];       # 0 = Sunday
    my $mon  = $epoch - (($wday + 6) % 7) * 86400;
    my @m    = localtime $mon;
    return sprintf('%04d-%02d-%02d', $m[5] + 1900, $m[4] + 1, $m[3]);
}

# Pick the All Releases week cover by how many weeks $ws (a Monday) is from the
# current week. Past: 0 → This Week, 1 → Last Week, ≥2 → Earlier. Future (negative,
# shown when "Include Upcoming" is on): -1 → Next Week, -2 → Next Fortnight,
# ≤-3 → Further (on the "Future Releases" cover). Falls back to the plain branded
# cover if the date can't be parsed.
sub _weekBadgeImage {
    my ($ws) = @_;
    return MENU_ALL unless $ws =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my $wsEpoch = eval { Time::Local::timelocal(0, 0, 12, $3, $2 - 1, $1) };
    return MENU_ALL unless defined $wsEpoch;

    my @n = localtime(time);
    my $curWs = _weekStart(sprintf('%04d-%02d-%02d', $n[5] + 1900, $n[4] + 1, $n[3]));
    return MENU_ALL unless $curWs =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my $curEpoch = Time::Local::timelocal(0, 0, 12, $3, $2 - 1, $1);

    # Positive = weeks in the past, negative = weeks in the future.
    my $weeks = int(($curEpoch - $wsEpoch) / (7 * 86400) + ($curEpoch >= $wsEpoch ? 0.5 : -0.5));
    return $weeks <= -3 ? AR_FURTHER
         : $weeks == -2 ? AR_FORTNIGHT
         : $weeks == -1 ? AR_NEXT
         : $weeks ==  0 ? AR_THIS
         : $weeks ==  1 ? AR_LAST
         :                AR_EARLIER;
}

# Week-commencing label for a week-start (Monday) date, e.g. "W/C 8 June 2026".
sub _weekLabel {
    my ($client, $ws) = @_;
    return cstring($client, 'PLUGIN_LBF_WEEK_UNKNOWN') unless $ws =~ /^\d{4}-\d{2}-\d{2}$/;
    return cstring($client, 'PLUGIN_LBF_WEEK_COMMENCING') . ' ' . _fmtDate($ws);
}

# Date / date-span formatting for the menu (no abbreviations: "8 June 2026").
my @MONTHS = qw(January February March April May June July August September October November December);

# "8 June 2026" from a YYYY-MM-DD string ('' if unparseable).
sub _fmtDate {
    my ($d) = @_;
    return '' unless ($d // '') =~ /^(\d{4})-(\d{2})-(\d{2})/;
    return sprintf('%d %s %d', $3 + 0, $MONTHS[$2 - 1], $1);
}

# A date span "8 – 20 June 2026" (collapsing a shared month/year), or a single
# date when min==max. Inputs are YYYY-MM-DD; min is the earliest.
sub _dateSpan {
    my ($min, $max) = @_;
    return _fmtDate($min) if !length($max // '') || $min eq $max;

    my ($y1, $m1, $d1) = $min =~ /^(\d{4})-(\d{2})-(\d{2})/ or return _fmtDate($max);
    my ($y2, $m2, $d2) = $max =~ /^(\d{4})-(\d{2})-(\d{2})/ or return _fmtDate($min);

    if ($y1 == $y2 && $m1 == $m2) {
        return sprintf("%d \x{2013} %d %s %d", $d1 + 0, $d2 + 0, $MONTHS[$m2 - 1], $y2);
    }
    elsif ($y1 == $y2) {
        return sprintf("%d %s \x{2013} %d %s %d",
            $d1 + 0, $MONTHS[$m1 - 1], $d2 + 0, $MONTHS[$m2 - 1], $y2);
    }
    return _fmtDate($min) . " \x{2013} " . _fmtDate($max);
}

# The date window implied by the user's settings for a section, used as the tile
# subtitle until a real feed summary is cached. past → back $days; future →
# forward $days; both → either side; neither → today only.
sub _windowSpan {
    my ($which) = @_;
    my $days   = $prefs->get('days') // 14;
    my $prefix = $which eq 'user' ? 'foryou' : 'all';
    my $past   = $prefs->get("${prefix}_past")   // 1;
    my $future = $prefs->get("${prefix}_future") // 0;

    my $now    = time;
    my $startE = $past   ? $now - ($days - 1) * 86400 : $now;
    my $endE   = $future ? $now + ($days - 1) * 86400 : $now;
    return _dateSpan(_ymd($startE), _ymd($endE));
}

sub _ymd {
    my @t = localtime(shift);
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

# Convert an ISO-8601 last_modified value to the server's LOCAL calendar date
# (YYYY-MM-DD). ListenBrainz sends this as a UTC instant (e.g. "2026-06-15T23:30:00+00:00"),
# so a date-with-time is interpreted as UTC and converted to local — otherwise the
# W/C / Daily-Jams label could show the UTC day, which is a day (or week) off from
# the user's local day near midnight (notably UK during BST). A date-only value has
# no instant to convert, so it's returned as-is. '' when unparseable.
sub _isoToLocalDate {
    my ($iso) = @_;
    return '' unless defined $iso && length $iso;

    if (my ($y, $mo, $d, $h, $mi, $s) =
            $iso =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/) {
        my $epoch = eval { Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y) };
        return _ymd($epoch) if defined $epoch;
    }
    return ($iso =~ /^(\d{4}-\d{2}-\d{2})/) ? $1 : '';
}

# ---------------------------------------------------------------------------
# Group releases under their artist (New Music Tracker style). Artists with a
# single release stay inline; artists with several collapse into one tappable
# entry that lists their releases. Artist order follows the chosen sort (first
# appearance), so e.g. a date sort keeps the freshest artists at the top.
# ---------------------------------------------------------------------------
sub _buildGrouped {
    my ($releases, $client) = @_;

    my @order;
    my %bucket;
    for my $rel (@$releases) {
        my $key = lc(_pickValue($rel, 'artist_credit_name', 'artist_name', 'artist'));
        push @order, $key unless exists $bucket{$key};
        push @{ $bucket{$key} }, $rel;
    }

    my @items;
    for my $key (@order) {
        my $rels = $bucket{$key};

        if (scalar @$rels == 1) {
            push @items, _buildReleaseItem($rels->[0], $client);
            next;
        }

        my $artist = _pickValue($rels->[0], 'artist_credit_name', 'artist_name', 'artist') // 'Unknown Artist';
        my $image  = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rels->[0]) // ICON;
        my $count  = scalar @$rels;

        push @items, {
            name  => "$artist  ($count)",
            type  => 'link',
            image => $image,
            url   => sub {
                my ($client, $callback) = @_;
                $callback->({ items => [ map { _buildReleaseItem($_, $client) } @$rels ] });
            },
        };
    }

    return \@items;
}

# ---------------------------------------------------------------------------
# Build a single OPML item from one release
# ---------------------------------------------------------------------------
sub _buildReleaseItem {
    my ($rel, $client) = @_;

    my $artist     = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') // 'Unknown Artist';
    my $album      = _pickValue($rel, 'release_name', 'title', 'name') // 'Unknown Album';
    my $date       = $rel->{release_date} // '';
    my $type       = _displayType($rel);   # includes the secondary type, e.g. "Album / Live"
    my $mbid       = $rel->{release_mbid} // '';
    my $conf       = $rel->{confidence};

    my $year = ($date =~ /^(\d{4})/) ? $1 : '';
    my $name = "$artist \x{2013} $album";
    $name .= " ($year)" if $year;

    my $line2 = $type;
    # Genre/style tags ride along in the payload (release_tags) — show up to 3
    # next to the title. Coverage is partial (~20%) and tag-only, so many rows
    # legitimately have none; no extra API call is made.
    my @tags = _releaseTags($rel);
    if (@tags) {
        my $max = $#tags < 2 ? $#tags : 2;
        $line2 .= " \x{00B7} " . join(', ', @tags[0..$max]);
    }
    if (defined $conf) {
        my $stars = $conf >= 3 ? "\x{2605}\x{2605}\x{2605}"
                  : $conf == 2 ? "\x{2605}\x{2605}"
                  :              "\x{2605}";
        $line2 .= "  $stars";
    }

    my $image = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel) // ICON;

    my $item = {
        name  => $name,
        line2 => $line2,
        type  => 'text',
        image => $image,
    };

    if ($mbid) {
        $item->{type} = 'link';
        $item->{url}  = sub {
            my ($client, $callback) = @_;
            _releaseDetail($rel, $client, $callback);
        };
    }

    return $item;
}

# ---------------------------------------------------------------------------
# Release detail page — base metadata, then (in parallel) directly-playable
# streaming matches and the MusicBrainz genres + tracklist, merged inline.
# Either async source can fail/empty without breaking the page.
# ---------------------------------------------------------------------------
sub _releaseDetail {
    my ($rel, $client, $callback, $useH) = @_;
    $useH = 1 unless defined $useH;   # the detail page is a Material experience by default

    my $mbid   = $rel->{release_mbid}       // '';
    my $rgMbid = $rel->{release_group_mbid} // '';
    my $artist = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') // '';
    my $album  = _pickValue($rel, 'release_name', 'title', 'name') // '';
    my $artistMbid = (ref $rel->{artist_mbids} eq 'ARRAY' && @{ $rel->{artist_mbids} })
                   ? $rel->{artist_mbids}[0] : undef;

    my @streamItems;   # playable streaming matches
    my @trackItems;    # tracklist (from the release)
    my $mbGenres;      # arrayref: genres from the MusicBrainz release-group
    my $lfmGenres;     # arrayref: tags from Last.fm (fallback)
    my $bio;           # artist biography text (MAI plugin or Last.fm)
    my $artistImg;     # artist photo url (MAI only)

    my $wantStream = ($prefs->get('play_via') && length $album && _orderedAdapters()) ? 1 : 0;
    my $wantGenres = $rgMbid ? 1 : 0;
    my $wantLastfm = ($prefs->get('lastfm_api_key') && (length $artist || length $album)) ? 1 : 0;
    my $wantTracks = $mbid   ? 1 : 0;
    my $wantArtist = length $artist ? 1 : 0;

    # Count all tasks up front: a cache hit completes its callback synchronously,
    # so per-task incrementing could let the barrier fire after the first one
    # finishes (before the others launched) and drop their data.
    my $pending = $wantStream + $wantGenres + $wantLastfm + $wantTracks + $wantArtist;
    my $done    = 0;

    my $finish = sub {
        my ($force) = @_;
        return if $done;
        return if !$force && $pending > 0;   # $force (watchdog) renders regardless
        $done = 1;
        # One "Genres" line: prefer curated MusicBrainz genres, fall back to
        # Last.fm tags (MB is usually empty for fresh releases).
        my $g = (ref $mbGenres  eq 'ARRAY' && @$mbGenres)  ? $mbGenres
              : (ref $lfmGenres eq 'ARRAY' && @$lfmGenres) ? $lfmGenres
              :                                              undef;
        my @genreItems = $g
            ? ({ name => cstring($client, 'PLUGIN_LBF_GENRES') . ': ' . join(', ', @$g), type => 'text' })
            : ();

        # Three Material sections, Streaming first: Streaming (matches + refresh),
        # Artist (photo + bio + block), Album (metadata + genres + tracklist, then
        # the MB link at the end). A section is emitted only if it has rows;
        # _sectionHeader gives a plain text divider when $useH is false.
        my @streamRows = @streamItems;
        my @artistRows = _artistRows($rel, $client, $artistImg, $bio);
        my @albumRows  = (_albumRows($rel, $client), @genreItems, @trackItems, _mbLink($rel, $client));

        my @items;
        push @items, _sectionHeader($client, 'PLUGIN_LBF_SECTION_STREAMING', $useH, \@streamRows, 1), @streamRows if @streamRows;
        push @items, _sectionHeader($client, 'PLUGIN_LBF_SECTION_ARTIST',    $useH, \@artistRows, 1), @artistRows if @artistRows;
        push @items, _sectionHeader($client, 'PLUGIN_LBF_SECTION_ALBUM',     $useH, \@albumRows,  1), @albumRows  if @albumRows;

        # cachetime => 0: don't let Material cache the detail page per-player, or a
        # Refresh (which clears the server-side play-via cache) — and any change to
        # streaming matches / settings — won't show until the client cache expires.
        # Same per-player staleness class fixed for the listing feeds in 0.9.25.
        $callback->({ items => \@items, cachetime => 0 });
    };

    unless ($pending) {
        my @artistRows = _artistRows($rel, $client, undef, undef);
        my @albumRows  = (_albumRows($rel, $client), _mbLink($rel, $client));
        my @items;
        push @items, _sectionHeader($client, 'PLUGIN_LBF_SECTION_ARTIST', $useH, \@artistRows, 1), @artistRows if @artistRows;
        push @items, _sectionHeader($client, 'PLUGIN_LBF_SECTION_ALBUM',  $useH, \@albumRows,  1), @albumRows  if @albumRows;
        $callback->({ items => \@items, cachetime => 0 });   # see cachetime note above
        return;
    }

    # Watchdog: if a task never returns (network hang, partial failure), FORCE a
    # render with whatever arrived ($finish->(1) bypasses the pending check) so
    # the page can never hang the client. $finish is idempotent ($done), so a
    # normal completion makes this a no-op.
    Slim::Utils::Timers::setTimer(undef, time() + DETAIL_TIMEOUT, sub { $finish->(1) });

    # Streaming services — search automatically and show matches inline, with a
    # manual "refresh" that re-searches (bypasses the cache) for this album.
    if ($wantStream) {
        _findPlayable($client, sub {
            my $res   = shift;
            my @items = (ref $res eq 'HASH' && ref $res->{items} eq 'ARRAY') ? @{ $res->{items} } : ();
            @items    = grep { ($_->{type} // '') ne 'text' } @items;   # drop "no match" placeholders
            @streamItems = (@items);   # the section header replaces the old text label
            # "Refresh" re-renders THIS detail page in place (no navigation). It's
            # a normal link whose coderef clears the play-via cache and returns an
            # EMPTY list: Material treats an empty browse response + nextWindow
            # 'refresh' as "pop back and refresh the page" (browse-functions.js),
            # so it re-fetches the detail — which now cache-misses and re-searches.
            push @streamItems, {
                name        => cstring($client, 'PLUGIN_LBF_REFRESH'),
                type        => 'link',
                nextWindow  => 'refresh',
                passthrough => [{}],
                url         => sub {
                    my ($c, $cb) = @_;
                    $cache->remove('lbf:stream:4:' . $mbid);
                    $cb->({ items => [] });
                },
            } if $mbid;
            $pending--;
            $finish->();
        }, $artist, $album, $mbid);
    }

    # Genres — from the release-group (release-level genres are nearly always empty)
    if ($wantGenres) {
        Plugins::ListenBrainzFreshReleases::API->getReleaseGroupGenres(
            $rgMbid,
            sub { $mbGenres = shift; $pending--; $finish->(); },
            sub {
                $log->info("Release-group genres lookup failed: " . (shift // ''));
                $pending--;
                $finish->();
            },
        );
    }

    # Last.fm tags — fallback genre source (album tags, then artist tags). Only
    # runs when an API key is configured; $finish prefers MB genres over these.
    if ($wantLastfm) {
        Plugins::ListenBrainzFreshReleases::API->getLastfmTags(
            $artist, $album,
            sub { $lfmGenres = shift; $pending--; $finish->(); },
            sub { $pending--; $finish->(); },
        );
    }

    # Tracklist — from the release
    if ($wantTracks) {
        Plugins::ListenBrainzFreshReleases::API->getReleaseDetails(
            $mbid,
            sub {
                my $info = shift;

                my @media = grep { $_->{tracks} && scalar @{ $_->{tracks} } } @{ $info->{media} || [] };
                if (@media) {
                    push @trackItems, { name => cstring($client, 'PLUGIN_LBF_TRACKLIST'), type => 'text' };
                    my $multi = scalar @media > 1;
                    for my $m (@media) {
                        if ($multi) {
                            my $hdr = cstring($client, 'PLUGIN_LBF_DISC') . ' ' . ($m->{position} // '');
                            $hdr .= " ($m->{format})" if $m->{format};
                            push @trackItems, { name => $hdr, type => 'text' };
                        }
                        for my $t (@{ $m->{tracks} }) {
                            my $line = ($t->{position} ? "$t->{position}. " : '') . ($t->{title} // '');
                            $line .= '  (' . _fmtDuration($t->{length}) . ')' if $t->{length};
                            push @trackItems, { name => $line, type => 'text' };
                        }
                    }
                }

                $pending--;
                $finish->();
            },
            sub {
                $log->info("Release detail lookup failed: " . (shift // ''));
                $pending--;
                $finish->();
            },
        );
    }

    # Artist biography + photo — MAI plugin when installed, else Last.fm bio.
    # Feeds the Artist section; always graceful (guarded inside _fetchArtistInfo).
    if ($wantArtist) {
        _fetchArtistInfo($client, $artist, $artistMbid, sub {
            my $i = shift || {};
            $bio       = $i->{bio};
            $artistImg = $i->{image};
            $pending--;
            $finish->();
        });
    }
}

# Artist-section rows: the artist name (with the artist photo as a small row
# thumbnail when available), an optional biography, and the Block-this-artist
# action (or a "blocked" note). The photo/bio are fetched async in _releaseDetail.
sub _artistRows {
    my ($rel, $client, $img, $bio) = @_;

    my $artist = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') // 'Unknown Artist';

    my @rows = ({
        name => cstring($client, 'PLUGIN_LBF_ARTIST') . ": $artist",
        type => 'text',
        ($img ? (image => $img) : ()),
    });

    # Biography: a short (~2 line) preview as plain text on the page, then a
    # "Read more" link that drills in to the FULL bio (all paragraphs, no cap).
    # Material renders text rows in full, so the preview must be pre-trimmed; the
    # complete bio lives behind the drill. A short bio shows inline with no link.
    # Live feed node, so the url coderef is fine (page is returned, never cached).
    if (defined $bio && length $bio) {
        (my $oneLine = $bio) =~ s/\s+/ /g;   # collapse to one line for the preview
        if (length $oneLine > BIO_PREVIEW) {
            my $short = substr($oneLine, 0, BIO_PREVIEW);
            $short =~ s/\s+\S*$//;           # back off to a word boundary
            $short .= "\x{2026}";
            push @rows, { name => $short, type => 'text' };

            my @paras = map { { name => $_, type => 'text' } } split /\n{2,}/, $bio;
            push @rows, {
                name => cstring($client, 'PLUGIN_LBF_READ_MORE'),
                type => 'link',
                url  => sub {
                    my ($c, $cb) = @_;
                    $cb->({ items => \@paras });
                },
            };
        }
        else {
            push @rows, { name => $bio, type => 'text' };   # short enough to show inline
        }
    }

    # Block this artist (managed/unblocked on the settings page). If already
    # blocked, show a static note. Never offered for Various Artists.
    unless (_isVariousArtists($rel)) {
        if (_isBlocked($rel, _blockedSet())) {
            push @rows, { name => cstring($client, 'PLUGIN_LBF_ARTIST_BLOCKED'), type => 'text' };
        }
        else {
            push @rows, {
                name  => cstring($client, 'PLUGIN_LBF_BLOCK_ARTIST'),
                type  => 'link',
                url   => sub {
                    my ($c, $cb) = @_;
                    my $name = _blockArtist($rel);
                    $cb->({ items => [{
                        name => sprintf(cstring($c, 'PLUGIN_LBF_BLOCKED_DONE'), $name),
                        type => 'text',
                    }] });
                },
            };
        }
    }

    return @rows;
}

# Album-section rows: album / date / type / tags. Genres, the tracklist and the
# "View on MusicBrainz" link (via _mbLink) are appended after these by _releaseDetail.
sub _albumRows {
    my ($rel, $client) = @_;

    my $album = _pickValue($rel, 'release_name', 'title', 'name') // 'Unknown Album';
    my $date  = $rel->{release_date} // '';
    my $type  = _displayType($rel);   # primary + secondary, e.g. "Album / Live"

    my @rows = (
        { name => cstring($client, 'PLUGIN_LBF_ALBUM') . ": $album", type => 'text' },
        { name => cstring($client, 'PLUGIN_LBF_DATE')  . ": $date",  type => 'text' },
        { name => cstring($client, 'PLUGIN_LBF_TYPE')  . ": $type",  type => 'text' },
    );

    my @tags = _releaseTags($rel);
    push @rows, { name => cstring($client, 'PLUGIN_LBF_TAGS') . ': ' . join(', ', @tags), type => 'text' }
        if @tags;

    return @rows;
}

# The "View on MusicBrainz" link — placed at the END of the Album section (after
# the tracklist). Only built for a well-formed release MBID (it lands in a
# Material-rendered href). Returns an empty list otherwise.
sub _mbLink {
    my ($rel, $client) = @_;
    my $mbid = $rel->{release_mbid} // '';
    return () unless $mbid =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    return {
        name    => cstring($client, 'PLUGIN_LBF_VIEW_ON_MB'),
        type    => 'link',
        weblink => "https://musicbrainz.org/release/$mbid",
    };
}

# Fetch an artist biography + photo for the detail page's Artist section. Prefers
# the MAI (Music Artist Info) plugin when installed — it already aggregates bios
# and photos — and falls back to a Last.fm bio (no photo) otherwise. Calls
# $cb->({ bio => $text|undef, image => $url|undef }). Fully guarded: any MAI/HTTP
# failure degrades to "no bio / no photo" and never breaks or hangs the page (the
# _releaseDetail watchdog still applies).
sub _fetchArtistInfo {
    my ($client, $artist, $artistMbid, $cb) = @_;

    my %info;
    unless (length($artist // '')) { $cb->(\%info); return; }

    # MAI's bio/photo are plain functions ($client, $cb, $params, $args); take the
    # coderefs from ->can so we never accidentally pass the package as $client.
    my ($bioFn, $photoFn);
    my $maiOn = 0;
    eval {
        $maiOn = Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin') ? 1 : 0;
        if ($maiOn) {
            $bioFn   = Plugins::MusicArtistInfo::ArtistInfo->can('getBiography');
            $photoFn = Plugins::MusicArtistInfo::ArtistInfo->can('getArtistPhotos');
        }
        1;
    };
    $log->info(sprintf("artist-info '%s': MAI enabled=%d bioFn=%d photoFn=%d mbid=%s",
        $artist, $maiOn, (defined $bioFn ? 1 : 0), (defined $photoFn ? 1 : 0), $artistMbid // '-'));

    my $pending = 0;
    my $fired   = 0;
    my $maybeDone = sub {
        return if $fired || $pending > 0;
        $fired = 1;
        $cb->(\%info);
    };

    my $lastfmBio = sub {
        Plugins::ListenBrainzFreshReleases::API->getArtistBio($artist,
            sub { $info{bio} = shift; $pending--; $maybeDone->(); },
            sub { $pending--; $maybeDone->(); },
        );
    };

    # --- Biography: MAI first, else Last.fm ---
    $pending++;
    if ($bioFn) {
        my $ok = eval {
            $bioFn->($client, sub {
                my $items = shift || [];
                for my $it (@$items) {
                    next unless ref $it eq 'HASH';
                    my $t = $it->{name};
                    if (defined $t && length $t) {
                        $info{bio} = Plugins::ListenBrainzFreshReleases::API::_cleanBio($t);
                        last;
                    }
                }
                # MAI gave nothing usable → Last.fm (reuses the same pending slot)
                if ($info{bio}) {
                    $log->info(sprintf("artist-info '%s': MAI bio len=%d", $artist, length $info{bio}));
                    $pending--; $maybeDone->();
                }
                else {
                    $log->info("artist-info '$artist': MAI bio empty -> Last.fm");
                    $lastfmBio->();
                }
            }, {}, { artist => $artist, ($artistMbid ? (mbid => $artistMbid) : ()) });
            1;
        };
        $lastfmBio->() unless $ok;   # MAI threw → Last.fm
    }
    else {
        $lastfmBio->();
    }

    # --- Photo: MAI only ---
    if ($photoFn) {
        $pending++;
        my $ok = eval {
            $photoFn->($client, sub {
                my $photos = shift || [];
                # MAI's getArtistPhotos puts the photo URL in each item's `image`
                # key (it renders `image => $_->{url}` internally); the older `url`
                # check here was always undef, so no artist photo ever loaded.
                for my $p (@$photos) {
                    next unless ref $p eq 'HASH';
                    my $u = $p->{image} || $p->{url};
                    if ($u) { $info{image} = $u; last; }
                }
                $log->info(sprintf("artist-info '%s': MAI photos=%d image=%s",
                    $artist, scalar(@$photos), $info{image} // '-'));
                $pending--; $maybeDone->();
            }, {}, { artist => $artist, ($artistMbid ? (mbid => $artistMbid) : ()) });
            1;
        };
        unless ($ok) { $pending--; $maybeDone->(); }
    }

    $maybeDone->();   # in case everything resolved synchronously
}

# Which supported streaming-service adapters are available on this server.
# Detection is via ->can on the plugin package: it's only loaded when the
# plugin is installed+enabled, and ->can on an absent package is safe (no die).
# In scalar/boolean context this returns the count (truthy if any present).
sub _streamingAdapters {
    my @adapters;

    push @adapters, {
        name => 'Qobuz', icon => _pluginIcon('Plugins::Qobuz::Plugin'),
        run => \&_searchQobuz, runTrack => \&_searchQobuzTrack,
    } if Plugins::Qobuz::Plugin->can('getAPIHandler')
      && Plugins::Qobuz::Plugin->can('_albumItem');

    push @adapters, {
        name => 'Bandcamp', icon => _pluginIcon('Plugins::Bandcamp::Plugin'),
        run => \&_searchBandcamp, runTrack => \&_searchBandcampTrack,
    } if Plugins::Bandcamp::Plugin->can('album_list');

    push @adapters, {
        name => 'Tidal', icon => _pluginIcon('Plugins::TIDAL::Plugin'),
        run => \&_searchTidal, runTrack => \&_searchTidalTrack,
    } if Plugins::TIDAL::Plugin->can('getAPIHandler')
      && Plugins::TIDAL::Plugin->can('getAlbum')
      && Plugins::TIDAL::Plugin->can('_renderAlbum');

    return @adapters;
}

# Installed adapters in search order: ascending svc_priority_<name>, dropping any
# set to 0 (disabled). Used by _findPlayable to search one service at a time.
sub _orderedAdapters {
    my @out;
    for my $a (_streamingAdapters()) {
        my $prio = $prefs->get('svc_priority_' . lc $a->{name});
        $prio = 1 unless defined $prio;   # unknown service → still searchable
        next unless $prio > 0;
        push @out, { %$a, priority => $prio };
    }
    my @ordered = sort { $a->{priority} <=> $b->{priority} } @out;
    return @ordered;   # named array → safe count in scalar/boolean context
}

# Is a cached track match still serveable given the CURRENT service config?
# 'Library' and untagged/no-match entries always are; a streaming match is only
# usable while its service is still enabled (svc_priority > 0). Lets a service
# set to 0 stop being served from cache immediately, instead of lingering for the
# 30-day track-cache TTL.
sub _cachedSvcUsable {
    my ($svc) = @_;
    return 1 if !defined $svc || $svc eq '' || lc $svc eq 'library';
    return scalar grep { lc($_->{name}) eq lc $svc } _orderedAdapters();
}

# Detection + priority for every service we know how to integrate (installed or
# not), in display order — drives the settings page's "Streaming Services" list.
sub serviceStatus {
    my @known = (
        [ 'qobuz',    'Qobuz'    ],
        [ 'bandcamp', 'Bandcamp' ],
        [ 'tidal',    'Tidal'    ],
    );
    my %installed = map { lc($_->{name}) => 1 } _streamingAdapters();
    return [ map {
        {   key       => $_->[0],
            name      => $_->[1],
            installed => $installed{ $_->[0] } ? 1 : 0,
            priority  => $prefs->get('svc_priority_' . $_->[0]) // 0,
        }
    } @known ];
}

# The service plugin's own icon (its Material logo), used as the thumbnail on
# each result so it's clear which service it came from. Undef if unavailable.
sub _pluginIcon {
    my ($class) = @_;
    return eval { $class->_pluginDataFor('icon') } || undef;
}

# Find the release on installed streaming services and present each service's
# matching album as a directly-playable node (one tap to play / add), using
# each plugin's own search API rather than a generic search drill-down.
sub _findPlayable {
    my ($client, $callback, $artist, $album, $mbid, $force) = @_;

    my @adapters   = _orderedAdapters();
    my $albumNorm  = _norm($album);
    my $artistNorm = _norm($artist);
    # Search with normalised terms (quotes, &, commas stripped). Raw multi-artist
    # credits like 'Lee "Scratch" Perry & Mouse on Mars' otherwise make the
    # service search miss the album.
    my $query      = join(' ', grep { length } $artistNorm, $albumNorm);
    # When the album title already BEGINS with the artist name AND has more after
    # it (e.g. "Placebo RE:CREATED" by Placebo), prefixing the artist again yields
    # a doubled token ("placebo placebo re created") that some service searches
    # fail to retrieve. In that one case the title already carries the artist, so
    # search on the title alone. Self-titled releases (album == artist, e.g.
    # "Placebo"/"Placebo") have nothing after the prefix, so index() misses and
    # they keep the existing "artist album" query unchanged — no regression there.
    # _albumMatches still validates the full title + artist regardless.
    if (length $artistNorm && index($albumNorm, "$artistNorm ") == 0) {
        $query = $albumNorm;
    }
    # Octet copy for the service HTTP search (a wide-char query warns/breaks in the
    # URI layer). artistNorm/albumNorm stay as characters for _albumMatches.
    my $queryEnc   = $query;
    utf8::encode($queryEnc) if utf8::is_utf8($queryEnc);

    unless (@adapters) {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_SERVICES'), type => 'text' }] });
        return;
    }

    # Cache hit → rebuild the playable items from the stored data (no re-search).
    # Key is versioned so a change to the set of searched services / matching
    # logic invalidates stale entries (:2: matching rework, :3: added Tidal,
    # :4: decode non-Latin names so the artist disambiguator works).
    # $force (manual refresh) skips the read so the services are searched again.
    my $key = 'lbf:stream:4:' . ($mbid || _norm($query));
    utf8::encode($key) if utf8::is_utf8($key);   # octet key — non-Latin fallback can't crash md5
    if (!$force && (my $c = $cache->get($key))) {
        $log->info("play-via cache hit: $key (" . scalar(@{ $c->{items} || [] }) . " match(es))");
        $callback->({ items => _streamResult($client, _rebuildStreamItems($c->{items})) });
        return;
    }

    # Search every service in PARALLEL, but resolve to the highest-priority service
    # that matched, as soon as that's decided — i.e. once every higher-priority
    # service has come back (matched or not). Each service has its own timeout so a
    # slow/hung one is treated as "no match" and can't stall the result. The chosen
    # service's matches (or an empty result if nothing matched) are cached.
    my @result   = map { undef } @adapters;   # undef = pending, [] = miss, [..] = match
    my $resolved = 0;

    my $resolve = sub {
        return if $resolved;
        my $win;
        for my $i (0 .. $#adapters) {
            return if !defined $result[$i];     # a higher-priority service is still pending
            if (@{ $result[$i] }) { $win = $i; last; }
        }
        $resolved = 1;
        my $items = defined $win ? $result[$win] : [];
        _cacheStream($key, $items, @$items ? STREAM_FOUND_TTL : STREAM_NOMATCH_TTL);
        $log->info("play-via '$query': "
            . (defined $win ? "matched on $adapters[$win]{name} (" . scalar(@$items) . ")"
                            : "no match on any service"));
        $callback->({ items => _streamResult($client, $items) });
    };

    for my $i (0 .. $#adapters) {
        my $a    = $adapters[$i];
        my $svc  = $a->{name};
        my $icon = $a->{icon};

        my $settled = 0;
        my $settle  = sub {
            return if $settled || $resolved;
            $settled = 1;
            my @matched = (ref $_[0] eq 'ARRAY') ? @{ $_[0] } : ();
            for my $it (@matched) {
                $it->{image} = $icon if $icon;   # service logo as thumbnail
                $it->{_svc}  = $svc;             # for cache rebuild
            }
            $result[$i] = \@matched;
            $resolve->();
        };

        # Per-service timeout → treat as "no match" so it can't hold up the others.
        Slim::Utils::Timers::setTimer(undef, time() + STREAM_SVC_TIMEOUT, sub {
            return if $settled || $resolved;
            $log->warn("play-via $svc timed out");
            $settle->([]);
        });

        eval { $a->{run}->($client, $queryEnc, $artistNorm, $albumNorm, $svc, $settle); 1 } or do {
            $log->warn("play-via $svc failed: $@");
            $settle->([]);
        };
    }
}

# Cache the matched items for a play-via key (url coderef stripped — it's
# reattached per service on read by _rebuildStreamItems). Guarded: Storable dies
# on unexpected nested coderefs/blessed refs and that must not stop the page.
sub _cacheStream {
    my ($key, $items, $ttl) = @_;
    my @store = map { my %x = %$_; delete $x{url}; \%x } @$items;
    eval { $cache->set($key, { items => \@store }, $ttl); 1 }
        or $log->warn("play-via cache set failed: $@");
}

# Collapse duplicate streaming entries — some services (seen with Bandcamp)
# return the same album twice. Key on service + display name + subtitle so true
# duplicates merge, but genuinely different editions (which differ in the name,
# e.g. "(Hi-Res)" vs "(Album)") are both kept.
sub _dedupeStreamItems {
    my ($items) = @_;
    my (%seen, @out);
    for my $it (@{ $items || [] }) {
        my $key = join('|',
            lc($it->{_svc}  // ''),
            lc($it->{name}  // ''),
            lc($it->{line2} // ''));
        next if $seen{$key}++;
        push @out, $it;
    }
    return \@out;
}

# Wrap matched items for display, or a "no match" placeholder when empty.
sub _streamResult {
    my ($client, $items) = @_;
    $items = _dedupeStreamItems($items);
    $items = [ @{$items}[0 .. STREAM_MAX_RESULTS - 1] ] if @$items > STREAM_MAX_RESULTS;
    return @$items
        ? $items
        : [{ name => cstring($client, 'PLUGIN_LBF_NO_MATCH'), type => 'text' }];
}

# Rebuild playable items from cached (url-stripped) data by reattaching each
# service's native play coderef. Items whose service is no longer present are
# dropped.
sub _rebuildStreamItems {
    my ($cached) = @_;

    # Only surface matches from services the user currently has ENABLED. The cache
    # is keyed by mbid (not by service set), so a match found while e.g. Qobuz was
    # enabled would otherwise keep showing after Qobuz is disabled (svc_priority 0).
    # Filtering on read (rather than re-searching) hides it immediately without
    # re-triggering a service search — important since a service search can block.
    my %enabled = map { $_->{name} => 1 } _orderedAdapters();

    my @out;
    for my $c (@{ $cached || [] }) {
        my %item = %$c;
        my $svc  = $item{_svc} // '';

        next unless $enabled{$svc};   # service disabled in settings → drop its cached match

        if ($svc eq 'Qobuz' && Plugins::Qobuz::Plugin->can('QobuzGetTracks')) {
            $item{url} = \&Plugins::Qobuz::Plugin::QobuzGetTracks;
        }
        elsif ($svc eq 'Bandcamp' && Plugins::Bandcamp::Plugin->can('get_album')) {
            $item{url} = \&Plugins::Bandcamp::Plugin::get_album;
        }
        elsif ($svc eq 'Tidal' && Plugins::TIDAL::Plugin->can('getAlbum')) {
            $item{url} = \&Plugins::TIDAL::Plugin::getAlbum;
        }
        else {
            next;
        }

        push @out, \%item;
    }

    return \@out;
}

# Qobuz: search albums via the plugin's own API, keep title matches, and reuse
# the plugin's _albumItem so each result is a native, playable album node.
sub _searchQobuz {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect) = @_;

    my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
    unless ($api) {
        $collect->([]);
        return;
    }

    $api->search(sub {
        my $res = shift;
        my @out;
        for my $album (@{ ($res && $res->{albums} && $res->{albums}{items}) || [] }) {
            my $candArtist = ref $album->{artist} eq 'HASH' ? $album->{artist}{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title});
            push @out, Plugins::Qobuz::Plugin::_albumItem($client, $album);
        }
        $collect->(\@out);
    }, lc($query), 'albums');
}

# Bandcamp: run the plugin's combined search, keep the album results (identified
# by an album_id in their passthrough — they're already playable album nodes).
sub _searchBandcamp {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect) = @_;

    eval { require Plugins::Bandcamp::Search; 1 } or do {
        $collect->([]);
        return;
    };

    Plugins::Bandcamp::Search::search($client, sub {
        my $res = shift;
        my @out;
        for my $it (@{ ($res && $res->{items}) || [] }) {
            next unless ref $it eq 'HASH';
            my $pt = ref $it->{passthrough} eq 'ARRAY' ? $it->{passthrough}[0] : undef;
            next unless $pt && $pt->{album_id};
            next unless _albumMatches($artistNorm, $albumNorm, $pt->{artist}, $pt->{title});
            push @out, $it;
        }
        $collect->(\@out);
    }, { search => $query });
}

# Tidal: search albums via the plugin's API handler, keep title+artist matches,
# and reuse the plugin's _renderAlbum so each result is a native, playable album
# node (url => getAlbum, plus play/add/insert itemActions keyed by album id).
sub _searchTidal {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect) = @_;

    my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
    unless ($api) {
        $collect->([]);
        return;
    }

    $api->search(sub {
        my $albums = shift;   # raw album hashes (type => albums search)
        my @out;
        for my $album (@{ $albums || [] }) {
            next unless ref $album eq 'HASH';
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title});
            push @out, Plugins::TIDAL::Plugin::_renderAlbum($album);
        }
        $collect->(\@out);
    }, { type => 'albums', search => $query, limit => 20 });
}

# ===========================================================================
# Track-level matching (for the Created-for-You playlists). The album path above
# resolves to a playable ALBUM node; here each playlist track resolves to a single
# directly-playable TRACK. To keep the resolved playlist fully cacheable AND
# quantity-stable (see the 0.6.11 home-shelf lesson), we accept ONLY matches that
# carry a plain string protocol url (e.g. qobuz://<id>.flac) — no coderef url that
# Storable can't serialise and that would drop out of a cached list on revisit.
# ===========================================================================

# Resolve one playlist track to a single playable streaming-track item (or undef).
# Same ordered-adapter / per-service-timeout / first-priority-wins / versioned-cache
# shape as _findPlayable, but returns one item and enforces a string url.
sub _findPlayableTrack {
    my ($client, $callback, $artist, $title, $album, $recMbid, $force, $libMode) = @_;

    # Library-resolution mode:
    #   'first'    — try the local library before streaming (the playlist default,
    #                derived from the prefer_library pref). A library hit wins.
    #   'fallback' — streaming first; only try the library if no service matched
    #                (the DSTM radio/recommended default — favours discovery but
    #                still plays an owned-only track rather than dropping it).
    #   'never'    — streaming only; never consult the library.
    $libMode //= ($prefs->get('prefer_library') // 1) ? 'first' : 'never';

    my @adapters   = grep { $_->{runTrack} } _orderedAdapters();
    my $titleNorm  = _norm($title);
    my $artistNorm = _norm($artist);
    my $query      = join(' ', grep { length } $artistNorm, $titleNorm);
    my $queryEnc   = $query;
    utf8::encode($queryEnc) if utf8::is_utf8($queryEnc);

    # A title is the one thing we always need; missing streaming adapters is NOT
    # fatal — the library may still satisfy the track (handled below), so don't
    # bail on an empty @adapters here.
    unless (length $titleNorm) {
        $callback->(undef);
        return;
    }

    # Cache the per-track decision (item or "no match") keyed by recording MBID
    # where available, else the normalised "artist title". Versioned (:2:). The
    # non-default library modes get their own key suffix so a streaming-first
    # result can't collide with the playlist feature's library-preferring cache.
    my $key = 'lbf:track:2:' . ($recMbid || _norm($query));
    $key .= ":$libMode" unless $libMode eq 'first';
    utf8::encode($key) if utf8::is_utf8($key);
    if (!$force && (my $c = $cache->get($key))) {
        my $item = $c->{item};
        # Re-validate a cached streaming match against the CURRENT service config:
        # if its service was since disabled (svc_priority 0) or removed, ignore the
        # stale entry and re-resolve so the change takes effect immediately rather
        # than after the 30-day cache TTL. Library / no-match entries are always OK.
        if (!$item || _cachedSvcUsable($item->{_svc})) {
            $callback->($item);
            return;
        }
    }

    # Cache TTL for a resolved item: library hits can go stale on a rescan/delete,
    # so they get the short LIBRARY_TTL; a streaming match is durable.
    my $cacheItem = sub {
        my $item = shift;
        my $ttl = !$item ? TRACK_NOMATCH_TTL
                : (($item->{_svc} // '') eq 'Library') ? LIBRARY_TTL
                : TRACK_FOUND_TTL;
        eval { $cache->set($key, { item => $item }, $ttl); 1 }
            or $log->warn("track cache set failed: $@");
    };

    # 'first': a copy in the user's own LMS library short-circuits streaming
    # (instant, free, often higher quality). MBID-exact first, then artist+title.
    if ($libMode eq 'first') {
        my $local = eval { _findLocalTrack($artist, $title, $recMbid) };
        if ($local) {
            $cacheItem->($local);
            $callback->($local);
            return;
        }
    }

    # No streaming services installed (or all deprioritised) → the local library
    # is the only possible source. 'first' already tried it above and missed;
    # 'fallback' tries it now (so a no-streaming user still gets a library radio);
    # 'never' is streaming-only, so there's nothing left to do.
    unless (@adapters) {
        my $item;
        if ($libMode eq 'fallback') {
            my $local = eval { _findLocalTrack($artist, $title, $recMbid) };
            $item = $local if $local;
        }
        $cacheItem->($item);
        $callback->($item);
        return;
    }

    my @result   = map { undef } @adapters;   # undef pending, [] miss, [item] hit
    my $resolved = 0;

    my $resolve = sub {
        return if $resolved;
        my $win;
        for my $i (0 .. $#adapters) {
            return if !defined $result[$i];          # higher-priority svc still pending
            if (@{ $result[$i] }) { $win = $i; last; }
        }
        $resolved = 1;
        my $item = defined $win ? $result[$win][0] : undef;
        # 'fallback': no streaming match → try the library as a last resort.
        if (!$item && $libMode eq 'fallback') {
            my $local = eval { _findLocalTrack($artist, $title, $recMbid) };
            $item = $local if $local;
        }
        $cacheItem->($item);
        $callback->($item);
    };

    for my $i (0 .. $#adapters) {
        my $a   = $adapters[$i];
        my $svc = $a->{name};

        my $settled = 0;
        my $settle  = sub {
            return if $settled || $resolved;
            $settled = 1;
            my @matched = (ref $_[0] eq 'ARRAY') ? @{ $_[0] } : ();
            # String-url, directly-playable items only (see header note); keep the first.
            @matched = grep { defined $_->{url} && !ref $_->{url} } @matched;
            my $first = $matched[0];
            $first->{_svc} = $svc if $first;
            $result[$i] = $first ? [$first] : [];
            $resolve->();
        };

        Slim::Utils::Timers::setTimer(undef, time() + STREAM_SVC_TIMEOUT, sub {
            return if $settled || $resolved;
            $log->warn("track-match $svc timed out");
            $settle->([]);
        });

        eval { $a->{runTrack}->($client, $queryEnc, $artistNorm, $titleNorm, $album, $settle); 1 } or do {
            $log->warn("track-match $svc failed: $@");
            $settle->([]);
        };
    }
}

# Find a copy of this track in the local LMS library → a playable item (file URL),
# or undef. Tier 1: exact MusicBrainz recording MBID (tracks.musicbrainz_id), the
# most robust signal where files are MB-tagged. Tier 2: LMS's own title search,
# verified against our normalised artist+title matcher. All DB access is guarded
# so a schema/availability hiccup just falls through to streaming.
sub _findLocalTrack {
    my ($artist, $title, $recMbid) = @_;

    my $titleNorm = _norm($title);
    return undef if length $titleNorm < 2;
    my $artistNorm = _norm($artist);

    # Tier 1 — MBID exact.
    if ($recMbid) {
        my $item = eval { _localByMbid($recMbid) };
        $log->warn("local MBID lookup failed: $@") if $@;
        return $item if $item;
    }

    # Tier 2 — text search via LMS's titles query, gated by _trackMatches.
    my $item = eval { _localByText($artist, $title, $artistNorm, $titleNorm) };
    $log->warn("local text lookup failed: $@") if $@;
    return $item;
}

sub _localByMbid {
    my ($mbid) = @_;
    return undef unless $mbid && Slim::Schema->can('search');
    for my $m ($mbid, lc $mbid, uc $mbid) {
        my $tr = Slim::Schema->search('Track', { musicbrainz_id => $m })->first;
        return _localItem($tr) if $tr;
    }
    return undef;
}

sub _localByText {
    my ($artist, $title, $artistNorm, $titleNorm) = @_;

    # Let LMS tokenise/normalise the search; we re-verify candidates ourselves.
    my $term = join(' ', grep { length } $artist, $title);
    return undef unless length $term;

    my $req = Slim::Control::Request::executeRequest(undef,
        ['titles', 0, 20, "search:$term", 'tags:ula']);
    return undef unless $req;

    for my $e (@{ $req->getResult('titles_loop') || [] }) {
        next unless _trackMatches($artistNorm, $titleNorm, $e->{artist}, $e->{title});
        my $item = _localItemFromLoop($e);
        return $item if $item;
    }
    return undef;
}

# Build a playable library item from a Slim::Schema::Track row.
sub _localItem {
    my ($tr) = @_;
    return undef unless $tr;
    my $url = eval { $tr->url } or return undef;
    my $artist = eval { $tr->artistName } || eval { $tr->artist && $tr->artist->name } || '';
    my $album  = eval { $tr->album && $tr->album->title } || '';
    my $id     = eval { $tr->id };
    return _localItemHash($url, eval { $tr->title } // '', $artist, $album, $id);
}

# Build a playable library item from a 'titles' query loop entry.
sub _localItemFromLoop {
    my ($e) = @_;
    my $url = $e->{url} or return undef;
    return _localItemHash($url, $e->{title} // '', $e->{artist} // '', $e->{album} // '', $e->{id});
}

sub _localItemHash {
    my ($url, $title, $artist, $album, $id) = @_;
    my $line2 = join(" \x{2013} ", grep { defined && length } $artist, $album);
    return {
        name  => $title,
        ($line2 ne '' ? (line2 => $line2) : ()),
        type  => 'audio',
        url   => $url,
        play  => $url,
        (defined $id ? (image => "/music/$id/cover.jpg") : ()),
        _svc  => 'Library',
    };
}

# True if a candidate streaming track is the same song: title equals or
# prefix-matches ours (word boundary — tolerates " (Remastered)" etc. after
# _norm) AND the artist matches. Mirrors _albumMatches but for track titles.
sub _trackMatches {
    my ($artistNorm, $titleNorm, $candArtist, $candTitle) = @_;

    return 0 if length $titleNorm < 2;
    my $t = _norm($candTitle);
    return 0 if $t eq '';
    return 0 unless $t eq $titleNorm || index($t, "$titleNorm ") == 0;

    return $t eq $titleNorm ? 1 : 0 if $artistNorm eq '';
    return _artistMatch($artistNorm, _norm($candArtist));
}

# Qobuz: search the track index, keep title+artist matches, build a directly
# playable audio item using the Qobuz protocol url (qobuz://<id>.flac). A string
# url => the item is Storable and survives the resolved-playlist cache intact.
sub _searchQobuzTrack {
    my ($client, $query, $artistNorm, $titleNorm, $album, $collect) = @_;

    my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
    unless ($api) { $log->info("Qobuz track-match: no API handler"); $collect->([]); return; }

    $api->search(sub {
        my $res = shift;
        # Tolerate response-shape differences across Qobuz plugin versions.
        my $items = (ref $res eq 'HASH' && ref $res->{tracks} eq 'HASH' && ref $res->{tracks}{items} eq 'ARRAY')
                      ? $res->{tracks}{items}
                  : (ref $res eq 'HASH' && ref $res->{items} eq 'ARRAY') ? $res->{items}
                  : [];
        my @out;
        for my $tr (@$items) {
            next unless ref $tr eq 'HASH';
            # Qobuz exposes the artist under several fields, and the track-level
            # `performer` is often a featured/credited name rather than the main
            # artist — matching only that field rejected valid Qobuz hits and forced
            # a fall-through to Tidal. Try them ALL; accept if any matches.
            my @artists = grep { defined && length } (
                (ref $tr->{performer} eq 'HASH') ? $tr->{performer}{name} : undef,
                (ref $tr->{artist}    eq 'HASH') ? $tr->{artist}{name}    : undef,
                (ref $tr->{album} eq 'HASH' && ref $tr->{album}{artist} eq 'HASH') ? $tr->{album}{artist}{name} : undef,
            );
            next unless grep { _trackMatches($artistNorm, $titleNorm, $_, $tr->{title}) } @artists;
            my $id = $tr->{id} or next;

            my $albumName = ref $tr->{album} eq 'HASH' ? $tr->{album}{title} : '';
            my $cover;
            if (ref $tr->{album} eq 'HASH' && ref $tr->{album}{image} eq 'HASH') {
                $cover = $tr->{album}{image}{large} || $tr->{album}{image}{small};
            }
            my $url = "qobuz://$id.flac";
            push @out, {
                name  => $tr->{title},
                line2 => join(" \x{2013} ", grep { length } $artists[0], $albumName),
                type  => 'audio',
                url   => $url,
                play  => $url,
                image => $cover,
            };
        }
        $log->info("Qobuz track-match '$query': " . scalar(@$items) . " results, " . scalar(@out) . " matched");
        $collect->(\@out);
    }, lc($query), 'tracks');
}

# Tidal: search the track index, keep title+artist matches. We only adopt a match
# if the plugin's track renderer yields a plain string play url (kept for cache
# stability); otherwise treat as no match. (Renderer/protocol confirmed on server.)
sub _searchTidalTrack {
    my ($client, $query, $artistNorm, $titleNorm, $album, $collect) = @_;

    my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
    unless ($api) { $collect->([]); return; }

    $api->search(sub {
        my $tracks = shift;
        my @out;
        for my $tr (@{ $tracks || [] }) {
            next unless ref $tr eq 'HASH';
            my $artistRef  = $tr->{artist} || ($tr->{artists} && $tr->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _trackMatches($artistNorm, $titleNorm, $candArtist, $tr->{title});

            my $item = Plugins::TIDAL::Plugin->can('_renderTrack')
                ? eval { Plugins::TIDAL::Plugin::_renderTrack($tr) } : undef;
            next unless ref $item eq 'HASH' && defined $item->{url} && !ref $item->{url};
            push @out, $item;
        }
        $log->info("Tidal track-match '$query': " . scalar(@{ $tracks || [] }) . " results, " . scalar(@out) . " matched");
        $collect->(\@out);
    }, { type => 'tracks', search => $query, limit => 20 });
}

# Bandcamp: its search is album/track-mixed and individual-track streaming isn't a
# stable string-url path, so track matching is a no-op for now (album matching is
# unaffected). Left as a clearly-marked hook to fill in once confirmed on server.
sub _searchBandcampTrack {
    my ($client, $query, $artistNorm, $titleNorm, $album, $collect) = @_;
    $collect->([]);
}

# True if a streaming result is the same release: the candidate title must BE our
# album title, or START with it (tolerates " (Deluxe)", " EP", " (Hi-Res)" etc.
# after _norm), AND the candidate artist must match ours (the disambiguator —
# without it, similar titles by unrelated artists slip through). Artist matches in
# either direction to tolerate "feat."/credit variations. With no artist, title
# alone. NB: we require a leading-prefix (not a substring) match — the album name
# appearing mid-title was a common false positive, e.g. our "Apollo" by "Gene"
# wrongly matching "Friendship 7 to Apollo 11…". The trailing space is a word
# boundary so "Apollo" doesn't match "Apollonia".
sub _albumMatches {
    my ($artistNorm, $albumNorm, $candArtist, $candTitle) = @_;

    return 0 if length $albumNorm < 2;
    my $t = _norm($candTitle);
    return 0 if $t eq '';
    return 0 unless $t eq $albumNorm || index($t, "$albumNorm ") == 0;

    # No artist to disambiguate with → only an EXACT title match counts; otherwise
    # a generic one-word title ("Prism") prefix-matches dozens of unrelated albums.
    return $t eq $albumNorm ? 1 : 0 if $artistNorm eq '';
    return _artistMatch($artistNorm, _norm($candArtist));
}

# Artist match tolerant of word order, connectors and partial credits: every
# word of the shorter artist name must appear in the longer (token subset).
# Handles 'lee scratch perry mouse on mars' vs 'lee scratch perry mouse on mars'
# (& vs , normalise the same) and vs just one of the collaborators.
sub _artistMatch {
    my ($a, $b) = @_;
    return 0 if $a eq '' || $b eq '';

    my %at = map { ($_ => 1) } split ' ', $a;
    my %bt = map { ($_ => 1) } split ' ', $b;
    my ($small, $big) = (scalar keys %at <= scalar keys %bt) ? (\%at, \%bt) : (\%bt, \%at);

    for my $tok (keys %$small) {
        return 0 unless $big->{$tok};
    }
    return 1;
}

# Normalise a title/artist for fuzzy matching: lowercase, drop bracketed
# qualifiers (deluxe/remaster/etc.) and punctuation, collapse whitespace.
# Keeps alphanumerics from ANY script (\p{Alnum}, not just a-z0-9) so non-Latin
# artist/album names (e.g. Japanese "踊ってばかりの国") survive — otherwise they
# normalised to "" and matching fell back to title-only (one search returned 48).
sub _norm {
    my $s = shift // '';
    # Names often arrive as UTF-8 *octets* (no utf8 flag) via the Storable cache or
    # the play passthrough. On the server's Perl, \p{Alnum} then strips every byte
    # of a non-Latin name, so the artist normalised to '' and matching fell back to
    # title-only (a generic "Prism" matched dozens of unrelated albums). Decode to
    # real characters first so \p{Alnum} sees codepoints and the name survives.
    if (!utf8::is_utf8($s) && $s =~ /[^\x00-\x7f]/) {
        my $d = $s;
        $s = $d if utf8::decode($d);   # only adopt it if it's valid UTF-8
    }
    $s = lc($s);
    $s =~ s/[\(\[].*?[\)\]]//g;
    $s =~ s/[^\p{Alnum}]+/ /g;
    $s =~ s/^\s+|\s+$//g;
    $s =~ s/\s+/ /g;
    return $s;
}

# Extract usable tag names from the payload's release_tags. Entries may be plain
# strings or { tag, count } hashes; drop blanks, dedupe case-insensitively, and
# drop the over-long free-text junk ("adding tags for album ...") that isn't a genre.
sub _releaseTags {
    my ($rel) = @_;

    my $tags = $rel->{release_tags};
    return () unless ref $tags eq 'ARRAY';

    my @out;
    my %seen;
    for my $t (@$tags) {
        my $name = ref $t eq 'HASH' ? $t->{tag} : $t;
        next unless defined $name;
        $name =~ s/^\s+//; $name =~ s/\s+$//;
        next if $name eq '' || length($name) > 30;
        next if $seen{ lc $name }++;
        push @out, $name;
    }

    return @out;
}

# Format a millisecond track length as m:ss
sub _fmtDuration {
    my ($ms) = @_;
    return '' unless $ms;
    my $secs = int($ms / 1000 + 0.5);
    return sprintf('%d:%02d', int($secs / 60), $secs % 60);
}

1;
