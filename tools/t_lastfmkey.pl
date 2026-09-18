#!/usr/bin/env perl
#
# t_lastfmkey.pl — the BUILT-IN Last.fm key, and the rules that keep it safe.
#
#   perl tools/t_lastfmkey.pl
#
# The built-in key is the ONLY key: the manual settings field was removed on
# Simon's call (2026-09-14). The key cannot be secret — anything the plugin decodes
# at runtime, a user can decode too (see the block above API::_lfmBuiltin). What
# this suite pins is everything that CAN be controlled:
#
#   1. Storage     — not plaintext (or base64) anywhere in the repo; a clipped
#                    constant reads as "no key", never as a garbage key.
#   2. Resolution  — the built-in key, and nothing a pref can override.
#   3. Transport   — every Last.fm request is a POST with the key in the BODY.
#                    LMS core logs a failed request's URI at WARN, so a key in the
#                    URL is a key in server.log.
#   4. Latch       — error 10/26 stop the key for the process, logged ONCE; 29
#                    backs off and recovers; unrelated errors latch nothing.
#   5. Failures    — a failed or keyless request stores NO empty checkpoint; error 6
#                    (artist not found) is an ANSWER and IS stored as empty.
#   6. Scrubbing   — no log line carries the key.
#   7. Wiring      — every gate goes through the accessor; the manual option is
#                    gone from code, settings page and strings; a stored value is
#                    removed at startup.
#
# The real subs are lifted from API.pm, never retyped. The HTTP stub is shaped on
# LMS's own source, not a guess: slimserver public/9.0 SimpleAsyncHTTP::onError
# calls the error callback as (self, error, HTTP::Response), Async::HTTP routes a
# non-2xx there with the status line as the error, and SimpleHTTP::Base takes a
# trailing odd argument as the request body. The Last.fm responses are captured
# live (2026-09-14): an invalid key is HTTP 403 with {"error":10,...}.
#
# Anti-test it: LBF_API=<mutated copy> perl tools/t_lastfmkey.pl
#
# Exit 0 = all pass.
use strict;
use warnings;
use FindBin;
use File::Find ();
use MIME::Base64 ();
use JSON::PP ();

BEGIN { *CORE::GLOBAL::time = sub { $T::NOW } }

my $ROOT   = "$FindBin::Bin/..";
my $PLUGIN = "$ROOT/ListenBrainzFreshReleases";
my $APIF   = $ENV{LBF_API} || "$PLUGIN/API.pm";

sub slurp { my ($f) = @_; open my $fh, '<', $f or die "$f: $!"; local $/; return scalar <$fh> }
my $src = slurp($APIF);

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}

# One-liner subs first (`sub x { ... }` on one line), then the multi-line shape.
# A missing sub is a FAILED assertion, not a die — a harness that dies half way
# prints a shorter list, which reads as a pass.
sub grab {
    my ($name, $from) = @_;
    $from //= $src;
    return $1 if $from =~ /^(sub \Q$name\E\s+\{[^\n]*\}[ \t]*)$/m;
    return $1 if $from =~ /^(sub \Q$name\E \{.*?^\})/ms;
    ok(0, "sub $name exists");
    return "sub $name { die 'missing sub $name' }";
}
sub constval {
    my ($name) = @_;
    return $src =~ /^use constant \Q$name\E\s*=>\s*'([^']*)'/m ? $1
         : $src =~ /^use constant \Q$name\E\s*=>\s*(\d+)/m     ? $1
         : undef;
}

