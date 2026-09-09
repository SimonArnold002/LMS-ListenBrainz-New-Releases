package Plugins::ListenBrainzFreshReleases::DetailWarm;

use strict;
use warnings;
use Time::HiRes ();
use Slim::Utils::Timers;

# The feed store is the durable work inventory; the normal detail caches are
# its checkpoints. Rebuilding this queue after restart does not re-fetch a warm
# result. No second cache or completion marker can outlive the data it describes.
sub new {
    my ($class, %args) = @_;
    return bless { %args, jobs => {}, order => [], sequence => 0, active => 0,
                   completed => 0, deferred => 0, failed => 0,
                   cache_checks => 0, cache_hits => 0, fetches => 0 }, $class;
}

sub enqueue {
    my ($self, $rows, $priority, $focus) = @_;
    if ($focus) { delete $_->{focus} for values %{ $self->{jobs} } }
    my $rank = 0;
    for my $rel (@$rows) {
        my $key = $self->{key}->($rel);
        next unless defined $key && length $key;
        my $job = $self->{jobs}{$key};
        unless ($job) {
            $job = $self->{jobs}{$key} = { key => $key, priority => $priority,
                seq => ++$self->{sequence}, at => 0 };
            push @{ $self->{order} }, $key;
        }
        $job->{rel} = $rel;
        $job->{sources}{$priority} = 1;
        $job->{seen} = Time::HiRes::time();
        $job->{priority} = $priority if $priority < $job->{priority};
        $job->{focus} = $rank++ if $focus;
    }
    my $jobs = $self->{jobs};
    @{ $self->{order} } = sort {
        (defined $jobs->{$a}{focus} ? 0 : 1) <=> (defined $jobs->{$b}{focus} ? 0 : 1)
        || (($jobs->{$a}{focus} // 0) <=> ($jobs->{$b}{focus} // 0))
        || $jobs->{$a}{priority} <=> $jobs->{$b}{priority}
        || $jobs->{$a}{seq} <=> $jobs->{$b}{seq}
    } @{ $self->{order} };
    $self->_arm(0);
}

sub stats {
    my $self = shift;
    return { pending => scalar(keys %{ $self->{jobs} }),
             map { $_ => $self->{$_} }
                 qw(active completed deferred failed cache_checks cache_hits fetches) };
}

# Readiness probe retained for diagnostics/tests. Phase ownership lives in the
# caller: general detail work now follows Last.fm rather than pre-empting it.
sub busy {
    my $self = shift;
    return 1 if $self->{active};
    my $now = Time::HiRes::time();
    return scalar grep { $_->{at} <= $now } values %{ $self->{jobs} };
}

sub _arm {
    my ($self, $delay) = @_;
    my $when = Time::HiRes::time() + $delay;
    return if $self->{timer} && $self->{when} <= $when;
    Slim::Utils::Timers::killSpecific($self->{timer}) if $self->{timer};
    $self->{when} = $when;
    $self->{timer} = Slim::Utils::Timers::setTimer(undef, $when, sub {
        delete $self->{timer};
        $self->_tick();
    });
}

sub _tick {
    my $self = shift;
    return if $self->{active} || !@{ $self->{order} };
    if ($self->{pause}->()) { $self->_arm(5); return }
    my $now = Time::HiRes::time();
    my ($key, $soon);
    # Future retries cannot block ready work behind them.
    for my $i (0 .. $#{ $self->{order} }) {
        my $candidate = $self->{order}[$i];
        my $at = $self->{jobs}{$candidate}{at};
        if ($at <= $now) { ($key) = splice @{ $self->{order} }, $i, 1; last }
        $soon = $at if !defined $soon || $at < $soon;
    }
    unless (defined $key) { $self->_arm($soon - $now); return }
    my $job = $self->{jobs}{$key};
    if ($now - $job->{seen} > 2 * 86400) {
        delete $self->{jobs}{$key};
        $self->_arm(0);
        return;
    }
    $self->{active} = 1;
    my ($finished, $watchdog);
    my $done = sub {
        my ($retry, $note, $work) = @_;
        return if $finished++;
        Slim::Utils::Timers::killSpecific($watchdog) if $watchdog;
        $self->{active} = 0;
        if ($retry) {
            $job->{at} = Time::HiRes::time() + $retry;
            push @{ $self->{order} }, $key;
            $self->{deferred}++;
        }
        else {
            delete $self->{jobs}{$key};
            $self->{completed}++;
        }
        if (ref $work eq 'HASH') {
            $self->{cache_checks} += $work->{cache_checks} || 0;
            $self->{cache_hits}   += $work->{cache_hits}   || 0;
            $self->{fetches}      += $work->{fetches}      || 0;
        }
        $self->{log}->info("detail warm: $key " . ($note // ($retry ? 'deferred' : 'cached')));
        # Yield even on synchronous cache hits. One job per turn bounds SQLite
        # reads without imposing an artificial one-second gap on cache-only work.
        $self->_arm($retry ? 0 : 0.05);
    };
    $watchdog = Slim::Utils::Timers::setTimer(undef, $now + 120, sub {
        $self->{failed}++ unless $finished;
        $done->(300, 'callback timed out; retry queued');
    });
    eval { $self->{run}->($job->{rel}, $done, [keys %{ $job->{sources} }]); 1 } or do {
        $self->{failed}++;
        $done->(300, "worker error: $@");
    };
}

1;
