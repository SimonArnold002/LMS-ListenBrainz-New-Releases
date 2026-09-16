#!/usr/bin/env perl
#
# t_spotifybackoff.pl — while SPOTIFY is refusing searches, the warm must narrow and
# wait, and a refused search must not spend a retry attempt.
#
#   perl tools/t_spotifybackoff.pl
#
# THE FIELD EVIDENCE (plex, 2026-09-15): one day's log.txt carries 20
# `Plugins::Spotty::API::error429` lines (Retry-After 2-7s) and 191 Spotty 502s, all on
# api.spotify.com/v1/search. Spotify's limit is per APP over a rolling 30s window, and
# Spotty ships ONE client id that every install shares unless the user sets their own —
# so a wide warm burns a quota it does not own alone, and during the lockout Spotty
# refuses EVERY call server-wide, the user's own browsing included.
#
# WHY THIS IS NOT JUST THE SIBLING'S FIX COPIED. Pitchfork Reviews solved the same
# problem in its 0.9.36/0.9.37, but it has no retry budget. LBF does: an inconclusive
# miss gets MISS_RETRY_SCHEDULE attempts and then becomes a durable no-match
# (TRACK_NOMATCH_TTL / STREAM_NOMATCH_TTL). A refusal is a search that was NEVER SENT,
# so counting it retires a track the service actually carries — and for a
# Spotify-ONLY user every attempt in a storm is a refusal, so that is the normal case,
# not an edge. Hence the free passes, and hence the CAP on them: Simon's standing call
# is that a miss must converge rather than retry for ever.
#
# Sub bodies are lifted VERBATIM from Browse.pm and driven against stub
# cache/timers/Spotty, so these assertions track shipped code rather than a paraphrase.
# No LMS and no Spotty install needed.
#
# ANTI-TESTED (each mutation must fail ONLY its own checks — run with LBF_BROWSE
# pointing at the mutated copy):
#   the stamp removed from the adapters      -> section 2 + the budget sections
#   the paced width ignored                  -> section 4
#   the gap removed                          -> section 4
#   free passes uncapped                     -> section 3 (convergence)
#   free passes removed entirely             -> section 3
#   the detail-warm pause removed            -> section 5
#   follow/trending $warm read after detach  -> section 4b (view assertion / source order)
#   follow/trending paced => $warm dropped   -> section 4b (warm assertion / source)
#
# Exit 0 = all good. Exit 1 = at least one assertion failed.
use strict;
use warnings;
use File::Spec;

my $ROOT   = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
# Overridable so the suite can be ANTI-TESTED against a mutated copy.
my $BROWSE = $ENV{LBF_BROWSE} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');

my ($pass, $fail) = (0, 0);
my @failed;
# ok() MUST NOT DIE and must not autovivify: a suite that dies mid-run reports fewer
# failures than it found, which reads as progress.
sub ok {
    my ($cond, $what) = @_;
    my $t = $cond ? 1 : 0;
    $t ? ($pass++, print "ok    $what\n") : ($fail++, push(@failed, $what), print "not ok  $what\n");
    return $t;
}
sub is { my ($got, $want, $what) = @_; my $g = defined $got ? $got : '(undef)';
         ok((defined $got && $got eq $want), "$what (got $g)") }
sub section { print "\n$_[0]\n" }

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}

# Brace-matched verbatim extraction. Regex brace-scan, NOT substr()-per-character:
# the source is a CHARACTER string and Browse.pm is half a megabyte, so a
# per-character walk is quadratic and reads as a hang.
sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name\n";
    my $start = $-[0];
    my $depth = 1;
    my $end   = length($src);
    while ($src =~ /([{}])/g) {
        $1 eq '{' ? $depth++ : $depth--;
        next if $depth;
        $end = pos($src);
        last;
    }
    pos($src) = undef;
    return substr($src, $start, $end - $start) . "\n";
}

# A constant's REAL value, lifted from the source — a hand-copied number drifts, and a
# suite asserting a value it invented asserts nothing.
sub constant_of {
    my ($src, $name) = @_;
    my ($v) = $src =~ /use constant \Q$name\E\s*=>\s*([^;]+);/;
    die "no constant $name\n" unless defined $v;
    $v =~ s{#.*$}{};
    return eval $v;
}

my $src = slurp($BROWSE);

my $WINDOW = constant_of($src, 'SPOTIFY_BACKOFF_WINDOW');
my $GAP    = constant_of($src, 'PACED_TRACK_GAP');
my $PASSES = constant_of($src, 'SPOTIFY_FREE_PASSES');

# The real values are read at RUNTIME, so they have to be installed at runtime too: a
# `use constant X => $lifted` inside a package block is resolved at COMPILE time, when
# the lifted variable is still undef — which defines the constant as undef and makes
# every comparison against it quietly false.
sub install_constants {
    my ($pkg, %kv) = @_;
    eval "package $pkg; use constant { " . join(', ', map { "$_ => $kv{$_}" } sort keys %kv) . " }; 1"
        or die $@;
    return;
}

# The LMS tree is absent on a dev Mac, so the stubs must exist BEFORE anything real is
# loaded — SingleFlight.pm `use`s Slim::Utils::Log at its own BEGIN.
BEGIN {
    $INC{'Slim/Utils/Log.pm'}    = 1;
    $INC{'Slim/Utils/Timers.pm'} = 1;
    $INC{'Slim/Utils/Prefs.pm'}  = 1;
    package Slim::Utils::Log;
    sub import { no strict 'refs'; *{ caller() . '::logger' } = sub { bless {}, 'T::Log' } }
    package Slim::Utils::Prefs;
    sub import { no strict 'refs'; *{ caller() . '::preferences' } = sub { bless {}, 'T::Prefs' } }
    package T::Log;
    sub info { 1 } sub warn { 1 } sub error { 1 } sub debug { 1 }
    sub is_info { 0 } sub is_debug { 0 }
    package T::Prefs;
    sub get { undef } sub set { 1 }
}

# The real SingleFlight, as the neighbouring suites do — _findPlayable requires it.
require File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'SingleFlight.pm');
$INC{'Plugins/ListenBrainzFreshReleases/SingleFlight.pm'} = 1;

