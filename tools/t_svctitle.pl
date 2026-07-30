#!/usr/bin/env perl
# _stripArtistAffix (LBF 0.9.148): Bandcamp joins its artist onto its own album title, and
# that string must NOT reach Listen Later as the album name. Uses the REAL sub and the REAL
# _norm chain, and the real %FOLD table LIFTED FROM Browse.pm (0.9.148 — it used to be
# hand-copied here, so a %FOLD edit drifted silently instead of failing). No stubs: a change
# to any of it fails here.
#
# TWO halves, and the second is the point:
#   • "must strip" — the wart Bandcamp really produces;
#   • "must not strip" — a wrong strip corrupts the title LL matches and dedupes on, which is
#     strictly worse than the wart it removes.
# Plus a CALL-SITE check: 0.9.147 applied the strip on all four services, and on the three
# that don't join an artist it could only misfire (truncating a real "Album - Artist" title),
# so the search subs are pinned here — Bandcamp calls it, Qobuz/Tidal/Deezer must not.
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
my $LBF = $ENV{LBF_BROWSE} || 'ListenBrainzFreshReleases/Browse.pm';
open(my $fh,'<:encoding(UTF-8)',$LBF) or die "$LBF: $!";
my $SRC = do { local $/; <$fh> };
sub grab { my ($n)=@_; $SRC =~ /\nsub \Q$n\E \{.*?\n\}\n/s or die "no sub $n"; return $&; }
# The %FOLD block, verbatim from the plugin (same lift as tools/bench_walk.pl).
$SRC =~ /(my \$HAVE_NFD = .*?^\);)/ms or die "no %FOLD block in $LBF\n";
my $FOLD = $1;
eval "package X; use strict; use warnings; use utf8;\n" . $FOLD . "\n"
   . grab('_stripArtistAffix') . grab('_norm')
   . grab('_asciiNorm') . grab('_punctNorm') . "1;" or die $@;
my ($p,$f)=(0,0);
sub is { my($d,$g,$w)=@_; my $ok=((defined $g ? $g : '') eq (defined $w ? $w : '')); $ok?$p++:$f++;
    printf "%s %-46s got=%-48s want=%s\n",($ok?'ok  ':'FAIL'),$d,"'".(defined $g?$g:'')."'","'".(defined $w?$w:'')."'"; }
sub ok { my($d,$c)=@_; $c?$p++:$f++; printf "%s %s\n",($c?'ok  ':'FAIL'),$d; }

print "STRIP — Bandcamp has joined the artist on\n";
is('bandcamp suffix (the LIVE case)',
   X::_stripArtistAffix('Radio: Journey Beat (Original Music from Big Walk) - aksfx','aksfx'),
   'Radio: Journey Beat (Original Music from Big Walk)');
is('artist-first join', X::_stripArtistAffix('aksfx - Radio: Fourth Space','aksfx'), 'Radio: Fourth Space');
is('en dash',  X::_stripArtistAffix("Album \x{2013} aksfx",'aksfx'), 'Album');
is('em dash',  X::_stripArtistAffix("aksfx \x{2014} Album",'aksfx'), 'Album');
is('case/punctuation tolerated', X::_stripArtistAffix('Album - AKSFX.','aksfx'), 'Album');
is('title containing its own " - "',
   X::_stripArtistAffix('Songs - Volume One - aksfx','aksfx'), 'Songs - Volume One');
is('artist IS the front half (band Live)',
   X::_stripArtistAffix('Live - Throwing Copper','Live'), 'Throwing Copper');

print "\nMUST NOT STRIP — a wrong strip is worse than the wart\n";
is('already clean',              X::_stripArtistAffix('Radio: Fourth Space','aksfx'), 'Radio: Fourth Space');
is('hyphenated, no spaces',      X::_stripArtistAffix('Jay-Z','Jay'), 'Jay-Z');
is('dash title, artist absent',  X::_stripArtistAffix('Songs - Volume One','aksfx'), 'Songs - Volume One');
is('side only CONTAINS artist',  X::_stripArtistAffix('Album - aksfx remixes','aksfx'), 'Album - aksfx remixes');
is('empty artist',               X::_stripArtistAffix('Album - aksfx',''), 'Album - aksfx');
is('title IS the artist',        X::_stripArtistAffix('aksfx','aksfx'), 'aksfx');
is('undef title',                X::_stripArtistAffix(undef,'aksfx'), undef);
# The 0.9.147 false positive, kept as a live reminder of WHY the call is Bandcamp-only: the
# guards can't save this one — the artist really does equal the discarded side — so the only
# defence is not calling the sub on a service that never joins the artist on. See below.
is('a real catalogue "Album - Artist" IS truncated',
   X::_stripArtistAffix('Goldberg Variations - Glenn Gould','Glenn Gould'), 'Goldberg Variations');

print "\nCALL SITES — the strip is spent only where the wart exists\n";
ok('_searchBandcamp strips',      grab('_searchBandcamp') =~ /_stripArtistAffix/);
for my $svc (qw(_searchQobuz _searchTidal _searchDeezer)) {
    my $body = grab($svc);
    ok("$svc does NOT strip (0.9.148)", $body !~ /^[^#\n]*_stripArtistAffix/m);
    ok("$svc sends the raw album title", $body =~ /\{_svctitle\}\s*=\s*\$album->\{title\}/);
}
printf "\n%d passed, %d failed\n",$p,$f; exit($f?1:0);
