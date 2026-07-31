#!/usr/bin/env perl
#
# bench_walk.pl — measure the per-WALK cost of the release pipeline.
#
# WHY THIS EXISTS (read CLAUDE.md "If browsing feels slow again, look here first"):
# XMLBrowser re-walks the menu from the ROOT on every drill-in, in-place refresh and
# paging tap, and the root builds both sections. So the question that matters is
# never "how long does the HTTP take" (the feeds are cached) — it is "how much work
# does ONE walk do, and how many walks does a tap cost". This script answers the
# first half against real feed data, with no LMS running.
#
# It does NOT reimplement anything: it extracts the sub bodies VERBATIM from
# Browse.pm (the same trick tools/matcher_sync_check.py uses) and evals them against
# stub prefs/cache/API objects. So the numbers track the shipped code, and a
# refactor that slows the pipeline down shows up here.
#
#   perl tools/bench_walk.pl [feed.json]
#
# With no argument it fetches a live All Releases feed (public endpoint, no auth)
# into the system temp dir and reuses it on later runs. Timings are wall-clock on
# whatever box you run it on — a Pi is roughly an order of magnitude slower than a
# dev Mac, so read the RATIOS, not the absolute milliseconds.
use strict;
use warnings;
use Time::HiRes ();
use File::Spec;

my $ROOT = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
my $SRC  = File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');
my $FEED = $ARGV[0] || File::Spec->catfile(File::Spec->tmpdir(), 'lbf-bench-feed.json');

unless (-s $FEED) {
    my @t   = localtime(time);
    my $ymd = sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
    my $url = 'https://api.listenbrainz.org/1/explore/fresh-releases/'
            . "?sort=release_date&past=true&future=false&days=14&release_date=$ymd";
    print "fetching a live feed -> $FEED\n";
    system('curl', '-sS', '-m', '90', $url, '-o', $FEED) == 0 && -s $FEED
        or die "couldn't fetch a feed; pass a saved JSON file as an argument\n";
}

# --- pull the real sub bodies out of Browse.pm -----------------------------
open(my $fh, '<:encoding(UTF-8)', $SRC) or die "$SRC: $!";
my $src = do { local $/; <$fh> };
close $fh;

