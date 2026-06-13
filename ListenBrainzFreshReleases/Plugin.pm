package Plugins::ListenBrainzFreshReleases::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.listenbrainzfreshreleases',
    'defaultLevel' => 'INFO',
    'description'  => 'PLUGIN_LISTENBRAINZ_FRESH_RELEASES',
});

my $prefs = preferences('plugin.listenbrainzfreshreleases');

$prefs->init({
    # General
    username             => '',
    token                => '',
    days                 => 14,
    sort                 => 'release_date',

    # For You section
    foryou_albums        => 1,
    foryou_past          => 1,
    foryou_future        => 0,
    foryou_artwork_only  => 1,
    foryou_various       => 1,

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
    all_type_soundtrack  => 1,
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

    $class->SUPER::initPlugin(
        tag    => 'listenbrainzfreshreleases',
        feed   => \&Plugins::ListenBrainzFreshReleases::Browse::topLevel,
        is_app => 1,
        menu   => 'radios',
        weight => 10,
    );

    return;
}

sub getDisplayName { 'PLUGIN_LISTENBRAINZ_FRESH_RELEASES' }

sub playerMenu { undef }

1;
