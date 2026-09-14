#!/usr/bin/env perl
#
# t_warmclock.pl — the FIXED OVERNIGHT CLOCK (docs/scheduled-overnight-warm.md §4A).
#
#   perl tools/t_warmclock.pl
#
# WHAT THIS PROTECTS, AND WHY EACH ASSERTION EXISTS.
#
# The warm used to re-arm at `time() + WARM_INTERVAL` — 24 hours relative to
# STARTUP. So the daily tick landed at whatever o'clock the server happened to be
# restarted at: on the live rig that was 08:58, the middle of the day, competing
# with listening and ~6 hours adrift of ListenBrainz's own 03:00 UTC job purely by
# coincidence. A server restarted at 21:00 pulled at 21:00 for ever. Neither
# honours "the user wakes up to find new material ready and waiting".
#
# It now re-arms from `_secsUntilNextWarm`, which answers "how many seconds until
# the next WARM_HOUR o'clock LOCAL". The failure shapes that answer protects:
#
#   - AN ANSWER OF ZERO OR LESS IS A TIGHT LOOP. `_warmTick` re-arms from this at
#     the bottom of the sub, so a helper that can return 0 at the moment the tick
#     fires re-arms for NOW, fires again, and spins. Section 1 walks every one of
#     the 86,400 seconds-into-day and requires a STRICTLY future answer, never
#     merely a non-negative one. This is the assertion the boundary bug hides in:
#     the natural `$secs += 86400 if $secs < 0` passes every other test here.
#
#   - LOCAL, NOT UTC, AND IT MUST ACTUALLY LAND ON THE HOUR. The release-window
#     arithmetic is local throughout (API::_today, DB::_weekStart), so a UTC
#     schedule would roll the warm and the window on different clocks. Section 2
#     converts the answer BACK through localtime and requires the target hour —
#     a helper that is merely consistent with itself would pass a delta-only test.
#
#   - EVERY RUN LANDS ON TARGET, THE DST DAYS INCLUDED, AND THERE IS ONE RUN PER
#     LOCAL DATE. This section USED to pin the opposite — "the transition day lands
#     within an hour, the next is back on target" — as a deliberate design
#     decision. It was wrong: the arithmetic-only helper re-armed the AUTUMN tick
#     for 04:10 GMT and that tick re-armed an hour later, so the warm ran TWICE on
#     2026-10-25 (review 2026-09-14). The old section asked one landing from
#     midnight and never followed the re-arm CHAIN, which is the only place the
#     second run exists. Section 3 now walks the chain across both transitions and
#     demands exact landings, one per date, and _lastWarmInstant exact on the
#     transition day. The transitions are FOUND by scanning, never hardcoded, so
#     the suite cannot quietly test the wrong day in a later year.
#
#   - A RESTART JUST BEFORE THE CLOCK DOES NOT ALSO RE-SEED. If the clock tick is
#     due within WARM_DELAY, the re-seed would fire AFTER the tick had zeroed
#     $detailMainReady and release it mid-warm. Section 6 pins both sides of the
#     WARM_DELAY boundary.
#
#   - A TICK LANDING SHORTLY BEFORE A SCHEDULED WARM FOLDS INTO IT, AND A
#     SCHEDULED TICK NEVER FOLDS ITSELF. A catch-up (or a scan-deferred tick) that
#     warms just before the instant re-arms for seconds later, and two complete
#     warms run over each other (review of 0.9.217). Section 6b pins the WARM_MERGE
#     boundary, that the clock tick at or up to ten minutes past its instant never
#     folds (across both DST weeks), and FOLLOWS THE CHAIN for every boot minute of
#     two days with scans of 0/1h/2h — the gate-only fix passed the single-instant
#     assertions and still left warms 40s apart behind a 2h scan.
#
#   - THE JITTER MUST BE STABLE, BOUNDED, AND NOT ZERO. Without jitter every
#     install of this plugin in a given timezone hits api.listenbrainz.org in the
#     same second, and MetaBrainz is publicly asking for relief from exactly that.
#     Stable per install (derived from a fixed local value) or it moves between
#     ticks and `next_tick_at` becomes unfalsifiable. Section 4 pins all three,
#     INCLUDING that it is not a constant zero for every install — the shape a
#     "temporarily disabled" jitter leaves behind, which every other assertion
#     here passes against.
#
#   - AND THE RE-ARM MUST ACTUALLY USE IT. Sections 1-4 can all be green while
#     `_warmTick` still re-arms from WARM_INTERVAL, because the helper is correct
#     and simply unreachable. Section 5 is a body assertion on the real Plugin.pm
#     (the t_buildingstate.pl pattern — there is no return value to inspect).
#
# ANTI-TEST (run these; a green baseline proves nothing on its own):
#
#   cp ListenBrainzFreshReleases/Plugin.pm /tmp/Plugin.pm
#   # _secsUntilNextWarm: `$at > $now` becomes `$at >= $now`             -> RED §1 §2 §3
#   # _warmInstantOn: build the instant as UTC (Time::Local::timegm_nocheck
#   #   in place of POSIX::mktime)                                       -> RED §2
#   #   (gmtime for the DATE is deliberately harmless: both candidate loops
#   #    start a day early/late, so a date one day off still finds the instant)
#   # _warmJitter: return 0                                              -> RED §4
#   # _warmTick: re-arm from `time() + WARM_INTERVAL` again              -> RED §5
#   # _secsUntilNextWarm: back to seconds-into-day arithmetic
#   #   (`WARM_HOUR*3600 + jitter - secsIntoDay`, += 86400 if <= 0)       -> RED §3
#   # _lastWarmInstant: back to `$now + _secsUntilNextWarm($now) - 86400` -> RED §3
#   # _armWarm: arm 'reseed' unconditionally again                      -> RED §6
#   # _warmTick: delete the _catchUpFold block                          -> RED §6b (2)
#   #   (ONLY the two order assertions see this: the chain models the fold
#   #    through the helper, so the body assertion is the guard here)
#   # _catchUpFold: `<= WARM_MERGE` becomes `< WARM_MERGE`              -> RED §6b (1)
#   # _catchUpFold deleted outright                                     -> RED §6b (8)
#   LBF_PLUGIN=/tmp/Plugin.pm perl tools/t_warmclock.pl
#
# Exit 0 = all good. Exit 1 = at least one regressed.

