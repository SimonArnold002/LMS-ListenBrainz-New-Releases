#!/usr/bin/env perl
#
# t_orderfreeze.pl — an All Releases week's row ORDER must not move under the user.
#
#   perl tools/t_orderfreeze.pl
#
# WHY THIS EXISTS (field bug, 2026-09-04). XMLBrowser addresses a row by its
# POSITION ('6.57'), and because this plugin's top level is coderef-driven no
# session cache is minted, so the whole tree is rebuilt from topLevel down on every
# click. '6.57' therefore means "whatever is 57th when the click is resolved" — safe
# only while the list is deterministic. It was not: BOTH of the week list's ordering
# inputs are cache-only PEEKS that a background warm is actively filling.
#
#   * artist sort   — peekArtistSorts; an unwarmed name falls back to the display
#                     credit, so "Panda Bear" sorts under P and later under B.
#   * genre filter  — peeked genre facts; a release with no genre yet is filtered
#                     OUT and filtered back IN when its genre lands.
#
# Symptom: search-in-list on an expanded week, tap the highlighted row, open a
# completely different album. Search is simply the interaction slow enough for the
# warm to land in between (Material's "search within list" never re-fetches — it
# scrolls and highlights, so the client holds an order the server has already moved).
#
# THE PROPERTY UNDER TEST IS NOT "the order is correct". It is "the order is the
# SAME as the one the rendered page is holding". A suite that only checked sorting
# would pass against the bug — the sort was never wrong, it was merely different on
# the second walk. So every section below walks TWICE with the world changed in
# between, which is the only way to see it.
#
# Sub bodies and the TTL are extracted VERBATIM from the shipped source (the
# bench_walk.pl trick), so a change to either fails here rather than passing against
# a paraphrase. No LMS needed.
#
# ANTI-TEST: point LBF_BROWSE at a mutated copy.
#   * make _frozenOrder `return $sorted` unconditionally  -> sections 2,3,5,7 fail.
#   * drop the re-stamp so the freeze is not sliding      -> section 7 fails.
#   * drop the _dropOrderFreeze call from _refreshItem    -> section 8 fails.
#   * put _sortWithin back into the _pageSection call     -> section 8 fails.
#
# Exit 0 = all good. Exit 1 = at least one regressed.
use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

my $LBF = $ENV{LBF_BROWSE} || 'ListenBrainzFreshReleases/Browse.pm';
open(my $fh, '<:encoding(UTF-8)', $LBF) or die "$LBF: $!";
my $SRC = do { local $/; <$fh> };

sub grab {
    my ($n) = @_;
    $SRC =~ /\nsub \Q$n\E \{.*?\n\}\n/s or die "no sub $n in $LBF\n";
    return $&;
}

# The TTL is READ OUT of the source, never restated — a suite that pins its own copy
# of a cap cannot catch the cap changing (the t_coldwarm.pl rule).
$SRC =~ /^use constant ORDER_FREEZE_TTL\s*=>\s*(\d+)/m
    or die "no ORDER_FREEZE_TTL constant in $LBF\n";
my $TTL = $1;

# %FOLD, verbatim, for _norm (same lift as tools/bench_walk.pl).
$SRC =~ /(my \$HAVE_NFD = .*?^\);)/ms or die "no %FOLD block in $LBF\n";
my $FOLD = $1;

# ---------------------------------------------------------------------------
# The world the extracted subs run in: a clock we control (the TTL is a time
# property, so it cannot be tested against the real one), a peek that we can fill
# mid-test to reproduce a warm landing, and a genre selection.
# ---------------------------------------------------------------------------
our $NOW    = 1_000_000;
our %SORTS  = ();      # mbid => MB sort-name, i.e. what the warm has answered so far
our @GENRES = ();      # the ticked genre families

BEGIN { *CORE::GLOBAL::time = sub { $main::NOW } }

{
    package Plugins::ListenBrainzFreshReleases::API;
    sub peekArtistSorts {
        my ($class, $mbids) = @_;
        return { map { lc($_) => $main::SORTS{ lc $_ } }
                 grep { exists $main::SORTS{ lc $_ } } @{ $mbids || [] } };
    }
    sub peekArtistSort { my ($class, $m) = @_; return $main::SORTS{ lc $m } }
}
{
    package T::Prefs;
    sub new { bless {}, shift }
    sub get {
        my ($s, $k) = @_;
        return [ @main::GENRES ] if $k eq 'all_genres';
        return undef;
    }
}