# --- a controllable clock + timer queue, shared by every package below -------
# time() is overridden GLOBALLY rather than per package: a `sub time` in a package
# does NOT override the builtin (the call still resolves to CORE::time, with a warning),
# so a per-package stub silently leaves the lifted body on the real clock — which reads
# as a passing test of an unmeasured thing.
our $NOW = 1_000_000;
BEGIN { *CORE::GLOBAL::time = sub { $main::NOW } }
our @TIMERS;
{
    package Slim::Utils::Timers;
    sub setTimer { my (undef, $when, $cb) = @_; push @main::TIMERS, { at => $when, cb => $cb }; return $cb }
    sub killSpecific { my ($t) = @_; @main::TIMERS = grep { $_->{cb} ne $t } @main::TIMERS; return }
}
# AFTER the requires above, deliberately: SingleFlight pulls in the REAL Time::HiRes,
# and a `sub time` compiled into that package earlier is simply overwritten when the
# module loads — leaving the paced gap measured against the wall clock, where a 2s
# timer never comes due inside a suite and the assertion fails for the wrong reason.
{
    no warnings 'redefine';
    *Time::HiRes::time = sub { $main::NOW };
}
# Fire every timer due at or before the (advanced) clock.
sub advance {
    my ($secs) = @_;
    $NOW += $secs;
    for my $t (sort { $a->{at} <=> $b->{at} } splice @TIMERS) {
        $t->{at} <= $NOW ? $t->{cb}->() : push @TIMERS, $t;
    }
    return;
}

# =============================================================================
section("1. the refusal clock");
# =============================================================================
{
    package C;
    our $log = bless {}, 'T::Log';
    our $SPOTIFY_REFUSED_AT = 0;
}
install_constants('C', SPOTIFY_BACKOFF_WINDOW => $WINDOW);
eval 'package C; no strict "vars"; ' . grab($src, '_spottyRateLimited')
                                     . grab($src, '_noteSpotifyRefusal')
                                     . grab($src, '_spotifyBackingOff'); die $@ if $@;

