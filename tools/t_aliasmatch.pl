#!/usr/bin/env perl
#
# t_aliasmatch.pl — a streaming match for an artist credited under ANOTHER NAME, and
# the community-API-only artist lookup behind it and behind the radio.
#
#   perl tools/t_aliasmatch.pl
#
# WHY THIS EXISTS (2026-09-14). Two misses of the same shape:
#   * JOINT CREDITS. Qobuz credits several Dexys releases "Dexys, Kevin Rowland".
#     The shared matcher's artist rule is a word subset, and "kevin"/"rowland" are
#     not in "dexys midnight runners", so the whole credit is rejected although
#     "Dexys" alone passes. Simon reported Dexys' LOVE not matching in All Releases.
#   * RENAMED ARTISTS. Osees shares no word with Oh Sees; no word rule can join them.
# And the radio's name -> MBID lookup dropped its MusicBrainz fallback (Simon: the
# community API is built from MusicBrainz, so its miss is MusicBrainz's miss), which
# is only safe because the alias list now accepts a renamed artist.
#
# THE SHARED MATCHER IS NOT TOUCHED. _albumMatchesAlt CALLS _albumMatches; the sync
# rule (matcher_sync_check.py / t_matchersync.pl) keeps guarding the engine itself.
#
# Every sub is lifted VERBATIM from the shipped source and driven for real —
# _findPlayable included, with the real SingleFlight — over a fake clock, a fixture
# adapter and a stubbed community API. The adapter dies past 20 searches, so an
# alias pass that loops shows up as failed assertions, not as a hang.
#
# ANTI-TEST: point LBF_BROWSE / LBF_API at mutated copies.
#   * _albumMatchesAlt without the credit split            -> sections 1, 4
#   * the alias pass never runs (condition made false)     -> section 4
#   * the alias pass not limited to once (`!$alts` dropped) -> section 4
#   * a failed alias lookup treated as a clean miss        -> section 4
#   * getArtistAliases accepts on the fold alone (no alias) -> sections 2, 3, 4
#   * getArtistAliases without `length $mbid`              -> section 2
#   * a failed request cached                              -> section 2
#
# Exit 0 = all good. Exit 1 = at least one regressed.
use strict;
use warnings;
use utf8;
use FindBin;
use Time::HiRes ();
binmode(STDOUT, ':encoding(UTF-8)');

our $NOW = 1_000_000;
our @TIMERS;
BEGIN {
    $INC{'Slim/Utils/Timers.pm'} = 1;
    $INC{'Slim/Utils/Log.pm'}    = 1;
    *CORE::GLOBAL::time = sub { $main::NOW };
}
{ no warnings 'redefine'; *Time::HiRes::time = sub () { $main::NOW } }
{
    package Slim::Utils::Timers;
    sub setTimer     { my $t = [@_]; push @main::TIMERS, $t; $t }
    sub killSpecific { $_[0][4] = 1 if ref $_[0] eq 'ARRAY'; 1 }
    package Slim::Utils::Log;
    sub import { no strict 'refs'; *{ caller() . '::logger' } = sub { bless {}, 'T::Log' } }
    package T::Log;
    our @LINES;
    sub info { push @LINES, $_[1]; 1 } sub warn { push @LINES, $_[1]; 1 }
    sub error { push @LINES, $_[1]; 1 } sub is_info { 0 }
    package T::Cache;
    sub new    { bless { d => {}, ttl => {} }, shift }
    sub get    { $_[0]{d}{ $_[1] } }
    sub set    { $_[0]{d}{ $_[1] } = $_[2]; $_[0]{ttl}{ $_[1] } = $_[3]; 1 }
    sub remove { delete $_[0]{d}{ $_[1] } }
    package Plugins::ListenBrainzFreshReleases::DB;
    sub kver { $_[0] . '1:' }
}
require "$FindBin::Bin/../ListenBrainzFreshReleases/SingleFlight.pm";
$INC{'Plugins/ListenBrainzFreshReleases/SingleFlight.pm'} = 1;

