#!/usr/bin/env perl
#
# t_feedsingleflight.pl — a COLD feed open fetches ONCE, however many browse walks
# arrive while it is in flight.
#
# WHAT THIS PINS, and why %REVALIDATING did not already cover it.
#
#   `_fetchReleaseFeed` guards concurrent fetches with %REVALIDATING — but only
#   `if ($bg)`, and $bg is `!$p{onDone}`, so an OPEN-path fetch (which always carries
#   onDone) takes no flag at all. On a WARM store that is harmless: the three-plus
#   XMLBrowser walks a single tap produces all read the store and never fetch. On a
#   COLD store there is nothing to read, so each walk fires its own ListenBrainz
#   request for the identical URL. %FEED_MEMO cannot help either — it caches
#   COMPLETED results, and none of them completes until seconds later.
#
#   THE TWO HALVES, and the second is the one that turns a waste into a hang:
#
#   (a) only the FIRST caller reaches the network;
#   (b) EVERY parked caller is answered — on success AND on failure. Parking callers
#       and then answering only the first would convert a duplicate fetch into a
#       browse that never renders, which is strictly worse than the race it replaces.
#
#   Behavioural, not source-matching: the whole property is "how many requests went
#   out and who got called back", which no pattern match can show.
#
# ANTI-TEST: point LBF_API at a mutated copy.
#   - remove the $INFLIGHT park           -> section 1 red (3 requests, not 1)
#   - drop $fanout from $done             -> section 2 red (waiters never answered)
#   - drop $fanout from the failure path  -> section 3 red (waiters hang on an error)
#   - key $INFLIGHT on $feed not $memoKey -> section 4 red (different query, wrong answer)

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);

my $ROOT = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));
my $API  = $ENV{LBF_API} || "$ROOT/ListenBrainzFreshReleases/API.pm";

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $msg) = @_;
    die "t_feedsingleflight: assertion called with no message — a bare m// or grep\n"
      . "has shifted the arguments. Wrap the condition in scalar().\n"
        unless defined $msg && length $msg;
    if ($cond) { $pass++; printf "  ok   %s\n", $msg }
    else       { $fail++; printf "  FAIL %s\n", $msg }
}
sub is {
    my ($got, $want, $msg) = @_;
    $got  = defined $got  ? $got  : '(undef)';
    $want = defined $want ? $want : '(undef)';
    if ($got eq $want) { $pass++; printf "  ok   %s\n", $msg }
    else { $fail++; printf "  FAIL %s  ->  '%s'  (wanted '%s')\n", $msg, $got, $want }
}
sub section { printf "\n%s\n%s\n", $_[0], '-' x 74 }

# ---------------------------------------------------------------------------
# A minimal LMS. The HTTP stub RECORDS the request and holds its callbacks instead
# of answering — that suspended state IS the thing under test, since the race only
# exists while a fetch is outstanding.
# ---------------------------------------------------------------------------
our %PREFS;
our @REQUESTS;
our @TIMERS;   # every armed timer, fired only when a test says so

