#!/usr/bin/env perl
#
# t_review_fixes.pl — regression guard for the three defects found in the 0.9.141
# pre-release review. Each one reproduced against the REAL sub bodies before the
# fix and passes after it; this keeps them from coming back.
#
#   perl tools/t_review_fixes.pl
#
# It reimplements nothing: sub bodies are extracted VERBATIM from Browse.pm/API.pm
# (the tools/bench_walk.pl + matcher_sync_check.py trick) and driven against stub
# cache/prefs objects, so the assertions track the shipped code. No LMS needed.
#
#   1. lbf:bcmatch: must NOT be bumped for a favurl change. It has no automatic
#      repopulation (manual "Search Bandcamp" only), so a bump deletes every pinned
#      Bandcamp-only match — the 0.9.42 mistake, reverted in 0.9.47, re-made in
#      0.9.141. Checked by reading the key builder at git HEAD (what a user has
#      installed) and comparing it with the working tree.
#   2. clearFeedCache('user') must drop the MuSpy MEMO as well as its cache key —
#      getMuSpyReleases checks the memo first, so cache-only leaves Refresh serving
#      the copy it was meant to replace.
#   3. An All Releases week whose releases are all filtered out by the active
#      Albums/Singles & EPs lens must say "no results", not render Options rows and
#      nothing else. (The week rows are built before the lens is known.)
#
# Exit 0 = all three still fixed. Exit 1 = at least one has regressed.
use strict;
use warnings;
use File::Spec;

my $ROOT = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
my $BROWSE = File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');
my $API    = File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'API.pm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}

# Brace-matched verbatim extraction of a named sub (bench_walk.pl's `grab`).
sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name\n";
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

my $browse_src = slurp($BROWSE);
my $api_src    = slurp($API);

# git-HEAD copy of Browse.pm = what a user currently has installed (0.9.120).
my $head_src = `cd '$ROOT' && git show HEAD:ListenBrainzFreshReleases/Browse.pm`;
die "couldn't read Browse.pm at HEAD\n" unless length $head_src;

# --- shared stubs (defined ONCE; each finding's package just uses them) -----
{
    # A stand-in for Slim::Utils::Cache: get/set/remove over a plain hash.
    package StubCache;
    sub new { bless { d => {} }, shift }
    sub get { $_[0]{d}{$_[1]} }
    sub set { $_[0]{d}{$_[1]} = $_[2]; 1 }
    sub remove { delete $_[0]{d}{$_[1]} }
    package StubPrefs;
    sub new { my ($c,%p) = @_; bless { %p }, $c }
    sub get { $_[0]{ $_[1] } }
    sub set { $_[0]{ $_[1] } = $_[2] }
    package StubLog;
    sub new { bless {}, shift }
    sub info {} sub warn {} sub error {} sub is_info { 0 }
}
my $STUBS = "use strict; use warnings;\n";

# ===========================================================================
print "\nFINDING 1 — lbf:bcmatch bump orphans every pinned Bandcamp match\n";
print "-" x 74, "\n";
{
    my $pkg = <<"CODE";
package F1;
$STUBS
package F1;
@{[ grab($head_src,   '_bcMatchKey')  ]}
@{[ grab($head_src,   '_bcMarkerKey') ]}
sub old_match  { _bcMatchKey(\$_[0]) }
sub old_marker { _bcMarkerKey(\$_[0]) }
package F1new;
$STUBS
package F1new;
@{[ grab($browse_src, '_bcMatchKey')  ]}
@{[ grab($browse_src, '_bcMarkerKey') ]}
sub new_match  { _bcMatchKey(\$_[0]) }
sub new_marker { _bcMarkerKey(\$_[0]) }
1;
CODE
    eval $pkg or die "F1 eval: $@";

    my $id    = 'panda bear sonic boom|a ? of when';
    my $cache = StubCache->new;

    # State on a user's box BEFORE the update: a hand-curated Bandcamp match,
    # pinned by a manual "Search Bandcamp" tap, plus its already-searched marker.
    $cache->set(F1::old_match($id),  [{ name => 'A ? of WHEN', _svc => 'Bandcamp' }]);
    $cache->set(F1::old_marker($id), 1);

    # After the update, the running code reads the NEW keys.
    my $match  = $cache->get(F1new::new_match($id));
    my $marker = $cache->get(F1new::new_marker($id));

    print "    key at HEAD (installed): " . F1::old_match($id) . "\n";
    print "    key in working tree    : " . F1new::new_match($id) . "\n";

    ok($match, 'pinned Bandcamp match still reachable after the update');
    ok(!($marker && !$match),
       'no "already searched, not found" state left behind (marker without a match)');
}

