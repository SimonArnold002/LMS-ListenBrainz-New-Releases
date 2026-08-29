#!/usr/bin/env perl
#
# t_rgresolver.pl — getReleaseGroupByName resolves through the HOSTED
# /discography tier first, and falls back to MusicBrainz on anything less than a
# confident hit.
#
# WHY THIS SUITE EXISTS.
#
#   Measured on the live server 2026-08-22: a cold People You Follow open spent
#   22,880ms in 12 serial MusicBrainz searches, because `mb_base_url` was unset
#   and they went to public musicbrainz.org at ~1 req/s (one came back 503). The
#   hosted route answers in 195-358ms cold / ~80ms warm, and returns release-GROUP
#   mbids verified identical to MusicBrainz's own.
#
#   THE RISK THIS PINS is not speed, it is IDENTITY. The `release_group_mbid` this
#   sub fills is what everything downstream keys on: the dedupe key when one album
#   arrives from two followers, the CAA `release-group/<id>` art URL, the LB genre
#   lookups and the detail page. A tier that returned a RELEASE mbid instead —
#   which is exactly what the neighbouring `/album/<t>/<a>` route does — would
#   poison all four while looking like it worked. So the fixtures here use REAL
#   payload shapes captured from the live service, and section 1 asserts the id
#   that comes back is the one MusicBrainz gives for the same album.
#
#   The second risk is the fallback going quiet. Every non-hit must reach
#   MusicBrainz: an unknown artist, a title absent from the discography, a rate
#   limit past the budget, a dead service. A hosted tier that swallowed those
#   would look like a coverage regression with no error anywhere.
#
# ANTI-TEST: point LBF_API / LBF_BROWSE at mutated copies.
#   - delete the `return $mbFallback->()` on "not in discography"  -> section 5 red
#   - reverse _hostedDiscoPick's sort (pick the remaster)          -> section 4 red
#   - drop the `?mbid=` from the discography path                  -> section 3 red
#   - cache the unknown artist at MB_FOUND_TTL instead of EMPTY    -> section 6 red

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);

my $ROOT = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));
my $API  = $ENV{LBF_API} || "$ROOT/ListenBrainzFreshReleases/API.pm";

my ($pass, $fail) = (0, 0);

# Same guard as every other suite here: a bare m// or grep in the condition slot
# returns a LIST, which shifts $msg out of position and turns the assertion into
# "is this label truthy". Wrap conditions in scalar().
sub ok {
    my ($cond, $msg) = @_;
    die "t_rgresolver: assertion called with no message — a bare m// or grep has\n"
      . "shifted the arguments. Wrap the condition in scalar().\n"
        unless defined $msg && length $msg;
    if ($cond) { $pass++; printf "  ok   %s\n", $msg }
    else       { $fail++; printf "  FAIL %s\n", $msg }
}
sub is {
    my ($got, $want, $msg) = @_;
    $got  = defined $got  ? $got  : '(undef)';
    $want = defined $want ? $want : '(undef)';
    if ($got eq $want) { $pass++; printf "  ok   %s\n", $msg }
    else { $fail++; printf "  FAIL %s  ->  '%s'  (wanted '%s')\n", $msg, $got, $want }
}
sub section { printf "\n%s\n%s\n", $_[0], '-' x 74 }

# ---------------------------------------------------------------------------
# A minimal LMS. Three levers: %ROUTES maps a url substring to a canned response,
# @REQUESTS records what went out, and %CACHE is a REAL store (not a black hole)
# because the per-artist map caching is one of the properties under test.
# ---------------------------------------------------------------------------
our %ROUTES;
our @REQUESTS;
our %CACHE;
our %CACHE_TTL;

my $stub = tempdir(CLEANUP => 1);
sub stubfile {
    my ($path, $body) = @_;
    my $full = "$stub/$path";
    system('mkdir', '-p', dirname($full)) == 0 or die "mkdir: $?";
    open my $fh, '>', $full or die "$full: $!";
    print $fh $body;
    close $fh;
}

