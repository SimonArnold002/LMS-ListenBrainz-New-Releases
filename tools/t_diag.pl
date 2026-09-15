#!/usr/bin/env perl
#
# t_diag.pl — behavioural suite for the server-side connectivity diagnostic.
#
#   perl tools/t_diag.pl
#
# WHY THIS EXISTS. The check it replaces ran a fetch() in the USER'S BROWSER and
# painted one string, "Could not reach ListenBrainz to check the token", for every
# failure it could have. That string was reported from the field on 0.9.149 and the
# LMS server had made no request at all — the browser had been blocked by something
# local (a Pi-hole rule, a reverse-proxy CSP, a portal returning HTML). The whole
# value of Diag.pm is that it does NOT collapse distinguishable outcomes, so this
# suite is mostly about keeping them distinguishable:
#
#   * 'fail' = nothing answered            (DNS / TLS / network)
#   * 'warn' = answered, answer is wrong   (bad token, empty search index, HTTP 500)
#   * 'skip' = not configured              (optional service, not a problem)
#
# A regression that folds 'warn' into 'fail' would re-create exactly the ambiguity
# this feature exists to remove, and would do it silently — hence sections 2-5.
#
# The REAL Diag.pm is loaded (not extracted sub bodies) against a driveable HTTP
# stub, so every assertion runs shipped code. No LMS needed.
#
#   1. Probe coverage      — every dependency has a row; optional ones skip cleanly.
#   2. Answered vs not     — 500 and 404 are NOT network failures.
#   3. Semantic checks     — bad token, impostor on :5000, unbuilt Solr index.
#   4. Token-free install  — the LB row survives with no token set.
#   5. Redaction           — no credential reaches a row url or the context.
#   6. Deadline            — a silent host yields a complete report, callback once.
#
# Anti-test it: LBF_DIAG=<mutated copy> perl tools/t_diag.pl
#
# Exit 0 = all pass.
use strict;
use warnings;
use File::Spec;

my $ROOT = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
my $DIAG = $ENV{LBF_DIAG} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Diag.pm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}

