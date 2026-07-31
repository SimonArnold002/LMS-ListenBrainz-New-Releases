#!/usr/bin/env perl
#
# t_trending_empty.pl — regression guard for the 0.9.149 Trending Albums fix.
#
#   perl tools/t_trending_empty.pl
#
# THE BUG (diagnosed live 2026-07-30, This Month AND This Year both empty):
# _buildAlbumsData's streaming gate settled an EMPTY aggregate with $short = 0, so
# a build in which every follower's release-group stats came back empty — a
# transient LB blip, a fan-out that all timed out — was cached at the FULL TTL:
# 7 days for This Month, 30 days for This Year. The view then served that empty
# arrayref straight from cache ($cache->get is truthy for []), rendering
# "No trending data yet" without issuing a single request. Confirmed on the server:
# opening This Month produced the message and ZERO new log lines while the LB API
# was answering 650 rows / 558 albums for the same 13 followers.
# Compounding it, the empty view rendered ONLY the message — no Refresh row — so
# there was no way out but the TTL or the period rolling over (January, This Year).
#
# Sub bodies are extracted VERBATIM from Browse.pm (the tools/bench_walk.pl trick)
# and driven against stub cache/prefs/API/timers, so the assertions track shipped
# code rather than a paraphrase of it. No LMS needed.
#
#   1. Empty aggregate  -> cached at the INCONCLUSIVE TTL (1h), not 7d/30d.
#   2. Healthy build    -> still cached at the full 7d / 30d TTL (fix isn't a
#                          blanket downgrade — a good build must stay cached).
#   3. Gate keeps zero  -> unchanged: ungated result, short TTL.
#   4. Empty view       -> carries a working Refresh row whose tap drops the
#                          aggregate key, so the next open rebuilds.
#   5. Key is :7:       -> the bump that abandons already-poisoned empties.
#
# Exit 0 = all still fixed. Exit 1 = at least one regressed.
use strict;
use warnings;
use File::Spec;

my $ROOT   = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
# Overridable so the suite can be ANTI-TESTED against a mutated copy (put the
# pre-0.9.149 lines back and every assertion below must fail).
my $BROWSE = $ENV{LBF_BROWSE} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');

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

# Brace-matched verbatim extraction of a named sub.
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

my $src = slurp($BROWSE);

# ---------------------------------------------------------------- stub world --
{
    package T::Cache;
    sub new { bless { d => {}, ttl => {}, sets => [] }, shift }
    sub get { my ($s, $k) = @_; return $s->{d}{$k} }
    sub set {
        my ($s, $k, $v, $t) = @_;
        $s->{d}{$k} = $v; $s->{ttl}{$k} = $t;
        push @{ $s->{sets} }, [ $k, $t ];
        return 1;
    }
    sub remove { my ($s, $k) = @_; delete $s->{d}{$k}; delete $s->{ttl}{$k} }
}
{
    package T::Prefs;
    sub new { bless { d => { username => 'CrystalGipsy' } }, shift }
    sub get { my ($s, $k) = @_; return $s->{d}{$k} }
    sub set { my ($s, $k, $v) = @_; $s->{d}{$k} = $v }
}
{
    package T::Log;
    sub new { bless {}, shift }
    sub warn { 1 } sub info { 1 } sub error { 1 } sub is_info { 0 }
}
{   # Timers: the gate's watchdog must never fire in-process.
    package Slim::Utils::Timers;
    my $n = 0;
    sub setTimer { return ++$n }
    sub killSpecific { 1 }
}

# The API the build calls. %API_STATS is what each follower's release-groups
# request answers with — the knob every scenario below turns.
our %API_STATS;
our @API_FOLLOWERS;
{
    package Plugins::ListenBrainzFreshReleases::API;
    sub getFollowing {
        my ($class, %a) = @_;
        $a{onDone}->([ @main::API_FOLLOWERS ]);
    }
    sub getLatestListenTs {          # every follower is active
        my ($class, $u, $cb, %a) = @_;
        $cb->(time());
    }
    sub getUserTopReleaseGroups {
        my ($class, $u, %a) = @_;
        $a{onDone}->($main::API_STATS{$u} || []);
    }
    sub getReleaseGroupMetadata { my ($class, $mbids, $cb) = @_; $cb->({}) }
    sub getReleaseGroupByName   { my ($class, $ar, $al, $cb) = @_; $cb->(undef) }
    sub clearFeedCache          { 1 }
}

my $CACHE = T::Cache->new;
my $PREFS = T::Prefs->new;

