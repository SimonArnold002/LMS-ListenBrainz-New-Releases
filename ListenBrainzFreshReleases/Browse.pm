package Plugins::ListenBrainzFreshReleases::Browse;

use strict;
use warnings;

use Time::Local ();
use Time::HiRes ();
use Digest::MD5 ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::Strings qw(cstring string);

use Plugins::ListenBrainzFreshReleases::API;
use Plugins::ListenBrainzFreshReleases::DB;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');

# THE STORE, NOT THE LMS CACHE — see the same note in API.pm. Everything reached
# through this handle is DISPOSABLE by definition; the two things on this page
# that are not (a Bandcamp pin, the recommendation store) go through named DB
# subs onto their own tables instead.
my $cache = Plugins::ListenBrainzFreshReleases::DB::store();

# ---------------------------------------------------------------------------
# THE LAYERED-CACHE RULE, MADE STRUCTURAL.
#
# The match caches nest: a resolved playlist / follow list / trending list is a
# list of decisions each cached under `lbf:track:`, and a trending-albums
# aggregate is a list of decisions each cached under `lbf:stream:`. Bumping only
# the INNER key does nothing, because an outer hit never reaches it — a lesson
# this repo has written down three times (0.9.36, 0.9.110, 0.9.120) and broken
# anyway, costing a release each time.
#
# So the inner version is now a TERM IN THE OUTER KEY. Bumping `lbf:track:` in
# DB::KEY_VERSIONS necessarily re-keys every list that wraps it; there is nothing
# left to remember to do. Do not "tidy" these out of the keys.
# ---------------------------------------------------------------------------
sub _trackLayerTag  { 't' . Plugins::ListenBrainzFreshReleases::DB::kverNum('lbf:track:') }
sub _streamLayerTag { 's' . Plugins::ListenBrainzFreshReleases::DB::kverNum('lbf:stream:') }