# ---------------------------------------------------------------- stub world --
# Everything Diag.pm pulls in, marked loaded in %INC so its own `use` lines are
# no-ops. Only the HTTP layer and the prefs are driveable; the rest is inert.
BEGIN {
    # %INC suppresses the load, but `use` still calls import — which is how the
    # real modules export logger/preferences/from_json, so the stubs must too.
    package Slim::Utils::Log;
    sub logger { bless {}, 'T::Log' }
    sub import { no strict 'refs'; *{ caller() . '::logger' } = \&logger }
    $INC{'Slim/Utils/Log.pm'} = 1;

    package T::Log;
    sub info {} sub warn {} sub error {} sub debug {} sub is_info { 0 }

    package Slim::Utils::Prefs;
    our %STORE;
    sub preferences { bless { ns => $_[0] }, 'T::Prefs' }
    sub import { no strict 'refs'; *{ caller() . '::preferences' } = \&preferences }
    $INC{'Slim/Utils/Prefs.pm'} = 1;

    package T::Prefs;
    sub get { my ($s, $k) = @_; return $Slim::Utils::Prefs::STORE{ $s->{ns} }{$k} }

    package Slim::Utils::Timers;
    our @T;
    # $when is RECORDED and fire() honours it. The staggered same-host probes and
    # the overall deadline are both timers, and firing them in REGISTRATION order
    # would run the 12s deadline before a 1.1s probe — inverting real time and
    # making the pacing look broken when it is not.
    sub setTimer { my (undef, $when, $cb) = @_; push @T, { cb => $cb, when => $when, killed => 0 }; return $T[-1] }
    sub killSpecific { my ($t) = @_; $t->{killed} = 1 if ref $t eq 'HASH' }
    sub fire {
        for my $t (sort { $a->{when} <=> $b->{when} } @T) { next if $t->{killed}; $t->{cb}->() }
    }
    sub reset { @T = () }
    $INC{'Slim/Utils/Timers.pm'} = 1;

    # Real JSON, so a check that mis-parses fails here rather than passing against
    # a stub that hands back whatever was asked for.
    package JSON::XS::VersionOneAndTwo;
    require JSON::PP;
    sub from_json { JSON::PP->new->utf8->decode($_[0]) }
    sub import { no strict 'refs'; *{ caller() . '::from_json' } = \&from_json }
    $INC{'JSON/XS/VersionOneAndTwo.pm'} = 1;

    # --- driveable HTTP ----------------------------------------------------
    # Routes are matched against the request URL in order. A url matching NO
    # route never calls back at all — that is how section 6 simulates a host
    # that neither answers nor errors.
    package Slim::Networking::SimpleAsyncHTTP;
    our @ROUTES;
    our @REQUESTS;
    sub new { my ($c, $okcb, $errcb) = @_; bless { ok => $okcb, err => $errcb }, $c }
    sub get {
        my ($self, $url) = @_;
        push @REQUESTS, $url;
        for my $r (@ROUTES) {
            next unless $url =~ $r->{match};
            my $resp = bless {
                content => $r->{content} // '',
                code    => $r->{code},
                error   => $r->{error},
            }, 'T::Resp';
            $r->{error} || (defined $r->{code} && $r->{code} >= 400)
                ? $self->{err}->($resp)
                : $self->{ok}->($resp);
            return;
        }
        return;   # silent host
    }
    # POST routes exactly like GET (REQUESTS records the URL), and records the
    # body separately — section 5 needs to tell "the key is sent" apart from "the
    # key is in the URL". Body is the trailing odd argument, as LMS takes it.
    our @BODIES;
    sub post {
        my ($self, $url, @rest) = @_;
        push @BODIES, (@rest % 2 ? pop @rest : '');
        return $self->get($url);
    }
    $INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;

    package T::Resp;
    sub content { $_[0]{content} }
    sub code    { $_[0]{code} }
    sub error   { $_[0]{error} }

    # --- the API accessors Diag reads --------------------------------------
    package Plugins::ListenBrainzFreshReleases::API;
    sub baseUrl     { 'https://api.listenbrainz.org' }
    sub labsUrl     { 'https://labs.api.listenbrainz.org' }
    sub caaBaseUrl  { 'https://coverartarchive.org/release/' }
    sub lastfmUrl   { 'https://ws.audioscrobbler.com/2.0/' }
    # The key accessors. The built-in key is the ONLY key (no user override since
    # 2026-09-14). $BUILTIN is driveable so sections can model a specific key, or
    # an install with no key at all (a mangled constant).
    our $BUILTIN = 'BUILTINLASTFMKEY';
    sub lastfmKey        { $BUILTIN }
    sub lastfmKeySource  { length $BUILTIN ? 'builtin' : 'none' }
    sub lastfmLatchState { length $BUILTIN ? 'builtin: ok' : 'no key' }
    sub muspyUrl    { 'https://muspy.com/api/1' }
    sub similarAlgo { 'algo' }
    sub mbProbeMbid { 'a74b1b7f-06a0-4672-a641-eb3353aa608d' }
    sub mbProbeName { 'Radiohead' }
    sub USER_AGENT  { 'test/1' }
    our $MB_BASE   = 'http://localhost:5000/ws/2/';
    our $MB_PUBLIC = 0;
    sub mbBase     { $MB_BASE }
    sub mbIsPublic { $MB_PUBLIC }
    sub hostedUrl     { 'https://api.lms-community.org/music/' }
    sub hostedHeaders { { 'X-LMS-Plugin-ID' => 'Plugins::ListenBrainzFreshReleases::Plugin' } }
    $INC{'Plugins/ListenBrainzFreshReleases/API.pm'} = 1;

    package Plugins::ListenBrainzFreshReleases::Browse;
    sub serviceStatus { [ { key => 'qobuz', name => 'Qobuz', installed => 1, priority => 1 } ] }
    $INC{'Plugins/ListenBrainzFreshReleases/Browse.pm'} = 1;
}

require $DIAG;
my $DIAGPKG = 'Plugins::ListenBrainzFreshReleases::Diag';

# ------------------------------------------------------------------ helpers --
my $NS = 'plugin.listenbrainzfreshreleases';

sub setPrefs { %{ $Slim::Utils::Prefs::STORE{$NS} } = @_ }

sub routes { @Slim::Networking::SimpleAsyncHTTP::ROUTES = @_ }

