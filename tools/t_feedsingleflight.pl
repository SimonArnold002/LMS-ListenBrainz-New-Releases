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
# ANTI-TEST: point LBF_API / LBF_BROWSE at a mutated copy.
#   - remove the $INFLIGHT park            -> section 1 red (3 requests, not 1)
#   - drop $fanout from $done              -> section 2 red (waiters never answered)
#   - drop $fanout from the failure path   -> section 3 red (waiters hang on an error)
#   - key $INFLIGHT on $feed not $memoKey  -> section 4 red (different query, wrong answer)
#   - MuSpy store gate ignores `force`     -> 4 red (the 0.9.190 state: the nightly
#                                             warm returns yesterday's rows, no request)
#   - only $bg claims %REVALIDATING        -> 1 red (a browse revalidates a feed the
#                                             warm is already fetching, on another sort)
#   - only !$bg claims %INFLIGHT           -> 5 red (a forced warm arriving during a
#                                             revalidation issues its own second fetch)
#   - restore `return if $bg` in $fanout   -> 3 red (a background fetch never releases
#                                             the claim, so its waiters hang for ever)
#   - %REVALIDATING released UNCONDITIONALLY (a flag, not a count, i.e. the 0.9.192
#     shape)                               -> 3 red in the LAST section, one of them
#                                             reading 3 requests where 2 were expected —
#                                             the duplicate fetch + duplicate ingest
#                                             itself, and the watchdog one showing a
#                                             dead fetch freeing a healthy sibling
#   - MuSpy success answers with $rels     -> 1 red (the forced warm hands _warmCovers
#     instead of the store                    the top-100 slice, not what the view draws;
#                                             the FETCHED assertion beside it stays GREEN,
#                                             which is why they are two assertions)
#
# THE LAST THREE ARE DELIBERATELY SEPARATE MUTANTS. The two guards close the overlap
# from opposite directions, and each is invisible to the other's assertions: the
# per-request %INFLIGHT covers a browse asking the SAME question, and only the coarse
# per-feed %REVALIDATING covers one asking a different question of the same feed.
# Asserting only the same-question case passes with the feed guard removed entirely,
# which is how the first cut of these sections read.

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);

my $ROOT = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));
my $API  = $ENV{LBF_API} || "$ROOT/ListenBrainzFreshReleases/API.pm";
# Browse.pm joined this suite when it grew the check that warmFeeds actually
# PASSES force. It needs its own override for the same reason API.pm has one:
# without it the anti-test reads the pristine copy and a mutated warmFeeds goes
# on passing, which is exactly the failure this file exists to prevent.
my $BROWSE = $ENV{LBF_BROWSE} || "$ROOT/ListenBrainzFreshReleases/Browse.pm";

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