my $BROWSE = $ENV{LBF_BROWSE} || "$FindBin::Bin/../ListenBrainzFreshReleases/Browse.pm";
my $APIF   = $ENV{LBF_API}    || "$FindBin::Bin/../ListenBrainzFreshReleases/API.pm";
sub slurp { open(my $fh, '<:encoding(UTF-8)', $_[0]) or die "$_[0]: $!"; local $/; <$fh> }
my $BSRC = slurp($BROWSE);
my $ASRC = slurp($APIF);

sub grabFrom {
    my ($src, $file, $n) = @_;
    $src =~ /\nsub \Q$n\E \{.*?\n\}\n/s or die "no sub $n in $file\n";
    return $&;
}
sub grabB { join '', map { grabFrom($BSRC, $BROWSE, $_) } @_ }
sub grabA { join '', map { grabFrom($ASRC, $APIF, $_) } @_ }
sub constant_line {
    my ($src, $file, $n) = @_;
    $src =~ /^(use constant \Q$n\E\s*=>.*?;)/m or die "no constant $n in $file\n";
    return "$1\n";
}

my $API = 'Plugins::ListenBrainzFreshReleases::API';
my $BR  = 'Plugins::ListenBrainzFreshReleases::Browse';

$BSRC =~ /(my \$HAVE_NFD = .*?^\);)/ms or die "no %FOLD block in $BROWSE\n";
my $FOLD = $1;

eval "package $BR;\nuse strict; use warnings; use utf8;\n"
   . "our \$cache = T::Cache->new; our \$log = bless {}, 'T::Log'; our \$albumDetailFlights;\n"
   . join('', map { constant_line($BSRC, $BROWSE, $_) }
                  qw(STREAM_FOUND_TTL STREAM_NOMATCH_TTL STREAM_SVC_TIMEOUT MISS_RETRY_SCHEDULE
                     SPOTIFY_FREE_PASSES VA_MBID))
   . "sub _spotifyBackingOff { 0 }\n"
   . $FOLD . "\n"
   . "our \@ADAPTERS; sub _orderedAdapters { \@ADAPTERS }\n"
   . "sub _bcMatchItems { () } sub _streamKey { 'stream:' . \$_[0] } sub _cid { 'player' }\n"
   . "sub _streamResult { \$_[1] } sub _rebuildStreamItems { \$_[0] } sub _attachFavUrl { }\n"
   . "sub _llRelType { undef }\n"
   . grabB(qw(_norm _stripFmt _asciiNorm _punctNorm _stripArtistPrefix _artistMatch _albumMatches
              _albumMatchesAlt _artistAltNames _streamId _cacheStream _stripStreamUrls
              _missRetryAt _findPlayable))
   . "1;" or die $@;

eval "package $API;\nuse strict; use warnings; use utf8;\n"
   . "our \$cache = T::Cache->new; our \$log = bless {}, 'T::Log';\n"
   . join('', map { constant_line($ASRC, $APIF, $_) } qw(MB_FOUND_TTL MB_EMPTY_TTL))
   . "our (\@HOSTED, %HOSTED);\n"
   . "sub _hostedGet { my (\$path, \$found, \$miss) = \@_; push \@HOSTED, \$path;\n"
   . "    my \$r = \$HOSTED{\$path}; return \$miss->() unless ref \$r eq 'HASH'; \$found->(\$r) }\n"
   . grabA(qw(splitArtistCredits _hostedSeg _foldEq getArtistAliases getArtistMbidByName))
   . "1;" or die $@;

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; my $b = $c ? 1 : 0; $b ? $p++ : $f++; printf "%s %s\n", ($b ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; my $c = (defined $g ? $g : '(undef)') eq (defined $w ? $w : '(undef)');
         $c ? $p++ : $f++;
         printf "%s %-60s got=%-24s want=%s\n", ($c ? 'ok  ' : 'FAIL'), $d,
                "'" . (defined $g ? $g : '(undef)') . "'", "'" . (defined $w ? $w : '(undef)') . "'" }
sub section { print "\n" . ('-' x 78) . "\n$_[0]\n" . ('-' x 78) . "\n" }