# The resolved-playlist key, in ONE place. It was written out at three separate
# sites (the tile's count, the open, the warm), which is how the warm came to
# build a key the other two could not hit — a whole playlist re-resolving on every
# open while the warm quietly filled a key nobody read.
sub _plResolvedKey {
    my ($mbid, $lastMod, $svcOrder) = @_;
    return Plugins::ListenBrainzFreshReleases::DB::kver('lbf:pl:resolved:')
         . join('|', ($mbid // ''), ($lastMod // ''), ($svcOrder // ''), _trackLayerTag());
}

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

# Record a warm-stage boundary — instrumentation only, read by ["lbf","warmstats"].
#
# `_stage('start', $name)` / `_stage('end', $name, $outcome, $note)`. Eval-guarded
# on purpose and at this level rather than at each of the ~20 call sites: these
# marks sit INSIDE async HTTP callbacks, where a die does not reach any caller's
# eval and simply abandons the rest of the chain. An instrument must not be able
# to break the thing it measures, and one that logged its own failure at every
# call would be worse than the gap it leaves.
sub _stage {
    my ($what, $name, $outcome, $note) = @_;
    eval {
        my $P = 'Plugins::ListenBrainzFreshReleases::Plugin';
        if ($what eq 'start') { $P->can('stageStart')->($name) }
        else                  { $P->can('stageEnd')->($name, $outcome, $note) }
        1;
    };
    return;
}

# ---------------------------------------------------------------------------
# IN-FLIGHT REGISTRY — one build per view, not one per opener.
#
# The People-You-Follow builds are minutes long cold (measured 52.8s for the
# tracks list alone, and that was AFTER the rate-limit fix). Until now there was
# no guard at all, so a warm build and a user tap ran two complete fan-outs
# against each other — doubling the ListenBrainz traffic that
# [[lbf-lb-rate-limit-shared]] shows is already the binding constraint, and
# doubling the streaming searches behind it.
#
# The registry is deliberately NOT a cache and NOT in `kv`: it is the answer to
# "is someone building this RIGHT NOW", which is only ever true within one
# process and must not survive a restart. A stale "building" flag read from disk
# would render the building row for ever with nothing actually running.
#
# OWNERSHIP IS THE SUBTLE PART. Whoever sets the flag clears it. A second caller
# that finds the flag already set renders the building row and returns WITHOUT
# clearing it — clearing another build's flag would let a third caller start a
# duplicate fan-out, which is the exact thing being prevented.
# ---------------------------------------------------------------------------
# A LEAKED FLAG IS WORSE THAN NO GUARD AT ALL — the view says "still being built"
# for ever with nothing running, and because the registry is in-process on purpose,
# no TTL and no restart-free cache expiry can clear it. Every caller releases its own
# flag; this timer is the braces to that belt, for the case no release path can cover:
# a resolve whose async chain never calls back at all (a wedged service, a die inside
# an LMS timer callback, which happens outside any eval this file could wrap).
use constant BUILDING_MAX => 180;

my %BUILDING;
my %BUILDING_TIMER;

sub _buildingStart {
    my $key = $_[0] // '';
    $BUILDING{$key} = 1;
    eval {
        Slim::Utils::Timers::killSpecific($BUILDING_TIMER{$key}) if $BUILDING_TIMER{$key};
        $BUILDING_TIMER{$key} = Slim::Utils::Timers::setTimer(undef, time() + BUILDING_MAX, sub {
            return unless delete $BUILDING{$key};
            delete $BUILDING_TIMER{$key};
            $log->warn("build flag '$key' expired after " . BUILDING_MAX . "s without a release"
                     . " — freeing it so the view can rebuild");
        });
        1;
    };
    return 1;
}
sub _buildingEnd {
    my $key = $_[0] // '';
    delete $BUILDING{$key};
    eval { Slim::Utils::Timers::killSpecific(delete $BUILDING_TIMER{$key}) if $BUILDING_TIMER{$key}; 1 };
    return;
}
sub _isBuilding    { return $BUILDING{ $_[0] // '' } ? 1 : 0 }


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
# A manually-found Bandcamp match has NO TTL at all any more: it is a row in the
# `bandcamp_pin` table (see _pinBandcamp), because it is the only way a
# Bandcamp-only release becomes playable and it has no automatic repopulation. It
# used to sit in the shared cache on a 30-day expiry, which meant a user who did
# not revisit the release for a month silently lost the album's sole playable
# entry — a quieter version of the bump that 0.9.47 and the 0.9.141 review each
# had to revert.
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

# The warm's feed chain (For You -> All Releases -> MuSpy) runs the three feeds in
# priority order instead of firing them together. Ordering them creates a failure
# the concurrent version could not have: one hung feed starves playlists and
# followers for ever. This is the ceiling on the WHOLE chain, after which the rest
# of the warm starts regardless. Generous rather than tight — the feeds each carry
# their own timeouts, so this only ever fires when something is genuinely wedged,
# and cutting a slow-but-working feed short would lose the feed for the day.
use constant WARM_FEED_CHAIN_MAX => 120;

# "Recommended by People You Follow" is ONE new-music list (owned tracks excluded),
# newest-first, with day dividers in the opened view. The source recs are accumulated
# into a small persisted store so a rec isn't lost once it scrolls out of the feed's
# 75-event window; history builds forward from first capture. Capped at a generous
# number of recs (they're tiny metadata) so the store can't grow without bound.
use constant FOLLOW_KEEP_MAX  => 500;
# NO TTL — the source store is `follow_item`, a table (see _mergeFollow). It used
# to be a 30-day cache entry refreshed on every merge, which meant a user who did
# not open the section for a month lost recommendations that CANNOT BE REFETCHED:
# they build forward from first capture, out of a 75-event feed window. The bound
# is FOLLOW_KEEP_MAX rows, applied by followTrim, not an expiry.
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
use constant FOLLOWER_FANOUT     => 10;    # concurrent per-follower stat fetches.
                                           # THIS USED TO SAY "the LB stats endpoint is cheap — safe to
                                           # parallelise more than the streaming resolve". Cheap is not the
                                           # same as EXEMPT: measured 2026-08-22, three builds running at
                                           # this concurrency put 30 requests in flight at once and every
                                           # one of 39 came back 429. The endpoint shares ListenBrainz's
                                           # ~30-per-10s budget like everything else. What makes 10 safe
                                           # now is the serialised chain in _warmTrending plus the shared
                                           # backoff in API::_getUserStats — not the endpoint being special.
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

# The row a view renders when it has no answer YET, as distinct from having an
# answer that is empty. PLUGIN_LBF_NO_TRENDING is an affirmative "nobody you
# follow has listened"; this one means "come back in a moment". Conflating them
# is what made a cold open look like a broken feature.
sub _buildingRow {
    my ($client) = @_;
    return { items => [ { name => cstring($client, 'PLUGIN_LBF_BUILDING'), type => 'text' },
                        _checkAgainItem($client) ],
             cachetime => 0 };
}

# "Check again" — the ONLY refresh Material can give a page that is waiting on work.
#
# THERE IS NO SERVER PUSH. A browse page keeps whatever it was built with; a plugin
# cannot refresh a page the user is sitting on, and `needsRefresh` is client-side
# only, so the building row cannot turn itself into the real list. What Material DOES
# honour is `nextWindow` — but ONLY on an EMPTY browse response
# (`browseHandleNextWindow`, browse-functions.js:834), which is why this row returns
# `{ items => [] }` and does nothing else. Material then treats it as "pop back and
# re-fetch the page this row lives on", which re-runs the view: cache warm by now →
# the real list, still building → this row again.
#
# It is the same mechanism as every Refresh row in this file (_refreshItem and the
# detail page's streaming refresh), with the side effect removed — there is no cache
# to drop here, the point is purely to re-walk the view.
sub _checkAgainItem {
    my ($client) = @_;
    return {
        name        => cstring($client, 'PLUGIN_LBF_CHECK_AGAIN'),
        type        => 'link',
        image       => MENU_REFRESH,
        nextWindow  => 'refresh',
        passthrough => [{}],
        url         => sub { $_[1]->({ items => [] }) },
    };
}
use constant MENU_SORT     => IMG_BASE . 'lbf-sort_MTL_icon_sort.png';
# Per-view release-family toggle: ONE cycling row whose icon reflects the CURRENT
# family — an album disc while showing Albums, a music note while showing Singles &
# EPs. The _MTL_icon_<name> filenames make Material render its own themed
# album/music_note font-icons; the PNGs are minimal fallbacks for other skins.
use constant VIEW_ALBUMS   => IMG_BASE . 'lbf-view-albums_MTL_icon_album.png';
use constant VIEW_SINGLES  => IMG_BASE . 'lbf-view-singles_MTL_icon_music_note.png';
# Genre labels + the multi-select genre picker.
use constant MENU_GENRE    => IMG_BASE . 'lbf-genre_MTL_icon_category.png';
use constant CHECK_ON      => IMG_BASE . 'lbf-check-on_MTL_icon_check_box.png';
use constant CHECK_OFF     => IMG_BASE . 'lbf-check-off_MTL_icon_check_box_outline_blank.png';
use constant MENU_APPLY    => IMG_BASE . 'lbf-apply_MTL_icon_done.png';
# How many release groups the genre fill may cover in one pass when it needs the
# WHOLE feed rather than one page — the daily warm, and any render with a genre
# filter active (which must filter before paging). Declared here, not next to
# _warmGenres, because `use constant` is compile-time: the picker and the All
# Releases week coderef both reference it and both appear earlier in this file.
use constant GENRE_WARM_MAX => 600;
# The DAILY WARM's own bound, and deliberately larger than GENRE_WARM_MAX: it
# covers the WHOLE feed, so that the first open of any week is a cache hit rather
# than a bare render followed by "go in and out and they appear".
#
# THIS NUMBER WAS ONLY EVER SAFE TO RAISE ONCE THE GENRE STORE PERSISTED. Before
# the 30-day TTL boundary was fixed, every entry the warm wrote was discarded on
# write, so a bigger warm just re-fetched more the next night — the 600 cap was
# concealing that bug rather than protecting anything. Measured on the live feed
# (3,255 releases, 2026-08-13): 66 batches of 50, median 0.23s each, ~16s serial
# for the whole feed, and the entries then hold for 30 days.
#
# 4000 is a HEADROOM BOUND, not a target — it exists so a pathological feed can
# never turn the warm into an unbounded loop. The real pacing is in
# API::getReleaseGroupMetadata, which honours ListenBrainz's rate limit (30 per
# ~10s window, measured); without that a 66-batch burst 429s halfway through and
# looks exactly like the bug this widening fixes.
use constant GENRE_WARM_ALL => 4000;

# Marker key inside the shared per-render $meta map, set only when the bulk
# hosted-genre read actually found something. Release-group entries in that hash
# are keyed by lowercase UUID and the hosted ones by 'a:<folded name>', so
# 'hosted?' can collide with neither.
#
# Declared HERE, with the other constants, because `use constant` is BEGIN-time:
# a constant must appear earlier in the file than any use of it, and this one is
# read from _genresFor and written from two fill paths, all further down.
# (HOSTED_MARK lived here until 0.9.173, alongside the hosted artist rung it
# belonged to. Both are gone; the `hosted_genres` column survives, unread.)
# One marker per ARTIST-LEVEL rung. Each says "the bulk read found at least one
# answer for this tier on this page", which is what lets _artistTierGenres skip
# building a key that could only miss — the empty case has to stay free, because
# the genre picker walks the WHOLE feed through it.
use constant LB_MARK  => 'lbartist?';
use constant LFM_MARK => 'lfmartist?';
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
    # USERNAME ONLY — fresh_releases is a public endpoint (see the header comment
    # on API::getFreshReleasesForUser for the verification). Do NOT re-add $token
    # here: it made the plugin's flagship feed unreachable without a credential
    # the endpoint has never required.
    my $newReleases = $username
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
    #
    # SECTION ORDER: Created for You -> All Releases -> People You Follow ->
    # Settings. Only the FIRST of those can be assembled here, because the All
    # Releases weeks are inlined from an async feed fetch and everything after
    # them has to be emitted on the far side of that callback. So @head is the
    # part that precedes All Releases, and $finish emits the rest in order — the
    # People section moved into $finish for no reason other than that it now
    # sits below a section which is only known asynchronously.
    my @head;
    push @head, _sectionHeader($client, 'PLUGIN_LBF_SECTION_CREATED_FOR_YOU', $useH, \@createdFor), @createdFor;

    my ($finished, $watchdog);
    my $finish = sub {
        my ($allRows) = @_;
        return if $finished;   # idempotent: whichever of feed / fallback / watchdog wins renders once
        $finished = 1;
        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;
        my @items = @head;
        push @items, _sectionHeader($client, 'PLUGIN_LBF_ALL_RELEASES', $useH, $allRows), @$allRows;
        # People You Follow sits BELOW All Releases and above Settings — last of
        # the content sections. Emitted here rather than in @head purely because
        # of that position; the array itself is built synchronously above and is
        # captured by this closure, so an empty/disabled section is still simply
        # absent, exactly as before.
        push @items, _sectionHeader($client, 'PLUGIN_LBF_SECTION_PEOPLE', $useH, \@people), @people if @people;
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
        onDone => sub {
            my $releases = _allSection(shift);
            _stashSummary('all', $releases);
            # No inline Refresh row at the top level (it's cluttered there); All Releases
            # refreshes on its own 24h cadence, and each week drill carries the Options
            # section — family selector, sort toggle AND Refresh. (Until 0.9.127 that
            # last one was missing, so inlining the weeks here left the feed with no
            # reachable Refresh: fetchAll's row is only seen via the fallback tile.)
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
# else the whole-week window implied by the user's settings — plus the
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
# Has a stashed summary actually moved since we last wrote it? (0.9.139)
#
# The three summary keys are written on EVERY walk of their render paths — the top
# level alone rewrites two of them three-plus times per tap — and the value is
# almost always byte-identical to what is already stored. Skipping the redundant
# SQLite write is free; the only thing to be careful of is the TTL, because a
# skipped write is also a skipped RENEWAL. So rewrite unconditionally once every
# SUMMARY_REWRITE, well inside the 25h TTL, and an unchanging feed can never let its
# tile subtitle quietly expire.
use constant SUMMARY_REWRITE => 6 * 3600;
my %_SUMMARY_SIG;   # summary key => [ signature, last written ]

sub _summaryChanged {
    my ($which, $sig) = @_;
    my $e   = $_SUMMARY_SIG{$which};
    my $now = time();
    return 0 if $e && $e->[0] eq $sig && $now - $e->[1] < SUMMARY_REWRITE;
    $_SUMMARY_SIG{$which} = [ $sig, $now ];
    return 1;
}

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
    return unless _summaryChanged('playlists', $min);
    eval { $cache->set('lbf:summary:playlists', { min => $min }, 25 * 3600); 1 };
}

# Cache a section feed's summary (release count + actual earliest/latest release
# date) so _categoryTile can render its subtitle instantly without re-fetching.
# Keyed by section ('user' | 'all'); rewritten each time the feed is built.
sub _stashSummary {
    my ($which, $releases) = @_;
    return unless ref $releases eq 'ARRAY';

    # Scan for min/max rather than sorting the whole list: this runs on every walk
    # of every render path, and only two of those values are ever wanted.
    my ($min, $max);
    for my $rel (@$releases) {
        my $d = $rel->{release_date} // '';
        next unless length $d;
        $min = $d if !defined $min || $d lt $min;
        $max = $d if !defined $max || $d gt $max;
    }

    my %sum = (count => scalar(@$releases), min => ($min // ''), max => ($max // ''));

    # SKIP THE WRITE when nothing has changed (0.9.139). This is an SQLite write, and
    # it was firing on every root walk, every fetchAll and every home-shelf load —
    # three-plus times per tap — to store bytes identical to what was already there.
    # The summary only moves when the feed does, which is at most once per feed TTL.
    my $sig = join('|', $sum{count}, $sum{min}, $sum{max});
    return unless _summaryChanged($which, $sig);

    eval { $cache->set('lbf:summary:' . $which, \%sum, 25 * 3600); 1 };
}

# ---------------------------------------------------------------------------
# Fetch For You — applies For You prefs
# ---------------------------------------------------------------------------
sub fetchForYou {
    my ($client, $callback, $args, $passDict) = @_;

    my $headers = _wantHeaders(ref $passDict eq 'HASH' ? $passDict->{features} : undef);
    my $mode   = $prefs->get('foryou_sort')   || 'release_date';
    # Effective release-family view + which families this section offers (clamped
    # so a section with only one family ticked never renders empty; the selector
    # rows are shown only when BOTH families are available).
    my ($view, $viewHasAlb, $viewHasSing) = _effectiveView('foryou', 'foryou_view');

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
                # _viewFilter narrows to the current release family (albums vs
                # singles/EPs) AFTER the settings type filter, so it only ever
                # narrows within the ticked types.
                my $section  = _forYouSection($lbReleases, shift);
                # Summary is stashed from the UNFILTERED section: the top-level tile's
                # "<date span> · N releases" describes the whole feed, not whichever
                # family lens is active — otherwise the tile's count halved (and its
                # span moved) the moment the user tapped Singles & EPs.
                _stashSummary('user', $section);
                my $releases = _viewFilter($section, $view);
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
                my @opt   = ( _viewToggle($client, 'foryou_view', $view, $viewHasAlb, $viewHasSing),
                              _genresRow($client, 'foryou', $releases),
                              _sortToggle($client, 'foryou_sort', $mode),
                              _refreshItem($client, 'user') );
                # Genres for the rows, CACHE ONLY (peek). A render never waits on a
                # lookup: rows draw with whatever is known and a bounded background
                # top-up fills the rest for next time.
                #
                # THE FILL MUST COVER WHAT THE FILTER IS ABOUT TO WALK. $meta was
                # built under the default GENRE_FETCH_MAX (150) and then used to
                # filter the WHOLE list, so every release past the cap had no entry,
                # bucketed as GENRE_NONE and was dropped outright by any ticked
                # family — while the picker builds its counts over GENRE_WARM_MAX
                # (600) and so promised rows this view then refused to show. Same
                # correctness rule _buildAllLanding already applies to a week, for
                # the same reason: filter before paging needs the wider fill. Only
                # when a filter is actually set — unfiltered keeps the cheap
                # one-page-one-request behaviour.
                my $gmax = @{ _selectedGenres('foryou') } ? GENRE_WARM_MAX : undef;
                _withGenres($releases, sub {
                    my $meta  = shift;
                    # Genre filter applies AFTER the fill (it needs the genres) but
                    # BEFORE rendering. For You is one native-windowed level, so the
                    # whole list is already filled and this costs nothing extra.
                    my $shown = _genreSelectFilter($releases, 'foryou', $meta);
                    my @items = ( _sectionHeader($client, 'PLUGIN_LBF_SECTION_OPTIONS', $headers, \@opt),
                                  @opt, @{ _buildItems($shown, $client, $headers, $mode, $meta) } );
                    $callback->({ items => \@items, cachetime => 0 });
                }, $gmax, peek => 1);
            },
        );
    };

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => 'release_date',
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
                my $releases = _forYouSection($lbReleases, shift);
                _stashSummary('user', $releases);
                $cb->({ items => [ map { _buildReleaseItem($_, $client) } @$releases ], cachetime => 0 });
            },
        );
    };

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => 'release_date',
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
        onDone  => sub {
            my $releases = _allSection(shift);
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

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
        sort    => 'release_date',
        onDone  => sub {
            my $releases = _allSection(shift);
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
                _dropTrendingCount();   # the tile's count memo must not outlive the list
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
    my $rkey = _plResolvedKey($pl->{mbid}, $lastMod, $svcOrder);
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
    my $rkey = _plResolvedKey($mbid, $lastMod, $svcOrder);

    my $title = ref $pass eq 'HASH' ? $pass->{title} : undef;

    if (my $c = $cache->get($rkey)) {
        _dbg("resolved playlist cache hit: $mbid ($c->{matched}/$c->{total})");
        $callback->(_playlistResult($client, $c, $title));
        return;
    }

    # A COLD playlist open is a streaming search per track — measured ~12s each on
    # the warm (4 playlists in 48.6s), so it is the same "user watches dots" problem
    # the follower views had, at a third of the duration. Same three parts: a second
    # opener starts nothing, the first opener gets the row immediately, and the flag
    # is released by wrapping $callback ONCE rather than at each of the five exits.
    my $bkey = "playlist:$mbid";
    if (_isBuilding($bkey)) {
        _dbg("playlist $mbid: a resolve is already in flight — rendering the building row");
        $callback->(_buildingRow($client));
        return;
    }
    my $owns  = _buildingStart($bkey);
    my $fired = 0;
    my $raw   = $callback;
    $callback = sub {
        return if $fired++;
        _buildingEnd($bkey) if $owns;
        $raw->(@_) if ref $raw eq 'CODE';
    };
    _dbg("playlist $mbid: cold resolve started — rendering the building row, completing into cache");
    $raw->(_buildingRow($client));
    $raw = undef;   # the resolve carries on and completes into cache; nothing renders twice

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

# THE REC STORE IS A TABLE, NOT A CACHE — `follow_item`, one row per rec.
#
# It builds FORWARD from first capture: ListenBrainz's feed endpoint serves a
# 75-EVENT window, most of which is not a recommendation at all, so a rec that
# scrolls out of it cannot be re-derived from anywhere, by us or by anyone. It was
# a single blob on a 30-day expiry, which meant it ALSO quietly emptied itself for
# any user who went a month without opening the section — the failure this whole
# rework exists to stop, in its least visible form.
#
# The shape returned to callers is unchanged (`{ tracks => [ newest-first ] }`), so
# nothing downstream had to move with it.
sub _followUser { return $prefs->get('username') // '' }

sub _loadFollowStore {
    my $user = _followUser();
    my $rows = Plugins::ListenBrainzFreshReleases::DB::followList($user, FOLLOW_KEEP_MAX);

    # Empty means either "never captured anything" or "this is the first read
    # since the store moved", and the second is recoverable exactly once. Asked on
    # an EMPTY table only, so a user with a populated store never pays for it.
    if (!@$rows && Plugins::ListenBrainzFreshReleases::DB::importFollow($user)) {
        $rows = Plugins::ListenBrainzFreshReleases::DB::followList($user, FOLLOW_KEEP_MAX);
    }
    return { tracks => $rows };
}

# Dedup key for a rec: recording MBID if present, else lc "artist|title".
sub _followTrackKey {
    my ($t) = @_;
    return $t->{recording_mbid}
        ? "m:$t->{recording_mbid}"
        : 't:' . lc(($t->{artist} // '') . '|' . ($t->{title} // ''));
}

# Merge freshly-fetched feed tracks into the store (add-if-new, so a rec that later
# scrolls out of the 75-event window isn't lost), then trim to FOLLOW_KEEP_MAX
# newest. Both halves are now SQL rather than a read-modify-write of the whole
# list, so two merges racing cannot lose each other's additions. Returns the
# updated store.
sub _mergeFollow {
    my ($tracks) = @_;
    my $user = _followUser();

    my @items = map { { %$_, _key => _followTrackKey($_) } }
                grep { ref $_ eq 'HASH' } @{ $tracks || [] };
    Plugins::ListenBrainzFreshReleases::DB::followAdd($user, \@items) if @items;
    Plugins::ListenBrainzFreshReleases::DB::followTrim($user, FOLLOW_KEEP_MAX);

    return _loadFollowStore();
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
    return Plugins::ListenBrainzFreshReleases::DB::kver("lbf:follow:resolved:") . join("|", $user, $svcOrder, _trackLayerTag());
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

    # Cold resolve = a streaming search per recommended track, the same cost shape as
    # a playlist. $callback is UNDEF on the warm path, so the building row and the
    # detach are both conditional on it — the warm wants the completion, not a
    # placeholder, exactly as in _resolveTrending.
    my $bkey = 'follow:feed';
    if (_isBuilding($bkey)) {
        _dbg("follow feed: a resolve is already in flight — rendering the building row");
        $callback->(_buildingRow($client)) if $callback;
        return;
    }
    my $owns     = _buildingStart($bkey);
    my $released = 0;
    my $release  = sub { return if $released++; _buildingEnd($bkey) if $owns };

    # NOT wrapped into $callback here, unlike the album build. $callback being UNDEF
    # is load-bearing on the warm path — the single terminal below reads
    # `if $callback` to decide whether to BUILD `_followResult` at all, and a wrapper
    # would make that always true, rendering rows the warm never uses. So the flag is
    # released explicitly at the one terminal, and _buildingStart's expiry timer is
    # what covers a resolve that never returns.
    if ($callback) {
        _dbg("follow feed: cold resolve started — rendering the building row, completing into cache");
        $callback->(_buildingRow($client));
        $callback = undef;   # detach: the resolve carries on and completes into cache
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
        $release->();
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
    unless (($prefs->get('token') // '') ne '') {
        _stage('end', 'follow_feed', 'skipped', 'no token');
        return;
    }

    _stage('start', 'follow_feed');
    Plugins::ListenBrainzFreshReleases::API->getFollowFeed(
        # force => 1: bypass the working-cache READ so a warm always re-pulls the
        # feed and can discover newly-arrived recommendations.
        force  => 1,
        onDone => sub {
            my $store  = _mergeFollow(shift // []);
            my $tracks = $store->{tracks} || [];
            unless (@$tracks) {
                _stage('end', 'follow_feed', 'done', 'empty');
                _dbg("warm: follow feed empty");
                return;
            }
            unless ($client) {   # no player → resolve on first open instead
                _stage('end', 'follow_feed', 'skipped', 'no player');
                return;
            }

            my $c = $cache->get(_followResolvedKey());
            if (!$force && $c && ($c->{sig} // '') eq _followSig($tracks)) {
                _stage('end', 'follow_feed', 'cache-hit', 'unchanged');
                _dbg("warm: follow feed unchanged — skip");
                return;
            }
            # NB the resolve is async and this stage's end is recorded HERE, at the
            # hand-off, not at its completion — `_resolveFollow` has no completion
            # callback on the warm path. So this row measures the FETCH, and the
            # resolve it kicks off runs on past it. Worth knowing when reading the
            # table: a short follow_feed does not mean the follow work is finished.
            _stage('end', 'follow_feed', 'done', scalar(@$tracks) . ' track(s), resolve started');
            _resolveFollow($client, $store, undef, $force);
        },
        onError => sub {
            my $err = shift // '';
            _stage('end', 'follow_feed', 'failed', $err);
            $log->info("warm: follow feed fetch failed: $err");
        },
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
    return Plugins::ListenBrainzFreshReleases::DB::kver("lbf:trending:resolved:") . join("|", $user, $svcOrder, _trackLayerTag());   # :7:->:8: — stale-follower filter (0.9.116)
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
#
# The COUNT is memoed (0.9.139). This tile is built on every walk of the top level,
# and working the number out meant reading the whole resolved track list back out of
# SQLite — a deserialise of up to TRENDING_MAX full item hashes — purely to count
# what survives the service filter. The resolved list only changes on the daily warm
# or an explicit Refresh, so one read per interaction is plenty; the key carries the
# resolved-cache key (which itself carries user + service order), so a Refresh or a
# service change re-counts rather than showing a stale figure.
# Same few-seconds window as the feed and section memos — one user interaction's
# worth of re-walks. (Declared here rather than reusing SECTION_MEMO_TTL: that one
# is defined further down the file, and a constant has to be compiled before the
# code that names it.)
use constant TRENDING_COUNT_TTL => 5;
my %_TRENDING_COUNT;    # resolved key => [ expiry, count ]

# Dropped by the Refresh row so the tile can't keep quoting a count for a list that
# has just been thrown away. A sub, not a direct reset, because _refreshItem is
# compiled ABOVE this declaration and so can't see the lexical itself.
sub _dropTrendingCount { %_TRENDING_COUNT = () }

sub _trendingTile {
    my ($client, $feat) = @_;
    my $rkey = _trendingResolvedKey();
    my $e    = $_TRENDING_COUNT{$rkey};
    my $n;
    if ($e && $e->[0] >= time()) {
        $n = $e->[1];
    }
    else {
        $n = 0;
        if (my $c = $cache->get($rkey)) {
            my $enabled = { map { lc($_->{name}) => 1 } _orderedAdapters() };
            $n = grep { _cachedSvcUsable($_->{_svc}, $enabled) } @{ $c->{items} || [] };
            $n = TRENDING_MAX if $n > TRENDING_MAX;
        }
        # Memo the "nothing resolved yet" answer too — before the first warm that is
        # every walk, and it's the same SQLite lookup either way. One key only: the
        # resolved key changes with the user/service order, and an old one is dead.
        %_TRENDING_COUNT = ($rkey => [ time() + TRENDING_COUNT_TTL, $n ]);
    }
    my $line2 = $n ? sprintf(cstring($client, 'PLUGIN_LBF_N_TRACKS'), $n) : '';
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
    my ($client, $callback, $force, $feat, $onDone) = @_;

    # $onDone signals COMPLETION to the warm chain, which is a different thing from
    # $callback (which renders). It must fire at EVERY terminal point or the chain
    # stalls and the two album builds never start — so it is wrapped to fire at most
    # once and called from all four exits.
    #
    # $owns is what keeps the in-flight guard honest: only the caller that SET the
    # flag clears it. A caller that merely found it set advances its own chain and
    # leaves the flag alone.
    my $bkey  = 'trending:tracks';
    my $owns  = 0;
    my $fired = 0;
    my $finish = sub {
        return if $fired++;
        _buildingEnd($bkey) if $owns;
        $onDone->() if ref $onDone eq 'CODE';
    };

    my $user = $prefs->get('username') // '';
    unless (length $user) {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_SETUP_REQUIRED'), type => 'text' }], cachetime => 0 }) if $callback;
        $finish->();
        return;
    }

    my $rkey = _trendingResolvedKey();
    if (!$force && (my $c = $cache->get($rkey))) {
        my $n = scalar(@{ $c->{items} || [] });
        _stage('end', 'trending_tracks', 'cache-hit', "$n tracks");
        _dbg("trending cache hit ($n tracks)");
        $callback->(_trendingResult($client, $c, $feat)) if $callback;
        $finish->();
        return;
    }

    # A BUILD IS ALREADY RUNNING. Render "still being built" NOW rather than
    # starting a second fan-out or spinning on Material's three dots — the cold
    # build is ~50s, far past any watchdog worth waiting behind, which is what the
    # measurement settled. The flag is left alone: this caller does not own it.
    if (_isBuilding($bkey)) {
        _dbg("trending: a build is already in flight — rendering the building row");
        $callback->(_buildingRow($client)) if $callback;
        $finish->();
        return;
    }
    $owns = _buildingStart($bkey);

    # AND THE FIRST OPENER GETS THE ROW TOO — this is the whole point, and 0.9.180
    # missed it. Guarding only the SECOND caller left the first one holding
    # $callback for the entire build, which is precisely the ~50s of Material
    # loading dots the building state exists to replace: the commonest case (a cold
    # open with nothing running) was the one case still unguarded.
    #
    # Rendering NOW and clearing $callback detaches the render from the build. The
    # fan-out is async and holds its own closures, so it carries on and completes
    # into the cache; every later render path is already `if $callback`, so none of
    # them fires a second time into a callback the skin has finished with. The next
    # open reads the cache and is instant.
    if ($callback) {
        _dbg("trending: cold build started — rendering the building row, completing into cache");
        $callback->(_buildingRow($client));
        $callback = undef;
    }

    my $empty = sub {
        my ($msg, $cacheEmpty) = @_;
        _stage('end', 'trending_tracks', ($cacheEmpty ? 'done' : 'failed'), ($msg // 'empty'));
        _dbg("trending: $msg") if $msg;
        # Cache a genuine "no data" outcome (nobody followed / all stale / no candidates)
        # SHORT, so it doesn't re-run the whole fan-out + aggregation on every browse but
        # re-checks within the hour. NEVER cache the network-error path ($cacheEmpty unset)
        # — a transient following/stats failure must not pin the list empty.
        eval { $cache->set($rkey, { items => [], total => 0 }, PLAYLIST_INCONCLUSIVE_TTL); 1 } if $cacheEmpty;
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_TRENDING'), type => 'text' }], cachetime => 0 }) if $callback;
        $finish->();
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
        # NB the onError for this call is at the END of the argument list, below —
        # getFollowing's own default would be `sub { $onDone->([]) }` (API.pm ~2012),
        # which would launder a network failure into "not following anyone" and get
        # it cached. It is overridden there, correctly and without the cache flag.
        # Don't add a second one here: these arguments become a hash, so the LAST
        # onError wins and an earlier one is silently dead.
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

                    # DID THE FAN-OUT ACTUALLY RETURN ANYTHING? This decides whether a
                    # subsequent empty result is a FACT about the followed users or just
                    # what we happened to get this time, and those must not be cached
                    # alike — see docs/feed-findings-2026-08-14.md §3.
                    #
                    # The fan-out is one getUserTopRecordings per follower and takes ~10s.
                    # When it comes back thin (a slow or failing ListenBrainz, a follower
                    # whose stats have not been computed yet) %recFol is empty, @$cands is
                    # then empty, and the old code cached "no data" for an HOUR — so the
                    # feed sat empty until the user found Refresh, which is the only path
                    # that forces past the read. Observed live: `mapped 0 recordings in
                    # 0ms` and `trending cache hit (0 tracks)` in the same session that
                    # later produced 50 tracks.
                    my $sawListens = scalar keys %recFol;

                    my $afterMap = sub {
                        my ($meta) = @_;
                        _dbg("trending timing: mapped " . scalar(@mbids) . " recordings in " . $dt->() . "ms");
                        my $cands = _buildTrendingCandidates($followers, $perFollower, $meta || {}, TRENDING_CANDIDATES);
                        # Blocked artists never reach the resolve (no wasted searches);
                        # the render side filters again for blocks added after this build.
                        my $blk = _blockedSet();
                        @$cands = grep { !_trendBlocked($_->{artist}, $_->{artist_mbid}, $blk) } @$cands;
                        # Cache the empty ONLY when the fan-out gave us listens to work
                        # from — then "no candidates" is a real property of those users
                        # (everything blocked, or nothing mapped to an album). With no
                        # listens at all we learned nothing, so record nothing: an empty
                        # result is not a fact.
                        unless (@$cands) {
                            $empty->($sawListens ? "no candidate tracks"
                                                 : "no listens from the fan-out — not caching",
                                     $sawListens ? 1 : 0);
                            return;
                        }

                        my $resolve = sub {
                            _resolveTracks($client, $cands, sub {
                            my ($items, $inconclusive, $unmatched, $owned) = @_;
                            $items //= []; $owned //= 0;
                            @$items = @{ $items }[0 .. TRENDING_MAX - 1] if @$items > TRENDING_MAX;
                            my $payload = { items => $items, total => scalar(@$items) };
                            my $ttl = $inconclusive ? PLAYLIST_INCONCLUSIVE_TTL : TREND_RESOLVED_TTL;
                            eval { $cache->set($rkey, $payload, $ttl); 1 }
                                or $log->warn("resolved trending cache set failed: $@");
                            _stage('end', 'trending_tracks', 'done',
                                   scalar(@$items) . " tracks, $owned owned excluded"
                                   . ($inconclusive ? ", $inconclusive inconclusive" : ""));
                            _dbg("resolved trending: " . scalar(@$items) . " tracks"
                                . " ($owned owned excluded"
                                . ($inconclusive ? ", $inconclusive inconclusive — short TTL" : "") . ")"
                                . " — resolve " . $dt->() . "ms, total " . int((Time::HiRes::time() - $t0) * 1000) . "ms");
                            $callback->(_trendingResult($client, $payload, $feat)) if $callback;
                            $finish->();
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
                                    },
                                    # Disambiguates the hosted tier, which otherwise
                                    # resolves the artist NAME by popularity.
                                    artist_mbid => ($c->{artist_mbid} // ''));
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

    # Render ONCE. Either the building row (a build is running, or one has just
    # started for us) or the real list — whichever comes first wins, and the other
    # is dropped rather than firing a second time into a callback the skin has
    # already used.
    #
    # $what is logged, not decorative: it is the ONLY way to tell "the row was
    # never produced" from "the row was produced and the skin ignored it", and
    # those two have completely different fixes.
    my $rendered = 0;
    my $render = sub {
        my ($res, $what) = @_;
        if ($rendered++) { _dbg("albums ($range): dropped a second render ($what)"); return }
        _dbg("albums ($range): rendering $what");
        $callback->($res);
    };

    _buildAlbumsData($client, $range, sub {
        my ($data) = @_;
        # undef means "a build is already in flight" (never "empty"). Render the
        # building row rather than an empty list the user would read as final.
        return $render->(_buildingRow($client), 'the building row (a build was already in flight)')
            unless defined $data;
        $render->(_trendingAlbumsResult($client, $data, $range, $feat), 'the real list');
    }, 0,
    # A COLD build just started for this open. Render immediately and let it
    # complete into the cache — a ~50s hold is what the building row replaces.
    sub { $render->(_buildingRow($client), 'the building row (cold build just started)') });
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
    # :6:->:7: (0.9.149) — NOT a shape change: it abandons the EMPTY aggregates the
    # pre-0.9.149 full-TTL empty-cache write pinned for 7d/30d. Without the bump a
    # poisoned This Year list stays empty until the calendar year rolls over.
    my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());
    return Plugins::ListenBrainzFreshReleases::DB::kver("lbf:trending:albums:") . "$range:$period:$user|$svcOrder|" . _streamLayerTag();
}

sub _buildAlbumsData {
    my ($client, $range, $onDone, $force, $onPending) = @_;
    $force ||= 0;

    # THE FLAG IS CLEARED BY WRAPPING $onDone, not by hand at each exit. This sub
    # has a dozen scattered `$onDone->([])` returns across four nested fan-out
    # callbacks; clearing at each one would work today and leak the first time a
    # new early return is added. $owns is read at CALL time, so the wrapper is
    # installed before the flag is taken and still does the right thing on the
    # paths that never take it (cache hit, no username, already building).
    my $bkey  = "trending:albums:$range";
    my $owns  = 0;
    my $fired = 0;
    my $raw   = $onDone;
    $onDone = sub {
        return if $fired++;
        _buildingEnd($bkey) if $owns;
        $raw->(@_) if ref $raw eq 'CODE';
    };

    my $user = $prefs->get('username') // '';
    unless (length $user) { $onDone->([]); return; }

    my $dkey = _albumsDataKey($range, $user);
    if (!$force && (my $data = $cache->get($dkey))) { $onDone->($data); return; }

    # Already building: hand back undef, which is DISTINCT from the empty arrayref
    # every other exit uses. The render path turns undef into the "still being
    # built" row; the warm chain treats it as "skip, advance". Returning [] here
    # would render an affirmative "nobody you follow has listened" — a cold build
    # reported as a finished empty one, which is the confusion this whole change
    # exists to remove.
    if (_isBuilding($bkey)) {
        _dbg("albums ($range): a build is already in flight — not starting a second");
        $onDone->(undef);
        return;
    }
    $owns = _buildingStart($bkey);

    # $onPending fires the moment a COLD build starts, so the view can render the
    # building row instead of holding its callback for the whole fan-out. The warm
    # chain passes no $onPending and is unaffected — it wants the completion, not a
    # placeholder. Separate from $onDone on purpose: this build still has to finish
    # and populate the cache, so the two events are genuinely different.
    #
    # LOGGED EITHER WAY, and deliberately: 0.9.181 instrumented the TRACKS cold
    # start but not this one, so when the albums view span its dots instead of
    # showing the row there was no line saying whether the hook had fired — the
    # only misbehaving path was the only uninstrumented one. "no render hook" is
    # the warm and is correct; seeing it on a USER open is the bug.
    if (ref $onPending eq 'CODE') {
        _dbg("albums ($range): cold build started — rendering the building row, completing into cache");
        $onPending->();
    }
    else {
        _dbg("albums ($range): cold build started — no render hook (warm path)");
    }
    my $ttl = ($range eq 'this_year') ? TREND_ALBUMS_YEAR_TTL : TREND_ALBUMS_MONTH_TTL;

    # Phase timing, the same shape `_resolveTrending` has carried since 0.9.108 —
    # this build had none, so a slow cold Trending Albums could only be guessed at.
    # dt() = ms since the last mark.
    my $t0 = Time::HiRes::time();
    my $tp = $t0;
    my $dt = sub { my $now = Time::HiRes::time(); my $d = int(($now - $tp) * 1000); $tp = $now; return $d };

    Plugins::ListenBrainzFreshReleases::API->getFollowing(
        force  => $force,
        onDone => sub {
            my $followers = shift // [];
            @$followers = @{ $followers }[0 .. FOLLOWER_MAX - 1] if @$followers > FOLLOWER_MAX;
            unless (@$followers) { $onDone->([]); return; }
            _dbg("albums ($range) timing: following " . scalar(@$followers) . " in " . $dt->() . "ms");

            _activeFollowers($followers, sub {
            $followers = shift;
            unless (@$followers) { $onDone->([]); return; }
            _dbg("albums ($range) timing: active-follower filter -> "
                 . scalar(@$followers) . " in " . $dt->() . "ms");

            _fanFollowers($followers,
                sub {
                    my ($u, $cb) = @_;
                    Plugins::ListenBrainzFreshReleases::API->getUserTopReleaseGroups(
                        $u, range => $range, count => 50, force => $force, onDone => $cb);
                },
                sub {
                    my ($perFollower) = @_;
                    _dbg("albums ($range) timing: stats fan-out in " . $dt->() . "ms");
                    my $data = _aggregateAlbums($followers, $perFollower);
                    _dbg("albums ($range) timing: aggregate " . scalar(@$data)
                         . " album(s) in " . $dt->() . "ms");
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
                        # An EMPTY aggregate is INCONCLUSIVE, never a fact worth 7d/30d.
                        # It means every follower's stats came back empty this build — a
                        # transient LB blip, a fan-out that all timed out, or a following
                        # fetch that emptied — and caching that at the full TTL pinned
                        # "No trending data yet" for a week (month) or a MONTH (year), on a
                        # view whose empty state doesn't even render a Refresh row. Short
                        # TTL, like every other inconclusive settle below (diagnosed live
                        # 2026-07-30: LB was serving 650 rows / 558 albums while the plugin
                        # returned the empty message from cache without a single request).
                        unless ($total) { $settle->($data, 1); return; }

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
                                . ($timedOut ? " (timed out — short TTL)" : "")
                                . " — gate " . $dt->() . "ms, total "
                                . int((Time::HiRes::time() - $t0) * 1000) . "ms");
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
                        # This is the release-group metadata pass finishing. NB it
                        # carries `inc=release_group tag`, so it fetches GENRES as
                        # well as the date/type these rows render — the genres are
                        # stored rather than wasted, but the latency lands here, on
                        # a view that shows none.
                        _dbg("albums ($range) timing: release-group metadata in " . $dt->() . "ms");
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
                        if ($i >= @miss) {
                            _dbg("albums ($range) timing: name-resolved " . scalar(@miss)
                                 . " unmapped row(s) in " . $dt->() . "ms");
                            $rgPass->(); return;
                        }
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
                            },
                            artist_mbid => ($a->{artist_mbid} // ''));
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
        # The empty view keeps its Refresh row (no sort toggle — nothing to sort).
        # Without it a bad build was a DEAD END: the aggregate cache is the only way
        # back and the user had no way to drop it, so the only exits were the cache
        # TTL or the period rolling over (January, for This Year).
        my @opt = ( _refreshItem($client, 'trending_albums', $range) );
        @items  = ( _sectionHeader($client, 'PLUGIN_LBF_SECTION_OPTIONS', $useH, \@opt), @opt,
                    { name => cstring($client, 'PLUGIN_LBF_NO_TRENDING'), type => 'text' } );
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
# The fresh-release-shaped hashref a trending aggregate renders through. Split
# out of _trendingAlbumRow so the COVER WARM can build the same thing: the warm
# needs a $rel to hand _warmCovers, and a second copy of this mapping would drift
# the moment either side changed — which is exactly how the release-group cover
# URL came to be built two different ways (0.9.188).
sub _trendingAlbumRel {
    my ($agg) = @_;
    return {
        artist_credit_name         => $agg->{artist},
        release_name               => $agg->{title},
        release_date               => ($agg->{date} || ($agg->{year} ? "$agg->{year}-01-01" : '')),
        release_group_mbid         => $agg->{release_group_mbid},
        release_group_primary_type => ($agg->{type} // ''),
        caa_id                     => $agg->{caa_id},
        caa_release_mbid           => $agg->{caa_release_mbid},
        artist_mbids               => ($agg->{artist_mbid} ? [ $agg->{artist_mbid} ] : []),
    };
}

# The release-GROUP art fallback, as a $rel coverArtUrl understands. Stats rows
# built from UNMAPPED listens carry no caa_release_mbid, so the row would fall back
# to the plugin icon; a release-group mbid still resolves at CAA. Named because the
# warm has to queue the IDENTICAL url — a warm that guessed differently would fill
# a key nobody reads, which is the trap _warmCovers' own comment describes.
sub _trendingAlbumFallbackRel {
    my ($agg) = @_;
    return { caa_release_group_mbid => $agg->{release_group_mbid} };
}

sub _trendingAlbumRow {
    my ($client, $agg) = @_;
    my $rel = _trendingAlbumRel($agg);

    my $item = _buildReleaseItem($rel, $client);
    # Artwork fallback: stats rows built from UNMAPPED listens carry no
    # caa_release_mbid (coverArtUrl → undef → plugin icon), but once the row has a
    # release-group mbid (from stats or the MB name-resolution) the Cover Art
    # Archive can serve the GROUP's front cover directly — same host, so the
    # registered image proxy caches it like every other cover.
    # THROUGH coverArtUrl, not a literal. This built the same release-group URL
    # by hand, which meant it was the one CAA row in the plugin that did NOT pick
    # up the `.jpg` suffix — so trending rows would have gone on shipping as
    # `image.png` and re-encoding every cover at ~6x the bytes while every other
    # row got JPEG. One builder for the string is what stops that recurring; the
    # hashref form is exactly the shape coverArtUrl already handles for MuSpy.
    if (($item->{image} // '') eq ICON && $agg->{release_group_mbid}) {
        $item->{image} = Plugins::ListenBrainzFreshReleases::API->coverArtUrl(
            _trendingAlbumFallbackRel($agg));
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

# Queue the covers for a list of trending AGGREGATES.
#
# WHY THIS EXISTS AT ALL: `_warmCovers` was called from exactly three places, all
# inside `warmFeeds` — For You, All Releases and MuSpy. **People You Follow warmed
# no artwork whatsoever**, so every Trending Albums row was cold on first sight,
# every time, at ~2.1s of Cover Art Archive latency each. That is the same "the
# artwork is missing and then populates" report as the release feeds, arriving
# from a section nobody had wired up.
#
# It runs on a CACHE HIT as well as a fresh build, and that is the point rather
# than an accident: `_buildAlbumsData` answers its callback with the stored
# aggregates when the data is still inside its TTL (2/7/30 days by range), so the
# list is in hand either way, and the covers are what expire independently of it.
#
# Both mappings go through the same two builders the ROW uses, so the warmed path
# is byte-identical to what the client will ask for. The fallback rel is included
# because a stats row with no caa_release_mbid renders its cover from the release
# GROUP — the case that is most likely to be cold and least likely to be noticed.
sub _warmTrendingCovers {
    my ($aggs, $label) = @_;
    return unless ref $aggs eq 'ARRAY' && @$aggs;
    my @rels;
    for my $agg (@$aggs) {
        next unless ref $agg eq 'HASH';
        push @rels, _trendingAlbumRel($agg);
        push @rels, _trendingAlbumFallbackRel($agg) if $agg->{release_group_mbid};
    }
    _warmCovers(\@rels, $label);
    return;
}

# Warm hook: pre-resolve the trending tracks (needs a player) and pre-build the two
# album aggregates (no player needed), so the section opens instantly. Chained after
# the follow-feed warm in warmCache.
sub _warmTrending {
    my ($client, $force) = @_;
    unless (($prefs->get('username') // '') ne '') {
        _stage('end', $_, 'skipped', 'no username')
            for qw(trending_tracks trending_month trending_year);
        return;
    }

    # ONE AT A TIME. THIS WAS MEASURED, NOT PREFERRED.
    #
    # These three builds used to be started together. Each runs its own
    # getFollowing -> active-follower fan-out -> per-follower stats fan-out at
    # FOLLOWER_FANOUT (10) concurrency, so three at once put THIRTY requests in
    # flight — ListenBrainz's entire ~30-per-10s budget, fired inside 50ms.
    #
    # The live result on 2026-08-22: `warmstats` showed all three starting within
    # 50ms (51.03 / 51.06 / 51.08), getFollowing fetched THREE TIMES 25ms apart
    # because none had finished writing its cache before the next asked, and
    # **39 of 39 stats requests came back 429**. People You Follow was empty:
    # "mapped 0 recordings", "aggregate 0 album(s)" on both ranges.
    #
    # Serialising also makes the per-user caches do their job: getFollowing and
    # getLatestListenTs are cached, so builds 2 and 3 are nearly free ONLY if
    # build 1 has finished writing them first. Racing defeated the caching that
    # was supposed to make this cheap.
    #
    # Chained back-to-front so each step is defined before the one that calls it.
    my $albumsYear = sub {
        _stage('start', 'trending_year');
        _buildAlbumsData($client, 'this_year', sub {
            _stage('end', 'trending_year', 'done', scalar(@{ $_[0] // [] }) . ' album(s)');
            _warmTrendingCovers($_[0], 'trending albums · this year');
        }, $force);
    };

    # The albums build needs the player too (its streaming gate resolves each album
    # via _findPlayable); with no player it builds ungated on a short TTL.
    my $albumsMonth = sub {
        _stage('start', 'trending_month');
        _buildAlbumsData($client, 'this_month', sub {
            _stage('end', 'trending_month', 'done', scalar(@{ $_[0] // [] }) . ' album(s)');
            _warmTrendingCovers($_[0], 'trending albums · this month');
            $albumsYear->();
        }, $force);
    };

    if ($client) {
        _stage('start', 'trending_tracks');
        # The 5th arg is the COMPLETION hook, distinct from the render callback
        # (4th is $feat, which the warm has no use for). It fires at every terminal
        # point in _resolveTrending, including the cache-hit and empty ones — a
        # chain that only advanced on success would stall the whole section the
        # first time a follower build found nothing.
        _resolveTrending($client, undef, $force, undef, $albumsMonth);
    }
    else {
        _stage('end', 'trending_tracks', 'skipped', 'no player');
        $albumsMonth->();
    }
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
# ---------------------------------------------------------------------------
# THE FEED WARM — deliberately OUTSIDE warmCache, and ahead of it.
#
# `warmCache` returns early without a username, which is correct for everything it
# does (playlists, follow, trending all need an account). The consequence nobody
# noticed is that ALL RELEASES — which needs no account whatsoever — HAS NEVER BEEN
# WARMED FOR ANYONE. It only ever filled on a user's own first browse of the day,
# which is exactly the 2-15s ListenBrainz round trip the warm exists to remove.
#
# It is worth doing NOW, and was not before, because a feed fetch fills a durable
# store rather than a cache key that expired at local midnight: warming a feed that
# was about to be re-minted anyway bought nothing.
#
# Both feeds go through the ordinary getFreshReleases* path, so all of the coverage
# logic applies unchanged — a warm on a fresh store makes NO request at all, and
# each one ingests exactly as a browse would. For You is skipped without a username;
# All Releases never is.
# ---------------------------------------------------------------------------
# THE FEEDS RUN IN PRIORITY ORDER: For You -> All Releases -> MuSpy, each starting
# when the previous finishes, and $onDone fires when the last one does.
#
# They used to fire all three at once. On a WARM store that costs nothing (measured:
# all three ended within 0.01s, served from the feed store) — but a cold store is
# exactly when the ordering matters, and a cold store is what a new user and every
# dev build has. "New Releases should populate first, then All releases" is the
# stated priority; concurrent starts cannot honour it.
#
# COVERS STAY FIRE-AND-FORGET off each feed as it lands, deliberately. Chaining the
# next feed behind ~450 cover fetches would make the ordering worse, not better, and
# artwork appearing promptly is its own requirement.
sub warmFeeds {
    my ($onDone) = @_;

    # A CHAIN NEEDS A WATCHDOG — this is the failure mode the old fire-and-forget
    # did not have. With the stages independent, one feed hanging cost only that
    # feed; chained, it starves playlists and followers for ever. So the chain is
    # raced against a timer and warmCache runs regardless. Fires at most once.
    my $fired  = 0;
    my $wdog;
    my $finish = sub {
        return if $fired++;
        Slim::Utils::Timers::killSpecific($wdog) if $wdog;
        $onDone->() if ref $onDone eq 'CODE';
    };
    $wdog = Slim::Utils::Timers::setTimer(undef, time() + WARM_FEED_CHAIN_MAX, sub {
        _dbg("warm: feed chain still running after " . WARM_FEED_CHAIN_MAX
             . "s — starting the rest anyway");
        $finish->();
    });

    # MuSpy rides the For You feed and has its own (much wider) window, so warm it
    # too — it is a no-op without a configured user id. Last because it is the
    # narrowest audience: most users have no MuSpy id at all.
    my $muspy = sub {
        _stage('start', 'muspy_feed');
        Plugins::ListenBrainzFreshReleases::API->getMuSpyReleases(
            # force => 1: the warm must warm what ARRIVED, not what a browse left
            # in the memo. See the block comment on the sub.
            force  => 1,
            onDone => sub {
                my $n = scalar(@{ $_[0] // [] });
                _stage('end', 'muspy_feed', 'done', "$n releases");
                _dbg("warm: muspy — $n stored");
                _warmCovers($_[0], 'muspy');
                $finish->();
            },
        );
    };

    my $all = sub {
        _stage('start', 'all_feed');
        Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
            sort   => 'release_date',
            # force => 1: WITHOUT THIS THE WARM WARMED YESTERDAY'S FEED. The store
            # short-circuit answered in ~0.00s with the stored list and the
            # revalidation's result reached nobody, so _warmCovers below never saw
            # a release that arrived today. See API::getFreshReleasesAll.
            force  => 1,
            onDone => sub {
                my $n = scalar(@{ $_[0] // [] });
                _stage('end', 'all_feed', 'done', "$n releases");
                _dbg("warm: all releases — $n stored");
                _warmCovers($_[0], 'all releases');
                $muspy->();
            },
            # A warm failure is not the user's problem: they are not looking at
            # anything, and the next browse retries. Never surfaced — but it MUST
            # still advance the chain, or one bad feed strands everything behind it.
            onError => sub {
                _stage('end', 'all_feed', 'failed', ($_[0] // '?'));
                _dbg("warm: all releases failed — " . ($_[0] // '?'));
                $muspy->();
            },
        );
    };

    unless (($prefs->get('username') // '') ne '') {
        # Recorded rather than silently absent: "no username" is the commonest
        # reason a personalised stage contributes nothing, and a report that
        # simply omitted the row would read as a stage that never ran.
        _stage('end', 'foryou_feed', 'skipped', 'no username');
        _stage('end', 'muspy_feed',  'skipped', 'no username');
        # All Releases needs no username, so it still runs — and is now the only
        # link in the chain, so it finishes it.
        _stage('start', 'all_feed');
        Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
            sort   => 'release_date',
            force  => 1,   # see the chained branch above
            onDone => sub {
                my $n = scalar(@{ $_[0] // [] });
                _stage('end', 'all_feed', 'done', "$n releases");
                _dbg("warm: all releases — $n stored");
                _warmCovers($_[0], 'all releases');
                $finish->();
            },
            onError => sub {
                _stage('end', 'all_feed', 'failed', ($_[0] // '?'));
                _dbg("warm: all releases failed — " . ($_[0] // '?'));
                $finish->();
            },
        );
        return;
    }

    # FOR YOU FIRST — the flagship feed, and the one the home-screen extra shows.
    _stage('start', 'foryou_feed');
    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort   => 'release_date',
        # force => 1: same reason as All Releases below — the warm must see the
        # releases that actually arrived, not the stored copy.
        force  => 1,
        onDone => sub {
            my $n = scalar(@{ $_[0] // [] });
            _stage('end', 'foryou_feed', 'done', "$n releases");
            _dbg("warm: for you — $n stored");
            _warmCovers($_[0], 'for you');
            $all->();
        },
        onError => sub {
            _stage('end', 'foryou_feed', 'failed', ($_[0] // '?'));
            _dbg("warm: for you failed — " . ($_[0] // '?'));
            $all->();
        },
    );
}

# ---------------------------------------------------------------------------
# COVER PRE-WARM — why this exists, and why it warms three SIZES of one picture.
#
# A row's cover is not cached as "that picture". LMS's image proxy keys its cache
# on the WHOLE request path — the escaped source URL, the size spec the skin
# spliced in, AND the extension (`Slim::Web::ImageProxy::getImage`, `cachekey =>
# $path`). Material picks that spec from the DEVICE: `_150x150_f` for a list row,
# doubled to `_300x300_f` on a hi-dpi screen, and `_300x300_f` / `_600x600_f` for
# a grid tile. So a cover the desktop warmed is still COLD on the phone.
#
# Measured on the live server, same cover, varying only the spec: 150 -> 1.80s,
# 300 -> 1.92s, 400 -> 2.05s, 600 -> 2.12s, then a REPEAT of 150 -> 0.03s. The
# cache works perfectly; it is simply per size. The cost is Cover Art Archive
# itself, which 307s out to an archive.org node with no CDN behind it (0.11s +
# 0.63s + ~0.85s per cover). That is the whole of "the covers take ages on my
# other device".
#
# Nothing can merge those cache entries, so the fix is to fill them ahead of
# time, on the daily warm, while nobody is looking. Steady state is cheap: the
# proxy holds an entry for 30 days and we record what we have warmed, so a second
# pass over the same feed only pays for releases that are actually new.
# ---------------------------------------------------------------------------

# The specs Material actually asks for, read out of the live material.min.js:
# LMS_LIST_IMAGE_SZ = IS_HIGH_DPI ? 300 : 150 (list rows) and
# LMS_IMAGE_SZ      = IS_HIGH_DPI ? 600 : 300 (grid tiles), each rendered as
# "_<n>x<n>_f". The now-playing pair (1024/2048) is deliberately NOT warmed — no
# LBF row is ever the now-playing artwork, and those two are the most expensive
# entries in the whole table.
use constant COVER_SPECS => [qw(_150x150_f _300x300_f _600x600_f)];

# Covers warmed per feed per pass.
#
# THIS WAS 150 AGAINST A FEED OF 2,157, and the old comment's premise — "nobody
# scrolls that far" — was answering the wrong question. It is not about scrolling
# to the tail; it is that 93% of All Releases rows had NO warmed artwork at all,
# so opening almost any week showed bare rows that filled in front of the user at
# ~2.1s each. That is the "artwork is missing and then populates" report, and no
# amount of speed fixes it while the cap is the binding constraint.
#
# Raised now because the pass is no longer serial (see COVER_CONCURRENCY): the
# arithmetic that justified a small cap has changed by ~4x. Measured against the
# live server, cold covers through the proxy: 0.40/s serial, 1.62/s at
# concurrency 8. A whole 2,157-release feed is 3 x 2,157 = 6,471 requests, which
# went from ~4.5 hours to ~1.1 hours of background work — and the markers hold
# for COVER_WARM_TTL (25 days), so this is a first-run cost, not a nightly one.
# Steady state is whatever is genuinely new.
use constant COVER_WARM_MAX => 2000;

# Requests in flight at once.
#
# THE OLD VALUE WAS EFFECTIVELY 1, and the comment defending it said a parallel
# burst was "neither faster for us nor kind to them". The first half is measured
# false: same server, same cold covers, wall time for a fixed batch — 1 -> 0.40
# covers/s, 4 -> 1.20, 8 -> 1.62, 16 -> 2.77, still climbing at 16. It scales
# because the cost is almost entirely ORIGIN LATENCY, not work: Cover Art Archive
# 307s to an archive.org node with no CDN, ~2.1s to deliver 25-41 KB. That is
# nearly all waiting, and waiting parallelises.
#
# 8 rather than 16, for a reason that has nothing to do with CAA: these requests
# go to OUR OWN server, so each one occupies an LMS HTTP handler slot that a
# browsing user might want. 8 takes most of the available speedup while leaving
# the server responsive. It is a constant precisely so it can be moved.
use constant COVER_CONCURRENCY => 8;

# How long we remember that a path is warm. Deliberately UNDER the proxy's own 30d
# (Slim::Web::ImageProxy::Cache is constructed with 86400*30), so our marker can
# never outlive the entry it describes. Note this is the PLUGIN's store, whose
# expires_at is always absolute — the LMS 30-day TTL cliff does not apply here.
use constant COVER_WARM_TTL => 25 * 86400;

my @coverQueue;      # [ [$path, $key], ... ] — proxy paths still to fetch
my %coverQueued;     # $path => 1 while queued, so two feeds can't queue it twice
my $coverRunning = 0;   # requests currently in flight (0 .. COVER_CONCURRENCY)
my $coverPumping = 0;   # re-entrancy guard on _coverTick's launch loop
# Instrumentation only. The queue is SHARED by all three feeds, so the covers
# stage spans from the first path any of them queues to the moment the queue
# drains — it is deliberately one row rather than three, because that is how the
# work actually happens and three rows would imply a parallelism that isn't there.
my $coverStageOpen = 0;
my $coverFetched   = 0;

sub _warmCovers {
    my ($releases, $label) = @_;

    return unless $prefs->get('warm_covers') // 1;
    return unless ref $releases eq 'ARRAY' && @$releases;

    eval { require Slim::Web::ImageProxy; 1 } or return;
    return unless Slim::Web::ImageProxy->can('proxiedImage');

    # Newest first, which is the order every view renders in — so a capped pass
    # warms the covers that are actually at the top of the list.
    my @rels = sort { ($b->{release_date} // '') cmp ($a->{release_date} // '') } @$releases;

    # SPEC-MAJOR, NOT RELEASE-MAJOR — the queue is walked in order, so the order
    # IS the priority, and this was the wrong way round. Release-major meant a
    # release got all three of its specs before the next release got any, so a
    # pass interrupted (or merely still running) part-way had a third of the feed
    # fully warmed at every size and the rest with nothing — while the size a
    # standard-dpi list row actually asks for, _150x150_f, was still unfetched
    # for two thirds of the rows the user was looking at.
    #
    # Walking spec-first means the FIRST third of the work leaves every row in
    # the feed with its list-row cover, and the two hi-dpi/grid sizes fill behind
    # it. COVER_SPECS is already ordered cheapest-and-most-asked-for first, so
    # the useful pass is the one that completes first.
    my ($seen, $added) = (0, 0);
    my @bases;
    for my $rel (@rels) {
        last if @bases >= COVER_WARM_MAX;
        my $url = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel) or next;
        # Built by the SAME sub XMLBrowser runs over the row (proxiedImage), so
        # the string we warm is byte-identical to the one the client will ask
        # for. Anything else fills a key nobody ever reads.
        my $base = Slim::Web::ImageProxy::proxiedImage($url) or next;
        push @bases, $base;
    }
    $seen = scalar @bases;

    for my $spec (@{ +COVER_SPECS }) {
        for my $base (@bases) {
            (my $path = $base) =~ s/(\.\w+)$/$spec$1/ or next;
            next if $coverQueued{$path};
            # THROUGH kver, so the family can be invalidated like every other.
            # Written as a bare literal this marker outlived the thing it
            # described: it is a claim about an entry in the LMS image proxy's
            # cache, keyed by a path that changes whenever the row URL changes
            # (the `.png` -> `.jpg` switch being exactly that), and there was no
            # way to retire the stale ones short of the dev wipe.
            my $key = Plugins::ListenBrainzFreshReleases::DB::kver('lbf:imgwarm:') . $path;
            next if $cache->get($key);
            $coverQueued{$path} = 1;
            push @coverQueue, [ $path, $key ];
            $added++;
        }
    }

    return unless $added;
    unless ($coverStageOpen) {
        $coverStageOpen = 1;
        $coverFetched   = 0;
        _stage('start', 'covers');
    }
    _dbg("warm: covers — $label queued $added request(s) across $seen release(s)");
    _coverTick();
}

# Keep COVER_CONCURRENCY requests in flight, refilling a slot the moment one
# lands. No inter-request timer: with a bounded number in flight the pacing IS
# the bound, and a gap between launches only lengthened an already-serial pass.
#
# THE PUMP IS RE-ENTRANT-GUARDED, and that is not theoretical. `$done` is called
# INLINE when a request fails to launch at all (the eval below), so without the
# guard a run of launch failures would recurse one frame per queued path — and
# the queue is now thousands of entries deep, not a hundred and fifty. The guard
# makes such a `$done` decrement its counter and return, leaving the loop that is
# already running to fill the freed slot.
sub _coverTick {
    return if $coverPumping;
    $coverPumping = 1;
    _coverLaunch(shift @coverQueue)
        while $coverRunning < COVER_CONCURRENCY && @coverQueue;
    $coverPumping = 0;

    # Checked here rather than inside $done: with several in flight, "the queue is
    # empty" is not the same as "the pass is over", and ending the stage on the
    # first callback to see an empty queue would close it with requests still
    # outstanding.
    _coverMaybeEnd();
}

sub _coverMaybeEnd {
    return if @coverQueue || $coverRunning;
    return unless $coverStageOpen;
    # Drained. A later feed landing after this re-opens the stage, which
    # would overwrite the row — acceptable, and visible: the report shows
    # the LAST drain, and its start offset says when that pass began.
    $coverStageOpen = 0;
    _stage('end', 'covers', 'done', "$coverFetched request(s)");
}

sub _coverLaunch {
    my ($next) = @_;
    my ($path, $key) = @$next;
    $coverRunning++;

    # ONCE-ONLY. Both SimpleAsyncHTTP callbacks and the inline failure path all
    # route here; a double call would decrement the in-flight count twice and let
    # the pass run more than COVER_CONCURRENCY requests wide.
    my $fired = 0;
    my $done = sub {
        return if $fired++;
        delete $coverQueued{$path};
        $coverRunning--;
        $coverFetched++;
        _coverTick();
    };

    my $ok = eval {
        require Slim::Networking::SimpleAsyncHTTP;
        my $port = preferences('server')->get('httpport') || 9000;

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                # Only the fact that the proxy answered matters — by the time this
                # returns the resized image is in its cache, and we throw our copy
                # away.
                eval { $cache->set($key, 1, COVER_WARM_TTL); 1 };
                $done->();
            },
            sub {
                my (undef, $error) = @_;
                # A server behind HTTP auth refuses our own request, and retrying
                # the rest of the queue would just log the same failure a few
                # hundred times. Drop the whole pass; the next warm retries.
                if (($error // '') =~ /\b40[13]\b/) {
                    $log->info("warm: covers — the server refused a local request ($error);"
                             . " skipping the cover warm");
                    @coverQueue  = ();
                    %coverQueued = ();
                }
                $done->();
            },
            { timeout => 30 },
        )->get("http://127.0.0.1:$port$path");
        1;
    };

    $done->() unless $ok;
}

sub warmCache {
    my ($client, %opts) = @_;
    my $force = $opts{force} ? 1 : 0;   # force => 1: re-resolve even already-cached playlists (manual refresh)

    # ORDER WITHIN THE WARM: FIRST, a reversal of the original with a reason.
    #
    # It used to run LAST, chained behind the created-for playlists (every track in
    # them resolved against the streaming services), the follow feed, and the whole
    # People-You-Follow trending build (follower fan-out, per-user stats, a streaming
    # gate over 50 albums). The comment justifying that called genres "the least
    # urgent". That was true when a genre was a nice-to-have on a row; it is exactly
    # backwards now. **Genres are the one thing that must be ready before a view
    # opens** — everything queued ahead of them only matters once the user presses
    # play — and the ladder's own tail is slow by design (Last.fm is paced at one
    # request per second). Measured on the live server: the ladder did not start
    # until many minutes into the tick, so every view opened bare in the meantime,
    # which is what "it still renders when it has none" actually was.
    #
    # Started here rather than chained, so it runs ALONGSIDE the streaming work
    # instead of after it. That does not undo the original concern — which was that
    # the playlist/follow/trending stages must not hit the STREAMING APIs all at once
    # — because the genre ladder touches none of them: ListenBrainz bulk metadata,
    # the community API, then Last.fm. Their order relative to each other is
    # unchanged. Every stage of the ladder is on idle ticks and yields, so it cannot
    # hold the event loop while the resolves run.
    #
    # GENRES BEFORE THE USERNAME GATE, because ALL RELEASES NEEDS NO ACCOUNT.
    # This call used to sit below the early return, so an account-less user never
    # reached it — and `_warmGenres`'s own no-username branch, which skips the two
    # For You stages and warms All Releases for everyone, was dead code. The
    # consequence was the genre half of exactly the bug `_warmTick`'s comment
    # describes about feeds: All Releases was fetched and stored by `warmFeeds`
    # (which runs ahead of us for that very reason) but its genres were never
    # pre-warmed, so the view opened bare and could only fill from the
    # `_kickGenreFill` top-up — a page at a time, 120s apart.
    #
    # `_warmGenres` reads the username itself and decides per feed, so the gate
    # below stays where it is: everything under it (playlists, the follow feed,
    # the trending builds) genuinely does need an account.
    _warmGenres();

    unless (($prefs->get('username') // '') ne '') {
        # The genre stages are NOT listed here any more — `_warmGenres` has just
        # recorded them itself, correctly: For You skipped, All Releases running.
        # Re-marking them 'skipped' here would overwrite a live stage with a
        # wrong outcome, which is worse than the missing warm was.
        _stage('end', $_, 'skipped', 'no username')
            for qw(playlists follow_feed trending_tracks trending_month trending_year);
        return;
    }

    # Need a player for the streaming-service API context (Qobuz/Tidal handlers
    # are fetched per-client). Use any connected player; if none, we still warm
    # the list + grid covers, and track resolution happens on first open.
    $client ||= (Slim::Player::Client::clients())[0];


    _stage('start', 'playlists');
    Plugins::ListenBrainzFreshReleases::API->getCreatedForPlaylists(
        # force => 1: bypass the working-cache READ so the warm always re-pulls the
        # listing from ListenBrainz. Without this, a warm tick that ran while the
        # (Monday-aligned) listing cache was still valid would short-circuit on the
        # old listing and never discover/resolve the new week's playlists.
        force  => 1,
        onDone => sub {
            my @queue = @{ shift // [] };
            my $nPl   = scalar @queue;
            _stashPlaylistSummary(\@queue);
            _dbg("warm: $nPl playlist(s)" . ($force ? " (forced re-resolve)" : ""));

            my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());

            my $next;
            $next = sub {
                my $pl = shift @queue or do {
                    _stage('end', 'playlists', 'done', "$nPl playlist(s)");
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
                    else {
                        # The master switch off is the one case where the whole
                        # follower block genuinely costs nothing — worth seeing in
                        # the report, since it is otherwise indistinguishable from
                        # a follower stage that hung and never recorded an end.
                        _stage('end', $_, 'skipped', 'people_follow off')
                            for qw(follow_feed trending_tracks trending_month trending_year);
                    }
                    # NB genres are NOT started here — they were kicked off at the
                    # top of warmCache, before any of this. See the comment there;
                    # do not chain them back onto the end.
                    return;
                };

                Plugins::ListenBrainzFreshReleases::API->getPlaylistTracks(
                    $pl->{mbid}, $pl->{last_modified},
                    sub {
                        my $tracks = shift // [];

                        my $rkey = _plResolvedKey($pl->{mbid}, $pl->{last_modified}, $svcOrder);

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
        # NOTE FOR THE MEASUREMENT: the follower stages are chained off the
        # playlist queue DRAINING, so this branch means they never begin at all.
        # Recorded as such rather than left blank — "the playlist listing failed"
        # and "the follower build hung" produce very different reports, and only
        # one of them is a follower problem.
        onError => sub {
            my $err = shift // '';
            _stage('end', 'playlists', 'failed', $err);
            _stage('end', $_, 'skipped', 'playlist listing failed')
                for qw(follow_feed trending_tracks trending_month trending_year);
            $log->info("warm: playlist list fetch failed: $err");
        },
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
# Derived-section memo (0.9.139)
# ---------------------------------------------------------------------------
# The companion to API's %FEED_MEMO, and the other half of the same fix. That memo
# stopped the re-walks RE-READING the feed; this one stops them RE-DERIVING it.
#
# XMLBrowser re-walks from the ROOT on every drill-in, in-place refresh and paging
# tap, and the root builds both sections — so `_sortReleases(_filterAll(...))` was
# running three or more times per user tap, over the WHOLE raw feed each time.
# Measured against a live feed (2902 raw releases, the 14-day default window) on a
# dev Mac: filter 1.1ms + dedupe/sort 3.7ms = ~4.8ms per walk, and a Pi is an order
# of magnitude slower again. None of that work can differ between two walks of the
# same interaction: the input is the same arrayref and the prefs that shape it
# haven't moved.
#
# Validity is by IDENTITY of the source arrayref(s), not a content hash — the feed
# memo hands back the same ref for its whole TTL, and a Refresh (clearFeedCache →
# _memoDrop) forces a re-fetch that necessarily produces a NEW ref, so a refresh can
# never be masked. The memo holds those refs itself, which is what makes `==`
# sound: an address can't be recycled by a different array while we're still
# pointing at it. Everything else that shapes the result is prefs, so those go in a
# signature — a settings change lands on the very next walk.
#
# For You needs TWO sources: _mergeMuSpy builds a fresh arrayref every call, so the
# identity has to come from the LB feed and the MuSpy list separately (which is why
# getMuSpyReleases is memoed too).
use constant SECTION_MEMO_TTL => 5;
my %SECTION_MEMO;    # prefix => [ expiry, sig, [ source refs ], result ]

# Every pref that can change what a section's derived list contains: the type
# checkboxes, the Various-Artists and artwork gates, the blocklist, and the MuSpy
# merge window (For You). The LB feed's own window prefs are already in the feed's
# cache key, so a change there arrives as a different source ref — but the MuSpy
# merge is applied HERE, from the same week prefs, so those have to be in the
# signature too or a widened window leaves the merged list five seconds stale.
sub _sectionSig {
    my ($prefix) = @_;
    my @v = map { $prefs->get("${prefix}_type_$_") ? 1 : 0 } @RELEASE_TYPES;
    push @v, ($prefs->get("${prefix}_artwork_only") // 1) ? 1 : 0;
    push @v, ($prefs->get("${prefix}_various")      // 1) ? 1 : 0;
    push @v, map { $prefs->get($_) // '' } qw(foryou_past muspy_future weeks_past weeks_future);
    my $blocked = $prefs->get('blocked_artists');
    push @v, ref $blocked eq 'ARRAY'
        ? join(',', map { ref $_ eq 'HASH' ? (($_->{mbid} // '') . '/' . ($_->{name} // '')) : '' } @$blocked)
        : '';
    return join('|', @v);
}

sub _sectionList {
    my ($prefix, $sources, $build) = @_;

    # A non-ref source (shouldn't happen — every caller passes an arrayref) can't be
    # identity-checked, so just build it.
    for my $s (@$sources) { return $build->() unless ref $s eq 'ARRAY' }

    my $now = time();
    my $sig = _sectionSig($prefix);
    my $e   = $SECTION_MEMO{$prefix};
    if ($e && $e->[0] >= $now && $e->[1] eq $sig && @{ $e->[2] } == @$sources) {
        my $same = 1;
        for my $i (0 .. $#$sources) {
            next if $e->[2][$i] == $sources->[$i];
            $same = 0;
            last;
        }
        return $e->[3] if $same;
    }

    my $out = $build->();
    $SECTION_MEMO{$prefix} = [ $now + SECTION_MEMO_TTL, $sig, [ @$sources ], $out ];
    return $out;
}

# The two derived lists, as every render path wants them: filtered to the section's
# settings, deduped and date-sorted. Call these rather than composing the steps by
# hand, or the walk pays for the pipeline again.
sub _allSection {
    my ($feed) = @_;
    return _sectionList('all', [$feed], sub { _sortReleases(_filterAll($feed)) });
}

sub _forYouSection {
    my ($lb, $muspy) = @_;
    return _sectionList('foryou', [$lb, $muspy],
        sub { _sortReleases(_filterForYou(_mergeMuSpy($lb, $muspy))) });
}

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
# MUSPY RIDES THE SAME WEEK WINDOW (0.9.185). It used to have its own units — a
# `muspy_future_months` cap, up to 24 MONTHS, against the LB feed's rolling days —
# and that pref is retired. What survives is the GATE: `muspy_future` (default ON)
# decides whether MuSpy contributes a future side at all, independently of
# foryou_future, because MuSpy is a small list of artists the user explicitly
# followed and upcoming releases are the whole point of following them. That is
# exactly what API::sectionWeeks' 'muspy' prefix is — the For You window with
# muspy_future in place of foryou_future. (Consequence, unchanged: with the
# defaults, even when the LB "later weeks" box is off the feed can show past-LB +
# future-MuSpy together. A user who doesn't want that turns muspy_future off.)
#
# NOTHING FAR OUT IS LOST BY THE NARROWER WINDOW. MuSpy is fetched `?limit=100`
# newest-first, stored with rotation OFF and read back from the store UNWINDOWED,
# so an album announced three months out is fetched and HELD today — the week
# window only decides whether it is DISPLAYED. Each Monday the forward edge rolls
# on and it appears. Rows age out on `seen_at` in DB::feedSweep at 120 days, and
# upcoming releases sit at the top of MuSpy's newest-first list, so they keep being
# refreshed while they wait.
sub _mergeMuSpy {
    my ($lb, $muspy) = @_;
    $lb = [] unless ref $lb eq 'ARRAY';
    return $lb unless ref $muspy eq 'ARRAY' && @$muspy;

    my ($lo, $hi) = Plugins::ListenBrainzFreshReleases::API->sectionWindow('muspy');

    my @kept;
    for my $r (@$muspy) {
        my $d = $r->{release_date} // '';
        next unless $d =~ /^\d{4}-\d{2}-\d{2}$/;   # padded on ingest; skip the undatable
        # Dates are zero-padded, so a lexical compare is a chronological one. Both
        # gates are already folded into the window: a side whose box is unticked
        # contributes zero weeks, so its edge collapses onto the current week's
        # Monday or Sunday and nothing beyond it can match.
        push @kept, $r if $d ge $lo && $d le $hi;
    }
    $log->info("MuSpy merge: kept " . scalar(@kept) . " of " . scalar(@$muspy) . " within window [$lo .. $hi]")
        if $log->is_info;
    return [ @$lb, @kept ];
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
#
# $sorts is the BULK map from API::peekArtistSorts, built once per bucket by the
# caller. Passing it is not an optimisation detail — without it this reads the
# store once per release, which on an artist-sorted All Releases view is ~2,900
# synchronous SELECTs on the render path. The single-key fallback is kept only for
# a caller outside a sort.
sub _artistSortKey {
    my ($rel, $sorts) = @_;
    my $s = $rel->{artist_sort_name};
    if (!(defined $s && length $s)) {
        my $mbids = $rel->{artist_mbids};
        my $mbid  = (ref $mbids eq 'ARRAY' && @$mbids) ? $mbids->[0] : undef;
        if ($mbid) {
            $s = ref $sorts eq 'HASH'
                ? $sorts->{ lc $mbid }
                : Plugins::ListenBrainzFreshReleases::API->peekArtistSort($mbid);
        }
    }
    $s = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist')
        unless defined $s && length $s;
    return lc $s;
}

# Every first-artist MBID in a list, deduped — the input to both the bulk
# sort-name read and the background warm.
sub _firstArtistMbids {
    my ($releases) = @_;
    my (%seen, @mbids);
    for my $r (@{ $releases || [] }) {
        my $m = $r->{artist_mbids};
        next unless ref $m eq 'ARRAY' && @$m && $m->[0];
        push @mbids, $m->[0] unless $seen{ lc $m->[0] }++;
    }
    return \@mbids;
}

# Kick off a background MB sort-name warm for a list's artists (the API dedupes,
# skips cached, throttles + bounds the fetch). Called only from the Artist-sort
# paths, so a user who never sorts by artist never triggers an MB lookup.
sub _warmArtistSorts {
    my ($releases) = @_;
    return unless ref $releases eq 'ARRAY' && @$releases;
    my $mbids = _firstArtistMbids($releases);
    Plugins::ListenBrainzFreshReleases::API->warmArtistSorts($mbids) if @$mbids;
}

sub _sortWithin {
    my ($releases, $mode) = @_;
    return $releases unless ref $releases eq 'ARRAY';
    $mode ||= 'release_date';

    if ($mode eq 'artist') {
        # TWO separate reasons this is shaped the way it is, and losing either one
        # puts synchronous work back on the render path:
        #  1. ONE bulk store read for the whole bucket's sort-names, not one per
        #     release (~2,900 SELECTs on a full artist-sorted All Releases view).
        #  2. A Schwartzian transform, because Perl's sort calls the comparator
        #     O(N log N) times and the key must be computed exactly once each.
        # Primary A-Z, secondary date newest-first (element [1] compared b-vs-a).
        my $sorts = Plugins::ListenBrainzFreshReleases::API
                        ->peekArtistSorts(_firstArtistMbids($releases));
        return [ map  { $_->[2] }
                 sort { $a->[0] cmp $b->[0] || $b->[1] cmp $a->[1] }
                 map  { [ _artistSortKey($_, $sorts), $_->{release_date} // '', $_ ] } @$releases ];
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
# Per-view release-family filter (the "Showing …" toggle). Two states:
#   'singles_eps' — keep releases whose PRIMARY type is Single or EP
#   'albums'      — keep everything else (Album, Broadcast, Other, and the
#                   secondary-typed album variants Compilation/Soundtrack/Live/…,
#                   all of which have primary type Album)
# Partitioned by PRIMARY type so the two states are mutually exclusive and cover
# every release — nothing a user has ticked in Settings is lost. Applied AFTER
# _filterSection (the settings type/artwork/VA filter), so it only ever narrows
# WITHIN the ticked types. An unknown/blank primary type falls into 'albums'
# (the default, non-single bucket).
# ---------------------------------------------------------------------------
my %_SINGLE_FAMILY = ( single => 1, ep => 1 );
sub _viewFilter {
    my ($releases, $mode) = @_;
    $releases //= [];
    my $wantSingles = ($mode // 'albums') eq 'singles_eps';
    return [ grep {
        my $p = lc($_->{release_group_primary_type} // '');
        $wantSingles ? $_SINGLE_FAMILY{$p} : !$_SINGLE_FAMILY{$p}
    } @$releases ];
}

# Which release families a section actually offers, from its type checkboxes.
# Returns ($hasAlbums, $hasSingles). An empty allowed-set means the settings
# filter is "show everything" (the _typeMatches safety net), so BOTH families
# are available. Otherwise a family is available iff at least one of its types
# is ticked. Every @RELEASE_TYPES value is in exactly one family (single/ep vs
# the rest), so at least one family is always available when anything is ticked.
sub _familyAvail {
    my ($prefix) = @_;
    my $allowed = _allowedTypes($prefix);
    return (1, 1) unless %$allowed;   # nothing ticked → all types shown
    my $hasSingles = ($allowed->{single} || $allowed->{ep}) ? 1 : 0;
    my $hasAlbums  = 0;
    for my $t (@RELEASE_TYPES) {
        next if $_SINGLE_FAMILY{$t};
        if ($allowed->{$t}) { $hasAlbums = 1; last }
    }
    return ($hasAlbums, $hasSingles);
}

# The view mode to actually apply for a section, plus the family-availability
# flags. Clamps the stored pref to a family the section can show — so a section
# with only Single/EP ticked doesn't render EMPTY under the default 'albums'
# view (and vice versa). Returns ($view, $hasAlbums, $hasSingles).
sub _effectiveView {
    my ($prefix, $pref) = @_;
    my ($hasAlbums, $hasSingles) = _familyAvail($prefix);
    my $stored = $prefs->get($pref) || 'albums';
    my $view   = $stored;
    $view = 'albums'      if $view eq 'singles_eps' && !$hasSingles;
    $view = 'singles_eps' if $view eq 'albums'      && !$hasAlbums;
    # PERSIST the clamp, don't just apply it. The selector is HIDDEN while only one
    # family is available (_viewToggle returns ()), so a stored value the section can't
    # show is unreachable from the UI — it sits there invisibly and then takes effect
    # the moment the user ticks the other family in Settings, silently opening that
    # feed on Singles & EPs. Writing the clamped value back keeps what's stored equal
    # to what's displayed. Guarded on an actual change, so it's a no-op normally.
    $prefs->set($pref, $view) if $view ne $stored;
    return ($view, $hasAlbums, $hasSingles);
}

# The release-family selector for the Options section: ONE cycling row —
# "Showing Albums (tap for Singles & EPs)" and vice versa — exactly like the
# neighbouring "Sorted by …" toggle. 0.9.125–0.9.127 used TWO radio-marked rows so
# you could see the option you were NOT on; 0.9.128 collapsed them back to one row
# because two rows cost a line of screen for a two-state choice, and the option
# rows sit above the releases you actually came to look at.
#
# **Why not two buttons side by side** (asked twice — don't re-derive): Material
# gives a plugin feed NO way to lay rows out horizontally. Re-verified against the
# server's own material-deferred.min.js: the header toolbar's `currentActions` is
# filled by `browseActions(...)` from native-library `stdItem` shapes or
# `getCustomActions(...)` keyed on a media item's `favorites_url`, and rows flagged
# `isListItemInMenu` are pushed to `d.actionItems` (the ⋮ overflow) — both set only
# on native-menu paths. A plain OPML `type=>'link'` row always lands in `d.items`
# as a full-width v-list-tile. Grid view is the only horizontal layout and applies
# to the WHOLE list, releases included. So one row is the floor.
#
# The icon REFLECTS THE CURRENT STATE (album disc vs music note), which is what
# carries the at-a-glance "which lens am I in" that the radio marks used to give;
# the label's "(tap for …)" carries the action. $pref is the DURABLE pref the
# choice lives in — 'foryou_view' or 'all_view' (All Releases, shared across every
# week). Returns a LIST so the call sites can spread it — EMPTY when only ONE
# family is available for the section (nothing to switch to, so the row is hidden
# rather than showing a dead toggle or one that opens an empty list).
# $hasAlbums/$hasSingles come from _effectiveView (i.e. _familyAvail).
sub _viewToggle {
    my ($client, $pref, $mode, $hasAlbums, $hasSingles) = @_;
    return () unless $hasAlbums && $hasSingles;
    my $singles = (($mode // 'albums') eq 'singles_eps') ? 1 : 0;
    my $now  = cstring($client, $singles ? 'PLUGIN_LBF_VIEW_SINGLES' : 'PLUGIN_LBF_VIEW_ALBUMS');
    my $next = cstring($client, $singles ? 'PLUGIN_LBF_VIEW_ALBUMS'  : 'PLUGIN_LBF_VIEW_SINGLES');
    return ({
        name        => sprintf(cstring($client, 'PLUGIN_LBF_SHOWING'), $now, $next),
        type        => 'link',
        image       => $singles ? VIEW_SINGLES : VIEW_ALBUMS,
        nextWindow  => 'refresh',
        passthrough => [{ pref => $pref }],
        url         => sub {
            my ($c, $cb, $a, $p) = @_;
            # Flip from the LIVE pref, not the mode captured at render time — the
            # same rule as _sortToggle: a value changed in between (another player,
            # or the _effectiveView clamp) must not make this tap land back on the
            # state we're already showing and read as a dead row.
            my $cur = $prefs->get($p->{pref}) || 'albums';
            $prefs->set($p->{pref}, $cur eq 'singles_eps' ? 'albums' : 'singles_eps');
            $cb->({ items => [] });
        },
    });
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
    my ($releases, $client, $headers, $mode, $meta) = @_;   # $meta: genre map (see _withGenres)

    unless ($releases && scalar @$releases) {
        return [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }];
    }

    # For You is ALWAYS the weekly view now — W/C material headers, newest week
    # first — as a single level Material windows natively (its in-list filter spans
    # every item). The Options sort ($mode) reorders releases inside each week; the
    # week grouping is unconditional (the old week_dividers/group_by_artist toggles
    # were retired in 0.9.97).
    return _buildWeekly($releases, $client, $headers, $mode, $meta);
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

# Escape for the HTML that _proseBlock emits. REQUIRED, not defensive: API::_cleanBio
# DECODES entities (&amp; -> &, &lt; -> <), so a bio quoting a band name with an
# ampersand or an angle bracket arrives as raw markup characters and would other-
# wise break the row. This is the only place in the plugin that builds HTML.
sub _escHtml {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# Prose rows for the artist bio: one row per paragraph, Discography's markup.
#
# Material's list layout still sets the constraints, verified against the live 6.4.5
# bundle, and they are why the PARSING has to be right:
#
#   1. Every prose row's title carries `min-height: var(--list-elem-height)` (48px in
#      6.4.5), so each row occupies a full row height however short its text. A dozen
#      paragraphs is fine; ninety-two one-line fragments is the 0.9.152 field report
#      ("empty space on iPad landscape").
#   2. `browse-page.js: useRecyclerForLists` switches a level to a virtual scroller
#      above LMS_MAX_NON_SCROLLER_ITEMS (100) items, with a FIXED `item-size` of
#      LMS_LIST_ELEMENT_SIZE (48) and every row `position:absolute`. There text rows
#      get `browse-text-inrecycler`, which — unlike `browse-text` — has NO
#      `height:unset`, so a row taller than 48px is DRAWN OVER the one below it
#      ("renders over itself on iOS").
#
# Both are governed by ROW COUNT, and row count is governed by _bioBlocks. A correctly
# parsed bio is ~10-20 rows and never approaches the threshold on its own.
#
# ONE ROW PER PARAGRAPH, AND THE MARKUP IS DISCOGRAPHY'S — copied deliberately,
# because that plugin's bio renders correctly on desktop AND iOS and ours did not.
# Compare the two over the same MAI bio before changing anything here; the difference
# was not subtle and cost several builds to see.
#
#   Discography (Browse.pm `_proseRow`, ~257): one `type=>'text'` row per paragraph,
#     each `<div style='margin-left:72px'>escaped text</div>`. 72px is Material's list
#     AVATAR column, so prose lines up with the icon rows above and below it instead
#     of sitting flush to the viewport edge. Bold comes from a plain `<b>`, the idiom
#     its meta-title row (~3396) has always used.
#
# 0.9.152 collapsed the whole bio into ONE row to stop the iPad overlap. That was
# treating the symptom: the overlap came from **92 rows**, and those came from the
# broken paragraph detection (a hard-wrapped MAI bio split at every wrapped LINE), not
# from having one row per paragraph. With _bioBlocks parsing correctly the same bio is
# ~10 rows — the same count Discography emits, nowhere near the 100-item scroller
# threshold. So the row-per-paragraph layout is not the hazard; bad parsing was.
#
# Do NOT reintroduce a single-row wrapper with its own typography (max-width,
# line-height, font-weight). It was tried in 0.9.154 and, whatever it computes in
# isolation, it did not render as intended on every client — whereas this shape
# demonstrably does.
#
# A bare string is accepted in place of a { text, heading, bullet } entry so the sub
# stays usable for prose that has no structure to preserve.
use constant PROSE_INDENT     => '72px';    # Material's list avatar column
use constant PROSE_BULLET_IND => '1.2em';   # hanging indent for a wrapped bullet
sub _proseBlock {
    my (@paras) = @_;
    return () unless @paras;

    my @rows;
    for my $p (map { ref $_ ? $_ : { text => $_, heading => 0, bullet => 0 } } @paras) {
        my $text  = _escHtml($p->{text});
        my $style = 'margin-left:' . PROSE_INDENT;

        if ($p->{heading}) {
            # EXPLICIT WEIGHT, NEVER A BARE <b>. Measured in headless Chrome inside
            # Material's own row: the title element carries `font-weight:200
            # !important`, and CSS `bolder` (all a <b> gets from the UA stylesheet)
            # resolves RELATIVE to the inherited weight — from 200 it lands on 400,
            # not 700. On iOS, where the font has a real 200 thin face, 400 against
            # 200 reads as bold; in a desktop browser whose font stack has no 200
            # face the body ALREADY renders at 400, so the heading is identical to
            # it and the bold vanishes. That is the 0.9.155 field report exactly.
            # `font-weight:bold` is what Discography uses and it computes to 700
            # regardless of what is inherited.
            $style .= ';font-weight:bold';
        }
        elsif ($p->{bullet}) {
            $style .= ';padding-left:' . PROSE_BULLET_IND
                    . ';text-indent:-'  . PROSE_BULLET_IND;
            $text   = "\x{2022}\x{00A0}$text";
        }
        push @rows, { name => "<div style='$style'>$text</div>", type => 'text' };
    }
    return @rows;
}

# Is this text HARD-WRAPPED at a fixed column, rather than carrying deliberate
# line breaks? The two sources disagree completely and _bioParagraphs cannot treat
# a newline the same way in both:
#     Last.fm  — prose, never column-wrapped, so a lone "\n" IS a break (0.9.151).
#     MAI      — a plain-text render (Wikipedia-derived): hard-wrapped at ~72
#                columns, with setext headings ("Early life" / "----------").
# MEASURED on the live server, Tyondai Braxton via MAI (5799 chars): 92 lines,
# max 78 chars, 74 of them 60-78. Under 0.9.151's rule that became 92 one-line
# "paragraphs" — the field bug.
#
# TWO signals, BOTH required, because either alone has a real false positive:
#   * no line exceeds BIO_WRAP_MAX_COL. A wrap column is by definition a ceiling;
#     genuine paragraphs run well past it. On its own this admits any bio made of
#     short deliberate lines (a discography list).
#   * more than half the non-final lines END MID-SENTENCE. A wrap cuts wherever
#     the column falls; a deliberate break lands on a full stop. On its own this
#     admits a long unpunctuated run.
# Plus a floor of BIO_WRAP_MIN_LINES, since two or three short lines prove nothing.
#
# A false positive costs one joined paragraph — never a broken render — which is
# why the gates are stated as a preference for leaving 0.9.151's behaviour alone.
use constant BIO_WRAP_MAX_COL   => 100;
use constant BIO_WRAP_MIN_LINES => 4;
sub _bioHardWrapped {
    my ($lines) = @_;
    my @l = grep { length } @$lines;
    return 0 if @l < BIO_WRAP_MIN_LINES;

    my $mid = 0;
    for my $i (0 .. $#l) {
        return 0 if length($l[$i]) > BIO_WRAP_MAX_COL;
        # $#l is the count of NON-FINAL lines; the last one ends where the text does
        # and says nothing either way.
        $mid++ if $i < $#l && $l[$i] !~ /[.!?:;\x{2026}]$/;
    }
    return $mid * 2 > $#l ? 1 : 0;
}

# A SECTION HEADING THAT CARRIES NO UNDERLINE. MEASURED in the same MAI bio: the
# top-level titles are setext-underlined ("Early life" / "----------") but the
# sub-headings are not — "Early solo work and Battles (2000-2009)" is a bare line
# with a blank line either side. So the underline cannot be the only signal.
#
# The test is: the paragraph is ONE source line, it stops well short of the wrap
# column, and it does not end on sentence punctuation. In a hard-wrapped document a
# body paragraph is by construction several lines long AND ends on a full stop, so
# it is the PAIR that does the work; the column cap is belt and braces. Note ':' is
# deliberately not disqualifying — "Discography:" is a heading.
#
# ONLY SOUND ON A HARD-WRAPPED SOURCE, which is why _bioBlocks gates it on that. Where
# a lone newline is a real break, "a block of one short line" describes a perfectly
# ordinary sentence, and this would promote prose to headings wholesale. Bullets are
# excluded by the caller, which knows the marker it stripped.
use constant BIO_HEADING_MAX_COL => 80;

# How many CONSECUTIVE bare-line headings mean "this is a list, not a stack of
# section titles". Real sections have a body between them; a discography or a
# roster matches _bioLooksLikeHeading on every single entry. See _bioParagraphs.
use constant BIO_HEADING_RUN_MAX => 3;
sub _bioLooksLikeHeading {
    my ($lines) = @_;
    return 0 unless @$lines == 1;
    return 0 if length($lines->[0]) > BIO_HEADING_MAX_COL;
    return $lines->[0] =~ /[.!?;,]$/ ? 0 : 1;
}

# A LIST ITEM. MAI's plain-text render indents them and marks them with "*"; other
# sources use a dash or a real bullet. The marker must be followed by whitespace, so a
# hyphenated word cannot open a list.
#
# Returns ($marker, $text) so the caller can tell an UNAMBIGUOUS marker from a dash.
# The trailing-whitespace rule is not enough on its own: a hard wrap can push a
# DASHED PARENTHETICAL to the start of a line — "... their second album\n- recorded
# in 1997 -\nwas released ..." — and reading that as a list item closes the preceding
# partial paragraph as its own block, which is then one short line with no terminal
# punctuation, exactly what _bioLooksLikeHeading promotes to BOLD. _bioBlocks
# therefore requires a dash to be corroborated by a neighbour.
sub _bioBullet {
    my ($line) = @_;
    return unless $line =~ /^([*\x{2022}\x{00B7}\-\x{2013}])\s+(\S.*)$/;
    return ($1, $2);
}

# THE ONE STRUCTURE PARSER, for BOTH bio shapes. Returns { text, heading, bullet }
# per block.
#
# $wrapped (from _bioHardWrapped) changes exactly two things, and NOTHING else may be
# made conditional on it:
#   * how a lone newline is read — a wrap artefact to rejoin, or a real break;
#   * whether a bare short line may be promoted to a heading (see
#     _bioLooksLikeHeading for why that test is unsound otherwise).
#
# 0.9.152 got this wrong by running the whole parser only when $wrapped was true, so a
# MAI bio that failed the wrap test lost every heading AND rendered its setext
# underlines as rows of literal dashes. A SETEXT UNDERLINE IS UNAMBIGUOUS IN ANY
# SOURCE — it must always be consumed, and it must always mark what it underlines.
# That is why $underlined can reach BACKWARDS to the last block already pushed: when a
# lone newline is a break, the heading was closed before its underline was read.
sub _bioBlocks {
    my ($bio, $wrapped) = @_;

    my @lines = split /\n/, ($bio // ''), -1;
    s/^\s+|\s+$//g for @lines;

    # CORROBORATION PRE-PASS for list markers. "*", a real bullet and a middot are
    # used for nothing else, so they open a list on their own. A hyphen and an en
    # dash are ordinary punctuation, and only open a list when a NEIGHBOURING
    # non-blank line is also marker-marked — i.e. they are part of a run. A lone
    # dashed line is a parenthetical that a hard wrap pushed to column 0.
    #
    # `my ($mk) = ...`, NOT `(_bioBullet($_))[0]`: a list slice of an EMPTY list
    # yields an empty list in list context, so the map would contribute nothing for
    # an unmarked line and every index after it would silently shift.
    my @marker = map { my ($mk) = _bioBullet($_); $mk } @lines;
    my @isBullet;
    for my $i (0 .. $#lines) {
        next unless defined $marker[$i];
        if ($marker[$i] =~ /^[*\x{2022}\x{00B7}]$/) { $isBullet[$i] = 1; next }
        for my $j (grep { $_ >= 0 && $_ <= $#lines } ($i - 1, $i + 1)) {
            next unless length $lines[$j];
            $isBullet[$i] = 1 if defined $marker[$j];
        }
    }

    my (@out, @cur, $bullet);
    my $flush = sub {
        my ($underlined) = @_;
        if (!@cur) {
            # An underline with nothing pending marks the block it followed.
            if ($underlined && @out && !$out[-1]{bullet}) {
                $out[-1]{heading} = 1;
                $out[-1]{setext}  = 1;
            }
            return;
        }
        my $text = join(' ', @cur);
        $text =~ s/\s+/ /g;
        $text =~ s/^\s+|\s+$//g;
        # `setext` records WHY a block is a heading. An underline is the source's
        # own mark; the bare-line test is only an inference off a document we
        # merely believe is hard-wrapped. _bioParagraphs must tell them apart
        # before it acts on an all-heading document or throws content away.
        push @out, {
            text    => $text,
            bullet  => $bullet ? 1 : 0,
            setext  => (!$bullet && $underlined) ? 1 : 0,
            heading => (!$bullet
                        && ($underlined || ($wrapped && _bioLooksLikeHeading(\@cur))))
                       ? 1 : 0,
        } if length $text;
        @cur    = ();
        $bullet = 0;
    };
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        if ($line =~ /^[-=_~*]{3,}$/) { $flush->(1); next }
        if (!length $line)            { $flush->(0); next }

        if ($isBullet[$i]) {
            $flush->(0);          # a marker always opens a new block
            $bullet = 1;
            (undef, $line) = _bioBullet($line);
        }
        push @cur, $line;
        # Unwrapped: the newline that ends this line is the author's, so close here.
        # Wrapped: it is the renderer's, so the next line joins on.
        $flush->(0) unless $wrapped;
    }
    $flush->(0);
    return @out;
}

# Split a bio into display paragraphs.
#
# MEASURED against the live bios that actually reach us. NONE of them carry <p>
# tags, so API::_cleanBio's </p><p> -> "\n\n" rule almost never fires and the
# breaks are whatever the prose happens to carry:
#     Sigur Ros  15 blank-line breaks + 3 single newlines   (Last.fm)
#     Radiohead   4 blank-line breaks + 9 single newlines   (Last.fm)
#     Mildlife    NO newlines whatsoever — 685 characters in one unbroken run
#     T. Braxton  92 hard-wrapped lines at <=78 columns     (MAI)
# Hence three rules, in order:
#   0. Structure — headings and bullets — is parsed from EVERY bio by _bioBlocks,
#      which also decides whether a lone "\n" is a wrap artefact to rejoin (MAI) or a
#      real paragraph break (Last.fm: splitting on blank lines alone threw away 9 of
#      Radiohead's 13 breaks).
#   1. Do NOT gate the parse on the wrap test. It was gated in 0.9.152's first cut,
#      which cost every heading in any bio the test happened to reject.
#   2. If that yields ONE long chunk the source genuinely has no paragraph structure
#      and no split can recover it, so group sentences instead. This is a PRESENTATION
#      decision — the text is unchanged, only where it is broken.
use constant BIO_SENTENCES_PER_PARA => 3;
sub _bioParagraphs {
    my ($bio) = @_;
    $bio //= '';

    my @lines = map { my $t = $_; $t =~ s/^\s+|\s+$//g; $t } split /\n/, $bio, -1;
    my @paras = _bioBlocks($bio, _bioHardWrapped(\@lines));

    # A RUN OF CONSECUTIVE BARE-LINE HEADINGS IS A LIST, NOT A STACK OF SECTION
    # TITLES — real sections have a body between them. A discography or a roster
    # ("Discography / Varmints (2016) / FIBS (2019)") matches _bioLooksLikeHeading on
    # every entry, so without this the whole list rendered bold and, being trailing,
    # was then thrown away entirely by the pop below. A setext underline is the
    # source's own mark and is never second-guessed; only inferences are demoted.
    my $i = 0;
    while ($i < @paras) {
        if ($paras[$i]{heading} && !$paras[$i]{setext}) {
            my $j = $i;
            $j++ while $j < @paras && $paras[$j]{heading} && !$paras[$j]{setext};
            $paras[$_]{heading} = 0 for ($j - $i >= BIO_HEADING_RUN_MAX) ? ($i .. $j - 1) : ();
            $i = $j;
        }
        else { $i++ }
    }

    # A DOCUMENT THAT IS NOTHING BUT HEADINGS HAS NOT BEEN PARSED, IT HAS BEEN
    # MISREAD. Demote rather than render every line bold — this can only be the
    # bare-line inference (a Last.fm bio of short deliberate lines that happened to
    # clear _bioHardWrapped's gates), never a source-marked heading.
    #
    # NB each grep is bound to its own scalar: `grep BLOCK LIST` slurps everything
    # after it, so `!grep {...} @paras && !grep {...} @paras` would make the SECOND
    # grep part of the FIRST one's list. That is the bare-grep trap this repo has
    # now been bitten by three times — keep them separate.
    my $bodyCount   = scalar grep { !$_->{heading} } @paras;
    my $setextCount = scalar grep {  $_->{setext}  } @paras;
    if (@paras && !$bodyCount && !$setextCount) {
        $_->{heading} = 0 for @paras;
        $bodyCount = scalar @paras;
    }

    # A heading with nothing under it is not a section. MAI ends its HTML bio with a
    # "More online sources" heading over a list of links, and _cleanBio drops the
    # links — so without this the bio ends on a bold title introducing nothing.
    #
    # TWO FLOORS, BOTH LOAD-BEARING. Unbounded, this discards the WHOLE biography
    # when every block is a heading: _proseBlock returns () and the expanded branch
    # emits only "Show less", so the user taps Read more and gets an empty section.
    # And only a SETEXT-marked heading may be discarded at all — deleting real
    # content on the strength of a bare-line inference is what lost the discography.
    pop @paras while $bodyCount && @paras && $paras[-1]{heading} && $paras[-1]{setext};

    # Rule 2 regroups prose, so it must not touch a lone heading or bullet.
    return @paras if @paras != 1
                  || $paras[0]{heading}
                  || $paras[0]{bullet}
                  || length $paras[0]{text} <= BIO_PREVIEW;

    # Rule 2. Break after . ! ? when the next sentence opens like one (capital or an
    # opening quote), which leaves abbreviations mid-sentence alone. A stray split
    # (e.g. "St. John") is harmless: sentences are regrouped in fixed-size blocks, so
    # it shifts a boundary rather than producing a wrong-looking paragraph.
    my @sent = split /(?<=[.!?])\s+(?=["'\x{201C}\x{2018}(]?[A-Z\x{00C0}-\x{00DE}])/, $paras[0]{text};
    return @paras if @sent < 2;

    my @out;
    while (@sent) {
        my @chunk = splice(@sent, 0, BIO_SENTENCES_PER_PARA);
        push @out, { text => join(' ', @chunk), heading => 0, bullet => 0, setext => 0 };
    }
    return @out;
}

# Sibling of _pageRow for a BOOLEAN in-place reveal (the artist bio on the release
# detail page). Same mechanism and the same %pageState store, so there is exactly one
# place per player where transient view state lives. Expanding writes the flag;
# collapsing DELETES it, so a bio that was never expanded leaves no residue — the
# same convention as _pageRow collapsing back to PAGE_SIZE.
sub _bioToggleRow {
    my ($client, $key, $on, $name, $image) = @_;
    return {
        name        => $name,
        type        => 'link',
        image       => $image,
        nextWindow  => 'refresh',
        passthrough => [{ key => $key, on => $on }],
        url         => sub {
            my ($c, $cb, $a, $p) = @_;
            my $ctx = $pageState{ _cid($c) } ||= {};
            if ($p->{on}) { $ctx->{ $p->{key} } = 1 }
            else          { delete $ctx->{ $p->{key} } }
            $cb->({ items => [] });
        },
    };
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
                # family selector + sort toggle + Refresh sit on top.
                my $mode  = $prefs->get('all_sort') || 'release_date';
                # Effective release-family view + which families All Releases offers
                # (clamped so a single-family section never renders empty; the
                # selector rows show only when BOTH families are available).
                # Re-read each walk so the selector refreshes in place, like sort.
                my ($view, $vHasAlb, $vHasSing) = _effectiveView('all', 'all_view');
                my $rows  = _viewFilter($rels, $view);
                _warmArtistSorts($rows) if $mode eq 'artist';
                # Refresh belongs HERE, not only in fetchAll. Since the top-level menu
                # started inlining these week rows directly (0.9.99–0.9.119), fetchAll —
                # the only other place with a Refresh row — is reached only via the
                # watchdog/error fallback tile, so in normal use the All Releases feed
                # had NO reachable Refresh at all. The week drill is the level a user is
                # actually looking at when the feed looks wrong, so it carries it.
                my @opt = ( _viewToggle($c, 'all_view', $view, $vHasAlb, $vHasSing),
                            _genresRow($c, 'all', $rows),
                            _sortToggle($c, 'all_sort', $mode),
                            _refreshItem($c, 'all') );

                # Page on the RELEASES, not the finished tiles, so the genre fill
                # covers only the rows about to be shown — one bulk request per
                # 30-row page instead of one for the whole week. _pageSection only
                # slices and counts, so it behaves identically given releases.
                my $render = sub {
                    my ($set) = @_;
                    my ($visRel, $pgRows) = _pageSection($c, $key, _sortWithin($set, $mode));
                    # Cache ONLY (peek): a week draws immediately with the genres
                    # already known and tops the rest up in the background, instead of
                    # holding the page open on a metadata request.
                    _withGenres($visRel, sub {
                        my $meta  = shift;
                        my @tiles = map { _buildReleaseItem($_, $c, $meta) } @$visRel;

                        # The week ROWS are built from the section list before _viewFilter (the
                        # landing can't know the lens — it's re-read per walk in here), so a week
                        # holding nothing in the active family — all albums while Showing Singles
                        # & EPs — otherwise opens with its Options rows and no word of why. Say it,
                        # the same way an empty landing does. A genre filter that matches nothing
                        # in this week lands here too, which is exactly the same "you filtered it
                        # all away" case and wants the same answer.
                        @tiles = ({ name => cstring($c, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' })
                            unless @tiles;
                        $cb->({ items => [ _sectionHeader($c, 'PLUGIN_LBF_SECTION_OPTIONS', $headers, \@opt),
                                           @opt, @tiles, @$pgRows ] });
                    }, undef, peek => 1);
                };

                # A genre filter has to be applied BEFORE paging, or a page of 30
                # would be mostly filtered away and "Show more" counts would lie. That
                # needs genres for the WHOLE week, not just the visible slice — so the
                # wider fill happens only when a filter is actually set. Unfiltered
                # (the default) keeps the cheap one-page-one-request behaviour.
                if (@{ _selectedGenres('all') }) {
                    _withGenres($rows, sub {
                        my $meta = shift;
                        $render->(_genreSelectFilter($rows, 'all', $meta));
                    }, GENRE_WARM_MAX, peek => 1);
                }
                else {
                    $render->($rows);
                }
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
    my ($releases, $client, $headers, $mode, $meta) = @_;

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
                $cb->({ items => [ map { _buildReleaseItem($_, $c, $meta) } @$rels ] });
            };
            $hdr->{passthrough} = [{}];
        }

        push @items, $hdr;
        push @items, map { _buildReleaseItem($_, $client, $meta) } @$rels;
    }

    return \@items;
}

# Monday (YYYY-MM-DD) of the week containing $date, or '' if unparseable. Works
# on a local calendar date (use noon so a whole-day subtraction can't cross a date
# boundary even across a DST change). The result is the same regardless of zone for
# a date-only input — the weekday of a calendar date is timezone-independent — but
# computing it in local time keeps the whole date path consistent with "today".
#
# MEMOED (0.9.139) — a pure function of a date STRING, and the week grouping calls
# it once per release while a feed only ever holds a couple of dozen distinct dates.
# Measured on a live feed: 726 calls resolving to 15 distinct dates, 2.7ms a walk
# (timelocal + two localtimes + an eval each), in both _buildAllLanding and
# _buildWeekly — so it ran on every root walk AND every week render. Cached it is
# ~0.05ms. The map is keyed by the input string and never expires: the answer for a
# given date cannot change, and the key space is bounded by the dates a feed carries.
my %_WEEK_START;

sub _weekStart {
    my ($date) = @_;
    return '' unless $date && $date =~ /^(\d{4})-(\d{2})-(\d{2})/;
    return $_WEEK_START{$date} if exists $_WEEK_START{$date};

    my $epoch = eval { Time::Local::timelocal(0, 0, 12, $3, $2 - 1, $1) };
    return '' unless defined $epoch;

    my $wday = (localtime $epoch)[6];       # 0 = Sunday
    my $mon  = $epoch - (($wday + 6) % 7) * 86400;
    my @m    = localtime $mon;
    return $_WEEK_START{$date} = sprintf('%04d-%02d-%02d', $m[5] + 1900, $m[4] + 1, $m[3]);
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
    # The SAME window the fetch will ask for, from API::sectionWindow — not a
    # second computation from the same prefs. The tile subtitle is the one place
    # a drifting copy would be invisible: it would simply state a span the feed
    # never had.
    my ($from, $to) = Plugins::ListenBrainzFreshReleases::API->sectionWindow(
        $which eq 'user' ? 'foryou' : 'all');
    return _dateSpan($from, $to);
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
    my ($rel, $client, $meta) = @_;

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
    # Genres, strongest first. Real MusicBrainz genres (album's own, else the
    # artist's — see _genresFor) are preferred; the payload's inline release_tags
    # are the fallback for rows the bulk lookup had nothing for. $meta is absent on
    # paths that don't pre-fill genres (the home shelves), which just means those
    # rows behave exactly as they did before.
    # ONE top-level family on a list row (_familyFor), never the raw genre list —
    # scanning a week of releases wants "Electronic"; the detail page is where the
    # sub-genres belong. _familyFor owns EVERY source, including the payload's
    # inline release_tags, so there is exactly one path to a row label and nothing
    # can reach the row unrolled (the 0.9.132 bug).
    # "Funk (funk rock, funk soul)" — the top-level family for scanning and sorting,
    # with the release's own sub-genres in brackets so the row still says something
    # specific. Brackets are omitted when the family is all we know.
    my ($family, @subs) = _familyFor($rel, $meta);
    if (defined $family && length $family) {
        my $label = $family;
        $label .= ' (' . join(', ', @subs) . ')' if @subs;
        $line2 .= " \x{00B7} " . $label;
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
    my $mbGenres;      # arrayref: the genre ladder's answer for this release
    my $bio;           # artist biography text (MAI plugin only)
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
    # A release group MBID is no longer the only way to answer this: the hosted tier
    # in the genre block below is NAME-keyed, so a release that reaches this page
    # without one (an unmapped listen aggregated into Trending Albums) can still get
    # genres. Without either the mbid or a name pair there is nothing to ask with.
    my $wantGenres = ($rgMbid || (length $artist && length $album)) ? 1 : 0;
    my $wantTracks = $mbid   ? 1 : 0;
    # MAI-ONLY, and the gate says so. Without MAI there is no bio and no photo, so
    # there is nothing for this task to fetch and it is not counted at all — see
    # _fetchArtistInfo.
    my $wantArtist = (length $artist && _maiEnabled()) ? 1 : 0;

    # Count all tasks up front: a cache hit completes its callback synchronously,
    # so per-task incrementing could let the barrier fire after the first one
    # finishes (before the others launched) and drop their data.
    my $pending = $wantStream + $wantGenres + $wantTracks + $wantArtist;
    my $done    = 0;
    my $watchdog;

    my $finish = sub {
        my ($force) = @_;
        return if $done;
        return if !$force && $pending > 0;   # $force (watchdog) renders regardless
        $done = 1;
        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;   # cancel the unused watchdog
        # ONE "Genres" line, and ONE source for it: the ladder's answer, peeked out
        # of the store below. There is no second genre lookup on this page — the
        # ladder's own last rung IS Last.fm, so asking Last.fm again here could only
        # ever repeat what the peek already returned (see the genre block).
        my $g = (ref $mbGenres eq 'ARRAY' && @$mbGenres) ? $mbGenres : undef;
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

    # Genres — the SAME source the lists use, so the detail page can no longer
    # contradict the row you tapped. This was a per-album MusicBrainz
    # `release-group?inc=genres` call, which covers only ~5% of fresh releases and
    # left the other 95% falling through to raw, ungated Last.fm — so a row reading
    # "post-punk" could open a page reading "japanese, 90s, seen live".
    # _withGenres reads the shared bulk cache (already filled by the list that got
    # you here, so this is normally a pure cache hit and makes NO request at all),
    # and _genresFor applies the same album-genres-then-artist-genres preference.
    # Net effect: one MB call FEWER than before, and the two views agree.
    #
    # The detail page shows the FULL, specific genres — the lists roll them up to a
    # top-level family (_familyFor). That is the deliberate split: families where
    # you're scanning, detail where you've drilled in.
    #
    # THIS PATH FETCHES NOTHING — it is a store read and nothing else, and it is
    # now the page's ONLY genre source. It used to carry three on-demand fallbacks
    # (hosted + MusicBrainz, removed 0.9.185; Last.fm, removed 0.9.186); see the
    # block inside for why each went and what was verified first.
    if ($wantGenres) {
        # ---------------------------------------------------------------------
        # THE DETAIL PAGE READS THE STORE AND ASKS NOBODY. Removed 0.9.185: the
        # hosted `/album/<t>/<a>/genres` call and the MusicBrainz release-group
        # call that sat behind it. Simon, repeatedly, and correct: *"there is no
        # need for extra genre calls at all on click in, all this is done before
        # the view is rendered… pulling genres again is wasted code as it's just
        # going to find the same things."* Verified before removing:
        #
        #  1. THE LADDER HAS ALREADY RUN. This peek walks the WHOLE of
        #     `_genresFor` against the store, so anything any tier ever answered
        #     is already in hand and the two calls never fired for it.
        #  2. THE ONE POPULATION THEY WERE JUSTIFIED ON IS ALREADY COVERED.
        #     `getAlbumGenresHosted` was kept for established albums — the
        #     Trending Albums population — but that build ALREADY fetches and
        #     stores genres: its release-group metadata pass carries
        #     `inc=release_group tag` (see the note at the trending rg pass), so
        #     those genres are in the store before anyone can click a row.
        #  3. SO THEY ONLY EVER RAN ON THE RESIDUE WHERE EVERY MB-DERIVED SOURCE
        #     WAS ALREADY EMPTY — and both of them are MB-derived, the same well
        #     ListenBrainz's tags come from. Measured 2026-08-22: hosted answered
        #     0 of 40 albums off the live fresh-releases feed; MB release-group
        #     genres previously measured 0 of 14 on the same residue.
        #
        # Two blocking requests per album open, on the render path, to re-ask a
        # well that had just come up dry.
        #
        # `release_group.detail_genres` (ladder tier 1b) is therefore no longer
        # WRITTEN by this page. It is still READ, and values already stored stay
        # valid — do not strip the tier out of `_genresFor`.
        #
        # AND THE LAST.FM CALL WENT TOO (0.9.186), for the reason 0.9.185 gave for
        # keeping it — that it is the one INDEPENDENT source — being an argument
        # about the LADDER, not about this page. Last.fm IS the ladder's last rung
        # (`_genresFor` tier 5, artist tags then `_lastfmGenres`), so the peek
        # immediately below has already asked it. A second, live `album.gettoptags`
        # here could only repeat the rung that just answered, or re-ask the one
        # that just came up empty — while blocking the render barrier behind up to
        # two chained HTTP calls, and rendering tags UNGATED by `_genreKnown` that
        # the lists would have refused ("japanese", "Dreamy", "zzz").
        #
        # `API::getLastfmTags` STAYS — `_warmLastfm` is the ladder's tier-5 filler
        # and is the thing that puts Last.fm's answer in the store in the first
        # place. What went is this page's own call to it.
        # ---------------------------------------------------------------------
        _withGenres([$rel], sub {
            my $meta = shift;
            $mbGenres = [ _genresFor($rel, $meta) ];
            $pending--;
            $finish->();
        }, undef, peek => 1, kick => 0);
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

    # Artist biography + photo — the MAI plugin, or nothing. Feeds the Artist
    # section; always graceful (guarded inside _fetchArtistInfo). $wantArtist is
    # already false without MAI, so this whole task is absent rather than being a
    # barrier slot that resolves to an empty hash.
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

    # Biography: expands IN PLACE rather than drilling into a separate view (the
    # Discography idiom — which is itself this plugin's old full-bio recipe, improved).
    # Collapsed = a ~2-line preview + "Read more"; expanded = the full bio, one text
    # row per PARAGRAPH, + "Show less". Material renders a text row in full and has no
    # auto-collapse, so the preview must still be pre-trimmed; what changed is only
    # WHERE the rest appears. A short bio shows inline with no toggle at all.
    #
    # The toggle rows reuse the All Releases paging mechanism verbatim
    # (_bioToggleRow, sibling of _pageRow): nextWindow=>'refresh' plus an EMPTY
    # response, the only shape Material acts on, which pops the toggle's own window
    # and re-renders THIS page with the bio's new shape.
    #
    # ROW-COUNT SAFETY: _releaseDetail emits the Streaming section BEFORE this one,
    # so expanding only shifts the non-playable rows that follow (the rest of the
    # artist block, album metadata, genres, tracklist text and the MB weblink). The
    # playable streaming rows keep their item_ids, so deep play is unaffected — the
    # 0.6.11 rule. Do not reorder the sections without revisiting this.
    if (defined $bio && length $bio) {
        my $bkey  = 'bio:' . lc $artist;
        my @paras = _bioParagraphs($bio);

        # THE PREVIEW IS BUILT FROM THE PARSED BLOCKS, NOT THE RAW TEXT. Since
        # 0.9.157 API::_cleanBio rewrites an HTML heading into a SETEXT block
        # ("title\n----------"), a shape that means something only to _bioBlocks —
        # so collapsing the raw bio with s/\s+/ /g leaves the underline in the
        # preview as ten literal hyphens: "Lambchop is an American band from
        # Nashville. Description and history ---------- Initially...".
        #
        # Join ALL the body blocks, not just the first, so the preview still fills
        # BIO_PREVIEW the way it always has rather than stopping short at a one-line
        # opening paragraph. Verified byte-identical on ordinary Last.fm bios.
        my $body = join(' ', map { $_->{text} } grep { !$_->{heading} } @paras);
        my $whole = join(' ', map { $_->{text} } @paras);
        (my $oneLine = (length $body ? $body : $whole)) =~ s/\s+/ /g;

        # Branch selection still measures the WHOLE bio, as it always did — only
        # what gets RENDERED changes. Measuring the body alone would send a long bio
        # whose blocks are mostly headings down the inline branch and lose the rest.
        if (length $whole <= BIO_PREVIEW) {
            # Short enough to show inline, with no toggle. A lone plain paragraph is
            # emitted verbatim (it needs no wrapper); anything carrying structure
            # goes through _proseBlock so a heading or bullet still renders as one.
            push @rows, (@paras == 1 && !$paras[0]{heading} && !$paras[0]{bullet})
                ? { name => $paras[0]{text}, type => 'text' }
                : _proseBlock(@paras);
        }
        elsif ($pageState{ _cid($client) }{$bkey}) {
            # ONE ROW PER PARAGRAPH, matching Discography — see _bioParagraphs for
            # why the split is what it is, and _proseBlock for why the row shape is
            # Discography's. NB this is N rows, not a fixed two: expanding grows the
            # page, so the bio still counts toward LMS_MAX_NON_SCROLLER_ITEMS.
            push @rows, _proseBlock(@paras);
            push @rows, _bioToggleRow($client, $bkey, 0,
                cstring($client, 'PLUGIN_LBF_SHOW_LESS'), PAGE_LESS);
        }
        else {
            # TRIM ONLY WHEN THERE IS SOMETHING TO TRIM. The body can be shorter
            # than the cap once the headings are out of it, and an unconditional
            # back-off to a word boundary would chop its last word off. The ellipsis
            # is correct either way — this branch means more follows.
            my $short = $oneLine;
            if (length $short > BIO_PREVIEW) {
                $short = substr($short, 0, BIO_PREVIEW);
                $short =~ s/\s+\S*$//;       # back off to a word boundary
            }
            $short .= "\x{2026}";
            push @rows, { name => $short, type => 'text' };
            push @rows, _bioToggleRow($client, $bkey, 1,
                cstring($client, 'PLUGIN_LBF_READ_MORE'), PAGE_MORE);
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

# Is the MAI (Music Artist Info) plugin installed and enabled? The detail page's
# whole Artist section depends on it, so the answer is needed BEFORE the barrier
# is counted as well as inside the fetch — hence a sub rather than a local.
# Guarded: PluginManager throwing means "no MAI", never a broken page.
sub _maiEnabled {
    my $on = eval {
        Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin') ? 1 : 0;
    };
    return $on ? 1 : 0;
}

# Fetch an artist biography + photo for the detail page's Artist section, from the
# MAI (Music Artist Info) plugin. Calls $cb->({ bio => $text|undef, image =>
# $url|undef }). Fully guarded: any MAI failure degrades to "no bio / no photo"
# and never breaks or hangs the page (the _releaseDetail watchdog still applies).
#
# NO LAST.FM FALLBACK — removed 0.9.186, deliberately, and the reasoning is short:
# MAI's own bio sources INCLUDE Last.fm, so the fallback was a second route to a
# well MAI had already drawn from. Without MAI there is simply no bio, which is
# the same bargain the artist PHOTO has always been on (MAI-only since this sub
# was written). `API::getArtistBio` went with it, along with `_setText`/`_getText`
# and the `lbf:bio:` key family.
sub _fetchArtistInfo {
    my ($client, $artist, $artistMbid, $cb) = @_;

    my %info;
    unless (length($artist // '') && _maiEnabled()) { $cb->(\%info); return; }

    # MAI's bio/photo are plain functions ($client, $cb, $params, $args); take the
    # coderefs from ->can so we never accidentally pass the package as $client.
    my ($bioFn, $photoFn);
    my $maiOn = 1;
    eval {
        $bioFn   = Plugins::MusicArtistInfo::ArtistInfo->can('getBiography');
        $photoFn = Plugins::MusicArtistInfo::ArtistInfo->can('getArtistPhotos');
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

    # --- Biography: MAI, or nothing ---
    if ($bioFn) {
        $pending++;
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
                # MAI gave nothing usable → no bio. There is nowhere else to ask.
                if ($info{bio}) {
                    $log->info(sprintf("artist-info '%s': MAI bio len=%d", $artist, length $info{bio}));
                }
                else {
                    $log->info("artist-info '$artist': MAI bio empty");
                }
                $pending--; $maybeDone->();
            }, {}, { artist => $artist, ($artistMbid ? (mbid => $artistMbid) : ()) });
            1;
        };
        # MAI threw before it could ever call back — release the slot ourselves, or
        # the barrier never reaches zero and the page waits out DETAIL_TIMEOUT.
        unless ($ok) { $pending--; $maybeDone->(); }
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
#
# Memoed for ADAPTER_MEMO_TTL (0.9.139). Building the list means ~10 ->can probes
# plus a _pluginDataFor icon lookup per service, and it is asked for far more often
# than it can change: the top level alone builds it twice per walk (once inside
# _trendingResolvedKey, once for the tile's enabled-service set), and it is on the
# per-item path of every resolved list via _cachedSvcUsable. Installed plugins can't
# change without a restart and the priority prefs change only in Settings, so a few
# seconds of staleness is invisible — a priority edit still takes effect on the next
# browse, which is the same "next walk" contract as every other pref here.
use constant ADAPTER_MEMO_TTL => 5;
my @_ADAPTERS_MEMO;
my $_ADAPTERS_EXP = 0;

sub _orderedAdapters {
    return @_ADAPTERS_MEMO if time() < $_ADAPTERS_EXP;

    my @out;
    for my $a (_streamingAdapters()) {
        my $prio = $prefs->get('svc_priority_' . lc $a->{name});
        $prio = 1 unless defined $prio;   # unknown service → still searchable
        next unless $prio > 0;
        push @out, { %$a, priority => $prio };
    }
    my @ordered = sort { $a->{priority} <=> $b->{priority} } @out;
    @_ADAPTERS_MEMO = @ordered;
    $_ADAPTERS_EXP  = time() + ADAPTER_MEMO_TTL;
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
    # :20→:21 (0.9.141): the favurl gained '&rt=' for Listen Later's release type.
    # `favorites_url` is part of the CACHED item (_cacheStream stores everything but
    # `url`), so without this bump every already-resolved album would keep handing LL
    # a favurl with no type on it and the handshake would look broken for weeks.
    # :21→:22 (0.9.142): the favurl gained '&tc=' and items gained `_tracks`. **0.9.143 removed
    # both again** (the count is absent from every service's SEARCH response — see _attachFavUrl),
    # and the key deliberately STAYS at :22: rather than going back to :21: or on to :23:.
    # Reverting the key would resurrect pre-0.9.142 entries and bumping it would force a third
    # needless re-resolve; dropping a field from the cached item needs neither, since an orphaned
    # `_tracks` key on an existing entry is simply never read. Bump only when a cached item gains
    # something a reader depends on. (Contrast the Bandcamp pin below: it does NOT re-populate itself
    # and is therefore never bumped for a favurl change at all.)
    # :22→:23 (0.9.144): the favurl GAINED '&al=' (the album title). Same rule as :20→:21
    # and the opposite of the :22 no-op above — this ADDS a field a reader depends on, so
    # every already-resolved album must re-resolve once or it keeps handing LL the old
    # favurl for the whole 7-day TTL.
    # :23→:24 (0.9.145): 0.9.144 SHIPPED '&al=' carrying the MUSICBRAINZ release name; 0.9.145
    # moved it to the matched service's naming.
    # :24→:25 (0.9.146): ...but 0.9.145 SHIPPED TOO, reading the service's RENDERED ROW LABEL
    # (`name`/`line1`), which bakes the artist in — Qobuz artist-first, Bandcamp artist-last.
    # Now the raw album title (`_svctitle`). THREE consecutive builds have put a different
    # wrong string in this one field, each one silently un-matchable at playback, so the rule
    # is worth stating plainly: **a favurl value that LL matches on cannot be left to age out
    # of a 7d cache.** Bump this key on ANY change to what '&al=' carries, even when the field
    # keeps its shape — the cost is one re-resolve, the alternative is a week of silent misses.
    # :25→:26 (0.9.147): ...and a FOURTH, because Bandcamp's raw passthrough title turned out
    # to carry "<album> - <artist>" too, so :25: cached that. Now _stripArtistAffix'd.
    # :26→:27 (0.9.148): 0.9.147 applied that strip on ALL FOUR services, so :26: can hold a
    # Qobuz/Tidal/Deezer title truncated at a dash the service really does use. Bandcamp-only now.
    my $key = Plugins::ListenBrainzFreshReleases::DB::kver("lbf:stream:") . $svcOrder . ':' . ($idPart // '');
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
    my $key = Plugins::ListenBrainzFreshReleases::DB::kver("lbf:bcdone:") . ($idPart // "");
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
#
# THE KEY IS GONE — the pin is a row in `bandcamp_pin`, keyed on the release id
# alone, with no version in its identity at all (see _pinBandcamp). What that
# retires, permanently:
#   * the bump question. 0.9.42 bumped `lbf:bcmatch:` and 0.9.47 reverted it;
#     0.9.141 bumped it again and the pre-release review reverted it again. Both
#     times because a version sitting in a key looks exactly like every other
#     version in the file, and both times a bump would have silently deleted every
#     hand-curated Bandcamp-only match — the album's sole playable entry.
#   * the wipe question. `DELETE FROM kv` is unconditional and needs no allowlist
#     precisely because anything that must survive is not in `kv`.
# The residual cost is UNCHANGED and still worth knowing: a pin replays its stored
# `favorites_url` verbatim (_bcMatchItems), so Listen Later keeps being sent
# whichever album name was current when the pin was made. Removing and re-adding
# the row in Listen Later re-sends the same stale favurl; only a manual
# "Re-search Bandcamp" rewrites the pin.

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
                # $tnorm is the release's OWN MusicBrainz primary type (the same value
                # the single-drop above keys on) — pass it to Listen Later as '&rt='.
                # The album name we send is THE MATCHED SERVICE'S OWN TITLE — `_svctitle`,
                # stashed from the RAW album hash at match time. NOT $album (the MB/LB
                # release name; see '&al=' in _attachFavUrl) and NOT `name`/`line1`, which
                # are the plugin's rendered LABEL with the artist baked in. No fallback: if
                # a service ever yields no title we send nothing and LL reads Material's
                # label, which is what happened before 0.9.144 and is merely imperfect —
                # whereas either wrong string here is silently destructive.
                _attachFavUrl($it, $svc, $art, $artist, $year, _llRelType($tnorm),
                              $it->{_svctitle});  # qobuz://album:<id>?cover=<art>&a=<artist>&al=<svc title>&y=<year>&rt=<type>
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
    eval { $cache->set($key, { items => _stripStreamUrls($items) }, $ttl); 1 }
        or $log->warn("play-via cache set failed: $@");
}

# An OPML `url` is a coderef, which Storable cannot freeze — so it is stripped on
# the way in and reattached on read by _rebuildStreamItems. Shared by the
# disposable play-via cache above and the durable Bandcamp pin below, which must
# store byte-identical items or a pin made before this change and one made after
# would rebuild differently.
sub _stripStreamUrls {
    my ($items) = @_;
    return [ map { my %x = %$_; delete $x{url}; \%x } @{ $items || [] } ];
}

# ---------------------------------------------------------------------------
# The manual Bandcamp pin — A TABLE, NOT A CACHE, and with NO VERSION IN ITS KEY.
#
# A pin comes back ONLY from a manual "Search Bandcamp" tap, and for a
# Bandcamp-only release it is the album's sole playable entry. That is why
# `lbf:bcmatch:` was never bumped: 0.9.42 bumped it and 0.9.47 reverted, then
# 0.9.141 bumped it again and the pre-release review reverted it again. The
# question kept coming up because the version was sitting there in the key
# looking like every other version in the file. As a table row keyed on the
# release id alone, it cannot come up again — which is the actual fix, and the
# reason this is not merely `kv` with a long expiry.
#
# The stored value keeps the old `{ items => [...] }` shape, so a pin carried over
# from the LMS cache by DB::importLegacy and a pin made today are the same value.
# ---------------------------------------------------------------------------
sub _pinBandcamp {
    my ($id, $items) = @_;
    return 0 unless defined $id && length $id;
    return Plugins::ListenBrainzFreshReleases::DB::bcPinPut(
        $id, { items => _stripStreamUrls($items) });
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
# ---------------------------------------------------------------------------
# Release type for the Listen Later handshake (0.9.141)
# ---------------------------------------------------------------------------
# Listen Later 0.1.86 stores a release type per row ('album'|'ep'|'single') and uses
# it for the row glyph, its Played auto-detection thresholds (a single needs one
# play, an EP two) and its single-vs-single dedupe. It has no good way to work that
# out for a streaming add: Qobuz exposes a release_type, but Tidal and the others
# expose NOTHING on the track coderefs, so LL falls back to guessing from a resolved
# TRACK COUNT (1 => single, <=6 => EP). That guess is wrong for a one-track album, a
# seven-track EP, or any release whose count it can't resolve at all.
#
# We know the real answer — it comes from the MusicBrainz release group in the feed
# — so we hand it over. LL's documented channel for this is a private '&rt=' param
# on the favurl (Sources::relTypeFor takes it as `service =>`, and it WINS over the
# count guess); it strips the param before use, exactly like the '&a='/'&y='/'&al='
# handshakes already here.
#
# Only the three values LL understands are ever sent. A MusicBrainz primary type of
# Broadcast or Other (or a blank one) maps to nothing and the param is omitted —
# better to let LL fall back to its count heuristic than to assert "album" for a
# release we can't actually classify. Compilations/soundtracks/live albums arrive as
# primary type Album with a SECONDARY type, so they correctly map to 'album'.
sub _llRelType {
    my ($type) = @_;
    my $t = lc($type // '');
    return 'single' if $t eq 'single';
    return 'ep'     if $t eq 'ep';
    return 'album'  if $t eq 'album';
    return undef;
}

# Strip an artist affix a service has joined onto its own album title, for '&al='.
#
# BANDCAMP ONLY (0.9.148). _searchBandcamp is the single caller: Bandcamp's search
# passthrough returns "<album> - <artist>" (confirmed live: a Bandcamp add stored "Radio:
# Journey Beat (Original Music from Big Walk) - aksfx"), whereas Qobuz/Tidal/Deezer hand back a
# bare title in the raw album hash 0.9.146 moved to. 0.9.147 ran all four through here, which
# was wrong: with no wart to remove on the other three, the strip could only ever misfire —
# a real catalogue title ending in its own artist ("Goldberg Variations - Glenn Gould" by Glenn
# Gould) clears both guards below and reaches LL truncated. Do NOT widen this back out to a
# service without live evidence that it joins the artist on.
#
# WHY IT IS NEEDED AT ALL, having already moved to the raw album hash: the MATCHER never
# noticed the wart, because _albumMatches accepts a candidate that STARTS WITH our album, so a
# trailing " - artist" passes straight through — right for matching, wrong for a title.
#
# Deliberately conservative, following the same reasoning as LL's own 0.1.72 hardening:
#   • the separator must be SPACE-PADDED, so a hyphenated title ("Jay-Z", "Sunn O)))-Monoliths")
#     is never mistaken for a join;
#   • the discarded side must EQUAL the artist under _norm — not merely contain or start with
#     it — so "Album - aksfx remixes" survives intact even when the artist IS aksfx, and an
#     album genuinely named after a dash phrase is untouched. Note the gate is about the
#     DISCARDED side only: "Live - Throwing Copper" by the band Live does strip, to "Throwing
#     Copper", and that is correct — there the artist really is joined on the front;
#   • anything that doesn't match both tests is returned VERBATIM. A missed strip is a cosmetic
#     wart; a wrong strip corrupts the title LL matches and dedupes on. That asymmetry is also
#     why the sub stays where the wart is, rather than being applied defensively everywhere.
# Prefix is tested at the FIRST separator and suffix at the LAST, so a title that itself
# contains " - " still resolves whichever end the artist is on.
#
# LBF-ONLY, outside the shared matcher — it is presentation logic for the handshake, not
# matching. Do NOT confuse it with `_stripArtistPrefix` below, which IS a shared-engine sub
# (fleet-synced across DSC/LBF/PFR); this one does not trip matcher_sync_check.
sub _stripArtistAffix {
    my ($title, $artist) = @_;
    return $title unless defined $title  && !ref $title  && length $title;
    return $title unless defined $artist && !ref $artist && length $artist;

    my $an = _norm($artist);
    return $title unless length $an;

    # Hyphen-minus, the Unicode dash family (figure/en/em/horizontal bar) and minus sign.
    my $dash = qr/\s+[-\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]\s+/;

    if ($title =~ /^(.*?)$dash(.*)$/s) {          # first separator → "<artist> - <album>"
        my ($lhs, $rhs) = ($1, $2);
        return $rhs if length $rhs && _norm($lhs) eq $an;
    }
    if ($title =~ /^(.*)$dash(.*?)$/s) {          # last separator  → "<album> - <artist>"
        my ($lhs, $rhs) = ($1, $2);
        return $lhs if length $lhs && _norm($rhs) eq $an;
    }
    return $title;
}

sub _attachFavUrl {
    my ($it, $svc, $art, $artist, $year, $relType, $album) = @_;

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

    # The MATCHED SERVICE'S album title as '&al=' (0.9.144), the symmetric partner of '&a='.
    # ListenLater has no structured album name for an online row: Material substitutes
    # $ALBUMNAME/$TITLE with the row's DISPLAY LABEL verbatim, which is whatever that
    # streaming plugin's renderer printed — Bandcamp's search rows read "Title (Album)".
    # Sending the service's own title makes the album name independent of that plumbing.
    #
    # SEND THE SERVICE'S NAME, NEVER MUSICBRAINZ'S — this is the whole rule, and 0.9.144
    # SHIPPED IT BACKWARDS (fixed in 0.9.145). By the time we build a favurl we have RESOLVED
    # this release to a specific service album, and from that point the service's spelling is
    # the only one that matters downstream:
    #   • LL's Played auto-detection matches the PLAYING track's album title, which the
    #     service reports — so a record stored under MB's spelling is never recognised while
    #     it plays and never leaves the list. Silent: the album plays perfectly.
    #   • LL's dedupe key is artist|album|year, so the same album added DIRECTLY from that
    #     service must produce the same key — it will only if we use the service's name.
    # The two disagree constantly, and not just over edition qualifiers: ListenBrainz has
    # aksfx – "Radio: Fourth Space (Original Music from Big Walk)" where Qobuz has
    # "…(Original Music from the Game \"Big Walk\")". MusicBrainz also keeps a release's
    # distinguisher OUT of the title (all four American Football LPs are titled "American
    # Football"; "LP2"/"LP3" live in MB's `disambiguation`), which the services put IN it.
    # Sending MB's name loses on both.
    #
    # Same idiom (and the same defined/ref/length guard) as '&a='; Pitchfork Reviews sends the
    # identical param — but for a DIFFERENT reason worth keeping straight: its rows are
    # labelled "Artist - Album", so its '&al=' undoes ITS OWN renderer's prefix. That is not
    # licence to substitute a different naming authority, which is exactly the mistake here.
    # NB [?&]a= on LL's side cannot match '&al=' — it needs '=' right after the 'a' — so the
    # two params can't collide whatever order they arrive in.
    if (defined $album && !ref $album && length $album) {
        require URI::Escape;
        push @params, 'al=' . URI::Escape::uri_escape_utf8($album);
    }

    # And the release year, so ListenLater's dedupe key (artist|album|year) tells two
    # same-titled releases from different years apart — otherwise the second one added
    # is silently dropped as a duplicate. Bare 4-digit, no escaping needed.
    if (defined $year && $year =~ /^\d{4}$/) {
        push @params, 'y=' . $year;
    }

    # The authoritative MusicBrainz release type, for Listen Later (see _llRelType).
    # Bare word from a fixed three-value set — no escaping needed.
    if (defined $relType && length $relType) {
        push @params, 'rt=' . $relType;
    }

    # NO '&tc=' (the service track count) — 0.9.142 added one and 0.9.143 removed it again as
    # measurably dead. The count fields (Qobuz tracks_count / Deezer nb_tracks / TIDAL
    # numberOfTracks) are real, but they live on each service's per-ALBUM endpoint and are
    # ABSENT from the SEARCH responses these matches come from, so nothing was ever sent.
    # (Spotify is the ONE exception — its search payload really does carry total_tracks and
    # Spotty's normalize() keeps it, which is why _candReleaseType reads it. It changes
    # nothing here: Spotify returns early from this sub, keeping Spotty's own favorites_url.)
    # Verified live rather than assumed: adding a 3-track MusicBrainz Single from a match row
    # logged `rel=single` at insert on all three services, then LL's own check corrected it to
    # `ep` (Qobuz 1.5 ms, Tidal 150 ms, Deezer 2-277 ms) — i.e. LL always did the work. Don't
    # re-add this without ONE real end-to-end observation of a count arriving: every test
    # written for it supplied the field itself, which is exactly how it shipped inert.
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
    # On a miss, ask the outgoing LMS cache ONCE for a pin made before this
    # release moved the store — it cannot be enumerated, so this is the only
    # moment we know which id to ask about. Bounded by DB::IMPORT_WINDOW, and a
    # no-op after it.
    my $c = Plugins::ListenBrainzFreshReleases::DB::bcPinGet($id)
         // Plugins::ListenBrainzFreshReleases::DB::importPin($id);
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
# Spotify total_tracks. NOTE: unlike the old dead `&tc=` param, total_tracks is NOT inert —
# Spotify is the one service whose SEARCH payload actually carries a count (normalize() keeps
# it), so the count chain below genuinely fires from a Spotify search result. Don't remove it.
sub _candReleaseType {
    my ($album) = @_;
    return '' unless ref $album eq 'HASH';

    for my $f (qw(release_type record_type album_type type)) {
        my $t = lc($album->{$f} // '');
        next unless $t;
        # Spotify has no EP class — EPs report album_type "single". Guard the
        # single verdict on the count so a 4+-track EP falls through to '' (and
        # so isn't dropped for album/compilation targets) while a real 1-3 track
        # single still classifies. total_tracks is absent (→ 0) on the other
        # services, so this is inert for them.
        return 'single' if $t eq 'single' && !(($album->{total_tracks} // 0) > 3);
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
            # The service's own ALBUM TITLE, for Listen Later's '&al=' (see _attachFavUrl).
            # Taken from the RAW album hash, never from the rendered node: `name`/`line1` are
            # each plugin's DISPLAY LABEL and they bake the artist in — Qobuz renders it
            # artist-first, Bandcamp artist-last — which lands in LL's stored title and its
            # dedupe key, and never matches at playback. This is the same field _albumMatches
            # validates against above, so it is the album title alone by construction.
            # NOT run through _stripArtistAffix (0.9.148, correcting 0.9.147, which applied it
            # here too): the raw hash title is already bare on this path — only Bandcamp's
            # PASSTHROUGH is evidenced to join the artist on — while a catalogue title that
            # genuinely ends in its artist ("Goldberg Variations - Glenn Gould" by Glenn Gould)
            # clears both of the sub's guards and would be truncated to a name the service never
            # reports at playback: the exact failure this handshake exists to prevent, in reverse.
            $item->{_svctitle} = $album->{title};
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
            # Bandcamp's own ALBUM TITLE for '&al=' — from the PASSTHROUGH, not the rendered
            # row, whose label is "<album> - <artist>". Same field _albumMatches validates
            # against above. Serves BOTH Bandcamp paths: the manual picker calls this sub
            # through the adapter's `run`, so the stash flows through to it.
            # Bandcamp joins the artist ON: its passthrough title is "<album> - <artist>"
            # (confirmed live — an add stored "Radio: Journey Beat (…) - aksfx", while
            # playback reports the bare title, so the two could never match). Strip it.
            # THE ONLY CALLER of _stripArtistAffix (0.9.148): Bandcamp is the one service
            # evidenced to join, and the strip carries a real false-positive cost, so it is
            # spent only where the wart is known to exist. See the sub's own header.
            $it->{_svctitle} = _stripArtistAffix($pt->{title}, $pt->{artist});
            push @out, $it;
        }
        $collect->(\@out);
    }, { search => $query });
}

# The detail-page "Search Bandcamp" row: a deliberate one-tap manual search
# (Bandcamp is excluded from the auto search because it blocks the loop). It uses
# the SAME in-place refresh mechanism as the streaming "Refresh" row
# (nextWindow 'refresh'): the tap searches, persists any match (_pinBandcamp),
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
# its own durable table row (_pinBandcamp); _findPlayable appends it to every render,
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
            # BANDCAMP'S OWN title from `_svctitle` (the passthrough title stashed in
            # _searchBandcamp), like every other service. NOT $album (the MB/LB release
            # name) and NOT $name/`line1` — Bandcamp's row label is "<album> - <artist>",
            # so using it bakes the artist into LL's stored title and dedupe key and can
            # never match at playback. See '&al=' in _attachFavUrl.
            _attachFavUrl($cand, 'Bandcamp', $art, $artist, $year,
                          _llRelType($rel->{release_group_primary_type}),
                          $cand->{_svctitle});  # …&al=<svc title>&rt=<type>
            push @rows, {
                name        => $name,
                line2       => $artist,
                type        => 'link',
                image       => $art // $bc->{icon},
                passthrough => [{}],
                url         => sub {
                    my ($c, $cb2) = @_;
                    _pinBandcamp($id, [$cand]);
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
            # The service's own ALBUM TITLE, for Listen Later's '&al=' (see _attachFavUrl).
            # Taken from the RAW album hash, never from the rendered node: `name`/`line1` are
            # each plugin's DISPLAY LABEL and they bake the artist in — Qobuz renders it
            # artist-first, Bandcamp artist-last — which lands in LL's stored title and its
            # dedupe key, and never matches at playback. This is the same field _albumMatches
            # validates against above, so it is the album title alone by construction.
            # NOT run through _stripArtistAffix (0.9.148, correcting 0.9.147, which applied it
            # here too): the raw hash title is already bare on this path — only Bandcamp's
            # PASSTHROUGH is evidenced to join the artist on — while a catalogue title that
            # genuinely ends in its artist ("Goldberg Variations - Glenn Gould" by Glenn Gould)
            # clears both of the sub's guards and would be truncated to a name the service never
            # reports at playback: the exact failure this handshake exists to prevent, in reverse.
            $item->{_svctitle} = $album->{title};
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
            # The service's own ALBUM TITLE, for Listen Later's '&al=' (see _attachFavUrl).
            # Taken from the RAW album hash, never from the rendered node: `name`/`line1` are
            # each plugin's DISPLAY LABEL and they bake the artist in — Qobuz renders it
            # artist-first, Bandcamp artist-last — which lands in LL's stored title and its
            # dedupe key, and never matches at playback. This is the same field _albumMatches
            # validates against above, so it is the album title alone by construction.
            # NOT run through _stripArtistAffix (0.9.148, correcting 0.9.147, which applied it
            # here too): the raw hash title is already bare on this path — only Bandcamp's
            # PASSTHROUGH is evidenced to join the artist on — while a catalogue title that
            # genuinely ends in its artist ("Goldberg Variations - Glenn Gould" by Glenn Gould)
            # clears both of the sub's guards and would be truncated to a name the service never
            # reports at playback: the exact failure this handshake exists to prevent, in reverse.
            $item->{_svctitle} = $album->{title};
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
    # A missing handler is only INCONCLUSIVE (undef → 1h TTL) when Spotty COULD
    # have answered. With no credentials on the server at all it is PERMANENT —
    # getAccount returns undef on every call — so reporting it inconclusive would
    # pin every genuine miss to STREAM_INCONCLUSIVE_TTL (1h instead of 24h) for
    # ever, 24x the re-search load on the other services. hasCredentials() with
    # no id is truthy iff any account exists, so signed-out → [] (real no-match).
    unless ($api) {
        my $signedIn = eval { Plugins::Spotty::AccountHelper->hasCredentials() };
        $collect->($signedIn ? undef : []);
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
            $item->{_albumid}  = $sid;
            $item->{_svctitle} = $album->{name};            # raw service title (name, not title, on Spotify)
            $item->{_ctype}    = _candReleaseType($album);  # album/single/ep — for the type filter (album_type)
            $item->{_year}     = _svcYear($album);          # service release year (trending date fallback)
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
    my $key = Plugins::ListenBrainzFreshReleases::DB::kver("lbf:track:") . $svcOrder . ':' . ($recMbid || _norm($query));
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
    # See _searchSpotify: signed-out is PERMANENT, so report it as a real no-match
    # ([]) not inconclusive (undef), else every miss pins to the 1h TTL for ever.
    unless ($api) {
        $log->info("Spotify track-match: no API handler");
        my $signedIn = eval { Plugins::Spotty::AccountHelper->hasCredentials() };
        $collect->($signedIn ? undef : []);
        return;
    }

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
    # LEETSPEAK SUBSTITUTIONS - a punctuation mark standing in for a LETTER.
    #
    # Applied ONLY when a word character FOLLOWS the mark. That is precisely
    # what separates a letter from decoration: "P!nk" -> pink and "Ke$ha" ->
    # kesha (the mark sits INSIDE the word), while a trailing or free-standing
    # mark is punctuation and falls through to the [^\p{Alnum}] rule below.
    #
    # WHY, and it is not cosmetic (field via DSC, 2026-07-21): the old
    # unconditional fold made a name spelled WITH the mark disagree with the
    # same name spelled WITHOUT it - "Layo & Bushwacka!" -> 'layo bushwackai'
    # against 'layo bushwacka'. `_albumMatches`' artist gate is MANDATORY, so
    # EVERY streaming candidate was rejected and the page read "No releases
    # found" for an artist with a correctly resolved MBID. The same fold also
    # made "Panic At The Disco" unsearchable without typing the "!".
    #
    # A name made ENTIRELY of these marks ("!!!", a real band) keeps the old
    # unconditional fold: stripping would leave '', and `_artistMatch` rejects
    # an empty side outright - i.e. this very bug in a new costume.
    # "$" and "@" are UNCONDITIONAL: in a stylised name they are effectively
    # always a letter, including at the END - "$uicideboy$" is Suicideboy(s),
    # so the trailing "$" is an s, not decoration. Scoping the boundary rule
    # below to them broke exactly that (caught by the cross-repo behaviour
    # harness, which PFR documents as a supported case).
    $s =~ s/\$/s/g;
    $s =~ s/\@/a/g;
    # "!" IS different, and it is the one that motivated this: it has a real
    # decorative use that the others do not - "Wham!", "Panic! At The Disco",
    # "Godspeed You! Black Emperor", "Layo & Bushwacka!" - where the mark is
    # punctuation and the name is spelled both ways in the wild. So "!" folds
    # to a letter ONLY when a word character FOLLOWS it (inside a word, as in
    # "P!nk"); otherwise it falls through to the [^\p{Alnum}] pass below.
    #
    # A name of nothing BUT marks ("!!!", a real band) keeps the unconditional
    # fold: stripping would leave '', and `_artistMatch` rejects an empty side
    # outright - this very bug in a new costume.
    if ($s =~ /[\p{Alnum}]/) { $s =~ s/(?<=\w)!(?=\w)/i/g }
    else                      { $s =~ s/!/i/g }
    $s =~ s/\x{20ac}/e/g;   # euro sign
    $s =~ s/\x{a3}/l/g;     # pound sign
    $s =~ s/\x{a5}/y/g;     # yen sign

    # "&" and "+" are SPOKEN "and", and this is the same rule as every
    # substitution above it - a symbol folded to the word it stands for, like
    # $ -> s and ! -> i. Without it the two spellings key differently ("simon
    # garfunkel" vs "simon and garfunkel", because & alone becomes a space
    # below), so the SAME act arriving from two services became two search rows
    # and only merged if MusicBrainz happened to record the variant as an
    # alias. Field 2026-07-21: Deezer says "Layo and bushwacka!" where Tidal
    # says "Layo & Bushwacka" - one act, two rows.
    #
    # "+" is included because services use it the same way; MB's own alias list
    # for that duo literally carries "Layo + Bushwacka!".
    $s =~ s/[&+]/ and /g;
    $s =~ s/[\(\[].*?[\)\]]//g;
    $s =~ s/[^\p{Alnum}]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}


# ---------------------------------------------------------------------------
# The feed itself carries almost no genre: measured over 400 releases of a live
# All Releases feed (2026-07-26), the inline `release_tags` populate 8% of rows and
# MusicBrainz's release-group genres only 5% — which is why the genre line has
# always looked broken. The credited ARTIST's genres cover 47%, and both arrive in
# the SAME bulk ListenBrainz call (API::getReleaseGroupMetadata, `inc=tag`), so the
# list can be filled at ~one request per 50 releases instead of one per release.
#
# **Why this isn't attached to an existing call:** there is none to attach it to at
# feed level — the feed is ONE `fresh_releases` request that returns every release
# and offers no tag option, and the per-album MB genre lookup only happens on a
# drill-in. So the cost is kept invisible three other ways: (1) only the releases
# actually being RENDERED are filled (the All Releases weeks page 30 at a time → one
# request per page turn), (2) the daily warm pre-fills the cache so a browse is a
# pure cache hit, and (3) the detail page's own per-album MB genre call is retired
# in favour of this data, so that path makes one call FEWER than before.
#
# Bounded per render: a cold For You feed with hundreds of releases would otherwise
# fan out to many chunks at once. Rows past the cap simply render without a genre
# and pick one up once the warm has cached them.
use constant GENRE_FETCH_MAX => 150;   # ≤3 batches per render
use constant GENRE_BATCH     =>  50;   # == METADATA_CHUNK: one request + ≤50 cache reads per tick

# NEVER do the fill inline on the render path (0.9.130). getReleaseGroupMetadata
# opens with a SYNCHRONOUS cache-scan — one `$cache->get` per mbid — and writes one
# `$cache->set` per fetched entry. At GENRE_FETCH_MAX that is up to 150 blocking
# SQLite round-trips inside the browse callback, on EVERY feed render including
# every sort tap, and every one of them is a miss right after a cache-prefix bump.
# This plugin has form here: Bandcamp was pulled from the auto-search because
# synchronous work in a browse handler stalled the event loop and dropped players
# (see "Streaming matching & playlist robustness"), and the library probe was moved
# behind an idle tick for the same reason in 0.9.48.
#
# So: the collect loop below touches no cache, then the work is handed to
# `Slim::Utils::Timers` and run a batch at a time, yielding to the event loop
# BETWEEN batches. Audio is serviced between slices and the render path itself
# never blocks. Cost is one extra event-loop turn per batch — invisible next to a
# feed fetch, and a fully-warmed feed still does no HTTP at all.
#
# $step is passed to ITSELF as a timer argument rather than captured in its own
# closure: `my $s; $s = sub { ... $s ... }` is a reference cycle Perl never
# collects — the exact leak fixed in API::getArtistMbidByName in 0.9.95.
# ---------------------------------------------------------------------------
# Where genres come from, and whether we're allowed to go and get them (0.9.140)
# ---------------------------------------------------------------------------
# 0.9.129–0.9.135 added genre labels by putting a REMOTE lookup on the path of a
# render. Measured, that was the wrong trade: ListenBrainz's metadata host answers
# a 50-mbid batch in anywhere from 0.25s to 24s, caps out below 100 mbids, and one
# full fill of a 381-release feed took 125 SECONDS — which the genre picker sat and
# waited for. The feature is worth having; paying for it on a tap is not.
#
#   'mirror' — a local MusicBrainz mirror is configured or was autodetected. Ask it
#              directly, per artist, six at a time. Same data ListenBrainz would
#              have served (verified: identical coverage over 50 artists, zero
#              disagreement either way), at 40–120ms with no throttle and no
#              variance. Still the fastest path, so it still wins when available.
#   'lb'      — no mirror: the ListenBrainz bulk path, concurrent. NOW THE DEFAULT.
#   'off'     — no lookup at all. Rows still show the genres that arrive FREE with
#              the feed (its own release_tags) and anything the Last.fm tier has
#              already cached. Opt-in only.
#
# THE UNPARK (2026-08-12). This sub used to end `return $pref eq 'always' ? 'lb'
# : 'off'` — so the default 'auto' meant OFF for everyone without a mirror, and
# that single line is what kept the whole genre feature parked. The reasoning was
# sound at the time and is recorded above: ListenBrainz answered a 50-mbid batch in
# 0.25s–24s, 502'd above ~90 mbids, and took a measured 125s to fill one
# 381-release feed, so turning it on by default would have made every browse a
# lottery for a cosmetic label.
#
# ListenBrainz fixed that endpoint. Re-benchmarked against the live 556-release All
# Releases week: **2.8s for the whole feed** — 12 batches of 50, worst batch 0.52s,
# no 502s — with coverage reproduced exactly (5% release-group, 47% artist). At
# that speed the bulk path is fine as a default, and because every render is a
# `peek` (cache-only, never waits) the user never blocks on it even when cold.
# 'always' now means "use the bulk path even if a mirror exists" rather than
# "opt in to something slow".
sub _genreLookupMode {
    my $pref = $prefs->get('genre_lookup') // 'auto';
    return 'off' if $pref eq 'off';
    return 'lb'  if $pref eq 'always';
    return Plugins::ListenBrainzFreshReleases::API->hasMirror() ? 'mirror' : 'lb';
}

# The genre map for a list of releases, as { lc release-group-mbid => { genres,
# agenres } } — the shape _genresFor consumes.
#
# $opt{peek} (every RENDER path) means CACHE ONLY: never fetch, never wait. The
# rows draw immediately with whatever is known, and a bounded background fill is
# kicked off so the next visit is complete. The warm calls without peek, which is
# where the fetching actually happens — nobody is watching it there.
sub _withGenres {
    my ($releases, $cb, $max, %opt) = @_;   # $max: the warm passes a bigger bound than a render
    $max ||= GENRE_FETCH_MAX;
    my $mode = _genreLookupMode();

    if ($mode eq 'off') { $cb->({}); return }

    # A RELEASE WITH NO RELEASE GROUP IS NOT A RELEASE WITH NO GENRE. This loop
    # used to `next` on a missing release_group_mbid, so those rows never reached
    # _mergeHostedGenres and the two ARTIST-KEYED rungs — tier 2b (ListenBrainz
    # artist tags) and tier 5 (Last.fm) — were unreachable for them. Those rungs
    # key on the artist, not on a release group, and the Trending rows with no
    # MBID are precisely the case they exist to answer, so the rows the ladder was
    # built for were the rows it could never reach. A bare view is a bug.
    #
    # They ride in a SEPARATE list on their own budget rather than in @rels: @rels
    # is what the release-group lookups are batched from and $max bounds that HTTP,
    # so letting artist-only rows in would let them displace lookups that actually
    # fetch something.
    my (@rels, @artOnly, %seenRg, %seenArt);
    for my $r (@{ $releases || [] }) {
        last if @rels >= $max && @artOnly >= $max;
        if (my $m = $r->{release_group_mbid}) {
            next if $seenRg{ lc $m }++;
            push @rels, $r if @rels < $max;
        }
        else {
            # Deduped by the key the merge itself uses, so one prolific artist
            # cannot eat the budget with a dozen singles.
            my $ak = _hostedArtistKey($r) or next;
            next if $seenArt{$ak}++;
            push @artOnly, $r if @artOnly < $max;
        }
    }
    unless (@rels || @artOnly) { $cb->({}); return }

    # A peek normally kicks a background top-up; $opt{kick}=>0 suppresses that for
    # callers that do their own follow-up lookup (the release detail page), so a
    # single-release peek can not spend the whole feed's top-up budget.
    my $kick = exists $opt{kick} ? $opt{kick} : 1;
    if ($mode eq 'mirror') { _withGenresMirror(\@rels, \@artOnly, $cb, $opt{peek}, $kick) }
    else                   { _withGenresLB(\@rels, \@artOnly, $cb, $opt{peek}, $kick) }
}

# Mirror path: genres are keyed by ARTIST, so the map is assembled by looking each
# release's credited artists up rather than by release group.
sub _withGenresMirror {
    my ($rels, $artOnly, $cb, $peek, $kick) = @_;
    $artOnly ||= [];
    my @all = (@$rels, @$artOnly);            # everything the artist rungs answer for

    # NB: never name a loop variable $a or $b in this file — they're sort's globals,
    # and a lexical one silently breaks any sort in the same scope.
    my (@artists, %seen);
    for my $r (@all) {
        my $am = ref $r->{artist_mbids} eq 'ARRAY' ? $r->{artist_mbids} : [];
        for my $amb (@$am) {
            next unless $amb;
            push @artists, $amb unless $seen{ lc $amb }++;
        }
    }

    if ($peek) {
        # BULK, NOT ONE SELECT PER ARTIST. The genre picker's pass walks the whole
        # feed through here, so the per-artist loop this replaces was up to ~600
        # synchronous SQLite SELECTs inside the browse callback — the same hazard
        # 0.9.130 removed from the release-group side and 0.9.165 nearly put back.
        # peekArtistGenresBulk is what every other peek path already uses.
        my $known   = Plugins::ListenBrainzFreshReleases::API->peekArtistGenresBulk(\@artists);
        my $missing = grep { !exists $known->{ lc $_ } } @artists;

        my $meta = _metaFromArtists($rels, $known);
        _mergeRgGenres($rels, $meta);   # ladder tiers 1 + 1b — see the sub
        # The FULL list: a release with no release group has nothing for
        # _metaFromArtists to key on, but the artist-keyed rungs answer for it.
        _mergeHostedGenres(\@all, $meta);   # ONE store read, not one per release
        $cb->($meta);
        _kickGenreFill(\@all) if $kick && ($missing || _artistRungMissing($artOnly, $meta));
        return;
    }

    # No artist carries an MBID, so the artist rungs have nothing to look up — but
    # a release-group answer does not depend on them, so this branch still has to
    # go and get one rather than answering with an empty map.
    unless (@artists) {
        my $meta = {};
        _mergeRgGenres($rels, $meta);
        $cb->($meta);
        return;
    }

    Plugins::ListenBrainzFreshReleases::API->getArtistGenres(\@artists, sub {
        my $meta = _metaFromArtists($rels, shift // {});
        _mergeRgGenres($rels, $meta);
        $cb->($meta);
    });
}

# ---------------------------------------------------------------------------
# LADDER TIER 1b ON THE MIRROR PATH — the half of 0.9.173 that was never applied.
#
# `_genresFor` reads `detail_genres` (what the detail page learned about THIS
# release group) and ranks it ABOVE the artist tiers on purpose: it is an answer
# about the RECORD, and an artist genre is only ever a proxy for one. But it
# reaches $meta solely through DB::rgGet — i.e. through peekReleaseGroupMetadataBulk
# and getReleaseGroupMetadata, BOTH ON THE LISTENBRAINZ PATH. Mirror mode builds
# $meta entirely from artist rows via _metaFromArtists, which hard-codes
# `genres => []` and never touches the release_group row, so tier 1b was
# unreachable and opening an album still threw its answer away as far as the list
# was concerned — the exact defect _migrate_5 and the 0.9.173 note describe as
# fixed. It is also the DEFAULT path on any server with a local MusicBrainz mirror.
#
# ONE bulk read for the page, never one per row: that is the ~2,900 synchronous
# SELECTs bench_walk caught in 0.9.165 and the hazard 0.9.130 moved off the render
# path. Through peekReleaseGroupMetadataBulk rather than DB::rgGet directly, so the
# two paths cannot drift on key-casing or row shape.
#
# It CREATES an entry as well as filling one: _metaFromArtists only makes a $meta
# row when some credited artist had genres, so a release group whose only answer is
# the detail page's would otherwise have nowhere to put it. `genres`/`agenres` are
# seeded empty so _genresFor's tier order still walks through this entry to the
# artist rungs below rather than stopping at it.
#
# BOTH RELEASE-GROUP TIERS, NOT JUST 1b — decided 2026-08-23, and the evidence is
# what settled it. Tier 1 (`genres`, the album's own ListenBrainz tags) sits in the
# SAME row this already reads, and mirror mode ignored it for exactly the same
# reason it ignored 1b. The question was whether a mirror box's store ever holds
# one: it does, and not by accident — `getReleaseGroupMetadata` is called by the
# Trending Tracks date fill and the Trending Albums release-group pass REGARDLESS
# of genre mode, and that request carries `inc=release_group tag`, so it writes the
# `genres` column on a mirror box where the genre ladder itself never touches it.
# So a mirror user who has browsed Trending had album-level genres in the store
# that the list refused to read, and saw the artist proxy instead.
#
# This is a VISIBLE change for existing mirror users — a row that reads as the
# artist's genre today can flip to the album's own — which is why it was raised
# rather than folded into the 1b fix. It is the ladder behaving as specified:
# an answer about the RECORD outranks a proxy for it.
#
# `agenres` is deliberately NOT merged. The artist tiers have their own reader
# (_mergeHostedGenres, keyed per artist) and on this path _metaFromArtists has
# already filled them from the mirror's own artist rows — writing them here would
# put a second, differently-sourced answer into the same slot.
# ---------------------------------------------------------------------------
sub _mergeRgGenres {
    my ($rels, $meta) = @_;
    return unless ref $meta eq 'HASH';

    my %want;
    for my $r (@{ $rels || [] }) {
        my $rg = lc($r->{release_group_mbid} // '') or next;
        $want{$rg} = 1;
    }
    return unless %want;

    my $rows = eval {
        Plugins::ListenBrainzFreshReleases::API->peekReleaseGroupMetadataBulk([ keys %want ]);
    } || {};

    for my $rg (keys %want) {
        my $row = $rows->{$rg} or next;
        my $own = ref $row->{genres}        eq 'ARRAY' ? $row->{genres}        : [];
        my $det = ref $row->{detail_genres} eq 'ARRAY' ? $row->{detail_genres} : [];
        next unless @$own || @$det;
        # Seeded empty so _genresFor's tier walk still falls THROUGH this entry to
        # the artist rungs below when neither column answered for a given release.
        $meta->{$rg} ||= { genres => [], agenres => [] };
        # Each column into its own slot, and only when it actually answered — the
        # tier ORDER is _genresFor's business, not this sub's. An empty column must
        # not overwrite a filled slot beside it.
        $meta->{$rg}{genres}        = $own if @$own;
        $meta->{$rg}{detail_genres} = $det if @$det;
    }
    return;
}

# Fold artist genres back onto their releases, in the { genres, agenres } shape
# _genresFor expects. `genres` (the release's OWN, tier 1) stays empty here: MB
# release-group genres are ~5% on fresh releases — measured at 0 of 47 on a live
# feed — so fetching a second per-release lookup for them would double the traffic
# to change almost no rows. Tier 1 still arrives on the ListenBrainz path.
sub _metaFromArtists {
    my ($rels, $byArtist) = @_;
    my %meta;
    for my $r (@$rels) {
        my $rg = lc($r->{release_group_mbid} // '') or next;
        my $am = ref $r->{artist_mbids} eq 'ARRAY' ? $r->{artist_mbids} : [];
        for my $amb (@$am) {
            my $g = $amb ? $byArtist->{ lc $amb } : undef;
            next unless ref $g eq 'ARRAY' && @$g;
            $meta{$rg} = { genres => [], agenres => $g };
            last;                                   # first credited artist with genres wins
        }
    }
    return \%meta;
}

# ListenBrainz bulk path — the pre-0.9.140 behaviour, kept for opted-in users with
# no mirror, with two fixes.
#
# NEVER do the fill inline on the render path (0.9.130). getReleaseGroupMetadata
# opens with a SYNCHRONOUS cache-scan — one `$cache->get` per mbid — and writes one
# `$cache->set` per fetched entry. At GENRE_FETCH_MAX that is up to 150 blocking
# SQLite round-trips inside the browse callback, and this plugin has form here:
# Bandcamp was pulled from the auto-search because synchronous work in a browse
# handler stalled the event loop and dropped players. So each batch is launched on
# its own idle tick, which spreads those scans across event-loop turns.
#
# What's new in 0.9.140 is that the batches no longer wait for EACH OTHER. They ran
# strictly one at a time, so eight batches meant eight round trips end to end — the
# 125s. They're still launched a tick apart (so the cache scans never gang up), but
# up to GENRE_CONCURRENCY are in flight at once.
#
# $step is passed to ITSELF as a timer argument rather than captured in its own
# closure: `my $s; $s = sub { ... $s ... }` is a reference cycle Perl never
# collects — the exact leak fixed in API::getArtistMbidByName in 0.9.95.
use constant GENRE_CONCURRENCY => 4;

sub _withGenresLB {
    my ($rels, $artOnly, $cb, $peek, $kick) = @_;
    $artOnly ||= [];
    my @all = (@$rels, @$artOnly);            # everything the artist rungs answer for

    my @mbids = grep { defined && length } map { $_->{release_group_mbid} } @$rels;

    # A peek can't use the bulk endpoint at all — it has no cache-only mode — so
    # read the per-release-group entries directly and fetch nothing.
    if ($peek) {
        # ONE bulk read for the whole page, not one per release group. The genre
        # picker's pass walks the WHOLE feed through here (~2,900 release groups),
        # so a per-release read would put thousands of synchronous SELECTs back on
        # the render path — the hazard 0.9.130 removed and 0.9.165 nearly
        # reintroduced through the hosted tier.
        my %meta = %{ Plugins::ListenBrainzFreshReleases::API
                          ->peekReleaseGroupMetadataBulk(\@mbids) };
        # A ROW BEING PRESENT IS NOT A GENRE BEING PRESENT, and this counted rows.
        # `rgGet` answers for any row that exists, and rows get created by things
        # that have nothing to do with the ListenBrainz genre tier — the release
        # detail page files its own answer with `rgPut($rg, detail_genres => …)`,
        # which leaves `n_genres` at its -1 "never asked" default. So a feed whose
        # release groups had each had a detail page opened once looked fully
        # covered here, the top-up never fired, and the rows stayed bare in the
        # list for ever however many times they were opened. Count an mbid as
        # answered only when the tier actually recorded an answer for it.
        my $rgKnown = grep { _rgAnswered($meta{$_}) } keys %meta;
        # Count only the RELEASE-GROUP answers when deciding whether to top up:
        # the artist entries share this hash but are keyed per ARTIST, so counting
        # them would make a page of one prolific artist look fully covered. Hence
        # this is read BEFORE the merge, while the keys are all release groups.
        _mergeHostedGenres(\@all, \%meta);   # ONE store read, not one per release
        $cb->(\%meta);
        _kickGenreFill(\@all)
            if $kick && ($rgKnown < scalar(@mbids) || _artistRungMissing($artOnly, \%meta));
        return;
    }

    my @batches;
    push @batches, [ splice(@mbids, 0, GENRE_BATCH) ] while @mbids;

    # NO BATCHES MEANS NOTHING TO FETCH — IT DOES NOT MEAN NOTHING TO ANSWER.
    # The launch loop below runs `1 .. $starts`, and $starts is 0 for an empty
    # @batches, so $step never ran and $cb was never called AT ALL: the chain just
    # stopped. The all-empty case is guarded upstream in _withGenres, so the
    # reachable hole is the MIXED one this ladder deliberately introduced —
    # @rels empty, @artOnly non-empty, i.e. a list whose rows carry an artist
    # credit but no release group, which is exactly the Trending shape the
    # @artOnly budget exists to answer.
    #
    # It strands the WARM, whose two _withGenres calls are the only non-peek
    # callers besides the top-up: _warmGenres chains For You -> Last.fm ->
    # $warmAll, so a For You pass that filters down to artist-only rows leaves
    # genres_foryou 'running' for ever in warmstats and ALL RELEASES IS NEVER
    # WARMED for that tick. The artist rungs still answer for these rows — the
    # non-peek path leaves that to _warmLastfm behind this callback, which is
    # precisely what never gets reached.
    #
    # _withGenresMirror has had this guard since it was written (`unless
    # (@artists)`); this is the same guard the LB path was missing.
    unless (@batches) { $cb->({}); return }

    my %meta;
    my $active = 0;
    my $fired  = 0;
    my $step = sub {
        my (undef, $self) = @_;                  # timer calls $step->($obj, @args)
        my $batch = shift @batches;
        unless ($batch) {
            $cb->(\%meta) if !$active && !$fired++;
            return;
        }
        $active++;
        Plugins::ListenBrainzFreshReleases::API->getReleaseGroupMetadata($batch, sub {
            my $m = shift || {};
            @meta{ keys %$m } = values %$m;
            $active--;
            if (@batches)     { Slim::Utils::Timers::setTimer(undef, time(), $self, $self) }
            elsif (!$active)  { $cb->(\%meta) unless $fired++ }
        });
    };

    # Stagger the initial launches by a tick each: the point of the yield was never
    # the HTTP (that's async), it was the synchronous cache scan at the head of each
    # getReleaseGroupMetadata call. Firing four in one turn would gang four scans.
    my $starts = @batches < GENRE_CONCURRENCY ? scalar @batches : GENRE_CONCURRENCY;
    for my $i (1 .. $starts) {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.05 * $i, $step, $step);
    }
}

# Background top-up after a peek found gaps, so "open it, come back, they're there"
# works without waiting for the nightly warm. Strictly fire-and-forget: no callback
# reaches the render that triggered it. One at a time and no more often than
# GENRE_KICK_GAP, so paging through a feed can't launch a fill per page.
use constant GENRE_KICK_GAP    => 120;
use constant GENRE_KICK_MAXRUN => 300;   # watchdog: never let the busy flag stick
my $_genreKickAt  = 0;
my $_genreKicking = 0;

sub _kickGenreFill {
    my ($rels) = @_;
    my $now = time();
    return if $_genreKicking || $now - $_genreKickAt < GENRE_KICK_GAP;
    $_genreKicking = 1;
    $_genreKickAt  = $now;
    # A fill that never calls back (a wedged request) must not disable top-ups for
    # the life of the server, so clear the flag on a watchdog as well as on
    # completion. Whichever lands first wins; the other is a no-op.
    Slim::Utils::Timers::setTimer(undef, time() + GENRE_KICK_MAXRUN, sub { $_genreKicking = 0 });
    _dbg("genres: background top-up for " . scalar(@$rels) . " release(s)");

    # BOTH TIERS, NOT JUST LISTENBRAINZ — this is what §2.4.1 of
    # docs/caching-rework.md specifies ("it fills the same background top-up
    # _kickGenreFill already runs"), and it was never wired up. The sub called
    # _withGenres alone (the ListenBrainz release-group/artist tags) and never
    # reached the community API, which answers for ~43% of what ListenBrainz's
    # ~48% leaves behind. So the top-up could only ever repair about half the
    # feed and the rest waited on the once-daily warm — which is why rows could
    # stay blank however many times you opened them.
    #
    # Chained, not parallel, and in ladder order: _warmLastfm skips every release a
    # cheaper tier has already answered, so running it second means it asks only
    # about what is genuinely still missing.
    #
    # 0.9.173: the middle rung here was the hosted artist tier, removed with the
    # rest of it. The top-up therefore now goes LB bulk → Last.fm, which is both
    # rungs the ladder still has — so the reasoning above still holds and the
    # top-up is no longer capable of repairing only half the feed.
    _withGenres($rels, sub {
        my $meta = shift // {};
        _warmLastfm($rels, $meta, sub { $_genreKicking = 0 });
    }, GENRE_WARM_MAX);
}

# ---------------------------------------------------------------------------
# Daily warm of the genre cache (0.9.134)
# ---------------------------------------------------------------------------
# Without this, the FIRST time you open a week the rows render before the fill
# lands, so the genre labels only appear on the second visit. Pre-filling on the
# daily tick means an open is a pure cache hit and the labels are there straight
# away — which is also what makes the (per-artist, non-bulk) Last.fm tier
# affordable when it lands.
#
# Bounded well above the per-render cap: this runs once a day in the background,
# not per page. 600 release groups is ~12 bulk requests, and entries then sit in
# the cache for 90 days, so in the steady state a tick only fetches whatever is
# newly released. Reuses the same batched, idle-tick _withGenres the browse path
# uses, so the warm can no more hold the event loop than a render can.
#
# Both feeds are themselves cached (24h) and the warm runs after the playlist
# stage, so this normally adds no feed traffic at all — just the genre fill.
# (GENRE_WARM_MAX is declared up with the other constants — the genre picker and
# the All Releases week coderef both use it, and both sit earlier in this file.)

# The Last.fm stage of the warm (phase 3). Fills the per-artist tag cache for the
# releases the bulk ListenBrainz pass left with NO genre, so the render path — which
# only ever peeks at that cache — has something to show next time.
#
# Deliberately the most conservative stage in the whole warm:
#   • Only releases with nothing from any cheaper tier are considered.
#   • Deduped by ARTIST, because the tags fetched are artist-level anyway. One call
#     covers every release by that artist in the feed.
#   • Hard-capped at LFM_WARM_MAX per tick. It's per-artist (not bulk), so this is
#     the expensive tier; the cache holds 30 days, so a small daily allowance still
#     converges — it just doesn't try to do it all in one night.
#   • ONE call in flight at a time, each behind an idle tick, so we never burst at
#     Last.fm and never hold the event loop.
#   • No key configured → does nothing at all.
use constant LFM_WARM_MAX => 40;

# ...AND THE DAILY WARM'S OWN BOUND, for the same reason GENRE_WARM_ALL exists.
# See the note below: a rung that only ever fills 40 artists a night cannot
# prepare a feed, so the rows it owns arrive as a background top-up in front of the
# user. Still ONE request per second, one in flight — the pacing is what protects
# Last.fm, and it is untouched; this is the per-night QUOTA, which protected
# nothing. A full pass is ~7 minutes of idle-tick background work.
use constant LFM_WARM_ALL => 400;

# `_warmHosted`, HOSTED_WARM_MAX and HOSTED_WARM_ALL were removed in 0.9.173 with
# the rung they filled. The warm chain is now LB bulk → Last.fm, which is the
# ladder _genresFor actually reads.
#
# ONE THING FROM THEIR COMMENTS IS WORTH KEEPING, because it applies to every
# remaining rung and was learned the hard way in 0.9.165: WHAT PROTECTS A SHARED
# SERVICE IS THE PACING, NOT THE PER-NIGHT QUOTA. A cap that stops the warm after
# N artists does not reduce the rate anything is pushed at in any given second —
# it just guarantees the feed is never fully prepared, however many nights pass,
# which is the "genres only show after going in and out of a release" report.
# Bound the concurrency; do not ration the job. LFM_WARM_ALL above is that lesson
# applied, and it is why it is 400 and not 40.

sub _warmLastfm {
    my ($releases, $meta, $done, $max) = @_;   # $max: the warm passes the whole-feed bound
    $done ||= sub {};
    $max ||= LFM_WARM_MAX;
    unless (($prefs->get('lastfm_api_key') // '') ne '') { $done->(); return }

    my (@queue, %seenArtist);
    for my $rel (@{ $releases || [] }) {
        last if @queue >= $max;
        next if _genresFor($rel, $meta);          # a cheaper tier already answered
        my $artist = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') or next;
        next if $seenArtist{ lc $artist }++;
        # ARTIST-LEVEL, so the answer generalises. This queue is already deduped by
        # artist "because the tags fetched are artist-level anyway" — but it used to
        # pass the FIRST release's album, and getLastfmTags stores under
        # artist+album while the row reads back with each release's OWN album. So of
        # an artist's three releases only the one that seeded the warm could ever
        # read the answer, and the other two consumed the allowance again next
        # night. An empty album goes straight to artist.gettoptags.
        push @queue, $artist;
    }
    unless (@queue) { _dbg("warm: last.fm — nothing to fill"); $done->(); return }

    my $filled = 0;
    my $step = sub {
        my (undef, $self) = @_;
        my $job = shift @queue;
        unless ($job) {
            _dbg("warm: last.fm — filled $filled artist(s)");
            $done->();
            return;
        }
        Plugins::ListenBrainzFreshReleases::API->getLastfmTags(
            $job, '',
            sub {
                my $tags = shift // [];
                $filled++ if grep { _genreKnown($_) } @$tags;
                # Filed on the ARTIST row, through the same key builder the readers
                # use, so every release by this artist in the feed can read it.
                if (my $mk = Plugins::ListenBrainzFreshReleases::API->artistKeyForName($job)) {
                    eval {
                        require Plugins::ListenBrainzFreshReleases::DB;
                        Plugins::ListenBrainzFreshReleases::DB::artistPut(
                            $mk, lastfm_genres => $tags);
                        1;
                    } or $log->warn("last.fm artist-tier store failed for $job: $@");
                }
                # Yield between calls: paced for Last.fm, and the event loop keeps
                # servicing audio through a long warm.
                Slim::Utils::Timers::setTimer(undef, time() + 1, $self, $self);
            },
            sub { Slim::Utils::Timers::setTimer(undef, time() + 1, $self, $self) },
        );
    };
    Slim::Utils::Timers::setTimer(undef, time(), $step, $step);
}

# IS THE FEED ACTUALLY PREPARED? The one question the warm exists to answer, and
# until now it reported everything except that: how many artists each rung asked
# about, never how many ROWS would draw with a genre. So a warm that covered a
# third of the feed and a warm that covered all of it produced equally cheerful
# logs, and the only way to tell them apart was to open a view and look — which is
# how "it is still background filling" gets found by the user rather than by us.
#
# Counted through _genresFor, so it measures exactly what the row builder will
# show: the whole ladder, in ladder order, for the releases the user's own filters
# leave in the feed. Anything short of ~100% means the next open of that view draws
# bare rows and fills behind them.
# FILE THE LISTENBRAINZ ARTIST TAGS UNDER THE ARTIST, not only under the release
# group they arrived with. They are `tag.artist` — the credited artist's genres — and
# storing them per release group meant the store re-bought the same answer once per
# release, which is the single biggest reason the warm could never prepare a feed.
#
# Written HERE rather than in API::getReleaseGroupMetadata for a concrete reason: the
# ListenBrainz response carries no artist identity at all (the request is
# `inc=release_group tag`), so the association between those tags and an artist key
# exists only in the FEED ROW. Doing it at the store layer would mean guessing, and a
# wrong guess files one artist's genres under another's.
#
# Keyed through _hostedArtistKey, so it lands on the SAME artist row the hosted and
# Last.fm rungs use — one row per artist, one column per tier, nothing overwriting
# anything.
sub _persistLbArtistTags {
    my ($rels, $meta) = @_;
    return 0 unless ref $meta eq 'HASH';
    my ($n, %seen) = (0);

    for my $rel (@{ $rels || [] }) {
        my $rg = lc($rel->{release_group_mbid} // '') or next;
        my $m  = $meta->{$rg} or next;
        my $g  = ref $m->{agenres} eq 'ARRAY' ? $m->{agenres} : next;
        my $mk = _hostedArtistKey($rel) or next;
        (my $key = $mk) =~ s/^a://;
        # First writer wins within a pass. A joined credit ("A & B") keys as itself,
        # so it cannot pollute either member's row.
        next if $seen{$key}++;
        eval {
            require Plugins::ListenBrainzFreshReleases::DB;
            Plugins::ListenBrainzFreshReleases::DB::artistPut($key, lb_genres => $g);
            1;
        } and $n++;
    }
    _dbg("warm: LB artist tags — filed $n artist(s) on the artist row") if $n;
    return $n;
}

sub _warmReport {
    my ($rels, $meta, $which) = @_;
    my $total = scalar @{ $rels || [] } or return;
    my $with  = 0;
    for my $rel (@$rels) { $with++ if _genresFor($rel, $meta) }
    _dbg(sprintf('warm: %s PREPARED — %d of %d releases have a genre (%d%%)%s',
                 $which, $with, $total, int(100 * $with / $total),
                 $with < $total ? ' — the remainder will fill in the background' : ''));
    return;
}

sub _warmGenres {
    my $user  = $prefs->get('username') // '';
    my $token = $prefs->get('token')    // '';

    # All Releases needs no account, so it's warmed for everyone.
    my $warmAll = sub {
        _stage('start', 'genres_all');
        Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
            sort    => 'release_date',
            onDone  => sub {
                # Filter first: no point warming genres for releases the user's own
                # type/artwork/VA settings would never show.
                my $rels = _filterAll(shift);
                _withGenres($rels, sub {
                    my $meta = shift // {};
                    # The LB rung is finished here; Last.fm is a separate stage
                    # below it, because it is the paced one (one request per
                    # second) and folding the two together would hide which of
                    # them the ladder actually spends its time in.
                    _stage('end', 'genres_all', 'done', scalar(keys %$meta) . ' release group(s)');
                    _stage('start', 'genres_lastfm_all');
                    _dbg("warm: genres — All Releases, " . scalar(keys %$meta) . " release group(s)");
                    _persistLbArtistTags($rels, $meta);
                    # Ladder order, strictly chained so the two never fan out
                    # together: LB bulk (done), then Last.fm.
                    # BOTH RUNGS GET THE WHOLE-FEED BOUND, not just the first.
                    # A ladder that completes on one tier and trickles on the
                    # other cannot prepare a feed — see LFM_WARM_ALL.
                    _warmLastfm($rels, $meta, sub {
                        _stage('end', 'genres_lastfm_all', 'done', '');
                        _warmReport($rels, $meta, 'All Releases');
                    }, LFM_WARM_ALL);
                }, GENRE_WARM_ALL);
            },
            onError => sub {
                my $err = shift // '';
                _stage('end', 'genres_all', 'failed', $err);
                _dbg("warm: genres — All Releases fetch failed: $err");
            },
        );
    };

    # USERNAME ONLY. This used to require a token as well, which was left over from
    # before 0.9.160 established that `fresh_releases` has never needed one — so a
    # tokenless user's For You genres were never warmed at all, and their rows
    # could only ever fill from a background top-up two minutes at a time.
    unless ($user) {
        _stage('end', 'genres_foryou',         'skipped', 'no username');
        _stage('end', 'genres_lastfm_foryou',  'skipped', 'no username');
        $warmAll->();
        return;
    }

    _stage('start', 'genres_foryou');
    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => 'release_date',
        onDone  => sub {
            my $rels = _filterForYou(shift);
            _withGenres($rels, sub {
                my $meta = shift // {};
                _stage('end', 'genres_foryou', 'done', scalar(keys %$meta) . ' release group(s)');
                _stage('start', 'genres_lastfm_foryou');
                _dbg("warm: genres — For You, " . scalar(keys %$meta) . " release group(s)");
                _persistLbArtistTags($rels, $meta);
                # Chained, never fanned out: Last.fm, then the whole All Releases
                # pass behind it.
                _warmLastfm($rels, $meta, sub {
                    _stage('end', 'genres_lastfm_foryou', 'done', '');
                    _warmReport($rels, $meta, 'For You');
                    $warmAll->();
                }, LFM_WARM_ALL);
            }, GENRE_WARM_ALL);
        },
        onError => sub {
            my $err = shift // '';
            _stage('end', 'genres_foryou', 'failed', $err);
            _dbg("warm: genres — For You fetch failed: $err");
            $warmAll->();
        },
    );
}

# The genres to SHOW for one release, strongest first. Prefers the album's own
# release-group genres and falls back to the credited artist's — deliberately in
# that order, because an artist genre is only a proxy for the record (a jazz
# artist's ambient side project would inherit "jazz"), so it must never override a
# genre the release itself carries. Returns () when neither has one.
sub _genresFor {
    my ($rel, $meta) = @_;
    return () unless ref $rel eq 'HASH';

    if (ref $meta eq 'HASH') {
        my $m = $meta->{ lc($rel->{release_group_mbid} // '') };
        if (ref $m eq 'HASH') {
            my $own = ref $m->{genres}  eq 'ARRAY' ? $m->{genres}  : [];
            return @$own if @$own;                              # tier 1: the album's own

            # Tier 1b: what the DETAIL PAGE learned about this very release group
            # — the hosted album route, else MusicBrainz's release-group genres.
            # ABOVE the artist tiers on purpose: this is an answer about the RECORD,
            # and an artist genre is only ever a proxy for it (the reason tier 2
            # sits below tier 1 in the first place — a jazz artist's ambient side
            # project would otherwise inherit "jazz").
            #
            # Before 0.9.173 this answer existed but was written only to
            # Slim::Utils::Cache, so opening an album discovered a genre and threw
            # it away as far as the list was concerned. See DB::_migrate_5.
            my $det = ref $m->{detail_genres} eq 'ARRAY' ? $m->{detail_genres} : [];
            return @$det if @$det;

            my $art = ref $m->{agenres} eq 'ARRAY' ? $m->{agenres} : [];
            return @$art if @$art;                              # tier 2: the artist's
        }
    }

    # Tier 2b: the SAME ListenBrainz artist tags, read off the ARTIST row rather
    # than off this release's group. Before schema 4 they were only ever stored per
    # release group, so an artist's tags learned from one release did nothing for
    # that artist's other releases — the store re-bought the same answer once per
    # release and the feed could never be prepared. Same data, keyed where it
    # generalises, so it sits with tier 2 and above the hosted rung.
    my @lbArtist = _lbArtistGenres($rel, $meta);
    return @lbArtist if @lbArtist;

    # Tier 3 was the HOSTED artist genres (LMS-community API), removed in 0.9.173:
    # it is MusicBrainz-derived, so it failed wherever ListenBrainz failed, and it
    # answered ~2% of the artists that actually reached it across two measurements
    # a week apart. See the block comment in API.pm where it used to live.

    # Tier 4: the feed payload's own release_tags. Free (already in hand) and
    # release-specific. Proven independent of ListenBrainz's tag block — André
    # Cymone's "The Resurrection of Funk" has inline tags while LB returns nothing
    # for its release group OR artist.
    my @inline = _releaseTags($rel);
    return @inline if @inline;

    # Tier 5: Last.fm, gated to MusicBrainz's genre vocabulary. The ARTIST-level
    # answer comes off the same bulk read as the rungs above — the album-keyed
    # `lastfm_tags` table stays for the release detail page, whose album.gettoptags
    # answer is genuinely album-specific. `_lastfmGenres` remains as the per-release
    # fallback for anything the bulk read had nothing for.
    my @lfmArtist = grep { _genreKnown($_) } _lastfmArtistGenres($rel, $meta);
    return @lfmArtist if @lfmArtist;

    return _lastfmGenres($rel);
}

# Hosted artist genres, READ OUT OF THE RENDER'S OWN META MAP — never from the
# store, and never from the network (see the tier-3 note in _genresFor).
#
# THE MAP IS WHY, AND IT IS NOT AN OPTIMISATION. The obvious implementation asks
# the store per release, and the first version of this sub did. That is one
# synchronous SQLite SELECT per row — ~30 for a page, and ~2,900 for the genre
# picker, which walks the WHOLE feed through _bucketFor. Exactly the blocking
# work 0.9.130 moved off the render path after the same class of thing stalled
# the event loop and dropped players. `_withGenres` does ONE bulk read per render
# and hands the answers down in $meta instead. Caught by bench_walk, not by
# review.
#
# Stored under an 'a:' namespace rather than by release group, because the whole
# point of this tier is that it is keyed on the artist NAME: it is the only genre
# source that can answer for a Trending row arriving with no MBID at all, and
# those rows have no release-group key to file anything under.
sub _lbArtistGenres { return _artistTierGenres($_[0], $_[1], 'lb:', LB_MARK()) }
sub _lastfmArtistGenres { return _artistTierGenres($_[0], $_[1], 'lfm:', LFM_MARK()) }

sub _artistTierGenres {
    my ($rel, $meta, $prefix, $mark) = @_;
    # The marker is set only when the bulk read actually found something for THIS
    # rung, and checking it FIRST is what keeps the common empty case free: without
    # it every release pays a _norm to build a key that can only ever miss, which
    # measured at +1.5ms per walk on the picker's whole-feed pass (bench_walk).
    return () unless ref $meta eq 'HASH' && $meta->{$mark};
    my $key = _hostedArtistKey($rel) or return ();
    $key =~ s/^a://;
    my $g = $meta->{ $prefix . $key };
    return ref $g eq 'ARRAY' ? @$g : ();
}


# The $meta key for a release's credited artist, or '' when it has no usable
# credit. One place, so the fill side and the read side cannot disagree.
sub _hostedArtistKey {
    my ($rel) = @_;
    my $artist = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') or return '';
    my $key = Plugins::ListenBrainzFreshReleases::API->artistKeyForName($artist) or return '';
    return 'a:' . $key;
}

# Has the ListenBrainz release-group tier actually ANSWERED for this row, as
# opposed to the row merely existing? `n_genres` is -1 until that tier writes, so
# it — not the row's presence — is the question the top-up gate has to ask. A row
# that already carries a genre from any tier needs no top-up either way.
sub _rgAnswered {
    my ($m) = @_;
    return 0 unless ref $m eq 'HASH';
    return 1 if defined $m->{n_genres} && $m->{n_genres} >= 0;
    for my $c (qw(genres agenres detail_genres)) {
        return 1 if ref $m->{$c} eq 'ARRAY' && @{ $m->{$c} };
    }
    return 0;
}

# Do any of these releases still have nothing from the ARTIST-keyed rungs
# (_mergeHostedGenres' `lb:` / `lfm:` entries)? Asked of the release-group-less
# rows, which have no other rung to reach — pure hash lookups against the map the
# render just built, so it costs nothing on the browse path.
sub _artistRungMissing {
    my ($rels, $meta) = @_;
    return 0 unless ref $meta eq 'HASH';
    for my $rel (@{ $rels || [] }) {
        # No artist name at all -> no rung can ever answer, so it is not evidence
        # that a top-up would help. Skip it rather than kicking a fill for ever.
        my $mk = _hostedArtistKey($rel) or next;
        (my $id = $mk) =~ s/^a://;
        my $got = grep { ref $meta->{$_} eq 'ARRAY' && @{ $meta->{$_} } }
                       ("lb:$id", "lfm:$id");
        return 1 unless $got;
    }
    return 0;
}

# Merge the hosted artist genres for @$rels into $meta, in ONE store read.
# Called from the peek paths of _withGenres, so every render that builds a genre
# map gets the tier for free and nothing else has to think about it.
sub _mergeHostedGenres {
    my ($rels, $meta) = @_;
    return unless ref $meta eq 'HASH';

    my (%want, %seen);
    for my $rel (@{ $rels || [] }) {
        my $mk = _hostedArtistKey($rel) or next;
        next if $seen{$mk}++;
        (my $bare = $mk) =~ s/^a://;
        $want{$bare} = $mk;
    }
    return unless %want;

    my $rows = eval {
        require Plugins::ListenBrainzFreshReleases::DB;
        Plugins::ListenBrainzFreshReleases::DB::artistGet([ keys %want ]);
    } || {};

    # BOTH ARTIST-LEVEL RUNGS COME OFF THE SAME BULK READ. One statement for the
    # page, never one per release — that is the ~2,900 synchronous SELECTs
    # bench_walk caught in 0.9.165, and the hazard 0.9.130 removed. Each rung has
    # its OWN column, so nothing here can mistake one tier's answer for another's
    # or overwrite it; the marker keys keep the empty case free for each.
    #
    # It was THREE rungs until 0.9.173 dropped the hosted artist tier — the `a:`
    # prefix and `hosted_genres` column are gone from this loop but NOT from the
    # table, so a downgrade still finds its data. The sub keeps its name because
    # `_hostedArtistKey` is still the shared key builder for the artist row.
    for my $bare (keys %want) {
        my $row = $rows->{$bare} or next;
        my $mk  = $want{$bare};
        (my $id = $mk) =~ s/^a://;

        for my $t (['lb_genres', 'lb:', LB_MARK()],
                   ['lastfm_genres', 'lfm:', LFM_MARK()]) {
            my ($col, $prefix, $mark) = @$t;
            next unless ref $row->{$col} eq 'ARRAY' && @{ $row->{$col} };
            $meta->{ $prefix . $id } = $row->{$col};
            $meta->{$mark} = 1;
        }
    }
    return;
}

# Last.fm artist/album tags, cache-ONLY and vocabulary-gated.
#
# Coverage: measured on the 206 releases (of 400) that ListenBrainz had no genre
# for, Last.fm answered for 44% of them — taking the feed as a whole from ~49% to
# ~71%. But its raw tags are unusable as genres ("japanese", "Colombia", "anime",
# "Dreamy", "zzz", "brainrot"), so every tag must be a name MusicBrainz recognises.
#
# NEVER fetches here. Last.fm is per-ARTIST, not bulk — filling it on the render
# path would mean ~15 HTTP calls for a 30-row page, which is the opposite of what
# phase 1 was for. The daily warm populates the cache (_warmLastfm) and this reads
# whatever landed; an artist not yet warmed simply has no genre this time round.
sub _lastfmGenres {
    my ($rel) = @_;
    return () unless ($prefs->get('lastfm_api_key') // '') ne '';
    my $artist = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') or return ();
    my $album  = _pickValue($rel, 'release_name', 'title', 'name') // '';
    my $tags   = Plugins::ListenBrainzFreshReleases::API->peekLastfmTags($artist, $album);
    return grep { _genreKnown($_) } @$tags;
}

# ---------------------------------------------------------------------------
# Genre -> top-level family rollup (0.9.131)
# ---------------------------------------------------------------------------
# MusicBrainz publishes a curated genre VOCABULARY (2177 names via `genre/all`)
# but NO hierarchy — verified against a mirror: `genre/<mbid>?inc=genre-rels` is
# "Not Found" and genre search "hasn't been implemented". So the parent/child
# rollup ships as a generated data file, `genre-families.txt`
# (tools/make_genre_families.py — rerun it to regenerate; don't hand-edit).
#
# The split, as specified: the LISTS show the top-level family ("Electronic"),
# because that's what you want when scanning a week of releases; the release
# DETAIL page shows the full specific genres ("downtempo, chillwave, drone").
#
# Loaded once, lazily, from the plugin's own directory (derived from %INC so it
# works for a manual install and a repo install alike). A missing or unreadable
# file is not an error — every genre then simply has no family, and the lists fall
# back to showing the genre itself.
my %_GENRE_FAMILY;
my %_GENRE_MODIFIER;   # family '-' in the table: a treatment word, not a style
my %_GENRE_KNOWN;      # EVERY name MusicBrainz calls a genre — the Last.fm gate
my $_familiesLoaded = 0;

sub _loadGenreFamilies {
    return if $_familiesLoaded;
    $_familiesLoaded = 1;
    my $path = $INC{'Plugins/ListenBrainzFreshReleases/Browse.pm'} or return;
    $path =~ s{Browse\.pm$}{genre-families.txt};
    open(my $fh, '<:encoding(UTF-8)', $path) or do {
        $log->info("genre families: no table at $path (genres will show unrolled)");
        return;
    };
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/ || $line !~ /\t/;
        chomp $line;
        my ($g, $fam) = split /\t/, $line, 2;
        next unless defined $g && defined $fam && length $g && length $fam;
        $_GENRE_KNOWN{$g} = 1;                        # the vocabulary (gates Last.fm)
        if    ($fam eq '-') { $_GENRE_MODIFIER{$g} = 1 }
        elsif ($fam ne '?') { $_GENRE_FAMILY{$g}   = $fam }
        # '?' = a real genre with no family yet: known, showable, not rolled up.
    }
    close $fh;
    $log->info("genre families: loaded " . scalar(keys %_GENRE_FAMILY) . " genres");
}

# Normalise a genre the same way the generator did, so "synth-pop" and "Synth Pop"
# both find the "synth pop" key.
sub _genreKey {
    my ($g) = @_;
    $g = lc($g // '');
    $g =~ s/[\s\-_\/]+/ /g;
    $g =~ s/^\s+//; $g =~ s/\s+$//;
    return $g;
}

sub _genreFamily {
    my ($g) = @_;
    _loadGenreFamilies();
    return $_GENRE_FAMILY{ _genreKey($g) };
}

# A treatment word (instrumental, lo-fi, acoustic …) rather than a style. Distinct
# from "no family": an UNKNOWN genre is still worth showing to the user, a modifier
# never is.
sub _genreModifier {
    my ($g) = @_;
    _loadGenreFamilies();
    return $_GENRE_MODIFIER{ _genreKey($g) };
}

# Is this string a genre MusicBrainz actually recognises? This is the gate that
# makes Last.fm usable: its tags are dominated by languages, countries, moods and
# junk ("japanese", "seen live", "brainrot", "zzz"), and none of those are in MB's
# curated vocabulary. Modifiers are in the vocabulary but excluded here — a tier
# that only ever yielded "instrumental" would be worse than no tier.
sub _genreKnown {
    my ($g) = @_;
    _loadGenreFamilies();
    my $k = _genreKey($g);
    return $_GENRE_KNOWN{$k} && !$_GENRE_MODIFIER{$k};
}

# ---------------------------------------------------------------------------
# Genre picker + filter (0.9.136)
# ---------------------------------------------------------------------------
# A multi-select genre filter, modelled on the genre selection menu in SvenInNdh's
# Qobuz fork (checkbox rows + a Select-all row + the count on the entry row).
# Deliberately DIVERGES from it in three ways:
#   • IMMEDIATE APPLY, no staging buffer and no "Store" row. Sven's version stages
#     toggles in memory and commits on save, which forces a `refreshing` flag and a
#     `$params->{index}` heuristic to tell an internal refresh from a fresh entry.
#     Our picker is its own drill-in level, so a tap re-renders only the picker off
#     cached data — the pref can just be written directly, and all that state goes
#     away.
#   • Material's OWN check_box font icons via the _MTL_icon_<name> convention, so
#     no custom checkbox artwork is needed.
#   • An ARRAYREF pref, not a "#id#id#" delimited string — no regex membership
#     tests, and a family name containing the delimiter can't corrupt it. Matches
#     the existing `blocked_artists` pref shape.
#
# The bucket key for a release is its FAMILY, or GENRE_NONE for anything that
# doesn't roll up. An empty selection means "everything" — the same convention the
# release-type checkboxes already use.
use constant GENRE_NONE => '_none';   # stable internal key; displayed via a string

sub _selectedGenres {
    my ($prefix) = @_;
    my $v = $prefs->get("${prefix}_genres");
    return ref $v eq 'ARRAY' ? $v : [];
}

# The family a release is FILED under. Unlike _familyFor (which is for display and
# falls back to the raw genre when nothing rolls up), this returns only a real
# family — so the picker can't sprout a singleton bucket per obscure genre.
sub _bucketFor {
    my ($rel, $meta) = @_;
    for my $g (_genresFor($rel, $meta)) {
        my $fam = _genreFamily($g);
        return $fam if $fam;
    }
    return GENRE_NONE;
}

sub _genreSelectFilter {
    my ($releases, $prefix, $meta) = @_;
    my $sel = _selectedGenres($prefix);
    return $releases unless @$sel;                  # nothing ticked = show everything
    my %want = map { $_ => 1 } @$sel;
    return [ grep { $want{ _bucketFor($_, $meta) } } @{ $releases || [] } ];
}

# The Options row that opens the picker. Carries the count so an active filter is
# visible without opening it ("Genres (3)" vs "Genres (All)") — the one idea from
# Sven's version I took unchanged.
sub _genresRow {
    my ($client, $prefix, $rels) = @_;
    my $sel = _selectedGenres($prefix);
    my $n   = @$sel ? scalar(@$sel) : cstring($client, 'PLUGIN_LBF_GENRE_ALL');
    return {
        name        => sprintf(cstring($client, 'PLUGIN_LBF_GENRES_SELECT'), $n),
        type        => 'link',
        image       => MENU_GENRE,
        # Hand the picker THIS level's releases (0.9.138). Two reasons, and the
        # first is a correctness bug: the picker used to re-fetch the whole feed,
        # so an All Releases week showed feed-wide counts — "Rock (188)" over a
        # week listing twelve. Now the counts describe exactly the list you came
        # from. It is also the bulk of the picker's cost: no second feed decode,
        # and the genre fill covers one week instead of up to GENRE_WARM_MAX
        # across every week. Rebuilt on every walk by the level that owns it, so
        # it can't go stale.
        passthrough => [{ prefix => $prefix, rels => $rels }],
        url         => \&genrePicker,
    };
}

# One feed, filtered by the section's settings. Shared by the picker and the warm
# so the two can't drift on which prefs drive which feed.
sub _feedFor {
    my ($prefix, $cb) = @_;
    if ($prefix eq 'foryou') {
        Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
            sort   => 'release_date',
            onDone  => sub { $cb->(_filterForYou(shift)) },
            onError => sub { $cb->([]) },
        );
    }
    else {
        Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
            sort   => 'release_date',
            onDone  => sub { $cb->(_filterAll(shift)) },
            onError => sub { $cb->([]) },
        );
    }
}

# The picker level: "All genres" then one checkbox row per family PRESENT in the
# list it was opened from, with counts. Listing only what's actually there
# (rather than all 21 families) doubles as a view of that list's shape, and can't
# offer a filter that would return nothing.
#
# It works on the releases the OWNING LEVEL handed it (0.9.138) and only falls
# back to fetching the feed if that's missing. The fallback exists for safety, not
# for use: it's the old whole-feed path, whose counts don't describe the week you
# came from.
sub genrePicker {
    my ($client, $cb, $args, $pass) = @_;
    my $prefix = (ref $pass eq 'HASH' && $pass->{prefix}) ? $pass->{prefix} : 'all';
    my $given  = (ref $pass eq 'HASH' && ref $pass->{rels} eq 'ARRAY') ? $pass->{rels} : undef;

    my $scope = $given ? sub { $_[0]->($given) } : sub { _feedFor($prefix, $_[0]) };
    $scope->(sub {
        my $rels = shift // [];
        # CACHE ONLY (peek — 0.9.140). This is the screen that made the problem
        # visible: it asked for a fill of up to GENRE_WARM_MAX releases and then sat
        # on it, and a measured cold fill of a 381-release feed took 125 SECONDS
        # (8 ListenBrainz batches, 9–24s each). It now opens instantly off the cache
        # and tops up behind. With a mirror the cache is filled in seconds, so the
        # counts are complete almost immediately; without one the user has opted in
        # to a slower source and the first open shows what's known so far.
        _withGenres($rels, sub {
            my $meta = shift // {};
            # ONE bucketing pass (0.9.139). The counts and the apply row's "Show N
            # releases" both need each release's family, and this used to work it out
            # twice — once here, once inside _genreSelectFilter below. _bucketFor walks
            # the whole genre tier ladder per release (and, with a Last.fm key set,
            # reads the tag cache), so on a busy week that was hundreds of lookups
            # done for a second time, on every tick of the picker.
            my (%count, @bucket);
            for my $rel (@$rels) {
                my $b = _bucketFor($rel, $meta);
                push @bucket, $b;
                $count{$b}++;
            }

            my $sel  = _selectedGenres($prefix);
            my %on   = map { $_ => 1 } @$sel;

            # Apply & return. Material has NO server-driven way to mark a parent
            # level as stale: browseGoBack() restores the history entry's CACHED
            # items, and the only thing that forces a re-fetch is its own
            # `needsRefresh` flag, which nothing but Material's internals sets
            # (browse-functions: podcasts addshow/delshow, search, playlist moves).
            # So plain Back can never show the newly filtered list — 0.9.136's
            # bug. nextWindow 'parent' on an EMPTY response is the one lever a
            # plugin does have: it pops this level off the history and calls
            # browseGoBack(force=1), which DOES refreshList() the level below.
            # This row is what Sven's "Store" row is for; we keep immediate apply
            # so it's a return, not a commit, and the label re-renders on every
            # tick as a live preview of what going back will show.
            #
            # It COUNTS the result, which it can only do honestly now that the
            # picker is scoped to the level that opened it (0.9.138) — while it
            # re-fetched the whole feed, every number here was feed-wide and
            # didn't match the week you returned to. The tick marks already say
            # which genres are on, so the useful thing to add is how many rows
            # you'll land on.
            # Counted off the single bucketing pass above — same answer
            # _genreSelectFilter would give (nothing ticked = everything shows).
            my $shown = @$sel ? scalar(grep { $on{$_} } @bucket) : scalar(@$rels);
            my @rows  = ({
                name        => sprintf(cstring($client,
                                  $shown == 1 ? 'PLUGIN_LBF_GENRE_APPLY_ONE'
                                              : 'PLUGIN_LBF_GENRE_APPLY'), $shown),
                type        => 'link',
                image       => MENU_APPLY,
                nextWindow  => 'parent',
                passthrough => [{}],
                url         => sub { $_[1]->({ items => [] }) },
            }, {
                name        => cstring($client, 'PLUGIN_LBF_GENRE_SELECT_ALL'),
                type        => 'link',
                image       => @$sel ? CHECK_OFF : CHECK_ON,   # ticked when no filter is set
                nextWindow  => 'refresh',
                passthrough => [{ prefix => $prefix, all => 1 }],
                url         => \&genreToggle,
            });

            # Families first (busiest first, then alphabetical), the catch-all last
            # so it can never head the list.
            my @fams = sort { $count{$b} <=> $count{$a} or $a cmp $b }
                       grep { $_ ne GENRE_NONE } keys %count;
            push @fams, GENRE_NONE if $count{ +GENRE_NONE };

            for my $f (@fams) {
                my $label = $f eq GENRE_NONE ? cstring($client, 'PLUGIN_LBF_GENRE_NONE') : $f;
                push @rows, {
                    name        => "$label (" . $count{$f} . ")",
                    type        => 'link',
                    image       => $on{$f} ? CHECK_ON : CHECK_OFF,
                    nextWindow  => 'refresh',
                    passthrough => [{ prefix => $prefix, genre => $f }],
                    url         => \&genreToggle,
                };
            }
            $cb->({ items => \@rows, cachetime => 0 });
        }, GENRE_WARM_MAX, peek => 1);
    });
}

# Immediate apply: flip the family in the pref and refresh the picker in place.
# Re-reads the LIVE pref rather than trusting a value captured at render time —
# the same rule as _sortToggle and _viewToggle.
sub genreToggle {
    my ($client, $cb, $args, $pass) = @_;
    my $prefix = (ref $pass eq 'HASH' && $pass->{prefix}) ? $pass->{prefix} : 'all';

    if (ref $pass eq 'HASH' && $pass->{all}) {
        $prefs->set("${prefix}_genres", []);        # clear the filter entirely
        $cb->({ items => [] });
        return;
    }

    my $g   = $pass->{genre} // '';
    my $sel = _selectedGenres($prefix);
    my @out = grep { $_ ne $g } @$sel;
    push @out, $g if @out == @$sel;                 # wasn't there -> turn it on
    $prefs->set("${prefix}_genres", \@out);
    $cb->({ items => [] });
}

# The single label a LIST row shows. Walks the release's genres strongest-first and
# returns the first FAMILY it can resolve — so a release tagged
# "instrumental, lo-fi hip hop" reads "Hip Hop", not "instrumental". Words that
# describe a treatment rather than a family (instrumental, lo-fi, acoustic …) are
# deliberately absent from the table precisely so they fall through like this.
# If nothing rolls up, the strongest genre is shown as-is — still better than the
# blank line these rows used to have.
use constant GENRE_SUBS_MAX => 2;   # sub-genres shown in brackets on a list row

sub _familyFor {
    my ($rel, $meta) = @_;
    # _genresFor owns the whole tier ladder now (album genres → artist genres →
    # the feed's inline release_tags → gated Last.fm), so there is exactly ONE
    # source of genres and exactly one producer of a row label. Appending a source
    # here instead was the 0.9.132 bug: it bypassed the rollup and printed three raw
    # sub-genres where the design calls for one family.
    my @g = _genresFor($rel, $meta);
    return () unless @g;

    my $family;
    for my $g (@g) {
        my $f = _genreFamily($g);
        if ($f) { $family = $f; last }
    }
    # Nothing rolled up — show the strongest single genre rather than a list, and
    # no brackets (there's no family for them to be sub-genres OF).
    return ($g[0]) unless defined $family;

    # Sub-genres for the brackets: the release's OTHER genres, strongest first.
    # Only the genre that merely RESTATES the family is dropped, so a row can't read
    # "Funk (funk)".
    #
    # These are deliberately NOT restricted to genres that roll up to the same
    # family. That was the first cut and it was wrong on the very case this feature
    # was asked for: "funk rock" and "funk soul" roll up to Rock and Soul under the
    # whole-word suffix rule, so a same-family filter emptied the brackets on
    # "funk, funk rock, funk soul" — the one release that prompted this. The
    # brackets are "what else this release is tagged", not a claim of descent.
    # A bracket entry must not be a MODIFIER — otherwise "instrumental" and "lo-fi"
    # walk straight back onto the row as "Hip Hop (instrumental, lo-fi hip hop)",
    # reintroducing exactly the noise the modifier rule exists to remove.
    #
    # It does NOT have to be a genre we have a family for. Requiring that was the
    # second wrong cut: "funk soul" isn't in MusicBrainz's vocabulary at all (it
    # reached us as a free tag on the release), so it was silently dropped from
    # "Funk (funk rock, funk soul)". Unknown genre = still worth showing; known
    # modifier = never worth showing. That's why the table ships modifiers with
    # family '-' rather than just omitting them.
    my $famKey = _genreKey($family);
    my (@subs, %seen);
    for my $g (@g) {
        next if _genreModifier($g);
        my $k = _genreKey($g);
        next if $k eq $famKey || $seen{$k}++;
        push @subs, $g;
        last if @subs >= GENRE_SUBS_MAX;
    }
    return ($family, @subs);
}

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
