package Plugins::ListenBrainzFreshReleases::Browse;

use strict;
use warnings;

use Time::Local ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Utils::Timers;
use Slim::Utils::Strings qw(cstring string);

use Plugins::ListenBrainzFreshReleases::API;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');
my $cache = Slim::Utils::Cache->new();

# How long to remember a streaming-match result before searching again.
# A found match rarely changes (albums don't vanish) → keep a week. A "no match"
# on a brand-new release is likely to change soon (it may land on the service in
# a few days) → recheck daily.
use constant STREAM_FOUND_TTL   => 7 * 86400;
use constant STREAM_NOMATCH_TTL => 1 * 86400;

# Safety net (seconds): if a streaming/MusicBrainz callback never fires (network
# hang, partial failure), render the detail page anyway rather than hang.
use constant DETAIL_TIMEOUT => 15;

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

    push @items, {
        name    => cstring($client, 'PLUGIN_LBF_SETTINGS'),
        type    => 'link',
        weblink => '/plugins/ListenBrainzFreshReleases/settings.html',
        image   => ICON,
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
            my $releases = _sortReleases(_filterForYou(shift));
            $callback->({ items => _buildItems($releases, $client) });
        },
        onError => sub {
            $log->error("For You fetch error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        },
    );
}

# ---------------------------------------------------------------------------
# Flat For You feed for the Material Skin home-page scrollable row. Same
# filters/sort as the menu, but a flat, capped list of release cards (no weekly
# dividers / artist grouping — those don't suit a carousel).
# ---------------------------------------------------------------------------
sub homeForYou {
    my ($client, $cb) = @_;

    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => $prefs->get('sort')          // 'release_date',
        past    => $prefs->get('foryou_past')   // 1,
        future  => $prefs->get('foryou_future') // 0,
        days    => $prefs->get('days')          // 14,
        onDone  => sub {
            my $releases = _sortReleases(_filterForYou(shift));
            $releases = [ @{$releases}[0 .. 49] ] if @$releases > 50;
            $cb->({ items => [ map { _buildReleaseItem($_, $client) } @$releases ] });
        },
        onError => sub {
            $log->error("Home For You fetch error: " . (shift // ''));
            $cb->({ items => [] });
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
            my $releases = _sortReleases(_filterAll(shift));
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
# Sort releases by the configured order. Release date is newest-first and
# confidence highest-first; artist/album are A–Z. (The API's own ordering is
# unreliable — e.g. date comes back oldest-first — so we sort here.)
# ---------------------------------------------------------------------------
sub _sortReleases {
    my ($releases) = @_;
    return $releases unless ref $releases eq 'ARRAY';

    my $sort = $prefs->get('sort') // 'release_date';

    if ($sort eq 'artist_credit_name') {
        return [ sort { lc($a->{artist_credit_name} // '') cmp lc($b->{artist_credit_name} // '') } @$releases ];
    }
    elsif ($sort eq 'release_name') {
        return [ sort { lc($a->{release_name} // '') cmp lc($b->{release_name} // '') } @$releases ];
    }
    elsif ($sort eq 'confidence') {
        return [ sort { ($b->{confidence} // 0) <=> ($a->{confidence} // 0) } @$releases ];
    }

    # default: release_date, newest first
    return [ sort { ($b->{release_date} // '') cmp ($a->{release_date} // '') } @$releases ];
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

    my $sort = $prefs->get('sort') // 'release_date';

    # Return the whole (already filtered + sorted) list as a single level and let
    # LMS/Material window it natively — so Material's in-list filter spans every
    # item, not just one page, and we get the native scroll/prev-next pager.
    if ($prefs->get('week_dividers') && $sort eq 'release_date') {
        # weekly view takes precedence for the date sort (it's the chronological read)
        return _buildWeekly($releases, $client);
    }
    elsif ($prefs->get('group_by_artist')) {
        return _buildGrouped($releases, $client);
    }

    return [ map { _buildReleaseItem($_, $client) } @$releases ];
}

# ---------------------------------------------------------------------------
# Flat date-sorted list with a divider row at the start of each week, so the
# chronological feed is easier to scan. Assumes releases are already sorted
# newest-first; weeks run Monday–Sunday.
# ---------------------------------------------------------------------------
sub _buildWeekly {
    my ($releases, $client) = @_;

    my @items;
    my $curWeek = "\0";   # sentinel that no real week-start can equal

    for my $rel (@$releases) {
        my $ws = _weekStart($rel->{release_date} // '');
        if ($ws ne $curWeek) {
            $curWeek = $ws;
            push @items, { name => _weekLabel($client, $ws), type => 'text' };
        }
        push @items, _buildReleaseItem($rel, $client);
    }

    return \@items;
}

# Monday (YYYY-MM-DD) of the week containing $date, or '' if unparseable.
sub _weekStart {
    my ($date) = @_;
    return '' unless $date && $date =~ /^(\d{4})-(\d{2})-(\d{2})/;

    my $epoch = eval { Time::Local::timegm(0, 0, 12, $3, $2 - 1, $1) };
    return '' unless defined $epoch;

    my $wday = (gmtime $epoch)[6];          # 0 = Sunday
    my $mon  = $epoch - (($wday + 6) % 7) * 86400;
    my @m    = gmtime $mon;
    return sprintf('%04d-%02d-%02d', $m[5] + 1900, $m[4] + 1, $m[3]);
}

# Human-readable divider label for a week-start date.
sub _weekLabel {
    my ($client, $ws) = @_;
    return cstring($client, 'PLUGIN_LBF_WEEK_UNKNOWN') unless $ws =~ /^(\d{4})-(\d{2})-(\d{2})$/;

    my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    return sprintf('%s %d %s %d',
        cstring($client, 'PLUGIN_LBF_WEEK_OF'), $3 + 0, $months[$2 - 1], $1);
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
                $callback->({ items => [ map { _buildReleaseItem($_, $client) } @$rels ] });
            },
        };
    }

    return \@items;
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

    my $year = ($date =~ /^(\d{4})/) ? $1 : '';
    my $name = "$artist \x{2013} $album";
    $name .= " ($year)" if $year;

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
# Release detail page — base metadata, then (in parallel) directly-playable
# streaming matches and the MusicBrainz genres + tracklist, merged inline.
# Either async source can fail/empty without breaking the page.
# ---------------------------------------------------------------------------
sub _releaseDetail {
    my ($rel, $client, $callback) = @_;

    my @base   = _detailMeta($rel, $client);
    my $mbid   = $rel->{release_mbid} // '';
    my $artist = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') // '';
    my $album  = _pickValue($rel, 'release_name', 'title', 'name') // '';

    my @streamItems;   # playable streaming matches (with a header)
    my @mbItems;       # genres + tracklist

    my $wantStream = ($prefs->get('play_via') && length $album && _streamingAdapters()) ? 1 : 0;
    my $wantMB     = $mbid ? 1 : 0;

    # Count all tasks up front: a cache hit completes its callback synchronously,
    # so if we incremented per-task the barrier could fire after the first one
    # finishes (before the second was even launched) and drop the other's data.
    my $pending = $wantStream + $wantMB;
    my $done    = 0;

    my $finish = sub {
        return if $done || $pending > 0;
        $done = 1;
        $callback->({ items => [ @base, @streamItems, @mbItems ] });
    };

    unless ($pending) {
        $callback->({ items => \@base });
        return;
    }

    # Watchdog: if a streaming/MusicBrainz callback never returns (network hang,
    # partial failure), force a render with whatever arrived. $finish is
    # idempotent ($done), so a normal completion makes this a no-op.
    Slim::Utils::Timers::setTimer(undef, time() + DETAIL_TIMEOUT, sub { $finish->() });

    # Streaming services — search automatically and show matches inline
    if ($wantStream) {
        _findPlayable($client, sub {
            my $res   = shift;
            my @items = (ref $res eq 'HASH' && ref $res->{items} eq 'ARRAY') ? @{ $res->{items} } : ();
            @items    = grep { ($_->{type} // '') ne 'text' } @items;   # drop "no match" placeholders
            @streamItems = ({ name => cstring($client, 'PLUGIN_LBF_PLAY_VIA'), type => 'text' }, @items)
                if @items;
            $pending--;
            $finish->();
        }, $artist, $album, $mbid);
    }

    # MusicBrainz genres + tracklist
    if ($wantMB) {
        Plugins::ListenBrainzFreshReleases::API->getReleaseDetails(
            $mbid,
            sub {
                my $info = shift;

                my @genres = @{ $info->{genres} || [] };
                push @mbItems, {
                    name => cstring($client, 'PLUGIN_LBF_GENRES') . ': ' . join(', ', @genres),
                    type => 'text',
                } if @genres;

                my @media = grep { $_->{tracks} && scalar @{ $_->{tracks} } } @{ $info->{media} || [] };
                if (@media) {
                    push @mbItems, { name => cstring($client, 'PLUGIN_LBF_TRACKLIST'), type => 'text' };
                    my $multi = scalar @media > 1;
                    for my $m (@media) {
                        if ($multi) {
                            my $hdr = cstring($client, 'PLUGIN_LBF_DISC') . ' ' . ($m->{position} // '');
                            $hdr .= " ($m->{format})" if $m->{format};
                            push @mbItems, { name => $hdr, type => 'text' };
                        }
                        for my $t (@{ $m->{tracks} }) {
                            my $line = ($t->{position} ? "$t->{position}. " : '') . ($t->{title} // '');
                            $line .= '  (' . _fmtDuration($t->{length}) . ')' if $t->{length};
                            push @mbItems, { name => $line, type => 'text' };
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

    # Only build the link for a well-formed MBID (UUID) — the value comes from
    # the API but lands in an href Material renders, so validate before trusting.
    push @detail, {
        name    => cstring($client, 'PLUGIN_LBF_VIEW_ON_MB'),
        type    => 'link',
        weblink => "https://musicbrainz.org/release/$mbid",
        image   => ICON,
    } if $mbid =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    return @detail;
}

# Which supported streaming-service adapters are available on this server.
# Detection is via ->can on the plugin package: it's only loaded when the
# plugin is installed+enabled, and ->can on an absent package is safe (no die).
# In scalar/boolean context this returns the count (truthy if any present).
sub _streamingAdapters {
    my @adapters;

    push @adapters, { name => 'Qobuz', icon => _pluginIcon('Plugins::Qobuz::Plugin'), run => \&_searchQobuz }
        if Plugins::Qobuz::Plugin->can('getAPIHandler')
        && Plugins::Qobuz::Plugin->can('_albumItem');

    push @adapters, { name => 'Bandcamp', icon => _pluginIcon('Plugins::Bandcamp::Plugin'), run => \&_searchBandcamp }
        if Plugins::Bandcamp::Plugin->can('album_list');

    return @adapters;
}

# The service plugin's own icon (its Material logo), used as the thumbnail on
# each result so it's clear which service it came from. Undef if unavailable.
sub _pluginIcon {
    my ($class) = @_;
    return eval { $class->_pluginDataFor('icon') } || undef;
}

# Find the release on installed streaming services and present each service's
# matching album as a directly-playable node (one tap to play / add), using
# each plugin's own search API rather than a generic search drill-down.
sub _findPlayable {
    my ($client, $callback, $artist, $album, $mbid) = @_;

    my @adapters   = _streamingAdapters();
    my $albumNorm  = _norm($album);
    my $artistNorm = _norm($artist);
    # Search with normalised terms (quotes, &, commas stripped). Raw multi-artist
    # credits like 'Lee "Scratch" Perry & Mouse on Mars' otherwise make the
    # service search miss the album.
    my $query      = join(' ', grep { length } $artistNorm, $albumNorm);

    unless (@adapters) {
        $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_NO_SERVICES'), type => 'text' }] });
        return;
    }

    # Cache hit → rebuild the playable items from the stored data (no re-search).
    # Key is versioned (:2:) so old entries from previous matching logic are ignored.
    my $key = 'lbf:stream:2:' . ($mbid || _norm($query));
    if (my $c = $cache->get($key)) {
        $log->info("play-via cache hit: $key (" . scalar(@{ $c->{items} || [] }) . " match(es))");
        $callback->({ items => _streamResult($client, _rebuildStreamItems($c->{items})) });
        return;
    }

    my @collected;
    my $pending = scalar @adapters;
    my $done    = 0;

    my $finish = sub {
        return if $done || $pending > 0;
        $done = 1;

        # Cache serializable copies (OPML item url is a coderef → strip it; it's
        # reattached per-service on read). _svc identifies which to reattach.
        # Guarded: Storable dies on any unexpected nested coderef/blessed ref, and
        # that must not stop us calling $callback below (would hang the page).
        my @store = map { my %x = %$_; delete $x{url}; \%x } @collected;
        my $ttl   = @collected ? STREAM_FOUND_TTL : STREAM_NOMATCH_TTL;
        eval { $cache->set($key, { items => \@store }, $ttl); 1 }
            or $log->warn("play-via cache set failed: $@");

        $log->info("play-via '$query': " . scalar(@collected) . " match(es), cached ${ttl}s");
        $callback->({ items => _streamResult($client, \@collected) });
    };

    for my $a (@adapters) {
        my $svc     = $a->{name};
        my $icon    = $a->{icon};
        my $collect = sub {
            my $items = shift;
            if (ref $items eq 'ARRAY') {
                for my $it (@$items) {
                    $it->{image} = $icon if $icon;   # service logo as thumbnail
                    $it->{_svc}  = $svc;             # for cache rebuild
                }
                push @collected, @$items;
            }
            $pending--;
            $finish->();
        };

        eval { $a->{run}->($client, $query, $artistNorm, $albumNorm, $svc, $collect); 1 } or do {
            $log->warn("play-via $svc failed: $@");
            $pending--;
            $finish->();
        };
    }
}

# Wrap matched items for display, or a "no match" placeholder when empty.
sub _streamResult {
    my ($client, $items) = @_;
    return @$items
        ? $items
        : [{ name => cstring($client, 'PLUGIN_LBF_NO_MATCH'), type => 'text' }];
}

# Rebuild playable items from cached (url-stripped) data by reattaching each
# service's native play coderef. Items whose service is no longer present are
# dropped.
sub _rebuildStreamItems {
    my ($cached) = @_;

    my @out;
    for my $c (@{ $cached || [] }) {
        my %item = %$c;
        my $svc  = $item{_svc} // '';

        if ($svc eq 'Qobuz' && Plugins::Qobuz::Plugin->can('QobuzGetTracks')) {
            $item{url} = \&Plugins::Qobuz::Plugin::QobuzGetTracks;
        }
        elsif ($svc eq 'Bandcamp' && Plugins::Bandcamp::Plugin->can('get_album')) {
            $item{url} = \&Plugins::Bandcamp::Plugin::get_album;
        }
        else {
            next;
        }

        push @out, \%item;
    }

    return \@out;
}

# Qobuz: search albums via the plugin's own API, keep title matches, and reuse
# the plugin's _albumItem so each result is a native, playable album node.
sub _searchQobuz {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect) = @_;

    my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
    unless ($api) {
        $collect->([]);
        return;
    }

    $api->search(sub {
        my $res = shift;
        my @out;
        for my $album (@{ ($res && $res->{albums} && $res->{albums}{items}) || [] }) {
            my $candArtist = ref $album->{artist} eq 'HASH' ? $album->{artist}{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title});
            push @out, Plugins::Qobuz::Plugin::_albumItem($client, $album);
        }
        $collect->(\@out);
    }, lc($query), 'albums');
}

# Bandcamp: run the plugin's combined search, keep the album results (identified
# by an album_id in their passthrough — they're already playable album nodes).
sub _searchBandcamp {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect) = @_;

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
            next unless _albumMatches($artistNorm, $albumNorm, $pt->{artist}, $pt->{title});
            push @out, $it;
        }
        $collect->(\@out);
    }, { search => $query });
}

# True if a streaming result is the same release: the candidate title must
# contain our album title (tolerates " (Deluxe)", " EP", etc. after _norm), AND
# the candidate artist must match ours (the disambiguator — without it, similar
# titles by unrelated artists slip through). Artist matches in either direction
# to tolerate "feat."/credit variations. With no artist to compare, title alone.
sub _albumMatches {
    my ($artistNorm, $albumNorm, $candArtist, $candTitle) = @_;

    return 0 if length $albumNorm < 2;
    my $t = _norm($candTitle);
    return 0 if $t eq '' || index($t, $albumNorm) < 0;

    return 1 if $artistNorm eq '';
    return _artistMatch($artistNorm, _norm($candArtist));
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

# Normalise a title for fuzzy matching: lowercase, drop bracketed qualifiers
# (deluxe/remaster/etc.) and punctuation, collapse whitespace.
sub _norm {
    my $s = lc(shift // '');
    $s =~ s/[\(\[].*?[\)\]]//g;
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+|\s+$//g;
    $s =~ s/\s+/ /g;
    return $s;
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
