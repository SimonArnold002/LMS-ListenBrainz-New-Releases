#!/usr/bin/env perl
#
# t_mbqueue.pl — the two request queues and the tracklist source (2026-09-14).
#
# WHY. On 2026-09-14 the live server logged ~80 MusicBrainz 503s in ten minutes
# after a restart. MusicBrainz's rule is ~1 request per second per IP, averaged,
# and above it EVERY request from the IP is refused. Five code paths called it and
# each paced itself at best, so the sum went over. The fix is structural:
#
#   1. API::_mbGet — ONE queue for public MusicBrainz: one in flight, MB_GAP apart,
#      nothing sent during the shared 503 backoff. A mirror is not queued.
#   2. API::_hostedGet — ONE queue for the LMS-community API: one in flight (MAI's
#      own precedent for this service), the existing 429 backoff and budgets.
#   3. API::getTracklist — ListenBrainz by release group first, MusicBrainz for the
#      exact release only when ListenBrainz has none.
#
# Everything is driven BEHAVIOURALLY over a fake clock and a transport that answers
# only when the test says so, because the properties are "how many requests are out
# at once" and "when does the next one go", which no pattern match can show.
#
# The subs are lifted from the real API.pm (LBF_API overrides it), not restated.
# ANTI-TEST, each should turn its own section red:
#   - _mbPump: drop `!$mbInFlight &&` from the while            -> 1 red
#   - _mbPump: ignore $mbBusyUntil                              -> 2 red
#   - _mbSend: release AFTER the caller's callback, no local     -> 4 red
#   - _hostedPump: drop `!$hostedInFlight &&`                   -> 5 red
#   - getTracklist: skip ListenBrainz and go straight to MB     -> 7 red

use strict;
use warnings;
use FindBin;
use JSON::PP ();

our $now = 100;
BEGIN { *CORE::GLOBAL::time = sub { int $main::now } }
# LOAD Time::HiRes BEFORE replacing its clock. SingleFlight.pm does `use
# Time::HiRes ()`, and loading the real module after the override silently puts the
# real clock back — the queue then waits on wall-clock time the fake clock never
# reaches, which reads exactly like a queue that never sends its second request.
use Time::HiRes ();
BEGIN { no warnings 'redefine'; *Time::HiRes::time = sub () { $main::now } }

my ($pass, $fail) = (0, 0);
sub ok { my ($c, $m) = @_; die "ok() needs a message\n" unless defined $m && length $m;
         if ($c) { $pass++; print "  ok   $m\n" } else { $fail++; print "  FAIL $m\n" } }
sub is { my ($g, $w, $m) = @_; $g //= '(undef)'; $w //= '(undef)';
         if ($g eq $w) { $pass++; print "  ok   $m\n" }
         else { $fail++; print "  FAIL $m  ->  '$g' (wanted '$w')\n" } }
sub section { print "\n$_[0]\n", '-' x 74, "\n" }

