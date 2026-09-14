#!/usr/bin/env perl
#
# t_orderfreeze.pl — an All Releases week's row ORDER must not move under the user,
# and the Artist sort is A-Z on the display name.
#
#   perl tools/t_orderfreeze.pl
#
# WHY THIS EXISTS (field bug, 2026-09-04). XMLBrowser addresses a row by its
# POSITION ('6.57'), and because this plugin's top level is coderef-driven no
# session cache is minted, so the whole tree is rebuilt from topLevel down on every
# click. '6.57' therefore means "whatever is 57th when the click is resolved" — safe
# only while the list is deterministic. It was not: the week list's ordering inputs
# were cache-only PEEKS that a background warm was actively filling.
#
#   * genre filter  — peeked genre facts; a release with no genre yet is filtered
#                     OUT and filtered back IN when its genre lands. STILL LIVE.
#   * artist sort   — used to read MusicBrainz sort-names as they arrived, so
#                     "Panda Bear" moved from P to B. GONE since 2026-09-14: the sort
#                     is A-Z on the display name, which never moves (section 9).
#
# Symptom: search-in-list on an expanded week, tap the highlighted row, open a
# completely different album. Search is simply the interaction slow enough for the
# warm to land in between (Material's "search within list" never re-fetches — it
# scrolls and highlights, so the client holds an order the server has already moved).
#
# THE PROPERTY UNDER TEST IS NOT "the order is correct". It is "the order is the
# SAME as the one the rendered page is holding". A suite that only checked sorting
# would pass against the bug — the sort was never wrong, it was merely different on
# the second walk. So every freeze section below walks TWICE with the world changed
# in between — a release ARRIVING, which is what the genre warm does — and asserts
# the natural order really did move before asserting the frozen one did not.
#
# Sub bodies and the TTL are extracted VERBATIM from the shipped source (the
# bench_walk.pl trick), so a change to either fails here rather than passing against
# a paraphrase. No LMS needed.
#
# ANTI-TEST: point LBF_BROWSE at a mutated copy.
#   * make _frozenOrder `return $sorted` unconditionally  -> sections 2,3,7 fail.
#   * drop the re-stamp so the freeze is not sliding      -> section 7 fails.
#   * drop the _dropOrderFreeze call from _refreshItem    -> section 8 fails.
#   * put _sortWithin back into the _pageSection call     -> section 8 fails.
#   * let _artistSortKey read artist_sort_name again      -> section 9 fails.
#   * drop the ignoreArticles call from _artistSortKey    -> section 9 fails.
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
# property, so it cannot be tested against the real one) and a genre selection.
# ---------------------------------------------------------------------------
our $NOW    = 1_000_000;
our @GENRES = ();      # the ticked genre families

BEGIN { *CORE::GLOBAL::time = sub { $main::NOW } }

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
   . grab('_sortWithin')  . grab('_artistSortKey')
   . grab('_selectedGenres') . grab('_pickValue') . grab('_norm')
   . "1;" or die $@;

