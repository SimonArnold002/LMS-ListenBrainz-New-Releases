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
#   4. The runner   — never more than the idle width in flight, the counter
#                     returning to zero, the marker written under the proxy's
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
$| = 1;   # unbuffered: a hang must show WHERE it hung, not lose the output

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
    my ($cond, $msg) = @_;
    # A MISSING MESSAGE IS A BUG IN THE TEST, AND IT IS REPORTED, NOT THROWN.
    #
    # It means a bare m// or grep landed in ok()'s LIST-context argument slot: on
    # a MATCH it yields (1, $msg) and passes, on a FAILURE it yields () and the
    # message slides into $cond, so the assertion silently tests its own label.
    # This has now cost two suites in this repo, which is why it is caught here.
    #
    # It used to `die`, and that traded one hidden bug for another: the abort took
    # every later assertion in the file with it, so a real regression reported one
    # failure and concealed the rest. Fail loudly, keep going.
    unless (defined $msg && length $msg) {
        $fail++;
        print "  FAIL  ok() called with no message — a bare m// or grep in the "
            . "condition slot? wrap it in scalar(). (condition was: "
            . (defined $cond ? "'$cond'" : 'undef') . ")\n";
        return;
    }
    if ($cond) { $pass++; print "  PASS  $msg\n" }
    else       { $fail++; print "  FAIL  $msg\n" }
    return;
}

