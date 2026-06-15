package Plugins::ListenBrainzFreshReleases::API;

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use JSON::XS::VersionOneAndTwo;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');
my $cache = Slim::Utils::Cache->new();

# A MusicBrainz tracklist never changes, so cache a found result for a long time;
# genres can be sparse on fresh releases, so recheck an empty result daily.
use constant MB_FOUND_TTL => 30 * 86400;
use constant MB_EMPTY_TTL =>  1 * 86400;

# Last.fm tags change slowly; cache a found result for a month and recheck an
# empty one weekly (a brand-new album may pick up tags over time).
use constant LFM_FOUND_TTL => 30 * 86400;
use constant LFM_EMPTY_TTL =>  7 * 86400;

# The fresh-releases feed only changes ~daily, but the Material home row reloads
# it constantly. Without caching, every home/menu view fired a fresh, slow (2-15s)
# ListenBrainz call — which flooded and rate-limited the API and hung the home
# page. Cache the parsed feed so repeat views are instant. 6h balances freshness
# (the data is ~daily) against fetch count; All Releases also rolls over at local
# midnight anyway via the date in its cache key.
use constant FEED_TTL => 6 * 3600;   # 6 hours

use constant BASE_URL        => 'https://api.listenbrainz.org';
use constant CAA_BASE_URL    => 'https://coverartarchive.org/release/';
use constant MB_BASE_URL     => 'https://musicbrainz.org/ws/2/';
use constant LASTFM_BASE_URL => 'https://ws.audioscrobbler.com/2.0/';

# MusicBrainz requires a descriptive User-Agent identifying the application
use constant USER_AGENT   => 'LMS-ListenBrainzFreshReleases/0.6.8 ( https://github.com/SimonArnold002/LMS-ListenBrainz-New-Releases )';

# ---------------------------------------------------------------------------
# GET /1/user/<username>/fresh_releases  (personalised, auth required)
# ---------------------------------------------------------------------------
sub getFreshReleasesForUser {
    my ($class, %args) = @_;

    my $username = $prefs->get('username') // '';
    my $token    = $prefs->get('token')    // '';

    unless ($username && $token) {
        $args{onError}->("No ListenBrainz username/token configured");
        return;
    }

    my $sort   = $args{sort}   // 'release_date';
    my $days   = $args{days}   // 14;
    my $past   = $args{past}   ? 'true' : 'false';
    my $future = $args{future} ? 'true' : 'false';

    my $cacheKey = 'lbf:feed:user:' . join('|', $username, $sort, $past, $future, $days);
    if (my $cached = $cache->get($cacheKey)) {
        $log->info("For-you releases cache hit ($cacheKey)");
        $args{onDone}->($cached);
        return;
    }

    (my $safe_user = $username) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;

    my $url = sprintf('%s/1/user/%s/fresh_releases?sort=%s&past=%s&future=%s&days=%d',
        BASE_URL, $safe_user, $sort, $past, $future, $days);

    $log->info("Fetching for-you releases: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            _handleResponse(shift, sub {
                my $releases = shift;
                eval { $cache->set($cacheKey, $releases, FEED_TTL); 1 }
                    or $log->warn("For-you feed cache set failed: $@");
                $args{onDone}->($releases);
            });
        },
        sub { _handleError(shift, $args{onError}) },
        { timeout => 15 }
    );

    $http->get($url,
        'Authorization' => "Token $token",
        'Accept'        => 'application/json',
    );
}