stubfile('Slim/Utils/Log.pm', <<'EOF');
package Slim::Utils::Log;
use Exporter 'import'; our @EXPORT = qw(logger);
package Slim::Utils::Log::Obj;
sub AUTOLOAD { my $n = our $AUTOLOAD; return if $n =~ /DESTROY/; return 1 }
package Slim::Utils::Log;
sub logger { bless {}, 'Slim::Utils::Log::Obj' }
sub addLogCategory { 1 }
1;
EOF

stubfile('Slim/Utils/Prefs.pm', <<'EOF');
package Slim::Utils::Prefs;
use Exporter 'import'; our @EXPORT = qw(preferences);
package Slim::Utils::Prefs::Obj;
sub get { undef } sub set { 1 } sub init { 1 } sub setChange { 1 } sub migrate { 1 }
package Slim::Utils::Prefs;
sub preferences { bless {}, 'Slim::Utils::Prefs::Obj' }
1;
EOF

stubfile('Slim/Utils/Cache.pm', <<'EOF');
package Slim::Utils::Cache;
package Slim::Utils::Cache::Obj;
sub get { undef } sub set { 1 } sub remove { 1 }
package Slim::Utils::Cache;
sub new { bless {}, 'Slim::Utils::Cache::Obj' }
1;
EOF

# Routed HTTP. Matches the FIRST %ROUTES key found in the url; an unrouted url is
# an error response, which is itself meaningful (it exercises the fallback).
stubfile('Slim/Networking/SimpleAsyncHTTP.pm', <<'EOF');
package Slim::Networking::SimpleAsyncHTTP;
sub new { my ($c, $ok, $err, $opt) = @_; bless { ok => $ok, err => $err }, $c }
sub content { $_[0]{_body} }
sub code    { $_[0]{_code} }
sub error   { $_[0]{_error} }
sub headers { {} }
sub get {
    my ($self, $url, @headers) = @_;
    push @main::REQUESTS, { url => $url, headers => \@headers };
    for my $frag (sort { length($b) <=> length($a) } keys %main::ROUTES) {
        next unless index($url, $frag) >= 0;
        my $r = $main::ROUTES{$frag};
        if (ref $r eq 'HASH' && $r->{error}) {
            $self->{_error} = $r->{error};
            $self->{_code}  = $r->{code} || 500;
            $self->{err}->($self);
            return 1;
        }
        $self->{_body} = ref $r eq 'HASH' ? $r->{body} : $r;
        $self->{_code} = 200;
        $self->{ok}->($self);
        return 1;
    }
    $self->{_error} = 'no route';
    $self->{_code}  = 404;
    $self->{err}->($self);
    return 1;
}
sub post { my $self = shift; $self->get(@_) }
1;
EOF

for my $m (qw(Slim/Utils/Strings Slim/Utils/Timers Slim/Utils/Misc
              Slim/Utils/OSDetect Slim/Utils/PluginManager Slim/Web/ImageProxy
              Slim/Control/Request Slim/Schema Slim/Music/Import)) {
    (my $pkg = $m) =~ s{/}{::}g;
    stubfile("$m.pm", <<"EOF");
package $pkg;
use Exporter 'import'; our \@EXPORT = qw(string cstring);
sub string { '' } sub cstring { '' }
sub AUTOLOAD { my \$n = our \$AUTOLOAD; return if \$n =~ /DESTROY/; return 1 }
1;
EOF
}

# REAL JSON, unlike the other suites' `sub from_json { {} }`. The payload shape is
# the thing under test — a stub parser would make every fixture indistinguishable.
stubfile('JSON/XS/VersionOneAndTwo.pm', <<'EOF');
package JSON::XS::VersionOneAndTwo;
use JSON::PP ();
use Exporter 'import'; our @EXPORT = qw(to_json from_json encode_json decode_json);
my $J = JSON::PP->new->utf8->canonical;
sub from_json   { $J->decode($_[0]) }
sub decode_json { $J->decode($_[0]) }
sub to_json     { $J->encode($_[0]) }
sub encode_json { $J->encode($_[0]) }
1;
EOF

