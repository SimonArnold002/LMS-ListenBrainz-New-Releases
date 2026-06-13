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
    username => '',
    token    => '',
    days     => 14,
    sort     => 'release_date',
    past     => 1,
    future   => 0,
});

sub initPlugin {
    my $class = shift;

    if (main::WEBUI) {
        require Plugins::ListenBrainzFreshReleases::Settings;
        Plugins::ListenBrainzFreshReleases::Settings->new();
    }

    require Plugins::ListenBrainzFreshReleases::Browse;
    require Plugins::ListenBrainzFreshReleases::API;

    # Register Cover Art Archive URLs with LMS image proxy cache
    # LMS will fetch, cache and resize the image locally — no repeated external calls
    eval {
        require Slim::Web::ImageProxy;
        if ( UNIVERSAL::can('Slim::Web::ImageProxy', 'getRightSize') ) {
            Slim::Web::ImageProxy->registerHandler(
                match => qr/coverartarchive\.org/,
                func  => sub {
                    my ($url, $spec) = @_;
                    # Map requested size to CAA size suffixes
                    my $size = Slim::Web::ImageProxy->getRightSize($spec, {
                        50  => '250',
                        100 => '250',
                        250 => '250',
                        500 => '500',
                    }) || '250';
                    # Replace the size suffix in the URL
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
