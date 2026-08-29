package Plugins::ListenBrainzFreshReleases::SingleFlight;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Timers;
use Time::HiRes ();

# ---------------------------------------------------------------------------
# SHARED ACROSS THE FLEET. Canonical copy lives in this repo; every other repo
# carries a byte-identical copy with only the `package` line changed, and
# tools/singleflight_sync_check.py is the enforcement. Same rule, and the same
# reasoning, as the matcher: a fix here lands in every copy in the SAME session.
#
# WHY THIS EXISTS AT ALL. THIRTEEN hand-rolled versions of this had grown across
# four plugins (counted 2026-08-26, excluding their timer companions, plain
# counters and memos):
#
#   LBF  %BUILDING  %INFLIGHT  %coverQueued  %sortInFlight  %agenInFlight
#   LL   %counting  %trackPending
#   PFR  %PENDING   %RESOLVING
#   DSC  %nameRefetched  %candWaiting  %bandsInFlight  %officialInFlight
#
# Every one of them coalesces duplicate async work behind one flight, and every
# one was written fresh, so each got a different subset of the four things that
# make it correct. The reviews then found the missing subset, one site at a time,
# for weeks -- the same defect reported as if it were a new one, in a different
# file each round. This module is those four things written once:
#
#   1. THE CLAIM IS RELEASED ON EVERY EXIT, not just the happy one. A claim that
#      outlives its flight is worse than no coalescing at all: every later caller
#      parks onto a list nothing will drain and returns WITHOUT RENDERING, for the
#      life of the process. The registry is in-process by design, so no TTL and no
#      cache expiry can clear it.
#   2. A WATCHDOG COVERS THE CASE NO EXIT PATH CAN. Belt is `resolve`/`reject`;
#      braces is the timer, for a callback that never arrives at all (a wedged
#      service, or a die inside an LMS timer callback -- which happens outside
#      any eval a call site could wrap).
#   3. THE CLAIM IS DROPPED BEFORE ANY WAITER RUNS. A waiter that re-enters the
#      same key must find it free and start a NEW flight, not adopt the corpse of
#      the one currently fanning out.
#   4. EACH WAITER IS EVAL'D SEPARATELY. Waiters are unrelated browse sessions
#      that merely asked the same question; one dying must not strand the rest.
#
# THE OWNER IS A WAITER TOO -- the one real design change from the %INFLIGHT
# original this was lifted from. There, the first caller's callback was held
# outside the waiter list and run BEFORE the claim was released, so a die in it
# stranded the key for ever (LBF 0.9.184 finding 3, and the same shape turned up
# in PFR's resolver and in LL's _learnTrackCount). Here `join` puts everyone in
# the same list and every callback runs after the claim is gone. The asymmetry
# that caused the bug is not fixed at each site; it is absent by construction.
# ---------------------------------------------------------------------------

# Registries are per-INSTANCE, not package globals, so two flights that happen to
# share a key string ('bio' in one subsystem, 'bio' in another) cannot collide.
sub new {
    my ($class, %p) = @_;
    return bless {
        name    => $p{name} || 'flight',
        # Comfortably clear of a legitimate run: long enough that a slow but live
        # flight is never cut off, short enough that a wedge self-heals inside one
        # browse session. Callers pass their own transport timeout * 3.
        max     => $p{max}  || 60,
        log     => $p{log}  || logger('plugin.listenbrainzfreshreleases'),
        flights => {},      # key => [ { onDone, onError }, ... ]
        timers  => {},      # key => timer handle
    }, $class;
}