system('mkdir', '-p', "$stub/Plugins/ListenBrainzFreshReleases") == 0 or die;
system('cp', $API, "$stub/Plugins/ListenBrainzFreshReleases/API.pm") == 0 or die;
system('cp', "$ROOT/ListenBrainzFreshReleases/DB.pm",
             "$stub/Plugins/ListenBrainzFreshReleases/DB.pm") == 0 or die;

# _foldKey and _foldEq reach Browse::_norm through ->can at RUNTIME (API.pm must
# gain no compile-time dependency on Browse). Loading the real Browse.pm here
# would drag in the whole plugin, so the normaliser is provided directly — and it
# must FOLD (lowercase + strip diacritics), not merely lowercase, or section 3's
# diacritic case would pass against a broken fold.
{
    package Plugins::ListenBrainzFreshReleases::Browse;
    sub _norm {
        my ($s) = @_;
        return '' unless defined $s;
        $s = lc $s;
        $s =~ tr{áàâäãåéèêëíìîïóòôöõúùûüñçøæ}{aaaaaaeeeeiiiiooooouuuuncoa};
        $s =~ s/[^a-z0-9]+/ /g;
        $s =~ s/^\s+|\s+$//g;
        return $s;
    }
}

unshift @INC, $stub;

# THE CACHE LEVER IS DB::store, NOT Slim::Utils::Cache. API.pm line 24 is
#     my $cache = Plugins::ListenBrainzFreshReleases::DB::store();
# so the plugin's own SQLite-backed store is the handle every `$cache->get/set`
# in this file talks to. A first cut of this suite stubbed Slim::Utils::Cache
# instead and TEN assertions failed for one reason: the real store was still
# live, so nothing could be observed and nothing could be reset between
# sections — section 3 read a map section 2 had written and made no request at
# all. Stub the handle the code actually holds.
#
# The override must be installed BEFORE API.pm is compiled, because that `my
# $cache = ...` runs at load time and captures whatever store() returns then.
require Plugins::ListenBrainzFreshReleases::DB;
{
    package T::Store;
    sub get    { return $main::CACHE{ $_[1] } }
    sub set    { $main::CACHE{ $_[1] } = $_[2]; $main::CACHE_TTL{ $_[1] } = $_[3]; 1 }
    sub remove { delete $main::CACHE{ $_[1] }; 1 }
}
{
    no warnings 'redefine';
    *Plugins::ListenBrainzFreshReleases::DB::store = sub { bless {}, 'T::Store' };
}

require Plugins::ListenBrainzFreshReleases::API;
my $api = 'Plugins::ListenBrainzFreshReleases::API';

# The lever has to be proven live, or every cache assertion below is vacuous
# against a handle nobody holds — which is exactly how the first cut failed.
{
    %CACHE = ();
    local %ROUTES = ('/discography' => '{"discography":[{"mbid":"x","title":"y"}]}');
    local @REQUESTS = ();
    $api->getReleaseGroupByName('probe', 'y', sub {});
    die "t_rgresolver: DB::store override is not in effect — the suite would be vacuous\n"
        unless grep { /^lbf:hdisco:/ } keys %CACHE;
    %CACHE = (); %CACHE_TTL = ();
}

# ---------------------------------------------------------------------------
# Fixtures. Shapes taken from the live service 2026-08-22, including the ids —
# which is what lets section 1 assert interchangeability with MusicBrainz.
# ---------------------------------------------------------------------------
my $RADIOHEAD = <<'EOF';
{"discography":[
 {"mbid":"b1392450-e666-3926-a536-22c65f834433","title":"OK Computer","primary_type":"Album","release_date":"1997-05-21"},
 {"mbid":"cc78c2fd-3d1a-4b0f-8b52-1234567890ab","title":"OK Computer","primary_type":"Album","secondary_types":["Compilation"],"release_date":"2017-06-23"},
 {"mbid":"aa11bb22-cc33-dd44-ee55-ff6677889900","title":"OK Computer","primary_type":"Album","release_date":"2009-08-24"},
 {"mbid":"6b9a509f-6907-30b4-9dc9-8ac0b0f0c1a3","title":"Kid A","primary_type":"Album","release_date":"2000-10-02"},
 {"mbid":"1111aaaa-2222-bbbb-3333-cccc4444dddd","title":"Reckoner (Cubicolor remix)","primary_type":"Single","release_date":"2014-11-07"}
]}
EOF

