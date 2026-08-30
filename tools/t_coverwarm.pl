#!/usr/bin/env perl
#
# t_coverwarm.pl — the cover-art half of the image proxy: the CAA size table and
# the background cover pre-warm.
#
#   perl tools/t_coverwarm.pl
#
# WHAT THIS EXISTS FOR (measured on the live server 2026-08-22, not inferred).
#
# 1. THE SIZE TABLE. `Slim::Web::ImageProxy->getRightSize($spec, \%sizes)` returns
#    the value of the SMALLEST key >= the requested dimension and UNDEF when
#    nothing in the table is big enough — so a `|| '<smallest>'` fallback fires on
#    exactly the BIGGEST requests and serves the SMALLEST file. Material asks for
#    600 on a hi-dpi grid tile and 1024/2048 for now-playing, and the table topped
#    out at 500, so every retina grid tile was a 250px thumbnail upscaled 2.4x.
#    Live proof: `_600x600_f` came back 38,248 bytes, SMALLER than the
#    `_400x400_f` beside it at 72,764.
#
# 2. THE PRE-WARM. The proxy keys its cache on the WHOLE request path — escaped
#    url + size spec + extension (`ImageProxy::getImage`, `cachekey => $path`) —
#    and Material picks the spec from the DEVICE. Same cover, one spec each:
#    150 -> 1.80s, 300 -> 1.92s, 400 -> 2.05s, 600 -> 2.12s, then a REPEAT of 150
#    -> 0.03s. The cache is perfect and per-size, so a second device starts cold.
#    `_warmCovers` fills the three specs Material asks for, ahead of time.
#
# THE ONE THING MOST WORTH GUARDING: the warmed path must be BYTE-IDENTICAL to
# what the client will request. A path that differs by so much as its extension
# fills a key nobody ever reads, and the feature would look like it worked while
# doing nothing — which is precisely the failure this suite would otherwise miss.
#
# Sub bodies and constants are extracted VERBATIM from the shipped source (the
# tools/bench_walk.pl trick) so the assertions track the code rather than a
# paraphrase of it. No LMS needed.
#
#   1. Size table   — 150/300 unchanged, 600 and the now-playing specs no longer
#                     fall through to the smallest file.
#   2. Path shape   — the warmed strings equal Material's, spec spliced before the
#                     extension, for all three specs.
#   3. Queueing     — pref off, no artwork, the cap, the already-warm skip, the
#                     cross-feed dedupe, newest-first ordering.
#   4. The runner   — one request in flight, the marker written under the proxy's
#                     own 30-day life, and an auth refusal abandoning the pass.
#
# ANTI-TEST: point LBF_PLUGIN / LBF_BROWSE at a mutated copy.
#   * restore `500 => '500'` as the ceiling with `|| '250'`  -> section 1 fails.
#   * re-anchor the url rewrite as `s|/front-\d+$|...|`       -> section 1 fails.
#   * drop the `.jpg` from coverArtUrl (LBF_API)              -> section 2 fails.
#   * change the spec splice to append after the extension    -> section 2 fails.
#
# Exit 0 = all good. Exit 1 = at least one regressed.
use strict;
use warnings;
use File::Spec;

my $ROOT   = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
my $BROWSE = $ENV{LBF_BROWSE} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');
my $PLUGIN = $ENV{LBF_PLUGIN} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Plugin.pm');
# API.pm and DB.pm joined the suite when `coverArtUrl` and the marker's key
# version stopped being paraphrased here. They need the same override as the
# other two or the anti-test cannot reach them: a mutated coverArtUrl would go on
# passing against the pristine copy, which is the failure mode this whole file is
# organised against.
my $API    = $ENV{LBF_API}    || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'API.pm');
my $DB     = $ENV{LBF_DB_SRC} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'DB.pm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    die "ok() called with no message\n" unless defined $what && length $what;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}
sub section { print "\n" . uc($_[0]) . "\n" . ('-' x 74) . "\n" }

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

my $bsrc = slurp($BROWSE);
my $psrc = slurp($PLUGIN);

