package Plugins::ListenBrainzFreshReleases::HomeExtras;

# Material Skin home-page scrollable row for the "Newly Released for You" feed.
# Subclasses Material's HomeExtraBase (only loaded/registered when Material is
# present — see Plugin::postinitPlugin).

use strict;
use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::ListenBrainzFreshReleases::Browse;

sub initPlugin {
    my ($class) = @_;

    $class->SUPER::initPlugin(
        feed  => \&feed,
        tag   => 'LBFForYou',
        extra => {
            title       => 'PLUGIN_LBF_FOR_YOU',
            # Material recolours the home-row icon, so use the _svg.png form (as
            # the browse menu does) rather than the install.xml colour tile,
            # which renders blank in the home row.
            icon        => 'plugins/ListenBrainzFreshReleases/html/images/ListenBrainzFreshReleasesIcon_svg.png',
            needsPlayer => 0,
        },
    );
}

sub feed {
    my ($client, $cb, $args) = @_;
    Plugins::ListenBrainzFreshReleases::Browse::homeForYou($client, $cb);
}

1;
