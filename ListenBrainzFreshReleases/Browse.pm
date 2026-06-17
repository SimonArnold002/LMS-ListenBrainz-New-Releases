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

    # The requesting client's "features" string is only available here (the top
    # feed gets the request params); XMLBrowser does NOT forward request params
    # to drilled coderef sub-feeds. So capture it now and pass it down to
    # fetchForYou/fetchAll via passthrough (which IS forwarded).
    my $feat = _featuresOf($args);

    my @items;

    if ($username && $token) {
        push @items, {
            name        => cstring($client, 'PLUGIN_LBF_FOR_YOU'),
            type        => 'link',
            url         => \&fetchForYou,
            passthrough => [{ features => $feat }],
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
        passthrough => [{ features => $feat }],
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

    my $headers = _wantHeaders(ref $passDict eq 'HASH' ? $passDict->{features} : undef);
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
            $callback->({ items => _buildItems($releases, $client, $headers) });
        },
        onError => sub {
            $log->error("For You fetch error: " . (shift // ''));
            $callback->({ items => [{ name => cstring($client, 'PLUGIN_LBF_ERROR'), type => 'text' }] });
        },
    );
}

# ---------------------------------------------------------------------------
# For You feed for the Material Skin home-page row (carousel + "show all"
# click-in). Same structure as the main For You menu (week dividers / grouping).
# ---------------------------------------------------------------------------
sub homeForYou {
    my ($client, $cb, $args) = @_;

    # Flat list of release cards — NO week-divider headers. The Material carousel
    # and its "show all" click-in are the SAME feed (Material exposes no way to
    # give the click-in a different command), so they must share one structure.
    # A header item sits at index 0 and shifts every card's item_id; play commands
    # re-traverse the feed by item_id at quantity 1, so that shift makes deep
    # streaming playback resolve the wrong item and fail (verified via JSON-RPC:
    # headered item_id:1 = a card, flat item_id:1 = a different card). It must
    # also not vary by request quantity for the same reason. So: always flat, for
    # every quantity. Week dividers live in the main For You / All Releases menus.
    Plugins::ListenBrainzFreshReleases::API->getFreshReleasesForUser(
        sort    => $prefs->get('sort')          // 'release_date',
        past    => $prefs->get('foryou_past')   // 1,
        future  => $prefs->get('foryou_future') // 0,
        days    => $prefs->get('days')          // 14,
        onDone  => sub {
            my $releases = _sortReleases(_filterForYou(shift));
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

    my $headers = _wantHeaders(ref $passDict eq 'HASH' ? $passDict->{features} : undef);
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
            $callback->({ items => _buildItems($releases, $client, $headers) });
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
# All release types offered as per-section filter checkboxes.
my @RELEASE_TYPES = qw(album single ep broadcast other compilation soundtrack live remix demo);

# Build the allowed-type set for a section from its <prefix>_type_* prefs.
sub _allowedTypes {
    my ($prefix) = @_;
    my %allowed;
    $allowed{$_} = 1 for grep { $prefs->get("${prefix}_type_$_") } @RELEASE_TYPES;
    return \%allowed;
}

# A release's secondary type, lower-cased ('' if none). ListenBrainz sends this
# as a single scalar string (release_group_secondary_type) — NOT an array — but
# accept the plural/array form defensively in case the API ever changes.
sub _secondaryType {
    my ($rel) = @_;
    my $s = $rel->{release_group_secondary_type}
         // $rel->{release_group_secondary_types}
         // $rel->{secondary_types};
    $s = $s->[0] if ref $s eq 'ARRAY';
    return (defined $s && lc($s) ne 'none') ? lc($s) : '';
}

# Does a release pass the type filter? Allowlist semantics: the primary type
# must be ticked AND any secondary type must also be ticked. This is what
# excludes live/soundtrack/audiobook/etc. releases whose primary is "Album".
# The secondary list in the API is larger than the offered checkboxes (DJ-mix,
# Audiobook, Interview…), so an untickable secondary correctly fails the list.
# An empty allowed-set means "nothing selected" → show everything (safety net).
sub _typeMatches {
    my ($rel, $allowed) = @_;
    return 1 unless %$allowed;

    return 0 unless $allowed->{ lc($rel->{release_group_primary_type} // '') };

    my $sec = _secondaryType($rel);
    return 0 if length $sec && !$allowed->{$sec};

    return 1;
}

# Shared per-section filter: release type (by prefix), Various Artists, artwork.
sub _filterSection {
    my ($releases, $prefix) = @_;
    $releases //= [];

    my $artwork_only = $prefs->get("${prefix}_artwork_only") // 1;
    my $various      = $prefs->get("${prefix}_various")      // 1;
    my $allowed      = _allowedTypes($prefix);

    my @out;
    for my $rel (@$releases) {
        next unless _typeMatches($rel, $allowed);
        next if !$various && _isVariousArtists($rel);
        next if $artwork_only && !Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel);
        push @out, $rel;
    }
    return \@out;
}

sub _filterForYou { _filterSection(shift, 'foryou') }
sub _filterAll    { _filterSection(shift, 'all') }

# ---------------------------------------------------------------------------
# Sort releases by the configured order. Release date is newest-first and
# confidence highest-first; artist/album are A–Z. (The API's own ordering is
# unreliable — e.g. date comes back oldest-first — so we sort here.)
# ---------------------------------------------------------------------------
# Collapse duplicate editions of the same album. ListenBrainz/MusicBrainz often
# list a fresh release twice — sometimes as two different release-groups — so key
# on normalised artist + album + date rather than MBID. Keep the copy with cover
# art where one of the pair has it.
sub _dedupeReleases {
    my ($releases) = @_;
    return $releases unless ref $releases eq 'ARRAY';

    my %idx;
    my @out;
    for my $rel (@$releases) {
        my $key = join('|',
            _norm(_pickValue($rel, 'artist_credit_name', 'artist_name', 'artist')),
            _norm(_pickValue($rel, 'release_name', 'title', 'name')),
            ($rel->{release_date} // ''));

        if (defined(my $i = $idx{$key})) {
            $out[$i] = $rel
                if !Plugins::ListenBrainzFreshReleases::API->coverArtUrl($out[$i])
                &&  Plugins::ListenBrainzFreshReleases::API->coverArtUrl($rel);
            next;
        }
        $idx{$key} = scalar @out;
        push @out, $rel;
    }
    return \@out;
}

sub _sortReleases {
    my ($releases) = @_;
    return $releases unless ref $releases eq 'ARRAY';

    $releases = _dedupeReleases($releases);

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

    my $secondary = _secondaryType($rel);
    if ($secondary ne '') {
        my $formatted = _formatTypeName($secondary);
        push @parts, $formatted if $formatted ne '';
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
# The requesting client's "features" string, read from the top feed's request
# params (e.g. Material sends "features:hi").
sub _featuresOf {
    my ($args) = @_;
    return (ref $args->{params} eq 'HASH') ? ($args->{params}{features} // '') : '';
}

# True when the client advertises support for the "header" item type ('h' in
# features). Material renders such items bold/accent-coloured (and can use a grid
# view); other skins get plain text dividers instead.
sub _wantHeaders {
    my ($features) = @_;
    return (defined $features && $features =~ /h/) ? 1 : 0;
}

sub _buildItems {
    my ($releases, $client, $headers) = @_;

    unless ($releases && scalar @$releases) {
        return [{ name => cstring($client, 'PLUGIN_LBF_NO_RESULTS'), type => 'text' }];
    }

    my $sort = $prefs->get('sort') // 'release_date';

    # Return the whole (already filtered + sorted) list as a single level and let
    # LMS/Material window it natively — so Material's in-list filter spans every
    # item, not just one page, and we get the native scroll/prev-next pager.
    if ($prefs->get('week_dividers') && $sort eq 'release_date') {
        # weekly view takes precedence for the date sort (it's the chronological read)
        return _buildWeekly($releases, $client, $headers);
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
    my ($releases, $client, $headers) = @_;

    # Real header item for Material (bold, accent colour); plain text elsewhere.
    my $divType = $headers ? 'header' : 'text';

    # Group into weeks (input is already date-sorted, so same-week rows are
    # adjacent and week order is preserved).
    my @order;
    my %bucket;
    for my $rel (@$releases) {
        my $ws = _weekStart($rel->{release_date} // '');
        push @order, $ws unless exists $bucket{$ws};
        push @{ $bucket{$ws} }, $rel;
    }

    my @items;
    for my $ws (@order) {
        my $rels = $bucket{$ws};

        # Give the header an image. Material's grid detection counts headers too
        # (older versions: image-less item → haveWithoutIcons → grid/list toggle
        # disabled for the whole page). With every item carrying an image the grid
        # view stays available, and the header still renders as a divider. (Same
        # approach as the Listen to Later plugin.)
        my $hdr = { name => _weekLabel($client, $ws), type => $divType, image => ICON };
        if ($headers) {
            # Material renders header items with a drill action that XMLBrowser
            # forces on (can't be suppressed); rather than lead nowhere, point it
            # at this week's releases (same coderef pattern as _buildGrouped).
            $hdr->{url} = sub {
                my ($c, $cb) = @_;
                $cb->({ items => [ map { _buildReleaseItem($_, $c) } @$rels ] });
            };
            $hdr->{passthrough} = [{}];
        }

        push @items, $hdr;
        push @items, map { _buildReleaseItem($_, $client) } @$rels;
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
    my $type       = _displayType($rel);   # includes the secondary type, e.g. "Album / Live"
    my $mbid       = $rel->{release_mbid} // '';
    my $conf       = $rel->{confidence};

    my $year = ($date =~ /^(\d{4})/) ? $1 : '';
    my $name = "$artist \x{2013} $album";
    $name .= " ($year)" if $year;

    my $line2 = $type;
    # Genre/style tags ride along in the payload (release_tags) — show up to 3
    # next to the title. Coverage is partial (~20%) and tag-only, so many rows
    # legitimately have none; no extra API call is made.
    my @tags = _releaseTags($rel);
    if (@tags) {
        my $max = $#tags < 2 ? $#tags : 2;
        $line2 .= " \x{00B7} " . join(', ', @tags[0..$max]);
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
    my $mbid   = $rel->{release_mbid}       // '';
    my $rgMbid = $rel->{release_group_mbid} // '';
    my $artist = _pickValue($rel, 'artist_credit_name', 'artist_name', 'artist') // '';
    my $album  = _pickValue($rel, 'release_name', 'title', 'name') // '';

    my @streamItems;   # playable streaming matches (with a header)
    my @trackItems;    # tracklist (from the release)
    my $mbGenres;      # arrayref: genres from the MusicBrainz release-group
    my $lfmGenres;     # arrayref: tags from Last.fm (fallback)

    my $wantStream = ($prefs->get('play_via') && length $album && _orderedAdapters()) ? 1 : 0;
    my $wantGenres = $rgMbid ? 1 : 0;
    my $wantLastfm = ($prefs->get('lastfm_api_key') && (length $artist || length $album)) ? 1 : 0;
    my $wantTracks = $mbid   ? 1 : 0;

    # Count all tasks up front: a cache hit completes its callback synchronously,
    # so per-task incrementing could let the barrier fire after the first one
    # finishes (before the others launched) and drop their data.
    my $pending = $wantStream + $wantGenres + $wantLastfm + $wantTracks;
    my $done    = 0;

    my $finish = sub {
        return if $done || $pending > 0;
        $done = 1;
        # One "Genres" line: prefer curated MusicBrainz genres, fall back to
        # Last.fm tags (MB is usually empty for fresh releases).
        my $g = (ref $mbGenres  eq 'ARRAY' && @$mbGenres)  ? $mbGenres
              : (ref $lfmGenres eq 'ARRAY' && @$lfmGenres) ? $lfmGenres
              :                                              undef;
        my @genreItems = $g
            ? ({ name => cstring($client, 'PLUGIN_LBF_GENRES') . ': ' . join(', ', @$g), type => 'text' })
            : ();
        $callback->({ items => [ @base, @streamItems, @genreItems, @trackItems ] });
    };

    unless ($pending) {
        $callback->({ items => \@base });
        return;
    }

    # Watchdog: if a callback never returns (network hang, partial failure),
    # force a render with whatever arrived. $finish is idempotent ($done), so a
    # normal completion makes this a no-op.
    Slim::Utils::Timers::setTimer(undef, time() + DETAIL_TIMEOUT, sub { $finish->() });

    # Streaming services — search automatically and show matches inline, with a
    # manual "refresh" that re-searches (bypasses the cache) for this album.
    if ($wantStream) {
        _findPlayable($client, sub {
            my $res   = shift;
            my @items = (ref $res eq 'HASH' && ref $res->{items} eq 'ARRAY') ? @{ $res->{items} } : ();
            @items    = grep { ($_->{type} // '') ne 'text' } @items;   # drop "no match" placeholders
            @streamItems = ({ name => cstring($client, 'PLUGIN_LBF_PLAY_VIA'), type => 'text' }, @items);
            push @streamItems, {
                name        => cstring($client, 'PLUGIN_LBF_REFRESH'),
                type        => 'link',
                image       => ICON,
                url         => sub { _findPlayable($_[0], $_[1], $artist, $album, $mbid, 1) },
                passthrough => [{}],
            };
            $pending--;
            $finish->();
        }, $artist, $album, $mbid);
    }

    # Genres — from the release-group (release-level genres are nearly always empty)
    if ($wantGenres) {
        Plugins::ListenBrainzFreshReleases::API->getReleaseGroupGenres(
            $rgMbid,
            sub { $mbGenres = shift; $pending--; $finish->(); },
            sub {
                $log->info("Release-group genres lookup failed: " . (shift // ''));
                $pending--;
                $finish->();
            },
        );
    }

    # Last.fm tags — fallback genre source (album tags, then artist tags). Only
    # runs when an API key is configured; $finish prefers MB genres over these.
    if ($wantLastfm) {
        Plugins::ListenBrainzFreshReleases::API->getLastfmTags(
            $artist, $album,
            sub { $lfmGenres = shift; $pending--; $finish->(); },
            sub { $pending--; $finish->(); },
        );
    }

    # Tracklist — from the release
    if ($wantTracks) {
        Plugins::ListenBrainzFreshReleases::API->getReleaseDetails(
            $mbid,
            sub {
                my $info = shift;

                my @media = grep { $_->{tracks} && scalar @{ $_->{tracks} } } @{ $info->{media} || [] };
                if (@media) {
                    push @trackItems, { name => cstring($client, 'PLUGIN_LBF_TRACKLIST'), type => 'text' };
                    my $multi = scalar @media > 1;
                    for my $m (@media) {
                        if ($multi) {
                            my $hdr = cstring($client, 'PLUGIN_LBF_DISC') . ' ' . ($m->{position} // '');
                            $hdr .= " ($m->{format})" if $m->{format};
                            push @trackItems, { name => $hdr, type => 'text' };
                        }
                        for my $t (@{ $m->{tracks} }) {
                            my $line = ($t->{position} ? "$t->{position}. " : '') . ($t->{title} // '');
                            $line .= '  (' . _fmtDuration($t->{length}) . ')' if $t->{length};
                            push @trackItems, { name => $line, type => 'text' };
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
    my $type    = _displayType($rel);   # primary + secondary, e.g. "Album / Live"
    my $mbid    = $rel->{release_mbid} // '';

    my @detail = (
        { name => cstring($client, 'PLUGIN_LBF_ARTIST') . ": $artist", type => 'text' },
        { name => cstring($client, 'PLUGIN_LBF_ALBUM')  . ": $album",  type => 'text' },
        { name => cstring($client, 'PLUGIN_LBF_DATE')   . ": $date",   type => 'text' },
        { name => cstring($client, 'PLUGIN_LBF_TYPE')   . ": $type",   type => 'text' },
    );

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

    push @adapters, { name => 'Tidal', icon => _pluginIcon('Plugins::TIDAL::Plugin'), run => \&_searchTidal }
        if Plugins::TIDAL::Plugin->can('getAPIHandler')
        && Plugins::TIDAL::Plugin->can('getAlbum')
        && Plugins::TIDAL::Plugin->can('_renderAlbum');

    return @adapters;
}

# Installed adapters in search order: ascending svc_priority_<name>, dropping any
# set to 0 (disabled). Used by _findPlayable to search one service at a time.
sub _orderedAdapters {
    my @out;
    for my $a (_streamingAdapters()) {
        my $prio = $prefs->get('svc_priority_' . lc $a->{name});
        $prio = 1 unless defined $prio;   # unknown service → still searchable
        next unless $prio > 0;
        push @out, { %$a, priority => $prio };
    }
    my @ordered = sort { $a->{priority} <=> $b->{priority} } @out;
    return @ordered;   # named array → safe count in scalar/boolean context
}

# Detection + priority for every service we know how to integrate (installed or
# not), in display order — drives the settings page's "Streaming Services" list.
sub serviceStatus {
    my @known = (
        [ 'qobuz',    'Qobuz'    ],
        [ 'bandcamp', 'Bandcamp' ],
        [ 'tidal',    'Tidal'    ],
    );
    my %installed = map { lc($_->{name}) => 1 } _streamingAdapters();
    return [ map {
        {   key       => $_->[0],
            name      => $_->[1],
            installed => $installed{ $_->[0] } ? 1 : 0,
            priority  => $prefs->get('svc_priority_' . $_->[0]) // 0,
        }
    } @known ];
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
    my ($client, $callback, $artist, $album, $mbid, $force) = @_;

    my @adapters   = _orderedAdapters();
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
    # Key is versioned so a change to the set of searched services / matching
    # logic invalidates stale entries (:2: matching rework, :3: added Tidal).
    # $force (manual refresh) skips the read so the services are searched again.
    my $key = 'lbf:stream:3:' . ($mbid || _norm($query));
    if (!$force && (my $c = $cache->get($key))) {
        $log->info("play-via cache hit: $key (" . scalar(@{ $c->{items} || [] }) . " match(es))");
        $callback->({ items => _streamResult($client, _rebuildStreamItems($c->{items})) });
        return;
    }

    # Search one service at a time in priority order; stop at the first that has a
    # match (see _tryNextAdapter). The chosen service's matches are cached (or an
    # empty result if none matched anywhere), so a revisit is instant.
    _tryNextAdapter({
        client     => $client,
        callback   => $callback,
        query      => $query,
        artistNorm => $artistNorm,
        albumNorm  => $albumNorm,
        key        => $key,
        adapters   => \@adapters,
        idx        => 0,
    });
}

# Cache the matched items for a play-via key (url coderef stripped — it's
# reattached per service on read by _rebuildStreamItems). Guarded: Storable dies
# on unexpected nested coderefs/blessed refs and that must not stop the page.
sub _cacheStream {
    my ($key, $items, $ttl) = @_;
    my @store = map { my %x = %$_; delete $x{url}; \%x } @$items;
    eval { $cache->set($key, { items => \@store }, $ttl); 1 }
        or $log->warn("play-via cache set failed: $@");
}

# Try the service at $ctx->{idx}, advancing one at a time; stop at the first with
# a match. A named sub with an explicit $ctx (rather than a self-referencing
# closure) so there's no reference cycle / leak across the async hops.
sub _tryNextAdapter {
    my ($ctx) = @_;
    my $adapters = $ctx->{adapters};

    if ($ctx->{idx} >= @$adapters) {
        _cacheStream($ctx->{key}, [], STREAM_NOMATCH_TTL);
        $log->info("play-via '$ctx->{query}': no match on any service");
        $ctx->{callback}->({ items => _streamResult($ctx->{client}, []) });
        return;
    }

    my $a    = $adapters->[ $ctx->{idx}++ ];
    my $svc  = $a->{name};
    my $icon = $a->{icon};

    my $collect = sub {
        my $items   = shift;
        my @matched = (ref $items eq 'ARRAY') ? @$items : ();

        unless (@matched) {
            _tryNextAdapter($ctx);   # nothing here — fall through to the next service
            return;
        }

        for my $it (@matched) {
            $it->{image} = $icon if $icon;   # service logo as thumbnail
            $it->{_svc}  = $svc;             # for cache rebuild
        }
        _cacheStream($ctx->{key}, \@matched, STREAM_FOUND_TTL);
        $log->info("play-via '$ctx->{query}': matched on $svc (" . scalar(@matched) . ")");
        $ctx->{callback}->({ items => _streamResult($ctx->{client}, \@matched) });
    };

    eval { $a->{run}->($ctx->{client}, $ctx->{query}, $ctx->{artistNorm}, $ctx->{albumNorm}, $svc, $collect); 1 }
        or do {
            $log->warn("play-via $svc failed: $@");
            _tryNextAdapter($ctx);
        };
}

# Collapse duplicate streaming entries — some services (seen with Bandcamp)
# return the same album twice. Key on service + display name + subtitle so true
# duplicates merge, but genuinely different editions (which differ in the name,
# e.g. "(Hi-Res)" vs "(Album)") are both kept.
sub _dedupeStreamItems {
    my ($items) = @_;
    my (%seen, @out);
    for my $it (@{ $items || [] }) {
        my $key = join('|',
            lc($it->{_svc}  // ''),
            lc($it->{name}  // ''),
            lc($it->{line2} // ''));
        next if $seen{$key}++;
        push @out, $it;
    }
    return \@out;
}

# Wrap matched items for display, or a "no match" placeholder when empty.
sub _streamResult {
    my ($client, $items) = @_;
    $items = _dedupeStreamItems($items);
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
        elsif ($svc eq 'Tidal' && Plugins::TIDAL::Plugin->can('getAlbum')) {
            $item{url} = \&Plugins::TIDAL::Plugin::getAlbum;
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

# Tidal: search albums via the plugin's API handler, keep title+artist matches,
# and reuse the plugin's _renderAlbum so each result is a native, playable album
# node (url => getAlbum, plus play/add/insert itemActions keyed by album id).
sub _searchTidal {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect) = @_;

    my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
    unless ($api) {
        $collect->([]);
        return;
    }

    $api->search(sub {
        my $albums = shift;   # raw album hashes (type => albums search)
        my @out;
        for my $album (@{ $albums || [] }) {
            next unless ref $album eq 'HASH';
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title});
            push @out, Plugins::TIDAL::Plugin::_renderAlbum($album);
        }
        $collect->(\@out);
    }, { type => 'albums', search => $query, limit => 20 });
}

# True if a streaming result is the same release: the candidate title must BE our
# album title, or START with it (tolerates " (Deluxe)", " EP", " (Hi-Res)" etc.
# after _norm), AND the candidate artist must match ours (the disambiguator —
# without it, similar titles by unrelated artists slip through). Artist matches in
# either direction to tolerate "feat."/credit variations. With no artist, title
# alone. NB: we require a leading-prefix (not a substring) match — the album name
# appearing mid-title was a common false positive, e.g. our "Apollo" by "Gene"
# wrongly matching "Friendship 7 to Apollo 11…". The trailing space is a word
# boundary so "Apollo" doesn't match "Apollonia".
sub _albumMatches {
    my ($artistNorm, $albumNorm, $candArtist, $candTitle) = @_;

    return 0 if length $albumNorm < 2;
    my $t = _norm($candTitle);
    return 0 if $t eq '';
    return 0 unless $t eq $albumNorm || index($t, "$albumNorm ") == 0;

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
