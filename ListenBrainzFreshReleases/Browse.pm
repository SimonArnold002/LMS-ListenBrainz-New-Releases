package Plugins::ListenBrainzFreshReleases::Browse;

use strict;
use warnings;

use Time::Local ();
use Time::HiRes ();
use Digest::MD5 ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Utils::Timers;
use Slim::Utils::Strings qw(cstring string);

use Plugins::ListenBrainzFreshReleases::API;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');
my $cache = Slim::Utils::Cache->new();

# Per-player section paging state for the All Releases per-week lists:
# { <client-id> => { <section-key> => shown-count } }. Module-level so it
# survives the cachetime=>0 re-walk a "Show more" tap triggers (the tap uses
# nextWindow=>'refresh', which re-fetches the level from the top; the count the
# tap stored here is what makes the rebuild render the grown page).
my %pageState;
sub _cid { my ($client) = @_; return $client ? $client->id : '_none' }

# Route warm/resolve lifecycle events through the plugin's dedicated debug log
# (server.log at info always; lbf-debug.log too when the debug_log pref is on).
sub _dbg { Plugins::ListenBrainzFreshReleases::Plugin::dbg(@_) }

# How long to remember a streaming-match result before searching again.
# A found match rarely changes (albums don't vanish) → keep a week. A "no match"
# on a brand-new release is likely to change soon (it may land on the service in
# a few days) → recheck daily.
use constant STREAM_FOUND_TTL   => 7 * 86400;
use constant STREAM_NOMATCH_TTL => 1 * 86400;
# A no-match where a service couldn't even be QUERIED (no API handler at search
# time, a timeout, an error, or a broken/changed renderer that produced nothing
# from a real match) is inconclusive — NOT a confirmed miss. Cache it only briefly
# so it retries soon, rather than pinning a transient outage as "no match" for the
# day. Mirrors the track path's TRACK_INCONCLUSIVE_TTL.
use constant STREAM_INCONCLUSIVE_TTL => 1 * 3600;
# A manually-found Bandcamp match persists much longer (and in its own key): it's
# the only way a Bandcamp-only release becomes playable, so it shouldn't quietly
# expire and force a re-search. Re-tapping (after a Refresh) refreshes it.
use constant BC_MATCH_TTL       => 30 * 86400;
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
# A no-match where a streaming service couldn't even be QUERIED (API handler not
# ready at resolve time, timeout, or error) is inconclusive — NOT a real miss.
# Cache it only briefly so it retries soon instead of locking in a false "no
# match" for the full week. (This is what left a playlist stuck on local-only
# when its warm resolve ran before the streaming plugins' auth was ready.)
use constant TRACK_INCONCLUSIVE_TTL => 1 * 3600;
# How far ahead to keep MuSpy upcoming releases in the For You merge. MuSpy is a
# small, user-curated follow list whose whole point is upcoming releases, so its
# future side has its own toggle (muspy_future, default ON) rather than riding the
# LB feed's foryou_future — and its own limit (muspy_future_months, default 12) so
# it can't run away. The cap is expressed in whole months; MUSPY_FUTURE_MONTHS_* are
# the pref's default/clamp bounds (a stray/garbage pref can't push the window insane).
use constant MUSPY_FUTURE_MONTHS_DEFAULT => 12;
use constant MUSPY_FUTURE_MONTHS_MAX     => 24;
# Resolved whole-playlist cache. The JSPF content is IMMUTABLE for a given
# mbid|last_modified, so there's no correctness reason to expire early — a new
# week brings a new mbid (a fresh key) which re-resolves once. The Weekly Jams/
# Exploration playlists only exist ~2 weeks (current + previous week, 14 days from
# the Monday they're created), then ListenBrainz drops them — so the cache only
# needs to survive that long; a longer TTL just leaves dead entries that are never
# requested again. 14 days covers the playlist's whole life incl. its second week.
# (Trade-off: a track that only later appears on a service isn't picked up until
# next week's playlist — an intentional choice to avoid the slow re-resolve.)
use constant PLAYLIST_FOUND_TTL   => 14 * 86400;
use constant PLAYLIST_PARTIAL_TTL => 14 * 86400;
# A resolve in which one or more tracks were inconclusive (a service couldn't be
# queried) is cached only briefly, so a list that came back stuck on local-only /
# few matches because streaming was momentarily unavailable re-resolves soon
# rather than being pinned for the full partial TTL (a month).
use constant PLAYLIST_INCONCLUSIVE_TTL => 1 * 3600;
# Max tracks resolved in parallel — bounds the burst of service searches a 50-track
# playlist would otherwise fire all at once (rate-limit friendliness).
use constant PLAYLIST_CONCURRENCY => 6;
# Overall watchdog for resolving a playlist, so a hung service search can't leave
# the playlist page spinning forever.
use constant PLAYLIST_TIMEOUT => 45;
# The top-level menu inlines the All Releases weeks from an async feed fetch (usually a
# cache hit → synchronous). On a cold miss a slow ListenBrainz would otherwise hold the
# WHOLE menu (Created for You, People You Follow AND Settings) until the feed's own 10s
# timeout. This local watchdog renders the menu with the drill-tile fallback first if the
# fetch hasn't returned quickly, so navigation (esp. Settings) never waits on the network.
use constant TOPLEVEL_ALL_WAIT => 5;

# "Recommended by People You Follow" is ONE new-music list (owned tracks excluded),
# newest-first, with day dividers in the opened view. The source recs are accumulated
# into a small persisted store so a rec isn't lost once it scrolls out of the feed's
# 75-event window; history builds forward from first capture. Capped at a generous
# number of recs (they're tiny metadata) so the store can't grow without bound.
use constant FOLLOW_KEEP_MAX  => 500;
# The source store is tiny metadata (artist/title/mbid/created), so keep it well
# beyond a typical feed window — it only needs to survive quiet spells / restarts;
# each merge refreshes the TTL. 30d (not longer) — proven to persist, matching
# FEED_FALLBACK_TTL (very large TTLs weren't reliably retained by the cache).
use constant FOLLOW_STORE_TTL => 30 * 86400;
# The "seen" marker for "Play what's new" lives in a PREF, not the cache store, so it
# survives cache eviction / restarts reliably. Newest rec epoch the user has caught
# up to; 0 = never (baselined on first list render to the newest rec then).
use constant FOLLOW_SEEN_PREF => 'follow_last_seen';

# "People You Follow → Trending" — top PLAYED tracks/albums of the users you follow,
# ranked by one-follower-one-vote breadth (see _buildTrendingCandidates). Tracks:
# fan out each follower's weekly top recordings, group to albums, pick a
# representative track per album, exclude owned, cap at TRENDING_MAX. Albums lists:
# aggregate weekly/monthly/yearly top release-groups by the same breadth.
use constant TRENDING_MAX        => 50;    # final playlist cap (owned already excluded)
use constant TRENDING_CANDIDATES => 80;    # ranked candidates fed to resolve — enough head-room for
                                           # owned/unmatched attrition without streaming a big wasted tail
use constant TRENDING_RANGE      => 'week';# rolling last 7 days — "what they're all playing this week"
use constant TRENDING_PER_USER   => 60;    # equal per-follower cap (a heavy listener can't dominate);
                                           # 60 covers a week's real listening, less metadata/aggregation work
use constant TREND_MAP_CAP       => 250;   # map only the top-breadth recordings to albums — a big library
                                           # of distinct one-off plays can't trigger dozens of metadata calls
use constant TREND_RESOLVE_CONC  => 10;    # streaming-resolve parallelism for trending (> the playlist
                                           # default; the cold build's dominant cost is the per-track search)
use constant FOLLOWER_FANOUT     => 10;    # concurrent per-follower stat fetches (LB stats endpoint is
                                           # cheap — safe to parallelise more than the streaming resolve)
use constant FOLLOWER_MAX        => 250;   # cap the fan-out (and bound the async pump depth)
use constant FANOUT_DEADLINE     => 30;    # proceed with partial data if the fan-out drags (never hang the browse)
use constant FOLLOWER_STALE_DAYS => 183;   # drop followers with no listen in ~6 months from the trending builds —
                                           # a user who quit the service keeps seeding This Year with old plays
                                           # otherwise (week/month self-clean; the year window doesn't)
# Refresh cadence scales with the window each feed summarises — the data (LB
# listen-stats) only recomputes ~daily, and a month/year of trending barely moves.
# The album caches are also keyed by the current month/year (see _albumsDataKey), so
# a calendar rollover rebuilds immediately regardless of TTL.
use constant TREND_RESOLVED_TTL     => 2 * 86400;   # Weekly Tracks — rebuilt ~every 2 days
use constant TREND_ALBUMS_MONTH_TTL => 7 * 86400;   # Trending Albums · This Month — weekly
use constant TREND_ALBUMS_YEAR_TTL  => 30 * 86400;  # Trending Albums · This Year — monthly

use constant ICON => 'plugins/ListenBrainzFreshReleases/html/images/ListenBrainzFreshReleasesIcon_svg.png';

# Branded cover-style images for the top-level menu rows (same look as the
# playlist covers). The settings cog uses Material's "_MTL_icon_<name>" filename
# convention so Material renders its own themed cog font-icon; the file itself is
# a flat gear PNG fallback for non-Material skins.
use constant IMG_BASE      => 'plugins/ListenBrainzFreshReleases/html/images/';
use constant MENU_NEW      => IMG_BASE . 'menu-new-releases.png';
use constant MENU_PLAYLISTS=> IMG_BASE . 'menu-playlists.png';
use constant MENU_ALL      => IMG_BASE . 'menu-all-releases.png';
use constant MENU_FOLLOW   => IMG_BASE . 'menu-follow.png';
use constant MENU_TRENDING => IMG_BASE . 'menu-trending.png';
use constant MENU_TRENDING_ALB => IMG_BASE . 'menu-trending-albums.png';        # This Month
use constant MENU_TRENDING_ALB_YEAR => IMG_BASE . 'menu-trending-albums-year.png';  # This Year (distinct colour)
use constant MENU_COG      => IMG_BASE . 'lbf-cog_MTL_icon_settings.png';
use constant MENU_REFRESH  => IMG_BASE . 'lbf-refresh_MTL_icon_refresh.png';
use constant MENU_SORT     => IMG_BASE . 'lbf-sort_MTL_icon_sort.png';
# "Show more"/"Show less" paging rows for the All Releases per-week lists — the
# global feed can list hundreds of releases in a single week, so each week is
# capped and grown a page at a time. The _MTL_icon_<name> filename makes Material
# render its own themed unfold_more/less font-icon; the PNG is a fallback.
use constant PAGE_MORE     => IMG_BASE . 'lbf-more_MTL_icon_unfold_more.png';
use constant PAGE_LESS     => IMG_BASE . 'lbf-less_MTL_icon_unfold_less.png';
# Rows shown per All Releases week before "Show more" (and the step it grows by).
use constant PAGE_SIZE     => 30;
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

    # "People You Follow" — features driven by what the users you follow actually
    # PLAY (public listen-stats) and recommend. What's Trending + the two Trending
    # Albums lists need a username only (public endpoints); the Recommended list
    # (relocated here from Created for You) reads the private social feed, so it
    # also needs a token.
    # Master switch (default on): when off, the whole section is absent AND its warm
    # pre-build + unmatched-debug entry are skipped, so nothing here is fetched, cached
    # or warmed (the tiles' resolve coderefs are the only entry points and never render).
    my @people;
    if ($username && $prefs->get('people_follow')) {
        push @people, _trendingTile($client, $feat);
        push @people, _trendingAlbumsTile($client, 'this_month', $feat);
        push @people, _trendingAlbumsTile($client, 'this_year',  $feat);
        push @people, _followTile($client, $feat) if $token;
    }

    my @settings = ({
        name => cstring($client, 'PLUGIN_LBF_SETTINGS'), type => 'link',
        weblink => '/plugins/ListenBrainzFreshReleases/settings.html', image => MENU_COG,
    });
    # Diagnostics: list the playlist tracks that didn't resolve to any service, so a
    # matcher gap (e.g. a stylised title the service search couldn't find) is
    # visible without the web settings page (blocked off-network). Needs a username
    # (to fetch the created-for playlists).
    push @settings, {
        name  => cstring($client, 'PLUGIN_LBF_UNMATCHED'), type => 'link',
        image => MENU_COG, url => \&fetchUnmatchedPlaylists,
    } if $username;

    # --- assemble with Material section headers --------------------------
    # The static sections build synchronously; the All Releases weeks are fetched and
    # inlined DIRECTLY under their header (no intermediate tile/folder). The feed is
    # cached (24h) + warm-fetched, so this is usually instant; on a cold miss it costs
    # one fetch, and on error we fall back to the old drill tile so the menu still works.
    my @head;
    push @head, _sectionHeader($client, 'PLUGIN_LBF_SECTION_CREATED_FOR_YOU', $useH, \@createdFor), @createdFor;
    push @head, _sectionHeader($client, 'PLUGIN_LBF_SECTION_PEOPLE', $useH, \@people), @people if @people;

    my ($finished, $watchdog);
    my $finish = sub {
        my ($allRows) = @_;
        return if $finished;   # idempotent: whichever of feed / fallback / watchdog wins renders once
        $finished = 1;
        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;
        my @items = @head;
        push @items, _sectionHeader($client, 'PLUGIN_LBF_ALL_RELEASES', $useH, $allRows), @$allRows;
        push @items, _sectionHeader($client, 'PLUGIN_LBF_SECTION_SETTINGS', $useH, \@settings), @settings;
        # cachetime => 0 so Material doesn't cache the top menu per-player — keeps the
        # inlined weeks in step with the weekly rollover (same rationale as the feeds).
        $callback->({ items => \@items, cachetime => 0 });
    };

    # If the feed fetch is slow (cold cache), render the menu with the drill-tile fallback
    # so Settings et al. aren't held hostage to the network; the inlined weeks then appear
    # on the next open (the feed populates its own cache meanwhile).
    $watchdog = Slim::Utils::Timers::setTimer(undef, time() + TOPLEVEL_ALL_WAIT, sub {
        $finish->([ _categoryTile($client, 'all', MENU_ALL, \&fetchAll, $feat) ]);
    });

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
        sort   => 'release_date',
        past   => $prefs->get('all_past')   // 1,
        future => $prefs->get('all_future') // 0,
        days   => $prefs->get('days')       // 14,
        onDone => sub {
            my $releases = _sortReleases(_filterAll(shift));
            _stashSummary('all', $releases);
            # No inline Refresh row at the top level (it's cluttered there); All Releases
            # refreshes on its own 24h cadence, and each week drill has its own controls.
            $finish->([ @{ _buildAllLanding($releases, $client, $useH) } ]);
        },
        onError => sub {
            $log->error("top-level All Releases fetch error: " . (shift // ''));
            # Fall back to the drill tile so the section still works.
            $finish->([ _categoryTile($client, 'all', MENU_ALL, \&fetchAll, $feat) ]);
        },
    );
}

# Which header item-type to emit for a header-capable (Material) client.
# Material's 'header-basic' (a non-actionable, full-width divider) only exists
# from Material 6.4.3 onwards. On the newer Material dev line an ACTIONABLE
# type=>'header' is drawn as a grid CARD (mixed in with the album artwork)
# instead of a full-width divider; 'header-basic' clears the item's action so it
# renders as a plain divider again. Both skins advertise the same features string
# ('hi'), so the request can't distinguish them — check the running Material
# version server-side: use 'header-basic' iff Material >= 6.4.3 (or a non-release
# dev/test build), else the long-standing 'header' (no regression on older
# skins). Cached — the Material version can't change at runtime.
# (Same approach as the Listen to Later plugin.)
my $_headerTypeCache;
sub _headerType {
    return $_headerTypeCache if defined $_headerTypeCache;
    my $ver = eval { Plugins::MaterialSkin::Plugin->getPluginVersion() };
    my $useBasic;
    if (!defined $ver) {
        $useBasic = 0;                                                   # can't tell -> stay safe ('header')
    } elsif ($ver =~ /^(\d+)\.(\d+)\.(\d+)/) {
        $useBasic = ( $1 <=> 6 || $2 <=> 4 || $3 <=> 3 ) >= 0 ? 1 : 0;   # >= 6.4.3
    } else {
        $useBasic = 1;                                                   # dev/test build -> new type
    }
    return $_headerTypeCache = $useBasic ? 'header-basic' : 'header';
}

