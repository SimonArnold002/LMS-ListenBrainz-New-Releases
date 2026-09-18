#!/usr/bin/env perl
#
# t_ttlceiling.pl — no TTL handed to Slim::Utils::Cache may exceed 2,592,000.
#
#   perl tools/t_ttlceiling.pl
#
# THE MECHANISM, because a guard whose number is wrong looks exactly like
# coverage. Slim::Utils::DbCache::_canonicalize_expiration_time:
#
#     # "If value is less than 60*60*24*30 (30 days), time is assumed to be
#     # relative from the present. If larger, it's considered an absolute Unix time."
#     if ( $expiry <= 2592000 && $expiry > -1 ) { $expiry += time(); }
#
# So 2,592,000 is RELATIVE and 2,592,001 is an ABSOLUTE EPOCH IN 1970. A 90-day
# TTL is stored already expired: `set` returns 1, nothing dies, nothing warns, and
# every read comes back undef.
#
# LBF shipped two of them — RECMETA_TTL (release-group and recording metadata) and
# AGEN_FOUND_TTL (mirror artist genres) — and BOTH are the branch used for the
# entries worth keeping (a release group WITH a date, an artist WITH genres),
# while the worthless ones got a valid 1-day TTL. That is why the ListenBrainz
# genre tiers had never once served a dated release.
#
# THE SIBLING PLUGIN RAN THIS GUARD AT 90 DAYS THROUGHOUT ITS OWN INVESTIGATION,
# so it passed green while the bug was live and burned five releases. The ceiling
# here is 2,592,000 EXACTLY and section 1 proves the boundary is where this file
# claims it is, rather than trusting the number in a comment.
#
# THE END STATE this file is aiming at is section 3: once no module uses
# Slim::Utils::Cache at all, the boundary is unreachable and the sweep becomes
# redundant rather than load-bearing. Until then it is the only thing standing
# between us and a silent repeat.
#
# ANTI-TEST:
#   perl -0777 -pe 's/RECMETA_TTL => 30/RECMETA_TTL => 90/' \
#       ListenBrainzFreshReleases/API.pm > /tmp/API.pm
#   LBF_API=/tmp/API.pm perl tools/t_ttlceiling.pl        # must go RED
#
# Exit 0 = all good. Exit 1 = at least one regressed.

use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);

use constant DBCACHE_BOUNDARY => 2_592_000;   # 60*60*24*30 — LMS's own number

my $SRCDIR = File::Spec->catdir($FindBin::Bin, File::Spec->updir, 'ListenBrainzFreshReleases');
my %SRC = (
    'API.pm'    => $ENV{LBF_API}    || File::Spec->catfile($SRCDIR, 'API.pm'),
    'Browse.pm' => $ENV{LBF_BROWSE} || File::Spec->catfile($SRCDIR, 'Browse.pm'),
    'DSTM.pm'   => $ENV{LBF_DSTM}   || File::Spec->catfile($SRCDIR, 'DSTM.pm'),
    'Diag.pm'   => $ENV{LBF_DIAG}   || File::Spec->catfile($SRCDIR, 'Diag.pm'),
);

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    die "ok() called with no message\n" unless defined $what && length $what;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}
sub section { printf "\n%s\n%s\n", $_[0], '-' x 74 }

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}

# Evaluate only the arithmetic these constants are written with. Anything else
# (a sub call, a variable) is reported as unevaluable rather than assumed safe —
# "I could not read it" must never render as "it is fine".
sub arith {
    my ($expr) = @_;
    $expr =~ s/_//g;                       # 30_000 style separators
    return undef unless $expr =~ m{^[\s\d*+()/-]+$};
    my $v = eval $expr;
    return (defined $v && $v =~ /^-?[\d.]+$/) ? $v : undef;
}

