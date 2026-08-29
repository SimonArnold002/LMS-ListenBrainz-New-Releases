#!/usr/bin/env perl
#
# bench_store.pl — how long does the FEED STORE block the event loop?
#
#   perl tools/bench_store.pl [n_releases]     (default 3255, the live All Releases feed)
#
# WHY THIS EXISTS. Field report 2026-08-22: *"server losing players when opening an
# All Releases feed"*. Players dropping off is the signature of a BLOCKED EVENT
# LOOP, not of a slow network — LMS streams audio from the same loop that serves
# the browse request, so anything synchronous and long enough starves playback.
# This repo has shipped that hazard three times already (Bandcamp's synchronous
# parse, the per-release SELECT `bench_walk.pl` caught, `_execBlob` preparing a
# statement per row), and each time it was found by MEASURING, not by reading.
#
# `bench_walk.pl` already covers the per-release RENDER work. It does not touch the
# store, and since 0.9.166 the feed IS the store — so the two synchronous stretches
# below are on the All Releases path and have never been measured:
#
#   READ  (every open)  feedReleases: one SELECT, then Storable::thaw PER ROW.
#   WRITE (a cold open / a revalidation) ingestFeed: ONE transaction, one upsert
#         per release, run inside an async HTTP callback — which is the worst
#         possible place for it, because nothing can interleave.
#
# Run it on the DEV MAC and remember the target is a Raspberry Pi, which is roughly
# an order of magnitude slower. A figure that looks harmless here does not stay
# harmless there — that is exactly how the 0.9.165 per-release SELECT survived
# review.
#
# Uses REAL DBD::SQLite against a real file in a tempdir (the t_db.pl setup), and
# the REAL DB.pm — a benchmark against a paraphrase measures the paraphrase.
use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Time::HiRes qw(time);

my $DB = $ENV{LBF_DB} || File::Spec->catfile($FindBin::Bin, File::Spec->updir,
                                             'ListenBrainzFreshReleases', 'DB.pm');
my $NS = 'Plugins::ListenBrainzFreshReleases::DB';
my $N  = shift(@ARGV) || 3255;

BEGIN { $INC{'Slim/Utils/Log.pm'} = $INC{'Slim/Utils/Prefs.pm'}
      = $INC{'Slim/Utils/Timers.pm'} = __FILE__ }
{
    package Slim::Utils::Log;   use Exporter 'import'; our @EXPORT = qw(logger);
                                sub addLogCategory {} sub logger { bless {}, 'T::Log' }
    package T::Log;             our $AUTOLOAD; sub AUTOLOAD {} sub warn {1} sub error {1}
                                sub is_debug {0} sub is_info {0}
    package Slim::Utils::Prefs; use Exporter 'import'; our @EXPORT = qw(preferences);
                                our %P; sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;           sub get { $Slim::Utils::Prefs::P{$_[1]} }
                                sub set { $Slim::Utils::Prefs::P{$_[1]} = $_[2] }
    # Driveable timer queue: the chunked ingest schedules its yields here, so each
    # chunk can be stepped individually and its blocking time measured on its own.
    # That per-chunk figure is the one that matters — the TOTAL work is unchanged,
    # what changed is the longest stretch the event loop cannot run.
    package Slim::Utils::Timers;
                                our @Q;
                                # $obj is handed back to the callback, as LMS does.
                                sub setTimer { my ($obj,undef,$cb,@a)=@_; push @Q,[$cb,$obj,@a]; 1 }
                                sub killSpecific {1}
}

my $DIR = tempdir(CLEANUP => 1);
$Slim::Utils::Prefs::P{cachedir} = $DIR;
do $DB or die "can't load $DB: " . ($@ || $!);

