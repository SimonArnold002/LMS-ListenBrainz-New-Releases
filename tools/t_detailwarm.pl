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
done_testing();