# The one collaborator that decides which cover a release has — EXTRACTED
# VERBATIM, like every other body in this suite, and it was the one thing here
# that wasn't. A hand-written copy returning '/front-250' sat here while the
# shipped sub moved to '/front-250.jpg', and because `proxiedImage` derives the
# proxied path's extension FROM THAT URL, the paraphrase kept the whole suite
# asserting `.png` paths that the plugin had stopped producing. That is exactly
# the drift the header comment warns about, and it is worth more than a fixed
# literal here: the extension is not cosmetic, it decides whether the proxy
# caches JPEG or re-encodes every cover as PNG (measured: 44,000 B vs 7,994 B at
# _150x150_f, 648,081 B vs 101,100 B at _600x600_f).
my $asrc = slurp($API);
{
    package Plugins::ListenBrainzFreshReleases::API;
    use constant CAA_BASE_URL    => 'https://coverartarchive.org/release/';
    use constant CAA_RG_BASE_URL => 'https://coverartarchive.org/release-group/';
}
{
    my $body = grab($asrc, 'coverArtUrl');
    eval "package Plugins::ListenBrainzFreshReleases::API; $body 1;"
        or die "eval coverArtUrl: $@";
}

# The store's key-version rule, reproduced from DB.pm's own KEY_VERSIONS so the
# marker assertions below check the REAL family version rather than a guess. A
# bump has to invalidate the markers — every one of them names a proxy path, and
# the `.png` -> `.jpg` switch changed every path the plugin will ever request.
my $dsrc = slurp($DB);
my ($kv_src) = $dsrc =~ /use constant KEY_VERSIONS => \{(.*?)^\};/ms
    or die "no KEY_VERSIONS in DB.pm\n";
my %KEY_VERSIONS = $kv_src =~ /'([^']+)'\s*=>\s*(\d+)/g;
die "KEY_VERSIONS parsed empty\n" unless keys %KEY_VERSIONS;
die "'lbf:imgwarm:' is not a registered key family\n"
    unless defined $KEY_VERSIONS{'lbf:imgwarm:'};
{
    package Plugins::ListenBrainzFreshReleases::DB;
    sub kver { return $_[0] . $KEY_VERSIONS{ $_[0] } . ':' }
}
my $IMGWARM = 'lbf:imgwarm:' . $KEY_VERSIONS{'lbf:imgwarm:'} . ':';

# ==========================================================================
section('1. the CAA size table answers the specs Material actually asks for');
# ==========================================================================
# getRightSize's REAL body, transcribed from Slim/Web/ImageProxy.pm (LMS 9.1):
# smallest key >= the requested dimension, undef when nothing is big enough.
# Reproduced rather than stubbed so a table that looks fine against a made-up
# rule cannot pass — the undef is the whole bug.
sub right_size {
    my ($want, $sizes) = @_;
    for my $k (sort { $a <=> $b } keys %$sizes) {
        return $sizes->{$k} if $k >= $want;
    }
    return undef;
}

# Table + fallback lifted out of the shipped handler.
my ($table_src) = $psrc =~ /getRightSize\(\$spec,\s*\{(.*?)\}\)\s*\|\|\s*'(\d+)'/s
    or die "no CAA size table in Plugin.pm\n";
my $fallback = $2;
my %sizes = $table_src =~ /(\d+)\s*=>\s*'(\d+)'/g;
die "size table parsed empty\n" unless keys %sizes;

sub caa_size { return right_size($_[0], \%sizes) || $fallback }

ok(caa_size(150)  eq '250',  'list row, standard dpi (150) -> front-250');
ok(caa_size(300)  eq '500',  'list row hi-dpi / grid tile standard dpi (300) -> front-500');
ok(caa_size(600)  eq '1200', 'grid tile hi-dpi (600) -> front-1200, not the 250 it used to get');
ok(caa_size(1024) eq '1200', 'now playing, standard dpi (1024) -> the largest option');
ok(caa_size(2048) eq '1200', 'now playing, hi-dpi (2048) -> the largest option');
# The property, stated independently of the numbers: the fallback IS the ceiling.
my ($largest) = sort { $b <=> $a } values %sizes;
ok($fallback eq $largest,
   "the fallback ($fallback) is the LARGEST table entry, never the smallest");