my ($p, $f) = (0, 0);
sub ok   { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is   { my ($d, $g, $w) = @_; my $c = (defined $g ? $g : '') eq (defined $w ? $w : '');
           $c ? $p++ : $f++;
           printf "%s %-52s got=%-30s want=%s\n", ($c ? 'ok  ' : 'FAIL'), $d,
                  "'" . (defined $g ? $g : '') . "'", "'" . (defined $w ? $w : '') . "'" }
sub section { print "\n" . ('-' x 74) . "\n$_[0]\n" . ('-' x 74) . "\n" }

my $seq = 0;
sub rel {
    my (%o) = @_;
    $seq++;
    return {
        release_mbid       => $o{mbid} // sprintf('mbid-%04d', $seq),
        artist_credit_name => $o{artist},
        artist_mbids       => [ 'a-' . lc($o{artist} =~ s/\W//gr) ],
        release_name       => $o{album} // "Album $seq",
        release_date       => $o{date}  // '2026-08-01',
        (defined $o{sort} ? (artist_sort_name => $o{sort}) : ()),
    };
}
sub names { return join(',', map { $_->{artist_credit_name} } @{ $_[0] }) }

# The cast, and the arrival. Dates are distinct so the release_date mode is
# distinguishable from the artist one. The arrival is "Acid Arab" because it sorts
# FIRST — an arrival that naturally lands at the end would let every freeze
# assertion below pass against a freeze that does nothing, which is exactly what the
# first draft of this file did (with a sort-name that landed in the same slot).
#   natural, cast only   : Bilal, Panda Bear, Yves Tumor
#   natural, with arrival: Acid Arab, Bilal, Panda Bear, Yves Tumor
sub cast {
    $seq = 0;
    return [ rel(artist => 'Bilal',      date => '2026-08-01'),
             rel(artist => 'Panda Bear', date => '2026-08-03'),
             rel(artist => 'Yves Tumor', date => '2026-08-02') ];
}
sub arrival { rel(artist => 'Acid Arab', mbid => 'mbid-late', date => '2026-08-04') }

# ===========================================================================
section('1. a first look freezes the natural order');
{
    X::_dropOrderFreeze(); @GENRES = ();
    my $set = cast();
    my $out = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('cold walk returns the natural artist order', names($out), 'Bilal,Panda Bear,Yves Tumor');
    my $again = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('...and an unchanged second walk is identical', names($again), 'Bilal,Panda Bear,Yves Tumor');
}

# ===========================================================================
section('2. THE BUG: a release arriving between two walks must not reorder the page');
{
    X::_dropOrderFreeze(); @GENRES = ();
    my $set   = cast();
    my $first = X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    is('rendered order', names($first), 'Bilal,Panda Bear,Yves Tumor');

    # The genre warm files a release in. This is the ONLY thing that changes.
    my $grown = [ @$set, arrival() ];

    # The control, and it is not optional: if the natural order did NOT move, the
    # assertion below would pass against a freeze that does nothing at all.
    is('the NATURAL order really did move (else this proves nothing)',
       names(X::_sortWithin($grown, 'artist')), 'Acid Arab,Bilal,Panda Bear,Yves Tumor');

    my $second = X::_frozenOrder('2026-08-31', 'artist', 'albums', $grown);
    is('the arrival lands at the END, not at its natural position',
       names($second), 'Bilal,Panda Bear,Yves Tumor,Acid Arab');
    ok('...so every index the rendered page held still points at the same album',
       names([ @{$second}[0..2] ]) eq names($first));
}

# ===========================================================================
section('3. the freeze is EXTENDED, never reshuffled');
{
    X::_dropOrderFreeze(); @GENRES = ();
    my $set = cast();
    X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    my $grown = [ @$set, arrival() ];
    X::_frozenOrder('2026-08-31', 'artist', 'albums', $grown);

    my $third = X::_frozenOrder('2026-08-31', 'artist', 'albums', $grown);
    is('the arrival stays where it was appended on the next walk',
       names($third), 'Bilal,Panda Bear,Yves Tumor,Acid Arab');

    my $second = rel(artist => 'Aaa Second', mbid => 'mbid-later', date => '2026-08-05');
    my $again  = X::_frozenOrder('2026-08-31', 'artist', 'albums', [ @$grown, $second ]);
    is('...and a second arrival goes after it, not ahead of it',
       names($again), 'Bilal,Panda Bear,Yves Tumor,Acid Arab,Aaa Second');
}

# ===========================================================================
section('4. a departure is honest about what it costs');
{
    X::_dropOrderFreeze(); @GENRES = ();
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
    X::_dropOrderFreeze(); @GENRES = ();
    my $set = cast();
    X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    my $grown = [ @$set, arrival() ];

    my $sorted = X::_frozenOrder('2026-08-31', 'release_date', 'albums', $grown);
    is('a different SORT MODE is a different freeze, in that mode\'s own order',
       names($sorted), names(X::_sortWithin($grown, 'release_date')));
    ok('...which really is different from the artist order (else this proves nothing)',
       names($sorted) ne names(X::_sortWithin($grown, 'artist')));

    my $lens = X::_frozenOrder('2026-08-31', 'artist', 'singles_eps', $grown);
    is('a different FAMILY LENS is a different freeze',
       names($lens), names(X::_sortWithin($grown, 'artist')));

    @GENRES = ('Rock');
    my $genre = X::_frozenOrder('2026-08-31', 'artist', 'albums', $grown);
    is('a different GENRE SELECTION is a different freeze',
       names($genre), names(X::_sortWithin($grown, 'artist')));
    @GENRES = ();

    my $other = X::_frozenOrder('2026-08-24', 'artist', 'albums', $grown);
    is('and one week never leaks into another',
       names($other), names(X::_sortWithin($grown, 'artist')));
}

# ===========================================================================
section('6. Refresh drops it — the user asking for the feed as it is now');
{
    X::_dropOrderFreeze(); @GENRES = ();
    my $set = cast();
    X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    X::_dropOrderFreeze();
    my $grown = [ @$set, arrival() ];
    is('after a Refresh the week re-derives, arrival in its natural place',
       names(X::_frozenOrder('2026-08-31', 'artist', 'albums', $grown)),
       'Acid Arab,Bilal,Panda Bear,Yves Tumor');
}

# ===========================================================================
section("7. the freeze is SLIDING (TTL ${TTL}s, read from the source)");
{
    X::_dropOrderFreeze(); @GENRES = ();
    my $set = cast();
    X::_frozenOrder('2026-08-31', 'artist', 'albums', $set);
    my $grown = [ @$set, arrival() ];

    # Kept alive by being looked at: three walks, each just inside the TTL, spanning
    # well over it in total. A fixed expiry would have dropped this long ago.
    for (1 .. 3) {
        $NOW += $TTL - 1;
        X::_frozenOrder('2026-08-31', 'artist', 'albums', $grown);
    }
    is('a week you keep browsing stays frozen past a whole TTL',
       names(X::_frozenOrder('2026-08-31', 'artist', 'albums', $grown)),
       'Bilal,Panda Bear,Yves Tumor,Acid Arab');

    # Walk away from it and it re-derives.
    $NOW += $TTL + 1;
    is('...and one you leave alone re-derives after the TTL',
       names(X::_frozenOrder('2026-08-31', 'artist', 'albums', $grown)),
       'Acid Arab,Bilal,Panda Bear,Yves Tumor');
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
section('9. THE ARTIST SORT IS A-Z ON THE DISPLAY NAME (2026-09-14)');
{
    # A MuSpy row carries MusicBrainz's sort-name inline. It must be IGNORED, so the
    # two feeds sort the same way. Chosen so reading it would visibly reorder: with
    # the sort-name "Aaa" Jack White would sort ahead of Bilal.
    my $muspy = [ rel(artist => 'Jack White', sort => 'Aaa'), rel(artist => 'Bilal') ];
    is('MuSpy\'s inline sort-name is ignored — the display name decides',
       names(X::_sortWithin($muspy, 'artist')), 'Bilal,Jack White');

    my @cast = map { rel(artist => $_) }
               ('Yves Tumor', 'The Cure', 'Bilal', 'The The', 'Los Lobos', 'Theo Parrish', 'ANOHNI');

    # Without LMS (a harness, or a server too old to have the helper) it still sorts:
    # case-folded, articles kept.
    is('no LMS helper: case-folded A-Z, articles kept',
       names(X::_sortWithin([ @cast ], 'artist')),
       'ANOHNI,Bilal,Los Lobos,The Cure,The The,Theo Parrish,Yves Tumor');

    # WITH LMS's own helper — verbatim from slimserver public/9.0
    # Slim/Utils/Text.pm `ignoreArticles`, the server pref replaced by its shipped
    # default from Slim/Utils/Prefs.pm. Using LMS's list is the point: the Artist sort
    # files names the way the user's own library does, in the user's language.
    {
        package T::LMSText;
        my $ignoredArticles;
        sub ignoreArticles {
            my $item = shift;
            if (!defined $item) {
                return undef;
            }
            if (!defined($ignoredArticles)) {
                $ignoredArticles = 'The El La Los Las Le Les';
                $ignoredArticles =~ s/\s+/|/g;
                $ignoredArticles = qr/^($ignoredArticles)\s+/i;
            }
            $item =~ s/$ignoredArticles//;
            return $item;
        }
    }
    { no warnings 'once'; *Slim::Utils::Text::ignoreArticles = \&T::LMSText::ignoreArticles; }

    is('with LMS\'s helper: a leading article is skipped',
       names(X::_sortWithin([ @cast ], 'artist')),
       'ANOHNI,Bilal,The Cure,Los Lobos,The The,Theo Parrish,Yves Tumor');
    is('"The Cure" keys as "cure"', X::_artistSortKey(rel(artist => 'The Cure')), 'cure');
    is('"The The" keys as "the" — only the FIRST word goes', X::_artistSortKey(rel(artist => 'The The')), 'the');
    is('"Theo Parrish" is untouched — an article must be a whole word',
       X::_artistSortKey(rel(artist => 'Theo Parrish')), 'theo parrish');
    is('"The" alone is not emptied', X::_artistSortKey(rel(artist => 'The')), 'the');

    my $key = grab('_artistSortKey');
    ok('the key reads no sort-name and asks no API',
       $key !~ /artist_sort_name|peekArtistSort|API/);
    ok('_sortWithin makes no store read for the Artist sort',
       grab('_sortWithin') !~ /peekArtistSorts/);
    ok('nothing in Browse.pm fetches MusicBrainz sort-names',
       $SRC !~ /\bwarmArtistSorts\b|\n\s*_warmArtistSorts\(/);
}

# ===========================================================================
print "\n" . ('=' x 74) . "\n$p passed, $f failed.\n";
exit($f ? 1 : 0);
