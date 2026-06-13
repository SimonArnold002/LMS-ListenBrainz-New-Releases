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
use constant MAX_ITEMS    => 50;

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

    if (scalar @$releases > MAX_ITEMS) {
        $releases = [ @{$releases}[0 .. MAX_ITEMS - 1] ];
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