# ---------------------------------------------------------------------------
# A realistic release. Shape and field count taken from a live fresh_releases
# payload (13 keys), because the cost being measured is Storable's, and Storable's
# cost is a function of the structure — a toy two-key hash would understate it.
# ---------------------------------------------------------------------------
sub mkrel {
    my ($i) = @_;
    my $day = sprintf('2026-08-%02d', ($i % 28) + 1);
    return {
        release_mbid             => sprintf('%08x-1111-2222-3333-444444444444', $i),
        release_group_mbid       => sprintf('%08x-5555-6666-7777-888888888888', $i),
        release_name             => "A Reasonably Long Album Title Number $i",
        artist_credit_name       => "Some Artist With A Long Name $i",
        artist_mbids             => [ sprintf('%08x-9999-aaaa-bbbb-cccccccccccc', $i) ],
        release_date             => $day,
        release_group_primary_type   => ($i % 5 ? 'Album' : 'Single'),
        release_group_secondary_type => ($i % 7 ? '' : 'Compilation'),
        caa_id                   => 1000000 + $i,
        caa_release_mbid         => sprintf('%08x-dddd-eeee-ffff-000000000000', $i),
        release_tags             => [ 'indie rock', 'shoegaze', 'dream pop' ],
        listen_count             => $i % 500,
        confidence               => ($i % 10) / 10,
    };
}

my @rels = map { mkrel($_) } 1 .. $N;
printf "Feed size: %d releases   (live All Releases measured 3,255)\n", $N;
printf "Perl %vd, DBD::SQLite %s\n\n", $^V, $DBD::SQLite::VERSION;

my ($from, $to) = ('2026-08-01', '2026-08-28');

# ---------------------------------------------------------------------------
printf "%-52s %10s %12s\n", 'STAGE', 'ms', 'per release';
printf "%s\n", '-' x 76;

my $t = time;
my $res = $NS->can('ingestFeed')->('all', \@rels, from => $from, to => $to, rotate => 1);
my $ingest = (time - $t) * 1000;
printf "%-52s %10.1f %9.3f ms\n", 'ingestFeed (COLD — one transaction, in an HTTP cb)',
       $ingest, $ingest / $N;

$t = time;
$res = $NS->can('ingestFeed')->('all', \@rels, from => $from, to => $to, rotate => 1);
my $reingest = (time - $t) * 1000;
printf "%-52s %10.1f %9.3f ms\n", 'ingestFeed (WARM — every row already stored)',
       $reingest, $reingest / $N;

$t = time;
my $cov = $NS->can('feedCoverage')->('all', $from, $to);
my $covms = (time - $t) * 1000;
printf "%-52s %10.1f %9s\n", 'feedCoverage (the freshness query)', $covms, '-';

$t = time;
my $got = $NS->can('feedReleases')->('all', $from, $to);
my $read = (time - $t) * 1000;
printf "%-52s %10.1f %9.3f ms\n", 'feedReleases (EVERY OPEN — SELECT + thaw per row)',
       $read, $read / $N;

printf "%s\n", '-' x 76;
printf "read back %d of %d releases, coverage %s\n\n",
       scalar(@$got), $N, ($cov->{complete} ? 'complete' : 'partial');

# ---------------------------------------------------------------------------
# Split the read: how much is SQLite, and how much is Storable? They have very
# different fixes — a slow SELECT wants an index, a slow thaw wants to not be
# thawing thousands of rows on the render path at all.
# ---------------------------------------------------------------------------
{
    my $h = $NS->can('dbh')->();
    my $sql = 'SELECT r.payload FROM feed_member m JOIN release r ON r.rel_id = m.rel_id
                WHERE m.feed = ? AND r.base_version = ?
                  AND (r.rel_date = ? OR (r.rel_date >= ? AND r.rel_date <= ?))
                ORDER BY r.rel_date DESC';
    my $t2 = time;
    my $rows = $h->selectall_arrayref($sql, { Slice => {} }, 'all',
                   $NS->can('BASE_VERSION')->(), '', $from, $to);
    my $sqlms = (time - $t2) * 1000;

    $t2 = time;
    my $n = 0;
    for my $r (@$rows) { my $v = eval { Storable::thaw($r->{payload}) }; $n++ if ref $v }
    my $thawms = (time - $t2) * 1000;

    printf "  %-50s %10.1f ms  (%.0f%%)\n", 'of which: SQLite SELECT', $sqlms,
           $read ? 100 * $sqlms / $read : 0;
    printf "  %-50s %10.1f ms  (%.0f%%)  %d rows\n", 'of which: Storable::thaw per row', $thawms,
           $read ? 100 * $thawms / $read : 0, $n;
}