# ------------------------------------------------------- the code under test --
{
    package T;
    use strict;
    use warnings;

    our $cache = $CACHE;
    our $prefs = $PREFS;
    our $log   = T::Log->new;

    # Constants the grabbed subs close over, VERBATIM values from Browse.pm.
    use constant TREND_ALBUMS_MONTH_TTL     => 7 * 86400;
    use constant TREND_ALBUMS_YEAR_TTL      => 30 * 86400;
    use constant PLAYLIST_INCONCLUSIVE_TTL  => 1 * 3600;
    use constant PLAYLIST_TIMEOUT           => 45;
    use constant TRENDING_MAX               => 50;
    use constant FOLLOWER_MAX               => 250;
    use constant FOLLOWER_FANOUT            => 6;
    use constant FANOUT_DEADLINE            => 30;
    use constant FOLLOWER_STALE_DAYS        => 183;
    use constant MENU_REFRESH               => 'refresh.png';
    use constant MENU_SORT                  => 'sort.png';

    # Collaborators that aren't what's being tested.
    our @ADAPTERS   = ( { name => 'Qobuz' }, { name => 'Tidal' } );
    our $FIND_MATCH = 1;                      # does the streaming gate keep an album?
    sub _orderedAdapters { return @ADAPTERS }
    sub _findPlayable {
        my ($client, $cb, $artist, $title, $x, $force, $year, $type) = @_;
        $cb->($FIND_MATCH ? { items => [ { name => "$artist - $title", _year => '2026' } ] }
                          : { items => [ { type => 'text', name => 'no match' } ] });
    }
    sub _blockedSet      { return { mbids => {}, names => {} } }   # real shape; _isBlocked derefs both
    sub _dbg             { 1 }
    sub _wantHeaders     { 1 }
    sub _sectionHeader   { my ($c, $tok) = @_; return { name => $tok, type => 'text', _hdr => 1 } }
    sub _trendingAlbumRow{ my ($c, $a) = @_; return { name => $a->{title}, type => 'link' } }
    sub _trendingSortToggle { return { name => 'sorted-by', type => 'link' } }
    sub _trendingResolvedKey { return 'lbf:trending:resolved:test' }
    sub _dropTrendingCount   { 1 }
    sub cstring          { my (undef, $t) = @_; return $t }
}

for my $name (qw(_albumsDataKey _buildAlbumsData _aggregateAlbums _fanFollowers
                 _activeFollowers _trendBlocked _isBlocked _trendingAlbumsResult
                 _refreshItem)) {
    my $body = grab($src, $name);
    # `our` in the package block above is lexically scoped to that block, so each
    # eval must re-declare the module globals the grabbed body closes over.
    eval "package T; our (\$cache, \$prefs, \$log); $body 1;" or die "eval $name: $@";
}

# ------------------------------------------------------------------ scenarios --
# One follower row = one album, shaped like a parsed LB release-groups entry.
sub rows {
    my (@titles) = @_;
    my $i = 0;
    return [ map { { release_group_mbid => sprintf('mb-%02d', ++$i), title => $_,
                     artist => 'Artist ' . $i, artist_mbid => '', caa_id => undef,
                     caa_release_mbid => '', listen_count => 10 } } @titles ];
}

sub build {
    my (%o) = @_;
    $CACHE->{d} = {}; $CACHE->{ttl} = {}; $CACHE->{sets} = [];
    @API_FOLLOWERS = @{ $o{followers} || [ 'terant', 'blism' ] };
    %API_STATS     = %{ $o{stats}     || {} };
    $T::FIND_MATCH = exists $o{gate} ? $o{gate} : 1;

    my $got;
    T::_buildAlbumsData('player', ($o{range} || 'this_month'), sub { $got = shift }, 0);
    my $key = T::_albumsDataKey(($o{range} || 'this_month'), 'CrystalGipsy');
    return ($got, $key, $CACHE->{ttl}{$key});
}

print "\n1. An empty aggregate is INCONCLUSIVE, not a 7d/30d fact\n";
{
    # Every follower answers empty — exactly what a transient LB stats blip looks like.
    my ($data, $key, $ttl) = build(stats => { terant => [], blism => [] });
    ok(ref $data eq 'ARRAY' && !@$data, 'empty build returns an empty list');
    ok(defined $ttl, 'the empty result is still cached (so a browse storm re-fetches once, not per open)');
    ok(defined $ttl && $ttl == 3600,
       "empty This Month cached at the 1h inconclusive TTL (got " . (defined $ttl ? $ttl : 'undef') . ")");

    my (undef, $ykey, $yttl) = build(range => 'this_year', stats => { terant => [], blism => [] });
    ok(defined $yttl && $yttl == 3600,
       "empty This Year cached at 1h, NOT 30d (got " . (defined $yttl ? $yttl : 'undef') . ")");
}

