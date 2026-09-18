#!/usr/bin/env perl
#
# t_singleflight.pl — the shared single-flight registry.
#
#   perl tools/t_singleflight.pl
#
# WHAT THIS PINS. This module replaces sixteen hand-rolled coalescing guards, and
# the reviews that produced it found the SAME four defects across them, one site
# at a time. Each is a section here, so the class cannot come back by being
# rewritten a seventeenth time:
#
#   1. Only the owner does the work; everyone else parks. (The point of the thing.)
#   2. The claim is released on SUCCESS and every waiter is answered.
#   3. The claim is released on FAILURE and every waiter is answered. Parking
#      callers and then answering only the owner turns a duplicate fetch into a
#      hung browse — strictly worse than the race it replaces.
#   4. A callback that NEVER ARRIVES is released by the watchdog, by answering the
#      waiters rather than merely dropping the key: a waiter freed without a
#      callback is still a browse that never renders.
#
# And the two that are properties of THIS design rather than fixes to the old one:
#
#   5. A dying waiter does not strand its neighbours, and the OWNER is a waiter
#      like any other — the asymmetry that stranded LBF 0.9.184 finding 3 is
#      absent by construction, so a die in the owner's callback must leave the
#      key free.
#   6. resolve/reject are idempotent, so an error path that a timeout can also
#      reach does not double-fire.
#
# Behavioural, not source-matching: "how many flights ran and who got called
# back" is not something a pattern match can show.
#
# ANTI-TEST (do this after changing the module — a green suite against a mutant
# proves nothing):
#   - make join() always return 1               -> section 1 red
#   - drop the `delete $self->{flights}{$key}`  -> sections 2/5 red
#   - skip the waiter loop in reject            -> section 3 red
#   - make the watchdog delete without landing  -> section 4 red
#   - remove the per-waiter eval                -> section 5 ABORTS (the waiter's
#       die propagates out of the suite itself, so this one shows as a crash and a
#       non-zero exit rather than a FAIL line — still red, just louder)
#
# Verified 2026-08-26: 4/4 mutants caught (2, 11, 1 failures and an abort).

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);

my $ROOT = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $msg) = @_;
    die "t_singleflight: assertion called with no message\n"
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
# A minimal LMS. Timers RECORD rather than fire — the watchdog IS a timer, so a
# no-op stub would make removing it invisible to this suite, which is exactly how
# a belt-and-braces guard rots. Section 4 fires it deliberately.
# ---------------------------------------------------------------------------
our @TIMERS;
our @LOGGED;

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
sub AUTOLOAD {
    my $n = our $AUTOLOAD; return if $n =~ /DESTROY/;
    $n =~ s/.*:://; push @main::LOGGED, { level => $n, msg => $_[1] // '' }; return 1;
}
package Slim::Utils::Log;
sub logger { bless {}, 'Slim::Utils::Log::Obj' }
sub addLogCategory { 1 }
1;
EOF

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
    @main::TIMERS = grep { $_->{id} != $id } @main::TIMERS;
    return 1;
}
sub killTimers { 1 }
1;
EOF

my $SF_SRC = $ENV{LBF_SINGLEFLIGHT}
          || "$ROOT/ListenBrainzFreshReleases/SingleFlight.pm";
system('mkdir', '-p', "$stub/Plugins/ListenBrainzFreshReleases") == 0 or die "mkdir: $?";
system('cp', $SF_SRC, "$stub/Plugins/ListenBrainzFreshReleases/SingleFlight.pm") == 0
    or die "cp $SF_SRC: $?";

unshift @INC, $stub;
require Plugins::ListenBrainzFreshReleases::SingleFlight;
my $CLASS = 'Plugins::ListenBrainzFreshReleases::SingleFlight';

sub fresh { @TIMERS = (); @LOGGED = (); return $CLASS->new(name => 'test', max => 30) }

# ---------------------------------------------------------------------------
section('1. Only the owner does the work; later callers park');
{
    my $sf = fresh();
    my (@answered, $owners);

    for my $i (1 .. 3) {
        my $own = $sf->join('k', onDone => sub { push @answered, "$i:$_[0]" });
        $owners++ if $own;
    }

    is($owners, 1, 'exactly one caller owns the flight');
    is($sf->_count, 1, 'one claim held while the flight is open');
    is(scalar @answered, 0, 'nobody is answered before the flight lands');
    ok($sf->inFlight('k'), 'inFlight reports the open flight');
    ok(!$sf->inFlight('other'), 'a different key is not in flight');

    # A DIFFERENT KEY IS A DIFFERENT FLIGHT — the property that makes the "fold the
    # sort and the headers into the key" rule enforceable rather than advisory.
    my $own2 = $sf->join('k2', onDone => sub { push @answered, "x:$_[0]" });
    is($own2, 1, 'a different key gets its own flight, not the first one');
}