# ---------------------------------------------------------------------------
# GET /1/explore/fresh-releases/  (global, no auth needed)
# ---------------------------------------------------------------------------
sub getFreshReleasesAll {
    my ($class, %args) = @_;

    my $sort   = $args{sort}   // 'release_date';
    my $days   = $args{days}   // 14;
    my $past   = $args{past}   ? 'true' : 'false';
    my $future = $args{future} ? 'true' : 'false';

    my @t = localtime(time);
    my $today = sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]);

    my $cacheKey = 'lbf:feed:all:' . join('|', $sort, $past, $future, $days, $today);
    if (my $cached = $cache->get($cacheKey)) {
        $log->info("All releases cache hit ($cacheKey)");
        $args{onDone}->($cached);
        return;
    }

    my $url = sprintf('%s/1/explore/fresh-releases/?sort=%s&past=%s&future=%s&days=%d&release_date=%s',
        BASE_URL, $sort, $past, $future, $days, $today);

    $log->info("Fetching all releases: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            _handleResponse(shift, sub {
                my $releases = shift;
                eval { $cache->set($cacheKey, $releases, FEED_TTL); 1 }
                    or $log->warn("All-releases feed cache set failed: $@");
                $args{onDone}->($releases);
            });
        },
        sub { _handleError(shift, $args{onError}) },
        { timeout => 15 }
    );

    $http->get($url, 'Accept' => 'application/json');
}

# ---------------------------------------------------------------------------
# GET /1/validate-token  (used by Settings on save)
# ---------------------------------------------------------------------------
sub validateToken {
    my ($class, $token, $onDone, $onError) = @_;

    (my $safe = $token) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = BASE_URL . '/1/validate-token?token=' . $safe;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) { $onError->("JSON error: $@"); return; }
            $onDone->($data);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 10 }
    );

    $http->get($url, 'Accept' => 'application/json');
}

# ---------------------------------------------------------------------------
# GET /ws/2/release/<mbid> from MusicBrainz — tracklist + genres for the
# release detail page. On-demand (one release at a time), so the anonymous
# 1 req/sec MusicBrainz rate limit is not a concern.
# ---------------------------------------------------------------------------
sub getReleaseDetails {
    my ($class, $mbid, $onDone, $onError) = @_;

    unless ($mbid) {
        $onError->('No release MBID') if ref $onError eq 'CODE';
        return;
    }

    # Cache hit → return the parsed tracklist/genres without re-fetching.
    my $cacheKey = 'lbf:mb:' . $mbid;
    if (my $cached = $cache->get($cacheKey)) {
        $log->info("MusicBrainz release cache hit: $mbid");
        $onDone->($cached);
        return;
    }

    (my $safe = $mbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    # recordings = tracklist. Genres come from the release-GROUP
    # (getReleaseGroupGenres) — release-level genres are almost always empty.
    my $url = MB_BASE_URL . 'release/' . $safe . '?inc=recordings&fmt=json';

    $log->info("Fetching MusicBrainz release details: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $log->error("MusicBrainz JSON parse error: $@");
                $onError->("JSON error: $@") if ref $onError eq 'CODE';
                return;
            }
            my $parsed = _parseReleaseDetails($data);
            my $ttl    = (@{ $parsed->{media} } || @{ $parsed->{genres} })
                       ? MB_FOUND_TTL : MB_EMPTY_TTL;
            $cache->set($cacheKey, $parsed, $ttl);
            $onDone->($parsed);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );

    $http->get($url,
        'Accept'     => 'application/json',
        'User-Agent' => USER_AGENT,
    );
}

# ---------------------------------------------------------------------------
# GET /ws/2/release-group/<mbid> genres. Genres live on the release-group, not
# the release, so this is what actually populates the detail page. Keyed by
# release-group MBID so releases sharing a group reuse the cache.
# ---------------------------------------------------------------------------
sub getReleaseGroupGenres {
    my ($class, $rgMbid, $onDone, $onError) = @_;

    unless ($rgMbid) {
        $onError->('No release-group MBID') if ref $onError eq 'CODE';
        return;
    }

    my $cacheKey = 'lbf:rggenres:' . $rgMbid;
    if (my $cached = $cache->get($cacheKey)) {
        $onDone->($cached);
        return;
    }

    (my $safe = $rgMbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = MB_BASE_URL . 'release-group/' . $safe . '?inc=genres&fmt=json';

    $log->info("Fetching MusicBrainz release-group genres: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $log->error("MusicBrainz RG JSON parse error: $@");
                $onError->("JSON error: $@") if ref $onError eq 'CODE';
                return;
            }
            my $genres = _parseGenres($data);
            my $ttl    = @$genres ? MB_FOUND_TTL : MB_EMPTY_TTL;
            eval { $cache->set($cacheKey, $genres, $ttl); 1 }
                or $log->warn("RG genre cache set failed: $@");
            $onDone->($genres);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );

    $http->get($url,
        'Accept'     => 'application/json',
        'User-Agent' => USER_AGENT,
    );
}

