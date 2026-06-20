package Plugins::ListenBrainzFreshReleases::HomeExtras;

# Material Skin home-page scrollable rows. Three shelves, each a separate
# HomeExtraBase subclass (own tag → own CLI dispatch → own feed; separate
# packages avoid any shared per-class feed state):
#   - New Releases for You  (LBFForYou      → Browse::homeForYou)
#   - Playlists             (LBFPlaylists   → Browse::homePlaylists)
#   - All Releases          (LBFAllReleases → Browse::homeAllReleases)
# Each feed returns a FLAT card list that does not vary by request quantity — the
# 0.6.11 rule that keeps deep home-shelf playback resolving the right item.

use strict;
use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::ListenBrainzFreshReleases::Browse;

use constant ICON => 'plugins/ListenBrainzFreshReleases/html/images/ListenBrainzFreshReleasesIcon_svg.png';

sub initPlugin {
    my ($class) = @_;

    # New Releases for You
    $class->SUPER::initPlugin(
        feed  => \&feed,
        tag   => 'LBFForYou',
        extra => { title => 'PLUGIN_LBF_FOR_YOU', icon => ICON, needsPlayer => 0 },
    );

    # Playlists + All Releases shelves (own packages, below)
    Plugins::ListenBrainzFreshReleases::HomePlaylists->initPlugin();
    Plugins::ListenBrainzFreshReleases::HomeAllReleases->initPlugin();
}

sub feed {
    my ($client, $cb, $args) = @_;
    Plugins::ListenBrainzFreshReleases::Browse::homeForYou($client, $cb, $args);
}


package Plugins::ListenBrainzFreshReleases::HomePlaylists;

use strict;
use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::ListenBrainzFreshReleases::Browse;

sub initPlugin {
    my ($class) = @_;
    $class->SUPER::initPlugin(
        feed  => \&feed,
        tag   => 'LBFPlaylists',
        extra => {
            title       => 'PLUGIN_LBF_PLAYLISTS',
            icon        => Plugins::ListenBrainzFreshReleases::HomeExtras::ICON,
            needsPlayer => 0,
        },
    );
}

sub feed {
    my ($client, $cb, $args) = @_;
    Plugins::ListenBrainzFreshReleases::Browse::homePlaylists($client, $cb, $args);
}


package Plugins::ListenBrainzFreshReleases::HomeAllReleases;

use strict;
use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::ListenBrainzFreshReleases::Browse;

sub initPlugin {
    my ($class) = @_;
    $class->SUPER::initPlugin(
        feed  => \&feed,
        tag   => 'LBFAllReleases',
        extra => {
            title       => 'PLUGIN_LBF_ALL_RELEASES',
            icon        => Plugins::ListenBrainzFreshReleases::HomeExtras::ICON,
            needsPlayer => 0,
        },
    );
}

sub feed {
    my ($client, $cb, $args) = @_;
    Plugins::ListenBrainzFreshReleases::Browse::homeAllReleases($client, $cb, $args);
}

1;
