package Plugins::ListenBrainzFreshReleases::Browse;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring string);

use Plugins::ListenBrainzFreshReleases::API;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');

use constant ICON => 'plugins/ListenBrainzFreshReleases/html/images/ListenBrainzFreshReleasesIcon_svg.png';

# Various Artists MBID — used to detect VA releases
use constant VA_MBID => '89ad4ac3-39f7-470e-963a-56509c546377';

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
            url         => \&fetchForYou,
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
        url         => \&fetchAll,
        passthrough => [{}],
        image       => ICON,
    };

    $callback->({ items => \@items });
}

# ---------------------------------------------------------------------------
# Fetch For You — applies For You prefs
# ---------------------------------------------------------------------------
sub fetchForYou {
    my ($client, $callback, $args, $passDict) = @_;

    my $sort   = $prefs->get('sort')          // 'release_date';
    my $past   = $prefs->get('foryou_past')   // 1;
    my $future = $prefs->get('foryou_future') // 0;

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => $sort,
        past    => $past,
        future  => $future,
        days    => $prefs->get('days') // 14,
        onDone  => sub {
            my $releases = _filterForYou(shift);
            $callback->({ items => _buildItems($releases, $client) });
        },
        onError => sub {
            $log->error("For You fetch error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        },
    );
}

# ---------------------------------------------------------------------------
# Fetch All Releases — applies All Releases prefs
# ---------------------------------------------------------------------------
sub fetchAll {
    my ($client, $callback, $args, $passDict) = @_;

    my $sort   = $prefs->get('sort')       // 'release_date';
    my $past   = $prefs->get('all_past')   // 1;
    my $future = $prefs->get('all_future') // 0;

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesAll(
        sort    => $sort,
        past    => $past,
        future  => $future,
        days    => $prefs->get('days') // 14,
        onDone  => sub {
            my $releases = _filterAll(shift);
            $callback->({ items => _buildItems($releases, $client) });
        },
        onError => sub {
            $log->error("All releases fetch error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        },
    );
}

# ---------------------------------------------------------------------------
# Filter for For You section
# ---------------------------------------------------------------------------
sub _filterForYou {
    my $releases = shift // [];

    my $albums       = $prefs->get('foryou_albums')       // 1;
    my $artwork_only = $prefs->get('foryou_artwork_only') // 1;
    my $various      = $prefs->get('foryou_various')      // 1;

    my @out;
    for my $rel (@$releases) {
        my $type = $rel->{release_group_primary_type} // '';

        # Albums-only filter: if Show Albums is checked, ONLY allow albums
        if ($albums) {
            next unless lc($type) eq 'album';
        }

        # Various artists filter
        if (!$various) {
            next if _isVariousArtists($rel);
        }

        # Artwork filter
        if ($artwork_only) {
            next unless Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel);
        }

        push @out, $rel;
    }

    return \@out;
}

# ---------------------------------------------------------------------------
# Filter for All Releases section
# ---------------------------------------------------------------------------
sub _filterAll {
    my $releases = shift // [];

    my $artwork_only = $prefs->get('all_artwork_only') // 1;
    my $various      = $prefs->get('all_various')      // 1;

    # Build set of allowed types from prefs
    my %allowed;
    $allowed{'album'}       = 1 if $prefs->get('all_type_album');
    $allowed{'single'}      = 1 if $prefs->get('all_type_single');
    $allowed{'ep'}          = 1 if $prefs->get('all_type_ep');
    $allowed{'broadcast'}   = 1 if $prefs->get('all_type_broadcast');
    $allowed{'other'}       = 1 if $prefs->get('all_type_other');
    $allowed{'compilation'} = 1 if $prefs->get('all_type_compilation');
    $allowed{'soundtrack'}  = 1 if $prefs->get('all_type_soundtrack');
    $allowed{'live'}        = 1 if $prefs->get('all_type_live');
    $allowed{'remix'}       = 1 if $prefs->get('all_type_remix');
    $allowed{'demo'}        = 1 if $prefs->get('all_type_demo');

    # If nothing selected, allow everything
    my $any_selected = scalar keys %allowed;

    my @out;
    for my $rel (@$releases) {
        my $primary = lc($rel->{release_group_primary_type} // '');
        my $sec_types = $rel->{release_group_secondary_types} // [];

        # Type filter — match either primary or any secondary type
        if ($any_selected) {
            my $match = $allowed{$primary} ? 1 : 0;
            if (!$match && ref $sec_types eq 'ARRAY') {
                for my $st (@$sec_types) {
                    if ($allowed{ lc($st) }) { $match = 1; last; }
                }
            }
            next unless $match;
        }

        # Various artists filter
        if (!$various) {
            next if _isVariousArtists($rel);
        }

        # Artwork filter
        if ($artwork_only) {
            next unless Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel);
        }

        push @out, $rel;
    }

    return \@out;
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
# Build OPML items from release array
# ---------------------------------------------------------------------------
sub _buildItems {
    my ($releases, $client) = @_;

    unless ($releases && scalar @$releases) {
        return [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }];
    }

    my @items;

    for my $rel (@$releases) {
        my $artist     = $rel->{artist_credit_name}             // 'Unknown Artist';
        my $album      = $rel->{release_name}                   // 'Unknown Album';
        my $date       = $rel->{release_date}                   // '';
        my $type       = $rel->{release_group_primary_type}     // '';
        my $sec_types  = $rel->{release_group_secondary_types}  // [];
        my $mbid       = $rel->{release_mbid}                   // '';
        my $conf       = $rel->{confidence};

        my $name = "$artist \x{2013} $album";
        $name .= "  [$date]" if $date;

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

        my $image = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel) // ICON;

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