# ---------------------------------------------------------------- the stubs --
our (@TIMERS, @HTTP);
{
    package Slim::Utils::Timers;
    sub setTimer { my $t = [@_]; push @main::TIMERS, $t; $t }
    sub killSpecific { $_[0][4] = 1 if ref $_[0] }
    $INC{'Slim/Utils/Timers.pm'} = 1;

    package Slim::Utils::Log;
    sub logger { bless {}, 'T::Log' }
    $INC{'Slim/Utils/Log.pm'} = 1;
    package T::Log; sub info {} sub warn {} sub error {} sub is_info { 0 }

    package Slim::Utils::Misc;     # no apiHeaders: the literal-header fallback is used

    # A transport that answers ONLY when the test calls ->answer / ->fail. $SYNC
    # makes it answer inside ->get instead, the shape of a cached transport.
    package Slim::Networking::SimpleAsyncHTTP;
    our $SYNC;
    sub new { my ($c, $ok, $err, $opt) = @_; bless { ok => $ok, err => $err, opt => $opt }, $c }
    sub get {
        my ($self, $url, @h) = @_;
        $self->{url} = $url; $self->{headers} = {@h};
        push @main::HTTP, $self;
        $self->answer($SYNC) if defined $SYNC;
        return 1;
    }
    sub answer { my ($s, $body) = @_; $s->{ok}->(T::Resp->new(content => $body)) }
    sub fail   { my ($s, %r) = @_; $s->{err}->(T::Resp->new(%r), $r{error}) }

    package T::Resp;
    sub new     { my ($c, %a) = @_; bless {%a}, $c }
    sub content { $_[0]{content} // '' }
    sub code    { $_[0]{code} }
    sub error   { $_[0]{error} }
    sub headers { bless {}, 'T::Headers' }
    package T::Headers; sub header { undef }

    package T::Cache;
    sub new { bless { v => {}, ttl => {} }, shift }
    sub get { $_[0]{v}{$_[1]} }
    sub set { $_[0]{v}{$_[1]} = $_[2]; $_[0]{ttl}{$_[1]} = $_[3]; 1 }
}

sub advance {
    my ($to) = @_;
    my $n = 0;
    while (1) {
        @TIMERS = sort { $a->[1] <=> $b->[1] } grep { !$_->[4] } @TIMERS;
        last unless @TIMERS && $TIMERS[0][1] <= $to;
        die "timer spin\n" if ++$n > 10000;
        my $t = shift @TIMERS;
        $now = $t->[1] if $t->[1] > $now;
        $t->[2]->($t->[0], @{$t}[3 .. $#$t]);
    }
    $now = $to if $to > $now;
}
sub inflight { scalar grep { !$_->{done} } @HTTP }

# ---------------------------------------------------------------- the lift --
my $API = $ENV{LBF_API} || "$FindBin::Bin/../ListenBrainzFreshReleases/API.pm";
open my $fh, '<', $API or die "$API: $!";
my $SRC = do { local $/; <$fh> };
sub grab {
    my ($name) = @_;
    return $1 if $SRC =~ /^(sub \Q$name\E \{[^\n]*\}\n)/m;          # one-liner
    return $1 if $SRC =~ /^(sub \Q$name\E \{.*?^\})/ms;
    die "t_mbqueue: sub $name not found in $API\n";
}

require "$FindBin::Bin/../ListenBrainzFreshReleases/SingleFlight.pm";
$INC{'Plugins/ListenBrainzFreshReleases/SingleFlight.pm'} = 1;
{
    package Plugins::ListenBrainzFreshReleases::API::LostResponse;
    sub new { bless {}, shift } sub code { 0 } sub error { 'timed out' } sub content { '' }
    package Plugins::ListenBrainzFreshReleases::DB;
    sub kver { $_[0] . '1:' }
}

# The constants the lifted subs expect, read out of the real file so a change there
# is a change here. Installed BEFORE the lift compiles: under strict subs a bareword
# constant must already exist when the code naming it is compiled.
for my $c (qw(MB_GAP MB_WATCHDOG_PAD MB_BACKOFF_START MB_BACKOFF_MAX
              HOSTED_BACKOFF_START HOSTED_BACKOFF_MAX HOSTED_RETRY_MAX HOSTED_WAIT_MAX
              HOSTED_WATCHDOG_PAD)) {
    my ($v) = $SRC =~ /^use constant \Q$c\E\s*=>\s*([\d.]+)/m or die "constant $c not found\n";
    no strict 'refs';
    *{"Q::$c"} = sub () { $v };
}

my $code = join "\n", map { grab($_) } qw(
    _mbWait _mbIsRateLimited _mbNoteLimit _mbNoteOk
    _mbIsPublicUrl _mbGet _mbQueueWait _mbPump _mbSend
    _hostedWait _hostedIsRateLimited _hostedNoteLimit _hostedNoteOk
    _hostedGet _hostedPump _hostedSend
    _lbWait _lbNoteLimit _lbIsRateLimited
    _hasTracks _lbTracksKey peekTracklist getTracklist _fetchLbTracklist _parseLbTracklist
);
eval <<"EOF" or die $@;
package Q;
no strict 'vars';
use constant USER_AGENT => 'test/1';
use constant PLUGIN_PACKAGE => 'Plugins::ListenBrainzFreshReleases::Plugin';
use constant BASE_URL => 'https://api.listenbrainz.org';
use constant HOSTED_BASE_URL => 'https://api.lms-community.org/music/';
use constant HOSTED_TIMEOUT => 4;
use constant MB_FOUND_TTL => 30 * 86400;
use constant MB_EMPTY_TTL => 86400;
use constant LB_RETRY_MAX => 3;
use constant LB_BACKOFF_MIN => 2;
use constant LB_BACKOFF_CAP => 30;
our \$log = bless {}, 'T::Log';
our \$cache = T::Cache->new;
sub from_json { JSON::PP->new->utf8(0)->decode(\$_[0]) }
our (\@MBCALLS);
sub getReleaseDetails { my (\$c, \$mbid, \$ok, \$err) = \@_; push \@MBCALLS, \$mbid; \$ok->({ media => [ { position => 1, format => 'CD', tracks => [ { position => 1, title => 'from MB', length => 1 } ] } ] }) }
$code
1;
EOF

no warnings 'once';
sub reset_all {
    @HTTP = (); @TIMERS = (); $now = 100;
    $Slim::Networking::SimpleAsyncHTTP::SYNC = undef;
    @Q::mbQueue = (); $Q::mbInFlight = 0; $Q::mbNextAt = 0; $Q::mbTimer = undef;
    $Q::mbBusyUntil = 0; $Q::mbDelay = 0;
    @Q::hostedQueue = (); $Q::hostedInFlight = 0; $Q::hostedTimer = undef;
    $Q::hostedBusyUntil = 0; $Q::hostedDelay = 0;
    $Q::_lbBusyUntil = 0; @Q::MBCALLS = ();
    $Q::cache = T::Cache->new;
}
sub mark { $_->{done} = 1 for @_ }

my $PUB = 'https://musicbrainz.org/ws/2/';

# ===========================================================================
section '1. MUSICBRAINZ: ONE REQUEST IN FLIGHT, EVER';
{
    reset_all();
    my @got;
    Q::_mbGet("${PUB}a", sub { push @got, 'a' }) for 1;
    Q::_mbGet("${PUB}b", sub { push @got, 'b' });
    Q::_mbGet("${PUB}c", sub { push @got, 'c' });
    is(scalar @HTTP, 1, 'three callers at once send ONE request');

    advance(105);                                 # far past the gap, first still out
    is(scalar @HTTP, 1, 'the gap passing does not release a second while one is in flight');

    $HTTP[0]->answer('{}'); mark($HTTP[0]);
    is($got[0], 'a', 'the first caller is answered');
    is(scalar @HTTP, 2, 'the moment it lands (gap already long past), the next goes');
    ok(scalar($HTTP[1]{url} =~ m{/b$}), '...in the order they were queued');
}

# ===========================================================================
section '2. MUSICBRAINZ: MB_GAP BETWEEN SENDS, AND NOTHING DURING A 503 BACKOFF';
{
    reset_all();
    Q::_mbGet("${PUB}a", sub {});
    Q::_mbGet("${PUB}b", sub {});
    $HTTP[0]->answer('{}');                       # answered at t=100, sent at t=100
    is(scalar @HTTP, 1, 'a fast answer does not let the next one out early');
    advance(100 + Q::MB_GAP() - 0.05);
    is(scalar @HTTP, 1, '...not even just before MB_GAP');
    advance(100 + Q::MB_GAP());
    is(scalar @HTTP, 2, '...and it goes exactly MB_GAP after the previous SEND');

    # A refusal: the queue notes it, the caller is told, and the next waits it out.
    reset_all();
    my @err;
    Q::_mbGet("${PUB}a", sub {}, sub { push @err, $_[1] // ($_[0] && $_[0]->error) });
    Q::_mbGet("${PUB}b", sub {});
    $HTTP[0]->fail(error => '503 Service Temporarily Unavailable');
    is(scalar @err, 1, 'the refused caller\'s error path runs once');
    ok(Q::_mbWait() > 0, 'the queue itself noted the limit on the shared backoff');
    ok(Q::_mbQueueWait() > 2, '...and reports the wait, for the connection check');
    advance(104.9);
    is(scalar @HTTP, 1, 'nothing is sent while the backoff is in force');
    advance(105.1);
    is(scalar @HTTP, 2, '...and the queue resumes when it ends');
    $HTTP[1]->answer('{}');
    is($Q::mbDelay, 0, 'a success clears the backoff curve');
}

# ===========================================================================
section '3. MUSICBRAINZ: A MIRROR IS NOT QUEUED; THE PUBLIC FALLBACK IS';
{
    reset_all();
    Q::_mbGet("${PUB}a", sub {});
    Q::_mbGet('http://plex:5000/ws/2/artist/x', sub {});
    is(scalar @HTTP, 2, 'a request to a local mirror goes out beside a public one');
    Q::_mbGet("${PUB}artist?query=x", sub {});
    is(scalar @HTTP, 2, 'but the public-host retry a mirror search makes IS queued');
    ok(!$Q::mbInFlight || $HTTP[1]{url} =~ /plex/, 'the mirror request never held the public slot');
}

# ===========================================================================
section '4. MUSICBRAINZ: THE QUEUE CANNOT BE WEDGED';
{
    # A transport that never calls back: the watchdog frees the slot and ANSWERS.
    reset_all();
    my @err;
    Q::_mbGet("${PUB}lost", sub { push @err, 'late-ok' }, sub { push @err, ref $_[0] ? $_[0]->error : 'x' });
    Q::_mbGet("${PUB}next", sub {});
    advance(100 + 15 + Q::MB_WATCHDOG_PAD() + 0.1);
    is(scalar @HTTP, 2, 'a lost callback frees the slot after timeout + pad');
    is($err[0], 'timed out', '...answering the caller with a response-shaped object');
    $HTTP[0]->answer('{}');
    is(scalar @err, 1, 'and a late real answer does not call the caller a second time');

    # A caller whose callback dies must not leave the pump guard set.
    reset_all();
    Q::_mbGet("${PUB}dies", sub { die "boom\n" });
    Q::_mbGet("${PUB}after", sub {});
    eval { $HTTP[0]->answer('{}') };
    ok($@ =~ /boom/, '(the caller\'s callback died)');
    advance(102);
    is(scalar @HTTP, 2, 'the next request still goes out after a callback died');

    # A transport that answers synchronously, inside ->get.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::SYNC = '{}';
    my $n = 0;
    Q::_mbGet("${PUB}s$_", sub { $n++ }) for 1 .. 3;
    advance(110);
    is($n, 3, 'synchronous answers drain the whole queue across the gap timers');
    is(scalar @HTTP, 3, '...one request each');
    ok($HTTP[1]{url} && $HTTP[2]{url}, '(all three sent)');
}

# ===========================================================================
section '4b. MUSICBRAINZ: A FRONT JOB (THE CONNECTION CHECK) JUMPS THE LINE, NOT THE RULES';
{
    # A warm has a, b, c waiting (a in flight); the connection check then asks for
    # the front twice. It must go ahead of b and c — and still never beside a,
    # never inside MB_GAP, never during a backoff.
    reset_all();
    Q::_mbGet("${PUB}$_", sub {}) for qw(a b c);
    Q::_mbGet("${PUB}f1", sub {}, undef, front => 1);
    Q::_mbGet("${PUB}f2", sub {}, undef, front => 1);
    is(scalar @HTTP, 1, 'a front job does not go out beside the request already in flight');

    $HTTP[0]->answer('{}'); mark($HTTP[0]);       # a lands at t=100, inside the gap
    is(scalar @HTTP, 1, '...nor before MB_GAP has passed');
    advance(100 + Q::MB_GAP());
    ok(scalar(($HTTP[1]{url} // '') =~ m{/f1$}), 'the first front job goes before the earlier-queued b and c');

    $HTTP[1]->answer('{}'); advance(100 + 2 * Q::MB_GAP());
    ok(scalar(($HTTP[2]{url} // '') =~ m{/f2$}), 'two front jobs keep their own order');

    $HTTP[2]->answer('{}'); advance(100 + 3 * Q::MB_GAP());
    ok(scalar(($HTTP[3]{url} // '') =~ m{/b$}), '...and the ordinary queue resumes where it left off');
    is(scalar @HTTP, 4, 'one request per turn throughout');

    # A 503 backoff holds a front job like anything else.
    reset_all();
    Q::_mbGet("${PUB}a", sub {}, sub {});
    Q::_mbGet("${PUB}f", sub {}, undef, front => 1);
    $HTTP[0]->fail(error => '503 Service Temporarily Unavailable');
    advance(104.9);
    is(scalar @HTTP, 1, 'a front job waits out a 503 backoff');
    advance(105.1);
    ok(@HTTP == 2 && scalar(($HTTP[1]{url} // '') =~ m{/f$}), '...and is the first thing sent after it');
}

# ===========================================================================
section '5. COMMUNITY API: ONE REQUEST IN FLIGHT, 429 RETRIES AT THE FRONT';
{
    reset_all();
    my (@found, @miss);
    Q::_hostedGet('artist/a/mbid', sub { push @found, 'a' }, sub { push @miss, 'a' });
    Q::_hostedGet('artist/b/mbid', sub { push @found, 'b' }, sub { push @miss, 'b' });
    is(scalar @HTTP, 1, 'two callers send ONE request');
    is($HTTP[0]{headers}{'X-LMS-Plugin-ID'}, 'Plugins::ListenBrainzFreshReleases::Plugin',
       'the mandatory plugin-id header is sent');
    $HTTP[0]->answer('{"mbid":"x"}');
    is($found[0], 'a', 'the first is answered');
    is(scalar @HTTP, 2, 'and the next goes immediately — no gap, only one at a time');

    # A 429 on b: b goes back to the FRONT, c waits behind it, both wait out the deadline.
    Q::_hostedGet('artist/c/mbid', sub { push @found, 'c' }, sub { push @miss, 'c' });
    $HTTP[1]->fail(code => 429, error => '429 Too Many Requests');
    ok(Q::_hostedWait() > 0, 'a 429 sets the shared deadline');
    is(scalar @HTTP, 2, 'nothing is sent during it');
    advance(105.5);
    is(scalar @HTTP, 3, 'after the deadline one request goes');
    ok(scalar($HTTP[2]{url} =~ m{/b/}), '...and it is the RETRY, not the job queued behind it');
    is(scalar @miss, 0, 'a retried 429 is not reported as a miss');

    # The retry budget: b keeps getting 429 until HOSTED_RETRY_MAX is spent.
    my $t = 105.5;
    for (1 .. Q::HOSTED_RETRY_MAX()) {
        $HTTP[-1]->fail(code => 429, error => '429');
        $t += 31; advance($t);
    }
    ok(scalar(grep { $_ eq 'b' } @miss) == 1, 'past HOSTED_RETRY_MAX the retry becomes ONE miss');
    ok(scalar($HTTP[-1]{url} =~ m{/c/}), '...and the queue moves on to the next job');
}

# ===========================================================================
section '6. COMMUNITY API: A LOST CALLBACK AND A PERMANENT DEADLINE ARE NOT HANGS';
{
    reset_all();
    my @miss;
    Q::_hostedGet('artist/lost/mbid', sub {}, sub { push @miss, 'lost' });
    Q::_hostedGet('artist/next/mbid', sub {}, sub { push @miss, 'next' });
    advance(100 + 4 + Q::HOSTED_WATCHDOG_PAD() + 0.1);
    is($miss[0], 'lost', 'a callback that never arrives is reported as a miss');
    is(scalar @HTTP, 2, '...and frees the slot for the next job');

    reset_all();
    my @m2;
    # Someone else's deadline, pushed OUT again at every wake — a deadline only ever
    # moves outward in the real code (_hostedNoteLimit), so never set it far out and
    # then pull it in: the queue's timer is armed for the deadline it saw.
    $Q::hostedBusyUntil = int($now) + 5;
    Q::_hostedGet('artist/stuck/mbid', sub {}, sub { push @m2, 'stuck' });
    my $wakes = 0;
    while (!@m2 && $wakes++ < 50) {
        # Still held at every wake: pushed PAST the next wake-up (a deadline that
        # ends exactly when the queue wakes is a deadline that has ended).
        $Q::hostedBusyUntil = int($now) + 10;
        advance($now + 6);
    }
    is(scalar @m2, 1, 'a deadline that never clears ends in ONE miss, not a hang');
    ok($wakes <= Q::HOSTED_WAIT_MAX() + 2, "...within the wait budget ($wakes wakes)");
    is(scalar @HTTP, 0, 'and nothing was sent into the held deadline');
}

# ===========================================================================
section '7. TRACKLISTS: LISTENBRAINZ FIRST, MUSICBRAINZ ONLY WHEN IT HAS NONE';
{
    my $RG = 'f02f15c0-3dcd-4463-bcdf-c87838fd27d4';
    # Shape captured live 2026-09-14 (Sinister Grift, trimmed to two tracks).
    my $LB = '{"' . $RG . '":{"recording":{"release_mbid":"b15b950c","mediums":[{"format":"CD","position":1,"tracks":['
           . '{"name":"Praise","position":1,"length":211120},{"name":"Anywhere but Here","position":2,"length":200000}]}]},'
           . '"release_group":{"name":"Sinister Grift"}}}';

    # (a) ListenBrainz has it.
    reset_all();
    my @got;
    Q->getTracklist($RG, 'rel-1', sub { push @got, $_[0] }, sub { push @got, 'ERR' });
    is(scalar @HTTP, 1, 'one ListenBrainz request');
    ok(scalar($HTTP[0]{url} =~ m{^https://api\.listenbrainz\.org/1/metadata/release_group/\?inc=recording&release_group_mbids=\Q$RG\E$}),
       '...to the release-group metadata route with inc=recording');
    $HTTP[0]->answer($LB);
    my $p = $got[0];
    is(scalar @Q::MBCALLS, 0, 'MusicBrainz is NOT asked when ListenBrainz has a tracklist');
    is($p->{media}[0]{format}, 'CD', 'mediums -> media, format kept');
    is($p->{media}[0]{tracks}[1]{title}, 'Anywhere but Here', 'name -> title');
    is($p->{media}[0]{tracks}[0]{length}, 211120, 'length in ms, as the detail page expects');
    my ($k) = grep { /^lbf:lbtracks:/ } keys %{ $Q::cache->{v} };
    is($Q::cache->{ttl}{$k}, 30 * 86400, 'a found tracklist is cached for the long TTL');

    @got = ();
    Q->getTracklist($RG, 'rel-1', sub { push @got, $_[0] });
    is(scalar @HTTP, 1, 'the second open makes no request');
    ok(Q->peekTracklist($RG, 'rel-1'), 'and peekTracklist reports it answered');

    # (b) ListenBrainz has none -> the exact release from MusicBrainz.
    reset_all();
    @got = ();
    Q->getTracklist($RG, 'rel-2', sub { push @got, $_[0] });
    $HTTP[0]->answer('{}');
    is_deeply_ok(\@Q::MBCALLS, ['rel-2'], 'ListenBrainz "none" falls back to MusicBrainz for the exact release');
    is($got[0]{media}[0]{tracks}[0]{title}, 'from MB', '...and answers with it');
    ($k) = grep { /^lbf:lbtracks:/ } keys %{ $Q::cache->{v} };
    is($Q::cache->{ttl}{$k}, 86400, 'ListenBrainz "none" is cached short');
    @got = (); @Q::MBCALLS = ();
    Q->getTracklist($RG, 'rel-2', sub { push @got, $_[0] });
    is(scalar @HTTP, 1, 'a later open does not ask ListenBrainz again');

    # (c) the ListenBrainz request fails -> MusicBrainz, and "none" is NOT cached.
    reset_all();
    Q->getTracklist($RG, 'rel-3', sub {});
    $HTTP[0]->fail(code => 500, error => '500 Internal Server Error');
    is_deeply_ok(\@Q::MBCALLS, ['rel-3'], 'a failed ListenBrainz request falls back to MusicBrainz');
    ok(!scalar(grep { /^lbf:lbtracks:/ } keys %{ $Q::cache->{v} }), '...and caches nothing for ListenBrainz');

    # (d) no release id (a Trending or MuSpy row) and ListenBrainz has none.
    reset_all();
    @got = ();
    Q->getTracklist($RG, '', sub { push @got, $_[0] });
    $HTTP[0]->answer('{}');
    is(scalar @Q::MBCALLS, 0, 'with no release id there is nothing to ask MusicBrainz');
    ok(ref $got[0] eq 'HASH' && !@{ $got[0]{media} }, '...so the answer is an empty tracklist');
    ok(Q->peekTracklist($RG, ''), 'and that answer counts as answered');

    # (e) no group id -> MusicBrainz directly.
    reset_all();
    Q->getTracklist('', 'rel-4', sub {});
    is(scalar @HTTP, 0, 'no release group: ListenBrainz is not asked');
    is_deeply_ok(\@Q::MBCALLS, ['rel-4'], '...MusicBrainz is');

    # (f) an exact MusicBrainz answer already stored is served first.
    reset_all();
    $Q::cache->set('lbf:mb:rel-5', { media => [ { tracks => [ { title => 'stored' } ] } ] }, 1);
    @got = ();
    Q->getTracklist($RG, 'rel-5', sub { push @got, $_[0] });
    is(scalar @HTTP, 0, 'a stored exact MusicBrainz tracklist costs no request');
    is($got[0]{media}[0]{tracks}[0]{title}, 'stored', '...and is what is served');

    # (g) two callers for one album share one request; a 429 is retried, not MB.
    reset_all();
    my $n = 0;
    Q->getTracklist($RG, 'rel-6', sub { $n++ });
    Q->getTracklist($RG, 'rel-6', sub { $n++ });
    is(scalar @HTTP, 1, 'a detail open and the prewarm for the same album share ONE request');
    $HTTP[0]->fail(code => 429, error => '429 Too Many Requests');
    is(scalar @Q::MBCALLS, 0, 'a ListenBrainz 429 does not fall back to MusicBrainz');
    advance(110);
    is(scalar @HTTP, 2, '...it is retried after the backoff');
    $HTTP[1]->answer($LB);
    is($n, 2, 'and both callers are answered');
}

sub is_deeply_ok { my ($g, $w, $m) = @_; is(join(',', @$g), join(',', @$w), $m) }

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