# Healthy answers for everything, so a section only has to override the one
# target it is about.
sub healthy {
    return (
        { match => qr{validate-token},   content => '{"valid":true,"user_name":"simon"}' },
        { match => qr{similar-artists},  content => '[]' },
        { match => qr{artist/\?query=},  content => '{"count":3,"artists":[]}' },
        { match => qr{artist/a74b1b7f},  content => '{"name":"Radiohead"}' },
        # Hosted LMS-community API. Echoes the same probe MBID the row asserts
        # against, so a healthy run settles it 'ok'.
        { match => qr{lms-community},    content => '{"name":"Radiohead","mbid":"a74b1b7f-06a0-4672-a641-eb3353aa608d"}' },
        { match => qr{coverartarchive},  content => 'binary' },
        { match => qr{audioscrobbler},   content => '{"token":"abc"}' },
        { match => qr{muspy},            content => '[]' },
    );
}

# Run the diagnostic. The result also lands in these globals, because section 6
# inspects it AFTER the deadline timer fires — i.e. after this sub has returned,
# at which point a lexical captured here would be invisible to the caller.
our ($ROWS, $CTX, $CALLS);
sub runDiag {
    Slim::Utils::Timers::reset();
    @Slim::Networking::SimpleAsyncHTTP::REQUESTS = ();
    @Slim::Networking::SimpleAsyncHTTP::BODIES   = ();

    ($ROWS, $CTX, $CALLS) = (undef, undef, 0);
    $DIAGPKG->run(sub { ($ROWS, $CTX) = @_; $CALLS++ });

    return ($ROWS, $CTX, $CALLS);
}

# Healthy answers with the PUBLIC MusicBrainz base (section 8). Kept separate from
# healthy() because that one is written around the localhost mirror the rest of the
# suite uses — which is exactly why the pacing was uncovered until 0.9.161.
sub healthy_public {
    return (
        { match => qr{validate-token},   content => '{"valid":true,"user_name":"simon"}' },
        { match => qr{similar-artists},  content => '[]' },
        { match => qr{artist/\?query=},  content => '{"count":3,"artists":[]}' },
        { match => qr{artist/a74b1b7f},  content => '{"name":"Radiohead"}' },
        # Hosted LMS-community API. Echoes the same probe MBID the row asserts
        # against, so a healthy run settles it 'ok'.
        { match => qr{lms-community},    content => '{"name":"Radiohead","mbid":"a74b1b7f-06a0-4672-a641-eb3353aa608d"}' },
        { match => qr{coverartarchive},  content => 'binary' },
    );
}

# Run, then let every queued timer fire, then return the settled report.
sub runDiagFired {
    my @r = runDiag();
    Slim::Utils::Timers::fire();
    return ($ROWS, $CTX, $CALLS);
}

sub byKey {
    my ($rows) = @_;
    return { map { $_->{key} => $_ } @{ $rows || [] } };
}

# =============================================================== 1. coverage ==
print "\n1. Probe coverage\n";
{
    setPrefs(token => 'TOKENSECRET', username => 'simon', lastfm_api_key => '', muspy_userid => '');
    routes(healthy());
    my ($rows, $ctx, $calls) = runDiag();
    my $r = byKey($rows);

    ok($calls == 1, 'callback fires exactly once');
    ok(scalar(grep { defined } @$rows) == scalar(@$rows), 'no holes in the report');

    for my $k (qw(listenbrainz lb_labs musicbrainz mb_search coverart lastfm muspy)) {
        ok(exists $r->{$k}, "row present: $k");
    }

    ok($r->{listenbrainz}{status} eq 'ok', 'valid token -> ok');
    ok(scalar($r->{listenbrainz}{note} =~ /simon/), 'valid token names the user');
    ok($r->{musicbrainz}{status} eq 'ok', 'MusicBrainz identity -> ok');
    ok(scalar($r->{musicbrainz}{name} =~ /mirror/i), 'MB row names the mirror it tested');

    # Unconfigured optional services are NOT failures. Reporting them as failures
    # is how a report full of red noise trains people to ignore it.
    # No user key is no longer "no key": the built-in one is probed.
    ok($r->{lastfm}{status} eq 'ok', 'no user Last.fm key -> the built-in key is probed, ok');
    ok(scalar($r->{lastfm}{note} =~ /built-in/i), '...and the row says it was the built-in key');
    ok($r->{muspy}{status}  eq 'skip', 'no MuSpy id -> skip, not fail');
    ok(!grep({ $_ =~ /muspy/ } @Slim::Networking::SimpleAsyncHTTP::REQUESTS),
       'a skipped target issues no request');

    # An install with no key AT ALL (a mangled built-in constant) still skips cleanly.
    {
        local $Plugins::ListenBrainzFreshReleases::API::BUILTIN = '';
        routes(healthy());
        my $n = byKey((runDiag())[0]);
        ok($n->{lastfm}{status} eq 'skip', 'no key at all -> skip, not fail');
        ok(!grep({ $_ =~ /audioscrobbler/ } @Slim::Networking::SimpleAsyncHTTP::REQUESTS),
           '...and issues no Last.fm request');
    }
}

