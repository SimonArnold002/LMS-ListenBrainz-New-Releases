#!/usr/bin/env perl
#
# t_playlistresolve.pl — the Created-for-You playlists must resolve to completion,
# and must not cache an unfinished answer as if it were a finished one.
#
#   perl tools/t_playlistresolve.pl
#
# THE FIELD REPORT (2026-09-10): after a full install the four created-for
# playlists come up short and stay short; a manual "Refresh playlist matches"
# picks up the stragglers. On the released build (main, 0.9.149) the same cold
# pass always converged.
#
# WHAT THE main->dev DIFF ACTUALLY SHOWS. Three things people reach for first are
# present on main TOO, so they are latent bugs rather than the regression: the
# watchdog with no timed-out signal, PLAYLIST_PARTIAL_TTL == PLAYLIST_FOUND_TTL,
# and a warm that skips on a merely-present key. What main had that dev does not
# is an UNBOUNDED retry: an inconclusive track miss was cached for an hour and the
# list holding it expired on the same hour, so the next look re-searched every
# straggler, for ever, until they all matched. 0.9.195 replaced that with a bounded
# ladder (deliberately, on Simon's own call), and 0.9.207 stopped every build from
# wiping the store. Together those removed the brute force that was covering a cold
# pass that has never matched in one go.
#
# So the fix has to be at the two places that decide whether an unfinished resolve
# is an ANSWER, plus the one place that decides whether the ladder ever runs:
#
#   1. _resolveTracks must tell its caller when the WATCHDOG finished it, not the
#      work. Currently indistinguishable, so a truncated pass is cached for 14 days.
#   2. The playlist paths must get a timeout sized for a job nobody waits on. The
#      45s value dates from main, where opening a playlist BLOCKED the user; since
#      0.9.182 the open renders a building row and completes into cache, and a
#      fifth adapter (Spotify) joined every track search after main was cut.
#   3. The warm must re-resolve an INCOMPLETE list instead of skipping it, so the
#      1h/6h/24h ladder means hours rather than "the next three times you look".
#   4. The warm's resolve must hold the in-flight flag, so browsing during the warm
#      cannot double the fan-out that produces the misses in the first place.
#   5. lbf:pl:resolved: 8 -> 9, one-time, to drop what is already pinned.
#
# Sub bodies are lifted VERBATIM from Browse.pm (the tools/bench_walk.pl trick) and
# driven against stub cache/prefs/API/timers, so these assertions track shipped code
# rather than a paraphrase. No LMS needed.
#
# SECTION 5 IS THE OTHER HALF OF THE JOB and is why it is here at the start of the
# work rather than the end: every TTL, key version and retry constant this change
# must NOT touch is pinned. A fix that converges the playlists by quietly shortening
# something else fails this suite.
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
# ok() MUST NOT DIE and must not autovivify: a suite that dies mid-run reports
# fewer failures than it found, which reads as progress.
sub ok {
    my ($cond, $what) = @_;
    my $t = $cond ? 1 : 0;
    $t ? ($pass++, print "  PASS  $what\n") : ($fail++, push(@failed, $what), print "  FAIL  $what\n");
    return $t;
}
sub section { print "\n$_[0]\n" }

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}

# Brace-matched verbatim extraction of a named sub. Regex brace-scan, NOT
# substr()-per-character: the source is a CHARACTER string, so a per-character
# walk is quadratic and Browse.pm is half a megabyte.
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

my $src = slurp($BROWSE);

