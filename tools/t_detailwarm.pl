#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use Time::HiRes ();
our ($now, @timers) = (100);
BEGIN { $INC{'Slim/Utils/Timers.pm'} = 1 }
{ package Slim::Utils::Timers;
  sub setTimer { my $t = [@_]; push @main::timers, $t; $t }
  sub killSpecific { $_[0][4] = 1 }
  package Log; sub info {} sub warn {} sub error {}
}
{ no warnings 'redefine'; *Time::HiRes::time = sub () { $now } }
require "$FindBin::Bin/../ListenBrainzFreshReleases/DetailWarm.pm";
sub advance {
    my $to = shift; my $steps = 0;
    while (1) {
        @timers = sort { $a->[1] <=> $b->[1] } grep { !$_->[4] } @timers;
        last unless @timers && $timers[0][1] <= $to;
        die 'timer spin' if ++$steps > 10000;
        my $t = shift @timers; $now = $t->[1]; $t->[2]->($t->[0], $t->[3]);
    }
    $now = $to;
}
my ($paused, @started, @done) = (1);
my $q = Plugins::ListenBrainzFreshReleases::DetailWarm->new(
    key => sub { $_[0]{id} }, pause => sub { $paused }, log => bless({}, 'Log'),
    run => sub { push @started, $_[0]{id}; push @done, $_[1] });
$q->enqueue([{id=>'all1'},{id=>'all2'}], 1);
$q->enqueue([{id=>'personal'}], 0);
advance(105);
is(scalar @started, 0, 'core/artwork/browse priority pauses detail work');
$q->enqueue([{id=>'all2'}], 1, 1);
$paused = 0; advance(110);
is_deeply(\@started, ['all2'], 'focused week wins over background For You');
$q->enqueue([{id=>'all2'}], 1, 1); advance(111);
is(scalar @started, 1, 'an in-flight release is not duplicated');
$done[0]->(); advance(112);
is_deeply(\@started, ['all2','personal'], 'For You resumes after focused work');
$done[1]->(300, 'no player'); advance(113);
is($started[-1], 'all1', 'a deferred job does not block ready work');
$done[2]->(); advance(114);
ok(!$q->busy(), 'Last.fm may run while all remaining jobs are deferred');
is($q->stats->{pending}, 1, 'deferred job remains queued');
advance(413);
is($started[-1], 'personal', 'deferred job retries when eligible');
$done[-1]->(); advance(414);
is($q->stats->{pending}, 0, 'all jobs drained');
is($q->stats->{completed}, 3, 'completed releases counted once');
$q->enqueue([{id=>'measured'}], 0); advance(415);
$done[-1]->(0, 'cache classified', {cache_checks=>2, cache_hits=>2, fetches=>0});
advance(416);
is($q->stats->{cache_checks}, 2, 'detail stats count cache checkpoint checks');
is($q->stats->{cache_hits}, 2, 'detail stats separate cache hits from work');
is($q->stats->{fetches}, 0, 'cache-only rebuilt jobs are not reported as fetches');

$q->enqueue([{id=>'lost'}], 0); advance(417);
my $late = $done[-1];
advance(537);
is($q->stats->{failed}, 1, 'watchdog records the lost callback');
is($q->stats->{active}, 0, 'watchdog releases worker slot');
is($q->stats->{pending}, 1, 'lost job is retained for retry');
$q->enqueue([{id=>'new'}], 0); advance(538);
$late->();
is($q->stats->{active}, 1, 'late callback cannot release a newer job');
$done[-1]->(); advance(539);