# A Material section-divider header. Older Material renders type=>'header'
# bold/accented but forces a drill action onto it (can't be suppressed), so — as
# with the week dividers — give it a url returning its own child items, so tapping
# the header (or its "More") shows that section rather than an empty page. On
# Material 6.4.3+ _headerType() returns 'header-basic', which strips the action
# (no grid-card) and harmlessly ignores the url. Non-Material skins get plain text.
sub _sectionHeader {
    my ($client, $stringToken, $useH, $children, $noIcon) = @_;
    # $noIcon: drop the logo thumbnail (detail-page section headers — there's
    # nothing to drill into, the rows sit right below, so the icon just adds
    # clutter). List pages keep the icon so Material's grid toggle stays enabled.
    my $hdr = {
        name  => cstring($client, $stringToken),
        type  => $useH ? _headerType() : 'text',
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
    my $mode   = $prefs->get('foryou_sort')   || 'release_date';
    my $past   = $prefs->get('foryou_past')   // 1;
    my $future = $prefs->get('foryou_future') // 0;

    # Once the LB releases are in hand, fetch the (opt-in) MuSpy releases, merge,
    # and render. MuSpy is best-effort — getMuSpyReleases always resolves onDone
    # (empty when unconfigured/unreachable), so this never blanks the feed. On an
    # LB failure we still run this with an empty LB list ($lbFailed set), so a
    # MuSpy-configured user keeps their releases through an LB outage; only when
    # BOTH yield nothing do we surface the error tile.
    my $render = sub {
        my ($lbReleases, $lbFailed) = @_;
        Plugins::ListenBrainzFreshReleases::API->getMuSpyReleases(
            onDone => sub {
                my $releases = _sortReleases(_filterForYou(_mergeMuSpy($lbReleases, shift)));
                _stashSummary('user', $releases);
                # cachetime => 0: don't let Material cache this dynamic feed per-player
                # (proven for Playlists in 0.9.24 — forces a re-fetch on each open so the
                # weekly rollover shows immediately rather than a stale cached copy).
                if ($lbFailed && !@$releases) {
                    $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }], cachetime => 0 });
                    return;
                }
                # Only when the Artist sort is active, fire a background MB warm of
                # the artists' sort-names (second-load: cold artists key on the
                # display credit this render, correct on re-entry). No MB traffic
                # for users who never pick the Artist sort.
                _warmArtistSorts($releases) if $mode eq 'artist';
                # Options section (Material header + rows) at the top: the sort
                # toggle then Refresh, like Discography/Pitchfork. The toggle sorts
                # the releases inside each W/C week; Refresh re-fetches the feed.
                my @opt   = ( _sortToggle($client, 'foryou_sort', $mode), _refreshItem($client, 'user') );
                my @items = ( _sectionHeader($client, 'PLUGIN_LBF_SECTION_OPTIONS', $headers, \@opt),
                              @opt, @{ _buildItems($releases, $client, $headers, $mode) } );
                $callback->({ items => \@items, cachetime => 0 });
            },
        );
    };

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => 'release_date',
        past    => $past,
        future  => $future,
        days    => $prefs->get('days') // 14,
        onDone  => sub { $render->(shift, 0) },
        onError => sub {
            $log->error("For You fetch error: " . (shift // ''));
            $render->([], 1);
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
    # Merge MuSpy releases in too, so the home carousel matches the main For You
    # menu (same source set, dedupe and window). MuSpy is best-effort (empty when
    # unconfigured/unreachable), so this never blanks the row.
    my $render = sub {
        my ($lbReleases) = @_;
        Plugins::ListenBrainzFreshReleases::API->getMuSpyReleases(
            onDone => sub {
                my $releases = _sortReleases(_filterForYou(_mergeMuSpy($lbReleases, shift)));
                _stashSummary('user', $releases);
                $cb->({ items => [ map { _buildReleaseItem($_, $client) } @$releases ], cachetime => 0 });
            },
        );
    };

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => 'release_date',
        past    => $prefs->get('foryou_past')   // 1,
        future  => $prefs->get('foryou_future') // 0,
        days    => $prefs->get('days')          // 14,
        onDone  => sub { $render->(shift) },
        onError => sub {
            $log->error("Home For You fetch error: " . (shift // ''));
            $render->([]);
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
        sort    => 'release_date',
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
    my $past   = $prefs->get('all_past')   // 1;
    my $future = $prefs->get('all_future') // 0;

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
        sort    => 'release_date',
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

# A "Refresh" row for the feed lists — ONE builder shared by EVERY section (the
# rule the People You Follow feeds must follow too). The feeds cache; tapping this
# clears that feed's working cache key and reloads the list IN PLACE via nextWindow
# 'refresh' (same mechanism as the detail-page streaming refresh), so the next
# render cache-misses and re-fetches fresh data. $which selects which cache to drop:
#   'user'  — New Releases for You feed   (API::clearFeedCache)
#   'all'   — All Releases feed           (API::clearFeedCache)
#   'trending'        — Weekly Tracks resolved list   (lbf:trending:resolved)
#   'trending_albums' — a Trending Albums aggregate    (lbf:trending:albums, per $range)
# The trending caches live in Browse.pm (keyed by user/service-order/period), so
# they're dropped here directly; the parent level (resolveTrending /
# resolveTrendingAlbums) then re-walks, cache-misses, and rebuilds in place — exactly
# like For You / All Releases. $range is only needed for 'trending_albums'.
sub _refreshItem {
    my ($client, $which, $range) = @_;
    return {
        name        => cstring($client, 'PLUGIN_LBF_REFRESH_FEED'),
        type        => 'link',
        image       => MENU_REFRESH,
        nextWindow  => 'refresh',
        passthrough => [{ which => $which, range => $range }],
        url         => sub {
            my ($c, $cb, $a, $pass) = @_;
            my $w = (ref $pass eq 'HASH' && $pass->{which}) ? $pass->{which} : 'user';
            if ($w eq 'trending') {
                $cache->remove(_trendingResolvedKey());
            }
            elsif ($w eq 'trending_albums') {
                my $r = (ref $pass eq 'HASH' && $pass->{range}) ? $pass->{range} : 'this_month';
                $cache->remove(_albumsDataKey($r, $prefs->get('username') // ''));
            }
            else {
                Plugins::ListenBrainzFreshReleases::API->clearFeedCache($w);
            }
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
            # A "Refresh matches" row at the top of the Playlists list, mirroring the
            # New Releases / All Releases feed refresh — forces a fresh, library-first
            # re-resolve of every playlist (recovers from an all-streaming result a
            # pre-scan warm cached). Async (~a minute); the tap confirms and re-matches
            # in the background, so it's a drill-in confirmation rather than an in-place
            # reload (unlike the feed refresh, the new matches aren't ready instantly).
            $callback->({
                items     => [
                    {
                        name  => cstring($client, 'PLUGIN_LBF_REFRESH_MATCHES'),
                        type  => 'link',
                        image => MENU_REFRESH,
                        url   => \&refreshPlaylists,
                    },
                    map { _playlistTile($_, $client) } @$playlists,
                ],
                cachetime => 0,
            });
        },
        onError => sub {
            $log->error("Playlists fetch error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }], cachetime => 0 });
        },
    );
}

# One browse tile for a playlist: line1 = the period it covers (the branded cover
# already carries the playlist name), line2 = the streaming-match count, plus the
# per-category bundled cover image (_categoryCover) — a real server-served PNG, so
# every skin shows it.
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
    my @adapters = _orderedAdapters();
    my $svcOrder = join(',', map { lc $_->{name} } @adapters);
    my $rkey = 'lbf:pl:resolved:7:' . join('|', ($pl->{mbid} // ''), $lastMod, $svcOrder);
    if (my $c = $cache->get($rkey)) {
        # Count only tracks whose service is still usable, so the tile agrees with
        # the count shown when the playlist is opened (_playlistResult applies the
        # same filter) after a service is disabled/uninstalled.
        my $enabled = { map { lc($_->{name}) => 1 } @adapters };
        my $usable = grep { _cachedSvcUsable($_->{_svc}, $enabled) } @{ $c->{items} || [] };
        $matched = sprintf(cstring($client, 'PLUGIN_LBF_PL_MATCHED'), $usable, $c->{total});
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
    my $rkey = 'lbf:pl:resolved:7:' . join('|', $mbid, ($lastMod // ''), $svcOrder);

    my $title = ref $pass eq 'HASH' ? $pass->{title} : undef;

    if (my $c = $cache->get($rkey)) {
        _dbg("resolved playlist cache hit: $mbid ($c->{matched}/$c->{total})");
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

            # Enrich with release years first (same pass as the follow feed), so the
            # rows show " (YYYY)" like the rest of the plugin — one cached, chunked
            # metadata call; the resolve then bakes the year into each item name.
            _enrichYears($tracks, sub {
            _resolveTracks($client, $tracks, sub {
                my ($items, $inconclusive) = @_;
                $items //= [];
                my $payload = { items => $items, matched => scalar(@$items), total => scalar(@$tracks) };
                my $ttl     = _playlistTtl($items, scalar @$tracks, $inconclusive);
                eval { $cache->set($rkey, $payload, $ttl); 1 }
                    or $log->warn("resolved playlist cache set failed: $@");
                my $lib = grep { ($_->{_svc} // '') eq 'Library' } @$items;
                _dbg("resolved playlist $mbid: $payload->{matched}/$payload->{total} matched ($lib library)"
                    . ($inconclusive ? " ($inconclusive inconclusive — short TTL)" : ""));
                $callback->(_playlistResult($client, $payload, $title));
            });
            });
        },
        sub {
            $log->error("Playlist resolve error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        },
    );
}

# ===========================================================================
# "Recommended by People You Follow" — ONE new-music list from the user's ListenBrainz
# social feed (recording_recommendation / recording_pin events from followed users).
# Every track the user ALREADY OWNS in their library is excluded ('exclude' libMode),
# so the list is purely music they don't have yet. Recs are accumulated into a small
# persisted store (_mergeFollow) so a rec isn't lost when it scrolls out of the feed's
# 75-event window; history builds forward from first capture. The opened view is
# newest-first with DAY DIVIDER rows so new additions are easy to spot, while the tile
# itself is a playable container (Play/Add queues the whole list) — Material drops the
# in-view Play-all once divider rows are present, so play-as-one-list comes from the
# tile. Resolved once, cached under a service-order-scoped key validated by a content
# signature; refreshed by the daily warm.
# ===========================================================================

# Persisted rec store for the current user: { updated, tracks => [ newest-first, each
# with a `created` epoch ] }. Keyed by username; ':1:' namespaces this flat store.
sub _followStoreKey { 'lbf:follow:accum:1:' . ($prefs->get('username') // '') }

sub _loadFollowStore {
    my $s = $cache->get(_followStoreKey());
    return (ref $s eq 'HASH' && ref $s->{tracks} eq 'ARRAY') ? $s : { tracks => [] };
}

# Dedup key for a rec: recording MBID if present, else lc "artist|title".
sub _followTrackKey {
    my ($t) = @_;
    return $t->{recording_mbid}
        ? "m:$t->{recording_mbid}"
        : 't:' . lc(($t->{artist} // '') . '|' . ($t->{title} // ''));
}

# Merge freshly-fetched feed tracks into the store (add-if-new, so a rec that later
# scrolls out of the 75-event window isn't lost), keep newest-first by `created`, and
# cap at FOLLOW_KEEP_MAX. Returns the updated store.
sub _mergeFollow {
    my ($tracks) = @_;
    my $store = _loadFollowStore();
    my @all   = @{ $store->{tracks} };
    my %seen  = map { _followTrackKey($_) => 1 } @all;

    for my $t (@$tracks) {
        my $k = _followTrackKey($t);
        next if $seen{$k}++;
        push @all, $t;
    }
    @all = sort { ($b->{created} // 0) <=> ($a->{created} // 0) } @all;   # newest first
    @all = @all[0 .. FOLLOW_KEEP_MAX - 1] if @all > FOLLOW_KEEP_MAX;

    $store->{tracks}  = \@all;
    $store->{updated} = time();
    eval { $cache->set(_followStoreKey(), $store, FOLLOW_STORE_TTL); 1 }
        or $log->warn("follow store cache set failed: $@");
    return $store;
}

# Resolved-list cache key: user + streaming-service order (so a priority change
# re-resolves). ':4:' namespaces it away from the retired single (:1:) / weekly (:2:)
# / day-only (:3:) resolved keys; content re-validated by {sig}. Bumped :3:→:4: so
# existing resolves re-run once and bake in each item's `_recommender` (0.9.88, the
# by-recommender sort) — the source store already carries it, so it's a free re-tag.
sub _followResolvedKey {
    my $user     = $prefs->get('username') // '';
    my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());
    # :4:->:5: (0.9.111) — items now carry _artist/_amb so the blocked-artists
    # filter applies to this list too; one re-resolve bakes the tags in.
    return 'lbf:follow:resolved:5:' . join('|', $user, $svcOrder);
}

# A stable, order-sensitive signature of a week's track set, so a cached resolve is
# reused only while that week's recs are unchanged.
sub _followSig {
    my ($tracks) = @_;
    my $s = join("\n",
        map { join('|', $_->{recording_mbid} // '', lc($_->{artist} // ''), lc($_->{title} // '')) } @$tracks);
    # md5_hex dies ("Wide character in subroutine entry") on any code point > 255,
    # and feed titles/artists are full Unicode (Japanese, accents, curly quotes) —
    # so hash the UTF-8 byte form, not the wide string.
    utf8::encode($s);
    return Digest::MD5::md5_hex($s);
}

# The Recommended tile ("Recommended Tracks" cover): a playable container (Play/Add
# queues the whole list) that drills into the day-divided view. Row text = "Your
# Followers" — names the source; the matched-count line2 was dropped (0.9.115, not
# needed on the tile — the opened page title still carries matched/total).
sub _followTile {
    my ($client, $feat) = @_;

    return {
        name        => cstring($client, 'PLUGIN_LBF_FOLLOW_TILE'),
        type        => 'playlist',
        image       => MENU_FOLLOW,
        url         => \&resolveFollowFeed,
        passthrough => [{ features => $feat }],
    };
}

# Open the follow list → the resolved, owned-excluded, day-divided track list. Serves
# the cached resolve while the recs are unchanged (same sig); else re-resolves.
sub resolveFollowFeed {
    my ($client, $callback, $args, $pass) = @_;
    my $feat = (ref $pass eq 'HASH') ? $pass->{features} : undef;

    Plugins::ListenBrainzFreshReleases::API->getFollowFeed(
        onDone => sub {
            my $store = _mergeFollow(shift // []);
            _resolveFollow($client, $store, $callback, 0, $feat);
        },
        onError => sub {
            $log->error("Follow feed resolve error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }], cachetime => 0 });
        },
    );
}

# Shared resolve (open path + warm). Excludes owned tracks; count is matched / NEW-track
# total. $force re-resolves past both cache layers. $callback is undef on the warm path.
# Each matched item is tagged with its source rec's `created` (in _resolveTracks) so the
# day dividers can be built at render time (see _followResult).
sub _resolveFollow {
    my ($client, $store, $callback, $force, $feat) = @_;

    my $tracks = $store->{tracks} || [];
    unless (@$tracks) {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_FOLLOW'), type => 'text' }], cachetime => 0 }) if $callback;
        return;
    }

    my $rkey = _followResolvedKey();
    my $sig  = _followSig($tracks);
    if (!$force && (my $c = $cache->get($rkey))) {
        if (($c->{sig} // '') eq $sig) {
            _dbg("follow feed cache hit ($c->{matched}/$c->{total})");
            $callback->(_followResult($client, $c, $feat)) if $callback;
            return;
        }
    }

    # On the open path with no player, still resolve-and-report (don't hang the browse
    # level); the warm guards $client before calling here. Enrich the recs with their
    # release year first (shown in the list, like New Releases), then resolve.
    _enrichYears($tracks, sub {
    _resolveTracks($client, $tracks, sub {
        my ($items, $inconclusive, $unmatched, $owned) = @_;
        $items //= [];
        $owned //= 0;
        my $newTotal = scalar(@$tracks) - $owned;   # tracks the user doesn't already own
        my $payload  = { items => $items, matched => scalar(@$items), total => $newTotal, sig => $sig };
        my $ttl      = _playlistTtl($items, $newTotal, $inconclusive);
        eval { $cache->set($rkey, $payload, $ttl); 1 }
            or $log->warn("resolved follow cache set failed: $@");
        my $lib = grep { ($_->{_svc} // '') eq 'Library' } @$items;
        _dbg("resolved follow feed: $payload->{matched}/$payload->{total} new ($owned owned excluded, $lib library)"
            . ($inconclusive ? " ($inconclusive inconclusive — short TTL)" : ""));
        $callback->(_followResult($client, $payload, $feat)) if $callback;
    }, 'exclude', $force);
    });
}

# Enrich track hashes IN PLACE with their release `year` (from the recording
# metadata), for any that carry a recording_mbid and don't already have one. Used
# by the follow list AND (since 0.9.114) the Created-for-You playlists, so their
# rows show the year like New Releases. Every track leaves with a `year` KEY
# (possibly '') — that key is the gate that lets _resolveTracks apply the
# remaining date fallbacks (the matched item's service `_year`, a library
# track's own tag year) to enriched lists, while un-enriched sources (DSTM
# pools) stay untouched. Always calls $onDone (even on no-op / fetch failure)
# so the caller's flow continues.
sub _enrichYears {
    my ($tracks, $onDone) = @_;
    my $finish = sub {
        $_->{year} //= '' for @$tracks;   # open the year gate for this list
        $onDone->();
    };
    my (%seen, @mbids);
    for my $t (@$tracks) {
        next if defined $t->{year} && length $t->{year};
        my $m = $t->{recording_mbid} || '';
        push @mbids, $m if $m && !$seen{$m}++;
    }
    unless (@mbids) { $finish->(); return; }

    Plugins::ListenBrainzFreshReleases::API->getRecordingMetadata(\@mbids, sub {
        my ($meta) = @_;
        if (ref $meta eq 'HASH') {
            for my $t (@$tracks) {
                next if defined $t->{year} && length $t->{year};
                my $m = $t->{recording_mbid} || '' or next;
                my $e = $meta->{$m} or next;
                $t->{year} = $e->{year} if $e->{year};
            }
        }
        $finish->();
    });   # getRecordingMetadata is onDone-always (best-effort enrichment)
}

# Build the follow browse level: the owned-excluded matched tracks, newest-first, with a
# DAY DIVIDER header before each new day (from the source rec's `created`, tagged onto the
# item in _resolveTracks). Dividers use the SAME Material header style as the New Releases
# week dividers (_headerType()/`image`/per-group drill coderef via _buildWeekly's pattern)
# for a consistent look; plain text on non-header skins.
sub _followResult {
    my ($client, $payload, $feat) = @_;

    my $enabled = { map { lc($_->{name}) => 1 } _orderedAdapters() };
    my @tracks  = grep { _cachedSvcUsable($_->{_svc}, $enabled) } @{ $payload->{items} || [] };
    # Blocked artists drop here too (the whole People You Follow section honours
    # the same blocklist as For You / All Releases). Pre-tag cached items (no
    # _artist) pass through until their next re-resolve.
    my $blkF = _blockedSet();
    @tracks = grep { !_trendBlocked($_->{_artist}, $_->{_amb}, $blkF) } @tracks;
    my $matched = scalar @tracks;
    my $total   = $payload->{total} // $matched;

    my $useH    = _wantHeaders($feat);
    my $divType = $useH ? _headerType() : 'text';
    my $sort    = $prefs->get('follow_sort') || 'date';

    # Group the (already newest-first) tracks either by DAY or by the follower who
    # RECOMMENDED them. Iterating the newest-first list and bucketing in first-seen
    # order gives the newest activity first in BOTH modes: a recommender's first
    # appearance is their most-recent rec, so recommender groups come out
    # most-recent-first, and within a group tracks stay newest-first. Same tree shape
    # as the New Releases week/day dividers, so item_id walks stay consistent.
    my (@order, %bucket);
    for my $it (@tracks) {
        my $k = $sort eq 'recommender' ? ($it->{_recommender} // '') : _dayOf($it->{_created});
        push @order, $k unless exists $bucket{$k};
        push @{ $bucket{$k} }, $it;
    }

    my @items;
    for my $k (@order) {
        my $rows = $bucket{$k};
        push @items, ($sort eq 'recommender'
            ? _recommenderDivider($client, $k, $divType, $useH, $rows)
            : _dayDivider($client, $k, $divType, $useH, $rows));
        push @items, @$rows;
    }
    @items = ({ name => cstring($client, 'PLUGIN_LBF_NO_MATCH'), type => 'text' }) unless @items;

    # "Play what's new (N)" action row at the TOP (per-feature action-row placement) —
    # matched tracks newer than the user's durable "seen" marker (a PREF, so it survives
    # cache eviction). Baseline the marker to the newest matched rec on first use, so the
    # existing backlog counts as already played and only later arrivals surface. Count
    # AND content (playFollowNew) both derive "new" from the SAME resolved items' _created,
    # so the row's number and what's inside it can't disagree. It's a `type=>'link'`
    # DRILL row (like the Refresh rows), NOT a playable `playlist` container: this level
    # is the tile's Play-all source, and a nested playable container here would be
    # re-expanded by Play-all and queue the new tracks a SECOND time. The resolved items
    # are threaded through the passthrough (this level is live/cachetime=>0, rebuilt each
    # open) so playFollowNew works off fresh data rather than re-reading a cache that may
    # have been evicted between render and tap.
    my $maxSeen = 0;
    for (@tracks) { my $c = $_->{_created} // 0; $maxSeen = $c if $c > $maxSeen; }
    my $lastSeen = $prefs->get(FOLLOW_SEEN_PREF) // 0;
    if (!$lastSeen && $maxSeen) {
        $lastSeen = $maxSeen;
        $prefs->set(FOLLOW_SEEN_PREF, $lastSeen);
    }
    my $newCount = grep { ($_->{_created} // 0) > $lastSeen } @tracks;
    if ($newCount) {
        unshift @items, {
            name        => sprintf(cstring($client, 'PLUGIN_LBF_PLAY_NEW'), $newCount),
            type        => 'link',
            image       => MENU_FOLLOW,
            url         => \&playFollowNew,
            passthrough => [{ features => $feat, items => \@tracks }],
        };
    }

    # Inline sort toggle at the VERY top (above "Play what's new") — only when there's
    # something to order. Flips between by-date and by-recommender in place.
    unshift @items, _followSortToggle($client, $sort) if $matched;

    my $heading = cstring($client, 'PLUGIN_LBF_FOLLOW_FEED') . " ($matched/$total)";
    return { title => $heading, items => \@items, cachetime => 0 };
}

# Inline sort toggle for the People You Follow list. The label names the CURRENT ordering
# with a "(tap for …)" hint (Discography's _sortToggleItem style, so it's clear what changes);
# the tap flips the follow_sort PREF and refreshes the
# list in place (nextWindow 'refresh' → the re-walk re-reads the pref). A pref, not
# passthrough, so the choice survives the refresh re-walk AND future visits — like the
# feed's own Sort setting. Sits with "Play what's new" per the top-of-view action-row rule.
sub _followSortToggle {
    my ($client, $sort) = @_;
    my $byRec = $sort eq 'recommender';
    return {
        name        => cstring($client, $byRec ? 'PLUGIN_LBF_FOLLOW_SORT_REC'
                                               : 'PLUGIN_LBF_FOLLOW_SORT_DATE'),
        type        => 'link',
        image       => MENU_SORT,
        nextWindow  => 'refresh',
        passthrough => [{}],
        url         => sub {
            my ($c, $cb) = @_;
            $prefs->set('follow_sort', $byRec ? 'date' : 'recommender');
            $cb->({ items => [] });
        },
    };
}

# A recommender-divider header: "Recommended by <user>" (or a generic label when the feed
# didn't name them), styled exactly like the day dividers so the by-recommender view
# matches the by-date one. Older Material forces a drill on 'header' → point it at this
# person's tracks (like _dayDivider); 'header-basic' (Material 6.4.3+) ignores it.
sub _recommenderDivider {
    my ($client, $name, $divType, $useH, $rows) = @_;
    my $label = length $name
        ? sprintf(cstring($client, 'PLUGIN_LBF_FOLLOW_BY'), $name)
        : cstring($client, 'PLUGIN_LBF_FOLLOW_BY_UNKNOWN');
    my $hdr = { name => $label, type => $divType, image => ICON };
    if ($useH) {
        my @kids = @$rows;
        $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
        $hdr->{passthrough} = [{}];
    }
    return $hdr;
}

# "Play what's new" → the matched recs newer than the user's "seen" marker. The list
# view threads its already-resolved, service-filtered items through the passthrough
# (the follow level is live/cachetime=>0, so they're always fresh) — so the count on the
# row and the tracks inside it always agree; the resolved cache is only a fallback for a
# direct invocation. Reading/playing it advances the durable marker (a pref) to the
# newest matched rec, so the row clears until more arrives. Returns a PURE track list
# (no dividers/action rows) so this drilled level is itself a proper Play-all container.
sub playFollowNew {
    my ($client, $callback, $args, $pass) = @_;

    my @items;
    if (ref $pass eq 'HASH' && ref $pass->{items} eq 'ARRAY') {
        @items = @{ $pass->{items} };   # threaded from the list view — fresh, no cache read
    }
    else {
        # Fallback: re-read the resolved cache (may be absent if it was evicted).
        my $enabled = { map { lc($_->{name}) => 1 } _orderedAdapters() };
        my $c       = $cache->get(_followResolvedKey());
        @items = grep { _cachedSvcUsable($_->{_svc}, $enabled) } @{ ($c && $c->{items}) || [] };
    }

    my $lastSeen = $prefs->get(FOLLOW_SEEN_PREF) // 0;
    my @new      = grep { ($_->{_created} // 0) > $lastSeen } @items;

    # Mark caught up: advance the marker to the newest matched rec.
    my $maxSeen = $lastSeen;
    for (@items) { my $t = $_->{_created} // 0; $maxSeen = $t if $t > $maxSeen; }
    $prefs->set(FOLLOW_SEEN_PREF, $maxSeen);
    _dbg("follow play-new: " . scalar(@new) . " new of " . scalar(@items) . " (lastSeen=$lastSeen -> $maxSeen)");

    unless (@new) {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_NEW'), type => 'text' }], cachetime => 0 });
        return;
    }
    my $heading = sprintf(cstring($client, 'PLUGIN_LBF_PLAY_NEW'), scalar(@new));
    $callback->({ title => $heading, items => \@new, cachetime => 0 });
}

# YYYY-MM-DD (local) of a rec epoch, '' if none.
sub _dayOf {
    my ($created) = @_;
    return '' unless $created;
    my @lt = localtime($created);
    return sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
}

# A day-divider header: "22 June 2026" (or "Undated"), styled exactly like the New
# Releases week dividers — Material's header type via _headerType() with an `image` (so
# the grid toggle stays enabled), plain text on non-header skins. Older Material forces a
# drill action on 'header', so (as in _buildWeekly) point it at this day's tracks rather
# than an empty page; 'header-basic' (Material 6.4.3+) strips the action and ignores it.
sub _dayDivider {
    my ($client, $day, $divType, $useH, $rows) = @_;
    my $label = length $day ? _fmtDate($day) : cstring($client, 'PLUGIN_LBF_UNDATED');
    my $hdr   = { name => $label, type => $divType, image => ICON };
    if ($useH) {
        my @kids = @$rows;
        $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
        $hdr->{passthrough} = [{}];
    }
    return $hdr;
}

# Warm the follow list. Needs a token (private feed) and a player (streaming API
# context). Refreshes the store, then resolves the whole list if its sig changed. A
# forced warm always re-resolves.
sub _warmFollow {
    my ($client, $force) = @_;
    return unless ($prefs->get('token') // '') ne '';

    Plugins::ListenBrainzFreshReleases::API->getFollowFeed(
        # force => 1: bypass the working-cache READ so a warm always re-pulls the
        # feed and can discover newly-arrived recommendations.
        force  => 1,
        onDone => sub {
            my $store  = _mergeFollow(shift // []);
            my $tracks = $store->{tracks} || [];
            unless (@$tracks) { _dbg("warm: follow feed empty"); return; }
            return unless $client;   # no player → resolve on first open instead

            my $c = $cache->get(_followResolvedKey());
            if (!$force && $c && ($c->{sig} // '') eq _followSig($tracks)) {
                _dbg("warm: follow feed unchanged — skip");
                return;
            }
            _resolveFollow($client, $store, undef, $force);
        },
        onError => sub { $log->info("warm: follow feed fetch failed: " . (shift // '')) },
    );
}

# ===========================================================================
# People You Follow — TRENDING (top PLAYED tracks/albums of the users you follow).
# One-follower-one-vote / equal weight: every ranking signal is "how many DISTINCT
# followers", never play volume, so a heavy listener (or someone hammering one
# track) counts once per album — "what are they ALL listening to". Tracks trend at
# the ALBUM level (release-group) so a full-album play doesn't flood the list with
# its tracks; each album is represented by the one track the circle converges on.
# Singles/EPs are 1-track albums, captured the same way. Public endpoints → needs a
# username only. See tools/fetch_trending.py for the same algorithm, live.
# ===========================================================================

# Bounded-concurrency async fan-out over followers: $fetch->($user, $cb) per user
# (each $cb->($rows)); when all are in, $onAll->({ user => rows }). Per-user stats
# are cached, so a warm-populated run may call back synchronously — the followers
# list is capped (FOLLOWER_MAX) by the caller so the pump can't recurse too deep.
sub _fanFollowers {
    my ($users, $fetch, $onAll) = @_;
    my $total = scalar @$users;
    unless ($total) { $onAll->({}); return; }

    my %result;
    my @queue = @$users;
    my ($active, $done, $fin) = (0, 0, 0);

    # Overall deadline: proceed with whatever's collected rather than hanging the
    # browse if some followers' stats are slow/unreachable (late callbacks no-op).
    my $watchdog;
    my $finish = sub {
        return if $fin;
        $fin = 1;
        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;
        $onAll->(\%result);
    };
    $watchdog = Slim::Utils::Timers::setTimer(undef, time() + FANOUT_DEADLINE, sub { $finish->() });

    my $pumping = 0;
    my $pump;
    $pump = sub {
        return if $fin;
        # Re-entrancy guard: with per-user stats cached (warm run), $fetch calls back
        # SYNCHRONOUSLY, so the completion's $pump->() would recurse one level per follower
        # (a ~FOLLOWER_MAX-deep stack, with the whole downstream build running on it). The
        # guard makes a synchronous re-entry a no-op and lets the outer while loop keep
        # launching iteratively instead — same work, flat stack.
        return if $pumping;
        $pumping = 1;
        while ($active < FOLLOWER_FANOUT && @queue) {
            my $u = shift @queue;
            $active++;
            $fetch->($u, sub {
                return if $fin;
                $result{$u} = shift || [];
                $active--; $done++;
                ($done >= $total) ? $finish->() : $pump->();
            });
        }
        $pumping = 0;
    };
    $pump->();
}

# Filter the followed users down to the ACTIVE ones before a trending build:
# anyone whose latest listen (API::getLatestListenTs, per-user cached 1d) is older
# than FOLLOWER_STALE_DAYS is dropped, so a user who stopped using ListenBrainz
# can't keep seeding the aggregates (This Year especially — the week/month stats
# self-clean, a year of history doesn't). UNKNOWN activity (0 — private feed,
# transient error, brand-new account) KEEPS the follower: only an affirmative
# "last listen was months ago" drops anyone, and an all-unknown outage degrades
# to today's behaviour. Reuses _fanFollowers (bounded concurrency + deadline).
sub _activeFollowers {
    my ($followers, $onDone, $force) = @_;
    unless (@{ $followers || [] }) { $onDone->($followers || []); return; }
    _fanFollowers($followers,
        sub {
            my ($u, $cb) = @_;
            Plugins::ListenBrainzFreshReleases::API->getLatestListenTs($u, $cb, force => $force);
        },
        sub {
            my ($ts) = @_;
            my $cutoff = time() - FOLLOWER_STALE_DAYS * 86400;
            my (@active, @stale);
            for my $u (@$followers) {
                my $t = $ts->{$u};
                $t = 0 if ref $t;   # _fanFollowers turns a 0/undef result into []
                if ($t && $t < $cutoff) { push @stale, $u; }
                else                    { push @active, $u; }
            }
            _dbg("trending: dropped " . scalar(@stale) . " stale follower(s): @stale") if @stale;
            $onDone->(\@active);
        });
}

# Blocked-artists test for a People You Follow row (aggregate album / candidate /
# resolved-item tags): shape it like a release and reuse the shared _isBlocked,
# so "Block this artist" hides an artist from THIS section exactly as it does
# from For You / All Releases. Purely local + render/build-time (the NRFY rule):
# takes effect on the next browse, no cache clear needed.
sub _trendBlocked {
    my ($artist, $ambid, $set) = @_;
    return _isBlocked({ artist => ($artist // ''), artist_mbids => [ $ambid ? ($ambid) : () ] }, $set);
}

sub _trendingResolvedKey {
    my $user     = $prefs->get('username') // '';
    my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());
    return 'lbf:trending:resolved:8:' . join('|', $user, $svcOrder);   # :7:->:8: — stale-follower filter (0.9.116)
}

# Aggregate every follower's weekly top recordings into per-album breadth, pick a
# representative track per album, then return an ORDERED candidate source-track
# list: unique-artist albums (by rank) first, repeat-artist albums after — so
# taking the first N after owned/streaming attrition prefers artist variety but a
# lean week still fills from repeats. $rgmap: recording_mbid => { rg, album }.
sub _buildTrendingCandidates {
    my ($followers, $perFollower, $rgmap, $limit) = @_;

    my %rg;   # rg-key => { fol => {}, plays, artist, artist_mbid, album, tracks => { tkey => {...} } }
    for my $fu (@$followers) {
        for my $r (@{ $perFollower->{$fu} || [] }) {
            my $rm    = $r->{recording_mbid} || '';
            my $info  = $rgmap->{$rm} || {};
            my $tfall = 't:' . lc(($r->{artist} // '') . '|' . ($r->{title} // ''));
            # getRecordingMetadata keys the album as release_group_mbid (NOT 'rg');
            # an unmapped/mbid-less track buckets alone (still a candidate).
            my $rgk   = $info->{release_group_mbid} || $tfall;
            my $tkey  = $rm || $tfall;

            # NB: never name a lexical $a/$b in a scope containing a sort block — it
            # shadows sort's package $a/$b and silently breaks the comparator.
            my $alb = $rg{$rgk} ||= { fol => {}, plays => 0, artist => '', artist_mbid => '', album => '', year => '', release_group_mbid => '', tracks => {} };
            $alb->{fol}{$fu}    = 1;
            $alb->{plays}      += $r->{listen_count} // 0;
            $alb->{artist}    ||= $r->{artist}     // '';
            $alb->{artist_mbid} ||= $r->{artist_mbid} // '';
            $alb->{album}     ||= ($info->{album} || $r->{release_name} || '');
            $alb->{release_group_mbid} ||= ($info->{release_group_mbid} // '');
            # Album-level year = first non-empty year among the album's tracks, so a
            # track missing its own year can still show the album's (no extra fetch).
            $alb->{year} = $info->{year} if !$alb->{year} && $info->{year};

            my $t = $alb->{tracks}{$tkey} ||= {
                fol => {}, plays => 0, title => ($r->{title} // ''),
                artist => ($r->{artist} // ''), recording_mbid => $rm,
                year => ($info->{year} // ''),   # release year from the recording metadata
            };
            $t->{fol}{$fu} = 1;
            $t->{plays}   += $r->{listen_count} // 0;
        }
    }

    # Rank albums by breadth (distinct followers), tie-break rep-track breadth then
    # plays. The representative track is the one the MOST followers played (breadth),
    # tie-break its plays.
    my @ranked;
    for my $rgk (keys %rg) {
        my $alb = $rg{$rgk};
        my ($rep) = sort {
            scalar(keys %{ $b->{fol} }) <=> scalar(keys %{ $a->{fol} })
            || $b->{plays} <=> $a->{plays}
        } values %{ $alb->{tracks} };
        next unless $rep;
        push @ranked, {
            breadth  => scalar(keys %{ $alb->{fol} }),
            rbreadth => scalar(keys %{ $rep->{fol} }),
            plays    => $alb->{plays},
            a => $alb, rep => $rep,
        };
    }
    @ranked = sort {
        $b->{breadth} <=> $a->{breadth}
        || $b->{rbreadth} <=> $a->{rbreadth}
        || $b->{plays} <=> $a->{plays}
    } @ranked;

    # Artist-diversify: unique primary artist first, repeats appended after.
    my (@uniq, @rest, %seen);
    for my $row (@ranked) {
        my $am = $row->{a}{artist_mbid} || ('name:' . lc($row->{a}{artist}));
        if ($seen{$am}++) { push @rest, $row; } else { push @uniq, $row; }
    }
    my @ordered = (@uniq, @rest);
    @ordered = @ordered[0 .. $limit - 1] if @ordered > $limit;

    return [ map {
        {
            artist             => $_->{rep}{artist},
            title              => $_->{rep}{title},
            album              => $_->{a}{album},
            recording_mbid     => $_->{rep}{recording_mbid},
            release_group_mbid => $_->{a}{release_group_mbid},
            artist_mbid        => ($_->{a}{artist_mbid} // ''),   # blocked-artists filter + item tag
            year               => ($_->{rep}{year} || $_->{a}{year} || ''),   # track year, else album year
        }
    } @ordered ];
}

# The "What's Trending" tile: a playable container (Play/Add queues the whole list)
# that drills into the ranked, owned-excluded track list. Track count (from the
# resolved cache the warm populates) on line2, filtered to services still usable.
sub _trendingTile {
    my ($client, $feat) = @_;
    my $line2 = '';
    if (my $c = $cache->get(_trendingResolvedKey())) {
        my $enabled = { map { lc($_->{name}) => 1 } _orderedAdapters() };
        my $n = grep { _cachedSvcUsable($_->{_svc}, $enabled) } @{ $c->{items} || [] };
        $n = TRENDING_MAX if $n > TRENDING_MAX;
        $line2 = sprintf(cstring($client, 'PLUGIN_LBF_N_TRACKS'), $n) if $n;
    }
    # The branded cover already says "What's Trending"; the row label names what it
    # is — weekly tracks (cf. All Releases, whose row shows the period not the name).
    return {
        name => cstring($client, 'PLUGIN_LBF_WEEKLY_TRACKS'),
        ($line2 ne '' ? (line2 => $line2) : ()),
        type        => 'playlist',
        image       => MENU_TRENDING,
        url         => \&resolveTrending,
        passthrough => [{ features => $feat }],
    };
}

# Open "What's Trending" → resolved, owned-excluded, breadth-ranked track list.
sub resolveTrending {
    my ($client, $callback, $args, $pass) = @_;
    my $feat = (ref $pass eq 'HASH') ? $pass->{features} : undef;
    _resolveTrending($client, $callback, 0, $feat);
}

# Shared build (open path + warm). Serves the keyed resolved cache while fresh
# (refreshed daily by the warm; a service-order change re-keys); else fans out
# following → each follower's weekly recordings → recording→album map → candidate
# ranking → _resolveTracks('exclude', drops owned) → cap TRENDING_MAX. $callback is
# undef on the warm path. NB: needs a connected player for the streaming API
# context; on the open path with no player _resolveTracks still reports (empty).
sub _resolveTrending {
    my ($client, $callback, $force, $feat) = @_;

    my $user = $prefs->get('username') // '';
    unless (length $user) {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_SETUP_REQUIRED'), type => 'text' }], cachetime => 0 }) if $callback;
        return;
    }

    my $rkey = _trendingResolvedKey();
    if (!$force && (my $c = $cache->get($rkey))) {
        _dbg("trending cache hit (" . scalar(@{ $c->{items} || [] }) . " tracks)");
        $callback->(_trendingResult($client, $c, $feat)) if $callback;
        return;
    }

    my $empty = sub {
        my ($msg, $cacheEmpty) = @_;
        _dbg("trending: $msg") if $msg;
        # Cache a genuine "no data" outcome (nobody followed / all stale / no candidates)
        # SHORT, so it doesn't re-run the whole fan-out + aggregation on every browse but
        # re-checks within the hour. NEVER cache the network-error path ($cacheEmpty unset)
        # — a transient following/stats failure must not pin the list empty.
        eval { $cache->set($rkey, { items => [], total => 0 }, PLAYLIST_INCONCLUSIVE_TTL); 1 } if $cacheEmpty;
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_TRENDING'), type => 'text' }], cachetime => 0 }) if $callback;
    };

    # Phase timing so a slow cold build points at the culprit (fan-out / metadata /
    # streaming resolve) rather than being guessed at. dt() = ms since the last mark.
    my $t0 = Time::HiRes::time();
    my $tp = $t0;
    my $dt = sub { my $now = Time::HiRes::time(); my $d = int(($now - $tp) * 1000); $tp = $now; return $d };

    Plugins::ListenBrainzFreshReleases::API->getFollowing(
        # force => 1 (manual Refresh) bypasses the following/stats read caches so it's
        # a genuine cold rebuild — the whole point of Refresh (and how to time it).
        force  => $force,
        onDone => sub {
            my $followers = shift // [];
            @$followers = @{ $followers }[0 .. FOLLOWER_MAX - 1] if @$followers > FOLLOWER_MAX;
            unless (@$followers) { $empty->("not following anyone", 1); return; }
            _dbg("trending timing: following " . scalar(@$followers) . " in " . $dt->() . "ms");

            _activeFollowers($followers, sub {
            $followers = shift;
            unless (@$followers) { $empty->("no active followed users", 1); return; }

            _fanFollowers($followers,
                sub {
                    my ($u, $cb) = @_;
                    Plugins::ListenBrainzFreshReleases::API->getUserTopRecordings(
                        $u, range => TRENDING_RANGE, count => TRENDING_PER_USER, force => $force, onDone => $cb);
                },
                sub {
                    my ($perFollower) = @_;
                    _dbg("trending timing: stats fan-out in " . $dt->() . "ms");

                    # Rank distinct recordings by breadth (distinct followers) and map ONLY
                    # the top TREND_MAP_CAP to albums — a huge library of one-off plays can't
                    # trigger dozens of sequential metadata calls; low-breadth tail can't make
                    # the top albums anyway. (getRecordingMetadata caches per-mbid, so repeat
                    # builds mostly hit cache regardless.)
                    my %recFol;
                    for my $fu (@$followers) {
                        for my $r (@{ $perFollower->{$fu} || [] }) {
                            my $m = $r->{recording_mbid} || '' or next;
                            $recFol{$m}{$fu} = 1;
                        }
                    }
                    my @mbids = sort { scalar(keys %{ $recFol{$b} }) <=> scalar(keys %{ $recFol{$a} }) } keys %recFol;
                    @mbids = @mbids[0 .. TREND_MAP_CAP - 1] if @mbids > TREND_MAP_CAP;

                    my $afterMap = sub {
                        my ($meta) = @_;
                        _dbg("trending timing: mapped " . scalar(@mbids) . " recordings in " . $dt->() . "ms");
                        my $cands = _buildTrendingCandidates($followers, $perFollower, $meta || {}, TRENDING_CANDIDATES);
                        # Blocked artists never reach the resolve (no wasted searches);
                        # the render side filters again for blocks added after this build.
                        my $blk = _blockedSet();
                        @$cands = grep { !_trendBlocked($_->{artist}, $_->{artist_mbid}, $blk) } @$cands;
                        unless (@$cands) { $empty->("no candidate tracks", 1); return; }

                        my $resolve = sub {
                            _resolveTracks($client, $cands, sub {
                            my ($items, $inconclusive, $unmatched, $owned) = @_;
                            $items //= []; $owned //= 0;
                            @$items = @{ $items }[0 .. TRENDING_MAX - 1] if @$items > TRENDING_MAX;
                            my $payload = { items => $items, total => scalar(@$items) };
                            my $ttl = $inconclusive ? PLAYLIST_INCONCLUSIVE_TTL : TREND_RESOLVED_TTL;
                            eval { $cache->set($rkey, $payload, $ttl); 1 }
                                or $log->warn("resolved trending cache set failed: $@");
                            _dbg("resolved trending: " . scalar(@$items) . " tracks"
                                . " ($owned owned excluded"
                                . ($inconclusive ? ", $inconclusive inconclusive — short TTL" : "") . ")"
                                . " — resolve " . $dt->() . "ms, total " . int((Time::HiRes::time() - $t0) * 1000) . "ms");
                            $callback->(_trendingResult($client, $payload, $feat)) if $callback;
                            # early-stop at TRENDING_MAX matches (ranked pool — we only need the
                            # first N), higher parallelism (the resolve is the cold build's cost).
                            }, 'exclude', $force, limit => TRENDING_MAX, concurrency => TREND_RESOLVE_CONC);
                        };

                        # TARGETED metadata fill: the pre-grouping map is capped at
                        # TREND_MAP_CAP by breadth, and breadth-1 ties fall outside it
                        # ARBITRARILY — so a track can reach the final list with no
                        # metadata at all (no year, no rg; the Stephen Rennicks case:
                        # its recording had first_release_date all along, just never
                        # fetched). Fetch metadata for exactly the CHOSEN candidates
                        # that missed the map — ≤TRENDING_CANDIDATES mbids, chunked,
                        # recmeta-cached, so this is 0–2 requests and feeds the whole
                        # date ladder below (rg date → name-search → service year).
                        my $fillMeta = sub {
                            my ($next) = @_;
                            my @need = do { my %s;
                                grep { $_ && !$s{$_}++ }
                                map  { $_->{recording_mbid} }
                                grep { !$_->{year} || !$_->{release_group_mbid} } @$cands };
                            unless (@need) { $next->(); return; }
                            Plugins::ListenBrainzFreshReleases::API->getRecordingMetadata(\@need, sub {
                                my ($m2) = @_;
                                if (ref $m2 eq 'HASH') {
                                    for my $c (@$cands) {
                                        my $e = $m2->{ lc($c->{recording_mbid} || '') } or next;
                                        $c->{year}               ||= $e->{year}               || '';
                                        $c->{album}              ||= $e->{album}              || '';
                                        $c->{release_group_mbid} ||= $e->{release_group_mbid} || '';
                                    }
                                }
                                _dbg("trending timing: candidate metadata fill (" . scalar(@need) . ") in " . $dt->() . "ms");
                                $next->();
                            });   # onDone-always
                        };

                        # LAST year fallback: candidates from UNMAPPED listens have no
                        # recording mbid (so no metadata, no rg mbid, no year at all) —
                        # resolve their album by artist+name against MusicBrainz
                        # (mirror-aware, per-name cached 30d, so this drains to zero
                        # over builds). Bounded per build; sequential pump.
                        my $fillByName = sub {
                            my @miss = grep { !$_->{year}
                                              && length($_->{artist} // '') && length($_->{album} // '') } @$cands;
                            splice(@miss, 25) if @miss > 25;
                            unless (@miss) { $resolve->(); return; }
                            my $i = 0;
                            my $step = sub {
                                my ($self) = @_;
                                if ($i >= @miss) {
                                    _dbg("trending timing: name-resolved years in " . $dt->() . "ms");
                                    $resolve->(); return;
                                }
                                my $c = $miss[$i++];
                                Plugins::ListenBrainzFreshReleases::API->getReleaseGroupByName(
                                    $c->{artist}, $c->{album}, sub {
                                        my ($rgi) = @_;
                                        if (ref $rgi eq 'HASH') {
                                            $c->{year}               ||= $rgi->{year} || '';
                                            $c->{release_group_mbid} ||= $rgi->{mbid} || '';
                                        }
                                        $self->($self);
                                    });
                            };
                            $step->($step);
                        };

                        # Fill any missing years from the album's release-group date (more
                        # reliably present than a recording's own release year), then the
                        # name fallback for whatever's still blank, then resolve. Runs
                        # AFTER $fillMeta (which can supply the rg mbids this pass needs).
                        my $fillDates = sub {
                            my @rgs = do { my %s; grep { $_ && !$s{$_}++ } map { $_->{release_group_mbid} } @$cands };
                            my $needYear = grep { !$_->{year} } @$cands;
                            if (@rgs && $needYear) {
                                Plugins::ListenBrainzFreshReleases::API->getReleaseGroupMetadata(\@rgs, sub {
                                    my ($rgmeta) = @_;
                                    if (ref $rgmeta eq 'HASH') {
                                        for my $c (@$cands) {
                                            next if $c->{year};
                                            my $rg = $c->{release_group_mbid} or next;
                                            my $y = ref $rgmeta->{$rg} eq 'HASH' ? $rgmeta->{$rg}{year} : '';
                                            $c->{year} = $y if $y;
                                        }
                                    }
                                    _dbg("trending timing: album years in " . $dt->() . "ms");
                                    $fillByName->();
                                });   # onDone-always
                            } else {
                                $fillByName->();
                            }
                        };
                        $fillMeta->($fillDates);
                    };

                    @mbids ? Plugins::ListenBrainzFreshReleases::API->getRecordingMetadata(\@mbids, $afterMap)
                           : $afterMap->({});
                });
            }, $force);   # _activeFollowers — stale-follower filter
        },
        onError => sub { $empty->("following fetch failed: " . (shift // '')); },
    );
}

# Render the resolved trending track list. A top-of-view "Refresh (rebuild now)"
# action row precedes the tracks (per the top-of-feed action-row rule); Play-all
# still works from the TILE (a type=>'playlist' container), like the follow list.
# Count in the title.
sub _trendingResult {
    my ($client, $payload, $feat) = @_;
    my $enabled = { map { lc($_->{name}) => 1 } _orderedAdapters() };
    my @tracks  = grep { _cachedSvcUsable($_->{_svc}, $enabled) } @{ $payload->{items} || [] };
    # Blocked artists drop at render (immediate, like every other feed) via the
    # _artist/_amb tags; pre-tag cached items pass through until they re-resolve.
    my $blk = _blockedSet();
    @tracks = grep { !_trendBlocked($_->{_artist}, $_->{_amb}, $blk) } @tracks;
    @tracks = @tracks[0 .. TRENDING_MAX - 1] if @tracks > TRENDING_MAX;
    my $n = scalar @tracks;

    my @items = @tracks
        ? ( _refreshItem($client, 'trending'), @tracks )
        : ( { name => cstring($client, 'PLUGIN_LBF_NO_TRENDING'), type => 'text' } );

    return {
        title     => cstring($client, 'PLUGIN_LBF_TRENDING') . " ($n)",
        items     => \@items,
        cachetime => 0,
    };
}

# --- Trending Albums (This Month / This Year) ------------------------------
# Same one-vote-per-follower breadth, straight from each follower's top
# release-groups. Rendered as album tiles that resolve to streaming on tap via
# _releaseDetail (like fresh releases) — no pre-resolution needed. Show-all (owned
# NOT filtered — trending is about popularity).

sub _trendingAlbumsTile {
    my ($client, $range, $feat) = @_;
    my $isYear = $range eq 'this_year';
    # Cover says "Trending Albums"; the row label names the period. Year gets a
    # distinct-colour cover so the two album rows are easy to tell apart at a glance.
    return {
        name        => cstring($client, $isYear ? 'PLUGIN_LBF_PERIOD_YEAR' : 'PLUGIN_LBF_PERIOD_MONTH'),
        type        => 'link',
        image       => $isYear ? MENU_TRENDING_ALB_YEAR : MENU_TRENDING_ALB,
        url         => \&resolveTrendingAlbums,
        passthrough => [{ range => $range, features => $feat }],
    };
}

sub resolveTrendingAlbums {
    my ($client, $callback, $args, $pass) = @_;
    my $range = (ref $pass eq 'HASH' && $pass->{range}) ? $pass->{range} : 'this_month';
    my $feat  = (ref $pass eq 'HASH') ? $pass->{features} : undef;

    _buildAlbumsData($client, $range, sub {
        my ($data) = @_;
        $callback->(_trendingAlbumsResult($client, $data, $range, $feat));
    }, 0);
}

# Build (or serve cached) the ranked album aggregate for a range: following →
# fan-out top release-groups → per-album breadth → ranked plain-hash arrayref
# (no coderefs, so it's Storable-cacheable; rows are rebuilt each open). Always
# calls $onDone with an arrayref (possibly empty).
# Cache key includes the CURRENT calendar month/year, so a rollover (new month/
# year) is a fresh key that rebuilds at once regardless of the long TTL.
sub _albumsDataKey {
    my ($range, $user) = @_;
    my @n = localtime(time);
    my $period = ($range eq 'this_year')
        ? sprintf('%04d', $n[5] + 1900)
        : sprintf('%04d-%02d', $n[5] + 1900, $n[4] + 1);
    # :2:->:3: — 0.9.106 added date/type to the stored shape WITHOUT bumping (the
    # layered-cache lesson again: month/year aggregates live 7d/30d, so users kept
    # serving dateless pre-0.9.106 rows); :3: baked in the unmapped-row merge
    # + MB name-resolution (0.9.108). :3:->:4: — the streaming gate (0.9.109):
    # survivors depend on the enabled services, so the key carries the service
    # order (like the resolved-playlist keys) and re-keys on a service change.
    # :4:->:5: (0.9.110) — years also from the matched item's service date (_year).
    my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());
    return "lbf:trending:albums:6:$range:$period:$user|$svcOrder";
}

sub _buildAlbumsData {
    my ($client, $range, $onDone, $force) = @_;
    $force ||= 0;

    my $user = $prefs->get('username') // '';
    unless (length $user) { $onDone->([]); return; }

    my $dkey = _albumsDataKey($range, $user);
    if (!$force && (my $data = $cache->get($dkey))) { $onDone->($data); return; }
    my $ttl = ($range eq 'this_year') ? TREND_ALBUMS_YEAR_TTL : TREND_ALBUMS_MONTH_TTL;

    Plugins::ListenBrainzFreshReleases::API->getFollowing(
        force  => $force,
        onDone => sub {
            my $followers = shift // [];
            @$followers = @{ $followers }[0 .. FOLLOWER_MAX - 1] if @$followers > FOLLOWER_MAX;
            unless (@$followers) { $onDone->([]); return; }

            _activeFollowers($followers, sub {
            $followers = shift;
            unless (@$followers) { $onDone->([]); return; }

            _fanFollowers($followers,
                sub {
                    my ($u, $cb) = @_;
                    Plugins::ListenBrainzFreshReleases::API->getUserTopReleaseGroups(
                        $u, range => $range, count => 50, force => $force, onDone => $cb);
                },
                sub {
                    my ($perFollower) = @_;
                    my $data = _aggregateAlbums($followers, $perFollower);
                    # Blocked artists never take a pool slot (or a gate search); the
                    # render side filters again for blocks added after this build.
                    my $blk = _blockedSet();
                    @$data = grep { !_trendBlocked($_->{artist}, $_->{artist_mbid}, $blk) } @$data;
                    # Pool = shown cap + head-room: the streaming gate below drops
                    # non-streamable albums, so rank a few extra candidates to keep
                    # the list near TRENDING_MAX after attrition (bounded — every
                    # pooled row costs metadata + one gated streaming search).
                    my $pool = TRENDING_MAX + 10;
                    @$data = @{ $data }[0 .. $pool - 1] if @$data > $pool;

                    # STREAMING GATE (after the metadata fill): only albums that
                    # actually match a streaming service are kept — a not-on-services
                    # album (10-hour noise uploads, private rips) can't take a slot it
                    # can't play. Resolves through the SAME _findPlayable/cache the
                    # detail page uses, so gated albums open instantly afterwards.
                    # Rank order preserved via slots; early-stop at TRENDING_MAX kept.
                    # Degrades safely: no player/services → ungated result; gate keeps
                    # NOTHING (streaming down / not yet authed) → ungated result; both
                    # cached SHORT (inconclusive) so a healthy build replaces them soon.
                    my $gate = sub {
                        my $settle = sub {
                            my ($kept, $short) = @_;
                            @$kept = @{ $kept }[0 .. TRENDING_MAX - 1] if @$kept > TRENDING_MAX;
                            eval { $cache->set($dkey, $kept, ($short ? PLAYLIST_INCONCLUSIVE_TTL : $ttl)); 1 }
                                or $log->warn("trending albums cache set failed: $@");
                            $onDone->($kept);
                        };
                        unless ($client && scalar(_orderedAdapters())) {
                            _dbg("trending albums ($range): no client/services — gate skipped (short TTL)");
                            $settle->($data, 1); return;
                        }
                        my $total = scalar @$data;
                        unless ($total) { $settle->($data, 0); return; }

                        my (@slots, $finished, $timedOut);
                        my ($idx, $active, $completed, $kept) = (0, 0, 0, 0);
                        my $finish = sub {
                            return if $finished; $finished = 1;
                            my @keep = grep { ref $_ } @slots;
                            if (!@keep) {   # nothing survived → streaming likely unavailable
                                _dbg("trending albums ($range): gate kept 0/$total — serving ungated (short TTL)");
                                $settle->($data, 1); return;
                            }
                            # A watchdog-truncated build (timed out mid-gate) holds only the albums
                            # gated so far — cache it SHORT so a healthy build replaces the partial
                            # list within the hour, not at the full 7d/30d TTL.
                            _dbg("trending albums ($range): gate kept " . scalar(@keep) . "/$total"
                                . ($timedOut ? " (timed out — short TTL)" : ""));
                            $settle->(\@keep, $timedOut ? 1 : 0);
                        };
                        my $watchdog = Slim::Utils::Timers::setTimer(undef, time() + PLAYLIST_TIMEOUT, sub { $timedOut = 1; $finish->() });
                        my $pump;
                        $pump = sub {
                            return if $finished;
                            while ($active < 5 && $idx < $total) {
                                last if $kept >= TRENDING_MAX;
                                my $i = $idx++;
                                my $a = $data->[$i];
                                $active++;
                                _findPlayable($client, sub {
                                    my $res = shift;
                                    my @m = (ref $res eq 'HASH' && ref $res->{items} eq 'ARRAY')
                                        ? grep { ($_->{type} // '') ne 'text' } @{ $res->{items} } : ();
                                    if (@m) {
                                        $slots[$i] = $a; $kept++;
                                        # LAST date fallback: unmapped on LB + absent from
                                        # MB, but the service catalogue knows the year
                                        # (`_year`, tagged by the adapters).
                                        unless ($a->{year}) {
                                            my ($sy) = grep { $_ } map { $_->{_year} } @m;
                                            $a->{year} = $sy if $sy;
                                        }
                                    }
                                    else    { $slots[$i] = 0; }
                                    $active--; $completed++;
                                    if ($completed >= $total || ($kept >= TRENDING_MAX && $active == 0)) {
                                        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;
                                        $finish->();
                                    }
                                    elsif ($kept < TRENDING_MAX) { $pump->(); }
                                }, $a->{artist}, $a->{title}, '', $force, $a->{year}, $a->{type});
                            }
                        };
                        $pump->();
                    };

                    my $finish2 = sub {
                        my ($ymeta) = @_;
                        if (ref $ymeta eq 'HASH') {
                            for my $a (@$data) {
                                my $m = $a->{release_group_mbid} or next;
                                my $e = ref $ymeta->{$m} eq 'HASH' ? $ymeta->{$m} : {};
                                # date + type feed _buildReleaseItem exactly like a fresh release
                                $a->{year} = $e->{year} if $e->{year};
                                $a->{date} = $e->{date} if $e->{date};
                                $a->{type} = $e->{type} if $e->{type};
                            }
                        }
                        $gate->();
                    };
                    my $rgPass = sub {
                        my @rgm = grep { $_ } map { $_->{release_group_mbid} } @$data;
                        @rgm ? Plugins::ListenBrainzFreshReleases::API->getReleaseGroupMetadata(\@rgm, $finish2)
                             : $finish2->({});
                    };

                    # Rows STILL missing an rg mbid = every follower's listen was
                    # UNMAPPED on ListenBrainz (verified live — those rows also have
                    # no caa/date/type). Resolve them by artist+album against
                    # MusicBrainz (mirror-aware, per-name cached) so they get an
                    # mbid + date + type — and thereby art (CAA release-group) and a
                    # full NRFY-equivalent detail page. Sequential pump: typically a
                    # handful of rows; each result is cached 30d so later builds are
                    # free. Self-passing sub (no self-capturing closure leak).
                    my @miss = grep { !$_->{release_group_mbid}
                                      && length($_->{artist} // '') && length($_->{title} // '') } @$data;
                    unless (@miss) { $rgPass->(); return; }
                    my $i = 0;
                    my $step = sub {
                        my ($self) = @_;
                        if ($i >= @miss) { $rgPass->(); return; }
                        my $a = $miss[$i++];
                        Plugins::ListenBrainzFreshReleases::API->getReleaseGroupByName(
                            $a->{artist}, $a->{title}, sub {
                                my ($rgi) = @_;
                                if (ref $rgi eq 'HASH' && $rgi->{mbid}) {
                                    $a->{release_group_mbid} = $rgi->{mbid};
                                    $a->{date} ||= $rgi->{date} || '';
                                    $a->{year} ||= $rgi->{year} || '';
                                    $a->{type} ||= $rgi->{type} || '';
                                }
                                $self->($self);
                            });
                    };
                    $step->($step);
                });
            }, $force);   # _activeFollowers — stale-follower filter
        },
        onError => sub { $log->info("trending albums: following fetch failed: " . (shift // '')); $onDone->([]); },
    );
}

# Aggregate top release-groups across followers → ranked arrayref of plain hashes,
# one-vote-per-follower breadth desc (tie-break total plays).
# MERGE RULE: a stats row is only as good as that follower's LISTEN MAPPING — the
# SAME album arrives WITH release_group_mbid/caa from one follower and with them
# null from another (verified live: "Mácula" mapped + unmapped split into two rows
# and split the breadth). So bucket by mbid, but first index each mbid's
# lc(artist|title) so an UNMAPPED row of the same album joins the mapped bucket
# instead of forking its own; per-field ||= backfills mbid/caa from whichever row
# carries them.
sub _aggregateAlbums {
    my ($followers, $perFollower) = @_;

    # Pass 1: text-key → the mbid bucket key, for every row that HAS an mbid.
    my %byText;
    for my $fu (@$followers) {
        for my $r (@{ $perFollower->{$fu} || [] }) {
            next unless $r->{release_group_mbid};
            my $tk = lc(($r->{artist} // '') . '|' . ($r->{title} // ''));
            $byText{$tk} ||= $r->{release_group_mbid};
        }
    }

    # Pass 2: aggregate. An mbid-less row joins its mapped sibling's bucket when
    # one exists; otherwise it buckets by text (and may be MB-resolved later).
    my %rg;
    for my $fu (@$followers) {
        for my $r (@{ $perFollower->{$fu} || [] }) {
            my $tk  = lc(($r->{artist} // '') . '|' . ($r->{title} // ''));
            my $key = $r->{release_group_mbid} || $byText{$tk} || ('t:' . $tk);
            my $alb = $rg{$key} ||= {
                release_group_mbid => '', title => ($r->{title} // ''), artist => ($r->{artist} // ''),
                artist_mbid => '', caa_id => undef, caa_release_mbid => '',
                fol => {}, plays => 0,
            };
            $alb->{fol}{$fu} = 1;
            $alb->{plays}   += $r->{listen_count} // 0;
            # Backfill identity/art from whichever follower's row carries them.
            $alb->{release_group_mbid} ||= $r->{release_group_mbid} || '';
            $alb->{artist_mbid}        ||= $r->{artist_mbid}        || '';
            $alb->{caa_id}             //= $r->{caa_id};
            $alb->{caa_release_mbid}   ||= $r->{caa_release_mbid}   || '';
        }
    }

    my @ranked = sort {
        scalar(keys %{ $b->{fol} }) <=> scalar(keys %{ $a->{fol} })
        || $b->{plays} <=> $a->{plays}
    } values %rg;

    return [ map {
        {
            release_group_mbid => $_->{release_group_mbid},
            title => $_->{title}, artist => $_->{artist}, artist_mbid => $_->{artist_mbid},
            caa_id => $_->{caa_id}, caa_release_mbid => $_->{caa_release_mbid},
            breadth => scalar(keys %{ $_->{fol} }), plays => $_->{plays},
        }
    } @ranked ];
}

sub _trendingAlbumsResult {
    my ($client, $data, $range, $feat) = @_;

    # Blocked artists drop at render (immediate — no cache clear needed), exactly
    # like For You / All Releases; the aggregate rows carry artist + artist_mbid.
    my $blk = _blockedSet();
    my @src = grep { !_trendBlocked($_->{artist}, $_->{artist_mbid}, $blk) } @{ $data || [] };

    # Per-view sort, NRFY-style: a durable pref (shared by both album lists, like
    # All Releases' all_sort) applied at render time — the cached aggregate stays
    # in breadth order. 'trending' (the breadth ranking) is the extra, default mode.
    my $mode   = $prefs->get('trending_sort') || 'trending';
    my @sorted = @src;
    if ($mode eq 'release_date') {
        @sorted = sort { ($b->{date} // '') cmp ($a->{date} // '') } @sorted;   # newest first
    }
    elsif ($mode eq 'artist') {
        @sorted = sort { lc($a->{artist} // '') cmp lc($b->{artist} // '')
                         || ($b->{date} // '') cmp ($a->{date} // '') } @sorted;
    }
    elsif ($mode eq 'album') {
        @sorted = sort { lc($a->{title} // '') cmp lc($b->{title} // '') } @sorted;
    }

    my @rows = map { _trendingAlbumRow($client, $_) } @sorted;
    @rows = @rows[0 .. TRENDING_MAX - 1] if @rows > TRENDING_MAX;
    my $n = scalar @rows;

    my $title = cstring($client, $range eq 'this_year'
        ? 'PLUGIN_LBF_TRENDING_ALBUMS_YEAR' : 'PLUGIN_LBF_TRENDING_ALBUMS_MONTH') . " ($n)";

    # Options section on top (Material header + rows), exactly like New Releases
    # for You: the sort toggle then Refresh — the SAME _refreshItem every other
    # section uses (drops this range's aggregate cache, reloads in place).
    my $useH  = _wantHeaders($feat);
    my @items;
    if (@rows) {
        my @opt = ( _trendingSortToggle($client, $mode), _refreshItem($client, 'trending_albums', $range) );
        @items  = ( _sectionHeader($client, 'PLUGIN_LBF_SECTION_OPTIONS', $useH, \@opt), @opt, @rows );
    }
    else {
        @items = ( { name => cstring($client, 'PLUGIN_LBF_NO_TRENDING'), type => 'text' } );
    }

    return {
        title     => $title,
        items     => \@items,
        cachetime => 0,
    };
}

# The Trending Albums "Sorted by <mode> (tap to change)" row — same mechanics as
# NRFY's _sortToggle (durable pref, advance from the LIVE pref, nextWindow refresh
# re-walks and re-sorts in place) with 'trending' (the breadth ranking) as an
# extra mode ahead of the shared Release Date / Artist / Album Title trio.
my @TREND_SORT_MODES = ('trending', 'release_date', 'artist', 'album');
sub _trendingSortToggle {
    my ($client, $mode) = @_;
    my $label = $mode eq 'trending'
        ? cstring($client, 'PLUGIN_LBF_SORT_TRENDING')
        : _sortLabel($client, $mode);
    return {
        name        => sprintf(cstring($client, 'PLUGIN_LBF_SORTED_BY'), $label),
        type        => 'link',
        image       => MENU_SORT,
        nextWindow  => 'refresh',
        url         => sub {
            my ($c, $cb) = @_;
            my $cur  = $prefs->get('trending_sort') || 'trending';
            my $next = $TREND_SORT_MODES[0];
            for my $i (0 .. $#TREND_SORT_MODES) {
                $next = $TREND_SORT_MODES[($i + 1) % @TREND_SORT_MODES], last
                    if $TREND_SORT_MODES[$i] eq $cur;
            }
            $prefs->set('trending_sort', $next);
            $cb->({ items => [] });
        },
    };
}

# One trending-album row. Rendered through the SAME builder as New Releases
# (_buildReleaseItem) from a full fresh-release-shaped $rel, so the year suffix,
# release-type line, cover art, tap-through and streaming-match behaviour are all
# IDENTICAL to NRFY. The album's release date + primary type come from the
# release-group metadata (fetched in _buildAlbumsData). We only override line2 with
# the trending signal (breadth) and keep the always-link safety net for the rare
# release-group with no MBID.
sub _trendingAlbumRow {
    my ($client, $agg) = @_;
    my $rel = {
        artist_credit_name         => $agg->{artist},
        release_name               => $agg->{title},
        release_date               => ($agg->{date} || ($agg->{year} ? "$agg->{year}-01-01" : '')),
        release_group_mbid         => $agg->{release_group_mbid},
        release_group_primary_type => ($agg->{type} // ''),
        caa_id                     => $agg->{caa_id},
        caa_release_mbid           => $agg->{caa_release_mbid},
        artist_mbids               => ($agg->{artist_mbid} ? [ $agg->{artist_mbid} ] : []),
    };

    my $item = _buildReleaseItem($rel, $client);
    # Artwork fallback: stats rows built from UNMAPPED listens carry no
    # caa_release_mbid (coverArtUrl → undef → plugin icon), but once the row has a
    # release-group mbid (from stats or the MB name-resolution) the Cover Art
    # Archive can serve the GROUP's front cover directly — same host, so the
    # registered image proxy caches it like every other cover.
    if (($item->{image} // '') eq ICON && $agg->{release_group_mbid}) {
        $item->{image} = 'https://coverartarchive.org/release-group/' . $agg->{release_group_mbid} . '/front-250';
    }
    # Trending signal in place of the type/genre line.
    $item->{line2} = sprintf(cstring($client, 'PLUGIN_LBF_TREND_BREADTH'), $agg->{breadth} // 0);
    # _buildReleaseItem only links when there's an MBID; a release-group without one
    # can still resolve to streaming from artist+album, so never leave a dead text row.
    if (($item->{type} // '') eq 'text' && (length($agg->{artist} // '') || length($agg->{title} // ''))) {
        $item->{type} = 'link';
        $item->{url}  = sub { my ($c, $cb) = @_; _releaseDetail($rel, $c, $cb); };
    }
    return $item;
}

# Warm hook: pre-resolve the trending tracks (needs a player) and pre-build the two
# album aggregates (no player needed), so the section opens instantly. Chained after
# the follow-feed warm in warmCache.
sub _warmTrending {
    my ($client, $force) = @_;
    return unless ($prefs->get('username') // '') ne '';
    _resolveTrending($client, undef, $force) if $client;
    # The albums build now needs the player too (its streaming gate resolves each
    # album via _findPlayable); with no player it builds ungated on a short TTL.
    _buildAlbumsData($client, 'this_month', sub {}, $force);
    _buildAlbumsData($client, 'this_year',  sub {}, $force);
}

# ===========================================================================
# Diagnostics: "Unmatched tracks (debug)" — list, per playlist, the source tracks
# that didn't resolve to any service, so a matcher/recall gap (e.g. a stylised
# title the service search can't find) is visible in the UI on or off-network.
# ===========================================================================

# Level 1: every list that resolves streaming tracks — the created-for playlists AND
# the People-You-Follow list — each drilling into its own unmatched list, so a matcher
# gap is visible whichever feature it came from.
sub fetchUnmatchedPlaylists {
    my ($client, $callback, $args) = @_;

    Plugins::ListenBrainzFreshReleases::API->getCreatedForPlaylists(
        onDone => sub {
            my $playlists = shift // [];
            my %n;
            my @items = map {
                my $pl = $_;
                $pl->{_variant} = $n{ lc($pl->{source_patch} // '') }++ ? 'previous' : 'current';
                {
                    name        => $pl->{title} // 'Playlist',
                    type        => 'link',
                    image       => _categoryCover($pl->{source_patch}, $pl->{_variant}),
                    url         => \&showUnmatched,
                    passthrough => [{
                        mbid          => $pl->{mbid},
                        title         => $pl->{title},
                        last_modified => $pl->{last_modified},
                    }],
                }
            } @$playlists;

            my $finish = sub {
                $callback->({
                    items => @items ? \@items
                                    : [{ name => cstring($client, 'PLUGIN_LBF_NO_PLAYLISTS'), type => 'text' }],
                    cachetime => 0,
                });
            };

            # Append the People-You-Follow list (token-gated — the feed is private),
            # drilling into its unmatched view. A feed outage just falls back to the
            # createdfor playlists (still a useful diagnostic). Skipped when the whole
            # section is disabled (no feed fetch for it at all).
            if (($prefs->get('token') // '') ne '' && $prefs->get('people_follow')) {
                Plugins::ListenBrainzFreshReleases::API->getFollowFeed(
                    onDone => sub {
                        my $store = _mergeFollow(shift // []);
                        if (@{ $store->{tracks} || [] }) {
                            push @items, {
                                name  => cstring($client, 'PLUGIN_LBF_FOLLOW_FEED'),
                                type  => 'link',
                                image => MENU_FOLLOW,
                                url   => \&showUnmatchedFollow,
                            };
                        }
                        $finish->();
                    },
                    onError => sub { $finish->() },
                );
            }
            else { $finish->(); }
        },
        onError => sub {
            $log->error("Unmatched: playlist list fetch failed: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }], cachetime => 0 });
        },
    );
}

# Build the unmatched-track rows: plain "Artist — Title", with the source list name on
# line2 (so "what list is it from" is clear now the tracker mixes playlists + follow
# weeks). Falls back to an "all matched" note when nothing was dropped.
sub _unmatchedRows {
    my ($client, $unmatched, $srcName) = @_;
    my @rows = map {
        my $a = $_->{artist} // ''; my $t = $_->{title} // '';
        {
            name => (length $a ? "$a \x{2014} $t" : $t),
            (defined $srcName && length $srcName ? (line2 => $srcName) : ()),
            type => 'text',
        }
    } @$unmatched;
    @rows = ({ name => cstring($client, 'PLUGIN_LBF_ALL_MATCHED'), type => 'text' }) unless @rows;
    return @rows;
}

# Level 2: fetch one playlist's source tracks and resolve them (cache-warm after a
# normal open, so usually instant), then list the SOURCE tracks that matched
# nothing as plain "Artist — Title" rows. Reuses _resolveTracks' new unmatched
# return, so it reflects exactly what the playlist view dropped.
sub showUnmatched {
    my ($client, $callback, $args, $pass) = @_;

    my $mbid    = ref $pass eq 'HASH' ? $pass->{mbid}          : undef;
    my $lastMod = ref $pass eq 'HASH' ? $pass->{last_modified} : '';
    my $title   = ref $pass eq 'HASH' ? $pass->{title}         : '';
    unless ($mbid) {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        return;
    }

    my $libMode = ($prefs->get('prefer_library') // 1) ? 'first' : 'never';

    Plugins::ListenBrainzFreshReleases::API->getPlaylistTracks(
        $mbid, $lastMod,
        sub {
            my $tracks = shift // [];
            unless (@$tracks) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }], cachetime => 0 });
                return;
            }
            _resolveTracks($client, $tracks, sub {
                my ($matched, $inconclusive, $unmatched) = @_;
                $unmatched //= [];
                my @rows = _unmatchedRows($client, $unmatched, $title);
                my $heading = (length $title ? $title : cstring($client, 'PLUGIN_LBF_UNMATCHED'))
                            . ' (' . scalar(@$unmatched) . '/' . scalar(@$tracks) . ')';
                $callback->({ title => $heading, items => \@rows, cachetime => 0 });
            }, $libMode);
        },
        sub {
            $log->error("Unmatched: playlist tracks fetch failed: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }], cachetime => 0 });
        },
    );
}

# Level 2 for the follow list: resolve its recs in 'exclude' mode (owned tracks are
# dropped, not counted as unmatched) and list the NEW tracks that matched no service.
# The count is unmatched / new-track total (owned excluded), matching the list view.
sub showUnmatchedFollow {
    my ($client, $callback, $args, $pass) = @_;

    my $srcName = cstring($client, 'PLUGIN_LBF_FOLLOW_FEED');

    Plugins::ListenBrainzFreshReleases::API->getFollowFeed(
        onDone => sub {
            my $store  = _mergeFollow(shift // []);
            my $tracks = $store->{tracks} || [];
            unless (@$tracks) {
                $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }], cachetime => 0 });
                return;
            }
            _resolveTracks($client, $tracks, sub {
                my ($matched, $inconclusive, $unmatched, $owned) = @_;
                $unmatched //= []; $owned //= 0;
                my @rows     = _unmatchedRows($client, $unmatched, $srcName);
                my $newTotal = scalar(@$tracks) - $owned;
                my $heading  = $srcName . ' (' . scalar(@$unmatched) . '/' . $newTotal . ')';
                $callback->({ title => $heading, items => \@rows, cachetime => 0 });
            }, 'exclude');
        },
        onError => sub {
            $log->error("Unmatched: follow fetch failed: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }], cachetime => 0 });
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

    # Drop any track whose streaming service is no longer usable — uninstalled or
    # disabled (priority 0) since this playlist was cached — so a cached list never
    # offers a dead link to a service you've removed. Same on-read guard the album
    # section uses (_rebuildStreamItems). Library tracks always stay. The resolved
    # cache key already re-resolves on a service change; this filters the moment
    # the cached payload is served, matching the album behaviour exactly, and the
    # match count reflects what's actually playable now.
    my $enabled = { map { lc($_->{name}) => 1 } _orderedAdapters() };
    my @items   = grep { _cachedSvcUsable($_->{_svc}, $enabled) } @{ $payload->{items} || [] };
    my $matched = scalar @items;
    my $total   = $payload->{total} // scalar(@items);

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
    my ($items, $total, $inconclusive) = @_;
    # Any track left unresolved because a service couldn't be queried → keep the
    # whole resolve short so it retries soon rather than pinning a streaming outage
    # for a month. Takes precedence (it's the reason a list looks under-matched).
    return PLAYLIST_INCONCLUSIVE_TTL if $inconclusive;
    return LIBRARY_TTL if grep { ($_->{_svc} // '') eq 'Library' } @$items;
    return (scalar(@$items) == $total) ? PLAYLIST_FOUND_TTL : PLAYLIST_PARTIAL_TTL;
}

# Resolve every track to a streaming track with bounded concurrency, preserving
# playlist order. Matched items only are returned (unmatched are dropped). A
# watchdog guarantees the page renders even if a service search hangs.
sub _resolveTracks {
    my ($client, $tracks, $done, $libMode, $force, %opt) = @_;
    # $opt{limit}: stop launching new resolves once this many have MATCHED (playable),
    #   letting in-flight ones drain — for a ranked candidate pool where we only need
    #   the first N (trending). $opt{concurrency}: parallelism (default PLAYLIST_CONCURRENCY).
    my $limit       = $opt{limit};
    my $concurrency = $opt{concurrency} || PLAYLIST_CONCURRENCY;

    my $total        = scalar @$tracks;
    my @slots        = (undef) x $total;   # per-index: hashref (match) / 0 (miss) / 'owned' (excluded) / undef (pending)
    my $next         = 0;
    my $active       = 0;
    my $completed    = 0;
    my $matched      = 0;   # playable matches so far (drives the early-stop limit)
    my $finished     = 0;
    my $inconclusive = 0;   # tracks whose no-match was inconclusive (svc unavailable)
    my $owned        = 0;   # tracks dropped as already-owned ('exclude' mode only)

    my $watchdog;
    my $finish = sub {
        return if $finished;
        $finished = 1;
        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;   # cancel the unused watchdog
        # Also hand back the SOURCE tracks that didn't resolve (slot still 0/undef),
        # so the diagnostics view can list what couldn't be matched — but NOT the
        # ones dropped as already-owned ('owned' sentinel), which aren't a match gap.
        # Pass the inconclusive count too (so the caller can keep the resolved cache
        # short when streaming was momentarily unavailable) and the owned count (so
        # the "new tracks" total can exclude what the user already has).
        my @unmatched = map { $tracks->[$_] }
                        grep { !ref $slots[$_] && ($slots[$_] // '') ne 'owned' } 0 .. $#slots;
        $done->([ grep { ref $_ } @slots ], $inconclusive, \@unmatched, $owned);   # matched items, in order
    };

    $watchdog = Slim::Utils::Timers::setTimer(undef, time() + PLAYLIST_TIMEOUT, sub { $finish->() });

    my $pump;
    $pump = sub {
        return if $finished;
        while ($active < $concurrency && $next < $total) {
            last if $limit && $matched >= $limit;   # got enough — stop launching new
            my $i  = $next++;
            my $tr = $tracks->[$i];
            $active++;
            _findPlayableTrack($client, sub {
                my ($item, $inc, $own) = @_;
                if (ref $item eq 'HASH') {
                    # Tag the matched item with its source rec's timestamp AND the
                    # follower who recommended it (both only present on the follow
                    # feed), so the follow view can group by day OR by recommender.
                    # Harmless elsewhere (undef/absent → not set).
                    $item->{_created}     = $tr->{created}     if defined $tr->{created};
                    $item->{_recommender} = $tr->{recommender} if defined $tr->{recommender};
                    # Source-artist identity (name + mbid when known) — lets the
                    # trending/follow renders apply the blocked-artists filter to
                    # already-resolved lists immediately (like every other feed).
                    $item->{_artist} = $tr->{artist}      if defined $tr->{artist};
                    $item->{_amb}    = $tr->{artist_mbid} if $tr->{artist_mbid};
                    # Append the release year to the display name (like New Releases),
                    # for any source track that carries one (trending + follow). Inert
                    # for playlists (no year). Guard against a double-append on re-resolve.
                    # LAST fallback: the matched item's own service year (`_year`, tagged
                    # by the adapters) — for tracks unmapped on LB AND absent from MB,
                    # the streaming catalogue still knows the date. Gated on the source
                    # track CARRYING a year key (trending candidates always do), so the
                    # playlists' deliberate no-year look is unchanged.
                    my $y = $tr->{year} || (exists $tr->{year} ? ($item->{_year} // '') : '');
                    if ($y && defined $item->{name} && $item->{name} !~ /\(\d{4}\)\s*$/) {
                        $item->{name} .= " ($y)";
                    }
                    $slots[$i] = $item;
                    $matched++;
                }
                else {
                    $slots[$i] = $own ? 'owned' : 0;
                }
                $inconclusive++ if $inc;
                $owned++ if $own;
                $active--;
                $completed++;
                # Finish when every track is done, OR (early-stop) we have enough
                # matches and the in-flight ones have drained. Otherwise pump more.
                if ($completed >= $total || ($limit && $matched >= $limit && $active == 0)) {
                    $finish->();
                }
                elsif (!($limit && $matched >= $limit)) {
                    $pump->();
                }
            }, $tr->{artist}, $tr->{title}, $tr->{album}, $tr->{recording_mbid}, $force, $libMode);
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
    my ($client, %opts) = @_;
    my $force = $opts{force} ? 1 : 0;   # force => 1: re-resolve even already-cached playlists (manual refresh)

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
            _dbg("warm: " . scalar(@queue) . " playlist(s)" . ($force ? " (forced re-resolve)" : ""));

            my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());

            my $next;
            $next = sub {
                my $pl = shift @queue or do {
                    _dbg("warm: playlists done");
                    # Then warm the follow feed (a no-op without a token), then the
                    # People-You-Follow trending list + album aggregates. Chained
                    # after the playlists so they don't all hit the streaming APIs at
                    # once; runs on both the daily tick and the manual forced refresh.
                    # Skipped entirely when the section is disabled — no following/stats/
                    # feed calls, no resolve, no cache writes for it.
                    if ($prefs->get('people_follow')) {
                        _warmFollow($client, $force);
                        _warmTrending($client, $force);
                    }
                    return;
                };

                Plugins::ListenBrainzFreshReleases::API->getPlaylistTracks(
                    $pl->{mbid}, $pl->{last_modified},
                    sub {
                        my $tracks = shift // [];

                        my $rkey = 'lbf:pl:resolved:7:'
                            . join('|', $pl->{mbid}, ($pl->{last_modified} // ''), $svcOrder);

                        # Already resolved (same week) or no client → move on. A forced
                        # refresh bypasses the cache-hit skip so it always re-resolves.
                        if ((!$force && $cache->get($rkey)) || !$client || !@$tracks) {
                            $next->();
                            return;
                        }

                        # Year-enrich first (mirrors resolvePlaylist) so the warm bakes
                        # the same " (YYYY)" names the open path would.
                        _enrichYears($tracks, sub {
                        _resolveTracks($client, $tracks, sub {
                            my ($items, $inconclusive) = @_;
                            $items //= [];
                            my $payload = { items => $items, matched => scalar(@$items), total => scalar(@$tracks) };
                            my $ttl = _playlistTtl($items, scalar @$tracks, $inconclusive);
                            eval { $cache->set($rkey, $payload, $ttl); 1 }
                                or $log->warn("warm resolved cache set failed: $@");
                            my $lib = grep { ($_->{_svc} // '') eq 'Library' } @$items;
                            _dbg("warm: resolved $pl->{mbid} $payload->{matched}/$payload->{total}"
                                . " ($lib library)"
                                . ($inconclusive ? " ($inconclusive inconclusive)" : ""));
                            $next->();
                        }, undef, $force);
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

# Manual "Refresh playlist matches" action (Settings section). Kicks off a FORCED
# warm — re-resolves every playlist from scratch (bypassing both the resolved-playlist
# and per-track caches), library-first. Use after the library has finished scanning
# to clear an all-streaming result the startup warm cached before the scan completed.
# Fire-and-forget (the warm is async and takes ~a minute); returns a confirmation row.
sub refreshPlaylists {
    my ($client, $callback, $args) = @_;

    $client ||= (Slim::Player::Client::clients())[0];
    _dbg("refresh: manual forced playlist re-resolve requested");

    my $msg = $client
        ? cstring($client, 'PLUGIN_LBF_REFRESH_STARTED')
        : cstring($client, 'PLUGIN_LBF_REFRESH_NO_PLAYER');
    warmCache($client, force => 1) if $client;

    $callback->({ items => [{ name => $msg, type => 'text' }], cachetime => 0 });
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
# MuSpy merge (For You feed only)
# ---------------------------------------------------------------------------
# Merge the user's MuSpy followed-artist releases into the ListenBrainz For You
# list. MuSpy returns release groups newest-first but NOT windowed to the plugin's
# day range (its API takes limit/offset only), so window them here, then
# concatenate. Overlap dedupe is left to _dedupeReleases (via _sortReleases), which
# prefers the copy that has cover art — naturally keeping the richer ListenBrainz
# entry on a duplicate.
#
# Windowing differs deliberately from the LB feed: MuSpy is a small, user-curated
# list of artists the user explicitly follows, and its whole value is UPCOMING
# releases. So its future side has its OWN toggle (muspy_future, default ON) rather
# than riding foryou_future (off by default, tuned for the broad LB fresh-releases
# feed) — bounded to its OWN limit (muspy_future_months, default 12) so it can't run
# away, kept separate from the LB feed's narrow days window. The past side still
# honours foryou_past + the days window, so recent MuSpy releases align with the
# feed's freshness setting. (Consequence with the default: even when the LB "Include
# upcoming" is off, the feed can show past-LB + future-MuSpy together — intended; the
# user picked those MuSpy artists. A user who doesn't want that turns muspy_future off.)
sub _mergeMuSpy {
    my ($lb, $muspy) = @_;
    $lb = [] unless ref $lb eq 'ARRAY';
    return $lb unless ref $muspy eq 'ARRAY' && @$muspy;

    my $past   = $prefs->get('foryou_past')   // 1;
    my $future = $prefs->get('muspy_future')  // 1;
    my $days   = $prefs->get('days')          // 14;

    # Whole-month cap on the future side, user-set via muspy_future_months. Guard a
    # missing/garbage/out-of-range pref (it's multiplied out, so a bad value would
    # otherwise blow the window wide open or negative).
    my $months = $prefs->get('muspy_future_months');
    $months = MUSPY_FUTURE_MONTHS_DEFAULT
        unless defined $months && $months =~ /^\d+$/ && $months >= 1;
    $months = MUSPY_FUTURE_MONTHS_MAX if $months > MUSPY_FUTURE_MONTHS_MAX;

    my @n = localtime(time);
    my $today = sprintf('%04d-%02d-%02d', $n[5] + 1900, $n[4] + 1, $n[3]);
    my $lo = _dateShift($today, -$days);
    my $hi = _dateShift($today,  $months * 30);

    my @kept;
    for my $r (@$muspy) {
        my $d = $r->{release_date} // '';
        next unless $d =~ /^\d{4}-\d{2}-\d{2}$/;   # padded on ingest; skip the undatable
        # Dates are zero-padded, so a lexical compare is a chronological one. A
        # release out today counts as "past" (i.e. shown when foryou_past is on);
        # anything ahead is kept when muspy_future is on, up to the muspy_future_months cap.
        my $inWindow = ($d le $today) ? ($past   && $d ge $lo)
                                      : ($future && $d le $hi);
        push @kept, $r if $inWindow;
    }
    $log->info("MuSpy merge: kept " . scalar(@kept) . " of " . scalar(@$muspy) . " within window [$lo .. $hi]")
        if $log->is_info;
    return [ @$lb, @kept ];
}

# Shift a 'YYYY-MM-DD' date by N days (local time), returning 'YYYY-MM-DD'.
sub _dateShift {
    my ($ymd, $delta) = @_;
    return $ymd unless $ymd =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my $epoch = eval { Time::Local::timelocal(0, 0, 12, $3, $2 - 1, $1) };
    return $ymd unless $epoch;
    my @t = localtime($epoch + $delta * 86400);
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

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

    my %idx;      # full key (artist|album|date) -> index in @out
    my %aaSeen;   # dateless key (artist|album)  -> index in @out
    my @out;
    for my $rel (@$releases) {
        my $artist = _norm(_pickValue($rel, 'artist_credit_name', 'artist_name', 'artist'));
        my $album  = _norm(_pickValue($rel, 'release_name', 'title', 'name'));
        my $key    = join('|', $artist, $album, ($rel->{release_date} // ''));
        my $aaKey  = join('|', $artist, $album);

        if (defined(my $i = $idx{$key})) {
            $out[$i] = $rel
                if !Plugins::ListenBrainzFreshReleases::API->coverArtUrl($out[$i])
                &&  Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel);
            next;
        }

        # Cross-source overlap: MuSpy and ListenBrainz can carry the same album with
        # a slightly different release date (MuSpy uses the release-group's first
        # date; LB the fresh-release date), so an exact artist|album|date key would
        # miss it. When THIS entry or the already-seen one is from MuSpy, collapse
        # on artist+album alone so the album shows once — keeping the copy with cover
        # art (usually the richer LB entry). Same-source LB editions that differ only
        # by date are left as separate entries (neither is MuSpy), preserving the
        # long-standing behaviour.
        my $j = $aaSeen{$aaKey};
        if (defined $j
            && ( ($rel->{_source} // '') eq 'muspy' || ($out[$j]{_source} // '') eq 'muspy' )) {
            $out[$j] = $rel
                if !Plugins::ListenBrainzFreshReleases::API->coverArtUrl($out[$j])
                &&  Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel);
            next;
        }

        $idx{$key} = scalar @out;
        $aaSeen{$aaKey} = scalar @out unless defined $aaSeen{$aaKey};
        push @out, $rel;
    }
    return \@out;
}

sub _sortReleases {
    my ($releases) = @_;
    return $releases unless ref $releases eq 'ARRAY';

    $releases = _dedupeReleases($releases);

    # Always newest-first by release date. This is the order the week-bucketing
    # relies on (same-week rows adjacent, weeks newest-first); the per-view Options
    # sort (_sortWithin) reorders the releases WITHIN each week without disturbing
    # the week grouping or its chronological order. The old global "Default sort
    # order" pref was retired in 0.9.97 in favour of the in-view sort toggles.
    return [ sort { ($b->{release_date} // '') cmp ($a->{release_date} // '') } @$releases ];
}

# ---------------------------------------------------------------------------
# Per-view content sort — the three modes offered by the in-view "Sorted by …"
# toggle (Options section): 'release_date' (newest first, the default read),
# 'artist' (A–Z) and 'album' (A–Z). Applied WITHIN a week bucket, so the W/C week
# headers and their chronological order are preserved whichever mode is chosen.
# ---------------------------------------------------------------------------
my @SORT_MODES = qw(release_date artist album);

# The mode after $mode in the fixed cycle (wraps back to the first).
sub _nextSortMode {
    my ($mode) = @_;
    for my $i (0 .. $#SORT_MODES) {
        return $SORT_MODES[($i + 1) % @SORT_MODES] if $SORT_MODES[$i] eq $mode;
    }
    return $SORT_MODES[0];
}

# Localised label for a sort mode (also reused as the toggle-row text).
sub _sortLabel {
    my ($client, $mode) = @_;
    my $tok = $mode eq 'artist' ? 'PLUGIN_LBF_SORT_ARTIST'
            : $mode eq 'album'  ? 'PLUGIN_LBF_SORT_ALBUM'
            :                     'PLUGIN_LBF_SORT_DATE';
    return cstring($client, $tok);
}

# Sort a bucket of releases by the chosen mode. Secondary key is release_date
# (newest first) so ties within an artist/album sort still read chronologically.
# The key the Artist sort orders on: the MusicBrainz sort-name ("White, Jack";
# a stage name like "Panda Bear" keeps its natural order) when known, else the
# display credit ("Jack White"). The sort-name rides on the release (MuSpy) or is
# filled from a background MB warm keyed by the first artist MBID; until then a
# cold artist falls back to the display credit (self-corrects on re-entry).
sub _artistSortKey {
    my ($rel) = @_;
    my $s = $rel->{artist_sort_name};
    if (!(defined $s && length $s)) {
        my $mbids = $rel->{artist_mbids};
        my $mbid  = (ref $mbids eq 'ARRAY' && @$mbids) ? $mbids->[0] : undef;
        $s = $mbid ? Plugins::ListenBrainzFreshReleases::API->peekArtistSort($mbid) : undef;
    }
    $s = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist')
        unless defined $s && length $s;
    return lc $s;
}

# Kick off a background MB sort-name warm for a list's artists (the API dedupes,
# skips cached, throttles + bounds the fetch). Called only from the Artist-sort
# paths, so a user who never sorts by artist never triggers an MB lookup.
sub _warmArtistSorts {
    my ($releases) = @_;
    return unless ref $releases eq 'ARRAY' && @$releases;
    my @mbids;
    for my $r (@$releases) {
        my $m = $r->{artist_mbids};
        push @mbids, $m->[0] if ref $m eq 'ARRAY' && @$m && $m->[0];
    }
    Plugins::ListenBrainzFreshReleases::API->warmArtistSorts(\@mbids) if @mbids;
}

sub _sortWithin {
    my ($releases, $mode) = @_;
    return $releases unless ref $releases eq 'ARRAY';
    $mode ||= 'release_date';

    if ($mode eq 'artist') {
        # Schwartzian transform: compute each release's sort key ONCE, then sort
        # on the precomputed pair. _artistSortKey does a cache read (peekArtistSort),
        # and Perl's sort calls the comparator O(N log N) times — recomputing the
        # key inside it would repeat those reads thousands of times per render on
        # a big week, on the synchronous render path. Primary A-Z, secondary date
        # newest-first (element [1] compared b-vs-a).
        return [ map  { $_->[2] }
                 sort { $a->[0] cmp $b->[0] || $b->[1] cmp $a->[1] }
                 map  { [ _artistSortKey($_), $_->{release_date} // '', $_ ] } @$releases ];
    }
    elsif ($mode eq 'album') {
        return [ map  { $_->[2] }
                 sort { $a->[0] cmp $b->[0] || $b->[1] cmp $a->[1] }
                 map  { [ lc(_pickValue($_, 'release_name', 'title', 'name')), $_->{release_date} // '', $_ ] } @$releases ];
    }
    # release_date, newest first
    return [ sort { ($b->{release_date} // '') cmp ($a->{release_date} // '') } @$releases ];
}

# A cycling "Sorted by <mode> (tap to change)" row for the Options section. $pref
# is the DURABLE pref the choice is stored in — 'foryou_sort' (New Releases for You)
# or 'all_sort' (All Releases, shared across every week view). Tapping advances to
# the next mode, persists it, and refreshes the view in place (nextWindow 'refresh'
# → the re-walk re-reads the pref and re-sorts). Because it's a pref, the choice
# sticks across visits AND server restarts — set once, it stays. Same in-place
# mechanism as the paging rows and the follow-list toggle.
sub _sortToggle {
    my ($client, $pref, $mode) = @_;
    return {
        name        => sprintf(cstring($client, 'PLUGIN_LBF_SORTED_BY'), _sortLabel($client, $mode)),
        type        => 'link',
        image       => MENU_SORT,
        nextWindow  => 'refresh',
        passthrough => [{ pref => $pref }],
        url         => sub {
            my ($c, $cb, $a, $p) = @_;
            # Advance from the LIVE pref, not a mode captured at render time — so
            # a value another player changed in between can't make this tap land
            # on the same mode and read as a no-op.
            my $cur = $prefs->get($p->{pref}) || 'release_date';
            $prefs->set($p->{pref}, _nextSortMode($cur));
            $cb->({ items => [] });
        },
    };
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
    my ($releases, $client, $headers, $mode) = @_;

    unless ($releases && scalar @$releases) {
        return [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }];
    }

    # For You is ALWAYS the weekly view now — W/C material headers, newest week
    # first — as a single level Material windows natively (its in-list filter spans
    # every item). The Options sort ($mode) reorders releases inside each week; the
    # week grouping is unconditional (the old week_dividers/group_by_artist toggles
    # were retired in 0.9.97).
    return _buildWeekly($releases, $client, $headers, $mode);
}

# ---------------------------------------------------------------------------
# Section paging for the All Releases per-week lists (the For You feed keeps its
# native full-list windowing — it works well and Material's in-list filter spans
# every item there). A single All Releases week can hold hundreds of releases, so
# each week is capped at PAGE_SIZE rows followed by a "Show more (N)" row that
# grows it a page at a time, and — once grown — a "Show less" row that collapses
# back to the cap.
#
# Two properties this depends on:
#   - The row carries its target as an ABSOLUTE count, never "+= PAGE_SIZE". Every
#     deeper click re-executes the whole item_id path, so a relative bump could
#     advance the page more than once. Absolute targets keep it idempotent.
#   - The count lives in module-level %pageState (per player, per section key), so
#     it survives the cachetime=>0 re-walk the "Show more" refresh triggers.
# Returns (visible tiles, paging rows) — both go into the level in that order.
# ---------------------------------------------------------------------------
sub _pageSection {
    my ($client, $key, $tiles) = @_;

    my $total = scalar @$tiles;
    return ($tiles, []) if $total <= PAGE_SIZE;

    my $ctx   = $pageState{ _cid($client) } ||= {};
    my $shown = $ctx->{$key} || PAGE_SIZE;
    $shown = $total if $shown > $total;   # a shrunk feed must not slice past the end

    my @rows;
    if ($shown < $total) {
        my $next = $shown + PAGE_SIZE;
        $next = $total if $next > $total;
        push @rows, _pageRow($client, $key, $next,
            cstring($client, 'PLUGIN_LBF_SHOW_MORE') . ' (' . ($total - $shown) . ')',
            PAGE_MORE);
        # "Show all" jumps straight to the whole list (count = the full total) —
        # only offered when it reveals MORE than the single-page "Show more"
        # already would, so the two rows never do the same thing.
        if ($total - $shown > PAGE_SIZE) {
            push @rows, _pageRow($client, $key, $total,
                cstring($client, 'PLUGIN_LBF_SHOW_ALL') . ' (' . $total . ')',
                PAGE_MORE);
        }
    }
    if ($shown > PAGE_SIZE) {
        push @rows, _pageRow($client, $key, PAGE_SIZE,
            cstring($client, 'PLUGIN_LBF_SHOW_LESS'), PAGE_LESS);
    }

    return ([ @$tiles[ 0 .. $shown - 1 ] ], \@rows);
}

sub _pageRow {
    my ($client, $key, $target, $name, $image) = @_;
    return {
        name        => $name,
        type        => 'link',
        image       => $image,
        nextWindow  => 'refresh',
        passthrough => [{ key => $key, target => $target }],
        url         => sub {
            my ($c, $cb, $a, $p) = @_;
            my $ctx = $pageState{ _cid($c) } ||= {};
            # Collapsing back to the cap clears the key rather than storing the
            # default, so an unpaged section leaves no residue.
            if ($p->{target} <= PAGE_SIZE) { delete $ctx->{ $p->{key} } }
            else                           { $ctx->{ $p->{key} } = $p->{target} }
            $cb->({ items => [] });
        },
    };
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

    # The landing is just the per-week sections — one drill-in per week-commencing,
    # each paged 30-at-a-time. The old "Show all" entry was removed (0.9.87): it
    # duplicated the same releases the dated weeks already cover, but as one
    # unpaged full-list dump, so it was the path that still flooded. The dated
    # weeks with "Show more" serve the same purpose and stay manageable.
    my @items;

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
        my $key   = "arweek:$ws";
        push @items, {
            name        => _weekLabel($client, $ws),
            type        => 'link',
            image       => _weekBadgeImage($ws),
            passthrough => [{}],
            url         => sub {
                my ($c, $cb) = @_;
                # Sort by the SHARED, durable All Releases sort (all_sort) — the
                # same order in every week, and it sticks across visits/restarts —
                # then cap at PAGE_SIZE with the "Show more"/"Show all" reveal (an
                # All Releases week can list hundreds of releases). Paging is still
                # per-week module state (keyed "arweek:<ws>"); re-sorting/paging
                # re-walks this coderef, which re-reads the pref. Options header +
                # sort toggle sit on top.
                my $mode  = $prefs->get('all_sort') || 'release_date';
                _warmArtistSorts($rels) if $mode eq 'artist';
                my @tiles = map { _buildReleaseItem($_, $c) } @{ _sortWithin($rels, $mode) };
                my ($vis, $pgRows) = _pageSection($c, $key, \@tiles);
                my @opt = ( _sortToggle($c, 'all_sort', $mode) );
                $cb->({ items => [ _sectionHeader($c, 'PLUGIN_LBF_SECTION_OPTIONS', $headers, \@opt),
                                   @opt, @$vis, @$pgRows ] });
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
    my ($releases, $client, $headers, $mode) = @_;

    # Real header item for Material (bold, accent colour); plain text elsewhere.
    # _headerType() => 'header-basic' on Material 6.4.3+ (a non-actionable divider,
    # so the week row isn't drawn as a grid card), else the long-standing 'header'.
    my $divType = $headers ? _headerType() : 'text';

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
        # Sort the releases WITHIN this week by the chosen Options mode; the week
        # buckets themselves stay in date order (newest week first).
        my $rels = _sortWithin($bucket{$ws}, $mode);

        # Give the header an image. Material's grid detection counts headers too
        # (older versions: image-less item → haveWithoutIcons → grid/list toggle
        # disabled for the whole page). With every item carrying an image the grid
        # view stays available, and the header still renders as a divider. (Same
        # approach as the Listen to Later plugin.)
        my $hdr = { name => _weekLabel($client, $ws), type => $divType, image => ICON };
        if ($headers) {
            # Material renders header items with a drill action that XMLBrowser
            # forces on (can't be suppressed); rather than lead nowhere, point it
            # at this week's releases (the same already-sorted $rels shown below).
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
# Build a single OPML item from one release
# ---------------------------------------------------------------------------
sub _buildReleaseItem {
    my ($rel, $client) = @_;

    my $artist     = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') || 'Unknown Artist';
    my $album      = _pickValue($rel, 'release_name', 'title', 'name') || 'Unknown Album';
    my $date       = $rel->{release_date} // '';
    my $type       = _displayType($rel);   # includes the secondary type, e.g. "Album / Live"
    my $mbid       = $rel->{release_mbid} // '';
    my $rgMbid     = $rel->{release_group_mbid} // '';
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

    # Tap-through to the detail page whenever we have EITHER a release MBID (LB) or
    # just a release-group MBID (MuSpy). The detail page degrades gracefully: with
    # only a release-group MBID it still shows streaming matches, genres and the
    # artist bio — only the MusicBrainz tracklist (which needs a release MBID) is
    # absent (see _releaseDetail's $wantTracks gate).
    if ($mbid || $rgMbid) {
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
    my $year   = ($rel->{release_date} && $rel->{release_date} =~ /(\d{4})/) ? $1 : undef;

    my @streamItems;   # playable streaming matches
    my @trackItems;    # tracklist (from the release)
    my $mbGenres;      # arrayref: genres from the MusicBrainz release-group
    my $lfmGenres;     # arrayref: tags from Last.fm (fallback)
    my $bio;           # artist biography text (MAI plugin or Last.fm)
    my $artistImg;     # artist photo url (MAI only)

    # Auto-search runs for the non-Bandcamp services (Qobuz/Tidal). Bandcamp is a
    # manual action only (see _searchBandcampOnly) — offered whenever its plugin is
    # installed and play-via is on, regardless of the auto result.
    my $playVia    = $prefs->get('play_via') && length $album;
    # Route through _findPlayable whenever ANY service is enabled (not just the
    # auto-searched ones): it surfaces a persisted manual Bandcamp match too, so a
    # Bandcamp-only release shows even when Bandcamp is the only enabled service.
    my $wantStream  = ($playVia && scalar(_orderedAdapters())) ? 1 : 0;
    my $canBandcamp = ($playVia && (grep { $_->{name} eq 'Bandcamp' } _orderedAdapters())) ? 1 : 0;
    my $wantGenres = $rgMbid ? 1 : 0;
    my $wantLastfm = ($prefs->get('lastfm_api_key') && (length $artist || length $album)) ? 1 : 0;
    my $wantTracks = $mbid   ? 1 : 0;
    my $wantArtist = length $artist ? 1 : 0;

    # Count all tasks up front: a cache hit completes its callback synchronously,
    # so per-task incrementing could let the barrier fire after the first one
    # finishes (before the others launched) and drop their data.
    my $pending = $wantStream + $wantGenres + $wantLastfm + $wantTracks + $wantArtist;
    my $done    = 0;
    my $watchdog;

    my $finish = sub {
        my ($force) = @_;
        return if $done;
        return if !$force && $pending > 0;   # $force (watchdog) renders regardless
        $done = 1;
        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;   # cancel the unused watchdog
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
        # Manual "Search Bandcamp" — Bandcamp isn't auto-searched (it blocks the
        # loop), so offer it as a deliberate one-tap action. It searches, caches
        # the match and re-renders this page so the match shows inline (above). The
        # row's label depends on state: a "Re-search Bandcamp" action when a match
        # is already shown (force-refresh a stale match — kept if the re-search
        # comes back empty), a "retry" prompt after a prior empty search, else a
        # plain "Search Bandcamp".
        if ($canBandcamp) {
            my $bcMatched = grep { ($_->{_svc} // '') eq 'Bandcamp' } @streamItems;
            if ($bcMatched) {
                push @streamRows, _bandcampSearchRow($client, $artist, $album, $mbid,
                    'PLUGIN_LBF_RESEARCH_BANDCAMP', MENU_REFRESH, $year, $rel);
            }
            else {
                my $bcSearched = $cache->get(_bcMarkerKey(_streamId($artist, $album, $mbid)));
                push @streamRows, _bandcampSearchRow($client, $artist, $album, $mbid,
                    $bcSearched ? 'PLUGIN_LBF_SEARCH_BANDCAMP_RETRY' : 'PLUGIN_LBF_SEARCH_BANDCAMP', undef, $year, $rel);
            }
        }
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
    $watchdog = Slim::Utils::Timers::setTimer(undef, time() + DETAIL_TIMEOUT, sub { $finish->(1) });

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
                    $cache->remove(_streamKey(_streamId($artist, $album, $mbid)));
                    $cache->remove(_bcMarkerKey(_streamId($artist, $album, $mbid)));
                    $cb->({ items => [] });
                },
            } if $mbid;
            $pending--;
            $finish->();
        }, $artist, $album, $mbid, undef, $year, $rel->{release_group_primary_type});
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

    my $artist = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') || 'Unknown Artist';

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

    my $album = _pickValue($rel, 'release_name', 'title', 'name') || 'Unknown Album';
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
        run => \&_searchQobuz, runTrack => \&_searchQobuzTrack, query_enc => 'chars',
    } if Plugins::Qobuz::Plugin->can('getAPIHandler')
      && Plugins::Qobuz::Plugin->can('_albumItem');

    push @adapters, {
        name => 'Bandcamp', icon => _pluginIcon('Plugins::Bandcamp::Plugin'),
        run => \&_searchBandcamp, runTrack => \&_searchBandcampTrack, query_enc => 'bytes',
    } if Plugins::Bandcamp::Plugin->can('album_list');

    push @adapters, {
        name => 'Tidal', icon => _pluginIcon('Plugins::TIDAL::Plugin'),
        run => \&_searchTidal, runTrack => \&_searchTidalTrack, query_enc => 'chars',
    } if Plugins::TIDAL::Plugin->can('getAPIHandler')
      && Plugins::TIDAL::Plugin->can('getAlbum')
      && Plugins::TIDAL::Plugin->can('_renderAlbum');

    # Deezer — same modern Michael-Herger plugin family as Qobuz/Tidal. Album nodes
    # from `_renderAlbum` carry a COREF `url` (\&getAlbum, id in passthrough) exactly
    # like Tidal — reattached in _rebuildStreamItems; the `deezer://album:<id>` string
    # is the `play`/favourites value. Tracks (`_renderTrack`) carry a plain string url
    # (deezer://<id>.<fmt>). getAlbum is required so a cached album match can be rebuilt
    # (else it would drop on re-read). Fails safe: absent method → service doesn't
    # register. Confirmed against michaelherger/lms-deezer.
    push @adapters, {
        name => 'Deezer', icon => _pluginIcon('Plugins::Deezer::Plugin'),
        run => \&_searchDeezer, runTrack => \&_searchDeezerTrack, query_enc => 'bytes',
    } if Plugins::Deezer::Plugin->can('getAPIHandler')
      && Plugins::Deezer::Plugin->can('_renderAlbum')
      && Plugins::Deezer::Plugin->can('_renderTrack')
      && Plugins::Deezer::Plugin->can('getAlbum');

    # Spotify — via the Spotty plugin, an OLDER, independent codebase (not the
    # Michael-Herger Qobuz/Tidal/Deezer family): getAPIHandler is a CLASS method
    # (returns undef with no client OR no Spotty account), the renderers live in
    # OPML.pm (not Plugin.pm), and search results arrive pre-normalized. Album
    # nodes from OPML::_albumItem carry a CODEREF `url` (\&OPML::album, the
    # spotify:album:<id> uri in passthrough) like Tidal/Deezer — reattached in
    # _rebuildStreamItems. Tracks render via OPML::trackList (plain string
    # spotify://track:<id> urls). OPML.pm is `use`d by Spotty's Plugin.pm, so its
    # methods are loaded whenever the plugin is enabled; ->can on the absent
    # package is safe, and a missing method → the service doesn't register.
    # Confirmed against the deployed Spotty source.
    push @adapters, {
        name => 'Spotify', icon => _pluginIcon('Plugins::Spotty::Plugin'),
        run => \&_searchSpotify, runTrack => \&_searchSpotifyTrack, query_enc => 'chars',
    } if Plugins::Spotty::Plugin->can('getAPIHandler')
      && Plugins::Spotty::OPML->can('_albumItem')
      && Plugins::Spotty::OPML->can('trackList')
      && Plugins::Spotty::OPML->can('album');

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
# $enabled (optional) is a precomputed { lc-name => 1 } set of currently-enabled
# adapters — pass it when filtering a whole list so we don't rebuild the adapter
# set (three ->can probes + prefs reads) once per item. Built on demand otherwise.
sub _cachedSvcUsable {
    my ($svc, $enabled) = @_;
    return 1 if !defined $svc || $svc eq '' || lc $svc eq 'library';
    $enabled ||= { map { lc($_->{name}) => 1 } _orderedAdapters() };
    return $enabled->{ lc $svc } ? 1 : 0;
}

# Detection + priority for every service we know how to integrate (installed or
# not), in display order — drives the settings page's "Streaming Services" list.
sub serviceStatus {
    my @known = (
        [ 'qobuz',    'Qobuz'    ],
        [ 'bandcamp', 'Bandcamp' ],
        [ 'tidal',    'Tidal'    ],
        [ 'deezer',   'Deezer'   ],
        [ 'spotify',  'Spotify'  ],
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

# Cache key for an album's streaming matches. Keyed by the current service
# CONFIGURATION (enabled+installed services in priority order, via
# _orderedAdapters) as well as the release id, so ANY change to the streaming
# setup — reordering priorities, disabling a service (priority 0), or
# (un)installing one — yields a different key. The detail page then RE-MATCHES
# against the new set on next open, automatically (no manual refresh), instead of
# serving stale links to a service the user no longer wants (or that's gone).
# Re-matching only happens when the config actually changes (a stable config hits
# the same key); the feed-list refresh is separate and never re-matches. Mirrors
# the playlist resolved cache, whose key already carries the service order.
sub _streamKey {
    my ($idPart) = @_;
    my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());
    # :18→:19 (0.9.110): matched album items gained `_year` (the service release
    # year, the trending lists' last date fallback) — re-resolve once to bake it in.
    my $key = 'lbf:stream:19:' . $svcOrder . ':' . ($idPart // '');
    utf8::encode($key) if utf8::is_utf8($key);   # octet key — non-Latin fallback can't crash md5
    return $key;
}

# The album-identifying part of a stream cache key: the MusicBrainz id when we
# have one, else the normalised "artist album" string. Shared by the auto search,
# the manual Bandcamp search and the detail render so all three agree on the key.
sub _streamId {
    my ($artist, $album, $mbid) = @_;
    return $mbid if defined $mbid && length $mbid;
    # Each part is already normalised and empties are filtered before the join, so
    # the joined string is itself normalised — no outer _norm needed. (Keep the
    # output byte-identical: this string is a cache-key component, not a matcher.)
    return join(' ', grep { length } _norm($artist), _norm($album));
}

# Marker recording that a manual Bandcamp search has already run for this album,
# so the detail page can show a "not found — retry" prompt rather than a fresh
# "Search Bandcamp" when Bandcamp returned nothing. Keyed on the album id only
# (not the service order — a Bandcamp miss doesn't depend on the Qobuz/Tidal set).
sub _bcMarkerKey {
    my ($idPart) = @_;
    my $key = 'lbf:bcdone:6:' . ($idPart // '');
    utf8::encode($key) if utf8::is_utf8($key);
    return $key;
}

# Long-lived store for a manually-found Bandcamp match (url stripped, reattached
# on read). Separate from the auto Qobuz/Tidal cache and NOT keyed on service
# order — a Bandcamp match is intrinsic to the album. _findPlayable appends it to
# every render so a Bandcamp-only release stays playable / primary.
# DELIBERATELY NOT bumped for the ListenLater favurl (kept at :6:): unlike the auto
# play-via cache (_streamKey), this key has NO automatic repopulation — a Bandcamp
# match only comes back via a manual "Search Bandcamp" tap. Bumping it would silently
# drop every hand-curated Bandcamp-only match on update (its sole playable entry).
# A fresh search bakes the favurl in (_searchBandcampOnly → _attachFavUrl); an older
# cached match simply keeps playing without the favurl until it's re-searched.
sub _bcMatchKey {
    my ($idPart) = @_;
    my $key = 'lbf:bcmatch:6:' . ($idPart // '');
    utf8::encode($key) if utf8::is_utf8($key);
    return $key;
}

# Find the release on installed streaming services and present each service's
# matching album as a directly-playable node (one tap to play / add), using
# each plugin's own search API rather than a generic search drill-down.
sub _findPlayable {
    my ($client, $callback, $artist, $album, $mbid, $force, $year, $type) = @_;

    my $albumNorm  = _norm($album);
    my $artistNorm = _norm($artist);

    # Type consistency (0.9.89): when the release being resolved is NOT itself a single,
    # a same-named SINGLE on the service must not stand in for the album (field bug —
    # an album resolved to a like-named single of the same year, which year/title alone
    # can't separate). Each candidate is classified by the service's own data
    # (_candReleaseType → album/single/ep), and single-typed candidates are dropped, per
    # service, KEEPING ALL if that would empty a service's matches (a service that only
    # lists the single, or an unreliable type field, still yields a match). This lives
    # OUTSIDE the shared matcher (_albumMatches/_norm), so it's LBF-only — no fleet sync,
    # and Discography's own EP/single handling is untouched (Discography has no candidate
    # type-matching at all — it disambiguates by year+ownership; this classifier is a new,
    # portable building block). Applied before caching, so a cache hit reflects it too.
    #
    # Fires ONLY when the release's own type is KNOWN and is not itself a single: a single
    # release (LBF lets users include singles) still matches a single, and an unknown/blank
    # type is left unfiltered (never risk dropping the only match on missing metadata).
    my $tnorm       = lc($type // '');
    # EP targets are EXCLUDED from the single-drop: a legitimate 2-track EP can be
    # track-count-classified as a "single" by _candReleaseType (no explicit type field),
    # so dropping singles for an EP target risks discarding the correct match in favour of
    # a like-named rival. Album/compilation targets (primary type 'album') still shed a
    # same-named single — the 0.9.89 case. Unknown/blank type is never filtered.
    my $dropSingles = $tnorm ne '' && $tnorm ne 'single' && $tnorm ne 'ep';

    # Search the ARTIST only, then filter the results by album title locally
    # (_albumMatches). Searching "artist album" as one string made the services'
    # own fuzzy search rank/drop the target — Tidal missed "Sweating Someone
    # Else's Fever", Qobuz missed "Placebo RE:CREATED" — whereas an artist search
    # returns the discography and we pick the album ourselves. Far better recall;
    # _albumMatches still guarantees the right album AND artist, so the broader
    # query can't admit a wrong album.
    my $query      = $artistNorm;   # normalised form — for logging only
    # Send the RAW artist to the service search, NOT the normalised form: the
    # normaliser turns punctuation into spaces, which mangles stylised artist names
    # ("P!nk" -> "p nk", "will.i.am" -> "will i am") so the service's own search
    # can't find them — the same bug that lost the L.U.C.K.Y track. Normalisation
    # stays for our _albumMatches validation only. Built in BOTH spellings: the
    # service plugins' URL layers differ — Qobuz escapes with uri_escape_utf8 and
    # Tidal transliterates with Text::Unidecode, both needing CHARACTER strings
    # (octets double-encode: "Sigur Rós" searched as "Sigur RÃ³s" -> junk/empty
    # results; found + fixed in the Discography plugin 2026-07-10) — Spotty also
    # escapes with uri_escape_utf8, so it's in the character camp — while
    # Deezer's complex_to_query and Bandcamp want OCTETS. Each adapter's
    # query_enc picks its spelling at the call site.
    my $qChars     = $artist;
    utf8::decode($qChars) unless utf8::is_utf8($qChars);   # no-op if not valid UTF-8
    my $qBytes     = $artist;
    utf8::encode($qBytes) if utf8::is_utf8($qBytes);

    # Bandcamp is deliberately NOT auto-searched: its plugin search is
    # cookie-dependent / often broken AND does heavy SYNCHRONOUS response-parsing
    # that blocks the event loop when it returns data (confirmed by loop-stall
    # probing). It's offered as a manual "Search Bandcamp" action on the detail
    # page instead (_searchBandcampOnly) — one deliberate tap, never on auto-open.
    # BUT a match found by a previous manual search is persisted (_bcMatchItems)
    # and appended to every result below, so a Bandcamp-only release stays playable
    # and — when no other service has it — is the primary (sole) entry.
    my $id       = _streamId($artist, $album, $mbid);
    my @bc       = _bcMatchItems($id);
    my @adapters = grep { $_->{name} ne 'Bandcamp' } _orderedAdapters();

    # No auto-searchable service (e.g. only Bandcamp enabled): show the persisted
    # Bandcamp match if there is one, else the no-match placeholder.
    unless (@adapters) {
        $callback->({ items => _streamResult($client, [], \@bc) });
        return;
    }

    # Cache hit → rebuild the playable items from the stored data (no re-search).
    # The key is versioned so a change to the matching logic invalidates stale
    # entries; the current version and its history live on _streamKey (don't restate
    # the version number here — it drifts). $force (manual refresh) skips the read so
    # the services are searched again. The id part stays album-specific (the query
    # itself is now artist-only).
    my $key = _streamKey($id);
    if (!$force && (my $c = $cache->get($key))) {
        $log->info("play-via cache hit: $key (" . scalar(@{ $c->{items} || [] }) . " match(es))");
        $callback->({ items => _streamResult($client, _rebuildStreamItems($c->{items}), \@bc) });
        return;
    }

    # Search every service in PARALLEL, but resolve to the highest-priority service
    # that matched, as soon as that's decided — i.e. once every higher-priority
    # service has come back (matched or not). Each service has its own timeout so a
    # slow/hung one is treated as "no match" and can't stall the result. The chosen
    # service's matches (or an empty result if nothing matched) are cached.
    my @result       = map { undef } @adapters;   # undef = pending, [] = miss, [..] = match
    my $resolved     = 0;
    my $inconclusive = 0;   # services that couldn't be queried (no handler / timeout / error)

    my $resolve = sub {
        return if $resolved;
        my $win;
        for my $i (0 .. $#adapters) {
            return if !defined $result[$i];     # a higher-priority service is still pending
            if (@{ $result[$i] }) { $win = $i; last; }
        }
        $resolved = 1;
        my $items = defined $win ? $result[$win] : [];
        # A miss caused (wholly or partly) by a service we couldn't query is
        # inconclusive → cache it briefly so it retries soon, rather than pinning a
        # transient outage as a confirmed no-match for the day (mirrors the track path).
        my $ttl = @$items       ? STREAM_FOUND_TTL
                : $inconclusive ? STREAM_INCONCLUSIVE_TTL
                :                 STREAM_NOMATCH_TTL;
        _cacheStream($key, $items, $ttl);
        $log->info("play-via '$query': "
            . (defined $win ? "matched on $adapters[$win]{name} (" . scalar(@$items) . ")"
                            : "no match on any service" . ($inconclusive ? " ($inconclusive inconclusive — short TTL)" : "")));
        $callback->({ items => _streamResult($client, $items, \@bc) });
    };

    for my $i (0 .. $#adapters) {
        my $a    = $adapters[$i];
        my $svc  = $a->{name};
        my $icon = $a->{icon};

        my $settled = 0;
        my $svcTimer;
        my $settle  = sub {
            return if $settled || $resolved;
            $settled = 1;
            Slim::Utils::Timers::killSpecific($svcTimer) if $svcTimer;   # cancel this service's timeout
            # undef arg = the service couldn't be queried (no API handler / timeout /
            # error / broken renderer) → contributes no match, but INCONCLUSIVELY (a
            # short-TTL retry), not a confirmed miss. Same signal as the track path.
            if (!defined $_[0]) {
                $inconclusive++;
                $result[$i] = [];
                $resolve->();
                return;
            }
            my @matched = (ref $_[0] eq 'ARRAY') ? @{ $_[0] } : ();
            # Type consistency (see the $dropSingles note above): for a non-single
            # release, drop candidates this service classified as a single, but keep the
            # whole set if that would leave nothing (fall back rather than lose the match).
            if ($dropSingles && @matched) {
                my @keep = grep { ($_->{_ctype} // '') ne 'single' } @matched;
                if (@keep && @keep != @matched) {
                    $log->info("play-via $svc: dropped " . (@matched - @keep) . " single(s) for non-single release");
                    @matched = @keep;
                }
            }
            for my $it (@matched) {
                my $art = $it->{image};          # native album cover, before the logo override
                $it->{image} = $icon if $icon;   # service logo as thumbnail (LBF detail view)
                $it->{_svc}  = $svc;             # for cache rebuild
                _attachFavUrl($it, $svc, $art, $artist, $year);  # qobuz://album:<id>?cover=<art>&a=<artist>&y=<year> for ListenLater
            }
            $result[$i] = \@matched;
            $resolve->();
        };

        # Per-service timeout → inconclusive (not a confirmed miss) so a slow/hung
        # service retries soon rather than caching a false no-match for the day.
        $svcTimer = Slim::Utils::Timers::setTimer(undef, time() + STREAM_SVC_TIMEOUT, sub {
            return if $settled || $resolved;
            $log->warn("play-via $svc timed out");
            $settle->(undef);
        });

        my $queryEnc = ($a->{query_enc} || 'bytes') eq 'chars' ? $qChars : $qBytes;
        eval { $a->{run}->($client, $queryEnc, $artistNorm, $albumNorm, $svc, $settle, $album); 1 } or do {
            $log->warn("play-via $svc failed: $@");
            $settle->(undef);
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

# Decorate a matched streaming album item with a ListenLater-friendly favorites_url:
#   <scheme>://album:<nativeId>[?cover=<url-encoded album art>]
# The row's own `image` is the service LOGO (so the LBF detail page shows which
# service the match is on), so $IMAGE can't carry the cover — the album art rides
# the favurl as a private ?cover= param instead. ListenLater reads the scheme as the
# source + service indicator, the album:<id> for direct replay, and the cover param
# as the stored artwork (it strips the param before saving, so its own replay/source
# logic sees a clean URL). The param is opaque to Material, which just forwards the
# favurl. XMLBrowser copies an explicit $item->{favorites_url} into
# presetParams.favorites_url (= $item->{favorites_url} || $item->{play} || $item->{url}),
# which Material exposes as $FAVURL — without this the coderef `url` leaked through as
# the favurl (the "broken link"). No native id → no favurl (the row still displays
# and plays in LBF; it just can't be added to ListenLater with full fidelity).
sub _attachFavUrl {
    my ($it, $svc, $art, $artist, $year) = @_;

    # Spotify is EXEMPT — the one service whose renderer already ships a WORKING
    # native favorites_url: Spotty's _albumItem sets it to the spotify:album:<id>
    # uri, which Spotty itself replays (explodePlaylist → tracksFromURI → album).
    # Overwriting it with the decorated <svc>://album:<id>?cover=… scheme would
    # REGRESS a natively-saved favourite: Spotty's album() extracts the id with
    # /album:(.*)/, so the query string would be captured INTO the id and the
    # albums/<id> API call errors → empty tracklist on replay. For Qobuz/Tidal/
    # Deezer there was no working favurl to preserve (their renderers leaked a
    # broken coderef — the reason this decorator exists), so only Spotify keeps
    # its own. Nothing is lost: ListenLater has no spotify source support.
    return if $svc eq 'Spotify';

    my $id = $it->{_albumid};
    return unless defined $id && length $id;
    my $fav = lc($svc) . '://album:' . $id;   # scheme = ListenLater's qobuz/tidal/bandcamp source tag
    my @params;

    my $url = $it->{_albumurl};               # Bandcamp only: the album PAGE url (exact get_album replay key)
    if (defined $url && !ref $url && length $url) {
        # Bandcamp: pack the cover art AND the album page url into ONE escaped param so
        # ListenLater can replay the EXACT album (get_album needs the page url, not the
        # id). Single 'art|url' blob, escaped as a whole → no literal '?'/'&'/'|' → it
        # parses just like a lone '?cover='. The result is longer (~164 chars) and is
        # confirmed to survive Material's custom-action transport intact (an earlier
        # "long favurls get dropped" worry turned out to be a shadowed-install artifact,
        # not real). ListenLater still keeps an album_id-resolve safety net regardless.
        require URI::Escape;
        my $blob = (defined $art && !ref $art ? $art : '') . '|' . $url;
        push @params, 'b=' . URI::Escape::uri_escape_utf8($blob);
    }
    elsif (defined $art && !ref $art && length $art) {   # plain URL string only (not a coderef/other ref)
        require URI::Escape;
        push @params, 'cover=' . URI::Escape::uri_escape_utf8($art);   # _utf8 variant: a wide-char art URL can't carp/emit a malformed escape
    }

    # Pack the release artist too. Material sends these matched rows NO $ARTISTNAME —
    # the row image is the service LOGO and its subtitle isn't mapped — so ListenLater
    # would store an artist-less record, which then never auto-moves to Played (its
    # per-source dedupe key needs the artist). A private '&a=' param (opaque to Material,
    # same handshake as ?cover=/?b=) carries it; ListenLater reads it as a fallback when
    # $ARTISTNAME is empty, then strips it. Bandcamp rows already surface an artist, so
    # this is belt-and-braces there.
    if (defined $artist && !ref $artist && length $artist) {
        require URI::Escape;
        push @params, 'a=' . URI::Escape::uri_escape_utf8($artist);
    }

    # And the release year, so ListenLater's dedupe key (artist|album|year) tells two
    # same-titled releases from different years apart — otherwise the second one added
    # is silently dropped as a duplicate. Bare 4-digit, no escaping needed.
    if (defined $year && $year =~ /^\d{4}$/) {
        push @params, 'y=' . $year;
    }

    $fav .= '?' . join('&', @params) if @params;
    $it->{favorites_url} = $fav;
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
# $pinned (optional) is a list of items that must always survive — the persisted
# manual Bandcamp match. Only the auto (Qobuz/Tidal) matches are capped at
# STREAM_MAX_RESULTS; the pinned items are appended AFTER the cap so an abundant
# generic-title match (12+ hits) can't truncate a hand-curated Bandcamp-only entry
# out — the very case where it's meant to be the primary/sole playable row. Deduped
# across both so an item that both auto-matched and is pinned isn't shown twice.
sub _streamResult {
    my ($client, $items, $pinned) = @_;
    $items = _dedupeStreamItems($items);
    $items = [ @{$items}[0 .. STREAM_MAX_RESULTS - 1] ] if @$items > STREAM_MAX_RESULTS;
    my $out = _dedupeStreamItems([ @$items, @{ $pinned || [] } ]);
    return @$out
        ? $out
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
        elsif ($svc eq 'Deezer' && Plugins::Deezer::Plugin->can('getAlbum')) {
            # Deezer album nodes are the same shape as Tidal's: `_renderAlbum` sets
            # `url => \&getAlbum` (a COREF, stripped on cache) and keeps the album id
            # in `passthrough` (plain data, survives the cache), so getAlbum resolves
            # the tracklist on read. Without this branch a cached Deezer match hit the
            # `else { next }` below and silently vanished on re-read (fixed 0.9.76).
            $item{url} = \&Plugins::Deezer::Plugin::getAlbum;
        }
        elsif ($svc eq 'Spotify' && Plugins::Spotty::OPML->can('album')) {
            # Spotify album nodes are the Tidal/Deezer shape too — Spotty's OPML
            # `_albumItem` sets `url => \&OPML::album` (a CODEREF, stripped on
            # cache) and keeps the spotify:album:<id> uri in `passthrough` (plain
            # data, survives the cache), so OPML::album resolves the tracklist on
            # read. Only the renderer's home differs (OPML.pm, not Plugin.pm).
            $item{url} = \&Plugins::Spotty::OPML::album;
        }
        else {
            next;
        }

        push @out, \%item;
    }

    return \@out;
}

# Rebuild the persisted manual Bandcamp match (if any) into live, playable items.
# Returns () when there's no stored match or Bandcamp is currently disabled
# (_rebuildStreamItems drops items whose service isn't enabled), so disabling
# Bandcamp hides it without discarding the stored match.
sub _bcMatchItems {
    my ($id) = @_;
    my $c = $cache->get(_bcMatchKey($id));
    return () unless $c && ref $c->{items} eq 'ARRAY' && @{ $c->{items} };
    return @{ _rebuildStreamItems($c->{items}) };
}

# Qobuz: search albums via the plugin's own API, keep title matches, and reuse
# the plugin's _albumItem so each result is a native, playable album node.
# Classify a streaming candidate's release type (album / single / ep / '') from the
# service's OWN album data, so a non-single release isn't resolved to a like-named single
# (0.9.89 — the type filter in _findPlayable uses this). Deliberately CONSERVATIVE: it
# only commits to 'single'/'ep' when the service is clear, else '' (unknown = keep). An
# explicit trusted type field wins (Qobuz release_type, Deezer record_type, Spotify
# album_type, TIDAL type — album_type sits BEFORE type as DEFENSIVE ordering: Spotify's
# raw `type` is the OBJECT type, but Spotty's Cache normalize() deletes it unconditionally
# (_removeUnused), so it can't reach us today; the ordering just guarantees it could never
# be misread as a release type if that changes);
# otherwise the track count decides — a real ALBUM never has 1-2 tracks, so a low count is
# a safe single signal, while a many-track album (even if mistyped) stays unflagged. Field
# names verified per plugin: Qobuz tracks_count, Deezer nb_tracks, TIDAL numberOfTracks,
# Spotify total_tracks.
sub _candReleaseType {
    my ($album) = @_;
    return '' unless ref $album eq 'HASH';

    for my $f (qw(release_type record_type album_type type)) {
        my $t = lc($album->{$f} // '');
        next unless $t;
        return 'single' if $t eq 'single';
        return 'ep'     if $t eq 'ep' || $t eq 'epmini';
        return 'album'  if $t eq 'album' || $t eq 'compile' || $t eq 'compilation';
        # unrecognised value → fall through to the track-count heuristic
    }

    my $tc = $album->{tracks_count} // $album->{nb_tracks} // $album->{numberOfTracks} // $album->{total_tracks};
    return '' unless defined $tc && "$tc" =~ /^\d+$/;
    return 'single' if $tc <= 2;
    return '';   # 3+ tracks: don't presume EP-vs-album — only the single case matters here
}

# Extract a release YEAR from a streaming service's RAW result hash — the LAST
# date fallback for the People You Follow rows: when a track/album is unmapped on
# ListenBrainz AND absent from MusicBrainz, the streaming catalogue still knows
# its date (Qobuz release_date_original / released_at epoch, Tidal releaseDate,
# Deezer release_date). Each adapter tags its matched items `_year` from this
# (a plain scalar, so it survives the Storable stream/track caches); the trending
# renders read it only when the source data had no year of its own.
sub _svcYear {
    my (@hashes) = @_;
    for my $h (@hashes) {
        next unless ref $h eq 'HASH';
        for my $k (qw(release_date_original release_date releaseDate date streamStartDate)) {
            my $v = $h->{$k};
            return $1 if defined $v && !ref $v && $v =~ /^(\d{4})/;
        }
        my $e = $h->{released_at};   # Qobuz epoch variant
        if (defined $e && !ref $e && $e =~ /^\d{9,}$/) {
            return (localtime($e))[5] + 1900;
        }
        return $1 if defined $h->{year} && !ref $h->{year} && $h->{year} =~ /^(\d{4})/;
    }
    return '';
}

sub _searchQobuz {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;

    my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
    # undef (not []) → "couldn't query" → inconclusive, so a transient missing
    # handler isn't cached as a durable no-match (see _findPlayable).
    unless ($api) {
        $collect->(undef);
        return;
    }

    $api->search(sub {
        my $res = shift;
        # No response at all → the search errored, not "no results" → inconclusive.
        return $collect->(undef) unless defined $res;
        my @out;
        my $rendererFailed = 0;
        for my $album (@{ ($res && $res->{albums} && $res->{albums}{items}) || [] }) {
            my $candArtist = ref $album->{artist} eq 'HASH' ? $album->{artist}{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title}, $albumRaw);
            # Qobuz's catalogue sometimes carries a bogus partial/orphaned duplicate of a
            # release that isn't actually playable (e.g. Beth Orton – The Ground Above lists
            # two, only one playable). The duplicate is flagged NON-STREAMABLE, so dropping a
            # candidate whose `streamable` is explicitly false is enough to remove it —
            # confirmed live (0.9.44). (The earlier "*"-prefixed-title heuristic was removed:
            # _norm strips a leading "*" so it never actually distinguished the two, and a real
            # album can be legitimately "*"-titled.)
            next if defined $album->{streamable} && !$album->{streamable};
            # Guard the foreign renderer: a die here runs INSIDE this async search
            # callback (not under _findPlayable's invocation-time eval), so an
            # unguarded throw would leave the service un-settled until its 8s
            # timeout. Skip a bad item instead (mirrors the track path's _renderTrack).
            my $item = eval { Plugins::Qobuz::Plugin::_albumItem($client, $album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Qobuz _albumItem failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            $item->{_albumid} = $album->{id};   # native id → ListenLater favurl (album:<id>)
            $item->{_ctype}   = _candReleaseType($album);   # album/single/ep — for the type filter
            $item->{_year}    = _svcYear($album);           # service release year (trending date fallback)
            push @out, $item;
        }
        # Matched the album but the renderer produced nothing usable → inconclusive
        # (the service HAD it; a broken/changed renderer mustn't cache a false
        # no-match for the day). A clean empty (nothing matched) stays a real miss.
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, lc($query), 'albums');
}

# Bandcamp: run the plugin's combined search, keep the album results (identified
# by an album_id in their passthrough — they're already playable album nodes).
sub _searchBandcamp {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;

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
            next unless _albumMatches($artistNorm, $albumNorm, $pt->{artist}, $pt->{title}, $albumRaw);
            $it->{_albumid}  = $pt->{album_id};               # native id → ListenLater favurl (album:<id>)
            $it->{_albumurl} = $pt->{album_url} || $pt->{url}; # album PAGE url → packed into the favurl ?b= blob (exact Bandcamp replay key)
            push @out, $it;
        }
        $collect->(\@out);
    }, { search => $query });
}

# The detail-page "Search Bandcamp" row: a deliberate one-tap manual search
# (Bandcamp is excluded from the auto search because it blocks the loop). It uses
# the SAME in-place refresh mechanism as the streaming "Refresh" row
# (nextWindow 'refresh'): the tap searches, persists any match (_bcMatchKey),
# then pops back so the detail page re-renders with the Bandcamp match shown
# INLINE in the Streaming section (not a separate sub-page) — and when no other
# service has the album it's the primary (sole) playable entry. $retry switches
# the label to the "not found — tap to retry" prompt after an empty search.
sub _bandcampSearchRow {
    my ($client, $artist, $album, $mbid, $labelKey, $icon, $year, $rel) = @_;
    $labelKey ||= 'PLUGIN_LBF_SEARCH_BANDCAMP';
    # nextWindow 'refresh' drives BOTH outcomes off one row (Material only honours
    # nextWindow when the response is EMPTY — browse-functions.js:834):
    #   • a MATCH returns candidate rows → a non-empty response, so Material pushes a
    #     new sub-page (a "choose" picker), ignoring nextWindow;
    #   • NO MATCH returns an empty list → nextWindow 'refresh' re-renders this detail
    #     page inline (the row flips to "…not found — tap to retry"), no dead-end page.
    return {
        name        => cstring($client, $labelKey),
        type        => 'link',
        image       => $icon || _pluginIcon('Plugins::Bandcamp::Plugin'),
        nextWindow  => 'refresh',
        passthrough => [{}],
        url         => sub {
            my ($c, $cb) = @_;
            _searchBandcampOnly($c, $cb, $artist, $album, $mbid, $year, $rel);
        },
    };
}

# Split a (possibly collaborative) artist credit into the FULL credit followed by
# each individual collaborator, so the manual Bandcamp search can also try each
# artist on its own. A "Panda Bear & Sonic Boom" release is frequently only
# surfaced by Bandcamp's search under ONE of the artists, not the combined string
# ("Panda Bear & Sonic Boom – A ? of WHEN" missed on the combined query but each
# artist carries it). Order-preserving + de-duplicated; a solo artist yields just
# the one name. Split only on clear collaboration separators (not " and "/","/"/"),
# which would wrongly split single-act names like "Belle and Sebastian" — an over-
# split only costs an extra search anyway, since _albumMatches still gates results.
sub _bandcampArtists {
    # Delegates to THE shared collab-credit splitter (API::splitArtistCredits) —
    # the 0.9.56 Panda Bear & Sonic Boom fix generalised, also used by the MB
    # release-group name-resolver. Keep the ladder in ONE place.
    my ($artist) = @_;
    return Plugins::ListenBrainzFreshReleases::API::splitArtistCredits($artist);
}

# Manual "Search Bandcamp" for the detail page. Bandcamp is excluded from the
# automatic search (heavy synchronous response-parsing blocks the loop when it
# returns data), so it runs ONLY on a deliberate user tap. A match is persisted in
# its own long-lived key (_bcMatchKey); _findPlayable appends it to every render,
# so it shows inline AND — when no other service has the album — is the primary
# (sole) playable entry, surviving auto re-search and the streaming Refresh.
# ON A MATCH: returns a "choose" picker — one NON-playable row per candidate. Tapping
# a candidate PINS it as this release's Bandcamp match and re-renders the detail page
# via _releaseDetail (a fresh drill, so Material arms the custom actions → the pinned
# match carries "Add to Listen Later / Wish List"). Nothing is pinned until the user
# chooses. ON A MISS: sets the "searched" marker and returns an EMPTY list, so the
# search row's nextWindow 'refresh' re-renders the detail page inline (row flips to
# "…not found — tap to retry") — no dead-end sub-page. See _bandcampSearchRow.
sub _searchBandcampOnly {
    my ($client, $cb, $artist, $album, $mbid, $year, $rel) = @_;

    my $artistNorm = _norm($artist);
    my $albumNorm  = _norm($album);

    my $id        = _streamId($artist, $album, $mbid);
    my $markerKey = _bcMarkerKey($id);

    # No match / error → mark searched (detail row offers a retry) and return EMPTY,
    # so nextWindow 'refresh' pops back and re-renders the detail page inline.
    my $noMatch = sub {
        $cache->set($markerKey, 1, STREAM_NOMATCH_TTL);
        $log->info("manual bandcamp '$artistNorm': no match");
        $cb->({ items => [] });
    };

    my ($bc) = grep { $_->{name} eq 'Bandcamp' } _streamingAdapters();
    return $noMatch->() unless $bc;

    # Ordered list of RAW search strings, most-specific first, tried in turn until
    # one yields an _albumMatches hit. Bandcamp recall is unlike Qobuz/Tidal — a
    # bare-artist search doesn't surface the album, so each query carries the album
    # title. RAW (un-normalised) so stylised names/titles aren't mangled before the
    # service's own search. _albumMatches still validates album+artist on every
    # result, so a broader/album-only query can't admit a wrong album.
    #   1. full "artist album" (the common case — collab indexed as one string)
    #   2. each collaborator + album (the "A & B" release only found under one artist)
    #   3. album title alone (last resort)
    my @queries;
    push @queries, join(' ', grep { length } $_, $album) for _bandcampArtists($artist);
    push @queries, $album if length $album;
    my %seenq;
    @queries = grep { length && !$seenq{ lc $_ }++ } @queries;

    my $done   = 0;
    my $bcTimer;
    my $finish = sub {
        return if $done; $done = 1;
        Slim::Utils::Timers::killSpecific($bcTimer) if $bcTimer;   # cancel the unused watchdog
        my @items = (ref $_[0] eq 'ARRAY') ? @{ $_[0] } : ();
        return $noMatch->() unless @items;

        # Build the "choose" picker: one NON-playable row per candidate, showing the
        # real album art + "Album / Artist". Tapping PINS that candidate (own long-lived
        # key, so it survives auto re-search and the Refresh) and re-renders the detail
        # page as a fresh drill — which shows the pinned match inline AND arms Material's
        # custom actions (Add to Listen Later / Wish List). The candidate is baked into
        # the exact same pinned form as before: service logo as the row image, with the
        # cover + page URL + artist + year carried on the favurl for Listen Later.
        my @rows;
        for my $cand (@items) {
            my $art  = $cand->{image};                          # real cover, before logo override
            my $name = $cand->{name} // $cand->{line1} // $album;
            $cand->{image} = $bc->{icon} if $bc->{icon};        # service logo (as inline detail rows)
            $cand->{_svc}  = 'Bandcamp';
            _attachFavUrl($cand, 'Bandcamp', $art, $artist, $year); # bandcamp://album:<id>?b=<art|url>&a=<artist>&y=<year>
            push @rows, {
                name        => $name,
                line2       => $artist,
                type        => 'link',
                image       => $art // $bc->{icon},
                passthrough => [{}],
                url         => sub {
                    my ($c, $cb2) = @_;
                    _cacheStream(_bcMatchKey($id), [$cand], BC_MATCH_TTL);
                    $cache->remove($markerKey);
                    $log->info("manual bandcamp: pinned '$name'");
                    # Re-render the album page as a fresh drill so it shows the match
                    # AND arms Add to Listen Later / Wish List. Fall back to an empty
                    # pop if we somehow have no release (shouldn't happen).
                    $rel ? _releaseDetail($rel, $c, $cb2) : $cb2->({ items => [] });
                },
            };
        }
        $log->info("manual bandcamp '$artistNorm': " . scalar(@rows) . " candidate(s)");
        # Lead with a prompt so it's clear the rows are tap-to-choose (not play).
        unshift @rows, { name => cstring($client, 'PLUGIN_LBF_CHOOSE_BANDCAMP'), type => 'text' };
        # cachetime => 0 so a re-tap always re-searches rather than showing a cached picker.
        $cb->({ items => \@rows, cachetime => 0 });
    };

    # Try each query in turn; the FIRST with a match wins (so the common combined
    # query still does a single search — extra searches happen only on a miss).
    # These run on a deliberate user tap, so a few sequential searches are fine.
    my $tryNext;
    $tryNext = sub {
        return if $done;   # watchdog (or a match) already finished us — don't start another search
        my $q = shift @queries;
        unless (defined $q) { $finish->([]); return; }   # queries exhausted → no match
        my $queryEnc = $q;
        utf8::encode($queryEnc) if utf8::is_utf8($queryEnc);
        $log->info("manual bandcamp: trying '$q'");
        eval {
            $bc->{run}->($client, $queryEnc, $artistNorm, $albumNorm, 'Bandcamp', sub {
                my @m = (ref $_[0] eq 'ARRAY') ? @{ $_[0] } : ();
                @m ? $finish->(\@m) : $tryNext->();
            }, $album);
            1;
        } or do { $log->warn("manual bandcamp search failed: $@"); $tryNext->(); };
    };

    # One overall watchdog covering all attempts (scaled by the query count, capped)
    # in case a search hangs — covers an async hang; a synchronous block can't be
    # bounded. $finish is idempotent, so a late callback after it fires is a no-op.
    my $budget = STREAM_SVC_TIMEOUT * scalar(@queries);
    $budget = 30 if $budget > 30;
    $bcTimer = Slim::Utils::Timers::setTimer(undef, time() + $budget, sub { $finish->([]) });

    $tryNext->();
}

# Tidal: search albums via the plugin's API handler, keep title+artist matches,
# and reuse the plugin's _renderAlbum so each result is a native, playable album
# node (url => getAlbum, plus play/add/insert itemActions keyed by album id).
sub _searchTidal {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;

    my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
    # undef (not []) → inconclusive (see _findPlayable / _searchQobuz).
    unless ($api) {
        $collect->(undef);
        return;
    }

    $api->search(sub {
        my $albums = shift;   # raw album hashes (type => albums search)
        # No response at all → the search errored, not "no results" → inconclusive.
        return $collect->(undef) unless defined $albums;
        my @out;
        my $rendererFailed = 0;
        for my $album (@{ $albums || [] }) {
            next unless ref $album eq 'HASH';
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title}, $albumRaw);
            # Guard the foreign renderer: a die here runs INSIDE this async search
            # callback (not under _findPlayable's invocation-time eval), so an
            # unguarded throw would leave the service un-settled until its 8s
            # timeout. Skip a bad item instead (mirrors the track path's _renderTrack).
            my $item = eval { Plugins::TIDAL::Plugin::_renderAlbum($album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Tidal _renderAlbum failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            $item->{_albumid} = $album->{id};   # native id → ListenLater favurl (album:<id>)
            $item->{_ctype}   = _candReleaseType($album);   # album/single/ep — for the type filter
            $item->{_year}    = _svcYear($album);           # service release year (trending date fallback)
            push @out, $item;
        }
        # Matched the album but the renderer produced nothing usable → inconclusive
        # (see _searchQobuz). A clean empty (nothing matched) stays a real miss.
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, { type => 'albums', search => $query, limit => 50 });   # artist-only search → fetch more so a prolific artist's target album isn't truncated
}

# Deezer album search — mirror of _searchTidal. getAPIHandler returns a
# Plugins::Deezer::API::Async whose ->search(cb, {search,type,strict}) calls back
# with a bare arrayref of raw result items (already typed by `type`); we filter by
# title/artist locally and render each hit via the plugin's own _renderAlbum
# (which sets play => deezer://album:<id>). Type is SINGULAR ('album') for Deezer.
sub _searchDeezer {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;

    my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
    # undef (not []) → inconclusive (see _findPlayable / _searchTidal).
    unless ($api) {
        $collect->(undef);
        return;
    }

    $api->search(sub {
        my $albums = shift;   # expected: bare arrayref of raw album hashes
        # No response at all → the search errored, not "no results" → inconclusive.
        return $collect->(undef) unless defined $albums;
        # Be tolerant of the response shape: lms-deezer is expected to hand back a bare
        # arrayref (Tidal-style), but accept a hash-wrapped list too so a shape mismatch
        # degrades to a clean miss instead of dying on a bad deref in this async callback
        # (which runs OUTSIDE _findPlayable's eval → would leave the service un-settled).
        $albums = $albums->{data} || $albums->{albums} || [] if ref $albums eq 'HASH';
        return $collect->([]) unless ref $albums eq 'ARRAY';
        my @out;
        my $rendererFailed = 0;
        for my $album (@$albums) {
            next unless ref $album eq 'HASH';
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title}, $albumRaw);
            # Guard the foreign renderer (dies here run inside this async callback,
            # not under _findPlayable's eval) — skip a bad item (mirrors _searchTidal).
            my $item = eval { Plugins::Deezer::Plugin::_renderAlbum($album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Deezer _renderAlbum failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            $item->{_albumid} = $album->{id};   # native id → ListenLater favurl (album:<id>)
            $item->{_ctype}   = _candReleaseType($album);   # album/single/ep — for the type filter
            $item->{_year}    = _svcYear($album);           # service release year (trending date fallback)
            push @out, $item;
        }
        # Matched but the renderer produced nothing usable → inconclusive (see _searchTidal).
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, { search => $query, type => 'album', strict => 'off', limit => 50 });
}

# Spotify album search — via the Spotty plugin. getAPIHandler is a CLASS method
# and returns undef with no client OR no Spotty account → inconclusive (exactly
# the missing-handler path of the other adapters). ->search(cb,{query,type,limit})
# runs through Spotty's Pipeline, which calls back with a bare arrayref of
# ALREADY-NORMALIZED album hashes ({name, artist, artists, uri, id, image,
# release_date, album_type, total_tracks}). CAVEAT (verified in the deployed
# source): the Pipeline swallows API errors — _gotError/_call feed its extractor
# an error HASH, whose ->{albums}{items} extracts to nothing — so an errored
# search arrives as the SAME empty arrayref as a genuine zero-hit search and is
# cached as a real miss. Only undef / a non-arrayref (never seen from this
# Pipeline, kept defensively) can signal inconclusive here; a Spotify outage can
# therefore pin a no-match for STREAM_NOMATCH_TTL — accepted, nothing upstream
# distinguishes the two. Rendering reuses OPML::_albumItem (url => \&OPML::album
# coderef + uri in passthrough — reattached by _rebuildStreamItems).
sub _searchSpotify {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;

    my $api = Plugins::Spotty::Plugin->getAPIHandler($client);
    # undef (not []) → inconclusive (see _findPlayable / _searchTidal).
    unless ($api) {
        $collect->(undef);
        return;
    }

    $api->search(sub {
        my $albums = shift;
        # No response / unexpected shape → treated as "couldn't query" → inconclusive
        # (defensive only — see the header note: this Pipeline always sends an arrayref).
        return $collect->(undef) unless defined $albums && ref $albums eq 'ARRAY';
        my @out;
        my $rendererFailed = 0;
        for my $album (@$albums) {
            next unless ref $album eq 'HASH';
            # Normalized albums carry `artist` (first credit, a plain string) plus the
            # full `artists` list; the album TITLE is `name` (not `title` as elsewhere).
            my $candArtist = (defined $album->{artist} && !ref $album->{artist})
                ? $album->{artist}
                : (ref $album->{artists} eq 'ARRAY' && ref $album->{artists}[0] eq 'HASH')
                    ? $album->{artists}[0]{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{name}, $albumRaw);
            # Guard the foreign renderer (dies here run inside this async callback,
            # not under _findPlayable's eval) — skip a bad item (mirrors _searchTidal).
            my $item = eval { Plugins::Spotty::OPML::_albumItem($client, $album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Spotify _albumItem failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            # Native id, kept for parity with the other adapters (bare id field,
            # else parsed from the spotify:album:<id> uri). Deliberately NOT
            # turned into a decorated favurl — Spotty's own favorites_url is the
            # working one and is preserved (see _attachFavUrl's Spotify exemption).
            my $sid = $album->{id};
            ($sid) = ($album->{uri} // '') =~ /album:([A-Za-z0-9]+)$/ unless defined $sid && length $sid;
            $item->{_albumid} = $sid;
            $item->{_ctype}   = _candReleaseType($album);   # album/single/ep — for the type filter (album_type)
            $item->{_year}    = _svcYear($album);           # service release year (trending date fallback)
            push @out, $item;
        }
        # Matched but the renderer produced nothing usable → inconclusive (see _searchTidal).
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, { query => $query, type => 'album', limit => 50 });
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
    #   'exclude'  — INVERSE of 'first': probe the library and, if the track is owned,
    #                DROP it (signalled to the caller as owned, not a stream miss);
    #                only tracks the user does NOT already have are streamed. Used by
    #                the "People You Follow" weekly lists (new-music-only discovery).
    $libMode //= ($prefs->get('prefer_library') // 1) ? 'first' : 'never';

    my @adapters   = grep { $_->{runTrack} } _orderedAdapters();
    my $titleNorm  = _norm($title);
    my $artistNorm = _norm($artist);
    my $query      = join(' ', grep { length } $artistNorm, $titleNorm);   # for the cache key only
    # Search the services with the RAW artist+title, NOT the normalised form. The
    # normaliser turns punctuation into spaces ("L.U.C.K.Y" -> "l u c k y"), which
    # mangles stylised titles so the service's OWN search returns nothing —
    # confirmed against Tidal: it returns "L.U.C.K.Y" for the raw query but not for
    # the spaced one. Normalisation is only for OUR match validation (_trackMatches);
    # the outgoing query must stay faithful to what the service indexed.
    # Both spellings, per-adapter query_enc — see the album-search site's note
    # (Qobuz/Tidal/Spotify need characters, Deezer/Bandcamp octets).
    my $qRaw       = join(' ', grep { length } $artist, $title);
    my $qChars     = $qRaw;
    utf8::decode($qChars) unless utf8::is_utf8($qChars);   # no-op if not valid UTF-8
    my $qBytes     = $qRaw;
    utf8::encode($qBytes) if utf8::is_utf8($qBytes);

    # A title is the one thing we always need; missing streaming adapters is NOT
    # fatal — the library may still satisfy the track (handled below), so don't
    # bail on an empty @adapters here.
    unless (length $titleNorm) {
        $callback->(undef);
        return;
    }

    # Cache the per-track decision (item or "no match") keyed by recording MBID
    # where available, else the normalised "artist title". Versioned (:4:). The
    # key now includes the track-capable service set in priority order, like the
    # album play-via key (_streamKey) and the resolved-playlist key — so adding /
    # enabling / reordering a service re-resolves the track instead of returning a
    # stale entry. This is essential for the NO-MATCH case: a track that missed
    # while only Tidal was enabled was cached as "no match", and without the
    # service in the key, enabling Qobuz re-resolved the playlist but each track
    # lookup hit that stale miss and never tried Qobuz (the 6/50 symptom).
    # The non-default library modes get their own key suffix so a streaming-first
    # result can't collide with the playlist feature's library-preferring cache.
    my $svcOrder = join(',', map { lc $_->{name} } @adapters);
    # :6→:7 (0.9.110): matched track items gained `_year` (service release year,
    # the Weekly Tracks last date fallback) — cached pre-:7 items lack it. Since
    # 0.9.114 the Created-for-You playlists ARE year-enriched too (`_enrichYears`),
    # so the OUTER lbf:pl:resolved key was bumped to :7: in step — the `exists
    # $tr->{year}` gate now distinguishes enriched lists (playlists/follow/trending,
    # which render years) from un-enriched pools (DSTM), not "playlists never render
    # years" as the earlier note here claimed.
    my $key = 'lbf:track:7:' . $svcOrder . ':' . ($recMbid || _norm($query));
    $key .= ":$libMode" unless $libMode eq 'first';
    utf8::encode($key) if utf8::is_utf8($key);
    if (!$force && (my $c = $cache->get($key))) {
        # 'exclude' mode caches an owned-track decision so the caller drops it
        # without a re-probe. Owned → excluded (not a stream miss).
        if ($c->{owned}) { $callback->(undef, 0, 1); return; }
        my $item = $c->{item};
        # The service set is in the key, so a cached entry already matches the
        # current config; _cachedSvcUsable stays as a belt-and-braces guard for an
        # item whose service was uninstalled mid-TTL. Library / no-match always OK.
        if (!$item || _cachedSvcUsable($item->{_svc})) {
            $callback->($item);
            return;
        }
    }

    # Set when a streaming service couldn't be queried (no API handler / timeout /
    # error) — makes a resulting no-match INCONCLUSIVE (short TTL, see cacheItem).
    my $inconclusive = 0;

    # Cache TTL for a resolved item: library hits can go stale on a rescan/delete,
    # so they get the short LIBRARY_TTL; a streaming match is durable. A no-match is
    # kept a week UNLESS it's inconclusive (a service was unavailable), in which
    # case it retries within the hour rather than poisoning for the week.
    my $cacheItem = sub {
        my $item = shift;
        my $ttl = !$item ? ($inconclusive ? TRACK_INCONCLUSIVE_TTL : TRACK_NOMATCH_TTL)
                : (($item->{_svc} // '') eq 'Library') ? LIBRARY_TTL
                : TRACK_FOUND_TTL;
        eval { $cache->set($key, { item => $item }, $ttl); 1 }
            or $log->warn("track cache set failed: $@");
    };

    # The local-library probe (_findLocalTrack) is the only SYNCHRONOUS, loop-blocking
    # step in this otherwise-async resolver: LMS's DB layer (Slim::Schema and the
    # 'titles' request) has no non-blocking form and can't run off-thread. When a
    # playlist resolves mostly from the library, each track's probe would call back
    # synchronously and re-enter _resolveTracks' pump in the SAME event-loop pass — up
    # to ~50 blocking DB queries with no yield, which starves audio on a low-power box
    # (a Pi would stutter / drop players). So run every library probe on an idle timer
    # tick: the event loop services audio/UI between probes. Same total work, just never
    # one contiguous freeze. (Streaming search is already async — only the DB probe
    # needs this.) Reached only on a cache MISS; the warm pre-resolves, so normal opens
    # are cache hits that never get here. MBID-exact first, then artist+title.
    my $deferLocal = sub {
        my ($then) = @_;
        Slim::Utils::Timers::setTimer(undef, time(), sub {
            my $local = eval { _findLocalTrack($artist, $title, $recMbid) };
            $log->warn("local track lookup failed: $@") if $@;
            $then->($local);
        });
    };

    # Streaming phase — search each service in priority order (async, non-blocking);
    # the first match by priority wins. Factored into a closure so the library tiers
    # can run it after their (deferred) probe. Shares $inconclusive / $cacheItem.
    my $runStreaming = sub {
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
            # 'fallback': no streaming match → try the library (deferred) as a last resort.
            if (!$item && $libMode eq 'fallback') {
                $deferLocal->(sub {
                    my $local = shift;
                    $item = $local if $local;
                    $cacheItem->($item);
                    $callback->($item, (!$item && $inconclusive) ? 1 : 0);
                });
                return;
            }
            $cacheItem->($item);
            # Tell the caller this no-match was inconclusive (a service couldn't be
            # queried) so it can keep the resolved-playlist cache short too.
            $callback->($item, (!$item && $inconclusive) ? 1 : 0);
        };

        for my $i (0 .. $#adapters) {
            my $a   = $adapters[$i];
            my $svc = $a->{name};

            my $settled = 0;
            my $svcTimer;
            my $settle  = sub {
                return if $settled || $resolved;
                $settled = 1;
                Slim::Utils::Timers::killSpecific($svcTimer) if $svcTimer;   # cancel this service's timeout
                # undef arg = the service couldn't be queried (no API handler / timeout
                # / error) → contributes no match, but INCONCLUSIVELY (not a real miss).
                if (!defined $_[0]) {
                    $inconclusive++;
                    $result[$i] = [];
                    $resolve->();
                    return;
                }
                # String-url, directly-playable items only (see header note); keep the first.
                my @matched = grep { defined $_->{url} && !ref $_->{url} } @{ $_[0] };
                my $first = $matched[0];
                $first->{_svc} = $svc if $first;
                $result[$i] = $first ? [$first] : [];
                $resolve->();
            };

            $svcTimer = Slim::Utils::Timers::setTimer(undef, time() + STREAM_SVC_TIMEOUT, sub {
                return if $settled || $resolved;
                $log->warn("track-match $svc timed out");
                $settle->(undef);   # inconclusive, not a confirmed miss
            });

            my $queryEnc = ($a->{query_enc} || 'bytes') eq 'chars' ? $qChars : $qBytes;
            eval { $a->{runTrack}->($client, $queryEnc, $artistNorm, $titleNorm, $album, $settle); 1 } or do {
                $log->warn("track-match $svc failed: $@");
                $settle->(undef);   # inconclusive, not a confirmed miss
            };
        }
    };

    # 'first': prefer an owned copy. Probe the library (deferred) before streaming — a
    # hit short-circuits; otherwise fall through to streaming, or to a confirmed miss
    # when no service is installed.
    if ($libMode eq 'first') {
        $deferLocal->(sub {
            my $local = shift;
            if ($local) { $cacheItem->($local); $callback->($local); return; }
            if (@adapters) { $runStreaming->(); }
            else           { $cacheItem->(undef); $callback->(undef); }
        });
        return;
    }

    # 'exclude': new-music-only. Probe the library (deferred); if the user OWNS the
    # track, drop it — signal owned (3rd callback arg) so the caller excludes it from
    # the list AND from the "new tracks" total, rather than counting it as a stream
    # miss. Not owned → stream it (never falls back to the library). The owned
    # decision is cached (short LIBRARY_TTL, since a rescan can change ownership).
    if ($libMode eq 'exclude') {
        $deferLocal->(sub {
            my $local = shift;
            if ($local) {
                eval { $cache->set($key, { owned => 1 }, LIBRARY_TTL); 1 }
                    or $log->warn("track cache set failed: $@");
                $callback->(undef, 0, 1);
                return;
            }
            if (@adapters) { $runStreaming->(); }
            else           { $cacheItem->(undef); $callback->(undef); }
        });
        return;
    }

    # Not 'first'. With no streaming service installed, 'fallback' still tries the
    # library (deferred, so a no-streaming user gets a library radio); 'never' is
    # streaming-only, so there's nothing left to do.
    unless (@adapters) {
        if ($libMode eq 'fallback') {
            $deferLocal->(sub {
                my $local = shift;
                $cacheItem->($local);
                $callback->($local);
            });
        }
        else {
            $cacheItem->(undef);
            $callback->(undef);
        }
        return;
    }

    $runStreaming->();
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

    # Pass 1 — combined "artist title". Selective, and best recall when LMS's
    # full-text search index is present (FTS spans artist/album/title). We re-verify
    # every candidate with _trackMatches ourselves, so this only needs to surface it.
    my $combined = join(' ', grep { length } $artist, $title);
    my ($item, $n1) = _titlesSearch($combined, $artistNorm, $titleNorm, 20);
    return $item if $item;

    # Pass 2 — title only. The bare title hits the title index regardless of FTS
    # state, and _trackMatches re-verifies the artist, so it rescues BOTH ways pass 1
    # can miss an owned track:
    #   • FTS OFF/broken — `titles search:` degrades to a `titlesearch LIKE`, so the
    #     combined "artist title" term (artist words absent from the title) matches
    #     NOTHING ($n1 == 0) and every owned track misses (0 library across a whole
    #     playlist while the same tracks match on streaming).
    #   • FTS ON — the fuzzy combined query CAN return candidates ($n1 > 0) yet still
    #     rank the owned track outside pass 1's window (common title / deep library);
    #     the wider, order-independent title-only pass gives it a second chance.
    # Hence run on ANY pass-1 miss, not just $n1 == 0. Skipped only when there's no
    # separate title to try — artist empty (combined term already == title) or no
    # title. Cheap in practice: reached only on a per-track cache MISS, and the daily
    # warm pre-resolves, so a not-owned track pays one extra title query once (in the
    # background), not on every open. Wider window (100) since a bare title is less
    # selective than "artist title" — enough to cover same-title tracks in a big library.
    return undef unless length $title && length($artist // '');
    my ($item2, $n2) = _titlesSearch($title, $artistNorm, $titleNorm, 100);
    _dbg("local text: combined '$combined' ($n1) miss -> title-only '$title' "
        . "$n2 candidate(s), " . ($item2 ? 'matched' : 'no match'));
    return $item2;
}

# Run one LMS `titles` search and return (first _trackMatches-accepted item, candidate
# count). Shared by both _localByText passes so they search/verify identically.
sub _titlesSearch {
    my ($term, $artistNorm, $titleNorm, $limit) = @_;
    return (undef, 0) unless length $term;

    my $req = Slim::Control::Request::executeRequest(undef,
        ['titles', 0, ($limit || 20), "search:$term", 'tags:ulay']);   # y = year (library date fallback)
    return (undef, 0) unless $req;

    my $loop = $req->getResult('titles_loop') || [];
    for my $e (@$loop) {
        next unless _trackMatches($artistNorm, $titleNorm, $e->{artist}, $e->{title});
        my $item = _localItemFromLoop($e);
        return ($item, scalar @$loop) if $item;
    }
    return (undef, scalar @$loop);
}

# Build a playable library item from a Slim::Schema::Track row.
sub _localItem {
    my ($tr) = @_;
    return undef unless $tr;
    my $url = eval { $tr->url } or return undef;
    my $artist = eval { $tr->artistName } || eval { $tr->artist && $tr->artist->name } || '';
    my $album  = eval { $tr->album && $tr->album->title } || '';
    my $id     = eval { $tr->id };
    my $year   = eval { $tr->year } || '';
    return _localItemHash($url, eval { $tr->title } // '', $artist, $album, $id, $year);
}

# Build a playable library item from a 'titles' query loop entry.
sub _localItemFromLoop {
    my ($e) = @_;
    my $url = $e->{url} or return undef;
    return _localItemHash($url, $e->{title} // '', $e->{artist} // '', $e->{album} // '', $e->{id}, $e->{year});
}

sub _localItemHash {
    my ($url, $title, $artist, $album, $id, $year) = @_;
    my $line2 = join(" \x{2013} ", grep { defined && length } $artist, $album);
    # _year: the library track's own tag year — the date fallback for enriched
    # lists (playlists/follow), mirroring the streaming adapters' `_year`. A
    # 0/garbage tag year is dropped.
    my $y = (defined $year && $year =~ /^(\d{4})$/) ? $1 : '';
    return {
        name  => $title,
        ($line2 ne '' ? (line2 => $line2) : ()),
        type  => 'audio',
        url   => $url,
        play  => $url,
        (defined $id ? (image => "/music/$id/cover.jpg") : ()),
        _svc  => 'Library',
        ($y ? (_year => $y) : ()),
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
    # undef (not []) → "couldn't query", treated as inconclusive so a transient
    # missing handler doesn't get cached as a durable no-match.
    unless ($api) { $log->info("Qobuz track-match: no API handler"); $collect->(undef); return; }

    $api->search(sub {
        my $res = shift;
        # No response at all → the search errored, not "no results" → inconclusive.
        return $collect->(undef) unless defined $res;
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
                _year => _svcYear($tr->{album}, $tr),   # service release year (trending date fallback)
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
    # undef (not []) → inconclusive, so a transient missing handler isn't cached
    # as a durable no-match (see _findPlayableTrack).
    unless ($api) { $log->info("Tidal track-match: no API handler"); $collect->(undef); return; }

    $api->search(sub {
        my $tracks = shift;
        # No response at all → the search errored, not "no results" → inconclusive.
        return $collect->(undef) unless defined $tracks;
        my @out;
        for my $tr (@{ $tracks || [] }) {
            next unless ref $tr eq 'HASH';
            my $artistRef  = $tr->{artist} || ($tr->{artists} && $tr->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _trackMatches($artistNorm, $titleNorm, $candArtist, $tr->{title});

            my $item = Plugins::TIDAL::Plugin->can('_renderTrack')
                ? eval { Plugins::TIDAL::Plugin::_renderTrack($tr) } : undef;
            next unless ref $item eq 'HASH' && defined $item->{url} && !ref $item->{url};
            $item->{_year} = _svcYear($tr->{album}, $tr);   # service release year (trending date fallback)
            push @out, $item;
        }
        $log->info("Tidal track-match '$query': " . scalar(@{ $tracks || [] }) . " results, " . scalar(@out) . " matched");
        $collect->(\@out);
    }, { type => 'tracks', search => $query, limit => 20 });
}

# Deezer track search — mirror of _searchTidalTrack. ->search(cb,{type=>'track'})
# calls back with a bare arrayref of raw track hashes; we adopt the plugin's own
# _renderTrack item only if it carries a plain string url (deezer://<id>.<fmt>) —
# the cache-stability rule. Deezer's renderer sets `play` (and usually `url`); we
# normalise whichever string is present onto url/play and force type=>audio.
sub _searchDeezerTrack {
    my ($client, $query, $artistNorm, $titleNorm, $album, $collect) = @_;

    my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
    unless ($api) { $log->info("Deezer track-match: no API handler"); $collect->(undef); return; }

    $api->search(sub {
        my $tracks = shift;
        # No response at all → the search errored, not "no results" → inconclusive.
        return $collect->(undef) unless defined $tracks;
        # Tolerate the response shape (bare arrayref expected; accept a hash-wrapped
        # list) so a mismatch is a clean miss, not a die in this async callback.
        $tracks = $tracks->{data} || $tracks->{tracks} || [] if ref $tracks eq 'HASH';
        return $collect->([]) unless ref $tracks eq 'ARRAY';
        my @out;
        for my $tr (@$tracks) {
            next unless ref $tr eq 'HASH';
            my $artistRef  = $tr->{artist} || ($tr->{artists} && $tr->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _trackMatches($artistNorm, $titleNorm, $candArtist, $tr->{title});

            my $item = eval { Plugins::Deezer::Plugin::_renderTrack($tr) };
            next unless ref $item eq 'HASH';
            my $u = (defined $item->{url}  && !ref $item->{url})  ? $item->{url}
                  : (defined $item->{play} && !ref $item->{play}) ? $item->{play}
                  : undef;
            next unless defined $u && length $u;
            $item->{url}  = $u;
            $item->{play} = $u;
            $item->{type} = 'audio';
            $item->{_year} = _svcYear($tr->{album}, $tr);   # service release year (trending date fallback)
            push @out, $item;
        }
        $log->info("Deezer track-match '$query': " . scalar(@{ $tracks || [] }) . " results, " . scalar(@out) . " matched");
        $collect->(\@out);
    }, { search => $query, type => 'track', strict => 'off', limit => 20 });
}

# Spotify track search — mirror of _searchDeezerTrack, via the Spotty plugin.
# ->search(cb,{type=>'track'}) calls back (through Spotty's Pipeline — same
# error-swallowing caveat as _searchSpotify) with a bare arrayref of normalized
# track hashes. Rendering reuses OPML::trackList (one-track list → one item),
# whose items carry a plain string url (spotify://track:<id>) — the
# cache-stability rule. The renderer's `name` is its long spoken form ("Title BY
# Artist FROM Album"), so it's reset to the bare title (line1) to match the
# other adapters' rows — the year-append and dedupe key off `name`. A track the
# renderer withholds a url from (explicit-content filtering) fails the
# string-url rule and simply doesn't match.
sub _searchSpotifyTrack {
    my ($client, $query, $artistNorm, $titleNorm, $album, $collect) = @_;

    my $api = Plugins::Spotty::Plugin->getAPIHandler($client);
    unless ($api) { $log->info("Spotify track-match: no API handler"); $collect->(undef); return; }

    $api->search(sub {
        my $tracks = shift;
        # No response / unexpected shape → inconclusive (defensive — see _searchSpotify).
        return $collect->(undef) unless defined $tracks && ref $tracks eq 'ARRAY';
        my @out;
        for my $tr (@$tracks) {
            next unless ref $tr eq 'HASH';
            # Normalized tracks carry the full `artists` credit list (no flattened
            # `artist` field) — accept if ANY credited artist matches, like the
            # Qobuz track path does for its several artist fields.
            my @artists = grep { defined && length }
                map { ref $_ eq 'HASH' ? $_->{name} : undef }
                @{ (ref $tr->{artists} eq 'ARRAY') ? $tr->{artists} : [] };
            next unless grep { _trackMatches($artistNorm, $titleNorm, $_, $tr->{name}) } @artists;

            # Guard the foreign renderer (async callback — see _searchDeezerTrack).
            my ($item) = eval { @{ Plugins::Spotty::OPML::trackList($client, [$tr]) || [] } };
            next unless ref $item eq 'HASH';
            my $u = (defined $item->{url}  && !ref $item->{url})  ? $item->{url}
                  : (defined $item->{play} && !ref $item->{play}) ? $item->{play}
                  : undef;
            next unless defined $u && length $u;
            $item->{url}  = $u;
            $item->{play} = $u;
            $item->{type} = 'audio';
            $item->{name} = $item->{line1} if defined $item->{line1} && length $item->{line1};   # bare title (see header)
            $item->{_year} = _svcYear($tr->{album}, $tr);   # service release year (trending date fallback)
            push @out, $item;
        }
        $log->info("Spotify track-match '$query': " . scalar(@$tracks) . " results, " . scalar(@out) . " matched");
        $collect->(\@out);
    }, { query => $query, type => 'track', limit => 20 });
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
    my ($artistNorm, $albumNorm, $candArtist, $candTitle, $albumRaw) = @_;

    # All-punctuation / single-char titles ("( )", "X") normalise to (near)
    # nothing, so the standard path can't see them. Compare a punctuation-
    # PRESERVING form instead - lowercase, whitespace stripped: "( )" == "()"
    # but != "( ) (live)". Exact equality ONLY (a prefix rule would let "x"
    # swallow "xx") and the artist gate is mandatory. (Ported from the
    # Discography plugin 0.10.3, 2026-07-10.)
    if (length $albumNorm < 2) {
        my $ap = _punctNorm($albumRaw);
        return 0 unless length $ap;
        return 0 unless _punctNorm($candTitle) eq $ap;
        return 0 if $artistNorm eq '';
        return _artistMatch($artistNorm, _norm($candArtist));
    }

    my $t = _norm($candTitle);
    return 0 if $t eq '';

    # SELF-TITLED releases ("The Beatles", "Weezer") match on the EXACT title only:
    # every fallback below reads "<album> <extra>" as an edition of the same album,
    # which is catastrophic when the album title IS the artist name — it swallows
    # "The Beatles 1962-1966" (Red), "…1967-1970" (Blue), "…Anthology 1". _norm
    # already strips brackets, so "The Beatles (White Album)"/"(Remastered)" still
    # match. (Ported from the Discography plugin 0.11.1 — fleet matcher sync.)
    if (length($artistNorm) && $albumNorm eq $artistNorm) {
        return 0 unless $t eq $albumNorm;
        return _artistMatch($artistNorm, _norm($candArtist));
    }

    my $ok = ($t eq $albumNorm || index($t, "$albumNorm ") == 0);

    # Trailing format descriptor ("... EP"/"... LP") present on one side only.
    if (!$ok) {
        my $ab = _stripFmt($albumNorm);
        my $tb = _stripFmt($t);
        $ok = 1 if length($ab) >= 3 && length($tb) >= 3
                && ($tb eq $ab || index($tb, "$ab ") == 0);
    }

    # Decorative non-ASCII glyphs spelled differently between sources.
    if (!$ok) {
        my $aa = _asciiNorm($albumNorm);
        my $ta = _asciiNorm($t);
        $ok = 1 if length($aa) >= 2 && length($ta) >= 2
                && ($ta eq $aa || index($ta, "$aa ") == 0);
    }

    # Titles carrying the ARTIST NAME as a prefix on ONE side only - e.g. the
    # release "Belle and Sebastian Write About Love" vs the source title
    # "Write About Love". Strip a leading "<artist> " from both sides and
    # re-compare, gated on a >=3 char remainder; the artist check below still
    # applies. (Ported from the Discography plugin 0.9.1.)
    if (!$ok && length $artistNorm) {
        my $ab = _stripArtistPrefix($albumNorm, $artistNorm);
        my $tb = _stripArtistPrefix($t, $artistNorm);
        if (($ab ne $albumNorm || $tb ne $t) && length($ab) >= 3 && length($tb) >= 3) {
            $ok = 1 if $tb eq $ab || index($tb, "$ab ") == 0;
        }
    }
    return 0 unless $ok;

    # No artist to disambiguate with -> only an EXACT title match counts; otherwise
    # a generic one-word title ("Prism") prefix-matches dozens of unrelated albums.
    return ($t eq $albumNorm) ? 1 : 0 if $artistNorm eq '';
    return _artistMatch($artistNorm, _norm($candArtist));
}

sub _stripFmt {
    my $s = shift // '';
    $s =~ s/\s+(?:ep|lp)$//;
    return $s;
}

sub _asciiNorm {
    my $s = shift // '';
    $s =~ s/[^\x00-\x7f]+/ /g;
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

# Lowercased, whitespace-stripped, punctuation KEPT - only for titles _norm
# erases (see the short-title branch in _albumMatches).
sub _punctNorm {
    my $s = shift // '';
    if (!utf8::is_utf8($s) && $s =~ /[^\x00-\x7f]/) {
        my $d = $s;
        $s = $d if utf8::decode($d);
    }
    $s = lc($s);
    $s =~ s/\s+//g;
    return $s;
}

sub _stripArtistPrefix {
    my ($t, $a) = @_;
    return substr($t, length($a) + 1) if index($t, "$a ") == 0;
    return $t;
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

# Diacritic folding for _norm. Unicode::Normalize is a core module, but guard the
# load so a stripped Perl degrades to no-folding rather than failing to load the
# plugin. %FOLD covers the atomic Latin letters that have NO combining-mark
# decomposition (so NFD can't split them to a base + accent) — mapped to their plain
# ASCII base. All entries are lower-case: _norm lc()s before folding.
my $HAVE_NFD = eval { require Unicode::Normalize; 1 } ? 1 : 0;
my %FOLD = (
    "\x{131}" => 'i',    # ı  dotless i (Turkish/Azeri)  — "Altın" -> "altin"
    "\x{142}" => 'l',    # ł
    "\x{f8}"  => 'o',    # ø
    "\x{f0}"  => 'd',    # ð
    "\x{111}" => 'd',    # đ
    "\x{fe}"  => 'th',   # þ
    "\x{df}"  => 'ss',   # ß
    "\x{e6}"  => 'ae',   # æ
    "\x{153}" => 'oe',   # œ
    "\x{127}" => 'h',    # ħ
);

# Normalise a title/artist for fuzzy matching: lowercase, FOLD diacritics, drop
# bracketed qualifiers (deluxe/remaster/etc.) and punctuation, collapse whitespace.
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
    # Fold Latin diacritics so a name matches across the spellings a catalogue might
    # use — "Altın Gün" vs "Altin Gun", "Björk" vs "Bjork", or an NFC-vs-NFD spelling
    # of the same accent (the reason "Altın Gün — Neredesin Sen" missed on Qobuz
    # despite being there). Decompose (NFD), drop ONLY the Latin combining-mark block
    # (U+0300–036F: é→e ü→u ñ→n ç→c), then RE-COMPOSE (NFC) so combining marks OUTSIDE
    # that block are put back — essential for scripts where base+mark is semantic
    # (Japanese voiced kana ば = は+U+3099 would otherwise be split and the mark then
    # turned to a space by the punctuation pass below). Finally map the atomic Latin
    # letters NFD can't split (%FOLD: ı ł ø ð þ ß …). Gated on real characters (skip a
    # still-octet invalid-UTF-8 string) and on Unicode::Normalize being present.
    # Non-Latin scripts (CJK, Cyrillic, Arabic, …) pass through unchanged.
    if ($HAVE_NFD && utf8::is_utf8($s)) {
        $s = Unicode::Normalize::NFC(
             Unicode::Normalize::NFD($s) =~ s/[\x{0300}-\x{036F}]+//gr );
        $s =~ s/([^\x00-\x7f])/exists $FOLD{$1} ? $FOLD{$1} : $1/ge;
    }
    $s =~ s/\$/s/g;
    $s =~ s/\x{20ac}/e/g;   # euro sign
    $s =~ s/\x{a3}/l/g;     # pound sign
    $s =~ s/\x{a5}/y/g;     # yen sign
    $s =~ s/!/i/g;
    $s =~ s/\@/a/g;
    $s =~ s/[\(\[].*?[\)\]]//g;
    $s =~ s/[^\p{Alnum}]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
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
