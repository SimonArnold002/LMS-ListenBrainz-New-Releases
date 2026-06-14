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

# Maximum number of releases shown per page before a "Next page" link is added
use constant PAGE_SIZE => 50;

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

    my $secondary = $rel->{release_group_secondary_types} // $rel->{secondary_types} // [];
    if (ref $secondary eq 'ARRAY') {
        for my $value (@$secondary) {
            my $formatted = _formatTypeName($value);
            push @parts, $formatted if $formatted ne '';
        }
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
# Build OPML items from release array
# ---------------------------------------------------------------------------
sub _buildItems {
    my ($releases, $client) = @_;

    unless ($releases && scalar @$releases) {
        return [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }];
    }

    my $items = $prefs->get('group_by_artist')
        ? _buildGrouped($releases, $client)
        : [ map { _buildReleaseItem($_, $client) } @$releases ];

    return _paginate($items, $client, 0);
}

# ---------------------------------------------------------------------------
# Group releases under their artist (New Music Tracker style). Artists with a
# single release stay inline; artists with several collapse into one tappable
# entry that lists their releases. Artist order follows the chosen sort (first
# appearance), so e.g. a date sort keeps the freshest artists at the top.
# ---------------------------------------------------------------------------
sub _buildGrouped {
    my ($releases, $client) = @_;

    my @order;
    my %bucket;
    for my $rel (@$releases) {
        my $key = lc(_pickValue($rel, 'artist_credit_name', 'artist_name', 'artist'));
        push @order, $key unless exists $bucket{$key};
        push @{ $bucket{$key} }, $rel;
    }

    my @items;
    for my $key (@order) {
        my $rels = $bucket{$key};

        if (scalar @$rels == 1) {
            push @items, _buildReleaseItem($rels->[0], $client);
            next;
        }

        my $artist = _pickValue($rels->[0], 'artist_credit_name', 'artist_name', 'artist') // 'Unknown Artist';
        my $image  = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rels->[0]) // ICON;
        my $count  = scalar @$rels;

        push @items, {
            name  => "$artist  ($count)",
            type  => 'link',
            image => $image,
            url   => sub {
                my ($client, $callback) = @_;
                my $sub = [ map { _buildReleaseItem($_, $client) } @$rels ];
                $callback->({ items => _paginate($sub, $client, 0) });
            },
        };
    }

    return \@items;
}

# ---------------------------------------------------------------------------
# Window an already-built item list into pages of PAGE_SIZE, appending a
# "Next page (n/total)" link when more remain. The list is captured in the
# closure so paging never re-hits the API; LMS's back button goes back a page.
# ---------------------------------------------------------------------------
sub _paginate {
    my ($items, $client, $offset) = @_;
    $offset //= 0;

    my $total = scalar @$items;
    return $items if $total <= PAGE_SIZE && $offset == 0;

    my $last = $offset + PAGE_SIZE - 1;
    $last = $total - 1 if $last > $total - 1;

    my @page = @{$items}[$offset .. $last];

    if ($last < $total - 1) {
        my $next  = $offset + PAGE_SIZE;
        my $page  = int($next / PAGE_SIZE) + 1;
        my $pages = int(($total + PAGE_SIZE - 1) / PAGE_SIZE);
        push @page, {
            name  => cstring($client, 'PLUGIN_LBF_NEXT_PAGE') . " ($page/$pages)",
            type  => 'link',
            image => ICON,
            url   => sub {
                my ($client, $callback) = @_;
                $callback->({ items => _paginate($items, $client, $next) });
            },
        };
    }

    return \@page;
}

# ---------------------------------------------------------------------------
# Build a single OPML item from one release
# ---------------------------------------------------------------------------
sub _buildReleaseItem {
    my ($rel, $client) = @_;

    my $artist     = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') // 'Unknown Artist';
    my $album      = _pickValue($rel, 'release_name', 'title', 'name') // 'Unknown Album';
    my $date       = $rel->{release_date} // '';
    my $type       = _displayType($rel);
    my $sec_types  = $rel->{release_group_secondary_types} // $rel->{secondary_types} // [];
    my $mbid       = $rel->{release_mbid} // '';
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
        $item->{type} = 'link';
        $item->{url}  = sub {
            my ($client, $callback) = @_;
            _releaseDetail($rel, $client, $callback);
        };
    }

    return $item;
}

