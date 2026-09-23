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
    my $depth = 1;
    my $end   = length($src);
    # BRACE-SCAN BY REGEX, NOT substr()-PER-CHARACTER. The source is read with an
    # ':encoding(UTF-8)' layer, so it is a CHARACTER string — and substr() on one
    # is not O(1). The old per-character walk was therefore quadratic in file
    # size, and Browse.pm is half a megabyte: several suites had grown to spend
    # minutes here, which reads as a hang rather than as slowness. The //g picks
    # up from the header match's pos, which is exactly where the body starts.
    while ($src =~ /([{}])/g) {
        $1 eq '{' ? $depth++ : $depth--;
        next if $depth;
        $end = pos($src);
        last;
    }
    my $i = $end;
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
# THE STORE, stubbed: one hash shared by every harness package, because the point
# of section 6 is that a SECOND PROCESS (a restart) reads what the first one saved.
our %STORE; our @SETS;
{
    package Plugins::ListenBrainzFreshReleases::DB;
    sub store { return bless {}, 'T::Store' }
    sub kver  { return $_[0] . '1:' }
}
{
    package T::Store;
    sub set { my (undef, $k, $v, $ttl) = @_; push @main::SETS, [ $k, $ttl ]; $main::STORE{$k} = $v; 1 }
    sub get { my (undef, $k) = @_; return $main::STORE{$k} }
}
$INC{'Plugins/ListenBrainzFreshReleases/DB.pm'} = __FILE__;

my ($lastTtlLine) = $psrc =~ /^(use constant LAST_WARM_TTL\s*=>.*?;)$/m
    or die "no LAST_WARM_TTL in Plugin.pm\n";