# =========================================================== 2. answered/not ==
print "\n2. Answered is not the same as reachable-and-fine\n";
{
    setPrefs(token => 'T', username => 'simon', lastfm_api_key => '', muspy_userid => '');

    # No HTTP status at all = a genuine network failure.
    routes({ match => qr{validate-token}, error => 'Connect timed out' }, healthy());
    my $r = byKey((runDiag())[0]);
    ok($r->{listenbrainz}{status} eq 'fail', 'no status -> fail');
    ok($r->{listenbrainz}{http} == 0, 'no status -> http 0');

    # A 500 means the host answered. That is reachability, and calling it a
    # network failure is the misdiagnosis this module was written to stop.
    routes({ match => qr{validate-token}, code => 500, error => '500 Server Error' }, healthy());
    $r = byKey((runDiag())[0]);
    ok($r->{listenbrainz}{status} eq 'warn', 'HTTP 500 -> warn, not fail');
    ok($r->{listenbrainz}{http} == 500, 'HTTP 500 -> code recorded');

    # The status can arrive only in the error string on some LMS versions.
    routes({ match => qr{validate-token}, error => 'HTTP 503 Service Unavailable' }, healthy());
    $r = byKey((runDiag())[0]);
    ok($r->{listenbrainz}{http} == 503, 'status recovered from the error string');
    ok($r->{listenbrainz}{status} eq 'warn', '...and classified as answered');

    # CAA is probed with an ARTIST mbid, so a 404 is the expected answer and
    # still proves DNS+TLS+HTTP reached it.
    routes({ match => qr{coverartarchive}, code => 404, error => '404 Not Found' }, healthy());
    $r = byKey((runDiag())[0]);
    ok($r->{coverart}{status} eq 'ok', 'CAA 404 -> ok (reachability is the claim)');
    # The first real report asked whether the 404 was a fault. It is the expected
    # answer for this probe, so the note has to say so rather than quote it back.
    ok(scalar($r->{coverart}{note} =~ /expects a 404/), 'CAA note explains the expected 404');
    ok(scalar($r->{coverart}{note} !~ /^HTTP/), '...rather than reading as an error');

    routes({ match => qr{coverartarchive}, error => 'Name or service not known' }, healthy());
    $r = byKey((runDiag())[0]);
    ok($r->{coverart}{status} eq 'fail', 'CAA DNS failure -> fail');
}

# ============================================================ 3. semantics ====
print "\n3. Answered, but the answer is wrong\n";
{
    setPrefs(token => 'T', username => 'simon', lastfm_api_key => 'K', muspy_userid => '');

    routes({ match => qr{validate-token}, content => '{"valid":false}' }, healthy());
    my $r = byKey((runDiag())[0]);
    ok($r->{listenbrainz}{status} eq 'warn', 'rejected token -> warn, not fail');
    ok(scalar($r->{listenbrainz}{note} =~ /reject/i), 'rejected token says so');

    routes({ match => qr{validate-token}, content => '<html>portal</html>' }, healthy());
    $r = byKey((runDiag())[0]);
    ok($r->{listenbrainz}{status} eq 'warn', 'HTML instead of JSON -> warn');
    ok(scalar($r->{listenbrainz}{note} =~ /JSON/i), '...and names the reason');

    # Something else listening on :5000 is a real setup, and it is why the probe
    # asserts the NAME rather than just a 200.
    routes({ match => qr{artist/a74b1b7f}, content => '{"name":"Some Other Service"}' }, healthy());
    $r = byKey((runDiag())[0]);
    ok($r->{musicbrainz}{status} eq 'warn', 'impostor on the MB port -> warn');
    ok(scalar($r->{musicbrainz}{note} =~ /not MusicBrainz/i), '...and says it is not MusicBrainz');

    # The mirror failure that browses fine and searches nothing.
    routes({ match => qr{artist/\?query=}, content => '{"count":0,"artists":[]}' }, healthy());
    $r = byKey((runDiag())[0]);
    ok($r->{mb_search}{status} eq 'warn', 'empty search index -> warn');
    ok(scalar($r->{mb_search}{note} =~ /Solr|index/i), '...and names the Solr index');
    ok($r->{musicbrainz}{status} eq 'ok', '...while the identity row still passes');

    {
        local $Plugins::ListenBrainzFreshReleases::API::MB_PUBLIC = 1;
        routes({ match => qr{artist/\?query=}, content => '{"count":0}' }, healthy());
        my $p = byKey((runDiag())[0]);
        ok(scalar($p->{mb_search}{note} !~ /Solr/), 'public MB is not blamed for a mirror index');
    }

    routes({ match => qr{audioscrobbler}, content => '{"error":10,"message":"Invalid API key"}' }, healthy());
    $r = byKey((runDiag())[0]);
    ok($r->{lastfm}{status} eq 'warn', 'bad Last.fm key -> warn');
}