# ---------------------------------------------------------------------------
# Release detail page — base metadata, then genres + tracklist fetched from
# MusicBrainz on demand. Falls back to just the metadata if the lookup fails.
# ---------------------------------------------------------------------------
sub _releaseDetail {
    my ($rel, $client, $callback) = @_;

    my @base = _detailMeta($rel, $client);
    my $mbid = $rel->{release_mbid} // '';

    unless ($mbid) {
        $callback->({ items => \@base });
        return;
    }

    Plugins::ListenBrainzFreshReleases::API->getReleaseDetails(
        $mbid,
        sub {
            my $info = shift;
            my @items = @base;

            my @genres = @{ $info->{genres} || [] };
            push @items, {
                name => cstring($client, 'PLUGIN_LBF_GENRES') . ': ' . join(', ', @genres),
                type => 'text',
            } if @genres;

            my @media = grep { $_->{tracks} && scalar @{ $_->{tracks} } } @{ $info->{media} || [] };
            if (@media) {
                push @items, { name => cstring($client, 'PLUGIN_LBF_TRACKLIST'), type => 'text' };
                my $multi = scalar @media > 1;
                for my $m (@media) {
                    if ($multi) {
                        my $hdr = cstring($client, 'PLUGIN_LBF_DISC') . ' ' . ($m->{position} // '');
                        $hdr .= " ($m->{format})" if $m->{format};
                        push @items, { name => $hdr, type => 'text' };
                    }
                    for my $t (@{ $m->{tracks} }) {
                        my $line = ($t->{position} ? "$t->{position}. " : '') . ($t->{title} // '');
                        $line .= '  (' . _fmtDuration($t->{length}) . ')' if $t->{length};
                        push @items, { name => $line, type => 'text' };
                    }
                }
            }

            $callback->({ items => \@items });
        },
        sub {
            $log->info("Release detail lookup failed: " . (shift // ''));
            $callback->({ items => \@base });
        },
    );
}

# Base metadata lines shown at the top of every release detail page
sub _detailMeta {
    my ($rel, $client) = @_;

    my $artist  = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') // 'Unknown Artist';
    my $album   = _pickValue($rel, 'release_name', 'title', 'name') // 'Unknown Album';
    my $date    = $rel->{release_date} // '';
    my $type    = _displayType($rel);
    my $sec     = $rel->{release_group_secondary_types} // $rel->{secondary_types} // [];
    my $sec_str = (ref $sec eq 'ARRAY' && scalar @$sec) ? join(', ', @$sec) : '';
    my $mbid    = $rel->{release_mbid} // '';

    my @detail = (
        { name => cstring($client, 'PLUGIN_LBF_ARTIST') . ": $artist", type => 'text' },
        { name => cstring($client, 'PLUGIN_LBF_ALBUM')  . ": $album",  type => 'text' },
        { name => cstring($client, 'PLUGIN_LBF_DATE')   . ": $date",   type => 'text' },
        { name => cstring($client, 'PLUGIN_LBF_TYPE')   . ": $type",   type => 'text' },
    );
    push @detail, { name => cstring($client, 'PLUGIN_LBF_SEC_TYPES') . ": $sec_str", type => 'text' }
        if $sec_str;

    # Folksonomy tags ride along in the fresh_releases payload (no extra call).
    # Coverage is low (~9%) and noisy, so only show when present after cleanup.
    my @tags = _releaseTags($rel);
    push @detail, { name => cstring($client, 'PLUGIN_LBF_TAGS') . ': ' . join(', ', @tags), type => 'text' }
        if @tags;

    push @detail, { name => "MusicBrainz: https://musicbrainz.org/release/$mbid", type => 'text' }
        if $mbid;

    return @detail;
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