# ---------------------------------------------------------------------------
section('2. Success releases the claim and answers everyone');
{
    my $sf = fresh();
    my @answered;
    $sf->join('k', onDone => sub { push @answered, "a:$_[0]" });
    $sf->join('k', onDone => sub { push @answered, "b:$_[0]" });
    $sf->join('k', onDone => sub { push @answered, "c:$_[0]" });

    $sf->resolve('k', 'RESULT');

    is(scalar @answered, 3, 'all three waiters answered (owner included)');
    is(join(',', @answered), 'a:RESULT,b:RESULT,c:RESULT', 'each got the same result');
    is($sf->_count, 0, 'the claim is released');
    is(scalar @TIMERS, 0, 'the watchdog was disarmed');

    # The key must be genuinely free, not merely emptied.
    is($sf->join('k', onDone => sub {}), 1, 'a later caller starts a NEW flight');
}

# ---------------------------------------------------------------------------
section('3. Failure releases the claim and answers everyone');
{
    my $sf = fresh();
    my (@done, @err);
    $sf->join('k', onDone => sub { push @done, 1 }, onError => sub { push @err, "a:$_[0]" });
    $sf->join('k', onDone => sub { push @done, 1 }, onError => sub { push @err, "b:$_[0]" });

    $sf->reject('k', 'BOOM');

    is(scalar @err,  2, 'both waiters got the error');
    is(scalar @done, 0, 'no waiter got a success as well');
    is(join(',', @err), 'a:BOOM,b:BOOM', 'every waiter got the SAME argument shape');
    is($sf->_count, 0, 'the claim is released on the failure path too');
}

# ---------------------------------------------------------------------------
section('4. A callback that never arrives is released by the watchdog');
{
    my $sf = fresh();
    my @err;
    $sf->join('k', onError => sub { push @err, $_[0] });
    $sf->join('k', onError => sub { push @err, $_[0] });

    is(scalar @TIMERS, 1, 'a watchdog is armed with the claim');
    ok($TIMERS[0]{when} > 0, 'the watchdog is armed for a real time');

    # The flight simply never lands — no resolve, no reject. Fire the timer.
    my $t = shift @TIMERS;
    $t->{cb}->($t->{obj}, @{ $t->{args} });

    is($sf->_count, 0, 'the watchdog released the stranded claim');
    is(scalar @err, 2, 'it released BY ANSWERING, not by dropping the key');
    ok(scalar(grep { $_->{level} eq 'error' } @LOGGED), 'the expiry is never silent');
}

# ---------------------------------------------------------------------------
section('5. A dying waiter strands nobody — including a dying OWNER');
{
    my $sf = fresh();
    my @answered;
    $sf->join('k', onDone => sub { die "owner blew up\n" });        # owner first
    $sf->join('k', onDone => sub { push @answered, 'b' });
    $sf->join('k', onDone => sub { die "and so did this one\n" });
    $sf->join('k', onDone => sub { push @answered, 'd' });

    $sf->resolve('k', 'R');

    is(join(',', @answered), 'b,d', 'the survivors still ran');
    is($sf->_count, 0, 'a die in the OWNER callback does not strand the claim');
    is($sf->join('k', onDone => sub {}), 1, 'the key is reusable afterwards');
    ok(scalar(grep { $_->{level} eq 'error' } @LOGGED), 'the deaths were logged');
}

# ---------------------------------------------------------------------------
section('6. Landing twice is a no-op, not a double-fire');
{
    my $sf = fresh();
    my @answered;
    $sf->join('k', onDone => sub { push @answered, 'd' }, onError => sub { push @answered, 'e' });

    is($sf->resolve('k', 'R'), 1, 'the first landing reports it did something');
    is($sf->resolve('k', 'R'), 0, 'a second resolve finds nothing to do');
    is($sf->reject('k', 'E'),  0, 'a reject after a resolve is a no-op');
    is(join(',', @answered), 'd', 'the waiter ran exactly once');
}

# ---------------------------------------------------------------------------
section('7. The callback-less claim (a warm pass, a cover queue)');
{
    my $sf = fresh();
    is($sf->join('cover'), 1, 'a bare claim with no callbacks is granted');
    is($sf->join('cover'), 0, 'a second caller is still refused');
    is(scalar @TIMERS, 1, 'a bare claim is watchdogged like any other');
    $sf->resolve('cover');
    is($sf->_count, 0, 'and released normally');

    # _reset is the test seam; prove it actually clears timers too, or a suite
    # that resets between sections leaks armed watchdogs into the next one.
    $sf->join('a'); $sf->join('b');
    $sf->_reset;
    is($sf->_count, 0, '_reset clears the registry');
    is(scalar @TIMERS, 0, '_reset disarms the watchdogs');
}

# ---------------------------------------------------------------------------
section('8. Two instances with the same key string do not collide');
{
    @TIMERS = ();
    my $a = $CLASS->new(name => 'bio',   max => 30);
    my $b = $CLASS->new(name => 'cover', max => 30);
    is($a->join('artist:1'), 1, 'instance A claims the key');
    is($b->join('artist:1'), 1, 'instance B claims the same key string independently');
    $a->resolve('artist:1');
    is($a->_count, 0, 'A released');
    is($b->_count, 1, 'B is untouched');
}

printf "\n%s\n%d passed, %d failed\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