# ---------------------------------------------------------------------------
# THE FIX, MEASURED: the same work, chunked, with a yield between chunks.
# Total time is roughly unchanged (it is the same statements) — what changes is the
# LONGEST UNINTERRUPTED BLOCK, which is what starves audio and the image proxy.
# ---------------------------------------------------------------------------
{
    my $CHUNK = $NS->can('INGEST_CHUNK')->();
    @Slim::Utils::Timers::Q = ();
    my (@blocks, $done);
    my $t0 = time;

    my $mark = sub { my $s = time; return sub { push @blocks, (time - $s) * 1000 } };
    # Time each chunk by wrapping the pump: every step between yields is one
    # uninterrupted stretch of blocking.
    my $pre = time;
    $NS->can('ingestFeed')->('chunked', \@rels, from => $from, to => $to,
                             chunk => $CHUNK, onDone => sub { $done = $_[0] });
    push @blocks, (time - $pre) * 1000;          # the first chunk runs inline
    while (@Slim::Utils::Timers::Q) {
        my $t = shift @Slim::Utils::Timers::Q;
        my $s = time;
        $t->[0]->(@{$t}[1 .. $#$t]);
        push @blocks, (time - $s) * 1000;
    }
    my $total = (time - $t0) * 1000;
    my ($max) = sort { $b <=> $a } @blocks;

    printf "\nCHUNKED INGEST (INGEST_CHUNK = %d)\n%s\n", $CHUNK, '-' x 76;
    printf "%-52s %10.1f ms\n", 'total (same work, spread over chunks)', $total;
    printf "%-52s %10d\n",      'chunks (= yields the loop gets)', scalar(@blocks);
    printf "%-52s %10.1f ms\n", 'LONGEST UNINTERRUPTED BLOCK', $max;
    printf "%-52s %10.1f ms\n", '  ... same figure projected onto a Pi (10x)', $max * 10;
    printf "%-52s %10s\n", 'completed', ($done && $done->{ok} ? 'ok' : 'FAILED');
    printf "\n  Before: ONE block of %.0f ms here / ~%.0f ms on a Pi.\n", $ingest, $ingest * 10;
    printf "  After:  longest block %.0f ms here / ~%.0f ms on a Pi  (%.0fx shorter).\n",
           $max, $max * 10, $max ? $ingest / $max : 0;
}

# ---------------------------------------------------------------------------
print "\n";
print "WHAT THIS MEANS\n", '-' x 76, "\n";
printf "A browse tap produces THREE OR MORE XMLBrowser walks from the root, and the\n"
     . "root builds BOTH sections. %%FEED_MEMO (5s) collapses those to one read per\n"
     . "feed per interaction, so the figure that matters is ONE feedReleases: %.0f ms\n"
     . "here, and a Pi is roughly 10x slower -> ~%.0f ms of unbroken blocking.\n\n",
       $read, $read * 10;
printf "A COLD open (or any revalidation) additionally pays ingestFeed INSIDE the\n"
     . "HTTP callback: %.0f ms here, ~%.0f ms on a Pi, with nothing able to interleave.\n\n",
       $ingest, $ingest * 10;
print "LMS streams audio from this same event loop. Sustained blocking here is what\n"
    . "drops players. Anything over ~100ms on the TARGET hardware deserves a yield.\n";
