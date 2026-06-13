package Plugins::ListenBrainzFreshReleases::Browse;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring string);

use Plugins::ListenBrainzFreshReleases::API;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');

# Primary release types (MusicBrainz)
my @PRIMARY_TYPES = ('Album', 'Single', 'EP', 'Broadcast', 'Other');

# Secondary release types (MusicBrainz) — used for display in item detail
my @SECONDARY_TYPES = ('Compilation', 'Soundtrack', 'Spokenword', 'Interview',
                       'Audiobook', 'Audio drama', 'Live', 'Remix',
                       'Mixtape/Street', 'Demo');

# Material Skin release type icon mapping
my %TYPE_ICON = (
    'Album'        => 'material/html/images/release-album.svg',
    'Single'       => 'material/html/images/release-single.svg',
    'EP'           => 'material/html/images/release-ep.svg',
    'Broadcast'    => 'material/html/images/release-broadcast.svg',
    'Other'        => 'material/html/images/release.svg',
    # Secondary types
    'Compilation'  => 'material/html/images/release-bestof.svg',
    'Soundtrack'   => 'material/html/images/release-soundtrack.svg',
    'Spokenword'   => 'material/html/images/release-spokenword.svg',
    'Interview'    => 'material/html/images/release-interview.svg',
    'Audiobook'    => 'material/html/images/release-audiobook.svg',
    'Audio drama'  => 'material/html/images/release-audiodrama.svg',
    'Live'         => 'material/html/images/release-live.svg',
    'Remix'        => 'material/html/images/release-remix.svg',
    'Mixtape/Street' => 'material/html/images/release-mixtape.svg',
    'Demo'         => 'material/html/images/release-demo.svg',
);

use constant ICON => 'plugins/ListenBrainzFreshReleases/html/images/ListenBrainzFreshReleasesIcon_svg.png';

# ---------------------------------------------------------------------------
# Top-level feed
# ---------------------------------------------------------------------------
sub topLevel {
    my ($client, $callback, $args) = @_;

    my $username = $prefs->get('username') // '';
    my $token    = $prefs->get('token')    // '';

    my @items;

    if ($username && $token) {
        push @items, {
            name        => cstring($client, 'PLUGIN_LBF_FOR_YOU'),
            type        => 'link',
            url         => \&forYouMenu,
            passthrough => [{}],
            image       => ICON,
        };
    } else {
        push @items, {
            name  => cstring($client, 'PLUGIN_LBF_SETUP_REQUIRED'),
            type  => 'text',
            image => ICON,
        };
    }

    push @items, {
        name        => cstring($client, 'PLUGIN_LBF_ALL_RELEASES'),
        type        => 'link',
        url         => \&allMenu,
        passthrough => [{}],
        image       => ICON,
    };

    $callback->({ items => \@items });
}

# ---------------------------------------------------------------------------
# For You menu
# ---------------------------------------------------------------------------
sub forYouMenu {
    my ($client, $callback, $args, $passDict) = @_;
    _browseMenu($client, $callback, $passDict, 'foryou');
}

# ---------------------------------------------------------------------------
# All Releases menu
# ---------------------------------------------------------------------------
sub allMenu {
    my ($client, $callback, $args, $passDict) = @_;
    _browseMenu($client, $callback, $passDict, 'all');
}