# And the rule that made it a bug in the first place is really live.
ok(!defined right_size(600, { 50 => '250', 100 => '250', 250 => '250', 500 => '500' }),
   'getRightSize really does return undef above the table ceiling (the premise)');

# THE REWRITE ITSELF, not just the table it consults. Section 1 checked which
# SIZE the handler picks and stopped there — but picking 1200 is worthless if the
# substitution that stamps it into the URL doesn't fire, and that is precisely
# what went wrong: the pattern was anchored `/front-\d+$`, so the moment
# `coverArtUrl` started naming `.jpg` it matched nothing, the url passed through
# untouched, and every spec was served from whatever size the row happened to
# carry. Verified live before the fix — a `_600x600_f` came back off the 250px
# source instead of front-1200. Silent, and invisible to a table-only test.
#
# The line is lifted VERBATIM from the shipped handler for the usual reason.
# Delimiter-agnostic on purpose: pinning the extraction to `s{...}` would mean a
# reverted handler failed to PARSE rather than failing an assertion, and "the line
# looks different" is a much weaker claim than "the rewrite no longer works".
my ($rewrite_src) = $psrc =~ /^(\s*\$url =~ s.*?\/front.*?;)$/ms
    or die "no CAA url rewrite in Plugin.pm\n";
eval "sub caa_rewrite { my (\$url, \$size) = \@_; $rewrite_src return \$url; } 1;"
    or die "eval rewrite: $@";

{
    my $J = 'https://coverartarchive.org/release/x/front-250.jpg';
    my $B = 'https://coverartarchive.org/release/x/front-250';
    ok(caa_rewrite($J, '1200') eq 'https://coverartarchive.org/release/x/front-1200.jpg',
       'the ladder fires on an EXTENSIONED url and keeps the extension');
    ok(caa_rewrite($J, '500') eq 'https://coverartarchive.org/release/x/front-500.jpg',
       '...at every rung, not just the top one');
    ok(caa_rewrite($B, '1200') eq 'https://coverartarchive.org/release/x/front-1200',
       'an extension-less url still behaves exactly as it always did');
    # The regression this guards, stated as the property rather than the pattern:
    # whatever coverArtUrl builds must still be rewritable, or the ladder is dead.
    my $live = Plugins::ListenBrainzFreshReleases::API->coverArtUrl(
                   { caa_release_mbid => 'zz' });
    ok(caa_rewrite($live, '1200') ne $live,
       "the ladder actually matches what coverArtUrl ships today ($live)");
    ok(caa_rewrite($live, '1200') =~ m{/front-1200(\.\w+)?$},
       '...and lands the chosen size at the end of the path');
    ok(caa_rewrite('https://coverartarchive.org/release/x/back-250.jpg', '1200')
         eq 'https://coverartarchive.org/release/x/back-250.jpg',
       'a path that is not /front-<n> is left alone');
}

