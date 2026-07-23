package Plugins::ListenBrainzFreshReleases::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Timers;
use Slim::Music::Import;
use Slim::Utils::OSDetect;
use File::Spec;

# Background cache-warm timing: first run shortly after startup (so it doesn't
# compete with boot), then once a day. Daily is cheap because the playlist
# caches are keyed by last_modified — real work happens only when a new week's
# playlist appears.
use constant WARM_DELAY      => 60;          # seconds after startup
use constant WARM_INTERVAL   => 24 * 3600;   # daily
# While a library scan is running the local-library tier is incomplete, so a warm
# that ran then would miss every owned track and cache that all-streaming result
# for the resolved-playlist TTL (days) — and later warms skip an already-cached
# playlist, so it would stay wrong until the weekly mbid change. So defer the warm
# while scanning and re-check on this interval.
use constant WARM_SCAN_RETRY => 120;         # seconds between scan re-checks

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.listenbrainzfreshreleases',
    # WARN in production keeps server.log quiet (the INFO lines log every API
    # response code/length/URL and cache hit). Raise to INFO via Settings →
    # Logging when diagnosing.
    'defaultLevel' => 'WARN',
    'description'  => 'PLUGIN_LISTENBRAINZ_FRESH_RELEASES',
});

my $prefs = preferences('plugin.listenbrainzfreshreleases');

$prefs->init({
    # General
    username             => '',
    token                => '',
    lastfm_api_key       => '',
    muspy_userid         => '',
    muspy_future         => 1,
    muspy_future_months  => 12,
    days                 => 14,
    # Per-view content sort (release_date / artist / album), flipped in place by
    # the "Sorted by …" toggle in each view's Options section — not on the settings
    # page. Both are DURABLE, so the choice sticks across visits and restarts.
    # `foryou_sort` = New Releases for You; `all_sort` = All Releases (shared across
    # every week view). Replaced the old global `sort` pref in 0.9.97.
    foryou_sort          => 'release_date',
    all_sort             => 'release_date',
    play_via             => 1,
    # Master on/off for the whole "People You Follow" browse section (trending
    # tracks + both trending-albums lists + the Recommended list). Default ON
    # (preserves existing behaviour — the pref is new, so this default applies to
    # every install on update). When OFF the section, its warm pre-build and its
    # unmatched-debug entry are ALL skipped — no following/stats/feed calls, no
    # caching, no warming for it at all.
    people_follow        => 1,
    # People You Follow list ordering: 'date' (day dividers, newest first) or
    # 'recommender' (grouped by the follower who recommended each track). Flipped
    # in place by the inline toggle at the top of that list.
    follow_sort          => 'date',
    prefer_library       => 1,
    # MusicBrainz web-service base. Default is BLANK on purpose: blank lets
    # postinitPlugin auto-detect a same-host musicbrainz-docker mirror (and
    # _mbBase falls back to the public API when none is found). A non-blank
    # default would suppress both — autodetectMirror skips a configured base and
    # _mbBase never consults the auto-detected mirror. Point it at a local mirror
    # (e.g. http://your-server:5000/ws/2/) for fast, un-throttled lookups; a
    # mirror speaks the identical ws/2 API, so it's a pure host swap. (Cover art
    # still comes from the public Cover Art Archive.)
    mb_base_url          => '',
    # Opt-in dedicated warm/resolve debug log (lbf-debug.log beside server.log).
    # Off by default — turn on to track a match/caching issue, off again after.
    debug_log            => 0,

    # Artists the user has blocked: an arrayref of { mbid => <artist MBID or ''>,
    # name => <display name> }. Releases by any of these are hidden from every
    # feed (For You / All Releases + the home shelves) by Browse::_filterSection.
    # Built from the release detail page's "Block this artist" action; managed
    # (unblocked) on the settings page. There is no ListenBrainz API for this —
    # it is a purely local filter applied at render time.
    blocked_artists      => [],

    # Streaming-service search priority. Services are searched in ascending order
    # and the search stops at the first one with a match; 0 = never search it.
    svc_priority_qobuz    => 1,
    svc_priority_bandcamp => 2,
    svc_priority_tidal    => 3,
    svc_priority_deezer   => 4,
    svc_priority_spotify  => 5,

    # Don't Stop The Music propagators (Similar / Raw / Top). dstm_count = how many
    # recommended recordings to pull from ListenBrainz into the pool; dstm_batch =
    # how many resolved tracks to append per queue top-up. Track resolution reuses
    # prefer_library + svc_priority_* (library first, then streaming).
    dstm_count => 100,
    dstm_batch => 15,

    # For You section
    foryou_past             => 1,
    foryou_future           => 1,   # upcoming releases on by default (0.9.79) — new installs only; existing prefs win
    foryou_artwork_only     => 1,
    foryou_various          => 1,
    foryou_type_album       => 1,
    foryou_type_single      => 0,
    foryou_type_ep          => 0,
    foryou_type_broadcast   => 0,
    foryou_type_other       => 0,
    foryou_type_compilation => 1,
    foryou_type_soundtrack  => 0,
    foryou_type_live        => 0,
    foryou_type_remix       => 0,
    foryou_type_demo        => 0,

    # All Releases section
    all_past             => 1,
    all_future           => 0,
    all_artwork_only     => 1,
    all_various          => 1,
    all_type_album       => 1,
    all_type_single      => 0,
    all_type_ep          => 0,
    all_type_broadcast   => 0,
    all_type_other       => 0,
    all_type_compilation => 1,
    all_type_soundtrack  => 0,
    all_type_live        => 0,
    all_type_remix       => 0,
    all_type_demo        => 0,
});

