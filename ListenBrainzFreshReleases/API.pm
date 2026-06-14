package Plugins::ListenBrainzFreshReleases::API;

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');

use constant BASE_URL     => 'https://api.listenbrainz.org';
use constant CAA_BASE_URL => 'https://coverartarchive.org/release/';
use constant MB_BASE_URL  => 'https://musicbrainz.org/ws/2/';

# MusicBrainz requires a descriptive User-Agent identifying the application
use constant USER_AGENT   => 'LMS-ListenBrainzFreshReleases/0.4.1 ( https://github.com/CrystalGipsy/LMS-ListenBrainz-New-Releases )';

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

    (my $safe_user = $username) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;

    my $url = sprintf('%s/1/user/%s/fresh_releases?sort=%s&past=%s&future=%s&days=%d',
        BASE_URL, $safe_user, $sort, $past, $future, $days);

    $log->info("Fetching for-you releases: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub { _handleResponse(shift, $args{onDone}) },
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

    my $url = sprintf('%s/1/explore/fresh-releases/?sort=%s&past=%s&future=%s&days=%d&release_date=%s',
        BASE_URL, $sort, $past, $future, $days, $today);

    $log->info("Fetching all releases: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub { _handleResponse(shift, $args{onDone}) },
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

    (my $safe = $mbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = MB_BASE_URL . 'release/' . $safe . '?inc=recordings+genres&fmt=json';

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
            $onDone->(_parseReleaseDetails($data));
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );

    $http->get($url,
        'Accept'     => 'application/json',
        'User-Agent' => USER_AGENT,
    );
}

# Normalise a MusicBrainz release lookup into { genres => [names], media => [...] }
sub _parseReleaseDetails {
    my ($data) = @_;

    my %out = (genres => [], media => []);

    # Genres come back as [{ name, count }] — show the most-voted first
    if (ref $data->{genres} eq 'ARRAY') {
        my @g = sort { ($b->{count} // 0) <=> ($a->{count} // 0) } @{ $data->{genres} };
        @g = @g[0 .. 4] if @g > 5;
        $out{genres} = [ grep { defined && length } map { $_->{name} } @g ];
    }

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
    my $mbid = $rel->{caa_release_mbid} // $rel->{release_mbid};
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