# A minimal DB::kver/kverNum built from the REAL KEY_VERSIONS in DB.pm — a
# hand-copied constant drifts, and a suite asserting a key it invented asserts
# nothing.
my %KEYV;
{
    my $db_src = slurp($ENV{LBF_DB}
        || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'DB.pm'));
    my ($body) = $db_src =~ /use constant KEY_VERSIONS => \{(.*?)\n\};/s
        or die "no KEY_VERSIONS in DB.pm\n";
    %KEYV = $body =~ /'([^']+)'\s*=>\s*(\d+)/g;
    die "KEY_VERSIONS parsed empty\n" unless keys %KEYV;
    no strict 'refs';
    *{'Plugins::ListenBrainzFreshReleases::DB::kver'}    = sub { $_[0] . ($KEYV{$_[0]} // 0) . ':' };
    *{'Plugins::ListenBrainzFreshReleases::DB::kverNum'} = sub { $KEYV{$_[0]} // 0 };
    $INC{'Plugins/ListenBrainzFreshReleases/DB.pm'} = __FILE__;
}

# ---------------------------------------------------------------- stub world --
{
    package T::Cache;
    sub new { bless { d => {}, ttl => {}, sets => [] }, shift }
    sub get { my ($s, $k) = @_; return exists $s->{d}{$k} ? $s->{d}{$k} : undef }   # no autoviv
    sub set {
        my ($s, $k, $v, $t) = @_;
        $s->{d}{$k} = $v; $s->{ttl}{$k} = $t;
        push @{ $s->{sets} }, [ $k, $t ];
        return 1;
    }
    sub remove { my ($s, $k) = @_; delete $s->{d}{$k}; delete $s->{ttl}{$k} }
    sub reset_sets { $_[0]{sets} = [] }
}
{
    package T::Prefs;
    sub new { bless { d => { username => 'CrystalGipsy', people_follow => 0, prefer_library => 0 } }, shift }
    sub get { my ($s, $k) = @_; return exists $s->{d}{$k} ? $s->{d}{$k} : undef }
    sub set { my ($s, $k, $v) = @_; $s->{d}{$k} = $v }
}
{
    package T::Log;
    sub new { bless {}, shift }
    sub warn { 1 } sub info { 1 } sub error { 1 } sub is_info { 0 }
}
# Timers with a HANDLE ON THE SCHEDULE. The watchdog is the thing under test, so
# a stub that swallows it (t_trending_empty's, correctly, for its own subject)
# would make every assertion here vacuous.
{
    package Slim::Utils::Timers;
    our (%PENDING, $SEQ, $T0);
    $SEQ = 0; $T0 = time();
    sub setTimer {
        my ($obj, $when, $cb, @args) = @_;
        my $id = ++$SEQ;
        $PENDING{$id} = { when => $when, cb => $cb, args => \@args, obj => $obj };
        return $id;
    }
    sub killSpecific { my ($id) = @_; delete $PENDING{ $id // '' }; return 1 }
    sub reset_all { %PENDING = (); $T0 = time(); return }
    # Delays currently on the schedule, rounded — lets a test ASSERT the watchdog's
    # size instead of only its existence.
    sub delays { return sort { $a <=> $b } map { int($_->{when} - $T0 + 0.5) } values %PENDING }
    # Fire every timer whose scheduled delay is within $tol of $d. Targeted rather
    # than fire-everything: _buildingStart also schedules (BUILDING_MAX 180s) and
    # firing that would test the belt, not the braces.
    sub fire_delay {
        my ($d, $tol) = @_;
        $tol //= 3;
        my $n = 0;
        for my $id (sort { $a <=> $b } keys %PENDING) {
            my $e = $PENDING{$id} or next;
            next unless abs(int($e->{when} - $T0 + 0.5) - $d) <= $tol;
            delete $PENDING{$id};
            $n++;
            $e->{cb}->($e->{obj}, @{ $e->{args} });
        }
        return $n;
    }
}

my $CACHE = T::Cache->new;
my $PREFS = T::Prefs->new;

# The playlist listing and its tracks — the knobs each scenario turns.
our @PL_LIST;
our %PL_TRACKS;
{
    package Plugins::ListenBrainzFreshReleases::API;
    sub getCreatedForPlaylists {
        my ($class, %a) = @_;
        $a{onDone}->([ @main::PL_LIST ]);
    }
    sub getPlaylistTracks {
        my ($class, $mbid, $lastMod, $onDone, $onError) = @_;
        $onDone->($main::PL_TRACKS{$mbid} || []);
    }
    sub getRecordingMetadata { my ($class, $m, $cb) = @_; $cb->({}) }
}
{
    package Slim::Player::Client;
    sub clients { return ('player1') }
}

# ------------------------------------------------------- the code under test --
{
    package T;
    use strict;
    use warnings;

    our $cache = $CACHE;
    our $prefs = $PREFS;
    our $log   = T::Log->new;

    # Constants the lifted bodies close over — VERBATIM values from Browse.pm.
    use constant LIBRARY_TTL               => 1 * 86400;
    use constant PLAYLIST_FOUND_TTL        => 14 * 86400;
    use constant PLAYLIST_PARTIAL_TTL      => 14 * 86400;
    use constant PLAYLIST_INCONCLUSIVE_TTL => 1 * 3600;
    use constant PLAYLIST_CONCURRENCY      => 6;
    use constant PLAYLIST_TIMEOUT          => 45;
    use constant PLAYLIST_RESOLVE_TIMEOUT  => 150;
    use constant FANOUT_DEADLINE           => 30;
    use constant FOLLOWER_FANOUT           => 6;
    use constant BUILDING_MAX              => 180;

    # Collaborators that are not what is being tested.
    our @ADAPTERS = ( { name => 'Qobuz' }, { name => 'Tidal' } );
    sub _orderedAdapters { return @ADAPTERS }
    sub _dbg   { 1 }
    sub _stage { 1 }
    sub _stashPlaylistSummary { 1 }
    sub _warmGenres { 1 }
    sub _holdLastfm { return sub { 1 } }
    sub _noteBrowse { 1 }
    sub cstring { return $_[1] }
    sub _checkAgainItem { return { name => 'CHECKAGAIN' } }
    sub _buildingRow { return { items => [ { name => 'BUILDING' } ], cachetime => 0 } }
    sub _playlistResult { my ($c, $p) = @_; return { items => $p->{items} || [] } }
    sub _cachedSvcUsable { 1 }
    sub _enrichYears { my ($tracks, $onDone) = @_; $_->{year} //= '' for @$tracks; $onDone->() }
    sub _warmFollow   { my ($c, $f, $cb) = @_; $cb->() if ref $cb eq 'CODE' }
    sub _followResolvedKey { return 'lbf:follow:resolved:5:qobuz,tidal' }
    sub _followSig    { return 'sig-' . scalar @{ $_[0] } }
    sub _followResult { my ($c, $p) = @_; return { items => $p->{items} || [] } }
    sub _warmTrending { my ($c, $f, $cb) = @_; $cb->() if ref $cb eq 'CODE' }

    # THE RESOLVER'S ONE COLLABORATOR, and the knob for every scenario below.
    # %ANSWER maps a track title to 'match' / 'miss' / 'inconclusive' / 'hang'.
    # 'hang' never calls back — that is what leaves the watchdog to finish the pass.
    our %ANSWER;
    our @FORCE_SEEN;
    sub _findPlayableTrack {
        my ($client, $cb, $artist, $title, $album, $recMbid, $force, $libMode) = @_;
        push @FORCE_SEEN, ($force ? 1 : 0);
        my $a = $ANSWER{$title // ''} // 'match';
        return if $a eq 'hang';
        return $cb->({ name => $title, _svc => 'Qobuz' }) if $a eq 'match';
        return $cb->({ name => $title, _svc => 'Library' }) if $a eq 'library';
        return $cb->(undef, 1) if $a eq 'inconclusive';
        return $cb->(undef, 0);
    }
}

# Lift the real bodies into T. Each string eval is its own lexical scope, so the
# package globals the lifted bodies close over have to be re-declared inside it.
my $DECL = 'package T; use strict; use warnings; no warnings "redefine";'
         . ' our ($cache, $prefs, $log);';
for my $name (qw(_trackLayerTag _plResolvedKey _playlistTtl _resolveTracks
                 resolvePlaylist warmCache _resolveFollow _fanFollowers)) {
    my $body = grab($src, $name);
    my $ok = eval "$DECL $body 1;";
    die "lifting $name failed: $@" unless $ok;
}
# THE REGISTRY IS LIFTED AS ONE UNIT. %BUILDING / %BUILDING_TIMER are file-scoped
# lexicals shared by the three subs in Browse.pm; lifting them separately would
# give each its own private hash, and the guard would read as working while
# guarding nothing.
{
    my $reg = join "\n", map { grab($src, $_) } qw(_buildingStart _buildingEnd _isBuilding);
    # A reset defined INSIDE the same eval, because the two hashes are lexicals of
    # this scope. Harness-only: without it a scenario that leaves a resolve in flight
    # leaks its flag into the next one, which then early-returns and reads as a
    # failure of the code rather than of the suite.
    $reg .= "\nsub _buildingReset { %BUILDING = (); %BUILDING_TIMER = (); return }\n";
    my $ok = eval "$DECL my (%BUILDING, %BUILDING_TIMER); $reg 1;";
    die "lifting building registry failed: $@" unless $ok;
}

sub reset_world {
    $CACHE->{d} = {}; $CACHE->{ttl} = {}; $CACHE->reset_sets;
    Slim::Utils::Timers::reset_all();
    @T::FORCE_SEEN = ();
    %T::ANSWER = ();
    T::_buildingReset();
    @main::PL_LIST = (); %main::PL_TRACKS = ();
}
sub tracks { return [ map { { title => $_, artist => 'A', album => 'B', recording_mbid => '' } } @_ ] }

print "t_playlistresolve.pl — Browse.pm under test: $BROWSE\n";

# ===========================================================================
section('1. _resolveTracks must distinguish "the work finished" from "the clock did"');
# ===========================================================================
{
    reset_world();
    %T::ANSWER = ( t1 => 'match', t2 => 'match', t3 => 'hang', t4 => 'hang' );
    my @got;
    T::_resolveTracks('c', tracks(qw(t1 t2 t3 t4)), sub { @got = @_ });
    ok(!@got, '1.0 a pass with two tracks still in flight has not called back');
    my $fired = Slim::Utils::Timers::fire_delay(45);
    ok($fired == 1, '1.1 the watchdog is on the schedule and fires');
    ok(scalar(@got) >= 1, '1.2 the watchdog finishes the pass');
    my ($items, $inconclusive, $unmatched, $owned, $timedOut) = @got;
    ok(ref $items eq 'ARRAY' && @$items == 2, '1.3 the matches it did get are kept (no data loss)');
    ok(defined $timedOut && $timedOut, '1.4 the callback is TOLD the watchdog finished it');
}
{
    reset_world();
    %T::ANSWER = ( t1 => 'match', t2 => 'miss' );
    my @got;
    T::_resolveTracks('c', tracks(qw(t1 t2)), sub { @got = @_ });
    my $timedOut = $got[4];
    # CONTROL: without this, a fix that hard-codes "timed out" everywhere passes 1.4.
    ok(!$timedOut, '1.5 CONTROL a pass that completed normally is NOT flagged timed-out');
}
{
    reset_world();
    %T::ANSWER = ( t1 => 'hang' );
    T::_resolveTracks('c', tracks(qw(t1)), sub { });
    my @d = Slim::Utils::Timers::delays();
    ok(scalar(grep { $_ == 45 } @d) == 1, '1.6 CONTROL default watchdog is still PLAYLIST_TIMEOUT (45s) for other callers');
}
{
    reset_world();
    %T::ANSWER = ( t1 => 'hang' );
    T::_resolveTracks('c', tracks(qw(t1)), sub { }, undef, 0, timeout => 300);
    my @d = Slim::Utils::Timers::delays();
    ok(scalar(grep { $_ == 300 } @d) == 1, '1.7 an explicit $opt{timeout} is honoured (the warm needs a longer one)');
}

# ===========================================================================
section('2. TTL policy — an unfinished pass is not a 14-day answer');
# ===========================================================================
{
    # _playlistTtl is the one place the decision lands. Drive it directly.
    my $partial = [ { _svc => 'Qobuz' } ];
    ok(T::_playlistTtl($partial, 5, 0, 1) == T::PLAYLIST_INCONCLUSIVE_TTL,
       '2.1 a WATCHDOG-truncated resolve is cached short, not for 14 days');
    ok(T::_playlistTtl($partial, 5, 0, 0) == T::PLAYLIST_PARTIAL_TTL,
       '2.2 CONTROL a resolve that COMPLETED short still gets the partial TTL (not a blanket downgrade)');
    ok(T::_playlistTtl([ { _svc => 'Qobuz' }, { _svc => 'Tidal' } ], 2, 0, 0) == T::PLAYLIST_FOUND_TTL,
       '2.3 CONTROL a complete resolve still gets the full 14-day TTL');
    ok(T::_playlistTtl([ { _svc => 'Library' } ], 1, 0, 0) == T::LIBRARY_TTL,
       '2.4 CONTROL a library-backed resolve still gets the 1-day TTL');
    ok(T::_playlistTtl($partial, 5, 2, 0) == T::PLAYLIST_INCONCLUSIVE_TTL,
       '2.5 CONTROL an inconclusive resolve still gets the 1-hour TTL');
}

# ===========================================================================
section('3. The warm must revisit an INCOMPLETE list, or the retry ladder never runs');
# ===========================================================================
{
    reset_world();
    @main::PL_LIST = ( { mbid => 'pl-a', title => 'Weekly Jams', last_modified => 'M1' } );
    %main::PL_TRACKS = ( 'pl-a' => tracks(qw(t1 t2 t3)) );
    my $rkey = T::_plResolvedKey('pl-a', 'M1', 'qobuz,tidal');
    # A partial from an earlier cold pass, exactly as the warm would have written it.
    $CACHE->set($rkey, { items => [ { _svc => 'Qobuz' } ], matched => 1, total => 3 }, 14 * 86400);
    $CACHE->reset_sets;
    %T::ANSWER = ( t1 => 'match', t2 => 'match', t3 => 'match' );
    T::warmCache('c');
    my $after = $CACHE->get($rkey);
    ok(ref $after eq 'HASH' && ($after->{matched} // 0) == 3,
       '3.1 the warm RE-RESOLVES a cached list whose matched < total');
    ok(scalar(@T::FORCE_SEEN) && !grep({ $_ } @T::FORCE_SEEN),
       '3.2 the re-resolve does NOT force — the per-track cache is honoured, so it is cheap');
}
{
    reset_world();
    @main::PL_LIST = ( { mbid => 'pl-b', title => 'Weekly Jams', last_modified => 'M1' } );
    %main::PL_TRACKS = ( 'pl-b' => tracks(qw(t1 t2)) );
    my $rkey = T::_plResolvedKey('pl-b', 'M1', 'qobuz,tidal');
    $CACHE->set($rkey, { items => [ { _svc => 'Qobuz' }, { _svc => 'Tidal' } ], matched => 2, total => 2 }, 14 * 86400);
    $CACHE->reset_sets;
    T::warmCache('c');
    # CONTROL: without this, "always re-resolve" passes 3.1 while doubling the
    # daily fan-out against every streaming service.
    ok(scalar(@T::FORCE_SEEN) == 0,
       '3.3 CONTROL a COMPLETE cached list is still skipped — no new service traffic');
}
{
    reset_world();
    @main::PL_LIST = ( { mbid => 'pl-c', title => 'Weekly Jams', last_modified => 'M1' } );
    %main::PL_TRACKS = ( 'pl-c' => tracks(qw(t1)) );
    my $rkey = T::_plResolvedKey('pl-c', 'M1', 'qobuz,tidal');
    $CACHE->set($rkey, { items => [ { _svc => 'Qobuz' } ], matched => 1, total => 1 }, 14 * 86400);
    $CACHE->reset_sets;
    T::warmCache('c', force => 1);
    ok(scalar(@T::FORCE_SEEN) && (grep { $_ } @T::FORCE_SEEN),
       '3.4 CONTROL the manual forced refresh still re-resolves and still forces');
}

# ===========================================================================
section('4. The warm must hold the in-flight flag, so a browse cannot double the fan-out');
# ===========================================================================
{
    reset_world();
    @main::PL_LIST = ( { mbid => 'pl-d', title => 'Weekly Jams', last_modified => 'M1' } );
    %main::PL_TRACKS = ( 'pl-d' => tracks(qw(t1 t2)) );
    %T::ANSWER = ( t1 => 'hang', t2 => 'hang' );
    T::warmCache('c');
    ok(T::_isBuilding('playlist:pl-d'), '4.1 the flag is HELD while the warm resolves that playlist');

    # A user opening the same playlist mid-warm must get the building row, not a
    # second 50-track fan-out at the same services.
    #
    # 4.2 PASSES TODAY, AND FOR THE WRONG REASON — it is 4.3 that discriminates.
    # With the warm holding no flag the open finds no cache entry, starts its OWN
    # resolve, takes its OWN flag and renders the building row from the cold-start
    # branch. Same row on screen, two fan-outs at the services. Read the pair, never
    # 4.2 alone.
    @T::FORCE_SEEN = ();
    my $res;
    T::resolvePlaylist('c', sub { $res = shift }, {}, { mbid => 'pl-d', last_modified => 'M1', title => 'Weekly Jams' });
    my $isBuildingRow = (ref $res eq 'HASH' && ref $res->{items} eq 'ARRAY'
                         && ($res->{items}[0]{name} // '') eq 'BUILDING') ? 1 : 0;
    ok($isBuildingRow, '4.2 an open DURING the warm renders the building row');
    ok(scalar(@T::FORCE_SEEN) == 0, '4.3 ...and starts no second resolve of the same tracks');

    # Fire the WARM's watchdog, which now sits at PLAYLIST_RESOLVE_TIMEOUT, not at
    # the 45s default. Deliberately not fire-everything: BUILDING_MAX(180s) is also
    # on the schedule and firing THAT would prove only that the backstop works.
    ok(scalar(grep { $_ == T::PLAYLIST_RESOLVE_TIMEOUT } Slim::Utils::Timers::delays()) == 1,
       '4.4 the warm resolve is on the long watchdog, not the 45s default');
    Slim::Utils::Timers::fire_delay(T::PLAYLIST_RESOLVE_TIMEOUT);
    ok(!T::_isBuilding('playlist:pl-d'), '4.5 the flag is RELEASED by the NORMAL path, not by the expiry backstop');
    ok(T::PLAYLIST_RESOLVE_TIMEOUT < T::BUILDING_MAX,
       '4.6 ...which is only true while PLAYLIST_RESOLVE_TIMEOUT stays under BUILDING_MAX');
}

# ===========================================================================
section('5. Nothing else in the cache may move (the constraint, pinned)');
# ===========================================================================
{
    ok(($KEYV{'lbf:pl:resolved:'} // 0) == 9, '5.1 lbf:pl:resolved: bumped to 9 to drop the pinned partials');
    ok(($KEYV{'lbf:track:'} // 0) == 10, '5.2 lbf:track: UNCHANGED at 10 — the expensive layer must not be orphaned');
    ok(($KEYV{'lbf:stream:'} // 0) == 29, '5.3 lbf:stream: unchanged at 29');
    ok(($KEYV{'lbf:follow:resolved:'} // 0) == 5, '5.4 lbf:follow:resolved: unchanged at 5');
    ok(($KEYV{'lbf:trending:resolved:'} // 0) == 8, '5.5 lbf:trending:resolved: unchanged at 8');
    ok(($KEYV{'lbf:trending:albums:'} // 0) == 7, '5.6 lbf:trending:albums: unchanged at 7');

    my ($sched) = $src =~ /use constant MISS_RETRY_SCHEDULE => \[([^\]]*)\]/;
    ok(defined $sched && $sched =~ /1\s*\*\s*3600.*6\s*\*\s*3600.*24\s*\*\s*3600/s,
       '5.7 MISS_RETRY_SCHEDULE still [1h, 6h, 24h] — the ladder is not re-unbounded');

    my %want = (
        TRACK_FOUND_TTL          => '30 * 86400',
        TRACK_NOMATCH_TTL        => '7 * 86400',
        LIBRARY_TTL              => '1 * 86400',
        PLAYLIST_FOUND_TTL       => '14 * 86400',
        PLAYLIST_PARTIAL_TTL     => '14 * 86400',
        PLAYLIST_INCONCLUSIVE_TTL=> '1 * 3600',
        PLAYLIST_CONCURRENCY     => '6',
        PLAYLIST_TIMEOUT         => '45',
        PLAYLIST_RESOLVE_TIMEOUT => '150',
        STREAM_SVC_TIMEOUT       => '8',
    );
    for my $k (sort keys %want) {
        my ($v) = $src =~ /use constant \Q$k\E\s*=>\s*([^;]+);/;
        $v = defined $v ? $v : '';
        $v =~ s/\s+/ /g; $v =~ s/^\s+|\s+$//g;
        ok($v eq $want{$k}, "5.8 $k unchanged ($want{$k})");
    }

    # The build wipe stays OFF. Converging the playlists by reinstating it would
    # undo a deliberate 0.9.207 decision and clear far more than this fix needs.
    my $plugin = slurp(File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Plugin.pm'));
    my ($reset) = $plugin =~ /use constant RESET_CACHE_ON_BUILD\s*=>\s*(\d+)/;
    ok(defined $reset && $reset == 0, '5.9 RESET_CACHE_ON_BUILD still 0 — the build wipe is NOT reinstated');
}


# ===========================================================================
section('6. _fanFollowers — a deadline-truncated fan-out must say so');
# ===========================================================================
{
    reset_world();
    my @got;
    T::_fanFollowers([qw(u1 u2 u3)], sub { my ($u, $cb) = @_; $cb->([{ r => $u }]) }, sub { @got = @_ });
    ok(ref $got[0] eq 'HASH' && scalar(keys %{ $got[0] }) == 3, '6.1 a complete fan-out returns every follower');
    ok(!$got[1], '6.2 CONTROL a complete fan-out is NOT flagged truncated');
}
{
    # Two of three never answer; the FANOUT_DEADLINE watchdog ends the pass.
    reset_world();
    my @got;
    T::_fanFollowers([qw(u1 u2 u3)],
        sub { my ($u, $cb) = @_; $cb->([{ r => $u }]) if $u eq 'u1' },
        sub { @got = @_ });
    ok(!@got, '6.3 the pass has not called back while followers are outstanding');
    Slim::Utils::Timers::fire_delay(T::FANOUT_DEADLINE);
    ok(scalar(@got) >= 1, '6.4 the deadline ends the pass');
    ok(ref $got[0] eq 'HASH' && scalar(keys %{ $got[0] }) == 1, '6.5 what WAS collected is kept');
    ok(defined $got[1] && $got[1], '6.6 the caller is TOLD the deadline ended it, not the work');
}

# ===========================================================================
section('7. The follow feed caches on the same rule as the playlists');
# ===========================================================================
{
    reset_world();
    %T::ANSWER = ( t1 => 'match', t2 => 'hang', t3 => 'hang' );
    T::_resolveFollow('c', { tracks => tracks(qw(t1 t2 t3)) }, undef, 0, undef, sub { });
    Slim::Utils::Timers::fire_delay(T::PLAYLIST_RESOLVE_TIMEOUT);
    my ($set) = grep { $_->[0] =~ /^lbf:follow:resolved:/ } @{ $CACHE->{sets} };
    ok(defined $set, '7.1 the truncated follow resolve wrote its cache entry');
    ok(defined $set && $set->[1] == T::PLAYLIST_INCONCLUSIVE_TTL,
       '7.2 a WATCHDOG-truncated follow resolve is cached short, not for 14 days');
}
{
    reset_world();
    %T::ANSWER = ( t1 => 'match', t2 => 'miss' );
    T::_resolveFollow('c', { tracks => tracks(qw(t1 t2)) }, undef, 0, undef, sub { });
    my ($set) = grep { $_->[0] =~ /^lbf:follow:resolved:/ } @{ $CACHE->{sets} };
    ok(defined $set && $set->[1] == T::PLAYLIST_PARTIAL_TTL,
       '7.3 CONTROL a follow resolve that COMPLETED short still gets the partial TTL');
}
{
    reset_world();
    %T::ANSWER = ( t1 => 'hang' );
    T::_resolveFollow('c', { tracks => tracks(qw(t1)) }, undef, 0, undef, sub { });
    ok(scalar(grep { $_ == T::PLAYLIST_RESOLVE_TIMEOUT } Slim::Utils::Timers::delays()) == 1,
       '7.4 the follow resolve is on the long watchdog too — nothing waits on it either');
}

# ===========================================================================
section('8. WIRING — the two follower aggregates consume the signals');
# ===========================================================================
# These build through a fan-out, a metadata fill and a streaming gate. Driving them
# end to end here would assert the stubs rather than the code, so this section checks
# the THREADING only, and says so. Both signals are asserted behaviourally above:
# the timed-out flag in section 1, the fan-out cut in section 6.
{
    my $trend = grab($src, '_resolveTrending');
    ok(scalar($trend =~ /\$inconclusive, \$unmatched, \$owned, \$timedOut\)/) ? 1 : 0,
       '8.1 the trending TRACK resolve unpacks the timed-out flag');
    ok(scalar($trend =~ /\$timedOut[^\n]*PLAYLIST_INCONCLUSIVE_TTL/) ? 1 : 0,
       '8.2 ...and a truncated trending resolve is cached short');
    ok(scalar($trend =~ /timeout => PLAYLIST_RESOLVE_TIMEOUT/) ? 1 : 0,
       '8.3 ...and it runs on the long watchdog (it renders a building row too)');
    ok(scalar($trend =~ /my \(\$perFollower, \$fanCut\)/) ? 1 : 0,
       '8.4 the trending TRACK build unpacks the fan-out truncation');
    ok(scalar($trend =~ /\$sawListens && !\$fanCut/) ? 1 : 0,
       '8.5 ...and will not record "no candidates" as a fact from a cut-short fan-out');

    my $alb = grab($src, '_buildAlbumsData');
    ok(scalar($alb =~ /my \(\$perFollower, \$fanCut\)/) ? 1 : 0,
       '8.6 the trending ALBUMS build unpacks the fan-out truncation');
    ok(scalar($alb =~ /\$timedOut \|\| \$fanCut/) ? 1 : 0,
       '8.7 ...and settles short when EITHER the gate or the fan-out was cut short');
}

printf("\n%d passed, %d failed\n", $pass, $fail);
if ($fail) { print "\nfailed:\n"; print "  - $_\n" for @failed }
exit($fail ? 1 : 0);
