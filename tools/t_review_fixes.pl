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
# LBF_BROWSE points this suite at a MUTATED copy of Browse.pm so every finding
# here can be anti-tested (break the fix, watch the assertion go red). Without it
# the suite reads the working tree, which is the normal run. The other suites in
# tools/ already take this env var; this one did not, which meant an anti-test run
# silently exercised the UNMUTATED file and "passed" — proving nothing.
my $BROWSE = $ENV{LBF_BROWSE}
    || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');
# LBF_API is the same seam for API.pm, and it was missing for the same reason
# LBF_BROWSE once was: finding 2 lives entirely in API.pm, so with no way to point
# the suite at a mutated copy an anti-test run silently read the working tree and
# "passed". Added when finding 2 moved onto the store (0.9.166).
my $API    = $ENV{LBF_API}
    || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'API.pm');

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

# ---------------------------------------------------------------------------
# A minimal DB::kver/kverNum, built from the REAL KEY_VERSIONS in DB.pm.
#
# Since the caching rework the key builders ask DB for a family's version rather
# than spelling it out, so a harness that evals a lifted sub body has to answer
# that call. It is derived from the shipped table rather than restated here, for
# the usual reason: a hand-copied constant drifts silently, and a suite that
# asserts a key it made up itself asserts nothing. Loading the real DB.pm would
# pull in DBI and a real file for two hash lookups.
# ---------------------------------------------------------------------------
{
    my $db_src = slurp($ENV{LBF_DB}
        || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'DB.pm'));
    my ($body) = $db_src =~ /use constant KEY_VERSIONS => \{(.*?)\n\};/s
        or die "no KEY_VERSIONS in DB.pm\n";
    my %v = $body =~ /'([^']+)'\s*=>\s*(\d+)/g;
    die "KEY_VERSIONS parsed empty\n" unless keys %v;
    no strict 'refs';
    *{'Plugins::ListenBrainzFreshReleases::DB::kver'}    = sub { $_[0] . ($v{$_[0]} // 0) . ':' };
    *{'Plugins::ListenBrainzFreshReleases::DB::kverNum'} = sub { $v{$_[0]} // 0 };
    $INC{'Plugins/ListenBrainzFreshReleases/DB.pm'} = __FILE__;
}

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
print "\nFINDING 1 — a pinned Bandcamp match cannot be orphaned by a version bump\n";
print "-" x 74, "\n";
{
    # WHAT THIS ASSERTION USED TO BE, and why it changed shape rather than going
    # away. It compared the HEAD `_bcMatchKey` with the working-tree one and failed
    # if they differed — the 0.9.42 mistake (reverted in 0.9.47) and the 0.9.141
    # repeat (reverted in the pre-release review). Both times the bump would have
    # silently deleted every hand-curated Bandcamp-only match, which for those
    # releases is the album's ONLY playable entry.
    #
    # A pin is now a row in the `bandcamp_pin` TABLE, keyed on the release id with
    # NO VERSION IN ITS IDENTITY AT ALL, so the bump is no longer a thing that can
    # be done. The property this test was really protecting is "a pin survives",
    # and it is now protected two ways, in the two places that can each see half of
    # it: t_db.pl proves a pin survives the dev-build wipe against a real file, and
    # this section proves the versioned key it used to live under is gone and has
    # not crept back.
    ok(!scalar($browse_src =~ /sub _bcMatchKey\b/),
       '_bcMatchKey no longer exists — there is no key left to bump');
    ok(scalar($head_src =~ /sub _bcMatchKey\b/),
       '...and it DID exist at HEAD, so this assertion is comparing something real');

    # A QUOTED literal, not any mention: the comments here deliberately recount the
    # 0.9.42/0.9.141 history, and a test that failed on its own explanation would
    # get the explanation deleted. The only quoted `lbf:bcmatch:` left in the plugin
    # is in DB::importPin, which READS the old cache to carry a pre-rework pin
    # across; one in Browse.pm would mean a pin being written somewhere disposable
    # again.
    my @lits = ($browse_src =~ /(['"]lbf:bcmatch:)/g);
    ok(!scalar(@lits),
       'no quoted lbf:bcmatch: key remains in Browse.pm (found ' . scalar(@lits) . ')');

    ok(scalar($browse_src =~ /DB::bcPinGet\(/) && scalar($browse_src =~ /DB::bcPinPut\(/),
       'the pin is read and written through the durable table, not through the store handle');

    # The marker ("searched Bandcamp, found nothing") is the OPPOSITE case and must
    # stay disposable: it is re-derivable by tapping Search again, and pinning it
    # forever would leave a release stuck reading "not found" after Bandcamp
    # gained the album.
    ok(scalar($browse_src =~ /sub _bcMarkerKey\b/) && scalar($browse_src =~ /kver\(["']lbf:bcdone:["']\)/),
       'the "already searched" MARKER is still a versioned, disposable store key');
}

# ===========================================================================
print "\nFINDING 2 — clearFeedCache('user') leaves the MuSpy memo in place\n";
print "-" x 74, "\n";
{
    # THE LOWER LAYER IS NOW THE STORE, NOT Slim::Utils::Cache (0.9.166). The
    # PROPERTY this finding protects is unchanged and is the whole point: Refresh
    # must invalidate BOTH layers, for MuSpy as well as for the LB feed. Only the
    # name of the lower one moved, so these assertions follow it rather than
    # continuing to look for a `$cache->remove` that is no longer the mechanism.
    #
    # What DID change on purpose: Refresh no longer DELETES the lower layer. It
    # marks the stored feed stale, so the user keeps seeing releases while the
    # re-fetch runs behind them instead of staring at an empty list. Asserted below.
    my $gm = grab($api_src, 'getMuSpyReleases');
    my $memo_at  = index($gm, '_memoGet');
    my $store_at = index($gm, '_feedFromStore');
    ok($memo_at >= 0 && $store_at >= 0 && $memo_at < $store_at,
       'getMuSpyReleases consults the in-process memo before the store');

    my $pkg = <<"CODE";
package F2;
$STUBS
package F2;
our \$cache = StubCache->new;
our \$prefs = StubPrefs->new(
    weeks_past => 1, weeks_future => 2, foryou_past => 1, foryou_future => 1,
    username => 'simon', muspy_userid => ' muspyuser ',
);
our \$log = StubLog->new;
our %FEED_MEMO;
use constant FEED_MEMO_TTL => 5;
@{[ grab($api_src, '_memoGet')  ]}
@{[ grab($api_src, '_memoSet')  ]}
@{[ grab($api_src, '_memoDrop') ]}
@{[ grab($api_src, '_today')    ]}
@{[ ($api_src =~ /^(use constant WEEKS_MAX_SIDE\s*=>.*?;)/m)[0] ]}
@{[ ($api_src =~ /^(use constant WEEKS_PAST_DEFAULT\s*=>.*?;)/m)[0] ]}
@{[ ($api_src =~ /^(use constant WEEKS_FUTURE_DEFAULT\s*=>.*?;)/m)[0] ]}
@{[ ($api_src =~ /^(my %WEEK_GATES = \(.*?\n\);)/ms)[0] ]}
@{[ grab($api_src, '_clampWeeks')   ]}
@{[ grab($api_src, 'sectionWeeks')  ]}
@{[ grab($api_src, '_feedMemoKey')  ]}
@{[ grab($api_src, 'clearFeedCache') ]}
1;
package Plugins::ListenBrainzFreshReleases::DB;
# A SPY, not a stub: it records which feeds were invalidated so the assertions can
# be about what Refresh actually did, and it deliberately does NOT delete anything
# — a store that dropped rows here would hide the very regression being pinned.
our \@INVALIDATED;
sub feedInvalidate { push \@INVALIDATED, \$_[0]; 1 }
1;
CODE
    eval $pkg or die "F2 eval: $@";

    my $uid      = 'muspyuser';                      # trimmed, as getMuSpyReleases does
    my $muspyKey = 'lbf:muspy:' . $uid;
    # The key is asked for THE WAY THE FETCHER ASKS FOR IT (0.9.185): one builder,
    # fed from sectionWeeks. Spelling the join out here again would make this suite
    # pass on the day the fetcher and clearFeedCache drifted apart, which is the
    # one thing it exists to catch.
    my $feedKey  = F2::_feedMemoKey('foryou', 'release_date', F2::sectionWeeks('foryou'));

    my $stale = [{ release_name => 'STALE MuSpy copy' }];

    # A walk has just run: both feeds are memoed in-process over a stored copy.
    F2::_memoSet($feedKey,  [{ release_name => 'LB feed' }]);
    F2::_memoSet($muspyKey, $stale);

    # User taps "Refresh (force update now)" on New Releases for You.
    @Plugins::ListenBrainzFreshReleases::DB::INVALIDATED = ();
    F2::clearFeedCache('F2', 'user');
    my %inv = map { $_ => 1 } @Plugins::ListenBrainzFreshReleases::DB::INVALIDATED;

    # Control: the LB feed is dropped from BOTH layers (proves the harness works).
    ok($inv{'user:simon'} && !F2::_memoGet($feedKey),
       'LB feed invalidated in the store AND dropped from the memo (control)');

    ok($inv{'muspy:muspyuser'}, 'MuSpy invalidated in the store, under its own feed name');

    # The rebuild that Refresh triggers re-enters getMuSpyReleases within the memo's
    # 5s TTL: `if (my $memo = _memoGet($memoKey)) { onDone($memo); return }`.
    my $served = F2::_memoGet($muspyKey);
    ok(!$served, 'MuSpy dropped from the memo too, so the refresh actually re-fetches');
    print "    refresh would serve: " . ($served ? $served->[0]{release_name} : '(re-fetch)') . "\n";

    # And the deliberate improvement: nothing is deleted, so a Refresh whose fetch
    # then fails leaves the user with what they had rather than with nothing.
    my $cf = grab($api_src, 'clearFeedCache');
    ok(!scalar($cf =~ /\$cache->remove/),
       'Refresh no longer DELETES a feed — it marks it stale and deletes nothing');
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
# Genre collaborators of the week coderef. The NO_RESULTS guard this finding is
# about now lives INSIDE the _withGenres callback, so the stub must invoke that
# callback (synchronously, like a warm cache would) or the assertion below would
# pass vacuously by never reaching the guard at all.
use constant GENRE_WARM_MAX => 600;
sub _genresRow { () }                        # no genre row in this fixture
sub _selectedGenres { [] }                   # no genre filter set -> the cheap path
sub _genreSelectFilter { \$_[0] }
sub _withGenres { my (\$rels, \$cb) = \@_; \$cb->({}) }
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
