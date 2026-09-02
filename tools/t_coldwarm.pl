#!/usr/bin/env perl
# THE COLD-WARM NO-MATCH CLASS — a failed service search must never be cached as
# "this track is on no service".
#
# WHY THIS EXISTS. Diagnosed on the live server 2026-09-02: an update cleared every
# cache, the warm fired WARM_DELAY(60s) later, and the first resolve of the four
# created-for playlists pinned 8 tracks as unmatched. A forced re-match seventeen
# minutes later matched every one of them — 4 on Qobuz, 4 on Spotify — so nothing
# was missing from any catalogue and the matcher was in fleet sync throughout. The
# misses were WRITTEN WRONG by the cold pass and would have stood for a WEEK
# (TRACK_NOMATCH_TTL), because at LBF's boundary a service that FAILED to search is
# indistinguishable from one that searched and found nothing.
#
# Two defences, and this suite is the gate for both:
#   1. `_emptyResultIsError` — ZERO RAW RESULTS is an error signal. These searches
#      hit fuzzy catalogue indexes that answer with up to 20-200 rows; a genuine
#      absence still returns near-misses (the Avalon Emerson miss returned 2 and
#      matched 0). Empty means the search did not happen. Spotty makes this the ONLY
#      signal there is: its Pipeline swallows API errors into the SAME empty
#      arrayref a genuine zero-hit produces.
#   2. `streamingNotReady` + `_warmPlaylistsWhenReady` — don't resolve while a
#      service is still waking up. Installed is not ready.
#
# THE NEGATIVES CARRY THE WEIGHT HERE. Rule 1 must fire ONLY when nothing matched
# (a rule that discarded matches would be far worse than the bug), and must NOT
# apply to Bandcamp, whose catalogue is sparse enough that empty is a real answer.
# Rule 2 must not wait for a service that will never arrive, and must not hold the
# feeds or the genre ladder, which need no streaming API at all.
#
# Uses the REAL subs grabbed from the shipped sources, and the REAL constants read
# out of Plugin.pm — no retyped copies, so a change to either fails here rather than
# passing against a stale duplicate.
#
# Run from the repo root:  perl tools/t_coldwarm.pl
#   LBF_BROWSE=/path/Browse.pm LBF_PLUGIN=/path/Plugin.pm  → run against mutated
#   copies (how the anti-tests are driven).
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

my $BROWSE = $ENV{LBF_BROWSE} || 'ListenBrainzFreshReleases/Browse.pm';
my $PLUGIN = $ENV{LBF_PLUGIN} || 'ListenBrainzFreshReleases/Plugin.pm';
sub slurp { open(my $fh,'<:encoding(UTF-8)',$_[0]) or die "$_[0]: $!"; local $/; <$fh> }
my $SRC  = slurp($BROWSE);
my $PSRC = slurp($PLUGIN);

sub grab  { my ($n)=@_; $SRC  =~ /\nsub \Q$n\E \{.*?\n\}\n/s or die "no sub $n in $BROWSE"; return $& }
sub grabP { my ($n)=@_; $PSRC =~ /\nsub \Q$n\E \{.*?\n\}\n/s or die "no sub $n in $PLUGIN"; return $& }

my ($p,$f)=(0,0);
sub is { my($d,$g,$w)=@_; my $ok=((defined $g?$g:'') eq (defined $w?$w:'')); $ok?$p++:$f++;
    printf "%s %-58s got=%-22s want=%s\n",($ok?'ok  ':'FAIL'),$d,"'".(defined $g?$g:'')."'","'".(defined $w?$w:'')."'"; }
# NOT `ok($x =~ /re/, ...)` — a failed match returns the EMPTY LIST, so the call goes
# one argument short, the description slides into the condition slot and the assertion
# passes while testing nothing. Scalarised on the way in.
sub ok { my($d,$c)=@_; my $b = $c ? 1 : 0; $b?$p++:$f++; printf "%s %s\n",($b?'ok  ':'FAIL'),$d }