# ==========================================================================
section('THE WARM FETCHES; IT DOES NOT READ THE STORE');
# ==========================================================================
# WHAT THIS PINS, and it was a silent, permanent defect rather than a race.
# Both feed subs short-circuit on the store: if there are rows, `onDone` fires
# with THEM and returns, and the stale branch kicks a revalidation whose result
# reaches nobody. That is correct and deliberate for a BROWSE — it is what makes
# an open instant. It was catastrophic for the WARM, which is the one caller that
# exists to act on what actually arrived: `_warmCovers` and `_warmGenres` ran
# against the stored list every night, so a release that appeared today had its
# cover warmed no earlier than tomorrow's tick. Observed live as `foryou_feed
# 0.00s / all_feed 0.02s` in warmstats — no HTTP at all on a nightly tick.
#
# The store is stubbed empty for the rest of this file (that is what "cold"
# means), so these sections install a store that ANSWERS — the state in which the
# short-circuit exists at all.
{
    my @stored = ({ release_name => 'STORED', artist_credit_name => 'B',
                    release_date => '2026-08-01', release_group_mbid => 'rg-s',
                    release_mbid => 'r-s' });
    my $coverage = { any => 1, complete => 1, days => 28, covered => 28, ok_at => time() };
    no warnings 'redefine', 'once';
    local *Plugins::ListenBrainzFreshReleases::DB::feedReleases = sub { [ @stored ] };
    local *Plugins::ListenBrainzFreshReleases::DB::feedCoverage = sub { $coverage };

    # --- unforced: the browse behaviour, unchanged -------------------------
    @REQUESTS = ();
    my $r = { done => [], error => [] };
    {
        $api->getFreshReleasesAll(sort => 'warm-unforced',
            onDone => sub { push @{ $r->{done} }, $_[0] });
    }
    is(scalar(@REQUESTS), 0, 'unforced + a fresh store makes NO request (the browse path)');
    is(scalar(@{ $r->{done} }), 1, '...and answers immediately');
    is((($r->{done}[0] || [])->[0] || {})->{release_name}, 'STORED',
       '...from the store');

    # --- forced: the warm behaviour ---------------------------------------
    @REQUESTS = ();
    my $w = { done => [], error => [] };
    {
        $api->getFreshReleasesAll(sort => 'warm-forced', force => 1,
            onDone => sub { push @{ $w->{done} }, $_[0] });
    }
    is(scalar(@REQUESTS), 1, 'forced goes to the network even with a fresh store');
    is(scalar(@{ $w->{done} }), 0, '...and does NOT answer from the store first');
    # Guarded: without a request to answer this would die on undef and take every
    # remaining assertion in the file with it, so a real regression would report
    # two failures and hide the rest.
    answer_ok($REQUESTS[0], $PAYLOAD) if @REQUESTS;
    is(scalar(@{ $w->{done} }), 1, '...it answers once the fetch lands');
    is((($w->{done}[0] || [])->[0] || {})->{release_name}, 'A',
       '...with what the FETCH returned, not the stored copy — the whole point');

    # --- forced, and the fetch fails --------------------------------------
    # The warm must still warm SOMETHING: a ListenBrainz outage should degrade to
    # the stored list, not to warming nothing. This needs no code of its own —
    # _fetchReleaseFeed's failure path already serves the stored copy to onDone —
    # but that is a dependency worth pinning, because it is the reason the forced
    # branch passes its error handling straight through.
    @REQUESTS = ();
    my $f = { done => [], error => [] };
    {
        $api->getFreshReleasesAll(sort => 'warm-forced-fail', force => 1,
            onDone  => sub { push @{ $f->{done} },  $_[0] },
            onError => sub { push @{ $f->{error} }, $_[0] });
    }
    is(scalar(@REQUESTS), 1, 'forced fetch issued');
    answer_fail($REQUESTS[0], '503 Service Unavailable') if @REQUESTS;
    is(scalar(@{ $f->{error} }), 0, 'a failed forced fetch surfaces no error while the store has rows');
    is(scalar(@{ $f->{done} }), 1, '...it still answers');
    is((($f->{done}[0] || [])->[0] || {})->{release_name}, 'STORED',
       '...degrading to the stored list, so the warm warms something');
}

# THESE SECTIONS KEY OFF `sort`, NOT THE WEEK PREFS, and that is deliberate.
# `_feedMemoKey` covers (section, sort, wp, wf), and WEEKS_MAX_SIDE is 3 — so the
# legal week space is ten pairs, the earlier sections use most of them, and
# _clampWeeks silently folds an out-of-range pair onto one already taken ((4,0)
# became (3,0), and this section then read ANOTHER section's memo and passed for
# the wrong reason). Varying the sort gives an unbounded key space with no clamp
# to reason about. Cost a debugging pass.
#
# THE MEMO IS SKIPPED TOO. A browse that ran minutes before the tick leaves the
# feed memoed; without this gate the warm would be handed that copy and never
# reach either the store branch or the network.
{
    @REQUESTS = ();
    my $a = { done => [] };
    {
        $api->getFreshReleasesAll(sort => 'warm-memo',
            onDone => sub { push @{ $a->{done} }, $_[0] });
        is(scalar(@REQUESTS), 1, 'cold open fetches');
        answer_ok($REQUESTS[0], $PAYLOAD) if @REQUESTS;
        is(scalar(@{ $a->{done} }), 1, '...and populates the memo');

        @REQUESTS = ();
        my $b = { done => [] };
        $api->getFreshReleasesAll(sort => 'warm-memo',
            onDone => sub { push @{ $b->{done} }, $_[0] });
        is(scalar(@REQUESTS), 0, 'a second unforced open is served from the memo');

        @REQUESTS = ();
        my $c = { done => [] };
        $api->getFreshReleasesAll(sort => 'warm-memo', force => 1,
            onDone => sub { push @{ $c->{done} }, $_[0] });
        is(scalar(@REQUESTS), 1, 'a FORCED open ignores the memo and fetches');
        answer_ok($REQUESTS[0], $PAYLOAD) if @REQUESTS;
    }
}