my $stub = tempdir(CLEANUP => 1);
sub stubfile {
    my ($path, $body) = @_;
    my $full = "$stub/$path";
    system('mkdir', '-p', dirname($full)) == 0 or die "mkdir: $?";
    open my $fh, '>', $full or die "$full: $!";
    print $fh $body; close $fh;
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

stubfile('Slim/Utils/Cache.pm', <<'EOF');
package Slim::Utils::Cache;
package Slim::Utils::Cache::Obj;
sub get { undef } sub set { 1 } sub remove { 1 }
package Slim::Utils::Cache;
sub new { bless {}, 'Slim::Utils::Cache::Obj' }
1;
EOF

# Suspends every request: records it and keeps the callbacks so the test decides
# when (and whether) each one answers.
stubfile('Slim/Networking/SimpleAsyncHTTP.pm', <<'EOF');
package Slim::Networking::SimpleAsyncHTTP;
sub new { my ($c, $ok, $err, $opt) = @_; bless { ok => $ok, err => $err }, $c }
sub content { $_[0]{_body} }
sub code    { $_[0]{_code} }
sub error   { $_[0]{_error} }
sub headers { {} }
sub get {
    my ($self, $url, @h) = @_;
    push @main::REQUESTS, { url => $url, obj => $self };
    return 1;
}
sub post { my $s = shift; $s->get(@_) }
1;
EOF

# Timers RECORD rather than fire. The leak watchdog is a timer, so a no-op stub
# would make removing it invisible to this suite — which is how a belt-and-braces
# guard rots. The test fires it deliberately instead.
stubfile('Slim/Utils/Timers.pm', <<'EOF');
package Slim::Utils::Timers;
my $next = 0;
sub setTimer {
    my ($obj, $when, $cb, @args) = @_;
    my $id = ++$next;
    push @main::TIMERS, { id => $id, when => $when, cb => $cb, obj => $obj, args => \@args };
    return $id;
}
sub killSpecific {
    my ($id) = @_;
    return 0 unless defined $id;
    @main::TIMERS = grep { $_->{id} ne $id } @main::TIMERS;
    return 1;
}
sub killTimers { 1 }
1;
EOF

for my $m (qw(Slim/Utils/Strings Slim/Utils/Misc
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
use JSON::PP ();
use Exporter 'import'; our @EXPORT = qw(to_json from_json encode_json decode_json);
my $J = JSON::PP->new->utf8->canonical;
sub from_json { $J->decode($_[0]) }
sub decode_json { $J->decode($_[0]) }
sub to_json { $J->encode($_[0]) }
sub encode_json { $J->encode($_[0]) }
1;
EOF

system('mkdir', '-p', "$stub/Plugins/ListenBrainzFreshReleases") == 0 or die;
system('cp', $API, "$stub/Plugins/ListenBrainzFreshReleases/API.pm") == 0 or die;
system('cp', "$ROOT/ListenBrainzFreshReleases/DB.pm",
             "$stub/Plugins/ListenBrainzFreshReleases/DB.pm") == 0 or die;

unshift @INC, $stub;

# THE STORE MUST BE EMPTY — that is what "cold" means, and it is the only state in
# which this race exists at all. A store with rows serves them and never fetches, so
# a suite that let the real store answer would pass against no single-flight at all.
require Plugins::ListenBrainzFreshReleases::DB;
{
    package T::Store;
    sub get { undef } sub set { 1 } sub remove { 1 }
}
{
    no warnings 'redefine', 'once';
    *Plugins::ListenBrainzFreshReleases::DB::store       = sub { bless {}, 'T::Store' };
    *Plugins::ListenBrainzFreshReleases::DB::feedReleases = sub { () };
    *Plugins::ListenBrainzFreshReleases::DB::feedCoverage = sub { { any => 0 } };
    *Plugins::ListenBrainzFreshReleases::DB::ingestFeed   = sub { { ok => 1, stored => 0 } };
    *Plugins::ListenBrainzFreshReleases::DB::feedNoteAttempt = sub { 1 };
}

require Plugins::ListenBrainzFreshReleases::API;
my $api = 'Plugins::ListenBrainzFreshReleases::API';

$PREFS{username} = 'CrystalGipsy';
# BOTH GATES ON, or sectionWeeks zeroes the side the section is varying and every
# section collapses onto one memo key again. all_future is `// 0` by default, which
# is correct for the product and useless here.
$PREFS{all_past} = 1;
$PREFS{all_future} = 1;
$PREFS{foryou_past} = 1;
$PREFS{foryou_future} = 1;

# Open the All Releases feed. Returns a recorder the test inspects.
#
# EACH SECTION NEEDS ITS OWN MEMO KEY, and since 0.9.185 the window is weeks
# rather than a `days` argument — so the key is varied by setting the week PREFS
# the fetcher reads, which is also how it varies in production. (%INFLIGHT is a
# lexical inside API.pm and cannot be reset from a test, so a shared key silently
# parks one section behind another section's still-outstanding fetch. That
# actually happened on the first run of this file.)
sub open_feed {
    my (%o) = @_;
    local $PREFS{weeks_past}   = $o{wp} // 0;
    local $PREFS{weeks_future} = $o{wf} // 0;
    my $r = { done => [], error => [] };
    $api->getFreshReleasesAll(
        sort => 'release_date',
        onDone  => sub { push @{ $r->{done} },  $_[0] },
        onError => sub { push @{ $r->{error} }, $_[0] },
    );
    return $r;
}
sub answer_ok {
    my ($req, $json) = @_;
    $req->{obj}{_body} = $json;
    $req->{obj}{_code} = 200;
    $req->{obj}{ok}->($req->{obj});
}
sub answer_fail {
    my ($req, $msg) = @_;
    $req->{obj}{_error} = $msg;
    $req->{obj}{_code}  = 500;
    $req->{obj}{err}->($req->{obj});
}
my $PAYLOAD = '{"payload":{"releases":[{"release_name":"A","artist_credit_name":"B",'
            . '"release_date":"2026-08-01","release_group_mbid":"rg-1","release_mbid":"r-1"}]}}';

# ---------------------------------------------------------------------------
section '1. THREE COLD WALKS -> ONE REQUEST';
{
    local @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();

    # Each section uses its own (weeks_past, weeks_future), i.e. its own memo key —
    # see open_feed. Section 1 leaves its fetch deliberately outstanding.
    my @walks = map { open_feed(wp => 0, wf => 0) } 1 .. 3;

    is(scalar(@REQUESTS), 1, 'three concurrent opens of a COLD feed make ONE request');
    is(scalar(@{ $walks[0]{done} }), 0, 'and nobody has been answered yet');
    is(scalar(@{ $walks[2]{done} }), 0, 'including the ones parked behind it');
}

# ---------------------------------------------------------------------------
section '2. THE ONE RESULT REACHES EVERY WAITER';
{
    local @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();

    my @walks = map { open_feed(wp => 0, wf => 1) } 1 .. 3;
    is(scalar(@REQUESTS), 1, 'one request in flight');
    answer_ok($REQUESTS[0], $PAYLOAD);

    is(scalar(@{ $walks[0]{done} }), 1, 'the caller that fetched is answered');
    is(scalar(@{ $walks[1]{done} }), 1, 'the second walk is answered too');
    is(scalar(@{ $walks[2]{done} }), 1, 'and the third');
    ok(scalar(@{ $walks[0]{error} } == 0 && @{ $walks[2]{error} } == 0),
       'and none of them got an error instead');

    # Same data, not merely "something": a waiter handed a different result than the
    # caller it was multiplexed with would be worse than a second fetch.
    my $a = $walks[0]{done}[0];
    my $c = $walks[2]{done}[0];
    ok(scalar(ref $a eq 'ARRAY' && ref $c eq 'ARRAY'), 'both got an arrayref of releases');
    is(scalar(@$c), scalar(@$a), 'and the SAME number of releases');
}

# ---------------------------------------------------------------------------
section '3. A FAILURE RELEASES THE WAITERS — parking must never become hanging';
{
    local @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();

    my @walks = map { open_feed(wp => 0, wf => 2) } 1 .. 3;
    is(scalar(@REQUESTS), 1, 'one request in flight');
    answer_fail($REQUESTS[0], '503 Service Unavailable');

    # The store is empty, so there is no stored copy to degrade to — this is the
    # genuine error path.
    is(scalar(@{ $walks[0]{error} }), 1, 'the fetching caller gets the error');
    is(scalar(@{ $walks[1]{error} }), 1, 'and so does a parked waiter');
    is(scalar(@{ $walks[2]{error} }), 1, 'and the third');

    # SAME ARGUMENT SHAPE. _handleError hands onError a STRING; a waiter given the
    # response object instead would be a type mismatch visible only to whoever
    # happened to arrive second.
    ok(scalar(!ref $walks[0]{error}[0]), 'the primary gets a plain string message');
    ok(scalar(!ref $walks[2]{error}[0]), 'and so does the waiter (not a response object)');
    is($walks[2]{error}[0], $walks[0]{error}[0], 'the very same message');
}

# ---------------------------------------------------------------------------
section '4. A DIFFERENT QUESTION IS NOT MULTIPLEXED ONTO THIS ANSWER';
{
    local @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();

    # A different week window = a different memo key. Parking this
    # behind the first fetch would answer it with releases it did not ask for, which
    # is why the registry is keyed on the memo key and not on the feed name.
    my $a = open_feed(wp => 0, wf => 3);
    my $b = open_feed(wp => 1, wf => 0);
    is(scalar(@REQUESTS), 2, 'a different window fetches separately');

    my $c = open_feed(wp => 0, wf => 3);
    is(scalar(@REQUESTS), 2, 'while the SAME window still parks behind the first');
}

# ---------------------------------------------------------------------------
section '5. THE REGISTRY DOES NOT LEAK BETWEEN FETCHES';
{
    local @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();

    my $first = open_feed(wp => 1, wf => 1);
    is(scalar(@REQUESTS), 1, 'a cold open fetches');
    answer_ok($REQUESTS[0], $PAYLOAD);
    is(scalar(@{ $first->{done} }), 1, 'and answers');

    # A registry entry left behind would park the NEXT opener for ever with nothing
    # in flight to release it — the same hazard as a leaked build flag.
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    @REQUESTS = ();
    my $second = open_feed(wp => 1, wf => 1);
    is(scalar(@REQUESTS), 1, 'a later open fetches again rather than parking for ever');
}

# ---------------------------------------------------------------------------
section '6. ONLY IDENTICAL REQUESTS SHARE — the headers are part of the key';
{
    local @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();

    # The memo key covers the sort and the week window; it does NOT cover the ListenBrainz
    # TOKEN, which rides in an Authorization header. Keyed on the memo key alone, a
    # token holder arriving second would be parked behind an anonymous fetch and
    # their token silently never sent — the request LBF issues would depend on which
    # browse walk arrived first. Harmless for fresh_releases (the payloads are
    # byte-identical either way, which is t_tokenfree's whole premise) but it is not
    # a property to leave to luck.
    my $mk = sub {
        my ($token) = @_;
        local $PREFS{token} = $token;
        local $PREFS{weeks_past}   = 2;
        local $PREFS{weeks_future} = 1;
        my $r = { done => [], error => [] };
        $api->getFreshReleasesForUser(
            sort => 'release_date',
            onDone  => sub { push @{ $r->{done} },  $_[0] },
            onError => sub { push @{ $r->{error} }, $_[0] },
        );
        return $r;
    };

    $mk->('');
    is(scalar(@REQUESTS), 1, 'an anonymous open fetches');
    $mk->('sekrit-token');
    is(scalar(@REQUESTS), 2, 'a TOKEN holder fetches separately rather than being multiplexed onto it');
    $mk->('sekrit-token');
    is(scalar(@REQUESTS), 2, 'but a second identical token holder DOES park behind the first');
    $mk->('');
    is(scalar(@REQUESTS), 2, 'and so does a second anonymous caller');
}

# ---------------------------------------------------------------------------
section '7. A DIE IN THE FIRST CALLER MUST NOT STRAND THE CLAIM';
{
    local @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();

    # $fanout is the ONLY place the claim is released, and it runs AFTER the first
    # caller's own onDone. That callback is an XMLBrowser render callback exactly
    # like every waiter's — the waiters are eval'd and it was not. A die in it left
    # the key claimed with nothing in flight to release it, so from then on EVERY
    # cold open of this feed parked onto a list nothing would ever drain and
    # returned without rendering, for the life of the process.
    my $waiter = { done => [], error => [] };
    {
        local $PREFS{weeks_past}   = 3;
        local $PREFS{weeks_future} = 1;
        $api->getFreshReleasesAll(
            sort => 'release_date',
            onDone  => sub { die "render blew up\n" },     # the FIRST caller
            onError => sub { die "render blew up\n" },
        );
        $api->getFreshReleasesAll(
            sort => 'release_date',
            onDone  => sub { push @{ $waiter->{done} },  $_[0] },
            onError => sub { push @{ $waiter->{error} }, $_[0] },
        );
    }
    is(scalar(@REQUESTS), 1, 'the second walk parked behind the first, as always');

    my $survived = eval { answer_ok($REQUESTS[0], $PAYLOAD); 1 };
    ok($survived, 'answering does not propagate the caller\'s die to the HTTP layer');
    is(scalar(@{ $waiter->{done} }), 1, 'the parked waiter is STILL answered');

    # The claim is the point: a later opener must reach the network again rather
    # than parking on a fetch that finished long ago.
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    @REQUESTS = ();
    my $later = { done => [], error => [] };
    {
        local $PREFS{weeks_past}   = 3;
        local $PREFS{weeks_future} = 1;
        $api->getFreshReleasesAll(
            sort => 'release_date',
            onDone  => sub { push @{ $later->{done} },  $_[0] },
            onError => sub { push @{ $later->{error} }, $_[0] },
        );
    }
    is(scalar(@REQUESTS), 1, 'a later cold open FETCHES rather than parking for ever');
    # GUARDED, because the failure being tested for is precisely "no request went
    # out": answering $REQUESTS[0] unconditionally dies on undef and aborts the run
    # at exit 255 with no totals line — which reads like a pass. A missing request
    # must report as a red assertion, not as a crash.
    answer_ok($REQUESTS[0], $PAYLOAD) if @REQUESTS;
    is(scalar(@{ $later->{done} }), 1, 'and renders');
}

# ---------------------------------------------------------------------------
section '8. THE LEAK WATCHDOG — a result that NEVER ARRIVES still frees the key';
{
    local @REQUESTS = ();
    local @TIMERS   = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();

    # The eval in section 7 covers a callback that dies. It cannot cover a callback
    # that never runs at all — a wedged connection, or a die inside an LMS timer,
    # which happens outside any eval this module could wrap. The registry is
    # in-process by design, so nothing else would ever free the key.
    my $waiter = { done => [], error => [] };
    {
        local $PREFS{weeks_past}   = 2;
        local $PREFS{weeks_future} = 2;
        open_feed(wp => 2, wf => 2);
        $api->getFreshReleasesAll(
            sort => 'release_date',
            onDone  => sub { push @{ $waiter->{done} },  $_[0] },
            onError => sub { push @{ $waiter->{error} }, $_[0] },
        );
    }
    is(scalar(@REQUESTS), 1, 'one fetch, one parked waiter');

    my ($wd) = grep { $_->{when} && $_->{when} > 0 } @TIMERS;
    ok(scalar(defined $wd), 'the claim armed a watchdog timer');
    ok(scalar(defined $wd && $wd->{when} >=
              Time::HiRes::time() + 2 * Plugins::ListenBrainzFreshReleases::API::FEED_TIMEOUT()),
       '...well clear of one HTTP timeout, so it cannot fire on a healthy fetch');

    # Fire it WITHOUT ever answering the request.
    $wd->{cb}->($wd->{obj}, @{ $wd->{args} }) if $wd;
    is(scalar(@{ $waiter->{error} }), 1, 'the abandoned waiter is answered, not merely dropped');
    ok(scalar(!ref $waiter->{error}[0]), '...with a plain string, like every other error path');

    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    @REQUESTS = ();
    open_feed(wp => 2, wf => 2);
    is(scalar(@REQUESTS), 1, 'and the freed key lets the next open reach the network');
}

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