sub initPlugin {
    my $class = shift;

    if (main::WEBUI) {
        require Plugins::ListenBrainzFreshReleases::Settings;
        Plugins::ListenBrainzFreshReleases::Settings->new();
    }

    require Plugins::ListenBrainzFreshReleases::Browse;
    require Plugins::ListenBrainzFreshReleases::API;

    eval {
        require Slim::Web::ImageProxy;
        if ( UNIVERSAL::can('Slim::Web::ImageProxy', 'getRightSize') ) {
            Slim::Web::ImageProxy->registerHandler(
                match => qr/coverartarchive\.org/,
                func  => sub {
                    my ($url, $spec) = @_;
                    my $size = Slim::Web::ImageProxy->getRightSize($spec, {
                        50  => '250',
                        100 => '250',
                        250 => '250',
                        500 => '500',
                    }) || '250';
                    $url =~ s|/front-\d+$|/front-$size|;
                    return $url;
                },
            );
            $log->info("Registered Cover Art Archive image proxy handler");
        }
    } if preferences('server')->get('useLocalImageproxy');

    # NB: OPMLBased ignores an icon => arg; the app/menu icon always comes from
    # install.xml <icon> (OPMLBased.pm uses _pluginDataFor('icon')). We point it
    # at ...Icon_svg.png: Material's "_svg.png" convention makes it load the
    # sibling ...Icon.svg and recolour it per theme (white on dark, black on
    # light). The SVG MUST use #000 (not #000000) — Material string-replaces
    # "#000", so #000000 would corrupt to an invalid colour and render blank.
    # Non-Material skins fall back to the real transparent PNG.
    $class->SUPER::initPlugin(
        tag    => 'listenbrainzfreshreleases',
        feed   => \&Plugins::ListenBrainzFreshReleases::Browse::topLevel,
        is_app => 1,
        menu   => 'radios',
        weight => 10,
    );

    return;
}