print "\n2. A healthy build is still cached at the full TTL\n";
{
    my ($data, $key, $ttl) = build(stats => {
        terant => rows('Inferno', 'Roses'),
        blism  => rows('Inferno', 'Role Model Hermit'),
    });
    ok(ref $data eq 'ARRAY' && scalar(@$data), 'healthy build returns albums (' . scalar(@{ $data || [] }) . ')');
    ok(defined $ttl && $ttl == 7 * 86400,
       "This Month cached 7d (got " . (defined $ttl ? $ttl : 'undef') . ")");

    my ($ydata, undef, $yttl) = build(range => 'this_year', stats => {
        terant => rows('Inferno'), blism => rows('Inferno'),
    });
    ok(defined $yttl && $yttl == 30 * 86400,
       "This Year cached 30d (got " . (defined $yttl ? $yttl : 'undef') . ")");
}

print "\n3. Gate keeps nothing -> ungated + short TTL (unchanged behaviour)\n";
{
    my ($data, $key, $ttl) = build(gate => 0, stats => {
        terant => rows('Inferno', 'Roses'), blism => rows('Inferno'),
    });
    ok(ref $data eq 'ARRAY' && scalar(@$data), 'serves the ungated list rather than nothing');
    ok(defined $ttl && $ttl == 3600, 'gate-kept-zero still caches 1h');
}

print "\n4. The empty view carries a working Refresh row\n";
{
    my $res = T::_trendingAlbumsResult('player', [], 'this_year', 'h');
    my @items = @{ $res->{items} };
    my ($refresh) = grep { ref $_ eq 'HASH' && ($_->{image} // '') eq 'refresh.png' } @items;
    ok($refresh, 'empty view includes the shared Refresh row');
    ok(scalar(grep { ($_->{name} // '') eq 'PLUGIN_LBF_NO_TRENDING' } @items),
       'empty view still explains why it is empty');
    ok(($refresh && ($refresh->{nextWindow} // '') eq 'refresh'),
       'Refresh reloads in place (nextWindow), not as a drill');

    # Tapping it must drop THIS range's aggregate key — the only escape from a
    # poisoned build, and the reason the row has to be on the empty view.
    # Guarded so a missing row FAILS these rather than dying mid-suite (the
    # anti-test runs against a copy that has no Refresh row at all).
    my $key  = T::_albumsDataKey('this_year',  'CrystalGipsy');
    my $mkey = T::_albumsDataKey('this_month', 'CrystalGipsy');
    $CACHE->{d}{$key} = []; $CACHE->{d}{$mkey} = [];
    if ($refresh && ref $refresh->{url} eq 'CODE') {
        $refresh->{url}->('player', sub { 1 }, {}, $refresh->{passthrough}[0]);
    }
    ok($refresh && !exists $CACHE->{d}{$key}, 'tapping Refresh removes the This Year aggregate key');
    ok($refresh && exists $CACHE->{d}{$mkey}, '...and only that range (This Month untouched)');

    # A populated view must keep BOTH rows.
    my $full = T::_trendingAlbumsResult('player',
        [ { title => 'Inferno', artist => 'Boards of Canada', breadth => 7 } ], 'this_month', 'h');
    my @fitems = @{ $full->{items} };
    ok(scalar(grep { ($_->{image} // '') eq 'refresh.png' } @fitems), 'populated view still has Refresh');
    ok(scalar(grep { ($_->{name}  // '') eq 'sorted-by'   } @fitems), 'populated view still has the sort toggle');
}

print "\n5. The cache key is bumped, so poisoned empties are abandoned on update\n";
{
    my $key = T::_albumsDataKey('this_month', 'CrystalGipsy');
    # scalar() on every match/grep below: a bare m// or grep in ok()'s LIST
    # context returns the match list, which shifts the message into $cond and
    # makes the assertion pass on anything truthy (it did — caught by anti-test).
    ok(scalar($key =~ /^lbf:trending:albums:7:/), "key is at :7: (got $key)");
    ok(scalar($key =~ /this_month/ && $key =~ /qobuz,tidal/), 'key still carries range + service order');
}

printf("\n%d passed, %d failed\n", $pass, $fail);
exit($fail ? 1 : 0);
