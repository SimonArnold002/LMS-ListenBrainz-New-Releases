#!/usr/bin/env perl
#
# t_tokenfree.pl — the ListenBrainz token is OPTIONAL everywhere except the
# private social feed.
#
# WHAT THIS PINS, and why it is worth a suite of its own:
#
#   Until 0.9.160 the plugin's FLAGSHIP feed (New Releases for You) refused to
#   run without a token, on an endpoint that has never required one. Verified
#   2026-08-12 by fetching a real user's /1/user/<u>/fresh_releases twice — once
#   anonymous, once with that user's token — and comparing: byte-identical
#   payloads (same sha1 over payload.releases, same count, same fields). Nine
#   other LB endpoints the plugin calls compared identical the same way. The ONLY
#   401 in the whole plugin is /1/user/<u>/feed/events, which backs the
#   "Recommended by People You Follow" list.
#
#   So there are two halves to protect, and they pull in OPPOSITE directions:
#     (a) fresh_releases must run on a username alone, and must still SEND a
#         token when one is set (so a token user's request is unchanged);
#     (b) the follow-feed path must STAY token-gated — that gate is correct, and
#         a well-meaning "finish the token-free work" pass could easily strip it,
#         which would turn a clear "no token" into an opaque 401 at runtime.
#
#   (b) is the reason this file exists. (a) alone would be a one-line diff.
#
# Sections 1-3 are BEHAVIOURAL — API.pm is loaded for real and getFreshReleasesForUser
# is driven through a recording HTTP stub, so the assertions are about what the sub
# actually does, not about how its source reads. Section 4 is a source-level check of
# the four follow-feed gates, for the same reason 0.9.145's call-site section is:
# there is no return value to inspect when the point is that a sub was NOT reached.
#
# ANTI-TEST: point LBF_API / LBF_BROWSE at mutated copies.
#   - restore `unless ($username && $token)` in API.pm  -> section 1 goes red
#   - make the Authorization header unconditional       -> section 3 goes red
#   - drop the `if $token` from Browse.pm's _followTile -> section 4 goes red

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);

my $ROOT   = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));
my $API    = $ENV{LBF_API}    || "$ROOT/ListenBrainzFreshReleases/API.pm";
my $BROWSE = $ENV{LBF_BROWSE} || "$ROOT/ListenBrainzFreshReleases/Browse.pm";

my ($pass, $fail) = (0, 0);

# NOTE: every caller must wrap a bare m// or grep in scalar(). A match in the
# LIST-context argument slot returns the match LIST, which shifts $msg out of
# position — on failure the label becomes the condition and the assertion passes
# against any truthy string. That trap silently disarmed three assertions in
# t_trending_empty.pl (see the 0.9.149 notes) and disarmed two here, caught only
# by the anti-test run. The guard below turns a recurrence into a loud failure
# instead of a quiet pass.
sub ok {
    my ($cond, $msg) = @_;
    die "t_tokenfree: assertion called with no message — a bare m// or grep has\n"
      . "shifted the arguments. Wrap the condition in scalar().\n"
        unless defined $msg && length $msg;
    if ($cond) { $pass++; printf "  ok   %s\n", $msg }
    else       { $fail++; printf "  FAIL %s\n", $msg }
}

# ---------------------------------------------------------------------------
# A minimal LMS well enough to load API.pm for real. %PREFS and @REQUESTS are
# the two levers: the first drives the sub, the second records what it did.
# ---------------------------------------------------------------------------
our %PREFS;
our @REQUESTS;

my $stub = tempdir(CLEANUP => 1);
sub stubfile {
    my ($path, $body) = @_;
    my $full = "$stub/$path";
    my $dir  = dirname($full);
    system('mkdir', '-p', $dir) == 0 or die "mkdir $dir: $?";
    open my $fh, '>', $full or die "$full: $!";
    print $fh $body;
    close $fh;
}

stubfile('Slim/Utils/Log.pm', <<'EOF');
package Slim::Utils::Log;
use Exporter 'import'; our @EXPORT = qw(logger);
package Slim::Utils::Log::Obj;
sub AUTOLOAD { my $n = our $AUTOLOAD; return if $n =~ /DESTROY/; return 1 }
package Slim::Utils::Log;
sub logger { bless {}, 'Slim::Utils::Log::Obj' }
sub addLogCategory { 1 }
1;
EOF

# get() reads the harness's %PREFS, so a test can run the same sub as a
# token-holding user and as a username-only user.
stubfile('Slim/Utils/Prefs.pm', <<'EOF');
package Slim::Utils::Prefs;
use Exporter 'import'; our @EXPORT = qw(preferences);
package Slim::Utils::Prefs::Obj;
sub get { my (undef, $k) = @_; return $main::PREFS{$k} }
sub set { my (undef, $k, $v) = @_; $main::PREFS{$k} = $v; 1 }
sub init { 1 } sub setChange { 1 } sub migrate { 1 }
package Slim::Utils::Prefs;
sub preferences { bless {}, 'Slim::Utils::Prefs::Obj' }
1;
EOF