no strict 'refs';
my $N   = \&{"${BR}::_norm"};
my $AM  = \&{"${BR}::_albumMatches"};
my $AMA = \&{"${BR}::_albumMatchesAlt"};
use strict 'refs';

sub apiCache   { no strict 'refs'; ${"${API}::cache"} }
sub resetApi   { no strict 'refs'; ${"${API}::cache"} = T::Cache->new; @{"${API}::HOSTED"} = (); %{"${API}::HOSTED"} = () }
sub hosted     { no strict 'refs'; %{"${API}::HOSTED"} = (%{"${API}::HOSTED"}, @_) }
sub hostedLog  { no strict 'refs'; [ @{"${API}::HOSTED"} ] }

# ===========================================================================
section('1. _albumMatchesAlt — joint credits and other names, title always required');
{
    my ($dmr, $love) = ($N->('Dexys Midnight Runners'), $N->('LOVE'));

    ok('CONTROL: the shared matcher alone rejects "Dexys, Kevin Rowland"',
       !$AM->($dmr, $love, 'Dexys, Kevin Rowland', 'LOVE', 'LOVE'));
    ok('...and the helper accepts it on the "Dexys" part of the credit',
       $AMA->($dmr, $love, 'Dexys, Kevin Rowland', 'LOVE', 'LOVE', undef));
    ok('a plain "Dexys" credit still passes (the shared matcher answers first)',
       $AMA->($dmr, $love, 'Dexys', 'LOVE', 'LOVE', undef));
    ok('the right credit with the WRONG title is still rejected',
       !$AMA->($dmr, $love, 'Dexys, Kevin Rowland', 'Too-Rye-Ay', 'LOVE', undef));
    ok('a joint credit that does not contain our artist is still rejected',
       !$AMA->($dmr, $love, 'Kevin Rowland, Somebody Else', 'LOVE', 'LOVE', undef));

    my ($ohs, $pt) = ($N->('Oh Sees'), $N->('Protean Threat'));
    ok('CONTROL: a renamed artist fails with no other names', !$AMA->($ohs, $pt, 'Osees', 'Protean Threat', 'Protean Threat', []));
    ok('...and matches once its other name is supplied',
       $AMA->($ohs, $pt, 'Osees', 'Protean Threat', 'Protean Threat', [ $N->('Osees') ]));
    ok('...including when the service credits it jointly',
       $AMA->($ohs, $pt, 'Osees & Friends', 'Protean Threat', 'Protean Threat', [ $N->('Osees') ]));
    ok('another name never rescues a different title',
       !$AMA->($ohs, $pt, 'Osees', 'Carrion Crawler', 'Protean Threat', [ $N->('Osees') ]));
    ok('an empty artist on either side gets no extra leniency',
       !$AMA->('', $pt, 'Osees, Somebody', 'Other Title', 'Protean Threat', [ $N->('Osees') ]));
}

