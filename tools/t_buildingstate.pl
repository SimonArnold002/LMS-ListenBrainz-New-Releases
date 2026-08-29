#!/usr/bin/env perl
#
# t_buildingstate.pl — the in-flight guard and the "still being built" row.
#
# WHAT THIS PINS.
#
#   Until 0.9.180 there was NO guard on the People-You-Follow builds. A warm build
#   and a user tap ran two complete fan-outs against each other — doubling the
#   ListenBrainz traffic that is already the binding constraint (39 of 39 stats
#   requests came back 429 in the 0.9.177 incident) and doubling the streaming
#   searches behind it. And a cold open had nothing to render, so Material span its
#   three dots for the ~50s the build took.
#
#   THE TWO FAILURE MODES THIS GUARDS, and they pull in opposite directions:
#
#   (a) A SECOND caller must not start a second build. Easy to get right.
#   (b) The flag must ALWAYS be released, on every exit — success, empty, error,
#       cache hit, no username. A leaked flag is strictly worse than no guard at
#       all: the view renders "still being built" for ever, with nothing running,
#       and no cache expiry can clear it because the registry is in-process and
#       deliberately not a cache.
#
#   (b) is why `_buildAlbumsData` wraps $onDone instead of clearing by hand: it has
#   a dozen scattered early returns across four nested fan-out callbacks.
#
#   OWNERSHIP is the third property. A caller that FINDS the flag set must not
#   clear it on its way out — doing so would let a third caller start the
#   duplicate build the guard exists to prevent. Section 4 is about that alone.
#
# ANTI-TEST: point LBF_BROWSE at a mutated copy.
#   - drop the `_buildingEnd if $owns` from either wrapper   -> sections 2/3 red
#   - clear the flag unconditionally (ignore $owns)          -> section 4 red
#   - return [] instead of undef on the already-building path-> section 5 red
#   - delete the `_isBuilding` check in _resolveTrending     -> section 1 red

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

my $ROOT   = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));
my $BROWSE = $ENV{LBF_BROWSE} || "$ROOT/ListenBrainzFreshReleases/Browse.pm";

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $msg) = @_;
    die "t_buildingstate: assertion called with no message — a bare m// or grep has\n"
      . "shifted the arguments. Wrap the condition in scalar().\n"
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

my $src = do { open my $fh, '<', $BROWSE or die "$BROWSE: $!"; local $/; <$fh> };

