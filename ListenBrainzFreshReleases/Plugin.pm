package Plugins::ListenBrainzFreshReleases::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Timers;

# Background cache-warm timing: first run shortly after startup (so it doesn't
# compete with boot), then once a day. Daily is cheap because the playlist
# caches are keyed by last_modified — real work happens only when a new week's
# playlist appears.
use constant WARM_DELAY    => 60;          # seconds after startup
use constant WARM_INTERVAL => 24 * 3600;   # daily

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
    days                 => 14,
    sort                 => 'release_date',
    group_by_artist      => 1,
    week_dividers        => 1,
    play_via             => 1,
    prefer_library       => 1,

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

    # Don't Stop The Music propagators (Similar / Raw / Top). dstm_count = how many
    # recommended recordings to pull from ListenBrainz into the pool; dstm_batch =
    # how many resolved tracks to append per queue top-up. Track resolution reuses
    # prefer_library + svc_priority_* (library first, then streaming).
    dstm_count => 100,
    dstm_batch => 15,

    # For You section
    foryou_past             => 1,
    foryou_future           => 0,
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
}

# Run the warm, then re-arm for the next day.
sub _warmTick {
    eval {
        require Plugins::ListenBrainzFreshReleases::Browse;
        Plugins::ListenBrainzFreshReleases::Browse::warmCache();
        1;
    } or $log->error("Playlist warm failed: $@");

    Slim::Utils::Timers::setTimer(undef, time() + WARM_INTERVAL, \&_warmTick);
}

sub getDisplayName { 'PLUGIN_LISTENBRAINZ_FRESH_RELEASES' }

sub playerMenu { undef }

1;
