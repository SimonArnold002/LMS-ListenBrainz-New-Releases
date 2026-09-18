#!/usr/bin/env perl
#
# t_ingestchunk.pl — the chunked feed ingest, and the safety property it trades on.
#
#   perl tools/t_ingestchunk.pl
#
# WHY. Field report 2026-08-22: players dropping off when opening All Releases, and
# lazily-loaded artwork not populating until a revisit. Both are one blocked event
# loop — LMS streams audio AND serves the image proxy from the same loop that runs
# the feed's HTTP callback, and `ingestFeed` was issuing ~16,000 statements there
# in ONE transaction (measured 185ms on a dev Mac -> ~1.85s on the target Pi).
#
# The regression is exact and it is this sub: before the caching rework a feed was
# stored by TWO `$cache->set` calls. The store replaced that with a per-release
# upsert loop.
#
# The fix chunks the row work into separate transactions with a yield between, and
# THAT GIVES UP ATOMICITY. What this suite exists to pin is that the trade is the
# safe one — not that chunking happens, which is trivially visible in the source:
#
#   1. A chunked pass and a synchronous pass produce an IDENTICAL store. Same rows,
#      same members, same coverage, same generation. If chunking changed the
#      outcome it would not be an optimisation.
#   2. ROTATION AND COVERAGE ONLY EVER RUN ON A COMPLETE PASS. This is the whole
#      safety argument. A partial pass must not delete rows it merely did not reach
#      (rule 1, "an empty result is never a fact", arriving from a third direction)
#      and must not stamp `ok_at`, or a half-written feed would read as fresh and
#      never be revalidated.
#   3. The merge rule still holds across a chunk boundary — an incoming empty field
#      must not blank a stored one just because the two rows landed in different
#      transactions.
#   4. The refusal verdict is still SYNCHRONOUS, because both call sites read it
#      immediately to decide whether to serve the payload or the stored copy.
#
# Real DBD::SQLite against a real file, the real DB.pm. Timers are stubbed with a
# driveable queue so the async path can be stepped deterministically.
#
# ANTI-TEST (via LBF_DB= at a mutated copy). Both were run and both go red on the
# safety property itself, which is the only thing worth pinning here:
#
#   A. a failed chunk falls through to the finish step   -> 3 red (section 4)
#      `unless ($doRows->(...) || 1)`. The damage is worth seeing: the feed went
#      60 members -> 25, i.e. THIRTY-FIVE ROWS DELETED merely because the pass
#      never reached them, and `ok_at` stamped fresh on top so nothing would ever
#      revalidate and put them back.
#   B. rotation + coverage run after EVERY chunk         -> 6 red (sections 1,3,4)
#      `$finish->()` inside the pump. Mid-pass the store is already rotated and
#      already stamped, so a reader sees a feed that claims to be complete.
#
# AND THE FIRST CUT OF SECTION 4 CAUGHT NEITHER. It broke the store with a
# DROP TABLE to make a chunk fail, which breaks the finish step too — so mutant A
# produced an unstamped feed for the wrong reason and the section passed against
# it. A test of "X is skipped on failure" is vacuous unless X would otherwise have
# SUCCEEDED. The coderef-in-a-release trick gives exactly that: one chunk dies in
# Storable, the store stays perfectly usable.
#
# Exit 0 = the trade is safe. Exit 1 = it is not.
use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);

my $DB = $ENV{LBF_DB} || File::Spec->catfile($FindBin::Bin, File::Spec->updir,
                                             'ListenBrainzFreshReleases', 'DB.pm');
my $NS = 'Plugins::ListenBrainzFreshReleases::DB';