# ===========================================================================
section('2. getArtistAliases — the accept gate, the MBID override and the cache');
{
    my $call = sub {
        my ($name, $mbid) = @_;
        my $got = 'NOT CALLED BACK';
        $API->getArtistAliases($name, $mbid, sub { $got = shift });
        return $got;
    };
    my $FOUND = do { no strict 'refs'; &{"${API}::MB_FOUND_TTL"}() };
    my $EMPTY = do { no strict 'refs'; &{"${API}::MB_EMPTY_TTL"}() };

    resetApi();
    hosted('artist/Dexys/aliases' => { name => 'Dexys Midnight Runners', mbid => 'CCCE2053',
                                       aliases => [ 'Dexys', "Dexy's Midnight Runners" ] });
    my $e = $call->('Dexys');
    is('a name the artist is ALSO known by is accepted', $e->{mbid}, 'ccce2053');
    is('...with the canonical name', $e->{name}, 'Dexys Midnight Runners');
    is('...asked by name, with no ?mbid', hostedLog()->[0], 'artist/Dexys/aliases');
    is('...and cached for the found age', apiCache()->{ttl}{'lbf:aliases:1:n:dexys'}, $FOUND);
    $call->('Dexys');
    is('a second ask is a cache hit, no request', scalar(@{ hostedLog() }), 1);

    resetApi();
    # utf8::upgrade, because production strings are decoded from the service's JSON and
    # always carry the UTF-8 flag, and _norm folds diacritics only on a flagged string.
    # A literal below U+0100 is NOT flagged, so without this the fixture tests nothing
    # but the fixture (the harness trap t_matchersync.pl records).
    my $beyonce = "Beyonc\x{e9}"; utf8::upgrade($beyonce);
    hosted('artist/Beyonce/aliases' => { name => $beyonce, mbid => 'b1', aliases => [] });
    is('a diacritic correction is accepted on the fold', $call->('Beyonce')->{mbid}, 'b1');

    resetApi();
    hosted('artist/Nirvana%20Tribute/aliases' => { name => 'Nirvana', mbid => 'us-nirvana', aliases => [] });
    is('a popular namesake that is not about our name is rejected', $call->('Nirvana Tribute')->{mbid}, '');

    resetApi();
    hosted('artist/zzzqqq/aliases' => { name => 'zzzqqq' });
    my $u = $call->('zzzqqq');
    is('THE TRAP: an unknown artist echoes the name with no mbid — rejected', $u->{mbid}, '');
    is('...and that answer is cached for the empty age', apiCache()->{ttl}{'lbf:aliases:1:n:zzzqqq'}, $EMPTY);

    resetApi();
    hosted('artist/Nirvana/aliases?mbid=uk-nirvana' => { name => 'Nirvana', mbid => 'uk-nirvana', aliases => [] });
    is('with an MBID the request carries ?mbid= and the answer is accepted', $call->('Nirvana', 'UK-Nirvana')->{mbid}, 'uk-nirvana');
    is('...keyed by the MBID, not the name', exists apiCache()->{d}{'lbf:aliases:1:m:uk-nirvana'} ? 1 : 0, 1);

    resetApi();
    hosted('artist/Nirvana/aliases?mbid=uk-nirvana' => { name => 'Nirvana', mbid => 'us-nirvana', aliases => [] });
    is('...but a reply about a DIFFERENT MBID is rejected', $call->('Nirvana', 'uk-nirvana')->{mbid}, '');

    resetApi();
    is('a request that FAILS calls back undef', $call->('Down Band'), undef);
    ok('...caches nothing', !%{ apiCache()->{d} });
    $call->('Down Band');
    is('...so the next ask goes out again', scalar(@{ hostedLog() }), 2);

    resetApi();
    is('an empty name is answered without a request', $call->('   ')->{mbid}, '');
    is('...no request made', scalar(@{ hostedLog() }), 0);
}

# ===========================================================================
section('3. getArtistMbidByName — the radio lookup, community API only');
{
    resetApi();
    hosted('artist/Oh%20Sees/aliases' => { name => 'Osees', mbid => 'osees-1',
                                           aliases => [ 'OCS', 'Oh Sees', 'Thee Oh Sees' ] });
    my ($done, $err) = ('NOT CALLED', 'NOT CALLED');
    $API->getArtistMbidByName('Oh Sees', sub { $done = shift }, sub { $err = shift });
    is('a RENAMED artist resolves (the old fold gate threw this answer away)', $done, 'osees-1');

    resetApi();
    hosted('artist/zzzqqq/aliases' => { name => 'zzzqqq' });
    ($done, $err) = ('NOT CALLED', 'NOT CALLED');
    $API->getArtistMbidByName('zzzqqq', sub { $done = shift }, sub { $err = shift });
    is('an unknown artist resolves to undef', $done, undef);

    resetApi();
    ($done, $err) = ('NOT CALLED', 'NOT CALLED');
    $API->getArtistMbidByName('Down Band', sub { $done = shift }, sub { $err = shift });
    is('a failed request reaches the error callback', defined $err && $err ne 'NOT CALLED' ? 'error' : 'no error', 'error');
    is('...and not onDone', $done, 'NOT CALLED');

    my $body = grabA('getArtistMbidByName');
    ok('no MusicBrainz leg remains in the lookup', $body !~ /_mbGet|mbFallback|MB_DEFAULT_BASE_URL|musicbrainz/i);
}