use strict;
use warnings;
use FindBin;
use File::Spec;
use POSIX qw(tzset);

# EVERY assertion here is about where a boundary lands in LOCAL time, so the zone
# has to be chosen rather than inherited from whatever machine runs the suite.
# LBF_TZ overrides it, to run the same assertions in another zone (a southern-
# hemisphere change, Lord Howe's half hour). A zone with no DST fails only §3's
# "found both transitions" line, which is the correct answer there.
BEGIN { $ENV{TZ} = $ENV{LBF_TZ} || 'Europe/London'; tzset(); }

my $ROOT    = File::Spec->catdir($FindBin::Bin, File::Spec->updir);
my $PLUGDIR = File::Spec->catdir($ROOT, 'ListenBrainzFreshReleases');
# Overridable so an anti-test run can point the suite at a MUTATED copy. Without
# it the run silently reads the working tree and "passes" (t_review_fixes.pl).
my $PLUGIN  = $ENV{LBF_PLUGIN} || File::Spec->catfile($PLUGDIR, 'Plugin.pm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    # A MISSING MESSAGE IS A HARNESS BUG AND MUST REPORT RED, NEVER GREEN.
    #
    # `$src =~ /no captures/` in LIST context yields (1) on a match and the EMPTY
    # LIST on a miss — so a failing regex assertion shifts its message into $cond,
    # where a non-empty string is TRUE. The assertion then prints PASS at the exact
    # moment it detected the regression. An earlier draft of this file "handled"
    # that by defaulting the message, which is how it stayed hidden through a full
    # anti-test run. It must not die either (that takes every later assertion with
    # it), so it counts a failure and says what is wrong with the SUITE.
    unless (defined $what) {
        $fail++;
        print "  FAIL  HARNESS BUG: ok() called with no message — an assertion is\n"
            . "        passing its condition in list context. Wrap the regex:\n"
            . "        ok(scalar(\$x =~ /re/), '...')\n";
        return 0;
    }
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}
sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}
# Brace-matched verbatim extraction of a named sub (bench_walk.pl's `grab`).
# Eval'd by the caller so a RENAMED sub fails as an assertion rather than taking
# the harness down at exit 255 with no FAIL line (the 0.9.209 lesson).
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

my $plugin_src = slurp($PLUGIN);

