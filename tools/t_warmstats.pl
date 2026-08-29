#!/usr/bin/env perl
#
# t_warmstats.pl — the warm-stage instrument gets its own assertion.
#
#   perl tools/t_warmstats.pl
#
# WHY THIS EXISTS. `cachestats` spent most of a day reading as evidence about the
# store when it was only evidence about the schema — it counted a column nothing
# wrote, so the figure was 0 by construction. The rule that came out of that is
# in CLAUDE.md: AN INSTRUMENT GETS ITS OWN ASSERTION, OR IT IS DECORATIVE. This
# is that assertion for the warm-stage timing added alongside ["lbf","warmstats"].
#
# There are two independent ways this instrument can be worthless, and they need
# separate tests because either one alone passes while the other fails:
#
#   A. the recorder is wrong  — it records, but the table it produces misstates
#      what happened (the overlap collapses, a running stage reports nothing, the
#      order is lost). Sections 1-4 drive the REAL subs out of Plugin.pm.
#   B. the recorder is never called — it is perfect and no warm stage marks
#      anything, so every report is empty and reads as "the warm did nothing".
#      Section 5 asserts on the CALL SITES in Browse.pm, which is crude, but there
#      is no return value to inspect when the point is that a sub WAS reached.
#      (Same argument as t_tokenfree.pl section 4.)
#
# THE CENTRAL CLAIM being pinned is section 3: absolute start/end marks, not
# elapsed times. The question the whole measurement exists to answer is "what was
# running at the same time as what" — `_warmTick` calls warmFeeds and warmCache
# back to back without waiting, warmFeeds fires three fetches at once, and
# warmCache starts the genre ladder alongside the playlist resolves. A table of
# durations alone cannot tell "the genre ladder is slow" from "the genre ladder is
# starving the feeds". If a future change reduces this to elapsed-only, section 3
# must go red.
#
# ANTI-TEST (do this after touching it), via LBF_PLUGIN= / LBF_BROWSE= pointed at
# a mutated copy. All five were run and all five go red in the right place:
#   1. warmStages zeroes start/end, reporting elapsed only     -> 3 red (section 3)
#   2. stageStart clobbers @WARM_ORDER instead of appending    -> 8 red (sections 3,4)
#   3. the _stage marks are deleted from warmFeeds             -> 3 red (section 5)
#   4. _stage loses its eval guard                             -> 1 red (section 5)
#   5. trending_month/_year collapse to one shared stage name  -> 1 red (section 5)
#
# MUTATION 3 IS WHY THE ANTI-TEST RUN IS NOT OPTIONAL. Section 5's first cut
# accepted `_stage('end', $_, ...)` — the bulk-skip form — as an alternative to
# the literal stage name. That alternative matches for EVERY stage as soon as one
# bulk call exists anywhere in the file, so the name was never checked and
# deleting all three feed marks left the section fully green. The baseline was
# green and meaningless for thirteen assertions. Same family as the 0.9.160 and
# 0.9.149 traps: a green suite is evidence only once a mutation has moved it.
#
# Exit 0 = the instrument measures what it claims to. Exit 1 = it does not.

use strict;
use warnings;
use File::Spec;
use Time::HiRes ();

my $ROOT = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
# Overridable so the suite can be ANTI-TESTED against a mutated copy.
my $PLUGIN = $ENV{LBF_PLUGIN} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Plugin.pm');
my $BROWSE = $ENV{LBF_BROWSE} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $msg) = @_;
    # The 0.9.160 trap: a bare m// or grep in this LIST-context slot returns the
    # match LIST, the args shift, and the message becomes the condition — the
    # assertion then passes against any truthy string. Die rather than print a
    # blank label, so a recurrence is loud.
    die "t_warmstats: assertion called with no message — a bare m// or grep has\n"
      . "shifted the arguments. Wrap the condition in scalar().\n"
        unless defined $msg && length $msg;
    if ($cond) { $pass++; printf "  ok   %s\n", $msg }
    else       { $fail++; printf "  FAIL %s\n", $msg }
    return $cond ? 1 : 0;
}
sub section { printf "\n%s\n%s\n", $_[0], '-' x 74 }

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}