# ---------------------------------------------------------------- stub world --
{
    package T;
    our $NOW = 1_000_000;
    our (%PREF, %CACHE, @LOG, @HTTP, @PUT);
    our $prefs = bless {}, 'T::Prefs';
    our $log   = bless {}, 'T::Log';
    our $cache = bless {}, 'T::Cache';
    use constant LASTFM_BASE_URL   => 'https://ws.audioscrobbler.com/2.0/';
    use constant SIMILAR_TTL       => 86400;
    use constant LFM_EMPTY_TTL     => 86400;
    use constant LFM_SIMILAR_LIMIT => 30;
    sub USER_AGENT { 'test/1' }
    sub from_json  { JSON::PP->new->utf8->decode($_[0]) }
    sub _lfmFresh  { 0 }           # always ask upstream; freshness is not under test

    package T::Prefs;  sub get { $T::PREF{$_[1]} }
    package T::Cache;  sub get { $T::CACHE{$_[1]} } sub set { $T::CACHE{$_[1]} = $_[2]; 1 }
    package T::Log;
    sub warn  { push @T::LOG, [warn  => $_[1]] }
    sub error { push @T::LOG, [error => $_[1]] }
    sub info  { push @T::LOG, [info  => $_[1]] }
    sub debug { push @T::LOG, [debug => $_[1]] }

    package Plugins::ListenBrainzFreshReleases::DB;
    sub lfmGet { undef }
    sub lfmPut { push @T::PUT, [@_]; 1 }

    package Slim::Networking::SimpleAsyncHTTP;
    our @NEXT;   # queued answers: { code, content }
    sub new  { my ($c, $ok, $err) = @_; bless { ok => $ok, err => $err }, $c }
    sub get  { my ($s, $url) = @_; push @T::HTTP, { method => 'GET', url => $url }; $s->_answer }
    sub post {
        my ($s, $url, @rest) = @_;
        my $body = @rest % 2 ? pop @rest : '';
        push @T::HTTP, { method => 'POST', url => $url, body => $body, headers => { @rest } };
        $s->_answer;
    }
    sub error { $_[0]{error} }
    sub _answer {
        my ($s) = @_;
        my $a = shift(@NEXT) // { code => 200, content => '{}' };
        my $res = bless { %$a }, 'T::Resp';
        if (($a->{code} // 200) >= 400) {
            $s->{error} = "$a->{code} " . ($a->{code} == 403 ? 'Forbidden' : 'Error');
            $s->{err}->($s, $s->{error}, $res);
        } else {
            $s->{ok}->($res);
        }
    }
    package T::Resp;
    sub content { $_[0]{content} }
    sub code    { $_[0]{code} }
}

my @SUBS = qw(_lfmBuiltin _lfmLatched _lfmResolve lastfmKey lastfmKeySource
              lastfmConfigured lastfmLatchState _lfmNoteError _lfmScrub _lastfmPost _lfmKey
              getLastfmTags _lastfmCall _parseLastfmTags getSimilarArtistsLastfm);

my %CONST = map { $_ => constval($_) } qw(LFM_BUILTIN_HEX LFM_BUILTIN_PAD LFM_RATE_BACKOFF);
ok(defined $CONST{$_}, "constant $_ is declared") for sort keys %CONST;

sub compileInto {
    my ($pkg, %const) = @_;
    my $code = "package $pkg;\nour (%LFM_LATCH, %LFM_LATCH_LOGGED, %LFM_MEMO);\n"
             . "our (\$prefs, \$log, \$cache) = (\$T::prefs, \$T::log, \$T::cache);\n"
             . join('', map { "use constant $_ => " . (($const{$_} // '') =~ /^\d+$/ ? $const{$_} : "'" . ($const{$_} // '') . "'") . ";\n" } sort keys %const)
             . join("\n", map { grab($_) } @SUBS) . "\n1;\n";
    eval $code or die "compile $pkg: $@";
}
{
    no strict 'refs';
    for my $p (qw(T2)) {
        *{"${p}::$_"} = \&{"T::$_"} for qw(USER_AGENT from_json _lfmFresh LASTFM_BASE_URL SIMILAR_TTL LFM_EMPTY_TTL LFM_SIMILAR_LIMIT);
    }
}
compileInto('T', %CONST);
# TRUNCATED, not overwritten: replacing leading digits with non-hex letters can still
# decode to a hex-looking byte (pack 'H' maps any letter to SOME nibble), so that
# fixture passed the 32-hex check and proved nothing. A clipped constant is also
# the realistic corruption (a bad merge, an editor wrap).
compileInto('T2', %CONST, LFM_BUILTIN_HEX => substr($CONST{LFM_BUILTIN_HEX} // '', 0, -2));

no warnings 'once';
sub reset_world {
    %T::PREF = (); %T::CACHE = (); @T::LOG = (); @T::HTTP = (); @T::PUT = ();
    @Slim::Networking::SimpleAsyncHTTP::NEXT = ();
    %T::LFM_LATCH = (); %T::LFM_LATCH_LOGGED = (); %T::LFM_MEMO = ();
}
sub answer { push @Slim::Networking::SimpleAsyncHTTP::NEXT, { code => $_[0], content => $_[1] } }

my $BUILTIN = T::_lfmBuiltin();
my $TAGS    = '{"toptags":{"tag":[{"name":"rock","count":100},{"name":"indie","count":60}]}}';
my $ERR10   = '{"message":"Invalid API key - You must be granted a valid key by last.fm","error":10}';

# ============================================================ 1. storage =====
print "\n1. The built-in key is not stored in the clear\n";
{
    ok($BUILTIN =~ /^[0-9a-f]{32}$/, 'the built-in key decodes to a 32-hex Last.fm key');
    ok(T2::_lfmBuiltin() eq '', 'a clipped constant reads as NO key, not a garbage key');
    ok(T2->lastfmKeySource eq 'none' && T2->lastfmConfigured == 0, '...and the tier reads as not configured');

    my @hits;
    my $b64  = MIME::Base64::encode_base64($BUILTIN, '');
    my $b64q = MIME::Base64::encode_base64("api_key=$BUILTIN", '');
    File::Find::find({ no_chdir => 1, wanted => sub {
        if (-d $_ && m{/\.git$}) { $File::Find::prune = 1; return }
        return unless -f $_ && -s _ < 5_000_000;
        my $c = eval { slurp($_) } // return;
        push @hits, $_ if index($c, $BUILTIN) >= 0 || index($c, $b64) >= 0 || index($c, $b64q) >= 0;
    } }, $ROOT);
    ok(!@hits, 'the key (plain or base64) appears in no file in the repo'
             . (@hits ? ': ' . join(', ', @hits) : ''));
    # Control: the scan really reads the files it claims to.
    ok(index(slurp($APIF), $CONST{LFM_BUILTIN_HEX} // "\0") >= 0, '...control: the scan sees the masked constant');
}

# ========================================================= 2. resolution =====
print "\n2. The built-in key is the only key\n";
{
    reset_world();
    ok(T->lastfmKey eq $BUILTIN && T->lastfmKeySource eq 'builtin', 'the built-in key is used');
    ok(T->lastfmConfigured == 1, 'lastfmConfigured is true');
    # A value left in prefs.yaml from before the field was removed must do nothing.
    $T::PREF{lastfm_api_key} = 'a' x 32;
    ok(T->lastfmKey eq $BUILTIN, 'a stale lastfm_api_key pref is IGNORED');
    ok(index(T->lastfmLatchState, $BUILTIN) < 0 && T->lastfmLatchState eq 'builtin: ok',
       'the state report never carries the key value');
}

# ========================================================== 3. transport =====
print "\n3. The key travels in a POST body, never a URL\n";
{
    reset_world();
    answer(200, $TAGS);
    my ($got, $err);
    T->getLastfmTags('Radiohead', 'OK Computer', sub { $got = shift }, sub { $err = shift }, 1);
    my $r = $T::HTTP[0] || {};
    ok(@T::HTTP == 1, 'one request made');
    ok(($r->{method} // '') eq 'POST', 'tag lookup is a POST');
    ok(($r->{url} // '') eq T::LASTFM_BASE_URL, '...to the bare HTTPS endpoint, no query string');
    ok(index($r->{body} // '', "api_key=$BUILTIN") >= 0, '...with the key in the body');
    ok(index($r->{body} // '', 'method=album.gettoptags') >= 0, '...control: the body carries the method');
    ok(($r->{headers}{'Content-Type'} // '') eq 'application/x-www-form-urlencoded', '...form-encoded');
    ok(ref $got eq 'ARRAY' && "@$got" eq 'rock indie', 'the answer still parses');

    reset_world();
    answer(200, '{"similarartists":{"artist":[{"name":"Thom Yorke","mbid":"8ed2e0b3-aa4c-4e13-bec3-dc7393ed4d6b","match":"1"}]}}');
    my $sim;
    T->getSimilarArtistsLastfm('Radiohead', sub { $sim = shift }, sub {});
    $r = $T::HTTP[0] || {};
    ok(($r->{method} // '') eq 'POST' && ($r->{url} // '') eq T::LASTFM_BASE_URL,
       'similar artists is a POST to the bare endpoint');
    ok(index($r->{body} // '', 'method=artist.getsimilar') >= 0 && index($r->{body} // '', "api_key=$BUILTIN") >= 0,
       '...key and method in the body');
    ok(ref $sim eq 'ARRAY' && @$sim == 1 && $sim->[0]{name} eq 'Thom Yorke', 'the similar answer still parses');

    ok(!grep({ ($_->{method} // '') ne 'POST' || index($_->{url} // '', 'api_key') >= 0 } @T::HTTP),
       'no Last.fm request carries the key in its URL');
    ok($src !~ /LASTFM_BASE_URL\s*\.\s*'\?'/, 'API.pm builds no Last.fm GET query string');
    ok($src =~ /->post\(LASTFM_BASE_URL/, '...control: the POST call site is in API.pm');
}

# ============================================================== 4. latch =====
print "\n4. A rejected key stops, once, and does not wedge the warm\n";
{
    reset_world();
    answer(403, $ERR10);
    my ($done, $err) = (0, undef);
    T->getLastfmTags('A', '', sub { $done++ }, sub { $err = shift }, 1);
    ok(@T::HTTP == 1, 'control: the first request really went out');
    ok(defined $err && !$done, 'a 403 / error 10 reaches onError, not onDone');
    ok(T->lastfmKeySource eq 'latched' && T->lastfmKey eq '', 'the built-in key is now stopped');
    ok(T->lastfmConfigured == 1, '...but Last.fm still counts as configured (stored tags stay visible)');
    ok(T->lastfmLatchState =~ /^builtin: invalid key/, '...and the state report says why');
    my @warns = grep { $_->[0] eq 'warn' } @T::LOG;
    ok(@warns == 1 && $warns[0][1] =~ /built-in/ && $warns[0][1] =~ /error 10/, 'logged once, naming the built-in key');

    ($done, $err) = (0, undef);
    T->getLastfmTags('B', '', sub { $done++ }, sub { $err = shift }, 1);
    ok(@T::HTTP == 1, 'a stopped key makes NO further request');
    ok(defined $err && !$done, '...and the caller is told it failed');
    T::_lfmNoteError($BUILTIN, 10);
    ok((grep { $_->[0] eq 'warn' } @T::LOG) == 1, 'a repeat of the same error is not logged again');

    reset_world();
    answer(200, $ERR10);
    T->getLastfmTags('A', '', sub {}, sub {}, 1);
    ok(T->lastfmKeySource eq 'latched', 'error 10 in a 200 body also stops the key');

    reset_world();
    answer(200, '{"error":26,"message":"Suspended API key"}');
    T->getLastfmTags('A', '', sub {}, sub {}, 1);
    $T::NOW += 10 * 86400;
    ok(T->lastfmKeySource eq 'latched', 'error 26 (suspended) stays stopped');

    reset_world();
    answer(200, '{"error":29,"message":"Rate limit exceeded"}');
    T->getLastfmTags('A', '', sub {}, sub {}, 1);
    ok(T->lastfmKeySource eq 'latched', 'error 29 (rate limited) stops the key for now');
    $T::NOW += $CONST{LFM_RATE_BACKOFF} + 1;
    ok(T->lastfmKeySource eq 'builtin', '...and it is back after the backoff');

    reset_world();
    answer(200, '{"error":6,"message":"Artist not found"}');
    T->getLastfmTags('Nobody', '', sub {}, sub {}, 1);
    ok(T->lastfmKeySource eq 'builtin', 'an unrelated error (6) stops nothing');
}

# =========================================================== 5. failures =====
print "\n5. A failure is not an empty answer\n";
{
    reset_world();
    answer(200, $TAGS);
    my $done;
    T->getLastfmTags('A', '', sub { $done = shift }, sub {}, 1);
    ok(@T::PUT == 1 && ref $done eq 'ARRAY', 'control: a real answer IS stored');

    reset_world();
    answer(500, 'oops');
    my ($d, $e) = (0, undef);
    T->getLastfmTags('A', '', sub { $d++ }, sub { $e = shift }, 1);
    ok(!@T::PUT, 'a failed artist lookup stores nothing');
    ok(!$d && defined $e, '...and is reported as a failure, not as "no tags"');

    reset_world();
    T::_lfmNoteError($BUILTIN, 10);
    ($d, $e) = (0, undef);
    T->getLastfmTags('A', '', sub { $d++ }, sub { $e = shift }, 1);
    ok(!@T::PUT && !@T::HTTP && !$d && defined $e, 'with the key stopped: no request, no store, a failure');

    # ERROR 6 IS AN ANSWER. Captured live 2026-09-14: an artist Last.fm does not
    # know is HTTP 200 + this body, and ~20% of a sampled week's feed artists get it.
    my $ERR6 = '{"error":6,"message":"The artist you supplied could not be found","links":[]}';
    reset_world();
    answer(200, $ERR6);
    ($d, $e) = (0, undef);
    my $got;
    T->getLastfmTags('Doll Face Killah', '', sub { $got = shift; $d++ }, sub { $e = shift }, 1);
    ok(@T::PUT == 1 && ref $T::PUT[0][1] eq 'ARRAY' && !@{ $T::PUT[0][1] },
       'error 6 (artist not found) IS stored, as an empty answer');
    ok($d && !defined $e && ref $got eq 'ARRAY' && !@$got, '...and reported as "no tags", not as a failure');

    reset_world();
    answer(200, '{"error":8,"message":"Operation failed - Most likely the backend service failed"}');
    ($d, $e) = (0, undef);
    T->getLastfmTags('A', '', sub { $d++ }, sub { $e = shift }, 1);
    ok(!@T::PUT && !$d && defined $e, 'control: a transient error body (8) still stores nothing');

    reset_world();
    answer(200, $ERR6);
    my ($sim, $simErr);
    T->getSimilarArtistsLastfm('Doll Face Killah', sub { $sim = shift }, sub { $simErr = 1 });
    ok(ref $sim eq 'ARRAY' && !@$sim && !$simErr, 'similar artists: error 6 answers an empty list');
    ok(ref $T::CACHE{'lbf:lfmsimilar:doll face killah'} eq 'ARRAY', '...and caches it, so the radio does not re-ask');

    reset_world();
    answer(200, '{"error":8,"message":"Operation failed"}');
    ($sim, $simErr) = (undef, 0);
    T->getSimilarArtistsLastfm('A', sub { $sim = shift }, sub { $simErr = 1 });
    ok($simErr && !keys %T::CACHE, 'control: similar artists caches no transient error body');
}

# =========================================================== 6. scrubbing ====
print "\n6. No log line carries the key\n";
{
    reset_world();
    my $s = T::_lfmScrub("Failed to connect to https://ws.audioscrobbler.com/2.0/?api_key=$BUILTIN&method=x ($BUILTIN)");
    ok(index($s, $BUILTIN) < 0 && $s =~ /api_key=\*\*\*/, '_lfmScrub removes both the param and the bare value');

    answer(403, $ERR10);
    T->getLastfmTags('A', '', sub {}, sub {}, 1);
    my $all = join "\n", map { $_->[1] // '' } @T::LOG;
    ok(length($all) > 0, 'control: the failure was logged');
    ok(index($all, $BUILTIN) < 0, 'no key value in any log line');
}

# ============================================================== 7. wiring ====
print "\n7. Every gate goes through the accessor; the manual option is gone\n";
{
    my $browse = slurp("$PLUGIN/Browse.pm");
    my $dstm   = slurp("$PLUGIN/DSTM.pm");
    my $diag   = slurp("$PLUGIN/Diag.pm");
    my $plugin = slurp("$PLUGIN/Plugin.pm");
    my $html   = slurp("$PLUGIN/HTML/EN/plugins/ListenBrainzFreshReleases/settings.html");
    my $str    = slurp("$PLUGIN/strings.txt");
    my $sett   = slurp("$PLUGIN/Settings.pm");
    (my $code  = join "\n", $src, $browse, $dstm, $diag, $plugin, $sett) =~ s/^\s*#.*$//mg;

    my @reads = $code =~ /->get\(\s*'lastfm_api_key'\s*\)/g;
    my @removes = $plugin =~ /->remove\(\s*'lastfm_api_key'\s*\)/g;
    ok(@removes == 1, 'Plugin.pm removes a stored lastfm_api_key at startup');
    ok(@reads == 1 && $plugin =~ /defined \$prefs->get\('lastfm_api_key'\)/,
       '...and the only read of the pref is that removal guard (found ' . scalar(@reads) . ')');
    ok($code !~ /lastfm_api_key\s*=>/, 'no lastfm_api_key default in any init');
    ok($sett !~ /\blastfm_api_key\b/, 'Settings.pm no longer saves the pref');
    ok($html !~ /lastfm/i, 'the settings page has no Last.fm field, button or script hook');
    ok($str !~ /PLUGIN_LBF_LASTFM_(?:KEY|CHECK|PLACEHOLDER)/, 'the field strings are gone');
    ok($html =~ /lbf_token_check/, '...control: the token check button is still there');

    ok(grab('_warmLastfm', $browse) =~ /API->lastfmKey\b/, 'Browse::_warmLastfm gates on lastfmKey');
    ok(grab('_lastfmGenres', $browse) =~ /API->lastfmConfigured\b/, 'Browse::_lastfmGenres gates on lastfmConfigured (latch-independent)');
    ok(grab('_radioViaNames', $dstm) =~ /\$API->lastfmKey\b/, 'DSTM::_radioViaNames gates on lastfmKey');
    ok($diag =~ /body\s*=>\s*'method=auth\.gettoken[^']*api_key='/, 'Diag sends its Last.fm probe key in a body');
    ok($diag !~ /url\s*=>[^\n]*api_key/, 'Diag puts no api_key in any probe url');
}

print "\n", '=' x 74, "\n$pass passed, $fail failed.\n";
exit($fail ? 1 : 0);