# ===========================================================================
print "\nFINDING 2 — clearFeedCache('user') leaves the MuSpy memo in place\n";
print "-" x 74, "\n";
{
    # The memo is checked BEFORE the SQLite cache in getMuSpyReleases — assert that
    # from the real source, since it is what makes a live memo authoritative.
    my $gm = grab($api_src, 'getMuSpyReleases');
    my $memo_at  = index($gm, '_memoGet');
    my $cache_at = index($gm, '$cache->get($cacheKey)');
    ok($memo_at >= 0 && $cache_at >= 0 && $memo_at < $cache_at,
       'getMuSpyReleases consults the in-process memo before the cache');

    my $pkg = <<"CODE";
package F2;
$STUBS
package F2;
our \$cache = StubCache->new;
our \$prefs = StubPrefs->new(
    days => 14, foryou_past => 1, foryou_future => 0,
    username => 'simon', muspy_userid => ' muspyuser ',
);
our \$log = StubLog->new;
our %FEED_MEMO;
use constant FEED_MEMO_TTL => 5;
@{[ grab($api_src, '_memoGet')  ]}
@{[ grab($api_src, '_memoSet')  ]}
@{[ grab($api_src, '_memoDrop') ]}
@{[ grab($api_src, 'clearFeedCache') ]}
1;
CODE
    eval $pkg or die "F2 eval: $@";

    my $uid      = 'muspyuser';                      # trimmed, as getMuSpyReleases does
    my $muspyKey = 'lbf:muspy:' . $uid;
    my $feedKey  = 'lbf:feed:user:' . join('|', 'simon', 'release_date', 'true', 'false', 14);

    my $stale = [{ release_name => 'STALE MuSpy copy' }];

    # A walk has just run: both feeds are in SQLite and memoed in-process.
    $F2::cache->set($feedKey,  [{ release_name => 'LB feed' }]);
    $F2::cache->set($muspyKey, $stale);
    F2::_memoSet($feedKey,  [{ release_name => 'LB feed' }]);
    F2::_memoSet($muspyKey, $stale);

    # User taps "Refresh (force update now)" on New Releases for You.
    F2::clearFeedCache('F2', 'user');

    # Control: the LB feed is dropped from BOTH layers (proves the harness works).
    ok(!$F2::cache->get($feedKey) && !F2::_memoGet($feedKey),
       'LB feed dropped from cache AND memo (control)');

    ok(!$F2::cache->get($muspyKey), 'MuSpy dropped from the SQLite cache');

    # The rebuild that Refresh triggers re-enters getMuSpyReleases within the memo's
    # 5s TTL: `if (my $memo = _memoGet($cacheKey)) { onDone($memo); return }`.
    my $served = F2::_memoGet($muspyKey);
    ok(!$served, 'MuSpy dropped from the memo too, so the refresh actually re-fetches');
    print "    refresh would serve: " . ($served ? $served->[0]{release_name} : '(re-fetch)') . "\n";
}

# ===========================================================================
print "\nFINDING 3 — an All Releases week can open to an empty list\n";
print "-" x 74, "\n";
{
    my $pkg = <<"CODE";
package F3;
$STUBS
package F3;
our \$prefs = StubPrefs->new(all_sort => 'release_date');
our %_SINGLE_FAMILY = (single => 1, ep => 1);
my %_WEEK_START;                             # _weekStart's memo (0.9.139)
sub cstring { \$_[1] }                       # token back, so rows are identifiable
sub _weekLabel { 'W/C ' . \$_[1] }
sub _weekBadgeImage { 'badge.png' }
sub _effectiveView { ('singles_eps', 1, 1) } # user is on Singles & EPs, both families ticked
sub _warmArtistSorts { }
sub _pageSection { (\$_[2], []) }            # no paging in this fixture
sub _buildReleaseItem { { name => \$_[0]{release_name}, type => 'link' } }
sub _sectionHeader { { name => \$_[1], type => 'header' } }
sub _viewToggle { ({ name => 'PLUGIN_LBF_SHOWING', type => 'link' }) }
sub _sortToggle { ({ name => 'PLUGIN_LBF_SORTED_BY', type => 'link' }) }
sub _refreshItem { ({ name => 'PLUGIN_LBF_REFRESH_FEED', type => 'link' }) }
@{[ grab($browse_src, '_viewFilter')      ]}
@{[ grab($browse_src, '_sortWithin')      ]}
@{[ grab($browse_src, '_weekStart')       ]}
@{[ grab($browse_src, '_buildAllLanding') ]}
1;
CODE
    eval $pkg or die "F3 eval: $@";

    # One week, albums only — nothing for the Singles & EPs lens to show.
    my $releases = [
        { release_name => 'Album One', release_date => '2026-07-20', release_group_primary_type => 'Album' },
        { release_name => 'Album Two', release_date => '2026-07-21', release_group_primary_type => 'Album' },
    ];

    my $items = F3::_buildAllLanding($releases, undef, 1);
    ok(scalar(@$items) == 1, 'the week still lists on the landing page');

    my @out;
    $items->[0]{url}->(undef, sub { @out = @{ $_[0]{items} } });

    my @names = map { $_->{name} // '' } @out;
    print "    week opens with: " . join(' | ', @names) . "\n";

    my $releaseRows = grep { ($_->{name} // '') =~ /^Album / } @out;
    ok($releaseRows == 0, 'the Singles & EPs lens correctly hides the albums (setup)');
    ok(scalar(grep { ($_->{name} // '') eq 'PLUGIN_LBF_NO_RESULTS' } @out),
       'an empty week says so instead of showing only Options rows');

    # CONTROL: a week that DOES have something in the active family must be
    # untouched — releases listed, no stray "no results" row.
    my $mixed = [
        @$releases,
        { release_name => 'A Single',  release_date => '2026-07-22', release_group_primary_type => 'Single' },
        { release_name => 'An EP',     release_date => '2026-07-23', release_group_primary_type => 'EP' },
    ];
    my $mixedItems = F3::_buildAllLanding($mixed, undef, 1);
    my @m;
    $mixedItems->[0]{url}->(undef, sub { @m = @{ $_[0]{items} } });
    my @mnames = map { $_->{name} // '' } @m;
    print "    populated week : " . join(' | ', @mnames) . "\n";
    ok((grep { $_ eq 'A Single' } @mnames) && (grep { $_ eq 'An EP' } @mnames)
       && !(grep { $_ eq 'PLUGIN_LBF_NO_RESULTS' } @mnames)
       && !(grep { /^Album / } @mnames),
       'a populated week is unchanged (singles/EPs listed, no "no results", albums still filtered)');
}

print "\n", "=" x 74, "\n";
printf("%d passed, %d failed\n", $pass, $fail);
exit($fail ? 1 : 0);