# ---------------------------------------------------------------------------
# Harness: the real subs, with only the LMS surface they touch stubbed.
# ---------------------------------------------------------------------------
{
    package X;
    use strict; use warnings;
    our @LOGGED;
    our @ADAPTERS;
    our $CLIENT = 'player';
    # $log->info/warn — recorded, so "did it say why" is assertable.
    our $log = bless {}, 'X::Log';
    sub Slim::Player::Client::clients { return $X::CLIENT ? ($X::CLIENT) : () }
    package X::Log;
    sub info { push @X::LOGGED, $_[1]; 1 }
    sub warn { push @X::LOGGED, $_[1]; 1 }
    sub error { push @X::LOGGED, $_[1]; 1 }
}
# _orderedAdapters is the input to streamingNotReady, so it is a fixture, not the
# real memoed one (which would need prefs and installed service plugins).
eval "package X;\n"
   . "our \$log; our \@ADAPTERS; our \$CLIENT; our \@LOGGED;\n"
   . "sub _orderedAdapters { return \@X::ADAPTERS }\n"
   . ($SRC =~ /\nuse constant MISS_RETRY_SCHEDULE => \[[^\]]*\];\n/s ? $& : die "no MISS_RETRY_SCHEDULE")
   . grab('_missRetryAt')
   . grab('_emptyResultIsError')
   . grab('streamingNotReady')
   . "1;" or die $@;

print "== 1. ZERO RAW RESULTS IS INCONCLUSIVE; ANY RESULT AT ALL IS A REAL ANSWER\n";
@X::LOGGED = ();
is('0 results  -> error signal',        X::_emptyResultIsError('Qobuz','q',0),   1);
is('1 result   -> the service answered', X::_emptyResultIsError('Qobuz','q',1),  0);
is('2 results  -> the Avalon shape',     X::_emptyResultIsError('Qobuz','q',2),  0);
is('200 (cap)  -> the service answered', X::_emptyResultIsError('Qobuz','q',200),0);
ok('the empty case says why, once', scalar(grep { /0 results/ && /inconclusive/ } @X::LOGGED) == 1);
ok('a non-empty search logs nothing extra', scalar(@X::LOGGED) == 1);