ok(!C::_spotifyBackingOff(), 'not backing off before anything has refused');
# Spotty absent entirely: the probe must answer 0, not die — LBF must run for the
# four users who have no Spotify at all.
ok(!C::_spottyRateLimited(), 'no Spotty installed reads as "not rate-limited", and does not die');
{
    no warnings 'once';
    *Plugins::Spotty::API::hasError429 = sub { $main::RATE_LIMITED };
}
our $RATE_LIMITED = 1;
ok(C::_spottyRateLimited(), q{Spotty's own flag is the signal for "refusing right now"});
$RATE_LIMITED = 0;
ok(!C::_spottyRateLimited(), 'a cleared flag reads as not refusing');

C::_noteSpotifyRefusal();
ok(C::_spotifyBackingOff(), 'a refusal starts the back-off window');
$NOW += $WINDOW - 1;
ok(C::_spotifyBackingOff(), 'still backing off one second inside the window');
$NOW += 2;
ok(!C::_spotifyBackingOff(), 'the window expires on its own — nothing has to clear it');
# OUR OWN CLOCK, not Spotty's flag: the flag is cleared by the next SUCCESSFUL
# response, which at a low Spotify priority may be many albums away.
$RATE_LIMITED = 0;
C::_noteSpotifyRefusal();
ok(C::_spotifyBackingOff(), 'the window survives the flag clearing under us');

# =============================================================================
section("2. the adapters stamp a refusal — and ONLY a refusal");
# =============================================================================
{
    package S;
    our $log = bless {}, 'T::Log';
    our ($RESULTS, $STAMPED);
    our $SPOTIFY_REFUSED_AT = 0;
    sub _spottyRateLimited   { $main::RATE_LIMITED ? 1 : 0 }
    sub _noteSpotifyRefusal  { $STAMPED++; $SPOTIFY_REFUSED_AT = $main::NOW; 1 }
    # The pre-existing rule: ANY empty list is already inconclusive. Stubbed TRUE so
    # section 2 cannot pass merely because empty-is-an-error fires — the discriminator
    # is the STAMP, which only a refusal may set.
    sub _emptyResultIsError  { 1 }
    sub _trackMatches        { lc($_[2] // '') eq lc($_[0] // '') && lc($_[3] // '') eq lc($_[1] // '') }
    sub _svcYear             { undef }
    package Plugins::Spotty::Plugin;
    sub getAPIHandler { return bless {}, 'T::SpottyAPI' }
    package Plugins::Spotty::OPML;
    sub trackList { my (undef, $tracks) = @_; return [ map { { name => $_->{name}, url => 'spotify://track:1' } } @$tracks ] }
    package T::SpottyAPI;
    sub search { my (undef, $cb) = @_; $cb->($S::RESULTS) }
    package T::Log;
    sub info { 1 } sub warn { 1 } sub error { 1 } sub is_info { 0 } sub is_debug { 0 }
}
install_constants('S', SPOTIFY_BACKOFF_WINDOW => $WINDOW);
eval 'package S; no strict "vars"; ' . grab($src, '_searchSpotifyTrack'); die $@ if $@;

sub track_search {
    my ($results, $limited) = @_;
    local $RATE_LIMITED = $limited;
    $S::RESULTS = $results;
    $S::STAMPED = 0;
    my $got = 'NOT CALLED';
    $S::TAG = undef;
    S::_searchSpotifyTrack('player', 'q', 'artist', 'title', undef, sub { $got = $_[0]; $S::TAG = $_[1] }, 'Title');
    return ($got, $S::STAMPED);
}

my ($ans, $stamped) = track_search([], 1);
ok(!defined $ans, 'a refused search answers INCONCLUSIVE (undef), never an empty verdict');
is($stamped, 1, 'a refused search stamps the back-off clock');
is($S::TAG // 'undef', 'refused', 'and tags ITS OWN answer as refused — the resolver keys the free pass on this');

($ans, $stamped) = track_search([], 0);
ok(!defined $ans, 'a genuinely empty answer is still inconclusive (the pre-existing rule)');
is($stamped, 0, 'an empty answer with the flag CLEAR does not stamp — the stamp means refused');
ok(!defined $S::TAG, 'and carries no refused tag');

($ans, $stamped) = track_search([ { name => 'title', artists => [ { name => 'artist' } ] } ], 1);
ok(ref $ans eq 'ARRAY' && @$ans == 1, 'a list WITH results is an answer whatever the flag says');
is($stamped, 0, 'a real answer never stamps, even while Spotty is rate-limiting');

# =============================================================================
section("3. a refused search does not spend a retry attempt — and still converges");
# =============================================================================
{
    package B;
    our (@searches, @stored);
    our $BACKING_OFF = 0;
    our $cache = bless {}, 'T::Cache';
    our $log   = bless {}, 'T::Log';
    use constant STREAM_SVC_TIMEOUT  => 8;
    use constant STREAM_FOUND_TTL    => 7 * 86400;
    use constant STREAM_NOMATCH_TTL  => 86400;
    sub _spotifyBackingOff { $BACKING_OFF }
    sub _norm   { lc($_[0] // '') }
    sub _cid    { $_[0] }
    sub _streamId { $_[2] }
    sub _streamKey { $_[0] }
    sub _bcMatchItems { () }
    # ONE adapter that always answers inconclusively — the Spotify-ONLY user, which is
    # the case the free passes exist for (with a second service there is something else
    # to answer, and the miss is not inconclusive at all).
    sub _orderedAdapters { ( { name => 'Spotify', run => sub { push @searches, $_[5] } } ) }
    sub _streamResult { $_[1] }
    sub _rebuildStreamItems { $_[0] }
    sub _cacheStream { my ($k, $items, $ttl, $extra) = @_; push @stored, { ttl => $ttl, %{ $extra || {} } };
                       $cache->set($k, { items => $items, %{ $extra || {} } }) }
    sub _attachFavUrl {}
    sub _llRelType { '' }
    sub _artistAltNames { $_[2]->([]) }   # the alias pass has nothing to add here
    package T::Cache;
    our %D;
    sub get { $D{$_[1]} }
    sub set { $D{$_[1]} = $_[2] }
}
# The schedule must exist BEFORE the bodies that name it are compiled — the lifted
# code says `MISS_RETRY_SCHEDULE->[-1]`, which is a compile-time bareword under strict.
# Taken from the source rather than retyped, so a retune cannot leave this suite
# asserting a ladder the plugin no longer has.
{
    my ($sched) = $src =~ /use constant MISS_RETRY_SCHEDULE => \[([^\]]*)\]/
        or die "no MISS_RETRY_SCHEDULE\n";
    eval "package B; use constant MISS_RETRY_SCHEDULE => [$sched];"; die $@ if $@;
}
install_constants('B', SPOTIFY_FREE_PASSES => $PASSES);
eval 'package B; no strict "vars"; ' . grab($src, '_missRetryAt')
                                     . grab($src, '_findPlayable'); die $@ if $@;
my $RUNGS = scalar @{ B::MISS_RETRY_SCHEDULE() };

# Drive one resolve to an inconclusive miss and return what was stored. $refused says
# whether the adapter tags its answer as a REFUSAL (the search was never sent) or merely
# could not answer (a timeout, an error) — the free pass must follow the tag, not the
# back-off window, which is why the window is held ON throughout this section.
sub one_miss {
    my ($refused) = @_;
    @B::searches = ();
    B::_findPlayable('player', sub { }, 'Artist', 'Album', 'id');
    $_->(undef, $refused ? ('refused') : ()) for @B::searches;
    return $B::stored[-1];
}

%T::Cache::D = (); @B::stored = ();
$B::BACKING_OFF = 1;
my $e = one_miss(1);
is($e->{tries}, 0, 'a refused miss does not increment the attempt count');
is($e->{free},  1, 'it records a free pass instead');
ok($e->{retry_at} && $e->{retry_at} > $NOW, 'and it stays retryable');
is($e->{ttl}, B::STREAM_NOMATCH_TTL(),
   'stored at the FULL no-match TTL, so the count survives to be spent (not a short TTL)');

# Every later attempt must find its window open, or the budget can never be reached.
for my $n (2 .. $PASSES) {
    $NOW = $e->{retry_at} + 1;
    $e = one_miss(1);
    is($e->{free}, $n, "free pass $n of $PASSES is taken while Spotify keeps refusing");
    is($e->{tries}, 0, "attempt count still untouched after $n refusals");
}

# THE CAP IS THE HALF THAT MATTERS: without it a permanently rate-limited account
# re-searches for ever, which is the loop MISS_RETRY_SCHEDULE was written to bound.
$NOW = $e->{retry_at} + 1;
$e = one_miss(1);
is($e->{tries}, 1, 'past the cap, a refusal spends a real attempt again');
my $spent = 0;
for (1 .. $RUNGS + 2) {
    last unless $e->{retry_at};
    $NOW = $e->{retry_at} + 1;
    $e = one_miss(1);
    $spent++;
}
ok(!$e->{retry_at}, "the budget is spent in the end — the miss converges ($spent further attempts)");

# The control: with nothing refusing, the budget behaves exactly as it did before.
%T::Cache::D = (); @B::stored = ();
$B::BACKING_OFF = 0;
$e = one_miss(0);
is($e->{tries}, 1, 'an ordinary inconclusive miss still spends an attempt');
ok(!$e->{free}, 'and records no free pass');

# THE WINDOW IS NOT THE SIGNAL. A search that really went out inside the 30s back-off
# window (Spotify answered, or another service timed out) is an ordinary attempt. Keying
# the pass on the window gave it away to every miss in a storm's wake.
%T::Cache::D = (); @B::stored = ();
$B::BACKING_OFF = 1;
$e = one_miss(0);
is($e->{tries}, 1, 'inside the back-off window, an UNREFUSED miss still spends an attempt');
ok(!$e->{free}, 'and takes no free pass — the pass follows the refusal, not the window');
$B::BACKING_OFF = 0;
%T::Cache::D = (); @B::stored = ();
$e = one_miss(1);
is($e->{free}, 1, 'a refusal earns the pass even after the window has closed');

# =============================================================================
section("3b. the TRACK path keys its free pass on the refusal too");
# =============================================================================
{
    package K;
    our (@searches, $BACKING_OFF);
    our $cache = bless {}, 'T::KCache';
    our $log   = bless {}, 'T::Log';
    our $prefs = bless {}, 'T::Prefs';
    use constant STREAM_SVC_TIMEOUT => 8;
    use constant TRACK_FOUND_TTL    => 30 * 86400;
    use constant TRACK_NOMATCH_TTL  => 7 * 86400;
    use constant LIBRARY_TTL        => 86400;
    sub _spotifyBackingOff { $BACKING_OFF }
    sub _norm          { lc($_[0] // '') }
    sub _punctNorm     { lc($_[0] // '') }
    sub _trackKeyName  { join '|', map { lc($_ // '') } @_[0, 1] }
    sub _cachedSvcUsable { 1 }
    sub _findLocalTrack  { undef }
    sub _orderedAdapters { ( { name => 'Spotify', runTrack => sub { push @searches, $_[5] } } ) }
    package Plugins::ListenBrainzFreshReleases::DB;
    sub kver { $_[0] }
    package T::KCache;
    our %D;
    sub get { $D{$_[1]} }
    sub set { $D{$_[1]} = $_[2] }
}
{
    my ($sched) = $src =~ /use constant MISS_RETRY_SCHEDULE => \[([^\]]*)\]/;
    eval "package K; use constant MISS_RETRY_SCHEDULE => [$sched];"; die $@ if $@;
}
install_constants('K', SPOTIFY_FREE_PASSES => $PASSES);
eval 'package K; no strict "vars"; ' . grab($src, '_missRetryAt')
                                     . grab($src, '_findPlayableTrack'); die $@ if $@;

sub one_track_miss {
    my ($refused) = @_;
    @K::searches = ();
    K::_findPlayableTrack('player', sub { }, 'Artist', 'Title', undef, undef, 0, 'never');
    ok(scalar @K::searches, 'the track search went out') or return {};
    $_->(undef, $refused ? ('refused') : ()) for @K::searches;
    my ($entry) = values %T::KCache::D;
    return $entry || {};
}

%T::KCache::D = ();
$K::BACKING_OFF = 1;
my $t = one_track_miss(1);
is($t->{tries} // 'undef', 0, 'a refused track miss does not spend an attempt');
is($t->{free}  // 'undef', 1, 'it records a free pass');
%T::KCache::D = ();
$t = one_track_miss(0);
is($t->{tries} // 'undef', 1, 'inside the window, an UNREFUSED track miss spends an attempt');
ok(!$t->{free}, 'and takes no free pass');
$K::BACKING_OFF = 0;

# =============================================================================
section("4. the WARM narrows and waits; a view never does");
# =============================================================================
{
    package R;
    our (@inflight, @launched, @liveAt, %CACHED, $BACKING_OFF);
    our $log = bless {}, 'T::Log';
    use constant PLAYLIST_CONCURRENCY => 6;
    use constant PLAYLIST_TIMEOUT     => 45;
    sub time { $main::NOW }
    sub _spotifyBackingOff { $BACKING_OFF }
    sub _dbg { 1 }
    # Never answers by itself: the suite settles each resolve by hand, so "how many are
    # in flight at once" is observable rather than inferred from timing.
    # A CACHED title answers synchronously, from inside the pump, exactly as the real
    # resolver's cache read does — that is the case the re-entrancy guard exists for.
    sub _findPlayableTrack {
        my ($client, $cb, $artist, $title) = @_;
        push @launched, $cb;
        if ($CACHED{$title}) { $cb->(undef, 1, 0); return; }
        push @liveAt, $main::NOW;
        push @inflight, $cb;
        return;
    }
}
install_constants('R', PACED_TRACK_GAP => $GAP);
eval 'package R; no strict "vars"; ' . grab($src, '_resolveTracks'); die $@ if $@;

sub run_resolve {
    my (%opt) = @_;
    @R::launched = (); @R::inflight = (); @R::liveAt = (); @TIMERS = ();
    $R::BACKING_OFF = delete $opt{backing_off} ? 1 : 0;
    my $cached = delete $opt{cached} || 0;
    %R::CACHED = map { ("t$_" => 1) } 1 .. $cached;
    my @tracks = map { { artist => 'a', title => "t$_" } } 1 .. ($opt{total} ? delete $opt{total} : 10);
    my $done = 0;
    R::_resolveTracks('player', \@tracks, sub { $done = 1 }, undef, 0, %opt);
    return \$done;
}

run_resolve(paced => 1, backing_off => 1);
is(scalar @R::launched, 1, 'a paced warm launches ONE resolve at a time while Spotify refuses');
# Settle it: the next one must not go out until the gap has elapsed.
(shift @R::inflight)->(undef, 1, 0);
is(scalar @R::launched, 1, 'the next resolve does not follow immediately');
ok(scalar @TIMERS, 'it is queued on a timer instead');
advance($GAP - 1) if $GAP > 1;
is(scalar @R::launched, 1, "nothing launches before PACED_TRACK_GAP (${GAP}s) has passed");
advance(2);
is(scalar @R::launched, 2, 'the next resolve goes out once the gap has elapsed');

run_resolve(paced => 1, backing_off => 0);
is(scalar @R::launched, R::PLAYLIST_CONCURRENCY(),
   'the same warm runs at FULL width the moment Spotify stops refusing — a healthy run pays nothing');

run_resolve(backing_off => 1);
is(scalar @R::launched, R::PLAYLIST_CONCURRENCY(),
   'a VIEW never narrows, even while Spotify refuses — somebody is waiting on it');

# A refusal arriving mid-pass must take effect at the next slot, not the next pass:
# the width is read fresh on every pump (the rule _coverLimit already follows).
run_resolve(paced => 1, backing_off => 0);
$R::BACKING_OFF = 1;
my $before = scalar @R::launched;
(shift @R::inflight)->(undef, 1, 0);
is(scalar @R::launched, $before, 'a refusal mid-pass stops the next launch immediately');

# Paced wakeups only — the pass's own watchdog sits PLAYLIST_TIMEOUT out.
sub gap_timers { scalar grep { $_->{at} <= $NOW + $GAP } @TIMERS }

# CACHED TRACKS MUST NOT ARM THE GAP. They answer from inside the pump; before the
# re-entrancy guard each one armed its own timer, and those strays later launched live
# searches straight after one another.
run_resolve(paced => 1, backing_off => 1, cached => 4);
is(scalar @R::launched, 5, 'cached tracks run straight through, then ONE live search goes out');
is(scalar @R::inflight, 1, 'only that live search is in flight');
is(gap_timers(), 0, 'no cached answer arms a paced wakeup');
(shift @R::inflight)->(undef, 1, 0);
is(gap_timers(), 1, 'the live completion arms exactly one');

# The field case: a run of cached tracks, then live ones, each live search answering
# 0.3s after it goes out. Every live launch must be at least the gap after the LAST live
# completion — measured, not inferred from the timer count.
{
    run_resolve(paced => 1, backing_off => 1, cached => 40, total => 50);
    my (@doneAt, $steps);
    while (@R::inflight && ++$steps < 2000) {
        advance(0.3);
        push @doneAt, $NOW;
        (shift @R::inflight)->(undef, 1, 0);
        my $n = @R::liveAt;
        advance(0.1) while @R::liveAt == $n && gap_timers() && ++$steps < 2000;
    }
    is(scalar @R::liveAt, 10, 'all ten live searches went out');
    my $short = 0;
    for my $i (1 .. $#R::liveAt) {
        $short++ if $R::liveAt[$i] - $doneAt[$i - 1] < $GAP - 1e-6;
    }
    is($short, 0, "no live search followed the previous one inside ${GAP}s");
}

# SEVERAL IN FLIGHT WHEN THE BACK-OFF BEGINS: each completion re-arms the ONE wakeup, so
# nothing launches until the gap after the LAST of them.
run_resolve(paced => 1, backing_off => 0);
$R::BACKING_OFF = 1;
my $wide = scalar @R::launched;
my $last = pop @R::inflight;
(shift @R::inflight)->(undef, 1, 0) for 1 .. 3;
advance(1);
(shift @R::inflight)->(undef, 1, 0) while @R::inflight;
advance(0.9);
$last->(undef, 1, 0);
is(gap_timers(), 1, 'six completions leave ONE pending wakeup, not six');
advance($GAP - 0.5);
is(scalar @R::launched, $wide, 'nothing launches inside the gap after the LAST completion');
advance(1);
is(scalar @R::launched, $wide + 1, 'the next search goes out once that gap has passed');

# =============================================================================
section("4b. the follow-feed and trending WARMS are paced too; their views are not");
# =============================================================================
# The 1.0.2 review: only the playlist warm passed `paced => 1`, so the follow-feed and
# trending warms (the widest resolve in the plugin) kept pushing at full width through a
# refusal. Both subs DETACH $callback (set it undef) before the resolve on the view's cold
# path too, so "is this the warm?" must be read at ENTRY — a test of $callback at the
# resolve call would pace the view as well. _resolveFollow is CALLED both ways below;
# _resolveTrending sits behind a follower fan-out, so its order is checked in source.
{
    package F;
    our (%OPT, $log);
    $log = bless {}, 'T::Log';
    our $cache = bless {}, 'F::Cache';
    sub F::Cache::get { undef } sub F::Cache::set { 1 }
    use constant PLAYLIST_RESOLVE_TIMEOUT => 150;
    sub _followResolvedKey { 'k' }  sub _followSig { 's' }
    sub _isBuilding { 0 }  sub _buildingStart { 1 }  sub _buildingEnd { 1 }
    sub _buildingRow { { items => [] } }  sub _dbg { 1 }  sub cstring { '' }
    sub _enrichYears { $_[1]->() }
    sub _playlistTtl { 60 }  sub _followResult { { items => [] } }
    sub _resolveTracks { my (undef, undef, $done, undef, undef, %o) = @_; %OPT = %o; $done->([], 0, [], 0, 0) }
}
eval 'package F; no strict "vars"; ' . grab($src, '_resolveFollow'); die $@ if $@;

my $store = { tracks => [ { artist => 'a', title => 't' } ] };
%F::OPT = ();
F::_resolveFollow('player', $store, undef, 1, undef, sub {});
ok($F::OPT{paced}, 'the follow-feed WARM (no render callback) resolves paced');
%F::OPT = ();
my $rendered = 0;
F::_resolveFollow('player', $store, sub { $rendered++ }, 1, undef);
ok(exists $F::OPT{timeout} && !$F::OPT{paced},
   'a follow-feed VIEW resolves unpaced, even though its callback is detached first');
is($rendered, 1, 'the view got its building row (the detach happened)');

{
    my $b = grab($src, '_resolveTrending');
    my $warmAt   = index($b, 'my $warm = !$callback;');
    my $detachAt = index($b, '$callback = undef;');
    ok($warmAt >= 0 && $detachAt >= 0 && $warmAt < $detachAt,
       '_resolveTrending reads $warm BEFORE its cold build detaches $callback');
    ok(scalar($b =~ /_resolveTracks\(.*?paced\s*=>\s*\$warm\s*\)/s),
       '_resolveTrending passes paced => $warm to its resolve');
}

# =============================================================================
section("4c. the trending-ALBUMS streaming gate — the third pump");
# =============================================================================
# THE 1.0.3 REVIEW. Two rounds fixed the track side and believed the album side was
# `_detailPriorityBusy` (section 5). It is not: that is the DetailWarm QUEUE's pause hook
# and nothing else consults it. `_buildAlbumsData`'s streaming gate is a THIRD pump — it
# calls _findPlayable directly, never _resolveTracks, so it never saw `paced`, and it is a
# WRITER of $SPOTIFY_REFUSED_AT (through _searchSpotify) that never read it. 60 pooled
# albums per range, two ranges per warm, five wide, straight back into a quota it had
# just closed.
#
# DRIVEN, not source-grepped, and that is the point: the gate's completion re-enters the
# pump, and _findPlayable answers SYNCHRONOUSLY on a cache hit. A width-only fix passes
# any source check and still rebuilds the 1.0.1 defect (a timer armed per cached album).
# Only the timing assertions below separate the two.
{
    package G;
    our $log = bless {}, 'T::Log';
    our $cache = bless { d => {}, ttl => {} }, 'G::Cache';
    sub G::Cache::get { my ($s, $k) = @_; $s->{d}{$k} }
    sub G::Cache::set { my ($s, $k, $v, $t) = @_; $s->{d}{$k} = $v; $s->{ttl}{$k} = $t; 1 }
    our $prefs = bless {}, 'G::Prefs';
    sub G::Prefs::get { my (undef, $k) = @_; return $k eq 'username' ? 'CrystalGipsy' : undef }

    our $BACKING_OFF = 0;
    sub _spotifyBackingOff { $BACKING_OFF ? 1 : 0 }

    # The gate's launches, and its pending completions when SYNC is off.
    our (@launched, @inflight);
    # The FIRST $CACHED searches answer synchronously (a play-via cache hit, which
    # _findPlayable really does answer in-loop); the rest are live and queue up.
    our $CACHED = 0;
    sub _findPlayable {
        my ($client, $cb, $artist, $title) = @_;
        push @launched, { at => $main::NOW, what => "$artist - $title" };
        my $answer = sub { $cb->({ items => [ { name => "$artist - $title" } ] }) };
        scalar(@launched) <= $CACHED ? $answer->() : push @inflight, $answer;
        return;
    }

    our @ADAPTERS = ( { name => 'Spotify' }, { name => 'Qobuz' } );
    sub _orderedAdapters { @ADAPTERS }
    sub _blockedSet { { mbids => {}, names => {} } }
    sub _trendBlocked { 0 }
    sub _dbg { 1 } sub _stage { 1 } sub cstring { $_[1] }
    our %BUILDING;
    sub _buildingStart { $BUILDING{ $_[0] // '' } = 1; 1 }
    sub _buildingEnd   { delete $BUILDING{ $_[0] // '' }; return }
    sub _isBuilding    { $BUILDING{ $_[0] // '' } ? 1 : 0 }
    sub _streamLayerTag { 'v1' }
}
# The follower fan-out that feeds the gate — answered synchronously so the gate is
# reached in one turn, exactly as t_trending_empty.pl drives the same sub.
our @G_ROWS;
{
    package Plugins::ListenBrainzFreshReleases::API;
    sub getFollowing   { my (undef, %a) = @_; $a{onDone}->([ 'follower1' ]) }
    sub getLatestListenTs { my (undef, undef, $cb) = @_; $cb->($main::NOW) }
    sub getUserTopReleaseGroups { my (undef, undef, %a) = @_; $a{onDone}->([ @main::G_ROWS ]) }
    sub getReleaseGroupMetadata { my (undef, undef, $cb) = @_; $cb->({}) }
    sub getReleaseGroupByName   { my (undef, undef, undef, $cb) = @_; $cb->(undef) }
}
install_constants('G',
    TREND_ALBUMS_MONTH_TTL => 7 * 86400, TREND_ALBUMS_YEAR_TTL => 30 * 86400,
    PLAYLIST_INCONCLUSIVE_TTL => 3600,   PLAYLIST_TIMEOUT => constant_of($src, 'PLAYLIST_TIMEOUT'),
    TRENDING_MAX => constant_of($src, 'TRENDING_MAX'),
    FOLLOWER_MAX => 250, FOLLOWER_FANOUT => 6, FANOUT_DEADLINE => 30, FOLLOWER_STALE_DAYS => 183,
    PACED_TRACK_GAP => $GAP);
for my $name (qw(_albumsDataKey _buildAlbumsData _aggregateAlbums
                 _fanFollowers _activeFollowers)) {
    my $body = grab($src, $name);
    eval "package G; use Time::HiRes (); our (\$cache, \$prefs, \$log); $body 1;"
        or die "eval $name: $@";
}

# $onPending is the warm/view discriminator, and unlike _resolveTrending's $callback it is
# never reassigned — so `run_gate` passing it or not is the whole difference.
sub run_gate {
    my (%o) = @_;
    @G::launched = (); @G::inflight = (); @TIMERS = ();
    $G::cache->{d} = {}; %G::BUILDING = ();
    $G::BACKING_OFF = $o{backing_off} ? 1 : 0;
    $G::CACHED      = $o{cached} || 0;
    @G_ROWS = map { { release_group_mbid => sprintf('mb-%02d', $_), title => "Album $_",
                      artist => "Artist $_", artist_mbid => '', listen_count => 100 - $_ } }
              1 .. ($o{albums} || 20);
    G::_buildAlbumsData('player', 'this_month', sub { }, 1, ($o{view} ? sub { } : ()));
    return;
}

# A HEALTHY WARM PAYS NOTHING — the same rule the track pump follows.
run_gate(backing_off => 0, albums => 20);
is(scalar @G::launched, 5, 'a warm gate that is not backing off launches at full width (5)');
is(gap_timers(), 0, 'and arms no paced wakeup');

# BACKING OFF: ONE AT A TIME, with the gap between LIVE launches.
run_gate(backing_off => 1, albums => 20);
is(scalar @G::launched, 1, 'a backing-off WARM gate launches ONE album search, not five');
(shift @G::inflight)->();
is(scalar @G::launched, 1, 'the completion does not launch the next one immediately');
is(gap_timers(), 1, 'it arms exactly ONE paced wakeup');
advance($GAP - 0.5);
is(scalar @G::launched, 1, 'nothing launches inside the gap');
advance(1);
is(scalar @G::launched, 2, 'the next album search goes out once the gap has passed');

# THE RE-ENTRANCY ARM — what a width-only fix gets wrong, and it takes a MIXED pass to
# see it. An ALL-cached gate cannot: each stray wakeup re-arms the one before it and
# $finish kills the last, so the strays are absorbed and every count looks right (the
# 1.0.1 round recorded the same absorption on the track side). Four cached albums THEN a
# live one leaves the stray stranded next to a search that is genuinely in flight.
run_gate(backing_off => 1, albums => 20, cached => 4);
is(scalar @G::launched, 5, 'cached albums run straight through, then ONE live search goes out');
is(gap_timers(), 0, 'a CACHED completion arms nothing — it answers from inside the pump');
advance($GAP + 1);
is(scalar @G::launched, 5,
   'and no stray wakeup launches a second search beside the one in flight (the 1.0.1 defect)');

# A VIEW IS NEVER PACED. Somebody is waiting on it, and every other service still answers.
run_gate(backing_off => 1, albums => 20, view => 1);
is(scalar @G::launched, 5, 'a trending-albums VIEW keeps full width while Spotify refuses');
is(gap_timers(), 0, 'and arms no paced wakeup');

# THE WATCHDOG STILL BOUNDS IT — accepted 1.0.3: a gate held narrow for its whole run
# cannot finish under PLAYLIST_TIMEOUT, so it files SHORT and rebuilds in an hour.
{
    my $to = constant_of($src, 'PLAYLIST_TIMEOUT');
    run_gate(backing_off => 1, albums => 60);
    my $key = G::_albumsDataKey('this_month', 'CrystalGipsy');
    # Arm a real paced wakeup, then fire the WATCHDOG while that wakeup is still pending
    # — which advance() can never do, because it fires the nearer timer first. Calling the
    # watchdog directly is the only way to observe what $finish leaves behind.
    (shift @G::inflight)->();
    is(gap_timers(), 1, 'a live completion arms a wakeup that is still pending at the cut');
    my ($wd) = grep { $_->{at} == $NOW + $to } @TIMERS;
    ok($wd, "the gate's watchdog is queued at ${to}s");
    $wd->{cb}->() if $wd;
    is($G::cache->{ttl}{$key}, 3600,
       "a gate that never finishes inside ${to}s files at the 1h inconclusive TTL");
    is(gap_timers(), 0, 'and $finish cancels the pending wakeup rather than stranding it');
}

{
    my $b = grab($src, '_buildAlbumsData');
    my ($warmAt) = $b =~ /(my \$warm = ref \$onPending eq 'CODE' \? 0 : 1;)/ ? $-[0] : -1;
    ok($warmAt >= 0, '_buildAlbumsData reads $warm from $onPending at entry');
    ok(scalar($b =~ /while \(\$active < \(\(\$warm && _spotifyBackingOff\(\)\) \? 1 : 5\)/),
       'the gate reads the width FRESH on every iteration, off $warm');
    ok(scalar($b =~ /return if \$finished \|\| \$pumping;/),
       'the gate carries the re-entrancy guard, not just the width');
}

# =============================================================================
section("5. the album prewarm queue holds while Spotify refuses");
# =============================================================================
{
    package D;
    our ($detailMainReady, $lastfmWarmPending, $lastfmRequestBusy, $BACKING_OFF) = (1, 0, 0, 0);
    sub _lastfmPriorityBusy { 0 }
    sub _spotifyBackingOff  { $BACKING_OFF }
}
eval 'package D; no strict "vars"; ' . grab($src, '_detailPriorityBusy'); die $@ if $@;

ok(!D::_detailPriorityBusy(), 'the detail warm runs normally when nothing is refusing');
$D::BACKING_OFF = 1;
ok(D::_detailPriorityBusy(), 'it pauses while Spotify is refusing — its jobs are album searches too');
$D::BACKING_OFF = 0;
ok(!D::_detailPriorityBusy(), 'and resumes on its own when the window expires');

print "\n$pass passed, $fail failed\n";
print "  FAILED: $_\n" for @failed;
exit($fail ? 1 : 0);