# Join the flight for $key.
#
# Returns TRUE  -> this caller OWNS the flight and must do the work, then call
#                  resolve() or reject() exactly once, on every path.
# Returns FALSE -> a flight is already running; this caller has been parked and
#                  will be answered from it. The call site must return NOW,
#                  without starting any work of its own.
#
# THE KEY MUST DESCRIBE THE WORK THAT WILL ACTUALLY BE DONE, not just the
# subject of it. Two callers share a flight only if the request they would each
# have issued is identical -- fold in the sort, the window, the auth headers,
# anything that changes what comes back. Getting this wrong is silent and
# order-dependent: a caller holding a token parked behind an anonymous fetch
# gets an answer to a question it did not ask, and only in whichever browse
# happened to arrive second.
#
# onDone/onError are optional. Omit both for the plain "is this already running?"
# case (a warm pass, a cover queue) -- the claim, the release and the watchdog
# all still apply, there is simply nobody to answer.
sub join {
    my ($self, $key, %cb) = @_;
    $key = '' unless defined $key;

    if (my $waiters = $self->{flights}{$key}) {
        push @$waiters, { onDone => $cb{onDone}, onError => $cb{onError} }
            if $cb{onDone} || $cb{onError};
        $self->{log}->info(
            "$self->{name} '$key' already in flight -- waiting on it ("
            . scalar(@$waiters) . " waiting)");
        return 0;
    }

    $self->{flights}{$key} = [];
    push @{ $self->{flights}{$key} }, { onDone => $cb{onDone}, onError => $cb{onError} }
        if $cb{onDone} || $cb{onError};

    $self->_arm($key);
    return 1;
}

# Answer everyone parked behind $key with a success, exactly once.
sub resolve { my $self = shift; return $self->_land('onDone', @_) }

# Answer everyone parked behind $key with a failure, exactly once.
#
# A FAILURE MUST RELEASE THE WAITERS TOO. Parking them and then answering only
# the owner turns a duplicate fetch into a hung browse -- strictly worse than the
# race the coalescing replaces. Hand every waiter the SAME argument shape the
# owner would have got; a waiter handed a response object where its neighbour got
# a string is the kind of mismatch that only shows up in the second browse.
sub reject { my $self = shift; return $self->_land('onError', @_) }

# True while $key has a flight in progress. For call sites that want to report
# state ("still building...") rather than park on it.
sub inFlight { my ($self, $key) = @_; return exists $self->{flights}{ $key // '' } }

sub _arm {
    my ($self, $key) = @_;
    eval {
        Slim::Utils::Timers::killSpecific(delete $self->{timers}{$key})
            if $self->{timers}{$key};
        $self->{timers}{$key} = Slim::Utils::Timers::setTimer(
            undef, Time::HiRes::time() + $self->{max},
            sub {
                return unless $self->{flights}{$key};
                $self->{log}->error(
                    "$self->{name} '$key' claim expired after $self->{max}s without a "
                    . "result -- releasing " . scalar(@{ $self->{flights}{$key} })
                    . " waiter(s)");
                # RELEASE BY ANSWERING, never by merely dropping the key. A waiter
                # freed without a callback is still a browse that never renders,
                # which is the very thing this is here to prevent.
                $self->_land('onError', $key, "$self->{name} did not complete");
            });
        1;
    } or $self->{log}->warn("$self->{name} '$key' watchdog could not be armed: $@");
    return;
}

sub _land {
    my ($self, $which, $key, @args) = @_;
    $key = '' unless defined $key;

    eval {
        Slim::Utils::Timers::killSpecific(delete $self->{timers}{$key})
            if $self->{timers}{$key};
        1;
    };

    # DELETED BEFORE A SINGLE WAITER RUNS -- see (3) above. Also makes resolve()
    # and reject() idempotent: the second call finds nothing and returns quietly,
    # so a call site that cannot easily prove it answers once (an error path that
    # may also be reached by a timeout) is safe rather than double-firing.
    my $waiters = delete $self->{flights}{$key} or return 0;

    for my $w (@$waiters) {
        my $cb = $w->{$which};
        next unless ref $cb eq 'CODE';
        eval { $cb->(@args); 1 }
            or $self->{log}->error("$self->{name} waiter ($which) raised: $@");
    }
    return 1;
}

# --- test seams -------------------------------------------------------------
# Named to match the ones PFR's %RESOLVING already grew, so its tests port over
# unchanged. Counting is how a test proves a claim was released without reaching
# into the registry itself.
sub _count { my $self = shift; return scalar keys %{ $self->{flights} } }

sub _reset {
    my $self = shift;
    eval { Slim::Utils::Timers::killSpecific($_) for values %{ $self->{timers} }; 1 };
    $self->{flights} = {};
    $self->{timers}  = {};
    return;
}

1;