# Always a miss, so every call reaches the network path we want to inspect.
stubfile('Slim/Utils/Cache.pm', <<'EOF');
package Slim::Utils::Cache;
package Slim::Utils::Cache::Obj;
sub get { undef } sub set { 1 } sub remove { 1 }
package Slim::Utils::Cache;
sub new { bless {}, 'Slim::Utils::Cache::Obj' }
1;
EOF

# Records the url + headers instead of making a request. Never calls back, so a
# test observes the REQUEST rather than a synthesised response.
stubfile('Slim/Networking/SimpleAsyncHTTP.pm', <<'EOF');
package Slim::Networking::SimpleAsyncHTTP;
sub new { my ($c, $ok, $err, $opt) = @_; bless { ok => $ok, err => $err }, $c }
sub error { 'stubbed: never answered' }
sub code  { 500 }
sub content { '' }
sub headers { {} }
sub get {
    my ($self, $url, @headers) = @_;
    # $self is kept so the harness can DRAIN the request afterwards — see call_feed.
    push @main::REQUESTS, { url => $url, headers => \@headers, obj => $self };
    return 1;
}
sub post { my $self = shift; $self->get(@_) }
1;
EOF

for my $m (qw(Slim/Utils/Strings Slim/Utils/Timers Slim/Utils/Misc
              Slim/Utils/OSDetect Slim/Utils/PluginManager Slim/Web/ImageProxy
              Slim/Control/Request Slim/Schema Slim/Music/Import)) {
    (my $pkg = $m) =~ s{/}{::}g;
    stubfile("$m.pm", <<"EOF");
package $pkg;
use Exporter 'import'; our \@EXPORT = qw(string cstring);
sub string { '' } sub cstring { '' }
sub AUTOLOAD { my \$n = our \$AUTOLOAD; return if \$n =~ /DESTROY/; return 1 }
1;
EOF
}

stubfile('JSON/XS/VersionOneAndTwo.pm', <<'EOF');
package JSON::XS::VersionOneAndTwo;
use Exporter 'import'; our @EXPORT = qw(to_json from_json encode_json decode_json);
sub to_json { '{}' } sub from_json { {} }
sub encode_json { '{}' } sub decode_json { {} }
1;
EOF

system('mkdir', '-p', "$stub/Plugins/ListenBrainzFreshReleases") == 0 or die;
system('cp', $API, "$stub/Plugins/ListenBrainzFreshReleases/API.pm") == 0 or die;

# API.pm holds the plugin's own store rather than an LMS cache handle, so DB.pm
# has to come with it. It opens NOTHING here: `store()` blesses an empty hash and
# `kver` is a hash lookup, so no SQLite file is touched unless a code path that
# this suite does not drive actually reads or writes one.
system('cp', "$ROOT/ListenBrainzFreshReleases/DB.pm",
             "$stub/Plugins/ListenBrainzFreshReleases/DB.pm") == 0 or die;

unshift @INC, $stub;
require Plugins::ListenBrainzFreshReleases::API;
my $api = 'Plugins::ListenBrainzFreshReleases::API';

# Drive one call and report what came back / what went out.
sub call_feed {
    my (%p) = @_;
    local %PREFS   = (username => $p{username}, token => $p{token});
    local @REQUESTS = ();
    my (@errors, @done);
    $api->getFreshReleasesForUser(
        onDone  => sub { push @done,   $_[0] },
        onError => sub { push @errors, $_[0] },
        days    => 14, past => 1, future => 1,
    );
    my @reqs = @REQUESTS;
    # Snapshot BEFORE draining: the drain below deliberately fails each request, and
    # that failure reaches onError. Returning the post-drain lists would report an
    # error for every call and make section 1's "no error raised" assertion fail on
    # the harness's own cleanup rather than on the code under test.
    my @errSnap  = @errors;
    my @doneSnap = @done;

    # DRAIN. The stub records a request and never answers it, which was fine until
    # the single-flight guard (0.9.184) landed: a second call making the IDENTICAL
    # request is now correctly parked behind the first, so without this section 3's
    # no-token call recorded nothing and three assertions failed. That is the guard
    # working, not breaking — the harness just never let a request finish. Failing
    # them here releases the waiters and leaves the RECORDED request untouched,
    # which is all these assertions read.
    for my $r (@reqs) {
        my $o = $r->{obj} or next;
        eval { $o->{err}->($o); 1 };
    }
    return { errors => \@errSnap, done => \@doneSnap, requests => [@reqs] };
}

sub auth_header_of {
    my ($req) = @_;
    my @h = @{ $req->{headers} };
    while (@h) {
        my ($k, $v) = (shift @h, shift @h);
        return $v if defined $k && $k eq 'Authorization';
    }
    return undef;
}