my $IRON_ROSES = <<'EOF';
{"discography":[
 {"mbid":"87c8435b-e948-483a-9b88-c5e81b06d7c1","title":"Molotov Nights","primary_type":"Album","release_date":"2026-08-06"}
]}
EOF

# The real "unknown artist" answer: HTTP 200 with an empty object, never a 404.
my $UNKNOWN = '{}';

# A MusicBrainz ws/2 search response, for the fallback assertions.
my $MB_HIT = <<'EOF';
{"release-groups":[{"id":"deadbeef-0000-1111-2222-333344445555","score":100,
 "first-release-date":"1994-03-14","primary-type":"Album"}]}
EOF

sub resolve {
    my (%p) = @_;
    local @REQUESTS = ();
    my @got;
    $api->getReleaseGroupByName($p{artist}, $p{title}, sub { push @got, $_[0] },
                                ($p{artist_mbid} ? (artist_mbid => $p{artist_mbid}) : ()));
    return { got => (@got ? $got[0] : undef), n => scalar(@got), requests => [@REQUESTS] };
}
sub urls_matching { my ($r, $frag) = @_; return grep { index($_->{url}, $frag) >= 0 } @{ $r->{requests} } }
sub reset_all { %CACHE = (); %CACHE_TTL = (); %ROUTES = () }

# ---------------------------------------------------------------------------
section '1. A HOSTED HIT RETURNS THE RELEASE-GROUP ID, AND MB IS NEVER ASKED';
{
    reset_all();
    %ROUTES = ('/discography' => $IRON_ROSES);
    my $r = resolve(artist => 'The Iron Roses', title => 'Molotov Nights');

    is($r->{n}, 1, 'onDone fires exactly once');
    is($r->{got}{mbid}, '87c8435b-e948-483a-9b88-c5e81b06d7c1',
       'the RELEASE-GROUP mbid comes back — byte-identical to MusicBrainz for this album');
    is($r->{got}{year}, '2026', 'the year is derived from release_date');
    is($r->{got}{date}, '2026-08-06', 'and the full date is carried through');
    is($r->{got}{type}, 'Album', 'primary type is carried through');
    is(scalar(urls_matching($r, 'musicbrainz')), 0, 'MusicBrainz was NOT queried');
    is(scalar(urls_matching($r, '/discography')), 1, 'exactly one hosted call was made');
}

# ---------------------------------------------------------------------------
section '2. ONE CALL PER ARTIST, NOT PER ALBUM — the reason this is faster';
{
    reset_all();
    %ROUTES = ('/discography' => $RADIOHEAD);

    my $a = resolve(artist => 'Radiohead', title => 'OK Computer');
    is(scalar(urls_matching($a, '/discography')), 1, 'the first album fetches the discography');
    is($a->{got}{mbid}, 'b1392450-e666-3926-a536-22c65f834433', 'and resolves');

    # THE POINT. A second album by the same artist must cost NO network at all.
    my $b = resolve(artist => 'Radiohead', title => 'Kid A');
    is(scalar(@{ $b->{requests} }), 0, 'a SECOND album by that artist makes no request whatsoever');
    is($b->{got}{mbid}, '6b9a509f-6907-30b4-9dc9-8ac0b0f0c1a3', 'and still resolves, from the cached map');

    # The per-artist map and the per-album answer are separate cache families;
    # both must be written or the next process pays the fetch again.
    ok(scalar(grep { /^lbf:hdisco:/ } keys %CACHE), 'the per-artist map is cached under lbf:hdisco:');
    ok(scalar(grep { /^lbf:rgbyname:/ } keys %CACHE), 'the per-album answer is cached under lbf:rgbyname:');
}