# ---------------------------------------------------------------------------
# Lift the REAL helpers into a throwaway package.
#
# The constants are read OUT of Plugin.pm rather than restated: a suite that pins
# its own copy of WARM_HOUR cannot catch WARM_HOUR changing.
# ---------------------------------------------------------------------------
my %PREF;
{
    package StubPrefs;
    sub get { $PREF{ $_[1] } }
    sub set { $PREF{ $_[1] } = $_[2] }
}

my $lifted = eval {
    my $code = "package T; use strict; use warnings; use Digest::MD5 qw(md5_hex);\n"
             . "my \$prefs = bless {}, 'StubPrefs';\n"
             . "sub preferences { bless {}, 'StubPrefs' }\n"
             . "our \$warmJitter;\n"
             . "sub dbg {}\n"
             . "sub _warmTick {}\n"
             . "sub _warmReseed {}\n"
             . "sub _armTimer;\n";
    for my $c (qw(WARM_HOUR WARM_JITTER_MAX WARM_DELAY WARM_MERGE)) {
        $plugin_src =~ /^(use constant \s*\Q$c\E\s*=>.*?;)/m or die "no constant $c\n";
        $code .= "$1\n";
    }
    # _warmInstantOn is lifted too, and deliberately NOT required: a mutant that
    # reverts the two helpers to seconds-arithmetic no longer calls it, and must
    # fail as an ASSERTION in §3 rather than as a lift error here.
    $code .= "use POSIX ();\n";
    $code .= grab($plugin_src, $_) for qw(_warmJitter _secsUntilNextWarm
                                          _lastWarmInstant _armWarm);
    $code .= eval { grab($plugin_src, '_warmInstantOn') } // '';
    # Optional for the same reason: a mutant without it fails §6b as assertions.
    $code .= eval { grab($plugin_src, '_catchUpFold') } // '';
    $code .= "1;";
    eval $code or die "lifting: $@";
    1;
};
unless ($lifted) {
    print "\n  FAIL  the clock helpers could not be lifted from Plugin.pm: $@\n";
    print "\nRESULT: 0 passed, 1 failed\n";
    exit 1;
}

# A stable seed, so the jitter is a fixed number for the whole run and section 2
# can predict exactly where the answer lands.
$PREF{server_uuid} = 'test-uuid-for-the-suite';
my $JIT = T::_warmJitter();
my $H   = T::WARM_HOUR();

printf "\n(WARM_HOUR = %02d:00 local, jitter = %ds, TZ = %s)\n", $H, $JIT, $ENV{TZ};

# A plain, ordinary, non-transition day: Wednesday 2026-08-19, 00:00:00 local.
# Found by asking localtime rather than by hand-computing an epoch.
# mktime, not "step back an hour until 00:00:00": in a half-hour zone (Lord Howe,
# +10:30) hour-steps never reach minute 0 until they cross a DST change, which put
# DAY0 on a different day and broke every fixture built from it.
my $DAY0 = POSIX::mktime(0, 0, 0, 19, 7, 126, 0, 0, -1);

print "\nSECTION 1 — the answer is ALWAYS strictly future, and never more than a day away\n";
print "-" x 74, "\n";
{
    my ($notFuture, $tooFar, $worst) = (0, 0, 0);
    for my $s (0 .. 86399) {
        my $secs = T::_secsUntilNextWarm($DAY0 + $s);
        $notFuture++ if $secs <= 0;
        $tooFar++    if $secs > 86400 + T::WARM_JITTER_MAX();
        $worst = $secs if $secs > $worst;
    }
    ok($notFuture == 0,
       "every one of the 86,400 seconds-into-day gives a STRICTLY future answer ($notFuture zero-or-past)");
    ok($tooFar == 0,
       "no answer exceeds 86400 + max jitter (worst seen ${worst}s)");
}

print "\nSECTION 2 — it lands ON the target hour, checked by converting back\n";
print "-" x 74, "\n";
{
    my $offTarget = 0;
    my @bad;
    for my $hour (0 .. 23) {
        my $now  = $DAY0 + $hour * 3600 + 1234;      # an arbitrary offset into the hour
        my $land = $now + T::_secsUntilNextWarm($now);
        my @l    = localtime($land);
        my $into = $l[2] * 3600 + $l[1] * 60 + $l[0];
        unless ($into == $H * 3600 + $JIT) {
            $offTarget++;
            push @bad, sprintf("%02d:00->%02d:%02d:%02d", $hour, @l[2,1,0]);
        }
    }
    ok($offTarget == 0,
       "from every hour of an ordinary day the answer lands at "
       . sprintf("%02d:%02d:%02d", $H, int($JIT/60), $JIT%60)
       . " local" . (@bad ? " (off: " . join(', ', @bad) . ")" : ""));

    # THE CONTROL. Without this, a helper that returned a constant 86400 would pass
    # the assertion above for the single hour that happens to align, and the loop
    # above would be the only thing standing between us and not noticing.
    my $fromTarget = T::_secsUntilNextWarm($DAY0 + $H * 3600 + $JIT);
    ok($fromTarget == 86400,
       "asked AT the target instant it answers a full day, not zero (${fromTarget}s)");
}