# ---------------------------------------------------------------------------
# Shared browse menu with sort, filter, and release type options
# ---------------------------------------------------------------------------
sub _browseMenu {
    my ($client, $callback, $passDict, $mode) = @_;

    my $sort   = $passDict->{sort} // $prefs->get('sort') // 'release_date';
    my $past   = $prefs->get('past')   // 1;
    my $future = $prefs->get('future') // 1;

    my $fetchSub = $mode eq 'foryou' ? \&fetchForYou : \&fetchAll;

    my @items = (
        {
            name        => cstring($client, 'PLUGIN_LBF_SHOW_ALL'),
            type        => 'link',
            url         => $fetchSub,
            passthrough => [{ sort => $sort, past => $past, future => $future }],
            image       => ICON,
        },
        # Browse by type — groups releases under Album, EP, Single etc
        {
            name        => cstring($client, 'PLUGIN_LBF_BROWSE_BY_TYPE'),
            type        => 'link',
            url         => $mode eq 'foryou' ? \&browseByTypeForYou : \&browseByTypeAll,
            passthrough => [{ sort => $sort, past => $past, future => $future }],
            image       => ICON,
        },
        # Sort sub-menu
        {
            name  => cstring($client, 'PLUGIN_LBF_SORT_BY'),
            type  => 'link',
            image => ICON,
            url   => sub {
                my ($client, $callback, $args, $pd) = @_;
                my $activesort = $pd->{sort} // $sort;
                my @sitems = map {
                    my ($key, $strkey) = @$_;
                    my $mark = ($key eq $activesort) ? ' \x{2713}' : '';
                    {
                        name        => cstring($client, $strkey) . $mark,
                        type        => 'link',
                        url         => $fetchSub,
                        passthrough => [{ sort => $key, past => $past, future => $future }],
                        image       => ICON,
                    }
                } (
                    ['release_date',       'PLUGIN_LBF_SORT_DATE'  ],
                    ['artist_credit_name', 'PLUGIN_LBF_SORT_ARTIST'],
                    ['release_name',       'PLUGIN_LBF_SORT_ALBUM' ],
                );
                $callback->({ items => \@sitems });
            },
            passthrough => [{ sort => $sort }],
        },
    );

    $callback->({ items => \@items });
}

# ---------------------------------------------------------------------------
# Browse by Type — For You
# ---------------------------------------------------------------------------
sub browseByTypeForYou {
    my ($client, $callback, $args, $passDict) = @_;
    _browseByType($client, $callback, $passDict, 'foryou');
}

# ---------------------------------------------------------------------------
# Browse by Type — All Releases
# ---------------------------------------------------------------------------
sub browseByTypeAll {
    my ($client, $callback, $args, $passDict) = @_;
    _browseByType($client, $callback, $passDict, 'all');
}

# ---------------------------------------------------------------------------
# Fetch all releases then group by release type as top-level entries
# ---------------------------------------------------------------------------
sub _browseByType {
    my ($client, $callback, $passDict, $mode) = @_;

    my $sort   = $passDict->{sort}   // $prefs->get('sort') // 'release_date';
    my $past   = $prefs->get('past')   // 1;
    my $future = $prefs->get('future') // 1;

    my $onDone = sub {
        my $releases = shift;

        unless ($releases && scalar @$releases) {
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }] });
            return;
        }

        # Group releases by type
        my %grouped;
        for my $rel (@$releases) {
            my $type = $rel->{release_group_primary_type} // 'Other';
            push @{ $grouped{$type} }, $rel;
        }

        # Build menu — known primary types first in order, then any others
        my @order = @PRIMARY_TYPES;
        my %seen;
        my @items;

        for my $type (@order) {
            next unless $grouped{$type};
            $seen{$type} = 1;
            my $count = scalar @{ $grouped{$type} };
            my $typeReleases = $grouped{$type};
            my $typeIcon = $TYPE_ICON{$type} // ICON;
            push @items, {
                name  => "$type ($count)",
                type  => 'link',
                image => $typeIcon,
                url   => sub {
                    my ($client, $callback) = @_;
                    $callback->({ items => _buildItems($typeReleases, $client) });
                },
            };
        }

        # Any unexpected types the API returns
        for my $type (sort keys %grouped) {
            next if $seen{$type};
            my $count = scalar @{ $grouped{$type} };
            my $typeReleases = $grouped{$type};
            my $typeIcon = $TYPE_ICON{$type} // ICON;
            push @items, {
                name  => "$type ($count)",
                type  => 'link',
                image => $typeIcon,
                url   => sub {
                    my ($client, $callback) = @_;
                    $callback->({ items => _buildItems($typeReleases, $client) });
                },
            };
        }

        $callback->({ items => \@items });
    };

    my $onError = sub {
        $log->error("Browse by type fetch error: " . (shift // ''));
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
    };

    if ($mode eq 'foryou') {
        Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
            sort => $sort, past => $past, future => $future,
            days => $prefs->get('days') // 14,
            onDone => $onDone, onError => $onError,
        );
    } else {
        Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
            sort => $sort, past => $past, future => $future,
            days => $prefs->get('days') // 14,
            onDone => $onDone, onError => $onError,
        );
    }
}