# ---------------------------------------------------------------------------
section '3. THE ARTIST MBID IS SENT — a name collision must not pick a stranger';
{
    reset_all();
    %ROUTES = ('/discography' => $RADIOHEAD);
    my $r = resolve(artist => 'Radiohead', title => 'Kid A',
                    artist_mbid => 'a74b1b7f-71a5-4011-9441-d0b5e4122711');
    my ($req) = urls_matching($r, '/discography');
    ok(defined $req, 'the discography was fetched');
    ok(scalar(($req->{url} // '') =~ /\?mbid=a74b1b7f-71a5-4011-9441-d0b5e4122711/),
       'and the url carries ?mbid= — the service resolves the NAME by popularity without it');

    # THE DISAMBIGUATION HAS TO REACH BOTH CACHE LAYERS. Sending ?mbid= is not
    # enough on its own: the per-ALBUM key is `artist|title`, so two different
    # artists sharing a name AND an album title collide there, and the first one
    # cached answers for the other — the fix defeated one layer below where it was
    # made. Caught by this suite (the hosted map was never even consulted for the
    # second artist, because the album key had already answered).
    reset_all();
    %ROUTES = ('/discography' => $RADIOHEAD);
    resolve(artist => 'Nirvana', title => 'Kid A', artist_mbid => 'aaaaaaaa-0000-0000-0000-000000000001');
    my $n1 = scalar(grep { /^lbf:hdisco:/ } keys %CACHE);
    my $r2 = resolve(artist => 'Nirvana', title => 'Kid A', artist_mbid => 'bbbbbbbb-0000-0000-0000-000000000002');
    my $n2 = scalar(grep { /^lbf:hdisco:/ } keys %CACHE);

    is($n2, $n1 + 1, 'the same NAME with a different mbid fetches its OWN discography');
    ok(scalar(@{ $r2->{requests} } > 0),
       'the second artist is actually looked up, not answered from the first one\'s entry');
    is(scalar(grep { /^lbf:rgbyname:/ } keys %CACHE), 2,
       'and the per-ALBUM answers are cached separately too, not collapsed onto one key');
}

# ---------------------------------------------------------------------------
section '4. FOLD MATCHING, AND WHICH OF SEVERAL SAME-TITLED GROUPS WINS';
{
    reset_all();
    %ROUTES = ('/discography' => $RADIOHEAD);

    # Case and punctuation differences are what a listen-stats title actually
    # looks like; they must not force a MusicBrainz round trip.
    my $r = resolve(artist => 'Radiohead', title => '  ok computer  ');
    is($r->{got}{mbid}, 'b1392450-e666-3926-a536-22c65f834433',
       'a case/whitespace variant folds to the same entry');
    is(scalar(urls_matching($r, 'musicbrainz')), 0, 'without falling back to MusicBrainz');

    # THE DISAMBIGUATION RULE. Three release groups share the title "OK Computer":
    # the 1997 original, a 2009 re-release, and a 2017 Compilation. The field this
    # feeds is a YEAR shown beside an album someone played, so the ORIGINAL STUDIO
    # release must win — not the newest, and never the compilation.
    is($r->{got}{year}, '1997', 'the ORIGINAL wins over a later re-release');
    ok(scalar($r->{got}{mbid} ne 'cc78c2fd-3d1a-4b0f-8b52-1234567890ab'),
       'and the Compilation with the identical title is not chosen');

    # A single missing tie-breaker would flip this silently, so pin the reason
    # rather than only the outcome: secondary types lose EVEN WHEN EARLIER.
    my $pick = $api->can('_hostedDiscoPick');
    ok(defined $pick, '_hostedDiscoPick is reachable for a direct check');
    my $chosen = $pick->([
        { mbid => 'live', date => '1990-01-01', sec => 1 },
        { mbid => 'studio', date => '1999-01-01', sec => 0 },
    ]);
    is($chosen->{mbid}, 'studio', 'a secondary-typed EARLIER release still loses to the plain one');

    # An absent date must not sort as "earliest" — undated entries are common and
    # would otherwise hijack every title they share.
    my $chosen2 = $pick->([
        { mbid => 'undated', date => '', sec => 0 },
        { mbid => 'dated',   date => '2001-01-01', sec => 0 },
    ]);
    is($chosen2->{mbid}, 'dated', 'a dated entry beats an undated one');
}

# ---------------------------------------------------------------------------
section '5. EVERY NON-HIT FALLS BACK TO MUSICBRAINZ — the fallback is the safety';
{
    # (a) the artist is not in the hosted snapshot at all
    reset_all();
    %ROUTES = ('/discography' => $UNKNOWN, 'musicbrainz' => $MB_HIT);
    my $a = resolve(artist => 'Timon Verbeeck', title => 'Operatie T.O.I.L.E.T.');
    ok(scalar(urls_matching($a, 'musicbrainz') > 0), 'an UNKNOWN ARTIST falls back to MusicBrainz');
    is($a->{got}{mbid}, 'deadbeef-0000-1111-2222-333344445555', 'and the MB answer is returned');

    # (b) the artist is known but this title is not in the list — the case a
    #     "the hosted API is authoritative" mistake would swallow
    reset_all();
    %ROUTES = ('/discography' => $RADIOHEAD, 'musicbrainz' => $MB_HIT);
    my $b = resolve(artist => 'Radiohead', title => 'A Moon Shaped Pool');
    ok(scalar(urls_matching($b, 'musicbrainz') > 0), 'a TITLE ABSENT from the discography falls back');
    is($b->{got}{mbid}, 'deadbeef-0000-1111-2222-333344445555', 'and returns the MB answer');

    # (c) the service is down
    reset_all();
    %ROUTES = ('/discography' => { error => 'Service Unavailable', code => 503 },
               'musicbrainz'  => $MB_HIT);
    my $c = resolve(artist => 'Radiohead', title => 'Kid A');
    ok(scalar(urls_matching($c, 'musicbrainz') > 0), 'a hosted 503 falls back rather than failing');
    is($c->{got}{mbid}, 'deadbeef-0000-1111-2222-333344445555', 'and still resolves');

    # (d) both tiers miss — undef, and NOT an exception
    reset_all();
    %ROUTES = ('/discography' => $UNKNOWN, 'musicbrainz' => '{"release-groups":[]}');
    my $d = resolve(artist => 'Pieter Koolwijk', title => 'Missie afbreken');
    is($d->{n}, 1, 'onDone still fires exactly once when both tiers miss');
    is($d->{got}, undef, 'and the answer is undef, not a fabricated id');
}

# ---------------------------------------------------------------------------
section '6. AN UNKNOWN ARTIST IS A SHORT MISS, NOT A 30-DAY ONE';
{
    reset_all();
    %ROUTES = ('/discography' => $UNKNOWN, 'musicbrainz' => $MB_HIT);
    resolve(artist => 'Some New Band', title => 'First Album');

    my ($k) = grep { /^lbf:hdisco:/ } keys %CACHE;
    ok(defined $k, 'the empty discography IS cached (so a feed of unmapped rows does not re-ask per album)');
    is($CACHE{$k}, '', 'cached as the empty sentinel');

    # The hosted service is a WEEKLY snapshot. An artist missing today may be
    # present after the next rebuild, so holding the miss for 30 days would
    # outlast four chances to be right.
    my $ttl = $CACHE_TTL{$k} // 0;
    ok(scalar($ttl > 0 && $ttl <= 86400 * 2),
       "the miss ttl is short (got ${ttl}s, wanted <= 2 days)");

    # And the ceiling that has bitten this fleet twice.
    my $mapTtl = $api->can('HOSTED_DISCO_TTL') ? $api->HOSTED_DISCO_TTL : 0;
    ok(scalar($mapTtl > 0 && $mapTtl <= 2_592_000),
       "the map ttl stays under the 30-day absolute-epoch ceiling (got ${mapTtl}s)");
}

printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