print "\nSECTION 3 — across both DST changes: every run on target, ONE run per local date\n";
print "-" x 74, "\n";
{
    # FIND the transitions rather than hardcoding them — a hardcoded 2026 date
    # silently tests an ordinary day the moment someone runs this in 2027.
    my @flips;
    my $t = $DAY0 - 250 * 86400;
    my $prev = (localtime($t))[8];
    for my $d (1 .. 500) {
        my $n = $t + $d * 86400;
        my $is = (localtime($n))[8];
        if ($is != $prev) { push @flips, $n; $prev = $is; }
    }
    ok(scalar(@flips) >= 2, "found both DST transitions by scanning (" . scalar(@flips) . ")");

    my $target = $H * 3600 + $JIT;
    my $into   = sub { my @l = localtime($_[0]); $l[2] * 3600 + $l[1] * 60 + $l[0] };
    my $date   = sub { my @l = localtime($_[0]); sprintf '%04d-%02d-%02d', $l[5] + 1900, $l[4] + 1, $l[3] };

    my (@offTarget, @dupDates, @badGap, @lastOff);
    my $fires = 0;
    for my $f (@flips) {
        # Midnight local on the transition day.
        my $mid = $f;
        $mid -= 3600 while (localtime($mid))[2] != 0 || (localtime($mid))[1] || (localtime($mid))[0];

        # FOLLOW THE RE-ARM CHAIN, exactly as _warmTick does, from midday two days
        # before the change to two days after it. The autumn double run exists ONLY
        # in the chain: a single landing asked from midnight looks fine.
        my $t = $mid - 2 * 86400 + 12 * 3600;
        my ($prev, %dates);
        for (1 .. 5) {
            $t += T::_secsUntilNextWarm($t);
            $fires++;
            push @offTarget, $date->($t) . ' ' . scalar(localtime $t) if $into->($t) != $target;
            push @dupDates, $date->($t) if $dates{ $date->($t) }++;
            push @badGap, $t - $prev if defined $prev && ($t - $prev < 82800 || $t - $prev > 90000);
            $prev = $t;
        }

        # The gate's view: at 14:00 local the most recent scheduled instant is that
        # day's target, exactly — on the day BEFORE, OF and AFTER the change. The
        # day before is the one that matters: `next - 86400` there subtracts across
        # the change and lands an hour off. Checking only the change day itself let
        # the old arithmetic pass (anti-test M2, first run).
        for my $d (-1, 0, 1) {
            my $n = $mid + $d * 86400 + 14 * 3600;
            $n -= 3600 while (localtime($n))[2] > 14;
            $n += 3600 while (localtime($n))[2] < 14;
            my $li = T::_lastWarmInstant($n);
            push @lastOff, $date->($n) unless $date->($li) eq $date->($n) && $into->($li) == $target;
        }
    }
    ok($fires == 5 * @flips, "followed the re-arm chain across every transition ($fires runs)");
    ok(!@offTarget,
       "every run in the chain lands exactly on target, the change days included"
       . (@offTarget ? " (off: " . join('; ', @offTarget) . ")" : ""));
    ok(!@dupDates,
       "ONE run per local date — the autumn change does not warm twice"
       . (@dupDates ? " (twice on: @dupDates)" : ""));
    ok(!@badGap,
       "consecutive runs are 23-25 hours apart, never an hour" . (@badGap ? " (gaps: @badGap)" : ""));
    ok(!@lastOff,
       "_lastWarmInstant the day before, of and after each change is that day's target, exactly"
       . (@lastOff ? " (off on: @lastOff)" : ""));
}