# Brace-matched verbatim extraction of a named sub (the bench_walk.pl trick), so
# the assertions track SHIPPED code rather than a paraphrase of it.
sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name in source\n";
    my $start = $-[0];
    my $i     = pos($src);
    my $depth = 1;
    while ($i < length($src) && $depth) {
        my $c = substr($src, $i++, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
    }
    pos($src) = undef;
    return substr($src, $start, $i - $start) . "\n";
}

my $psrc = slurp($PLUGIN);
my $bsrc = slurp($BROWSE);

# ---------------------------------------------------------------------------
# Build a harness package holding the REAL recorder.
#
# The four subs close over package lexicals, so they are compiled together with
# those declarations inside ONE eval — a sub grabbed on its own would not see
# them. The declarations are restated here (they are four `my` lines, not logic);
# everything with behaviour in it is lifted verbatim.
# ---------------------------------------------------------------------------
my $harness = join('',
    "package T::Warm;\n",
    "use strict; use warnings; use Time::HiRes ();\n",
    "my %WARM_STAGE; my \@WARM_ORDER; my \$WARM_TICK_AT; my \$WARM_TICK_N = 0;\n",
    map { grab($psrc, $_) } qw(stageStart stageEnd stageReset warmStages),
);
eval $harness;
die "harness failed to compile: $@" if $@;

# ---------------------------------------------------------------------------
section('1. BEFORE ANY TICK — empty, but answering');
# "The tick has not fired yet" is a real and common answer (a restart, a library
# scan deferring the warm), and it is the one worth distinguishing from "the tick
# fired and recorded nothing". A report that refused to answer in that state, or
# that looked identical to a recorded-nothing tick, would hide the case.
{
    my $r = T::Warm::warmStages();
    ok(ref $r eq 'HASH',                    'warmStages returns a hashref before any tick');
    ok(scalar($r->{ticks} == 0),            'ticks is 0 before the first stageReset');
    ok(ref $r->{stages} eq 'ARRAY',         'stages is an arrayref, not undef');
    ok(scalar(@{ $r->{stages} } == 0),      'stages is empty before any tick');
}

# ---------------------------------------------------------------------------
section('2. A COMPLETED STAGE — outcome and note survive');
{
    T::Warm::stageReset();
    T::Warm::stageStart('all_feed');
    select(undef, undef, undef, 0.05);
    T::Warm::stageEnd('all_feed', 'done', '3255 releases');

    my $r = T::Warm::warmStages();
    ok(scalar($r->{ticks} == 1),            'stageReset counts the tick');
    ok(scalar($r->{tick_at} > 0),           'tick_at is stamped by stageReset');
    ok(scalar(@{ $r->{stages} } == 1),      'one stage recorded');

    my $s = $r->{stages}[0];
    ok(scalar($s->{name}    eq 'all_feed'),        'name recorded');
    ok(scalar($s->{outcome} eq 'done'),            'outcome recorded');
    ok(scalar($s->{note}    eq '3255 releases'),   'note recorded — the count is the evidence');
    ok(scalar($s->{elapsed} >= 0.04),              'elapsed reflects real wall-clock time');
    ok(scalar($s->{elapsed} <  5),                 'elapsed is a duration, not an epoch');
}

# ---------------------------------------------------------------------------
section('3. OVERLAP IS PRESERVED — the whole point of the measurement');
# Two stages that ran CONCURRENTLY must be visibly concurrent in the table. If
# this collapses to elapsed-only, the report can no longer distinguish a slow
# stage from a stage that was being starved by another — which is the actual
# question being asked of the warm.
{
    T::Warm::stageReset();
    T::Warm::stageStart('genres_foryou');   # starts first
    select(undef, undef, undef, 0.02);
    T::Warm::stageStart('playlists');       # starts while genres is still open
    select(undef, undef, undef, 0.02);
    T::Warm::stageEnd('genres_foryou', 'done', '');
    select(undef, undef, undef, 0.02);
    T::Warm::stageEnd('playlists', 'done', '');

    my $r = T::Warm::warmStages();
    my %by = map { $_->{name} => $_ } @{ $r->{stages} };

    ok(scalar(exists $by{genres_foryou} && exists $by{playlists}),
       'both concurrent stages are in the table');
    ok(scalar($by{genres_foryou}{start} > 0 && $by{genres_foryou}{end} > 0),
       'absolute start AND end are both recorded, not just a duration');
    # The overlap test itself: playlists began BEFORE genres finished.
    ok(scalar($by{playlists}{start} < $by{genres_foryou}{end}),
       'the table shows playlists starting before genres_foryou ended (OVERLAP VISIBLE)');
    ok(scalar($by{playlists}{start} > $by{genres_foryou}{start}),
       'and shows which of the two started first');
}

