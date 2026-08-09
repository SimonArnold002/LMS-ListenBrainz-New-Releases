package Plugins::ListenBrainzFreshReleases::Diag;

# Connectivity diagnostic — probes every host this plugin depends on FROM THE
# LMS SERVER and reports one row per target.
#
# WHY THIS EXISTS. The settings page used to check the ListenBrainz token with a
# fetch() in the USER'S BROWSER. That tests the wrong machine: it fails on a
# Pi-hole rule, an ad-blocker, a reverse proxy's connect-src CSP, or a captive
# portal returning HTML (which rejects r.json() and lands in the same catch) —
# none of which say anything about whether LMS can reach ListenBrainz, and none
# of which leave a trace in log.txt. It also could not answer the question users
# actually ask, which is "why is the feed empty", since the token is only one of
# seven upstream dependencies.
#
# So the probes here run server-side, over the same Slim::Networking stack (and
# therefore the same proxy settings) as the real requests, and the whole report
# is reachable over JSON-RPC — a user can paste one result instead of a log.
#
# THREE OUTCOMES, not two. 'fail' means nothing answered (DNS/TLS/network).
# 'warn' means the host ANSWERED but the answer is wrong — a rejected token, a
# mirror whose search index returns nothing, something that is not MusicBrainz
# listening on :5000. Collapsing those into one "unreachable" is the ambiguity
# this module was written to remove, so keep them distinct.

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes ();
use JSON::XS::VersionOneAndTwo;

use Plugins::ListenBrainzFreshReleases::API;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');

use constant API_PKG => 'Plugins::ListenBrainzFreshReleases::API';

# Per-probe timeout. Deliberately shorter than the feeds' FEED_TIMEOUT: this is a
# reachability question, and a host that needs more than 8s to answer at all is
# a finding in its own right.
use constant PROBE_TIMEOUT => 8;

# Global ceiling. Probes run in parallel, so this is not a sum — it exists so a
# single host that neither answers nor errors cannot hold the whole report (and
# with it the settings page) open indefinitely. A target still running when it
# fires keeps its pre-filled 'timed out' row, so the report is always complete.
use constant OVERALL_DEADLINE => 12;