# ==========================================================================
section('2. a warmed path is byte-identical to what Material will request');
# ==========================================================================
# ----------------------------------------------------------- stub world --
{
    package T::Cache;
    sub new { bless { d => {}, sets => [] }, shift }
    sub get { my ($s, $k) = @_; return $s->{d}{$k} }
    sub set {
        my ($s, $k, $v, $t) = @_;
        $s->{d}{$k} = $v;
        push @{ $s->{sets} }, [ $k, $t ];
        return 1;
    }
    sub remove { my ($s, $k) = @_; delete $s->{d}{$k} }
}
{
    package T::Prefs;
    sub new { bless { d => { warm_covers => 1, httpport => 9000 } }, shift }
    sub get { my ($s, $k) = @_; return $s->{d}{$k} }
    sub set { my ($s, $k, $v) = @_; $s->{d}{$k} = $v }
}
{
    package T::Log;
    sub new { bless { info => [] }, shift }
    sub warn { 1 } sub error { 1 } sub is_info { 0 }
    sub info { my ($s, $m) = @_; push @{ $s->{info} }, $m; 1 }
}
{   # Timers: record the re-arm rather than firing it, so the runner can be
    # stepped one request at a time.
    package Slim::Utils::Timers;
    our @PENDING;
    sub setTimer { my (undef, undef, $cb) = @_; push @PENDING, $cb; return scalar @PENDING }
    sub killSpecific { 1 }
}
{
    # proxiedImage, transcribed from Slim/Web/ImageProxy.pm — the escape set and
    # the ".png for an extension-less url" rule are the two things the warmed
    # path depends on, so they are reproduced rather than faked.
    package Slim::Web::ImageProxy;
    sub proxiedImage {
        my ($url) = @_;
        my $ext = '.png';
        if ($url =~ /(\.(?:jpg|jpeg|png|gif))/) { $ext = $1; $ext =~ s/jpeg/jpg/ }
        (my $esc = $url) =~ s/([^A-Za-z0-9\-_.!~*'()])/sprintf('%%%02X', ord($1))/ge;
        return '/imageproxy/' . $esc . '/image' . $ext;
    }
}
$INC{'Slim/Web/ImageProxy.pm'} = __FILE__;

our @HTTP_GETS;         # every url the runner asked for, in order
our $HTTP_MODE = 'ok';  # 'ok' | '401'
{
    package Slim::Networking::SimpleAsyncHTTP;
    sub new { my ($c, $done, $err, $o) = @_; bless { done => $done, err => $err }, $c }
    sub get {
        my ($s, $url) = @_;
        push @main::HTTP_GETS, $url;
        # Deliberately NOT called back here — the suite fires them by hand so it
        # can prove only one request is ever in flight.
        push @main::HTTP_PENDING, [ $s, $url ];
        return $s;
    }
}
our @HTTP_PENDING;
$INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = __FILE__;

# Answer the oldest outstanding request.
sub http_settle {
    my $req = shift @HTTP_PENDING or return 0;
    my ($s) = @$req;
    if ($HTTP_MODE eq '401') { $s->{err}->(undef, 'Failed to open socket: 401 Authorization Required') }
    else                     { $s->{done}->(bless {}, 'T::Resp') }
    return 1;
}

my $CACHE = T::Cache->new;
my $PREFS = T::Prefs->new;
my $LOG   = T::Log->new;

# ------------------------------------------------------- code under test --
{
    package T;
    use strict;
    use warnings;
    use Time::HiRes ();

    our $cache = $CACHE;
    our $prefs = $PREFS;
    our $log   = $LOG;

    sub preferences { return $PREFS }      # both 'plugin.…' and 'server' answer here
    sub _dbg { 1 }
}

# Constants are EVALLED FROM SOURCE, not restated: a hand-copied COVER_SPECS
# would drift the moment the shipped list changed, and every path assertion
# below would then be checking a spec nothing asks for.
for my $c (qw(COVER_SPECS COVER_WARM_MAX COVER_WARM_GAP COVER_WARM_TTL)) {
    my ($line) = $bsrc =~ /^(use constant \Q$c\E\s*=>.*?;)$/ms
        or die "no constant $c in Browse.pm\n";
    eval "package T; $line 1;" or die "eval $c: $@";
}

# The warm-stage recorder is instrumentation, not behaviour — these subs mark
# the covers stage, so the harness has to answer the call, but nothing here
# asserts on it (t_warmstats.pl owns that). A no-op stub keeps this suite
# measuring what it is actually for.
{ package T; sub _stage { } }

for my $name (qw(_warmCovers _coverTick)) {
    my $body = grab($bsrc, $name);
    eval "package T; use Time::HiRes (); our (\$cache, \$prefs, \$log); "
       . "our (\@coverQueue, \%coverQueued, \$coverRunning, \$coverStageOpen, \$coverFetched); $body 1;"
        or die "eval $name: $@";
}


sub reset_world {
    no warnings 'once';
    @T::coverQueue  = ();
    %T::coverQueued = ();
    $T::coverRunning = 0;
    @HTTP_GETS = (); @HTTP_PENDING = (); $HTTP_MODE = 'ok';
    @Slim::Utils::Timers::PENDING = ();
    $CACHE = T::Cache->new; $LOG = T::Log->new;
    $PREFS = T::Prefs->new;
    $T::cache = $CACHE; $T::log = $LOG; $T::prefs = $PREFS;
}

# A release shaped like a parsed fresh_releases entry.
my $n = 0;
sub rel {
    my (%o) = @_;
    $n++;
    return {
        release_date     => $o{date} // sprintf('2026-08-%02d', $n),
        artist_credit_name => "Artist $n",
        release_name     => "Album $n",
        caa_release_mbid => exists $o{mbid} ? $o{mbid} : sprintf('mbid-%04d', $n),
    };
}

# THE reference string: what Material builds for a list row on a standard-dpi
# screen. resolveImageUrl takes the row's already-proxied '/imageproxy/<esc>/image<ext>'
# and splices the size in before the extension.
#
# DERIVED, NOT WRITTEN OUT. Both halves come from shipped code — the real
# `coverArtUrl` and the transcribed `proxiedImage` — so this string cannot go on
# describing a path the plugin no longer builds. A literal here is what let the
# suite keep passing against `.png` after the source moved to `.jpg`.
my $MBID    = 'mbid-0001';
my $SRCURL  = Plugins::ListenBrainzFreshReleases::API->coverArtUrl(
                  { caa_release_mbid => $MBID });
my $EXPECT  = Slim::Web::ImageProxy::proxiedImage($SRCURL);
my ($EXT)   = $EXPECT =~ /(\.\w+)$/;
$EXPECT     =~ s/\Q$EXT\E$//;

# _warmCovers starts the runner before it returns, so one path is already in
# flight by the time we look — every count below is queue PLUS in-flight.
sub warmed_paths {
    my @out = map { my $u = $_; $u =~ s{^http://[^/]+}{}; $u } @HTTP_GETS;
    push @out, map { $_->[0] } @T::coverQueue;
    return @out;
}
sub warmed_count { return scalar warmed_paths() }

reset_world();
$n = 0;
T::_warmCovers([ rel() ], 'test');

ok(warmed_count() == 3, 'one cover produces exactly three requests (one per spec)');
my @paths = warmed_paths();
ok(scalar(grep { $_ eq $EXPECT . '_150x150_f' . $EXT } @paths),
   'list row, standard dpi: ' . $EXPECT . '_150x150_f' . $EXT);
ok(scalar(grep { $_ eq $EXPECT . '_300x300_f' . $EXT } @paths),
   'list row hi-dpi / grid standard dpi: ..._300x300_f' . $EXT);
ok(scalar(grep { $_ eq $EXPECT . '_600x600_f' . $EXT } @paths),
   'grid tile hi-dpi: ..._600x600_f' . $EXT);
ok(!scalar(grep { /\Q$EXT\E_/ } @paths),
   'the spec goes BEFORE the extension — no path ends up as image' . $EXT . '_150x150_f');

# THE EXTENSION ITSELF, asserted rather than merely followed. `proxiedImage`
# defaults to `.png` for an extension-less source URL, and CAA's `/front-250`
# was exactly that — so every cover was cached as a re-encoded PNG, measured at
# 5.5-6.4x the bytes of the same rendition as JPEG (and the 600px PNG came out
# LARGER than the 1200px JPEG it was scaled down from). Deriving $EXT above
# keeps the suite honest about what is built; this pins WHICH answer is correct,
# so a source URL that loses its extension fails here instead of silently
# doubling the proxy cache again.
ok($EXT eq '.jpg',
   "the proxied path is JPEG, not a re-encoded PNG (got $EXT)");
ok($SRCURL =~ m{/front-\d+\.jpg$},
   'coverArtUrl names an explicit .jpg on the CAA url — the thing that decides it');
ok(!scalar(grep { /_1024x1024_f|_2048x2048_f/ } @paths),
   'the now-playing specs are deliberately not warmed');
ok(scalar(grep { $_->[1] eq $IMGWARM . $_->[0] } @T::coverQueue),
   'the marker key is the path itself, so it cannot mark a different one warm');

# ==========================================================================
section('3. what gets queued, and what does not');
# ==========================================================================
reset_world(); $n = 0;
$PREFS->set('warm_covers', 0);
T::_warmCovers([ rel(), rel() ], 'test');
ok(warmed_count() == 0, 'warm_covers off queues nothing at all');

reset_world(); $n = 0;
T::_warmCovers([ rel(mbid => '') ], 'test');
ok(warmed_count() == 0, 'a release with no cover art contributes nothing');

reset_world(); $n = 0;
T::_warmCovers([ map { rel() } 1 .. (T::COVER_WARM_MAX() + 25) ], 'test');
ok(warmed_count() == T::COVER_WARM_MAX() * 3,
   'the pass is capped at COVER_WARM_MAX releases (' . T::COVER_WARM_MAX() . ' x 3 requests)');

# The cap is a constant, so rather than swapping it, assert the ORDER: a capped
# pass has to warm what the view puts at the TOP, which is the newest release.
reset_world(); $n = 0;
my @feed = (rel(date => '2026-08-01'), rel(date => '2026-08-31'), rel(date => '2026-08-15'));
T::_warmCovers(\@feed, 'test');
ok($HTTP_GETS[0] =~ /mbid-0002/,
   'the newest release is warmed first (2026-08-31, given to us out of order)');

reset_world(); $n = 0;
my $r = rel();
$CACHE->set($IMGWARM . $EXPECT . '_300x300_f' . $EXT, 1, 100);
T::_warmCovers([ $r ], 'test');
ok(warmed_count() == 2, 'a spec already marked warm is not queued again');
ok(!scalar(grep { /_300x300_f/ } warmed_paths()), '...and it is the right one that was skipped');

reset_world(); $n = 0;
my $shared = rel();
T::_warmCovers([ $shared ], 'all releases');
my $after_first = warmed_count();
T::_warmCovers([ $shared ], 'for you');       # same cover reached by a second feed
ok(warmed_count() == $after_first,
   'two feeds sharing a cover warm it once (the in-flight path is held, not re-queued)');

# ==========================================================================
section('4. the runner');
# ==========================================================================
reset_world(); $n = 0;
T::_warmCovers([ rel(), rel() ], 'test');
my $queued = warmed_count();
ok($queued == 6, 'two covers, six requests in total');
ok(scalar(@HTTP_GETS) == 1, 'exactly one request goes out at a time — the runner is serial');
ok($HTTP_GETS[0] =~ m{^http://127\.0\.0\.1:9000/imageproxy/},
   'it is addressed to our OWN server, on the configured http port');

http_settle();
ok(scalar(@{ $CACHE->{sets} }) == 1, 'a completed request writes its warm marker');
my ($mk, $mttl) = @{ $CACHE->{sets}[0] };
ok($mk =~ /^\Q$IMGWARM\E/, "the marker is keyed under the versioned family ($IMGWARM)");
ok($mttl && $mttl < 30 * 86400,
   'the marker expires INSIDE the proxy\'s own 30-day life, so it cannot outlive the image');
ok(scalar(@Slim::Utils::Timers::PENDING) == 1, 'the next request is armed on a timer, not fired inline');
ok(scalar(@HTTP_GETS) == 1, '...so still only one request has gone out');

(shift @Slim::Utils::Timers::PENDING)->();
ok(scalar(@HTTP_GETS) == 2, 'the timer fires the next one');

# Drain, and check the runner stops rather than re-arming for ever.
my $guard = 0;
while (@T::coverQueue || @HTTP_PENDING) {
    last if ++$guard > 50;
    http_settle();
    (shift @Slim::Utils::Timers::PENDING)->() while @Slim::Utils::Timers::PENDING;
}
ok(scalar(@HTTP_GETS) == $queued, 'every queued request is eventually made, and no more');
ok(scalar(@Slim::Utils::Timers::PENDING) == 0, 'an empty queue arms no further timer');

reset_world(); $n = 0;
$HTTP_MODE = '401';
T::_warmCovers([ map { rel() } 1 .. 5 ], 'test');
ok(scalar(@T::coverQueue) == 14, 'fifteen queued, one in flight');
http_settle();
ok(scalar(@T::coverQueue) == 0,
   'a 401 from our own server abandons the whole pass rather than logging it 400 times');
ok(scalar(grep { /refused a local request/ } @{ $LOG->{info} }), '...and says so once, at info');
ok(scalar(@HTTP_GETS) == 1, 'no further requests are made after the refusal');

# ==========================================================================
print "\n" . ('=' x 74) . "\n$pass passed, $fail failed.\n";
exit($fail ? 1 : 0);