# ---------------------------------------------------------------------------
# The registry itself is lifted and RUN, not pattern-matched — it is four
# one-line subs whose whole value is their behaviour under a specific call
# sequence, and a source check would assert nothing about that.
# ---------------------------------------------------------------------------
# Anchored on the LINE, not on a brace: the bodies contain `$BUILDING{...}`, so a
# `[^}]*` lift stops at the hash subscript and captures half a sub.
my ($reg) = $src =~ /(my %BUILDING;[\s\S]*?^sub _isBuilding[^\n]*$)/m;
# The registry references BUILDING_MAX, which is declared above the lift point. Take
# the REAL value from the source rather than inventing one, so the suite cannot pass
# against a ceiling the plugin does not actually use.
my ($bmax) = $src =~ /^use constant BUILDING_MAX\s*=>\s*(\d+)/m;
die "t_buildingstate: BUILDING_MAX not found in Browse.pm\n" unless $bmax;
$reg = "use constant BUILDING_MAX => $bmax;\n" . ($reg // '');
die "t_buildingstate: could not lift the registry from Browse.pm — it moved or was renamed\n"
    unless $reg && $reg =~ /_buildingStart/ && $reg =~ /_buildingEnd/;
# The registry now schedules an EXPIRY timer (a leaked flag is worse than no guard),
# so the lifted copy needs a timer and a logger. The timer stub RECORDS rather than
# no-ops, so section 1 can assert the expiry is armed and cancelled — a no-op stub
# would let a registry that never armed one pass.
{
    package T;
    our @TIMERS;
    our $log = bless {}, 'T::Log';
    package T::Log;
    sub AUTOLOAD { my $n = our $AUTOLOAD; return if $n =~ /DESTROY/; return 1 }
    package Slim::Utils::Timers;
    sub setTimer { my (undef, $when, $cb) = @_; push @T::TIMERS, { when => $when, cb => $cb, dead => 0 }; return $T::TIMERS[-1] }
    sub killSpecific { my ($t) = @_; $t->{dead} = 1 if ref $t eq 'HASH'; return 1 }
}
{
    local $@;
    # `our $log` must be declared INSIDE the eval's scope — the one in the block above
    # is a different lexical scope and does not reach the eval'd string under strict.
    eval "package T; our \$log; $reg 1;" or die "t_buildingstate: registry did not compile: $@\n";
}

section '1. THE REGISTRY: set, observe, release';
{
    is(T::_isBuilding('k'), 0, 'nothing is building to start with');
    T::_buildingStart('k');
    is(T::_isBuilding('k'), 1, 'a started build is observable');
    is(T::_isBuilding('other'), 0, 'and it is keyed — a different view is unaffected');
    T::_buildingEnd('k');
    is(T::_isBuilding('k'), 0, 'and released again');

    # The registry must survive being ended twice — the wrappers can be reached
    # more than once in principle, and a die inside an async callback is silent.
    T::_buildingEnd('k');
    is(T::_isBuilding('k'), 0, 'ending an already-ended key is harmless');

    is(T::_buildingStart('r'), 1, '_buildingStart returns true, so `$owns = _buildingStart(...)` takes ownership');
    T::_buildingEnd('r');

    # THE EXPIRY IS THE POINT OF THE TIMER. Every caller releases its own flag, but a
    # resolve whose async chain never calls back at all releases nothing — and an
    # in-process registry has no TTL to save it, so the view would say "still being
    # built" for ever with nothing running.
    @T::TIMERS = ();
    T::_buildingStart('x');
    is(scalar(@T::TIMERS), 1, 'taking a flag arms an expiry timer');
    my $t = $T::TIMERS[-1];
    T::_buildingEnd('x');
    is($t->{dead}, 1, 'and releasing it cancels that timer (no stray wakeups)');

    @T::TIMERS = ();
    T::_buildingStart('y');
    is(T::_isBuilding('y'), 1, 'a flag nobody releases is set...');
    $T::TIMERS[-1]{cb}->();
    is(T::_isBuilding('y'), 0, '...and the expiry frees it, so the view can rebuild');
}

# ---------------------------------------------------------------------------
# Sections 2-5 assert the CALL SITES, because the thing being protected is a
# control-flow property of two long async subs. There is no return value to
# inspect for "a second fan-out was not started".
# ---------------------------------------------------------------------------
sub sub_body {
    my ($name) = @_;
    my ($body) = $src =~ /\nsub \Q$name\E \{(.*?)\n\}\n/s;
    die "t_buildingstate: could not find sub $name in Browse.pm\n" unless $body;
    return $body;
}

section '2. _resolveTrending TAKES the flag, and RELEASES it on every exit';
{
    my $b = sub_body('_resolveTrending');

    ok(scalar($b =~ /\$owns\s*=\s*_buildingStart\(\$bkey\)/),
       'it takes the flag before starting the fan-out');
    ok(scalar($b =~ /if \(_isBuilding\(\$bkey\)\)/),
       'and checks the flag first');

    # THE RELEASE MUST BE IN $finish, not at the exits. $finish is already the
    # one thing called from all four terminal points (setup-required, cache hit,
    # empty, resolved) — releasing anywhere else would miss one.
    my ($fin) = $b =~ /my \$finish = sub \{(.*?)\n    \};/s;
    ok(defined $fin, 'the $finish wrapper is still there');
    ok(scalar(defined $fin && $fin =~ /_buildingEnd\(\$bkey\) if \$owns/),
       'and it releases the flag — so every exit that calls $finish releases it');

    # The guard's own exit must NOT be counted as an exit that started a build.
    ok(scalar($b =~ /_isBuilding\(\$bkey\)\)\s*\{[\s\S]{0,300}?\$finish->\(\);\s*return;/),
       'the already-building path still calls $finish, so a WARM caller advances its chain');
}

section '3. _buildAlbumsData RELEASES via a WRAPPER, not at each exit';
{
    my $b = sub_body('_buildAlbumsData');

    ok(scalar($b =~ /my \$raw\s*=\s*\$onDone;/ && $b =~ /\$onDone = sub \{/),
       '$onDone is wrapped once at the top');
    ok(scalar($b =~ /_buildingEnd\(\$bkey\) if \$owns/),
       'and the wrapper releases the flag');

    # This is the property that makes the wrapper worth having: there are many
    # exits, and none of them should need to know about the flag.
    my $exits = () = $b =~ /\$onDone->\(/g;
    ok(scalar($exits >= 4),
       "there really are many exits ($exits found) — hand-clearing each would rot");
    my $hand = () = $b =~ /_buildingEnd\(/g;
    is($hand, 1, 'the flag is cleared in exactly ONE place, the wrapper');

    ok(scalar($b =~ /return if \$fired\+\+;/),
       'the wrapper is idempotent, so a double callback cannot double-release');
}

section '4. OWNERSHIP — a caller that merely FINDS the flag must not clear it';
{
    for my $name (qw(_resolveTrending _buildAlbumsData)) {
        my $b = sub_body($name);
        # Every release is guarded by $owns. An unguarded _buildingEnd would let
        # a passer-by release someone else's build, re-opening the duplicate-build
        # hole from the other side.
        my @rel = $b =~ /(_buildingEnd\([^)]*\)[^;\n]*)/g;
        ok(scalar(@rel > 0), "$name releases the flag somewhere");
        my @unguarded = grep { !/if \$owns/ } @rel;
        is(scalar(@unguarded), 0, "$name has NO unguarded _buildingEnd (all are `if \$owns`)");
    }
}

section '5. "BUILDING" IS DISTINCT FROM "EMPTY" — the whole point of the change';
{
    my $b = sub_body('_buildAlbumsData');
    ok(scalar($b =~ /_isBuilding\(\$bkey\)\)\s*\{[\s\S]{0,300}?\$onDone->\(undef\);/),
       'the already-building path hands back undef, NOT an empty arrayref');

    my $r = sub_body('resolveTrendingAlbums');
    ok(scalar($r =~ /unless defined \$data/),
       'the render path distinguishes undef from an empty list');
    ok(scalar($r =~ /_buildingRow\(\$client\)/),
       'and renders the building row for it');

    # The two strings must not be conflated: NO_TRENDING is an affirmative
    # "nobody you follow has listened", BUILDING is "come back in a moment".
    ok(scalar($src =~ /sub _buildingRow[\s\S]{0,300}?PLUGIN_LBF_BUILDING/),
       '_buildingRow uses PLUGIN_LBF_BUILDING');
    ok(scalar($src !~ /_buildingRow[\s\S]{0,200}?PLUGIN_LBF_NO_TRENDING/),
       'and never PLUGIN_LBF_NO_TRENDING');

    my $strings = "$ROOT/ListenBrainzFreshReleases/strings.txt";
    my $st = do { open my $fh, '<', $strings or die "$strings: $!"; local $/; <$fh> };
    ok(scalar($st =~ /^PLUGIN_LBF_BUILDING$/m), 'PLUGIN_LBF_BUILDING is defined in strings.txt');
    ok(scalar($st =~ /PLUGIN_LBF_BUILDING\n\tEN\t\S/), 'and has an EN translation');
}

section '6. THE FEED CHAIN IS ORDERED, AND CANNOT STRAND THE REST';
{
    my $b = sub_body('warmFeeds');

    ok(scalar($b =~ /\$all->\(\);/ && $b =~ /\$muspy->\(\);/),
       'the feeds are chained rather than fired together');

    # For You must be the one that STARTS the chain — that is the stated priority
    # ("New Releases should populate first, then All releases").
    my $iFor = index($b, "_stage('start', 'foryou_feed')");
    my $iAll = index($b, "my \$all = sub {");
    ok(scalar($iFor > 0 && $iAll > 0 && $iFor > $iAll),
       'For You is the entry point (All Releases is defined above it, as a continuation)');

    # AN ERROR MUST ADVANCE THE CHAIN. This is the regression that ordering
    # introduces and concurrency could not have: one failing feed stranding
    # everything queued behind it.
    my @onerr = $b =~ /onError => sub \{(.*?)\},/gs;
    ok(scalar(@onerr >= 2), 'the chained feeds have error paths');
    my @dead = grep { !/->\(\);/ } @onerr;
    is(scalar(@dead), 0, 'and EVERY error path advances the chain (none is a dead end)');

    ok(scalar($b =~ /WARM_FEED_CHAIN_MAX/),
       'a watchdog bounds the whole chain, so a wedged feed cannot starve the warm');
    ok(scalar($b =~ /killSpecific\(\$wdog\)/),
       'and the watchdog is cancelled on normal completion');

    # The tick must WAIT for the chain, or "ordered" means only "issued first".
    my $plugin = do {
        my $p = $ENV{LBF_PLUGIN_PM} || "$ROOT/ListenBrainzFreshReleases/Plugin.pm";
        open my $fh, '<', $p or die "$p: $!"; local $/; <$fh>
    };
    ok(scalar($plugin =~ /warmFeeds\(sub \{[\s\S]{0,400}?warmCache\(\)/),
       'Plugin.pm starts warmCache FROM warmFeeds\' callback, not in the same turn');
}

section '7. THE FIRST OPENER GETS THE ROW TOO — the case 0.9.180 shipped broken';
{
    # WHY THIS SECTION EXISTS. 0.9.180 guarded only the SECOND caller: on a cold
    # open `_isBuilding` is false, so the first opener took the flag and held
    # $callback for the entire ~50s build — the exact Material spinner the building
    # state was added to replace, in the COMMONEST case. Sections 1-6 were all green
    # against that, because they assert the guard's bookkeeping and never ask
    # "what does the user actually see on a cold open".
    my $b = sub_body('_resolveTrending');

    # Anchored on POSITION, not on a span: a `[\s\S]{0,N}` window between the two
    # only passes while the comment between them stays under N, so it would be
    # "fixed" by widening N until it stopped testing anything.
    my $iFlag = index($b, '$owns = _buildingStart($bkey);');
    my $iRow  = $iFlag < 0 ? -1 : index($b, '$callback->(_buildingRow($client));', $iFlag);
    ok(scalar($iFlag > 0 && $iRow > $iFlag),
       'a COLD build renders the building row after taking the flag');

    # And nothing returns in between — a flag taken but a row unreachable would be
    # the same spinner with extra bookkeeping.
    my $between = ($iFlag > 0 && $iRow > $iFlag) ? substr($b, $iFlag, $iRow - $iFlag) : 'return;';
    ok(scalar($between !~ /^\s*return\b/m),
       'and nothing returns between taking the flag and rendering');
    ok(scalar($b =~ /\$callback->\(_buildingRow\(\$client\)\);\s*\n\s*\$callback = undef;/),
       'and clears $callback, so the finished build cannot render a second time');

    # The build must NOT be abandoned — the whole bargain is that it completes into
    # cache so the next open is instant.
    ok(scalar($b !~ /\$callback = undef;\s*\n\s*return;/),
       'clearing the callback does NOT return early — the build carries on into cache');

    my $ab = sub_body('_buildAlbumsData');
    # Structural, not literal: assert the hook is CALLED and is GUARDED, without
    # pinning the spelling — the first cut matched one exact line and broke the
    # moment a log line was added beside it, which tests formatting, not behaviour.
    ok(scalar($ab =~ /ref \$onPending eq 'CODE'/ && $ab =~ /\$onPending->\(\);/),
       '_buildAlbumsData calls $onPending, guarded by a CODE check');
    ok(scalar($ab =~ /my \(\$client, \$range, \$onDone, \$force, \$onPending\) = \@_;/),
       'and takes it as a parameter');

    my $r = sub_body('resolveTrendingAlbums');
    # A 5th argument to _buildAlbumsData that renders the building row. Matched on
    # what it DOES, not on where the line breaks fall.
    my ($call) = $r =~ /_buildAlbumsData\((.*)/s;   # to the end of the sub body
    ok(scalar(defined $call && $call =~ /sub \{ \$render->\(_buildingRow\(\$client\)/),
       'the album view passes an $onPending that renders the building row');
    # "at most once" = the counter is consulted AND the callback is reached from
    # exactly one place. Two invocations would mean two renders whatever the
    # counter said.
    ok(scalar($r =~ /\$rendered\+\+/), 'a render counter is consulted');
    my $invocations = () = $r =~ /\$callback->\(/g;
    is($invocations, 1, 'and $callback is invoked from exactly ONE place');

    # THE WARM MUST NOT GET A PLACEHOLDER. It wants the completion; handing it a
    # building row would advance the chain before the data existed.
    my $wt = sub_body('_warmTrending');
    ok(scalar($wt =~ /_resolveTrending\(\$client, undef,/),
       'the warm passes NO render callback to _resolveTrending');
    my @warmAlbums = $wt =~ /_buildAlbumsData\((.*?)\n/gs;
    ok(scalar(@warmAlbums >= 2), 'the warm drives both album ranges');
    ok(scalar($wt !~ /_buildAlbumsData\([^;]*?_buildingRow/s),
       'and passes NO $onPending for either — the warm gets completions, not placeholders');
}

section '8. EVERY UNREADY VIEW, AND THE "CHECK AGAIN" ROW';
{
    # THE ROW IS THE ONLY REFRESH MATERIAL CAN GIVE A WAITING PAGE. There is no
    # server push: a plugin cannot refresh a page the user is on, and `needsRefresh`
    # is client-side only. `nextWindow` is honoured ONLY on an EMPTY response
    # (browseHandleNextWindow), which is why the row must return no items and do
    # nothing else — returning items would silently make nextWindow a no-op.
    my $ca = sub_body('_checkAgainItem');
    ok(scalar($ca =~ /nextWindow\s*=>\s*'refresh'/), 'Check again uses nextWindow refresh');
    ok(scalar($ca =~ /\{ items => \[\] \}/),
       'and returns an EMPTY list — nextWindow is ignored on a non-empty response');
    ok(scalar($ca =~ /type\s*=>\s*'link'/), 'and is a link, so it is tappable');

    my $br = sub_body('_buildingRow');
    ok(scalar($br =~ /_checkAgainItem\(\$client\)/),
       'the building row carries the Check again row');
    ok(scalar($br =~ /PLUGIN_LBF_BUILDING/), 'alongside the building message');
    ok(scalar($br =~ /cachetime => 0/),
       'and is never cached — a cached building row would outlive the build');

    my $strings = "$ROOT/ListenBrainzFreshReleases/strings.txt";
    my $st = do { open my $fh, '<', $strings or die "$strings: $!"; local $/; <$fh> };
    ok(scalar($st =~ /PLUGIN_LBF_CHECK_AGAIN\n\tEN\t\S/), 'PLUGIN_LBF_CHECK_AGAIN has an EN string');

    # ALL FOUR UNREADY VIEWS, not just the follower ones. Each must guard, take the
    # flag, and render the row to its FIRST opener.
    my %views = (
        _resolveTrending  => '$bkey',
        _buildAlbumsData  => '$bkey',
        resolvePlaylist   => '$bkey',
        _resolveFollow    => '$bkey',
    );
    for my $name (sort keys %views) {
        my $b = sub_body($name);
        ok(scalar($b =~ /_isBuilding\(\$bkey\)/),   "$name guards on _isBuilding");
        ok(scalar($b =~ /_buildingStart\(\$bkey\)/), "$name takes the flag");
        ok(scalar($b =~ /_buildingEnd\(\$bkey\)/),   "$name releases it");
    }

    # The two track-resolving views render to the first opener directly (the album
    # build does it through $onPending, asserted in section 7).
    for my $name (qw(resolvePlaylist _resolveFollow)) {
        my $b = sub_body($name);
        ok(scalar($b =~ /_buildingRow\(\$client\)/), "$name renders the building row");
        # Either detach form is fine ($callback in one, the wrapped $raw in the
        # other); what must hold is that the render is followed by a detach, so the
        # completed resolve cannot render into a callback the skin has finished with.
        ok(scalar($b =~ /_buildingRow\(\$client\)\);\s*\n\s*\$(?:callback|raw) = undef;/),
           "$name detaches the callback, so the resolve completes into cache without rendering twice");
    }

    # _resolveFollow is ALSO on the warm path, where $callback is undef and the single
    # terminal reads `if $callback` to decide whether to build the result rows at all.
    # Wrapping $callback there would make that always true and render rows the warm
    # never uses — so it must release through its own closure instead.
    my $rf = sub_body('_resolveFollow');
    ok(scalar($rf =~ /my \$release\s*=\s*sub/),
       '_resolveFollow releases via a closure, NOT by wrapping $callback');
    ok(scalar($rf =~ /\$release->\(\);/), 'and calls it at the terminal');
    ok(scalar($rf !~ /\$callback = sub \{/),
       'and never replaces $callback — undef is load-bearing on the warm path');
}

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