# ===========================================================================
# The resolver. One fixture service; the catalogue decides what it returns, through
# the real _albumMatchesAlt, exactly as the shipped adapters do.
our (@SEARCHES, @CATALOGUE, $INCONCLUSIVE);
sub adapter {
    my ($name) = @_;
    return { name => $name, icon => '', query_enc => 'chars', run => sub {
        my ($client, $q, $an, $aln, $svc, $collect, $albumRaw, $alts) = @_;
        push @main::SEARCHES, { svc => $svc, alts => $alts };
        die "alias pass looped\n" if @main::SEARCHES > 20;
        return $collect->(undef) if $main::INCONCLUSIVE;
        my @hit = grep { $AMA->($an, $aln, $_->{artist}, $_->{title}, $albumRaw, $alts) } @main::CATALOGUE;
        $collect->([ map { +{ name => $_->{title}, _svctitle => $_->{title}, type => 'playlist' } } @hit ]);
    } };
}
sub resolve {
    my (%o) = @_;
    { no strict 'refs';
      ${"${BR}::cache"} = T::Cache->new; ${"${BR}::albumDetailFlights"} = undef;
      @{"${BR}::ADAPTERS"} = (adapter('Qobuz')); }
    resetApi() unless $o{keep_api};
    hosted(%{ $o{hosted} || {} });
    @SEARCHES = (); @CATALOGUE = @{ $o{catalogue} || [] }; $INCONCLUSIVE = $o{inconclusive} ? 1 : 0;
    my $mbid = $o{mbid} // 'rel-1';
    my $got;
    no strict 'refs';
    &{"${BR}::_findPlayable"}('player', sub { $got = shift }, $o{artist}, $o{album}, $mbid,
                              undef, '2026', 'Album', $o{artist_mbid});
    my $c = ${"${BR}::cache"};
    return { items    => (ref $got eq 'HASH' ? scalar(@{ $got->{items} || [] }) : -1),
             entry    => $c->{d}{"stream:$mbid"}, ttl => $c->{ttl}{"stream:$mbid"},
             searches => [ @SEARCHES ], lookups => scalar(@{ hostedLog() }) };
}