eval "package X; use strict; use warnings; use utf8;\n"
   . 'our $prefs = T::Prefs->new;' . "\n"
   . "use constant ORDER_FREEZE_TTL => $TTL;\n"
   . $FOLD . "\n"
   . 'my %ORDER_FREEZE;' . "\n"
   . grab('_frozenOrder') . grab('_dropOrderFreeze') . grab('_relKey')
   . grab('_sortWithin')  . grab('_artistSortKey')   . grab('_firstArtistMbids')
   . grab('_selectedGenres') . grab('_pickValue') . grab('_norm')
   . "1;" or die $@;

my ($p, $f) = (0, 0);
sub ok   { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is   { my ($d, $g, $w) = @_; my $c = (defined $g ? $g : '') eq (defined $w ? $w : '');
           $c ? $p++ : $f++;
           printf "%s %-52s got=%-30s want=%s\n", ($c ? 'ok  ' : 'FAIL'), $d,
                  "'" . (defined $g ? $g : '') . "'", "'" . (defined $w ? $w : '') . "'" }
sub section { print "\n" . ('-' x 74) . "\n$_[0]\n" . ('-' x 74) . "\n" }

# A release. `sort` is the MB sort-name the warm will eventually answer with; it is
# deliberately NOT on the release, because the whole point is that it arrives later.
my $seq = 0;
sub rel {
    my (%o) = @_;
    $seq++;
    return {
        release_mbid       => $o{mbid} // sprintf('mbid-%04d', $seq),
        artist_credit_name => $o{artist},
        artist_mbids       => [ $o{ambid} // ('a-' . lc($o{artist} =~ s/\W//gr)) ],
        release_name       => $o{album} // "Album $seq",
        release_date       => $o{date}  // '2026-08-01',
    };
}
sub names { return join(',', map { $_->{artist_credit_name} } @{ $_[0] }) }

# The cast. Panda Bear is the case from the ledger: MB files it "Bear, Panda", so
# once the warm answers it moves from P to B and OVERTAKES Bilal. The neighbours are
# chosen so that it really does change places — a cast where the sort-name lands in
# the same slot would let every assertion below pass against a freeze that does
# nothing, which is exactly what the first draft of this file did.
#   cold (display credit): Bilal, Panda Bear, Yves Tumor
#   warm (MB sort-name)  : Panda Bear, Bilal, Yves Tumor
# Dates are distinct so the release_date mode is distinguishable from the artist one.
sub cast {
    $seq = 0;
    return [ rel(artist => 'Bilal',      ambid => 'a-bilal', date => '2026-08-01'),
             rel(artist => 'Panda Bear', ambid => 'a-panda', date => '2026-08-03'),
             rel(artist => 'Yves Tumor', ambid => 'a-yves',  date => '2026-08-02') ];
}

# ===========================================================================
section('1. a first look freezes the natural order');
{
    X::_dropOrderFreeze(); %SORTS = (); @GENRES = ();
    my $set = cast();
    my $out = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('cold walk returns the natural artist order', names($out), 'Bilal,Panda Bear,Yves Tumor');
    my $again = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('...and an unchanged second walk is identical', names($again), 'Bilal,Panda Bear,Yves Tumor');
}

# ===========================================================================
section('2. THE BUG: a warm landing between two walks must not reorder the page');
{
    X::_dropOrderFreeze(); %SORTS = (); @GENRES = ();
    my $set = cast();
    my $first = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('rendered order, nothing warm yet', names($first), 'Bilal,Panda Bear,Yves Tumor');

    # The warm answers. This is the ONLY thing that changes.
    %SORTS = ('a-panda' => 'Bear, Panda');

    # The control, and it is not optional: if the natural order did NOT move, the
    # assertion below would pass against a freeze that does nothing at all.
    my $natural = X::_sortWithin($set, 'artist');
    is('the NATURAL order really did move (else this proves nothing)',
       names($natural), 'Panda Bear,Bilal,Yves Tumor');

    my $second = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('the FROZEN order is unchanged — the tapped row is still the tapped row',
       names($second), 'Bilal,Panda Bear,Yves Tumor');
}

# ===========================================================================
section('3. an arrival is APPENDED, so no index the client holds can shift');
{
    X::_dropOrderFreeze(); %SORTS = (); @GENRES = ();
    my $set = cast();
    my $first = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('page as rendered', names($first), 'Bilal,Panda Bear,Yves Tumor');

    # The genre-warm case: a release the filter had excluded gains a genre and
    # enters the set. Naturally it sorts FIRST; it must not.
    my $late = rel(artist => 'AAA Newcomer', ambid => 'a-aaa');
    my $grown = X::_frozenOrder('2026-08-31', 'artist', 'albums', [ @$set, $late ]);
    is('the arrival lands at the END, not at its natural position',
       names($grown), 'Bilal,Panda Bear,Yves Tumor,AAA Newcomer');
    ok('...so every index the rendered page held still points at the same album',
       names([ @{$grown}[0..2] ]) eq names($first));

    # And it keeps that position on the next walk rather than sliding home.
    my $third = X::_frozenOrder('2026-08-31', 'artist', 'albums', [ @$set, $late ]);
    is('...and it stays there (the freeze is EXTENDED, never reshuffled)',
       names($third), 'Bilal,Panda Bear,Yves Tumor,AAA Newcomer');
}

# ===========================================================================
section('4. a departure is honest about what it costs');
{
    X::_dropOrderFreeze(); %SORTS = (); @GENRES = ();
    my $set = cast();
    X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    my $short = X::_frozenOrder('2026-08-31', 'artist', 'albums',
                                [ $set->[0], $set->[2] ]);
    is('survivors keep their relative order', names($short), 'Bilal,Yves Tumor');
    ok('...and nothing is duplicated or invented', scalar(@$short) == 2);
}

# ===========================================================================
section('5. every input that legitimately changes the order re-keys');
{
    X::_dropOrderFreeze(); %SORTS = (); @GENRES = ();
    my $set = cast();
    X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    %SORTS = ('a-panda' => 'Bear, Panda');

    my $sorted = X::_frozenOrder('2026-08-31', 'release_date', 'albums', $set);
    ok('a different SORT MODE is a different freeze, so the toggle still works',
       names($sorted) ne 'Bilal,Panda Bear,Yves Tumor');
    is('...and it is that mode\'s own order', names($sorted),
       names(X::_sortWithin($set, 'release_date')));

    my $lens = X::_frozenOrder('2026-08-31', 'artist', 'singles_eps', $set);
    is('a different FAMILY LENS is a different freeze',
       names($lens), names(X::_sortWithin($set, 'artist')));

    @GENRES = ('Rock');
    my $genre = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('a different GENRE SELECTION is a different freeze',
       names($genre), names(X::_sortWithin($set, 'artist')));
    @GENRES = ();

    my $other = X::_frozenOrder('2026-08-24', 'artist', 'albums', $set);
    is('and one week never leaks into another',
       names($other), names(X::_sortWithin($set, 'artist')));
}

# ===========================================================================
section('6. Refresh drops it — the user asking for the feed as it is now');
{
    X::_dropOrderFreeze(); %SORTS = (); @GENRES = ();
    my $set = cast();
    X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    %SORTS = ('a-panda' => 'Bear, Panda');
    X::_dropOrderFreeze();
    my $out = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('after a Refresh the week re-derives from the warmed data',
       names($out), names(X::_sortWithin($set, 'artist')));
}

# ===========================================================================
section("7. the freeze is SLIDING (TTL ${TTL}s, read from the source)");
{
    X::_dropOrderFreeze(); %SORTS = (); @GENRES = ();
    my $set = cast();
    X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    %SORTS = ('a-panda' => 'Bear, Panda');

    # Kept alive by being looked at: three walks, each just inside the TTL, spanning
    # well over it in total. A fixed expiry would have dropped this long ago.
    for (1 .. 3) {
        $NOW += $TTL - 1;
        X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    }
    is('a week you keep browsing stays frozen past a whole TTL',
       names(X::_frozenOrder('2026-08-31', 'artist', 'albums', $set)),
       'Bilal,Panda Bear,Yves Tumor');

    # Walk away from it and it re-derives.
    $NOW += $TTL + 1;
    is('...and one you leave alone re-derives after the TTL',
       names(X::_frozenOrder('2026-08-31', 'artist', 'albums', $set)),
       names(X::_sortWithin($set, 'artist')));
}

# ===========================================================================
section('8. the call sites — the half a unit test of the sub cannot see');
{
    my $week = grab('_buildAllWeekItems');
    ok('the All Releases week drill was located', defined $week && length $week);
    ok('the week renders through _frozenOrder', $week =~ /_frozenOrder\(\s*\$ws\s*,/);
    ok('...and no longer hands _pageSection a bare _sortWithin',
       $week !~ /_pageSection\([^)]*_sortWithin/s);

    my $refresh = grab('_refreshItem');
    ok('Refresh drops the frozen order for the All Releases feed',
       $refresh =~ /_dropOrderFreeze\(\)\s+if\s+\$w\s+eq\s+'all'/);
}

# ===========================================================================
print "\n" . ('=' x 74) . "\n$p passed, $f failed.\n";
exit($f ? 1 : 0);