# ---------------------------------------------------------------------------
# Stubs. Timers get a DRIVEABLE queue rather than a real scheduler, so the chunk
# pump can be stepped one chunk at a time and the store inspected BETWEEN chunks —
# which is the only way to test the partial-pass property at all.
# ---------------------------------------------------------------------------
BEGIN { $INC{'Slim/Utils/Log.pm'} = $INC{'Slim/Utils/Prefs.pm'}
      = $INC{'Slim/Utils/Timers.pm'} = __FILE__ }
{
    package Slim::Utils::Log;   use Exporter 'import'; our @EXPORT = qw(logger);
                                sub addLogCategory {} sub logger { bless {}, 'T::Log' }
    package T::Log;             our @ERRORED; our $AUTOLOAD; sub AUTOLOAD {}
                                sub warn {1} sub error { push @ERRORED, $_[1]; 1 }
                                sub is_debug {0} sub is_info {0}
    package Slim::Utils::Prefs; use Exporter 'import'; our @EXPORT = qw(preferences);
                                our %P; sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;           sub get { $Slim::Utils::Prefs::P{$_[1]} }
                                sub set { $Slim::Utils::Prefs::P{$_[1]} = $_[2] }
    package Slim::Utils::Timers;
                                our @Q;
                                # LMS invokes the callback as $cb->($obj, @args) — the
                                # first setTimer argument is HANDED BACK, it is not
                                # dropped. The stub keeps $obj for that reason: an
                                # earlier version called $cb->(@args) and was green
                                # against a driver that read its self-reference from
                                # the wrong slot, which then stalled in the field.
                                sub setTimer { my ($obj, undef, $cb, @a) = @_; push @Q, [$cb, $obj, @a]; 1 }
                                sub killSpecific {1}
}
sub pending { scalar @Slim::Utils::Timers::Q }

# A driver that scheduled a non-coderef is the exact shape of the 0.9.176 stall:
# LMS dies inside its timer loop and the chain simply stops. Counting it instead of
# dying here keeps the assertions that follow reachable, so the suite reports a red
# line rather than aborting at exit 255 with no FAIL — which reads like a pass.
our $BROKEN_CHAIN = 0;
sub step1   {
    my $t = shift @Slim::Utils::Timers::Q or return 0;
    unless (ref $t->[0] eq 'CODE') { $BROKEN_CHAIN++; return 0 }
    $t->[0]->(@{$t}[1..$#$t]);
    1;
}
sub drain   { my $n = 0; $n++ while step1(); return $n }

my $DIR = tempdir(CLEANUP => 1);
$Slim::Utils::Prefs::P{cachedir} = $DIR;
do $DB or die "can't load $DB: " . ($@ || $!);

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $msg) = @_;
    die "t_ingestchunk: assertion called with no message — a bare m// or grep has\n"
      . "shifted the arguments. Wrap the condition in scalar().\n"
        unless defined $msg && length $msg;
    if ($cond) { $pass++; printf "  ok   %s\n", $msg }
    else       { $fail++; printf "  FAIL %s\n", $msg }
    return $cond ? 1 : 0;
}
sub is {
    my ($got, $want, $msg) = @_;
    $got = defined $got ? $got : '(undef)'; $want = defined $want ? $want : '(undef)';
    ok($got eq $want, "$msg  ->  '$got'" . ($got eq $want ? '' : "  (wanted '$want')"));
}
sub section { printf "\n%s\n%s\n", $_[0], '-' x 74 }

sub raw { $NS->can('dbh')->() }
sub rel {
    my ($i, %o) = @_;
    return {
        release_mbid       => sprintf('%08x-1111-2222-3333-444444444444', $i),
        release_group_mbid => sprintf('%08x-5555-6666-7777-888888888888', $i),
        release_name       => "Album $i",
        artist_credit_name => "Artist $i",
        release_date       => sprintf('2026-08-%02d', ($i % 28) + 1),
        caa_release_mbid   => $o{no_caa} ? '' : sprintf('%08x-dddd-eeee-ffff-000000000000', $i),
        %{ $o{extra} || {} },
    };
}
sub snapshot {
    my ($feed) = @_;
    my $h = raw();
    return {
        members  => $h->selectrow_array('SELECT COUNT(*) FROM feed_member WHERE feed = ?', undef, $feed) // 0,
        releases => $h->selectrow_array('SELECT COUNT(*) FROM release') // 0,
        days     => $h->selectrow_array('SELECT COUNT(*) FROM feed_day WHERE feed = ?', undef, $feed) // 0,
        meta     => [ $h->selectrow_array(
            'SELECT fetched_at, ok_at, generation, n_items FROM feed_meta WHERE feed = ?', undef, $feed) ],
    };
}

my ($FROM, $TO) = ('2026-08-01', '2026-08-28');
my @REL = map { rel($_) } 1 .. 60;