# AND THE WARM ACTUALLY PASSES IT. The three call sites live in Browse::warmFeeds,
# and a `force` that no caller sets is worth nothing — this is the half that a
# test of API.pm alone cannot see.
{
    my $bsrc = do {
        open(my $fh, '<:encoding(UTF-8)', $BROWSE) or die $!;
        local $/; <$fh>;
    };
    my ($warm) = $bsrc =~ /^sub warmFeeds \{(.*?)^\}/ms;
    ok(defined $warm && length $warm, 'warmFeeds located in Browse.pm');
    # COMMENTS STRIPPED FIRST. The block comments explaining this change quote
    # `force => 1` in prose, so counting the raw source counted them too and the
    # assertion read 7 against 4 calls. Count code.
    (my $code = $warm) =~ s/^\s*#.*$//mg;
    my $calls  = () = $code =~ /getFreshReleases(?:ForUser|All)\(|getMuSpyReleases\(/g;
    my $forced = () = $code =~ /force\s*=>\s*1/g;
    ok($calls > 0, "warmFeeds makes $calls feed call(s)");
    is($forced, $calls, 'EVERY feed call in warmFeeds passes force => 1');
}

# ==========================================================================
section('MUSPY HAS TWO SHORT-CIRCUITS, AND force MUST GATE BOTH');
# ==========================================================================
# 0.9.190 gave MuSpy `force` and gated only the MEMO, on the stated grounds that
# "MuSpy has no store short-circuit (it always fetches)". It has one — the same
# `if ($stored && !$stale)` the LB feeds have, minus the day-coverage test. With
# WARM_INTERVAL and FEED_STALE_AFTER both 24h, ANY browse inside the window leaves
# a fresh store, so the nightly forced warm returned yesterday's rows and issued no
# request: precisely the bug `force` was added to fix, reached through the other
# door. The memo assertion alone could never see it — the memo is a 5s window.
{
    local @REQUESTS = ();
    $PREFS{muspy_userid} = 'mu-1';

    my @stored = ({ release_name => 'STORED-MUSPY', artist_credit_name => 'B',
                    release_date => '2026-08-01', release_group_mbid => 'rg-m',
                    release_mbid => 'r-m' });
    no warnings 'redefine', 'once';
    # FRESH, not stale: ok_at is now, so !$stale — the state the forced warm has to
    # push past. A stale store would fetch either way and prove nothing.
    local *Plugins::ListenBrainzFreshReleases::DB::feedReleases = sub { [ @stored ] };
    local *Plugins::ListenBrainzFreshReleases::DB::feedCoverage =
        sub { { any => 1, complete => 1, days => 28, covered => 28, ok_at => time() } };
    # THE INGEST STUB IS STATEFUL HERE, and it has to be. The property under test is
    # "the forced warm answers from the STORE, which now holds what arrived" — with a
    # no-op ingest the store can never reflect the fetch and the section could only
    # ever pin a stub artefact. Appending is also what the real store does: MuSpy is
    # stored with rotation OFF, so today's slice MERGES with the retained rows rather
    # than replacing them.
    local *Plugins::ListenBrainzFreshReleases::DB::ingestFeed = sub {
        my ($f, $rels) = @_;
        my %have = map { ($_->{release_name} // '') => 1 } @stored;
        push @stored, grep { !$have{ $_->{release_name} // '' }++ } @{ $rels || [] };
        return { ok => 1, stored => scalar @{ $rels || [] } };
    };

    my $browse = { done => [] };
    $api->getMuSpyReleases(onDone => sub { push @{ $browse->{done} }, $_[0] });
    is(scalar(@REQUESTS), 0, 'unforced + a fresh store makes NO request (the browse path)');
    is((($browse->{done}[0] || [])->[0] || {})->{release_name}, 'STORED-MUSPY',
       '...and is answered from the store');

    # The memo now holds the stored copy, so this also covers both short-circuits at
    # once: a `force` that gated only the memo would fall straight into the store.
    @REQUESTS = ();
    my $warm = { done => [] };
    $api->getMuSpyReleases(force => 1, onDone => sub { push @{ $warm->{done} }, $_[0] });
    is(scalar(@REQUESTS), 1, 'forced goes to the network even with a fresh store');
    is(scalar(@{ $warm->{done} }), 0, '...and does NOT answer from the store first');

    answer_ok($REQUESTS[0], '[{"artist":{"name":"MB Artist","sort_name":"Artist, MB"},'
                          . '"mbid":"rg-fresh","name":"FETCHED","date":"2026-08-20","type":"Album"}]')
        if @REQUESTS;
    is(scalar(@{ $warm->{done} }), 1, '...it answers once the fetch lands');

    # WHAT THE ANSWER MUST CONTAIN, and it is BOTH rows — the two properties pull in
    # opposite directions and only the pair pins the behaviour.
    #
    #   FETCHED       is 0.9.190: the warm must act on what actually ARRIVED. An answer
    #                 without it is the stale-store bug `force` exists to fix.
    #   STORED-MUSPY  is the 0.9.192 review: `?limit=100` is a TOP-N SLICE while every browse
    #                 renders from the UNWINDOWED store, so an answer of the slice ALONE
    #                 hands _warmCovers fewer rows than the view draws — stored rows
    #                 inside the display window silently lose their nightly cover warm —
    #                 and briefly publishes the short list to For You through the memo.
    #
    # Asserting only the first passes against serving the raw slice, which is exactly
    # how the 0.9.192 assertion read.
    my %warmed = map { ($_->{release_name} // '') => 1 } @{ $warm->{done}[0] || [] };
    ok($warmed{FETCHED}, '...carrying what the FETCH returned — the warm acts on what arrived');
    ok($warmed{'STORED-MUSPY'},
       '...AND the stored rows outside the top-100 slice, which is what the view renders');

    # And the best-effort contract is unchanged: a forced fetch that FAILS must still
    # answer, degrading to the store rather than blanking the feed it merges into.
    @REQUESTS = ();
    my $bad = { done => [] };
    $api->getMuSpyReleases(force => 1, onDone => sub { push @{ $bad->{done} }, $_[0] });
    is(scalar(@REQUESTS), 1, 'forced fetch issued');
    answer_fail($REQUESTS[0], 'boom') if @REQUESTS;
    is(scalar(@{ $bad->{done} }), 1, 'a failed forced fetch still answers');
    is((($bad->{done}[0] || [])->[0] || {})->{release_name}, 'STORED-MUSPY',
       '...degrading to the stored list, so the warm warms something');

    delete $PREFS{muspy_userid};
}

# ==========================================================================
section('THE TWO GUARDS CAN SEE EACH OTHER');
# ==========================================================================
# %REVALIDATING was claimed only when $bg and %INFLIGHT only when not, so the two
# roles were mutually invisible. Harmless while the warm revalidated in the
# BACKGROUND; 0.9.190 made it a foreground caller, and from that build a browse
# could kick a background revalidation of a feed the warm was already fetching —
# two ListenBrainz requests and two ~3,000-release chunked ingests of one payload.
#
# A stale-but-populated store is the state both roles meet in: the browse serves it
# and revalidates behind the render, while the forced warm fetches for real.
{
    local @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    # RESET THE FEED GUARD. It has held a COUNT since the 0.9.192 review, and the sections above
    # leave fetches deliberately suspended and never answered — claims that in
    # production would always be released by $done/$failed/the watchdog. They share
    # one feed key, so without this the count arrives here non-zero and this section
    # would be asserting about the previous ones.
    %Plugins::ListenBrainzFreshReleases::API::REVALIDATING = ();

    my @stored = ({ release_name => 'STORED', artist_credit_name => 'B',
                    release_date => '2026-08-01', release_group_mbid => 'rg-s',
                    release_mbid => 'r-s' });
    no warnings 'redefine', 'once';
    local *Plugins::ListenBrainzFreshReleases::DB::feedReleases = sub { [ @stored ] };
    # STALE: ok_at well past FEED_STALE_AFTER, so a browse revalidates behind its render.
    local *Plugins::ListenBrainzFreshReleases::DB::feedCoverage =
        sub { { any => 1, complete => 1, days => 28, covered => 28,
                ok_at => time() - 10 * 86400 } };

    # --- warm first, then a browse -----------------------------------------
    my $warm = { done => [] };
    $api->getFreshReleasesAll(sort => 'overlap-a', force => 1,
        onDone => sub { push @{ $warm->{done} }, $_[0] });
    is(scalar(@REQUESTS), 1, 'the forced warm fetches');

    my $browse = { done => [] };
    $api->getFreshReleasesAll(sort => 'overlap-a',
        onDone => sub { push @{ $browse->{done} }, $_[0] });
    is(scalar(@{ $browse->{done} }), 1, 'the browse still renders instantly from the store');
    is(scalar(@REQUESTS), 1,
       'and its revalidation is SUPPRESSED — no second fetch or ingest of one payload');

    # AND WITH A DIFFERENT QUESTION, which is what the coarse per-feed guard is FOR.
    # A browse on another sort has a different $ikey, so %INFLIGHT says nothing about
    # it — only %REVALIDATING does, and only because the warm claims it. Two
    # revalidations of one feed are still two requests at ListenBrainz and two
    # ~3,000-release ingests, and the rate limit is per-user, not per-question.
    my $other = { done => [] };
    $api->getFreshReleasesAll(sort => 'overlap-a-alt',
        onDone => sub { push @{ $other->{done} }, $_[0] });
    is(scalar(@{ $other->{done} }), 1, 'a browse on another sort still renders from the store');
    is(scalar(@REQUESTS), 1,
       'and ITS revalidation is suppressed too — the feed guard, not the request guard');

    answer_ok($REQUESTS[0], $PAYLOAD) if @REQUESTS;
    is(scalar(@{ $warm->{done} }), 1, 'the warm is answered');

    # The claim is released on the way out, or one warm would suppress every
    # revalidation of that feed for the life of the process.
    @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    $api->getFreshReleasesAll(sort => 'overlap-a',
        onDone => sub { });
    is(scalar(@REQUESTS), 1, 'a later browse CAN revalidate again — the claim was released');
    answer_ok($REQUESTS[0], $PAYLOAD) if @REQUESTS;

    # --- the other direction: a foreground caller arriving mid-revalidation --
    # It owes an answer, so it can never simply return; it parks on the background
    # fetch and is answered from it. Before 0.9.192 it issued its own request.
    @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    $api->getFreshReleasesAll(sort => 'overlap-b', onDone => sub { });
    is(scalar(@REQUESTS), 1, 'the browse kicks a background revalidation');

    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    my $late = { done => [] };
    $api->getFreshReleasesAll(sort => 'overlap-b', force => 1,
        onDone => sub { push @{ $late->{done} }, $_[0] });
    is(scalar(@REQUESTS), 1, 'a forced warm arriving mid-revalidation PARKS, it does not re-fetch');
    is(scalar(@{ $late->{done} }), 0, '...and is not answered before the fetch lands');

    answer_ok($REQUESTS[0], $PAYLOAD) if @REQUESTS;
    is(scalar(@{ $late->{done} }), 1,
       '...then a BACKGROUND fetch fans out to it — the claim it holds is answerable');
    is((($late->{done}[0] || [])->[0] || {})->{release_name}, 'A',
       '...with what the fetch returned');

    # A failing background fetch must release its waiters too — a park that becomes a
    # hang is strictly worse than the duplicate fetch this replaces.
    @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    $api->getFreshReleasesAll(sort => 'overlap-c', onDone => sub { });
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    my $parked = { done => [], error => [] };
    $api->getFreshReleasesAll(sort => 'overlap-c', force => 1,
        onDone  => sub { push @{ $parked->{done} },  $_[0] },
        onError => sub { push @{ $parked->{error} }, $_[0] });
    is(scalar(@REQUESTS), 1, 'one fetch, one parked forced caller');
    answer_fail($REQUESTS[0], 'boom') if @REQUESTS;
    is(scalar(@{ $parked->{done} }) + scalar(@{ $parked->{error} }), 1,
       'a FAILED background fetch still answers the caller parked on it');
}

# ==========================================================================
section('THE FEED GUARD IS A COUNT, NOT A FLAG');
# ==========================================================================
# The hole 0.9.192 left open, and it is a consequence of its own design: %REVALIDATING
# is keyed on the FEED but was RELEASED per FETCH, unconditionally. Two foreground
# fetches of one feed on different $ikeys — a browse and a forced warm on another sort,
# precisely the overlap that build made possible — both claimed the one entry, and
# whichever finished FIRST deleted it. The survivor then ran unguarded and the next
# background revalidation sailed through: duplicate request, duplicate ~3,000-release
# chunked ingest, the one thing on this path that must not happen twice.
#
# %INFLIGHT CANNOT SEE THIS AND NEVER COULD. It is per-REQUEST, so it says nothing
# about two fetches asking different questions of the same feed — which is the whole
# reason the coarse guard exists. The section above pins that the two guards can see
# each other; this one pins that the coarse guard survives its first release.
{
    local @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    %Plugins::ListenBrainzFreshReleases::API::REVALIDATING = ();   # see the section above

    my @stored = ({ release_name => 'STORED', artist_credit_name => 'B',
                    release_date => '2026-08-01', release_group_mbid => 'rg-s',
                    release_mbid => 'r-s' });
    no warnings 'redefine', 'once';
    local *Plugins::ListenBrainzFreshReleases::DB::feedReleases = sub { [ @stored ] };
    # STALE and populated: a browse renders from it AND revalidates behind the render,
    # which is the only state in which the guard is consulted at all.
    local *Plugins::ListenBrainzFreshReleases::DB::feedCoverage =
        sub { { any => 1, complete => 1, days => 28, covered => 28,
                ok_at => time() - 10 * 86400 } };

    # TWO forced fetches of ONE feed on DIFFERENT sorts. Different $ikey, so the second
    # cannot park on the first — it issues its own request and claims the same feed.
    my $a = { done => [] };
    $api->getFreshReleasesAll(sort => 'refc-a', force => 1,
        onDone => sub { push @{ $a->{done} }, $_[0] });
    my $b = { done => [] };
    $api->getFreshReleasesAll(sort => 'refc-b', force => 1,
        onDone => sub { push @{ $b->{done} }, $_[0] });
    is(scalar(@REQUESTS), 2, 'two fetches of one feed on different sorts both go out');

    # The FIRST one lands. Under a boolean this deleted the claim outright.
    answer_ok($REQUESTS[0], $PAYLOAD) if @REQUESTS;
    is(scalar(@{ $a->{done} }), 1, 'the first is answered');
    is(scalar(@{ $b->{done} }), 0, '...and the second is still in flight');

    # A browse on a THIRD sort now arrives. Its $ikey matches neither fetch, so only
    # the feed guard can suppress its revalidation — and only if the still-running
    # second fetch's claim survived the first one's release.
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    my $browse = { done => [] };
    $api->getFreshReleasesAll(sort => 'refc-c',
        onDone => sub { push @{ $browse->{done} }, $_[0] });
    is(scalar(@{ $browse->{done} }), 1, 'a browse still renders instantly from the store');
    is(scalar(@REQUESTS), 2,
       'and its revalidation is SUPPRESSED while a sibling fetch is still running');

    # The last fetch out releases the claim — a count that never reached zero would
    # suppress every revalidation of this feed for the life of the process, which is
    # the failure a naive refcount trades for the one above.
    answer_ok($REQUESTS[1], $PAYLOAD) if @REQUESTS > 1;
    is(scalar(@{ $b->{done} }), 1, 'the second is answered');

    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    $api->getFreshReleasesAll(sort => 'refc-d', onDone => sub { });
    is(scalar(@REQUESTS), 3,
       'once BOTH are out, a later browse can revalidate again — the count reached zero');
    answer_ok($REQUESTS[2], $PAYLOAD) if @REQUESTS > 2;

    # AND A DEAD FETCH FREES ONLY ITS OWN CLAIM. The watchdog fires for one fetch while
    # a sibling is healthy; releasing the shared entry there would strand the sibling
    # unguarded exactly as the first-one-out release did.
    @REQUESTS = ();
    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    @TIMERS = ();
    $api->getFreshReleasesAll(sort => 'refc-e', force => 1, onDone => sub { });
    $api->getFreshReleasesAll(sort => 'refc-f', force => 1, onDone => sub { });
    is(scalar(@REQUESTS), 2, 'two more fetches in flight');

    # Fire the FIRST fetch's leak watchdog, leaving the second untouched.
    my ($wd) = grep { $_->{cb} } @TIMERS;
    $wd->{cb}->(@{ $wd->{args} || [] }) if $wd;

    %Plugins::ListenBrainzFreshReleases::API::FEED_MEMO = ();
    $api->getFreshReleasesAll(sort => 'refc-g', onDone => sub { });
    is(scalar(@REQUESTS), 2,
       "an expired fetch's watchdog does not free a healthy sibling's claim");
}

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