# ---------------------------------------------------------------------------
# Public entry point. Calls back with (\@rows, \%context).
#
# Each row: { key, name, url, status, http, ms, note }, where `url` is already
# REDACTED for display — see _targets. Never hand a caller the raw probe URL;
# the ListenBrainz and Last.fm ones carry credentials.
# ---------------------------------------------------------------------------
sub run {
    my ($class, $cb) = @_;

    my @targets = _targets();
    my @rows;
    my $pending = 0;
    my $done    = 0;
    my $timer;

    my $finish = sub {
        return if $done;
        $done = 1;
        Slim::Utils::Timers::killSpecific($timer) if $timer;

        # Log the whole report too, so a user who can reach log.txt but not the
        # settings page (or who reports this after the fact) still has it.
        $log->info(sprintf('lbf diag: %s %s (%s) %sms%s',
            $_->{status}, $_->{name}, $_->{url},
            $_->{ms} // '-', ($_->{note} ? ' - ' . $_->{note} : '')))
            for @rows;

        $cb->(\@rows, _context());
    };

    for my $i (0 .. $#targets) {
        my $t = $targets[$i];

        if ($t->{skip}) {
            $rows[$i] = _row($t, 'skip', 0, undef, $t->{skip});
            next;
        }

        # Pre-fill, so a probe that never calls back still has a row when the
        # deadline fires. Overwritten by whichever callback lands first.
        $rows[$i] = _row($t, 'fail', 0, undef, 'timed out');
        $pending++;
    }

    unless ($pending) {
        $finish->();
        return;
    }

    $timer = Slim::Utils::Timers::setTimer(undef, time() + OVERALL_DEADLINE, $finish);

    for my $i (0 .. $#targets) {
        my $t = $targets[$i];
        next if $t->{skip};

        my $started = Time::HiRes::time();

        my $settle = sub {
            my ($status, $code, $note) = @_;
            return if $done;
            my $ms = int((Time::HiRes::time() - $started) * 1000);
            $rows[$i] = _row($t, $status, $ms, $code, $note);
            $finish->() unless --$pending;
        };

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                my $code = _httpCode($resp);
                my ($status, $note) = eval { $t->{check}->($resp->content, $code) };
                # A check that dies is a bug in the check, not a network finding
                # — say so rather than reporting the host as broken.
                ($status, $note) = ('warn', "check failed: $@") if $@;
                $settle->($status // 'ok', $code, $note);
            },
            sub {
                my $resp = shift;
                my $code = _httpCode($resp);
                my $err  = eval { $resp->error } // 'no response';

                # An HTTP status means the host answered — that IS reachability,
                # even when the status is an error. Only a missing status is a
                # network-level failure, and the distinction is the whole point.
                if ($code) {
                    # An answered_ok target is asking ONLY "did anything answer",
                    # so quoting the status back would read as a fault when the
                    # status is the expected one. Say what was established.
                    $settle->($t->{answered_ok} ? 'ok' : 'warn', $code,
                        $t->{answered_ok} ? ($t->{answered_note} // 'reachable') : "HTTP $code");
                }
                else {
                    $settle->('fail', 0, $err);
                }
            },
            { timeout => PROBE_TIMEOUT },
        );

        $http->get($t->{url}, %{ $t->{headers} || {} });
    }

    return;
}

# ---------------------------------------------------------------------------
# The probe table. Everything is derived from the SAME accessors the real code
# uses (API::mbBase and friends), so a mirror, a changed base URL or a blank
# credential is reflected here without this file knowing the rules.
# ---------------------------------------------------------------------------
sub _targets {
    my $token   = $prefs->get('token')          // '';
    my $lastfm  = $prefs->get('lastfm_api_key') // '';
    my $muspy   = $prefs->get('muspy_userid')   // '';

    my $mbBase   = API_PKG->mbBase;
    my $mbPublic = API_PKG->mbIsPublic;
    my $mbWhat   = $mbPublic ? 'public MusicBrainz' : 'local mirror';
    my $ua       = { 'User-Agent' => API_PKG->USER_AGENT, 'Accept' => 'application/json' };
    my $json     = { 'Accept' => 'application/json' };

    my @t;

    # --- ListenBrainz core -------------------------------------------------
    # validate-token is the cheapest endpoint that answers on every install:
    # with a token it also tells us whether the token is good, and without one
    # it still proves reachability. That second case is what keeps this row
    # meaningful after the token-free work lands.
    if (length $token) {
        (my $safe = $token) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
        push @t, {
            key  => 'listenbrainz',
            name => 'ListenBrainz',
            url  => API_PKG->baseUrl . '/1/validate-token?token=' . $safe,
            # REDACTED — the raw URL above carries the token and must never
            # leave this sub.
            display => API_PKG->baseUrl . '/1/validate-token?token=***',
            headers => $json,
            check   => sub {
                my ($content) = @_;
                my $d = eval { from_json($content) };
                return ('warn', 'answered, but not JSON') if $@ || ref $d ne 'HASH';
                return ('warn', 'token rejected by ListenBrainz') unless $d->{valid};
                my $user = $d->{user_name} // $d->{user} // '';
                return ('ok', length $user ? "token valid (user: $user)" : 'token valid');
            },
        };
    }
    else {
        push @t, {
            key         => 'listenbrainz',
            name        => 'ListenBrainz',
            url         => API_PKG->baseUrl . '/1/validate-token',
            headers     => $json,
            # No token to check, so any HTTP answer is the whole finding.
            answered_ok => 1,
            check       => sub { ('ok', 'reachable (no token set)') },
        };
    }

    # --- ListenBrainz Labs (similar-artists; drives the DSTM radio) ---------
    push @t, {
        key     => 'lb_labs',
        name    => 'ListenBrainz Labs',
        url     => API_PKG->labsUrl . '/similar-artists/json?artist_mbids='
                 . API_PKG->mbProbeMbid . '&algorithm=' . API_PKG->similarAlgo,
        headers => $json,
        check   => sub {
            my ($content) = @_;
            my $d = eval { from_json($content) };
            return ('warn', 'answered, but not JSON') if $@;
            return ('ok', 'reachable');
        },
    };

    # --- MusicBrainz identity ----------------------------------------------
    # Asserting the NAME is what separates "MusicBrainz answered" from "something
    # is listening on :5000" — the same check the mirror auto-detect relies on.
    push @t, {
        key     => 'musicbrainz',
        name    => "MusicBrainz ($mbWhat)",
        url     => $mbBase . 'artist/' . API_PKG->mbProbeMbid . '?fmt=json',
        headers => $ua,
        check   => sub {
            my ($content) = @_;
            my $d = eval { from_json($content) };
            return ('warn', 'answered, but not JSON') if $@ || ref $d ne 'HASH';
            my $name = $d->{name} // '';
            return ('ok', 'identified correctly') if $name eq API_PKG->mbProbeName;
            return ('warn', "answered, but this is not MusicBrainz (name: '$name')");
        },
    };

    # --- MusicBrainz search index ------------------------------------------
    # A musicbrainz-docker mirror serves browses from Postgres and SEARCH from
    # Solr. An unbuilt Solr index returns 0 for every query while browses work
    # perfectly, so the row above passes and name resolution silently fails.
    # That failure has cost real debugging time; it gets its own row.
    push @t, {
        key     => 'mb_search',
        name    => 'MusicBrainz search index',
        url     => $mbBase . 'artist/?query=' . API_PKG->mbProbeName . '&fmt=json',
        headers => $ua,
        check   => sub {
            my ($content) = @_;
            my $d = eval { from_json($content) };
            return ('warn', 'answered, but not JSON') if $@ || ref $d ne 'HASH';
            my $count = $d->{count} // 0;
            return ('ok', "$count results") if $count > 0;
            return ('warn', $mbPublic
                ? 'search returned 0 results'
                : "search returned 0 results - this mirror's Solr index is probably not built");
        },
    };

    # --- Cover Art Archive --------------------------------------------------
    # Fetched server-side by the image proxy, so a block here shows up as missing
    # artwork rather than a broken feed.
    #
    # The probe id is an ARTIST mbid on a RELEASE endpoint, so CAA correctly 404s
    # — deliberately, to avoid hardcoding a release whose art could later be
    # removed and turn this row red for everyone at once. A 404 still proves DNS,
    # TLS and HTTP all reached the service, which is the entire claim. The note
    # says that outright rather than quoting "HTTP 404" back at the user, which
    # read as a fault on the first real report.
    push @t, {
        key           => 'coverart',
        name          => 'Cover Art Archive',
        url           => API_PKG->caaBaseUrl . API_PKG->mbProbeMbid . '/front-250',
        answered_ok   => 1,
        answered_note => 'reachable (this probe expects a 404)',
        check         => sub { ('ok', 'reachable') },
    };

    # --- Last.fm (optional) -------------------------------------------------
    if (length $lastfm) {
        (my $safe = $lastfm) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
        push @t, {
            key     => 'lastfm',
            name    => 'Last.fm',
            url     => API_PKG->lastfmUrl . '?method=auth.gettoken&format=json&api_key=' . $safe,
            display => API_PKG->lastfmUrl . '?method=auth.gettoken&format=json&api_key=***',
            check   => sub {
                my ($content) = @_;
                my $d = eval { from_json($content) };
                return ('warn', 'answered, but not JSON') if $@ || ref $d ne 'HASH';
                return ('ok', 'API key valid') if !$d->{error} && $d->{token};
                return ('warn', 'Last.fm rejected this API key');
            },
        };
    }
    else {
        push @t, {
            key  => 'lastfm',
            name => 'Last.fm',
            url  => API_PKG->lastfmUrl,
            skip => 'no API key set (optional)',
        };
    }

    # --- MuSpy (optional) ---------------------------------------------------
    if (length $muspy) {
        (my $safe = $muspy) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
        push @t, {
            key     => 'muspy',
            name    => 'MuSpy',
            url     => API_PKG->muspyUrl . '/releases/' . $safe . '?limit=1',
            headers => $json,
            check   => sub {
                my ($content) = @_;
                my $d = eval { from_json($content) };
                return ('warn', 'answered, but not JSON') if $@;
                return ('ok', 'reachable');
            },
        };
    }
    else {
        push @t, {
            key  => 'muspy',
            name => 'MuSpy',
            url  => API_PKG->muspyUrl,
            skip => 'no user id set (optional)',
        };
    }

    return @t;
}

# Non-HTTP context that explains a lot of failures on its own.
#
# CREDENTIALS ARE REPORTED AS PRESENCE ONLY. A diagnostic exists to be pasted
# into a forum thread; it must be safe to paste. Never add the value of a token
# or key here, however convenient it looks while debugging.
sub _context {
    my %c;

    my $token = $prefs->get('token')    // '';
    my $user  = $prefs->get('username') // '';

    $c{username} = length $user  ? $user                          : '(not set)';
    $c{token}    = length $token ? 'set (' . length($token) . ' chars)' : '(not set)';

    $c{proxy} = eval { preferences('server')->get('webproxy') } || '(none)';

    $c{services} = eval {
        require Plugins::ListenBrainzFreshReleases::Browse;
        [ map {{
            name      => $_->{name},
            installed => $_->{installed},
            priority  => $_->{priority},
        }} @{ Plugins::ListenBrainzFreshReleases::Browse::serviceStatus() || [] } ];
    } || [];

    return \%c;
}

sub _row {
    my ($t, $status, $ms, $code, $note) = @_;
    return {
        key    => $t->{key},
        name   => $t->{name},
        url    => $t->{display} // $t->{url},
        status => $status,
        ms     => $ms,
        http   => $code // 0,
        note   => $note // '',
    };
}

# An HTTP status proves the host answered. SimpleAsyncHTTP exposes it as ->code
# on the response, but the error path is not consistent about setting it across
# LMS versions, so fall back to digging a status out of the error string rather
# than misreporting an answered request as a network failure.
sub _httpCode {
    my ($resp) = @_;

    my $code = eval { $resp->code };
    return $code if defined $code && $code =~ /^\d{3}$/;

    my $err = eval { $resp->error };
    return $1 if defined $err && $err =~ /\b([1-5]\d\d)\b/;

    return 0;
}

1;

__END__