print "\nSECTION 4 — the jitter is stable, bounded, and not a constant zero\n";
print "-" x 74, "\n";
{
    my $a = T::_warmJitter();
    my $b = T::_warmJitter();
    ok($a == $b, "two calls in one process give the same offset ($a == $b)");
    ok($a >= 0 && $a < T::WARM_JITTER_MAX(),
       "it lies in [0, " . T::WARM_JITTER_MAX() . ") — got $a");

    # NOT ZERO FOR EVERY INSTALL. A `return 0` passes every other assertion in this
    # file, and is exactly what a disabled-for-debugging jitter leaves behind.
    # Drive several distinct seeds through the REAL sub by resetting its memo.
    my %seen;
    for my $seed (qw(uuid-alpha uuid-beta uuid-gamma uuid-delta uuid-epsilon
                     uuid-zeta uuid-eta uuid-theta)) {
        $PREF{server_uuid} = $seed;
        no warnings 'once';
        $T::warmJitter = undef;                       # clear the per-process memo
        $seen{ T::_warmJitter() }++;
    }
    ok(scalar(keys %seen) > 1,
       "different installs get different offsets (" . scalar(keys %seen) . " distinct across 8 seeds)");
    ok(!(keys %seen == 1 && exists $seen{0}),
       "it is not a constant zero for every install");

    $PREF{server_uuid} = 'test-uuid-for-the-suite';
    { no warnings 'once'; $T::warmJitter = undef; }
}