# ---------------------------------------------------------------------------
# Fetch personalised releases
# ---------------------------------------------------------------------------
sub fetchForYou {
    my ($client, $callback, $args, $passDict) = @_;

    my $sort   = $passDict->{sort} // $prefs->get('sort') // 'release_date';
    my $past   = $prefs->get('past')   // 1;
    my $future = $prefs->get('future') // 1;

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => $sort,
        past    => $past,
        future  => $future,
        days    => $prefs->get('days') // 14,
        onDone  => sub { $callback->({ items => _buildItems(shift, $client) }) },
        onError => sub {
            $log->error("For You fetch error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        },
    );
}

# ---------------------------------------------------------------------------
# Fetch global releases
# ---------------------------------------------------------------------------
sub fetchAll {
    my ($client, $callback, $args, $passDict) = @_;

    my $sort   = $passDict->{sort} // $prefs->get('sort') // 'release_date';
    my $past   = $prefs->get('past')   // 1;
    my $future = $prefs->get('future') // 1;

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
        sort    => $sort,
        past    => $past,
        future  => $future,
        days    => $prefs->get('days') // 14,
        onDone  => sub { $callback->({ items => _buildItems(shift, $client) }) },
        onError => sub {
            $log->error("All releases fetch error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        },
    );
}

# ---------------------------------------------------------------------------
# Build OPML items from release array
# ---------------------------------------------------------------------------
sub _buildItems {
    my ($releases, $client) = @_;

    unless ($releases && scalar @$releases) {
        return [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }];
    }

    my @items;

    for my $rel (@$releases) {
        my $artist     = $rel->{artist_credit_name}           // 'Unknown Artist';
        my $album      = $rel->{release_name}                 // 'Unknown Album';
        my $date       = $rel->{release_date}                 // '';
        my $type       = $rel->{release_group_primary_type}   // '';
        my $sec_types  = $rel->{release_group_secondary_types} // [];
        my $mbid       = $rel->{release_mbid}                 // '';
        my $conf       = $rel->{confidence};

        # Skip releases without artwork
        my $image = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel);
        next unless $image;

        my $name = "$artist \x{2013} $album";
        $name .= "  [$date]" if $date;

        # line2: primary type + secondary types + confidence stars
        my $line2 = $type;
        if (ref $sec_types eq 'ARRAY' && scalar @$sec_types) {
            $line2 .= ' / ' . join(', ', @$sec_types);
        }
        if (defined $conf) {
            my $stars = $conf >= 3 ? "\x{2605}\x{2605}\x{2605}"
                      : $conf == 2 ? "\x{2605}\x{2605}"
                      :              "\x{2605}";
            $line2 .= "  $stars";
        }

        my $item = {
            name  => $name,
            line2 => $line2,
            type  => 'text',
            image => $image,
        };

        if ($mbid) {
            my $sec_str = (ref $sec_types eq 'ARRAY' && scalar @$sec_types)
                        ? join(', ', @$sec_types) : '';
            $item->{type} = 'link';
            $item->{url}  = sub {
                my ($client, $callback) = @_;
                my @detail = (
                    { name => cstring($client, 'PLUGIN_LBF_ARTIST') . ": $artist", type => 'text' },
                    { name => cstring($client, 'PLUGIN_LBF_ALBUM')  . ": $album",  type => 'text' },
                    { name => cstring($client, 'PLUGIN_LBF_DATE')   . ": $date",   type => 'text' },
                    { name => cstring($client, 'PLUGIN_LBF_TYPE')   . ": $type",   type => 'text' },
                );
                push @detail, { name => cstring($client, 'PLUGIN_LBF_SEC_TYPES') . ": $sec_str", type => 'text' }
                    if $sec_str;
                push @detail, { name => "MusicBrainz: https://musicbrainz.org/release/$mbid", type => 'text' };
                $callback->({ items => \@detail });
            };
        }

        push @items, $item;
    }

    return \@items;
}

1;