# ---------------------------------------------------------------------------
section '1. A CHUNKED PASS AND A SYNCHRONOUS PASS BUILD THE SAME STORE';
# If chunking changed the outcome it would not be an optimisation. Two feeds, same
# input, one ingested each way, compared field for field.
{
    $NS->can('ingestFeed')->('sync', [@REL], from => $FROM, to => $TO, now => 1000);
    my $sync = snapshot('sync');

    my $done;
    my $res = $NS->can('ingestFeed')->('chunked', [@REL], from => $FROM, to => $TO,
                                       now => 1000, chunk => 7,
                                       onDone => sub { $done = $_[0] });
    ok(scalar($res->{chunked}), 'a chunked call returns immediately, marked in progress');
    ok(scalar(!$done), 'and has NOT finished before the timers are driven');
    ok(scalar(pending() > 0), 'it scheduled a yield rather than running straight through');
    drain();
    # The driver must hand itself on through EVERY yield, not just the first. The
    # first turn runs inline and so works under either signature; only turn two
    # onwards comes back through the timer, which is why the 0.9.176 stall got past
    # a green suite and only showed up as a feed that never stamped its coverage.
    is($BROKEN_CHAIN, 0, 'every yield scheduled a real callback — the chain never broke');
    ok(scalar(defined $done), 'onDone fires once the pass completes');

    my $chunked = snapshot('chunked');
    is($chunked->{members}, $sync->{members}, 'same member count as the synchronous pass');
    is($chunked->{days},    $sync->{days},    'same day-coverage rows');
    is($chunked->{meta}[1], $sync->{meta}[1], 'same ok_at stamp');
    is($chunked->{meta}[2], $sync->{meta}[2], 'same generation');
    is($chunked->{meta}[3], $sync->{meta}[3], 'same n_items');
    is($done->{ok},      1,           'the result reports success');
    is($done->{stored},  scalar(@REL),'and the full stored count');
}

# ---------------------------------------------------------------------------
section '2. IT ACTUALLY YIELDS — one transaction per chunk, not one per pass';
{
    $Slim::Utils::Timers::Q = [];
    my $done;
    $NS->can('ingestFeed')->('yield', [@REL], from => $FROM, to => $TO,
                             now => 2000, chunk => 10, onDone => sub { $done = $_[0] });
    # 60 releases / 10 per chunk = 6 chunks, so 5 yields between them.
    my $steps = 0;
    $steps++ while step1();
    ok(scalar($steps >= 5), "the pass yielded between chunks ($steps yields for 60 rows at 10/chunk)");
    ok(scalar(defined $done && $done->{ok}), 'and still completed successfully');
}

# ---------------------------------------------------------------------------
section '3. ROTATION AND COVERAGE ONLY ON A COMPLETE PASS — the safety property';
# This is the whole argument for the trade. Mid-pass the store must show rows
# already committed, but MUST NOT show a refreshed ok_at and MUST NOT have deleted
# anything — otherwise a half-written feed reads as fresh, or a row is dropped
# merely because the pass had not reached it yet.
{
    # Seed a feed, then re-ingest a SMALLER set: rotation should drop the absentees,
    # but only at the very end.
    $NS->can('ingestFeed')->('rot', [@REL], from => $FROM, to => $TO, now => 3000);
    my $before = snapshot('rot');
    is($before->{members}, 60, 'seeded with 60 members');

    $Slim::Utils::Timers::Q = [];
    my $done;
    my @half = @REL[0 .. 29];      # 30 of the 60 — the rest must rotate out
    $NS->can('ingestFeed')->('rot', [@half], from => $FROM, to => $TO,
                             now => 4000, chunk => 5, onDone => sub { $done = $_[0] });

    # Step ONE chunk only, then look at the store mid-pass.
    step1();
    my $mid = snapshot('rot');
    ok(scalar($mid->{members} == 60),
       'MID-PASS: nothing has been deleted yet (rotation has not run)');
    is($mid->{meta}[1], $before->{meta}[1],
       'MID-PASS: ok_at is UNCHANGED, so the feed still reads as stale/revalidating');

    drain();
    my $after = snapshot('rot');
    ok(scalar($after->{members} == 30), 'AFTER: rotation ran once, dropping the absentees');
    ok(scalar($after->{meta}[1] == 4000), 'AFTER: ok_at is stamped only now');
    ok(scalar($done && $done->{removed} == 30), 'and the result reports what it removed');
}