# ===========================================================================
section '1. THE BOUNDARY IS WHERE WE SAY IT IS (LMS\'s own rule, reproduced)';
{
    # Verbatim shape of Slim::Utils::DbCache::_canonicalize_expiration_time.
    my $canon = sub {
        my ($expiry) = @_;
        $expiry += time() if ($expiry <= 2592000 && $expiry > -1);
        return $expiry;
    };

    my $now = time();
    ok($canon->(DBCACHE_BOUNDARY) >= $now,
       '2,592,000 exactly is treated as RELATIVE (so the ceiling is inclusive)');
    ok($canon->(DBCACHE_BOUNDARY + 1) < $now,
       '2,592,001 is treated as an ABSOLUTE epoch — i.e. already expired');

    my $ninety = $canon->(90 * 86400);
    my @t = gmtime($ninety);
    ok($t[5] + 1900 == 1970,
       'a 90-day TTL resolves to ' . sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3])
       . ' — the defect, reproduced');
}

# ===========================================================================
section '2. NO CONSTANT ABOVE THE CEILING, AND NO INLINE LITERAL EITHER';
{
    for my $name (sort keys %SRC) {
        my $src = slurp($SRC{$name});
        my $seen = 0;
        my $bad  = 0;

        # (a) every TTL-ish constant
        while ($src =~ /^use\s+constant\s+(\w*TTL\w*)\s*=>\s*([^;#]+);/mg) {
            my ($const, $expr) = ($1, $2);
            $expr =~ s/\s+$//;
            $seen++;
            my $v = arith($expr);
            unless (defined $v) {
                $bad++;
                ok(0, "$name: $const = $expr — CANNOT BE EVALUATED, so it cannot be cleared");
                next;
            }
            next if $v <= DBCACHE_BOUNDARY;
            $bad++;
            ok(0, sprintf('%s: %s = %s (%d) EXCEEDS %d — this value means 1970',
                          $name, $const, $expr, $v, DBCACHE_BOUNDARY));
        }

        # (b) a duration written straight into a cache write, which no constant
        #     sweep can see. `_stashSummary`'s 25 * 3600 is the shape meant here.
        while ($src =~ /cache->set\([^;]*?,\s*([\d_]+(?:\s*[*+]\s*[\d_]+)*)\s*\)/g) {
            my $expr = $1;
            $seen++;
            my $v = arith($expr) // 0;
            next if $v <= DBCACHE_BOUNDARY;
            $bad++;
            ok(0, sprintf('%s: inline $cache->set TTL %s (%d) EXCEEDS %d',
                          $name, $expr, $v, DBCACHE_BOUNDARY));
        }

        ok(!$bad, "$name: all $seen cache durations are within the ceiling");
    }
}

# ===========================================================================
section '3. THE TWO THAT WERE WRONG, BY NAME';
{
    # A sweep passes the moment a constant is renamed or deleted, so the two known
    # defects are also pinned individually — a revert has to survive being named.
    my $api = slurp($SRC{'API.pm'});
    for my $const (qw(RECMETA_TTL AGEN_FOUND_TTL)) {
        if ($api =~ /^use\s+constant\s+\Q$const\E\s*=>\s*([^;#]+);/m) {
            my $expr = $1; $expr =~ s/\s+$//;
            my $v = arith($expr);
            ok(defined $v && $v <= DBCACHE_BOUNDARY,
               "$const = $expr" . (defined $v ? " ($v)" : '') . ' — at or below the ceiling');
        } else {
            # Gone is fine: it means the value moved to a fetched_at policy on the
            # facts tables, which is the intended destination. Say which, though.
            ok(1, "$const is no longer a constant (moved off Slim::Utils::Cache?)");
        }
    }
}

# ===========================================================================
section '4. THE BOUNDARY IS NOW UNREACHABLE — and must stay that way';
{
    # THE END STATE, REACHED. No module hands a duration to Slim::Utils::Cache any
    # more; every TTL goes to DB::kvSet, where `expires_at` is an absolute epoch we
    # compute ourselves and no magnitude re-interprets itself.
    #
    # USE, NOT MENTION. These files deliberately recount the 1970 defect in their
    # comments, and a check that failed on its own explanation would get the
    # explanation deleted — which is the opposite of what this file is for. So the
    # test is for a `use` statement or a constructor call.
    my $USE = qr/(?:^\s*use\s+Slim::Utils::Cache\b|Slim::Utils::Cache->new)/m;

    my @still;
    for my $name (sort keys %SRC) {
        push @still, $name if slurp($SRC{$name}) =~ $USE;
    }
    ok(!@still,
       @still ? ('still holding an LMS cache handle: ' . join(', ', @still)
                 . ' — section 2 is load-bearing until that list is empty')
              : 'no module holds an LMS cache handle — no duration can reach the boundary');

    # DB.pm is the ONE deliberate exception, and only for READING. The legacy
    # import has to open the outgoing cache to carry the three families that were
    # never caches (a Bandcamp pin, the recommendation store, the artist
    # sort-names) — it cannot be enumerated, so there is no other way to get them.
    # It must never WRITE there: a `set` would be a duration handed to LMS again,
    # from the one file that still can.
    my $db = slurp($ENV{LBF_DB} || File::Spec->catfile($SRCDIR, 'DB.pm'));
    ok(scalar($db =~ $USE), 'DB.pm does open the old cache — the legacy import needs it');
    my @writes = ($db =~ /(\$c->set\(|\$cache->set\(|\$legacyCache->set\()/g);
    ok(!scalar(@writes),
       'DB.pm never WRITES to it (' . scalar(@writes) . ' set calls found) — read-only by design');
}

# ===========================================================================
section '5. THE POSITIVE — the same duration in the plugin store';
{
    # The point is not that 90 days is now avoided; it is that in DB.pm the same
    # number is stored as an absolute `now + 7776000` and READS BACK. If this ever
    # fails while section 2 passes, the ceiling has been worked around rather than
    # the storage fixed.
    my $DIR = tempdir(CLEANUP => 1);
    my $DB  = $ENV{LBF_DB} || File::Spec->catfile($SRCDIR, 'DB.pm');

    my $probe = <<"PROBE";
BEGIN { \$INC{'Slim/Utils/Log.pm'} = \$INC{'Slim/Utils/Prefs.pm'} = __FILE__ }
{
    package Slim::Utils::Log;   use Exporter 'import'; our \@EXPORT = qw(logger);
                                sub addLogCategory {} sub logger { bless {}, 'P::L' }
    package P::L;               our \$AUTOLOAD; sub AUTOLOAD {} sub warn {1} sub error {1}
    package Slim::Utils::Prefs; use Exporter 'import'; our \@EXPORT = qw(preferences);
                                sub preferences { bless {}, 'P::P' }
    package P::P;               sub get { '$DIR' }
}
do '$DB' or die \$@ || \$!;
my \$NS = 'Plugins::ListenBrainzFreshReleases::DB';
my \$before = time();
\$NS->can('kvSet')->('probe:90d', { kept => 1 }, 90 * 86400);
my (\$exp) = \$NS->can('dbh')->()->selectrow_array("SELECT expires_at FROM kv WHERE k = 'probe:90d'");
my \$got = \$NS->can('kvGet')->('probe:90d');
printf "PROBE\\t%d\\t%d\\t%s\\n", \$before, (\$exp // 0), (ref \$got eq 'HASH' && \$got->{kept} ? 'readable' : 'LOST');
PROBE

    my $file = File::Spec->catfile($DIR, 'probe.pl');
    open(my $fh, '>', $file) or die $!;
    print $fh $probe;
    close $fh;

    my $out = `$^X $file 2>&1`;
    my ($before, $exp, $state) = $out =~ /^PROBE\t(\d+)\t(\d+)\t(\w+)/m;

    ok(defined $exp && $exp >= $before + 7_776_000 && $exp <= $before + 7_776_000 + 5,
       'kvSet(90 days) stores expires_at = now + 7,776,000 (an absolute epoch we computed)');
    ok(defined $state && $state eq 'readable',
       'and the 90-day entry READS BACK — the defect is inexpressible in the store');
}

# ===========================================================================
section '6. AGE POLICY — empty answers expire TOMORROW, found answers in 30 days';
{
    # DB.pm is deliberately NOT in %SRC: sections 2 and 4 sweep for durations handed
    # to Slim::Utils::Cache, and the store uses none. It owns RG_GENRE_* though, so
    # this section needs it and adds it locally rather than widening %SRC and
    # changing what those sections assert.
    my %AGESRC = (%SRC,
        'DB.pm' => $ENV{LBF_DB}
            || File::Spec->catfile($FindBin::Bin, File::Spec->updir,
                                   'ListenBrainzFreshReleases', 'DB.pm'));
    # Simon's standing rule, re-broken by the genre work and now guarded:
    # NO CACHE MAY GO STALE FOR A LONG PERIOD. See
    # docs/feed-findings-2026-08-14.md §2.
    #
    # The EMPTY ages are the ones that actually hurt. A found genre being a month
    # old is harmless — genres barely move. A stored "this artist has no genres"
    # is the answer most likely to be WRONG tomorrow, because it is precisely the
    # one an upstream dataset fills in: the hosted API's artist genres were
    # observed changing within a single day (Taylor Swift went from no `genres`
    # key to seventeen), while our store held 400 artists at "asked, none" behind
    # a seven-day age.
    #
    # These are store ages compared against a stored fetched_at, NOT durations
    # handed to Slim::Utils::Cache, so section 2's ceiling does not apply to them.
    # They are capped at the same 30 days anyway, so that moving one onto a cache
    # TTL later cannot silently reintroduce the 1970 bug.
    #
    # ANTI-TEST:
    #   perl -0777 -pe 's/HAGEN_EMPTY_AGE   =>  1/HAGEN_EMPTY_AGE   =>  7/' \
    #       ListenBrainzFreshReleases/API.pm > /tmp/API.pm
    #   LBF_API=/tmp/API.pm perl tools/t_ttlceiling.pl        # must go RED
    use constant DAY => 86_400;

    my $checked = 0;
    for my $name (sort keys %AGESRC) {
        my $src = slurp($AGESRC{$name});
        my $bad = 0;

        while ($src =~ /^use\s+constant\s+(\w+)\s*=>\s*([^;#]+);/mg) {
            my ($const, $expr) = ($1, $2);
            $expr =~ s/\s+$//;

            # Only the freshness knobs. MEMO/TIMEOUT/MAX/CONCURRENCY and the feed
            # TTLs are a different question and keep their own numbers.
            my $isEmpty = $const =~ /_(?:EMPTY|NONE)_(?:AGE|TTL)$/;
            my $isFound = $const =~ /_FOUND_(?:AGE|TTL)$/ || $const =~ /^RECMETA_AGE$/;
            next unless $isEmpty || $isFound;

            my $v = arith($expr);
            unless (defined $v) {
                $bad++;
                ok(0, "$name: $const = $expr — CANNOT BE EVALUATED");
                next;
            }
            $checked++;

            my $cap   = $isEmpty ? 1 * DAY : 30 * DAY;
            my $label = $isEmpty ? 'empty' : 'found';
            ok($v <= $cap,
               sprintf('%s: %s = %s (%d) — %s answer, cap %d (%d day%s)',
                       $name, $const, $expr, $v, $label, $cap,
                       $cap / DAY, $cap == DAY ? '' : 's'))
                or $bad++;
        }
    }

    ok($checked >= 8,
       "the sweep actually found the freshness constants ($checked of them) — a "
       . 'rename must not silently empty this section');

    # Named individually, because a sweep passes the moment a constant is renamed
    # away. These are the four that were over the cap.
    my %WAS = (
        'API.pm' => { AGEN_EMPTY_AGE => 1, HAGEN_EMPTY_AGE => 1,
                      LFM_EMPTY_TTL  => 1, RECMETA_AGE     => 30 },
        'DB.pm'  => { RG_GENRE_EMPTY_AGE => 1, RG_GENRE_FOUND_AGE => 30 },
    );
    for my $file (sort keys %WAS) {
        my $src = slurp($AGESRC{$file}) or next;
        for my $const (sort keys %{ $WAS{$file} }) {
            my $days = $WAS{$file}{$const};
            if ($src =~ /^use\s+constant\s+\Q$const\E\s*=>\s*([^;#]+);/m) {
                my $expr = $1; $expr =~ s/\s+$//;
                my $v = arith($expr);
                ok(defined $v && $v <= $days * DAY,
                   "$file: $const = $expr — at or below $days day(s)");
            }
            else {
                ok(1, "$file: $const is gone (rung removed?)");
            }
        }
    }
}

# ===========================================================================
printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