section('4. _findPlayable — the alias pass, once, and only on a clean miss');
{
    my ($FOUND, $NOMATCH) = do { no strict 'refs'; (&{"${BR}::STREAM_FOUND_TTL"}(), &{"${BR}::STREAM_NOMATCH_TTL"}()) };
    my %osees = ('artist/Oh%20Sees/aliases?mbid=osees-1' =>
                     { name => 'Osees', mbid => 'osees-1', aliases => [ 'Oh Sees', 'Thee Oh Sees', 'OCS' ] });

    my $r = resolve(artist => 'Oh Sees', album => 'Protean Threat', artist_mbid => 'osees-1',
                    catalogue => [ { artist => 'Osees', title => 'Protean Threat' } ], hosted => \%osees);
    is('a renamed artist is MATCHED', $r->{items}, 1);
    is('...on the second search', scalar(@{ $r->{searches} }), 2);
    ok('...the first searched with no other names, the second with them',
       !defined $r->{searches}[0]{alts} && grep { $_ eq 'osees' } @{ $r->{searches}[1]{alts} || [] });
    is('...one alias lookup, by the artist MBID', $r->{lookups}, 1);
    is('...and the match is cached for the found age', $r->{ttl}, $FOUND);

    $r = resolve(artist => 'Oh Sees', album => 'Protean Threat', artist_mbid => 'osees-1',
                 catalogue => [ { artist => 'Osees', title => 'Protean Threat' } ],
                 hosted => { 'artist/Oh%20Sees/aliases?mbid=osees-1' => { name => 'Oh Sees' } });
    is('CONTROL: with no other names known, the same album is a miss', $r->{items}, 0);

    $r = resolve(artist => 'Dexys Midnight Runners', album => 'LOVE',
                 catalogue => [ { artist => 'Dexys, Kevin Rowland', title => 'LOVE' } ]);
    is('a joint credit matches on the FIRST search', $r->{items}, 1);
    is('...with no second search', scalar(@{ $r->{searches} }), 1);
    is('...and no alias lookup at all', $r->{lookups}, 0);

    $r = resolve(artist => 'Dexys Midnight Runners', album => 'Not A Real Album',
                 catalogue => [ { artist => 'Dexys', title => 'LOVE' } ],
                 hosted => { 'artist/Dexys%20Midnight%20Runners/aliases' =>
                                 { name => 'Dexys Midnight Runners', mbid => 'ccce', aliases => [ 'Dexys' ] } });
    is('a genuine miss is still a miss', $r->{items}, 0);
    is('...after exactly TWO searches — the alias pass never triggers another', scalar(@{ $r->{searches} }), 2);
    ok('...and it is a clean, durable no-match', !$r->{entry}{retry_at} && ($r->{ttl} // 0) == $NOMATCH);

    $r = resolve(artist => 'Solo Name', album => 'Nothing',
                 hosted => { 'artist/Solo%20Name/aliases' => { name => 'Solo Name', mbid => 's1', aliases => [] } });
    is('an artist with no other names is searched ONCE', scalar(@{ $r->{searches} }), 1);
    is('...after one lookup', $r->{lookups}, 1);

    $r = resolve(artist => 'Down Band', album => 'Nothing');
    is('an alias lookup that FAILS: no second search', scalar(@{ $r->{searches} }), 1);
    ok('...and the miss is INCONCLUSIVE, so it is retried on the schedule',
       defined $r->{entry}{retry_at} && ($r->{entry}{tries} // 0) == 1);

    $r = resolve(artist => 'Anyone', album => 'Anything', inconclusive => 1);
    is('a service that could not be asked: no alias lookup', $r->{lookups}, 0);
    ok('...the miss keeps its own retry schedule', defined $r->{entry}{retry_at});

    $r = resolve(artist => 'Various Artists', album => 'A Compilation',
                 artist_mbid => '89ad4ac3-39f7-470e-963a-56509c546377');
    is('a Various Artists credit is never alias-searched', $r->{lookups}, 0);

    resolve(artist => 'Oh Sees', album => 'Protean Threat', artist_mbid => 'osees-1',
            catalogue => [ { artist => 'Osees', title => 'Protean Threat' } ], hosted => \%osees);
    $r = resolve(artist => 'Oh Sees', album => 'Carrion Crawler', artist_mbid => 'osees-1', mbid => 'rel-2',
                 keep_api => 1, catalogue => [ { artist => 'Osees', title => 'Carrion Crawler' } ]);
    is('a second album by the same artist matches', $r->{items}, 1);
    is('...using the CACHED aliases — still one lookup in total', $r->{lookups}, 1);
}

# ===========================================================================
section('5. the wiring — the halves a driven resolver cannot see');
{
    for my $svc (qw(_searchQobuz _searchBandcamp _searchTidal _searchDeezer _searchSpotify)) {
        my $body = grabB($svc);
        ok("$svc takes the other names and matches through _albumMatchesAlt",
           $body =~ /\$albumRaw, \$alts\) = \@_;/ && $body =~ /_albumMatchesAlt\([^;]*\$alts\)/
           && $body !~ /\b_albumMatches\(/);
    }
    my $fp = grabB('_findPlayable');
    ok('_findPlayable hands the names to every service', $fp =~ /->\{run\}->\([^;]*\$album, \$alts\)/);
    my @calls = $BSRC =~ /(_findPlayable\(\$client, sub \{.*?\n\s*\}, [^;]*;)/sg;
    is('three _findPlayable call sites', scalar(@calls), 3);
    is('...and every one passes the artist MBID', scalar(grep { /artist_mbid/ } @calls), 3);
}

# ===========================================================================
print "\n" . ('=' x 78) . "\n$p passed, $f failed.\n";
exit($f ? 1 : 0);