# ---------------------------------------------------------------------------
section '4. AN ABANDONED PASS LEAVES THE FEED STALE, NEVER FRESH-BUT-PARTIAL';
# A chunk that fails must stop the pass WITHOUT running rotation or stamping
# coverage. Rows already committed are merged, never half-written, so keeping them
# is safe; what must not happen is the feed looking complete.
#
# THE FAILURE HAS TO BE ISOLATED TO THE CHUNK, and getting that wrong is why the
# first cut of this section proved nothing. It broke the store (DROP TABLE), which
# breaks the FINISH step too — so a mutant that ignored chunk failures still
# produced an unstamped feed, and the section passed against it. A coderef in a
# release makes Storable::nfreeze die inside `_freeze` (which is deliberately
# unguarded), killing exactly one chunk and leaving the store perfectly usable, so
# the finish step WOULD succeed if it were wrongly reached.
{
    $NS->can('ingestFeed')->('abort', [@REL], from => $FROM, to => $TO, now => 5000);
    my $before = snapshot('abort');
    is($before->{members}, 60, 'seeded with 60 members');

    $Slim::Utils::Timers::Q = [];
    @T::Log::ERRORED = ();
    my $done;
    # 30 releases, one of which cannot be frozen; chunk 5 so it lands in chunk 3.
    my @half = @REL[0 .. 29];
    $half[12] = { %{ $half[12] }, poison => sub { 1 } };
    $NS->can('ingestFeed')->('abort', [@half], from => $FROM, to => $TO,
                             now => 6000, chunk => 5, onDone => sub { $done = $_[0] });
    drain();

    ok(scalar(defined $done),        'onDone still fires when a chunk fails');
    ok(scalar(!$done->{ok}),         'the result does NOT report success');
    ok(scalar(@T::Log::ERRORED > 0), 'and the failure is logged, not swallowed');

    my $after = snapshot('abort');
    # The two properties that make the trade safe. Both are reachable here because
    # the store itself is fine — only the pass was abandoned.
    is($after->{meta}[1], $before->{meta}[1],
       'ok_at was NOT advanced, so the next open revalidates');
    is($after->{members}, $before->{members},
       'ROTATION NEVER RAN: no row was deleted merely for not being reached');
}

section '5. THE MERGE RULE SURVIVES A CHUNK BOUNDARY';
# "UPSERT MERGES, IT NEVER BLANKS" (rule 3) was written for one transaction. A row
# whose update lands in a different transaction from its insert must behave the same.
{
    $NS->can('ingestFeed')->('merge', [ rel(1) ], from => $FROM, to => $TO, now => 7000);
    my ($caa0) = raw()->selectrow_array('SELECT caa_rel_mbid FROM release WHERE rel_id = ?',
                                        undef, $NS->can('relId')->(rel(1)));
    ok(scalar(length $caa0), 'the seeded row has cover art recorded');

    $Slim::Utils::Timers::Q = [];
    my $done;
    # Same release, now with NO caa, arriving in a multi-chunk pass.
    my @batch = (rel(2), rel(3), rel(1, no_caa => 1), rel(4));
    $NS->can('ingestFeed')->('merge', \@batch, from => $FROM, to => $TO,
                             now => 8000, chunk => 2, onDone => sub { $done = $_[0] });
    drain();

    my ($caa1) = raw()->selectrow_array('SELECT caa_rel_mbid FROM release WHERE rel_id = ?',
                                        undef, $NS->can('relId')->(rel(1)));
    is($caa1, $caa0, 'an incoming EMPTY field did not blank the stored one across a chunk');
    ok(scalar($done && $done->{ok}), 'and the pass completed');
}

# ---------------------------------------------------------------------------
section '6. THE REFUSAL VERDICT IS STILL SYNCHRONOUS';
# Both call sites read $res->{refused} immediately to decide whether to serve the
# payload or the stored copy. It is decided by a COUNT before any row work, so
# chunking must not have pushed it behind a callback.
{
    # Seed a feed of its OWN. Section 4 deliberately drops feed_member to simulate a
    # disk error, which empties every feed in the file — so reusing an earlier
    # feed's rows here would test nothing. (It didn't: the first cut of this section
    # did exactly that and both assertions failed for the wrong reason.)
    $NS->can('ingestFeed')->('refuse', [ rel(1), rel(2) ], from => $FROM, to => $TO, now => 8500);
    ok(scalar(snapshot('refuse')->{members} == 2), 'seeded a feed to refuse against');

    $Slim::Utils::Timers::Q = [];
    my $called = 0;
    my $res = $NS->can('ingestFeed')->('refuse', [], from => $FROM, to => $TO,
                                       now => 9000, chunk => 5,
                                       onDone => sub { $called++ });
    ok(scalar($res->{refused}), 'an empty ingest over a populated feed is refused SYNCHRONOUSLY');
    ok(scalar(!$res->{chunked}), 'a refusal never enters the chunked path');
    is(pending(), 0, 'and schedules no timers at all');

    my $s = snapshot('refuse');
    ok(scalar($s->{members} == 2), 'rule 1 holds: the refusal deleted nothing');
}

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