print "\nSECTION 5 — _warmTick re-arms FROM the helper, not from WARM_INTERVAL\n";
print "-" x 74, "\n";
{
    my $tick = eval { grab($plugin_src, '_warmTick') };
    if (ok(defined $tick, "_warmTick is present in Plugin.pm")) {
        # Comment-stripped, or a comment MENTIONING the old constant passes this.
        (my $body = $tick) =~ s/^\s*#.*$//mg;

        ok(scalar($body =~ /setTimer\s*\(\s*undef\s*,\s*time\(\)\s*\+\s*_secsUntilNextWarm\(\)/),
           "the daily re-arm is time() + _secsUntilNextWarm()");
        ok($body !~ /setTimer\s*\(\s*undef\s*,\s*time\(\)\s*\+\s*WARM_INTERVAL/,
           "nothing in _warmTick re-arms from WARM_INTERVAL any more");
        # The scan defer is a DIFFERENT re-arm and must survive untouched — a
        # rewrite that routed it through the clock would defer a scan-blocked tick
        # to tomorrow morning instead of retrying in two minutes.
        # SCOPED TO THE setTimer, NOT THE WHOLE BODY. WARM_SCAN_RETRY also appears
        # in the dbg() line beside it, so a bare grep for the name stays green
        # while the defer itself is rerouted through the clock — which would send a
        # scan-blocked tick to tomorrow morning instead of retrying in two minutes.
        # The 0.9.209 lesson: a whole-file regex for a common idiom is a trap.
        ok(scalar($body =~ /setTimer\s*\(\s*undef\s*,\s*time\(\)\s*\+\s*WARM_SCAN_RETRY/),
           "the scan defer still re-arms on WARM_SCAN_RETRY (control)");
    }
    else {
        ok(0, "the daily re-arm is time() + _secsUntilNextWarm()");
        ok(0, "nothing in _warmTick re-arms from WARM_INTERVAL any more");
        ok(0, "the scan defer still re-arms on WARM_SCAN_RETRY (control)");
    }
}

print "\nSECTION 6 — the startup gate: every row of the §4B table\n";
print "-" x 74, "\n";
{
    # Drive the REAL _armWarm. Everything it touches is stubbed at the seam:
    # the timer registry records what was armed, the prefs are a plain hash.
    #
    # THE TWO THINGS THIS MUST DISTINGUISH, and a naive test conflates them:
    # "did the catch-up tick get armed" and "did the CLOCK get armed". A gate that
    # skipped the catch-up AND forgot the schedule would stop the plugin warming at
    # all, and would pass a test that only checked "no tick ran".
    my @ARMED;
    {
        no warnings 'redefine', 'once';
        *T::_armTimer = sub { push @ARMED, { in => $_[0], what => $_[1] } };
    }

    # $now is fixed at 14:00 local on an ordinary day, so "today's 05:0x" is in the
    # past and "yesterday's" is a day further back.
    my $NOW   = $DAY0 + 14 * 3600;
    my $TODAY = $DAY0 + $H * 3600 + $JIT;          # today's scheduled instant
    my $YDAY  = $TODAY - 86400;

    my $armed = sub {
        my (%o) = @_;
        @ARMED = ();
        %PREF = (server_uuid => 'test-uuid-for-the-suite');
        $PREF{warm_last_at} = $o{last} if exists $o{last};
        T::_armWarm($o{build} ? 1 : 0, $NOW);
        my %by = map { $_->{what} => $_->{in} } @ARMED;
        return \%by;
    };

    # The instant helper itself, first — the gate is only as good as this.
    my $li = T::_lastWarmInstant($NOW);
    ok($li <= $NOW && $li > $NOW - 86400,
       "_lastWarmInstant lands in the last 24h and never in the future");
    ok(abs($li - $TODAY) < 2,
       "at 14:00 the most recent scheduled instant is today's 05:0x");

    # ROW 1 — always on, restarted five times in an evening. THE SAVING.
    my $r = $armed->(last => $TODAY + 5);
    ok(!exists $r->{tick},
       "restarted after today's warm: NO catch-up tick — this is the call saving");
    ok(exists $r->{clock},
       "...but the clock IS still armed (the gate that forgot this stops warming entirely)");
    ok(exists $r->{reseed},
       "...and the detail queue is re-seeded, or §3.4's nine-hour hole is back");

    # ROW 2 — switched off overnight, powered on at 09:00. THE CATCH-UP.
    # This is the regression the whole change could plausibly introduce: a fixed
    # 05:00 NEVER fires on a machine its owner switches off at night, so if the
    # gate suppressed the catch-up here the plugin would never warm at all.
    $r = $armed->(last => $YDAY + 5);
    ok(exists $r->{tick},
       "off overnight, warmed only yesterday: catch-up RUNS (the machine that would never warm)");
    ok(!exists $r->{reseed},
       "...and it does not ALSO re-seed — the tick's own feed pass does that");

    # ROW 3 — fresh install.
    $r = $armed->();
    ok(exists $r->{tick}, "no warm_last_at at all: catch-up runs, as it must");

    # ROW 4 — restarted at 04:00 having warmed yesterday at 05:0x. Uses a $now
    # BEFORE today's instant, so "the most recent instant" is yesterday's.
    {
        my $early = $DAY0 + 4 * 3600;
        @ARMED = ();
        %PREF = (server_uuid => 'test-uuid-for-the-suite', warm_last_at => $YDAY + 5);
        T::_armWarm(0, $early);
        my %by = map { $_->{what} => $_->{in} } @ARMED;
        ok(!exists $by{tick},
           "restarted at 04:00 having warmed yesterday: skips (yesterday's warm still counts)");
        ok(exists $by{clock} && $by{clock} > 0 && $by{clock} <= 3600 + $JIT + 1,
           "...and the clock fires about an hour later, not tomorrow");
    }

    # ROW 5 — the build changed. THE BRANCH THAT WAS DEAD CODE.
    # _buildChanged sets last_build INSIDE its own eval, so a gate that re-called it
    # would always be told "no change". The answer has to be PASSED IN. Without this
    # a clean-load test build that restarts after 05:00 would skip its own refill.
    $r = $armed->(last => $TODAY + 5, build => 1);
    ok(exists $r->{tick},
       "build changed AFTER today's warm: catch-up still runs (the RESET_CACHE_ON_BUILD refill)");

    # ROW 6 — restarted JUST BEFORE the scheduled instant, having warmed yesterday.
    # The clock tick fires before a WARM_DELAY re-seed would, zeroes
    # $detailMainReady for its phase ordering, and the re-seed would then release it
    # mid-warm. The tick seeds the queue itself, so the re-seed must not be armed.
    # Both sides of the boundary, or a guard at the wrong number passes.
    my $D = T::WARM_DELAY();
    for my $case ([ $D,     0, 'clock due in exactly WARM_DELAY' ],
                  [ 60,     0, 'clock due in 60s' ],
                  [ $D + 1, 1, 'clock due in WARM_DELAY + 1 (control)' ]) {
        my ($before, $wantReseed, $what) = @$case;
        @ARMED = ();
        %PREF = (server_uuid => 'test-uuid-for-the-suite', warm_last_at => $YDAY + 5);
        T::_armWarm(0, $TODAY - $before);
        my %by = map { $_->{what} => $_->{in} } @ARMED;
        ok(!exists $by{tick} && exists $by{clock} && $by{clock} == $before,
           "$what: no catch-up, clock armed for ${before}s");
        ok(($wantReseed ? 1 : 0) == (exists $by{reseed} ? 1 : 0),
           "$what: re-seed " . ($wantReseed ? "IS armed (it fires before the clock)"
                                            : "is NOT armed (the tick seeds the queue itself)"));
    }
}

print "\nSECTION 6b — a tick landing just before a scheduled warm folds into it\n";
print "-" x 74, "\n";
{
    my $M     = T::WARM_MERGE();
    my $TODAY = $DAY0 + $H * 3600 + $JIT;
    my $f     = sub { T->can('_catchUpFold') ? T::_catchUpFold($_[0]) : -1 };

    ok(T->can('_catchUpFold') ? 1 : 0, "_catchUpFold is present");
    ok($f->($TODAY - 1) == 1,        "1s before the instant: folds, waits 1s");
    ok($f->($TODAY - $M) == $M,      "exactly WARM_MERGE before: folds (boundary)");
    ok($f->($TODAY - $M - 1) == 0,   "WARM_MERGE + 1 before: runs now (control)");
    ok($f->($TODAY) == 0,            "AT the instant — the clock tick itself — never folds");
    my $late = grep { $f->($TODAY + $_) != 0 } 1 .. 600;
    ok($late == 0,                   "a clock tick firing up to 10 minutes late never folds");

    # THE PROPERTY THAT MAKES THE FOLD SAFE: no scheduled tick folds itself. Every
    # instant across both DST weeks, at and just after it.
    my ($n, $bad) = (0, 0);
    for my $wk ([23, 9, 126], [27, 2, 126]) {
        my $t0 = POSIX::mktime(0, 0, 0, $wk->[0], $wk->[1], $wk->[2], 0, 0, -1);
        for my $day (0 .. 5) {
            my $inst = T::_warmInstantOn($t0, $day);
            $n++;
            $bad++ if grep { $f->($inst + $_) != 0 } 0 .. 300;
        }
    }
    ok($n == 12 && $bad == 0, "no scheduled instant across either DST week folds itself ($bad of $n)");

    # THE CHAIN, followed rather than asked once (the §3 lesson): boot every minute
    # for two days having missed the last warm, with no scan, a 1h scan and a 2h
    # scan, modelling _warmTick's order — scan defer, fold, warm, re-arm. The
    # gate-only version of this fix passes everything above and fails HERE.
    my ($RETRY) = $plugin_src =~ /^use constant\s+WARM_SCAN_RETRY\s*=>\s*(\d+)/m;
    $RETRY ||= 120;
    my ($minGap, $never) = (undef, 0);
    for my $scan (0, 3600, 7200) {
        for (my $B = $DAY0; $B < $DAY0 + 2 * 86400; $B += 60) {
            %PREF = (server_uuid => 'test-uuid-for-the-suite',
                     warm_last_at => T::_lastWarmInstant($B) - 3600);
            my @q;
            {
                no warnings 'redefine';
                local *T::_armTimer = sub { push @q, [ $B + $_[0], $_[1] ] };
                T::_armWarm(0, $B);
            }
            my @warms;
            while (@q) {
                @q = sort { $a->[0] <=> $b->[0] } @q;
                my ($t, $what) = @{ shift @q };
                last if $t > $B + 30 * 3600;
                next if $what eq 'reseed';
                if ($t < $B + $scan) { push @q, [ $t + $RETRY, $what ]; next }
                if ((my $w = $f->($t)) > 0) { push @q, [ $t + $w, 'clock' ]; next }
                push @warms, $t;
                push @q, [ $t + T::_secsUntilNextWarm($t), 'clock' ];
            }
            $never++ if !@warms || $warms[0] > $B + 26 * 3600;
            for my $i (1 .. $#warms) {
                my $g = $warms[$i] - $warms[$i - 1];
                $minGap = $g if !defined $minGap || $g < $minGap;
            }
        }
    }
    ok($never == 0, "every boot minute over two days, scans of 0/1h/2h: it still warms within 26h");
    ok(defined $minGap && $minGap > $M,
       "...and no two warms start within WARM_MERGE of each other (min gap " . ($minGap // 'none') . "s)");

    # ORDER IN _warmTick: after the scan defer (a scan-blocked tick keeps retrying),
    # before stageReset and the warm_last_at stamp (a folded tick is not a warm).
    my $tick = eval { grab($plugin_src, '_warmTick') } // '';
    (my $body = $tick) =~ s/^\s*#.*$//mg;
    my ($pScan, $pFold, $pReset, $pStamp) =
        map { index($body, $_) } ('stillScanning', '_catchUpFold(', 'stageReset(', 'warm_last_at');
    ok($pScan >= 0 && $pFold > $pScan, "_warmTick checks the fold AFTER the scan defer");
    ok($pFold >= 0 && $pFold < $pReset && $pFold < $pStamp,
       "...and BEFORE stageReset and the warm_last_at stamp");
}

print "\nSECTION 7 — the gate's answer comes from _buildChanged, which cannot be re-asked\n";
print "-" x 74, "\n";
{
    my $bc = eval { grab($plugin_src, '_buildChanged') };
    if (ok(defined $bc, "_buildChanged is present")) {
        (my $body = $bc) =~ s/^\s*#.*$//mg;
        # It must hand back whether it actually did the work. A bare `or $log->error`
        # statement at the end returns the eval's value, which is 1 on the DID-NOTHING
        # early-return path too — so the early return has to say so explicitly.
        # \b, not `\s*;` — the early return is a statement-modifier
        # (`return 0 if $seen eq $version;`) and an over-tight regex here reports a
        # code defect that is not there.
        ok(scalar($body =~ /return\s+0\b/),
           "it returns 0 on the nothing-to-do path, so 'did it fire?' is answerable");
        ok(scalar($body =~ /return\s+1\b/),
           "...and 1 when it did the work");
    }
    else {
        ok(0, "it returns 0 on the nothing-to-do path, so 'did it fire?' is answerable");
        ok(0, "...and 1 when it did the work");
    }

    my $post = eval { grab($plugin_src, 'postinitPlugin') };
    if (ok(defined $post, "postinitPlugin is present")) {
        (my $body = $post) =~ s/^\s*#.*$//mg;
        ok(scalar($body =~ /_armWarm\s*\(/),
           "the warm is armed through the gate, not with a bare unconditional setTimer");
        ok($body !~ /setTimer\s*\(\s*undef\s*,\s*time\(\)\s*\+\s*WARM_DELAY\s*,\s*\\&_warmTick/,
           "the old unconditional +WARM_DELAY arm is gone");
        ok(scalar($body =~ /_buildChanged\s*\(\s*\)/),
           "_buildChanged is still called exactly where it was (control)");
    }
    else {
        ok(0, "the warm is armed through the gate, not with a bare unconditional setTimer");
        ok(0, "the old unconditional +WARM_DELAY arm is gone");
        ok(0, "_buildChanged is still called exactly where it was (control)");
    }
}

print "\nSECTION 8 — warm_last_at is stamped at the BOTTOM of _warmTick\n";
print "-" x 74, "\n";
{
    my $tick = eval { grab($plugin_src, '_warmTick') };
    if (ok(defined $tick, "_warmTick is present")) {
        (my $body = $tick) =~ s/^\s*#.*$//mg;
        ok(scalar($body =~ /\$prefs->set\s*\(\s*['"]warm_last_at['"]/),
           "the tick stamps warm_last_at");

        # IT IS A SCHEDULE MARKER, NOT A SUCCESS RECORD. Written on the synchronous
        # path beside the re-arm, so a tick whose async chain later fails still
        # counts as "the warm ran at this hour" — otherwise a run of failures would
        # make every restart re-run a full warm, which is the behaviour being fixed.
        # warmstats remains the record of what actually succeeded.
        my ($stampAt) = ($body =~ /(.*)\$prefs->set\s*\(\s*['"]warm_last_at['"]/s);
        ok(defined $stampAt && $stampAt !~ /onDone\s*=>/,
           "it is NOT inside an onDone callback — a failed chain still counts as today's warm");

        # And it is the LAST thing, beside the re-arm, not before the work is issued.
        my $stampPos  = index($body, 'warm_last_at');
        my $sweepPos  = index($body, 'feedSweep');
        ok($stampPos > $sweepPos && $sweepPos > 0,
           "it is stamped after the sweeps, at the bottom of the sub");
    }
    else {
        ok(0, "the tick stamps warm_last_at");
        ok(0, "it is NOT inside an onDone callback — a failed chain still counts as today's warm");
        ok(0, "it is stamped after the sweeps, at the bottom of the sub");
    }
}

printf "\nRESULT: %d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