# One harness per "process": each gets its own lexicals, as a restart does.
sub harness {
    my ($pkg) = @_;
    my $h = join('',
        "package $pkg;\n",
        "use strict; use warnings; use Time::HiRes ();\n",
        "my %WARM_STAGE; my \@WARM_ORDER; my \$WARM_TICK_AT; my \$WARM_TICK_N = 0;\n",
        "my %LAST_STAGE; my \@LAST_ORDER; my \$LAST_SEAL = 0;\n",
        "sub version { '9.9.9' }\n",
        "$lastTtlLine\n",
        # stageSeal only if the source has it, so the section-8 assertions can report
        # its absence as a FAIL instead of the harness dying before they run.
        map { grab($psrc, $_) }
            (qw(stageStart stageEnd stageReset _stageRows warmStages _noteLast _saveLastWarm lastWarm),
             grep { $psrc =~ /^sub \Q$_\E\b/m } qw(stageSeal)),
    );
    eval $h;
    die "harness $pkg failed to compile: $@" if $@;
}
harness('T::Warm');

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

    # THE SHIM PASSES THE TRANSIENT FLAG THROUGH (review of 1.0.19). Driven for real:
    # t_coverwarm.pl stubs _stage, so a shim that dropped the 5th argument would let
    # every browse overwrite the saved warm with every suite green — the anti-test
    # run found exactly that gap.
    {
        my @got;
        no warnings 'once';
        local *Plugins::ListenBrainzFreshReleases::Plugin::stageStart = sub { push @got, [ 'start', @_ ] };
        local *Plugins::ListenBrainzFreshReleases::Plugin::stageEnd   = sub { push @got, [ 'end',   @_ ] };
        eval "package T::Shim; $shim 1;" or die "shim failed to compile: $@";
        T::Shim::_stage('start', 'covers', undef, undef, 1);
        T::Shim::_stage('end',   'covers', 'done', 'n', 1);
        T::Shim::_stage('start', 'covers');
        ok(scalar(@got) == 3 && $got[0][2] && $got[1][4],
           '_stage passes the TRANSIENT flag through to stageStart and stageEnd');
        ok(scalar(@got) == 3 && !$got[2][2], '...and a plain call stays non-transient');
    }

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
    ok(scalar($bsrc =~ /_stage\('start', 'trending_month'[,)]/ && $bsrc =~ /_stage\('start', 'trending_year'[,)]/),
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

# ---------------------------------------------------------------------------
section('6. THE LAST SCHEDULED WARM SURVIVES A RESTART (1.0.18)');
# Simon's server stops every service for a 06:30 backup, so the 05:xx warm's table
# was gone by the time anyone read it (live 2026-09-22: ticks 0). The table is now
# also saved to the store — but ONLY by a process that ran a tick, so the restart's
# re-seed (which still marks `covers`) cannot overwrite the real warm.
{
    %STORE = (); @SETS = ();
    harness('T::P1');                  # the process that runs the 05:xx warm
    T::P1::stageStart('covers');       # a mark BEFORE any tick (a startup re-seed)
    T::P1::stageEnd('covers', 'done', 're-seed');
    ok(scalar(@SETS) == 0, 'a process that has run no tick saves nothing');

    T::P1::stageReset();
    T::P1::stageStart('all_feed');
    my $saved = T::P1::lastWarm();
    ok($saved && ($saved->{stages}[0]{outcome} // '') eq 'running',
       'a stage START is saved, so a warm cut off mid-stage shows it still running');
    T::P1::stageEnd('all_feed', 'done', '1776 releases');
    T::P1::stageStart('covers');
    T::P1::stageEnd('covers', 'done', '54 request(s)');
    $saved = T::P1::lastWarm();
    ok($saved && scalar(@{ $saved->{stages} }) == 2, 'every stage of the tick is saved');
    ok($saved && $saved->{stages}[0]{note} eq '1776 releases' && $saved->{stages}[1]{outcome} eq 'done',
       '...with its outcome and note');
    ok($saved && $saved->{tick_at} > 0 && $saved->{version} eq '9.9.9',
       '...and the tick time and the build that ran it');
    my ($k, $ttl) = @{ $SETS[-1] || [] };
    ok(($k // '') eq 'lbf:warmlast:1:tick', 'saved under the versioned lbf:warmlast: family');
    ok(($ttl // 0) == T::P1::LAST_WARM_TTL() && T::P1::LAST_WARM_TTL() > 86400,
       '...with a TTL longer than a day, so yesterday\'s warm is readable the next morning');

    # THE RESTART: a new process, fresh lexicals, same store.
    harness('T::P2');
    my $n = scalar @SETS;
    T::P2::stageStart('covers');
    T::P2::stageEnd('covers', 'done', '0 request(s), 1908 already warm');
    ok(scalar(@SETS) == $n, 'after a restart the re-seed marks do NOT overwrite the saved warm');
    my $after = T::P2::lastWarm();
    ok($after && scalar(@{ $after->{stages} }) == 2 && $after->{stages}[1]{note} eq '54 request(s)',
       '...and the restarted process reads the 05:xx warm back intact');
    ok(scalar(@{ T::P2::warmStages()->{stages} }) == 1,
       '...while its OWN table stays its own (the re-seed row only, never merged)');

    # The CLI has to report it, under names that cannot be read as the live table.
    my $cli = grab($psrc, '_cliWarmStats');
    ok(scalar($cli =~ /lastWarm\(\)/ && $cli =~ /last_stages_loop/ && $cli =~ /last_tick_at/),
       'warmstats reports the saved warm under its own last_ names');
    ok(scalar(grab($psrc, '_saveLastWarm') =~ /\beval\s*\{/),
       '_saveLastWarm is eval-guarded (its callers are inside async callbacks)');
}

# ---------------------------------------------------------------------------
section('7. A BROWSE AFTER THE TICK DOES NOT OVERWRITE THE SAVED WARM (review of 1.0.19)');
# The 1.0.19 review: a browse that queues a cold cover opens a NEW `covers` stage,
# and _saveLastWarm stored the whole live table — so a 06:10 browse replaced the
# 05:xx warm's cover numbers (and on a server with no daily restart, every browse
# did, all day). A browse-driven boundary is TRANSIENT: it shows in the live table
# and never reaches the saved warm. Nor may a LATER tick boundary carry the browse's
# row into the save with it.
{
    %STORE = (); @SETS = ();
    harness('T::P3');
    T::P3::stageReset();
    T::P3::stageStart('covers');
    T::P3::stageEnd('covers', 'done', '54 request(s) / 18 release(s)');
    T::P3::stageStart('genres_lastfm_all');                     # still running
    my $n = scalar @SETS;

    # The browse: a transient covers stage.
    T::P3::stageStart('covers', 1);
    T::P3::stageEnd('covers', 'done', '3 request(s) / 1 release(s)', 1);
    ok(scalar(@SETS) == $n, 'a TRANSIENT (browse) boundary writes nothing to the store');
    my $live = { map { $_->{name} => $_ } @{ T::P3::warmStages()->{stages} } };
    ok(scalar(($live->{covers}{note} // '') =~ /^3 request/),
       '...while the LIVE table still shows the browse (unchanged behaviour)');

    # A tick stage finishing AFTER the browse must not drag the browse's row in.
    T::P3::stageEnd('genres_lastfm_all', 'done', '68 requested');
    my $saved = { map { $_->{name} => $_ } @{ (T::P3::lastWarm() || {})->{stages} || [] } };
    ok(scalar(($saved->{covers}{note} // '') =~ /^54 request/),
       'the saved warm keeps the TICK\'s covers row after a later tick stage is saved');
    ok(($saved->{genres_lastfm_all}{outcome} // '') eq 'done',
       '...and still records the tick stage that finished after the browse');
    ok(scalar(keys %$saved) == 2, '...and nothing else');

    # A new tick starts a new saved table.
    T::P3::stageReset();
    T::P3::stageStart('all_feed');
    my $fresh = T::P3::lastWarm();
    ok($fresh && scalar(@{ $fresh->{stages} }) == 1 && $fresh->{stages}[0]{name} eq 'all_feed',
       'a new tick starts a new saved table (yesterday\'s rows do not carry over)');
}
# ...and the tick must clear the cover memo, or a cover memoised by an evening
# browse is skipped at 05:xx without asking the proxy (the second 1.0.19 finding).
{
    my $tick = grab($psrc, '_warmTick');
    ok(scalar($tick =~ /stageReset\(\);.*?coverMemoForget/s),
       '_warmTick clears the cover memo (Browse::coverMemoForget) after the reset');
    # ...and forgets yesterday's HELD MISSES, or the daily retry the hold's comment
    # promises never happens: the warm fires at the same instant each day and reaches a
    # held path earlier in the tick than the fetch that recorded it, so a 24h hold is
    # still standing and the retry lands on a browse walk instead (review of 1.0.23).
    ok(scalar($tick =~ /stageReset\(\);.*?coverMissForget/s),
       '...and the held-miss family (Browse::coverMissForget), so the warm retries them');
}

# ---------------------------------------------------------------------------
section('8. A MANUAL REFRESH DOES NOT OVERWRITE THE SAVED WARM (reviews of 1.0.20 and 1.0.21)');
# "Refresh playlist matches" runs warmCache(force => 1) OUTSIDE any tick
# (docs/scheduled-overnight-warm.md §3.3: a refresh is not a warm). 1.0.21 SEALED the
# save by time, and the review of 1.0.21 broke that: a refresh tapped WHILE the tick
# is still running restarts a stage the tick has open, the seal marked the entry late,
# and the tick's own end was then never saved — the row read `running` until the next
# day. Tick stages that first started after the seal were dropped too. Time cannot say
# whose boundary it is; the CALLER can. So a refresh's boundaries are TRANSIENT (like a
# browse's), and the saved warm is its OWN table, moved only by non-transient boundaries
# — it never copies the live entry a transient boundary may have replaced.
{
    %STORE = (); @SETS = ();
    harness('T::P4');
    T::P4::stageReset();                                       # 05:00, the tick
    T::P4::stageStart('playlists');
    T::P4::stageEnd('playlists', 'done', '4 playlist(s)');
    T::P4::stageStart('genres_lastfm_all');                    # the tick, still running
    T::P4::stageStart('trending_year');                        # the tick, still running
    my $tickStart = { map { $_->{name} => $_ } @{ T::P4::lastWarm()->{stages} } }->{trending_year}{start};
    select(undef, undef, undef, 0.03);
    # 05:02: the refresh, while the tick is still running. Every boundary transient.
    T::P4::stageStart('playlists', 1);
    T::P4::stageEnd('playlists', 'done', '4 playlist(s) (forced)', 1);
    T::P4::stageEnd('follow_feed', 'skipped', 'no token', 1);  # never started: refresh-only
    T::P4::stageStart('trending_year', 1);                     # re-runs a stage the TICK has open
    T::P4::stageEnd('trending_year', 'done', '9 album(s) (refresh)', 1);
    # ...and the tick carries on.
    T::P4::stageEnd('trending_year', 'done', '8 album(s)');    # the tick's own end
    T::P4::stageStart('trending_tracks');                      # a tick stage that STARTS after the refresh
    T::P4::stageEnd('trending_tracks', 'done', '50 tracks');
    T::P4::stageEnd('genres_lastfm_all', 'done', '68 requested');
    my $saved = { map { $_->{name} => $_ } @{ (T::P4::lastWarm() || {})->{stages} || [] } };
    ok(($saved->{playlists}{note} // '') eq '4 playlist(s)',
       'a stage the refresh re-runs keeps the TICK\'s row in the saved warm');
    ok(!exists $saved->{follow_feed}, 'a stage only the refresh recorded is not saved');
    ok(($saved->{trending_year}{outcome} // '') eq 'done' && ($saved->{trending_year}{note} // '') eq '8 album(s)',
       'a tick stage the refresh RESTARTED mid-run still has the tick\'s END saved (review of 1.0.21)');
    ok(abs(($saved->{trending_year}{start} // 0) - ($tickStart // -1)) < 1e-6,
       '...with the TICK\'s start, not the refresh\'s');
    ok(($saved->{trending_tracks}{note} // '') eq '50 tracks',
       'a tick stage that first starts after the refresh is saved (review of 1.0.21)');
    ok(($saved->{genres_lastfm_all}{outcome} // '') eq 'done',
       'a tick stage running through the refresh has its END saved');
    my $live = { map { $_->{name} => $_ } @{ T::P4::warmStages()->{stages} } };
    ok(($live->{playlists}{note} // '') eq '4 playlist(s) (forced)',
       '...while the LIVE table shows the refresh (unchanged behaviour)');

    # A refresh in a process that has run no tick saves nothing (the tick guard).
    harness('T::P5');
    my $n = scalar @SETS;
    T::P5::stageStart('playlists', 1);
    T::P5::stageEnd('playlists', 'done', 'x', 1);
    ok(scalar(@SETS) == $n, 'a refresh before any tick writes nothing');
}

# ---------------------------------------------------------------------------
section('9. EVERY NON-TICK CALLER MARKS ITS STAGES TRANSIENT (reviews of 1.0.20 and 1.0.21)');
# The recorder can only keep a boundary out of the save if the CALLER says whose it
# is. Two callers close tick stages from outside a tick: the manual refresh
# (warmCache(force => 1) and everything it reaches) and the What's Trending VIEW
# (_resolveTrending with a callback). 1.0.21's trace followed only warmCache/warmFeeds
# callers and missed the view, which closes `trending_tracks` directly. Source-level,
# because there is no return value to inspect: every _stage call in these subs must
# carry the transient argument.
{
    my %flag = (
        warmCache        => qr/\$transient/,
        _warmGenres      => qr/\$transient/,
        _warmFollow      => qr/\$transient/,
        _warmTrending    => qr/\$transient/,
        _resolveTrending => qr/\$transient/,
    );
    for my $sub (sort keys %flag) {
        my $body  = grab($bsrc, $sub);
        my @calls = $body =~ /(_stage\([^;]*?\)\s*(?:for\s+qw\([^)]*\))?;)/gs;
        my @bare  = grep { $_ !~ $flag{$sub} } @calls;
        ok(scalar(@calls) && !@bare,
           "$sub: every _stage call passes \$transient (" . scalar(@calls) . " call(s))"
             . (@bare ? " — bare: " . join(' | ', map { (my $c = $_) =~ s/\s+/ /g; $c } @bare) : ''));
    }
    my $wc = grab($bsrc, 'warmCache');
    ok(scalar($wc =~ /my \$transient\s*=\s*\$force/), 'warmCache: $transient is the refresh (force), never the tick');
    ok(scalar($wc =~ /_warmGenres\(\$transient\)/), 'warmCache hands $transient to _warmGenres');
    ok(scalar($wc =~ /_warmFollow\(\$client, \$force/ && $wc =~ /_warmTrending\(\$client, \$force/),
       'warmCache hands $force to _warmFollow and _warmTrending');
    ok(scalar(grab($bsrc, '_warmGenres') =~ /my \(\$transient\)\s*=\s*\@_/), '_warmGenres takes $transient');
    ok(scalar(grab($bsrc, '_warmFollow') =~ /my \$transient\s*=\s*\$force/), '_warmFollow derives $transient from $force');
    my $wt = grab($bsrc, '_warmTrending');
    ok(scalar($wt =~ /my \$transient\s*=\s*\$force/), '_warmTrending derives $transient from $force');
    ok(scalar($wt =~ /_warmTrendingCovers\([^)]*\$transient\)/), '_warmTrending hands $transient to its cover warm');
    ok(scalar(grab($bsrc, '_warmTrendingCovers') =~ /_warmCovers\([^)]*\$transient\)/),
       '_warmTrendingCovers passes it on to _warmCovers');
    my $rt = grab($bsrc, '_resolveTrending');
    ok(scalar($rt =~ /my \$transient\s*=\s*\(!\$warm \|\| \$force\)/),
       '_resolveTrending: the VIEW (a callback) or a refresh is transient; only the tick is not (review of 1.0.21)');
    my $tr = grab($bsrc, '_warmTrending');
    ok(scalar($tr =~ /_resolveTrending\([^)]*\$force/), '_warmTrending hands $force to _resolveTrending');
    ok(scalar($bsrc !~ /stageSeal/ && $psrc !~ /LAST_SEAL|stageSeal/),
       'the time-based seal is gone (it lost a tick stage restarted by a refresh)');
}

# ---------------------------------------------------------------------------
section('10. EVERY EXIT OF _resolveTrending CLOSES trending_tracks (review of 1.0.22)');
# The mirror of section 9, and a REGRESSION THE 1.0.22 FIX COULD INTRODUCE. The warm
# opens `trending_tracks` in _warmTrending and _resolveTrending closes it. Two exits
# never did: "a build is already in flight" and "no username". While the VIEW's close
# was non-transient that was invisible — the view eventually closed the row for the
# warm. Now the view's close is transient, so a tick taking one of those exits leaves
# the SAVED warm's row `running` for 24h: warmstats reports a warm that finished as cut
# off mid-stage, the exact false signal the save exists to prevent.
#
# The rule, not the two cases: each $finish->() must have a stage end between it and
# the previous exit. ($finish is the one thing every exit calls — it releases the
# in-flight flag, which t_buildingstate.pl pins.)
{
    my $b = grab($bsrc, '_resolveTrending');
    my @exits;
    my $prev = 0;
    while ($b =~ /\$finish->\(\)/g) {
        my $at = $-[0];
        push @exits, substr($b, $prev, $at - $prev);
        $prev = pos($b);
    }
    ok(scalar(@exits) >= 4, 'found the exits of _resolveTrending (' . scalar(@exits) . ')');
    my $n = 0;
    for my $seg (@exits) {
        $n++;
        my ($tail) = $seg =~ /([^\n]*\n[^\n]*)$/;
        $tail = ' ' . join(' ', split ' ', ($tail // ''));
        ok(scalar($seg =~ /_stage\('end', 'trending_tracks',[^;]*\$transient\)/s),
           "exit $n closes trending_tracks (with \$transient) before it finishes —$tail");
    }
}

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