sub is_count {
    my ($got, $want, $what) = @_;
    return ok($got == $want, "$what (got $got)");
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
    my $end   = length($src);
    my $depth = 1;

    # BRACE-SCAN BY REGEX, NOT substr()-PER-CHARACTER, and the difference is not
    # style. slurp() reads with ':encoding(UTF-8)', so $src is a CHARACTER string
    # — and substr() on one is not O(1). The old per-character walk was therefore
    # quadratic in file size, and Browse.pm is half a megabyte: once this suite
    # grabbed a dozen subs it spent ~100 SECONDS here, which reads as a hang
    # rather than as slowness. The //g picks up from the header match's pos, which
    # is exactly where the body starts.
    while ($src =~ /([{}])/g) {
        $1 eq '{' ? $depth++ : $depth--;
        next if $depth;
        $end = pos($src);
        last;
    }
    return substr($src, $start, $end - $start) . "\n";
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
section('1. every spec resolves to ONE source url, so the proxy can coalesce');
# ==========================================================================
# THIS SECTION INVERTED IN 0.9.196, and the old assertions are kept below as
# anti-tests rather than deleted. It used to check that the size LADDER picked
# the right CAA size per spec. The ladder is the bug: mapping each spec to a
# different CAA size means three different SOURCE URLs, and
# Slim::Web::ImageProxy::getImage queues by the source url — so three specs of one
# release could never share a download. Collapsing them to one url is what turns
# three upstream fetches into one, and the table's absence is now the property.

ok($psrc !~ /getRightSize\(\$spec/,
   'the getRightSize size table is GONE from the handler');
ok(scalar($psrc =~ /UNIVERSAL::can\('Slim::Web::ImageProxy',\s*'getRightSize'\)/),
   '...but the registration guard still probes for it as a version check');

# THE REWRITE ITSELF, not just what it resolves to. Lifted VERBATIM from the
# shipped handler for the usual reason. Delimiter-agnostic on purpose: pinning the
# extraction to `s{...}` would mean a reverted handler failed to PARSE rather than
# failing an assertion, and "the line looks different" is a much weaker claim than
# "the rewrite no longer works".
my ($rewrite_src) = $psrc =~ /^(\s*\$url =~ s.*?\/front.*?;)$/ms;
ok(defined $rewrite_src, 'the CAA url rewrite is still there to extract');

# COMPILED STANDALONE, AND THAT IS ITSELF THE ASSERTION. After the collapse the
# rewrite depends on nothing but $url — no computed size, no table lookup — so it
# must eval cleanly in a sub that supplies only ($url, $spec). Reinstating a
# ladder reintroduces a `$size` this scope does not have, and that is caught here
# as a FAIL rather than as a die.
#
# It must NOT die: the suite once lost every later assertion in the file because a
# failing check then died on the very thing it was asserting about, so a real
# regression reported one failure and hid the rest.
my $rewrite_ok = 0;
if (defined $rewrite_src) {
    $rewrite_ok = eval "sub caa_rewrite { my (\$url, \$spec) = \@_; $rewrite_src return \$url; } 1;" ? 1 : 0;
}
ok($rewrite_ok, 'the rewrite compiles depending on $url alone — no size to compute');

if (!$rewrite_ok) {
    ok(0, "SKIPPED (rewrite would not compile): $_") for
        ('all three specs rewrite to one url', 'that url is front-1200',
         'extension-less url unchanged', 'release-group url shape',
         'matches what coverArtUrl ships', 'lands front-1200',
         'non-front path left alone');
}
elsif (1) {
    my $J = 'https://coverartarchive.org/release/x/front-250.jpg';
    my $B = 'https://coverartarchive.org/release/x/front-250';
    my $G = 'https://coverartarchive.org/release-group/y/front-250.jpg';

    # THE COALESCING PROPERTY, stated directly: the three specs Material asks for
    # must produce ONE string. This is the assertion the whole stage rests on —
    # if these ever differ again, every release costs three downloads and nothing
    # else in this file would notice.
    my @out = map { caa_rewrite($J, $_) } qw(_150x150_f _300x300_f _600x600_f);
    is_count(scalar(keys %{{ map { $_ => 1 } @out }}), 1,
             'all three of Material\'s specs rewrite to ONE source url');
    ok($out[0] eq 'https://coverartarchive.org/release/x/front-1200.jpg',
       '...and that url is front-1200, the only size that never upscales at 600');

    ok(caa_rewrite($B, '_600x600_f') eq 'https://coverartarchive.org/release/x/front-1200',
       'an extension-less url still behaves exactly as it always did');
    ok(caa_rewrite($G, '_150x150_f') eq 'https://coverartarchive.org/release-group/y/front-1200.jpg',
       'the release-GROUP url shape rewrites too (trending / MuSpy rows)');

    # The regression this guards, stated as the property rather than the pattern:
    # whatever coverArtUrl builds must still be rewritable, or the handler is dead.
    # The pattern used to be anchored `/front-\d+$`, so the moment coverArtUrl
    # started naming `.jpg` it matched nothing and every spec was served from
    # whatever size the row happened to carry.
    my $live = Plugins::ListenBrainzFreshReleases::API->coverArtUrl(
                   { caa_release_mbid => 'zz' });
    ok(caa_rewrite($live, '_600x600_f') ne $live,
       "the rewrite actually matches what coverArtUrl ships today ($live)");
    ok(scalar(caa_rewrite($live, '_600x600_f') =~ m{/front-1200(\.\w+)?$}),
       '...and lands front-1200 at the end of the path');
    ok(caa_rewrite('https://coverartarchive.org/release/x/back-250.jpg', '_600x600_f')
         eq 'https://coverartarchive.org/release/x/back-250.jpg',
       'a path that is not /front-<n> is left alone');
}

# THE ANTI-TEST, kept live rather than described in a comment: reinstating the
# ladder must fail here. getRightSize's REAL body, transcribed from
# Slim/Web/ImageProxy.pm (LMS 9.1) — smallest key >= the request, UNDEF when
# nothing is big enough. That undef is why a `|| '<smallest>'` fallback served the
# SMALLEST file on the BIGGEST request, and it is why the table is a trap for
# anyone who puts it back.
sub right_size {
    my ($want, $sizes) = @_;
    for my $k (sort { $a <=> $b } keys %$sizes) {
        return $sizes->{$k} if $k >= $want;
    }
    return undef;
}
ok(!defined right_size(600, { 50 => '250', 100 => '250', 250 => '250', 500 => '500' }),
   'getRightSize really does return undef above its ceiling (why the table was a trap)');
{
    # A ladder that maps the specs to different sizes produces different source
    # urls — the state this stage exists to leave behind.
    my %ladder = (50 => '250', 100 => '250', 250 => '250', 500 => '500', 1200 => '1200');
    my %urls = map {
        my ($n) = /_(\d+)x/;
        my $sz = right_size($n, \%ladder) || '1200';
        ("https://coverartarchive.org/release/x/front-$sz.jpg" => 1)
    } qw(_150x150_f _300x300_f _600x600_f);
    is_count(scalar(keys %urls), 3,
             'the OLD ladder would give three different source urls (the bug, pinned)');
}

# ==========================================================================
section('2. a warmed path is byte-identical to what Material will request');
# ==========================================================================
# ----------------------------------------------------------- stub world --
{
    package T::Cache;
    sub new { bless { d => {}, sets => [], gets => 0 }, shift }
    # gets are COUNTED, because "the queue builder reads no store" is a claim
    # about the event loop that only a count can make.
    sub get { my ($s, $k) = @_; $s->{gets}++; return $s->{d}{$k} }
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
    # REPLICATES LMS's CALLING CONVENTION, and that is not pedantry: setTimer
    # invokes $cb->($obj, @args) — the first argument is HANDED BACK, not
    # consumed — and a stub that drops it once let a chunk driver ship broken for
    # two builds (0.9.178). $when is recorded too, so a deadline can be asserted
    # rather than merely the fact that something was scheduled.
    sub setTimer {
        my ($obj, $when, $cb, @args) = @_;
        push @PENDING, { when => $when, cb => $cb, obj => $obj, args => \@args };
        return scalar @PENDING;
    }
    sub killSpecific { 1 }
    # SNAPSHOT, then fire. Draining as it goes would spin for ever once a fired
    # callback schedules another timer — which the cover pump does by design
    # whenever the browsing brake is on and work is left. "Fire the timers that
    # were pending when I asked" is the semantics a test actually wants.
    sub fire_all {
        my @now = @PENDING;
        @PENDING = ();
        $_->{cb}->($_->{obj}, @{ $_->{args} }) for @now;
        return scalar @now;
    }
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
    # 'die' mode reproduces a launch that never gets off the ground, which is the
    # ONLY path that calls the runner's $done synchronously.
    sub new {
        my ($c, $done, $err, $o) = @_;
        die "simulated launch failure\n" if $main::HTTP_MODE eq 'die';
        bless { done => $done, err => $err }, $c;
    }
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
for my $c (qw(COVER_SPECS COVER_WARM_MAX COVER_WARM_TTL
              COVER_CONCURRENCY_IDLE COVER_CONCURRENCY_BROWSING COVER_BROWSE_QUIET
              COVER_SCAN_BUDGET)) {
    my ($line) = $bsrc =~ /^(use constant \Q$c\E\s*=>.*?;)$/ms
        or die "no constant $c in Browse.pm\n";
    eval "package T; $line 1;" or die "eval $c: $@";
}

# The warm-stage recorder is instrumentation, not behaviour — these subs mark
# the covers stage, so the harness has to answer the call, but nothing here
# asserts on it (t_warmstats.pl owns that). A no-op stub keeps this suite
# measuring what it is actually for.
{ package T; sub _stage { } }

for my $name (qw(_warmCovers _coverGroupsFor _coverTick _coverMaybeEnd _coverLaunch
                 _noteBrowse _coverLimit _coverArmRestart _coverArmResume)) {
    my $body = grab($bsrc, $name);
    eval "package T; use Time::HiRes (); our (\$cache, \$prefs, \$log); "
       . "our (\@coverQueue, \%coverQueued, \$coverRunning, \$coverPumping, \$coverStageOpen, "
       . "\$coverFetched, \$coverSkipped, \$coverGroups, \$coverPeak, "
       . "\$lastBrowseAt, \$coverRestartArmed, \$coverResumeArmed); $body 1;"
        or die "eval $name: $@";
}


sub reset_world {
    no warnings 'once';
    @T::coverQueue  = ();
    %T::coverQueued = ();
    $T::coverRunning = 0;
    $T::coverPumping = 0;
    $T::coverFetched = 0;
    $T::coverSkipped = 0;
    $T::coverGroups  = 0;
    $T::coverPeak    = 0;
    $T::coverStageOpen = 0;
    $T::lastBrowseAt = 0;          # nobody browsing: every section below runs at the IDLE width
    $T::coverRestartArmed = 0;
    $T::coverResumeArmed  = 0;
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
# A queue element is a GROUP (every spec of one release) since 0.9.196, so this
# flattens one level. Written as a flatten rather than a two-level walk at each
# call site so the request-count assertions below keep meaning "requests".
sub warmed_paths {
    my @out = map { my $u = $_; $u =~ s{^http://[^/]+}{}; $u } @HTTP_GETS;
    push @out, map { $_->[0] } map { @$_ } @T::coverQueue;
    return @out;
}
# ...and the release-level view, which is what COVER_CONCURRENCY now bounds.
sub queued_groups { return scalar @T::coverQueue }
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
ok(scalar($SRCURL =~ m{/front-\d+\.jpg$}),
   'coverArtUrl names an explicit .jpg on the CAA url — the thing that decides it');
ok(!scalar(grep { /_1024x1024_f|_2048x2048_f/ } @paths),
   'the now-playing specs are deliberately not warmed');

# RELEASE-MAJOR, AND THE THREE SPECS MUST TRAVEL TOGETHER. This assertion
# INVERTED in 0.9.196 and the reason is worth keeping, because the old one was
# correct for its own world.
#
# 0.9.189 made the queue spec-major: with three DIFFERENT source urls a release's
# three specs cost three downloads, so a part-finished release-major pass left
# most rows with no cover at the size a list row asks for. Spec-major meant the
# first third of the work gave EVERY row its list-row cover.
#
# Collapsing the ladder removes that premise. The three specs now share one
# download, so grouping them costs a third of the upstream traffic AND finishes
# whole rows. Grouping is also what makes coalescing possible at all: the proxy
# queues by source url and only shares a download between requests that are in
# flight TOGETHER. Both orderings queue exactly the same paths, so only the order
# distinguishes them — a set comparison cannot see this.
{
    reset_world(); $n = 0;
    my $N = 12;
    T::_warmCovers([ map { rel() } 1 .. $N ], 'test');
    my @ordered = warmed_paths();
    ok(scalar(@ordered) == $N * 3, "$N covers queue " . ($N * 3) . ' requests');

    # One entry per RELEASE, each holding every spec.
    is_count(queued_groups() + $T::coverRunning, $N,
             'the queue holds one GROUP per release, not one entry per request');

    # The property, stated over the path strings rather than the structure: the
    # first three requests belong to ONE release and cover all three specs.
    my @first = @ordered[0 .. 2];
    my %specs = map { /(_\d+x\d+_f)/ ? ($1 => 1) : () } @first;
    is_count(scalar(keys %specs), 3,
             'the first three requests are the three SPECS of one release');
    my %bases = map { my $b = $_; $b =~ s/_\d+x\d+_f//; ($b => 1) } @first;
    is_count(scalar(keys %bases), 1,
             '...and they share ONE source path, which is what lets the proxy coalesce');

    # And the old ordering is now the failure: spec-major would put twelve
    # different releases' list-row covers first.
    ok(scalar(grep { /_150x150_f/ } @first) == 1,
       'NOT spec-major — the first three are not twelve rows\' list covers');
    reset_world();
}
# THE MARKER NAMES ITS OWN PATH. Checked over a warm big enough to leave entries
# still QUEUED: with a concurrent runner a pass is launched in full before this
# line runs, so @coverQueue is empty and a grep over it would pass vacuously — it
# did, until the runner stopped being serial. Asserted over every queued entry
# rather than "at least one", which is the actual invariant.
{
    reset_world(); $n = 0;
    T::_warmCovers([ map { rel() } 1 .. 20 ], 'test');
    my @q = map { @$_ } @T::coverQueue;
    ok(scalar(@q) > 0, 'a pass larger than the idle width leaves entries queued');
    ok(scalar(@q) == scalar(grep { $_->[1] eq $IMGWARM . $_->[0] } @q),
       'every queued marker key is its own path, so it cannot mark a different one warm');
    reset_world();
}

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
ok(scalar($HTTP_GETS[0] =~ /mbid-0002/),
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
# THE RUNNER IS NOW CONCURRENT, and this section was the thing asserting it was
# not. The old shape — one request out, a timer arming the next — was measured to
# be the whole reason a cold feed took hours: the cost of a cover is almost
# entirely Cover Art Archive's origin latency (~2.1s to deliver 25-41 KB via a
# 307 to archive.org), so the pass was ~0.40 covers/s of almost pure waiting.
# Measured on the live server at fixed batch size: 1 -> 0.40 covers/s, 4 -> 1.20,
# 8 -> 1.62, 16 -> 2.77. The assertions below now pin the BOUND rather than the
# absence of parallelism, which is the property that actually matters: never more
# than COVER_CONCURRENCY in flight, and every queued path eventually fetched.
reset_world(); $n = 0;
my @many = map { rel() } 1 .. 10;      # 10 covers x 3 specs = 30 requests
T::_warmCovers(\@many, 'test');
my $queued = warmed_count();
ok($queued == 30, 'ten covers, thirty requests in total');
# THE UNIT CHANGED IN 0.9.196 AND THAT IS THE ASSERTION. COVER_CONCURRENCY now
# bounds RELEASES, and a release is three local requests sharing one upstream
# download — so the fan-out is 3x the bound in requests and exactly the bound in
# downloads. Reading this in requests is how someone "tidying" the constant would
# silently triple the load on the LMS handler pool.
ok(scalar(@HTTP_GETS) == T::COVER_CONCURRENCY_IDLE() * 3,
   'the runner opens COVER_CONCURRENCY_IDLE (' . T::COVER_CONCURRENCY_IDLE() . ') RELEASES at once, i.e. '
   . (T::COVER_CONCURRENCY_IDLE() * 3) . ' requests');
ok($T::coverRunning == T::COVER_CONCURRENCY_IDLE(),
   '...and its in-flight counter agrees, counting releases');
{
    # ...and those requests really are whole releases, not a slice across many:
    # three specs each, one source path each. This is the coalescing precondition.
    my %base;
    for my $u (@HTTP_GETS) { (my $b = $u) =~ s/_\d+x\d+_f//; $base{$b}++ }
    is_count(scalar(keys %base), T::COVER_CONCURRENCY_IDLE(),
             'the in-flight requests cover exactly COVER_CONCURRENCY source urls');
    ok(!scalar(grep { $_ != 3 } values %base),
       '...and every one of them has all three of its specs in flight together');
}
ok(scalar($HTTP_GETS[0] =~ m{^http://127\.0\.0\.1:9000/imageproxy/}),
   'it is addressed to our OWN server, on the configured http port');

# THE BOUND, checked at every step of a full drain rather than once: a leak in
# the counter shows up as creep, and a single sample at the start cannot see it.
my $peak = $T::coverRunning;
my $guard = 0;
while (@HTTP_PENDING) {
    last if ++$guard > 200;
    http_settle();
    $peak = $T::coverRunning if $T::coverRunning > $peak;
    Slim::Utils::Timers::fire_all();
}
ok($peak == T::COVER_CONCURRENCY_IDLE(),
   "never more than the idle width in flight across a full drain (peak $peak)");
ok(scalar(@HTTP_GETS) == $queued, 'every queued request is eventually made, and no more');
ok($T::coverRunning == 0, 'the in-flight counter returns to zero — no leak');
ok(scalar(@T::coverQueue) == 0, 'the queue drains completely');

# The marker, from the first completed request.
ok(scalar(@{ $CACHE->{sets} }) == $queued, 'every completed request writes its warm marker');
my ($mk, $mttl) = @{ $CACHE->{sets}[0] };
ok(scalar($mk =~ /^\Q$IMGWARM\E/), "the marker is keyed under the versioned family ($IMGWARM)");
ok($mttl && $mttl < 30 * 86400,
   'the marker expires INSIDE the proxy\'s own 30-day life, so it cannot outlive the image');

# THE RE-ENTRANCY GUARD, which only a launch FAILURE can exercise. When the
# request cannot be constructed at all, `$done` runs INLINE — so without the
# guard the pump recurses one frame per queued path, and the queue is now
# thousands deep rather than 150. Perl reports that as a deep-recursion warning
# long before it becomes a crash, which is the observable this uses; the pass
# must still complete either way, so "it finished" proves nothing on its own.
{
    reset_world(); $n = 0;
    local $HTTP_MODE = 'die';
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, $_[0] };
    T::_warmCovers([ map { rel() } 1 .. 60 ], 'test');   # 180 requests
    ok(!scalar(grep { /Deep recursion/i } @warn),
       'a run of launch failures does not recurse the pump (the re-entrancy guard)');
    # 0.9.197: the drain now SPANS TURNS — 60 releases against COVER_SCAN_BUDGET is
    # more than one turn's worth, and stopping is the point. So the pass completes
    # across the resume timers rather than in one block, and firing them is part of
    # the assertion: a budget that stopped and never came back would stall the queue
    # for ever, which is worse than the stall it exists to fix.
    Slim::Utils::Timers::fire_all() for 1 .. 20;
    ok($T::coverRunning == 0 && !@T::coverQueue,
       '...and the pass still drains completely, across the budget\'s resume timers');
    reset_world();
}

reset_world(); $n = 0;
$HTTP_MODE = '401';
my $N401 = T::COVER_CONCURRENCY_IDLE() + 4;      # more releases than fit in one fan-out
T::_warmCovers([ map { rel() } 1 .. $N401 ], 'test');
is_count(scalar(@T::coverQueue), $N401 - T::COVER_CONCURRENCY_IDLE(),
   'the rest stay queued while COVER_CONCURRENCY_IDLE releases are in flight');
http_settle();
ok(scalar(@T::coverQueue) == 0,
   'a 401 from our own server abandons the whole pass rather than logging it 400 times');
ok(scalar(grep { /refused a local request/ } @{ $LOG->{info} }), '...and says so once, at info');
# The already-in-flight requests still land; what must NOT happen is the queue
# being picked back up. Nothing beyond the initial fan-out is ever launched.
http_settle() while @HTTP_PENDING;
ok(scalar(@HTTP_GETS) == T::COVER_CONCURRENCY_IDLE() * 3,
   'no further requests are made after the refusal — only the initial fan-out');

# --------------------------------------------------------------------------
# THE MARKER CHECK LIVES IN THE LAUNCHER, NOT THE QUEUE BUILDER (0.9.196).
# --------------------------------------------------------------------------
# Two separate properties, and neither was covered before.
#
# 1. THE EVENT LOOP. The check used to sit in the queue-building loop, which runs
#    inside an async HTTP callback (a feed's onDone) — up to COVER_WARM_MAX x 3 =
#    6,000 synchronous SQLite reads in ONE turn, on the loop that streams audio
#    and serves the image proxy. Same hazard class as the 16,000-statement ingest.
#    Asserted as a COUNT of store reads during a build, because that is the only
#    thing that sees it.
# 2. THE SKIP ITSELF. Once the builder stops checking, the launcher is the ONLY
#    thing standing between a re-render and a re-fetch of already-warm covers —
#    and it is what the page-aligned warm (stage 3) will depend on, since that
#    unshifts unchecked by design. Asserted on REQUEST COUNT, which is the only
#    observable: a set comparison of queued paths cannot see a skip.
{
    reset_world(); $n = 0;
    my @feed = map { rel() } 1 .. 30;
    $CACHE->{gets} = 0;
    my ($groups, $seen) = T::_coverGroupsFor(\@feed, T::COVER_WARM_MAX());
    is_count($CACHE->{gets}, 0,
             'the queue builder reads the store ZERO times — it is allocation only');
    is_count(scalar(@$groups), 30, '...and still returns one group per release');
    reset_world();
}
{
    # A release already warm at every spec: no request at all, and the slot is
    # handed straight back rather than being held by a group that does nothing.
    reset_world(); $n = 0;
    my $r    = rel();
    my $src  = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($r);
    my $base = Slim::Web::ImageProxy::proxiedImage($src);
    for my $spec (@{ +T::COVER_SPECS() }) {
        (my $path = $base) =~ s/(\.\w+)$/$spec$1/;
        $CACHE->set($IMGWARM . $path, 1, 100);
    }
    T::_warmCovers([ $r ], 'test');
    is_count(scalar(@HTTP_GETS), 0,
             'a release warm at every spec issues NO request');
    is_count($T::coverRunning, 0, '...and its slot is released, not held');
    is_count($T::coverSkipped, scalar(@{ +T::COVER_SPECS() }),
             '...and the skips are counted, so the stage note can say so');
    is_count($T::coverGroups, 0, '...and it is not counted as a download');
    reset_world();
}
{
    # A PARTLY warm release still fetches the missing spec — the skip must be per
    # path, not per group, or one warm spec would suppress two cold ones.
    reset_world(); $n = 0;
    my $r    = rel();
    my $src  = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($r);
    my $base = Slim::Web::ImageProxy::proxiedImage($src);
    my ($first) = @{ +T::COVER_SPECS() };
    (my $warm = $base) =~ s/(\.\w+)$/$first$1/;
    $CACHE->set($IMGWARM . $warm, 1, 100);

    T::_warmCovers([ $r ], 'test');
    is_count(scalar(@HTTP_GETS), scalar(@{ +T::COVER_SPECS() }) - 1,
             'a partly-warm release fetches only the specs it is missing');
    ok(!scalar(grep { /\Q$first\E/ } @HTTP_GETS),
       '...and the already-warm spec is the one that was skipped');
    is_count($T::coverGroups, 1,
             '...and it still counts as one download, since the rest coalesce');
    http_settle() while @HTTP_PENDING;
    is_count($T::coverRunning, 0, '...and the group completes cleanly afterwards');
    reset_world();
}

# ==========================================================================
section('4b. the browsing brake — one compromise number becomes two');
# ==========================================================================
# THE REPORT THIS ANSWERS is "everything locks up when I move between views",
# and it is not an artwork bug at all: the warm's requests go to OUR OWN server,
# so each one holds an LMS HTTP handler slot that the browse is queued behind.
# A single COVER_CONCURRENCY had to be both "fast enough to drain a feed" and
# "polite enough not to be noticed", and could be neither.

{
    reset_world();
    is_count(T::_coverLimit(), T::COVER_CONCURRENCY_IDLE(),
             'nobody browsing -> the idle width');
    T::_noteBrowse();
    is_count(T::_coverLimit(), T::COVER_CONCURRENCY_BROWSING(),
             'a browse tap -> the browsing width, immediately');
    # The quiet window, driven by moving the marker rather than the clock.
    $T::lastBrowseAt = time() - T::COVER_BROWSE_QUIET() + 2;
    is_count(T::_coverLimit(), T::COVER_CONCURRENCY_BROWSING(),
             '...still braked just inside the quiet window');
    $T::lastBrowseAt = time() - T::COVER_BROWSE_QUIET() - 1;
    is_count(T::_coverLimit(), T::COVER_CONCURRENCY_IDLE(),
             '...and back to the idle width once the window has passed');
    reset_world();
}

{
    # A pass that STARTS while someone is browsing never opens wide.
    reset_world(); $n = 0;
    T::_noteBrowse();
    T::_warmCovers([ map { rel() } 1 .. 20 ], 'test');
    is_count($T::coverRunning, T::COVER_CONCURRENCY_BROWSING(),
             'a warm started while browsing runs at the browsing width');
    is_count(scalar(@HTTP_GETS), T::COVER_CONCURRENCY_BROWSING() * 3,
             '...which is that many RELEASES, so that many times three requests');
    reset_world();
}

{
    # THE CASE THAT MATTERS MOST: a browse arriving MID-DRAIN. The limit must be
    # re-read per pump, and — separately — nothing already in flight may be
    # cancelled, because a cover is nearly always most of the way through a ~2s
    # wait and throwing it away wastes the download rather than saving anything.
    reset_world(); $n = 0;
    T::_warmCovers([ map { rel() } 1 .. 30 ], 'test');
    my $wide = $T::coverRunning;
    is_count($wide, T::COVER_CONCURRENCY_IDLE(), 'the pass opens at the idle width');

    T::_noteBrowse();
    is_count($T::coverRunning, $wide,
             'a browse mid-drain does NOT cancel anything already in flight');

    # Drain the wide fan-out that was ALREADY out. The brake cannot narrow it —
    # that is the previous assertion — so the measurement only begins once the
    # pump has actually had to decide how many to launch NEXT.
    my $guard = 0;
    while (@HTTP_PENDING && $T::coverRunning > T::COVER_CONCURRENCY_BROWSING()
           && ++$guard < 600) {
        http_settle();
        T::_noteBrowse();                       # the user keeps browsing
    }

    my $maxAfter = $T::coverRunning;
    while (@HTTP_PENDING && ++$guard < 900) {
        http_settle();
        $maxAfter = $T::coverRunning if $T::coverRunning > $maxAfter;
        T::_noteBrowse();
    }
    ok($maxAfter <= T::COVER_CONCURRENCY_BROWSING(),
       "under continuous browsing the pass relaunches at the browsing width (peak $maxAfter)");
    ok($T::coverRunning == 0 && !@T::coverQueue,
       '...and it still drains completely rather than stalling under the brake');
    reset_world();
}

{
    # ONE RESTART TIMER, NOT ONE PER CALLBACK. Every landing re-enters _coverTick,
    # so an unguarded arm would schedule one timer per request — 24 of them for a
    # single fan-out, each waking the pump again.
    reset_world(); $n = 0;
    T::_noteBrowse();
    T::_warmCovers([ map { rel() } 1 .. 30 ], 'test');
    T::_coverTick() for 1 .. 5;
    is_count(scalar(@Slim::Utils::Timers::PENDING), 1,
             'repeated pumps under the brake arm exactly ONE restart timer');
    # READ, DO NOT AUTOVIVIFY. Subscripting PENDING[0] when nothing is armed
    # CREATES an empty hashref in the list, which fire_all() then calls as a
    # coderef — so a failing assertion killed the run instead of reporting.
    my $armed = $Slim::Utils::Timers::PENDING[0];
    ok(ref $armed eq 'HASH' && defined $armed->{when}
       && $armed->{when} <= $T::lastBrowseAt + T::COVER_BROWSE_QUIET(),
       '...armed no later than the end of the quiet window');
    # FIRING IT MUST NOT ACCUMULATE. The fired tick re-enters the pump, finds the
    # user still browsing and work still queued, and arms again — that is correct
    # and self-correcting, not a leak. What must never happen is two timers
    # pending for one pass, which is what an unguarded arm produces.
    Slim::Utils::Timers::fire_all();
    is_count(scalar(@Slim::Utils::Timers::PENDING), 1,
             'firing it re-arms exactly once — still one timer, never two');
    is_count($T::coverRestartArmed, 1,
             '...and the flag agrees with the timer that is actually pending');

    # Let the quiet window pass, and it stops re-arming: the pass goes back to
    # full width under its own steam, which is the whole point of the timer.
    $T::lastBrowseAt = time() - T::COVER_BROWSE_QUIET() - 1;
    Slim::Utils::Timers::fire_all();
    is_count(scalar(@Slim::Utils::Timers::PENDING), 0,
             'once the quiet window has passed it arms nothing further');
    is_count($T::coverRestartArmed, 0, '...and the flag is clear');
    reset_world();
}

{
    # ...and NO timer when the pass merely runs out of slots at the idle width:
    # the in-flight callbacks are the wake-up there, and a timer would be churn.
    reset_world(); $n = 0;
    T::_warmCovers([ map { rel() } 1 .. 30 ], 'test');
    is_count(scalar(@Slim::Utils::Timers::PENDING), 0,
             'a full-width pass arms no restart timer — the callbacks wake it');
    reset_world();
}

# EVERY BROWSE ENTRY POINT MARKS THE BROWSE. Source-level, because there is no
# return value to inspect and the defect is an entry point that was never wired —
# exactly how the People You Follow section came to warm no artwork at all.
{
    my @entries = qw(topLevel fetchForYou fetchAll fetchPlaylists resolvePlaylist
                     resolveFollowFeed resolveTrending resolveTrendingAlbums
                     _releaseDetail);
    my @missing = grep { grab($bsrc, $_) !~ /_noteBrowse\(\)/ } @entries;
    ok(!@missing, 'every browse entry point calls _noteBrowse (' . scalar(@entries)
                  . ' checked)' . (@missing ? ' — missing: ' . join(', ', @missing) : ''));
    # The All Releases week drill is a coderef, not a sub, so it needs naming
    # separately — and it is the level a user is most often sitting on while the
    # warm runs.
    ok(scalar(grab($bsrc, '_buildAllLanding') =~ /_noteBrowse\(\)/),
       '...including the All Releases week drill, which is a coderef not a sub');
}

# ==========================================================================
section('4d. the pump yields — store reads per TURN, not per pass');
# ==========================================================================
# THE ASSERTION 0.9.196 WAS MISSING, and the reason it was missing is worth as much
# as the fix. That build moved the marker check out of the queue builder to stop
# 6,000 synchronous store reads landing in one turn of the event loop, and pinned it
# with a counter — but the counter was scoped to the BUILDER (section above: "the
# queue builder reads the store ZERO times"). Nothing counted reads during a TICK.
#
# So the stall did not go away, it MOVED. A group whose paths are already warm never
# goes in flight: _coverLaunch reads its markers, decrements the counter it just
# incremented and returns, leaving `$coverRunning < $limit` unchanged — so the
# launch loop shifts the next group, and the next, to the end of the queue, in one
# turn. Measured against the shipped 0.9.196: 900 reads for 300 all-warm releases.
# And WARM IS THE STEADY STATE, so that was the normal case.
#
# The property is therefore not "how many reads" but "how many reads BEFORE THE LOOP
# GETS A TURN". Only a per-tick count sees it; a per-pass count is identical either
# way, which is exactly how this survived.
{
    reset_world(); $n = 0;
    my $N = T::COVER_SCAN_BUDGET() * 4;          # comfortably more than one turn
    my @feed = map { rel() } 1 .. $N;
    # Every spec of every release already warm — the steady state after a warm pass.
    for my $r (@feed) {
        my $src  = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($r);
        my $base = Slim::Web::ImageProxy::proxiedImage($src);
        for my $spec (@{ +T::COVER_SPECS() }) {
            (my $path = $base) =~ s/(\.\w+)$/$spec$1/;
            $CACHE->set($IMGWARM . $path, 1, 100);
        }
    }
    my ($groups) = T::_coverGroupsFor(\@feed, T::COVER_WARM_MAX());
    push @T::coverQueue, @$groups;

    $CACHE->{gets} = 0;
    T::_coverTick();
    my $first = $CACHE->{gets};
    ok($first <= T::COVER_SCAN_BUDGET() * scalar(@{ +T::COVER_SPECS() }),
       "one turn reads at most the budget's worth ($first, cap "
       . (T::COVER_SCAN_BUDGET() * scalar(@{ +T::COVER_SPECS() })) . ')');
    ok(scalar(@T::coverQueue) > 0,
       '...so an all-warm queue is NOT drained in a single turn');
    ok($T::coverResumeArmed, '...and a resume is armed to carry on');

    # It really does carry on — a budget that stopped and never came back would
    # stall the queue for ever, which is worse than the stall being fixed.
    my ($turns, $worst) = (1, $first);
    while (@T::coverQueue && $turns < 200) {
        $CACHE->{gets} = 0;
        Slim::Utils::Timers::fire_all();
        $turns++;
        $worst = $CACHE->{gets} if $CACHE->{gets} > $worst;
    }
    ok(!scalar(@T::coverQueue), 'the queue still drains completely, over several turns');
    ok($turns > 1, "...and it took more than one ($turns)");
    ok($worst <= T::COVER_SCAN_BUDGET() * scalar(@{ +T::COVER_SPECS() }),
       "no single turn exceeds the budget across the whole drain (worst $worst)");
    is_count(scalar(@HTTP_GETS), 0, '...and nothing was fetched — every group was warm');
    reset_world();
}
{
    # THE BRAKE DOES NOT COVER THIS, which is why the budget is a second bound and
    # not a duplicate of _coverLimit(). A skipped group never occupies a slot, so
    # the concurrency width has nothing to bind on: pre-fix this read all 900 with
    # the brake ON.
    reset_world(); $n = 0;
    my @feed = map { rel() } 1 .. (T::COVER_SCAN_BUDGET() * 4);
    for my $r (@feed) {
        my $src  = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($r);
        my $base = Slim::Web::ImageProxy::proxiedImage($src);
        for my $spec (@{ +T::COVER_SPECS() }) {
            (my $path = $base) =~ s/(\.\w+)$/$spec$1/;
            $CACHE->set($IMGWARM . $path, 1, 100);
        }
    }
    my ($groups) = T::_coverGroupsFor(\@feed, T::COVER_WARM_MAX());
    push @T::coverQueue, @$groups;
    $T::lastBrowseAt = time();                    # somebody is browsing: brake ON
    $CACHE->{gets} = 0;
    T::_coverTick();
    ok($CACHE->{gets} <= T::COVER_SCAN_BUDGET() * scalar(@{ +T::COVER_SPECS() }),
       'the budget bounds the turn with the brake ON too (' . $CACHE->{gets} . ')');
    reset_world();
}
{
    # ONE resume timer, not one per skipped group — the trap the restart timer
    # already carries a flag for.
    reset_world(); $n = 0;
    my @feed = map { rel() } 1 .. (T::COVER_SCAN_BUDGET() * 3);
    for my $r (@feed) {
        my $src  = Plugins::ListenBrainzFreshReleases::API->coverArtUrl($r);
        my $base = Slim::Web::ImageProxy::proxiedImage($src);
        for my $spec (@{ +T::COVER_SPECS() }) {
            (my $path = $base) =~ s/(\.\w+)$/$spec$1/;
            $CACHE->set($IMGWARM . $path, 1, 100);
        }
    }
    my ($groups) = T::_coverGroupsFor(\@feed, T::COVER_WARM_MAX());
    push @T::coverQueue, @$groups;
    T::_coverTick() for 1 .. 5;
    is_count(scalar(@Slim::Utils::Timers::PENDING), 1,
             'five pumps arm ONE resume timer, not five');
    reset_world();
}
{
    # A queue SHORTER than the budget must not arm anything: the resume exists for
    # work left behind, and arming with an empty queue would be a wake-up for nobody.
    reset_world(); $n = 0;
    T::_warmCovers([ map { rel() } 1 .. 2 ], 'test');
    ok(!$T::coverResumeArmed, 'a queue that fits in one turn arms no resume');
    reset_world();
}

# ==========================================================================
section('4c. the warm warms only what will be rendered');
# ==========================================================================
# The warm was handed the RAW feed while every render path applies
# _filterSection first, so blocked artists, unticked release types and hidden
# Various Artists rows were warmed and then never drawn — eating slots out of
# COVER_WARM_MAX. _warmGenres has filtered first since it was written; this is
# the same rule arriving at the covers. Source-level over the warm's call sites,
# for the same reason as above: the bug is a call site that forgot.
{
    my $warm = grab($bsrc, 'warmFeeds');
    $warm =~ s/^\s*#.*$//mg;                      # comments cannot satisfy this
    my @calls = $warm =~ /_warmCovers\(([^,]+),/g;
    is_count(scalar(@calls), 4, 'warmFeeds has four cover-warm call sites');
    my @raw = grep { !/_filter(All|ForYou)\(/ } @calls;
    ok(!@raw, 'every one of them filters the feed first'
              . (@raw ? ' — raw: ' . join(' | ', @raw) : ''));
    # And the right filter each: MuSpy rows are merged into For You, so they
    # answer to that section's settings, not All Releases'.
    ok(scalar($warm =~ /_warmCovers\(_filterForYou\(\$_\[0\]\), 'muspy'\)/),
       'the MuSpy site filters through For You, whose feed its rows are merged into');
    ok(scalar($warm =~ /_warmCovers\(_filterAll\(\$_\[0\]\), 'all releases'\)/),
       'the All Releases sites filter through All Releases');
}
# NO BEHAVIOURAL CASE HERE, AND THAT IS A DECISION RATHER THAN AN OMISSION.
# Driving a blocked artist end-to-end means lifting _filterSection and its five
# dependencies — _allowedTypes, _blockedSet, _isBlocked, _isVariousArtists,
# _typeMatches — which pull in _norm and %FOLD, i.e. the shared matcher. This
# suite would then fail whenever the matcher moved, for reasons that have nothing
# to do with cover art, and the fleet sync already owns that. What CHANGED here is
# which argument the four call sites pass; _filterSection itself is unchanged and
# covered where it belongs.

# ==========================================================================
section('5. people you follow — trending albums warm their covers too');
# ==========================================================================
# THE GAP THIS CLOSES: `_warmCovers` had exactly three callers, all inside
# `warmFeeds` — For You, All Releases and MuSpy. People You Follow warmed NO
# artwork at all, so every Trending Albums row was cold on first sight, every
# time, at ~2.1s of Cover Art Archive latency each. Same symptom as the release
# feeds, from a section nobody had wired up.
#
# The property worth pinning is not "it queues something" — it is that the warmed
# path is byte-identical to what the ROW will request, AND that nothing else is
# warmed. Both halves matter and only the first was asserted until 0.9.192: the warm
# queued a second release-GROUP rel for every aggregate carrying a release_group_mbid,
# while the row falls back to group art only when there is NO caa_release_mbid — so
# every MAPPED row warmed 3 covers no client would ever request, and the suite was
# green because every path it checked was correct. AN ASSERTION THAT EVERY WARMED
# PATH IS RIGHT SAYS NOTHING ABOUT WHETHER EVERY WARMED PATH IS WANTED. Hence the
# exact-count assertions below.
#
# ONE REL, ONE COVER URL. Since 0.9.192 _trendingAlbumRel carries both art ids and
# coverArtUrl picks between them (release, then group), exactly as _parseMuSpy does —
# so there is one builder, the row does no ICON re-test, and the warm has no branch
# to replay. _trendingAlbumFallbackRel is gone.
{
    for my $name (qw(_trendingAlbumRel _warmTrendingCovers)) {
        my $body = grab($bsrc, $name);
        eval "package T; our (\@coverQueue, \%coverQueued, \$coverRunning, \$coverPumping,"
           . " \$coverStageOpen, \$coverFetched); $body 1;"
            or die "eval $name: $@";
    }
    ok(scalar($bsrc !~ /_trendingAlbumFallbackRel/),
       'the second rel builder is GONE — one builder per row, as every other view has');
    my ($rowsub) = $bsrc =~ /^sub _trendingAlbumRow \{(.*?)^\}/ms;
    (my $rowcode = $rowsub // '') =~ s/^\s*#.*$//mg;
    ok(scalar(length $rowsub && $rowcode !~ /\bICON\b/),
       '...and the row no longer re-tests the built item for ICON to choose a URL');

    # A mapped aggregate (has a release MBID) and an UNMAPPED one (stats row with
    # only a release group), which is the case that resolves to release-group art.
    my $mapped = { artist => 'A', title => 'T', year => 2026,
                   release_group_mbid => 'rg-1', caa_release_mbid => 'rel-1' };
    my $unmapped = { artist => 'B', title => 'U', year => 2026,
                     release_group_mbid => 'rg-2' };
    # Neither id: the row shows the plugin icon and there is nothing to warm.
    my $bare = { artist => 'C', title => 'V', year => 2026 };

    reset_world();
    T::_warmTrendingCovers([ $mapped, $unmapped, $bare ], 'trending albums · this month');
    my @paths = warmed_paths();
    ok(scalar(@paths) > 0, 'a trending albums build queues cover warms at all');

    # What the ROW would ask for, derived the same way the renderer does it — ONE
    # coverArtUrl call on the row's own rel, for both shapes.
    # Asserted on the RAW coverArtUrl output, not the proxied path: proxiedImage
    # percent-escapes the url into a single path segment, so `release-group/` is not
    # greppable there and a regex against it would pass for the wrong reason.
    my $api = 'Plugins::ListenBrainzFreshReleases::API';
    my $urlMapped   = $api->coverArtUrl(T::_trendingAlbumRel($mapped))   // '';
    my $urlUnmapped = $api->coverArtUrl(T::_trendingAlbumRel($unmapped)) // '';
    ok(scalar($urlMapped =~ m{/release/rel-1/}),
       'a mapped aggregate resolves to RELEASE art (coverArtUrl prefers it)');
    ok(scalar($urlUnmapped =~ m{/release-group/rg-2/}),
       'an UNMAPPED one resolves to RELEASE-GROUP art from the SAME builder');
    ok(scalar(!defined $api->coverArtUrl(T::_trendingAlbumRel($bare))),
       '...and one with neither id resolves to nothing, so the row keeps the icon');

    my $rowMapped   = Slim::Web::ImageProxy::proxiedImage($urlMapped);
    my $rowUnmapped = Slim::Web::ImageProxy::proxiedImage($urlUnmapped);
    for my $pair ([ $rowMapped, 'a mapped album' ], [ $rowUnmapped, 'an UNMAPPED stats row (release-group art)' ]) {
        my ($base, $what) = @$pair;
        (my $want = $base) =~ s/(\.\w+)$/_150x150_f$1/;
        ok(scalar(grep { $_ eq $want } @paths),
           "$what warms the exact path its row will request");
    }

    # THE HALF THAT WAS MISSING. Two rows with art, three specs each, and nothing
    # else — in particular NO release-group cover for the mapped row, which is what
    # 0.9.191 queued and no client would ever ask for. The bare aggregate contributes
    # nothing. Counting is the only way to see work that is correct but unwanted.
    is_count(scalar(@paths), 2 * scalar(@{ +T::COVER_SPECS() }),
             'exactly one cover URL per row with art, times the spec ladder — nothing spare');
    # The escaped form, because that is what lands in the queue. rg-1 is the mapped
    # aggregate's group: 0.9.191 warmed this and nothing would ever request it.
    my $strayRg = Slim::Web::ImageProxy::proxiedImage(
        $api->coverArtUrl({ caa_release_group_mbid => 'rg-1' }));
    (my $strayBase = $strayRg) =~ s/(\.\w+)$//;
    ok(scalar(!grep { index($_, $strayBase) == 0 } @paths),
       'the MAPPED row does NOT also warm its release-group cover');
    ok(scalar(grep { /\.jpg$/ } @paths) == scalar(@paths),
       'trending covers are JPEG like every other row, not re-encoded PNG');
    reset_world();
}

# AND THE BUILD ACTUALLY CALLS IT — the half a unit test of the helper cannot see.
# Both album ranges, and on the CACHE-HIT path as well as a fresh build, because
# `_buildAlbumsData` answers its callback with the stored aggregates when the data
# is still inside its TTL (2/7/30 days by range) — the covers expire on their own
# schedule, so the list being unchanged is no reason to skip warming them.
{
    my ($warm) = $bsrc =~ /^sub _warmTrending \{(.*?)^\}/ms;
    ok(defined $warm && length $warm, '_warmTrending located');
    (my $code = $warm) =~ s/^\s*#.*$//mg;
    my $n = () = $code =~ /_warmTrendingCovers\(/g;
    is_count($n, 2, 'both trending album ranges warm their covers');
    my ($builder) = $bsrc =~ /^sub _buildAlbumsData \{(.*?)^\}/ms;
    ok(scalar(defined $builder && $builder =~ /\$onDone->\(\$data\);\s*return/),
       '...and _buildAlbumsData answers its callback on a CACHE HIT, so a warm still runs');
}

# ==========================================================================
print "\n" . ('=' x 74) . "\n$pass passed, $fail failed.\n";
exit($fail ? 1 : 0);