# ---------------------------------------------------------------------------
section('4. THE THREE STATES A STAGE CAN BE IN');
{
    T::Warm::stageReset();
    T::Warm::stageStart('trending_tracks');             # running, never ended
    T::Warm::stageEnd('follow_feed', 'skipped', 'no token');  # ended, never started
    T::Warm::stageStart('all_feed');
    T::Warm::stageEnd('all_feed', 'done', 'x');         # normal

    my $r  = T::Warm::warmStages();
    my %by = map { $_->{name} => $_ } @{ $r->{stages} };

    # A stage still running when the report is read: elapsed SO FAR, which is what
    # is wanted when the table is fetched mid-tick — and it is how a hung follower
    # build will show up, which is the thing being hunted.
    ok(scalar($by{trending_tracks}{outcome} eq 'running'), 'an unfinished stage reads as running');
    ok(scalar($by{trending_tracks}{elapsed} >= 0),         'a running stage reports elapsed so far');
    ok(scalar($by{trending_tracks}{end} == 0),             'a running stage has no end mark');

    # A stage skipped before it began still records. Silently omitting it would
    # read as a stage that never ran at all, which is a different diagnosis.
    ok(scalar($by{follow_feed}{outcome} eq 'skipped'),  'a never-started stage still records');
    ok(scalar($by{follow_feed}{note} eq 'no token'),    'and says WHY it was skipped');
    ok(scalar($by{follow_feed}{elapsed} == 0),          'a never-started stage reports 0, not a negative');

    # Order is START order, so the table reads as a timeline.
    my @names = map { $_->{name} } @{ $r->{stages} };
    ok(scalar($names[0] eq 'trending_tracks'),  'rows are ordered by when they started');
    ok(scalar(@names == 3),                     'every stage appears exactly once');

    # A new tick must not inherit yesterday's rows.
    T::Warm::stageReset();
    ok(scalar(@{ T::Warm::warmStages()->{stages} } == 0), 'stageReset clears the previous tick');
}