# Use the real cache-aware job runner with cache and transport boundaries stubbed.
# LBF_BROWSE points at a mutated copy, so every assertion below can be anti-tested.
my $BROWSE = $ENV{LBF_BROWSE} || "$FindBin::Bin/../ListenBrainzFreshReleases/Browse.pm";
open my $fh, '<', $BROWSE or die $!;
my $src = do {local $/; <$fh>};
$src =~ /^(sub _focusReleaseCovers \{.*?^\})/ms or die 'cover focus missing';
unlike($1, qr/_queueReleaseDetails/, 'list open, Show more and Show all focus artwork only');
$src =~ /^(sub _warmReleaseDetails \{.*?^\})/ms or die 'runner missing';
my $runner = $1;
# _sectionBounds is lifted too, not stubbed. It is the sub under test in section 8:
# a hand-written copy here could agree with a broken shipped one — say, one that
# went back to widening For You with a MuSpy window of its own.
$src =~ /^(sub _sectionBounds \{.*?^\})/ms or die 'section bounds missing';
my $bounds = $1;
{
    package R;
    our (%values, @calls, $player, $failMb, $failStream);
    our $cache = bless {}, 'Cache';
    our $prefs = bless {play_via=>1}, 'Prefs';
    sub _pickValue { my $r = shift; for (@_) { return $r->{$_} if defined $r->{$_} } '' }
    sub _filterForYou { $_[0] }
    sub _filterAll { $_[0] }
    sub _orderedAdapters { ({name=>'Qobuz'}) }
    sub streamingNotReady { () }
    sub _streamId { $_[2] }
    sub _streamKey { 'stream:'.$_[0] }
    sub _findPlayable { push @calls, 'stream'; $values{'stream:'.$_[4]}={items=>[]} unless $failStream; $_[1]->({items=>[]}) }
    package Cache; sub get { $R::values{$_[1]} }
    package Prefs; sub get { $_[0]{$_[1]} }
    package Slim::Player::Client; sub clients { $R::player ? ('player') : () }
    package Plugins::ListenBrainzFreshReleases::API;
    # PREFIX-AWARE, and that is the point of the stub. A single window for every
    # prefix cannot tell a For You window widened by some other prefix apart from
    # the plain For You window, so a flat stub would pass against that regression.
    our %WINDOW = (foryou => ['2026-09-01','2026-09-30'],
                   muspy  => ['2026-09-01','2026-09-30'],
                   all    => ['2026-09-01','2026-09-30']);
    sub sectionWindow { my $w = $WINDOW{$_[1] // ''} or return (); @$w }
    sub getReleaseDetails {
        my ($class,$id,$ok,$err)=@_; push @R::calls,'mb';
        if ($R::failMb) { $err->('offline'); return }
        $R::values{'lbf:mb:'.$id}={media=>[]}; $ok->({media=>[]});
    }
}
eval "package R; no strict 'vars'; $runner $bounds"; die $@ if $@;
my $rel = {release_mbid=>'id', artist=>'artist', release_name=>'album'};
my ($retry, $work);
$R::player=1;
R::_warmReleaseDetails($rel, sub { $retry=shift; shift; $work=shift });
is_deeply(\@R::calls, ['mb','stream'], 'cold release warms normal tracklist and streaming caches');
is($retry, 0, 'written answers mark the job complete');
is_deeply($work, {cache_checks=>2, cache_hits=>0, fetches=>2},
          'cold detail stats report checks and actual fetches separately');
@R::calls=();
R::_warmReleaseDetails($rel, sub { $retry=shift; shift; $work=shift });
is_deeply(\@R::calls, [], 'reconstructed job after restart makes no requests when caches are warm');
is_deeply($work, {cache_checks=>2, cache_hits=>2, fetches=>0},
          'reconstructed cache-only job reports hits rather than fetches');
%R::values=(); $R::player=0;
R::_warmReleaseDetails($rel, sub { $retry=shift });
is_deeply(\@R::calls, ['mb'], 'tracklist can warm without a connected streaming player');
is($retry, 300, 'streaming remains queued until a player is available');
@R::calls=(); %R::values=(); $R::player=1; $R::failMb=1;
R::_warmReleaseDetails($rel, sub { $retry=shift });
is_deeply(\@R::calls, ['mb','stream'], 'tracklist error still allows independent streaming progress');
is($retry, 300, 'tracklist error is retried, not reported as complete');
$R::failMb=0; $R::failStream=1; %R::values=();
R::_warmReleaseDetails($rel, sub { $retry=shift });
is($retry, 300, 'missing streaming cache write remains retryable');
@R::calls=(); $R::failStream=0; $R::values{'stream:id'}={items=>[],retry_at=>time()+600};
R::_warmReleaseDetails($rel, sub { $retry=shift });
is_deeply(\@R::calls, [], 'inconclusive streaming miss honours existing retry deadline');
ok($retry>0, 'retryable miss stays on the queue');
@R::calls=(); %R::values=();
R::_warmReleaseDetails({%$rel, release_date=>'2025-01-01'}, sub { $retry=shift }, [0,1]);
is_deeply(\@R::calls, [], 'queued release outside both current windows is skipped');
is($retry, 0, 'obsolete job leaves the queue instead of retrying');

# ==========================================================================
# 8. MUSPY RIDES FOR YOU'S WEEKS — SOURCE 0 HAS ONE WINDOW
# ==========================================================================
# MuSpy used to carry its own future gate, and source-0 eligibility took the UNION
# of the For You and MuSpy windows (both feeds enqueue at priority 0, so a job
# cannot say which feed it came from). MuSpy has no window of its own now: its rows
# merge into For You and are windowed by For You's weeks, so a source-0 job is
# judged by the For You window alone — the same window the merge shows.
#
# The stub still answers a WIDER window for a 'muspy' prefix on purpose: if anything
# went back to asking for one, the bounds below would widen and this section fails.
{
    local $R::values{'lbf:mb:id'} = undef;
    %R::values = (); @R::calls = (); $R::player = 1;
    local $Plugins::ListenBrainzFreshReleases::API::WINDOW{foryou}
        = ['2026-09-01','2026-09-14'];    # this week + one upcoming
    local $Plugins::ListenBrainzFreshReleases::API::WINDOW{muspy}
        = ['2026-09-01','2026-09-30'];    # a stale, wider window that must NOT leak in

    my $upcoming = {%$rel, release_date => '2026-09-24', _source => 'muspy'};

    is_deeply([R::_sectionBounds('foryou')], ['2026-09-01','2026-09-14'],
              'For You bounds are the For You window — no MuSpy union');
    is_deeply([R::_sectionBounds('all')], ['2026-09-01','2026-09-30'],
              'All Releases bounds are its own window');

    # THE CONTROL: the stale MuSpy window really would have accepted this release,
    # else refusing it below proves nothing about the union being gone.
    my (undef, $mTo) = Plugins::ListenBrainzFreshReleases::API->sectionWindow('muspy');
    ok($upcoming->{release_date} le $mTo,
       'the release is inside the old MuSpy window — else this proves nothing');

    R::_warmReleaseDetails($upcoming, sub { $retry = shift }, [0]);
    is_deeply(\@R::calls, [],
              'a MuSpy release past For You\'s weeks is not prewarmed — it is not shown');
    is($retry, 0, 'and it leaves the queue rather than retrying');

    @R::calls = ();
    R::_warmReleaseDetails({%$upcoming, release_date => '2026-09-10'},
                           sub { $retry = shift }, [0]);
    is_deeply(\@R::calls, ['mb','stream'],
              'a MuSpy release inside For You\'s weeks is prewarmed');
}

# ==========================================================================
# SECTION 9 — THE STARTUP SKIP PATH RE-SEEDS A QUEUE THAT CAN ACTUALLY RUN.
#
# docs/scheduled-overnight-warm.md §4B stops a restart re-running a full warm when
# one already ran today. §4F is what stops that being a regression: _queueReleaseDetails
# has four call sites and ALL FOUR are inside warmFeeds, and the queue is a hash in
# MEMORY — so a skipped catch-up would leave it empty until the next scheduled tick.
#
# THE ASSERTION THE DESIGN DOCUMENT ASKED FOR IS NOT SUFFICIENT, AND THAT IS THE
# POINT OF THIS SECTION. It asked for "detail_pending is non-zero". A queue that is
# seeded and then PAUSED has a non-zero pending count too, and that is exactly the
# state the skip path would leave behind: $detailMainReady is a file lexical that
# starts at 0 and is set to 1 in ONE place — the genre tails inside warmFeeds —
# while _detailPriorityBusy reports busy for as long as it is 0. warmFeeds does not
# run on this path, so without an explicit release the flag stays 0 for the life of
# the process and nothing drains. Nine hours of no pre-warm, reported as success.
#
# So this pins RUNNABLE, not merely POPULATED, and it pins the control that makes
# that mean something: the queue really was paused beforehand.
{
    package S;
    our (@queued, @covers, @forced, $detailMainReady, $lastfmWarmPending,
         $lastfmRequestBusy);
    our $prefs = bless {username => 'someone'}, 'Prefs';

    # The two queues, recorded rather than driven — section 1 already proves the
    # runner, and what is under test here is which releases reach it.
    sub _warmCovers         { push @covers, [ scalar @{$_[0]}, $_[1] ] }
    sub _queueReleaseDetails{ push @queued, [ scalar @{$_[0]}, $_[1] ] }
    sub _filterForYou       { $_[0] }
    sub _filterAll          { $_[0] }
    sub _mergeMuSpy         { $_[1] // [] }
    sub _dbg                {}
    sub _lastfmPriorityBusy { 0 }

    package Plugins::ListenBrainzFreshReleases::API;
    # RECORD WHETHER `force` WAS PASSED. This is the control half: a re-seed that
    # quietly re-fetched every feed would satisfy every "the queue is populated"
    # assertion while costing three ListenBrainz requests on every restart — which
    # is most of what the startup gate exists to save.
    sub _answer {
        my ($class, %a) = @_;
        push @S::forced, ($a{force} ? 'FORCED' : 'store');
        $a{onDone}->([ {release_mbid=>'a'}, {release_mbid=>'b'} ]) if $a{onDone};
    }
    sub getFreshReleasesForUser { shift->_answer(@_) }
    sub getFreshReleasesAll     { shift->_answer(@_) }
    sub getMuSpyReleases        { shift->_answer(@_) }
}
{
    my $bsrc = do { open my $f, '<', $BROWSE or die $!; local $/; <$f> };
    for my $name (qw(reseedFromStore _fanOutFeed _detailPriorityBusy)) {
        $bsrc =~ /^(sub \Q$name\E \{.*?^\})/ms or die "$name missing";
        eval "package S; no strict 'vars'; $1"; die $@ if $@;
    }

    # THE CONTROL, FIRST. $detailMainReady starts at 0 — the state a freshly booted
    # process is in — so the detail queue is PAUSED. Without this line the assertion
    # below would pass against a re-seed that never touched the flag at all.
    $S::detailMainReady = 0;
    ok(S::_detailPriorityBusy(),
       'before the re-seed the detail queue is paused — else the next assertion proves nothing');

    S::reseedFromStore();

    ok(!S::_detailPriorityBusy(),
       'after the re-seed the detail queue can actually RUN, not merely hold jobs');

    is(scalar @S::queued, 3,
       're-seed queues detail work for all three feeds from the store');
    is(scalar @S::covers, 3,
       'and warms their artwork through the same one fan-out');
    # THE LABELS MUST BE THE WARM'S OWN. This assertion used to require a
    # '(re-seed)' suffix "so warmstats cannot read it as a warm" — but the label
    # reaches no report; it is the key _warmCovers and _queueReleaseDetails decide
    # ORDER on (`eq 'all releases'` week-orders both queues). The suffix silently
    # queued a restart's covers and details newest-date-first. Read the warm's
    # labels out of warmFeeds rather than restating them, so the two cannot drift.
    my ($wf) = $bsrc =~ /^(sub warmFeeds \{.*?^\})/ms;
    my %warmLabels = map { $_ => 1 } ($wf // '') =~ /_fanOutFeed\([^;]*?,\s*'([^']+)'\s*\)/g;
    is_deeply([ sort keys %warmLabels ], [ 'all releases', 'for you', 'muspy' ],
              'control: warmFeeds fans out under exactly these three labels');
    is_deeply([ sort map { $_->[1] } @S::queued ], [ sort keys %warmLabels ],
              're-seed labels are byte-identical to the warm\'s, so both queues order a restart the same way');

    # THE OTHER HALF. Asserting only "the queue is populated" passes against a skip
    # that quietly fetched; asserting only "no request" passes against a skip that
    # seeds nothing. Both are required, which is why they sit together.
    is_deeply([ grep { $_ eq 'FORCED' } @S::forced ], [],
              'no feed is force-fetched — the re-seed reads the store, it does not warm');
    is(scalar @S::forced, 3,
       'all three feeds were nonetheless consulted (control: it did not simply skip them)');
}

done_testing();