print "\n1. fresh_releases runs on a USERNAME ALONE (the 0.9.160 fix)\n";
{
    my $r = call_feed(username => 'CrystalGipsy', token => '');
    ok(@{ $r->{errors} } == 0, 'no error raised without a token');
    ok(@{ $r->{requests} } == 1, 'the request is actually made without a token');
    my $url = @{ $r->{requests} } ? ($r->{requests}[0]{url} // '') : '';
    ok(scalar($url =~ m{/1/user/CrystalGipsy/fresh_releases}),
       'and it is the fresh_releases endpoint for the configured user');
}

print "\n2. a missing USERNAME is still a hard stop (the gate that is real)\n";
{
    my $r = call_feed(username => '', token => '');
    ok(@{ $r->{errors} } == 1, 'onError is called with no username');
    ok(@{ $r->{requests} } == 0, 'and no request is made');
    ok(scalar(($r->{errors}[0] // '') !~ /token/i),
       'the error no longer blames the token (it would send users to the wrong field)');

    # A token without a username must NOT be treated as configured.
    my $r2 = call_feed(username => '', token => 'abc123');
    ok(@{ $r2->{errors} } == 1,   'a token alone does not satisfy the gate');
    ok(@{ $r2->{requests} } == 0, 'and still makes no request');
}

print "\n3. the token is SENT when set, ABSENT when not\n";
{
    my $with = call_feed(username => 'CrystalGipsy', token => 'sekrit-token');
    ok(@{ $with->{requests} } == 1, 'token user still makes the request');
    my $withReq = $with->{requests}[0];
    ok($withReq && (auth_header_of($withReq) // '') eq 'Token sekrit-token',
       'Authorization header carries the token verbatim when one is set');

    my $without = call_feed(username => 'CrystalGipsy', token => '');
    my $noneReq = $without->{requests}[0];
    ok($noneReq && !defined auth_header_of($noneReq),
       'NO Authorization header at all when no token is set');
    # An empty "Token " header is worse than none — it is a malformed credential
    # rather than an anonymous request, and LB may reject it outright.
    my @hdrs = $noneReq ? @{ $noneReq->{headers} } : ();
    ok($noneReq && !scalar(grep { defined $_ && /^Token\s*$/ } @hdrs),
       'and no empty "Token " value is sent instead');
    ok($noneReq && scalar(grep { defined $_ && $_ eq 'Accept' } @hdrs),
       'the Accept header survives the rewrite');
}

print "\n4. the PRIVATE follow feed stays token-gated (the anti-regression)\n";
{
    open my $fh, '<', $API or die "$API: $!";
    my $apisrc = do { local $/; <$fh> };
    close $fh;

    # Isolate getFollowFeed so a gate elsewhere in the file cannot satisfy this.
    my ($follow) = $apisrc =~ /sub\s+getFollowFeed\s*\{(.*?)\n\}/s;
    ok(defined $follow, 'getFollowFeed found in API.pm');
    ok(scalar(defined $follow && $follow =~ /unless\s*\(\s*\$username\s*&&\s*\$token\s*\)/),
       'getFollowFeed STILL requires both username and token (the feed is 401 without it)');

    open my $bh, '<', $BROWSE or die "$BROWSE: $!";
    my $bsrc = do { local $/; <$bh> };
    close $bh;

    ok(scalar($bsrc =~ /_followTile\s*\(\s*\$client\s*,\s*\$feat\s*\)\s*if\s+\$token/),
       'the Recommended tile is still token-gated in topLevel');
    ok(scalar($bsrc =~ /sub\s+_warmFollow\b.*?\$prefs->get\('token'\)/s),
       '_warmFollow still bails without a token');
    ok(scalar($bsrc =~ /\$prefs->get\('token'\)\s*\/\/\s*''\s*\)\s*ne\s*''\s*&&\s*\$prefs->get\('people_follow'\)/),
       'the unmatched-debug follow entry is still token-gated');

    # The For You tile must NOT be gated on the token any more.
    my ($toplevel) = $bsrc =~ /sub\s+topLevel\s*\{(.*?)\n    my \@settings/s;
    ok(scalar(defined $toplevel && $toplevel !~ /\(\s*\$username\s*&&\s*\$token\s*\)/),
       'topLevel no longer gates the For You tile on username AND token');
    ok(scalar(defined $toplevel && $toplevel =~ /my\s+\$newReleases\s*=\s*\$username\s*\n?\s*\?/),
       'and gates it on the username alone');
}

print "\n5. no user-facing string still demands a token\n";
{
    my $sfile = "$ROOT/ListenBrainzFreshReleases/strings.txt";
    open my $fh, '<', $sfile or die "$sfile: $!";
    my $s = do { local $/; <$fh> };
    close $fh;

    my ($setup) = $s =~ /PLUGIN_LBF_SETUP_REQUIRED\n\tEN\t([^\n]*)/;
    ok(scalar(defined $setup && $setup !~ /token/i),
       'PLUGIN_LBF_SETUP_REQUIRED no longer tells the user to configure a token');
    ok(scalar(defined $setup && $setup =~ /username/i),
       'and it still names the username, which IS required');

    my ($hint) = $s =~ /PLUGIN_LBF_TOKEN_HINT\n\tEN\t([^\n]*)/;
    ok(scalar(defined $hint && $hint =~ /optional/i),
       'the token hint describes the field as optional');
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