# ========================================================= 4. token-free ======
print "\n4. Survives a token-free install\n";
{
    setPrefs(token => '', username => 'simon', lastfm_api_key => '', muspy_userid => '');
    routes({ match => qr{validate-token}, code => 400, error => '400 Bad Request' }, healthy());
    my ($rows, $ctx) = runDiag();
    my $r = byKey($rows);

    # The whole point of scoping this as connectivity rather than a token check:
    # the row must keep working when the token goes away.
    ok(exists $r->{listenbrainz}, 'LB row still present with no token');
    ok($r->{listenbrainz}{status} eq 'ok', 'no token + host answers -> ok');
    ok(scalar($r->{listenbrainz}{url} !~ /token=/), 'no token in the probe url');
    ok($ctx->{token} eq '(not set)', 'context reports the token as unset');
}

# =========================================================== 5. redaction =====
print "\n5. A report must be safe to paste\n";
{
    my $tok = 'ZZTOPSECRETTOKEN';
    my $key = 'YYLASTFMSECRET';
    my $usr = 'XXMUSPYUSERID';
    setPrefs(token => $tok, username => 'simon', muspy_userid => $usr);
    local $Plugins::ListenBrainzFreshReleases::API::BUILTIN = $key;
    routes(healthy());
    my ($rows, $ctx) = runDiag();

    my $blob = join "\n", map { join '|', map { $_ // '' } @{$_}{qw(key name url status note)} } @$rows;
    ok(index($blob, $tok) < 0, 'token appears nowhere in the rows');
    ok(index($blob, $key) < 0, 'Last.fm key appears nowhere in the rows');
    # A MuSpy user id is a public identifier, not a credential — but the section's
    # own rule is "it must be safe to paste", and the row had no `display` key at
    # all until 0.9.161 while the Last.fm row beside it did.
    ok(index($blob, $usr) < 0, 'MuSpy user id appears nowhere in the rows');
    ok(scalar(grep { index($_, $usr) >= 0 } @Slim::Networking::SimpleAsyncHTTP::REQUESTS),
       '...while the real MuSpy id IS still sent');
    ok(index(join('|', map { $_ // '' } values %$ctx), $tok) < 0, 'token not in the context');
    ok(scalar($ctx->{token} =~ /^set \(\d+ chars\)$/), 'token reported as presence + length only');

    # The credential must still reach the wire, or the check is testing nothing.
    ok(scalar(grep { index($_, $tok) >= 0 } @Slim::Networking::SimpleAsyncHTTP::REQUESTS),
       'the real token IS sent to ListenBrainz');

    # The Last.fm key must never be in a URL — LMS core logs a failed request's URI
    # at WARN — but it must still be SENT, or this is testing nothing.
    ok(index(join('|', @Slim::Networking::SimpleAsyncHTTP::REQUESTS), $key) < 0,
       'the Last.fm key is in NO request URL');
    ok(scalar(grep { index($_, $key) >= 0 } @Slim::Networking::SimpleAsyncHTTP::BODIES),
       '...while it IS sent, in the POST body');
    ok(index(join('|', map { $_ // '' } values %$ctx), $key) < 0, 'Last.fm key not in the context');
    ok(($ctx->{lastfm} // '') eq 'builtin: ok', 'context names the key STATE only');
    ok(ref $ctx->{services} eq 'ARRAY' && @{ $ctx->{services} }, 'streaming services reported');
}

# ============================================================ 6. deadline =====
print "\n6. A silent host cannot hold the report open\n";
{
    setPrefs(token => 'T', username => 'simon', lastfm_api_key => '', muspy_userid => '');

    # Everything answers except ListenBrainz, which never calls back at all.
    routes(grep { $_->{match} !~ /validate-token/ } healthy());
    runDiag();

    ok($CALLS == 0, 'report does not settle while a probe is outstanding');
    Slim::Utils::Timers::fire();
    ok($CALLS == 1, 'deadline settles the report exactly once');

    my $r = byKey($ROWS);
    # 8 rows: listenbrainz, lb_labs, musicbrainz, mb_search, hosted_api, coverart,
    # lastfm, muspy. Bump this when a probe is added — a silent host must never
    # cost the report a row, which is the whole point of this section.
    ok(scalar(keys %$r) == 8, 'report is COMPLETE despite the silent host');
    ok($r->{listenbrainz}{status} eq 'fail', 'silent host -> fail');
    ok(scalar($r->{listenbrainz}{note} =~ /timed out/i), '...noted as a timeout');
    ok($r->{musicbrainz}{status} eq 'ok', 'the hosts that did answer keep their results');
    # The community-API row probes the route the plugin calls (2026-09-14: `/aliases`,
    # not `/mbid`), and no longer promises a MusicBrainz fallback it does not have.
    ok(scalar(($r->{hosted_api}{url} // '') =~ m{/artist/[^/]+/aliases$}),
       'community-API probe hits /aliases');
    my $diagSrc = do { open(my $fh, '<:encoding(UTF-8)', $DIAG) or die "$DIAG: $!"; local $/; <$fh> };
    ok(scalar($diagSrc !~ /MusicBrainz fallback still applies/),
       'community-API amber note no longer promises a MusicBrainz fallback');

    # A late deadline must not deliver a second report to the settings page.
    routes(healthy());
    runDiag();
    ok($CALLS == 1, 'healthy run settles once');
    Slim::Utils::Timers::fire();
    ok($CALLS == 1, 'a stale deadline cannot re-deliver');
}

# ========================================== 7. the probe artist really exists ==
#
# THE ONLY ASSERTION HERE THAT NEEDS A NETWORK, AND IT HAS TO.
#
# 0.9.94 shipped MB_PROBE_MBID as 'a74b1b7f-06a0-4672-a641-eb3353aa608d', a
# mangled Radiohead id sharing only the first block, which 404s on musicbrainz.org
# and on every mirror. autodetectMirror validates a candidate by fetching that
# artist and comparing the name, so the probe could never validate and NO MIRROR
# WAS EVER ADOPTED — for four years of releases, silently.
#
# It survived because the failure is INVISIBLE BY CONSTRUCTION: a 404 on the
# probe artist is indistinguishable from "nothing is running on :5000", the
# correct and silent outcome for most users. Every section above this one would
# pass with a bogus id, because they all stub the response. Reading the code
# cannot catch it either — the id looks exactly like a real one.
#
# So this asks MusicBrainz. Skipped cleanly when offline, so the suite stays
# usable without a network.
print "\n7. The mirror-probe artist exists (live MusicBrainz)\n";
{
    my $src = do {
        open(my $fh, '<:encoding(UTF-8)', File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'API.pm'))
            or die "API.pm: $!";
        local $/; <$fh>;
    };
    my ($mbid) = $src =~ /MB_PROBE_MBID\s*=>\s*'([^']+)'/;
    my ($name) = $src =~ /MB_PROBE_NAME\s*=>\s*'([^']+)'/;

    if (!$mbid || !$name) {
        ok(0, 'MB_PROBE_MBID / MB_PROBE_NAME found in API.pm');
    }
    else {
        # THE HTTP STATUS MUST BE READ SEPARATELY FROM THE BODY.
        #
        # The first cut of this gate keyed "offline" on an empty body — and
        # MusicBrainz answers a 404 with an empty body, so a bogus MBID SKIPPED
        # instead of failing. That is precisely the bug this section exists to
        # catch, so the gate would have been decorative. Caught only by
        # anti-testing it against the old constant; don't collapse these again.
        my $ua  = 'LMS-ListenBrainzFreshReleases-tdiag/1.0 ( https://github.com/SimonArnold002 )';
        my $url = "https://musicbrainz.org/ws/2/artist/$mbid?fmt=json";
        my $out = `curl -s -w '\n%{http_code}' --max-time 8 -A '$ua' '$url' 2>/dev/null`;

        my ($json, $code) = ('', '000');
        if (defined $out && $out =~ /\A(.*)\n(\d{3})\z/s) { ($json, $code) = ($1, $2) }

        if ($code eq '000') {
            print "  SKIP  no network - could not ask MusicBrainz about $mbid\n";
        }
        # ...AND RATE LIMITING IS NOT AN ANSWER EITHER. MusicBrainz allows ~1
        # anonymous request per second and replies 503 (429 behind some proxies)
        # when you exceed it. That says nothing about whether the MBID is real, so
        # failing on it reports a fault in the plugin for a fault in the test's own
        # traffic — observed once while iterating on this suite, which is the same
        # class of false alarm that section 8 exists to stop in the product.
        elsif ($code eq '503' || $code eq '429') {
            print "  SKIP  MusicBrainz rate-limited this check (HTTP $code) - re-run to verify $mbid\n";
        }
        elsif ($code ne '200') {
            ok(0, "$mbid is not a real artist on MusicBrainz (HTTP $code) "
                . "- the mirror auto-detect can NEVER succeed");
        }
        else {
            ok(scalar($json =~ /"name"\s*:\s*"\Q$name\E"/),
               "$mbid really is $name on MusicBrainz (or the mirror auto-detect can NEVER succeed)");
        }
    }
}

print "\n8. TWO PROBES OF THE SAME REMOTE HOST ARE STAGGERED\n";
{
    # Both MusicBrainz rows are built from the same _mbBase. With no mirror that is
    # musicbrainz.org, whose anonymous limit is ~1 req/s — fired together, the loser
    # comes back 503 (LMS routes any non-2xx to the ERROR callback) and the report
    # shows a fault on a perfectly healthy install.
    #
    # NB the rest of this suite runs against a LOCALHOST mirror, which is never
    # paced — so nothing here was covered until this section existed.
    local $Plugins::ListenBrainzFreshReleases::API::MB_BASE   = 'https://musicbrainz.org/ws/2/';
    local $Plugins::ListenBrainzFreshReleases::API::MB_PUBLIC = 1;

    setPrefs(username => 'simon', token => 'x' x 36);
    routes(healthy_public());

    my ($rows, $ctx, $calls) = runDiag();

    my @sent = @Slim::Networking::SimpleAsyncHTTP::REQUESTS;
    ok(scalar(grep { m{^https://musicbrainz\.org/} } @sent) == 1,
                                     'only ONE musicbrainz.org request goes out immediately');
    ok(scalar(grep { m{coverartarchive} } @sent) == 1,
                                     'a different host is NOT delayed behind it');
    ok(!$calls,                      'the report does not complete while a probe is queued');

    Slim::Utils::Timers::fire();
    @sent = @Slim::Networking::SimpleAsyncHTTP::REQUESTS;
    ok(scalar(grep { m{^https://musicbrainz\.org/} } @sent) == 2,
                                     'the second musicbrainz.org request follows on its timer');

    my $r = byKey((runDiagFired())[0]);
    ok($r->{musicbrainz}{status} eq 'ok', 'identity row still settles ok');
    ok($r->{mb_search}{status}   eq 'ok', 'search row still settles ok');
}

print "\n9. PUBLIC MUSICBRAINZ PROBES GO THROUGH THE PLUGIN'S ONE QUEUE (2026-09-14)\n";
{
    # Section 8's stagger kept our two probes apart from EACH OTHER, not from a warm
    # already sending to MusicBrainz — and the limit is on the sum. With the plugin's
    # queue available (API::mbGet), the probes are handed to it and Diag adds no
    # stagger of its own. The stub queue here answers straight away; the queue's own
    # pacing is pinned in tools/t_mbqueue.pl.
    no warnings qw(redefine once);
    local $Plugins::ListenBrainzFreshReleases::API::MB_BASE   = 'https://musicbrainz.org/ws/2/';
    local $Plugins::ListenBrainzFreshReleases::API::MB_PUBLIC = 1;
    my (@queued, $hold);
    local *Plugins::ListenBrainzFreshReleases::API::mbGet = sub {
        my ($class, $url, $okcb, $errcb, %o) = @_;
        push @queued, $url;
        $o{onSend}->() if ref $o{onSend} eq 'CODE';
        Slim::Networking::SimpleAsyncHTTP->new($okcb, $errcb)->get($url);
    };
    local *Plugins::ListenBrainzFreshReleases::API::mbQueueWait = sub { $hold };

    setPrefs(username => 'simon', token => 'x' x 36);
    routes(healthy_public());

    $hold = 0;
    runDiag();
    ok(scalar(@queued) == 2, 'both MusicBrainz probes are handed to the plugin\'s queue');
    # Counted BEFORE any timer fires: a Diag stagger would still be holding one back.
    ok(scalar(grep { m{^https://musicbrainz\.org/} } @Slim::Networking::SimpleAsyncHTTP::REQUESTS) == 2,
       '...with no Diag stagger timer layered on top');
    # (healthy_public leaves Last.fm and MuSpy silent, so the report itself only
    # completes at its deadline — read the rows once the timers have fired.)
    my ($rows) = runDiagFired();
    my $r = byKey($rows);
    ok($r->{musicbrainz}{status} eq 'ok' && $r->{mb_search}{status} eq 'ok',
       'both rows settle ok through the queue');

    # MusicBrainz backing off: say so, send nothing.
    @queued = (); $hold = 20;
    ($rows) = runDiagFired();
    $r = byKey($rows);
    ok(!@queued && !scalar(grep { m{musicbrainz\.org} } @Slim::Networking::SimpleAsyncHTTP::REQUESTS),
       'during a MusicBrainz backoff no probe is sent');
    ok($r->{musicbrainz}{status} eq 'warn' && scalar($r->{musicbrainz}{note} =~ /backing off/),
       '...and the row reports the backoff instead of a misleading "timed out"');

    # A mirror is not the plugin's public queue.
    @queued = (); $hold = 0;
    local $Plugins::ListenBrainzFreshReleases::API::MB_BASE   = 'http://localhost:5000/ws/2/';
    local $Plugins::ListenBrainzFreshReleases::API::MB_PUBLIC = 0;
    routes(healthy());
    runDiagFired();
    ok(!@queued, 'a local mirror is probed directly, not through the public queue');
}

print "\n10. A PROBE THE QUEUE NEVER REACHED IS 'NOT PROBED', NOT A TIMEOUT (2026-09-15)\n";
{
    # Seen live 2026-09-14: the identity probe took 11s, so the search probe queued
    # behind it was never sent before the 12s deadline and read "fail / 0 ms / timed
    # out" — a fault reported against a host nobody asked. This stub is the real
    # queue's shape: ONE in flight; the first probe is sent and never answers, the
    # second waits behind it.
    no warnings qw(redefine once);
    local $Plugins::ListenBrainzFreshReleases::API::MB_BASE   = 'https://musicbrainz.org/ws/2/';
    local $Plugins::ListenBrainzFreshReleases::API::MB_PUBLIC = 1;
    my (@front, $busy);
    local *Plugins::ListenBrainzFreshReleases::API::mbGet = sub {
        my ($class, $url, $okcb, $errcb, %o) = @_;
        push @front, $o{front} ? 1 : 0;
        return if $busy++;                              # queued behind the one in flight
        $o{onSend}->() if ref $o{onSend} eq 'CODE';     # sent; never answers
    };
    local *Plugins::ListenBrainzFreshReleases::API::mbQueueWait = sub { 0 };

    setPrefs(username => 'simon', token => 'x' x 36);
    routes(healthy_public());
    my ($rows) = runDiagFired();
    my $r = byKey($rows);

    ok(@front == 2 && !scalar(grep { !$_ } @front), 'both MusicBrainz probes ask the queue for the front');
    ok($r->{mb_search}{status} eq 'warn' && scalar(($r->{mb_search}{note} // '') =~ /not probed/),
       'the probe the queue never sent reads warn / "not probed"');
    ok($r->{musicbrainz}{status} eq 'fail' && scalar(($r->{musicbrainz}{note} // '') =~ /timed out/),
       'the probe that WAS sent and never answered is still fail / "timed out"');
    ok($r->{listenbrainz}{status} eq 'ok', 'rows that answered are untouched');
    ok($r->{lastfm}{status} eq 'fail' && scalar(($r->{lastfm}{note} // '') =~ /timed out/),
       'a silent host outside the queue is still fail / "timed out"');
}

printf("\n%d passed, %d failed\n", $pass, $fail);
exit($fail ? 1 : 0);