# Top genre names (most-voted first, max 5) from a MusicBrainz entity response.
sub _parseGenres {
    my ($data) = @_;
    return [] unless ref $data->{genres} eq 'ARRAY';
    my @g = sort { ($b->{count} // 0) <=> ($a->{count} // 0) } @{ $data->{genres} };
    @g = @g[0 .. 4] if @g > 5;
    return [ grep { defined && length } map { $_->{name} } @g ];
}

# ---------------------------------------------------------------------------
# Last.fm genre/style tags — fallback for when MusicBrainz genres AND the
# payload's release_tags are both empty (common for brand-new releases). Tries
# the album's top tags, then the artist's (the artist almost always has tags
# even when a new album doesn't yet). Requires a free Last.fm API key in the
# lastfm_api_key pref; with no key this is a graceful no-op. Detail page only.
# ---------------------------------------------------------------------------
sub getLastfmTags {
    my ($class, $artist, $album, $onDone, $onError) = @_;

    my $key = $prefs->get('lastfm_api_key');
    unless ($key && length($artist // '')) {
        $onDone->([]);
        return;
    }

    my $cacheKey = 'lbf:lfm:' . lc("$artist|" . ($album // ''));
    if (my $cached = $cache->get($cacheKey)) {
        $onDone->($cached);
        return;
    }

    my $finish = sub {
        my $tags = shift || [];
        my $ttl  = @$tags ? LFM_FOUND_TTL : LFM_EMPTY_TTL;
        eval { $cache->set($cacheKey, $tags, $ttl); 1 }
            or $log->warn("Last.fm tag cache set failed: $@");
        $onDone->($tags);
    };

    # Fallback step: artist-level tags.
    my $tryArtist = sub {
        $class->_lastfmCall('artist.gettoptags',
            { artist => $artist, api_key => $key },
            sub { $finish->(shift) },
            sub { $finish->([]) },   # any failure -> empty; never break the page
        );
    };

    # Preferred step: album tags; fall back to the artist if empty/failed.
    if (length $album) {
        $class->_lastfmCall('album.gettoptags',
            { artist => $artist, album => $album, api_key => $key },
            sub {
                my $tags = shift || [];
                @$tags ? $finish->($tags) : $tryArtist->();
            },
            sub { $tryArtist->() },
        );
    }
    else {
        $tryArtist->();
    }
}

# One Last.fm getTopTags call -> cleaned tag-name arrayref via $onDone.
sub _lastfmCall {
    my ($class, $method, $args, $onDone, $onError) = @_;

    my %p = (method => $method, format => 'json', autocorrect => 1, %$args);
    my $qs = join('&', map {
        (my $v = defined $p{$_} ? $p{$_} : '')
            =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
        "$_=$v";
    } sort keys %p);
    my $url = LASTFM_BASE_URL . '?' . $qs;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $onError->("JSON error: $@") if ref $onError eq 'CODE';
                return;
            }
            $onDone->(_parseLastfmTags($data));
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );
    $http->get($url, 'User-Agent' => USER_AGENT);
}

# Top tag names (weight-sorted, max 5) from a Last.fm getTopTags response.
# Last.fm returns a single tag as a hash (not an array); drop blanks/long junk
# and the very-low-weight tail once we already have a few solid tags.
sub _parseLastfmTags {
    my ($data) = @_;
    my $t = $data->{toptags}{tag};
    return [] unless $t;
    my @tags = ref $t eq 'ARRAY' ? @$t : ($t);
    @tags = sort { ($b->{count} // 0) <=> ($a->{count} // 0) } @tags;

    my @out;
    for my $tag (@tags) {
        my $name = ref $tag eq 'HASH' ? $tag->{name} : $tag;
        next unless defined $name;
        $name =~ s/^\s+//; $name =~ s/\s+$//;
        next if $name eq '' || length($name) > 30;
        next if ($tag->{count} // 0) < 10 && @out >= 3;
        push @out, $name;
        last if @out >= 5;
    }
    return \@out;
}

# Normalise a MusicBrainz release lookup into { genres => [names], media => [...] }
sub _parseReleaseDetails {
    my ($data) = @_;

    my %out = (genres => _parseGenres($data), media => []);

    # Tracks are grouped by medium (disc); preserve that grouping
    if (ref $data->{media} eq 'ARRAY') {
        for my $m (@{ $data->{media} }) {
            my @tracks;
            if (ref $m->{tracks} eq 'ARRAY') {
                for my $t (@{ $m->{tracks} }) {
                    my $rec = ref $t->{recording} eq 'HASH' ? $t->{recording} : {};
                    push @tracks, {
                        position => $t->{number} // $t->{position},
                        title    => $t->{title} // $rec->{title} // '',
                        length   => $t->{length} // $rec->{length},
                    };
                }
            }
            push @{ $out{media} }, {
                position => $m->{position},
                format   => $m->{format} // '',
                tracks   => \@tracks,
            };
        }
    }

    return \%out;
}

# ---------------------------------------------------------------------------
# Build Cover Art Archive thumbnail URL
# ---------------------------------------------------------------------------
sub coverArtUrl {
    my ($class, $rel) = @_;
    # caa_release_mbid (with caa_id) is the authoritative "has cover art" signal
    # in the fresh_releases payload. release_mbid is always present, so falling
    # back to it returned a URL even when no art exists (404s + broke the
    # artwork-only filter). Require caa_release_mbid so absence == no artwork.
    my $mbid = $rel->{caa_release_mbid};
    return undef unless $mbid;
    return CAA_BASE_URL . $mbid . '/front-250';
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------
sub _handleResponse {
    my ($resp, $onDone) = @_;

    $log->info("ListenBrainz API response code: " . $resp->code);
    $log->info("ListenBrainz API response length: " . length($resp->content));

    my $data = eval { from_json($resp->content) };
    if ($@) {
        $log->error("JSON parse error: $@");
        $onDone->([]);
        return;
    }

    my $releases = [];

    if (ref $data eq 'HASH') {
        my $payload = $data->{payload};
        if (ref $payload eq 'HASH' && ref $payload->{fresh_releases} eq 'ARRAY') {
            $releases = $payload->{fresh_releases};
            $log->info("Found " . scalar(@$releases) . " releases in payload.fresh_releases");
        } elsif (ref $payload eq 'HASH' && ref $payload->{releases} eq 'ARRAY') {
            $releases = $payload->{releases};
            $log->info("Found " . scalar(@$releases) . " releases in payload.releases");
        } elsif (ref $payload eq 'ARRAY') {
            $releases = $payload;
            $log->info("Found " . scalar(@$releases) . " releases in payload array");
        } elsif (ref $data->{fresh_releases} eq 'ARRAY') {
            $releases = $data->{fresh_releases};
            $log->info("Found " . scalar(@$releases) . " releases in fresh_releases");
        } else {
            $log->info("Unexpected response structure, keys: " . join(', ', keys %$data));
            if (ref $payload eq 'HASH') {
                $log->info("Payload keys: " . join(', ', keys %$payload));
            }
        }
    } elsif (ref $data eq 'ARRAY') {
        $releases = $data;
        $log->info("Found " . scalar(@$releases) . " releases in root array");
    } else {
        $log->error("Unexpected data type: " . ref($data));
    }

    $onDone->($releases);
}

sub _handleError {
    my ($resp, $onError) = @_;
    my $msg = $resp->error // 'Unknown HTTP error';
    $log->error("API error: $msg");
    $onError->($msg) if ref $onError eq 'CODE';
}

1;