# ---------------------------------------------------------------------------
section('5. THE RECORDER IS ACTUALLY CALLED — a perfect unused instrument is decorative');
# Source-level on purpose: there is no return value to inspect when the claim is
# that a sub was REACHED. This is the half that catches "the warm was refactored
# and the marks were dropped", which no amount of testing the recorder can see.
{
    ok(scalar($bsrc =~ /^sub _stage \{/m), 'Browse.pm defines the _stage shim');
    # The shim must be eval-guarded: these marks sit inside async HTTP callbacks,
    # where a die reaches no caller's eval and simply abandons the rest of the
    # chain. An instrument must not be able to break the thing it measures.
    my $shim = grab($bsrc, '_stage');
    ok(scalar($shim =~ /eval \{/), '_stage is eval-guarded (a die inside an async callback is unrecoverable)');
    ok(scalar($shim !~ /\bdie\b/), '_stage cannot itself raise');

    # Every stage the report is expected to carry must be marked somewhere.
    for my $stage (qw(all_feed foryou_feed muspy_feed covers
                      genres_foryou genres_all genres_lastfm_foryou genres_lastfm_all
                      playlists follow_feed
                      trending_tracks trending_month trending_year)) {
        # THE NAME ITSELF MUST APPEAR. The first cut of this assertion allowed
        # `_stage('end', $_, ...)` (the bulk-skip form) as an alternative to the
        # literal name — which matches for EVERY stage as soon as one bulk call
        # exists anywhere in the file, so the name was never actually checked.
        # The anti-test run is what exposed it: deleting all three feed marks left
        # this section fully green. Two SPECIFIC contexts only, both naming the
        # stage: a direct call, or a qw() list handed to a bulk call.
        ok(scalar($bsrc =~ /_stage\(\s*'(?:start|end)'\s*,\s*'\Q$stage\E'/)
           || scalar($bsrc =~ /\bqw\([^)]*\b\Q$stage\E\b[^)]*\)/),
           "stage '$stage' is marked in Browse.pm");
    }

    # ...AND THE REVERSE, which is the direction that actually failed (0.9.185).
    # The loop above asks "is every stage I expect marked?" — it cannot see a mark
    # for a stage that does not exist. `warmCache`'s no-username skip list named
    # `genres_lastfm`, a name recorded NOWHERE else (the real ones are
    # genres_lastfm_all and genres_lastfm_foryou), and because stageEnd creates a
    # row for any name it is handed — deliberately, so "skipped before it began"
    # is visible — the report for an account-less user carried a phantom line and
    # no line for either real Last.fm stage. Instrumentation only, but this is the
    # instrument the warm-ordering work is judged on, so a misreading instrument
    # is the whole cost.
    #
    # Derived from the source both ways rather than from a list restated here: a
    # hand-kept list of valid names is the same class of thing that produced the
    # phantom.
    my %started = map { $_ => 1 } $bsrc =~ /_stage\('start',\s*'([a-z_]+)'/g;
    my %ended   = map { $_ => 1 } $bsrc =~ /_stage\('end',\s*'([a-z_]+)'/g;
    # The bulk form: `_stage('end', $_, ...) for qw(a b c);`. [^;] keeps the match
    # inside one statement so it cannot reach a later call's qw() list.
    $ended{$_} = 1 for map { split ' ' } $bsrc =~ /_stage\('end',\s*\$_[^;]*?for\s+qw\(([^)]*)\)/gs;

    my @phantom = sort grep { !$started{$_} } keys %ended;
    ok(scalar(!@phantom),
       'every stage NAME that is ended is a stage that is also started'
         . (@phantom ? " — phantom: @phantom" : ''));
    # The mirror hazard: a stage started and never ended reads as 'running' for
    # ever in the report, which looks like a hang rather than a missing mark.
    my @orphan = sort grep { !$ended{$_} } keys %started;
    ok(scalar(!@orphan),
       '...and every stage that is started is ended on some path'
         . (@orphan ? " — never ended: @orphan" : ''));

    # Each of the three concurrently-started follower builds needs its OWN name.
    # One shared name would overwrite, and the measurement that matters most here
    # is precisely whether those three overlap.
    ok(scalar($bsrc =~ /_stage\('start', 'trending_month'\)/ && $bsrc =~ /_stage\('start', 'trending_year'\)/),
       'trending_month and trending_year are separate stages, not one shared name');
    # Same for the Last.fm rung, which runs once for For You and once for All.
    ok(scalar($bsrc =~ /genres_lastfm_foryou/ && $bsrc =~ /genres_lastfm_all/),
       'the Last.fm rung is two stages — it runs twice, and one name would overwrite');

    # The tick must reset, or every report shows an ever-growing merge of ticks.
    ok(scalar($psrc =~ /stageReset\(\)/), 'Plugin.pm resets the table on a tick');
    # ...but AFTER the scan-defer check: a deferred tick has not begun, and
    # resetting there shows an empty table for as long as the scan runs.
    my $tick = grab($psrc, '_warmTick');
    ok(scalar($tick =~ /stillScanning.*?stageReset\(\)/s),
       'the reset happens after the scan-defer check, not before it');

    # And the CLI surface has to exist, or none of this is readable off-network.
    ok(scalar($psrc =~ /\['lbf',\s*'warmstats'\]/), '["lbf","warmstats"] dispatch is registered');
    ok(scalar($psrc =~ /^sub _cliWarmStats \{/m),   'its handler is defined');
    my $cli = grab($psrc, '_cliWarmStats');
    ok(scalar($cli =~ /setStatusDone/),             'the handler completes the request');
    ok(scalar($cli =~ /\bat\b/ && $cli =~ /\buntil\b/),
       'the CLI emits start AND end offsets, so the overlap survives to the reader');
}

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