# Runs after all plugins have initialised, so Material Skin is available to
# check. Registers a home-page scrollable row for the For You feed, mirroring
# how Qobuz/Bandcamp do it.
sub postinitPlugin {
    my $class = shift;

    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')
      && Plugins::MaterialSkin::Plugin->can('registerHomeExtra') ) {
        eval {
            require Plugins::ListenBrainzFreshReleases::HomeExtras;
            Plugins::ListenBrainzFreshReleases::HomeExtras->initPlugin();
            $log->info("Registered Material Skin home extra (For You)");
            1;
        } or $log->error("Failed to register Material home extra: $@");
    }

    # Register the Don't Stop The Music propagators (Similar / Raw / Top). DSTM is
    # a core plugin (normally enabled); DSTM->register guards on registerHandler so
    # a disabled DSTM is a quiet no-op.
    eval {
        require Plugins::ListenBrainzFreshReleases::DSTM;
        Plugins::ListenBrainzFreshReleases::DSTM->register();
        1;
    } or $log->error("Failed to register DSTM propagators: $@");

    # Warm the Created-for-You caches (playlist list, per-track matches, grid
    # covers) shortly after startup, then daily — so the Playlists view and each
    # playlist open instantly and the tile artwork is pre-rendered. A daily tick
    # is cheap (caches keyed by last_modified; real work only when a new week's
    # playlist lands). First run is delayed so it doesn't compete with boot.
    Slim::Utils::Timers::setTimer(undef, time() + WARM_DELAY, \&_warmTick);

    # If no MusicBrainz base is configured, probe for a same-host mirror once so a
    # musicbrainz-docker instance on this machine is used with zero config. Async,
    # no-op when a base is set or a recent probe result is cached (see API).
    eval { Plugins::ListenBrainzFreshReleases::API->autodetectMirror(); 1 }
        or $log->error("Failed to auto-detect MusicBrainz mirror: $@");
}

# Run the warm, then re-arm for the next day. Deferred while a library scan is in
# progress (see WARM_SCAN_RETRY) so it never resolves against a half-scanned
# library and caches an all-streaming result for owned tracks.
sub _warmTick {
    if ( Slim::Music::Import->stillScanning() ) {
        dbg("warm: library scan in progress — deferring " . WARM_SCAN_RETRY . "s");
        Slim::Utils::Timers::setTimer(undef, time() + WARM_SCAN_RETRY, \&_warmTick);
        return;
    }

    eval {
        require Plugins::ListenBrainzFreshReleases::Browse;
        Plugins::ListenBrainzFreshReleases::Browse::warmCache();
        1;
    } or $log->error("Playlist warm failed: $@");

    Slim::Utils::Timers::setTimer(undef, time() + WARM_INTERVAL, \&_warmTick);
}

# ---------------------------------------------------------------------------
# Dedicated, opt-in debug log for warm/resolve tracking. Always mirrors to
# server.log at info; when the debug_log pref is on, ALSO appends a timestamped
# line to lbf-debug.log (beside server.log) so the warm/match timeline is easy
# to follow without wading through the rest of server.log. Size-capped (~1 MB,
# one .old rotation) so it can't grow unbounded. Fully eval-guarded — a logging
# failure never disrupts the caller.
# ---------------------------------------------------------------------------
my $DBG_FILE;   # memoised path

sub _dbgFile {
    return $DBG_FILE if defined $DBG_FILE;
    my $dir = eval { scalar Slim::Utils::OSDetect::dirsFor('log') };
    $dir = preferences('server')->get('cachedir') if !$dir || !-d $dir;
    $DBG_FILE = File::Spec->catfile($dir // '.', 'lbf-debug.log');
    return $DBG_FILE;
}

sub dbg {
    my $msg = shift;
    $log->info($msg);
    return unless $prefs->get('debug_log');
    eval {
        my $file = _dbgFile();
        rename($file, "$file.old") if (-s $file // 0) > 1_000_000;   # ~1 MB cap, keep one rotation
        open(my $fh, '>>:encoding(UTF-8)', $file) or die "open $file: $!";
        my @t = localtime(time);
        printf $fh "%04d-%02d-%02d %02d:%02d:%02d  %s\n",
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0], $msg;
        close $fh;
        1;
    } or $log->warn("debug-log write failed: $@");
}

sub getDisplayName { 'PLUGIN_LISTENBRAINZ_FRESH_RELEASES' }

sub playerMenu { undef }

1;