# Brace-match the body rather than assuming a closing "}" in column 0, so
# one-liners (sub _filterAll { ... }) come out whole too.
#
# Returns empty for a sub this branch doesn't carry, rather than dying: the genre
# subs exist only on `alpha` (see ALPHA.md), so the same harness has to run on both.
sub grab {
    my ($name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or return '';
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

# Everything a walk of the All Releases / For You pipeline touches.
my @SUBS = qw(
    _pickValue _norm _allowedTypes _typeMatches _secondaryType _filterSection
    _filterForYou _filterAll _isVariousArtists _blockedSet _isBlocked
    _dedupeReleases _sortReleases _weekStart _sortWithin _artistSortKey
    _viewFilter _releaseTags _genreKey _genreFamily _genreModifier _genreKnown
    _loadGenreFamilies _bucketFor _genresFor _lastfmGenres _mergeMuSpy _dateShift
    _sectionSig _sectionList _allSection _forYouSection
);

$src =~ /(my \$HAVE_NFD = .*?^\);)/ms or die "bench: no %FOLD block\n";
my $fold = $1;

my $code = <<'PRELUDE';
package LBF;
use strict; use warnings;
use Time::Local ();
my @RELEASE_TYPES = qw(album single ep broadcast other compilation soundtrack live remix demo);
my %_SINGLE_FAMILY = (single => 1, ep => 1);
use constant VA_MBID => '89ad4ac3-39f7-470e-963a-56509c546377';
use constant GENRE_NONE => '_none';
use constant SECTION_MEMO_TTL => 5;
use constant MUSPY_FUTURE_MONTHS_DEFAULT => 12;
use constant MUSPY_FUTURE_MONTHS_MAX     => 24;
my %SECTION_MEMO;
sub _benchAgeMemo { $_->[0] = 0 for values %SECTION_MEMO }   # bench-only: expire every entry
my %_WEEK_START;
# Defaults as shipped: Album + Compilation ticked, artwork-only and VA on.
our %PREFS = (
    all_type_album => 1, all_type_compilation => 1,
    foryou_type_album => 1, foryou_type_compilation => 1,
    all_artwork_only => 1, all_various => 1,
    foryou_artwork_only => 1, foryou_various => 1,
    blocked_artists => [], all_sort => 'release_date', all_view => 'albums',
    days => 14, foryou_past => 1, muspy_future => 1,
);
my $prefs = LBF::PrefsStub->new;
my $log   = LBF::LogStub->new;
sub _dbg {}
package LBF::PrefsStub;
sub new { bless {}, shift }
sub get { return $LBF::PREFS{$_[1]} }
sub set { $LBF::PREFS{$_[1]} = $_[2] }
package LBF::LogStub;
sub new { bless {}, shift }
sub info {} sub warn {} sub error {} sub is_info { 0 }
package Plugins::ListenBrainzFreshReleases::API;
use constant CAA_BASE_URL    => 'https://coverartarchive.org/release/';
use constant CAA_RG_BASE_URL => 'https://coverartarchive.org/release-group/';
our $COVER_CALLS = 0;
sub coverArtUrl {
    my ($class, $rel) = @_;
    $COVER_CALLS++;
    if (ref $rel eq 'HASH') {
        return CAA_BASE_URL . $rel->{caa_release_mbid} . '/front-250' if $rel->{caa_release_mbid};
        return CAA_RG_BASE_URL . $rel->{caa_release_group_mbid} . '/front-250' if $rel->{caa_release_group_mbid};
        return undef;
    }
    return $rel ? CAA_BASE_URL . $rel . '/front-250' : undef;
}
sub peekArtistSort { undef }
sub peekLastfmTags { [] }
package LBF;
PRELUDE

$code .= "$fold\n";
$code .= "my \$_familiesLoaded = 0; my %_GENRE_FAMILY; my %_GENRE_MODIFIER; my %_GENRE_KNOWN;\n";
$code .= join('', map { grab($_) } @SUBS);
$code .= "1;\n";
# _loadGenreFamilies finds its table via %INC; point it at the checkout instead.
$code =~ s{my \$path = \$INC\{'Plugins/ListenBrainzFreshReleases/Browse\.pm'\} or return;}
          {my \$path = '$SRC';};

eval $code or die "bench: extracted code didn't compile: $@";

# --- load the feed ---------------------------------------------------------
my $decode = eval { require JSON::PP; 1 }
    ? sub { JSON::PP->new->decode($_[0]) }
    : do { require JSON::XS; sub { JSON::XS->new->decode($_[0]) } };

open(my $jf, '<:raw', $FEED) or die "$FEED: $!";
my $json = do { local $/; <$jf> };
close $jf;
my $payload  = $decode->($json)->{payload};
my $releases = $payload->{releases} || $payload->{fresh_releases}
    or die "bench: $FEED doesn't look like a fresh-releases response\n";
printf "feed: %s\n      %d raw releases\n\n", $FEED, scalar @$releases;

sub bench {
    my ($label, $n, $cb) = @_;
    my $t0 = Time::HiRes::time();
    my $r;
    $r = $cb->() for 1 .. $n;
    printf "  %-40s %8.2f ms\n", $label, (Time::HiRes::time() - $t0) * 1000 / $n;
    return $r;
}

my $N = 5;
print "ONE COLD WALK (what topLevel / fetchAll do with an empty memo)\n";
my $filtered = bench('_filterAll', $N, sub { LBF::_filterSection($releases, 'all') });
printf "%50s%d kept\n", '-> ', scalar @$filtered;
my $sorted = bench('_sortReleases (dedupe + date sort)', $N, sub { LBF::_sortReleases($filtered) });
printf "%50s%d after dedupe\n", '-> ', scalar @$sorted;
bench('week grouping (_weekStart per release)', $N, sub {
    my (@order, %bucket);
    for my $rel (@$sorted) {
        my $ws = LBF::_weekStart($rel->{release_date} // '');
        push @order, $ws unless exists $bucket{$ws};
        push @{ $bucket{$ws} }, $rel;
    }
    \@order;
});

print "\nTHE SAME WALK, REPEATED (the 2nd and 3rd walks of one tap)\n";
# _allSection is the memoised entry point every render path calls.
my $first = LBF::_allSection($releases);
bench('_allSection (memo hit)', 20, sub { LBF::_allSection($releases) });
my $again = LBF::_allSection($releases);
printf "%50s%s\n", '-> ', ($first == $again ? 'same arrayref returned (memo working)'
                                            : 'REBUILT — memo not hitting!');

# A settings change has to land on the very next walk.
{
    no warnings 'once';   # %LBF::PREFS lives in the eval'd code above
    local $LBF::PREFS{all_type_single} = 1;
    my $changed = LBF::_allSection($releases);
    printf "%50s%s\n", '-> ',
        ($changed != $first && @$changed >= @$first)
            ? sprintf('pref change rebuilds (%d -> %d releases)', scalar @$first, scalar @$changed)
            : 'PREF CHANGE NOT SEEN — signature is wrong!';
}

{
    LBF::_benchAgeMemo();
    my $aged = LBF::_allSection($releases);
    printf "%50s%s\n", '-> ',
        $aged != $first ? 'expiry rebuilds' : 'EXPIRY IGNORED — memo never lets go!';
}

# For You takes TWO sources (LB feed + MuSpy). Both have to gate the memo, because
# _mergeMuSpy builds a fresh list from them every call.
print "\nFOR YOU (two-source identity)\n";
{
    my $muspy = [];
    my $fy1   = LBF::_forYouSection($releases, $muspy);
    my $fy2   = LBF::_forYouSection($releases, $muspy);
    printf "%50s%s\n", '-> ', ($fy1 == $fy2 ? 'memo hit on identical sources'
                                            : 'REBUILT — For You memo not hitting!');
    my $fy3 = LBF::_forYouSection($releases, [ @$muspy ]);   # different MuSpy ref
    printf "%50s%s\n", '-> ', ($fy3 != $fy1 ? 'a new MuSpy list rebuilds'
                                            : 'STALE — MuSpy ref not gating the memo!');
}

print "\nCOMPONENT COSTS (per walk, over the kept list)\n";
my @names = map { LBF::_pickValue($_, 'artist_credit_name', 'artist_name', 'artist') } @$sorted;
bench(sprintf('_norm x %d', scalar @names), $N, sub { [ map { LBF::_norm($_) } @names ] });
my @dates = map { $_->{release_date} // '' } @$sorted;
my %distinct = map { $_ => 1 } @dates;
bench(sprintf('_weekStart x %d (%d distinct)', scalar @dates, scalar keys %distinct),
      $N, sub { [ map { LBF::_weekStart($_) } @dates ] });
bench('_sortWithin(artist)', $N, sub { LBF::_sortWithin($sorted, 'artist') });
# Genre bucketing only exists on the `alpha` branch.
bench('_bucketFor x all (genre filter/picker)', $N, sub { [ map { LBF::_bucketFor($_, {}) } @$sorted ] })
    if defined &LBF::_bucketFor;