print "\n== 2. EVERY API-BACKED ADAPTER CONSULTS IT — album side AND track side\n";
for my $svc (qw(_searchQobuz _searchTidal _searchDeezer _searchSpotify
                _searchQobuzTrack _searchTidalTrack _searchDeezerTrack _searchSpotifyTrack)) {
    my $body = grab($svc);
    ok("$svc gates its settle on _emptyResultIsError",
       scalar($body =~ /_emptyResultIsError\(/));
}

print "\n== 3. THE NEGATIVE THAT MATTERS MOST: it only ever fires on a NO-MATCH\n";
# A rule that could discard MATCHES would be a worse bug than the one being fixed:
# every call site must be guarded by !@out, so a search that matched something is
# settled as a match no matter what the raw count says.
for my $svc (qw(_searchQobuz _searchTidal _searchDeezer _searchSpotify
                _searchQobuzTrack _searchTidalTrack _searchDeezerTrack _searchSpotifyTrack)) {
    my $body = grab($svc);
    my @calls = ($body =~ /(.{0,80}_emptyResultIsError\()/gs);
    ok("$svc guards it with !\@out", scalar(@calls) && !grep { $_ !~ /!\@out\s*&&/s } @calls);
}

print "\n== 3b. BANDCAMP IS DELIBERATELY OUT — sparse catalogue, empty is a real answer\n";
ok('_searchBandcamp does NOT gate on it',
   scalar(grab('_searchBandcamp') !~ /_emptyResultIsError/));
ok('_searchBandcampTrack does NOT gate on it',
   scalar(grab('_searchBandcampTrack') !~ /_emptyResultIsError/));

print "\n== 4. READINESS: which enabled services cannot answer a search yet\n";
my $ready    = { name => 'Qobuz',    ready => sub { 1 } };
my $notReady = { name => 'Spotify',  ready => sub { 0 } };
my $noProbe  = { name => 'Bandcamp' };                        # no handler concept
my $dies     = { name => 'Tidal',    ready => sub { die "boom\n" } };

@X::ADAPTERS = ($ready);
is('all ready -> nothing to wait for', join(',', X::streamingNotReady()), '');
@X::ADAPTERS = ($ready, $notReady);
is('one not ready -> named',           join(',', X::streamingNotReady()), 'Spotify');
@X::ADAPTERS = ($ready, $noProbe);
is('no probe (Bandcamp) counts ready', join(',', X::streamingNotReady()), '');
@X::ADAPTERS = ($notReady, $dies);
@X::LOGGED = ();
is('a probe that DIES is not waited on', join(',', X::streamingNotReady()), 'Spotify');
ok('...and it says so', scalar(grep { /readiness probe/ } @X::LOGGED));
@X::ADAPTERS = ($notReady);
{
    local $X::CLIENT = '';
    is('no player -> nothing to wait for (no resolve happens)',
       join(',', X::streamingNotReady()), '');
}

print "\n== 4b. SIGNED OUT IS READY, NOT \"NOT YET\" — the Spotty distinction\n";
# getAPIHandler answers undef both for an account that will never exist and for one
# whose helper is still starting. Waiting on the first would defer the warm to the
# cap on every single boot for a user who simply has no Spotify.
my $spotty = grab('_streamingAdapters');
ok('the Spotify probe consults hasCredentials, not just getAPIHandler',
   scalar($spotty =~ /ready\s*=>\s*sub\s*\{.*?hasCredentials.*?\}/s));
# Scoped to Bandcamp's OWN push block (up to its `} if`) — an unscoped search runs
# on into Tidal's entry and would pass whatever Bandcamp declared.
my ($bcEntry) = $spotty =~ /(name => 'Bandcamp'.*?\} if )/s;
ok('Bandcamp registers no ready probe',
   defined $bcEntry && scalar($bcEntry !~ /ready\s*=>/));

print "\n== 5. THE WARM WAITS FOR THE SERVICES — but never for ever\n";
# The constants are READ OUT OF Plugin.pm, never restated: a suite that pins its own
# copy of a cap cannot catch the cap changing.
my ($RETRY)    = $PSRC =~ /use constant WARM_SVC_RETRY\s*=>\s*(\d+)/;
my ($MAX_WAIT) = $PSRC =~ /use constant WARM_SVC_MAX_WAIT\s*=>\s*(\d+)/;
ok("WARM_SVC_RETRY is declared ($RETRY s)",        defined $RETRY && $RETRY > 0);
ok("WARM_SVC_MAX_WAIT is declared ($MAX_WAIT s)",  defined $MAX_WAIT && $MAX_WAIT > 0);
ok('the cap is reachable in whole retries',        defined $RETRY && $MAX_WAIT >= $RETRY);

{
    package P;
    use strict; use warnings;
    our @TIMERS;      # [$when, $cb]
    our @DBG;
    our @WARNED;
    our $WARMED = 0;
    our @NOT_READY;
    our $log = bless {}, 'P::Log';
    sub dbg { push @DBG, $_[0]; 1 }
    package P::Log;
    sub warn  { push @P::WARNED, $_[1]; 1 }
    sub error { push @P::WARNED, $_[1]; 1 }
    sub info  { 1 }
    package Slim::Utils::Timers;
    sub setTimer { my (undef,$when,$cb)=@_; push @P::TIMERS, [$when,$cb]; 1 }
    package Plugins::ListenBrainzFreshReleases::Browse;
    sub streamingNotReady { return @P::NOT_READY }
    sub warmCache { $P::WARMED++; 1 }
}
eval "package P;\n"
   . "our \$log; our \@TIMERS; our \@DBG; our \@WARNED; our \$WARMED; our \@NOT_READY;\n"
   . "use constant WARM_SVC_RETRY => $RETRY;\n"
   . "use constant WARM_SVC_MAX_WAIT => $MAX_WAIT;\n"
   . grabP('_warmPlaylistsWhenReady')
   . "1;" or die $@;

# Drains whatever is scheduled. Bounded, and tolerant of a mutated build that
# schedules nothing — a broken subject must produce FAILURES, never an abort that
# hides every assertion after it.
sub runTimers { my $n=0; while (my $t = shift @P::TIMERS) { eval { $t->[1]->(undef) }; last if ++$n > 100 } return $n }

@P::TIMERS=(); @P::DBG=(); @P::WARNED=(); $P::WARMED=0; @P::NOT_READY=();
P::_warmPlaylistsWhenReady(0);
is('everything ready -> resolves immediately', $P::WARMED, 1);
ok('...and schedules no retry', scalar(@P::TIMERS) == 0);

@P::TIMERS=(); @P::DBG=(); @P::WARNED=(); $P::WARMED=0; @P::NOT_READY=('Spotify');
P::_warmPlaylistsWhenReady(0);
is('service not ready -> does NOT resolve', $P::WARMED, 0);
ok('...schedules exactly one retry',        scalar(@P::TIMERS) == 1);
ok("...at WARM_SVC_RETRY ($RETRY s) out, not sooner",
   @P::TIMERS && abs(($P::TIMERS[0][0] - CORE::time()) - $RETRY) <= 2);
ok('...and names the service it is waiting on', scalar(grep { /Spotify/ } @P::DBG));

# The service comes up while we are waiting: the very next tick must resolve.
@P::NOT_READY = ();
runTimers();
is('service arrives -> the retry resolves', $P::WARMED, 1);

print "\n== 5b. A SERVICE THAT NEVER ARRIVES MUST NOT HOLD THE WARM FOR EVER\n";
@P::TIMERS=(); @P::DBG=(); @P::WARNED=(); $P::WARMED=0; @P::NOT_READY=('Spotify');
P::_warmPlaylistsWhenReady(0);
my $ticks = 1;
while (@P::TIMERS) { runTimers(); $ticks++; last if $ticks > 1000 }
is('it gives up and warms anyway',          $P::WARMED, 1);
ok('...within the cap, not for ever',       $ticks <= int($MAX_WAIT/$RETRY) + 2);
ok('...and warns rather than failing quietly', scalar(grep { /not ready/ } @P::WARNED));

@P::TIMERS=(); @P::WARNED=(); $P::WARMED=0; @P::NOT_READY=('Spotify');
P::_warmPlaylistsWhenReady($MAX_WAIT);
is('already at the cap -> resolves on this call', $P::WARMED, 1);
ok('...schedules nothing further',                scalar(@P::TIMERS) == 0);

print "\n== 6. THE WAIT IS SCOPED TO THE STREAMING STAGE ONLY\n";
# Holding the whole tick would also hold warmFeeds and the genre ladder — the two
# things a view needs to render, neither of which touches a streaming API. The gate
# belongs in the feed chain's callback, not in _warmTick's defer.
my $tick = grabP('_warmTick');
ok('_warmTick still defers only for the library scan',
   scalar($tick =~ /stillScanning/) && scalar($tick !~ /streamingNotReady/));
ok('the streaming wait hangs off the warmFeeds callback',
   scalar($tick =~ /warmFeeds\(sub \{\s*_warmPlaylistsWhenReady\(0\);/s));
ok('_warmTick no longer calls warmCache directly',
   scalar($tick !~ /Browse::warmCache/));
ok('warmCache is reached through the gate',
   scalar(grabP('_warmPlaylistsWhenReady') =~ /Browse::warmCache/));

print "\n== 7. THE RETRY IS A BUDGET, NOT A STATE — it must converge\n";
# The whole point of the rule in section 1 is that an inconclusive miss is
# re-searched. Without a bound that is a loop with no exit: a track genuinely on no
# service answers inconclusively for ever, re-searching on every expiry, and the
# resolved LIST cache stays short on the same clock so the whole playlist re-resolves
# with it. The schedule is what ends it.
my $sched = X->MISS_RETRY_SCHEDULE;
ok('the schedule is finite',            scalar(@$sched) > 0 && scalar(@$sched) <= 6);
my @delays = map { my $t = X::_missRetryAt($_); defined $t ? $t - CORE::time() : undef }
             (0 .. scalar(@$sched));
ok('every attempt inside the budget schedules a retry',
   scalar(@$sched) == scalar(grep { defined } @delays[0 .. $#$sched]));
ok('THE EXIT: the attempt past the budget schedules NOTHING',
   !defined $delays[scalar @$sched]);
ok('and it stays refused however many attempts are claimed',
   !defined X::_missRetryAt(scalar(@$sched) + 50) && !defined X::_missRetryAt(9999));
ok('each retry backs off further than the last (no hot loop)',
   scalar(@$sched) < 2 || !grep { $delays[$_] <= $delays[$_-1] } (1 .. $#$sched));
ok('the first step is an hour, so the FIRST retry behaves as it did before',
   abs($delays[0] - 3600) <= 2);

# Termination, driven the way the code drives it: read the count, write count+1.
my ($n, $tries) = (0, 0);
while (defined X::_missRetryAt($tries)) { $tries++; last if ++$n > 100 }
ok("the read/write cycle terminates (after $tries attempts)", $tries == scalar(@$sched));
ok('...well inside a day and a half of retrying',
   eval { my $t=0; $t += $_ for @$sched; $t <= 48*3600 });

print "\n== 7b. WHAT MAKES THE COUNT SURVIVE — and what must NOT enter the schedule\n";
my $ft = grab('_findPlayableTrack');
ok('the track miss is stored at the FULL no-match TTL, not a short one',
   scalar($ft =~ /\$ttl = !\$item \? TRACK_NOMATCH_TTL/));
# A short TTL would take the count with it when it expired, so the budget could never
# be spent — the loop would survive the fix that was meant to bound it.
ok('...and the entry carries its own retry_at instead',
   scalar($ft =~ /retry_at/) && scalar($ft =~ /_missRetryAt\(\$tries\)/));
ok('the count is read back only once the retry window has opened',
   scalar($ft =~ /if \(time\(\) < \$c->\{retry_at\}\).*?\$tries = \$c->\{tries\}/s));
ok('the next attempt is recorded as tries + 1',
   scalar($ft =~ /\$tries \+ 1/));
ok('ONLY an inconclusive miss enters the schedule (a confirmed one is durable at once)',
   scalar($ft =~ /if \(!\$item && \$inconclusive\) \{/));
ok('the caller is told RETRYABLE, not merely inconclusive',
   scalar($ft =~ /\$callback->\(\$item, \(!\$item && \$retryable\)/));
# That last one is what lets the LIST cache stop being short: while any track is
# retryable the playlist re-resolves on the short TTL, and the moment the budget is
# spent it gets its normal TTL back. Without it the list would loop for ever even
# though every track had settled.
my $fp = grab('_findPlayable');
ok('the album path is on the same budget',
   scalar($fp =~ /_missRetryAt\(\$tries\)/) && scalar($fp =~ /\$tries = \$c->\{tries\}/));
ok('...and its confirmed miss is still the plain durable TTL',
   scalar($fp =~ /\$ttl\s+= \@\$items \? STREAM_FOUND_TTL : STREAM_NOMATCH_TTL/));

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);
